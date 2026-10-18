# This run's own database (config/test.exs names it): the schema applied,
# the sandbox on, and the file gone when the suite ends.
database = Hireme.Repo.config()[:database]
Hireme.Release.migrate(database)
Ecto.Adapters.SQL.Sandbox.mode(Hireme.Repo, :manual)

ExUnit.after_suite(fn _ ->
  for suffix <- ["", "-wal", "-shm", ".migrate"], do: File.rm(database <> suffix)
end)

ExUnit.start()
