defmodule Hireme.Variety do
  @moduledoc """
  A day pack is 55 apps that are not 55 copies of one role.

  Flags are non-binding. An empty batch is `unfilled`. A short pack is
  `short`. A full pack with a narrow mix picks up `few_companies`,
  `few_locations`, or `few_fits`.
  """

  def summarize(apps, target \\ 55) when is_list(apps) do
    n = length(apps)

    flags =
      cond do
        n == 0 -> ["unfilled"]
        n < target -> ["short"]
        true -> []
      end

    flags =
      flags
      |> flag(n >= 20 and uniq(apps, :company) < 8, "few_companies")
      |> flag(n >= 20 and uniq(apps, :location) < 3, "few_locations")
      |> flag(n >= 20 and uniq(apps, :fit) < 3, "few_fits")

    %{
      "apps" => n,
      "companies" => uniq(apps, :company),
      "roles" => uniq(apps, :role),
      "locations" => uniq(apps, :location),
      "fits" => uniq(apps, :fit),
      "flags" => flags
    }
  end

  def label(%{"flags" => []}), do: "varied"
  def label(%{"flags" => flags}) when is_list(flags), do: Enum.join(flags, ", ")
  def label(_), do: "varied"

  defp flag(flags, true, name), do: flags ++ [name]
  defp flag(flags, false, _name), do: flags

  defp uniq(apps, key) do
    apps
    |> Enum.map(&(Map.get(&1, key) || Map.get(&1, Atom.to_string(key))))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> length()
  end
end
