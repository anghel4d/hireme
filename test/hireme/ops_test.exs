defmodule Hireme.OpsTest do
  use Hireme.DataCase, async: false

  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Ops
  alias Hireme.Pipeline

  @companies ["Acme", "Acme", "Globex", "Initech", "Google", "Umbrella"]
  @urls [
    "https://boards.greenhouse.io/acme/jobs/",
    "https://boards.greenhouse.io/globex/jobs/",
    "https://jobs.lever.co/initech/",
    "https://careers.example.test/"
  ]

  # A desk with company and ATS overlap, hot and cold stages of several
  # ages, a held batch, and lines to tailor.
  defp desk(seed) do
    :rand.seed(:exsss, {seed, seed * 7, seed * 13})
    profiles = for _ <- 1..2, do: profile()
    items = Map.new(profiles, fn p -> {p.id, for(n <- 1..3, do: item(p, %{position: n}))} end)

    {:ok, batch} =
      Ops.exec(
        {:insert, :batches,
         fn ->
           %Batch{}
           |> Batch.changeset(%{code: "B-#{seed}", ordinal: 1, status: :fire_ready, fire: :hold})
           |> Repo.insert!()
         end}
      )

    jobs =
      for n <- 1..18 do
        p = Enum.random(profiles)

        job(p, %{
          company: Enum.random(@companies),
          role: Enum.random(["Engineer", "Research Engineer", "SRE"]),
          listing_url: Enum.random(@urls) <> "#{n}",
          stage: Enum.random(Pipeline.keys()),
          stage_on: Date.add(Date.utc_today(), -:rand.uniform(60)),
          batch_id: if(rem(n, 3) == 0, do: batch.id)
        })
      end

    %{jobs: jobs, items: items, batch: batch}
  end

  defp random_op(%{jobs: jobs, items: items, batch: batch}, op_id) do
    job = Enum.random(jobs)
    pick = fn list -> Enum.random(list) end

    {kind, target, fields} =
      case :rand.uniform(9) do
        1 ->
          {:stage, job.id, [pick.(Enum.map(Pipeline.keys(), &Pipeline.name/1) ++ ["nope"])]}

        2 ->
          {:next, job.id, ["call #{op_id}", pick.(["", "2026-11-0#{:rand.uniform(9)}", "bad"])]}

        3 ->
          {:note, job.id, [Pipeline.name(pick.(Pipeline.keys())), "note #{op_id}"]}

        4 ->
          {:score, job.id, [pick.(["0", "55", "100", "101", "x"])]}

        5 ->
          item = pick.(items[job.profile_id])
          mode = pick.(~w(hidden emphasized altered inherit bogus))
          {:overlay, job.id, ["#{item.id}", mode, pick.(["", "Rewritten"]), ""]}

        6 ->
          {:heat_override, job.id, [pick.(["", "warm intro"])]}

        7 ->
          {:open_fire, 0, [pick.([batch.code, "missing"])]}

        8 ->
          {:stage, job.id, [pick.(~w(fire_ready open_fire submitted reply closed gated))]}

        9 ->
          {:gym_log, 0, ["title", "Two sum #{op_id}", "slug", "two-sum-#{op_id}"]}
      end

    %{op_id: op_id, kind: kind, target: target, fields: fields}
  end

  # A tab's view: the raw tables, by id. Every delta merges its rows
  # (a changed row carries only its moved columns) and drops what it
  # names gone.
  defp apply_delta(tables, delta) do
    tables =
      Enum.reduce(delta.gone, tables, fn {t, ids}, acc ->
        Map.update!(acc, t, &Map.drop(&1, ids))
      end)

    Enum.reduce(delta.rows, tables, fn {t, rows}, acc ->
      Map.update!(acc, t, fn table ->
        Enum.reduce(rows, table, fn row, table ->
          Map.update(table, row.id, row, &Map.merge(&1, row))
        end)
      end)
    end)
  end

  defp by_id(tables), do: Map.new(tables, fn {t, rows} -> {t, Map.new(rows, &{&1.id, &1})} end)
  defp fresh_view, do: by_id(Ops.read_tables())

  defp drain(acc) do
    receive do
      {:ops_delta, rev, delta} -> drain([{rev, delta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Take a lease on a random job for a stand-in agent, or drop the one
  # held there; `{:lease, changed?}`, whether a lease row came or went.
  defp lease_step(%{jobs: jobs}) do
    job = Enum.random(jobs)
    producers = Process.get(:producers, %{})

    case Map.pop(producers, job.id) do
      {nil, _} ->
        case Hireme.Fixtures.hold_lease(job.id) do
          {{:ok, _block, _}, producer} ->
            Process.put(:producers, Map.put(producers, job.id, producer))
            {:lease, true}

          {{:error, _busy}, producer} ->
            Hireme.Fixtures.let_go(producer)
            {:lease, false}
        end

      {producer, rest} ->
        Process.put(:producers, rest)
        Hireme.Fixtures.let_go(producer)
        {:lease, true}
    end
  end

  # A lease's repaint is a cast after the fact: wait for it.
  defp await_delta do
    receive do
      {:ops_delta, rev, delta} -> drain([{rev, delta}])
    after
      2_000 -> flunk("no delta for a lease change")
    end
  end

  defp diverged(view, want) do
    for {t, rows} <- want, {id, row} <- rows, view[t][id] != row, do: {t, id}
  end

  for seed <- 1..6 do
    test "boot plus every delta equals the tables (seed #{seed})",
         %{account: account} do
      seed = unquote(seed)
      fixture = desk(seed)
      {:ok, boot_rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
      boot = by_id(tables)
      assert boot == fresh_view()

      {view, rev, log} =
        Enum.reduce(1..60, {boot, boot_rev, []}, fn n, {view, rev, log} ->
          op = random_op(fixture, seed * 1000 + n)

          # Some writes arrive as an agent's, not a tab's, and agents take
          # and drop leases: all one stream.
          {reply, log} =
            cond do
              rem(n, 5) == 0 ->
                {lease_step(fixture), [:lease | log]}

              rem(n, 7) == 0 ->
                {Desk.set_next(Enum.random(fixture.jobs).id, "agent #{n}", nil), log}

              true ->
                {Ops.run(account.id, op), [op | log]}
            end

          deltas = if reply == {:lease, true}, do: await_delta(), else: drain([])

          case reply do
            {:lease, changed?} -> assert length(deltas) == if(changed?, do: 1, else: 0)
            {:ok, r} when is_integer(r) -> assert [{^r, _}] = deltas
            {:ok, _} -> assert [_] = deltas
            {:error, _} -> assert deltas == [], "seed #{seed}: a refusal sent a delta"
          end

          # Revisions are consecutive: nothing skipped, nothing twice.
          rev =
            Enum.reduce(deltas, rev, fn {r, _}, prev ->
              assert r == prev + 1, "seed #{seed}: rev #{r} after #{prev}"
              r
            end)

          {Enum.reduce(deltas, view, fn {_, d}, v -> apply_delta(v, d) end), rev, log}
        end)

      producers = Process.get(:producers, %{})
      on_exit(fn -> Enum.each(producers, fn {_, pid} -> Process.exit(pid, :kill) end) end)

      want = fresh_view()

      assert view == want,
             "seed #{seed}: #{inspect(diverged(view, want))} diverged " <>
               "after #{inspect(Enum.reverse(log), limit: :infinity)}"

      assert rev > boot_rev

      # A session that stood at the boot resumes from the ring alone.
      {:ok, ^rev, {:replay, deltas}} = Ops.attach(account.id, boot_rev)
      assert Enum.map(deltas, &elem(&1, 0)) == Enum.to_list((boot_rev + 1)..rev//1)

      resumed =
        Enum.reduce(deltas, boot, fn {_, d}, v ->
          apply_delta(v, d)
        end)

      assert resumed == want
    end
  end

  # Writes queued behind a busy sequencer are sealed together: one
  # transaction, one revision each, a refusal undone alone (even part-way
  # through an opening), every answer after its delta and in send order.
  for seed <- 1..3 do
    test "a batch of queued writes commits as one, each with its own revision (seed #{seed})",
         %{account: account} do
      seed = unquote(seed)
      fixture = desk(40 + seed)
      [p | _] = Map.keys(fixture.items)
      {:ok, boot_rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
      seq = Ops.whereis(account.id)
      :ok = :sys.suspend(seq)

      ops = for n <- 1..40, do: random_op(fixture, seed * 10_000 + n)
      refs = Enum.map(ops, &Ops.send_run(account.id, &1))

      # An opening that fails after writing its row, queued among them.
      me = self()

      opener =
        spawn(fn ->
          Repo.put_account(account.id)

          attrs = %{
            profile_id: p,
            company: "Half Open",
            role: "x",
            overlays: [%{item_id: 999_999, mode: :hidden}]
          }

          send(me, {:opened, Desk.create_job(attrs)})
        end)

      Process.sleep(20)
      :ok = :sys.resume(seq)

      replies =
        for ref <- refs do
          receive do
            {:ops_reply, ^ref, reply} -> reply
          after
            5_000 -> flunk("no answer, seed #{seed}")
          end
        end

      assert_receive {:opened, {:error, _}}, 5_000
      refute Repo.exists?(from j in Desk.Job, where: j.company == "Half Open")
      _ = opener

      revs = for {:ok, rev} <- replies, do: rev
      assert revs == Enum.sort(revs) and length(Enum.uniq(revs)) == length(revs)
      deltas = drain([])

      assert Enum.map(deltas, &elem(&1, 0)) ==
               Enum.to_list((boot_rev + 1)..List.last([boot_rev | revs])//1)

      view = Enum.reduce(deltas, by_id(tables), fn {_, d}, v -> apply_delta(v, d) end)
      assert view == fresh_view(), "seed #{seed}: #{inspect(diverged(view, fresh_view()))}"

      # Every answer is the ledger's: a resend gets it back unchanged, and
      # neither writes nor sends a delta.
      for {op, reply} <- Enum.zip(ops, replies), do: assert(Ops.run(account.id, op) == reply)
      assert fresh_view() == view and drain([]) == []
    end
  end

  # An op id is answered once, the first time, whatever a resend carries:
  # a copy queued in the same batch, a resend answered from the ledger
  # table (nothing of it is kept in memory), and one after a restart.
  for seed <- 1..3 do
    test "a resent op id gets its first answer on every path (seed #{seed})",
         %{account: account} do
      seed = unquote(seed)
      :rand.seed(:exsss, {seed, 7, 11})
      fixture = desk(60 + seed)
      {:ok, _rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
      ops = for n <- 1..30, do: random_op(fixture, seed * 10_000 + n)

      # The same id with other fields: never the one that counts.
      again = fn op -> %{random_op(fixture, op.op_id + 500) | op_id: op.op_id} end
      twice = Enum.take_random(ops, 10)
      queued = Enum.flat_map(ops, &if(&1 in twice, do: [&1, again.(&1)], else: [&1]))

      seq = Ops.whereis(account.id)
      :ok = :sys.suspend(seq)
      refs = Enum.map(queued, &Ops.send_run(account.id, &1))
      :ok = :sys.resume(seq)

      replies =
        for ref <- refs do
          receive do
            {:ops_reply, ^ref, reply} -> reply
          after
            5_000 -> flunk("no answer, seed #{seed}")
          end
        end

      first =
        Map.new(Enum.zip(queued, replies) |> Enum.reverse(), fn {op, r} -> {op.op_id, r} end)

      for {op, reply} <- Enum.zip(queued, replies), do: assert(reply == first[op.op_id])

      deltas = drain([])
      assert length(deltas) == Enum.count(Map.values(first), &match?({:ok, _}, &1))
      view = Enum.reduce(deltas, by_id(tables), fn {_, d}, v -> apply_delta(v, d) end)
      assert view == fresh_view(), "seed #{seed}: #{inspect(diverged(view, fresh_view()))}"

      for op <- ops, do: assert(Ops.run(account.id, again.(op)) == first[op.op_id])
      :ok = Ops.stop(account.id)
      for op <- ops, do: assert(Ops.run(account.id, again.(op)) == first[op.op_id])

      # Fields that raise when run: a new id is answered :internal, a
      # resent one still with its first answer.
      huge = ~w(title probe minutes 9223372036854775808)
      raising = &%{op_id: &1, kind: :gym_log, target: 0, fields: huge}

      assert Ops.run(account.id, raising.(seed * 10_000 + 999)) == {:error, :internal}
      for op <- ops, do: assert(Ops.run(account.id, raising.(op.op_id)) == first[op.op_id])
      assert fresh_view() == view and drain([]) == []
    end
  end

  # The writer lock is never left held: not by a write that raises, not
  # by a holder that dies holding it, and the next in line gets it.
  test "the writer lock is freed by a raise and by its holder's death" do
    assert_raise RuntimeError, fn -> Hireme.Store.transaction(fn -> raise "boom" end) end
    assert Hireme.Store.transaction(fn -> :again end) == {:ok, :again}

    me = self()

    # Holding the lock alone, with no connection checked out.
    holder =
      Task.async(fn ->
        :ok = GenServer.call(Hireme.Store, :lock)
        send(me, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held
    waiter = Task.async(fn -> Hireme.Store.transaction(fn -> :next end) end)
    refute Task.yield(waiter, 50)
    Process.unlink(holder.pid)
    Process.exit(holder.pid, :kill)
    assert Task.await(waiter) == {:ok, :next}
  end

  # The target is the client's: an id that is another account's, or no
  # one's, is refused like any other op, and the sequencer carries on.
  test "every kind refuses a target the account cannot see", %{account: account} do
    mine = job(profile(), %{company: "Mine"})
    mine_item = item(Repo.get!(Hireme.Corpus.Profile, mine.profile_id))
    other = Hireme.Accounts.create!(%{name: "Other"})

    {theirs, their_item, their_narrative} =
      Repo.with_account(other.id, fn ->
        p = profile()
        user = Hireme.Narrative.create_user!(%{name: "Them"})
        narrative = Hireme.Narrative.write!(user, "private")

        %Batch{}
        |> Batch.changeset(%{code: "Theirs", ordinal: 1, status: :fire_ready, fire: :hold})
        |> Repo.insert!()

        {job(p, %{company: "Theirs"}), item(p), narrative}
      end)

    on_exit(fn -> Ops.stop(other.id) end)
    :ok = Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account.id))

    ops =
      for target <- [theirs.id, 999_999_999],
          {kind, fields} <- [
            stage: ["gated"],
            next: ["x", ""],
            note: ["gated", "x"],
            score: ["5"],
            overlay: ["#{mine_item.id}", "hidden", "", ""],
            heat_override: ["because"]
          ],
          do: {kind, target, fields}

    ops =
      ops ++
        [
          {:overlay, mine.id, ["#{their_item.id}", "hidden", "", ""]},
          {:overlay, mine.id, ["999999999", "emphasized", "", ""]},
          {:open_fire, 0, ["Theirs"]},
          {:narrative, their_narrative.id, ["mine now"]},
          {:narrative, 999_999_999, ["nobody's"]}
        ]

    for {{kind, target, fields}, n} <- Enum.with_index(ops, 100) do
      op = %{op_id: n, kind: kind, target: target, fields: fields}
      result = Ops.run(account.id, op)

      assert match?({:error, reason} when is_atom(reason) and reason != :internal, result),
             "#{inspect(op)} -> #{inspect(result)}"

      refute_received {:ops_delta, _, _}, inspect(op)
    end

    assert {:ok, _} =
             Ops.run(account.id, %{op_id: 1, kind: :score, target: mine.id, fields: ["7"]})

    assert Repo.with_account(other.id, fn -> Repo.get!(Desk.Job, theirs.id).score_100 end) != 5
  end

  # The ops an agent's lease sends cover what its tools did.
  test "a generation opens on a lineage past its quarter, and an altered line keeps its title",
       %{account: account} do
    p = profile()
    line = item(p)
    job = job(p, %{company: "Quarter Co"})

    run = fn kind, fields ->
      op = %{
        op_id: System.unique_integer([:positive]),
        kind: kind,
        target: job.id,
        fields: fields
      }

      Ops.run(account.id, op)
    end

    assert {:ok, _} = run.(:overlay, ["#{line.id}", "altered", "Rewritten", "", "New title"])

    assert %{title: "New title", body: "Rewritten"} =
             Repo.get_by!(Hireme.Desk.Overlay, item_id: line.id)

    assert {:error, :cooldown} = run.(:generation, [])
    pair = Hireme.CvPair.bind!(job.id)
    lineage = Repo.get!(Hireme.Cv.Lineage, Hireme.CvPair.lineage_id(pair))
    past = Date.add(Date.utc_today(), -(Hireme.CvPair.cooldown_days() + 1))
    lineage |> Ecto.Changeset.change(opened_on: past) |> Repo.update!()

    :ok = Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account.id))
    assert {:ok, rev} = run.(:generation, [])
    assert_received {:ops_delta, ^rev, %{rows: %{cv_lineages: [%{generation: 2}]}}}
  end

  # Another VM (a release task, an import) writes the same database and
  # moves the revision. Whether the sequencer's next act is a write or an
  # attach, every tab and the next boot come level; the revision made
  # elsewhere is not in the ring, so a session behind it boots.
  test "a row another VM writes reaches every tab with the next write or attach, and the next boot",
       %{account: account} do
    %{jobs: [first, second | _]} = desk(99)
    {:ok, boot_rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
    view = by_id(tables)

    moved = fn ->
      Repo.update_all(
        from(a in Hireme.Accounts.Account, where: a.id == ^account.id),
        [inc: [desk_rev: 1]],
        skip_account: true
      )
    end

    Repo.update_all(from(j in Desk.Job, where: j.id == ^first.id),
      set: [next_action: "elsewhere"]
    )

    moved.()

    assert {:ok, rev} =
             Ops.run(account.id, %{op_id: 7, kind: :score, target: second.id, fields: ["9"]})

    deltas = drain([])
    assert rev > boot_rev + 1 and List.last(deltas) |> elem(0) == rev
    view = Enum.reduce(deltas, view, fn {_, d}, v -> apply_delta(v, d) end)
    assert view == fresh_view()

    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Around", ordinal: 9, status: :draft_prep, fire: :hold})
      |> Repo.insert()

    moved.()

    other =
      Task.async(fn ->
        Repo.put_account(account.id)
        Ops.attach(account.id, nil)
      end)

    assert {:ok, next, {:boot, %{tables: seen}}} = Task.await(other)
    assert Enum.any?(seen.batches, &(&1.id == batch.id))

    assert [{^next, delta}] = drain([])
    assert next == rev + 2
    assert apply_delta(view, delta) == fresh_view()

    assert {:ok, ^next, {:boot, _}} = Ops.attach(account.id, boot_rev)
    assert {:ok, ^next, {:boot, _}} = Ops.attach(account.id, rev)
  end

  # A boot reads the tables in the attaching process while writes go on;
  # whatever it read, the boot plus the deltas after its revision must
  # come out level with the database.
  test "boots racing writes each end level with the tables", %{account: account} do
    fixture = desk(97)
    {:ok, _, _} = Ops.attach(account.id, nil)
    me = self()

    booters =
      for b <- 1..6 do
        Task.async(fn ->
          Repo.put_account(account.id)
          Process.sleep(b * 3)
          {:ok, rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
          send(me, {:booted, b})

          receive do
            :done -> :ok
          end

          deltas = for {r, d} <- drain([]), r > rev, do: {r, d}

          deltas
          |> Enum.reduce(by_id(tables), fn {_, d}, v ->
            apply_delta(v, d)
          end)
        end)
      end

    for n <- 1..40, do: Ops.run(account.id, random_op(fixture, 97_000 + n))
    for b <- 1..6, do: assert_receive({:booted, ^b}, 5_000)
    _ = drain([])

    {:ok, _} =
      Ops.run(account.id, %{op_id: 1, kind: :score, target: hd(fixture.jobs).id, fields: ["3"]})

    want = by_id(Ops.read_tables())

    for task <- booters do
      send(task.pid, :done)
      assert Task.await(task) == want
    end
  end
end
