defmodule Hireme.Release do
  @moduledoc """
  What the node does to its own database, so systemd only starts it: the
  schema applied as the first boot step, and the daily backup.

  A database is `priv/db/baseline.sql` (the whole declaration, emitted by
  `mix hireme.schema`) plus the additive files `priv/db/NNNN_<name>.sql`
  emitted after it, applied in name order. `schema_files` records each
  file once applied; it is bookkeeping, not declared, and has no row
  module. Because the baseline is always a fresh emit of the declaration,
  an empty database takes the baseline and records every additive file
  present as already contained in it; an existing database takes only
  the additive files it has not recorded. A file that has rows in a
  database the baseline never touched (a v1 file, a stranger's) is
  refused: the only supported starting state is empty.

  Everything runs SQL, never domain code, on a connection of its own,
  under an exclusive transaction on a sidecar database (`<db>.migrate`):
  a second node booting on the same file waits there, then finds nothing
  to do. Tests apply the schema to their own database through `migrate/1`
  and get no children.
  """

  use Supervisor
  require Logger
  alias Exqlite.Sqlite3

  @baseline "0000_baseline"
  @bookkeeping "CREATE TABLE IF NOT EXISTS schema_files (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)"

  def start_link(opts \\ []) do
    if Hireme.Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
      do: :ignore,
      else: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    migrate()
    Supervisor.init([__MODULE__.Backup], strategy: :one_for_one)
  end

  @doc """
  Apply what the database at `path` (default: the repo's) lacks. Answers
  the file names applied, in order.
  """
  @spec migrate(Path.t()) :: [String.t()]
  def migrate(path \\ Hireme.Repo.config()[:database]) do
    Hireme.Store.write(fn -> locked(path, fn -> apply_files(path) end) end)
  end

  @doc "The schema files this release carries: the baseline, then the additive files in order."
  @spec files() :: [{String.t(), Path.t()}]
  def files do
    dir = Application.app_dir(:hireme, "priv/db")

    additive =
      dir
      |> File.ls!()
      |> Enum.filter(
        &(&1 =~ ~r/^\d{4}_[a-z0-9_]+\.sql$/ and not String.starts_with?(&1, "0000_"))
      )
      |> Enum.sort()
      |> Enum.map(&{Path.rootname(&1), Path.join(dir, &1)})

    [{@baseline, Path.join(dir, "baseline.sql")} | additive]
  end

  defp apply_files(path) do
    with_conn(path, fn conn ->
      :ok = Sqlite3.execute(conn, @bookkeeping)
      done = conn |> rows("SELECT name FROM schema_files") |> MapSet.new(&hd/1)
      [{@baseline, baseline} | additive] = files()

      if MapSet.member?(done, @baseline) do
        for {name, file} <- additive, not MapSet.member?(done, name) do
          apply_file(conn, file, [name])
        end
      else
        empty!(conn, path)
        apply_file(conn, baseline, [@baseline | Enum.map(additive, &elem(&1, 0))])
      end
      |> List.flatten()
    end)
  end

  defp empty!(conn, path) do
    case rows(
           conn,
           "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT IN ('schema_files') AND name NOT LIKE 'sqlite_%'"
         ) do
      [] ->
        :ok

      tables ->
        raise "#{path} is not empty and has no baseline (#{length(tables)} tables); a database starts empty"
    end
  end

  # One file, and the names it accounts for, in one transaction.
  defp apply_file(conn, file, names) do
    sql = File.read!(file)
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      with {:error, reason} <- Sqlite3.execute(conn, sql),
           do: raise("schema file #{Path.basename(file)} failed: #{inspect(reason)}")

      for name <- names,
          do:
            exec!(conn, "INSERT INTO schema_files (name, applied_at) VALUES (?1, ?2)", [name, now])

      :ok = Sqlite3.execute(conn, "COMMIT")
      Logger.info("schema: applied #{Enum.join(names, ", ")}")
      names
    rescue
      e ->
        Sqlite3.execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  The migration lock beside the database, named from SQLite's own name
  for the file it opened, so the same through any symlinked path.
  """
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(path) do
    with_conn(path, fn conn ->
      [[_, "main", file] | _] = rows(conn, "PRAGMA database_list")
      file <> ".migrate"
    end)
  end

  defp locked(path, fun) do
    {:ok, lock} = Sqlite3.open(lock_path(path))

    try do
      :ok = Sqlite3.set_busy_timeout(lock, :timer.minutes(5))
      :ok = Sqlite3.execute(lock, "BEGIN EXCLUSIVE")
      fun.()
    after
      Sqlite3.close(lock)
    end
  end

  defp with_conn(path, fun) do
    {:ok, conn} = Sqlite3.open(path)

    try do
      :ok = Sqlite3.set_busy_timeout(conn, 30_000)
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp rows(conn, sql, args \\ []) do
    {:ok, st} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(st, args)
      {:ok, rows} = Sqlite3.fetch_all(conn, st)
      rows
    after
      Sqlite3.release(conn, st)
    end
  end

  defp exec!(conn, sql, args), do: rows(conn, sql, args)
end

defmodule Hireme.Release.Backup do
  @moduledoc """
  A daily online copy of the database beside it, in `backups/`, keeping
  13. `Hireme.Store.backup/1` is SQLite's `VACUUM INTO`, a consistent
  copy of the live database, WAL included, that only reads it. A missed
  day (the node was down) is caught up at start; a failure is logged and
  kept in `status/0`, and a scheduled one is retried within the hour.
  """

  use GenServer
  require Logger

  @day :timer.hours(24)
  @retry :timer.hours(1)
  @keep 13
  @name ~r/^hireme-\d{8}T\d{6}\.db$/

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "The last attempt: `{:ok, path}`, `{:error, reason}`, or nil before the first."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Back up now (`bin/hireme rpc 'Hireme.Release.Backup.run()'`); a failure here is the caller's to retry."
  def run(server \\ __MODULE__), do: GenServer.call(server, :run, :infinity)

  @impl true
  def init(opts) do
    db = Hireme.Repo.config()[:database]
    dir = opts[:dir] || Path.join(Path.dirname(db), "backups")

    age =
      case backups(dir) do
        [] -> @day
        names -> System.os_time(:millisecond) - mtime(dir, List.last(names))
      end

    unless opts[:manual], do: Process.send_after(self(), :run, max(@day - age, 0))
    {:ok, %{dir: dir, last: nil}}
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
        :ok = Hireme.Store.backup(tmp)
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

  # Copies past their 13 days, and any copy a stop cut short. A removal that
  # fails fails the backup.
  defp prune(dir) do
    names = backups(dir)
    old = Enum.drop(names, -@keep)
    cut = for name <- File.ls!(dir), name =~ ~r/^hireme-\d{8}T\d{6}\.db\.tmp$/, do: name

    for name <- old ++ cut,
        {:error, reason} <- [File.rm(Path.join(dir, name))],
        reason != :enoent,
        do: raise(File.Error, reason: reason, action: "remove file", path: Path.join(dir, name))
  end

  # Oldest first: the names sort by their UTC stamp.
  defp backups(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&(&1 =~ @name)) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp mtime(dir, name), do: File.stat!(Path.join(dir, name), time: :posix).mtime * 1000
end
