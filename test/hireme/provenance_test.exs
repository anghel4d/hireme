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

  property "stale is monotonic: a metric's date only moves forward, and every accepted write is cited",
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
            {on, n + 1}
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
    for url <- [
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
