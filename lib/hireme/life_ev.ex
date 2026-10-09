defmodule Hireme.LifeEv.Chart do
  @moduledoc """
  Histogram and band counts for a list of score_100 values.
  """

  @enforce_keys [:n, :mean, :max, :min, :bands, :bins]
  defstruct @enforce_keys

  @type band_row :: %{
          key: Hireme.LifeEv.band(),
          label: String.t(),
          min: 0..100,
          max: 0..100,
          count: non_neg_integer(),
          share: float()
        }

  @type bin :: %{lo: 0..100, hi: 0..100, count: non_neg_integer()}

  @type t :: %__MODULE__{
          n: non_neg_integer(),
          mean: float() | nil,
          max: 0..100 | nil,
          min: 0..100 | nil,
          bands: [band_row()],
          bins: [bin()]
        }
end

defmodule Hireme.LifeEv do
  @moduledoc """
  Life-EV score_100. Closed bands, one parse at the edge.

  Anchors live in `alchemy/score-ladder.md`. Named employers win;
  heuristics only move unanchored seats down the ladder. A hard kill
  cannot be raised.
  """

  alias Hireme.LifeEv.Chart
  alias Hireme.Text

  @type score :: 0..100
  @type band :: :frontier | :labs | :big_tech | :systems | :craft | :mid | :thin | :kill

  @typedoc """
  A company name or raw fields with atom or string keys. Text scores are
  parsed, integers are clamped, and missing or malformed fields use defaults.
  Unrelated fields are ignored.
  """
  @type input :: String.t() | map()

  @bands [
    %{key: :frontier, min: 100, max: 100, label: "Frontier"},
    %{key: :labs, min: 90, max: 99, label: "Tier-2 labs"},
    %{key: :big_tech, min: 85, max: 89, label: "Big tech"},
    %{key: :systems, min: 70, max: 84, label: "Systems"},
    %{key: :craft, min: 55, max: 69, label: "Craft"},
    %{key: :mid, min: 40, max: 54, label: "Mid"},
    %{key: :thin, min: 20, max: 39, label: "Thin"},
    %{key: :kill, min: 0, max: 19, label: "Kill"}
  ]

  @keys Enum.map(@bands, & &1.key)
  @by_key Map.new(@bands, &{&1.key, &1})

  @frontier ~w(openai anthropic spacex neuralink xai spacexai)
  @labs ~w(starfish valve gdm deepmind meta fair ssi mira)
  @labs_phrases ["google deepmind", "thinking machines", "safe superintelligence", "meta fair"]
  @big_tech ~w(google alphabet apple microsoft amazon nvidia netflix uber stripe databricks snowflake tesla adobe salesforce oracle linkedin snap pinterest shopify)

  @spec bands() :: [map()]
  def bands, do: @bands

  @spec keys() :: [band()]
  def keys, do: @keys

  @spec name(band()) :: String.t()
  def name(band) when band in @keys, do: Atom.to_string(band)

  @spec label(band()) :: String.t()
  def label(band) when band in @keys, do: @by_key[band].label

  @spec parse_band(term()) :: {:ok, band() | :all} | :error
  def parse_band(band), do: Hireme.Closed.parse([:all | @keys], band)

  @spec band(score()) :: band()
  def band(score) when is_integer(score) and score >= 0 and score <= 100 do
    Enum.find(@bands, fn row -> score >= row.min and score <= row.max end).key
  end

  @spec clamp(integer()) :: score()
  def clamp(n) when is_integer(n), do: min(max(n, 0), 100)

  @spec score(input()) :: score()
  def score(company) when is_binary(company), do: score(%{company: company})

  def score(input) when is_map(input) do
    case explicit(input) do
      {:ok, n} ->
        n

      :none ->
        company = string(input, :company)
        role = string(input, :role)
        fit = string(input, :fit)
        location = string(input, :location)
        blob = "#{company} #{role} #{fit} #{location}"
        high_comp? = high_comp?(Map.get(input, :comp) || Map.get(input, "comp"))

        cond do
          kill = kill_score(blob, location) -> kill
          anchor = named_score(company, high_comp?) -> anchor
          true -> heuristic(company, role, fit, location, high_comp?)
        end
    end
  end

  @doc """
  Count raw scores or rows with an atom or string `score_100` key.
  Integers are clamped to 0..100; unrecognized rows contribute a zero.
  """
  @spec chart([term()]) :: Chart.t()
  def chart(rows) when is_list(rows) do
    # The input can be large; every subsequent pass is bounded by 101 scores.
    frequencies = Enum.frequencies_by(rows, &chart_score/1)
    scores = Map.keys(frequencies)

    {n, total} =
      Enum.reduce(frequencies, {0, 0}, fn {score, count}, {n, total} ->
        {n + count, total + score * count}
      end)

    %Chart{
      n: n,
      mean: if(n == 0, do: nil, else: Float.round(total / n, 1)),
      max: Enum.max(scores, fn -> nil end),
      min: Enum.min(scores, fn -> nil end),
      bands: band_rows(frequencies, n),
      bins: bin_rows(frequencies)
    }
  end

  @spec ascii(Chart.t()) :: String.t()
  def ascii(%Chart{} = chart) do
    width = 24
    peak = chart.bins |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end)

    bins =
      Enum.map_join(chart.bins, "\n", fn bin ->
        bar = String.duplicate("█", round(bin.count / max(peak, 1) * width))
        "#{pad(bin.lo)}–#{pad(bin.hi)} #{String.pad_trailing(bar, width)} #{bin.count}"
      end)

    bands =
      Enum.map_join(chart.bands, "\n", fn row ->
        "#{String.pad_trailing(row.label, 14)} #{pad(row.count)}  #{row.min}–#{row.max}"
      end)

    mean = if chart.mean, do: :erlang.float_to_binary(chart.mean, decimals: 1), else: "—"
    "n=#{chart.n} mean=#{mean} max=#{chart.max || "—"} min=#{chart.min || "—"}\n#{bands}\n#{bins}"
  end

  defp chart_score(n) when is_integer(n), do: clamp(n)
  defp chart_score(%{score_100: n}) when is_integer(n), do: clamp(n)
  defp chart_score(%{"score_100" => n}) when is_integer(n), do: clamp(n)
  defp chart_score(_), do: 0

  defp group_counts(frequencies, key) do
    Enum.reduce(frequencies, %{}, fn {score, count}, acc ->
      Map.update(acc, key.(score), count, &(&1 + count))
    end)
  end

  defp band_rows(frequencies, n) do
    counts = group_counts(frequencies, &band/1)

    Enum.map(@bands, fn row ->
      count = Map.get(counts, row.key, 0)

      Map.merge(row, %{count: count, share: if(n == 0, do: 0.0, else: Float.round(count / n, 3))})
    end)
  end

  defp bin_rows(frequencies) do
    grouped = group_counts(frequencies, &bin_lo/1)

    Enum.map(0..9, fn i ->
      lo = i * 10
      hi = if i == 9, do: 100, else: lo + 9
      %{lo: lo, hi: hi, count: Map.get(grouped, lo, 0)}
    end)
  end

  defp bin_lo(100), do: 90
  defp bin_lo(n), do: div(n, 10) * 10

  defp explicit(input) do
    case Map.get(input, :score_100) || Map.get(input, "score_100") || Map.get(input, :score) ||
           Map.get(input, "score") do
      n when is_integer(n) -> {:ok, clamp(n)}
      s when is_binary(s) -> parse_explicit(s)
      _ -> :none
    end
  end

  defp parse_explicit(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> {:ok, clamp(n)}
      :error -> :none
    end
  end

  defp named_score(company, high_comp?) do
    name = Text.normalize(company)

    cond do
      Text.named_normalized?(name, @frontier) -> 100
      Text.named_normalized?(name, @labs) or Text.phrase_normalized?(name, @labs_phrases) -> 90
      Text.named_normalized?(name, @big_tech) -> if(high_comp?, do: 85, else: 80)
      true -> nil
    end
  end

  defp heuristic(company, role, fit, location, high_comp?) do
    text = "#{company} #{role} #{fit}"
    score = 48
    score = if systems?(text), do: score + 22, else: score
    score = if agentic?(text), do: score + 10, else: score
    score = if low_level?(text), do: score + 8, else: score
    score = if canada_remote?(location), do: score + 5, else: score
    score = if high_comp?, do: score + 6, else: score
    score = if mid_curve?(text), do: score - 16, else: score
    # Named labs/frontier are anchors. Heuristics never climb onto those rungs.
    clamp(min(score, 84))
  end

  defp kill_score(blob, location) do
    cond do
      staffing?(blob) -> 8
      intern?(blob) -> 12
      theater?(blob) -> 10
      dressed_as_eng?(blob) or onsite_lock?(location) -> 15
      true -> nil
    end
  end

  defp staffing?(blob), do: blob =~ ~r/\b(staffing|body\s*shop|recruit)/i
  defp intern?(blob), do: blob =~ ~r/\b(intern(ship)?|new\s*grad|co-?op)\b/i
  defp theater?(blob), do: blob =~ ~r/\b(prompt(\s|-)?only|ai theater|chatgpt wrapper)\b/i

  defp dressed_as_eng?(blob) do
    blob =~
      ~r/\b(sales engineer|sales-eng|business analyst|\bba\b|project manager|\bpm\b|support engineer)\b/i
  end

  defp onsite_lock?(location) do
    loc = String.downcase(location)

    loc != "" and loc =~ ~r/\bonsite|on-site|in[- ]office\b/ and
      loc =~ ~r/\bno remote|not remote|onsite only/ and
      not canada_remote?(location)
  end

  defp systems?(text), do: text =~ ~r/\b(systems|runtime|kernel|infra|distributed|compiler)\b/i
  defp agentic?(text), do: text =~ ~r/\b(agentic|agent systems|agents)\b/i
  defp low_level?(text), do: text =~ ~r/\b(rust|c\+\+|low-?level|systems c)\b/i
  defp mid_curve?(text), do: text =~ ~r/\b(crud|full[- ]stack|rails shop|wordpress)\b/i

  defp canada_remote?(location) do
    loc = String.downcase(location)
    loc =~ ~r/\b(canada|canadian|montr[eé]al|toronto|vancouver|remote)\b/
  end

  defp high_comp?(nil), do: false
  defp high_comp?(n) when is_integer(n), do: n >= 200_000

  defp high_comp?(s) when is_binary(s) do
    digits = s |> String.replace(~r/[^\d.]/, "") |> String.trim()

    cond do
      s =~ ~r/\b(2\d{2}|[3-9]\d{2})\s*k\b/i ->
        true

      s =~ ~r/\$\s*2[0-9]{2}/ ->
        true

      digits == "" ->
        false

      true ->
        case Float.parse(digits) do
          {n, _} when n >= 200_000 -> true
          {n, _} when n >= 200 and n < 10_000 -> true
          _ -> false
        end
    end
  end

  defp high_comp?(_), do: false

  defp string(input, key) do
    case Map.get(input, key) || Map.get(input, Atom.to_string(key)) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp pad(n) when n < 10, do: "  #{n}"
  defp pad(n) when n < 100, do: " #{n}"
  defp pad(n), do: "#{n}"
end
