defmodule Hireme.PipelineTest do
  use ExUnit.Case, async: true

  alias Hireme.Pipeline

  test "a move marks earlier stages done and leaves the rest pending" do
    stages = Pipeline.initial("recon") |> Pipeline.move_to("screen")
    states = Enum.map(stages, & &1.state)

    assert states == [:done, :done, :done, :done, :active, :pending, :pending, :pending]
    assert Pipeline.current(stages).key == "screen"
    assert Pipeline.encode(stages) == "DDDDAPPP"
  end

  test "skipped and blocked stages stay put unless they are the target" do
    stages =
      Pipeline.initial("recon")
      |> Enum.map(fn stage ->
        cond do
          stage.key == "fit" -> %{stage | state: :skipped}
          stage.key == "offer" -> %{stage | state: :blocked}
          true -> stage
        end
      end)
      |> Pipeline.move_to("screen")

    by_key = Map.new(stages, &{&1.key, &1.state})

    assert by_key["fit"] == :skipped
    assert by_key["offer"] == :blocked
    assert by_key["screen"] == :active
    assert by_key["tailor"] == :done
    assert by_key["loop"] == :pending
  end
end
