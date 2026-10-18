defmodule Hireme.ProvenanceTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.Provenance
  alias Hireme.Rows.{Citation, Corporation, Source}

  defp corp(a, domain) do
    {[ack], []} = run(a.id, op(:put, :corporations, %{domain: domain, name: domain}))
    ack.id
  end

  property "stale is monotonic: a metric's date only moves forward, and every accepted change is cited",
           %{account: a} do
    check all(days <- list_of(integer(0..60), min_length: 1, max_length: 10), max_runs: 20) do
      id = corp(a, "m#{System.unique_integer([:positive])}.example")

      {newest, accepted} =
        Enum.reduce(days, {nil, 0}, fn d, {newest, n} ->
          on = Date.add(~D[2026-08-01], d)

          {acks, nacks} =
            run(a.id, op(:put, :corporations, %{headcount: d, as_of: on}, target: id))

          if newest && Date.compare(on, newest) == :lt do
            assert {[], [%{refusal: :stale}]} = {acks, nacks}
            {newest, n}
          else
            assert [_] = acks
            # The same value at the stored date restates it: no citation.
            {on, if(on == newest, do: n, else: n + 1)}
          end
        end)

      assert Repo.get!(Corporation, id).headcount_on == newest

      assert Repo.aggregate(
               from(c in Citation, where: c.row_id == ^id and c.column == "headcount"),
               :count
             ) == accepted
    end
  end

  test "a metric without as_of is freshness; prose without expect_rev is rev, without a source source_missing",
       %{account: a} do
    id = corp(a, "p.example")

    assert {[], [%{refusal: :freshness}]} =
             run(a.id, op(:put, :corporations, %{revenue_usd: 1.0e6}, target: id))

    assert {[], [%{refusal: :rev}]} =
             run(
               a.id,
               op(:put, :corporations, %{about: "x", source: "https://p.example/"}, target: id)
             )

    assert {[], [%{refusal: :source_missing}]} =
             run(a.id, op(:put, :corporations, %{about: "x"}, target: id, expect_rev: 1))

    assert {[], [%{refusal: :source_missing}]} =
             run(
               a.id,
               op(:put, :corporations, %{about: "x", source: 424_242}, target: id, expect_rev: 1)
             )
  end

  test "a source's host is derived by the server, never taken from the writer", %{account: a} do
    id = corp(a, "h.example")

    {[_], []} =
      run(
        a.id,
        op(
          :put,
          :corporations,
          %{headcount: 5, as_of: ~D[2026-10-01], source: "https://News.Example.ORG./story?x=1"},
          target: id
        )
      )

    assert [%{host: "news.example.org"}] = Repo.all(Source)

    assert {[], [%{refusal: :column}]} =
             run(a.id, op(:put, :sources, %{url: "https://a.example/", host: "evil.example"}))

    {[s], []} = run(a.id, op(:put, :sources, %{url: "https://b.example/page"}))
    assert Repo.get!(Source, s.id).host == "b.example"
  end

  test "the operator's drop of a cited source is a tombstone its citations keep naming", %{
    account: a
  } do
    id = corp(a, "l.example")

    {[_], []} =
      run(
        a.id,
        op(:put, :corporations, %{about: "x", source: "https://l.example/about"},
          target: id,
          expect_rev: 1
        )
      )

    [c] = Repo.all(from(c in Citation, where: c.row_id == ^id and c.column == "about"))
    assert c.source_id

    assert {[_], []} = run(a.id, op(:drop, :sources, %{}, target: c.source_id))
    assert Repo.get!(Citation, c.id).source_id == c.source_id
    # The operator's drop of a cited source is a tombstone; an uncited one goes.
    assert %{deleted_at: %DateTime{}, url: "https://l.example/about"} =
             Repo.get!(Source, c.source_id)

    {[uncited], []} = run(a.id, op(:put, :sources, %{url: "https://l.example/other"}))
    assert {[_], []} = run(a.id, op(:drop, :sources, %{}, target: uncited.id))
    refute Repo.get(Source, uncited.id)
  end

  test "a key cannot drop a source a citation names: provenance outlives it", %{
    account: a,
    session: s
  } do
    id = corp(a, "k.example")

    {[_], []} =
      run(
        a.id,
        op(:put, :corporations, %{about: "x", source: "https://k.example/about"},
          target: id,
          expect_rev: 1
        )
      )

    [c] = Repo.all(from(c in Citation, where: c.row_id == ^id and c.column == "about"))

    {:ok, %{key: key}} =
      Hireme.Keys.mint(s, "deleter", %{read_mask: 31, write_mask: 31, may_delete: true})

    {agent, _} = key_session(a.id, key, 997)

    assert {[], [%{refusal: :scope} = nack]} =
             key_session_ops(agent, op(:drop, :sources, %{}, target: c.source_id))

    assert JSON.decode!(nack.data)["reason"] =~ "provenance"
    assert Repo.get(Source, c.source_id)

    {[uncited], []} = run(a.id, op(:put, :sources, %{url: "https://k.example/other"}))
    assert {[_], []} = key_session_ops(agent, op(:drop, :sources, %{}, target: uncited.id))
  end

  test "restating a cited metric exactly writes nothing; the same value from another source is cited",
       %{account: a} do
    id = corp(a, "same.example")

    put = fn src ->
      op(:put, :corporations, %{headcount: 50, as_of: ~D[2026-09-01], source: src}, target: id)
    end

    cites = fn ->
      Repo.aggregate(
        from(c in Citation, where: c.row_id == ^id and c.column == "headcount"),
        :count
      )
    end

    {[first], []} = run(a.id, put.("https://same.example/a"))
    {[again], []} = run(a.id, put.("https://same.example/a"))
    assert again.rev == first.rev and cites.() == 1

    {[other], []} = run(a.id, put.("https://same.example/b"))
    assert other.rev == first.rev + 1 and cites.() == 2

    # Unsourced: restated exactly, it is the same citation too.
    unsourced = fn ->
      op(:put, :corporations, %{revenue_usd: 1.0e6, as_of: ~D[2026-09-01]}, target: id)
    end

    {[u1], []} = run(a.id, unsourced.())
    {[u2], []} = run(a.id, unsourced.())
    assert u2.rev == u1.rev

    assert Repo.aggregate(
             from(c in Citation, where: c.row_id == ^id and c.column == "revenue_usd"),
             :count
           ) == 1
  end

  test "culture and ratings need a trusted host; trusting a host covers its subdomains", %{
    account: a
  } do
    id = corp(a, "t.example")
    rating = %{rating: 4.1, as_of: ~D[2026-10-01], source: "https://www.ratings.example/c"}

    assert {[], [%{refusal: :source_trust}]} =
             run(a.id, op(:put, :corporations, rating, target: id))

    assert {[], [%{refusal: :source_missing}]} =
             run(a.id, op(:put, :corporations, %{rating: 4.1, as_of: ~D[2026-10-01]}, target: id))

    {:ok, _} = Provenance.trust("ratings.example", "reviews", %{})
    assert [%{host: "ratings.example", note: "reviews"}] = Provenance.trusted_hosts()
    {[_], []} = run(a.id, op(:put, :corporations, rating, target: id))

    [%{id: host_id}] = Provenance.trusted_hosts()
    :ok = Provenance.distrust(host_id, %{})

    assert {[], [%{refusal: :source_trust}]} =
             run(
               a.id,
               op(
                 :put,
                 :corporations,
                 %{rating_count: 9, as_of: ~D[2026-10-02], source: "https://ratings.example/"},
                 target: id
               )
             )
  end

  test "a source written directly needs an http(s) URL on a real hostname", %{account: a} do
    long = Enum.map_join(~w(a b c d e), ".", &String.duplicate(&1, 60)) <> ".example"

    for url <- [
          "http://10.0.0.1/x",
          "http://127.1/",
          "http://0x7f.1/",
          "https://#{long}/",
          "https://ex_ample.com/",
          "http://localhost/",
          "https://münchen.example/",
          "ftp://a.example/",
          "https://evil.example\\@levels.fyi/"
        ] do
      assert {[], [%{refusal: :type}]} = run(a.id, op(:put, :sources, %{url: url})), url
    end

    assert {[_], []} = run(a.id, op(:put, :sources, %{url: "https://xn--mnchen-3ya.example/a"}))
  end

  test "the operator's trusted hosts stop at their declared cap", %{account: a} do
    cap = Schema.table(:trusted_hosts).cap
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      Hireme.Rows.TrustedHost,
      for(
        i <- 1..(cap - 1),
        do: %{account_id: a.id, host: "h#{i}.example", rev: 1, inserted_at: now, updated_at: now}
      )
    )

    assert {:ok, _} = Provenance.trust("last.example", nil, %{})
    assert {:error, :cap} = Provenance.trust("over.example", nil, %{})
    # Re-trusting one already listed only edits its note.
    assert {:ok, _} = Provenance.trust("last.example", "edited", %{})
  end

  test "citations are in no mask: no key writes one", %{account: a} do
    key = %{
      label: "k",
      grants: Grants.key(%{id: 1, read_mask: 31, write_mask: 31, may_delete: true}),
      key_id: nil
    }

    assert {[], [%{refusal: :scope}]} = run(a.id, op(:put, :citations, %{}), key)

    assert {[], [%{refusal: :scope}]} =
             run(a.id, op(:put, :trusted_hosts, %{host: "x.example"}), key)
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
  end
end
