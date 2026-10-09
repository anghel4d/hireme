# `mix hireme.*`: the desk from a shell. Every task starts the app and
# prints a reading or imports a pack. None of them submits.

defmodule Mix.Tasks.Hireme.Import do
  use Mix.Task

  @shortdoc "Import a pack (JSON, markdown table, or freshness note)"

  @moduledoc """
  Idempotent import by canonical job URL.

      mix hireme.import seed/batch-001.json
      mix hireme.import seed/leftover-pursue.md

  A profile must already exist (`mix ecto.setup` with a `seed/` directory).
  Re-importing a URL updates that card. Hold still blocks `submitted` and
  `open_fire` until the batch is named. Passwords are not read.
  """

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")
    Hireme.Accounts.use_default!()

    case Hireme.Import.import_path(path) do
      {:ok, %{kind: kind, count: count}} -> Mix.shell().info("Imported #{kind}: #{count}")
      {:error, reason} -> Mix.raise("import failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix hireme.import PATH")
end

defmodule Mix.Tasks.Hireme.Flood do
  use Mix.Task

  @shortdoc "Insert N more applications into the SQLite desk"

  @moduledoc """
  Adds N generated applications on top of the seeded corpus. Ids start
  above 20000, past the JobApp14413 showcase.

      mix hireme.flood
      mix hireme.flood 5000
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    Hireme.Accounts.use_default!()

    n =
      case args do
        [] ->
          1000

        [raw] ->
          case Integer.parse(raw) do
            {n, ""} when n > 0 -> n
            _ -> Mix.raise("expected a positive integer, got #{raw}")
          end

        _ ->
          Mix.raise("usage: mix hireme.flood [N]")
      end

    Mix.shell().info("Inserted #{Hireme.Seed.flood(n)} applications.")
  end
end
