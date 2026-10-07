defmodule Mix.Tasks.Hireme.Score do
  use Mix.Task

  @shortdoc "Print the Life-EV score_100 histogram for the desk"

  @moduledoc """
  Standing order: every job has score_100. This prints the band
  breakdown and histogram. It does not submit.

      mix hireme.score
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    cards = Hireme.Desk.list_cards(%Hireme.Desk.Filters{status: :all})
    chart = Hireme.LifeEv.chart(cards)
    Mix.shell().info(Hireme.LifeEv.ascii(chart))
  end
end
