import Config

config :hireme, Hireme.Repo,
  database: Path.expand("../hireme_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

secret_key_base = "dev+only+K1e8mZ3wq0Yf9n2sJvT6cR4hXbLpA7uDgE5iNoQyWtSz0aMkCjVxB3lPr"
config :hireme, :secret_key_base, secret_key_base
config :wax_, origin: "http://localhost:4000"

# The WebTransport gate on UDP 4433, run by the node as a Port with a
# fresh self-signed certificate each start; the page passes its hash.
config :hireme, HiremeWeb.Gate,
  socket: Path.expand("../_build/gate.sock", __DIR__),
  url: "https://127.0.0.1:4433/wt",
  hash_file: Path.expand("../_build/gate.hash", __DIR__),
  cmd: ~w(cargo run --quiet --release --manifest-path native/Cargo.toml -p gate),
  env: [{"GATE_ORIGINS", "http://localhost:4000,http://127.0.0.1:4000"}]

# Loopback only; `ip: {0, 0, 0, 0}` opens the desk to the network.
config :hireme, HiremeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  url: [host: "localhost", port: 4000],
  check_origin: ["//localhost", "//127.0.0.1"],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [bun: {Mix.Tasks.Hireme.Bundle, :run, [~w(--sourcemap=inline --watch)]}],
  live_reload: [
    web_console_logger: true,
    patterns: [~r"priv/static/.*\.(js|css|wasm)$", ~r"lib/hireme_web/.*\.ex$"]
  ]

config :hireme, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
