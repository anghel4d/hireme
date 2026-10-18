defmodule Hireme.Import do
  @moduledoc """
  Packs of new data, lowered to `put` ops and run through the account's
  sequencer (`Hireme.Sequencer.call/3`) as the operator: every check a
  wire write meets, an import meets. It is a product feature for new data,
  not a reader of any older database.

  ## The pack format

  JSON:

      {
        "as_of": "2026-10-01",
        "source": "https://example.org/report",
        "tables": [
          {"table": "corporations", "rows": [
            {"domain": "example.com", "name": "Example", "headcount": 1200, "about": "..."}
          ]},
          {"table": "offices", "rows": [
            {"corporation_id": {"domain": "example.com"}, "place_id": {"iso2": "PT"},
             "kind": "engineering"}
          ]}
        ]
      }

  Markdown: a `## <table>` heading, then a pipe table whose header names the
  columns. `as_of: <date>` and `source: <url>` lines before the first
  heading set the pack's defaults.

      as_of: 2026-10-01
      source: https://example.org/report

      ## corporations
      | domain | name | headcount |
      | --- | --- | --- |
      | example.com | Example | 1200 |

  Rules:

  - Groups run in order, each after the one before it has committed, so a
    later group's refs may name rows an earlier one made.
  - A row carrying every column of one of its table's natural keys, with
    the key's where holding for its values, is a keyed put: it updates the
    row with that key, or makes it. A row naming a unique key updates the
    row that holds it. Any other row makes a new row on every import, and
    every import cites the metrics and prose it writes again.
  - Numbers past their column's range are refused, never wrapped; a
    markdown row whose cell count is not its header's is refused (`\\|` is a
    pipe inside a cell).
  - A ref is a row id or a natural key of the referenced table (an object,
    or for a one-column key its bare value); it is resolved when its group
    runs, and a key that names no row refuses the row (`not_found`).
  - A metric cell carries the row's `$as_of` or the pack's `as_of`; a
    prose cell carries the row's `$source` or the pack's `source`, and the
    row's stored `rev` (0 for a new row) as its `expect_rev`.
  - Values are JSON values (a day as `YYYY-MM-DD`, an enum by name); in
    markdown every cell is text, read by the column's type, and an empty
    cell is null.

  The answer counts what each group wrote and lists every refusal with
  its row's position, so one bad row costs that row alone.
  """

  alias Hireme.{Grants, Schema, Sequencer}
  alias HiremeWeb.Wire.Codec

  # The sequencer's batch.
  @batch 64
  @as_of 0xFFF0
  @source 0xFFF1
  @keyed 0x01

  @type refusal :: %{table: String.t(), row: non_neg_integer() | nil, code: atom(), data: map()}
  @type report :: %{
          rev: non_neg_integer(),
          groups: [%{table: String.t(), written: non_neg_integer(), refused: non_neg_integer()}],
          refusals: [refusal()]
        }

  @doc "Import the pack at `path` (`.json`, or markdown) into `account_id`."
  @spec file(pos_integer(), Path.t()) :: {:ok, report()} | {:error, term()}
  def file(account_id, path) do
    with {:ok, body} <- File.read(path) do
      format = if String.downcase(Path.extname(path)) == ".json", do: :json, else: :markdown
      run(account_id, body, format)
    end
  end

  @doc "Import a pack's text, in `format` (`:json` or `:markdown`)."
  @spec run(pos_integer(), String.t(), :json | :markdown) :: {:ok, report()} | {:error, term()}
  def run(account_id, body, format) do
    with {:ok, pack} <- parse(body, format) do
      write(account_id, pack)
    end
  catch
    {:import, reason} -> {:error, reason}
  end

  defp write(account_id, pack) do
    begin = fn ->
      actor = %{label: "import", grants: Grants.operator(), key_id: nil}
      initial = %{rev: 0, groups: [], refusals: []}

      report =
        Enum.reduce(pack.tables, initial, fn group, report ->
          run_group(account_id, actor, pack, group, report)
        end)

      # A bulk load moves the planner's statistics; refresh what it reads.
      Hireme.Store.write(fn -> Hireme.Repo.query!("PRAGMA optimize", [], skip_account: true) end)

      {:ok,
       %{report | groups: Enum.reverse(report.groups), refusals: Enum.reverse(report.refusals)}}
    end

    begin.()
  end

  # ------------------------------------------------------------------ parse

  @doc false
  def parse(body, :json) do
    case Jason.decode(String.trim_leading(body, "\uFEFF")) do
      {:ok, %{"tables" => tables} = pack} when is_list(tables) ->
        groups =
          Enum.map(tables, fn
            %{"table" => t, "rows" => rows} when is_binary(t) and is_list(rows) ->
              {t, rows, :json}

            other ->
              {:bad, other}
          end)

        case Enum.find(groups, &match?({:bad, _}, &1)) do
          nil -> {:ok, pack(pack["as_of"], pack["source"], groups)}
          {:bad, g} -> {:error, {:group, brief(g)}}
        end

      {:ok, _} ->
        {:error, :no_tables}

      {:error, e} ->
        {:error, {:json, Exception.message(e)}}
    end
  end

  def parse(body, :markdown) do
    # A byte-order mark (what some editors write first) is not text.
    body = String.trim_leading(body, "\uFEFF")
    # A byte-order mark can open any joined file, not only the first.
    lines =
      body
      |> String.split("\n")
      |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()))

    {head, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "## ")))

    defaults =
      for line <- head,
          [k, v] <- [String.split(line, ":", parts: 2)],
          k in ["as_of", "source"],
          into: %{},
          do: {k, String.trim(v)}

    groups =
      rest
      |> Enum.chunk_while(
        nil,
        fn
          "## " <> table, nil -> {:cont, {String.trim(table), []}}
          "## " <> table, acc -> {:cont, finish(acc), {String.trim(table), []}}
          line, {t, ls} -> {:cont, {t, [line | ls]}}
        end,
        fn
          nil -> {:cont, nil}
          acc -> {:cont, finish(acc), nil}
        end
      )

    if groups == [],
      do: {:error, :no_tables},
      else: {:ok, pack(defaults["as_of"], defaults["source"], groups)}
  end

  defp finish({table, lines}) do
    {table, lines |> Enum.reverse() |> table_rows(), :text}
  end

  # GFM tables: a header line, a delimiter row of `---` cells, then the rows
  # up to the first line without a pipe; a section may hold several. The
  # outer pipes are optional; prose before, between or after is not data.
  defp table_rows([line, delimiter | rest]) do
    header = cells(line)
    marks = cells(delimiter)

    if pipe?(line) and delimiter?(marks) do
      {body, after_table} = Enum.split_while(rest, &pipe?/1)

      rows =
        if length(marks) == length(header) do
          body
          |> Enum.map(&cells/1)
          # A delimiter row repeated inside the body is not a row.
          |> Enum.reject(&delimiter?/1)
          |> Enum.map(&row(header, &1))
        else
          [
            %{
              "$shape" =>
                "a #{length(marks)}-cell delimiter under a #{length(header)}-column header"
            }
          ]
        end

      rows ++ table_rows(after_table)
    else
      table_rows([delimiter | rest])
    end
  end

  defp table_rows(_lines), do: []

  defp pipe?(line), do: String.contains?(line, "|")
  defp delimiter?(cells), do: cells != [] and Enum.all?(cells, &(&1 =~ ~r/^:?-+:?$/))

  # A row with more or fewer cells than the header is refused, not trimmed.
  defp row(header, cells) when length(header) == length(cells),
    do: Map.new(Enum.zip(header, cells))

  defp row(header, cells),
    do: %{"$shape" => "#{length(cells)} cells under a #{length(header)}-column header"}

  # One leading and one trailing pipe frame the row; `\\|` is a pipe in a cell.
  defp cells(line) do
    line = String.trim(line)

    line =
      if String.starts_with?(line, "|"), do: binary_part(line, 1, byte_size(line) - 1), else: line

    line =
      if String.ends_with?(line, "|") and not String.ends_with?(line, "\\|"),
        do: binary_part(line, 0, byte_size(line) - 1),
        else: line

    line
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&(&1 |> String.replace("\\|", "|") |> String.trim()))
  end

  defp pack(as_of, source, groups),
    do: %{as_of: as_of, source: source, tables: groups}

  # ------------------------------------------------------------------ groups

  defp run_group(account_id, actor, pack, {name, rows, mode}, report) do
    case Schema.table(name) do
      %{residency: r} = table when r in [:resident, :server] and table.domain != "system" ->
        {ops, refused} =
          rows
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {row, i}, {ops, refused} ->
            case lower(account_id, table, pack, row, mode) do
              {:ok, op} ->
                {[{i, op} | ops], refused}

              {:refused, code, data} ->
                {ops, [%{table: name, row: i, code: code, data: data} | refused]}
            end
          end)

        {rev, written, nacked} = submit(account_id, actor, name, Enum.reverse(ops))

        %{
          report
          | rev: max(report.rev, rev),
            groups: [
              %{table: name, written: written, refused: length(refused) + length(nacked)}
              | report.groups
            ],
            refusals: Enum.reverse(nacked) ++ refused ++ report.refusals
        }

      _ ->
        name = named(name)
        refusal = %{table: name, row: nil, code: :not_found, data: %{table: name}}

        %{
          report
          | groups: [%{table: name, written: 0, refused: length(rows)} | report.groups],
            refusals: [refusal | report.refusals]
        }
    end
  end

  defp submit(account_id, actor, name, indexed_ops) do
    indexed_ops
    |> Enum.chunk_every(@batch)
    |> Enum.reduce({0, 0, []}, fn chunk, {rev, written, nacked} ->
      by_op = Map.new(chunk, fn {i, op} -> {op.op_id, i} end)

      {new_rev, acks, nacks} =
        case Sequencer.call(account_id, actor, Enum.map(chunk, &elem(&1, 1))) do
          {:ok, new_rev, acks, nacks} -> {new_rev, acks, nacks}
          {:error, reason} -> throw({:import, reason})
        end

      refused =
        for n <- nacks do
          %{table: name, row: by_op[n.op_id], code: Schema.refusal_name(n.code), data: n.data}
        end

      {max(rev, new_rev), written + length(acks), refused ++ nacked}
    end)
  end

  # ------------------------------------------------------------------ one row

  defp lower(account_id, table, pack, row, mode) when is_map(row) do
    {directives, values} = Map.split_with(row, fn {k, _} -> String.starts_with?(k, "$") end)
    values = if mode == :text, do: Map.reject(values, fn {_, v} -> v == "" end), else: values

    if shape = directives["$shape"] do
      {:refused, :type, %{row: shape}}
    else
      lower_row(account_id, table, pack, directives, values, mode)
    end
  rescue
    # One bad row costs that row alone: a value the checks below did not
    # foresee is that row's refusal, never the pack's crash.
    e -> {:refused, :type, %{row: "unreadable", reason: Exception.message(e)}}
  end

  defp lower(_account_id, _table, _pack, row, _mode), do: {:refused, :type, %{row: brief(row)}}

  defp lower_row(account_id, table, pack, directives, values, mode) do
    with {:ok, cells} <- cells(account_id, table, values, mode),
         {:ok, key} <- natural(table, values),
         unique = if(key, do: nil, else: unique(table, values)),
         {:ok, existing} <- existing(account_id, table, key || unique, cells),
         {:ok, extra, expect_rev} <- provenance(table, pack, directives, cells, existing) do
      # A natural key is the sequencer's (a keyed put); a row named by a
      # unique key alone updates the row that holds it.
      flags = if key, do: @keyed, else: 0
      target = if(unique && existing, do: existing.id, else: 0)
      raw = Codec.encode_op({op_id(), :put, flags, table.id, target, expect_rev, cells ++ extra})

      case Codec.op(raw) do
        {:ok, op, ""} -> {:ok, op}
        _ -> {:refused, :type, %{row: "a cell the wire cannot carry (text must be UTF-8)"}}
      end
    end
  end

  defp cells(account_id, table, values, mode) do
    Enum.reduce_while(values, {:ok, []}, fn {name, value}, {:ok, acc} ->
      case Schema.column(table.name, name) do
        nil ->
          {:halt, {:refused, :column, %{table: table.name, column: named(name)}}}

        %{implied: true} ->
          {:halt, {:refused, :column, %{table: table.name, column: name, reason: "implied"}}}

        col ->
          case cell(account_id, col, value, mode) do
            {:ok, cell} -> {:cont, {:ok, [cell | acc]}}
            refusal -> {:halt, refusal}
          end
      end
    end)
    |> case do
      {:ok, cells} -> {:ok, Enum.reverse(cells)}
      refusal -> refusal
    end
  end

  defp cell(_account_id, col, nil, _mode), do: {:ok, {col.id, 0, nil}}

  defp cell(account_id, %{type: :ref} = col, value, mode) do
    case resolve_ref(account_id, col.target, value, mode) do
      {:ok, id} -> {:ok, {col.id, Codec.cell_type(col), id}}
      :none -> {:refused, :not_found, %{column: col.name, ref: brief(value)}}
      :error -> {:refused, :type, %{column: col.name, value: brief(value)}}
    end
  end

  defp cell(_account_id, col, value, mode) do
    with {:ok, v} <- cast(col, value, mode) do
      wire = if col.deferred, do: v, else: Codec.to_wire(col, v)
      {:ok, {col.id, Codec.cell_type(col), wire}}
    end
  end

  defp cast(%{type: :json} = col, value, :text) do
    case Jason.decode(value) do
      {:ok, v} -> {:ok, v}
      _ -> {:refused, :type, %{column: col.name, value: brief(value)}}
    end
  end

  defp cast(%{type: :bool} = col, value, :text) when is_binary(value) do
    case String.downcase(value) do
      v when v in ~w(true yes 1) -> {:ok, true}
      v when v in ~w(false no 0) -> {:ok, false}
      _ -> {:refused, :type, %{column: col.name, value: brief(value)}}
    end
  end

  defp cast(col, value, _mode) do
    case Ecto.Type.cast(Schema.cast_type(col), value) do
      {:ok, nil} -> {:refused, :type, %{column: col.name, value: brief(value)}}
      {:ok, v} -> in_range(col, v, value)
      _ -> {:refused, :type, %{column: col.name, value: brief(value)}}
    end
  end

  # The wire's integers: a value past its column's range would be truncated
  # by the encoding, so it is refused; each type's top or bottom is null.
  @times 0..4_294_967_294

  @ranges %{
    u8: 0..255,
    u32: 0..4_294_967_294,
    i64: -9_223_372_036_854_775_807..9_223_372_036_854_775_807
  }

  defp in_range(%{type: t} = col, v, value) when is_map_key(@ranges, t) do
    if v in Map.fetch!(@ranges, t),
      do: {:ok, v},
      else: {:refused, :type, %{column: col.name, value: brief(value), reason: "out of range"}}
  end

  # A day travels as days since 0000-01-01 to 9999-12-31 and a time as unix
  # seconds, both u32 on the wire with its top for null; past either a value
  # would not travel.
  defp in_range(%{type: :day} = col, %Date{} = d, value) do
    if Codec.day_to_wire(d) != nil,
      do: {:ok, d},
      else: {:refused, :type, %{column: col.name, value: brief(value), reason: "out of range"}}
  end

  defp in_range(%{type: :time} = col, %DateTime{} = t, value) do
    if DateTime.to_unix(t) in @times,
      do: {:ok, t},
      else: {:refused, :type, %{column: col.name, value: brief(value), reason: "out of range"}}
  end

  defp in_range(%{type: t} = col, v, value) when t in [:str, :text] and is_binary(v) do
    if String.valid?(v),
      do: {:ok, v},
      else: {:refused, :type, %{column: col.name, value: brief(value), reason: "not UTF-8"}}
  end

  defp in_range(_col, v, _value), do: {:ok, v}

  # A ref is an id, a natural key object, or (one-column key) its value.
  defp resolve_ref(_account_id, _target, id, _mode)
       when is_integer(id) and id > 0 and id < 4_294_967_295,
       do: {:ok, id}

  defp resolve_ref(account_id, target, value, mode) do
    table = Schema.table(target)

    key =
      cond do
        is_map(value) ->
          value

        mode == :text and value =~ ~r/^\d+$/ ->
          String.to_integer(value) |> then(&if(&1 in 1..4_294_967_294, do: {:id, &1}, else: nil))

        true ->
          case Enum.find(table.naturals, &(length(&1.cols) == 1)) do
            %{cols: [col]} -> %{col => value}
            nil -> nil
          end
      end

    case key do
      {:id, id} ->
        {:ok, id}

      nil ->
        :error

      key ->
        with {:ok, cells} <- cells(account_id, table, key, mode),
             {:ok, natural} when natural != nil <- ref_key(table, key),
             {:ok, %{id: id}} <- existing(account_id, table, natural, cells) do
          {:ok, id}
        else
          {:ok, nil} -> :none
          _ -> :error
        end
    end
  end

  # The first natural key whose every column the row names (and whose
  # partial-index condition is the database's to decide).
  defp natural(table, values) do
    case Enum.find(table.naturals, &names?(&1, values)) do
      nil -> {:ok, nil}
      k -> {:ok, k}
    end
  end

  # A ref names its row by a key's columns; the key's where is the lookup's
  # (World.get applies it), since a ref carries no other column to judge.
  defp ref_key(table, key) do
    case Enum.find(table.naturals ++ table.uniques, fn k ->
           Enum.sort(k.cols) == Enum.sort(Map.keys(key))
         end) do
      nil -> {:ok, nil}
      k -> {:ok, k}
    end
  end

  # A key the row names: every column given, and its where held by the row.
  defp names?(k, values) do
    Enum.all?(k.cols, &Map.has_key?(values, &1)) and holds?(Map.get(k, :where_term), values)
  end

  defp holds?(nil, _values), do: true

  defp holds?({:eq, col, v}, values),
    do: Map.has_key?(values, col) and to_string(values[col]) == v

  defp holds?({:null, col}, values), do: values[col] in [nil, ""]
  defp holds?({:not_null, col}, values), do: values[col] not in [nil, ""]

  # The first unique key (or unique column) whose every column the row names.
  defp unique(table, values) do
    keys = table.uniques ++ for(c <- table.cols, c.unique, do: %{cols: [c.name], where_term: nil})
    Enum.find(keys, &names?(&1, values))
  end

  defp existing(_account_id, _table, nil, _cells), do: {:ok, nil}

  defp existing(account_id, table, natural, cells) do
    params =
      Map.new(natural.cols, fn name ->
        col = Schema.column(table.name, name)
        {_, _, wire} = Enum.find(cells, fn {id, _, _} -> id == col.id end)

        case Codec.from_wire(col, wire) do
          {:ok, value} -> {name, value}
          _ -> throw({:refused, :type, %{column: name}})
        end
      end)

    grants = Grants.operator()

    case Hireme.World.get(account_id, grants, %{
           "table" => table.name,
           "key" => json_key(params),
           "cols" => ["id", "rev"]
         }) do
      {:ok, %{"row" => row}} -> {:ok, %{id: row["id"], rev: row["rev"]}}
      {:error, :not_found, _} -> {:ok, nil}
      {:error, code, data} -> {:refused, code, data}
    end
  catch
    {:refused, _, _} = refusal -> refusal
  end

  defp json_key(params) do
    Map.new(params, fn
      {k, %Date{} = d} -> {k, Date.to_iso8601(d)}
      {k, v} when is_atom(v) and not is_nil(v) and not is_boolean(v) -> {k, Atom.to_string(v)}
      kv -> kv
    end)
  end

  # Metric cells carry as_of; prose cells a source and the row's rev.
  defp provenance(table, pack, directives, cells, existing) do
    ids = MapSet.new(cells, &elem(&1, 0))
    named = Enum.filter(table.cols, &MapSet.member?(ids, &1.id))
    metric? = Enum.any?(named, & &1.metric)
    prose? = Enum.any?(named, & &1.prose)

    as_of = directives["$as_of"] || pack.as_of
    source = directives["$source"] || pack.source

    with {:ok, as_of_cell} <- as_of_cell(metric?, as_of) do
      source_cell =
        if (metric? or prose?) and is_binary(source), do: [{@source, 2, source}], else: []

      expect_rev = if prose?, do: (existing && existing.rev) || 0
      {:ok, as_of_cell ++ source_cell, expect_rev}
    end
  end

  defp as_of_cell(false, _), do: {:ok, []}
  defp as_of_cell(true, nil), do: {:ok, []}

  defp as_of_cell(true, as_of) when is_binary(as_of) do
    with {:ok, d} <- Date.from_iso8601(as_of),
         days when days != nil <- Codec.day_to_wire(d) do
      {:ok, [{@as_of, 1, days}]}
    else
      _ -> {:refused, :type, %{column: "as_of", value: brief(as_of)}}
    end
  end

  defp as_of_cell(true, as_of), do: {:refused, :type, %{column: "as_of", value: brief(as_of)}}

  defp op_id do
    <<id::unsigned-63, _::1>> = :crypto.strong_rand_bytes(8)
    id
  end

  # A refusal names the value it refused, bounded.
  defp brief(value), do: inspect(value, limit: 8, printable_limit: 64)

  # A name the pack gave that no schema declares is echoed as given when
  # short, UTF-8 and free of control characters (the mix task prints it to
  # a terminal), escaped and bounded otherwise.
  defp named(name) when is_binary(name) and byte_size(name) <= 64 do
    if String.valid?(name) and not String.match?(name, ~r/\p{Cc}/u),
      do: name,
      else: brief(name)
  end

  defp named(name), do: brief(name)
end
