# Compile-time configuration shared by every environment; the
# environment's own file at the bottom overrides it.
import Config

# Set by the Nix build, which compiles the kernel NIF itself and puts it at
# priv/native/nif.so; everywhere else Rustler builds native/nif.
config :hireme, :nif_prebuilt, System.get_env("HIREME_NIF_PREBUILT") == "1"

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# WebAuthn relying party: the origin is set per environment.
config :wax_, rp_id: :auto, user_verification: "required"

# Mail: a local mailbox in development, Cloudflare Email Sending in production.
config :hireme, Hireme.Mail, adapter: Swoosh.Adapters.Local
config :hireme, :mail_from, {"Hireme", "hireme@localhost"}
config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
