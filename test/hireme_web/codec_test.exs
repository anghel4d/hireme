defmodule HiremeWeb.Wire.CodecTest do
  # The bytes are native/wire's, through the NIF: its own tests pin them
  # (tests/codec.rs the golden bytes, tests/vectors.rs the refusals). Pinned
  # here is what the node adds: its packing, which native/wire must read
  # back, and the Elixir types of cells. The day's range is pinned end to
  # end by Hireme.DayTest.
  use ExUnit.Case, async: true
  import Bitwise
  alias Hireme.Schema
  alias HiremeWeb.Wire.Codec

  test "a cell is its column's value or refused: a sentinel or another type is refused type; a value past its wire type is refused at encode, never wrapped" do
    assert {:error, :type} = Codec.cell_to_value(%{type: :u32, wire: 1}, {8, 1, 0xFFFF_FFFF})
    assert {:error, :type} = Codec.cell_to_value(%{type: :str, wire: 2}, {8, 1, 5})
    assert {:ok, nil} = Codec.cell_to_value(%{type: :str, wire: 2}, {8, 2, ""})

    for cell <- [{8, 1, 5_000_000_000}, {8, 1, -1}, {8, 3, 1 <<< 63}],
        do:
          assert_raise(ArgumentError, fn -> Codec.encode_op({1, :put, 0, 3, 0, nil, [cell]}) end)
  end

  test "a ZSTD table run unpacks to itself; a cut, relabelled or peer-sent one is refused" do
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
    # A peer never sends a packed frame: one is refused unread.
    assert {:error, :body} = Codec.decode(whole, :up)
  end
end
