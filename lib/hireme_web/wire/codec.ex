defmodule HiremeWeb.Wire.Codec do
  @moduledoc """
  The BEAM end of wire v2: frames, table runs and op cells.

  The byte layouts are the doc comment of `native/wire/src/lib.rs`; this
  module encodes and decodes exactly those bytes. Frame kinds, table and
  column ids, enum codes and `wire_hash` come from `schema/hireme.schema`
  through `Hireme.Schema`, so nothing here names an id.

  Cells cross into Elixir typed: a u32 cell for a `day` column is a
  `Date`, for a `time` column a `DateTime`, for an `enum` column its atom,
  for a `bool` column `true`/`false`; a str cell for a `json` column is
  decoded JSON. A cell whose wire type is not its column's is `{:error,
  :type}`, never cast.
  """

  import Bitwise
  alias Hireme.Schema

  @header 16
  @none32 0xFFFF_FFFF
  @min64 -0x8000_0000_0000_0000
  @nan <<0, 0, 0, 0, 0, 0, 0xF8, 0x7F>>
  @deflate 0x01
  @end_flag 0x02
  @max_up 16 <<< 20
  @max_ops 256
  @max_inflated 256 <<< 20

  @t_null 0
  @t_u32 1
  @t_str 2
  @t_i64 3
  @t_f64 4

  @frames Map.new(Schema.frames(), &{String.to_atom(&1.name), &1.id})
  @frame_names Map.new(Schema.frames(), &{&1.id, String.to_atom(&1.name)})
  @enum_codes Map.new(Schema.model().enums, fn e ->
                {e.name,
                 e.values |> Enum.with_index() |> Map.new(fn {v, i} -> {String.to_atom(v), i} end)}
              end)
  @enum_atoms Map.new(
                Schema.model().enums,
                &{&1.name, List.to_tuple(Enum.map(&1.values, fn v -> String.to_atom(v) end))}
              )

  @as_of 0xFFF0
  @source 0xFFF1
  @gone 0xFFFE

  @verbs %{1 => :put, 2 => :drop, 3 => :command}
  @keyed 0x01
  @create_only 0x02
  @expect_rev 0x04

  def as_of_col, do: @as_of
  def source_col, do: @source
  def max_up, do: @max_up

  # ------------------------------------------------------------ frames

  @doc "A whole frame: header, body, zero pad to 8."
  @spec frame(atom, non_neg_integer, iodata, keyword) :: binary
  def frame(kind, rev, body, opts \\ []) do
    body = IO.iodata_to_binary(body)
    flags = if opts[:end], do: @end_flag, else: 0

    {flags, body} =
      if opts[:deflate] && byte_size(body) >= 256 do
        packed = deflate(body)

        if pad8(8 + byte_size(packed)) < byte_size(body),
          do:
            {flags ||| @deflate,
             <<byte_size(body)::little-32, byte_size(packed)::little-32, packed::binary>>},
          else: {flags, body}
      else
        {flags, body}
      end

    body = pad(body)
    len = @header + byte_size(body)

    <<len::little-32, Map.fetch!(@frames, kind)::8, flags::8, Schema.wire_hash()::little-16,
      rev::little-64, body::binary>>
  end

  @doc """
  Splits the first whole frame off a byte stream.
  `{:ok, frame, rest}`, `:more`, or `{:error, :len}` for a stream that is not frames.
  """
  def split(buf, max \\ @max_up)

  def split(<<len::little-32, _::binary>> = buf, max) when byte_size(buf) >= @header do
    cond do
      len < @header or rem(len, 8) != 0 or len > max -> {:error, :len}
      byte_size(buf) < len -> :more
      # Not `true ->`: Dialyzer reads a literal-true tail as a false branch it cannot match.
      :else -> {:ok, binary_part(buf, 0, len), binary_part(buf, len, byte_size(buf) - len)}
    end
  end

  def split(_buf, _max), do: :more

  @doc """
  Parses one whole frame: `{:ok, kind_atom, flags, rev, plain_body}`. A
  DEFLATE body may inflate to at most `max_inflated` bytes; a session
  reading a peer's frame passes `max_up/0`.
  """
  def decode(frame, max_inflated \\ @max_inflated)

  def decode(
        <<len::little-32, kind::8, flags::8, hash::little-16, rev::little-64, body::binary>> = f,
        max_inflated
      )
      when byte_size(f) == len and len >= @header and rem(len, 8) == 0 do
    with :ok <- if(hash == Schema.wire_hash(), do: :ok, else: {:error, :hash}),
         {:ok, name} <- frame_name(kind),
         # Bits tested without bnot, which Dialyzer types as never zero.
         :ok <- if((flags &&& (@deflate ||| @end_flag)) == flags, do: :ok, else: {:error, :body}),
         {:ok, body} <- inflate(flags, body, max_inflated) do
      {:ok, name, flags, rev, body}
    end
  end

  def decode(_, _), do: {:error, :len}

  defp frame_name(kind) do
    case Map.fetch(@frame_names, kind) do
      :error -> {:error, :kind}
      ok -> ok
    end
  end

  defp inflate(flags, body, _max) when (flags &&& @deflate) == 0, do: {:ok, body}

  defp inflate(_, <<raw::little-32, n::little-32, rest::binary>> = body, max)
       when raw <= max and rem(raw, 8) == 0 and 8 + n <= byte_size(body) do
    pad = byte_size(body) - 8 - n

    if pad8(8 + n) == byte_size(body) and zeros?(binary_part(rest, n, pad)) do
      try do
        out = inflate_raw(binary_part(rest, 0, n), raw)
        if byte_size(out) == raw, do: {:ok, out}, else: {:error, :inflate}
      rescue
        _ -> {:error, :inflate}
      end
    else
      {:error, :inflate}
    end
  end

  defp inflate(_, _, _), do: {:error, :inflate}

  defp deflate(bin) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, 6, :deflated, -15, 8, :default)
      out = :zlib.deflate(z, bin, :finish)
      :zlib.deflateEnd(z)
      IO.iodata_to_binary(out)
    after
      :zlib.close(z)
    end
  end

  # Inflates at most `limit` bytes, so a small body cannot expand without bound.
  defp inflate_raw(bin, limit) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      out = inflate_loop(z, :zlib.safeInflate(z, bin), [], 0, limit)
      # Raises on a stream cut before its end marker, as native/wire refuses it.
      :ok = :zlib.inflateEnd(z)
      IO.iodata_to_binary(out)
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, chunk}, acc, n, limit) do
    n = n + IO.iodata_length(chunk)
    if n > limit, do: raise("inflate over limit")
    acc = [acc | chunk]

    case state do
      :continue -> inflate_loop(z, :zlib.safeInflate(z, []), acc, n, limit)
      :finished -> acc
    end
  end

  # ------------------------------------------------------- small frames

  def hello(body) do
    case body do
      <<cred::8, 0::56, snapshot::little-64, schema_rev::little-64, rest::binary>> ->
        with {:ok, credential, rest} <- field(rest),
             {:ok, label, ""} <- field(rest),
             true <- String.valid?(label) do
          {:ok,
           %{
             cred: cred_name(cred),
             snapshot_rev: snapshot,
             schema_rev: schema_rev,
             credential: credential,
             label: label
           }}
        else
          _ -> {:error, :body}
        end

      _ ->
        {:error, :body}
    end
  end

  defp cred_name(1), do: :ticket
  defp cred_name(2), do: :key
  defp cred_name(_), do: :unknown

  @doc "HELLO, for tests and tools that play the client."
  def encode_hello(cred, credential, label, snapshot_rev \\ 0, schema_rev \\ 0) do
    code = %{ticket: 1, key: 2}[cred]

    frame(:HELLO, 0, [
      <<code::8, 0::56, snapshot_rev::little-64, schema_rev::little-64>>,
      put_field(credential),
      put_field(label)
    ])
  end

  def welcome(rev, w) do
    frame(:WELCOME, rev, [
      <<w.account_id::little-64, w.session_id::little-64, w.schema_rev::little-64,
        w.read_mask::little-16, w.write_mask::little-16, bool(w.may_delete)::8, bool(w.lease)::8,
        0::16>>,
      put_field(w.label)
    ])
  end

  @doc "ACK for `[%{op_id, rev, id}]`."
  def acks(rev, acks) do
    frame(:ACK, rev, [
      <<length(acks)::little-32, 0::32>>
      | Enum.map(acks, fn %{op_id: op_id, rev: rev, id: id} ->
          <<op_id::little-64, rev::little-64, id::little-32, 0::32>>
        end)
    ])
  end

  @doc "NACK for `[%{op_id, code, data}]`, `data` already JSON."
  def nacks(rev, nacks) do
    frame(:NACK, rev, [
      <<length(nacks)::little-32, 0::32>>
      | Enum.map(nacks, fn %{op_id: op_id, code: code, data: data} ->
          [<<op_id::little-64, code::little-16, 0::48>>, put_field(data)]
        end)
    ])
  end

  def ping(kind, nonce), do: frame(kind, 0, <<nonce::little-64>>)

  def nonce(<<n::little-64>>), do: {:ok, n}
  def nonce(_), do: {:error, :body}

  def bye(rev, reason, message \\ "") do
    frame(:BYE, rev, [<<enum_code("bye", reason)::8, 0::56>>, put_field(message)], end: true)
  end

  def rpc(<<id::little-32, 0::32, rest::binary>>) do
    with {:ok, method, rest} <- field(rest),
         {:ok, params, ""} <- field(rest),
         true <- String.valid?(method) do
      {:ok, id, method, params}
    else
      _ -> {:error, :body}
    end
  end

  def rpc(_), do: {:error, :body}

  def encode_rpc(id, method, params_json),
    do: frame(:RPC, 0, [<<id::little-32, 0::32>>, put_field(method), put_field(params_json)])

  def reply(rev, id, ok?, json),
    do: frame(:REPLY, rev, [<<id::little-32, bool(ok?)::8, 0::24>>, put_field(json)])

  defp bool(true), do: 1
  defp bool(_), do: 0

  defp field(<<n::little-32, rest::binary>>) do
    p = pad8(4 + n) - 4 - n

    case rest do
      <<v::binary-size(^n), pad::binary-size(^p), more::binary>> ->
        if zeros?(pad), do: {:ok, v, more}, else: :error

      _ ->
        :error
    end
  end

  defp field(_), do: :error

  defp put_field(bin) do
    n = byte_size(bin)
    [<<n::little-32>>, bin, :binary.copy(<<0>>, pad8(4 + n) - 4 - n)]
  end

  defp zeros?(bin), do: bin == :binary.copy(<<0>>, byte_size(bin))

  # --------------------------------------------------------------- ops

  @doc """
  Decodes an OPS body into ops, each
  `%{op_id, verb, keyed, create_only, expect_rev, subject, target, cells, raw}`
  with `cells` a list of `{col_id, wire_type, raw_value}` (raw_value: integer,
  binary, float, `:nan` for a non-finite f64, `nil` for null). The whole body
  is validated first; a malformed frame is refused whole.
  """
  def ops(<<n::little-32, 0::32, rest::binary>>) when n <= @max_ops do
    case ops(rest, n, []) do
      {:ok, ops, ""} -> {:ok, ops}
      _ -> {:error, :body}
    end
  end

  def ops(_), do: {:error, :body}

  defp ops(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp ops(bin, n, acc) do
    case op(bin) do
      {:ok, op, rest} -> ops(rest, n - 1, [op | acc])
      :error -> :error
    end
  end

  @doc "One op from the start of `bin`: `{:ok, op, rest}` or `:error`."
  def op(
        <<op_id::little-64, verb::8, flags::8, subject::little-16, target::little-32,
          ncols::little-16, 0::16, expect::little-32, rest::binary>> = bin
      )
      when verb in 1..3 and (flags &&& (@keyed ||| @create_only ||| @expect_rev)) == flags do
    if (flags &&& @expect_rev) == 0 and expect != 0 do
      :error
    else
      case cells(rest, ncols, [], %{}) do
        {:ok, cells, more} ->
          raw = binary_part(bin, 0, byte_size(bin) - byte_size(more))

          {:ok,
           %{
             op_id: op_id,
             verb: @verbs[verb],
             keyed: (flags &&& @keyed) != 0,
             create_only: (flags &&& @create_only) != 0,
             expect_rev: if((flags &&& @expect_rev) != 0, do: expect),
             subject: subject,
             target: target,
             cells: cells,
             raw: raw
           }, more}

        :error ->
          :error
      end
    end
  end

  def op(_), do: :error

  defp cells(rest, 0, acc, _seen), do: {:ok, Enum.reverse(acc), rest}

  defp cells(<<col::little-16, ty::8, 0::8, len::little-32, rest::binary>>, n, acc, seen) do
    p = pad8(8 + len) - 8 - len

    # The columns seen so far, as a plain map (a MapSet's opaque type does
    # not survive this recursion for Dialyzer).
    with false <- Map.has_key?(seen, col),
         <<v::binary-size(^len), pad::binary-size(^p), more::binary>> <- rest,
         true <- zeros?(pad),
         {:ok, value} <- cell_value(ty, v) do
      cells(more, n - 1, [{col, ty, value} | acc], Map.put(seen, col, true))
    else
      _ -> :error
    end
  end

  defp cells(_, _, _, _), do: :error

  defp cell_value(@t_null, ""), do: {:ok, nil}
  defp cell_value(@t_u32, <<v::little-32>>), do: {:ok, v}
  defp cell_value(@t_i64, <<v::little-signed-64>>), do: {:ok, v}
  defp cell_value(@t_f64, <<v::little-float-64>>), do: {:ok, v}
  defp cell_value(@t_f64, <<_::64>>), do: {:ok, :nan}
  defp cell_value(@t_str, v), do: if(String.valid?(v), do: {:ok, v}, else: :error)
  defp cell_value(_, _), do: :error

  @doc "Encodes ops (tests, the importer's tools): `[{op_id, verb, flags, subject, target, expect_rev, [{col, type, value}]}]`."
  def encode_ops(ops) do
    frame(:OPS, 0, [<<length(ops)::little-32, 0::32>> | Enum.map(ops, &encode_op/1)])
  end

  def encode_op({op_id, verb, flags, subject, target, expect_rev, cells}) do
    v = %{put: 1, drop: 2, command: 3}[verb]
    flags = if expect_rev, do: flags ||| @expect_rev, else: flags - (flags &&& @expect_rev)

    [
      <<op_id::little-64, v::8, flags::8, subject::little-16, target::little-32,
        length(cells)::little-16, 0::16, expect_rev || 0::little-32>>
      | Enum.map(cells, fn {col, ty, value} ->
          bytes = encode_cell(ty, value)
          n = byte_size(bytes)

          [
            <<col::little-16, ty::8, 0::8, n::little-32>>,
            bytes,
            :binary.copy(<<0>>, pad8(8 + n) - 8 - n)
          ]
        end)
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_cell(@t_null, _), do: ""
  # Out of range is a caller's bug: a binary segment would silently wrap it.
  defp encode_cell(@t_u32, v) when v in 0..0xFFFF_FFFF, do: <<v::little-32>>

  defp encode_cell(@t_i64, v) when v in -0x8000_0000_0000_0000..0x7FFF_FFFF_FFFF_FFFF,
    do: <<v::little-signed-64>>

  defp encode_cell(ty, v) when ty in [@t_u32, @t_i64],
    do: raise(ArgumentError, "#{inspect(v)} does not fit wire type #{ty}")

  defp encode_cell(@t_f64, :nan), do: @nan
  defp encode_cell(@t_f64, v), do: <<v::little-float-64>>
  defp encode_cell(@t_str, v), do: v

  # ------------------------------------------------- cell <-> column value

  @doc """
  A decoded cell as the column's Elixir value, or `{:error, :type}`.
  Null sentinels in a cell are refused; an empty string is nil.
  """
  def cell_to_value(_col, {_, @t_null, nil}), do: {:ok, nil}

  def cell_to_value(col, {_, ty, raw}) do
    if ty == cell_type(col), do: to_value(col, raw), else: {:error, :type}
  end

  defp to_value(%{type: t}, @none32) when t not in [:i64, :f64], do: {:error, :type}
  defp to_value(_col, :nan), do: {:error, :type}
  defp to_value(%{type: :i64}, @min64), do: {:error, :type}
  defp to_value(_col, ""), do: {:ok, nil}
  defp to_value(%{type: t}, v) when t in [:id, :ref, :u32] and is_integer(v), do: {:ok, v}
  defp to_value(%{type: :u8}, v) when v in 0..255, do: {:ok, v}
  defp to_value(%{type: :bool}, 0), do: {:ok, false}
  defp to_value(%{type: :bool}, 1), do: {:ok, true}

  defp to_value(%{type: :day}, v) when is_integer(v) do
    case day_from_wire(v) do
      nil -> {:error, :type}
      d -> {:ok, d}
    end
  end

  defp to_value(%{type: :time}, v) when is_integer(v), do: {:ok, DateTime.from_unix!(v)}

  defp to_value(%{type: :enum, enum: e}, v) when is_integer(v) do
    atoms = Map.fetch!(@enum_atoms, e)
    if v < tuple_size(atoms), do: {:ok, elem(atoms, v)}, else: {:error, :type}
  end

  defp to_value(%{type: :i64}, v) when is_integer(v), do: {:ok, v}
  defp to_value(%{type: :f64}, v) when is_float(v), do: {:ok, v}
  defp to_value(%{type: t}, v) when t in [:str, :text] and is_binary(v), do: {:ok, v}

  defp to_value(%{type: :json}, v) when is_binary(v) do
    with {:ok, j} <- JSON.decode(v), true <- bounded?(j) do
      {:ok, j}
    else
      _ -> {:error, :type}
    end
  end

  defp to_value(_, _), do: {:error, :type}

  # A JSON integer is an i64: a million-digit one decodes fast but costs
  # seconds to encode again under the node's single write lock.
  # Comparisons, not `in`: `in` repeats is_integer/1, which the guard has
  # settled, and Dialyzer flags the branch it can never take.
  defp bounded?(i) when is_integer(i),
    do: i >= -0x8000_0000_0000_0000 and i <= 0x7FFF_FFFF_FFFF_FFFF

  defp bounded?(l) when is_list(l), do: Enum.all?(l, &bounded?/1)
  defp bounded?(m) when is_map(m), do: Enum.all?(m, fn {_, v} -> bounded?(v) end)
  defp bounded?(_), do: true

  @doc "The type an op cell for this column must carry: its wire type."
  def cell_type(%{wire: w}), do: w

  @doc "A column's wire type code in BOOT and PATCH."
  def wire_type(%{wire: w}), do: w

  @doc "An enum value's code; `nil` for one the enum does not have."
  def enum_code(enum, value) when is_atom(value),
    do: get_in(@enum_codes, [to_string(enum), value])

  def enum_code(enum, value) when is_binary(value) do
    enum_code(enum, String.to_existing_atom(value))
  rescue
    ArgumentError -> nil
  end

  @doc """
  A date as a wire `day`: days since 0000-01-01, proleptic Gregorian
  (`Date.to_gregorian_days/1`), from 0 to `Schema.day_max/0` (9999-12-31);
  nil outside it. Every day conversion in Elixir goes through this pair.
  """
  def day_to_wire(%Date{} = d) do
    n = Date.to_gregorian_days(d)
    if n >= 0 and n <= Schema.day_max(), do: n
  end

  @doc "A wire `day` as a date; nil outside 0..`Schema.day_max/0`."
  def day_from_wire(n) when is_integer(n) and n >= 0,
    do: if(n <= Schema.day_max(), do: Date.from_gregorian_days(n))

  def day_from_wire(_), do: nil

  @doc "A column's Elixir value as its wire value (the kernel's and BOOT's form)."
  def to_wire(_col, nil), do: nil
  def to_wire(%{type: :bool}, v), do: bool(v)
  def to_wire(%{type: :day}, %Date{} = d), do: day_to_wire(d)
  def to_wire(%{type: :time}, %DateTime{} = t), do: DateTime.to_unix(t)

  def to_wire(%{type: :time}, %NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  def to_wire(%{type: :enum, enum: e}, v), do: enum_code(e, v)
  def to_wire(%{type: :json}, v), do: JSON.encode!(v)
  def to_wire(_col, v), do: v

  @doc """
  A wire value (the kernel's effects: integers for days, times, enum codes
  and bools; binaries for text and JSON) as the column's Elixir value.
  `{:ok, value}` or `{:error, :type}`.
  """
  def from_wire(_col, nil), do: {:ok, nil}
  def from_wire(%{type: t} = col, v) when t in [:str, :text], do: to_value(col, v)
  def from_wire(col, v), do: to_value(col, v)

  # -------------------------------------------------------- table runs

  @doc """
  One table-run block: `cols` is `[{col_id, wire_type, values}]`, every
  `values` a list of `nrows` wire values (`nil` is null).
  """
  def block(table_id, nrows, cols) do
    [<<table_id::little-16, length(cols)::little-16, nrows::little-32>> | Enum.map(cols, &col/1)]
  end

  defp col({id, ty, values}) do
    data = IO.iodata_to_binary(col_data(ty, values))
    n = byte_size(data)
    [<<id::little-16, ty::8, 0::8, n::little-32>>, data, :binary.copy(<<0>>, pad8(n) - n)]
  end

  defp col_data(@t_u32, vs), do: for(v <- vs, into: <<>>, do: <<v || @none32::little-32>>)
  defp col_data(@t_i64, vs), do: for(v <- vs, into: <<>>, do: <<v || @min64::little-signed-64>>)

  defp col_data(@t_f64, vs),
    do: Enum.map(vs, &if(&1, do: <<&1 * 1.0::little-float-64>>, else: @nan))

  defp col_data(@t_str, vs) do
    {offsets, _} =
      Enum.map_reduce(vs, 0, fn v, at ->
        at = at + byte_size(v || "")
        {<<at::little-32>>, at}
      end)

    [<<0::little-32>>, offsets, Enum.map(vs, &(&1 || ""))]
  end

  @doc """
  A block from rows (maps keyed by column name atoms, or structs): every
  column in `cols` (column structs), values converted to the wire.
  """
  def rows_block(table, cols, rows) do
    block(
      table.id,
      length(rows),
      Enum.map(cols, fn c ->
        key = String.to_atom(c.name)
        wire = converter(c)
        {c.id, wire_type(c), Enum.map(rows, &wire.(Map.get(&1, key)))}
      end)
    )
  end

  # `to_wire/2` with the column's decisions taken once, not per cell: BOOT
  # encodes every cell of every resident row.
  defp converter(%{type: :enum, enum: e}) do
    codes = Map.fetch!(@enum_codes, e)

    fn
      nil -> nil
      v -> Map.get(codes, v)
    end
  end

  defp converter(%{type: t})
       when t in [:id, :ref, :u8, :u32, :i64, :f64, :str, :text],
       do: &Function.identity/1

  defp converter(col), do: &to_wire(col, &1)

  @doc "The gone blocks deleting `[{table_id, id}]`."
  def gone_block([]), do: []

  # One block per table, its only column the reserved GONE id (native/wire).
  def gone_block(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(fn {table_id, ids} -> block(table_id, length(ids), [{@gone, @t_u32, ids}]) end)
  end

  # Arithmetic, not a bit mask, so the type checker sees a non-negative size.
  defp pad8(n), do: n + rem(8 - rem(n, 8), 8)
  defp pad(bin), do: <<bin::binary, 0::size((pad8(byte_size(bin)) - byte_size(bin)) * 8)>>
end
