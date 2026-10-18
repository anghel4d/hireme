defmodule Hireme.Schema.Parser do
  @moduledoc """
  Reads `schema/hireme.schema` into the resolved declaration: ids assigned,
  implied columns added, metric twins and projections expanded. The file's
  own header is the grammar. `native/schema` resolves the same file the
  same way; `mix hireme.schema --check` compares the two canonical dumps,
  so the rules below and the crate's cannot drift unnoticed.
  """

  @flags ~w(deferred private server_only human_only readonly unique cascade loose)
  @table_mods ~w(append_only soft_delete global account_optional singleton unmasked)

  # Names: lowercase words for everything but frames, which are uppercase.
  @name ~r/^[a-z][a-z0-9_]*$/
  @frame_name ~r/^[A-Z][A-Z0-9_]*$/
  @types ~w(id ref enum bool u8 u32 i64 f64 day time str text json bytes)

  # The catalog's type codes: position in @types, from 1.
  @type_codes @types |> Enum.with_index(1) |> Map.new(fn {t, i} -> {String.to_atom(t), i} end)

  # Wire type codes (the header of schema/hireme.schema).
  @wire %{
    id: 1,
    ref: 1,
    bool: 1,
    u8: 1,
    u32: 1,
    day: 1,
    time: 1,
    enum: 1,
    str: 2,
    text: 2,
    json: 2,
    bytes: 2,
    i64: 3,
    f64: 4
  }

  # A free command param has no column; its cell id is 0xFE00 + its position.
  @free_param 0xFE00

  @flag_bits %{
    required: 1,
    deferred: 2,
    private: 4,
    server_only: 8,
    human_only: 16,
    readonly: 32,
    unique: 64,
    metric: 128,
    prose: 256,
    implied: 512,
    metric_on: 1024,
    natural: 2048,
    cascade: 4096,
    sha_on: 8192,
    loose: 16384
  }

  @doc "The resolved declaration of `source`; raises naming the line on any error."
  def parse!(source) do
    state = %{
      domains: [],
      carry: [],
      layout: nil,
      frames: [],
      enums: [],
      tables: [],
      commands: [],
      table: nil
    }

    state =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce(state, fn {line, n}, state ->
        case line |> strip_comment() |> trim() do
          "" -> state
          text -> line(text, n, state)
        end
      end)
      |> close_table()

    resolve(state)
  end

  def flag_bits, do: @flag_bits
  def type_codes, do: @type_codes

  defp strip_comment(line) do
    case :binary.match(line, "#") do
      {at, _} -> binary_part(line, 0, at)
      :nomatch -> line
    end
  end

  # Only ASCII space and tab separate tokens, in both parsers.
  defp trim(text), do: String.replace(text, ~r/^[ \t\r]+|[ \t\r]+$/, "")
  defp tokens(text), do: String.split(text, [" ", "\t"], trim: true)

  defp split_where(text) do
    case String.split(text, ~r/[ \t]where[ \t]/, parts: 2) do
      [head, where] -> {tokens(head), trim(where)}
      [head] -> {tokens(head), nil}
    end
  end

  defp line(text, n, state) do
    line_no = n
    {tokens, where} = split_where(text)

    case tokens do
      ["domain" | names] ->
        Enum.each(names, &name!(&1, line_no))
        %{state | domains: state.domains ++ names}

      ["carry" | names] ->
        Enum.each(names, &name!(&1, line_no))
        %{state | carry: state.carry ++ names}

      ["layout", n] ->
        %{state | layout: int!(n, line_no, 0..65_535)}

      ["frame", name, id] ->
        unless name =~ @frame_name, do: fail(n, "frame name #{name}")
        %{state | frames: state.frames ++ [{name, int!(id, n, 1..255)}]}

      ["enum", name | values] when values != [] ->
        Enum.each([name | values], &name!(&1, line_no))
        %{state | enums: state.enums ++ [{name, values}]}

      ["table", name, domain, residency | mods] ->
        name!(name, n)
        unless residency in ~w(resident server wire), do: fail(n, "residency #{residency}")
        Enum.each(mods, &unless(&1 in @table_mods, do: fail(n, "table modifier #{&1}")))
        if mods != Enum.uniq(mods), do: fail(n, "a table modifier twice")

        if "global" in mods and "singleton" in mods,
          do: fail(n, "a global table has no account to be one row of")

        state
        |> close_table()
        |> Map.put(:table, %{
          name: name,
          domain: domain,
          residency: String.to_atom(residency),
          mods: Enum.map(mods, &String.to_atom/1),
          naturals: [],
          uniques: [],
          indexes: [],
          cap: nil,
          cols: [],
          picks: [],
          source: nil,
          source_where: nil,
          commands: [],
          line: n
        })

      ["projection", name, domain, source] ->
        name!(name, n)
        if where == nil, do: fail(n, "a projection needs a where")

        state
        |> close_table()
        |> Map.put(:table, %{
          name: name,
          domain: domain,
          residency: :projection,
          mods: [],
          naturals: [],
          uniques: [],
          indexes: [],
          cap: nil,
          cols: [],
          picks: [],
          source: source,
          source_where: where,
          source_term: where_term!(where, n),
          commands: [],
          line: n
        })

      [kind | _] when kind in ~w(col metric prose natural unique index cap command pick) ->
        if state.table == nil, do: fail(n, "#{kind} outside a table")

        # A projection only picks its source's columns; a table never picks.
        if state.table.residency == :projection != (kind == "pick") do
          where = if kind == "pick", do: "table", else: "projection"
          fail(n, "#{kind} in #{where} #{state.table.name}")
        end

        %{state | table: table_line(tokens, where, n, state.table, state)}

      _ ->
        fail(n, "unreadable line: #{text}")
    end
  end

  defp table_line(["pick" | cols], _where, n, t, _state) do
    Enum.each(cols, &name!(&1, n))
    %{t | picks: t.picks ++ cols}
  end

  defp table_line(["cap", n], _where, line, t, _), do: %{t | cap: int!(n, line, 1..4_294_967_295)}

  defp table_line(["natural" | cols], where, n, t, _) do
    if cols == [], do: fail(n, "a key names its columns")

    %{
      t
      | naturals: t.naturals ++ [%{cols: cols, where: where, where_term: where_term!(where, n)}]
    }
  end

  defp table_line(["unique" | cols], where, n, t, _) do
    {global, cols} = global(cols, n)
    if cols == [], do: fail(n, "a key names its columns")
    key = %{cols: cols, global: global, where: where, where_term: where_term!(where, n)}
    %{t | uniques: t.uniques ++ [key]}
  end

  defp table_line(["index" | cols], where, n, t, _) do
    {global, cols} = global(cols, n)
    if cols == [], do: fail(n, "an index names its columns")
    index = %{cols: desc(cols), global: global, where: where, where_term: where_term!(where, n)}
    %{t | indexes: t.indexes ++ [index]}
  end

  defp table_line(["col", name, type | rest], _where, n, t, _) do
    {type, target, rest} = type!(type, rest, n)
    %{t | cols: t.cols ++ with_sha(column(name, type, target, rest, n))}
  end

  defp table_line(["metric", name, type | rest], _where, n, t, _) do
    unless type in ~w(u32 i64 f64), do: fail(n, "metric type #{type}")
    col = column(name, String.to_atom(type), nil, rest, n)

    if col.required, do: fail(n, "a metric is nullable")

    # The twin is the metric's own date: written with it, never alone, and
    # seen by whoever sees the metric.
    twin = %{
      blank(name <> "_on", :day)
      | metric_of: name,
        readonly: true,
        private: col.private,
        server_only: col.server_only,
        human_only: col.human_only
    }

    %{t | cols: t.cols ++ [%{col | metric: true}, twin]}
  end

  defp table_line(["prose", name | rest], _where, n, t, _) do
    rest = rest |> drop_prefix(["text"]) |> drop_prefix(["?"])
    col = column(name, :text, nil, rest, n)
    %{t | cols: t.cols ++ with_sha(%{col | prose: true, deferred: true})}
  end

  defp table_line(["command", name | rest], _where, n, t, _state) do
    name!(name, n)

    {human_only, rest} =
      case Enum.count(rest, &(&1 == "human_only")) do
        0 -> {false, rest}
        1 -> {true, rest -- ["human_only"]}
        _ -> fail(n, "human_only twice")
      end

    params = Enum.map(rest, &param(&1, n))

    command = %{name: name, table: t.name, params: params, human_only: human_only, line: n}
    %{t | commands: t.commands ++ [command]}
  end

  defp table_line(tokens, _where, n, _t, _), do: fail(n, "unreadable: #{Enum.join(tokens, " ")}")

  # A deferred column travels as its length and hash, so its hash is stored
  # beside it: the readonly `<name>_sha` (a trailing `_raw` dropped, so
  # listing_raw's is listing_sha). It stays on the server, which builds the
  # stub's 8 bytes from it; no client needs the 64 hex characters.
  defp with_sha(%{deferred: true} = col) do
    twin = %{
      blank(String.replace_suffix(col.name, "_raw", "") <> "_sha", :str)
      | sha_of: col.name,
        readonly: true,
        server_only: true
    }

    [col, twin]
  end

  defp with_sha(col), do: [col]

  defp drop_prefix([p | rest], [p]), do: rest
  defp drop_prefix(rest, _), do: rest

  defp global(cols, n) do
    case Enum.count(cols, &(&1 == "global")) do
      0 -> {false, cols}
      1 -> {true, cols -- ["global"]}
      _ -> fail(n, "global twice")
    end
  end

  # The where of a key, an index or a projection: `col = 'value'`,
  # `col is null` or `col is not null`, the only shapes a reader of the
  # declaration (the sequencer, World) can apply.
  defp where_term!(nil, _n), do: nil

  defp where_term!(where, n) do
    cond do
      m = Regex.run(~r/^([a-z][a-z0-9_]*) = '([^']*)'$/, where) ->
        {:eq, Enum.at(m, 1), Enum.at(m, 2)}

      m = Regex.run(~r/^([a-z][a-z0-9_]*) is not null$/, where) ->
        {:not_null, Enum.at(m, 1)}

      m = Regex.run(~r/^([a-z][a-z0-9_]*) is null$/, where) ->
        {:null, Enum.at(m, 1)}

      true ->
        fail(n, "where takes col = 'value', col is null or col is not null: #{where}")
    end
  end

  defp name!(name, n), do: unless(name =~ @name, do: fail(n, "name #{name}"))

  defp desc([col, "desc" | rest]), do: [{col, true} | desc(rest)]
  defp desc([col | rest]), do: [{col, false} | desc(rest)]
  defp desc([]), do: []

  defp param(token, n) do
    {token, required} =
      if String.ends_with?(token, "?"),
        do: {binary_part(token, 0, byte_size(token) - 1), false},
        else: {token, true}

    if String.ends_with?(token, "?"), do: fail(n, "param #{token}?")

    case String.split(token, ":", parts: 2) do
      [name, type] ->
        name!(name, n)
        unless type in @types and type not in ~w(id ref enum), do: fail(n, "param type #{type}")
        %{name: name, type: String.to_atom(type), target: nil, required: required, column: false}

      [name] ->
        name!(name, n)
        %{name: name, type: nil, target: nil, required: required, column: true}
    end
  end

  defp type!(type, rest, n) do
    cond do
      type in ~w(ref enum) ->
        case rest do
          [target | rest] -> {String.to_atom(type), target, rest}
          [] -> fail(n, "#{type} needs a target")
        end

      type in @types ->
        {String.to_atom(type), nil, rest}

      true ->
        fail(n, "type #{type}")
    end
  end

  defp blank(name, type) do
    %{
      name: name,
      type: type,
      target: nil,
      required: false,
      default: nil,
      deferred: false,
      private: false,
      server_only: false,
      human_only: false,
      readonly: false,
      unique: false,
      cascade: false,
      loose: false,
      metric: false,
      metric_of: nil,
      sha_of: nil,
      prose: false,
      implied: false,
      id: nil
    }
  end

  defp column(name, type, target, rest, n) do
    name!(name, n)
    if target, do: name!(target, n)
    col = walk(rest, %{blank(name, type) | target: target}, n)
    if col.cascade and type != :ref, do: fail(n, "cascade is a ref's")
    if col.loose and type != :ref, do: fail(n, "loose is a ref's")
    if col.loose and col.cascade, do: fail(n, "a loose ref has no delete to cascade")
    if col.deferred and type not in [:str, :text, :json], do: fail(n, "only text is deferred")
    default!(col, n)
    col
  end

  # A default must be a value of its column's type.
  defp default!(%{default: nil}, _n), do: :ok

  defp default!(%{default: d, type: type}, n) do
    ok =
      case type do
        :bool -> d in ~w(true false)
        :u8 -> int_in?(d, 0..255)
        :u32 -> int_in?(d, 0..4_294_967_294)
        :i64 -> int_in?(d, -9_223_372_036_854_775_807..9_223_372_036_854_775_807)
        :f64 -> d =~ ~r/^-?[0-9]+(\.[0-9]+)?$/
        t when t in [:str, :text] -> d =~ ~r/^'[^']*'$/
        :enum -> true
        _ -> false
      end

    unless ok, do: fail(n, "default #{d} is not a #{type}")
  end

  defp int_in?(text, range) do
    case Integer.parse(text) do
      {v, ""} -> v in range
      _ -> false
    end
  end

  defp walk([], col, _n), do: col
  defp walk(["!" | rest], col, n), do: walk(rest, %{col | required: true}, n)
  defp walk(["?" | rest], col, n), do: walk(rest, %{col | required: false}, n)
  defp walk(["=", value | rest], col, n), do: walk(rest, %{col | default: value}, n)

  defp walk([flag | rest], col, n) when flag in @flags,
    do: walk(rest, Map.put(col, String.to_atom(flag), true), n)

  defp walk([other | _], _col, n), do: fail(n, "flag #{other}")

  defp close_table(%{table: nil} = state), do: state

  defp close_table(%{table: t} = state) do
    {commands, t} = Map.pop(t, :commands)
    %{state | tables: state.tables ++ [t], commands: state.commands ++ commands, table: nil}
  end

  # ---------------------------------------------------------------- resolve

  defp resolve(state) do
    dupes(state.domains, "domain")

    domains =
      state.domains
      |> Enum.with_index()
      |> Enum.map(fn
        {"system", _} -> %{name: "system", bit: 0}
        {name, i} when i < 8 -> %{name: name, bit: Bitwise.bsl(1, i)}
        {name, _} -> raise(ArgumentError, "domain #{name}: a mask has eight bits")
      end)

    for {name, values} <- state.enums, do: dupes(values, "#{name} value")
    dupes(Enum.map(state.frames, &elem(&1, 1)), "frame id")

    enums =
      state.enums
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, values}, id} -> %{id: id, name: name, values: values} end)

    frames = Enum.map(state.frames, fn {name, id} -> %{name: name, id: id} end)

    stored =
      state.tables
      |> Enum.with_index(1)
      |> Enum.map(fn {t, id} -> {t, id} end)

    by_name = Map.new(stored, fn {t, id} -> {t.name, {t, id}} end)

    tables =
      Enum.map(stored, fn {t, id} ->
        natural = MapSet.new(Enum.flat_map(t.naturals, & &1.cols))

        cols =
          t
          |> resolve_cols(by_name)
          |> Enum.map(&(&1 |> decorate() |> Map.put(:natural, MapSet.member?(natural, &1.name))))

        t
        |> Map.drop([:picks, :line])
        |> Map.merge(%{
          id: id,
          cols: cols,
          append_only: :append_only in t.mods,
          soft_delete: :soft_delete in t.mods,
          global: :global in t.mods,
          account_optional: :account_optional in t.mods,
          singleton: :singleton in t.mods,
          unmasked: :unmasked in t.mods
        })
        |> Map.delete(:mods)
      end)

    tables_by_name = Map.new(tables, &{&1.name, &1})

    commands =
      state.commands
      |> Enum.with_index(1)
      |> Enum.map(fn {c, id} ->
        table = Map.fetch!(tables_by_name, c.table)

        params =
          c.params
          |> Enum.with_index()
          |> Enum.map(fn
            {%{column: true} = p, _i} ->
              col =
                Enum.find(table.cols, &(&1.name == p.name)) ||
                  fail(c.line, "command #{c.name}: no column #{p.name}")

              Map.merge(p, %{type: col.type, target: col.target, id: col.id})

            {p, i} ->
              Map.put(p, :id, @free_param + i)
          end)
          |> Enum.map(&decorate/1)

        %{id: id, name: c.name, table: c.table, params: params, human_only: c.human_only}
      end)

    unless state.layout, do: raise(ArgumentError, "schema/hireme.schema: no layout line")

    enum_names = MapSet.new(enums, & &1.name)

    for c <- state.carry,
        not MapSet.member?(enum_names, c),
        do: raise(ArgumentError, "carry names no enum #{c}")

    model = %{
      layout: state.layout,
      carry: state.carry,
      domains: domains,
      frames: frames,
      enums: enums,
      tables: tables,
      commands: commands
    }

    validate!(model)

    Map.merge(model, %{
      wire_hash: fold(fnv(canonical(model, :wire))),
      schema_rev: fnv(canonical(model, :full))
    })
  end

  # The derived keys every reader wants on a column or param.
  defp decorate(c) do
    Map.merge(c, %{
      wire: if(Map.get(c, :deferred), do: 5, else: Map.fetch!(@wire, c.type)),
      type_code: Map.fetch!(@type_codes, c.type),
      ref: if(c.type == :ref, do: c.target),
      enum: if(c.type == :enum, do: c.target)
    })
  end

  defp implied(t) do
    case t.residency do
      r when r in [:resident, :server] ->
        account =
          if :global in t.mods,
            do: [],
            else: [
              {2,
               %{
                 blank("account_id", :ref)
                 | target: "accounts",
                   required: :account_optional not in t.mods
               }}
            ]

        deleted =
          if :soft_delete in t.mods, do: [{6, blank("deleted_at", :time)}], else: []

        ([{1, %{blank("id", :id) | required: true}}] ++
           account ++
           [
             {3, %{blank("rev", :i64) | required: true, default: "1"}},
             {4, %{blank("inserted_at", :time) | required: true}},
             {5, %{blank("updated_at", :time) | required: true}}
           ] ++ deleted)
        |> Enum.map(fn {id, col} -> %{col | id: id, implied: true, readonly: true} end)

      _ ->
        []
    end
  end

  defp resolve_cols(%{residency: :projection} = t, by_name) do
    {source, _} = Map.get(by_name, t.source) || fail(t.line, "projection of #{t.source}")

    unless source.residency in [:resident, :server],
      do: fail(t.line, "a projection's source is a stored table, not #{t.source}")

    source_cols = resolve_cols(source, by_name)

    picked =
      Enum.map(["id" | t.picks], fn name ->
        Enum.find(source_cols, &(&1.name == name)) || fail(t.line, "#{t.source} has no #{name}")
      end)

    picked
  end

  defp resolve_cols(t, _by_name) do
    first = if t.residency == :wire, do: 1, else: 8

    declared =
      t.cols
      |> Enum.with_index(first)
      |> Enum.map(fn {col, id} -> %{col | id: id} end)

    implied(t) ++ declared
  end

  defp validate!(model) do
    tables = Map.new(model.tables, &{&1.name, &1})
    enums = Map.new(model.enums, &{&1.name, &1})
    domains = Enum.map(model.domains, & &1.name)

    dupes(Enum.map(model.tables, & &1.name), "table")
    dupes(Enum.map(model.enums, & &1.name), "enum")
    dupes(Enum.map(model.commands, & &1.name), "command")
    dupes(Enum.map(model.frames, & &1.name), "frame")

    for t <- model.tables do
      unless t.domain in domains, do: raise(ArgumentError, "#{t.name}: domain #{t.domain}")

      # An account's rows are bounded in every table it owns.
      if t.residency in [:resident, :server] and not t.global and t.cap == nil,
        do: raise(ArgumentError, "#{t.name}: an account's table needs a cap")

      dupes(Enum.map(t.cols, & &1.name), "#{t.name} column")
      names = MapSet.new(t.cols, & &1.name)

      for col <- t.cols do
        if col.id >= 0xFFF0, do: raise(ArgumentError, "#{t.name}.#{col.name}: id past 0xFFEF")

        case col.type do
          :ref ->
            unless Map.has_key?(tables, col.target),
              do: raise(ArgumentError, "#{t.name}.#{col.name}: no table #{col.target}")

          :enum ->
            enum =
              Map.get(enums, col.target) ||
                raise(ArgumentError, "#{t.name}.#{col.name}: no enum #{col.target}")

            if col.default && col.default not in enum.values,
              do:
                raise(ArgumentError, "#{t.name}.#{col.name}: #{col.default} not in #{enum.name}")

          _ ->
            :ok
        end
      end

      scoped = not t.global

      leads =
        (t.naturals ++ t.uniques ++ t.indexes)
        |> Enum.reject(&Map.get(&1, :global, false))
        |> Enum.map(fn k ->
          case List.first(k.cols) do
            {col, _desc} -> col
            col -> col
          end
        end)

      if scoped and "account_id" in leads,
        do:
          raise(
            ArgumentError,
            "#{t.name}: account_id already leads every per-account key and index"
          )

      where_cols =
        for k <- t.naturals ++ t.uniques ++ t.indexes, k.where_term, do: elem(k.where_term, 1)

      keys =
        Enum.flat_map(t.naturals ++ t.uniques, & &1.cols) ++
          Enum.flat_map(t.indexes, fn i -> Enum.map(i.cols, &elem(&1, 0)) end) ++ where_cols

      if t.residency == :projection do
        source = Map.fetch!(tables, t.source)
        col = elem(t.source_term, 1)

        unless Enum.any?(source.cols, &(&1.name == col)),
          do: raise(ArgumentError, "#{t.name}: its where names no #{t.source} column #{col}")

        term_fits!(source, t.source_term, enums)
      end

      for k <- t.naturals ++ t.uniques ++ t.indexes,
          k.where_term,
          do: term_fits!(t, k.where_term, enums)

      for c <- keys,
          not MapSet.member?(names, c),
          do: raise(ArgumentError, "#{t.name}: key or index names no column #{c}")
    end

    :ok
  end

  # A where's value must be one its column can hold, or the key never holds.
  defp term_fits!(t, {:eq, col, v}, enums) do
    c = Enum.find(t.cols, &(&1.name == col))

    # A quoted value matches only a column stored as its text.
    ok =
      case c && c.type do
        nil -> true
        :enum -> v in Map.fetch!(enums, c.target).values
        t when t in [:str, :text] -> true
        _ -> false
      end

    unless ok, do: raise(ArgumentError, "#{t.name}: where #{col} = '#{v}' is no value of #{col}")
  end

  defp term_fits!(_t, _term, _enums), do: :ok

  defp dupes(names, what) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [d | _] -> raise ArgumentError, "duplicate #{what} #{d}"
    end
  end

  # ---------------------------------------------------------------- hashes

  @doc """
  The declaration as canonical lines. `:wire` covers what a client is
  compiled against: domains, frames, enums, commands, and the resident,
  wire and projection tables. `:full` is everything.
  """
  def canonical(model, scope) do
    tables =
      if scope == :wire,
        do: Enum.filter(model.tables, &(&1.residency in [:resident, :wire, :projection])),
        else: model.tables

    # The wire's enums: those its tables' columns and its commands' params
    # name, and those the frames carry. An enum only server tables use is not.
    enums =
      if scope == :wire do
        used =
          MapSet.new(
            for(t <- tables, c <- t.cols, c.type == :enum, not c.server_only, do: c.target) ++
              for(c <- model.commands, p <- c.params, p.type == :enum, do: p.target) ++
              model.carry
          )

        Enum.filter(model.enums, &MapSet.member?(used, &1.name))
      else
        model.enums
      end

    lines =
      Enum.map(model.domains, &"domain #{&1.name} #{&1.bit}") ++
        ["layout #{model.layout}"] ++
        Enum.map(model.frames, &"frame #{&1.name} #{&1.id}") ++
        Enum.map(enums, &"enum #{&1.name} #{Enum.join(&1.values, " ")}") ++
        Enum.flat_map(tables, &table_lines(&1, scope)) ++
        Enum.map(model.commands, &command_line/1)

    Enum.map_join(lines, "", &(&1 <> "\n"))
  end

  defp table_lines(t, scope) do
    mods =
      [:append_only, :soft_delete, :global, :account_optional, :singleton, :unmasked]
      |> Enum.filter(&Map.fetch!(t, &1))
      |> Enum.map_join(",", &Atom.to_string/1)

    head =
      "table #{t.id} #{t.name} #{t.domain} #{t.residency} #{dash(mods)} #{dash(t.cap)}" <>
        if(t.residency == :projection, do: " #{t.source} #{t.source_where}", else: "")

    # A server_only column never travels, so it is no part of what a
    # client is compiled against.
    cols =
      t.cols
      |> Enum.reject(&(scope == :wire and &1.server_only))
      |> Enum.map(fn c ->
        "col #{t.id} #{c.id} #{c.name} #{type_name(c)} #{flags(c)} #{dash(c.default)}"
      end)

    keys =
      if scope == :full do
        Enum.map(t.naturals, &"natural #{t.id} #{Enum.join(&1.cols, ",")} #{dash(&1.where)}") ++
          Enum.map(
            t.uniques,
            &"unique #{t.id} #{Enum.join(&1.cols, ",")} #{bit(&1.global)} #{dash(&1.where)}"
          ) ++
          Enum.map(t.indexes, fn i ->
            cols = Enum.map_join(i.cols, ",", fn {c, d} -> if d, do: c <> ":desc", else: c end)
            "index #{t.id} #{cols} #{bit(i.global)} #{dash(i.where)}"
          end)
      else
        []
      end

    [head | cols] ++ keys
  end

  defp command_line(c) do
    params =
      Enum.map_join(c.params, ",", fn p ->
        "#{p.name}:#{type_name(p)}:#{bit(p.required)}:#{bit(p.column)}"
      end)

    "command #{c.id} #{c.name} #{c.table} #{bit(c.human_only)} #{dash(params)}"
  end

  @doc "A column's or param's type as the canonical dump spells it."
  def type_name(%{type: type, target: nil}), do: Atom.to_string(type)
  def type_name(%{type: type, target: target}), do: "#{type}:#{target}"

  @doc "A column's flags as the catalog's bit set."
  def flags(c) do
    [
      required: c.required,
      deferred: c.deferred,
      private: c.private,
      server_only: c.server_only,
      human_only: c.human_only,
      readonly: c.readonly,
      unique: c.unique,
      metric: c.metric,
      prose: c.prose,
      implied: c.implied,
      metric_on: c.metric_of != nil,
      natural: Map.get(c, :natural, false),
      cascade: Map.get(c, :cascade, false),
      sha_on: Map.get(c, :sha_of) != nil,
      loose: Map.get(c, :loose, false)
    ]
    |> Enum.reduce(0, fn {k, on}, acc -> if on, do: Bitwise.bor(acc, @flag_bits[k]), else: acc end)
  end

  defp dash(nil), do: "-"
  defp dash(""), do: "-"
  defp dash(v), do: to_string(v)

  defp bit(true), do: "1"
  defp bit(false), do: "0"

  @doc "FNV-1a, 32 bits."
  def fnv(bytes) do
    for <<b <- bytes>>, reduce: 0x811C9DC5 do
      h -> Bitwise.band(Bitwise.bxor(h, b) * 0x01000193, 0xFFFFFFFF)
    end
  end

  @doc "A 32-bit hash folded to the header's 16 bits."
  def fold(h), do: Bitwise.bxor(Bitwise.bsr(h, 16), Bitwise.band(h, 0xFFFF))

  defp int!(text, n, range) do
    case Integer.parse(text) do
      {v, ""} -> if v in range, do: v, else: fail(n, "#{v} is out of #{inspect(range)}")
      _ -> fail(n, "not a number: #{text}")
    end
  end

  defp fail(n, msg), do: raise(ArgumentError, "schema/hireme.schema:#{n}: #{msg}")
