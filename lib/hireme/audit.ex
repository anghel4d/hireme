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

  # Kinds under a per-account budget; past it a row is counted, not written,
  # and the window's counts become one coalesced row.
  @budgeted %{
    "agent_ops" => :activity,
    "lease_opened" => :activity,
    "lease_released" => :activity,
    "wire_key" => :activity,
    "lease_revoked" => :revokes
  }

  # Activity that expires (`Hireme.Release.Purge`, after
  # `Security.activity_retention_days/0`); every other kind is kept forever.
  @expiring ~w(agent_ops wire_key wire_key_refused lease_opened lease_released activity_coalesced)

  @doc "The trail's kinds that expire; every other kind is a security event, kept forever."
  @spec expiring_kinds() :: [String.t()]
  def expiring_kinds, do: @expiring

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

    with budget when budget != nil and account_id != nil <- @budgeted[name],
         {:error, _} <- Hireme.Security.hit(budget, account_id, 1) do
      __MODULE__.Coalescer.count(account_id, budget, name, Map.get(context, :key_id))
    else
      _ -> write(kind, meta, context, account_id)
    end
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

      # The cursor moves in the same turn as the row that moves it.
      if account_id && not quiet? do
        Repo.update_all(from(a in Account, where: a.id == ^account_id), [set: [audit_rev: id]],
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
  How far the account's security state has moved: the newest event that
  announces itself (every kind but activity: agent op batches and key
  HELLOs). The trail is
  append-only, so it only grows. Kept on the account row
  (`accounts.audit_rev`), written with the event, so reading it is one row;
  `account.watch` compares against it.
  """
  @spec rev(pos_integer()) :: non_neg_integer()
  def rev(account_id) do
    Repo.one(from(a in Account, where: a.id == ^account_id, select: a.audit_rev),
      skip_account: true
    ) || 0
  end

  @doc "The latest events for the account on the process, newest first."
  @spec recent(pos_integer()) :: [struct()]
  def recent(limit \\ 50), do: Repo.all(from(e in Event, order_by: [desc: e.id], limit: ^limit))
end

defmodule Hireme.Audit.Coalescer do
  @moduledoc """
  An account's activity past its trail budget, counted instead of written:
  per window, per kind and key. When the window closes its counts become one
  row (`activity_coalesced`, or `revokes_coalesced` for lease revokes), so
  the trail stays bounded per account and nothing is ever edited. A stop
  writes what it holds.
  """

  use GenServer
  alias Hireme.Audit

  @table __MODULE__
  @tick :timer.seconds(30)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Count one event of `kind` by `key_id` for the account's current window."
  @spec count(pos_integer(), atom(), String.t(), pos_integer() | nil) :: :ok
  def count(account_id, budget, kind, key_id) do
    key = {account_id, budget, window(budget, System.os_time(:millisecond)), kind, key_id}
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  end

  @doc "Write every window that has closed by `now_ms` (all of them with `:all`). Answers the rows written."
  @spec flush(integer() | :all) :: non_neg_integer()
  def flush(now_ms \\ System.os_time(:millisecond)) do
    closed =
      for {{account_id, budget, w, _, _} = key, n} <- :ets.tab2list(@table),
          now_ms == :all or w < window(budget, now_ms),
          do: {key, n, {account_id, budget, w}}

    closed
    |> Enum.group_by(&elem(&1, 2))
    |> Enum.map(fn {{account_id, budget, w}, entries} ->
      {scale, _} = Hireme.Security.limits()[budget]

      counts =
        Enum.reduce(entries, %{}, fn {{_, _, _, kind, key_id}, n, _}, acc ->
          put_in(acc, [Access.key(kind, %{}), to_string(key_id || "none")], n)
        end)

      kind = if budget == :revokes, do: :revokes_coalesced, else: :activity_coalesced

      Audit.write(
        kind,
        %{
          from: iso(w * scale),
          to: iso((w + 1) * scale),
          counts: counts
        },
        %{account_id: account_id},
        account_id
      )

      Enum.each(entries, fn {key, _, _} -> :ets.delete(@table, key) end)
    end)
    |> length()
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
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
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

  @impl true
  def terminate(_reason, _s) do
    unless Hireme.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox, do: flush(:all)
    :ok
  end
end
