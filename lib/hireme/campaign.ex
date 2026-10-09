defmodule Hireme.Variety do
  @moduledoc """
  A day pack is 55 apps that are not 55 copies of one role.

  Flags are non-binding. An empty batch is `:unfilled`. A short pack is
  `:short`. A pack of twenty or more with a narrow mix picks up
  `:few_companies`, `:few_locations`, or `:few_fits`.

  The batch row stores the summary as JSON. `to_map/1` and `from_map/1`
  are the inverse pair for that column.
  """

  alias Hireme.Closed

  @flags [:unfilled, :short, :few_companies, :few_locations, :few_fits]
  @counts [:apps, :companies, :roles, :locations, :fits]
  @narrow [{:few_companies, :company, 8}, {:few_locations, :location, 3}, {:few_fits, :fit, 3}]

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

  @spec summarize([app()], pos_integer()) :: t()
  def summarize(apps, target \\ 55) when is_list(apps) do
    n = length(apps)

    size =
      cond do
        n == 0 -> [:unfilled]
        n < target -> [:short]
        true -> []
      end

    mix = for {flag, key, floor} <- @narrow, n >= 20 and uniq(apps, key) < floor, do: flag

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
    @counts
    |> Map.new(&{Atom.to_string(&1), Map.fetch!(variety, &1)})
    |> Map.put("flags", Enum.map(variety.flags, &Atom.to_string/1))
  end

  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}
  def from_map(%__MODULE__{} = variety), do: variety

  def from_map(map) when is_map(map) do
    flags =
      Enum.flat_map(List.wrap(map["flags"]), fn flag ->
        case Closed.parse(@flags, flag) do
          {:ok, known} -> [known]
          :error -> []
        end
      end)

    counts = Map.new(@counts, &{&1, count(map[Atom.to_string(&1)])})
    struct!(__MODULE__, Map.put(counts, :flags, flags))
  end

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
