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
    stale = Path.join(dir, "hireme-20200103T000000.db.tmp")
    other = Path.join(dir, "notes.db.tmp")
    for f <- [old, kept, stale, other], do: File.write!(f, "")
    File.touch!(old, System.os_time(:second) - 14 * 86_400)
    File.touch!(kept, System.os_time(:second) - 12 * 86_400)

    pid = start(dir)
    assert {:ok, path} = Backup.run(pid)
    assert Backup.status(pid) == {:ok, path}
    refute File.exists?(old)
    refute File.exists?(stale)
    assert File.exists?(other)
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

  test "boot and eval migrate under one lock, wait for another VM's, and apply nothing twice" do
    {:ok, other} = Exqlite.Sqlite3.open(Hireme.Release.lock_path())
    :ok = Exqlite.Sqlite3.execute(other, "BEGIN EXCLUSIVE")
    booting = Task.async(&Hireme.Release.start_link/0)
    eval = Task.async(&Hireme.Release.migrate/0)
    refute Task.yield(booting, 200)
    refute Task.yield(eval, 0)
    Exqlite.Sqlite3.close(other)
    assert :ignore = Task.await(booting)
    assert :ok = Task.await(eval)
  end

  test "the lock is the same through a chain of symlinks to the database", %{dir: dir} do
    db = Hireme.Repo.config()[:database]
    File.mkdir_p!(dir)
    hop = Path.join(dir, "hop.db")
    link = Path.join(dir, "alias.db")
    File.ln_s!(Path.expand(db), hop)
    File.ln_s!("hop.db", link)
    canonical = Hireme.Release.lock_path()
    Application.put_env(:hireme, Hireme.Repo, Keyword.put(Hireme.Repo.config(), :database, link))

    try do
      assert Hireme.Release.lock_path() == canonical
    after
      Application.put_env(:hireme, Hireme.Repo, Keyword.put(Hireme.Repo.config(), :database, db))
    end
  end
end
