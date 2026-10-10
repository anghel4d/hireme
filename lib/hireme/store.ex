defmodule Hireme.Store do
  @moduledoc """
  What the sequencer (`Hireme.Ops`) asks of the database, and SQLite's
  answer to it.

  The sequencer is the account's single writer: it seals a batch of
  writes into one transaction, numbers their revisions, logs each client
  op's outcome and commits once. Every statement of its own on that path
  is a callback here, with the account named rather than read off the
  process, so another database can stand behind the same sequencer: a
  PostgreSQL or Cassandra store implements this behaviour and is chosen
  with `config :hireme, :store, Module`. A shadow drainer replaying the
  sequencer's batches into a second store needs nothing more than these.

  The domain writes themselves (`Hireme.Desk.execute/1` and the lanes)
  still go through `Hireme.Repo` and Ecto, inside `transaction/1`.

  Rows are the database's own values (text, integers, JSON text, ISO
  dates); they go to the wire as they are.

  SQLite has one writer at a time, and a writer that finds it taken
  sleeps on a growing backoff while another retakes it: under two busy
  accounts the loser waited up to a second. So every write takes a lock
  here first, granted in the order asked, and then the database's (a
  transaction begins IMMEDIATE): the sequencers' through `transaction/1`
  and `sweep/3`, the rest (sessions, keys, MFA, audit, mail, imports)
  through `transaction/1` or `write/1`. A holder that dies, or raises,
  frees it. A write that skips it (tests, migrations) still busy-waits,
  and the lock is this VM's: another VM on the same file (a release
  task, a remote console) has its own and contends at SQLite's lock as
  before. Its writes stay correct (the revision gap re-reads); only
  their order and fairness against ours are not kept. A store for a
  database with concurrent writers has no need of the lock.
  """

  @behaviour __MODULE__
  use GenServer

  alias Hireme.Repo

  @type account :: pos_integer()
  @type filter :: nil | {atom(), [term()]}
  @typedoc "A client op's outcome: `[op_id, kind, rev, refusal | nil]`."
  @type entry :: [term()]

  @doc "Run `fun` in one transaction: `{:ok, value}`, or `{:error, reason}` after `rollback/1`."
  @callback transaction((-> term())) :: {:ok, term()} | {:error, term()}
  @doc "Abandon the transaction in hand with `reason`."
  @callback rollback(term()) :: no_return()
  @doc "Inside a transaction: open a savepoint, keep it, or undo to it."
  @callback savepoint(:open | :keep | :undo) :: :ok
  @doc "The account's revision as stored."
  @callback rev(account()) :: non_neg_integer()
  @doc "Move the account's revision on by `n` and answer the last one."
  @callback bump(account(), pos_integer()) :: non_neg_integer()
  @doc "Take the account's next application number."
  @callback number(account()) :: pos_integer()
  @doc "The account's rows of `source` (every one, or those whose field is in values), as maps of `cols`."
  @callback read(String.t(), [atom()], account(), filter()) :: [map()]
  @doc """
  Set columns of one of the account's rows. A value is plain, or
  `{:json_put, key, value}` into a JSON column, answered with that
  column's new text. Answers the id and the columns set.
  """
  @callback write(String.t(), pos_integer(), account(), keyword()) ::
              {:ok, map()} | {:error, :not_found}
  @doc """
  Log client ops' outcomes in one statement, sharing one timestamp for
  the batch. Answers the op ids logged: one logged already is left as it
  was.
  """
  @callback log(account(), [entry()]) :: [integer()]
  @doc "The account's logged outcomes of these op ids: `{op_id, rev, refusal | nil}`."
  @callback answers(account(), [integer()]) :: [
              {integer(), integer(), String.t() | nil}
            ]
  @doc "Drop up to `limit` of the account's op outcomes logged before `before`; answers how many."
  @callback sweep(account(), DateTime.t(), pos_integer()) :: non_neg_integer()
  @doc """
  Upkeep off the write path (SQLite: fold the WAL into the database).
  `:behind` asks a writer to run it once between two of its commits:
  under a writer that never pauses, the log is never found wholly folded
  at the start of a write, so it never rewinds and grows without end.
  """
  @callback checkpoint() :: :ok | :behind

  @impl true
  def transaction(fun), do: write(fn -> Repo.transaction(fun, mode: :immediate) end)

  @doc """
  Run `fun` (one statement, or `fun.(arg)`) holding the writer lock: how
  a write outside the sequencers (a session, a key, an audit event)
  takes its turn instead of busy-waiting on SQLite's lock.
  """
  def write(arg, fun), do: write(fn -> fun.(arg) end)

  def write(fun) do
    if Process.get(__MODULE__) do
      fun.()
    else
      :ok = GenServer.call(__MODULE__, :lock, :infinity)
      Process.put(__MODULE__, true)

      try do
        fun.()
      after
        Process.delete(__MODULE__)
        GenServer.cast(__MODULE__, {:unlock, self()})
      end
    end
  end

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # The lock: its holder (pid and monitor) and the callers waiting, in order.
  @impl GenServer
  def init(:ok), do: {:ok, grant(:queue.new())}

  @impl GenServer
  def handle_call(:lock, from, {nil, waiting}), do: {:noreply, grant(:queue.in(from, waiting))}
  def handle_call(:lock, from, {held, waiting}), do: {:noreply, {held, :queue.in(from, waiting)}}

  @impl GenServer
  def handle_cast({:unlock, pid}, {{pid, ref}, waiting}) do
    Process.demonitor(ref, [:flush])
    {:noreply, grant(waiting)}
  end

  def handle_cast(_stale, lock), do: {:noreply, lock}

  @impl GenServer
  def handle_info({:DOWN, ref, _, _, _}, {{_, ref}, waiting}), do: {:noreply, grant(waiting)}
  def handle_info(_stale, lock), do: {:noreply, lock}

  defp grant(waiting) do
    case :queue.out(waiting) do
      {{:value, {pid, _} = from}, rest} ->
        GenServer.reply(from, :ok)
        {{pid, Process.monitor(pid)}, rest}

      {:empty, rest} ->
        {nil, rest}
    end
  end

  @impl true
  def rollback(reason), do: Repo.rollback(reason)

  @impl true
  def savepoint(:open), do: query!("SAVEPOINT op", [])
  def savepoint(:keep), do: query!("RELEASE op", [])
  # One statement per query: a prepared query runs its first statement only.
  def savepoint(:undo),
    do: with(:ok <- query!("ROLLBACK TO op", []), do: query!("RELEASE op", []))

  @impl true
  def rev(account), do: one!("SELECT desk_rev FROM accounts WHERE id = ?", [account])

  @impl true
  def bump(account, n),
    do:
      one!("UPDATE accounts SET desk_rev = desk_rev + ? WHERE id = ? RETURNING desk_rev", [
        n,
        account
      ])

  # Taken in the write that opens the application, so never handed out twice.
  @impl true
  def number(account),
    do:
      one!("UPDATE accounts SET next_no = next_no + 1 WHERE id = ? RETURNING next_no - 1", [
        account
      ])

  @impl true
  def read(source, cols, account, filter) do
    {where, params} =
      case filter do
        nil -> {"", []}
        {field, values} -> {" AND #{field} IN (#{marks(values)})", values}
      end

    %{rows: rows} =
      Repo.query!(
        "SELECT #{quoted(cols)} FROM #{source} WHERE account_id = ?" <> where,
        [account | params],
        skip_account: true
      )

    Enum.map(rows, &Map.new(Enum.zip(cols, &1)))
  end

  @impl true
  def write(source, id, account, changes) do
    {sets, params} =
      (changes ++ [updated_at: now()])
      |> Enum.map(fn
        {col, {:json_put, key, value}} ->
          {~s["#{col}" = json_set("#{col}", ?, ?)], ["$." <> key, value]}

        {col, value} ->
          {~s("#{col}" = ?), [native(value)]}
      end)
      |> Enum.unzip()

    json = for {col, {:json_put, _, _}} <- changes, do: col

    plain =
      for {col, value} <- changes,
          not match?({:json_put, _, _}, value),
          into: %{},
          do: {col, native(value)}

    sql =
      "UPDATE #{source} SET #{Enum.join(sets, ", ")} WHERE id = ? AND account_id = ?" <>
        if(json == [], do: "", else: " RETURNING #{quoted(json)}")

    case Repo.query!(sql, Enum.concat(params) ++ [id, account], skip_account: true) do
      %{num_rows: 0} ->
        {:error, :not_found}

      %{rows: [row]} when json != [] ->
        {:ok, Map.merge(plain, Map.new(Enum.zip(json, row))) |> Map.put(:id, id)}

      %{num_rows: 1} ->
        {:ok, Map.put(plain, :id, id)}
    end
  end

  @impl true
  def log(_account, []), do: []

  def log(account, entries) do
    at = now()

    %{rows: rows} =
      Repo.query!(
        "INSERT INTO wire_ops (account_id, op_id, kind, rev, refusal, inserted_at) VALUES " <>
          Enum.map_join(entries, ", ", fn _ -> "(?, ?, ?, ?, ?, ?)" end) <>
          " ON CONFLICT (account_id, op_id) DO NOTHING RETURNING op_id",
        Enum.flat_map(entries, &([account | &1] ++ [at])),
        skip_account: true
      )

    List.flatten(rows)
  end

  @impl true
  def answers(account, op_ids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT op_id, rev, refusal FROM wire_ops WHERE account_id = ? AND op_id IN (#{marks(op_ids)})",
        [account | op_ids],
        skip_account: true
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  @impl true
  def sweep(account, before, limit) do
    %{num_rows: n} =
      write(fn ->
        Repo.query!(
          "DELETE FROM wire_ops WHERE rowid IN (SELECT rowid FROM wire_ops " <>
            "WHERE account_id = ? AND inserted_at < ? LIMIT ?)",
          [account, iso(before), limit],
          skip_account: true
        )
      end)

    n
  end

  # PASSIVE never waits on a writer and never makes one wait; the fsync
  # it costs is paid here, not by the write whose commit crossed
  # SQLite's own threshold (off: `wal_auto_check_point: 0`). Past
  # @wal_frames the log is behind.
  @wal_frames 4096

  @impl true
  def checkpoint do
    case Repo.query!("PRAGMA wal_checkpoint(PASSIVE)", [], skip_account: true) do
      %{rows: [[_busy, log, _done]]} when log > @wal_frames -> :behind
      _ -> :ok
    end
  end

  defp query!(sql, params) do
    Repo.query!(sql, params, skip_account: true)
    :ok
  end

  defp one!(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params, skip_account: true)
    value
  end

  defp marks(values), do: Enum.map_join(values, ",", fn _ -> "?" end)

  # Column names quoted: `no` is an SQL keyword.
  defp quoted(cols), do: Enum.map_join(cols, ",", &~s("#{&1}"))

  defp native(%Date{} = day), do: Date.to_iso8601(day)
  defp native(value), do: value

  defp now, do: DateTime.utc_now() |> iso()
  defp iso(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
