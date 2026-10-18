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
  @quiet ~w(agent_ops wire_key wire_key_refused activity_coalesced)

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
    # The node's ceiling is on rows: only a row the account's own budget
    # admits spends it, so one account's flood of counts never spends another's.
    # Past the node's ceiling an account still writes its floor.
    admitted? =
      Hireme.Security.hit(budget, account_id, 1) == :ok and
        (budget not in [:activity, :hellos] or
           Hireme.Security.hit(:activity_node, :node, 1) == :ok or
           Hireme.Security.hit(:activity_floor, account_id, 1) == :ok)

    cond do
      admitted? ->
        # A HELLO written under the budget is its address's first, too.
        if name == "wire_key",
          do: __MODULE__.Coalescer.first?(account_id, context[:key_id], context[:ip])

        true

      # Past the budget, a key's first HELLO from an address in the window
      # is still a row (up to `Coalescer.first?/3`'s cap of addresses), so
      # which addresses held a key is never only a count.
      name == "wire_key" ->
        __MODULE__.Coalescer.first?(account_id, context[:key_id], context[:ip])

      true ->
        false
    end
  end

  defp coalesce(budget, name, account_id, context) do
    __MODULE__.Coalescer.count(account_id, budget, name, context)
    if name in @leases, do: __MODULE__.Coalescer.wake(account_id), else: :ok
  end

  @doc false
  # The cursor moves and parked watches wake, with no row: a coalesced lease
  # change still reaches the account lens (at most once a second per
  # account, `Coalescer.wake/1`).
  def moved(account_id) do
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
    commit(kind, meta, context, account_id)
    announce(kind, account_id)
  end

  @doc false
  # The row and the cursor it moves, in one transaction: both or neither.
  def commit(kind, meta, context, account_id) do
    now = Store.now()
    quiet? = Atom.to_string(kind) in @quiet

    {:ok, _} =
      Store.transaction(fn ->
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
                security: Atom.to_string(kind) not in activity_kinds(),
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

    :ok
  end

  @doc false
  # After the commit. An agent's op batch or a key's HELLO is not a change to
  # the account's security state: it wakes no parked account.watch.
  def announce(kind, account_id),
    do: if(Atom.to_string(kind) in @quiet, do: :ok, else: changed(account_id))

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
    security? = view == :security

    q =
      from(e in Event, where: e.security == ^security?, order_by: [desc: e.id], limit: ^limit)

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
  it came from (20 of each named, the rest counted, up to 1,000 tracked a
  window, past which the events from new ones are counted). When the window closes
  its counts become one row (`activity_coalesced`, or `revokes_coalesced`
  for lease revokes), so the trail stays bounded per account and nothing is
  ever edited.

  The table belongs to the application (`table/0`, made in
  `Hireme.Application.start/2`), not to this process, so a crash here keeps
  every count the table holds. Each window's group is taken, then written on
  its own: a write that fails or exits puts back what it took, so only an
  untrappable kill of the flushing process between its take and its commit
  loses that one window's counts. Without the table (the node starting or
  stopping) an event is written as itself. It stops after the sessions and
  sequencers (it starts before them), and writes every open window as it
  goes; an unclean exit of the VM loses the open windows' counts.
  """

  use GenServer, shutdown: :timer.seconds(30)
  require Logger
  alias Hireme.Audit

  @table __MODULE__
  @tick :timer.seconds(30)
  @named 20
  # Distinct addresses (and user agents) a window's group tracks; past it the
  # events are still counted, and so are those from a value it never tracked.
  @tracked 1000
  # Distinct addresses a key's first HELLOs are written for, per window.
  @firsts 50
  # A coalesced lease change wakes the account lens at most this often.
  @wake 1000

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

  defp seen(account_id, budget, w, what, value) do
    key = {what, account_id, budget, w, Hireme.Security.clip(value, 200)}

    # {key, events, first seen}: a row names the values with the most events.
    # A flush may take the key between any two steps here; none raises for it.
    cond do
      bump(key, 1) ->
        true

      :ets.update_counter(@table, {:tracked, account_id, budget, w, what}, 1, {nil, 0}) <=
          @tracked ->
        :ets.insert_new(@table, {key, 1, System.unique_integer([:monotonic])}) or bump(key, 1)

      true ->
        :ets.update_counter(@table, {:untracked, account_id, budget, w, what}, 1, {nil, 0})
    end
  end

  defp bump(key, n) do
    :ets.update_counter(@table, key, {2, n})
    true
  rescue
    ArgumentError -> false
  end

  @doc """
  Whether this is the first HELLO of `key_id` from `ip`'s peer
  (`Hireme.Security.peer/1`) in the account's current window, among the
  first #{@firsts} such peers of the key.
  """
  @spec first?(pos_integer(), pos_integer() | nil, String.t() | nil) :: boolean()
  def first?(account_id, key_id, ip) do
    w = window(:hellos, System.os_time(:millisecond))
    peer = Hireme.Security.peer(ip)

    mark = {:first, account_id, w, key_id, peer}

    # A peer past the key's first ones leaves no mark: the table stays bounded.
    not :ets.member(@table, mark) and
      :ets.update_counter(@table, {:first, account_id, w, key_id, :peers}, 1, {nil, 0}) <=
        @firsts and :ets.insert_new(@table, {mark, true})
  rescue
    ArgumentError -> true
  end

  @doc """
  Wake the account lens for a coalesced lease change: at once if it was not
  woken in the last second, else once when that second ends.
  """
  @spec wake(pos_integer()) :: :ok
  def wake(account_id) do
    now = System.os_time(:millisecond)
    key = {:wake, account_id}

    # Claimed atomically: racing changes wake the lens once, not each.
    claimed? =
      :ets.insert_new(@table, {key, now}) or
        :ets.select_replace(@table, [
          {{key, :"$1"}, [{:<, :"$1", now - @wake}], [{{{:const, key}, now}}]}
        ]) == 1

    if claimed? do
      Audit.moved(account_id)
    else
      last = :ets.lookup_element(@table, key, 2, now)

      # The marker holds when its wake is due, so a lost message cannot
      # keep it (the tick drops one long past due).
      if :ets.insert_new(@table, {{:trailing, account_id}, last + @wake}),
        do: Process.send_after(__MODULE__, {:wake, account_id}, max(last + @wake - now, 0))

      :ok
    end
  rescue
    ArgumentError -> Audit.moved(account_id)
  end

  @doc "Write every window closed by `now_ms` (all of them with `:all`). Answers the rows written."
  @spec flush(integer() | :all) :: non_neg_integer()
  def flush(now_ms \\ System.os_time(:millisecond)) do
    :ets.tab2list(@table)
    |> Enum.filter(&closed?(elem(&1, 0), now_ms))
    |> Enum.group_by(&group(elem(&1, 0)))
    |> Enum.count(fn {group, entries} -> write_group(group, entries) end)
  rescue
    ArgumentError -> 0
  end

  defp closed?({:wake, _}, _), do: false
  defp closed?({:trailing, _}, _), do: false
  defp closed?({:first, _, w, _, _}, now_ms), do: now_ms == :all or w < window(:hellos, now_ms)
  defp closed?(key, now_ms), do: now_ms == :all or elem(key, 3) < window(elem(key, 2), now_ms)

  defp group({:first, account_id, w, _, _}), do: {:first, account_id, w}
  defp group(key), do: {elem(key, 1), elem(key, 2), elem(key, 3)}

  # The first-HELLO marks only expire; every other group becomes one row.
  defp write_group({:first, _, _}, entries) do
    Enum.each(entries, &:ets.delete(@table, elem(&1, 0)))
    false
  end

  # Each key is taken before the row is written, so an event counted after
  # the take is held for the next flush, never deleted unwritten; a write
  # that fails puts what it took back.
  defp write_group({account_id, _, _} = group, entries) do
    taken = Enum.flat_map(entries, &:ets.take(@table, elem(&1, 0)))

    written =
      try do
        write_taken(group, taken)
      rescue
        e ->
          Logger.error(
            "trail coalescing for account #{account_id} failed: #{inspect(e.__struct__)}"
          )

          put_back(taken)
          nil
      catch
        :exit, _ ->
          Logger.error("trail coalescing for account #{account_id} failed: the write exited")
          put_back(taken)
          nil
      end

    # Committed: what follows never puts back, so the row is never written twice.
    if written do
      try do
        Audit.announce(written, account_id)
      rescue
        e -> Logger.error("trail wake for account #{account_id} failed: #{inspect(e.__struct__)}")
      end
    end

    written != nil
  end

  defp write_taken({account_id, budget, w}, entries) do
    {scale, _} = Hireme.Security.limits()[budget]

    counts =
      for {{:n, _, _, _, kind, key_id}, n} <- entries, reduce: %{} do
        acc -> put_in(acc, [Access.key(kind, %{}), to_string(key_id || "none")], n)
      end

    {ips, ip_total} = named(entries, :ip)
    {uas, ua_total} = named(entries, :ua)
    untracked = for {{:untracked, _, _, _, what}, n} <- entries, into: %{}, do: {what, n}

    meta = %{
      from: iso(w * scale),
      to: iso((w + 1) * scale),
      counts: counts,
      addresses: ips,
      addresses_total: ip_total,
      user_agents: uas,
      user_agents_total: ua_total,
      # Events from an address or user agent past the ones tracked.
      addresses_untracked_events: Map.get(untracked, :ip, 0),
      user_agents_untracked_events: Map.get(untracked, :ua, 0)
    }

    kind = if budget == :revokes, do: :revokes_coalesced, else: :activity_coalesced

    if counts != %{} do
      :ok = Audit.commit(kind, meta, %{account_id: account_id}, account_id)
      kind
    end
  end

  # What a failed write took goes back. A tracked value passes the tracking
  # cap again, beside what arrived meanwhile (the old :tracked count is not
  # restored; re-tracking counts afresh), so the cap holds after a put-back.
  defp put_back(taken) do
    {values, counters} = Enum.split_with(taken, &(tuple_size(&1) == 3))

    for {key, n} <- counters,
        elem(key, 0) != :tracked,
        do: :ets.update_counter(@table, key, n, {key, 0})

    for {key, n, first} <- values, do: put_back(key, n, first)
  end

  defp put_back({what, account_id, budget, w, _} = key, n, first) do
    cond do
      bump(key, n) ->
        true

      :ets.update_counter(@table, {:tracked, account_id, budget, w, what}, 1, {nil, 0}) <=
          @tracked ->
        :ets.insert_new(@table, {key, n, first}) or bump(key, n)

      true ->
        :ets.update_counter(@table, {:untracked, account_id, budget, w, what}, n, {nil, 0})
    end
  end

  # The values with the most events, the first seen first among equals, so
  # who is named is not picked by how a value sorts.
  defp named(entries, what) do
    values = for {{^what, _, _, _, value}, n, first} <- entries, do: {value, n, first}
    named = values |> Enum.sort_by(fn {_, n, first} -> {-n, first} end) |> Enum.take(@named)
    {Enum.map(named, &elem(&1, 0)), length(values)}
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
    unless sandbox?() do
      Process.flag(:trap_exit, true)
      :timer.send_interval(@tick, :flush)
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(:flush, s) do
    flush()
    now = System.os_time(:millisecond)
    :ets.select_delete(@table, [{{{:wake, :_}, :"$1"}, [{:<, :"$1", now - @wake}], [true]}])

    :ets.select_delete(@table, [
      {{{:trailing, :_}, :"$1"}, [{:<, :"$1", now - 2 * @wake}], [true]}
    ])

    {:noreply, s}
  end

  # Only a trailing wake still pending is sent.
  def handle_info({:wake, account_id}, s) do
    if :ets.take(@table, {:trailing, account_id}) != [] do
      :ets.insert(@table, {{:wake, account_id}, System.os_time(:millisecond)})

      try do
        Audit.moved(account_id)
      rescue
        e -> Logger.error("trail wake for account #{account_id} failed: #{inspect(e.__struct__)}")
      end
    end

    {:noreply, s}
  end

  def handle_info(_other, s), do: {:noreply, s}

  # The node is stopping: the sessions and sequencers are gone, so no count
  # comes after this.
  @impl true
  def terminate(_reason, _s), do: unless(sandbox?(), do: flush(:all))

  defp sandbox?, do: Hireme.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
end
