defmodule Hireme.ImportTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.{Import, World}
  alias Hireme.Rows.{Corporation, Office, Place}

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

  test "a JSON pack writes through the sequencer: refs resolved by natural key, metrics cited, prose sourced",
       %{account: a} do
    t = "#{System.unique_integer([:positive])}"
    {:ok, report} = Import.run(a.id, Jason.encode!(pack(t)), :json)

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

    {:ok, %{"citations" => cited}} =
      World.history(a.id, Grants.operator(), %{"table" => "corporations", "id" => a_id})

    assert Enum.sort(Enum.map(cited, & &1["column"])) == ["about", "headcount"]
    assert Enum.all?(cited, &(&1["source"]["host"] == "stats.example.org"))
  end

  test "importing the same pack again leaves every row a key names as it was", %{account: a} do
    t = "#{System.unique_integer([:positive])}"
    body = Jason.encode!(pack(t))
    {:ok, %{refusals: []}} = Import.run(a.id, body, :json)
    first = state(t)

    rows =
      Repo.aggregate(Corporation, :count) + Repo.aggregate(Office, :count) +
        Repo.aggregate(Place, :count)

    {:ok, again} = Import.run(a.id, body, :json)

    assert again.refusals == []
    assert state(t) == first

    assert Repo.aggregate(Corporation, :count) + Repo.aggregate(Office, :count) +
             Repo.aggregate(Place, :count) ==
             rows
  end

  test "a markdown pack and a JSON pack of the same rows leave the same rows", %{account: a} do
    t = "#{System.unique_integer([:positive])}"
    u = "#{System.unique_integer([:positive])}"
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

  test "a bad row is refused alone, by its position, and the rest are written", %{account: a} do
    t = "#{System.unique_integer([:positive])}"

    pack = %{
      "as_of" => "2026-09-01",
      "tables" => [
        %{
          "table" => "corporations",
          "rows" => [
            %{"domain" => "ok1.#{t}.example", "name" => "One"},
            %{"domain" => "bad.#{t}.example", "name" => "Bad", "no_such_column" => 1},
            %{"domain" => "ok2.#{t}.example", "name" => "Two", "headcount" => "many"},
            %{"domain" => "ok3.#{t}.example", "name" => "Three"}
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
             {"offices", 0, :not_found},
             {"accounts", nil, :not_found}
           ]

    {corps, _} = state(t)
    assert Enum.map(corps, &elem(&1, 1)) == ["One", "Three"]
  end

  test "a number past its column's range is refused, not wrapped", %{account: a} do
    t = "#{System.unique_integer([:positive])}"

    rows =
      for {n, i} <- Enum.with_index([5_000_000_000, -2, 4_294_967_296, 4_294_967_294]),
          do: %{"domain" => "#{i}.#{t}.example", "name" => "N#{i}", "headcount" => n}

    pack = %{"as_of" => "2026-09-01", "tables" => [%{"table" => "corporations", "rows" => rows}]}
    {:ok, report} = Import.run(a.id, Jason.encode!(pack), :json)

    assert Enum.map(report.refusals, &{&1.row, &1.code}) == [{0, :type}, {1, :type}, {2, :type}]

    assert Repo.all(
             from c in Corporation, where: like(c.domain, ^"%.#{t}.example"), select: c.headcount
           ) == [4_294_967_294]
  end

  test "a row names the natural key its own values satisfy", %{account: a} do
    t = "#{System.unique_integer([:positive])}"
    iso = "Z#{rem(String.to_integer(t), 9)}"

    pack = %{
      "source" => "https://stats.example.org/#{t}",
      "tables" => [
        %{
          "table" => "places",
          "rows" => [%{"kind" => "country", "iso2" => iso, "name" => "Country"}]
        },
        %{
          "table" => "places",
          "rows" => [
            %{
              "kind" => "city",
              "iso2" => iso,
              "geonames_id" => String.to_integer(t),
              "name" => "City",
              "notes" => "a city"
            }
          ]
        }
      ]
    }

    {:ok, report} = Import.run(a.id, Jason.encode!(pack), :json)
    assert report.refusals == []

    kinds = Repo.all(from p in Place, where: p.iso2 == ^iso, select: p.kind, order_by: p.id)
    assert kinds == [:country, :city]
  end

  test "a markdown row unlike its header is refused, and an escaped pipe stays in its cell", %{
    account: a
  } do
    t = "#{System.unique_integer([:positive])}"

    markdown = """
    ## corporations
    | domain | name |
    | --- | --- |
    | a.#{t}.example | A \\| B |
    | b.#{t}.example | B | extra |
    """

    {:ok, report} = Import.run(a.id, markdown, :markdown)
    assert Enum.map(report.refusals, &{&1.row, &1.code}) == [{1, :type}]

    assert Repo.one(from c in Corporation, where: c.domain == ^"a.#{t}.example", select: c.name) ==
             "A | B"
  end

  test "an import into an account with no sequencer answers an error" do
    assert {:error, _} =
             Import.run(
               987_654_321,
               Jason.encode!(%{
                 "tables" => [
                   %{
                     "table" => "corporations",
                     "rows" => [%{"domain" => "x.example", "name" => "X"}]
                   }
                 ]
               }),
               :json
             )
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
      tag = "#{System.unique_integer([:positive])}"
      good = %{"domain" => "good.#{tag}.example", "name" => "Good"}

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

  test "a byte-order mark, an upper-case .JSON and a heading-less markdown pack are read for what they are",
       %{account: a} do
    t = "#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "hireme-import-#{t}")
    File.mkdir_p!(dir)

    try do
      md = "\uFEFF## corporations\n| domain | name |\n| --- | --- |\n| bom.#{t}.example | Bom |\n"
      {:ok, %{refusals: []}} = Import.run(a.id, md, :markdown)
      assert Repo.exists?(from c in Corporation, where: c.domain == ^"bom.#{t}.example")

      json = Path.join(dir, "PACK.JSON")

      File.write!(
        json,
        Jason.encode!(%{
          "tables" => [
            %{
              "table" => "corporations",
              "rows" => [%{"domain" => "up.#{t}.example", "name" => "Up"}]
            }
          ]
        })
      )

      {:ok, %{refusals: []}} = Import.file(a.id, json)
      assert Repo.exists?(from c in Corporation, where: c.domain == ^"up.#{t}.example")

      assert {:error, :no_tables} = Import.run(a.id, "just some notes\n", :markdown)

      latin1 =
        "## corporations\n| domain | name |\n| --- | --- |\n| l1.#{t}.example | Caf" <>
          <<0xE9>> <> " |\n| l2.#{t}.example | Fine |\n"

      {:ok, report} = Import.run(a.id, latin1, :markdown)
      assert Enum.map(report.refusals, &{&1.row, &1.code}) == [{0, :type}]
      assert Repo.exists?(from c in Corporation, where: c.domain == ^"l2.#{t}.example")
    after
      File.rm_rf!(dir)
    end
  end

  test "prose around a markdown table, a pipe in it or not, is not data", %{account: a} do
    t = "#{System.unique_integer([:positive])}"

    markdown = """
    ## corporations
    Notes first: the a|b form is how we quote.

    | domain | name |
    | --- | --- |
    | p1.#{t}.example | One |
    p2.#{t}.example | Two

    Use `a|b` when quoting.
    """

    {:ok, report} = Import.run(a.id, markdown, :markdown)
    assert report.refusals == []

    assert Repo.all(
             from c in Corporation,
               where: like(c.domain, ^"%.#{t}.example"),
               select: c.name,
               order_by: c.domain
           ) ==
             ["One", "Two"]
  end

  test "a section's every table is read, a BOM before any heading is not text, and a delimiter is never data",
       %{account: a} do
    t = "#{System.unique_integer([:positive])}"

    markdown = """
    ## corporations
    | domain | name |
    | --- | --- |
    | t1.#{t}.example | One |
    | --- | --- |

    Between the tables.

    | domain | name |
    | --- | --- |
    | t2.#{t}.example | Two |

    \uFEFF## corporations
    | domain | name |
    | --- |
    | t3.#{t}.example | Three |
    """

    {:ok, report} = Import.run(a.id, markdown, :markdown)
    assert Enum.map(report.refusals, & &1.code) == [:type]

    assert Repo.all(
             from c in Corporation,
               where: like(c.domain, ^"%.#{t}.example"),
               select: c.name,
               order_by: c.domain
           ) ==
             ["One", "Two"]
  end
end
