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

config :hireme,
       :secret_key_base,
       "test+only+Qm2vX8kR1nB5tY7wE3uI9oP0aS4dF6gH2jK8lZ1xC5vB7nM3qW9eR0tY"

config :wax_, origin: "http://www.example.com"
config :hireme, Hireme.Mail, adapter: Swoosh.Adapters.Test

config :hireme, HiremeWeb.Endpoint, http: [ip: {127, 0, 0, 1}]

# Tests drain the outbox themselves; no worker sends behind their back.
config :hireme, :mail_outbox, false

config :logger, level: :warning

# A machine without a CA store at the paths OTP walks (the Nix sandbox):
# the bundle OTP's loader takes instead, for httpc and the connector's
# :system cacerts.
if path = System.get_env("HIREME_CACERTS"),
  do: config(:public_key, cacerts_path: String.to_charlist(path))
