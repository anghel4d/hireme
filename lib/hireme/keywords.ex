defmodule Hireme.Keywords do
  @moduledoc """
  Coverage of a listing's target words against the CV a reader would see.

  Hidden lines do not count. Matching is a whole term, so `ecs` does not
  hit inside `specs`.
  """

  @stop ~w(
    about after also and any are because been being both from have here
    into just more most only onto our over role such team that the their
    them then there these they this those very what when where which will
    with work would your you our for the and
  )

  def targets(%{theme: theme}, listing) when is_map(theme) do
    case Map.get(theme, "targets") || Map.get(theme, :targets) do
      list when is_list(list) and list != [] ->
        list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        extract(listing || "")
    end
  end

  def targets(_, listing), do: extract(listing || "")

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

  def coverage(targets, resolved) when is_list(targets) do
    text = visible_text(resolved)

    {hits, misses} =
      Enum.split_with(targets, fn term -> hit?(text, term) end)

    %{
      hits: hits,
      misses: misses,
      hit: length(hits),
      total: length(targets)
    }
  end

  def visible_text(resolved) do
    resolved
    |> Enum.filter(& &1.shown)
    |> Enum.map(fn line -> "#{line.title}\n#{line.body}" end)
    |> Enum.join("\n")
    |> String.downcase()
  end

  def hit?(text, term) do
    escaped = Regex.escape(String.downcase(term))
    Regex.match?(~r/(^|[^a-z0-9])#{escaped}([^a-z0-9]|$)/u, text)
  end
end
