defmodule Hireme.Schema.Load do
  @moduledoc false
  # `priv/schema.json`, as `native/schema` emits it, in the shapes every
  # reader of `Hireme.Schema.model/0` takes: atom keys, atoms for types and
  # residency, tuples for where terms and index columns.

  def model(json) do
    m = atoms(json)
    %{m | tables: Enum.map(m.tables, &table/1), commands: Enum.map(m.commands, &command/1)}
  end

  defp table(t) do
    %{
      t
      | residency: String.to_atom(t.residency),
        cols: Enum.map(t.cols, &typed/1),
        naturals: Enum.map(t.naturals, &key/1),
        uniques: Enum.map(t.uniques, &key/1),
        indexes: Enum.map(t.indexes, &index/1),
        source_term: term(t.source_term)
    }
  end

  defp key(k), do: %{k | where_term: term(k.where_term)}

  defp index(i),
    do: %{
      i
      | cols: Enum.map(i.cols, fn [c, desc] -> {c, desc} end),
        where_term: term(i.where_term)
    }

  defp command(c), do: %{c | params: Enum.map(c.params, &typed/1)}
  defp typed(c), do: %{c | type: String.to_atom(c.type)}

  defp term(nil), do: nil
  defp term(["eq", col, v]), do: {:eq, col, v}
  defp term(["null", col]), do: {:null, col}
  defp term(["not_null", col]), do: {:not_null, col}

  # Every key in the model is a known name; values (names, defaults) stay text.
  defp atoms(%{} = m), do: Map.new(m, fn {k, v} -> {String.to_atom(k), atoms(v)} end)
  defp atoms(l) when is_list(l), do: Enum.map(l, &atoms/1)
  defp atoms(v), do: v
end

defmodule Hireme.Schema do
  @moduledoc """
  The declaration, read at compile time from `priv/schema.json` (the
  resolved model `native/schema` emits; the schema compiler writes it at
  every build, before this module compiles):
  every table, column, enum, command, frame and refusal by name or id, the
  two hashes, and the row module of each stored table (`Hireme.Rows.*`).
  Recompiles when the file changes.
  """

  @json Path.expand("../../priv/schema.json", __DIR__)
  @external_resource @json
  @model @json |> File.read!() |> JSON.decode!() |> Hireme.Schema.Load.model()

  @tables @model.tables
  @by_name Map.new(@tables, &{&1.name, &1})
  @by_id Map.new(@tables, &{&1.id, &1})
  @commands @model.commands
  @command_by_name Map.new(@commands, &{&1.name, &1})
  @command_by_id Map.new(@commands, &{&1.id, &1})
  @enums Map.new(@model.enums, &{&1.name, &1})
  @refusals @enums["refusal"].values |> Enum.with_index() |> Map.new(fn {v, i} -> {v, i} end)
  @domains Map.new(@model.domains, &{&1.name, &1.bit})

  @doc "The whole resolved declaration."
  def model, do: @model

  def tables, do: @tables

  @doc """
  A natural or unique key as an interface states it: its columns, its
  condition as declared (`nil` when it has none) and the columns that
  condition reads (`[]` when none). A conditioned key names a row only
  when its condition holds, so a caller must give what it reads too.
  """
  def key_doc(%{cols: cols, where: where, where_term: term}),
    do: %{cols: cols, where: where, reads: if(term, do: [elem(term, 1)], else: [])}

  @doc "A table by name (string or atom) or id; nil when there is none."
  def table(id) when is_integer(id), do: Map.get(@by_id, id)
  def table(name) when is_atom(name), do: table(Atom.to_string(name))
  def table(name) when is_binary(name), do: Map.get(@by_name, name)

  @doc "A column of a table, by name or id; nil when either is unknown."
  def column(table, col) do
    case table(table) do
      nil -> nil
      t when is_integer(col) -> Enum.find(t.cols, &(&1.id == col))
      t -> Enum.find(t.cols, &(&1.name == to_string(col)))
    end
  end

  def commands, do: @commands

  @doc "A command by name or id, with its table's domain."
  def command(id) when is_integer(id), do: Map.get(@command_by_id, id) |> with_domain()
  def command(name) when is_atom(name), do: command(Atom.to_string(name))
  def command(name) when is_binary(name), do: Map.get(@command_by_name, name) |> with_domain()

  defp with_domain(nil), do: nil
  defp with_domain(c), do: Map.put(c, :domain, table(c.table).domain)

  @doc "An enum's values in code order, as atoms."
  def enum(name), do: Enum.map(enum_names(name), &String.to_atom/1)

  @doc "An enum's values in code order, as strings."
  def enum_names(name), do: Map.fetch!(@enums, to_string(name)).values

  @doc "The u16 NACK code of a refusal (atom or string)."
  def refusal(name), do: Map.fetch!(@refusals, to_string(name))

  @doc "The refusal a code names, as an atom; nil past the enum."
  def refusal_name(code), do: Enum.at(enum(:refusal), code)

  @doc "A domain's mask bit; `system` has none (0)."
  def domain_bit(name), do: Map.fetch!(@domains, to_string(name))

  @doc "Every domain's mask bit together: what a key granted everything holds."
  def domain_mask, do: @domains |> Map.values() |> Enum.reduce(0, &Bitwise.bor/2)

  def frames, do: @model.frames
  def wire_hash, do: @model.wire_hash

  @doc """
  The last day a `day` cell holds: 9999-12-31 as days since 0000-01-01. The
  Rust model declares it too (`DAY_MAX`, emitted into gen/schema.ts), and
  Hireme.SchemaTest holds the two equal.
  """
  def day_max, do: unquote(Date.to_gregorian_days(~D[9999-12-31]))
  def schema_rev, do: @model.schema_rev

  @doc "The row module of a stored table."
  def row(table), do: Module.concat(Hireme.Rows, singular(table(table).name))

  defp singular(name) do
    name =
      cond do
        String.ends_with?(name, "ies") ->
          String.replace_suffix(name, "ies", "y")

        String.ends_with?(name, ["ches", "shes", "xes", "sses"]) ->
          String.replace_suffix(name, "es", "")

        String.ends_with?(name, ["ss", "us", "as"]) ->
          name

        String.ends_with?(name, "s") ->
          String.replace_suffix(name, "s", "")

        true ->
          name
      end

    Macro.camelize(name)
  end

  @doc false
  def ecto_type(%{type: type} = col) do
    case type do
      t when t in [:id, :ref, :u8, :u32, :i64] -> :integer
      :bool -> :boolean
      :f64 -> :float
      :day -> :date
      :time -> :utc_datetime
      t when t in [:str, :text] -> :string
      :json -> Hireme.Schema.Json
      :bytes -> :binary
      :enum -> {Ecto.Enum, values: enum(col.target)}
    end
  end

  @doc """
  The type `Ecto.Type.cast/2` takes for a column or param: its Ecto type,
  with an enum initialized as the parameterized `Ecto.Enum` it is.
  """
  def cast_type(col) do
    case ecto_type(col) do
      {Ecto.Enum, opts} -> Ecto.ParameterizedType.init(Ecto.Enum, opts)
      type -> type
    end
  end

  @doc false
  def ecto_default(%{default: nil}), do: nil

  def ecto_default(%{default: value} = col) do
    case col.type do
      :bool -> value == "true"
      t when t in [:u8, :u32, :i64] -> String.to_integer(value)
      :f64 -> elem(Float.parse(value), 0)
      :enum -> String.to_atom(value)
      _ -> String.trim(value, "'")
    end
  end
