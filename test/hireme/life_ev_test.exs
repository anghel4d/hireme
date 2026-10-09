defmodule Hireme.LifeEvTest do
  use ExUnit.Case, async: true

  alias Hireme.LifeEv

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

  test "an explicit score_100 wins, clamped" do
    assert LifeEv.score(%{company: "OpenAI", score_100: 12}) == 12
    assert LifeEv.score(%{score: "140"}) == 100
    assert LifeEv.score(%{:company => nil, "company" => "OpenAI"}) == 100
    assert LifeEv.score(%{:score_100 => nil, "score_100" => "12 trailing"}) == 12
    assert LifeEv.score(%{company: "Staffing", score_100: 100}) == 100
  end
end
