defmodule HiremeWeb.Wire.Codec do
  @moduledoc """
  The BEAM end of wire v2: frames, table runs and op cells.

  The bytes are native/wire's, through the NIF (`Hireme.Kernel.Nif`): the
  crate every client reads with is the one implementation of the layouts
  its doc comment states. This module adds what only the node does,
  packing bodies and text cells with OTP's zstd, and the Elixir types of
  cells. Frame kinds and enum codes come from `schema/hireme.schema`
  through `Hireme.Schema`, so nothing here names an id.

  Cells cross into Elixir typed: a u32 cell for a `day` column is a
  `Date`, for a `time` column a `DateTime`, for an `enum` column its atom,
  for a `bool` column `true`/`false`; a str cell for a `json` column is
  decoded JSON. A cell whose wire type is not its column's is `{:error,
  :type}`, never cast.
  """

  import Bitwise
  alias Hireme.Kernel.Nif
  alias Hireme.Schema

  @none32 0xFFFF_FFFF
  @min64 -0x8000_0000_0000_0000
  @zstd 0x01
  @end_flag 0x02
  # An up OPS frame that is part of one atomic burst; the burst's last frame is also END.
  @atomic 0x04
  @max_up 16 <<< 20
  @max_inflated 256 <<< 20
  # Bodies and text cells under this many bytes travel raw.
  @floor 256
  # A block of more cells than this (a desk's table in a BOOT) is encoded on a dirty scheduler.
  @dirty_cells 4_096
  # A body to shuffle past this many bytes (about 150 us of work) goes there too.
  @dirty_bytes 256 <<< 10

  @t_null 0
  @t_u32 1
  @t_str 2
  @t_zstr 5

  # The zstd dictionaries both ends embed; their ids and hashes are in
  # schema/hireme.schema's dict lines, so wire_hash moves with them.
  @dicts Map.new([:text, :frame], fn k ->
           path = Path.expand("../../../priv/wire/#{k}.zdict", __DIR__)
           @external_resource path
           {k, File.read!(path)}
         end)
  @runs [:BOOT, :PATCH, :TICK]

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

  def as_of_col, do: @as_of
  def source_col, do: @source
  def max_up, do: @max_up

  # ------------------------------------------------------------ frames

  @doc "A whole frame: header, body, zero pad to 8; `compress:` packs a body packing shrinks, `end:` flags END."
  @spec frame(atom, non_neg_integer, iodata, keyword) :: binary
  def frame(kind, rev, body, opts \\ []) do
    body = IO.iodata_to_binary(body)
    flags = if opts[:end], do: @end_flag, else: 0
    packed = opts[:compress] && byte_size(body) >= @floor && zstd(shuffle(kind, body), 9, :frame)
    Nif.frame(Map.fetch!(@frames, kind), flags, rev, body, packed || nil)
  end

  @doc """
  Parses one whole frame: `{:ok, kind_atom, flags, rev, plain_body}`, or
  `{:error, :len | :hash | :kind | :body | :inflate}`. A peer's frame
  (`:up`) never comes packed (no client compresses), so a ZSTD flag on one
  is refused unread; a `:down` body unpacks to at most 256 MiB.
  """
  def decode(frame, dir \\ :down) do
    with {kind, flags, rev, body} <- Nif.open(frame, dir == :up),
         body when is_binary(body) <-
           if((flags &&& @zstd) == 0, do: body, else: Nif.unpack(frame, @max_inflated)) do
      {:ok, Map.fetch!(@frame_names, kind), flags, rev, body}
    else
      nil -> {:error, :inflate}
      error -> error
    end
  end

  @doc "Whether an up frame's flags mark it part of an atomic burst, and whether it ends one."
  def burst(flags), do: {(flags &&& @atomic) != 0, (flags &&& @end_flag) != 0}

  # One zstd frame against a dictionary, its content size and the
  # dictionary's id stated (native/wire refuses any other).
  defp zstd(bin, level, dict) do
    opts = %{
      compressionLevel: level,
      dictionary: dict(dict, level),
      checksumFlag: false,
      contentSizeFlag: true,
      dictIDFlag: true
    }

    IO.iodata_to_binary(:zstd.compress(bin, opts))
  end

  # Compiled dictionaries live once per node, by kind and level.
  defp dict(kind, level) do
    key = {__MODULE__, kind, level}

    :persistent_term.get(key, nil) ||
      tap(
        elem(:zstd.dict(:compress, Map.fetch!(@dicts, kind), %{compressionLevel: level}), 1),
        &:persistent_term.put(key, &1)
      )
  end

  # A table run's fixed-width columns as byte planes (and a str column's
  # offsets as deltas first), so like bytes sit together for zstd: headers,
  # pads, text and sym/list columns stay as they are. native/wire undoes it.
  defp shuffle(kind, body) when kind in @runs do
    case if(byte_size(body) > @dirty_bytes, do: Nif.shuffle_dirty(body), else: Nif.shuffle(body)) do
      nil -> raise ArgumentError, "a table run that does not walk"
      shuffled -> shuffled
    end
  end

  defp shuffle(_kind, body), do: body

  # A text cell as it travels: raw under the floor, past what a client
  # unpacks (native/wire's MAX_TEXT) or when packing does not pay, else zstd
  # 19 against the text dictionary, packed once per content. A text packing
  # does not shrink is remembered as :raw, not copied.
  defp zcell(s) when s in [nil, ""], do: ""
  defp zcell(s) when byte_size(s) < @floor or byte_size(s) > 16 <<< 20, do: <<0, s::binary>>

  defp zcell(s) do
    key = :crypto.hash(:sha256, s)

    case lookup(key) do
      nil ->
        z = zstd(s, 19, :text)
        cell = if byte_size(z) < byte_size(s), do: <<1, z::binary>>, else: :raw
        remember(key, cell)
        if cell == :raw, do: <<0, s::binary>>, else: cell

      :raw ->
        <<0, s::binary>>

      cell ->
        cell
    end
  end

  @ztext :hireme_ztext
  # Past this much memory the cache starts over.
  @ztext_bytes 256 <<< 20

  @doc "The packed-text cache's table: one per node, owned by its caller (the sequencers' supervisor)."
  def ztext_table,
    do: :ets.new(@ztext, [:named_table, :public, read_concurrency: true, write_concurrency: true])

  defp lookup(key) do
    case :ets.lookup(@ztext, key) do
      [{_, cell}] -> cell
      [] -> nil
    end
  end

  defp remember(key, cell) do
    if :ets.info(@ztext, :memory) * :erlang.system_info(:wordsize) >= @ztext_bytes,
      do: :ets.delete_all_objects(@ztext)

    :ets.insert(@ztext, {key, cell})
  end

  # ------------------------------------------------------- small frames

  # Bodies read: `{:ok, ...}` or `{:error, :body}`.
  defdelegate hello(body), to: Nif
  defdelegate rpc(body), to: Nif
  defdelegate nonce(body), to: Nif

  @doc "HELLO, for tests and tools that play the client."
  def encode_hello(cred, credential, label, snapshot_rev \\ 0, schema_rev \\ 0),
    do:
      small(:HELLO, 0, {%{ticket: 1, key: 2}[cred], credential, label, snapshot_rev, schema_rev})

  def welcome(rev, w) do
    masks = {w.read_mask, w.write_mask, w.may_delete, w.lease}
    small(:WELCOME, rev, {{w.account_id, w.session_id, w.schema_rev}, masks, w.label})
  end

  @doc "ACK for `[%{op_id, rev, id}]`."
  def acks(rev, acks), do: small(:ACK, rev, for(a <- acks, do: {a.op_id, a.rev, a.id}))
  @doc "NACK for `[%{op_id, code, data}]`, `data` already JSON."
  def nacks(rev, nacks), do: small(:NACK, rev, for(n <- nacks, do: {n.op_id, n.code, n.data}))
  def encode_rpc(id, method, params_json), do: small(:RPC, 0, {id, method, params_json})
  def reply(rev, id, ok?, json), do: small(:REPLY, rev, {id, ok?, json})
  # A nonce is a u64 as a binary segment takes it: the node's is monotonic time, often negative.
  def ping(kind, nonce), do: small(kind, 0, nonce &&& 0xFFFF_FFFF_FFFF_FFFF)
  def bye(rev, reason, message \\ ""), do: small(:BYE, rev, {enum_code("bye", reason), message})

  defp small(kind, rev, fields), do: Nif.small(Map.fetch!(@frames, kind), rev, fields)

  # --------------------------------------------------------------- ops

  @doc """
  Decodes an OPS body into ops, each
  `%{op_id, verb, keyed, create_only, expect_rev, subject, target, cells, raw}`
  with `cells` a list of `{col_id, wire_type, raw_value}` (raw_value: integer,
  binary, float, `:nan` for a non-finite f64, `nil` for null). The whole body
  is validated first; a malformed frame is refused whole.
  """
  defdelegate ops(body), to: Nif

  @doc "One op from the start of `bin`: `{:ok, op, rest}` or `:error`."
  defdelegate op(bin), to: Nif

  @doc """
  One op's bytes from `{op_id, verb, flags, subject, target, expect_rev,
  [{col, type, value}]}` (tests, the importer, the server's own writes); a
  value past its type raises, and a str cell that is not UTF-8 answers nil.
  """
  defdelegate encode_op(op), to: Nif

  @doc """
  An op id for an op the server makes itself (the importer, the keywords
  backfill): random, so it never repeats across restarts as
  `unique_integer`'s do, and under 2^63, so SQLite's i64 keeps it as is.
  """
  def op_id do
    <<id::unsigned-63, _::1>> = :crypto.strong_rand_bytes(8)
    id
  end

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

  @doc "The type an op cell for this column must carry: its wire type (a text column's is str)."
  def cell_type(%{wire: @t_zstr}), do: @t_str
  def cell_type(%{wire: w}), do: w

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

  # A wire `day` as a date; nil outside 0..`Schema.day_max/0`.
  defp day_from_wire(n) when is_integer(n) and n >= 0,
    do: if(n <= Schema.day_max(), do: Date.from_gregorian_days(n))

  defp day_from_wire(_), do: nil

  @doc "A column's Elixir value as its wire value (the kernel's and BOOT's form)."
  def to_wire(_col, nil), do: nil
  def to_wire(%{type: :bool}, v), do: if(v == true, do: 1, else: 0)
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
  def from_wire(col, v), do: to_value(col, v)

  # -------------------------------------------------------- table runs

  @doc """
  One table-run block: `cols` is `[{col_id, wire_type, values}]`, every
  `values` a list of `nrows` wire values (`nil` is null; a zstr column's
  are its texts, packed here).
  """
  def block(table_id, nrows, cols) do
    cols =
      for {id, ty, vs} <- cols,
          do: {id, ty, if(ty == @t_zstr, do: Enum.map(vs, &zcell/1), else: vs)}

    if nrows * length(cols) > @dirty_cells,
      do: Nif.block_dirty(table_id, nrows, cols),
      else: Nif.block(table_id, nrows, cols)
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
        {c.id, c.wire, Enum.map(rows, &wire.(Map.get(&1, key)))}
      end)
    )
  end

  @doc "The `clock` block: today and now, as the BOOT and the TICK carry them."
  def clock(now) do
    t = Schema.table(:clock)
    rows_block(t, t.cols, [%{today: DateTime.to_date(now), now: now}])
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

  @doc """
  How a column's values as SQLite stores them (integers, floats, text, nil)
  become the wire's, decided once per column: a function for each value, or
  nil when they already are. A BOOT reads its tables this way, never
  loading a row.
  """
  def stored_to_wire(%{type: :enum, enum: e}) do
    codes = Map.new(Map.fetch!(@enum_codes, e), fn {k, v} -> {Atom.to_string(k), v} end)
    &(&1 && Map.get(codes, &1))
  end

  def stored_to_wire(%{type: :day}), do: &(&1 && day_to_wire(Date.from_iso8601!(&1)))
  def stored_to_wire(%{type: :time}), do: &(&1 && stored_time(&1))
  # Stored as the encoder wrote it; read and written again, as a row's would be.
  def stored_to_wire(%{type: :json}), do: &(&1 && JSON.encode!(JSON.decode!(&1)))
  # Integers (ids, refs, counts, a bool's 0 or 1), floats and text as they
  # are: nil, no conversion to run per cell.
  def stored_to_wire(_col), do: nil

  defp stored_time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, t, _} ->
        DateTime.to_unix(t)

      _ ->
        text
        |> NaiveDateTime.from_iso8601!()
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix()
    end
  end

  @doc "The gone blocks deleting `[{table_id, id}]`."
  def gone_block([]), do: []

  # One block per table, its only column the reserved GONE id (native/wire).
  def gone_block(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort()
    |> Enum.map(fn {table_id, ids} -> block(table_id, length(ids), [{@gone, @t_u32, ids}]) end)
  end
end
