defmodule Hireme.MaskTest do
  use ExUnit.Case, async: true

  alias Hireme.Cv
  alias Hireme.Keywords
  alias Hireme.Keywords.Coverage
  alias Hireme.Mask
  alias Hireme.Mask.Line
  alias Hireme.Theme

  defp item(id, body, kind \\ :experience) do
    %{
      id: id,
      key: "k#{id}",
      kind: kind,
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

    [%Line{} = first, %Line{} = second] = Mask.apply(items, overlays)

    assert first.shown
    assert first.mode == :altered
    assert first.body == "columnar ECS"
    assert first.canonical_body == "structure of arrays"
    refute second.shown
    assert second.body == "theatre elective"

    coverage = Keywords.coverage(["ecs", "theatre"], Mask.apply(items, overlays))
    assert coverage.hits == ["ecs"]
    assert coverage.misses == ["theatre"]
    assert Coverage.hit(coverage) == 1
    assert Coverage.total(coverage) == 2
    assert Coverage.percent(coverage) == 50

    root = Keywords.coverage(["ecs", "theatre"], Mask.apply(items, []))
    assert root.hits == ["theatre"]
    assert root.misses == ["ecs"]

    assert Mask.counts(overlays) == %{hidden: 1, altered: 1, emphasized: 0}
  end

  test "ecs does not match inside a longer token" do
    refute Keywords.hit?("specs and sectors", "ecs")
    assert Keywords.hit?("a columnar ecs tick", "ecs")
  end

  test "literal keywords preserve punctuation, Unicode boundaries, and overlapping matches" do
    for {text, term, expected} <- [
          {"c++ and c#", "C++", true},
          {"xc++", "c++", false},
          {"c++17", "c++", false},
          {"use node.js", "node.js", true},
          {"nodeXjs", "node.js", false},
          {"xa-a-a", "a-a", true},
          {"ecs_", "ecs", true},
          {"éecs", "ecs", true},
          {"ecsélan", "ecs", true},
          {"", "", true},
          {"abc", "", false},
          {"a b", "", false},
          {" a", "", true},
          {"a  b", "", true},
          {"abc", "abcd", false},
          {"", "ecs", false}
        ] do
      assert Keywords.hit?(text, term) == expected
    end
  end

  test "a theme parses once from loose keys and round-trips through storage" do
    theme =
      Theme.parse(%{"lead" => " Lead line ", "accent" => "signal", :targets => ["ecs", " "]})

    assert theme.lead == "Lead line"
    assert theme.accent == :signal
    assert theme.density == :cv
    assert theme.targets == ["ecs"]
    assert Theme.parse(Theme.to_map(theme)) == theme

    assert Theme.parse(%{"accent" => "neon", "density" => 3}) == %Theme{}
    assert Theme.empty?(Theme.parse(nil))
  end

  test "the theme's targets win over the listing, and an empty theme reads the listing" do
    assert Keywords.targets(Theme.parse(%{"targets" => ["ecs"]}), "columnar columnar") == ["ecs"]
    assert Keywords.targets(%Theme{}, "columnar columnar theatre") == ["columnar", "theatre"]
  end

  test "the document folds lines into sections and keeps hidden lines on the tray" do
    items = [item(1, "runtime work"), item(2, "a fact", :fact), item(3, "old job")]
    overlays = [%{item_id: 3, mode: :hidden, reason: "noise"}]
    profile = %{headline: "Engineer", summary: "Root summary."}

    doc =
      Cv.compose(profile, Mask.apply(items, overlays), Theme.parse(%{"lead" => "Lead."}),
        label: "CV1"
      )

    assert %Cv.Document{label: "CV1", summary: "Lead.", summary_canonical: "Root summary."} = doc
    assert [%Cv.Section{kind: :experience, lines: [%Line{id: 1}]}] = doc.sections
    assert [%Line{id: 2}] = doc.facts
    assert [%Line{id: 3, shown: false}] = doc.hidden
  end
end
