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
  """

  @behaviour __MODULE__

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
  @doc "Log client ops' outcomes, in one statement."
  @callback log(account(), [entry()]) :: :ok
  @doc "The account's op outcomes logged since `since`: `{op_id, rev, refusal | nil, unix}`."
  @callback ledger(account(), DateTime.t()) :: [
              {integer(), integer(), String.t() | nil, integer()}
            ]
  @doc "Drop the account's op outcomes logged before `before`."
  @callback sweep(account(), DateTime.t()) :: :ok
  @doc "Periodic upkeep off the write path (SQLite: fold the WAL into the database)."
  @callback checkpoint() :: :ok

  @impl true
  def transaction(fun), do: Repo.transaction(fun)

  @impl true
  def rollback(reason), do: Repo.rollback(reason)

  @impl true
  def savepoint(:open), do: query!("SAVEPOINT op", [])
  def savepoint(:keep), do: query!("RELEASE op", [])
  def savepoint(:undo), do: query!("ROLLBACK TO op; RELEASE op", [])

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
  def log(_account, []), do: :ok

  def log(account, entries) do
    query!(
      "INSERT INTO wire_ops (account_id, op_id, kind, rev, refusal, inserted_at) VALUES " <>
        Enum.map_join(entries, ", ", fn _ -> "(?, ?, ?, ?, ?, ?)" end),
      Enum.flat_map(entries, &([account | &1] ++ [now()]))
    )
  end

  @impl true
  def ledger(account, since) do
    %{rows: rows} =
      Repo.query!(
        "SELECT op_id, rev, refusal, unixepoch(inserted_at) FROM wire_ops " <>
          "WHERE account_id = ? AND inserted_at >= ?",
        [account, iso(since)],
        skip_account: true
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  @impl true
  def sweep(account, before),
    do:
      query!("DELETE FROM wire_ops WHERE account_id = ? AND inserted_at < ?", [
        account,
        iso(before)
      ])

  # PASSIVE never waits on a writer and never makes one wait; the fsync
  # it costs is paid here, not by the write whose commit crossed
  # SQLite's own threshold (off: `wal_auto_check_point: 0`).
  @impl true
  def checkpoint, do: query!("PRAGMA wal_checkpoint(PASSIVE)", [])

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
