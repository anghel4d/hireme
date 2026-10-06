defmodule Hireme.MaskTest do
  use ExUnit.Case, async: true

  alias Hireme.Keywords
  alias Hireme.Mask

  defp item(id, body) do
    %{
      id: id,
      key: "k#{id}",
      kind: :experience,
      title: "Line #{id}",
      body: body,
      org: "Org",
      span: "2024",
      position: id
    }
  end

  test "a hidden line drops out of the visible CV and an altered line keeps the root beside it" do
    items = [item(1, "structure of arrays"), item(2, "theatre elective")]

    overlays = [
      %{item_id: 1, mode: :altered, title: nil, body: "columnar ECS", reason: "listing"},
      %{item_id: 2, mode: :hidden, title: nil, body: nil, reason: "noise"}
    ]

    [first, second] = Mask.apply(items, overlays)

    assert first.shown
    assert first.mode == :altered
    assert first.body == "columnar ECS"
    assert first.canonical_body == "structure of arrays"
    refute second.shown
    assert second.body == "theatre elective"

    coverage = Keywords.coverage(["ecs", "theatre"], Mask.apply(items, overlays))
    assert coverage.hits == ["ecs"]
    assert coverage.misses == ["theatre"]

    root = Keywords.coverage(["ecs", "theatre"], Mask.apply(items, []))
    assert root.hits == ["theatre"]
    assert root.misses == ["ecs"]
  end

  test "ecs does not match inside a longer token" do
    refute Keywords.hit?("specs and sectors", "ecs")
    assert Keywords.hit?("a columnar ecs tick", "ecs")
  end
end
