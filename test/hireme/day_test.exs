defmodule Hireme.DayTest do
  # A `day` is days since 0000-01-01, proleptic Gregorian, 0 to 3652424
  # (9999-12-31), past which a cell is refused `type`. End to end on the
  # node: a day cell through the codec, the kernel's judge and SQLite, and
  # back out of the database, on a resident table and a server one.
  use Hireme.WireCase, async: false

  alias HiremeWeb.Wire.Codec

  @days [~D[0000-01-01], ~D[1897-01-01], ~D[1969-12-31], ~D[1970-01-01], ~D[9999-12-31]]

  defp read(a, table, id, col) do
    Repo.with_account(a.id, fn -> Map.fetch!(Repo.get!(Schema.row(table), id), col) end)
  end

  test "every day from 0000-01-01 to 9999-12-31 is its Gregorian day number on the wire and reads back as itself",
       %{account: a} do
    {[%{id: corp}], []} = run(a.id, op(:put, :corporations, %{domain: "day.example", name: "D"}))

    for {d, i} <- Enum.with_index(@days ++ [Date.utc_today()]) do
      assert Codec.to_wire(Schema.column("applications", "listing_on"), d) ==
               Date.to_gregorian_days(d)

      # Resident: the kernel judges the cell before it lands.
      {[%{id: app}], []} =
        run(a.id, op(:put, :applications, %{company: "C#{i}", role: "R", listing_on: d}))

      assert read(a, "applications", app, :listing_on) == d

      # Server-side: an office opened that day, its headcount cited as of it
      # (as_of is never in the future).
      as_of = Enum.min([d, Date.utc_today()], Date)

      {[%{id: place}], []} =
        run(a.id, op(:put, :places, %{kind: :country, iso2: "D" <> <<?A + i>>, name: "Day #{i}"}))

      {[%{id: office}], []} =
        run(
          a.id,
          op(:put, :offices, %{
            corporation_id: corp,
            place_id: place,
            kind: :hq,
            opened_on: d,
            headcount: 12,
            as_of: as_of,
            source: "https://day.example/#{i}"
          })
        )

      assert read(a, "offices", office, :opened_on) == d
      assert read(a, "offices", office, :headcount_on) == as_of
    end
  end

  test "a day past 9999-12-31 is refused type", %{account: a} do
    col = Schema.column("applications", "listing_on")
    cols = Map.new(Schema.table(:applications).cols, &{&1.name, &1})

    raw =
      Codec.encode_op(
        {System.unique_integer([:positive]), :put, 0, Schema.table(:applications).id, 0, nil,
         [
           {cols["company"].id, 2, "Past"},
           {cols["role"].id, 2, "R"},
           {col.id, 1, Date.to_gregorian_days(~D[9999-12-31]) + 1}
         ]}
      )

    {:ok, op, ""} = Codec.op(raw)
    assert {[], [%{refusal: :type}]} = run(a.id, op)
  end
end
