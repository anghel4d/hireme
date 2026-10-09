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
        raw = IO.iodata_to_binary(body)
        packed = :zlib.zip(raw)
        {0x01, [<<byte_size(raw)::little-32, byte_size(packed)::little-32>>, packed]}
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
    n = length(rows)

    [
      <<id::little-16, length(cols)::little-16, n::little-32>>
      | Enum.map(cols, fn {col, cid, type} ->
          column(cid, type, Enum.map(rows, &Map.get(&1, col)))
        end)
    ]
  end

  defp column(cid, type, values) do
    {wire, data} = encode(type, values)
    size = IO.iodata_length(data)
    [<<cid::little-16, wire::8, 0::8, size::little-32>>, data, pad8(size)]
  end

  defp encode(type, values) when type in [:u32, :day, :time],
    do: {1, for(v <- values, into: <<>>, do: <<u32(v)::little-32>>)}

  defp encode(:u64, values), do: {3, for(v <- values, into: <<>>, do: <<v::little-64>>)}

  defp encode(:f64, values) do
    {4,
     for v <- values, into: <<>> do
       if is_number(v), do: <<v * 1.0::little-float-64>>, else: @nan
     end}
  end

  defp encode(:str, values) do
    strings = Enum.map(values, &text/1)

    {offsets, total} =
      Enum.reduce(strings, {[<<0::little-32>>], 0}, fn s, {acc, at} ->
        at = at + byte_size(s)
        {[acc, <<at::little-32>>], at}
      end)

    _ = total
    {2, [offsets, strings]}
  end

  defp u32(nil), do: @none
  defp u32(true), do: 1
  defp u32(false), do: 0
  defp u32(%Date{} = d), do: Date.diff(d, @epoch)
  defp u32(%DateTime{} = t), do: DateTime.to_unix(t)
  defp u32(%NaiveDateTime{} = t), do: t |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
  defp u32(n) when is_integer(n) and n >= 0 and n < @none, do: n
  defp u32(n) when is_float(n), do: round(n)

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
            rank: Pipeline.rank(s.key),
            fire_locked: Pipeline.fire_locked?(s.key),
            hot: Hireme.Heat.hot_stage?(s.key),
            queue: Hireme.Heat.entering?(:discovered, s.key)
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
  U+001F; `theme_targets` and `variety_*` are lifted out of their maps so
  the kernel needs no JSON reader.
  """
  @spec raw(atom(), [map()]) :: iodata()
  def raw(name, rows) do
    {_id, cols} = Map.fetch!(@tables, name)
    table(name, Enum.map(rows, &raw_row(&1, cols)))
  end

  defp raw_row(%_{} = row, cols), do: raw_row(Map.from_struct(row), cols)

  defp raw_row(row, cols) do
    Map.new(cols, fn {col, _cid, type} -> {col, raw_value(row, col, type)} end)
  end

  defp raw_value(row, :theme_targets, _),
    do: unit_list(get_in(row, [:theme, "targets"]) || get_in(row, [:theme, :targets]))

  defp raw_value(row, :variety_flags, _), do: unit_list(variety(row, "flags"))

  defp raw_value(row, col, :u32)
       when col in [
              :variety_apps,
              :variety_companies,
              :variety_roles,
              :variety_locations,
              :variety_fits
            ] do
    case variety(row, col |> Atom.to_string() |> String.replace_prefix("variety_", "")) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp raw_value(row, :keywords, _), do: unit_list(Map.get(row, :keywords))

  # A batch's fire is 0/1 on the wire (shared with the derived batches table).
  defp raw_value(row, :fire, :u32), do: Map.get(row, :fire) in [:open_fire, "open_fire", true, 1]

  defp raw_value(row, col, type) do
    case Map.get(row, col) do
      %{} = map when type == :str and not is_struct(map) -> Jason.encode!(map)
      value -> value
    end
  end

  defp variety(row, key) do
    case Map.get(row, :variety) do
      %{} = v -> Map.get(v, key) || Map.get(v, String.to_existing_atom(key))
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp unit_list(list) when is_list(list), do: Enum.map_join(list, <<0x1F>>, &text/1)
  defp unit_list(_), do: ""

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

  defp pad8(len) do
    case rem(len, 8) do
      0 -> <<>>
      r -> :binary.copy(<<0>>, 8 - r)
    end
  end
end
