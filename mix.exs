defmodule Hireme.MixProject do
  use Mix.Project

  def project do
    [
      app: :hireme,
      version: "0.2.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      releases: [hireme: []],
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [mod: {Hireme.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.8"},
      {:rustler, "~> 0.37", runtime: false},
      {:nimble_totp, "~> 1.0"},
      {:wax_, "~> 0.7.0"},
      {:hammer, "~> 7.1"},
      {:eqrcode, "~> 0.2.1"},
      {:swoosh, "~> 1.19"},
      {:assent, "~> 0.3"},
      {:req, "~> 0.5"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:stream_data, "~> 1.2", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # There is no ecto.migrate: a database is the generated baseline plus
  # additive files, applied by `Hireme.Release` at boot (and by the test
  # helper on each run's own database).
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      # The kernel as WebAssembly for the browser; Nix builds it for a release.
      "assets.wasm": [
        "cmd cargo build --manifest-path native/Cargo.toml -p kernel --lib --release --target wasm32-unknown-unknown",
        "cmd mkdir -p priv/static/wasm",
        "cmd cp native/target/wasm32-unknown-unknown/release/kernel.wasm priv/static/wasm/kernel.wasm"
      ],
      "assets.build": ["compile", "assets.wasm", "esbuild app", "esbuild early", "esbuild auth"],
      "assets.deploy": [
        "esbuild app --minify",
        "esbuild early",
        "esbuild auth --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "hireme.schema --check",
        "test"
      ]
    ]
  end
end
