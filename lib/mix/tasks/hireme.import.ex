defmodule Mix.Tasks.Hireme.Import do
  use Mix.Task

  @shortdoc "Import a DESERT STORM pack (JSON, CSV-less markdown table, or freshness note)"

  @moduledoc """
  Idempotent import by canonical job URL.

      mix hireme.import priv/desert_storm/sample/batch-001.json
      mix hireme.import red/ats-maps/batch001.json
      mix hireme.import red/leftover-pursue.md
      mix hireme.import red/universe-gaps-batch1-freshness.md

  The Matei profile must already exist (`mix ecto.setup`). Re-importing a
  URL updates that card. FIRE HOLD still blocks `submitted` and `open_fire`
  until the batch is named.

  The ATS password is not a flag and is not read.
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
