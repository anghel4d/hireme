defmodule Hireme.Schema do
  @moduledoc """
  What every row module shares: Ecto schema and changeset imports, UTC
  timestamps, and a `t()`.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      @timestamps_opts [type: :utc_datetime]
      @type t :: %__MODULE__{}
    end
  end
end

defmodule Hireme.Closed do
  @moduledoc """
  A closed set of atoms and the one way a name from the wire becomes a
  member. `parse/2` accepts the atom itself or its name and refuses
  everything else; `names/1` is the inverse for schemas and option lists.
  """

  @spec parse([atom()], term()) :: {:ok, atom()} | :error
  def parse(set, value) when is_atom(value) and not is_nil(value) do
    if value in set, do: {:ok, value}, else: :error
  end

  def parse(set, name) when is_binary(name) do
    Enum.find_value(set, :error, fn atom -> if Atom.to_string(atom) == name, do: {:ok, atom} end)
  end

  def parse(_set, _value), do: :error

  @doc "Parse, falling back to `default` for nil or empty, and to `:error` otherwise."
  @spec parse([atom()], term(), atom()) :: {:ok, atom()} | :error
  def parse(set, value, default) when value in [nil, ""], do: parse(set, default)
  def parse(set, value, _default), do: parse(set, value)

  @spec names([atom()]) :: [String.t()]
  def names(set), do: Enum.map(set, &Atom.to_string/1)
end

defmodule Hireme.Attrs do
  @moduledoc """
  Reading a loose map once. Keys may be atoms or strings; values come
  back trimmed, typed, or defaulted. Nothing here raises.
  """

  @spec get(map(), atom()) :: term()
  def get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  @spec string(map(), atom(), String.t()) :: String.t()
  def string(map, key, default \\ "") do
    case get(map, key) do
      s when is_binary(s) -> String.trim(s)
      _ -> default
    end
  end

  @spec int(map(), atom(), integer() | nil) :: integer() | nil
  def int(map, key, default \\ nil) do
    case get(map, key) do
      n when is_integer(n) ->
        n

      f when is_float(f) ->
        round(f)

      s when is_binary(s) ->
        with({n, ""} <- Integer.parse(String.trim(s)), do: n, else: (_ -> default))

      _ ->
        default
    end
  end

  @spec date(map(), atom(), Date.t() | nil) :: Date.t() | nil
  def date(map, key, default \\ nil) do
    case get(map, key) do
      %Date{} = d ->
        d

      s when is_binary(s) ->
        with({:ok, d} <- Date.from_iso8601(String.trim(s)), do: d, else: (_ -> default))

      _ ->
        default
    end
  end

  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(s) when is_binary(s), do: String.trim(s) == ""
  def blank?(_), do: false
end
