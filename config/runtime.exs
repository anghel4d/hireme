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
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        ~r"lib/hireme_web/router\.ex$",
        ~r"lib/hireme_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
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
  config :hireme, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # IPv6 on every interface; `{0, 0, 0, 0, 0, 0, 0, 1}` is local only.
  config :hireme, HiremeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base
end
