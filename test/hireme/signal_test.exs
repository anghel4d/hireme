defmodule Hireme.SignalTest do
  use ExUnit.Case, async: true

  alias Hireme.Desk.Signal

  test "a signal names its application and serialises without nil fields" do
    signal = Signal.stage(7, :gated)
    assert Signal.about?(signal, 7)
    refute Signal.about?(signal, 8)
    refute Signal.about?(Signal.open_fire("Batch-001"), 7)

    assert Signal.to_json(signal) == %{"type" => "stage", "job_id" => 7, "stage" => "gated"}

    assert Signal.to_json(Signal.open_fire("Batch-001")) ==
             %{"type" => "open_fire", "batch" => "Batch-001"}
  end
end
