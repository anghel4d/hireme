defmodule Hireme.ReleaseTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias Hireme.Release

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
      Ecto.Adapters.SQL.Sandbox.mode(Hireme.Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Hireme.Repo, :manual) end)
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
      {:ok, pid} = Hireme.Release.Backup.start_link(name: :bench_backup, dir: dir, manual: true)
      assert {:ok, path} = Hireme.Release.Backup.run(pid)
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
      Hireme.DataCase.setup_sandbox(tags)
      :ok
    end

    test "the purge takes what ended a month ago and leaves what is live" do
      %{session: ended} = Hireme.DataCase.sign_in()
      %{session: live} = Hireme.DataCase.sign_in()
      :ok = Hireme.Accounts.revoke_session(ended.account_id, ended.id)

      # Today nothing has been over long enough.
      assert %{sessions: 0} = Hireme.Release.Purge.run(Hireme.Store.now())
      assert Hireme.Repo.get(Hireme.Rows.Session, ended.id, skip_account: true)

      # A month on, the revoked session goes; the live one is untouched today.
      Hireme.Release.Purge.run(DateTime.add(Hireme.Store.now(), 31 * 86_400))
      refute Hireme.Repo.get(Hireme.Rows.Session, ended.id, skip_account: true)
      _ = live
    end
  end
end
