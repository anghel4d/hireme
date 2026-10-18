defmodule Hireme.WorldTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  alias Hireme.World

  defp tag, do: "t#{System.unique_integer([:positive])}"

  defp corp(account_id, attrs) do
    {[ack], []} = run(account_id, op(:put, :corporations, attrs))
    ack.id
  end

  defp key(read_mask),
    do: Grants.key(%{id: 1, read_mask: read_mask, write_mask: 0, may_delete: false})

  defp ids(rows), do: Enum.map(rows, & &1["id"])

  # Every page of a find, following `next`, with `between` run before each
  # page after the first.
  defp pages(a, grants, params, between) do
    Stream.unfold({nil, 0}, fn
      :done ->
        nil

      {cursor, n} ->
        if n > 0, do: between.()

        {:ok, %{"rows" => rows, "next" => next}} =
          World.find(a, grants, Map.put(params, "after", cursor))

        {rows, if(next, do: {next, n + 1}, else: :done)}
    end)
    |> Enum.to_list()
  end

  # Nulls last; then the column, then id, both in the find's direction.
  defp sorted?(rows, col, desc) do
    keys = Enum.map(rows, &{is_nil(&1[col]), &1[col], &1["id"]})

    keys
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [{n1, v1, i1}, {n2, v2, i2}] ->
      cond do
        n1 != n2 -> not n1
        v1 == v2 -> if desc, do: i1 > i2, else: i1 < i2
        desc -> v1 > v2
        true -> v1 < v2
      end
    end)
  end

  property "keyset paging returns every row present at the start exactly once, in order, while rows are inserted",
           %{account: a} do
    check all(
            tickers <-
              list_of(one_of([constant(nil), string(?A..?E, length: 1..2)]),
                min_length: 1,
                max_length: 20
              ),
            limit <- integer(1..5),
            desc <- boolean(),
            max_runs: 25
          ) do
      t = tag()

      start =
        for {tk, i} <- Enum.with_index(tickers),
            do: corp(a.id, %{domain: "#{i}.#{t}.example", name: "c#{i}", ticker: tk})

      params = %{
        "table" => "corporations",
        "where" => %{"domain" => %{"like" => ".#{t}."}},
        "order" => ["ticker", if(desc, do: "desc", else: "asc")],
        "limit" => limit
      }

      between = fn ->
        corp(a.id, %{
          domain: "x#{System.unique_integer([:positive])}.#{t}.example",
          name: "late",
          ticker: Enum.random(["A", "C", nil])
        })
      end

      seen = a.id |> pages(Grants.operator(), params, between) |> Enum.concat()

      assert ids(seen) == Enum.uniq(ids(seen))
      assert MapSet.subset?(MapSet.new(start), MapSet.new(ids(seen)))
      assert sorted?(seen, "ticker", desc)
    end
  end

  test "a filter answers what an independent reading of the rows answers", %{account: a} do
    t = tag()
    counts = [nil, 0, 5, 5, 40, 300, 12_000]

    for {n, i} <- Enum.with_index(counts) do
      attrs = %{domain: "#{i}.#{t}.example", name: "n#{i}"}
      attrs = if n, do: Map.merge(attrs, %{headcount: n, as_of: ~D[2026-01-01]}), else: attrs
      corp(a.id, attrs)
    end

    {:ok, %{"rows" => all}} =
      World.find(a.id, Grants.operator(), %{
        "table" => "corporations",
        "where" => %{"domain" => %{"like" => t}},
        "cols" => ["id", "headcount"],
        "limit" => 500
      })

    tests = [
      {"eq", 5, &(&1 == 5)},
      {"ne", 5, &(&1 != 5)},
      {"lt", 40, &(&1 != nil and &1 < 40)},
      {"le", 40, &(&1 != nil and &1 <= 40)},
      {"gt", 5, &(&1 != nil and &1 > 5)},
      {"ge", 300, &(&1 != nil and &1 >= 300)},
      {"in", [0, 300], &(&1 in [0, 300])},
      {"null", true, &is_nil/1},
      {"null", false, &(&1 != nil)}
    ]

    for {op, value, spec} <- tests do
      {:ok, %{"rows" => rows}} =
        World.find(a.id, Grants.operator(), %{
          "table" => "corporations",
          "where" => %{"domain" => %{"like" => t}, "headcount" => %{op => value}},
          "limit" => 500
        })

      expected = for r <- all, spec.(r["headcount"]), do: r["id"]
      assert Enum.sort(ids(rows)) == Enum.sort(expected), "#{op} #{inspect(value)}"
    end

    assert {:error, :type, _} =
             World.find(a.id, Grants.operator(), %{
               "table" => "corporations",
               "where" => %{"headcount" => %{"gt" => "many"}}
             })
  end

  property "every read answers only under its table's read bit, and never shows a column the grants may not see",
           %{account: a} do
    {[_], []} = run(a.id, op(:put, :corporations, %{domain: "#{tag()}.example", name: "C"}))
    {[_], []} = run(a.id, op(:put, :contacts, %{name: "A Contact"}))

    {[_], []} =
      run(
        a.id,
        op(:put, :gym_reps, %{platform: :leetcode, slug: "two-sum", done_on: ~D[2026-01-02]})
      )

    {[p], []} =
      run(
        a.id,
        op(:put, :profiles, %{slug: tag(), name: "P", narrative_private: "only the operator"})
      )

    tables = ~w(corporations contacts gym_reps profiles applications)

    check all(mask <- integer(0..31), operator <- boolean(), max_runs: 40) do
      grants = if operator, do: %{Grants.operator() | read_mask: mask}, else: key(mask)

      for name <- tables do
        table = Schema.table(name)
        answer = World.find(a.id, grants, %{"table" => name})

        if Grants.read?(grants, table) do
          {:ok, %{"rows" => rows}} = answer
          hidden = for c <- table.cols, c.server_only or (c.private and not operator), do: c.name
          assert Enum.all?(rows, fn r -> Enum.all?(hidden, &(not Map.has_key?(r, &1))) end)
        else
          assert {:error, :scope, _} = answer
        end
      end

      private = %{"table" => "profiles", "id" => p.id, "column" => "narrative_private"}

      case World.text(a.id, grants, private) do
        {:ok, %{"text" => "only the operator"}} ->
          assert operator and Grants.read?(grants, Schema.table(:profiles))

        {:error, :scope, _} ->
          refute Grants.read?(grants, Schema.table(:profiles))

        {:error, :column, _} ->
          refute operator
      end
    end

    for hidden <- ~w(citations trusted_hosts accounts api_keys op_ledger),
        do:
          assert(
            {:error, :not_found, _} = World.find(a.id, Grants.operator(), %{"table" => hidden})
          )
  end

  property "text chunks reassemble the cell, each one whole UTF-8, and each chunk re-checks the mask",
           %{account: a} do
    check all(
            note <- string(:printable, min_length: 1, max_length: 400),
            length <- integer(1..48),
            max_runs: 30
          ) do
      id = corp(a.id, %{domain: "#{tag()}.example", name: "T", note: note})
      read = %{"table" => "corporations", "id" => id, "column" => "note", "length" => length}

      chunks =
        Stream.unfold(0, fn
          nil ->
            nil

          offset ->
            {:ok, c} = World.text(a.id, Grants.operator(), Map.put(read, "offset", offset))
            {c, c["next"]}
        end)
        |> Enum.to_list()

      assert Enum.all?(chunks, &(String.valid?(&1["text"]) and &1["untrusted"]))
      assert Enum.map_join(chunks, & &1["text"]) == note
      assert hd(chunks)["total"] == byte_size(note)

      if next = hd(chunks)["next"],
        do: assert({:error, :scope, _} = World.text(a.id, key(0), Map.put(read, "offset", next)))
    end
  end

  test "history lists a cell's citations newest first, with each source's host derived", %{
    account: a
  } do
    id =
      corp(a.id, %{
        domain: "#{tag()}.example",
        name: "H",
        headcount: 10,
        as_of: ~D[2026-01-01],
        source: "https://Stats.Example.org/a"
      })

    {[_], []} =
      run(
        a.id,
        op(
          :put,
          :corporations,
          %{headcount: 12, as_of: ~D[2026-03-01], source: "https://other.example/b"},
          target: id
        )
      )

    {:ok, %{"citations" => [newest, older]}} =
      World.history(a.id, Grants.operator(), %{
        "table" => "corporations",
        "id" => id,
        "column" => "headcount"
      })

    assert {newest["as_of"], older["as_of"]} == {~D[2026-03-01], ~D[2026-01-01]}

    assert {newest["source"]["host"], older["source"]["host"]} ==
             {"other.example", "stats.example.org"}

    assert {:error, :scope, _} =
             World.history(a.id, key(0), %{"table" => "corporations", "id" => id})
  end

  test "get finds a row by id or by any natural or unique key, and a deferred cell by its length and hash",
       %{account: a} do
    domain = "#{tag()}.example"

    attrs = %{domain: domain, name: "G", about: "what it does", source: "https://x.example/"}
    {[%{id: id}], []} = run(a.id, op(:put, :corporations, attrs, expect_rev: 0))

    {:ok, %{"row" => by_id}} =
      World.get(a.id, Grants.operator(), %{"table" => "corporations", "id" => id})

    {:ok, %{"row" => by_key}} =
      World.get(a.id, Grants.operator(), %{
        "table" => "corporations",
        "key" => %{"domain" => domain}
      })

    assert by_id == by_key
    assert by_id["about"]["len"] == byte_size("what it does")
    assert is_binary(by_id["about"]["sha"])

    assert {:error, :not_found, _} =
             World.get(a.id, Grants.operator(), %{
               "table" => "corporations",
               "key" => %{"domain" => "none.example"}
             })
  end

  test "a row dropped between a page's ids and its rows is left out, not an error", %{account: a} do
    t = tag()
    ids = for i <- 1..4, do: corp(a.id, %{domain: "#{i}.#{t}.example", name: "D#{i}"})
    gone = List.last(ids)
    handler = "drop-#{t}"
    test_pid = self()

    # After the page query names the ids, the last row goes, as a concurrent
    # drop would take it.
    :telemetry.attach(
      handler,
      [:hireme, :repo, :query],
      fn _e, _m, meta, _ ->
        if self() == test_pid and meta.source == "corporations" and Process.delete(:drop_once) do
          Repo.query!("DELETE FROM corporations WHERE id = ?", [gone], skip_account: true)
        end
      end,
      nil
    )

    Process.put(:drop_once, true)

    try do
      assert {:ok, %{"rows" => rows}} =
               World.find(a.id, Grants.operator(), %{
                 "table" => "corporations",
                 "where" => %{"domain" => %{"like" => t}}
               })

      assert ids(rows) == ids -- [gone]
    after
      :telemetry.detach(handler)
    end
  end

  test "a tampered cursor, an id past int64 or a filter for a key is refused type", %{account: a} do
    corp(a.id, %{domain: "#{tag()}.example", name: "C"})
    ctx = %{account_id: a.id, grants: Grants.operator()}

    bad_cursor =
      ["not a bool", %{"x" => 1}, 1] |> Jason.encode!() |> Base.url_encode64(padding: false)

    wrong_value = [false, %{"x" => 1}, 1] |> Jason.encode!() |> Base.url_encode64(padding: false)

    for params <- [
          %{"table" => "corporations", "after" => bad_cursor},
          %{"table" => "corporations", "order" => "name", "after" => wrong_value},
          %{"table" => "corporations", "id" => 9_223_372_036_854_775_808},
          %{"table" => "corporations", "key" => %{"domain" => %{"like" => "x"}}}
        ] do
      method = if Map.has_key?(params, "after"), do: "find", else: "get"
      assert {:error, :type, _} = World.call(method, params, ctx), inspect(params)
    end
  end

  test "a filter value past its column's range is refused type, and no refusal carries SQL", %{
    account: a
  } do
    ctx = %{account_id: a.id, grants: Grants.operator()}

    for where <- [
          %{"headcount" => 99_999_999_999_999_999_999},
          %{"rev" => %{"in" => [1, 9_223_372_036_854_775_808]}},
          %{"headcount" => %{"gt" => -1}}
        ] do
      assert {:error, :type, data} =
               World.call("find", %{"table" => "corporations", "where" => where}, ctx)

      refute inspect(data) =~ "SELECT"
    end
  end

  test "a cursor past int64 or with a false null flag, a float past the double, an offset that overflows: refused, never internal",
       %{account: a} do
    corp(a.id, %{domain: "#{tag()}.example", name: "C", ticker: "T"})
    ctx = %{account_id: a.id, grants: Grants.operator()}
    cursor = &(&1 |> Jason.encode!() |> Base.url_encode64(padding: false))

    for {method, params} <- [
          {"find",
           %{
             "table" => "corporations",
             "after" => cursor.([false, nil, 9_223_372_036_854_775_808])
           }},
          {"find",
           %{"table" => "corporations", "order" => "ticker", "after" => cursor.([false, nil, 1])}},
          {"find",
           %{
             "table" => "corporations",
             "order" => "headcount",
             "after" => cursor.([false, 99_999_999_999_999, 1])
           }},
          {"find",
           %{
             "table" => "corporations",
             "where" => %{
               "rating" => %{"gt" => String.to_integer("1" <> String.duplicate("0", 400))}
             }
           }},
          {"text",
           %{
             "table" => "corporations",
             "id" => 1,
             "column" => "note",
             "offset" => 9_223_372_036_854_775_807
           }}
        ] do
      assert {:error, code, _} = World.call(method, params, ctx), inspect(params, limit: 3)
      assert code in [:type, :too_large]
    end
  end

  test "get leaves a row's empty cells out", %{account: a} do
    id = corp(a.id, %{domain: "#{tag()}.example", name: "Sparse"})

    {:ok, %{"row" => row}} =
      World.get(a.id, Grants.operator(), %{"table" => "corporations", "id" => id})

    assert row["name"] == "Sparse"
    refute Map.has_key?(row, "ticker")
    assert Enum.all?(row, fn {_, v} -> v != nil end)
  end

  test "a refusal repeats a name the caller sent at most 64 bytes long", %{account: a} do
    long = String.duplicate("x", 100_000)
    ctx = %{account_id: a.id, grants: Grants.operator()}

    for {method, params} <- [
          {long, %{}},
          {"find", %{"table" => long}},
          {"find", %{"table" => "corporations", "cols" => [long]}},
          {"find", %{"table" => "corporations", "order" => long}}
        ] do
      {:error, _, data} = World.call(method, params, ctx)
      assert byte_size(inspect(data)) < 400
    end
  end
end
