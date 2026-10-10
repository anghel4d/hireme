defmodule Hireme.PipelineTest do
  use ExUnit.Case, async: true

  alias Hireme.Pipeline
  alias Hireme.Pipeline.Rung

  test "a move marks earlier stages done and leaves the rest pending" do
    rail = Pipeline.initial(:discovered) |> Pipeline.move_to(:fire_ready)
    states = Enum.map(rail, & &1.state)

    assert states == [
             :done,
             :done,
             :done,
             :done,
             :done,
             :active,
             :pending,
             :pending,
             :pending,
             :pending
           ]

    assert %Rung{key: :fire_ready} = Pipeline.current(rail)
    assert Pipeline.encode(rail) == "DDDDDAPPPP"
  end

  test "skipped and blocked stages stay put unless they are the target" do
    rail =
      Pipeline.initial(:discovered)
      |> Enum.map(fn
        %Rung{key: :freshness} = rung -> %Rung{rung | state: :skipped}
        %Rung{key: :reply} = rung -> %Rung{rung | state: :blocked}
        rung -> rung
      end)
      |> Pipeline.move_to(:fire_ready)

    by_key = Map.new(rail, &{&1.key, &1.state})

    assert by_key.freshness == :skipped
    assert by_key.reply == :blocked
    assert by_key.fire_ready == :active
    assert by_key.draft_ready == :done
    assert by_key.open_fire == :pending
  end

  test "decode is the inverse of encode on every rail" do
    for start <- Pipeline.keys(), target <- Pipeline.keys() do
      rail = Pipeline.initial(start) |> Pipeline.move_to(target)
      assert {:ok, decoded} = Pipeline.decode(Pipeline.encode(rail))
      assert decoded == rail
    end

    rail =
      Pipeline.initial(:gated)
      |> Enum.map(fn
        %Rung{key: :freshness} = rung -> %Rung{rung | state: :skipped}
        %Rung{key: :closed} = rung -> %Rung{rung | state: :blocked}
        rung -> rung
      end)

    assert {:ok, ^rail} = Pipeline.decode(Pipeline.encode(rail))
  end

  test "any pip string decodes to a rail that encodes back, or not at all" do
    :rand.seed(:exsss, {2026, 10, 9})

    valid =
      for s <- Pipeline.keys(),
          t <- Pipeline.keys(),
          do: Pipeline.encode(Pipeline.move_to(Pipeline.initial(s), t))

    alphabet = String.graphemes("DAPSBXdap ")

    strings =
      for _ <- 1..2000 do
        case :rand.uniform(3) do
          1 -> Enum.map_join(1..:rand.uniform(12), "", fn _ -> Enum.random(alphabet) end)
          2 -> valid |> Enum.random() |> mutate(alphabet)
          3 -> Enum.random(["", " ", String.duplicate("D", 10), String.duplicate("A", 10)])
        end
      end

    decoded =
      for s <- strings, reduce: 0 do
        n ->
          case Pipeline.decode(s) do
            {:ok, rail} ->
              assert Pipeline.encode(rail) == s
              n + 1

            :error ->
              n
          end
      end

    assert decoded > 0
    for s <- valid, do: assert({:ok, _} = Pipeline.decode(s))
  end

  defp mutate(pips, alphabet) do
    i = :rand.uniform(String.length(pips)) - 1
    {head, tail} = String.split_at(pips, i)
    head <> Enum.random(alphabet) <> String.slice(tail, 1..-1//1)
  end
end
