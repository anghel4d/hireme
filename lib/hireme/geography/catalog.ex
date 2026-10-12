defmodule Hireme.Geography.Catalog do
  @moduledoc """
  The European city chart. Cost and quality of life are positions on the
  October 2026 Numbeo chart. Mobility is the country's legal class
  (`eu`, `eea`, `ch`, `uk`, `non`). Language is the local language, never
  a holder's. Romania is `eu` and `ro`; a desk's own passport is what
  turns a city into home.
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
          labeled: boolean()
        }

  # position, name, country, region, cost, qol, mobility, language, tech, ease, labeled
  @rows [
    {0, "Vienna", "Austria", :central, 55.7, 99.0, :eu, :de, 2, 2, true},
    {1, "Helsinki", "Finland", :nordic, 59.5, 96.5, :eu, :en, 2, 2, false},
    {2, "The Hague", "Netherlands", :west, 65.1, 100.0, :eu, :en, 2, 3, false},
    {3, "Eindhoven", "Netherlands", :west, 66.6, 97.6, :eu, :en, 2, 3, true},
    {4, "Reykjavik", "Iceland", :nordic, 66.6, 92.4, :eea, :en, 1, 2, false},
    {5, "Munich", "Germany", :central, 64.3, 86.3, :eu, :de, 3, 1, true},
    {6, "Rotterdam", "Netherlands", :west, 66.3, 88.7, :eu, :en, 2, 3, false},
    {7, "Gent", "Belgium", :west, 64.6, 84.6, :eu, :other, 1, 1, false},
    {8, "Utrecht", "Netherlands", :west, 75.9, 95.1, :eu, :en, 2, 3, true},
    {9, "Copenhagen", "Denmark", :nordic, 62.4, 83.4, :eu, :en, 2, 2, true},
    {10, "Luxembourg", "Luxembourg", :west, 80.2, 82.4, :eu, :fr, 2, 2, true},
    {11, "Amsterdam", "Netherlands", :west, 81.4, 87.3, :eu, :en, 3, 3, true},
    {12, "Tallinn", "Estonia", :nordic, 83.6, 89.9, :eu, :en, 2, 3, true},
    {13, "Dusseldorf", "Germany", :central, 57.8, 75.9, :eu, :de, 1, 1, false},
    {14, "Edinburgh", "United Kingdom", :west, 61.7, 78.4, :uk, :en, 2, 1, false},
    {15, "Zurich", "Switzerland", :central, 59.2, 72.1, :ch, :de, 3, 2, true},
    {16, "Oslo", "Norway", :nordic, 62.7, 69.5, :eea, :en, 2, 2, false},
    {17, "Stuttgart", "Germany", :central, 50.9, 68.2, :eu, :de, 2, 1, false},
    {18, "Liverpool", "United Kingdom", :west, 56.6, 65.7, :uk, :en, 1, 1, false},
    {19, "Gothenburg", "Sweden", :nordic, 63.2, 61.7, :eu, :en, 2, 2, false},
    {20, "Hamburg", "Germany", :central, 61.6, 60.5, :eu, :de, 2, 1, false},
    {21, "Geneva", "Switzerland", :central, 53.1, 63.0, :ch, :fr, 2, 2, true},
    {22, "Graz", "Austria", :central, 52.1, 59.3, :eu, :de, 1, 2, false},
    {23, "Frankfurt", "Germany", :central, 61.0, 56.6, :eu, :de, 2, 1, false},
    {24, "Glasgow", "United Kingdom", :west, 59.5, 55.4, :uk, :en, 1, 1, false},
    {25, "Lausanne", "Switzerland", :central, 55.7, 52.9, :ch, :fr, 2, 2, true},
    {26, "Trieste", "Italy", :south, 70.5, 51.6, :eu, :other, 1, 1, false},
    {27, "Stockholm", "Sweden", :nordic, 67.7, 50.2, :eu, :en, 3, 2, false},
    {28, "Toulouse", "France", :west, 71.3, 49.0, :eu, :fr, 2, 2, true},
    {29, "Cork", "Ireland", :west, 82.8, 54.1, :eu, :en, 2, 2, false},
    {30, "Basel", "Switzerland", :central, 48.3, 46.4, :ch, :de, 2, 2, false},
    {31, "Cologne", "Germany", :central, 60.0, 42.6, :eu, :de, 1, 1, false},
    {32, "Bristol", "United Kingdom", :west, 70.3, 40.0, :uk, :en, 2, 1, false},
    {33, "Berlin", "Germany", :central, 71.9, 38.8, :eu, :de, 3, 1, true},
    {34, "Rome", "Italy", :south, 77.0, 36.2, :eu, :other, 1, 1, false},
    {35, "Antwerp", "Belgium", :west, 63.4, 32.4, :eu, :other, 1, 1, false},
    {36, "Lyon", "France", :west, 70.3, 23.3, :eu, :fr, 2, 2, true},
    {37, "Manchester", "United Kingdom", :west, 64.5, 22.1, :uk, :en, 2, 1, false},
    {38, "Turin", "Italy", :south, 67.0, 13.1, :eu, :other, 1, 1, false},
    {39, "Brussels", "Belgium", :west, 67.8, 11.8, :eu, :fr, 2, 1, true},
    {40, "Paris", "France", :west, 72.9, 8.0, :eu, :fr, 3, 2, true},
    {41, "Naples", "Italy", :south, 76.9, 1.7, :eu, :other, 1, 1, false},
    {42, "London", "United Kingdom", :west, 84.8, 9.3, :uk, :en, 3, 1, true},
    {43, "Milan", "Italy", :south, 93.7, 6.7, :eu, :other, 2, 1, false},
    {44, "Dublin", "Ireland", :west, 92.0, 18.2, :eu, :en, 3, 2, true},
    {45, "Krakow", "Poland", :central, 92.8, 16.9, :eu, :other, 2, 2, false},
    {46, "Madrid", "Spain", :south, 90.8, 70.7, :eu, :other, 2, 1, true},
    {47, "Bologna", "Italy", :south, 81.4, 27.1, :eu, :other, 1, 1, false},
    {48, "Wroclaw", "Poland", :central, 90.9, 24.8, :eu, :other, 2, 2, false},
    {49, "Warsaw", "Poland", :central, 98.1, 25.8, :eu, :other, 2, 2, true},
    {50, "Budapest", "Hungary", :central, 97.5, 19.6, :eu, :other, 2, 2, false},
    {51, "Gdansk", "Poland", :central, 95.1, 28.5, :eu, :other, 1, 2, false},
    {52, "Nicosia", "Cyprus", :south, 88.3, 31.0, :eu, :en, 1, 1, false},
    {53, "Barcelona", "Spain", :south, 99.8, 29.8, :eu, :other, 2, 1, true},
    {54, "Thessaloniki", "Greece", :south, 104.0, 20.9, :eu, :other, 1, 1, false},
    {55, "Sarajevo", "Bosnia and Herzegovina", :east, 101.7, 15.7, :non, :other, 1, 1, false},
    {56, "Athens", "Greece", :south, 100.1, 14.2, :eu, :other, 1, 1, false},
    {57, "Florence", "Italy", :south, 94.3, 44.0, :eu, :other, 1, 1, false},
    {58, "Riga", "Latvia", :nordic, 96.3, 41.4, :eu, :other, 1, 2, false},
    {59, "Bratislava", "Slovakia", :central, 109.0, 45.1, :eu, :other, 1, 2, false},
    {60, "Cluj-Napoca", "Romania", :east, 122.8, 47.7, :eu, :ro, 2, 3, true},
    {61, "Plovdiv", "Bulgaria", :east, 135.7, 37.6, :eu, :other, 1, 2, false},
    {62, "Varna", "Bulgaria", :east, 143.5, 35.0, :eu, :other, 1, 2, false},
    {63, "Limassol", "Cyprus", :south, 132.8, 33.6, :eu, :en, 1, 1, false},
    {64, "Sofia", "Bulgaria", :east, 115.4, 10.7, :eu, :other, 2, 2, false},
    {65, "Bucharest", "Romania", :east, 108.6, 4.1, :eu, :ro, 2, 3, true},
    {66, "Belgrade", "Serbia", :east, 121.6, 5.5, :non, :other, 1, 1, false},
    {67, "Skopje", "North Macedonia", :east, 129.3, 2.9, :non, :other, 1, 1, false},
    {68, "Tirana", "Albania", :east, 168.6, 0.3, :non, :other, 1, 1, true},
    {69, "Porto", "Portugal", :south, 117.5, 93.9, :eu, :other, 2, 2, true},
    {70, "Split", "Croatia", :east, 128.1, 91.2, :eu, :other, 1, 2, false},
    {71, "Lisbon", "Portugal", :south, 127.0, 58.0, :eu, :other, 2, 2, true},
    {72, "Valencia", "Spain", :south, 97.4, 81.1, :eu, :other, 1, 1, false},
    {73, "Vilnius", "Lithuania", :nordic, 94.0, 77.3, :eu, :other, 2, 2, false},
    {74, "Ljubljana", "Slovenia", :central, 103.7, 79.8, :eu, :other, 1, 2, false},
    {75, "Malaga", "Spain", :south, 102.9, 74.7, :eu, :other, 1, 1, false},
    {76, "Prague", "Czechia", :central, 97.5, 73.3, :eu, :other, 2, 2, true},
    {77, "Brno", "Czechia", :central, 102.2, 66.9, :eu, :other, 1, 2, false},
    {78, "Zagreb", "Croatia", :east, 102.5, 64.4, :eu, :other, 1, 2, false}
  ]

  @spec places() :: [place()]
  def places do
    Enum.map(@rows, fn {position, name, country, region, cost, qol, mobility, language, tech,
                        ease, labeled} ->
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
        labeled: labeled
      }
    end)
  end

  @spec count() :: pos_integer()
  def count, do: length(@rows)
end
