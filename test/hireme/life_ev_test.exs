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
    assert LifeEv.score(%{:company => nil, "company" => "OpenAI"}) == 100
    assert LifeEv.score(%{:score_100 => nil, "score_100" => "12 trailing"}) == 12
    assert LifeEv.score(%{company: "Staffing", score_100: 100}) == 100
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

  test "chart covers every closed boundary and preserves empty and malformed input semantics" do
    empty = LifeEv.chart([])
    assert {empty.n, empty.mean, empty.min, empty.max} == {0, nil, nil, nil}
    assert Enum.all?(empty.bands, &(&1.count == 0 and &1.share == 0.0))
    assert Enum.all?(empty.bins, &(&1.count == 0))

    chart = LifeEv.chart(Enum.to_list(0..100))
    assert {chart.n, chart.mean, chart.min, chart.max} == {101, 50.0, 0, 100}

    for row <- chart.bands do
      assert row.count == row.max - row.min + 1
      assert row.share == Float.round(row.count / 101, 3)
    end

    assert Enum.map(chart.bins, & &1.count) == List.duplicate(10, 9) ++ [11]

    mixed =
      LifeEv.chart([
        -1,
        101,
        %{score_100: 5},
        %{"score_100" => 95},
        %{:score_100 => nil, "score_100" => 90},
        nil,
        "80",
        %{}
      ])

    assert {mixed.n, mixed.mean, mixed.min, mixed.max} == {8, 36.3, 0, 100}
  end

  test "grouped charts merge scores that clamp into the same bucket" do
    chart = LifeEv.chart_frequencies([{-1, 2}, {0, 3}, {100, 1}, {150, 2}, {nil, 1}])
    assert %Chart{n: 9, min: 0, max: 100, mean: 33.3} = chart
    assert Enum.find(chart.bands, &(&1.key == :kill)).count == 6
    assert Enum.find(chart.bands, &(&1.key == :frontier)).count == 3
    assert LifeEv.chart_frequencies([]) == LifeEv.chart([])
  end

  test "parse_band is closed at the edge" do
    assert LifeEv.parse_band("labs") == {:ok, :labs}
    assert LifeEv.parse_band("all") == {:ok, :all}
    assert LifeEv.parse_band("mystery") == :error
  end
end
