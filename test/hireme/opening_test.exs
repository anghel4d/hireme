defmodule Hireme.OpeningTest do
  use ExUnit.Case, async: true

  alias Hireme.Desk.Opening
  alias Hireme.Desk.Signal
  alias Hireme.Theme

  test "an opening parses wire strings once" do
    assert {:ok, opening} =
             Opening.new(%{
               profile_id: 1,
               company: "Co",
               role: "Engineer",
               stage: "fire_ready",
               freshness: "open",
               gate: :pursue,
               theme: %{"targets" => ["ecs"]},
               overlays: [%{item_id: 4, mode: "hidden", reason: "noise"}]
             })

    assert opening.stage == :fire_ready
    assert opening.freshness == :open
    assert opening.gate == :pursue
    assert opening.theme == %Theme{targets: ["ecs"]}

    assert [%{item_id: 4, mode: :hidden, reason: "noise", title: nil, body: nil}] =
             opening.overlays
  end

  test "an opening refuses what it cannot represent" do
    base = %{profile_id: 1, company: "Co", role: "Engineer"}

    assert {:error, {:missing, :company}} = Opening.new(Map.put(base, :company, ""))
    assert {:error, {:stage, "sent"}} = Opening.new(Map.put(base, :stage, "sent"))
    assert {:error, {:gate, "yes"}} = Opening.new(Map.put(base, :gate, "yes"))
    assert {:error, {:freshness, :stale}} = Opening.new(Map.put(base, :freshness, :stale))

    assert {:error, {:overlay, _}} =
             Opening.new(Map.put(base, :overlays, [%{item_id: 1, mode: "loud"}]))
  end

  test "a signal names its application and serialises without nil fields" do
    signal = Signal.stage(7, :gated)
    assert Signal.about?(signal, 7)
    refute Signal.about?(signal, 8)
    refute Signal.about?(Signal.open_fire("Batch-001"), 7)

    assert Signal.to_json(signal) == %{"type" => "stage", "job_id" => 7, "stage" => "gated"}

    assert Signal.to_json(Signal.open_fire("Batch-001")) == %{
             "type" => "open_fire",
             "batch" => "Batch-001"
           }
  end
end
