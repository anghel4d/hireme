defmodule Hireme.Variety do
  @moduledoc """
  A day pack is 55 apps that are not 55 copies of one role.

  Flags are non-binding. An empty batch is `:unfilled`. A short pack is
  `:short`. A pack of twenty or more with a narrow mix picks up
  `:few_companies`, `:few_locations`, or `:few_fits`.

  The batch row stores the summary as JSON. `to_map/1` and `from_map/1`
  are the inverse pair for that column.
  """

  @flags [:unfilled, :short, :few_companies, :few_locations, :few_fits]

  @type flag :: :unfilled | :short | :few_companies | :few_locations | :few_fits

  defstruct apps: 0, companies: 0, roles: 0, locations: 0, fits: 0, flags: []

  @type t :: %__MODULE__{
          apps: non_neg_integer(),
          companies: non_neg_integer(),
          roles: non_neg_integer(),
          locations: non_neg_integer(),
          fits: non_neg_integer(),
          flags: [flag()]
        }

  @type app :: %{
          required(:company) => String.t() | nil,
          required(:role) => String.t() | nil,
          required(:location) => String.t() | nil,
          required(:fit) => String.t() | nil
        }

  @spec flags() :: [flag()]
  def flags, do: @flags

  @spec summarize([app()], pos_integer()) :: t()
  def summarize(apps, target \\ 55) when is_list(apps) do
    n = length(apps)

    size =
      cond do
        n == 0 -> [:unfilled]
        n < target -> [:short]
        true -> []
      end

    mix =
      [
        {n >= 20 and uniq(apps, :company) < 8, :few_companies},
        {n >= 20 and uniq(apps, :location) < 3, :few_locations},
        {n >= 20 and uniq(apps, :fit) < 3, :few_fits}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %__MODULE__{
      apps: n,
      companies: uniq(apps, :company),
      roles: uniq(apps, :role),
      locations: uniq(apps, :location),
      fits: uniq(apps, :fit),
      flags: size ++ mix
    }
  end

  @spec label(t()) :: String.t()
  def label(%__MODULE__{apps: 0}), do: "unfilled"
  def label(%__MODULE__{flags: []}), do: "varied"
  def label(%__MODULE__{flags: flags}), do: Enum.map_join(flags, ", ", &Atom.to_string/1)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = variety) do
    %{
      "apps" => variety.apps,
      "companies" => variety.companies,
      "roles" => variety.roles,
      "locations" => variety.locations,
      "fits" => variety.fits,
      "flags" => Enum.map(variety.flags, &Atom.to_string/1)
    }
  end

  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = variety), do: variety

  def from_map(map) when is_map(map) do
    %__MODULE__{
      apps: count(map["apps"]),
      companies: count(map["companies"]),
      roles: count(map["roles"]),
      locations: count(map["locations"]),
      fits: count(map["fits"]),
      flags: map["flags"] |> List.wrap() |> Enum.flat_map(&parse_flag/1)
    }
  end

  defp parse_flag(flag) when flag in @flags, do: [flag]

  defp parse_flag(name) when is_binary(name) do
    Enum.filter(@flags, &(Atom.to_string(&1) == name))
  end

  defp parse_flag(_), do: []

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  defp uniq(apps, key) do
    apps
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> length()
  end
end
