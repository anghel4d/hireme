import Config

config :hireme, Hireme.Repo,
  database: Path.expand("../hireme_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

secret_key_base = "E+PE0bouCpNnm701s8LTvHah4Z9kfYWc6EKZ0O6GkKJ+6GhgKMv3TCh7aewMzzCC"
config :hireme, :secret_key_base, secret_key_base
config :wax_, origin: "http://localhost:4000"

gate_socket = Path.expand("../_build/gate.sock", __DIR__)
gate_hash = Path.expand("../_build/gate.hash", __DIR__)

gate_env = [
  {"GATE_LISTEN", "127.0.0.1:4433"},
  {"GATE_SOCKET", gate_socket},
  {"GATE_CERT_HASH_FILE", gate_hash},
  {"GATE_ORIGINS", "http://localhost:4000,http://127.0.0.1:4000"}
]

config :hireme, HiremeWeb.Gate,
  socket: gate_socket,
  url: "https://127.0.0.1:4433/wt",
  hash_file: gate_hash

# Loopback only; `ip: {0, 0, 0, 0}` opens the desk to the network.
config :hireme, HiremeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  url: [host: "localhost", port: 4000],
  check_origin: ["//localhost", "//127.0.0.1"],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: secret_key_base,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:hireme, ~w(--sourcemap=inline --watch)]},
    # The WebTransport gate on UDP 4433 with a fresh self-signed
    # certificate; the page passes its hash as `serverCertificateHashes`.
    gate:
      {System, :cmd,
       [
         System.find_executable("cargo") || Path.expand("~/.cargo/bin/cargo"),
         ~w(run --quiet --release --manifest-path native/gate/Cargo.toml),
         [
           env: gate_env,
           cd: Path.expand("..", __DIR__),
           into: IO.stream(),
           stderr_to_stdout: true
         ]
       ]}
  ]

config :hireme, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
