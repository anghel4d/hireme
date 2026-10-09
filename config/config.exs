# Compile-time configuration shared by every environment. The
# environment file at the bottom overrides it.
import Config

config :hireme,
  ecto_repos: [Hireme.Repo],
  generators: [timestamp_type: :utc_datetime]

config :hireme, HiremeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: HiremeWeb.ErrorHTML, json: HiremeWeb.ErrorJSON], layout: false],
  pubsub_server: Hireme.PubSub

config :esbuild,
  version: "0.25.4",
  hireme: [
    args:
      ~w(js/app.ts js/factor.ts --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Sign-in tokens, factor codes, OAuth state, and addresses never reach the log.
config :phoenix, :filter_parameters, ["password", "secret", "token", "code", "state", "email"]

# WebAuthn relying party: the origin the browser reports. Set per environment.
config :wax_, rp_id: :auto, user_verification: "required"

# Mail: a local mailbox in development; Cloudflare HTTPS in production.
config :hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Local
config :hireme, :mail_from, {"Hireme", "hireme@localhost"}
config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
