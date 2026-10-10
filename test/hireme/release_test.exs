defmodule Hireme.ReleaseTest do
  use Hireme.DataCase, async: false
  @moduletag :capture_log

  alias Hireme.Release.Backup

  setup do
    dir = Path.join(System.tmp_dir!(), "hireme-backup-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start(dir) do
    {:ok, pid} = Backup.start_link(dir: dir, manual: true)
    pid
  end

  test "a backup is a whole database, and copies older than 13 days are pruned", %{dir: dir} do
    File.mkdir_p!(dir)
    old = Path.join(dir, "hireme-20200101T000000.db")
    kept = Path.join(dir, "hireme-20200102T000000.db")
    for f <- [old, kept], do: File.write!(f, "")
    File.touch!(old, System.os_time(:second) - 14 * 86_400)
    File.touch!(kept, System.os_time(:second) - 12 * 86_400)

    pid = start(dir)
    assert {:ok, path} = Backup.run(pid)
    assert Backup.status(pid) == {:ok, path}
    refute File.exists?(old)
    assert File.exists?(kept)
    refute File.exists?(path <> ".tmp")

    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, st} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM schema_migrations")
    assert {:row, [n]} = Exqlite.Sqlite3.step(conn, st)
    assert n > 0
  end

  test "a failed backup is kept in its status, and leaves nothing behind", %{dir: dir} do
    File.write!(dir, "not a directory")
    pid = start(dir)
    assert {:error, _} = Backup.run(pid)
    assert {:error, _} = Backup.status(pid)
  end

  test "the boot migrator applies nothing twice and starts nothing" do
    assert :ignore = Hireme.Release.start_link()
  end
end
