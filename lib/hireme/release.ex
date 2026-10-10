defmodule Hireme.Release do
  @moduledoc """
  What the node does to its own database, so systemd only starts it:
  migrations as the first boot step (this module as a child, after
  `Hireme.Ops` so they take the writer lock) and the daily backup
  (`Hireme.Release.Backup`).
  """

  alias Hireme.Repo

  @doc """
  The boot children: pending migrations applied, then the backup. Tests
  own their sandboxed database (`mix test` migrates it first) and get none.
  """
  def children do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: [],
      else: [%{id: __MODULE__, start: {__MODULE__, :start_link, []}}, __MODULE__.Backup]
  end

  def start_link do
    Hireme.Store.write(fn -> Ecto.Migrator.run(Repo, :up, all: true) end)
    :ignore
  end

  @doc "Applies all pending migrations without starting the application (`bin/hireme eval`)."
  @spec migrate() :: :ok
  def migrate do
    :ok = Application.ensure_loaded(:hireme)
    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true))
    :ok
  end
end

defmodule Hireme.Release.Backup do
  @moduledoc """
  A daily online copy of the database beside it, in `backups/`, keeping
  13 days. `VACUUM INTO` is SQLite's own consistent copy of a live
  database, WAL included; it only reads this one, so it takes no writer
  lock. A missed day (the node was down) is caught up at start; a failure
  is logged as an error, kept in `status/0` and retried within the hour.
  """

  use GenServer
  require Logger

  @day :timer.hours(24)
  @retry :timer.hours(1)
  @keep 13

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "The last attempt: `{:ok, path}`, `{:error, reason}`, or nil before the first."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Back up now; answers what `status/1` will."
  def run(server \\ __MODULE__), do: GenServer.call(server, :run, :infinity)

  @impl true
  def init(opts) do
    db = Hireme.Repo.config()[:database]
    dir = opts[:dir] || Path.join(Path.dirname(db), "backups")
    s = %{db: db, dir: dir, last: nil}

    age =
      case backups(dir) do
        [] -> @day
        names -> System.os_time(:millisecond) - mtime(dir, List.last(names))
      end

    unless opts[:manual], do: Process.send_after(self(), :run, max(@day - age, 0))
    {:ok, s}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, s.last, s}
  def handle_call(:run, _from, s), do: s |> backup() |> then(&{:reply, &1.last, &1})

  @impl true
  def handle_info(:run, s) do
    s = backup(s)
    Process.send_after(self(), :run, if(match?({:ok, _}, s.last), do: @day, else: @retry))
    {:noreply, s}
  end

  defp backup(s) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    path = Path.join(s.dir, "hireme-#{stamp}.db")
    tmp = path <> ".tmp"

    last =
      try do
        File.mkdir_p!(s.dir)
        File.rm(tmp)
        copy(s.db, tmp)
        File.rename!(tmp, path)
        prune(s.dir)
        {:ok, path}
      rescue
        e ->
          File.rm(tmp)
          Logger.error("database backup failed: #{Exception.message(e)}")
          {:error, Exception.message(e)}
      end

    %{s | last: last}
  end

  # A connection of its own, read-only: no pool connection is held for the
  # copy, and no transaction (VACUUM refuses to run inside one).
  defp copy(db, to) do
    alias Exqlite.Sqlite3
    {:ok, conn} = Sqlite3.open(db, mode: :readonly)

    try do
      :ok = Sqlite3.set_busy_timeout(conn, 30_000)
      {:ok, st} = Sqlite3.prepare(conn, "VACUUM INTO ?1")
      :ok = Sqlite3.bind(st, [to])
      with {:error, reason} <- Sqlite3.step(conn, st), do: raise(reason)
    after
      Sqlite3.close(conn)
    end
  end

  defp prune(dir) do
    cutoff = System.os_time(:millisecond) - @keep * @day
    for name <- backups(dir), mtime(dir, name) < cutoff, do: File.rm(Path.join(dir, name))
  end

  # Oldest first: the names sort by their UTC stamp.
  defp backups(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&(&1 =~ ~r/^hireme-\d{8}T\d{6}\.db$/)) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp mtime(dir, name), do: File.stat!(Path.join(dir, name), time: :posix).mtime * 1000
end
