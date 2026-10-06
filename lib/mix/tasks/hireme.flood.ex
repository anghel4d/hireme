defmodule Mix.Tasks.Hireme.Flood do
  use Mix.Task

  @shortdoc "Insert N more applications into the SQLite desk"

  @moduledoc """
  Adds N generated applications on top of the seeded corpus.

      mix hireme.flood
      mix hireme.flood 5000

  Ids start above 20000, past the JobApp14413 showcase. The board paints
  a window of cards, so a few thousand stay responsive.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    n =
      case args do
        [raw] ->
          case Integer.parse(raw) do
            {n, ""} when n > 0 -> n
            _ -> raise "expected a positive integer, got #{raw}"
          end

        [] ->
          1000

        _ ->
          raise "usage: mix hireme.flood [N]"
      end

    inserted = Hireme.Seed.flood(n)
    Mix.shell().info("Inserted #{inserted} applications.")
  end
end
