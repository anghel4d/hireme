defmodule HiremeWeb.Wire.CodecTest do
  # The same bytes native/wire's golden test pins (native/wire/tests/codec.rs):
  # the two codecs agree on table runs and gone blocks byte for byte.
  use ExUnit.Case, async: true
  import Bitwise
  alias Hireme.Schema
  alias HiremeWeb.Wire.Codec

  defp hex(iodata), do: iodata |> IO.iodata_to_binary() |> Base.encode16(case: :lower)

  test "a table run and a gone block match the Rust crate's golden bytes" do
    block = Codec.block(3, 2, [{1, 1, [7, nil]}, {2, 2, ["ab", nil]}])

    assert hex(block) ==
             "0300020002000000010001000800000007000000ffffffff020002000e00000000000000020000000200000061620000"

    assert hex(Codec.gone_block([{9, 4}, {9, 5}])) ==
             "0900010002000000feff0100080000000400000005000000"
  end

  test "a day is days since 0000-01-01 to 9999-12-31, both ways, and past it a type refusal" do
    for d <- [
          ~D[0000-01-01],
          ~D[1897-01-01],
          ~D[1969-12-31],
          ~D[1970-01-01],
          Date.utc_today(),
          ~D[9999-12-31]
        ] do
      n = Codec.day_to_wire(d)
      assert n in 0..Hireme.Schema.day_max()
      assert Codec.day_from_wire(n) == d
      assert {:ok, ^d} = Codec.cell_to_value(%{type: :day, wire: 1}, {8, 1, n})
    end

    assert Codec.day_to_wire(~D[0000-01-01]) == 0
    assert Codec.day_to_wire(~D[9999-12-31]) == Hireme.Schema.day_max()
    assert Codec.day_to_wire(Date.new!(10_000, 1, 1)) == nil
    assert Codec.day_to_wire(Date.new!(-1, 12, 31)) == nil

    assert {:error, :type} =
             Codec.cell_to_value(%{type: :day, wire: 1}, {8, 1, Hireme.Schema.day_max() + 1})
  end

  test "an OPS body holds at most 256 ops; 257 is refused whole" do
    op = {7, :put, 0, 3, 0, nil, [{8, 1, 5}]}

    body = fn n ->
      IO.iodata_to_binary([<<n::little-32, 0::32>> | List.duplicate(Codec.encode_op(op), n)])
    end

    assert {:ok, ops} = Codec.ops(body.(256))
    assert length(ops) == 256
    assert {:error, :body} = Codec.ops(body.(257))
  end

  test "an OPS frame round-trips its cells, and a sentinel cell is refused as a value" do
    raw =
      Codec.encode_op(
        {7, :put, 0, 3, 0, nil, [{8, 1, 5}, {9, 2, "x"}, {10, 3, -2}, {11, 4, 1.5}, {12, 0, nil}]}
      )

    assert {:ok, op, ""} = Codec.op(raw)
    assert op.cells == [{8, 1, 5}, {9, 2, "x"}, {10, 3, -2}, {11, 4, 1.5}, {12, 0, nil}]
    assert {:error, :type} = Codec.cell_to_value(%{type: :u32, wire: 1}, {8, 1, 0xFFFF_FFFF})
    assert {:error, :type} = Codec.cell_to_value(%{type: :day, wire: 1}, {8, 1, 3_652_425})
    assert {:ok, nil} = Codec.cell_to_value(%{type: :str, wire: 2}, {8, 2, ""})
  end

  test "a ZSTD table run unpacks to itself, and a cut or relabelled one is refused" do
    texts =
      for i <- 1..300,
          do: "Senior Rust engineer #{i}, " <> String.duplicate("kernels and GPUs. ", rem(i, 40))

    t = Schema.table(:applications)
    cols = [Schema.column(:applications, "listing_raw"), Schema.column(:applications, "stage")]

    rows =
      for {x, i} <- Enum.with_index(texts, 1), do: %{id: i, listing_raw: x, stage: :discovered}

    apps =
      IO.iodata_to_binary(Codec.rows_block(t, [Schema.column(:applications, "id") | cols], rows))

    body =
      IO.iodata_to_binary([
        apps,
        Codec.block(t.id, 3, [{1, 3, [-5, nil, 1 <<< 40]}, {2, 4, [1.5, nil, -0.25]}]),
        Codec.gone_block([{t.id, 7}, {t.id, 9}])
      ])

    whole = Codec.frame(:BOOT, 0, body, compress: true)
    assert byte_size(whole) < div(byte_size(body), 2)
    assert {:ok, :BOOT, 1, _, ^body} = Codec.decode(whole)

    model = Hireme.WireCase.ingest(%{}, :BOOT, apps)

    assert get_in(model, ["applications", 300, Schema.column(:applications, "listing_raw").id]) ==
             List.last(texts)

    <<head::binary-16, raw::little-32, n::little-32, packed::binary-size(n), _::binary>> = whole

    reframe = fn packed, raw ->
      m = byte_size(packed)

      body2 =
        <<raw::little-32, m::little-32, packed::binary, 0::size(rem(8 - rem(8 + m, 8), 8) * 8)>>

      <<_::32, rest::binary-12>> = head
      <<16 + byte_size(body2)::little-32, rest::binary, body2::binary>>
    end

    assert {:ok, :BOOT, _, _, ^body} = Codec.decode(reframe.(packed, raw))
    assert {:error, _} = Codec.decode(reframe.(binary_part(packed, 0, n - 2), raw))
    assert {:error, _} = Codec.decode(reframe.(packed, raw + 8))
    assert {:error, _} = Codec.decode(whole, raw - 8)
  end

  test "a value that does not fit its cell type is refused, never wrapped" do
    assert_raise ArgumentError, fn ->
      Codec.encode_op({1, :put, 0, 3, 0, nil, [{8, 1, 5_000_000_000}]})
    end

    assert_raise ArgumentError, fn -> Codec.encode_op({1, :put, 0, 3, 0, nil, [{8, 1, -1}]}) end

    assert_raise ArgumentError, fn ->
      Codec.encode_op({1, :put, 0, 3, 0, nil, [{8, 3, 1 <<< 63}]})
    end
  end
end
