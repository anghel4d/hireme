import Config

# `MIX_TEST_PARTITION` is honoured by `mix test`; see `mix help test`.
config :hireme, Hireme.Repo,
  database: Path.expand("../hireme_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

secret_key_base = "XPx6qxoX/XRLHmiBlX6yrohT6bBZTJZai2UgJToxXZi4n0/9/jDw2FClsguZET3W"
config :hireme, :secret_key_base, secret_key_base
config :wax_, origin: "http://www.example.com"

config :hireme, HiremeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: secret_key_base,
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix, sort_verified_routes_query_params: true
