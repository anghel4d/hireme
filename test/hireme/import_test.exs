defmodule Hireme.ImportTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.Import
  alias Hireme.Rows.{Corporation, Office, Place}

  defp tag, do: "#{System.unique_integer([:positive])}"

  defp pack(t) do
    %{
      "as_of" => "2026-09-01",
      "source" => "https://stats.example.org/#{t}",
      "tables" => [
        %{
          "table" => "places",
          "rows" => [%{"kind" => "country", "iso2" => "Q#{t}", "name" => "Country #{t}"}]
        },
        %{
          "table" => "corporations",
          "rows" => [
            %{
              "domain" => "a.#{t}.example",
              "name" => "A",
              "headcount" => 120,
              "about" => "builds things"
            },
            %{"domain" => "b.#{t}.example", "name" => "B", "ownership" => "public"}
          ]
        },
        %{
          "table" => "offices",
          "rows" => [
            %{
              "corporation_id" => %{"domain" => "a.#{t}.example"},
              "place_id" => %{"iso2" => "Q#{t}"},
              "kind" => "engineering"
            }
          ]
        }
      ]
    }
  end

  # The pack's rows as the database holds them, by natural key.
  defp state(t) do
    corps =
      Repo.all(
        from c in Corporation,
          where: like(c.domain, ^"%.#{t}.example"),
          select: {c.domain, c.name, c.headcount, c.headcount_on, c.ownership},
          order_by: c.domain
      )

    offices =
      Repo.all(
        from o in Office,
          join: c in Corporation,
          on: c.id == o.corporation_id,
          join: p in Place,
          on: p.id == o.place_id,
          where: like(c.domain, ^"%.#{t}.example"),
          select: {c.domain, p.iso2, o.kind}
      )

    {corps, offices}
  end

  defp names(t) do
    Repo.all(
      from c in Corporation,
        where: like(c.domain, ^"%.#{t}.example"),
        select: c.name,
        order_by: c.domain
    )
  end

  defp corporations(rows), do: %{"tables" => [%{"table" => "corporations", "rows" => rows}]}

  test "a JSON pack writes through the sequencer: refs resolved by natural key, metrics cited, prose sourced; imported again it leaves every row as it was; a row names the key its own values satisfy",
       %{account: a} do
    t = tag()
    body = Jason.encode!(pack(t))
    {:ok, report} = Import.run(a.id, body, :json)
    assert report.refusals == []

    assert Enum.map(report.groups, &{&1.table, &1.written}) == [
             {"places", 1},
             {"corporations", 2},
             {"offices", 1}
           ]

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

    assert Enum.sort(cited) == [{"about", "stats.example.org"}, {"headcount", "stats.example.org"}]

    rows = fn ->
      Repo.aggregate(Corporation, :count) + Repo.aggregate(Office, :count) +
        Repo.aggregate(Place, :count)
    end

    n = rows.()
    {:ok, %{refusals: []}} = Import.run(a.id, body, :json)
    assert state(t) == {corps, offices} and rows.() == n

    # A city sharing the country's iso2 is its own row: its values meet the city key.
    city = %{
      "kind" => "city",
      "iso2" => "Q#{t}",
      "geonames_id" => String.to_integer(t),
      "name" => "City",
      "notes" => "a city"
    }

    pack = %{"tables" => [%{"table" => "places", "rows" => [city]}]}
    {:ok, %{refusals: []}} = Import.run(a.id, Jason.encode!(pack), :json)
    kinds = Repo.all(from p in Place, where: p.iso2 == ^"Q#{t}", select: p.kind, order_by: p.id)
    assert kinds == [:country, :city]
  end

  test "a markdown pack and a JSON pack of the same rows leave the same rows", %{account: a} do
    t = tag()
    u = tag()
    {:ok, %{refusals: []}} = Import.run(a.id, Jason.encode!(pack(t)), :json)

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

    rename = fn {corps, offices} ->
      {Enum.map(corps, &put_elem(&1, 0, &1 |> elem(0) |> String.replace([t, u], "_"))),
       Enum.map(offices, fn {d, iso, k} ->
         {String.replace(d, [t, u], "_"), String.replace(iso, [t, u], "_"), k}
       end)}
    end

    assert rename.(state(t)) == rename.(state(u))
  end

  test "a bad cell refuses its row alone, by position: an unknown column, a wrong type, a number past its range (never wrapped), a day outside 0000-01-01..9999-12-31 (so an as_of too), an unresolvable ref, an unknown table",
       %{account: a} do
    t = tag()
    corp = fn i, cells -> Map.merge(%{"domain" => "#{i}.#{t}.example", "name" => "N#{i}"}, cells) end

    pack = %{
      "as_of" => "2026-09-01",
      "tables" => [
        %{
          "table" => "corporations",
          "rows" => [
            corp.(0, %{}),
            corp.(1, %{"no_such_column" => 1}),
            corp.(2, %{"headcount" => "many"}),
            corp.(3, %{"headcount" => 5_000_000_000}),
            corp.(4, %{"headcount" => -2}),
            corp.(5, %{"headcount" => 4_294_967_296}),
            corp.(6, %{"headcount" => 4_294_967_294}),
            corp.(7, %{"last_round_on" => "-0001-12-31"}),
            corp.(8, %{"last_round_on" => %{"year" => 10_000, "month" => 1, "day" => 1}}),
            corp.(9, %{"last_round_on" => "0000-01-01"}),
            corp.(10, %{"last_round_on" => "1897-01-01"})
          ]
        },
        %{
          "table" => "offices",
          "rows" => [
            %{"corporation_id" => %{"domain" => "none.example"}, "place_id" => 1, "kind" => "hq"}
          ]
        },
        %{"table" => "accounts", "rows" => [%{"name" => "x"}]}
      ]
    }

    {:ok, report} = Import.run(a.id, Jason.encode!(pack), :json)

    assert Enum.map(report.refusals, &{&1.table, &1.row, &1.code}) == [
             {"corporations", 1, :column},
             {"corporations", 2, :type},
             {"corporations", 3, :type},
             {"corporations", 4, :type},
             {"corporations", 5, :type},
             {"corporations", 7, :type},
             {"corporations", 8, :type},
             {"offices", 0, :not_found},
             {"accounts", nil, :not_found}
           ]

    for r <- report.refusals, r.row in [7, 8],
        do: assert(r.data == %{reason: "out of range", column: "last_round_on"})

    assert Repo.all(
             from c in Corporation,
               where: like(c.domain, ^"%.#{t}.example"),
               order_by: c.domain,
               select: {c.name, c.headcount, c.last_round_on}
           ) == [
             {"N0", nil, nil},
             {"N10", nil, ~D[1897-01-01]},
             {"N6", 4_294_967_294, nil},
             {"N9", nil, ~D[0000-01-01]}
           ]

    far = Map.put(corporations([corp.(11, %{"headcount" => 3})]), "as_of", "-0001-12-31")
    {:ok, report} = Import.run(a.id, Jason.encode!(far), :json)
    assert [%{code: :type, data: %{column: "as_of"}}] = report.refusals
  end

  test "markdown: a BOM before a heading is not text; prose around a table, a pipe in it or not, is not data; a section's every table is read; a delimiter is never data; an escaped pipe stays in its cell; a row unlike its header or holding a Latin-1 byte is refused alone",
       %{account: a} do
    t = tag()

    markdown = """
    ﻿## corporations
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

    ﻿## corporations
    | domain | name |
    | --- |
    | f.#{t}.example | F |
    """

    {:ok, report} = Import.run(a.id, markdown, :markdown)
    assert Enum.map(report.refusals, & &1.code) == [:type, :type, :type]
    assert names(t) == ["A | B", "C", "E"]
  end

  test "a pack is read for what it is: an upper-case .JSON file, a heading-less markdown; an account with no sequencer answers an error",
       %{account: a} do
    t = tag()
    dir = Path.join(System.tmp_dir!(), "hireme-import-#{t}")
    File.mkdir_p!(dir)

    try do
      json = Path.join(dir, "PACK.JSON")
      File.write!(json, Jason.encode!(corporations([%{"domain" => "up.#{t}.example", "name" => "Up"}])))
      {:ok, %{refusals: []}} = Import.file(a.id, json)
      assert names(t) == ["Up"]
    after
      File.rm_rf!(dir)
    end

    assert {:error, :no_tables} = Import.run(a.id, "just some notes\n", :markdown)

    body = Jason.encode!(corporations([%{"domain" => "x.example", "name" => "X"}]))
    assert {:error, _} = Import.run(987_654_321, body, :json)
  end

  # Values no column should take: out-of-range dates and numbers, Latin-1
  # bytes, objects where text belongs, refs past the wire.
  defp hostile do
    one_of([
      constant("1950-06-01"),
      constant("2200-01-01T00:00:00Z"),
      constant(5_000_000_000),
      constant(-2),
      constant("4294967296"),
      constant(%{"x" => 1}),
      constant([1, 2]),
      integer(),
      string(:printable, max_length: 6)
    ])
  end

  property "whatever a row holds, an import answers a report and every other row is written", %{
    account: a
  } do
    tables = ~w(corporations offices places sources contacts gym_reps items cv_lineages batches)

    check all(
            table <- member_of(tables),
            col_pick <- integer(0..400),
            value <- hostile(),
            as_of <- one_of([constant("2026-09-01"), constant("1969-01-01"), constant(%{})]),
            max_runs: 60
          ) do
      t = Schema.table(table)
      cols = for c <- t.cols, not c.implied, not c.readonly, not c.server_only, do: c.name
      col = Enum.at(cols, rem(col_pick, length(cols)))
      good = %{"domain" => "good.#{tag()}.example", "name" => "Good"}

      pack = %{
        "as_of" => as_of,
        "tables" => [
          %{"table" => table, "rows" => [%{col => value}]},
          %{"table" => "corporations", "rows" => [good]}
        ]
      }

      assert {:ok, report} = Import.run(a.id, Jason.encode!(pack), :json)
      assert Enum.all?(report.refusals, &is_atom(&1.code))
      assert Repo.exists?(from c in Corporation, where: c.domain == ^good["domain"])
    end
  end

  test "a refusal echoes a bad cell, column or table bounded, however long it is, and never a name that could forge what a reader sees",
       %{account: a} do
    huge = String.duplicate("x", 3_000_000)

    body =
      Jason.encode!(%{
        "as_of" => "2026-09-01",
        "source" => "https://stats.example.org/huge",
        "tables" => [
          %{
            "table" => "corporations",
            "rows" => [
              %{"domain" => "huge.example", "name" => "Huge", "headcount" => huge},
              %{"domain" => "late.example", "name" => "Late", "as_of" => huge},
              %{"domain" => "wide.example", "name" => "Wide", huge => 1}
            ]
          },
          %{"table" => huge, "rows" => [%{"name" => "Nowhere"}]}
        ]
      })

    {:ok, %{refusals: refusals} = report} = Import.run(a.id, body, :json)
    assert length(refusals) == 4
    assert byte_size(inspect(report)) < 4_000
    for r <- refusals, do: assert(byte_size(inspect(r)) < 1_000, inspect(r, limit: 5))

    bad = Jason.encode!(%{"tables" => [%{"table" => "corporations", "rows" => huge}]})
    assert {:error, {:group, _}} = error = Import.run(a.id, bad, :json)
    assert byte_size(inspect(error)) < 1_000

    # One sample per excluded category: Cc, Cf (a bidi override), Zs other
    # than ASCII space, Zl, Zp, Co and Cn; a name that spells an escape; a
    # long one ending in a tag, a soft hyphen and a private-use codepoint;
    # and a plain name, echoed as given.
    plain = "Ünïcode name, punct. & symbols ★ 1"

    sly = [
      "\e[2J\e[31mFAKE\e[0m\rok",
      "a‮b",
      "nb sp",
      "ls ",
      "ps ",
      "pu",
      "un͸",
      "lit\\u{202E}",
      String.duplicate("long ", 12) <> "\u{E0041}­"
    ]

    sly_body =
      Jason.encode!(%{
        "tables" =>
          [
            %{
              "table" => "corporations",
              "rows" => [Map.new([{"domain", "s.example"} | Enum.map(sly, &{&1, 1})])]
            }
          ] ++
            for(n <- [plain | sly], do: %{"table" => n, "rows" => [%{"name" => "S"}]})
      })

    {:ok, sly_report} = Import.run(a.id, sly_body, :json)

    echoed =
      for r <- sly_report.refusals, n <- [r.data[:table], r.data[:column]], is_binary(n), do: n

    assert plain in echoed

    for n <- echoed,
        <<c::utf8 <- n>>,
        do: assert(<<c::utf8>> =~ ~r/^[\p{L}\p{N}\p{M}\p{P}\p{S} ]$/u, inspect(n))

    for n <- sly, do: refute(n in echoed)
  end
end
