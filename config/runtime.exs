# Runtime configuration, read in every environment including releases.
# Nothing compile-time belongs here.
import Config

# `PHX_SERVER=true bin/hireme start` serves from a release.
if System.get_env("PHX_SERVER") do
  config :hireme, HiremeWeb.Endpoint, server: true
end

config :hireme, HiremeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  config :hireme, HiremeWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/.*\.(js|css|wasm|png|svg)$",
        ~r"lib/hireme_web/.*\.ex$"
      ]
    ]
end

# Sign-in providers. A provider with no client id is not offered.
config :hireme, :oauth,
  github: [
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")
  ],
  x: [
    client_id: System.get_env("X_CLIENT_ID"),
    client_secret: System.get_env("X_CLIENT_SECRET")
  ]

if from = System.get_env("MAIL_FROM") do
  config :hireme, :mail_from, {"Hireme", from}
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/hireme/hireme.db
      """

  config :hireme, Hireme.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # Signs cookies and other secrets; generate one with `mix phx.gen.secret`.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :hireme, :secret_key_base, secret_key_base
  config :wax_, origin: "https://#{host}"

  # HTTPS avoids Hetzner's outbound SMTP port restrictions.
  config :swoosh, local: false

  config :hireme, Hireme.Mailer,
    adapter: Hireme.CloudflareMail,
    account_id: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID"),
    api_token: System.fetch_env!("CLOUDFLARE_EMAIL_TOKEN")

  # The WebTransport gate (native/gate, GATE_BIN) runs as this node's
  # Port, reads its other GATE_* settings from the environment it inherits,
  # and reaches the node through a Unix socket; the page learns its public
  # URL from GATE_URL. All are host configuration, never committed. Without
  # them the desk runs over the WebSocket fallback alone.
  if gate_socket = System.get_env("GATE_SOCKET") do
    config :hireme, HiremeWeb.Gate,
      socket: gate_socket,
      url: System.fetch_env!("GATE_URL"),
      cmd: List.wrap(System.get_env("GATE_BIN")),
      # Set only when the gate signs its own certificate (the dev profile).
      hash_file: System.get_env("GATE_CERT_HASH_FILE")
  end

  # The public HTTPS endpoint is served by the reverse proxy, not this socket.
  {:ok, listen_ip} =
    System.get_env("PHX_IP", "127.0.0.1")
    |> String.to_charlist()
    |> :inet.parse_address()

  config :hireme, HiremeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: listen_ip],
    secret_key_base: secret_key_base
end
