defmodule Mix.Tasks.Hireme.Gym do
  use Mix.Task

  @shortdoc "Print gym conditioning progress (streak, daily target, topics)"

  @moduledoc """
  Jumping jacks for the fight. Prints today's reps against the daily
  target, the streak, and topic counts. It does not submit jobs.

      mix hireme.gym
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Mix.shell().info(Hireme.Gym.ascii(Hireme.Gym.progress()))
  end
end
