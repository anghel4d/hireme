defmodule Hireme.LifeEvTest do
  use ExUnit.Case, async: true

  alias Hireme.LifeEv

  test "an explicit score_100 wins, clamped" do
    assert LifeEv.score(%{company: "OpenAI", score_100: 12}) == 12
    assert LifeEv.score(%{score: "140"}) == 100
    assert LifeEv.score(%{:company => nil, "company" => "OpenAI"}) == 100
    assert LifeEv.score(%{:score_100 => nil, "score_100" => "12 trailing"}) == 12
    assert LifeEv.score(%{company: "Staffing", score_100: 100}) == 100
  end
end
