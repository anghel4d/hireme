import Config

# Every `mix test` run gets a database of its own, so several runs in one
# tree never share a file or a lock. The helper applies the baseline to it
# and deletes it when the suite ends.
config :hireme, Hireme.Repo,
  database:
    Path.join(
      System.tmp_dir!(),
      "hireme-test-#{System.pid()}-#{System.unique_integer([:positive])}.db"
    ),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

secret_key_base = "test+only+Qm2vX8kR1nB5tY7wE3uI9oP0aS4dF6gH2jK8lZ1xC5vB7nM3qW9eR0tY"
config :hireme, :secret_key_base, secret_key_base
config :wax_, origin: "http://www.example.com"
config :hireme, Hireme.Mail, adapter: Swoosh.Adapters.Test

config :hireme, HiremeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: secret_key_base,
  server: false

# Tests drain the outbox themselves; no worker sends behind their back.
config :hireme, :mail_outbox, false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
