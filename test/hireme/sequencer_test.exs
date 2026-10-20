defmodule Hireme.SequencerTest do
  use Hireme.WireCase, async: false
  use ExUnitProperties

  import Ecto.Query
  alias Hireme.Rows.{Application, Corporation, GymRep, Office, OpLedger, Place}

  defp sub(id, grants \\ Grants.operator(), key_id \\ nil),
    do: %{id: id, label: "s#{id}", grants: grants, key_id: key_id, session_id: nil}

  defp mint(s, name), do: elem(Hireme.Keys.mint(s, name, Hireme.Keys.preset(:read_write)), 1).key

  # This pid's subscription and its BOOT as a model: `{rev, model}`.
  defp boot(account_id, id, grants \\ Grants.operator()) do
    {:ok, %{frames: [f], rev: rev}} = Sequencer.subscribe(account_id, sub(id, grants), 0)
    {:ok, :BOOT, _, _, body} = Codec.decode(f)
    {rev, ingest(%{}, :BOOT, body)}
  end

  # A fresh BOOT from another pid, so this pid keeps its live subscription.
  defp fresh(account_id, id), do: Task.async(fn -> boot(account_id, id) end) |> Task.await()

  defp gym(slug),
    do: op(:put, :gym_reps, %{platform: :other, slug: slug, done_on: ~D[2026-10-01]})

  defp count(queryable), do: Repo.aggregate(queryable, :count)

  test "ACKs: an insert is rev 1, an update rev 2, the account rev counts both; a singleton (me) is one row; a restatement or a no-op command moves no rev; a resend is answered from the ledger",
       %{account: a} do
    {[ack], []} = run(a.id, op(:put, :corporations, %{domain: "example.com", name: "Example"}))
    assert ack.rev == 1 and ack.id > 0
    {[ack2], []} = run(a.id, op(:put, :corporations, %{name: "Example Inc"}, target: ack.id))
    assert {ack2.id, ack2.rev} == {ack.id, 2}
    assert Repo.get!(Corporation, ack.id).name == "Example Inc"
    assert rev(a.id) == a.desk_rev + 2

    {[s1], []} = run(a.id, op(:put, :me, %{citizenships: "pt"}))
    {[s2], []} = run(a.id, op(:put, :me, %{citizenships: "de"}))
    assert s2.id == s1.id and s2.rev == s1.rev + 1
    assert [%{citizenships: "de"}] = Repo.all(Hireme.Rows.Me)

    listing = String.duplicate("Rust systems, kernels and GPU runtimes. ", 400)

    {[app], []} =
      run(a.id, op(:put, :applications, %{company: "L", role: "R", listing_raw: listing}))

    # The kernel derives stage_on: today, on the 0000-01-01 epoch, end to end.
    assert Repo.get!(Application, app.id).stage_on == Date.utc_today()
    rev = rev(a.id)
    again = op(:put, :applications, %{listing_raw: listing}, target: app.id)
    {[same], []} = run(a.id, again)
    assert {[^same], []} = run(a.id, again)
    {[still], []} = run(a.id, op(:command, :stage, %{stage: :discovered}, target: app.id))
    assert {same.id, same.rev, still.rev, rev(a.id)} == {app.id, app.rev, app.rev, rev}
    assert Repo.exists?(from(l in OpLedger, where: l.op_id == ^again.op_id), skip_account: true)
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

  test "every refusal is its op's own fault, named by code and reason (a default one marked); a hostile op costs only itself",
       %{account: a, session: s} do
    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "r.example", name: "R"}))
    {[app], []} = run(a.id, op(:put, :applications, %{company: "R", role: "R"}))
    t = Schema.table(:corporations)
    domain = Enum.find(t.cols, &(&1.name == "domain"))
    # A keyed put whose domain cell is an integer: whatever it raises inside.
    {:ok, hostile, ""} =
      Codec.op(Codec.encode_op({41, :put, 1, t.id, 0, nil, [{domain.id, 1, 7}]}))

    cases = [
      {op(:put, :corporations, %{domain: "r2.example"}), :column},
      {op(:put, :corporations, %{name: "X"}, target: 999_999_999), :not_found},
      {op(:put, :corporations, %{domain: "r.example", name: "R"}, keyed: true, create_only: true),
       :natural_key},
      {op(:put, :corporations, %{name: "Y"}, target: corp.id, expect_rev: 7), :rev},
      {op(:drop, :applications, %{}, target: app.id, expect_rev: 99), :rev},
      {op(:command, :note, %{stage: :discovered, body: "n"}, target: app.id, expect_rev: 99),
       :rev},
      {op(:put, :corporations, %{headcount: 5}, target: corp.id), :freshness},
      {op(:put, :corporations, %{about: "x"}, target: corp.id, expect_rev: 1), :source_missing},
      {op(:command, :stage, %{stage: :reply}, target: app.id), :stage},
      {op(:put, :applications, %{notes: String.duplicate("x", 1_048_577)}, target: app.id),
       :too_large},
      # An event's author is the server's, whatever the cells say; a command's
      # required param, absent or empty, is missing.
      {op(:put, :events, %{application_id: app.id, kind: "note", actor: :operator}), :column},
      {op(:command, :heat_override, %{}, target: app.id), :column},
      {op(:command, :heat_override, %{reason: ""}, target: app.id), :column},
      {hostile, :type}
    ]

    good = op(:put, :corporations, %{domain: "good.example", name: "G"})
    {[%{op_id: landed}], nacks} = run(a.id, Enum.map(cases, &elem(&1, 0)) ++ [good])
    assert landed == good.op_id
    assert Enum.map(nacks, & &1.refusal) == Enum.map(cases, &elem(&1, 1))
    data = Enum.map(nacks, &JSON.decode!(&1.data))
    assert for(d <- data, d["missing"], do: d["missing"]) == [["name"], ["reason"], ["reason"]]

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
    assert hd(data)["reason_default"] == true
    {[], [own]} = run(a.id, op(:put, :corporations, %{name: "No key"}, keyed: true))
    assert JSON.decode!(own.data)["reason"] == "no natural key among the cells"
    refute Map.has_key?(JSON.decode!(own.data), "reason_default")
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
      before = count(Corporation)
      again = for i <- resend, i < length(ops), do: Enum.at(ops, i)
      {acks, []} = run(a.id, again)
      assert count(Corporation) == before
      assert Enum.all?(acks, &(&1 in first))
    end
  end

  test "a keyed put finds its row by the key whose condition its cells meet; create_only refuses an existing row without naming it; a missed condition is explained",
       %{account: a} do
    keyed = fn cells, opts -> op(:put, :corporations, cells, [keyed: true] ++ opts) end
    {[first], []} = run(a.id, keyed.(%{domain: "keyed.example", name: "One"}, []))
    {[second], []} = run(a.id, keyed.(%{domain: "keyed.example", name: "Two"}, []))
    assert second.id == first.id and second.rev == 2
    {[], [nack]} = run(a.id, keyed.(%{domain: "keyed.example", name: "Three"}, create_only: true))
    assert nack.refusal == :natural_key
    refute JSON.decode!(nack.data)["id"]

    # A country's iso2 never finds a city.
    {[city], []} =
      run(
        a.id,
        op(:put, :places, %{kind: :city, name: "Dresden", iso2: "DE", geonames_id: 2_935_022})
      )

    de = %{kind: :country, name: "Germany", iso2: "DE"}
    {[country], []} = run(a.id, op(:put, :places, de, keyed: true))
    {[again], []} = run(a.id, op(:put, :places, %{de | name: "Deutschland"}, keyed: true))
    assert country.id != city.id and again.id == country.id
    assert Repo.get!(Place, city.id).name == "Dresden"

    refused = fn cells ->
      {[], [nack]} = run(a.id, op(:put, :places, cells, keyed: true))
      assert nack.refusal == :natural_key
      JSON.decode!(nack.data)
    end

    country = %{"cols" => ["iso2"], "where" => "kind = 'country'", "reads" => ["kind"]}
    by_geonames = &%{"cols" => ["geonames_id"], "where" => "kind = '#{&1}'", "reads" => ["kind"]}
    data = refused.(%{iso2: "DE", name: "Germany"})
    assert data["keys"] == [country | Enum.map(~w(city state province), by_geonames)]
    assert data["unmet"] == [Map.put(country, "missing", ["kind"])]
    # The condition column given, with a value the condition refuses.
    assert refused.(%{iso2: "DE", kind: :city, name: "Germany"})["unmet"] ==
             [Map.put(country, "missing", [])]

    assert refused.(%{name: "Germany"})["unmet"] == []
  end

  test "a ref resolves in the account alone; a drop takes the rows whose required ref names it, within the writer's write mask; a dropped application is no longer claimable",
       %{account: a} do
    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "drop.example", name: "D"}))
    {[place], []} = run(a.id, op(:put, :places, %{kind: :country, name: "Nowhere", iso2: "NW"}))

    office = fn c -> op(:put, :offices, %{corporation_id: c, place_id: place.id, kind: :hq}) end
    {[_], []} = run(a.id, office.(corp.id))

    # A ref to another account's row is refused as if it did not exist
    # (a sign-in scopes the process to its account; with_account restores ours).
    {[theirs], []} =
      Repo.with_account(a.id, fn ->
        other = sign_in().account.id
        run(other, op(:put, :corporations, %{domain: "theirs.example", name: "T"}))
      end)

    assert {[], [%{refusal: :not_found}]} = run(a.id, office.(theirs.id))
    assert {[], [%{refusal: :not_found}]} = run(a.id, office.(9_999_999))

    {[keep], []} = run(a.id, op(:put, :applications, %{company: "Keep", role: "R"}))
    {[gone], []} = run(a.id, op(:put, :applications, %{company: "Gone", role: "R"}))

    {[_], []} =
      run(a.id, op(:put, :applications, %{company: "R", role: "R", corporation_id: corp.id}))

    # The delete reaches the application: a world-only key may not take it.
    world_only = %{
      label: "w",
      grants: Grants.key(%{id: 1, read_mask: 1, write_mask: 1, may_delete: true}),
      key_id: nil
    }

    assert {[], [%{refusal: :scope}]} =
             run(a.id, op(:drop, :corporations, %{}, target: corp.id), world_only)

    assert Repo.get(Corporation, corp.id)

    {[_], []} = run(a.id, op(:drop, :applications, %{}, target: gone.id))
    {:ok, _} = Sequencer.subscribe(a.id, sub(903), 0)

    assert {:ok, %{"ids" => ids, "truncated" => true}} =
             Hireme.Lease.claim(a.id, 903, %{"count" => 5})

    assert keep.id in ids and gone.id not in ids

    {[_], []} = run(a.id, op(:drop, :corporations, %{}, target: corp.id))
    assert count(Office) == 0 and Repo.get(Place, place.id)
  end

  test "a key writes only with the lease; a refused op resent after the state changed is judged again; the ledger is per writer, so one op_id is each writer's own",
       %{account: a, session: s} do
    key = mint(s, "agent")
    {:ok, %{lease: false}} = Sequencer.subscribe(a.id, sub(930, Grants.key(key), key.id), 0)
    put = op(:put, :corporations, %{domain: "resend.example", name: "R"}, op_id: 77)
    Sequencer.submit(a.id, [put])
    assert_receive {:sequencer, :verdicts, _, [], [%{op_id: 77, code: code}]}
    assert Schema.refusal_name(code) == :lease_missing
    {:ok, %{"ids" => []}} = Hireme.Lease.claim(a.id, 930, %{})
    Sequencer.submit(a.id, [put])
    assert_receive {:sequencer, :verdicts, _, [%{op_id: 77, id: id}], []}

    # Another key and the operator reuse op_id 77: each writes and resends its own.
    {other, _} = key_session(a.id, mint(s, "other"), 931)
    theirs = op(:put, :corporations, %{domain: "other.example", name: "O"}, op_id: 77)
    assert {[%{id: other_id} = first], []} = key_session_ops(other, theirs)
    assert {[^first], []} = key_session_ops(other, theirs)

    {[%{id: mine}], []} =
      run(a.id, op(:put, :corporations, %{domain: "mine.example", name: "M"}, op_id: 77))

    assert length(Enum.uniq([id, other_id, mine])) == 3
  end

  test "a child row inserted or moved onto an application another session holds is leased; the operator's lands",
       %{account: a, session: s} do
    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "move.example", name: "M"}))
    app = fn n -> op(:put, :applications, %{company: n, role: "R", corporation_id: corp.id}) end
    {[app1], []} = run(a.id, app.("One"))
    {[app2], []} = run(a.id, app.("Two"))
    {[item], []} = run(a.id, op(:put, :items, %{kind: :skill, key: "rust", title: "Rust"}))

    {[ov], []} =
      run(
        a.id,
        op(:put, :cv_overlays, %{application_id: app1.id, item_id: item.id, mode: :tailor})
      )

    {_, %{"ids" => [_]}} = key_session(a.id, mint(s, "holder"), 910, %{"ids" => [app2.id]})
    {writer, _} = key_session(a.id, mint(s, "writer"), 911)
    event = fn -> op(:put, :events, %{application_id: app2.id, kind: "note"}) end
    assert {[], [%{refusal: :leased}]} = key_session_ops(writer, event.())

    assert {[], [%{refusal: :leased}]} =
             key_session_ops(
               writer,
               op(:put, :cv_overlays, %{application_id: app2.id}, target: ov.id)
             )

    # docs/rebuild.md: "the operator's browser session is never refused leased"
    assert {[_], []} = run(a.id, event.())
  end

  test "a BOOT for a key that reads only some domains loads into the real kernel, and a key reconnecting at the current rev still gets a BOOT",
       %{account: a} do
    {[_], []} = run(a.id, gym("s"))
    {[_], []} = run(a.id, op(:put, :applications, %{company: "K", role: "R"}))

    for {read, write} <- [{8, 0}, {1, 0}, {0, 31}] do
      g = Grants.key(%{id: 5, read_mask: read, write_mask: write, may_delete: false})
      {:ok, %{frames: [f], rev: rev}} = Sequencer.subscribe(a.id, sub(960 + read, g, 5), 0)
      {:ok, :BOOT, _, _, body} = Codec.decode(f)
      # A key that does not read the desk sees no application, even in the kernel.
      assert Hireme.Kernel.board_ids(Hireme.Kernel.new(body), nil) == []
      {:ok, %{frames: [f]}} = Sequencer.subscribe(a.id, sub(970 + read, g, 5), rev)
      assert {:ok, :BOOT, _, _, _} = Codec.decode(f)
    end
  end

  test "the account views: no secret replicates, no key reads them, they follow the trail (security events outlive an activity burst) and come fresh to a resumed session; texts, world and mail rows travel whole",
       %{account: a, session: s} do
    text = String.duplicate("Staff engineer, Rust. ", 20)

    {[app], []} =
      run(a.id, op(:put, :applications, %{company: "S", role: "R", listing_raw: text}))

    {[corp], []} = run(a.id, op(:put, :corporations, %{domain: "w.example", name: "W"}))
    {[contact], []} = run(a.id, op(:put, :contacts, %{name: "C", corporation_id: corp.id}))
    {:ok, %{key: key}} = Hireme.Keys.mint(s, "views", Hireme.Keys.preset(:read_write))
    {rev, model} = boot(a.id, 993)

    cell = fn t, id, c -> get_in(model, [to_string(t), id, Schema.column(t, c).id]) end
    assert cell.(:applications, app.id, "listing_raw") == text
    assert cell.(:corporations, corp.id, "domain") == "w.example"
    assert cell.(:contacts, contact.id, "name") == "C"

    secret =
      ~w(token_hash secret_hash totp_secret totp_last_step credential_id public_key sign_count aaguid subject)

    refute Enum.any?(
             Map.keys(model),
             &(&1 in ~w(sessions api_keys factors recovery_codes audit op_ledger))
           )

    for {t, rows} <- model,
        {_, row} <- rows,
        {c, _} <- row,
        do: refute(Schema.column(t, c).name in secret, "#{t} carried a secret")

    name = Schema.column(:acct_keys, "name").id
    names = fn m -> for {_, r} <- m["acct_keys"] || %{}, do: r[name] end
    kind = Schema.column(:acct_audit, "kind").id
    kinds = fn m -> for {_, r} <- m["acct_audit"] || %{}, do: r[kind] end
    assert "views" in names.(model)

    # Every trail event wakes the views: a key minted, an agent's op batch.
    {:ok, _} = Hireme.Keys.mint(s, "later", Hireme.Keys.preset(:read_only))
    assert_receive {:sequencer, :patch, _, patch}, 2_000
    model = ingest(model, :PATCH, patch)
    assert "later" in names.(model)
    :ok = Hireme.Audit.record(:agent_ops, %{ops: 1}, %{account_id: a.id})
    assert_receive {:sequencer, :patch, _, patch}, 2_000
    model = ingest(model, :PATCH, patch)
    assert "agent_ops" in kinds.(model)
    security = Enum.reject(kinds.(model), &(&1 in Hireme.Audit.activity_kinds()))
    assert security != []

    # A window's worth of activity after them pushes no security event out.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    burst =
      for _ <- 1..1_000,
          do: %{
            account_id: a.id,
            kind: "agent_ops",
            security: false,
            rev: 1,
            inserted_at: now,
            updated_at: now
          }

    Repo.insert_all(Hireme.Rows.Audit, burst, skip_account: true)
    Hireme.Audit.changed(a.id)
    assert_receive {:sequencer, :patch, _, patch}, 2_000
    model = ingest(model, :PATCH, patch)
    assert Enum.sort(security) -- kinds.(model) == []

    # A resumed session's snapshot holds the tables; its views come fresh as a PATCH.
    {:ok, _} = Hireme.Keys.mint(s, "while away", Hireme.Keys.preset(:read_only))
    assert_receive {:sequencer, :patch, _, _}, 2_000

    {:PATCH, body} =
      Task.async(fn ->
        {:ok, %{frames: [f]}} = Sequencer.subscribe(a.id, sub(989), rev)
        {:ok, k, _, _, b} = Codec.decode(f)
        {k, b}
      end)
      |> Task.await()

    assert "while away" in names.(ingest(%{}, :PATCH, body))

    # Last: a pid holds one subscription, and this one becomes the key's.
    {_, as_key} = boot(a.id, 992, Grants.key(key))

    assert Enum.all?(as_key, fn {t, rows} ->
             not String.starts_with?(t, "acct_") or rows == %{}
           end)
  end

  test "a PATCH ships each row the columns it moved: one listing edited among renames carries one listing",
       %{account: a} do
    listing = String.duplicate("Rust, kernels and GPUs. ", 40)

    apps =
      for i <- 1..3 do
        {[app], []} =
          run(a.id, op(:put, :applications, %{company: "C#{i}", role: "R", listing_raw: listing}))

        app
      end

    {_, _} = boot(a.id, 995)
    [one, two, three] = apps

    {_, []} =
      run(a.id, [
        op(:put, :applications, %{listing_raw: listing <> " Edited."}, target: one.id),
        op(:put, :applications, %{role: "Staff"}, target: two.id),
        op(:put, :applications, %{role: "Staff"}, target: three.id)
      ])

    assert_receive {:sequencer, :patch, _, body}, 2_000
    rows = ingest(%{}, :PATCH, body)["applications"]
    col = Schema.column(:applications, "listing_raw").id
    assert Map.has_key?(rows[one.id], col)
    refute Map.has_key?(rows[two.id], col) or Map.has_key?(rows[three.id], col)
  end

  property "a subscriber's BOOT plus its PATCHes is a fresh BOOT; a mask never lets a row through, and a reader outside the written domain still learns the rev moved",
           %{account: a} do
    word = string(:alphanumeric, min_length: 1, max_length: 6)
    at = integer(0..20)
    chart = one_of([constant(nil), integer(1..9)])

    # Writes to every resident table and to places, whose atlas projection
    # follows a rename, a move onto or off the chart and a drop, with drops
    # that cascade.
    gen_action =
      one_of([
        tuple({constant(:rep), word}),
        tuple({constant(:app), word}),
        tuple({constant(:note), at, string(:printable, max_length: 12)}),
        tuple({constant(:drop), at}),
        tuple({constant(:profile), word}),
        tuple({constant(:item), word}),
        tuple({constant(:batch), word}),
        tuple({constant(:net), word}),
        tuple({constant(:settings), member_of(["pt", "de", "pt\u001fde", ""])}),
        tuple({constant(:place), word, chart}),
        tuple({constant(:chart), at, chart}),
        tuple({constant(:rename), at, word}),
        tuple({constant(:drop_place), at}),
        tuple({constant(:event), at, word}),
        tuple({constant(:overlay), at, at}),
        tuple({constant(:stage), at, member_of([:gated, :closed, :in_batch])}),
        tuple({constant(:drop_app), at})
      ])

    check all(actions <- list_of(gen_action, min_length: 1, max_length: 12), max_runs: 12) do
      me = self()
      lanes_only = Grants.key(%{id: 3, read_mask: 8, write_mask: 0, may_delete: false})

      watcher =
        spawn_link(fn ->
          {:ok, _} =
            Sequencer.subscribe(a.id, sub(System.unique_integer([:positive]), lanes_only), 0)

          send(me, :watching)
          watch(me)
        end)

      assert_receive :watching
      {_, model} = boot(a.id, System.unique_integer([:positive]))
      id = fn table, i -> Enum.at(Map.keys(Map.get(model, table, %{})), i, 999_999) end

      ops =
        Enum.map(actions, fn
          {:rep, slug} ->
            op(:put, :gym_reps, %{platform: :leetcode, slug: slug, done_on: ~D[2026-10-18]})

          {:app, role} ->
            op(:put, :applications, %{company: "Co", role: role})

          {:note, i, text} ->
            op(:put, :gym_reps, %{note: text}, target: id.("gym_reps", i))

          {:drop, i} ->
            op(:drop, :gym_reps, %{}, target: id.("gym_reps", i))

          {:profile, s} ->
            op(:put, :profiles, %{slug: "p-#{s}", name: s})

          {:item, s} ->
            op(:put, :items, %{kind: :skill, key: "k-#{s}", title: s})

          {:batch, s} ->
            op(:put, :batches, %{code: "b-#{s}", ordinal: 1})

          {:net, s} ->
            op(:put, :net_entries, %{kind: :post, title: s})

          {:settings, c} ->
            op(:put, :me, %{citizenships: c})

          {:place, s, pos} ->
            op(:put, :places, %{kind: :city, name: s, atlas_position: pos})

          {:chart, i, pos} ->
            op(:put, :places, %{atlas_position: pos}, target: id.("places", i))

          {:rename, i, s} ->
            op(:put, :places, %{name: s}, target: id.("places", i))

          {:drop_place, i} ->
            op(:drop, :places, %{}, target: id.("places", i))

          {:event, i, s} ->
            op(:put, :events, %{application_id: id.("applications", i), kind: s})

          {:overlay, i, j} ->
            cells = %{
              application_id: id.("applications", i),
              item_id: id.("items", j),
              mode: :add
            }

            op(:put, :cv_overlays, cells)

          {:stage, i, to} ->
            op(:command, :stage, %{stage: to}, target: id.("applications", i))

          {:drop_app, i} ->
            op(:drop, :applications, %{}, target: id.("applications", i))
        end)

      Sequencer.submit(a.id, ops)
      {model, revs} = drain(model, [])
      {fresh_rev, fresh_model} = fresh(a.id, System.unique_integer([:positive]))
      assert model == fresh_model

      send(watcher, {:done, me})
      assert_receive {:watched, frames}

      for {_, tables} <- frames,
          do:
            assert(
              Enum.all?(tables, &(&1 in ~w(gym_reps net_entries gone leases))),
              inspect(tables)
            )

      # Its PATCH may carry no row, but it carries the rev.
      if revs != [], do: assert(fresh_rev in Enum.map(frames, &elem(&1, 0)))
    end
  end

  defp drain(model, revs) do
    receive do
      {:sequencer, :patch, rev, body} -> drain(ingest(model, :PATCH, body), [rev | revs])
      {:sequencer, :verdicts, _, _, _} -> {model, revs}
    after
      3_000 -> flunk("no verdicts")
    end
  end

  defp watch(parent, seen \\ []) do
    receive do
      {:sequencer, :patch, rev, body} ->
        watch(parent, [{rev, Enum.map(tables(body), &elem(&1, 0))} | seen])

      {:done, ^parent} ->
        send(parent, {:watched, Enum.reverse(seen)})
    end
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

    # A fresh sequencer reads the lineage.
    stop_sequencer(a.id)
    {[ack], []} = run(a.id, op(:command, :open_generation, %{corporation_id: corp.id}))
    assert ack.id > 0 and ack.rev > 0
    assert Repo.get!(Hireme.Rows.CvLineage, ack.id).corporation_id == corp.id
  end

  test "listings stored under another keywords version are re-extracted when the sequencer starts, past any ledger entries an earlier run left",
       %{account: a} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The operator's (writer 0) entries a previous boot left, low ids included:
    # every id unique_integer can have reached in this VM, and more.
    top = System.unique_integer([:positive]) + 1_000

    for chunk <- Enum.chunk_every(1..top, 2_000) do
      rows =
        for i <- chunk,
            do: %{
              account_id: a.id,
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

      Repo.insert_all(OpLedger, rows)
    end

    Repo.insert_all(Application, [
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

    _ = rev(a.id)
    version = Hireme.Kernel.keywords_version()
    assert eventually(fn -> match?([%{keywords_version: ^version}], Repo.all(Application)) end)
    assert hd(Repo.all(Application)).keywords not in [nil, ""]
  end

  test "two sessions' lease audits are each their own, however they interleave", %{
    account: a,
    session: s
  } do
    sessions =
      for {name, sid} <- [{"x", 997}, {"y", 998}] do
        key = mint(s, name)
        me = self()
        info = sub(sid, Grants.key(key), key.id)

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

    # Audits are written after the reply, as the sequencer's next message.
    _ = rev(a.id)

    kinds =
      Repo.all(
        from r in Hireme.Rows.Audit,
          where: r.kind in ["lease_opened", "lease_released"],
          select: r.kind
      )

    assert Enum.frequencies(kinds) == %{"lease_opened" => 10, "lease_released" => 10}
  end

  describe "limits" do
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

    defp set_counter(account_id, bytes),
      do:
        Repo.update_all(
          from(x in Hireme.Rows.Account, where: x.id == ^account_id),
          [set: [text_bytes: bytes]],
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

    test "past the account's text budget a longer write is refused cap and leaves no claim behind; a shorter rewrite lands",
         %{account: a, session: s} do
      {[app], []} =
        run(
          a.id,
          op(:put, :applications, %{
            company: "Full",
            role: "R",
            notes: String.duplicate("x", 5_000)
          })
        )

      set_counter(a.id, Hireme.Security.account_text_bytes() - 10)
      # The sequencer reads the counter when it starts; a fresh one sees the full account.
      stop_sequencer(a.id)
      {agent, _} = key_session(a.id, mint(s, "near"), 998)

      notes = fn n, c ->
        op(:put, :applications, %{company: "C", role: "R", notes: String.duplicate(c, n)})
      end

      assert {[], [%{refusal: :cap}]} = key_session_ops(agent, notes.(100, "x"))
      assert {:ok, [%{ids: []}]} = Sequencer.lease(a.id, :list)
      assert {[], [%{refusal: :cap}]} = run(a.id, notes.(100, "x"))
      assert {[_], []} = run(a.id, gym("s"))

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

    test "a key past its circuit breaker is refused rate whole, before anything is judged; a bulk contract's writes are outside the breaker, up to its count",
         %{account: a, session: s} do
      key = mint(s, "flood")
      {agent, _} = key_session(a.id, key, 980)
      {bulk, %{"bulk" => %{"writes" => 3}}} = key_session(a.id, key, 981, %{"bulk" => 3})
      {_, breaker} = Hireme.Security.limits()[:agent_write]

      Enum.reduce_while(1..breaker, nil, fn _, _ ->
        if Hireme.Security.hit(:agent_write, key.id, 1) == :ok,
          do: {:cont, nil},
          else: {:halt, nil}
      end)

      {[], nacks} = key_session_ops(agent, [gym("f1"), gym("f2")])
      assert Enum.all?(nacks, &(&1.refusal == :rate))
      assert count(GymRep) == 0

      {acks, []} = key_session_ops(bulk, [gym("b1"), gym("b2"), gym("b3")])
      assert length(acks) == 3 and count(GymRep) == 3
      {[], nacks} = key_session_ops(bulk, gym("b4"))
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
        cells = %{headcount: n, as_of: Date.add(~D[2026-01-01], n), source: url}
        run(a.id, op(:put, :corporations, cells, target: corp))
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
      stop_sequencer(a.id)
      assert {[_], []} = run(a.id, op(:put, :sources, %{url: "https://direct.example/2"}))

      assert {[], [%{refusal: :cap}]} =
               run(a.id, op(:put, :sources, %{url: "https://direct.example/3"}))
    end
  end
end
