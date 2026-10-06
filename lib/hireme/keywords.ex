defmodule Hireme.Keywords.Coverage do
  @moduledoc """
  Which target words the visible CV hits.
  """

  @enforce_keys [:hits, :misses]
  defstruct hits: [], misses: []

  @type t :: %__MODULE__{hits: [String.t()], misses: [String.t()]}

  @spec hit(t()) :: non_neg_integer()
  def hit(%__MODULE__{hits: hits}), do: length(hits)

  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{hits: hits, misses: misses}), do: length(hits) + length(misses)

  @spec percent(t()) :: 0..100
  def percent(%__MODULE__{} = coverage) do
    case total(coverage) do
      0 -> 0
      total -> round(hit(coverage) / total * 100)
    end
  end
end

defmodule Hireme.Keywords do
  @moduledoc """
  Coverage of a listing's target words against the CV a reader would see.

  Hidden lines do not count. Matching is a whole term, so `ecs` does not
  hit inside `specs`.
  """

  alias Hireme.Keywords.Coverage
  alias Hireme.Mask.Line
  alias Hireme.Theme

  @stop ~w(
    about after also and any are because been being both from have here
    into just more most only onto our over role such team that the their
    them then there these they this those very what when where which will
    with work would your you our for the and
  )

  @doc """
  The theme's targets when it names any, else the listing's own words.
  """
  @spec targets(Theme.t(), String.t() | nil) :: [String.t()]
  def targets(%Theme{targets: [_ | _] = targets}, _listing), do: targets
  def targets(%Theme{}, listing), do: extract(listing || "")

  @spec extract(String.t()) :: [String.t()]
  def extract(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9+#.]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 4 or &1 in @stop))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {word, count} -> {-count, word} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(10)
  end

  @spec coverage([String.t()], [Line.t()]) :: Coverage.t()
  def coverage(targets, resolved) when is_list(targets) do
    text = visible_text(resolved)
    {hits, misses} = Enum.split_with(targets, fn term -> hit?(text, term) end)
    %Coverage{hits: hits, misses: misses}
  end

  @spec visible_text([Line.t()]) :: String.t()
  def visible_text(resolved) do
    resolved
    |> Enum.filter(& &1.shown)
    |> Enum.map_join("\n", fn line -> "#{line.title}\n#{line.body}" end)
    |> String.downcase()
  end

  @spec hit?(String.t(), String.t()) :: boolean()
  def hit?(text, term) do
    escaped = Regex.escape(String.downcase(term))
    Regex.match?(~r/(^|[^a-z0-9])#{escaped}([^a-z0-9]|$)/u, text)
  end
end
