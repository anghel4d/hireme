# Read at boot in every environment, releases included. Nothing
# compile-time belongs here.
import Config

if System.get_env("PHX_SERVER"), do: config(:hireme, HiremeWeb.Endpoint, server: true)

config :hireme, HiremeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Sign-in providers. A provider without a client id and secret is not offered.
config :hireme, :oauth,
  github: [
    client_id: System.get_env("GITHUB_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_CLIENT_SECRET")
  ],
  x: [client_id: System.get_env("X_CLIENT_ID"), client_secret: System.get_env("X_CLIENT_SECRET")]

if from = System.get_env("MAIL_FROM"), do: config(:hireme, :mail_from, {"Hireme", from})

if config_env() == :prod do
  database =
    System.get_env("DATABASE_PATH") ||
      raise "DATABASE_PATH is missing, for example /var/lib/hireme/hireme.db"

  config :hireme, Hireme.Repo,
    database: database,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing; generate one with `mix phx.gen.secret`"

  host = System.get_env("PHX_HOST") || raise "PHX_HOST is missing"

  config :hireme, :secret_key_base, secret_key_base
  config :wax_, origin: "https://#{host}"

  # HTTPS delivery: Hetzner restricts outbound SMTP.
  config :swoosh, local: false

  config :hireme, Hireme.Mail,
    adapter: Hireme.Mail.Cloudflare,
    account_id: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID"),
    api_token: System.fetch_env!("CLOUDFLARE_EMAIL_TOKEN")

  # The gate (GATE_BIN) runs as this node's Port and reads its other
  # GATE_* settings from the environment. Without it the wire runs over
  # the WebSocket carrier alone.
  if socket = System.get_env("GATE_SOCKET") do
    config :hireme, HiremeWeb.Gate,
      socket: socket,
      url: System.fetch_env!("GATE_URL"),
      cmd: List.wrap(System.get_env("GATE_BIN")),
      hash_file: System.get_env("GATE_CERT_HASH_FILE")
  end

  # The public HTTPS endpoint is the reverse proxy, not this socket.
  {:ok, ip} =
    System.get_env("PHX_IP", "127.0.0.1") |> String.to_charlist() |> :inet.parse_address()

  config :hireme, HiremeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: ip],
    secret_key_base: secret_key_base
end
