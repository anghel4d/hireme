defmodule Hireme.ProvenanceTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.Provenance
  alias Hireme.Rows.{Citation, Corporation, Source}

  defp corp(a, domain),
    do: ack!(a.id, op(:put, :corporations, %{domain: domain, name: domain})).id

  defp put(id, cells, opts \\ []), do: op(:put, :corporations, cells, [target: id] ++ opts)

  defp cites(id, column),
    do:
      Repo.aggregate(from(c in Citation, where: c.row_id == ^id and c.column == ^column), :count)

  property "a metric is written and cited exactly when (value, source, as_of) differs from its last citation, column by column, and its date never moves back",
           %{account: a} do
    step =
      tuple(
        {member_of([:headcount, :revenue_usd, :both]), integer(1..3), integer(1..3),
         member_of([nil, "a", "b"]), integer(0..3)}
      )

    check all(steps <- list_of(step, min_length: 1, max_length: 12), max_runs: 20) do
      tag = System.unique_integer([:positive])
      id = corp(a, "m#{tag}.example")
      url = fn s -> "https://m#{tag}.example/#{s}" end
      # Both sources exist before the sequence, so a new source never decides.
      for s <- ~w(a b), do: ack!(a.id, op(:put, :sources, %{url: url.(s)}))

      model =
        Enum.reduce(steps, %{last: %{}, rev: 1, cites: %{}}, fn {which, v1, v2, s, d}, m ->
          on = Date.add(~D[2026-08-01], d)
          cols = if which == :both, do: [:headcount, :revenue_usd], else: [which]
          cells = Map.take(%{headcount: v1, revenue_usd: v2 * 1.0e6}, cols)
          reserved = if s, do: %{as_of: on, source: url.(s)}, else: %{as_of: on}
          verdict = run(a.id, put(id, Map.merge(cells, reserved)))

          stale =
            Enum.any?(cols, fn c ->
              match?({_, _, was} when was != nil, m.last[c]) and
                Date.compare(on, elem(m.last[c], 2)) == :lt
            end)

          changed = for {c, v} <- cells, m.last[c] != {v, s, on}, do: c

          cond do
            stale ->
              assert {[], [%{refusal: :stale}]} = verdict
              m

            changed == [] ->
              assert {[%{rev: rev}], []} = verdict
              assert rev == m.rev
              m

            true ->
              assert {[%{rev: rev}], []} = verdict
              assert rev == m.rev + 1

              %{
                m
                | rev: rev,
                  last: Enum.reduce(cells, m.last, fn {c, v}, l -> Map.put(l, c, {v, s, on}) end),
                  cites: Enum.reduce(changed, m.cites, &Map.update(&2, &1, 1, fn n -> n + 1 end))
              }
          end
        end)

      row = Repo.get!(Corporation, id)
      assert row.rev == model.rev

      for {c, {v, _, on}} <- model.last,
          do: assert({Map.fetch!(row, c), Map.fetch!(row, :"#{c}_on")} == {v, on})

      for c <- [:headcount, :revenue_usd],
          do: assert(cites(id, "#{c}") == Map.get(model.cites, c, 0), inspect(c))
    end
  end

  test "a metric needs as_of, a real day and not in the future; prose needs expect_rev and a source",
       %{account: a} do
    id = corp(a, "p.example")
    t = Schema.table(:corporations)
    hc = Enum.find(t.cols, &(&1.name == "headcount"))
    cells = [{hc.id, 1, 5}, {Codec.as_of_col(), 1, 4_000_000_000}]
    {:ok, huge, ""} = Codec.op(Codec.encode_op({1, :put, 0, t.id, id, nil, cells}))
    prose = &put(id, Map.put(&1, :about, "x"), &2)

    for {o, code} <- [
          {put(id, %{revenue_usd: 1.0e6}), :freshness},
          {put(id, %{headcount: 5, as_of: Date.add(Date.utc_today(), 30)}), :freshness},
          {huge, :type},
          {prose.(%{source: "https://p.example/"}, []), :rev},
          {prose.(%{}, expect_rev: 1), :source_missing},
          {prose.(%{source: 424_242}, expect_rev: 1), :source_missing}
        ],
        do: assert(nack!(a.id, o) == code, inspect(code))

    assert %{headcount: nil, about: nil} = Repo.get!(Corporation, id)
  end

  test "a source's host is derived by the server, never taken from the writer", %{account: a} do
    id = corp(a, "h.example")
    cells = %{headcount: 5, as_of: ~D[2026-10-01], source: "https://News.Example.ORG./story?x=1"}
    ack!(a.id, put(id, cells))
    assert [%{host: "news.example.org"}] = Repo.all(Source)
    forged = %{url: "https://a.example/", host: "evil.example"}
    assert nack!(a.id, op(:put, :sources, forged)) == :column
    s = ack!(a.id, op(:put, :sources, %{url: "https://b.example/page"}))
    assert Repo.get!(Source, s.id).host == "b.example"
  end

  test "a cited source outlives its citations: the operator's drop is a tombstone they keep naming, a key's is refused; an uncited one goes",
       %{account: a, session: s} do
    id = corp(a, "l.example")
    ack!(a.id, put(id, %{about: "x", source: "https://l.example/about"}, expect_rev: 1))
    [c] = Repo.all(from(c in Citation, where: c.row_id == ^id and c.column == "about"))
    assert c.source_id
    masks = %{read_mask: 15, write_mask: 15, may_delete: true}
    {:ok, %{key: key}} = Hireme.Keys.mint(s, "deleter", masks)
    {agent, _} = key_session(a.id, key, 997)
    drop = &op(:drop, :sources, %{}, target: &1)
    assert {[], [%{refusal: :scope} = nack]} = key_session_ops(agent, drop.(c.source_id))
    assert JSON.decode!(nack.data)["reason"] =~ "provenance"

    ack!(a.id, drop.(c.source_id))
    assert Repo.get!(Citation, c.id).source_id == c.source_id
    tombstone = Repo.get!(Source, c.source_id)
    assert %{deleted_at: %DateTime{}, url: "https://l.example/about"} = tombstone

    uncited = ack!(a.id, op(:put, :sources, %{url: "https://l.example/other"}))
    assert {[_], []} = key_session_ops(agent, drop.(uncited.id))
    refute Repo.get(Source, uncited.id)
  end

  test "prose restated exactly (text, source, expect_rev, and as_of if given) writes nothing; another source or date cites; a stale rev is refused",
       %{account: a} do
    id = corp(a, "pr.example")

    put = fn cells, rev ->
      put(id, Map.merge(%{about: "Old", source: "https://pr.example/x"}, cells), expect_rev: rev)
    end

    r1 = ack!(a.id, put.(%{}, 1))
    r2 = ack!(a.id, put.(%{source: "https://pr.example/y"}, r1.rev))
    same = ack!(a.id, put.(%{source: "https://pr.example/y"}, r2.rev))
    assert same.rev == r2.rev and cites(id, "about") == 2
    r3 = ack!(a.id, put.(%{}, r2.rev))
    assert r3.rev == r2.rev + 1 and cites(id, "about") == 3
    assert nack!(a.id, put.(%{}, r2.rev)) == :rev

    r4 = ack!(a.id, put.(%{as_of: ~D[2026-09-01]}, r3.rev))
    same = ack!(a.id, put.(%{as_of: ~D[2026-09-01]}, r4.rev))
    assert same.rev == r4.rev and cites(id, "about") == 4
    r5 = ack!(a.id, put.(%{as_of: ~D[2026-09-15]}, r4.rev))
    assert r5.rev == r4.rev + 1 and cites(id, "about") == 5
    assert Repo.get!(Corporation, id).rev == r5.rev
  end

  test "culture and ratings need a trusted host; trusting a host covers its subdomains, until distrusted; the trusted hosts stop at their declared cap",
       %{account: a} do
    id = corp(a, "t.example")
    rating = %{rating: 4.1, as_of: ~D[2026-10-01], source: "https://www.ratings.example/c"}
    assert nack!(a.id, put(id, rating)) == :source_trust
    assert nack!(a.id, put(id, Map.delete(rating, :source))) == :source_missing
    {:ok, _} = Provenance.trust("ratings.example", "reviews", %{})
    assert [%{id: host_id, host: "ratings.example", note: "reviews"}] = Provenance.trusted_hosts()
    ack!(a.id, put(id, rating))
    culture = %{culture: "Calm.", source: "https://www.levels.fyi/x"}
    assert nack!(a.id, put(id, culture, expect_rev: 2)) == :source_trust
    :ok = Provenance.distrust(host_id, %{})
    cells = %{rating_count: 9, as_of: ~D[2026-10-02], source: "https://ratings.example/"}
    assert nack!(a.id, put(id, cells)) == :source_trust

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    host = &%{account_id: a.id, host: "h#{&1}.example", rev: 1, inserted_at: now, updated_at: now}

    Repo.insert_all(
      Hireme.Rows.TrustedHost,
      for(i <- 2..Schema.table(:trusted_hosts).cap, do: host.(i))
    )

    assert {:ok, _} = Provenance.trust("last.example", nil, %{})
    assert {:error, :cap} = Provenance.trust("over.example", nil, %{})
    # Re-trusting one already listed only edits its note.
    assert {:ok, _} = Provenance.trust("last.example", "edited", %{})
  end

  test "a source URL is http(s) on a real hostname and at most 2,048 bytes, written directly or cited",
       %{account: a} do
    id = corp(a, "u.example")
    long = Enum.map_join(~w(a b c d e), ".", &String.duplicate(&1, 60)) <> ".example"
    too_long = "https://long.example/" <> String.duplicate("p", 2_048)

    for url <- [
          "http://10.0.0.1/x",
          "http://127.1/",
          "http://0x7f.1/",
          "https://#{long}/",
          "https://ex_ample.com/",
          "http://localhost/",
          "https://münchen.example/",
          "ftp://a.example/",
          "https://evil.example\\@levels.fyi/",
          too_long
        ],
        do: assert(nack!(a.id, op(:put, :sources, %{url: url})) == :type, url)

    {[], [nack]} = run(a.id, put(id, %{headcount: 1, as_of: ~D[2026-09-01], source: too_long}))
    assert nack.refusal == :type and JSON.decode!(nack.data)["reason"] =~ "2048 bytes"
    ack!(a.id, op(:put, :sources, %{url: "https://xn--mnchen-3ya.example/a"}))
  end

  property "host/1 lowercases, drops the port and a trailing dot, and refuses what is not a web URL" do
    check all(
            label <- string(?a..?z, min_length: 1, max_length: 8),
            tld <- member_of(~w(com org io)),
            port <- one_of([constant(""), map(integer(1..65535), &":#{&1}")]),
            scheme <- member_of(~w(http https HTTPS))
          ) do
      assert Provenance.host("#{scheme}://#{String.upcase(label)}.#{tld}.#{port}/p") ==
               "#{label}.#{tld}"
    end

    assert Provenance.host("ftp://a.example/") == nil
    assert Provenance.host("not a url") == nil
    assert Provenance.host("https://a.example/" <> String.duplicate("p", 2_048)) == nil

    # A port a browser refuses: the link could never open; leading zeros are a browser's too.
    for bad <- ~w(:65536 :99999 :80a :a :+1 :1e3 :١٢),
        do: assert(Provenance.host("https://a.example#{bad}/p") == nil, bad)

    for ok <- ~w(: :65535 :00080 :0 :00),
        do: assert(Provenance.host("https://a.example#{ok}/p") == "a.example", ok)

    # A URL past 4 KiB or a huge port is refused before any parsing: a cost
    # regression was ~200 ms; 20 ms leaves a loaded machine room.
    for hostile <- [
          "https://a.example:" <> String.duplicate("9", 1_000_000),
          "https://a.example/" <> String.duplicate("p", 1_048_576),
          "https://" <> String.duplicate("a.", 500_000) <> "example/"
        ] do
      {us, nil} = :timer.tc(fn -> Provenance.host(hostile) end)
      assert us < 20_000, "#{us} µs for #{byte_size(hostile)} bytes"
    end
  end
end
