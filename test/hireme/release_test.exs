defmodule Hireme.ReleaseTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Exqlite.Sqlite3
  alias Hireme.{DataCase, Release, Repo, Store}
  alias Hireme.Release.{Backup, Purge}
  alias Hireme.Rows.{Audit, Session}

  defp sql(db, statement) do
    {:ok, conn} = Sqlite3.open(db)
    {:ok, st} = Sqlite3.prepare(conn, statement)
    {:ok, rows} = Sqlite3.fetch_all(conn, st)
    Sqlite3.close(conn)
    rows
  end

  defp tables(db),
    do: List.flatten(sql(db, "SELECT name FROM sqlite_schema WHERE type = 'table'"))

  describe "a database file" do
    @describetag :tmp_dir
    setup %{tmp_dir: dir}, do: %{db: Path.join(dir, "hireme.db")}

    test "an empty database takes the whole schema once (two nodes booting on it, too); a second run applies nothing",
         %{db: db} do
      boots = for _ <- 1..2, do: Task.async(fn -> Release.migrate(db) end)
      [again, applied] = Enum.sort_by(Task.await_many(boots, 30_000), &length/1)
      assert hd(applied) == "0000_baseline" and length(applied) == length(Release.files())
      assert again == []

      for t <- Hireme.Schema.tables(),
          t.residency in [:resident, :server],
          do: assert(to_string(t.name) in tables(db), "#{t.name} missing")

      assert Release.migrate(db) == []
    end

    test "a database that already holds tables it did not get from a baseline is refused", %{
      db: db
    } do
      sql(db, "CREATE TABLE stranger (id INTEGER PRIMARY KEY)")
      assert_raise RuntimeError, ~r/not empty/, fn -> Release.migrate(db) end
      refute "accounts" in tables(db)
    end

    test "a table rebuilt by a schema file never hands out an id it handed out before",
         %{db: db, tmp_dir: dir} do
      base = Path.join(dir, "baseline.sql")
      File.write!(base, "CREATE TABLE things (id INTEGER PRIMARY KEY AUTOINCREMENT, x TEXT);")
      rebuild = Path.join(dir, "0001_rebuild_things.sql")

      File.write!(rebuild, """
      CREATE TABLE things_new (id INTEGER PRIMARY KEY AUTOINCREMENT, x INTEGER);
      INSERT INTO things_new (id, x) SELECT id, x FROM things;
      DROP TABLE things;
      ALTER TABLE things_new RENAME TO things;
      """)

      assert ["0000_baseline"] = Release.migrate(db, [{"0000_baseline", base}])
      for x <- 1..3, do: sql(db, "INSERT INTO things (x) VALUES (#{x})")
      sql(db, "DELETE FROM things WHERE id = 3")
      files = [{"0000_baseline", base}, {"0001_rebuild_things", rebuild}]
      assert ["0001_rebuild_things"] = Release.migrate(db, files)
      sql(db, "INSERT INTO things (x) VALUES (4)")
      assert [[4]] = sql(db, "SELECT max(id) FROM things")
    end
  end

  # VACUUM INTO refuses to run inside a transaction, which the sandbox
  # always holds open; this test writes nothing, so the pool runs unboxed.
  @tag :tmp_dir
  test "a backup keeps its own newest 13 copies, clears a copy a stop cut short, and never touches v1's",
       %{tmp_dir: dir} do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    day = &"202609#{String.pad_leading("#{&1}", 2, "0")}T000000"
    v1 = for d <- 1..20, do: "hireme-#{day.(d)}.db"

    files =
      for(d <- 1..14, do: "hireme-v2-#{day.(d)}.db") ++ v1 ++ ["hireme-v2-#{day.(1)}.db.tmp"]

    for name <- files, do: File.write!(Path.join(dir, name), "")
    {:ok, pid} = Backup.start_link(name: :bench_backup, dir: dir, manual: true)
    assert {:ok, path} = Backup.run(pid)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
    names = File.ls!(dir)
    assert length(names -- v1) == 13 and v1 -- names == []
    refute Enum.any?(names, &String.ends_with?(&1, ".tmp"))
    refute "hireme-v2-#{day.(1)}.db" in names
    GenServer.stop(pid)
  end

  describe "the purge, on the node's database" do
    setup tags, do: DataCase.setup_sandbox(tags)

    test "activity rows expire after the retention; security events stay forever" do
      %{account: a} = DataCase.sign_in()
      now = Store.now()

      row = fn kind, days ->
        t = DateTime.add(now, -days * 86_400)
        %{account_id: a.id, kind: kind, rev: 1, inserted_at: t, updated_at: t}
      end

      kept = [row.("agent_ops", 1), row.("wire_key_refused", 1), row.("factor_added", 5 * 365)]

      expired =
        [row.("agent_ops", 91), row.("wire_key_refused", 8)] ++
          List.duplicate(row.("agent_ops", 100), 12_000)

      # Many expired rows go in batches, the writer free between them.
      for chunk <- Enum.chunk_every(kept ++ expired, 2_000),
          do: Repo.insert_all(Audit, chunk, skip_account: true)

      assert %{audit: 12_002} = Purge.run(now)
      kinds = Repo.with_account(a.id, fn -> Repo.all(Audit) |> Enum.map(& &1.kind) end)
      counts = Enum.frequencies(kinds)

      assert {counts["agent_ops"], counts["wire_key_refused"], counts["factor_added"]} ==
               {1, 1, 1}
    end

    test "the purge takes what ended a month ago and leaves what is live" do
      %{session: ended} = DataCase.sign_in()
      DataCase.sign_in()
      :ok = Hireme.Accounts.revoke_session(ended.account_id, ended.id)
      # Today nothing has been over long enough.
      assert %{sessions: 0} = Purge.run(Store.now())
      assert Repo.get(Session, ended.id, skip_account: true)
      # A month on, the revoked session goes.
      Purge.run(DateTime.add(Store.now(), 31 * 86_400))
      refute Repo.get(Session, ended.id, skip_account: true)
    end
  end
end
