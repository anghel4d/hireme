# Compile-time configuration shared by every environment; the
# environment's own file at the bottom overrides it.
import Config

config :hireme, HiremeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: HiremeWeb.ErrorHTML, json: HiremeWeb.ErrorJSON], layout: false],
  pubsub_server: Hireme.PubSub

# The browser's three bundles and its stylesheet. `early` is inlined in
# <head> and allowed by its hash in the CSP; `auth` is the factor page's
# passkey script.
config :esbuild,
  version: "0.28.2",
  # The Nix build points this at its own esbuild; elsewhere the Mix task
  # installs this version.
  path: System.get_env("MIX_ESBUILD_PATH"),
  app: [
    args:
      ~w(js/app.ts css/app.css --bundle --format=esm --target=es2022 --outdir=../priv/static/assets --entry-names=[name] --external:/wasm/*),
    cd: Path.expand("../assets", __DIR__)
  ],
  early: [
    args:
      ~w(js/early.ts --bundle --format=iife --minify --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__)
  ],
  auth: [
    args:
      ~w(js/auth/factor.ts --bundle --format=esm --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__)
  ]

# Set by the Nix build, which compiles the kernel NIF itself and puts it at
# priv/native/nif.so; everywhere else Rustler builds native/nif.
config :hireme, :nif_prebuilt, System.get_env("HIREME_NIF_PREBUILT") == "1"

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
# `phx.digest` gzips these, and Plug.Static serves the .gz to a browser
# that accepts it; kernel.wasm compresses to about a third.
config :phoenix, :gzippable_exts, ~w(.js .map .css .txt .text .html .json .svg .eot .ttf .wasm)
config :phoenix, :format_encoders, html: HiremeWeb.ErrorHTML

# Sign-in tokens, factor codes, OAuth state, keys and addresses never reach the log.
config :phoenix, :filter_parameters, ~w(password secret token ticket code state email key)

# WebAuthn relying party: the origin is set per environment.
config :wax_, rp_id: :auto, user_verification: "required"

# Mail: a local mailbox in development, Cloudflare Email Sending in production.
config :hireme, Hireme.Mail, adapter: Swoosh.Adapters.Local
config :hireme, :mail_from, {"Hireme", "hireme@localhost"}
config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
