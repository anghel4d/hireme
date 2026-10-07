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

defmodule Mix.Tasks.Hireme.Score do
  use Mix.Task

  @shortdoc "Print the Life-EV score_100 histogram for the desk"
  @moduledoc "Standing order: every job has score_100. Prints the band breakdown and histogram."

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Hireme.Accounts.use_default!()
    cards = Hireme.Desk.list_cards(%Hireme.Desk.Filters{status: :all})
    Mix.shell().info(Hireme.LifeEv.ascii(Hireme.LifeEv.chart(cards)))
  end
end

defmodule Mix.Tasks.Hireme.Heat do
  use Mix.Task

  @shortdoc "Print company and ATS heat vs cap (does not submit)"
  @moduledoc "Structural heat: company load vs cap and ATS vendor load vs cap. The governor gates the queue."

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Hireme.Accounts.use_default!()
    Mix.shell().info(Hireme.Heat.ascii(Hireme.Heat.chart()))
  end
end

defmodule Mix.Tasks.Hireme.Gym do
  use Mix.Task

  @shortdoc "Print gym conditioning progress (streak, daily target, topics)"
  @moduledoc "Jumping jacks for the fight: today's reps against the target, the streak, topic counts."

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Hireme.Accounts.use_default!()
    Mix.shell().info(Hireme.Gym.ascii(Hireme.Gym.progress()))
  end
end

defmodule Mix.Tasks.Hireme.Net do
  use Mix.Task

  @shortdoc "Print networking lane (Broadside Observer, posts, drafts)"
  @moduledoc "Not CRM: shipped posts and artifacts this week, open drafts, Observer runs."

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Hireme.Accounts.use_default!()
    Mix.shell().info(Hireme.Net.ascii(Hireme.Net.progress()))
  end
end
