defmodule Hireme.GeographyTest do
  use Hireme.DataCase, async: false

  alias Hireme.Geography
  alias Hireme.Geography.Catalog
  alias Hireme.Geography.Country
  alias Hireme.Geography.Place
  alias Hireme.Geography.Profile
  alias Hireme.Ops

  test "the chart is seventy-nine cities, and Romania is a country on it" do
    assert Catalog.count() == 79

    for name <- ["Cluj-Napoca", "Bucharest"] do
      city = city(name)
      assert city.mobility == :eu
      assert city.language == :ro
      assert city.country == "Romania"
    end
  end

  test "the local desk is written once, and a later install keeps the weights" do
    assert :ok = Geography.install_local_desk!()
    profile = Repo.one!(Profile)
    assert profile.field == "Software / AI"
    assert profile.citizenships == "RO,CA"
    assert profile.languages == "fr,en"

    assert Geography.weights(profile) == %{
             energy: 5,
             qol: 3,
             afford: 2,
             lang: 3,
             route: 3,
             tech: 3,
             ease: 2
           }

    assert Repo.aggregate(Place, :count) == 79
    assert Repo.aggregate(Country, :count) == 34

    assert {:ok, _} =
             Geography.set_weights(%{
               energy: 4,
               qol: 5,
               afford: 0,
               lang: 1,
               route: 2,
               tech: 4,
               ease: 3
             })

    assert :ok = Geography.install_local_desk!()
    again = Repo.one!(Profile)
    assert again.citizenships == "RO,CA"

    assert Geography.weights(again) == %{
             energy: 4,
             qol: 5,
             afford: 0,
             lang: 1,
             route: 2,
             tech: 4,
             ease: 3
           }

    assert Repo.aggregate(Place, :count) == 79
  end

  test "another account gets the same cities and an empty holder" do
    assert :ok = Geography.install_local_desk!()
    Hireme.DataCase.open_account("Other desk")
    assert Repo.aggregate(Place, :count) == 0
    assert is_nil(Repo.one(Profile))

    assert :ok = Geography.install_local_desk!()
    assert Repo.aggregate(Place, :count) == 79
    assert Repo.aggregate(Country, :count) == 34
    other = Repo.one!(Profile)
    assert other.citizenships == ""
    assert other.field == ""
    assert other.languages == ""
  end

  test "a weight outside 0 to 5 is refused, and an accepted write is stored", %{account: account} do
    assert :ok = Geography.install_local_desk!()

    assert {:error, %Ecto.Changeset{}} =
             Geography.set_weights(%{qol: 9, afford: 2, lang: 3, route: 3, tech: 3, ease: 2})

    assert Repo.one!(Profile).weight_qol == 3

    refused = %{
      op_id: 2,
      kind: :atlas_weights,
      target: 0,
      fields: ["9", "2", "3", "3", "3", "2", "5"]
    }

    assert {:error, {:argument, "qol"}} = Ops.run(account.id, refused)

    accepted = %{
      op_id: 3,
      kind: :atlas_weights,
      target: 0,
      fields: ["1", "2", "3", "4", "5", "0", "5"]
    }

    assert {:ok, revision} = Ops.run(account.id, accepted)
    assert is_integer(revision)
    kept = %{energy: 5, qol: 1, afford: 2, lang: 3, route: 4, tech: 5, ease: 0}
    assert Geography.weights(Repo.one!(Profile)) == kept
  end

  test "the seeded holder scores home, free movement, and a youth visa from the same chart" do
    holder = holder("RO,CA", "fr,en")

    vienna = Geography.route(city("Vienna"), holder)
    assert vienna.key == :eu and vienna.score == 1.0
    assert Geography.language(city("Vienna"), holder).score == 0.4

    cluj = Geography.route(city("Cluj-Napoca"), holder)
    assert cluj.key == :home and cluj.score == 1.0
    assert cluj.text =~ "You're a citizen of Romania"
    romanian = Geography.language(city("Cluj-Napoca"), holder)
    assert romanian.score == 0.75
    assert romanian.text =~ "Your Romanian covers daily life"

    london = Geography.route(city("London"), holder)
    assert london.key == :uk and london.score == 0.6
    assert london.label == "UK Youth Mobility (Canadian passport)"
    assert london.text =~ "The EU passport gives no right"
    assert london.text =~ "Canadians"

    belgrade = Geography.route(city("Belgrade"), holder)
    assert belgrade.key == :permit and belgrade.score == 0.3
    assert Geography.language(city("Geneva"), holder).score == 1.0

    assert Geography.passport_line(holder) == "EU (RO) + CA"
    assert Geography.language_line(holder) == "FR · EN"
    assert Geography.language_filter_label(holder) == "FR or EN is enough"
    assert Geography.sweet_label(holder) == "Free + FR/EN + real tech"
  end

  test "a different holder rescores the same cities" do
    blank = %Profile{}
    vienna = Geography.route(city("Vienna"), blank)
    assert vienna.key == :permit and vienna.score == 0.3

    french = holder("FR", "fr")
    assert Geography.route(city("Paris"), french).key == :home
    london = Geography.route(city("London"), french)
    assert london.key == :permit
    refute london.text =~ "Canadian"

    german = holder("RO,CA", "fr,en,de")
    assert Geography.language(city("Berlin"), german).score == 1.0
  end

  test "fit follows the weights, and a zero total is zero" do
    holder = holder("RO,CA", "fr,en")
    parts = Geography.parts(city("Vienna"), holder)

    balanced =
      Geography.fit(parts, %{energy: 3, qol: 3, afford: 2, lang: 3, route: 3, tech: 3, ease: 2})

    career =
      Geography.fit(parts, %{energy: 1, qol: 2, afford: 1, lang: 2, route: 3, tech: 5, ease: 1})

    assert balanced != career

    assert Geography.fit(parts, %{
             energy: 0,
             qol: 0,
             afford: 0,
             lang: 0,
             route: 0,
             tech: 0,
             ease: 0
           }) == 0.0
  end

  test "energy use and its year are stored for countries and for cities" do
    romania = Enum.find(Catalog.countries(), &(&1.name == "Romania"))
    albania = Enum.find(Catalog.countries(), &(&1.name == "Albania"))
    assert romania.energy == 18_694.0 and romania.energy_year == 2024
    assert albania.energy_year == 2023
    assert Geography.eu_energy() == 35_318

    vienna = city("Vienna")
    assert vienna.energy_year == 2024
    assert_in_delta vienna.energy, 44_250.7, 0.05
    bucharest = city("Bucharest")
    assert bucharest.mobility == :eu and bucharest.language == :ro
    assert bucharest.energy_year == 2024
    assert bucharest.energy != romania.energy

    holder = holder("RO,CA", "fr,en")
    vienna_parts = Geography.parts(city("Vienna"), holder)
    reykjavik = Geography.parts(city("Reykjavik"), holder)
    assert reykjavik.energy > vienna_parts.energy
    flipped = Geography.parts(city("Reykjavik"), holder, :less)
    assert flipped.energy < Geography.parts(city("Vienna"), holder, :less).energy

    heavy = %{energy: 5, qol: 0, afford: 0, lang: 0, route: 0, tech: 0, ease: 0}
    assert Geography.fit(reykjavik, heavy) > Geography.fit(vienna_parts, heavy)
  end

  defp holder(citizenships, languages) do
    %Profile{field: "Software / AI", citizenships: citizenships, languages: languages}
  end

  defp city(name) do
    row = Enum.find(Catalog.places(), &(&1.name == name))
    struct!(Place, row)
  end
end
