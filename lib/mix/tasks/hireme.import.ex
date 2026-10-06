defmodule Mix.Tasks.Hireme.Import do
  use Mix.Task

  @shortdoc "Import a pack (JSON, markdown table, or freshness note)"

  @moduledoc """
  Idempotent import by canonical job URL.

      mix hireme.import seed/batch-001.json
      mix hireme.import seed/leftover-pursue.md

  A profile must already exist (`mix ecto.setup` with a `seed/` directory).
  Re-importing a URL updates that card. Hold still blocks `submitted` and
  `open_fire` until the batch is named.

  Passwords are not read.
  """

  @impl Mix.Task
  def run([path]) do
    Mix.Task.run("app.start")

    case Hireme.Import.import_path(path) do
      {:ok, %{kind: kind, count: count}} ->
        Mix.shell().info("Imported #{kind}: #{count}")

      {:error, reason} ->
        Mix.raise("import failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix hireme.import PATH")
end
