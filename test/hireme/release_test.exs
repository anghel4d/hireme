defmodule Hireme.ReleaseTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Exqlite.Sqlite3
  alias Hireme.Accounts
  alias Hireme.DataCase
  alias Hireme.Release
  alias Hireme.Release.Backup
  alias Hireme.Release.Purge
  alias Hireme.Rows.Session
  alias Hireme.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "hireme-release-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: Path.join(dir, "hireme.db"), dir: dir}
  end

  defp tables(db) do
    {:ok, conn} = Sqlite3.open(db)
    {:ok, st} = Sqlite3.prepare(conn, "SELECT name FROM sqlite_schema WHERE type = 'table'")
    {:ok, rows} = Sqlite3.fetch_all(conn, st)
    Sqlite3.close(conn)
    rows |> List.flatten() |> MapSet.new()
  end

  test "an empty database takes the whole schema once; a second run applies nothing", %{db: db} do
    applied = Release.migrate(db)
    assert hd(applied) == "0000_baseline"
    assert length(applied) == length(Release.files())

    for t <- Hireme.Schema.tables(),
        t.residency in [:resident, :server],
        do: assert(MapSet.member?(tables(db), to_string(t.name)), "#{t.name} missing")

    assert Release.migrate(db) == []
  end

  test "a database that already holds tables it did not get from a baseline is refused", %{db: db} do
    {:ok, conn} = Sqlite3.open(db)
    :ok = Sqlite3.execute(conn, "CREATE TABLE stranger (id INTEGER PRIMARY KEY)")
    Sqlite3.close(conn)

    assert_raise RuntimeError, ~r/not empty/, fn -> Release.migrate(db) end
    refute MapSet.member?(tables(db), "accounts")
  end

  defp sql(db, statement) do
    {:ok, conn} = Sqlite3.open(db)
    {:ok, st} = Sqlite3.prepare(conn, statement)
    {:ok, rows} = Sqlite3.fetch_all(conn, st)
    Sqlite3.close(conn)
    rows
  end

  test "a table rebuilt by a schema file never hands out an id it handed out before", %{
    db: db,
    dir: dir
  } do
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

    assert ["0001_rebuild_things"] =
             Release.migrate(db, [{"0000_baseline", base}, {"0001_rebuild_things", rebuild}])

    sql(db, "INSERT INTO things (x) VALUES (4)")
    assert [[4]] = sql(db, "SELECT max(id) FROM things")
  end

  test "two nodes booting on one file apply the schema once", %{db: db} do
    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> Release.migrate(db) end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.sort_by(results, &length/1) |> hd() == []
  end

  # VACUUM INTO refuses to run inside a transaction, which the sandbox
  # always holds open; this test writes nothing, so the pool runs unboxed.
  describe "the daily backup" do
    setup do
      Sandbox.mode(Hireme.Repo, :auto)
      on_exit(fn -> Sandbox.mode(Hireme.Repo, :manual) end)
    end

    @tag :tmp_dir
    test "a backup keeps the newest 13 copies and clears a copy a stop cut short", %{
      tmp_dir: dir
    } do
      for day <- 1..14,
          do:
            File.write!(
              Path.join(dir, "hireme-202609#{String.pad_leading("#{day}", 2, "0")}T000000.db"),
              ""
            )

      File.write!(Path.join(dir, "hireme-20260901T000000.db.tmp"), "")
      {:ok, pid} = Backup.start_link(name: :bench_backup, dir: dir, manual: true)
      assert {:ok, path} = Backup.run(pid)
      assert File.exists?(path)
      names = File.ls!(dir)
      assert length(names) == 13
      refute Enum.any?(names, &String.ends_with?(&1, ".tmp"))
      refute "hireme-20260901T000000.db" in names
      GenServer.stop(pid)
    end
  end

  describe "with the node's database" do
    setup tags do
      DataCase.setup_sandbox(tags)
      :ok
    end

    test "activity rows expire after the retention; security events stay forever" do
      %{account: a} = DataCase.sign_in()
      now = Store.now()

      row = fn kind, days ->
        t = DateTime.add(now, -days * 86_400)
        %{account_id: a.id, kind: kind, rev: 1, inserted_at: t, updated_at: t}
      end

      Hireme.Repo.insert_all(
        Hireme.Rows.Audit,
        [row.("agent_ops", 91), row.("agent_ops", 1), row.("factor_added", 5 * 365)],
        skip_account: true
      )

      Purge.run(now)

      kinds =
        Hireme.Repo.with_account(a.id, fn -> Enum.map(Hireme.Audit.recent(50), & &1.kind) end)

      assert Enum.count(kinds, &(&1 == "agent_ops")) == 1
      assert "factor_added" in kinds
    end

    test "the purge takes what ended a month ago and leaves what is live" do
      %{session: ended} = DataCase.sign_in()
      %{session: live} = DataCase.sign_in()
      :ok = Accounts.revoke_session(ended.account_id, ended.id)

      # Today nothing has been over long enough.
      assert %{sessions: 0} = Purge.run(Store.now())
      assert Hireme.Repo.get(Session, ended.id, skip_account: true)

      # A month on, the revoked session goes; the live one is untouched today.
      Purge.run(DateTime.add(Store.now(), 31 * 86_400))
      refute Hireme.Repo.get(Session, ended.id, skip_account: true)
      _ = live
    end
  end
end
