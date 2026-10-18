defmodule Hireme.SequencerTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.Rows.{Corporation, Office, Place}

  defp key(read, write, delete \\ false),
    do: %{
      label: "agent",
      grants: Grants.key(%{id: 1, read_mask: read, write_mask: write, may_delete: delete}),
      key_id: nil
    }

  test "an insert ACKs its new id at rev 1, an update the same id at rev 2, and the account rev counts both",
       %{account: a} do
    {[ack], []} = run(a.id, op(:put, :corporations, %{domain: "example.com", name: "Example"}))
    assert ack.rev == 1 and ack.id > 0
    {[ack2], []} = run(a.id, op(:put, :corporations, %{name: "Example Inc"}, target: ack.id))
    assert {ack2.id, ack2.rev} == {ack.id, 2}
    assert Repo.get!(Corporation, ack.id).name == "Example Inc"
    assert Sequencer.rev(a.id) == a.desk_rev + 2
  end

  test "a refusal rolls back exactly its own op", %{account: a} do
    ops = [
      op(:put, :corporations, %{domain: "a.example", name: "A"}),
      op(:put, :corporations, %{domain: "b.example"}),
      op(:put, :corporations, %{domain: "c.example", name: "C"})
    ]

    {acks, [nack]} = run(a.id, ops)
    assert length(acks) == 2 and nack.refusal == :column

    assert Repo.all(from c in Corporation, select: c.domain, order_by: c.domain) == [
             "a.example",
             "c.example"
           ]
  end

  property "a resent op writes nothing and answers its first verdict", %{account: a} do
    check all(
            names <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 6),
            resend <- list_of(integer(0..5), max_length: 6),
            max_runs: 15
          ) do
      ops =
        for n <- names,
            do:
              op(:put, :corporations, %{
                domain: "#{n}.#{System.unique_integer([:positive])}.example",
                name: n
              })

      {first, []} = run(a.id, ops)
      before = Repo.aggregate(Corporation, :count)
      again = for i <- resend, i < length(ops), do: Enum.at(ops, i)
      {acks, []} = run(a.id, again)
      assert Repo.aggregate(Corporation, :count) == before
      assert Enum.all?(acks, &(&1 in first))
    end
  end

  test "masks: a read-only key's put is scope, a write-only key's put ACKs, a drop needs may_delete",
       %{account: a} do
    put = fn ->
      op(:put, :corporations, %{
        domain: "k#{System.unique_integer([:positive])}.example",
        name: "K"
      })
    end

    assert {[], [%{refusal: :scope}]} = run(a.id, put.(), key(31, 0))
    {[ack], []} = run(a.id, put.(), key(0, 31))

    assert {[], [%{refusal: :scope}]} =
             run(a.id, op(:drop, :corporations, %{}, target: ack.id), key(0, 31))

    assert {[_], []} = run(a.id, op(:drop, :corporations, %{}, target: ack.id), key(0, 31, true))
  end

  test "a keyed put finds its row by natural key; create_only refuses an existing one", %{
    account: a
  } do
    {[first], []} =
      run(a.id, op(:put, :corporations, %{domain: "keyed.example", name: "One"}, keyed: true))

    {[second], []} =
      run(a.id, op(:put, :corporations, %{domain: "keyed.example", name: "Two"}, keyed: true))

    assert second.id == first.id and second.rev == 2

    assert {[], [%{refusal: :natural_key}]} =
             run(
               a.id,
               op(:put, :corporations, %{domain: "keyed.example", name: "Three"},
                 keyed: true,
                 create_only: true
               )
             )
  end

  test "cells are typed: a wrong wire type is refused, never cast", %{account: a} do
    t = Schema.table(:corporations)
    name = Enum.find(t.cols, &(&1.name == "name"))
    domain = Enum.find(t.cols, &(&1.name == "domain"))

    raw =
      Codec.encode_op(
        {1, :put, 0, t.id, 0, nil, [{domain.id, 2, "typed.example"}, {name.id, 1, 5}]}
      )

    {:ok, op, ""} = Codec.op(raw)
    assert {[], [%{refusal: :type}]} = run(a.id, op)
  end

  test "a metric needs as_of, is never older than stored, and leaves a citation", %{account: a} do
    base = %{domain: "metric.example", name: "M"}

    assert {[], [%{refusal: :freshness}]} =
             run(a.id, op(:put, :corporations, Map.put(base, :headcount, 10)))

    {[ack], []} =
      run(
        a.id,
        op(
          :put,
          :corporations,
          Map.merge(base, %{headcount: 10, as_of: ~D[2026-10-01], source: "https://example.org/a"})
        )
      )

    assert %{headcount: 10, headcount_on: ~D[2026-10-01]} = Repo.get!(Corporation, ack.id)

    assert {[], [%{refusal: :stale}]} =
             run(
               a.id,
               op(:put, :corporations, %{headcount: 9, as_of: ~D[2026-09-01]}, target: ack.id)
             )

    {[_], []} =
      run(a.id, op(:put, :corporations, %{headcount: 11, as_of: ~D[2026-10-01]}, target: ack.id))

    cites =
      Repo.all(
        from c in Hireme.Rows.Citation,
          where: c.row_id == ^ack.id and c.column == "headcount",
          order_by: c.id
      )

    assert Enum.map(cites, & &1.value) == [%{"v" => 10}, %{"v" => 11}]
    assert Repo.get!(Hireme.Rows.Source, hd(cites).source_id).host == "example.org"
  end

  test "prose needs expect_rev and a source; culture needs a trusted host", %{account: a} do
    {[ack], []} = run(a.id, op(:put, :corporations, %{domain: "prose.example", name: "P"}))
    about = %{about: "Makes things."}

    assert {[], [%{refusal: :rev}]} =
             run(
               a.id,
               op(:put, :corporations, Map.put(about, :source, "https://p.example/"),
                 target: ack.id
               )
             )

    assert {[], [%{refusal: :source_missing}]} =
             run(a.id, op(:put, :corporations, about, target: ack.id, expect_rev: 1))

    assert {[], [%{refusal: :rev}]} =
             run(
               a.id,
               op(:put, :corporations, Map.put(about, :source, "https://p.example/"),
                 target: ack.id,
                 expect_rev: 7
               )
             )

    {[_], []} =
      run(
        a.id,
        op(:put, :corporations, Map.put(about, :source, "https://p.example/"),
          target: ack.id,
          expect_rev: 1
        )
      )

    culture = %{culture: "Calm.", source: "https://www.levels.fyi/x"}

    assert {[], [%{refusal: :source_trust}]} =
             run(a.id, op(:put, :corporations, culture, target: ack.id, expect_rev: 2))

    {:ok, _} = Hireme.Provenance.trust("levels.fyi", nil, %{})
    {[_], []} = run(a.id, op(:put, :corporations, culture, target: ack.id, expect_rev: 2))
  end

  test "a drop takes the rows whose required ref names it", %{account: a} do
    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "drop.example", name: "D"}))
    {[place], []} = run(a.id, op(:put, :places, %{kind: :country, name: "Nowhere", iso2: "NW"}))

    {[_], []} =
      run(a.id, op(:put, :offices, %{corporation_id: corp.id, place_id: place.id, kind: :hq}))

    {[_], []} = run(a.id, op(:drop, :corporations, %{}, target: corp.id))
    assert Repo.aggregate(Office, :count) == 0
    assert Repo.get(Place, place.id)
  end

  test "a deleted application leaves the kernel too: it is no longer claimable", %{account: a} do
    {[keep], []} = run(a.id, op(:put, :applications, %{company: "Keep", role: "R"}))
    {[gone], []} = run(a.id, op(:put, :applications, %{company: "Gone", role: "R"}))
    {[_], []} = run(a.id, op(:drop, :applications, %{}, target: gone.id))
    session = %{id: 903, label: "agent", grants: Grants.operator(), key_id: nil, session_id: nil}
    {:ok, _} = Sequencer.subscribe(a.id, session, 0)

    assert {:ok, %{"ids" => [id], "truncated" => true}} =
             Hireme.Lease.claim(a.id, 903, %{"count" => 5})

    assert id == keep.id
  end

  test "a key's session writes only after it opens the lease", %{account: a, session: s} do
    {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))
    session = %{id: 900, label: "agent", grants: Grants.key(key), key_id: key.id, session_id: nil}
    {:ok, %{lease: false}} = Sequencer.subscribe(a.id, session, 0)
    Sequencer.submit(a.id, [op(:put, :corporations, %{domain: "l.example", name: "L"}, op_id: 1)])
    assert_receive {:sequencer, :verdicts, _, [], [%{code: code}]}
    assert Schema.refusal_name(code) == :lease_missing
    {:ok, %{"ids" => []}} = Hireme.Lease.claim(a.id, 900, %{})
    Sequencer.submit(a.id, [op(:put, :corporations, %{domain: "l.example", name: "L"}, op_id: 2)])
    assert_receive {:sequencer, :verdicts, _, [%{op_id: 2}], []}
  end

  test "subscribers get the PATCH before the submitter's ACK, filtered by their read mask", %{
    account: a
  } do
    reader = %{
      id: 901,
      label: "reader",
      grants: Grants.key(%{id: 2, read_mask: 2, write_mask: 0, may_delete: false}),
      key_id: nil,
      session_id: nil
    }

    me = self()

    other =
      spawn_link(fn ->
        {:ok, _} = Sequencer.subscribe(a.id, reader, 0)
        send(me, :subscribed)

        receive do
          {:sequencer, :patch, _, body} -> send(me, {:other_patch, body})
        after
          2_000 -> send(me, :other_nothing)
        end
      end)

    assert_receive :subscribed
    op = op(:put, :gym_reps, %{platform: :leetcode, slug: "two-sum", done_on: ~D[2026-10-18]})

    {:ok, _} =
      Sequencer.subscribe(
        a.id,
        %{id: 902, label: "op", grants: Grants.operator(), key_id: nil, session_id: 1},
        0
      )

    Sequencer.submit(a.id, [op])
    assert_receive {:sequencer, :patch, _, body}
    assert {"gym_reps", 1} in tables(body)
    assert_receive {:sequencer, :verdicts, _, [_], []}
    # The desk-only reader learns the rev moved, and is sent no lanes row.
    assert_receive {:other_patch, other_body}, 3_000
    assert tables(other_body) == []
    _ = other
  end

  property "a subscriber's BOOT plus its PATCHes is a fresh BOOT, and a mask never lets a row through",
           %{account: a} do
    gen_action =
      one_of([
        tuple({constant(:rep), string(:alphanumeric, min_length: 1, max_length: 6)}),
        tuple({constant(:app), string(:alphanumeric, min_length: 1, max_length: 6)}),
        tuple({constant(:note), integer(0..20), string(:printable, max_length: 12)}),
        tuple({constant(:drop), integer(0..20)})
      ])

    check all(actions <- list_of(gen_action, min_length: 1, max_length: 12), max_runs: 12) do
      me = self()

      sub = fn id, grants ->
        %{id: id, label: "s", grants: grants, key_id: nil, session_id: nil}
      end

      lanes_only = Grants.key(%{id: 3, read_mask: 8, write_mask: 0, may_delete: false})

      watcher =
        spawn_link(fn ->
          {:ok, %{frames: [f]}} =
            Sequencer.subscribe(a.id, sub.(System.unique_integer([:positive]), lanes_only), 0)

          send(me, {:watching, f})
          watch(me)
        end)

      assert_receive {:watching, _}

      {:ok, %{frames: [boot]}} =
        Sequencer.subscribe(a.id, sub.(System.unique_integer([:positive]), Grants.operator()), 0)

      {:ok, :BOOT, _, _, body} = Codec.decode(boot)
      model = ingest(%{}, :BOOT, body)

      ids = fn table -> Map.keys(Map.get(model, table, %{})) end

      ops =
        Enum.map(actions, fn
          {:rep, slug} ->
            op(:put, :gym_reps, %{platform: :leetcode, slug: slug, done_on: ~D[2026-10-18]})

          {:app, role} ->
            op(:put, :applications, %{company: "Co", role: role})

          {:note, i, text} ->
            op(:put, :gym_reps, %{note: text}, target: Enum.at(ids.("gym_reps"), i, 999_999))

          {:drop, i} ->
            op(:drop, :gym_reps, %{}, target: Enum.at(ids.("gym_reps"), i, 999_999))
        end)

      Sequencer.submit(a.id, ops)
      model = drain(model)

      {:ok, %{frames: [fresh]}} =
        Sequencer.subscribe(a.id, sub.(System.unique_integer([:positive]), Grants.operator()), 0)

      {:ok, :BOOT, _, _, fresh_body} = Codec.decode(fresh)
      assert model == ingest(%{}, :BOOT, fresh_body)

      send(watcher, {:done, me})
      assert_receive {:watched, tables}
      assert Enum.all?(tables, &(&1 in ~w(gym_reps net_entries gone leases)))
    end
  end

  defp drain(model) do
    receive do
      {:sequencer, :patch, _, body} -> drain(ingest(model, :PATCH, body))
      {:sequencer, :verdicts, _, _, _} -> model
    after
      3_000 -> flunk("no verdicts")
    end
  end

  defp watch(parent, seen \\ []) do
    receive do
      {:sequencer, :patch, _, body} -> watch(parent, seen ++ Enum.map(tables(body), &elem(&1, 0)))
      {:done, ^parent} -> send(parent, {:watched, Enum.uniq(seen)})
    end
  end
end
