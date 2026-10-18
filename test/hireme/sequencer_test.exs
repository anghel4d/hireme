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

  property "in any batch, each refusal rolls back exactly its own op", %{account: a} do
    # Each op is valid, or refused by its own fault: a missing required
    # column (column) or a target that names no row (not_found).
    check all(
            kinds <-
              list_of(member_of([:ok, :ok, :column, :not_found]), min_length: 1, max_length: 12),
            max_runs: 15
          ) do
      tag = System.unique_integer([:positive])
      before = Repo.all(from c in Corporation, select: c.domain)

      ops =
        kinds
        |> Enum.with_index()
        |> Enum.map(fn
          {:ok, i} -> op(:put, :corporations, %{domain: "#{tag}-#{i}.example", name: "N"})
          {:column, i} -> op(:put, :corporations, %{domain: "#{tag}-#{i}.example"})
          {:not_found, i} -> op(:put, :corporations, %{name: "#{i}"}, target: 999_999_999)
        end)

      {acks, nacks} = run(a.id, ops)
      assert length(acks) == Enum.count(kinds, &(&1 == :ok))
      assert Enum.map(nacks, & &1.refusal) == Enum.reject(kinds, &(&1 == :ok))

      accepted = for {:ok, i} <- Enum.with_index(kinds), do: "#{tag}-#{i}.example"
      after_ = Repo.all(from c in Corporation, select: c.domain)
      assert Enum.sort(after_ -- before) == Enum.sort(accepted)
    end
  end

  test "no refusal leaves the node without a reason", %{account: a, session: s} do
    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "r.example", name: "R"}))
    {[app], []} = run(a.id, op(:put, :applications, %{company: "R", role: "R"}))

    ops = [
      op(:put, :corporations, %{domain: "r2.example"}),
      op(:put, :corporations, %{name: "X"}, target: 999_999_999),
      op(:put, :corporations, %{domain: "r.example", name: "R"}, keyed: true, create_only: true),
      op(:put, :corporations, %{name: "Y"}, target: corp.id, expect_rev: 7),
      op(:put, :corporations, %{headcount: 5}, target: corp.id),
      op(:put, :corporations, %{about: "x"}, target: corp.id, expect_rev: 1),
      op(:command, :stage, %{stage: :reply}, target: app.id),
      op(:put, :applications, %{notes: String.duplicate("x", 1_048_577)}, target: app.id)
    ]

    {[], nacks} = run(a.id, ops)
    assert length(nacks) == length(ops)

    # A key's refusals too, including one redacted for a table it cannot read.
    {:ok, %{key: key}} =
      Hireme.Keys.mint(s, "blind", %{read_mask: 0, write_mask: 2, may_delete: false})

    {agent, _} = key_session(a.id, key, 994)

    {[], key_nacks} =
      key_session_ops(agent, [
        op(:put, :corporations, %{domain: "k.example", name: "K"}),
        op(:put, :applications, %{role: "x"}, target: app.id, expect_rev: 9)
      ])

    for n <- nacks ++ key_nacks do
      reason = JSON.decode!(n.data)["reason"]
      assert is_binary(reason) and reason != "", "#{n.refusal} has no reason: #{n.data}"
    end

    # A code's default reason is marked; a site's own is not.
    assert JSON.decode!(hd(nacks).data)["reason_default"] == true
    {[], [own]} = run(a.id, op(:put, :corporations, %{name: "No key"}, keyed: true))
    assert JSON.decode!(own.data)["reason"] == "no natural key among the cells"
    refute Map.has_key?(JSON.decode!(own.data), "reason_default")
  end

  test "a day before 1970 is written, cited and read back: an office opened in 1897", %{
    account: a
  } do
    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "old.example", name: "Old"}))
    {[place], []} = run(a.id, op(:put, :places, %{kind: :city, name: "Old Town"}))

    {[office], []} =
      run(
        a.id,
        op(:put, :offices, %{
          corporation_id: corp.id,
          place_id: place.id,
          kind: :hq,
          opened_on: ~D[1897-01-01],
          headcount: 12,
          as_of: ~D[1899-06-30],
          source: "https://old.example/history"
        })
      )

    row = Repo.get!(Office, office.id)
    assert row.opened_on == ~D[1897-01-01] and row.headcount_on == ~D[1899-06-30]
  end

  test "an exact restatement of a long deferred text writes nothing, and its ACK is ledgered", %{
    account: a
  } do
    listing = String.duplicate("Rust systems, kernels and GPU runtimes. ", 400)

    {[app], []} =
      run(a.id, op(:put, :applications, %{company: "L", role: "R", listing_raw: listing}))

    again = op(:put, :applications, %{listing_raw: listing}, target: app.id)
    {[same], []} = run(a.id, again)
    assert same.rev == app.rev and same.id == app.id

    # A resend of the same op is answered from the ledger with the same ACK.
    {[resent], []} = run(a.id, again)
    assert resent == same

    assert Repo.exists?(
             from(l in Hireme.Rows.OpLedger, where: l.op_id == ^again.op_id),
             skip_account: true
           )
  end

  test "a new application's stage_on is today, on the 0000-01-01 epoch end to end", %{account: a} do
    {[app], []} = run(a.id, op(:put, :applications, %{company: "Today", role: "R"}))
    assert Repo.get!(Hireme.Rows.Application, app.id).stage_on == Date.utc_today()
  end

  test "secrets never replicate: the account views carry none, reach no key, and follow the trail",
       %{account: a, session: s} do
    {:ok, %{key: key}} = Hireme.Keys.mint(s, "views", Hireme.Keys.preset(:read_write))

    boot = fn id, grants ->
      sub = %{id: id, label: "v", grants: grants, key_id: nil, session_id: nil}
      {:ok, %{frames: [f]}} = Sequencer.subscribe(a.id, sub, 0)
      {:ok, :BOOT, _, _, body} = Codec.decode(f)
      ingest(%{}, :BOOT, body)
    end

    secret =
      ~w(token_hash secret_hash totp_secret totp_last_step credential_id public_key sign_count aaguid subject)

    op = boot.(993, Grants.operator())

    refute Enum.any?(
             Map.keys(op),
             &(&1 in ~w(sessions api_keys factors recovery_codes audit op_ledger))
           )

    for {t, rows} <- op,
        {_, row} <- rows,
        {c, _} <- row,
        do: refute(Schema.column(t, c).name in secret, "#{t} carried a secret")

    name = Schema.column(:acct_keys, "name").id
    assert "views" in for({_, r} <- op["acct_keys"], do: r[name])

    {:ok, _} = Hireme.Keys.mint(s, "later", Hireme.Keys.preset(:read_only))
    assert_receive {:sequencer, :patch, _, body}, 2_000
    assert "later" in for({_, r} <- ingest(%{}, :PATCH, body)["acct_keys"], do: r[name])

    # Last: a pid holds one subscription, and this one becomes the key's.
    assert Enum.all?(boot.(992, Grants.key(key)), fn {t, rows} ->
             not String.starts_with?(t, "acct_") or rows == %{}
           end)
  end

  test "settings is one row: a put without a target finds it", %{account: a} do
    {[first], []} = run(a.id, op(:put, :settings, %{citizenships: "pt"}))
    {[second], []} = run(a.id, op(:put, :settings, %{citizenships: "de"}))
    assert second.id == first.id and second.rev == first.rev + 1
    assert [%{citizenships: "de"}] = Repo.all(Hireme.Rows.Setting)
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

  test "a keyed put names the key whose where its cells meet: a country's iso2 never finds a city",
       %{account: a} do
    {[city], []} =
      run(
        a.id,
        op(:put, :places, %{kind: :city, name: "Dresden", iso2: "DE", geonames_id: 2_935_022})
      )

    {[country], []} =
      run(a.id, op(:put, :places, %{kind: :country, name: "Germany", iso2: "DE"}, keyed: true))

    assert country.id != city.id

    {[again], []} =
      run(
        a.id,
        op(:put, :places, %{kind: :country, name: "Deutschland", iso2: "DE"}, keyed: true)
      )

    assert again.id == country.id
    assert Repo.get!(Place, city.id).name == "Dresden"
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

  test "a day past 9999-12-31 is refused type, so no row is stored that cannot be read back", %{
    account: a
  } do
    t = Schema.table(:gym_reps)
    col = &Enum.find(t.cols, fn c -> c.name == &1 end)

    cells = [
      {col.("platform").id, 1, 0},
      {col.("slug").id, 2, "far"},
      {col.("done_on").id, 1, Schema.day_max() + 1}
    ]

    {:ok, op, ""} = Codec.op(Codec.encode_op({1, :put, 0, t.id, 0, nil, cells}))
    assert {[], [%{refusal: :type}]} = run(a.id, op)
    assert Repo.aggregate(Hireme.Rows.GymRep, :count) == 0
  end

  test "a ref to another account's row is refused as if it did not exist", %{account: a} do
    other = sign_in()

    {[theirs], []} =
      Repo.with_account(other.account.id, fn ->
        run(other.account.id, op(:put, :corporations, %{domain: "theirs.example", name: "T"}))
      end)

    {[place], []} = run(a.id, op(:put, :places, %{kind: :country, name: "Mine", iso2: "MN"}))

    assert {[], [%{refusal: :not_found}]} =
             run(
               a.id,
               op(:put, :offices, %{corporation_id: theirs.id, place_id: place.id, kind: :hq})
             )

    assert {[], [%{refusal: :not_found}]} =
             run(
               a.id,
               op(:put, :offices, %{corporation_id: 9_999_999, place_id: place.id, kind: :hq})
             )
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
    word = string(:alphanumeric, min_length: 1, max_length: 6)

    # Writes to every resident table and to a world table with a resident
    # projection (places, seen as atlas), with drops that cascade.
    gen_action =
      one_of([
        tuple({constant(:rep), word}),
        tuple({constant(:app), word}),
        tuple({constant(:note), integer(0..20), string(:printable, max_length: 12)}),
        tuple({constant(:drop), integer(0..20)}),
        tuple({constant(:profile), word}),
        tuple({constant(:item), word}),
        tuple({constant(:batch), word}),
        tuple({constant(:net), word}),
        tuple({constant(:settings), member_of(["pt", "de", "pt\u001fde", ""])}),
        tuple({constant(:place), word}),
        tuple({constant(:event), integer(0..20), word}),
        tuple({constant(:overlay), integer(0..20), integer(0..20)}),
        tuple({constant(:stage), integer(0..20), member_of([:gated, :closed, :in_batch])}),
        tuple({constant(:drop_app), integer(0..20)})
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

          {:profile, s} ->
            op(:put, :profiles, %{slug: "p-#{s}", name: s})

          {:item, s} ->
            op(:put, :items, %{kind: :skill, key: "k-#{s}", title: s})

          {:batch, s} ->
            op(:put, :batches, %{code: "b-#{s}", ordinal: 1})

          {:net, s} ->
            op(:put, :net_entries, %{kind: :post, title: s})

          {:settings, c} ->
            op(:put, :settings, %{citizenships: c})

          {:place, s} ->
            op(:put, :places, %{kind: :city, name: s})

          {:event, i, s} ->
            app = Enum.at(ids.("applications"), i, 999_999)
            op(:put, :events, %{application_id: app, kind: s})

          {:overlay, i, j} ->
            app = Enum.at(ids.("applications"), i, 999_999)
            item = Enum.at(ids.("items"), j, 999_999)
            op(:put, :cv_overlays, %{application_id: app, item_id: item, mode: :add})

          {:stage, i, to} ->
            op(:command, :stage, %{stage: to}, target: Enum.at(ids.("applications"), i, 999_999))

          {:drop_app, i} ->
            op(:drop, :applications, %{}, target: Enum.at(ids.("applications"), i, 999_999))
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

  describe "from the write-path review" do
    test "a hostile op costs only itself, whatever it raises", %{account: a} do
      t = Schema.table(:corporations)
      domain = Enum.find(t.cols, &(&1.name == "domain"))
      {:ok, bad, ""} = Codec.op(Codec.encode_op({41, :put, 1, t.id, 0, nil, [{domain.id, 1, 7}]}))
      good = op(:put, :corporations, %{domain: "good.example", name: "G"})
      assert {[%{op_id: id}], [%{refusal: :type}]} = run(a.id, [bad, good])
      assert id == good.op_id
    end

    test "as_of is a real day, never in the future", %{account: a} do
      {[c], []} = run(a.id, op(:put, :corporations, %{domain: "asof.example", name: "A"}))
      t = Schema.table(:corporations)
      hc = Enum.find(t.cols, &(&1.name == "headcount"))

      huge =
        Codec.encode_op(
          {1, :put, 0, t.id, c.id, nil, [{hc.id, 1, 5}, {Codec.as_of_col(), 1, 4_000_000_000}]}
        )

      {:ok, huge, ""} = Codec.op(huge)
      assert {[], [%{refusal: :type}]} = run(a.id, huge)

      future =
        op(:put, :corporations, %{headcount: 5, as_of: Date.add(Date.utc_today(), 30)},
          target: c.id
        )

      assert {[], [%{refusal: :freshness}]} = run(a.id, future)
      assert Repo.get!(Corporation, c.id).headcount == nil
    end

    test "an insert naming an application another session holds is leased, but the operator's lands",
         %{account: a, session: s} do
      mint = fn name ->
        elem(Hireme.Keys.mint(s, name, Hireme.Keys.preset(:read_write)), 1).key
      end

      {[app], []} = run(a.id, op(:put, :applications, %{company: "Held", role: "R"}))
      {_, %{"ids" => [_]}} = key_session(a.id, mint.("holder"), 910, %{"ids" => [app.id]})
      {writer, _} = key_session(a.id, mint.("writer"), 911)

      assert {[], [%{refusal: :leased}]} =
               key_session_ops(writer, op(:put, :events, %{application_id: app.id, kind: "note"}))

      # docs/rebuild.md: "the operator's browser session is never refused leased"
      assert {[_], []} = run(a.id, op(:put, :events, %{application_id: app.id, kind: "note"}))
    end

    test "a delete may not reach rows outside the write mask", %{account: a} do
      {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "reach.example", name: "R"}))

      {[_], []} =
        run(a.id, op(:put, :applications, %{company: "R", role: "R", corporation_id: corp.id}))

      world_only = %{
        label: "w",
        grants: Grants.key(%{id: 1, read_mask: 1, write_mask: 1, may_delete: true}),
        key_id: nil
      }

      assert {[], [%{refusal: :scope}]} =
               run(a.id, op(:drop, :corporations, %{}, target: corp.id), world_only)

      assert Repo.get(Corporation, corp.id)
    end

    test "a place taken off the chart leaves the atlas", %{account: a} do
      {[p], []} =
        run(
          a.id,
          op(:put, :places, %{kind: :country, name: "Chartland", iso2: "CL", atlas_position: 3})
        )

      {:ok, %{frames: [boot]}} =
        Sequencer.subscribe(
          a.id,
          %{id: 920, label: "o", grants: Grants.operator(), key_id: nil, session_id: nil},
          0
        )

      {:ok, :BOOT, _, _, body} = Codec.decode(boot)
      model = ingest(%{}, :BOOT, body)
      assert Map.has_key?(model["atlas"], p.id)
      Sequencer.submit(a.id, [op(:put, :places, %{atlas_position: nil}, target: p.id)])
      model = drain(model)
      refute Map.has_key?(model["atlas"], p.id)
    end

    test "a refused op resent after the state changed is judged again; ACKs are a key's own", %{
      account: a,
      session: s
    } do
      {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))

      session = %{
        id: 930,
        label: "agent",
        grants: Grants.key(key),
        key_id: key.id,
        session_id: nil
      }

      {:ok, _} = Sequencer.subscribe(a.id, session, 0)
      put = op(:put, :corporations, %{domain: "resend.example", name: "R"}, op_id: 77)
      Sequencer.submit(a.id, [put])
      assert_receive {:sequencer, :verdicts, _, [], [%{op_id: 77}]}
      {:ok, _} = Hireme.Lease.claim(a.id, 930, %{})
      Sequencer.submit(a.id, [put])
      assert_receive {:sequencer, :verdicts, _, [%{op_id: 77, id: id}], []}
      # The operator reusing op_id 77 writes its own row.
      {[%{id: other}], []} =
        run(a.id, op(:put, :corporations, %{domain: "other.example", name: "O"}, op_id: 77))

      assert other != id
    end

    test "a key reconnecting at the current rev still gets a BOOT", %{account: a} do
      key = %{
        id: 940,
        label: "k",
        grants: Grants.key(%{id: 9, read_mask: 1, write_mask: 0, may_delete: false}),
        key_id: 9,
        session_id: nil
      }

      {:ok, %{rev: rev}} = Sequencer.subscribe(a.id, key, 0)
      {:ok, %{frames: [f]}} = Sequencer.subscribe(a.id, %{key | id: 941}, rev)
      {:ok, kind, _, _, body} = Codec.decode(f)
      assert kind == :BOOT
      assert {"applications", 0} in tables(body)
    end

    test "listings stored under another keywords version are re-extracted when the sequencer starts",
         %{account: a} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(Hireme.Rows.Application, [
        %{
          account_id: a.id,
          no: 1,
          stage: :discovered,
          status: :open,
          heat_override: false,
          rev: 1,
          listing_raw: "Senior Rust engineer, distributed systems, Elixir.",
          keywords_version: 0,
          inserted_at: now,
          updated_at: now
        }
      ])

      _ = Sequencer.rev(a.id)
      Process.sleep(300)
      [row] = Repo.all(Hireme.Rows.Application)
      assert row.keywords_version == Hireme.Kernel.keywords_version()
      assert row.keywords not in [nil, ""]
      # The kernel's realization stores the listing's hash too.
      assert row.listing_sha ==
               Base.encode16(:crypto.hash(:sha256, row.listing_raw), case: :lower)
    end

    test "a key's session opening and giving up the lease is audited", %{account: a, session: s} do
      {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))

      session = %{
        id: 950,
        label: "agent",
        grants: Grants.key(key),
        key_id: key.id,
        session_id: nil
      }

      {:ok, _} = Sequencer.subscribe(a.id, session, 0)
      {:ok, _} = Hireme.Lease.claim(a.id, 950, %{})
      {:ok, _} = Hireme.Lease.release(a.id, 950, nil)
      # Audits are written after the reply, as the sequencer's next message.
      _ = Sequencer.rev(a.id)

      kinds =
        Repo.all(
          from r in Hireme.Rows.Audit,
            where: r.kind in ["lease_opened", "lease_released"],
            order_by: r.id,
            select: r.kind
        )

      assert kinds == ["lease_opened", "lease_released"]
    end

    test "a command with no target ACKs the row it wrote on its table", %{account: a} do
      {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "lineage.example", name: "L"}))
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(Hireme.Rows.CvLineage, [
        %{
          account_id: a.id,
          corporation_id: corp.id,
          generation: 1,
          opened_on: ~D[2025-01-01],
          rewrites_allowed: false,
          rev: 1,
          inserted_at: now,
          updated_at: now
        }
      ])

      :ok = Sequencer.resync(a.id)
      {[ack], []} = run(a.id, op(:command, :open_generation, %{corporation_id: corp.id}))
      assert ack.id > 0 and ack.rev > 0
      assert Repo.get!(Hireme.Rows.CvLineage, ack.id).corporation_id == corp.id
    end

    test "an event's author is the server's, whatever the cells say", %{account: a} do
      {[app], []} = run(a.id, op(:put, :applications, %{company: "E", role: "R"}))

      assert {[], [%{refusal: :column}]} =
               run(
                 a.id,
                 op(:put, :events, %{application_id: app.id, kind: "note", actor: :operator})
               )
    end

    test "a command's required param, absent or empty, is refused column with the missing names",
         %{account: a} do
      {[app], []} = run(a.id, op(:put, :applications, %{company: "H", role: "R"}))

      for cells <- [%{}, %{reason: ""}] do
        {[], [nack]} = run(a.id, op(:command, :heat_override, cells, target: app.id))
        assert nack.refusal == :column
        assert JSON.decode!(nack.data)["missing"] == ["reason"]
      end
    end

    test "the backfill's ops never meet an earlier run's ledger entries", %{account: a} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # The operator's (writer 0) entries a previous boot left, low ids included.
      # Every id unique_integer can have reached in this VM, and more.
      top = System.unique_integer([:positive]) + 1_000

      for chunk <- Enum.chunk_every(1..top, 2_000) do
        Repo.insert_all(Hireme.Rows.OpLedger, ledger_rows(a.id, chunk, now))
      end

      Repo.insert_all(Hireme.Rows.Application, [
        %{
          account_id: a.id,
          no: 1,
          stage: :discovered,
          status: :open,
          heat_override: false,
          rev: 1,
          listing_raw: "Rust and Elixir engineer.",
          keywords_version: 0,
          inserted_at: now,
          updated_at: now
        }
      ])

      _ = Sequencer.rev(a.id)
      Process.sleep(300)

      assert Repo.one!(from r in Hireme.Rows.Application, select: r.keywords_version) ==
               Hireme.Kernel.keywords_version()
    end

    test "a keyed put that misses a key's condition is told the condition and what it lacks",
         %{account: a} do
      refused = fn cells ->
        {[], [nack]} = run(a.id, op(:put, :places, cells, keyed: true))
        assert nack.refusal == :natural_key
        JSON.decode!(nack.data)
      end

      country = %{"cols" => ["iso2"], "where" => "kind = 'country'", "reads" => ["kind"]}
      city = %{"cols" => ["geonames_id"], "where" => "kind = 'city'", "reads" => ["kind"]}

      data = refused.(%{iso2: "DE", name: "Germany"})
      assert data["keys"] == [country, city]
      assert data["unmet"] == [Map.put(country, "missing", ["kind"])]

      # The condition column given, with a value the condition refuses.
      data = refused.(%{iso2: "DE", kind: :city, name: "Germany"})
      assert data["unmet"] == [Map.put(country, "missing", [])]

      assert refused.(%{name: "Germany"})["unmet"] == []
    end

    test "a natural_key refusal does not name the row it found", %{account: a} do
      {[_], []} = run(a.id, op(:put, :corporations, %{domain: "nk.example", name: "N"}))

      {[], [nack]} =
        run(
          a.id,
          op(:put, :corporations, %{domain: "nk.example", name: "M"},
            keyed: true,
            create_only: true
          )
        )

      refute JSON.decode!(nack.data)["id"]
    end
  end

  describe "from the write-path review's second pass" do
    test "a BOOT for a key that reads only some domains loads into the real kernel", %{account: a} do
      {[_], []} =
        run(a.id, op(:put, :gym_reps, %{platform: :leetcode, slug: "s", done_on: ~D[2026-10-01]}))

      {[_], []} = run(a.id, op(:put, :applications, %{company: "K", role: "R"}))

      for {read, write} <- [{8, 0}, {1, 0}, {0, 31}] do
        g = Grants.key(%{id: 5, read_mask: read, write_mask: write, may_delete: false})

        {:ok, %{frames: [f]}} =
          Sequencer.subscribe(
            a.id,
            %{id: 960 + read, label: "k", grants: g, key_id: nil, session_id: nil},
            0
          )

        {:ok, :BOOT, _, _, body} = Codec.decode(f)
        k = Hireme.Kernel.new(body)
        # A key that does not read the desk sees no application, even in the kernel.
        assert Hireme.Kernel.board_ids(k, nil) == []
      end
    end

    test "moving a child row onto an application another session holds is leased", %{
      account: a,
      session: s
    } do
      mint = fn name ->
        elem(Hireme.Keys.mint(s, name, Hireme.Keys.preset(:read_write)), 1).key
      end

      {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "move.example", name: "M"}))

      {[app1], []} =
        run(a.id, op(:put, :applications, %{company: "One", role: "R", corporation_id: corp.id}))

      {[app2], []} =
        run(a.id, op(:put, :applications, %{company: "Two", role: "R", corporation_id: corp.id}))

      {[item], []} = run(a.id, op(:put, :items, %{kind: :skill, key: "rust", title: "Rust"}))

      {[ov], []} =
        run(
          a.id,
          op(:put, :cv_overlays, %{application_id: app1.id, item_id: item.id, mode: :tailor})
        )

      {_, %{"ids" => [_]}} = key_session(a.id, mint.("holder"), 970, %{"ids" => [app2.id]})
      {mover, _} = key_session(a.id, mint.("mover"), 971)

      assert {[], [%{refusal: :leased}]} =
               key_session_ops(
                 mover,
                 op(:put, :cv_overlays, %{application_id: app2.id}, target: ov.id)
               )
    end

    test "a key's submission past its budget is refused rate whole, before anything is judged", %{
      account: a,
      session: s
    } do
      {:ok, %{key: key}} = Hireme.Keys.mint(s, "agent", Hireme.Keys.preset(:read_write))

      {:ok, _} =
        Sequencer.subscribe(
          a.id,
          %{id: 980, label: "flood", grants: Grants.key(key), key_id: key.id, session_id: nil},
          0
        )

      ops =
        for i <- 1..601,
            do: op(:put, :gym_reps, %{platform: :other, slug: "f#{i}", done_on: ~D[2026-10-01]})

      Sequencer.submit(a.id, ops)
      assert_receive {:sequencer, :verdicts, _, [], nacks}
      assert length(nacks) == 601 and Enum.all?(nacks, &(Schema.refusal_name(&1.code) == :rate))
      assert Repo.aggregate(Hireme.Rows.GymRep, :count) == 0
    end

    test "an op over 1 MiB of text is too_large", %{account: a} do
      big = String.duplicate("x", 1_048_577)

      assert {[], [%{refusal: :too_large}]} =
               run(a.id, op(:put, :applications, %{company: "Big", listing_raw: big}))
    end

    test "a ledger entry older than a day no longer answers a resend", %{account: a} do
      put =
        op(:put, :gym_reps, %{platform: :other, slug: "old", done_on: ~D[2026-10-01]},
          op_id: 4242
        )

      {[first], []} = run(a.id, put)
      old = DateTime.add(DateTime.utc_now(), -25 * 3600) |> DateTime.truncate(:second)

      from(l in Hireme.Rows.OpLedger, where: l.op_id == 4242)
      |> Repo.update_all(set: [inserted_at: old])

      {[again], []} = run(a.id, put)
      assert again.id != first.id
    end

    test "two writers picking the same op_id each keep their own verdict and resend", %{
      account: a,
      session: s
    } do
      me = self()

      # Each key's session is its own process, holding its own lease.
      writer = fn name, sid ->
        {:ok, %{key: key}} = Hireme.Keys.mint(s, name, Hireme.Keys.preset(:read_write))

        spawn_link(fn ->
          {:ok, _} =
            Sequencer.subscribe(
              a.id,
              %{id: sid, label: name, grants: Grants.key(key), key_id: key.id, session_id: nil},
              0
            )

          {:ok, _} = Hireme.Lease.claim(a.id, sid, %{})

          put =
            op(:put, :gym_reps, %{platform: :other, slug: name, done_on: ~D[2026-10-01]},
              op_id: 7
            )

          for _ <- 1..2 do
            Sequencer.submit(a.id, [put])
            receive do: ({:sequencer, :verdicts, _, acks, []} -> send(me, {name, acks}))
          end
        end)
      end

      writer.("a", 990)
      assert_receive {"a", [first_a]}
      assert_receive {"a", [^first_a]}
      writer.("b", 991)
      assert_receive {"b", [first_b]}
      assert_receive {"b", [^first_b]}
      assert first_a.id != first_b.id
      assert Repo.aggregate(Hireme.Rows.GymRep, :count) == 2
    end

    test "texts travel whole in the BOOT, world and mail rows replicate, and a text keeps its hash twin",
         %{account: a} do
      text = "Staff engineer, Rust. " |> String.duplicate(20)

      {[app], []} =
        run(a.id, op(:put, :applications, %{company: "S", role: "R", listing_raw: text}))

      {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "w.example", name: "W"}))
      {[contact], []} = run(a.id, op(:put, :contacts, %{name: "C", corporation_id: corp.id}))

      assert Repo.get!(Hireme.Rows.Application, app.id).listing_sha ==
               Base.encode16(:crypto.hash(:sha256, text), case: :lower)

      {:ok, %{frames: [boot]}} =
        Sequencer.subscribe(
          a.id,
          %{id: 995, label: "o", grants: Grants.operator(), key_id: nil, session_id: nil},
          0
        )

      {:ok, :BOOT, _, _, body} = Codec.decode(boot)
      model = ingest(%{}, :BOOT, body)
      listing = Schema.column(:applications, "listing_raw").id
      assert get_in(model, ["applications", app.id, listing]) == text

      assert get_in(model, ["corporations", corp.id, Schema.column(:corporations, "domain").id]) ==
               "w.example"

      assert get_in(model, ["contacts", contact.id, Schema.column(:contacts, "name").id]) == "C"
    end

    test "a capped table refuses the row past its cap, and a delete frees a slot", %{account: a} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      cap = Schema.table(:corporations).cap

      for chunk <- Enum.chunk_every(1..(cap - 1), 2_000) do
        Repo.insert_all(
          Hireme.Rows.Corporation,
          for(
            i <- chunk,
            do: %{
              account_id: a.id,
              domain: "c#{i}.example",
              name: "C",
              rev: 1,
              inserted_at: now,
              updated_at: now
            }
          )
        )
      end

      {[last], []} = run(a.id, op(:put, :corporations, %{domain: "last.example", name: "L"}))

      assert {[], [%{refusal: :cap}]} =
               run(a.id, op(:put, :corporations, %{domain: "over.example", name: "O"}))

      {[_], []} = run(a.id, op(:drop, :corporations, %{}, target: last.id))
      assert {[_], []} = run(a.id, op(:put, :corporations, %{domain: "again.example", name: "A"}))
    end

    test "two sessions' lease audits are each their own, however they interleave", %{
      account: a,
      session: s
    } do
      sessions =
        for {name, sid} <- [{"x", 997}, {"y", 998}] do
          {:ok, %{key: key}} = Hireme.Keys.mint(s, name, Hireme.Keys.preset(:read_write))

          me = self()
          info = %{id: sid, label: name, grants: Grants.key(key), key_id: key.id, session_id: nil}

          # Each session its own process, as on the wire.
          spawn_link(fn ->
            {:ok, _} = Sequencer.subscribe(a.id, info, 0)
            send(me, {:joined, sid})
            Process.sleep(:infinity)
          end)

          # A subscribe under a loaded suite can take longer than the default 100 ms.
          assert_receive {:joined, ^sid}, 5_000
          sid
        end

      for _ <- 1..5, sid <- sessions do
        {:ok, _} = Hireme.Lease.claim(a.id, sid, %{})
        {:ok, _} = Hireme.Lease.release(a.id, sid, nil)
      end

      _ = Sequencer.rev(a.id)

      kinds =
        Repo.all(
          from r in Hireme.Rows.Audit,
            where: r.kind in ["lease_opened", "lease_released"],
            select: r.kind
        )

      assert Enum.frequencies(kinds) == %{"lease_opened" => 10, "lease_released" => 10}
    end

    test "an op that writes nothing moves no rev", %{account: a} do
      {[app], []} = run(a.id, op(:put, :applications, %{company: "Still", role: "R"}))
      rev = Sequencer.rev(a.id)
      assert {[_], []} = run(a.id, op(:command, :stage, %{stage: :discovered}, target: app.id))
      assert Sequencer.rev(a.id) == rev
    end

    test "expect_rev guards a drop and a command too", %{account: a} do
      {[app], []} = run(a.id, op(:put, :applications, %{company: "Rev", role: "R"}))

      assert {[], [%{refusal: :rev}]} =
               run(a.id, op(:drop, :applications, %{}, target: app.id, expect_rev: 99))

      assert {[], [%{refusal: :rev}]} =
               run(
                 a.id,
                 op(:command, :note, %{stage: :discovered, body: "n"},
                   target: app.id,
                   expect_rev: 99
                 )
               )

      assert {[_], []} =
               run(a.id, op(:drop, :applications, %{}, target: app.id, expect_rev: app.rev))
    end
  end

  defp ledger_rows(account_id, ids, now) do
    for i <- ids do
      %{
        account_id: account_id,
        op_id: i,
        writer: 0,
        verb: :put,
        subject: 1,
        row_id: 1,
        ack_rev: 1,
        rev: 1,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  describe "account size" do
    # Every byte of text the account's own tables hold, counted from scratch.
    defp recount(account_id) do
      for t <- Schema.tables(),
          t.residency in [:resident, :server],
          t.domain != "system" or t.name == "citations",
          reduce: 0 do
        acc ->
          case for(
                 c <- t.cols,
                 c.type in [:str, :text, :json],
                 do: ~s{coalesce(length(CAST("#{c.name}" AS BLOB)),0)}
               ) do
            [] ->
              acc

            parts ->
              %{rows: [[n]]} =
                Repo.query!(
                  ~s{SELECT coalesce(sum(#{Enum.join(parts, "+")}),0) FROM "#{t.name}" WHERE account_id = ?},
                  [account_id],
                  skip_account: true
                )

              acc + n
          end
      end
    end

    defp counter(account_id),
      do:
        Repo.one!(
          from(a in Hireme.Rows.Account, where: a.id == ^account_id, select: a.text_bytes),
          skip_account: true
        )

    test "the text counter stays exact through inserts, replaces, cascading drops and citations",
         %{account: a} do
      {[corp], []} =
        run(
          a.id,
          op(
            :put,
            :corporations,
            %{
              domain: "bytes.example",
              name: "Bytes",
              about: String.duplicate("long about ", 50),
              source: "https://bytes.example/a",
              headcount: 9,
              as_of: ~D[2026-10-01]
            },
            expect_rev: 0
          )
        )

      {[app], []} =
        run(
          a.id,
          op(:put, :applications, %{
            company: "Bytes",
            role: "R",
            corporation_id: corp.id,
            notes: String.duplicate("n", 1_000),
            listing_raw: String.duplicate("listing ", 100)
          })
        )

      assert counter(a.id) == recount(a.id)

      {[_], []} = run(a.id, op(:put, :applications, %{notes: "short"}, target: app.id))
      assert counter(a.id) == recount(a.id)

      {[_], []} =
        run(
          a.id,
          op(:put, :events, %{
            application_id: app.id,
            kind: "note",
            body: String.duplicate("e", 300)
          })
        )

      {[_], []} = run(a.id, op(:drop, :corporations, %{}, target: corp.id))
      assert counter(a.id) == recount(a.id)

      {[_], []} = run(a.id, op(:drop, :applications, %{}, target: app.id))
      assert counter(a.id) == recount(a.id)
    end

    test "past the account's text budget a write is refused cap", %{account: a} do
      budget = Hireme.Security.account_text_bytes()

      from(x in Hireme.Rows.Account, where: x.id == ^a.id)
      |> Repo.update_all([set: [text_bytes: budget - 10]], skip_account: true)

      assert {[], [%{refusal: :cap}]} =
               run(
                 a.id,
                 op(:put, :applications, %{
                   company: "Too much",
                   role: "R",
                   notes: String.duplicate("x", 100)
                 })
               )

      assert {[_], []} =
               run(
                 a.id,
                 op(:put, :gym_reps, %{platform: :other, slug: "s", done_on: ~D[2026-10-01]})
               )
    end

    test "an operator's lease revoke pauses the key across a sequencer restart, until resumed", %{
      account: a,
      session: s
    } do
      {:ok, %{key: key}} = Hireme.Keys.mint(s, "paused", Hireme.Keys.preset(:read_write))
      {_agent, _} = key_session(a.id, key, 996)
      :ok = Hireme.Lease.revoke(a.id, 996, %{ip: "203.0.113.9"})
      # The pause is recorded once, when it begins, with who and from where.
      :ok = Hireme.Lease.revoke(a.id, 996, %{})

      assert [%{ip: "203.0.113.9"}] =
               Repo.all(from(e in Hireme.Rows.Audit, where: e.kind == "key_paused"),
                 skip_account: true
               )

      [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)
      DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)

      info = %{
        id: 995,
        label: "again",
        grants: Hireme.Grants.key(key),
        key_id: key.id,
        session_id: nil
      }

      {:ok, _} = Hireme.Sequencer.subscribe(a.id, info, 0)

      assert {:refused, :lease_missing, %{paused: true, reason: "paused by the operator"}} =
               Hireme.Lease.claim(a.id, 995, %{})

      {:ok, _} = Hireme.Keys.resume(Repo.get!(Hireme.Rows.ApiKey, key.id, skip_account: true))
      assert {:ok, _} = Hireme.Lease.claim(a.id, 995, %{})
    end

    test "at its cap the ledger makes room from its oldest entries and refuses nobody", %{
      account: a
    } do
      {[_], []} =
        run(a.id, op(:put, :gym_reps, %{platform: :other, slug: "a", done_on: ~D[2026-10-01]}))

      ledger = fn -> Repo.aggregate(Hireme.Rows.OpLedger, :count, skip_account: true) end
      assert ledger.() == 1

      # The cached count says the ledger is full.
      [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)
      cap = Hireme.Schema.table("op_ledger").cap
      id = Hireme.Schema.table("op_ledger").id
      :sys.replace_state(pid, &put_in(&1.counts[id], cap))

      assert {[_], []} =
               run(
                 a.id,
                 op(:put, :gym_reps, %{platform: :other, slug: "b", done_on: ~D[2026-10-01]})
               )

      assert ledger.() == 1
    end

    test "at its cap an account's ledger makes room from its own oldest entries, never another's",
         %{account: a} do
      %{account: other} = sign_in()

      gym = fn account_id, slug ->
        run(
          account_id,
          op(:put, :gym_reps, %{platform: :other, slug: slug, done_on: ~D[2026-10-01]})
        )
      end

      # The other account's entries are the node's oldest.
      for i <- 1..3, do: {[_], []} = gym.(other.id, "o#{i}")
      {[_], []} = gym.(a.id, "a1")

      count = fn account_id ->
        Repo.aggregate(
          from(l in Hireme.Rows.OpLedger, where: l.account_id == ^account_id),
          :count,
          skip_account: true
        )
      end

      [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)
      t = Hireme.Schema.table("op_ledger")
      :sys.replace_state(pid, &put_in(&1.counts[t.id], t.cap))

      {[_], []} = gym.(a.id, "a2")
      assert {count.(a.id), count.(other.id)} == {1, 3}
    end

    test "an insert refused at the text budget leaves no claim behind", %{
      account: a,
      session: s
    } do
      {:ok, %{key: key}} = Hireme.Keys.mint(s, "near", Hireme.Keys.preset(:read_write))
      budget = Hireme.Security.account_text_bytes()

      from(x in Hireme.Rows.Account, where: x.id == ^a.id)
      |> Repo.update_all([set: [text_bytes: budget - 10]], skip_account: true)

      for {pid, _} <- Registry.lookup(Hireme.Sequencer.Registry, a.id),
          do: DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)

      {agent, _} = key_session(a.id, key, 998)

      assert {[], [%{refusal: :cap}]} =
               key_session_ops(
                 agent,
                 op(:put, :applications, %{
                   company: "C",
                   role: "R",
                   notes: String.duplicate("x", 100)
                 })
               )

      assert [%{ids: []}] = Hireme.Lease.leases(a.id)
    end

    test "at its budget an account can still rewrite text shorter, never longer", %{account: a} do
      {[app], []} =
        run(
          a.id,
          op(:put, :applications, %{
            company: "Full",
            role: "R",
            notes: String.duplicate("x", 5_000)
          })
        )

      budget = Hireme.Security.account_text_bytes()

      from(x in Hireme.Rows.Account, where: x.id == ^a.id)
      |> Repo.update_all([set: [text_bytes: budget - 10]], skip_account: true)

      # The sequencer reads the counter when it starts; a fresh one sees the full account.
      [{pid, _}] = Registry.lookup(Hireme.Sequencer.Registry, a.id)
      DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)

      assert {[_], []} =
               run(
                 a.id,
                 op(:put, :applications, %{notes: String.duplicate("y", 100)}, target: app.id)
               )

      assert {[], [%{refusal: :cap}]} =
               run(
                 a.id,
                 op(:put, :applications, %{notes: String.duplicate("z", 6_000)}, target: app.id)
               )
    end

    test "a key's text per minute is bounded beside its op count", %{account: a, session: s} do
      {:ok, %{key: key}} = Hireme.Keys.mint(s, "bulk", Hireme.Keys.preset(:read_write))
      {agent, _} = key_session(a.id, key, 999)
      {_, budget} = Hireme.Security.limits()[:agent_write_bytes]
      mib = String.duplicate("x", 1_048_000)

      ops =
        for i <- 1..(div(budget, 1_048_000) + 1),
            do: op(:put, :net_entries, %{kind: :draft, body: mib, title: "#{i}"})

      {[], nacks} = key_session_ops(agent, ops)
      assert Enum.all?(nacks, &(&1.refusal == :rate))
    end

    test "a source a citation creates counts against the sources cap, warm or cold, and a tombstone frees its place",
         %{account: a} do
      cap = Schema.table(:sources).cap
      now = Hireme.Store.now()

      for chunk <- Enum.chunk_every(1..(cap - 2), 4_000) do
        rows =
          for i <- chunk,
              do: %{
                account_id: a.id,
                url: "https://fill.example/#{i}",
                host: "fill.example",
                mutable: true,
                rev: 1,
                inserted_at: now,
                updated_at: now
              }

        Repo.insert_all(Hireme.Rows.Source, rows, skip_account: true)
      end

      {[%{id: corp}], []} =
        run(a.id, op(:put, :corporations, %{domain: "cap.example", name: "C"}))

      cite = fn n, url ->
        run(
          a.id,
          op(
            :put,
            :corporations,
            %{headcount: n, as_of: Date.add(~D[2026-01-01], n), source: url},
            target: corp
          )
        )
      end

      # The first count is read cold, with the cited source already stored.
      assert {[_], []} = cite.(1, "https://new.example/1")
      assert {[_], []} = cite.(2, "https://new.example/2")
      assert {[], [%{refusal: :cap, data: data}]} = cite.(3, "https://new.example/3")
      assert data =~ ~s("table":"sources")

      assert {[], [%{refusal: :cap}]} =
               run(a.id, op(:put, :sources, %{url: "https://direct.example/1"}))

      # The operator's drop of a cited source tombstones it, and the place
      # it held is free whether the count is cached or read afresh.
      [sid] =
        Repo.all(
          from(x in Hireme.Rows.Source, where: x.url == "https://new.example/2", select: x.id),
          skip_account: true
        )

      assert {[_], []} = run(a.id, op(:drop, :sources, %{}, target: sid))

      for {pid, _} <- Registry.lookup(Hireme.Sequencer.Registry, a.id),
          do: DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, pid)

      assert {[_], []} = run(a.id, op(:put, :sources, %{url: "https://direct.example/2"}))

      assert {[], [%{refusal: :cap}]} =
               run(a.id, op(:put, :sources, %{url: "https://direct.example/3"}))
    end
  end
end
