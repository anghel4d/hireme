defmodule Hireme.LifeEvTest do
  use ExUnit.Case, async: true

  alias Hireme.LifeEv
  alias Hireme.LifeEv.Chart

  test "named anchors sit on the published rungs" do
    assert LifeEv.score("OpenAI") == 100
    assert LifeEv.score("Anthropic") == 100
    assert LifeEv.score("SpaceX") == 100
    assert LifeEv.score("Neuralink") == 100
    assert LifeEv.score("Starfish") == 90
    assert LifeEv.score("Valve") == 90
    assert LifeEv.score(%{company: "DeepMind"}) == 90
    assert LifeEv.score(%{company: "Meta", role: "Research engineer"}) == 90
    assert LifeEv.score(%{company: "Google", comp: "$220k"}) == 85
    assert LifeEv.score(%{company: "Google"}) == 80
  end

  test "hard kills cannot be raised by a systems title" do
    assert LifeEv.score(%{company: "Acme Staffing", role: "Rust systems"}) < 20
    assert LifeEv.band(LifeEv.score(%{role: "Prompt-only intern"})) == :kill
  end

  test "unanchored systems seats land in the systems band" do
    score =
      LifeEv.score(%{
        company: "Redcedar Runtime",
        role: "Rust systems engineer",
        fit: "agentic",
        location: "Remote · Canada"
      })

    assert LifeEv.band(score) == :systems
    assert score >= 70
  end

  test "an explicit score_100 wins, clamped" do
    assert LifeEv.score(%{company: "OpenAI", score_100: 12}) == 12
    assert LifeEv.score(%{score: "140"}) == 100
  end

  test "chart counts bands and histogram bins" do
    chart = LifeEv.chart([100, 90, 85, 50, 50, 8])
    assert %Chart{n: 6, max: 100, min: 8} = chart
    by_key = Map.new(chart.bands, &{&1.key, &1.count})
    assert by_key.frontier == 1
    assert by_key.labs == 1
    assert by_key.big_tech == 1
    assert by_key.mid == 2
    assert by_key.kill == 1
    assert Enum.sum(Enum.map(chart.bins, & &1.count)) == 6
  end

  test "parse_band is closed at the edge" do
    assert LifeEv.parse_band("labs") == {:ok, :labs}
    assert LifeEv.parse_band("all") == {:ok, :all}
    assert LifeEv.parse_band("mystery") == :error
  end
end
