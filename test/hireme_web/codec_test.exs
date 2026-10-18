defmodule HiremeWeb.Wire.CodecTest do
  # The same bytes native/wire's golden test pins (native/wire/tests/codec.rs):
  # the two codecs agree on table runs and gone blocks byte for byte.
  use ExUnit.Case, async: true
  import Bitwise
  alias HiremeWeb.Wire.Codec

  defp hex(iodata), do: iodata |> IO.iodata_to_binary() |> Base.encode16(case: :lower)

  test "a table run and a gone block match the Rust crate's golden bytes" do
    block = Codec.block(3, 2, [{1, 1, [7, nil]}, {2, 2, ["ab", nil]}])

    assert hex(block) ==
             "0300020002000000010001000800000007000000ffffffff020002000e00000000000000020000000200000061620000"

    assert hex(Codec.gone_block([{9, 4}, {9, 5}])) ==
             "0900010002000000feff0100080000000400000005000000"
  end

  test "an OPS frame round-trips its cells, and a sentinel cell is refused as a value" do
    raw =
      Codec.encode_op(
        {7, :put, 0, 3, 0, nil, [{8, 1, 5}, {9, 2, "x"}, {10, 3, -2}, {11, 4, 1.5}, {12, 0, nil}]}
      )

    assert {:ok, op, ""} = Codec.op(raw)
    assert op.cells == [{8, 1, 5}, {9, 2, "x"}, {10, 3, -2}, {11, 4, 1.5}, {12, 0, nil}]
    assert {:error, :type} = Codec.cell_to_value(%{type: :u32, wire: 1}, {8, 1, 0xFFFF_FFFF})
    assert {:error, :type} = Codec.cell_to_value(%{type: :day, wire: 1}, {8, 1, 2_932_897})
    assert {:ok, nil} = Codec.cell_to_value(%{type: :str, wire: 2}, {8, 2, ""})
  end

  test "a DEFLATE body cut before its stream ends is refused" do
    body = :binary.copy("hireme ", 400)
    whole = Codec.frame(:BOOT, 0, body, deflate: true)
    assert {:ok, :BOOT, _, _, ^body} = Codec.decode(whole)
    <<head::binary-16, raw::little-32, n::little-32, stream::binary-size(n), _::binary>> = whole
    cut = binary_part(stream, 0, n - 2)
    m = byte_size(cut)
    pad = rem(8 - rem(8 + m, 8), 8)
    body2 = <<raw::little-32, m::little-32, cut::binary, 0::size(pad * 8)>>
    <<_::32, rest::binary-12>> = head
    frame = <<16 + byte_size(body2)::little-32, rest::binary, body2::binary>>
    assert {:error, _} = Codec.decode(frame)
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
