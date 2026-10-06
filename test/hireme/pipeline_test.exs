defmodule Hireme.PipelineTest do
  use ExUnit.Case, async: true

  alias Hireme.Pipeline

  test "a move marks earlier stages done and leaves the rest pending" do
    stages = Pipeline.initial("discovered") |> Pipeline.move_to("fire_ready")
    states = Enum.map(stages, & &1.state)

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

    assert Pipeline.current(stages).key == "fire_ready"
    assert Pipeline.encode(stages) == "DDDDDAPPPP"
  end

  test "skipped and blocked stages stay put unless they are the target" do
    stages =
      Pipeline.initial("discovered")
      |> Enum.map(fn stage ->
        cond do
          stage.key == "freshness" -> %{stage | state: :skipped}
          stage.key == "reply" -> %{stage | state: :blocked}
          true -> stage
        end
      end)
      |> Pipeline.move_to("fire_ready")

    by_key = Map.new(stages, &{&1.key, &1.state})

    assert by_key["freshness"] == :skipped
    assert by_key["reply"] == :blocked
    assert by_key["fire_ready"] == :active
    assert by_key["draft_ready"] == :done
    assert by_key["open_fire"] == :pending
  end

  test "submit rungs are the ones FIRE HOLD locks" do
    assert Pipeline.fire_locked?("submitted")
    assert Pipeline.fire_locked?("open_fire")
    refute Pipeline.fire_locked?("fire_ready")
  end
end
