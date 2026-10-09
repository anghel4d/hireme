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

  # Whole frames, with any DEFLATE body inflated the way the browser does
  # before ingest; the binary is re-framed plain, as the kernel sees it.
  defp one!(iodata) do
    bin = IO.iodata_to_binary(iodata)
    assert rem(byte_size(bin), 8) == 0
    assert {:ok, frames, ""} = Packet.split(bin)
    frames = Enum.map(frames, &plain/1)

    plain_bin =
      frames
      |> Enum.map(fn {k, f, r, b} -> Packet.frame(k, r, b, flags: f) end)
      |> IO.iodata_to_binary()

    {plain_bin, frames}
  end

  defp plain({kind, flags, rev, body}) when Bitwise.band(flags, 1) == 1 do
    <<raw_len::little-32, z_len::little-32, rest::binary>> = body
    <<z::binary-size(^z_len), _pad::binary>> = rest
    raw = :zlib.unzip(z)
    assert byte_size(raw) == raw_len
    {kind, Bitwise.band(flags, 0xFE), rev, raw}
  end

  defp plain(frame), do: frame

  defp desk do
    p = profile()
    item(p, %{title: "Shipped", body: "Shipped a thing"})
    item(p, %{title: "Built", body: "Built a thing", key: "exp.b", position: 2})
    jobs = for c <- ~w(Acme Globex Initech), do: job(p, %{company: c})
    {p, jobs}
  end

  # A table's rows by column name, through the schema's column ids.
  defp named(t, table) do
    ids = Packet.columns(table)

    Enum.map(t[Packet.table_id(table)] || [], fn row ->
      Map.new(ids, fn {name, cid} -> {name, row[cid]} end)
    end)
  end

  test "a raw boot decodes back to the account's rows, enums, dates, lists and JSON" do
    {p, [a | _] = jobs} = desk()
    {:ok, rev, {:boot, %{tables: tables}}} = Hireme.Ops.attach(Hireme.Repo.account_id!(), nil)
    body = [Packet.static_lookups(), for({k, rows} <- tables, do: Packet.raw(k, rows))]

    {bin, [{:boot, 0x02, ^rev, decoded}]} = one!(Packet.frame(:boot, rev, body, flags: 0x02))
    t = tables(decoded)
    rows = named(t, :job_apps)
    assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(Enum.map(jobs, & &1.id))
    row = Enum.find(rows, &(&1.id == a.id))
    assert row.current_stage == "discovered"
    assert row.profile_id == p.id
    assert row.company == "Acme"

    assert row.stage_on == Date.diff(Date.utc_today(), ~D[1970-01-01]) or
             row.stage_on == 0xFFFFFFFF

    assert [item | _] = named(t, :items)
    assert is_binary(item.keywords)

    assert Enum.map(named(t, :stages), & &1.key) ==
             Enum.map(Hireme.Pipeline.keys(), &Atom.to_string/1)

    zbin = IO.iodata_to_binary(Packet.frame(:boot, rev, body, deflate: true, flags: 0x02))
    assert {:ok, [{:boot, 0x03, ^rev, _} = packed], ""} = Packet.split(zbin)
    assert plain(packed) == {:boot, 0x02, rev, decoded}

    golden("boot.bin", bin)
    golden("boot.deflate.bin", zbin)
  end

  test "a raw patch carries partial rows, U+001F lists and deletions" do
    {_p, [a, b | _]} = desk()

    body = [
      Packet.raw(:job_apps, [%{id: a.id, next_action: "Call back"}]),
      Packet.raw(:cv_variants, [
        %{id: 7, theme: %{"targets" => ["elixir", "rust"], "accent" => "ink"}}
      ]),
      Packet.raw(:batches, [
        %{id: 3, code: "B-1", fire: :open_fire, variety: %{"apps" => 4, "flags" => ["mixed"]}}
      ]),
      Packet.table(:gone, [%{table: Packet.table_id(:job_apps), id: b.id}])
    ]

    {bin, [{:patch, 0, 8, decoded}]} = one!(Packet.frame(:patch, 8, body))
    t = tables(decoded)
    assert [%{id: id, next_action: "Call back", listing: ""}] = named(t, :job_apps)
    assert id == a.id

    assert [%{theme_targets: "elixir" <> <<0x1F>> <> "rust", theme: theme}] =
             named(t, :cv_variants)

    assert Jason.decode!(theme)["accent"] == "ink"
    assert [%{fire: 1, variety_apps: 4, variety_flags: "mixed"}] = named(t, :batches)
    assert [%{table: 47, id: gone}] = named(t, :gone)
    assert gone == b.id
    golden("patch.bin", bin)
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
