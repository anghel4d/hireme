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

  test "submit rungs are the ones FIRE HOLD locks" do
    assert Pipeline.fire_locked?(:submitted)
    assert Pipeline.fire_locked?(:open_fire)
    refute Pipeline.fire_locked?(:fire_ready)
  end

  test "a stage name parses to the one stage and nothing else parses" do
    assert {:ok, :in_batch} = Pipeline.parse("in_batch")
    assert {:ok, :in_batch} = Pipeline.parse(:in_batch)
    assert :error = Pipeline.parse("in-batch")
    assert :error = Pipeline.parse(nil)
    assert :error = Pipeline.parse(:anything)

    for key <- Pipeline.keys() do
      assert {:ok, ^key} = Pipeline.parse(Pipeline.name(key))
    end
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

  test "a pip string of the wrong length or alphabet does not decode" do
    assert :error = Pipeline.decode("APPPPPPP")
    assert :error = Pipeline.decode("DDDDDAPPPX")
    assert :error = Pipeline.decode("")
  end
end
