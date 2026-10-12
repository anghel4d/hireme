defmodule Hireme.Geography do
  @moduledoc """
  Career geography. The city chart is the same for every desk. What is
  personal — passports, languages, field, and the weight of each axis —
  is one profile row. A city's right to live and its language score are
  read from that profile, so the page that draws the chart never names
  a holder of its own.

  `route/2` and `language/2` are the spec the atlas view mirrors.
  """

  import Ecto.Query
  alias Hireme.Accounts.Account
  alias Hireme.Geography.Catalog
  alias Hireme.Geography.Country
  alias Hireme.Geography.Place
  alias Hireme.Geography.Profile
  alias Hireme.Repo

  @regions [:south, :west, :central, :nordic, :east]
  @mobility [:eu, :eea, :ch, :uk, :non]
  @languages [:fr, :en, :de, :ro, :other]
  @axes [:energy, :qol, :afford, :lang, :route, :tech, :ease]
  # Log range the energy axis is scored across, kWh per person per year.
  @energy_floor :math.log10(8000)
  @energy_ceil :math.log10(160_000)
  # EU average primary energy per person, the reference line on the energy chart.
  @eu_energy 35_318

  # The local desk's holder. Any other account starts blank and scores
  # the same cities against whatever passports it stores.
  @local_desk %{field: "Software / AI", citizenships: "RO,CA", languages: "fr,en"}

  @countries %{
    "AT" => %{
      name: "Austria",
      adjective: "Austrian",
      people: "Austrians",
      eu: true,
      eea: true,
      youth: false,
      lang: :de
    },
    "AU" => %{
      name: "Australia",
      adjective: "Australian",
      people: "Australians",
      eu: false,
      eea: false,
      youth: true,
      lang: :en
    },
    "BE" => %{
      name: "Belgium",
      adjective: "Belgian",
      people: "Belgians",
      eu: true,
      eea: true,
      youth: false,
      lang: :fr
    },
    "BG" => %{
      name: "Bulgaria",
      adjective: "Bulgarian",
      people: "Bulgarians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "CA" => %{
      name: "Canada",
      adjective: "Canadian",
      people: "Canadians",
      eu: false,
      eea: false,
      youth: true,
      lang: :en
    },
    "CH" => %{
      name: "Switzerland",
      adjective: "Swiss",
      people: "Swiss",
      eu: false,
      eea: false,
      youth: false,
      lang: :de
    },
    "CY" => %{
      name: "Cyprus",
      adjective: "Cypriot",
      people: "Cypriots",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "CZ" => %{
      name: "Czechia",
      adjective: "Czech",
      people: "Czechs",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "DE" => %{
      name: "Germany",
      adjective: "German",
      people: "Germans",
      eu: true,
      eea: true,
      youth: false,
      lang: :de
    },
    "DK" => %{
      name: "Denmark",
      adjective: "Danish",
      people: "Danes",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "EE" => %{
      name: "Estonia",
      adjective: "Estonian",
      people: "Estonians",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "ES" => %{
      name: "Spain",
      adjective: "Spanish",
      people: "Spaniards",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "FI" => %{
      name: "Finland",
      adjective: "Finnish",
      people: "Finns",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "FR" => %{
      name: "France",
      adjective: "French",
      people: "French",
      eu: true,
      eea: true,
      youth: false,
      lang: :fr
    },
    "GB" => %{
      name: "United Kingdom",
      adjective: "British",
      people: "Britons",
      eu: false,
      eea: false,
      youth: false,
      lang: :en
    },
    "GR" => %{
      name: "Greece",
      adjective: "Greek",
      people: "Greeks",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "HR" => %{
      name: "Croatia",
      adjective: "Croatian",
      people: "Croatians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "HU" => %{
      name: "Hungary",
      adjective: "Hungarian",
      people: "Hungarians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "IE" => %{
      name: "Ireland",
      adjective: "Irish",
      people: "Irish",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "IN" => %{
      name: "India",
      adjective: "Indian",
      people: "Indians",
      eu: false,
      eea: false,
      youth: true,
      lang: :en
    },
    "IS" => %{
      name: "Iceland",
      adjective: "Icelandic",
      people: "Icelanders",
      eu: false,
      eea: true,
      youth: true,
      lang: :en
    },
    "IT" => %{
      name: "Italy",
      adjective: "Italian",
      people: "Italians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "JP" => %{
      name: "Japan",
      adjective: "Japanese",
      people: "Japanese",
      eu: false,
      eea: false,
      youth: true,
      lang: nil
    },
    "KR" => %{
      name: "South Korea",
      adjective: "South Korean",
      people: "South Koreans",
      eu: false,
      eea: false,
      youth: true,
      lang: nil
    },
    "LT" => %{
      name: "Lithuania",
      adjective: "Lithuanian",
      people: "Lithuanians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "LU" => %{
      name: "Luxembourg",
      adjective: "Luxembourgish",
      people: "Luxembourgers",
      eu: true,
      eea: true,
      youth: false,
      lang: :fr
    },
    "LV" => %{
      name: "Latvia",
      adjective: "Latvian",
      people: "Latvians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "NL" => %{
      name: "Netherlands",
      adjective: "Dutch",
      people: "Dutch",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "NO" => %{
      name: "Norway",
      adjective: "Norwegian",
      people: "Norwegians",
      eu: false,
      eea: true,
      youth: false,
      lang: :en
    },
    "NZ" => %{
      name: "New Zealand",
      adjective: "New Zealand",
      people: "New Zealanders",
      eu: false,
      eea: false,
      youth: true,
      lang: :en
    },
    "PL" => %{
      name: "Poland",
      adjective: "Polish",
      people: "Poles",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "PT" => %{
      name: "Portugal",
      adjective: "Portuguese",
      people: "Portuguese",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "RO" => %{
      name: "Romania",
      adjective: "Romanian",
      people: "Romanians",
      eu: true,
      eea: true,
      youth: false,
      lang: :ro
    },
    "SE" => %{
      name: "Sweden",
      adjective: "Swedish",
      people: "Swedes",
      eu: true,
      eea: true,
      youth: false,
      lang: :en
    },
    "SI" => %{
      name: "Slovenia",
      adjective: "Slovenian",
      people: "Slovenians",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "SK" => %{
      name: "Slovakia",
      adjective: "Slovak",
      people: "Slovaks",
      eu: true,
      eea: true,
      youth: false,
      lang: nil
    },
    "US" => %{
      name: "United States",
      adjective: "American",
      people: "Americans",
      eu: false,
      eea: false,
      youth: false,
      lang: :en
    }
  }

  @lang_names %{
    fr: "French",
    en: "English",
    de: "German",
    ro: "Romanian",
    other: "Local language"
  }

  @presets [
    {"Balanced", %{energy: 3, qol: 3, afford: 2, lang: 3, route: 3, tech: 3, ease: 2}},
    {"Career first", %{energy: 1, qol: 2, afford: 1, lang: 2, route: 3, tech: 5, ease: 1}},
    {"Cheap and calm", %{energy: 1, qol: 4, afford: 5, lang: 2, route: 3, tech: 0, ease: 2}},
    {"Zero friction", %{energy: 1, qol: 2, afford: 1, lang: 5, route: 5, tech: 1, ease: 5}},
    {"Energy first", %{energy: 5, qol: 2, afford: 1, lang: 1, route: 2, tech: 1, ease: 1}},
    {"Best life", %{energy: 2, qol: 5, afford: 1, lang: 2, route: 2, tech: 1, ease: 1}}
  ]

  @type weights :: %{
          energy: 0..5,
          qol: 0..5,
          afford: 0..5,
          lang: 0..5,
          route: 0..5,
          tech: 0..5,
          ease: 0..5
        }

  @type reading :: %{
          key: atom(),
          label: String.t(),
          short: String.t(),
          tone: String.t(),
          score: float(),
          text: String.t()
        }

  @spec regions() :: [atom()]
  def regions, do: @regions

  @spec mobility() :: [atom()]
  def mobility, do: @mobility

  @spec languages() :: [atom()]
  def languages, do: @languages

  @spec axes() :: [atom()]
  def axes, do: @axes

  @spec presets() :: [{String.t(), weights()}]
  def presets, do: @presets

  @doc "The local desk's passports, languages, and field, written once."
  @spec install_local_desk!() :: :ok
  def install_local_desk! do
    ensure_countries!()
    ensure_places!()
    profile = ensure_profile!()

    if local_desk?() and profile.citizenships == "" and profile.field == "" do
      profile |> Profile.changeset(@local_desk) |> Repo.update!()
    end

    :ok
  end

  # The first account is the local desk (`Accounts.use_default!/0`). Its
  # passports are seed data. Every later account keeps a blank holder and
  # scores the same cities against whatever it stores.
  defp local_desk? do
    mine = Repo.account_id()

    first =
      Repo.one(from(a in Account, select: a.id, order_by: a.id, limit: 1), skip_account: true)

    mine != nil and mine == first
  end

  @doc "True once this account has the chart and a holder written on it."
  @spec installed?() :: boolean()
  def installed? do
    Repo.aggregate(Place, :count) > 0 and
      Repo.aggregate(Country, :count) > 0 and
      Repo.exists?(from(p in Place, where: not is_nil(p.energy))) and
      match?(%Profile{citizenships: c, field: f} when c != "" or f != "", Repo.one(Profile))
  end

  @spec set_weights(weights() | map()) :: {:ok, Profile.t()} | {:error, term()}
  def set_weights(weights) when is_map(weights) do
    attrs = %{
      weight_qol: Map.get(weights, :qol),
      weight_afford: Map.get(weights, :afford),
      weight_lang: Map.get(weights, :lang),
      weight_route: Map.get(weights, :route),
      weight_tech: Map.get(weights, :tech),
      weight_ease: Map.get(weights, :ease),
      weight_energy: Map.get(weights, :energy)
    }

    ensure_profile!() |> Profile.changeset(attrs) |> Repo.update()
  end

  @spec weights(Profile.t()) :: weights()
  def weights(%Profile{} = profile) do
    %{
      qol: profile.weight_qol,
      afford: profile.weight_afford,
      lang: profile.weight_lang,
      route: profile.weight_route,
      tech: profile.weight_tech,
      ease: profile.weight_ease,
      energy: profile.weight_energy
    }
  end

  @doc "EU average primary energy use per person, in kWh a year."
  @spec eu_energy() :: pos_integer()
  def eu_energy, do: @eu_energy

  @doc """
  Energy use scored from 0 to 1 across 8,000 to 160,000 kWh per person.
  `:more` treats higher use as a better fit. `:less` reverses it.
  """
  @spec energy_score(number(), :more | :less) :: float()
  def energy_score(kwh, direction \\ :more) when direction in [:more, :less] do
    norm =
      ((:math.log10(kwh) - @energy_floor) / (@energy_ceil - @energy_floor))
      |> max(0.0)
      |> min(1.0)

    if direction == :less, do: 1.0 - norm, else: norm
  end

  @spec passport_line(Profile.t()) :: String.t()
  def passport_line(%Profile{} = profile) do
    codes = split(profile.citizenships)

    if codes == [] do
      "none on file"
    else
      {eu, rest} = Enum.split_with(codes, &eu_code?/1)

      [eu_part(eu) | rest]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" + ")
    end
  end

  @spec language_line(Profile.t()) :: String.t()
  def language_line(%Profile{} = profile) do
    case split(profile.languages) do
      [] -> "none on file"
      codes -> Enum.map_join(codes, " · ", &String.upcase/1)
    end
  end

  @spec language_filter_label(Profile.t()) :: String.t()
  def language_filter_label(%Profile{} = profile) do
    case split(profile.languages) do
      [] ->
        "A language on file"

      [one] ->
        "#{String.upcase(one)} is enough"

      codes ->
        {lead, [last]} = Enum.split(codes, -1)
        "#{Enum.map_join(lead, ", ", &String.upcase/1)} or #{String.upcase(last)} is enough"
    end
  end

  @spec sweet_label(Profile.t()) :: String.t()
  def sweet_label(%Profile{} = profile) do
    tag =
      case split(profile.languages) do
        [] -> "a language on file"
        codes -> Enum.map_join(codes, "/", &String.upcase/1)
      end

    "Free + #{tag} + real tech"
  end

  @doc "Right to live for this holder. Home beats the country's legal class."
  @spec route(Place.t(), Profile.t()) :: reading()
  def route(%Place{} = place, %Profile{} = profile) do
    cond do
      home?(place, profile) ->
        pack(:home, "Your own country", "Home", "good", 1.0, home_text(place))

      place.mobility == :eu and eu?(profile) ->
        pack(:eu, "EU free movement", "Free", "good", 1.0, eu_text(profile))

      place.mobility == :eea and eea?(profile) ->
        pack(:eea, "EEA free movement", "Free", "good", 1.0, eea_text(profile))

      place.mobility == :ch and eu?(profile) ->
        pack(:ch, "Swiss free-movement agreement", "Contract", "warn", 0.8, ch_text())

      place.mobility == :uk and youth?(profile) ->
        pack(:uk, uk_label(profile), "Visa", "warn", 0.6, uk_text(profile))

      true ->
        pack(:permit, "Residence permit", "Permit", "bad", 0.3, permit_text(place))
    end
  end

  @doc "How well the local language fits the languages on the profile."
  @spec language(Place.t(), Profile.t()) :: reading()
  def language(%Place{} = place, %Profile{} = profile) do
    key = place.language
    spoken = spoken(profile)
    home = home_languages(profile)
    {score, text} = lang_score(key, spoken, home)

    tone =
      cond do
        score >= 0.75 -> "good"
        score >= 0.4 -> "warn"
        true -> "bad"
      end

    label = if key == :en, do: "English works", else: Map.fetch!(@lang_names, key)
    pack(key, label, label, tone, score, text)
  end

  @spec parts(Place.t(), Profile.t(), :more | :less) :: %{atom() => float()}
  def parts(%Place{} = place, %Profile{} = profile, direction \\ :more) do
    %{
      energy: energy_score(place.energy, direction),
      qol: place.qol / 100,
      afford: afford(place.cost),
      lang: language(place, profile).score,
      route: route(place, profile).score,
      tech: (place.tech - 1) / 2,
      ease: (place.ease - 1) / 2
    }
  end

  @spec fit(%{atom() => float()}, weights() | map()) :: float()
  def fit(parts, weights) do
    {sum, total} =
      Enum.reduce(@axes, {0.0, 0.0}, fn axis, {sum, total} ->
        w = Map.get(weights, axis, 0) * 1.0
        {sum + w * Map.fetch!(parts, axis), total + w}
      end)

    if total == 0.0, do: 0.0, else: 100 * sum / total
  end

  @spec tech_text(1..3) :: String.t()
  def tech_text(1), do: "Small tech market; mostly remote work from here."
  def tech_text(2), do: "Solid tech scene with real local employers."
  def tech_text(3), do: "Major European tech and AI hub."

  @spec ease_text(1..3) :: String.t()
  def ease_text(1),
    do:
      "Expect several in-person appointments (registration, tax ID, sometimes police or bank visits)."

  def ease_text(2), do: "One or two in-person visits; the rest is online or by letter."
  def ease_text(3), do: "Mostly online, or a single office visit."

  @spec lede(Profile.t(), non_neg_integer()) :: String.t()
  def lede(%Profile{} = profile, count) do
    field = if profile.field == "", do: "", else: ", field #{profile.field}"

    "#{count} European cities from the livability chart, scored for the passports " <>
      "(#{passport_line(profile)}) and languages (#{language_line(profile)}) stored on this desk#{field}. " <>
      "Every panel is linked: pick a city anywhere and it lights up everywhere."
  end

  defp ensure_countries! do
    existing = Map.new(Repo.all(Country), &{&1.name, &1})

    Enum.each(Catalog.countries(), fn row ->
      case Map.get(existing, row.name) do
        nil ->
          %Country{} |> Country.changeset(row) |> Repo.insert!()

        %Country{} = country ->
          country
          |> Country.changeset(%{energy: row.energy, energy_year: row.energy_year})
          |> Repo.update!()
      end
    end)
  end

  defp ensure_places! do
    existing = Map.new(Repo.all(Place), &{&1.name, &1})

    Enum.each(Catalog.places(), fn row ->
      case Map.get(existing, row.name) do
        nil ->
          %Place{} |> Place.changeset(row) |> Repo.insert!()

        %Place{} = place ->
          place
          |> Place.changeset(%{energy: row.energy, energy_year: row.energy_year})
          |> Repo.update!()
      end
    end)
  end

  defp ensure_profile! do
    Repo.one(from(p in Profile, limit: 1)) ||
      %Profile{} |> Profile.changeset(%{}) |> Repo.insert!()
  end

  defp pack(key, label, short, tone, score, text) do
    %{key: key, label: label, short: short, tone: tone, score: score, text: text}
  end

  defp afford(cost) do
    ((175 - cost) / 125) |> max(0) |> min(1)
  end

  defp split(nil), do: []
  defp split(""), do: []
  defp split(text), do: text |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp known(code), do: Map.get(@countries, code)

  defp eu_code?(code) do
    case known(code) do
      %{eu: true} -> true
      _ -> false
    end
  end

  defp eu?(profile), do: Enum.any?(split(profile.citizenships), &eu_code?/1)

  defp eea?(profile) do
    Enum.any?(split(profile.citizenships), fn code ->
      case known(code) do
        %{eu: true} -> true
        %{eea: true} -> true
        _ -> false
      end
    end)
  end

  defp youth?(profile) do
    Enum.any?(split(profile.citizenships), fn code ->
      match?(%{youth: true}, known(code))
    end)
  end

  defp home?(place, profile) do
    country = String.downcase(place.country)

    Enum.any?(split(profile.citizenships), fn code ->
      case known(code) do
        %{name: name} -> String.downcase(name) == country
        _ -> false
      end
    end)
  end

  defp spoken(profile) do
    profile.languages
    |> split()
    |> Enum.flat_map(fn
      "fr" -> [:fr]
      "en" -> [:en]
      "de" -> [:de]
      "ro" -> [:ro]
      _ -> []
    end)
  end

  defp home_languages(profile) do
    profile.citizenships
    |> split()
    |> Enum.flat_map(fn code ->
      case known(code) do
        %{lang: lang} when lang in [:fr, :en, :de, :ro] -> [lang]
        _ -> []
      end
    end)
  end

  defp lang_score(key, spoken, home) do
    name = Map.fetch!(@lang_names, key)

    cond do
      key in spoken and key == :en ->
        {0.95, "English is widely spoken and common at work, especially in tech."}

      key in spoken and key in [:fr, :de, :ro] ->
        {1.0, spoken_text(key)}

      key in home ->
        {0.75, "Your #{name} covers daily life; English is common in tech."}

      key == :de ->
        {0.4, "Tech jobs often run in English, but daily life and paperwork are in German."}

      key == :en ->
        {0.3, "English is common here, and it is not a language stored for this desk."}

      key == :fr ->
        {0.3, "French is the local language, and it is not one stored for this desk."}

      true ->
        {0.3, "Expect to need the local language for paperwork and much of daily life."}
    end
  end

  defp spoken_text(:fr), do: "French is an everyday language here. You're fully at home."

  defp spoken_text(:de),
    do: "German is a language stored for this desk. Daily life and paperwork can run in it."

  defp spoken_text(:ro), do: "Romanian is a language stored for this desk."

  defp home_text(place), do: "You're a citizen of #{place.country}. Nothing to apply for."

  defp eu_text(profile) do
    case eu_adjectives(profile) do
      [one] ->
        "Move with your #{one} passport. Register locally within about three months; no visa or permit."

      many ->
        "Move with your EU passports (#{Enum.join(many, ", ")}). " <>
          "Register locally within about three months; no visa or permit."
    end
  end

  defp eea_text(profile) do
    if eu?(profile) do
      "Outside the EU but in the EEA, so your EU passport works the same way: register locally, no permit."
    else
      adj =
        profile
        |> adjectives(fn code -> match?(%{eea: true, eu: false}, known(code)) end)
        |> List.first() || "EEA"

      "Your #{adj} passport is EEA free movement: register locally, no permit."
    end
  end

  defp ch_text do
    "EU citizens may enter and look for work without a permit. A Swiss job contract of a year or more " <>
      "gets a B permit valid for five years, applied for alongside the employer. Self-employment also " <>
      "qualifies if you can show a real, viable business. Register in person at the commune within 14 days of arriving."
  end

  defp uk_text(profile) do
    people = youth_people(profile)

    body =
      "#{people} aged 18 to 35 can apply for the Youth Mobility Scheme: up to three years, no sponsor or " <>
        "job offer, employment or limited self-employment allowed. Costs are an application fee, the health " <>
        "surcharge paid up front, and proof of about £2,500 in savings. Staying longer needs a sponsored work visa."

    if eu?(profile), do: "The EU passport gives no right to live here. " <> body, else: body
  end

  defp uk_label(profile) do
    adjectives = youth_adjectives(profile)

    case adjectives do
      [one] -> "UK Youth Mobility (#{one} passport)"
      many -> "UK Youth Mobility (#{Enum.join(many, ", ")} passports)"
    end
  end

  defp permit_text(%Place{mobility: mobility}) when mobility in [:eu, :eea] do
    bloc = if mobility == :eu, do: "EU", else: "EEA"

    "This country is in the #{bloc}. None of the passports on file grant free movement here, " <>
      "so living here means a national residence permit."
  end

  defp permit_text(%Place{mobility: :ch}) do
    "No Swiss free-movement agreement from the passports on file. A national permit is the path in."
  end

  defp permit_text(%Place{mobility: :uk}) do
    "No Youth Mobility passport is on file. A sponsored work visa is the path in."
  end

  defp permit_text(%Place{}) do
    "Visa-free visits, but living there means a national residence permit, usually with in-person steps."
  end

  defp eu_part([]), do: nil
  defp eu_part(codes), do: "EU (#{Enum.join(codes, ", ")})"

  defp eu_adjectives(profile), do: adjectives(profile, &eu_code?/1)

  defp youth_adjectives(profile) do
    adjectives(profile, fn code -> match?(%{youth: true}, known(code)) end)
  end

  defp youth_people(profile) do
    people = split_people(profile, fn country -> country.youth end)

    case people do
      [one] -> one
      [a, b] -> "#{a} or #{b}"
      many -> "#{Enum.join(Enum.drop(many, -1), ", ")} or #{List.last(many)}"
    end
  end

  defp adjectives(profile, pred) do
    profile.citizenships
    |> split()
    |> Enum.filter(pred)
    |> Enum.map(fn code -> known(code).adjective end)
  end

  defp split_people(profile, pred) do
    profile.citizenships
    |> split()
    |> Enum.flat_map(fn code ->
      case known(code) do
        nil -> []
        country -> if pred.(country), do: [country.people], else: []
      end
    end)
  end
end
