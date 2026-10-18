defmodule Hireme.ReleaseTest do
  use ExUnit.Case, async: true

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
    :ok = Sqlite3.execute(conn, "CREATE TABLE job_apps (id INTEGER PRIMARY KEY)")
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
end