end

defmodule Hireme.Schema.Json do
  @moduledoc """
  A `json` column: any JSON value (object, array, string, number, boolean),
  stored as its text; atom keys and values are written as their names and
  read back as strings. Ecto's `:map` takes objects only, and a JSON array in
  a `json` cell is as valid as an object.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(value), do: if(json?(value), do: {:ok, value}, else: :error)

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value), do: if(json?(value), do: {:ok, Jason.encode!(value)}, else: :error)

  @impl true
  def load(nil), do: {:ok, nil}

  def load(text) when is_binary(text), do: with({:error, _} <- Jason.decode(text), do: :error)
  def load(_), do: :error

  defp json?(v) when is_map(v),
    do: Enum.all?(v, fn {k, x} -> (is_binary(k) or is_atom(k)) and json?(x) end)

  defp json?(v) when is_list(v), do: Enum.all?(v, &json?/1)
  # An atom is written as its name, as Jason writes it.
  defp json?(v), do: is_binary(v) or is_number(v) or is_atom(v)
end

# One Ecto row module per stored table, generated from the declaration:
# `Hireme.Rows.Application` for `applications`, `Hireme.Rows.ApiKey` for
# `api_keys`. Domain checks are the kernel's and the sequencer's; a row
# module only maps the columns.
for table <- Hireme.Schema.tables(), table.residency in [:resident, :server] do
  fields =
    for col <- table.cols, col.name not in ~w(id inserted_at updated_at) do
      {type, type_opts} =
        case Hireme.Schema.ecto_type(col) do
          {Ecto.Enum, opts} -> {Ecto.Enum, opts}
          type -> {type, []}
        end

      opts =
        [default: Hireme.Schema.ecto_default(col)]
        |> Keyword.merge(if col.server_only, do: [redact: true], else: [])
        |> Enum.reject(fn {_, v} -> v == nil end)
        |> Keyword.merge(type_opts)

      quote do
        field unquote(String.to_atom(col.name)), unquote(type), unquote(opts)
      end
    end

  name = table.name

  body =
    quote do
      @moduledoc "The `#{unquote(name)}` row (`schema/hireme.schema`)."
      use Ecto.Schema
      @timestamps_opts [type: :utc_datetime]
      @type t :: %__MODULE__{}

      schema unquote(name) do
        unquote_splicing(fields)
        timestamps()
      end
    end

  Module.create(Hireme.Schema.row(table.name), body, Macro.Env.location(__ENV__))
end
