import Config

config :hireme, Hireme.Repo,
  database: Path.expand("../hireme_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :hireme,
       :secret_key_base,
       "dev+only+K1e8mZ3wq0Yf9n2sJvT6cR4hXbLpA7uDgE5iNoQyWtSz0aMkCjVxB3lPr"

config :wax_, origin: "http://localhost:4000"

# Loopback only; `ip: {0, 0, 0, 0}` opens the desk to the network.
config :hireme, HiremeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  url: [host: "localhost", port: 4000],
  check_origin: ["//localhost", "//127.0.0.1"]

config :hireme, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"
