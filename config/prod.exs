import Config

# `mix assets.deploy` writes the digest manifest before the server starts.
config :hireme, HiremeWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# HSTS and the https redirect; `force_ssl` is compile-time.
config :hireme, HiremeWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]

config :logger, level: :info

# Secrets and the database path are read at runtime in config/runtime.exs.
