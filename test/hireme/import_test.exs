defmodule Hireme.ImportTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.Import
  alias Hireme.Rows.{Corporation, Office, Place}

  defp tag, do: "#{System.unique_integer([:positive])}"
  defp groups(groups), do: for({t, rows} <- groups, do: %{"table" => t, "rows" => rows})
  defp json(a, pack), do: Import.run(a.id, Jason.encode!(pack), :json)
  defp mine(t), do: dynamic([c], like(c.domain, ^"%.#{t}.example"))

  defp pack(t) do
    a = %{"domain" => "a.#{t}.example", "name" => "A", "headcount" => 120}
    b = %{"domain" => "b.#{t}.example", "name" => "B", "ownership" => "public"}
    office = %{"corporation_id" => %{"domain" => a["domain"]}, "place_id" => %{"iso2" => "Q#{t}"}}

    %{
      "as_of" => "2026-09-01",
      "source" => "https://stats.example.org/#{t}",
      "tables" =>
        groups([
          {"places", [%{"kind" => "country", "iso2" => "Q#{t}", "name" => "Country #{t}"}]},
          {"corporations", [Map.put(a, "about", "builds things"), b]},
          {"offices", [Map.put(office, "kind", "engineering")]}
        ])
    }
  end

  # The pack's rows as the database holds them, by natural key.
  defp state(t) do
    corps =
      Repo.all(
        from c in Corporation,
          where: ^mine(t),
          select: {c.domain, c.name, c.headcount, c.headcount_on, c.ownership},
          order_by: c.domain
      )

    offices =
      Repo.all(
        from c in Corporation,
          where: ^mine(t),
          join: o in Office,
          on: o.corporation_id == c.id,
          join: p in Place,
          on: p.id == o.place_id,
          select: {c.domain, p.iso2, o.kind}
      )

    {corps, offices}
  end

  defp names(t),
    do: Repo.all(from c in Corporation, where: ^mine(t), select: c.name, order_by: c.domain)

  test "a JSON pack writes through the sequencer: refs resolved by natural key, metrics cited, prose sourced; imported again it changes nothing; a row names the key its values satisfy; a markdown pack of the same rows leaves the same rows",
       %{account: a} do
    t = tag()
    {:ok, report} = json(a, pack(t))
    assert report.refusals == []
    written = Enum.map(report.groups, &{&1.table, &1.written})
    assert written == [{"places", 1}, {"corporations", 2}, {"offices", 1}]
    {corps, offices} = state(t)
    assert [{_, "A", 120, ~D[2026-09-01], nil}, {_, "B", nil, nil, :public}] = corps
    assert offices == [{"a.#{t}.example", "Q#{t}", :engineering}]
    a_id = Repo.one!(from c in Corporation, where: c.domain == ^"a.#{t}.example", select: c.id)

    cited =
      Repo.all(
        from c in Hireme.Rows.Citation,
          join: s in Hireme.Rows.Source,
          on: s.id == c.source_id,
          where: c.table == "corporations" and c.row_id == ^a_id,
          select: {c.column, s.host}
      )

    assert Enum.sort(cited) == [
             {"about", "stats.example.org"},
             {"headcount", "stats.example.org"}
           ]

    rows = fn ->
      Enum.sum(for s <- [Corporation, Office, Place], do: Repo.aggregate(s, :count))
    end

    n = rows.()
    {:ok, %{refusals: []}} = json(a, pack(t))
    assert state(t) == {corps, offices} and rows.() == n

    # A city sharing the country's iso2 is its own row: its values meet the city key.
    city = %{"kind" => "city", "iso2" => "Q#{t}", "geonames_id" => String.to_integer(t)}
    city = Map.merge(city, %{"name" => "City", "notes" => "a city"})
    source = "https://stats.example.org/#{t}"

    {:ok, %{refusals: []}} =
      json(a, %{"source" => source, "tables" => groups([{"places", [city]}])})

    kinds = Repo.all(from p in Place, where: p.iso2 == ^"Q#{t}", select: p.kind, order_by: p.id)
    assert kinds == [:country, :city]

    u = tag()

    markdown = """
    as_of: 2026-09-01
    source: https://stats.example.org/#{u}

    ## places
    | kind | iso2 | name |
    | --- | --- | --- |
    | country | Q#{u} | Country #{u} |

    ## corporations
    | domain | name | headcount | about | ownership |
    | --- | --- | --- | --- | --- |
    | a.#{u}.example | A | 120 | builds things | |
    | b.#{u}.example | B | | | public |

    ## offices
    | corporation_id | place_id | kind |
    | --- | --- | --- |
    | a.#{u}.example | Q#{u} | engineering |
    """

    {:ok, %{refusals: []}} = Import.run(a.id, markdown, :markdown)

    blind = fn {corps, offices}, x ->
      blank = &String.replace(&1, x, "_")
      corps = Enum.map(corps, &put_elem(&1, 0, blank.(elem(&1, 0))))
      {corps, Enum.map(offices, fn {d, iso, k} -> {blank.(d), blank.(iso), k} end)}
    end

    assert blind.(state(u), u) == blind.(state(t), t)
  end

  test "a bad cell refuses its row alone, by position: an unknown column or table, a wrong type, a number past its range (never wrapped), a day outside 0000-01-01..9999-12-31 (an as_of too), a dangling ref",
       %{account: a} do
    t = tag()
    corp = &Map.merge(%{"domain" => "#{&1}.#{t}.example", "name" => "N#{&1}"}, &2)
    day = %{"year" => 10_000, "month" => 1, "day" => 1}

    dangling = %{
      "corporation_id" => %{"domain" => "none.example"},
      "place_id" => 1,
      "kind" => "hq"
    }

    corps = [
      corp.(0, %{}),
      corp.(1, %{"no_such_column" => 1}),
      corp.(2, %{"headcount" => "many"}),
      corp.(3, %{"headcount" => 5_000_000_000}),
      corp.(4, %{"headcount" => -2}),
      corp.(5, %{"headcount" => 4_294_967_296}),
      corp.(6, %{"headcount" => 4_294_967_294}),
      corp.(7, %{"last_round_on" => "-0001-12-31"}),
      corp.(8, %{"last_round_on" => day}),
      corp.(9, %{"last_round_on" => "0000-01-01"}),
      corp.(10, %{"last_round_on" => "1897-01-01"})
    ]

    groups = [{"corporations", corps}, {"offices", [dangling]}, {"accounts", [%{"name" => "x"}]}]
    {:ok, report} = json(a, %{"as_of" => "2026-09-01", "tables" => groups(groups)})
    type = for i <- [2, 3, 4, 5, 7, 8], do: {"corporations", i, :type}

    refused =
      [{"corporations", 1, :column}] ++
        type ++ [{"offices", 0, :not_found}, {"accounts", nil, :not_found}]

    assert Enum.map(report.refusals, &{&1.table, &1.row, &1.code}) == refused

    for r <- report.refusals,
        r.row in [7, 8],
        do: assert(%{reason: "out of range", column: "last_round_on"} = r.data)

    landed =
      from c in Corporation,
        where: ^mine(t),
        order_by: c.domain,
        select: {c.name, c.headcount, c.last_round_on}

    assert Repo.all(landed) == [
             {"N0", nil, nil},
             {"N10", nil, ~D[1897-01-01]},
             {"N6", 4_294_967_294, nil},
             {"N9", nil, ~D[0000-01-01]}
           ]

    far = %{
      "as_of" => "-0001-12-31",
      "tables" => groups([{"corporations", [corp.(11, %{"headcount" => 3})]}])
    }

    {:ok, report} = json(a, far)
    assert [%{code: :type, data: %{column: "as_of"}}] = report.refusals
  end

  test "markdown: a BOM, prose (pipes or not) and a delimiter row are not data; a section's every table is read; an escaped pipe stays; a row unlike its header or holding a Latin-1 byte is refused alone; a heading-less one has no tables",
       %{account: a} do
    t = tag()

    markdown = """
    \uFEFF## corporations
    Notes first: the a|b form is how we quote.

    | domain | name |
    | --- | --- |
    | a.#{t}.example | A \\| B |
    | b.#{t}.example | B | extra |
    c.#{t}.example | C
    | --- | --- |
    | d.#{t}.example | Caf\xE9 |

    Between the tables. Use `a|b` when quoting.

    | domain | name |
    | --- | --- |
    | e.#{t}.example | E |

    \uFEFF## corporations
    | domain | name |
    | --- |
    | f.#{t}.example | F |
    """

    {:ok, report} = Import.run(a.id, markdown, :markdown)
    assert Enum.map(report.refusals, & &1.code) == [:type, :type, :type]
    assert names(t) == ["A | B", "C", "E"]
    assert {:error, :no_tables} = Import.run(a.id, "just some notes\n", :markdown)
  end

  @tag :tmp_dir
  test "a pack file is read for what it is, an upper-case .JSON one too; an account with no sequencer answers an error",
       %{account: a, tmp_dir: dir} do
    t = tag()
    path = Path.join(dir, "PACK.JSON")

    pack = %{
      "tables" => groups([{"corporations", [%{"domain" => "up.#{t}.example", "name" => "Up"}]}])
    }

    File.write!(path, Jason.encode!(pack))
    {:ok, %{refusals: []}} = Import.file(a.id, path)
    assert names(t) == ["Up"]
    assert {:error, _} = json(%{id: 987_654_321}, pack)
  end

  # Values no column should take: out-of-range dates and numbers, Latin-1
  # bytes, objects where text belongs, refs past the wire.
  @hostile [
    "1950-06-01",
    "2200-01-01T00:00:00Z",
    5_000_000_000,
    -2,
    "4294967296",
    %{"x" => 1},
    [1, 2]
  ]

  property "whatever a row holds, an import answers a report and every other row is written",
           %{account: a} do
    check all(
            table <-
              member_of(
                ~w(corporations offices places sources contacts items cv_lineages batches)
              ),
            col_pick <- integer(0..400),
            value <- one_of([member_of(@hostile), integer(), string(:printable, max_length: 6)]),
            as_of <- member_of(["2026-09-01", "1969-01-01", %{}]),
            max_runs: 60
          ) do
      t = Schema.table(table)
      cols = for c <- t.cols, not c.implied, not c.readonly, not c.server_only, do: c.name
      col = Enum.at(cols, rem(col_pick, length(cols)))
      good = %{"domain" => "good.#{tag()}.example", "name" => "Good"}
      groups = [{table, [%{col => value}]}, {"corporations", [good]}]
      assert {:ok, report} = json(a, %{"as_of" => as_of, "tables" => groups(groups)})
      assert Enum.all?(report.refusals, &is_atom(&1.code))
      assert Repo.exists?(from c in Corporation, where: c.domain == ^good["domain"])
    end
  end

  test "a refusal echoes a bad cell, column or table bounded, however long it is, and never a name that could forge what a reader sees",
       %{account: a} do
    huge = String.duplicate("x", 3_000_000)

    corps = [
      %{"domain" => "huge.example", "name" => "Huge", "headcount" => huge},
      %{"domain" => "late.example", "name" => "Late", "as_of" => huge},
      %{"domain" => "wide.example", "name" => "Wide", huge => 1}
    ]

    groups = [{"corporations", corps}, {huge, [%{"name" => "Nowhere"}]}]

    pack = %{
      "as_of" => "2026-09-01",
      "source" => "https://stats.example.org/huge",
      "tables" => groups(groups)
    }

    {:ok, %{refusals: refusals} = report} = json(a, pack)
    assert length(refusals) == 4
    assert byte_size(inspect(report)) < 4_000
    for r <- refusals, do: assert(byte_size(inspect(r)) < 1_000, inspect(r, limit: 5))

    assert {:error, {:group, _}} =
             error = json(a, %{"tables" => [%{"table" => "corporations", "rows" => huge}]})

    assert byte_size(inspect(error)) < 1_000

    # One sample per excluded category: Cc, Cf (a bidi override), Zs other
    # than ASCII space, Zl, Zp, Co and Cn; a name that spells an escape; a
    # long one ending in a tag, a soft hyphen and a private-use codepoint;
    # and a plain name, echoed as given.
    plain = "Ünïcode name, punct. & symbols ★ 1"

    sly = [
      "\e[2J\e[31mFAKE\e[0m\rok",
      "a\u202Eb",
      "nb\u00A0sp",
      "ls\u2028",
      "ps\u2029",
      "pu\uE000",
      "un\u0378",
      "lit\\u{202E}",
      String.duplicate("long ", 12) <> "\u{E0041}\u00AD\uE000"
    ]

    wide = Map.new([{"domain", "s.example"} | Enum.map(sly, &{&1, 1})])
    groups = [{"corporations", [wide]} | for(n <- [plain | sly], do: {n, [%{"name" => "S"}]})]
    {:ok, sly_report} = json(a, %{"tables" => groups(groups)})

    echoed =
      for r <- sly_report.refusals, n <- [r.data[:table], r.data[:column]], is_binary(n), do: n

    assert plain in echoed

    for n <- echoed,
        <<c::utf8 <- n>>,
        do: assert(<<c::utf8>> =~ ~r/^[\p{L}\p{N}\p{M}\p{P}\p{S} ]$/u, inspect(n))

    for n <- sly, do: refute(n in echoed)
  end
end
