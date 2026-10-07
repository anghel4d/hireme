defmodule Hireme.Theme do
  @moduledoc """
  How one CV reads: the lead line, its reason, the accent, the density,
  and the words the listing is measured against.

  The database keeps a theme as a JSON object. `parse/1` turns that
  object, with string or atom keys, into this struct once. Everything
  after that reads fields. `to_map/1` is the inverse for storage.
  """

  @accents [:ink, :signal, :paper]
  @densities [:cv, :tight, :narrative]

  @type accent :: :ink | :signal | :paper
  @type density :: :cv | :tight | :narrative

  defstruct lead: nil, lead_reason: nil, accent: :ink, density: :cv, targets: []

  @type t :: %__MODULE__{
          lead: String.t() | nil,
          lead_reason: String.t() | nil,
          accent: accent(),
          density: density(),
          targets: [String.t()]
        }

  @spec accents() :: [accent()]
  def accents, do: @accents

  @spec densities() :: [density()]
  def densities, do: @densities

  @spec parse(map() | nil) :: t()
  def parse(nil), do: %__MODULE__{}
  def parse(%__MODULE__{} = theme), do: theme

  def parse(map) when is_map(map) do
    %__MODULE__{
      lead: text(fetch(map, :lead)),
      lead_reason: text(fetch(map, :lead_reason)),
      accent: choice(fetch(map, :accent), @accents, :ink),
      density: choice(fetch(map, :density), @densities, :cv),
      targets: words(fetch(map, :targets))
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = theme) do
    %{}
    |> put_text("lead", theme.lead)
    |> put_text("lead_reason", theme.lead_reason)
    |> Map.put("accent", Atom.to_string(theme.accent))
    |> Map.put("density", Atom.to_string(theme.density))
    |> put_list("targets", theme.targets)
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = theme), do: theme == %__MODULE__{}

  defp fetch(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_), do: nil

  defp choice(value, allowed, default) do
    Enum.find(allowed, default, fn atom -> Atom.to_string(atom) == value or atom == value end)
  end

  defp words(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp words(_), do: []

  defp put_text(map, _key, nil), do: map
  defp put_text(map, key, value), do: Map.put(map, key, value)

  defp put_list(map, _key, []), do: map
  defp put_list(map, key, list), do: Map.put(map, key, list)
end
