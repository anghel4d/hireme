defmodule Hireme.Geography.Catalog do
  @moduledoc """
  The European city chart. Cost and quality of life are positions on the
  October 2026 Numbeo chart. Mobility is the country's legal class
  (`eu`, `eea`, `ch`, `uk`, `non`). Language is the local language, never
  a holder's. Romania is `eu` and `ro`; a desk's own passport is what
  turns a city into home. `energy` and `energy_year` are primary energy
  use per person for that place, in kWh and the data year.
  """

  @type place :: %{
          position: non_neg_integer(),
          name: String.t(),
          country: String.t(),
          region: atom(),
          cost: float(),
          qol: float(),
          mobility: atom(),
          language: atom(),
          tech: 1..3,
          ease: 1..3,
          labeled: boolean(),
          energy: float(),
          energy_year: pos_integer()
        }

  @type country :: %{name: String.t(), energy: float(), energy_year: pos_integer()}

  # position, name, country, region, cost, qol, mobility, language, tech, ease,
  # labeled, energy kWh/person/year, energy year. City energy is the country's
  # figure adjusted for local heating (18% scaled by heating degree days).
  @rows [
    {0, "Vienna", "Austria", :central, 55.7, 99.0, :eu, :de, 2, 2, true, 44250.7, 2024},
    {1, "Helsinki", "Finland", :nordic, 59.5, 96.5, :eu, :en, 2, 2, false, 58278.4, 2024},
    {2, "The Hague", "Netherlands", :west, 65.1, 100.0, :eu, :en, 2, 3, false, 50824.0, 2024},
    {3, "Eindhoven", "Netherlands", :west, 66.6, 97.6, :eu, :en, 2, 3, true, 50824.0, 2024},
    {4, "Reykjavik", "Iceland", :nordic, 66.6, 92.4, :eea, :en, 1, 2, false, 159_101.2, 2024},
    {5, "Munich", "Germany", :central, 64.3, 86.3, :eu, :de, 3, 1, true, 38430.8, 2024},
    {6, "Rotterdam", "Netherlands", :west, 66.3, 88.7, :eu, :en, 2, 3, false, 50824.0, 2024},
    {7, "Gent", "Belgium", :west, 64.6, 84.6, :eu, :other, 1, 1, false, 54871.0, 2024},
    {8, "Utrecht", "Netherlands", :west, 75.9, 95.1, :eu, :en, 2, 3, true, 50824.0, 2024},
    {9, "Copenhagen", "Denmark", :nordic, 62.4, 83.4, :eu, :en, 2, 2, true, 32832.0, 2024},
    {10, "Luxembourg", "Luxembourg", :west, 80.2, 82.4, :eu, :fr, 2, 2, true, 59390.9, 2024},
    {11, "Amsterdam", "Netherlands", :west, 81.4, 87.3, :eu, :en, 3, 3, true, 50824.0, 2024},
    {12, "Tallinn", "Estonia", :nordic, 83.6, 89.9, :eu, :en, 2, 3, true, 40814.4, 2024},
    {13, "Dusseldorf", "Germany", :central, 57.8, 75.9, :eu, :de, 1, 1, false, 36942.7, 2024},
    {14, "Edinburgh", "United Kingdom", :west, 61.7, 78.4, :uk, :en, 2, 1, false, 28352.2, 2024},
    {15, "Zurich", "Switzerland", :central, 59.2, 72.1, :ch, :de, 3, 2, true, 38026.0, 2024},
    {16, "Oslo", "Norway", :nordic, 62.7, 69.5, :eea, :en, 2, 2, false, 97123.2, 2024},
    {17, "Stuttgart", "Germany", :central, 50.9, 68.2, :eu, :de, 2, 1, false, 37580.4, 2024},
    {18, "Liverpool", "United Kingdom", :west, 56.6, 65.7, :uk, :en, 1, 1, false, 27679.8, 2024},
    {19, "Gothenburg", "Sweden", :nordic, 63.2, 61.7, :eu, :en, 2, 2, false, 56065.6, 2024},
    {20, "Hamburg", "Germany", :central, 61.6, 60.5, :eu, :de, 2, 1, false, 37793.0, 2024},
    {21, "Geneva", "Switzerland", :central, 53.1, 63.0, :ch, :fr, 2, 2, true, 37196.3, 2024},
    {22, "Graz", "Austria", :central, 52.1, 59.3, :eu, :de, 1, 2, false, 44729.3, 2024},
    {23, "Frankfurt", "Germany", :central, 61.0, 56.6, :eu, :de, 2, 1, false, 37367.8, 2024},
    {24, "Glasgow", "United Kingdom", :west, 59.5, 55.4, :uk, :en, 1, 1, false, 28352.2, 2024},
    {25, "Lausanne", "Switzerland", :central, 55.7, 52.9, :ch, :fr, 2, 2, true, 37403.8, 2024},
    {26, "Trieste", "Italy", :south, 70.5, 51.6, :eu, :other, 1, 1, false, 28855.8, 2024},
    {27, "Stockholm", "Sweden", :nordic, 67.7, 50.2, :eu, :en, 3, 2, false, 56547.0, 2024},
    {28, "Toulouse", "France", :west, 71.3, 49.0, :eu, :fr, 2, 2, true, 36446.0, 2024},
    {29, "Cork", "Ireland", :west, 82.8, 54.1, :eu, :en, 2, 2, false, 34149.2, 2024},
    {30, "Basel", "Switzerland", :central, 48.3, 46.4, :ch, :de, 2, 2, false, 37196.3, 2024},
    {31, "Cologne", "Germany", :central, 60.0, 42.6, :eu, :de, 1, 1, false, 36942.7, 2024},
    {32, "Bristol", "United Kingdom", :west, 70.3, 40.0, :uk, :en, 2, 1, false, 27343.6, 2024},
    {33, "Berlin", "Germany", :central, 71.9, 38.8, :eu, :de, 3, 1, true, 37793.0, 2024},
    {34, "Rome", "Italy", :south, 77.0, 36.2, :eu, :other, 1, 1, false, 27231.0, 2024},
    {35, "Antwerp", "Belgium", :west, 63.4, 32.4, :eu, :other, 1, 1, false, 54871.0, 2024},
    {36, "Lyon", "France", :west, 70.3, 23.3, :eu, :fr, 2, 2, true, 37866.0, 2024},
    {37, "Manchester", "United Kingdom", :west, 64.5, 22.1, :uk, :en, 2, 1, false, 27847.9, 2024},
    {38, "Turin", "Italy", :south, 67.0, 13.1, :eu, :other, 1, 1, false, 29939.0, 2024},
    {39, "Brussels", "Belgium", :west, 67.8, 11.8, :eu, :fr, 2, 1, true, 54871.0, 2024},
    {40, "Paris", "France", :west, 72.9, 8.0, :eu, :fr, 3, 2, true, 37866.0, 2024},
    {41, "Naples", "Italy", :south, 76.9, 1.7, :eu, :other, 1, 1, false, 26418.6, 2024},
    {42, "London", "United Kingdom", :west, 84.8, 9.3, :uk, :en, 3, 1, true, 27175.5, 2024},
    {43, "Milan", "Italy", :south, 93.7, 6.7, :eu, :other, 2, 1, false, 29668.2, 2024},
    {44, "Dublin", "Ireland", :west, 92.0, 18.2, :eu, :en, 3, 2, true, 34371.6, 2024},
    {45, "Krakow", "Poland", :central, 92.8, 16.9, :eu, :other, 2, 2, false, 29206.0, 2024},
    {46, "Madrid", "Spain", :south, 90.8, 70.7, :eu, :other, 2, 1, true, 34241.0, 2024},
    {47, "Bologna", "Italy", :south, 81.4, 27.1, :eu, :other, 1, 1, false, 29126.6, 2024},
    {48, "Wroclaw", "Poland", :central, 90.9, 24.8, :eu, :other, 2, 2, false, 28755.4, 2024},
    {49, "Warsaw", "Poland", :central, 98.1, 25.8, :eu, :other, 2, 2, true, 29206.0, 2024},
    {50, "Budapest", "Hungary", :central, 97.5, 19.6, :eu, :other, 2, 2, false, 26952.0, 2024},
    {51, "Gdansk", "Poland", :central, 95.1, 28.5, :eu, :other, 1, 2, false, 29206.0, 2024},
    {52, "Nicosia", "Cyprus", :south, 88.3, 31.0, :eu, :en, 1, 1, false, 25182.3, 2024},
    {53, "Barcelona", "Spain", :south, 99.8, 29.8, :eu, :other, 2, 1, true, 32206.9, 2024},
    {54, "Thessaloniki", "Greece", :south, 104.0, 20.9, :eu, :other, 1, 1, false, 32325.6, 2024},
    {55, "Sarajevo", "Bosnia and Herzegovina", :east, 101.7, 15.7, :non, :other, 1, 1, false,
     26736.0, 2023},
    {56, "Athens", "Greece", :south, 100.1, 14.2, :eu, :other, 1, 1, false, 29808.3, 2024},
    {57, "Florence", "Italy", :south, 94.3, 44.0, :eu, :other, 1, 1, false, 28043.4, 2024},
    {58, "Riga", "Latvia", :nordic, 96.3, 41.4, :eu, :other, 1, 2, false, 20544.4, 2024},
    {59, "Bratislava", "Slovakia", :central, 109.0, 45.1, :eu, :other, 1, 2, false, 32501.1,
     2024},
    {60, "Cluj-Napoca", "Romania", :east, 122.8, 47.7, :eu, :ro, 2, 3, true, 19142.7, 2024},
    {61, "Plovdiv", "Bulgaria", :east, 135.7, 37.6, :eu, :other, 1, 2, false, 27989.0, 2024},
    {62, "Varna", "Bulgaria", :east, 143.5, 35.0, :eu, :other, 1, 2, false, 27596.0, 2024},
    {63, "Limassol", "Cyprus", :south, 132.8, 33.6, :eu, :en, 1, 1, false, 23919.7, 2024},
    {64, "Sofia", "Bulgaria", :east, 115.4, 10.7, :eu, :other, 2, 2, false, 28971.5, 2024},
    {65, "Bucharest", "Romania", :east, 108.6, 4.1, :eu, :ro, 2, 3, true, 18469.7, 2024},
    {66, "Belgrade", "Serbia", :east, 121.6, 5.5, :non, :other, 1, 1, false, 26156.5, 2023},
    {67, "Skopje", "North Macedonia", :east, 129.3, 2.9, :non, :other, 1, 1, false, 16003.7,
     2024},
    {68, "Tirana", "Albania", :east, 168.6, 0.3, :non, :other, 1, 1, true, 7851.3, 2023},
    {69, "Porto", "Portugal", :south, 117.5, 93.9, :eu, :other, 2, 2, true, 26310.8, 2024},
    {70, "Split", "Croatia", :east, 128.1, 91.2, :eu, :other, 1, 2, false, 24219.7, 2024},
    {71, "Lisbon", "Portugal", :south, 127.0, 58.0, :eu, :other, 2, 2, true, 24755.5, 2024},
    {72, "Valencia", "Spain", :south, 97.4, 81.1, :eu, :other, 1, 1, false, 30850.8, 2024},
    {73, "Vilnius", "Lithuania", :nordic, 94.0, 77.3, :eu, :other, 2, 2, false, 25547.3, 2024},
    {74, "Ljubljana", "Slovenia", :central, 103.7, 79.8, :eu, :other, 1, 2, false, 37361.0, 2024},
    {75, "Malaga", "Spain", :south, 102.9, 74.7, :eu, :other, 1, 1, false, 29833.8, 2024},
    {76, "Prague", "Czechia", :central, 97.5, 73.3, :eu, :other, 2, 2, true, 36401.8, 2024},
    {77, "Brno", "Czechia", :central, 102.2, 66.9, :eu, :other, 1, 2, false, 36213.6, 2024},
    {78, "Zagreb", "Croatia", :east, 102.5, 64.4, :eu, :other, 1, 2, false, 27703.8, 2024}
  ]

  # Country primary energy per person, and the year of that figure.
  @country_rows [
    {"Albania", 8032.0, 2023},
    {"Austria", 45208.0, 2024},
    {"Belgium", 54871.0, 2024},
    {"Bosnia and Herzegovina", 26736.0, 2023},
    {"Bulgaria", 28382.0, 2024},
    {"Croatia", 26615.0, 2024},
    {"Cyprus", 24551.0, 2024},
    {"Czechia", 36590.0, 2024},
    {"Denmark", 32832.0, 2024},
    {"Estonia", 40986.0, 2024},
    {"Finland", 59565.0, 2024},
    {"France", 37866.0, 2024},
    {"Germany", 37793.0, 2024},
    {"Greece", 31966.0, 2024},
    {"Hungary", 26952.0, 2024},
    {"Iceland", 159_676.0, 2024},
    {"Ireland", 34594.0, 2024},
    {"Italy", 28585.0, 2024},
    {"Latvia", 20722.0, 2024},
    {"Lithuania", 25660.0, 2024},
    {"Luxembourg", 59048.0, 2024},
    {"Netherlands", 50824.0, 2024},
    {"North Macedonia", 16220.0, 2024},
    {"Norway", 99634.0, 2024},
    {"Poland", 29206.0, 2024},
    {"Portugal", 25922.0, 2024},
    {"Romania", 18694.0, 2024},
    {"Serbia", 26332.0, 2023},
    {"Slovakia", 32883.0, 2024},
    {"Slovenia", 37361.0, 2024},
    {"Spain", 33902.0, 2024},
    {"Sweden", 57510.0, 2024},
    {"Switzerland", 38026.0, 2024},
    {"United Kingdom", 28016.0, 2024}
  ]

  @spec places() :: [place()]
  def places do
    Enum.map(@rows, fn {position, name, country, region, cost, qol, mobility, language, tech,
                        ease, labeled, energy, energy_year} ->
      %{
        position: position,
        name: name,
        country: country,
        region: region,
        cost: cost,
        qol: qol,
        mobility: mobility,
        language: language,
        tech: tech,
        ease: ease,
        labeled: labeled,
        energy: energy,
        energy_year: energy_year
      }
    end)
  end

  @spec countries() :: [country()]
  def countries do
    Enum.map(@country_rows, fn {name, energy, energy_year} ->
      %{name: name, energy: energy, energy_year: energy_year}
    end)
  end

  @spec count() :: pos_integer()
  def count, do: length(@rows)
end
