defmodule Hireme.Audit do
  @moduledoc """
  The security trail, and the account's topic.

  The trail is append-only (`audit` is declared `append_only`): who did
  what to an account, when, from where, with which key or session. CIS
  Controls v8.1 safeguards 8.2 and 8.5: every row carries its source
  address, user agent, time and kind. An agent's op batch is one row
  (`:agent_ops`), so the trail names every key that wrote.

  The topic `"account:<id>"` on `Hireme.PubSub` carries what a live
  session must react to: `{Hireme.Audit, :changed}` after every recorded
  event (the account lens re-reads), and the `{:bye, ...}` messages that
  end wire sessions (`bye/2`).
  """

  import Ecto.Query
  alias Hireme.Repo
  alias Hireme.Rows.Account
  alias Hireme.Rows.Audit, as: Event
  alias Hireme.Store

  # Kinds on the trail that are activity, not a change to the account.
  @quiet ~w(agent_ops wire_key wire_key_refused activity_coalesced revokes_coalesced)

  # Kinds under a per-account budget, and the node-wide one for activity;
  # past them a row is counted, not written, and the window's counts become
  # one coalesced row. A key's HELLO past its budget is still written the
  # first time a (key, address) is seen in the window.
  @budgeted %{
    "agent_ops" => :activity,
    "lease_opened" => :activity,
    "lease_released" => :activity,
    "wire_key" => :hellos,
    "lease_revoked" => :revokes
  }

  # A lease opening or closing changes what the account lens shows, so it
  # moves the cursor and wakes a parked watch even when coalesced.
  @leases ~w(lease_opened lease_released lease_revoked)

  # Activity that expires (`Hireme.Release.Purge`, after
  # `Security.activity_retention_days/0`); every other kind is kept forever.
  @expiring ~w(agent_ops wire_key wire_key_refused lease_opened lease_released activity_coalesced)

  @doc "The trail's kinds that expire; every other kind is a security event, kept forever."
  @spec expiring_kinds() :: [String.t()]
  def expiring_kinds, do: @expiring

  @doc "The kinds that are activity, not security events: what the account lens's activity view shows."
  @spec activity_kinds() :: [String.t()]
  def activity_kinds,
    do: Enum.uniq(@quiet ++ @expiring ++ (Map.keys(@budgeted) -- ["lease_revoked"]))

  @doc """
  Announce that the account's factors changed (bound, removed, disabled):
  a wire session re-checks at once whether its browser session now owes
  one, or is freed.
  """
  @spec factors(pos_integer()) :: :ok
  def factors(account_id),
    do: Phoenix.PubSub.broadcast(Hireme.PubSub, topic(account_id), {__MODULE__, :factors})

  @type context :: %{
          optional(:account_id) => pos_integer() | nil,
          optional(:ip) => String.t(),
          optional(:user_agent) => String.t(),
          optional(:key_id) => pos_integer() | nil,
          optional(:session_id) => pos_integer() | nil
        }

  @typedoc "Why a wire session ends, and which ones: one key, one browser session, or all."
  @type bye ::
          {{:key, pos_integer()}, :revoked | :grants}
          | {{:session, pos_integer()}, :revoked}
          | {:account, :suspended}

  @doc """
  Record `kind` for the account in `context`, else the one on the
  process, else none (an event before sign-in). `meta` holds display
  fields only (names, kinds, counts, hashes), never a secret.
  """
  @spec record(atom(), map(), context()) :: :ok
  def record(kind, meta \\ %{}, context \\ %{}) when is_atom(kind) and is_map(meta) do
    account_id = Map.get(context, :account_id) || Repo.account_id()
    name = Atom.to_string(kind)
    Process.put({__MODULE__, :recorded}, true)

    case account_id && @budgeted[name] do
      budget when is_atom(budget) and budget != nil ->
        if within?(budget, name, account_id, context),
          do: write(kind, meta, context, account_id),
          else: coalesce(budget, name, account_id, context)

      _ ->
        write(kind, meta, context, account_id)
    end
  end

  defp within?(budget, name, account_id, context) do
    node_ok? =
      budget not in [:activity, :hellos] or Hireme.Security.hit(:activity_node, :node, 1) == :ok

    cond do
      node_ok? and Hireme.Security.hit(budget, account_id, 1) == :ok ->
        # A HELLO written under the budget is its address's first, too.
        if name == "wire_key",
          do: __MODULE__.Coalescer.first?(account_id, context[:key_id], context[:ip])

        true

      # Past the budget, a key's first HELLO from an address in the window
      # is still a row, so which addresses held a key is never a count.
      name == "wire_key" ->
        __MODULE__.Coalescer.first?(account_id, context[:key_id], context[:ip])

      true ->
        false
    end
  end

  defp coalesce(budget, name, account_id, context) do
    __MODULE__.Coalescer.count(account_id, budget, name, context)
    if name in @leases, do: moved(account_id), else: :ok
  end

  # The cursor moves and parked watches wake, with no row: a coalesced lease
  # change still reaches the account lens.
  defp moved(account_id) do
    Store.write(fn ->
      Repo.update_all(from(a in Account, where: a.id == ^account_id), [inc: [audit_rev: 1]],
        skip_account: true
      )
    end)

    changed(account_id)
  end

  @doc false
  # Whether this process recorded an event since `recorded?(:reset)`: how an
  # account.* call knows it wrote, whatever else the account does meanwhile.
  def recorded?(:reset), do: Process.delete({__MODULE__, :recorded})
  def recorded?(:check), do: Process.get({__MODULE__, :recorded}, false)

  @doc false
  def write(kind, meta, context, account_id) do
    now = Store.now()
    quiet? = Atom.to_string(kind) in @quiet

    Store.write(fn ->
      {1, [%{id: id}]} =
        Repo.insert_all(
          Event,
          [
            %{
              account_id: account_id,
              kind: Atom.to_string(kind),
              ip: blank(context[:ip], 64),
              user_agent: blank(context[:user_agent], 200),
              meta: meta,
              key_id: Map.get(context, :key_id),
              session_id: Map.get(context, :session_id),
              rev: 1,
              inserted_at: now,
              updated_at: now
            }
          ],
          skip_account: true,
          returning: [:id]
        )

      # The cursor moves in the same turn as the row that moves it: a count
      # of the account's announced changes, so a coalesced lease change can
      # move it too.
      if account_id && not quiet? do
        _ = id

        Repo.update_all(from(a in Account, where: a.id == ^account_id), [inc: [audit_rev: 1]],
          skip_account: true
        )
      end
    end)

    # An agent's op batch or a key's HELLO is not a change to the account's
    # security state: it wakes no parked account.watch and moves no cursor.
    if quiet?, do: :ok, else: changed(account_id)
  end

  defp blank(nil, _), do: nil

  defp blank(value, max) do
    case Hireme.Security.clip(value, max) do
      "" -> nil
      text -> text
    end
  end

  @spec topic(pos_integer()) :: String.t()
  def topic(account_id), do: "account:#{account_id}"

  @doc """
  Announce a change to the account's security state to every other
  process on its topic. Recording an event does this; every change to
  that state is recorded, so `rev/1` moves with every announcement.
  """
  @spec changed(pos_integer() | nil) :: :ok
  def changed(nil), do: :ok

  def changed(account_id),
    do:
      Phoenix.PubSub.broadcast_from(
        Hireme.PubSub,
        self(),
        topic(account_id),
        {__MODULE__, :changed}
      )

  @doc "End the wire sessions `bye` names; each sends BYE with the reason and drops its lease."
  @spec bye(pos_integer(), bye()) :: :ok
  def bye(account_id, {who, reason}),
    do: Phoenix.PubSub.broadcast(Hireme.PubSub, topic(account_id), {:bye, who, reason})

  @doc """
  How far the account's security state has moved: a count of the changes
  it announced (every event but activity, and every lease opening or
  closing, coalesced or not). It only grows, is kept on the account row
  (`accounts.audit_rev`) in the turn that announces, and `account.watch`
  compares against it.
  """
  @spec rev(pos_integer()) :: non_neg_integer()
  def rev(account_id) do
    Repo.one(from(a in Account, where: a.id == ^account_id, select: a.audit_rev),
      skip_account: true
    ) || 0
  end

  @doc """
  A page of the account's trail on the process, newest first: its security
  events or its activity (`activity_kinds/0`), with ids below `before`.
  """
  @spec page(:security | :activity, pos_integer(), integer() | nil) :: [struct()]
  def page(view, limit, before) do
    activity = activity_kinds()
    q = from(e in Event, order_by: [desc: e.id], limit: ^limit)

    q =
      if view == :activity,
        do: where(q, [e], e.kind in ^activity),
        else: where(q, [e], e.kind not in ^activity)

    q = if is_integer(before), do: where(q, [e], e.id < ^before), else: q
    Repo.all(q)
  end

  @doc "The latest events for the account on the process, newest first."
  @spec recent(pos_integer()) :: [struct()]
  def recent(limit \\ 50), do: Repo.all(from(e in Event, order_by: [desc: e.id], limit: ^limit))
