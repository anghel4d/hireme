import Config

config :hireme, Hireme.Repo,
  database: Path.expand("../hireme_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

secret_key_base = "E+PE0bouCpNnm701s8LTvHah4Z9kfYWc6EKZ0O6GkKJ+6GhgKMv3TCh7aewMzzCC"
config :hireme, :secret_key_base, secret_key_base
config :wax_, origin: "http://localhost:4000"

# Loopback only; `ip: {0, 0, 0, 0}` opens the desk to the network.
config :hireme, HiremeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  url: [host: "localhost", port: 4000],
  check_origin: ["//localhost", "//127.0.0.1"],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:hireme, ~w(--sourcemap=inline --watch)]}
  ]

config :hireme, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
