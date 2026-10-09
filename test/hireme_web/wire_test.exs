defmodule HiremeWeb.WireTest do
  @moduledoc """
  The wire encoder against a reference reader: every frame is whole and
  8-aligned, every table block decodes back to the rows it was given, and
  the frames a session sends (BOOT, PATCH, FOCUS, LINES) hold together.
  `WIRE_GOLDEN=1 mix test test/hireme_web/wire_test.exs` rewrites the
  sample frames in test/fixtures/wire/ that the Rust and TypeScript
  readers test against.
  """

  use Hireme.DataCase, async: false

  import Hireme.Fixtures
  alias HiremeWeb.Packet

  @golden Path.expand("../fixtures/wire", __DIR__)

  # The reference reader: a frame's table blocks as %{table_id => [rows]}.
  defp tables(body), do: tables(body, %{})
  defp tables(<<>>, acc), do: acc

  defp tables(<<id::little-16, ncols::little-16, n::little-32, rest::binary>>, acc) do
    {cols, rest} =
      Enum.map_reduce(1..ncols//1, rest, fn _,
                                            <<cid::little-16, type::8, 0::8, size::little-32,
                                              rest::binary>> ->
        <<data::binary-size(^size), rest::binary>> = rest
        pad = rem(8 - rem(size, 8), 8)
        <<_::binary-size(^pad), rest::binary>> = rest
        {{cid, values(type, n, data)}, rest}
      end)

    rows = for i <- 0..(n - 1)//1, do: Map.new(cols, fn {cid, vs} -> {cid, Enum.at(vs, i)} end)
    tables(rest, Map.update(acc, id, rows, &(&1 ++ rows)))
  end

  defp values(1, _n, data), do: for(<<v::little-32 <- data>>, do: v)
  defp values(3, _n, data), do: for(<<v::little-64 <- data>>, do: v)
  defp values(4, _n, data), do: for(<<v::binary-8 <- data>>, do: v)

  defp values(2, n, data) do
    offs_len = 4 * (n + 1)
    <<offs::binary-size(^offs_len), bytes::binary>> = data
    offs = for <<o::little-32 <- offs>>, do: o

    offs
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> binary_part(bytes, a, b - a) end)
  end

  defp one!(iodata) do
    bin = IO.iodata_to_binary(iodata)
    assert rem(byte_size(bin), 8) == 0
    assert {:ok, frames, ""} = Packet.split(bin)
    {bin, frames}
  end

  defp desk do
    p = profile()
    item(p, %{title: "Shipped", body: "Shipped a thing"})
    item(p, %{title: "Built", body: "Built a thing", key: "exp.b", position: 2})
    jobs = for c <- ~w(Acme Globex Initech), do: job(p, %{company: c})
    {p, jobs}
  end

  test "a boot frame decodes back to its cards and lookups" do
    {_p, jobs} = desk()
    cards = Hireme.Desk.list_cards(%Hireme.Desk.Filters{status: :all})
    batches = Hireme.Desk.list_batches()
    profiles = Hireme.Corpus.list_profiles()

    body = [
      Packet.lookups(batches, profiles),
      Packet.table(:cards, Packet.card_rows(cards, batches, profiles)),
      Packet.score_tables(HiremeWeb.JSON.scoreboard(Hireme.Campaign.scoreboard())),
      Packet.lane_tables(HiremeWeb.JSON.lanes())
    ]

    {bin, [{:boot, 0x02, 7, decoded}]} = one!(Packet.frame(:boot, 7, body, flags: 0x02))
    t = tables(decoded)
    assert Enum.sort(Enum.map(t[1], & &1[1])) == Enum.sort(Enum.map(jobs, & &1.id))
    assert Enum.map(t[5], & &1[2]) == Enum.map(Hireme.Pipeline.keys(), &Atom.to_string/1)
    assert [_score] = t[11]

    {zbin, [{:boot, 0x03, 7, zbody}]} =
      one!(Packet.frame(:boot, 7, body, deflate: true, flags: 0x02))

    <<raw_len::little-32, z_len::little-32, rest::binary>> = zbody
    <<z::binary-size(^z_len), _pad::binary>> = rest
    assert byte_size(:zlib.unzip(z)) == raw_len
    assert :zlib.unzip(z) == decoded

    golden("boot.bin", bin)
    golden("boot.deflate.bin", zbin)
  end

  test "a patch carries changed cards, gone ids and partial columns" do
    {_p, [a, b | _]} = desk()
    cards = Hireme.Desk.list_cards(%Hireme.Desk.Filters{status: :all})

    rows =
      Packet.card_rows(
        Enum.filter(cards, &(&1.id == a.id)),
        Hireme.Desk.list_batches(),
        Hireme.Corpus.list_profiles()
      )

    body = [
      Packet.table(:cards, rows),
      Packet.table(:cards, Enum.map(rows, &%{&1 | next_action: "Call back"}), [:id, :next_action]),
      Packet.table(:cards_gone, [%{id: b.id}])
    ]

    {bin, [{:patch, 0, 8, decoded}]} = one!(Packet.frame(:patch, 8, body))
    t = tables(decoded)
    assert [%{1 => id}, %{1 => id, 24 => "Call back"}] = t[1]
    assert id == a.id
    assert t[2] == [%{1 => b.id}]
    golden("patch.bin", bin)
  end

  test "focus frames intern lines once per session and resend on demand" do
    {_p, [a, b | _]} = desk()
    focus = fn id -> HiremeWeb.JSON.focus(Hireme.Desk.focus(id)) end

    {first, intern} = Packet.focus_frames(focus.(a.id), 9, %{})
    {_, [{:lines, 0, 9, lines}, {:focus, 0, 9, fa}]} = one!(first)
    assert map_size(intern) == length(tables(lines)[24])

    {second, ^intern} = Packet.focus_frames(focus.(b.id), 9, intern)
    {bin, [{:focus, 0, 9, fb}]} = one!(second)
    assert hd(tables(fb)[30])[1] == b.id
    refs = Enum.map(tables(fa)[35], & &1[3])
    assert Enum.all?(refs, &(&1 in Map.values(intern)))

    {again, ^intern} = Packet.focus_frames(focus.(b.id), 9, intern, true)
    assert {_, [{:lines, 0, 9, _}, {:focus, 0, 9, _}]} = one!(again)

    golden(
      "lines.bin",
      IO.iodata_to_binary(
        Packet.frame(
          :lines,
          9,
          Packet.table(
            :lines,
            Enum.map(intern, fn {l, ix} -> l |> Map.put(:ix, ix) |> Map.put(:item, l.id) end)
          )
        )
      )
    )

    golden("focus.bin", bin)
  end

  test "split refuses torn lengths and other schemas, and keeps partial frames" do
    bin = IO.iodata_to_binary(Packet.frame(:ping, 0, <<1::little-64>>))
    torn = binary_part(bin, 0, 20)
    assert {:ok, [], ^torn} = Packet.split(torn)
    assert {:ok, [{:ping, 0, 0, <<1::little-64>>}], ""} = Packet.split(bin)
    assert {:error, :frame_length} = Packet.split(<<12::little-32, 0::96>>)
    <<len::binary-4, kind::8, flags::8, _hash::16, rest::binary>> = bin
    assert {:error, :schema} = Packet.split(len <> <<kind, flags>> <> <<0::16>> <> rest)
  end

  defp golden(name, bin) do
    if System.get_env("WIRE_GOLDEN") == "1", do: File.write!(Path.join(@golden, name), bin)
  end
end
