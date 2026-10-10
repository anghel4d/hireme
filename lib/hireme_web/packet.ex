defmodule HiremeWeb.Packet do
  @moduledoc """
  The desk as frames of columns.

  SQLite is the last place a card is a row. Everything the desk sends, the
  cards and their lookups, the scoreboard, the lanes, root CVs and one
  job's focus, travels as columnar table blocks in frames whose layout
  `priv/wire/schema.txt` states once for this encoder, the Rust codec and,
  through the kernel, the browser. Every column starts 8-aligned from the
  frame's first byte, so a reader views it in place.
  """

  alias Hireme.Desk.Job
  alias Hireme.LifeEv
  alias Hireme.Pipeline

  @epoch ~D[1970-01-01]
  @none 0xFFFFFFFF
  @heat_states [:cool, :warm, :hot, :blocked]

  # ---- The wire: frames of columnar tables, as priv/wire/schema.txt says ----
  #
  # Frame: u32 len (whole frame, header included, a multiple of 8) | u8 kind
  # | u8 flags | u16 schema_hash | u64 rev | body. A table body is a run of
  # blocks, u16 table | u16 ncols | u32 nrows | col*, each col u16 id | u8
  # type | u8 0 | u32 byte_len | data | zero pad to 8, so every column starts
  # 8-aligned from the frame's first byte and a reader views it in place.
  # The schema file is the one source for this encoder, the Rust codec and,
  # through the kernel, the browser; its hash rides in every header.

  @schema_file Path.expand("../../priv/wire/schema.txt", __DIR__)
  @external_resource @schema_file
  @schema_bytes File.read!(@schema_file)

  @schema_hash (fn bytes ->
                  h =
                    for <<b <- bytes>>, reduce: 0x811C9DC5 do
                      h -> Bitwise.band(Bitwise.bxor(h, b) * 0x01000193, 0xFFFFFFFF)
                    end

                  Bitwise.bxor(Bitwise.bsr(h, 16), Bitwise.band(h, 0xFFFF))
                end).(@schema_bytes)

  @schema (for line <- String.split(@schema_bytes, "\n"),
               words = String.split(line),
               words != [] and not String.starts_with?(line, "#"),
               reduce: %{frames: %{}, tables: %{}, ops: %{}, refusals: %{}} do
             acc ->
               case words do
                 ["frame", name, kind] ->
                   put_in(
                     acc,
                     [:frames, String.to_atom(String.downcase(name))],
                     String.to_integer(kind)
                   )

                 ["table", name, id] ->
                   put_in(acc, [:tables, String.to_atom(name)], {String.to_integer(id), []})

                 ["col", table, name, id, type] ->
                   update_in(acc, [:tables, String.to_atom(table)], fn {tid, cols} ->
                     {tid,
                      cols ++
                        [{String.to_atom(name), String.to_integer(id), String.to_atom(type)}]}
                   end)

                 ["op", name, kind | _] ->
                   put_in(acc, [:ops, String.to_integer(kind)], String.to_atom(name))

                 ["refusal", name, code] ->
                   put_in(acc, [:refusals, String.to_atom(name)], String.to_integer(code))
               end
           end)

  @frames @schema.frames
  @kinds Map.new(@schema.frames, fn {name, kind} -> {kind, name} end)
  @tables @schema.tables
  @op_kinds @schema.ops
  @refusals @schema.refusals
  @nan <<0, 0, 0, 0, 0, 0, 248, 127>>
  @memo {__MODULE__, :memo}

  @doc "The 16-bit schema hash every frame header carries."
  @spec schema_hash() :: non_neg_integer()
  def schema_hash, do: @schema_hash

  @doc "A table's columns as `{name, wire id}`, in schema order."
  @spec columns(atom()) :: [{atom(), non_neg_integer()}]
  def columns(name),
    do: @tables |> Map.fetch!(name) |> elem(1) |> Enum.map(fn {c, cid, _} -> {c, cid} end)

  @doc "A table's wire id."
  @spec table_id(atom()) :: non_neg_integer()
  def table_id(name), do: @tables |> Map.fetch!(name) |> elem(0)

  @doc "The op kind atom for a wire kind number, or `nil`."
  @spec op_kind(non_neg_integer()) :: atom() | nil
  def op_kind(n), do: Map.get(@op_kinds, n)

  @doc "The refusal code for a refusal atom; anything unnamed is `internal`."
  @spec refusal_code(atom()) :: non_neg_integer()
  def refusal_code(name), do: Map.get(@refusals, name, @refusals.internal)

  @doc """
  One frame of `kind` at `rev` around `body`. With `deflate: true` the body
  travels as `u32 raw_len | u32 deflate_len | raw deflate | pad` and the
  0x01 flag is set; `flags` adds the rest (0x02 END).
  """
  @spec frame(atom(), non_neg_integer(), iodata(), keyword()) :: iodata()
  def frame(kind, rev, body, opts \\ []) do
    {flags, body} =
      if opts[:deflate] do
        packed = deflate(body)
        {0x01, [<<IO.iodata_length(body)::little-32, byte_size(packed)::little-32>>, packed]}
      else
        {0, body}
      end

    flags = Bitwise.bor(flags, Keyword.get(opts, :flags, 0))
    size = IO.iodata_length(body)
    pad = pad8(size)

    [
      <<16 + size + byte_size(pad)::little-32, Map.fetch!(@frames, kind)::8, flags::8,
        @schema_hash::little-16, rev::little-64>>,
      body,
      pad
    ]
  end

  @doc """
  One table block: every row is a map holding each schema column by name
  (or the subset named in `only`, for a partial PATCH).
  """
  @spec table(atom(), [map()], [atom()] | nil) :: iodata()
  def table(name, rows, only \\ nil) do
    {id, cols} = Map.fetch!(@tables, name)
    cols = if only, do: Enum.filter(cols, fn {c, _, _} -> c in only end), else: cols
    block(id, cols, rows, fn col, _type -> &Map.get(&1, col) end)
  end

  # One pass per column straight off the rows: each value is read and
  # written once, with no row rebuilt on the way.
  defp block(id, cols, rows, value) do
    [
      <<id::little-16, length(cols)::little-16, length(rows)::little-32>>
      | Enum.map(cols, fn {col, cid, type} ->
          {wire, data} = encode(type, rows, value.(col, type))
          size = IO.iodata_length(data)
          [<<cid::little-16, wire::8, 0::8, size::little-32>>, data, pad8(size)]
        end)
    ]
  end

  defp encode(type, rows, get) when type in [:u32, :day, :time],
    do: {1, for(r <- rows, into: <<>>, do: <<u32(get.(r))::little-32>>)}

  defp encode(:u64, rows, get), do: {3, for(r <- rows, into: <<>>, do: <<get.(r)::little-64>>)}

  defp encode(:f64, rows, get) do
    {4,
     for r <- rows, into: <<>> do
       v = get.(r)
       if is_number(v), do: <<v * 1.0::little-float-64>>, else: @nan
     end}
  end

  defp encode(:str, rows, get) do
    {offsets, strings, _} =
      Enum.reduce(rows, {<<0::little-32>>, [], 0}, fn r, {offsets, strings, at} ->
        s = text(get.(r))
        at = at + byte_size(s)
        {<<offsets::binary, at::little-32>>, [s | strings], at}
      end)

    {2, [offsets, Enum.reverse(strings)]}
  end

  # A column of few distinct strings: each distinct value once, in order of
  # first appearance, then one u32 per row naming it. The dictionary is
  # built in the same pass that writes the ids.
  #   u32 nuniq | u32 offsets[nuniq + 1] | bytes | pad to 4 | u32 ids[nrows]
  defp encode(:sym, rows, get) do
    {ids, dict, n} =
      Enum.reduce(rows, {[], %{}, 0}, fn r, {ids, dict, n} ->
        s = text(get.(r))

        case dict do
          %{^s => i} -> {[<<i::little-32>> | ids], dict, n}
          _ -> {[<<n::little-32>> | ids], Map.put(dict, s, n), n + 1}
        end
      end)

    syms = dict |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

    {offsets, size} =
      Enum.reduce(syms, {<<0::little-32>>, 0}, fn s, {offsets, at} ->
        at = at + byte_size(s)
        {<<offsets::binary, at::little-32>>, at}
      end)

    pad = :binary.copy(<<0>>, rem(4 - rem(size, 4), 4))
    {5, [<<n::little-32>>, offsets, syms, pad, Enum.reverse(ids)]}
  end

  defp u32(nil), do: @none
  defp u32(true), do: 1
  defp u32(false), do: 0
  defp u32(%Date{} = d), do: Date.diff(d, @epoch)

  # A raw row's dates are SQLite's ISO text, read at fixed offsets.
  defp u32(<<y::binary-4, ?-, m::binary-2, ?-, d::binary-2>>), do: day(y, m, d)

  defp u32(
         <<y::binary-4, ?-, m::binary-2, ?-, d::binary-2, _t, hh::binary-2, ?:, mm::binary-2, ?:,
           ss::binary-2, _::binary>>
       ),
       do: day(y, m, d) * 86_400 + digits(hh) * 3600 + digits(mm) * 60 + digits(ss)

  defp u32(%DateTime{} = t), do: DateTime.to_unix(t)
  defp u32(n) when is_integer(n) and n >= 0 and n < @none, do: n
  defp u32(n) when is_float(n), do: round(n)

  # Days since 1970-01-01 from ISO digits, by arithmetic alone (Hinnant's
  # days_from_civil): no integer parsing, no calendar call.
  defp day(y, m, d) do
    {y, m, d} = {digits(y), digits(m), digits(d)}
    y = if m <= 2, do: y - 1, else: y
    era = div(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m + if(m > 2, do: -3, else: 9)) + 2, 5) + d - 1
    era * 146_097 + yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy - 719_468
  end

  defp digits(<<a, b>>), do: (a - ?0) * 10 + b - ?0
  defp digits(<<a, b, c, d>>), do: (a - ?0) * 1000 + (b - ?0) * 100 + (c - ?0) * 10 + d - ?0

  defp text(nil), do: ""
  defp text(s) when is_binary(s), do: s
  defp text(a) when is_atom(a), do: Atom.to_string(a)
  defp text(n) when is_number(n), do: to_string(n)
  defp text(list) when is_list(list), do: Enum.map_join(list, "\n", &text/1)
  defp text(%Date{} = d), do: Date.to_iso8601(d)

  # ---- What the desk sends ----

  @doc "The closed lists the card columns and views name: stages, statuses, freshness, gates, heat states, bands."
  @spec static_lookups() :: iodata()
  def static_lookups do
    keyed = fn list ->
      list |> Enum.with_index() |> Enum.map(fn {k, i} -> %{ix: i, key: k} end)
    end

    [
      table(
        :stages,
        Enum.with_index(Pipeline.stages(), fn s, i ->
          %{
            ix: i,
            key: s.key,
            label: s.label,
            hint: s.hint,
            rank: Pipeline.rank(s.key)
          }
        end)
      ),
      table(:statuses, keyed.(Job.statuses())),
      table(:freshness, keyed.(~w(unknown open thin closed blocked))),
      table(:gates, keyed.(~w(unset pursue maybe skip))),
      table(:heat_states, keyed.(@heat_states)),
      table(
        :bands,
        Enum.with_index(LifeEv.bands(), fn b, i ->
          %{ix: i, key: LifeEv.name(b.key), label: b.label, min: b.min, max: b.max}
        end)
      )
    ]
  end

  # ---- Raw tables: the account's rows as the database holds them ----

  @doc """
  A raw table block from database rows (structs or maps keyed by the
  schema's column names). Missing fields travel as none; enums as their
  name; maps as JSON text; lists the kernel reads as text joined with
  U+001F; `theme_targets` is lifted out of its map so the kernel needs no
  JSON reader.
  """
  @spec raw(atom(), [map()]) :: iodata()
  def raw(name, rows) do
    {id, cols} = Map.fetch!(@tables, name)

    # A struct is a whole row; a map may be partial (a delta carries `id`
    # plus only the fields that changed), and a column it does not carry
    # must not travel, or the reader would overwrite it with none. Rows
    # with the same fields share one block.
    rows
    |> Enum.map(fn
      %_{} = row -> Map.from_struct(row)
      row -> row
    end)
    |> Enum.group_by(&Map.keys/1)
    |> Enum.map(fn {_keys, [first | _] = group} ->
      block(id, present(first, cols), group, &getter/2)
    end)
  after
    Process.delete(@memo)
  end

  defp present(row, cols) do
    for {col, _, _} = c <- cols, carried?(row, col), do: c
  end

  defp carried?(row, :theme_targets), do: Map.has_key?(row, :theme)
  defp carried?(row, col), do: Map.has_key?(row, col)

  # How a column's value is read off a raw row, chosen once per column.
  defp getter(:theme_targets, _),
    do: &memo(Map.get(&1, :theme), fn theme -> targets(json(theme)) end)

  defp getter(:keywords, _), do: &memo(Map.get(&1, :keywords), fn k -> unit_list(json(k)) end)

  # A batch's fire is 0/1 on the wire (shared with the derived batches table).
  defp getter(:fire, :u32), do: &(Map.get(&1, :fire) in [:open_fire, "open_fire", true, 1])

  defp getter(col, type) when type in [:str, :sym] do
    fn row ->
      case Map.get(row, col) do
        %{} = map when not is_struct(map) -> Jason.encode!(map)
        value -> value
      end
    end
  end

  defp getter(col, _type), do: &Map.get(&1, col)

  defp targets(theme), do: unit_list(get_in(theme, ["targets"]) || get_in(theme, [:targets]))

  # One decode per distinct JSON text in a `raw/2` pass: a column of a few
  # themes repeated over a thousand rows decodes each once.
  defp memo(text, f) when is_binary(text) do
    memo = Process.get(@memo, %{})

    case memo do
      %{^text => v} ->
        v

      _ ->
        v = f.(text)
        Process.put(@memo, Map.put(memo, text, v))
        v
    end
  end

  defp memo(value, f), do: f.(value)

  # A raw row holds maps and lists as the JSON text SQLite stores.
  defp json("{}"), do: %{}
  defp json("[]"), do: []
  defp json(text) when is_binary(text), do: Jason.decode!(text)
  defp json(value), do: value

  defp unit_list(list) when is_list(list), do: Enum.map_join(list, <<0x1F>>, &text/1)
  defp unit_list(_), do: ""

  @doc """
  An OP frame's body read as an op: `{:ok, %{op_id, kind, target,
  fields}}`, `{:error, op_id}` when the id is readable but the kind or
  fields are not (answer it with a NACK), or `:error` when not even the
  header is.
  """
  @spec op(binary()) :: {:ok, map()} | {:error, non_neg_integer()} | :error
  def op(<<op_id::little-64, kind::8, n::8, _::16, target::little-32, fields::binary>>) do
    with name when not is_nil(name) <- op_kind(kind),
         {:ok, fields} <- fields(fields, n, []) do
      {:ok, %{op_id: op_id, kind: name, target: target, fields: fields}}
    else
      _ -> {:error, op_id}
    end
  end

  def op(_body), do: :error

  defp fields(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp fields(<<len::little-16, field::binary-size(len), rest::binary>>, n, acc),
    do: fields(rest, n - 1, [field | acc])

  defp fields(_, _, _), do: :error

  @doc "The ACK of an op, at the rev that settles it."
  @spec ack(non_neg_integer(), non_neg_integer()) :: iodata()
  def ack(op_id, rev), do: frame(:ack, rev, <<op_id::little-64>>)

  @doc "The NACK of an op: the refusal's code and a message a person can read."
  @spec nack(non_neg_integer(), term(), non_neg_integer()) :: iodata()
  def nack(op_id, reason, rev) do
    {name, message} = refusal(reason)
    msg = String.slice(message, 0, 400)

    frame(:nack, rev, [
      <<op_id::little-64, refusal_code(name)::8, 0::8, byte_size(msg)::little-16>>,
      msg
    ])
  end

  defp refusal({:argument, name}), do: {:argument, "Need a #{name}."}
  defp refusal({name, message}) when is_atom(name) and is_binary(message), do: {name, message}
  defp refusal(name) when is_atom(name), do: {name, Atom.to_string(name)}
  defp refusal(_), do: {:internal, "internal"}

  @doc """
  Cut whole frames off the front of a stream buffer. Answers the frames as
  `{kind_atom | integer, flags, rev, body}` in order and the bytes left
  over, or `{:error, reason}` for a frame no reader should keep going past:
  a length below 16 or not a multiple of 8, or another schema.
  """
  @spec split(binary()) :: {:ok, [tuple()], binary()} | {:error, atom()}
  def split(buffer), do: split(buffer, [])

  defp split(<<len::little-32, _::binary>>, _acc) when len < 16 or rem(len, 8) != 0,
    do: {:error, :frame_length}

  defp split(
         <<len::little-32, kind::8, flags::8, hash::little-16, rev::little-64, rest::binary>> =
           buffer,
         acc
       )
       when byte_size(buffer) >= len do
    if hash != @schema_hash do
      {:error, :schema}
    else
      body_len = len - 16
      <<body::binary-size(^body_len), rest::binary>> = rest
      split(rest, [{Map.get(@kinds, kind, kind), flags, rev, body} | acc])
    end
  end

  defp split(buffer, acc), do: {:ok, Enum.reverse(acc), buffer}

  # Level 1: on the boot's tables it costs a third of the default's time
  # for 1-10% more bytes, and the boot waits on it.
  defp deflate(body) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 1, :deflated, -15, 8, :default)
    packed = IO.iodata_to_binary(:zlib.deflate(z, body, :finish))
    :zlib.close(z)
    packed
  end

  defp pad8(len) do
    case rem(len, 8) do
      0 -> <<>>
      r -> :binary.copy(<<0>>, 8 - r)
    end
  end
end
