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
  everything else; `get/3` is the same read with a fallback; `names/1`
  is the inverse for schemas and option lists.
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

  @doc "The member `value` names, or `default` when it names none."
  @spec get([atom()], term(), atom()) :: atom()
  def get(set, value, default) do
    case parse(set, value) do
      {:ok, atom} -> atom
      :error -> default
    end
  end

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
        parse_int(String.trim(s), default)

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
        parse_date(String.trim(s), default)

      _ ->
        default
    end
  end

  defp parse_int(text, default) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_date(text, default) do
    case Date.from_iso8601(text) do
      {:ok, d} -> d
      _ -> default
    end
  end
end

defmodule Hireme.Form do
  @moduledoc """
  Reading a form once, refusing what it cannot read. Every reader
  answers `{:ok, value}` or `{:error, {:argument, name}}`; nothing
  raises. Unlike `Hireme.Attrs`, a form prefers a truthy string key
  over its atom key, so the two readers are not interchangeable.
  """

  alias Hireme.Closed

  defp get(attrs, name), do: Map.get(attrs, Atom.to_string(name)) || Map.get(attrs, name)

  def string(attrs, name) do
    case get(attrs, name) do
      s when is_binary(s) -> String.trim(s)
      _ -> ""
    end
  end

  def nonnegative(attrs, name) do
    case get(attrs, name) do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  # A member of `set` named by the form, `default` when the field is
  # blank, refused otherwise. A nil default makes the field required.
  def closed(attrs, name, set, default) do
    case get(attrs, name) do
      blank when blank in [nil, ""] ->
        if default, do: {:ok, default}, else: argument(name)

      value ->
        case Closed.parse(set, value) do
          {:ok, atom} -> {:ok, atom}
          :error -> argument(name)
        end
    end
  end

  # A date from the form, `default` when blank, refused when unreadable.
  def day(attrs, name, default) do
    case get(attrs, name) do
      blank when blank in [nil, ""] ->
        {:ok, default}

      %Date{} = date ->
        {:ok, date}

      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, date} -> {:ok, date}
          _ -> argument(name)
        end

      _ ->
        argument(name)
    end
  end

  def required(attrs, name) do
    case string(attrs, name) do
      "" -> argument(name)
      text -> {:ok, text}
    end
  end

  defp argument(name), do: {:error, {:argument, Atom.to_string(name)}}
end

defmodule Hireme.Text do
  @moduledoc """
  Names as comparable words: lowercased, punctuation folded to spaces.
  An anchor matches a whole name, its compacted form, or a whole word
  inside it, so "Google DeepMind" is named by `deepmind` and not by `go`.
  """

  @spec normalize(term()) :: String.t()
  def normalize(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  @doc "Match anchors against an already normalized name; normalize once before testing groups."
  @spec named_normalized?(String.t(), [String.t()]) :: boolean()
  def named_normalized?(name, anchors) do
    compact = String.replace(name, " ", "")
    padded = " #{name} "

    Enum.any?(anchors, fn anchor ->
      compact == String.replace(anchor, " ", "") or String.contains?(padded, " #{anchor} ")
    end)
  end

  @spec phrase_normalized?(String.t(), [String.t()]) :: boolean()
  def phrase_normalized?(name, phrases), do: Enum.any?(phrases, &String.contains?(name, &1))

  @doc "A lowercase, hyphenated key for a title."
  @spec slug(String.t()) :: String.t()
  def slug(text) do
    text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end
end
