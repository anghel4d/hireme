defmodule Hireme.VarietyTest do
  use ExUnit.Case, async: true

  alias Hireme.Variety

  defp app(company, location \\ "Remote", fit \\ "systems") do
    %{company: company, role: "Engineer", location: location, fit: fit}
  end

  test "an empty pack is unfilled and a short pack is short" do
    assert %Variety{apps: 0, flags: [:unfilled]} = Variety.summarize([], 55)
    assert Variety.label(Variety.summarize([], 55)) == "unfilled"

    short = Variety.summarize([app("A"), app("B")], 55)
    assert short.flags == [:short]
    assert Variety.label(short) == "short"
  end

  test "a full narrow pack picks up the mix flags" do
    apps = for i <- 1..55, do: app("Co #{rem(i, 4)}")
    variety = Variety.summarize(apps, 55)

    assert variety.companies == 4
    assert variety.flags == [:few_companies, :few_locations, :few_fits]
    assert Variety.label(variety) == "few_companies, few_locations, few_fits"
  end

  test "a varied pack has no flags" do
    apps = for i <- 1..55, do: app("Co #{i}", "City #{rem(i, 5)}", "fit #{rem(i, 3)}")
    variety = Variety.summarize(apps, 55)

    assert variety.flags == []
    assert Variety.label(variety) == "varied"
  end

  test "storage is a round trip and unknown flags are dropped" do
    variety = Variety.summarize(for(i <- 1..3, do: app("Co #{i}")), 55)
    assert Variety.from_map(Variety.to_map(variety)) == variety

    assert Variety.from_map(%{"apps" => 2, "flags" => ["short", "neon", 7]}) ==
             %Variety{apps: 2, flags: [:short]}

    assert Variety.from_map(nil) == %Variety{}
  end
end