end

defmodule Hireme.Audit.Coalescer do
  @moduledoc """
  An account's activity past its trail budget, counted instead of written:
  per window, per kind and key, with the distinct addresses and user agents
  it came from (20 of each named, the rest counted). When the window closes
  its counts become one row (`activity_coalesced`, or `revokes_coalesced`
  for lease revokes), so the trail stays bounded per account and nothing is
  ever edited.

  The table belongs to the application (`table/0`, made in
  `Hireme.Application.start/2`), not to this process: a crash here loses no
  count. Each window's group is written on its own, under a rescue, and
  only what was written is deleted. Without the table (the node starting or
  stopping) an event is written as itself.
  """

  use GenServer
  require Logger
  alias Hireme.Audit

  @table __MODULE__
  @tick :timer.seconds(30)
  @named 20

  @doc "Make the counts table; the application's own process owns it."
  def table, do: :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Count one event of `kind` for the account's current window, with where it came from."
  @spec count(pos_integer(), atom(), String.t(), map()) :: :ok
  def count(account_id, budget, kind, context) do
    w = window(budget, System.os_time(:millisecond))
    :ets.update_counter(@table, {:n, account_id, budget, w, kind, context[:key_id]}, 1, {nil, 0})
    seen(account_id, budget, w, :ip, context[:ip])
    seen(account_id, budget, w, :ua, context[:user_agent])
    :ok
  rescue
    ArgumentError ->
      Audit.write(String.to_existing_atom(kind), %{}, context, account_id)
  end

  defp seen(_, _, _, _, nil), do: :ok

  defp seen(account_id, budget, w, what, value),
    do:
      :ets.insert_new(
        @table,
        {{what, account_id, budget, w, Hireme.Security.clip(value, 200)}, true}
      )

  @doc "Whether this is the first HELLO of `key_id` from `ip` in the account's current window."
  @spec first?(pos_integer(), pos_integer() | nil, String.t() | nil) :: boolean()
  def first?(account_id, key_id, ip) do
    w = window(:hellos, System.os_time(:millisecond))
    :ets.insert_new(@table, {{:first, account_id, w, key_id, ip}, true})
  rescue
    ArgumentError -> true
  end

  @doc "Write every window closed by `now_ms` (all of them with `:all`). Answers the rows written."
  @spec flush(integer() | :all) :: non_neg_integer()
  def flush(now_ms \\ System.os_time(:millisecond)) do
    rows = :ets.tab2list(@table)

    rows
    |> Enum.filter(fn {key, _} -> closed?(key, now_ms) end)
    |> Enum.group_by(fn {key, _} -> group(key) end)
    |> Enum.count(fn {group, entries} -> write_group(group, entries) end)
  rescue
    ArgumentError -> 0
  end

  defp closed?({:first, _, w, _, _}, now_ms), do: now_ms == :all or w < window(:hellos, now_ms)
  defp closed?(key, now_ms), do: now_ms == :all or elem(key, 3) < window(elem(key, 2), now_ms)

  defp group({:first, account_id, w, _, _}), do: {:first, account_id, w}
  defp group(key), do: {elem(key, 1), elem(key, 2), elem(key, 3)}

  # The first-HELLO marks only expire; every other group becomes one row.
  defp write_group({:first, _, _}, entries) do
    Enum.each(entries, fn {key, _} -> :ets.delete(@table, key) end)
    false
  end

  defp write_group({account_id, budget, w}, entries) do
    {scale, _} = Hireme.Security.limits()[budget]

    counts =
      for {{:n, _, _, _, kind, key_id}, n} <- entries, reduce: %{} do
        acc -> put_in(acc, [Access.key(kind, %{}), to_string(key_id || "none")], n)
      end

    {ips, ip_total} = named(entries, :ip)
    {uas, ua_total} = named(entries, :ua)

    meta = %{
      from: iso(w * scale),
      to: iso((w + 1) * scale),
      counts: counts,
      addresses: ips,
      addresses_total: ip_total,
      user_agents: uas,
      user_agents_total: ua_total
    }

    kind = if budget == :revokes, do: :revokes_coalesced, else: :activity_coalesced
    if counts != %{}, do: Audit.write(kind, meta, %{account_id: account_id}, account_id)
    Enum.each(entries, fn {key, _} -> :ets.delete(@table, key) end)
    counts != %{}
  rescue
    # A group that cannot be written stays for the next flush; the others go on.
    e ->
      Logger.error("trail coalescing for account #{account_id} failed: #{inspect(e.__struct__)}")
      false
  end

  defp named(entries, what) do
    values = for {{^what, _, _, _, value}, _} <- entries, do: value
    {Enum.take(Enum.sort(values), @named), length(values)}
  end

  defp iso(ms),
    do:
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  defp window(budget, now_ms) do
    {scale, _} = Hireme.Security.limits()[budget]
    div(now_ms, scale)
  end

  @impl true
  def init(:ok) do
    # Tests flush themselves, in their own sandboxed process.
    unless Hireme.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: :timer.send_interval(@tick, :flush)

    {:ok, nil}
  end

  @impl true
  def handle_info(:flush, s) do
    flush()
    {:noreply, s}
  end

  def handle_info(_other, s), do: {:noreply, s}
end
