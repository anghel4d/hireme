defmodule Hireme.DayTest do
  # A `day` is days since 0000-01-01, proleptic Gregorian, 0 to 3652424
  # (9999-12-31), past which a cell is refused `type`. End to end on the
  # node: a day cell through the codec, the kernel's judge and SQLite, and
  # back out of the database, on a resident table and a server one.
  use Hireme.WireCase, async: false

  defp read(a, table, id, col),
    do: Repo.with_account(a.id, fn -> Map.fetch!(Repo.get!(Schema.row(table), id), col) end)

  test "every day from 0000-01-01 to 9999-12-31 is its Gregorian day number on the wire and reads back as itself; a day past it is refused type",
       %{account: a} do
    corp = ack!(a.id, op(:put, :corporations, %{domain: "day.example", name: "D"})).id
    days = [~D[0000-01-01], ~D[1897-01-01], ~D[1969-12-31], ~D[1970-01-01], ~D[9999-12-31]]
    listing_on = Schema.column("applications", "listing_on")

    for {d, i} <- Enum.with_index(days ++ [Date.utc_today()]) do
      assert Codec.to_wire(listing_on, d) == Date.to_gregorian_days(d)
      # Resident: the kernel judges the cell before it lands.
      app = ack!(a.id, app(%{company: "C#{i}", role: "R", listing_on: d})).id
      assert read(a, "applications", app, :listing_on) == d
      # Server-side: an office opened that day, its headcount cited as of it
      # (as_of is never in the future).
      as_of = Enum.min([d, Date.utc_today()], Date)

      place =
        ack!(a.id, op(:put, :places, %{kind: :country, iso2: "D" <> <<?A + i>>, name: "D#{i}"})).id

      office = %{corporation_id: corp, place_id: place, kind: :hq, opened_on: d, headcount: 12}
      office = Map.merge(office, %{as_of: as_of, source: "https://day.example/#{i}"})
      office = ack!(a.id, op(:put, :offices, office)).id
      assert read(a, "offices", office, :opened_on) == d
      assert read(a, "offices", office, :headcount_on) == as_of
    end

    t = Schema.table(:applications)
    col = &Schema.column(:applications, &1).id
    past = Date.to_gregorian_days(~D[9999-12-31]) + 1
    cells = [{col.("company"), 2, "Past"}, {col.("role"), 2, "R"}, {listing_on.id, 1, past}]
    {:ok, op, ""} = Codec.op(Codec.encode_op({1, :put, 0, t.id, 0, nil, cells}))
    assert nack!(a.id, op) == :type
  end
end
