defmodule Hireme.Release do
  @moduledoc """
  What the node does to its own database, so systemd only starts it: the
  schema applied as the first boot step, and the daily backup.

  A database is `priv/db/baseline.sql` (the whole declaration, emitted at
  build by the schema compiler) plus the additive files `priv/db/NNNN_<name>.sql`
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
  def migrate(path \\ Hireme.Repo.config()[:database], files \\ files()) do
    Hireme.Store.write(fn -> locked(path, fn -> apply_files(path, files) end) end)
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

  defp apply_files(path, files) do
    with_conn(path, fn conn ->
      :ok = Sqlite3.execute(conn, @bookkeeping)
      done = conn |> rows("SELECT name FROM schema_files") |> MapSet.new(&hd/1)
      [{@baseline, baseline} | additive] = files

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
      seq = high_water(conn)

      with {:error, reason} <- Sqlite3.execute(conn, sql),
           do: raise("schema file #{Path.basename(file)} failed: #{inspect(reason)}")

      keep_high_water(conn, seq)

      for name <- names,
          do:
            rows(conn, "INSERT INTO schema_files (name, applied_at) VALUES (?1, ?2)", [name, now])

      :ok = Sqlite3.execute(conn, "COMMIT")
      Logger.info("schema: applied #{Enum.join(names, ", ")}")
      names
    rescue
      e ->
        Sqlite3.execute(conn, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  # Ids are never reused, and AUTOINCREMENT keeps that only through
  # sqlite_sequence. A hand-written table rebuild (the one way SQLite
  # changes a column's type or a foreign key) starts the new table's
  # sequence over, so after every file no table's sequence may stand below
  # where it stood before.
  defp high_water(conn) do
    if rows(conn, "SELECT 1 FROM sqlite_schema WHERE name = 'sqlite_sequence'") == [],
      do: [],
      else: rows(conn, "SELECT name, seq FROM sqlite_sequence")
  end

  defp keep_high_water(conn, seq) do
    for [name, n] <- seq do
      rows(conn, "UPDATE sqlite_sequence SET seq = ?2 WHERE name = ?1 AND seq < ?2", [name, n])

      rows(
        conn,
        """
        INSERT INTO sqlite_sequence (name, seq) SELECT ?1, ?2
        WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = ?1)
          AND EXISTS (SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?1)
        """,
        [name, n]
      )
    end
  end

  # The migration lock beside the database, named from SQLite's own name
  # for the file it opened, so the same through any symlinked path.
  defp lock_path(path) do
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
end

defmodule Hireme.Release.Purge do
  @moduledoc """
  What nothing needs any longer, deleted once a day before the backup:
  spent or expired sign-in links and ceremonies a day on, sessions and
  revoked keys a month after they ended, notices a month after they were
  sent or given up, and the trail's activity rows
  (`Hireme.Audit.expiring_kinds/0`) after
  `Hireme.Security.activity_retention_days/0`; every security event on
  the trail is kept. Rows are deleted, never edited. SQL only, by the writer lock.
  """

  import Ecto.Query
  alias Hireme.Repo
  alias Hireme.Rows.{ApiKey, Audit, Challenge, MagicLink, Outbox, Session}

  @day 86_400
  @month 30 * @day

  @doc "Purge as of `now`; answers how many rows of each went."
  @spec run(DateTime.t()) :: %{atom() => non_neg_integer()}
  def run(now \\ Hireme.Store.now()) do
    day = DateTime.add(now, -@day)
    month = DateTime.add(now, -@month)

    rows =
      Hireme.Store.write(fn ->
        %{
          magic_links: delete(from(l in MagicLink, where: l.expires_at < ^day)),
          challenges: delete(from(c in Challenge, where: c.expires_at < ^day)),
          sessions:
            delete(
              from(s in Session,
                where: (not is_nil(s.revoked_at) or s.expires_at < ^now) and s.updated_at < ^month
              )
            ),
          # A revoked key a month on: it counts toward the table's cap until then.
          api_keys:
            delete(from(k in ApiKey, where: not is_nil(k.revoked_at) and k.revoked_at < ^month)),
          outbox:
            delete(
              from(n in Outbox,
                where: (not is_nil(n.sent_at) and n.sent_at < ^month) or n.next_at < ^month
              )
            )
        }
      end)

    Map.put(rows, :audit, purge_activity(now))
  end

  # Activity rows past their retention (refused HELLOs a week, the rest
  # 90 days); security events stay. In batches, each its own turn at the
  # writer lock with a pause between, so a large trail never stalls writers.
  defp purge_activity(now) do
    refused = DateTime.add(now, -Hireme.Security.refusal_retention_days() * @day)
    kept = DateTime.add(now, -Hireme.Security.activity_retention_days() * @day)
    activity = Hireme.Audit.expiring_kinds() -- ["wire_key_refused"]

    batches(from(e in Audit, where: e.kind == "wire_key_refused" and e.inserted_at < ^refused)) +
      batches(from(e in Audit, where: e.kind in ^activity and e.inserted_at < ^kept))
  end

  @batch 5_000
  defp batches(query, done \\ 0) do
    # The ids are found outside the writer lock; only their delete holds it.
    case Repo.all(from(e in query, select: e.id, limit: @batch), skip_account: true) do
      [] ->
        done

      ids ->
        n = Hireme.Store.write(fn -> delete(from(e in Audit, where: e.id in ^ids)) end)
        Process.sleep(20)
        batches(query, done + n)
    end
  end

  defp delete(query) do
    {n, _} = Repo.delete_all(query, skip_account: true)
    n
  end
end

defmodule Hireme.Release.Backup do
  @moduledoc """
  A daily online copy of the database beside it, in `backups/` as
  `hireme-v2-<UTC stamp>.db`, keeping its own newest 13, after the day's
  purge (`Hireme.Release.Purge`). Only its own prefix is pruned: v1's
  `hireme-<stamp>.db` copies stay until the operator deletes them. `Hireme.Store.backup/1` is SQLite's `VACUUM INTO`, a consistent
  copy of the live database, WAL included, that only reads it. A missed
  day (the node was down) is caught up at start; a failure is logged and
  kept in `status/0`, and a scheduled one is retried within the hour.
  """

  use GenServer
  require Logger

  alias Hireme.Release.Purge

  @day :timer.hours(24)
  @retry :timer.hours(1)
  @keep 13
  @name ~r/^hireme-v2-\d{8}T\d{6}\.db$/
  @cut ~r/^hireme-v2-\d{8}T\d{6}\.db\.tmp$/

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
    try do
      Purge.run()
    rescue
      e -> Logger.error("purge failed: #{Exception.message(e)}")
    end

    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%S")
    path = Path.join(s.dir, "hireme-v2-#{stamp}.db")
    tmp = path <> ".tmp"

    last =
      try do
        File.mkdir_p!(s.dir)
        File.chmod!(s.dir, 0o700)
        File.rm(tmp)
        :ok = Hireme.Store.backup(tmp)
        # A copy holds the whole database: the service's user only, whatever the umask.
        File.chmod!(tmp, 0o600)
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
    cut = for name <- File.ls!(dir), name =~ @cut, do: name

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
