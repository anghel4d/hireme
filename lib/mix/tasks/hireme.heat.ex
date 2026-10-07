defmodule Mix.Tasks.Hireme.Heat do
  use Mix.Task

  @shortdoc "Print company and ATS heat vs cap (does not submit)"

  @moduledoc """
  Structural heat. Prints company load vs cap and ATS vendor load vs
  cap. The governor gates the queue. It does not submit.

      mix hireme.heat
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.shell().info(Hireme.Heat.ascii(Hireme.Heat.chart()))
  end
end
