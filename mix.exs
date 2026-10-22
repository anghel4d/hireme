# The schema compiler (schema/build.exs) generates the declaration's
# outputs before anything else compiles from them.
Code.require_file("schema/build.exs", __DIR__)

defmodule Hireme.MixProject do
  use Mix.Project

  def project do
    [
      app: :hireme,
      version: "0.2.0",
      elixir: "~> 1.20",
      compilers: [:schema | Mix.compilers()],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      releases: [hireme: []],
      dialyzer: [plt_add_apps: [:mix]],
      deps: deps()
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
      {:plug, "~> 1.20"},
      {:websock_adapter, "~> 0.6.0"},
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, "~> 0.25"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.13"},
      {:rustler, "~> 0.38", runtime: false},
      {:nimble_totp, "~> 1.0"},
      {:wax_, "~> 0.7.0"},
      {:hammer, "~> 7.5"},
      {:eqrcode, "~> 0.2.1"},
      {:swoosh, "~> 1.29"},
      {:assent, "~> 0.3.1"},
      {:req, "~> 0.7.5"},
      {:stream_data, "~> 1.4", only: :test},
      # The acceptance suite drives the node over a real /wire WebSocket.
      {:mint_web_socket, "~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # There is no ecto.migrate: a database is the generated baseline plus
  # additive files, applied by `Hireme.Release` at boot (and by the test
  # helper on each run's own database).
  # Build the kernel for wasm and copy it from wherever cargo put it (its
  # target dir may be moved by CARGO_TARGET_DIR or a cargo config), so the
  # page never gets a kernel.wasm left from another build.
  defp wasm(_) do
    manifest = ["--manifest-path", "native/Cargo.toml"]

    cargo = fn args ->
      case System.cmd("cargo", args ++ manifest, into: IO.stream(), stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, status} -> Mix.raise("cargo #{hd(args)} failed (exit #{status})")
      end
    end

    cargo.(
      ~w(rustc -p kernel --lib --release --target wasm32-unknown-unknown --crate-type cdylib)
    )

    {json, 0} = System.cmd("cargo", ["metadata", "--format-version", "1", "--no-deps" | manifest])

    built =
      Path.join(
        JSON.decode!(json)["target_directory"],
        "wasm32-unknown-unknown/release/kernel.wasm"
      )

    File.mkdir_p!("priv/static/wasm")
    File.cp!(built, "priv/static/wasm/kernel.wasm")
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      # The kernel as WebAssembly for the browser; Nix builds it for a release.
      "assets.wasm": &wasm/1,
      "assets.build": ["compile", "assets.wasm", "hireme.bundle"],
      "assets.deploy": ["hireme.bundle --minify", "hireme.digest"],
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
