defmodule Hireme.Store do
  @moduledoc """
  SQLite as the authority: one writer, taken in turn.

  SQLite has one writer, and a connection that finds it taken backs off
  while another retakes it, so under load writers starve each other. Every
  write in this VM therefore takes the lock here first (`write/1,2`,
  `transaction/1`), granted in the order asked; a holder that dies or
  raises frees it. A write inside a write runs in place. Writers from
  another VM (a release RPC) still meet SQLite's own lock, which the
  connection's busy timeout (`Hireme.Repo`) waits out.

  The database path and pragmas come only from `Hireme.Repo`'s config.
  """

  use GenServer
  alias Hireme.Repo

  @doc "Run `fun` (or `fun.(arg)`) holding the writer lock, as one turn."
  @spec write((-> result)) :: result when result: term()
  def write(fun) do
    if Process.put(__MODULE__, true) do
      fun.()
    else
      try do
        :ok = GenServer.call(__MODULE__, :lock, :infinity)
        fun.()
      after
        Process.delete(__MODULE__)
        GenServer.cast(__MODULE__, {:unlock, self()})
      end
    end
  end

  @spec write(arg, (arg -> result)) :: result when arg: term(), result: term()
  def write(arg, fun), do: write(fn -> fun.(arg) end)

  @doc """
  Run `fun` in one `BEGIN IMMEDIATE` transaction under the writer lock:
  `{:ok, value}`, or `{:error, reason}` after `Repo.rollback/1`.
  """
  @spec transaction((-> term())) :: {:ok, term()} | {:error, term()}
  def transaction(fun), do: write(fn -> Repo.transaction(fun, mode: :immediate) end)

  @doc """
  Inside a transaction: open the op's savepoint, keep it, or undo to it.
  One op per savepoint, so a refusal rolls back exactly that op.
  """
  @spec savepoint(:open | :keep | :undo) :: :ok
  def savepoint(:open), do: exec("SAVEPOINT op")
  def savepoint(:keep), do: exec("RELEASE op")
  # One statement per query: a prepared query runs its first statement only.
  def savepoint(:undo) do
    :ok = exec("ROLLBACK TO op")
    exec("RELEASE op")
  end

  @doc "The second a write is stamped with: UTC, whole seconds."
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  A consistent copy of the whole database at `path`, taken while writers
  keep writing (`VACUUM INTO`). The file must not exist yet.
  """
  @spec backup(Path.t()) :: :ok | {:error, term()}
  def backup(path) do
    case Repo.query("VACUUM INTO ?", [path], skip_account: true) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp exec(sql) do
    Repo.query!(sql, [], skip_account: true)
    :ok
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
end