end

defmodule Hireme.Schema do
  @moduledoc """
  The declaration, read at compile time from `schema/hireme.schema`: every
  table, column, enum, command, frame and refusal by name or id, the two
  hashes, and the row module of each stored table (`Hireme.Rows.*`).
  Recompiles when the file changes.
  """

  alias Hireme.Schema.Parser

  @path Path.expand("../../schema/hireme.schema", __DIR__)
  @external_resource @path
  @model Hireme.Schema.Parser.parse!(File.read!(@path))

  @tables @model.tables
  @by_name Map.new(@tables, &{&1.name, &1})
  @by_id Map.new(@tables, &{&1.id, &1})
  @commands @model.commands
  @command_by_name Map.new(@commands, &{&1.name, &1})
  @command_by_id Map.new(@commands, &{&1.id, &1})
  @enums Map.new(@model.enums, &{&1.name, &1})
  @refusals @enums["refusal"].values |> Enum.with_index() |> Map.new(fn {v, i} -> {v, i} end)
  @domains Map.new(@model.domains, &{&1.name, &1.bit})

  @doc "The path of the declaration."
  def path, do: @path

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

  @doc "The code of an enum value (atom or string); nil when it is not one."
  def enum_code(name, value) do
    Enum.find_index(enum_names(name), &(&1 == to_string(value)))
  end

  @doc "The value an enum code names, as an atom; nil past the enum."
  def enum_value(name, code) do
    case Enum.at(enum_names(name), code) do
      nil -> nil
      value -> String.to_atom(value)
    end
  end

  @doc "An enum's values in code order, as strings."
  def enum_names(name), do: Map.fetch!(@enums, to_string(name)).values

  @doc "The u16 NACK code of a refusal (atom or string)."
  def refusal(name), do: Map.fetch!(@refusals, to_string(name))

  @doc "The refusal a code names, as an atom; nil past the enum."
  def refusal_name(code) do
    case Enum.at(enum_names(:refusal), code) do
      nil -> nil
      name -> String.to_atom(name)
    end
  end

  @doc "A domain's mask bit; `system` has none (0)."
  def domain_bit(name), do: Map.fetch!(@domains, to_string(name))

  def frames, do: @model.frames

  @doc "A frame's name (uppercase string) by kind id; nil when unknown."
  def frame_name(id), do: Enum.find_value(@model.frames, &(&1.id == id && &1.name))

  @doc "A frame's kind id by name (`:hello` or `\"HELLO\"`)."
  def frame(name) do
    name = name |> to_string() |> String.upcase()
    Enum.find_value(@model.frames, &(&1.name == name && &1.id))
  end

  def wire_hash, do: @model.wire_hash

  @doc "The byte layout `native/wire` implements."
  def layout, do: @model.layout

  @doc """
  The last day a `day` cell holds: 9999-12-31 as days since 0000-01-01. The
  Rust model declares it too (`DAY_MAX`, emitted into gen/schema.ts), and
  Hireme.SchemaTest holds the two equal.
  """
  def day_max, do: unquote(Date.to_gregorian_days(~D[9999-12-31]))
  def schema_rev, do: @model.schema_rev

  @doc "The canonical dump the hashes cover (`:wire` or `:full`)."
  def canonical(scope), do: Parser.canonical(@model, scope)

  @doc "The row module of a stored table."
  def row(table), do: Module.concat(Hireme.Rows, singular(table(table).name))

  @doc false
  def singular(name) do
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
  def cast(value) do
    if json?(value), do: {:ok, value}, else: :error
  end

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(value), do: if(json?(value), do: {:ok, Jason.encode!(value)}, else: :error)

  @impl true
  def load(nil), do: {:ok, nil}

  def load(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      _ -> :error
    end
  end

  def load(_), do: :error

  defp json?(v) when is_map(v),
    do: Enum.all?(v, fn {k, x} -> (is_binary(k) or is_atom(k)) and json?(x) end)

  defp json?(v) when is_list(v), do: Enum.all?(v, &json?/1)
  # An atom is written as its name, as Jason writes it.
  defp json?(v), do: is_binary(v) or is_number(v) or is_atom(v)
end

defmodule Hireme.Rows do
  @moduledoc """
  One Ecto row module per stored table, generated from the declaration:
  `Hireme.Rows.Application` for `applications`, `Hireme.Rows.ApiKey` for
  `api_keys`. Each has `changeset/2`, which casts every declared column,
  requires the `!` ones and, on a table an account owns, stamps the
  process's account (`Hireme.Repo.put_account/1`) on a row that has none.
  Domain checks are the sequencer's, not the changeset's.
  """

  import Ecto.Changeset

  @doc false
  def changeset(row, attrs, table) do
    declared = for c <- table.cols, not c.implied, do: String.to_atom(c.name)

    required =
      for c <- table.cols, not c.implied, c.required, do: String.to_atom(c.name)

    row
    |> cast(attrs, declared)
    |> validate_required(required)
    |> tenant(table)
  end

  defp tenant(cs, %{global: true}), do: cs

  defp tenant(cs, table) do
    cs =
      if get_field(cs, :account_id),
        do: cs,
        else: put_change(cs, :account_id, Hireme.Repo.account_id())

    cs = if table.account_optional, do: cs, else: validate_required(cs, [:account_id])
    foreign_key_constraint(cs, :account_id)
  end
end

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
  id = table.id

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

      @doc "The declared table this row is."
      def __table__, do: Hireme.Schema.table(unquote(id))

      @doc "Cast every declared column; see `Hireme.Rows`."
      def changeset(row \\ %__MODULE__{}, attrs),
        do: Hireme.Rows.changeset(row, attrs, __table__())
    end

  Module.create(Hireme.Schema.row(table.name), body, Macro.Env.location(__ENV__))
end
