defmodule Hireme.ClosedSetsTest do
  @moduledoc """
  Every closed set at the edge admits each member by its atom or its exact
  name and refuses everything else: exhaustively over the members, then
  over a seeded stream of near misses (other sets' names, case and
  whitespace variants, numbers, nil, lists).
  """
  use ExUnit.Case, async: true

  @seed 2026_10_09

  defp parsers do
    [
      {"gym platform", &Hireme.Closed.parse(Hireme.Gym.platforms(), &1), Hireme.Gym.platforms()},
      {"gym topic", &Hireme.Closed.parse(Hireme.Gym.topics(), &1), Hireme.Gym.topics()},
      {"gym difficulty", &Hireme.Closed.parse(Hireme.Gym.difficulties(), &1),
       Hireme.Gym.difficulties()},
      {"gym outcome", &Hireme.Closed.parse(Hireme.Gym.outcomes(), &1), Hireme.Gym.outcomes()},
      {"net kind", &Hireme.Closed.parse(Hireme.Net.kinds(), &1), Hireme.Net.kinds()},
      {"net channel", &Hireme.Closed.parse(Hireme.Net.channels(), &1), Hireme.Net.channels()},
      {"stage", &Hireme.Pipeline.parse/1, Hireme.Pipeline.keys()},
      {"overlay mode", &Hireme.Desk.Overlay.parse_mode/1, [:hidden, :altered, :emphasized]}
    ]
  end

  test "each closed set admits its members by atom or name and nothing else" do
    :rand.seed(:exsss, {@seed, 1, 1})
    all_names = parsers() |> Enum.flat_map(fn {_, _, set} -> Enum.map(set, &Atom.to_string/1) end)

    for {label, parse, set} <- parsers() do
      for member <- set do
        assert parse.(member) == {:ok, member}, label
        assert parse.(Atom.to_string(member)) == {:ok, member}, label
      end

      for _ <- 1..300 do
        value = near_miss(set, all_names)

        expected =
          Enum.find_value(set, :error, fn m ->
            if value == m or value == Atom.to_string(m), do: {:ok, m}
          end)

        assert parse.(value) == expected, "#{label}: #{inspect(value)}"
      end
    end
  end

  # Values a form or a pack could carry: mostly names that are almost right.
  defp near_miss(set, all_names) do
    name = Enum.random(all_names)

    Enum.random([
      Enum.random(set),
      Enum.random(all_names),
      String.upcase(name),
      String.capitalize(name),
      " #{name}",
      "#{name} ",
      String.replace(name, "_", "-"),
      name <> "s",
      String.slice(name, 0..-2//1),
      String.to_atom(name <> "_x"),
      :"",
      "",
      nil,
      Enum.random(0..9),
      [name],
      %{name: name}
    ])
  end
end
