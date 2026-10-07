defmodule Mix.Tasks.Hireme.Net do
  use Mix.Task

  @shortdoc "Print networking lane (Broadside Observer, posts, drafts)"

  @moduledoc """
  Not CRM. Prints shipped posts/artifacts this week, open drafts, and
  Observer runs. It does not submit jobs.

      mix hireme.net
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.shell().info(Hireme.Net.ascii(Hireme.Net.progress()))
  end
end
