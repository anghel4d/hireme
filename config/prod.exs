import Config

# `mix assets.deploy` writes the digest manifest before the release is built.
config :hireme, HiremeWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost", "127.0.0.1"]]]

config :logger, level: :info

# Secrets and the database path are read at runtime (config/runtime.exs).
