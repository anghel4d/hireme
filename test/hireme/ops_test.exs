defmodule Hireme.OpsTest do
  use Hireme.DataCase, async: false

  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Gym
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
          {{:ok, _pair}, producer} ->
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

  test "a resent op gets its first answer and writes once", %{account: account} do
    op = %{
      op_id: 0xFFFF_FFFF_0000_0001,
      kind: :gym_log,
      target: 0,
      fields: ["title", "Rerun", "slug", "rerun"]
    }

    :ok = Phoenix.PubSub.subscribe(Hireme.PubSub, Desk.topic(account.id))

    assert {:ok, rev} = Ops.run(account.id, op)
    assert_received {:ops_delta, ^rev, %{rows: %{gym_reps: [_]}}}
    assert {:ok, ^rev} = Ops.run(account.id, op)
    refute_received {:ops_delta, _, _}
    assert length(Gym.recent()) == 1

    refused = %{op | op_id: 2, kind: :score, target: 1, fields: ["101"]}
    assert {:error, {:argument, "score"}} = Ops.run(account.id, refused)
    assert {:error, {:argument, "score"}} = Ops.run(account.id, %{refused | fields: ["5"]})
  end

  # The target is the client's: an id that is another account's, or no
  # one's, is refused like any other op, and the sequencer carries on.
  test "every kind refuses a target the account cannot see", %{account: account} do
    mine = job(profile(), %{company: "Mine"})
    [mine_item | _] = for _ <- 1..1, do: item(Desk.focus(mine.id).profile)
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

  # An agent reads heat without a call into the sequencer, and still sees
  # its own committed writes.
  test "the heat an agent reads follows every committed move", %{account: account} do
    job = job(profile(), %{company: "Keel", stage: "gated"})
    hot? = fn -> Enum.any?(Ops.heat(account.id).jobs, &(&1.id == job.id)) end
    refute hot?.()

    assert {:ok, _} =
             Ops.run(account.id, %{op_id: 1, kind: :stage, target: job.id, fields: ["reply"]})

    assert hot?.()

    assert {:ok, _} =
             Ops.run(account.id, %{op_id: 2, kind: :stage, target: job.id, fields: ["gated"]})

    refute hot?.()
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
  # moves the revision; the next delta must still bring a tab level.
  test "a write from outside the sequencer reaches tabs with the next delta", %{account: account} do
    %{jobs: [first, second | _]} = desk(99)
    {:ok, boot_rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
    boot = by_id(tables)

    Repo.update_all(from(j in Desk.Job, where: j.id == ^first.id),
      set: [next_action: "elsewhere"]
    )

    Repo.update_all(
      from(a in Hireme.Accounts.Account, where: a.id == ^account.id),
      [inc: [desk_rev: 1]],
      skip_account: true
    )

    assert {:ok, rev} =
             Ops.run(account.id, %{op_id: 7, kind: :score, target: second.id, fields: ["9"]})

    deltas = drain([])
    assert rev > boot_rev + 1 and List.last(deltas) |> elem(0) == rev
    assert Enum.reduce(deltas, boot, fn {_, d}, v -> apply_delta(v, d) end) == fresh_view()

    # The revision made elsewhere is not in the ring: a session behind it boots.
    assert {:ok, ^rev, {:boot, _}} = Ops.attach(account.id, boot_rev)
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

  # A boot is a copy of the sequencer's tables. A row only reaches them
  # through the sequencer, or (from another VM) with the revision moved.
  test "a row another VM writes reaches the next boot and every tab", %{account: account} do
    desk(98)
    {:ok, boot_rev, {:boot, %{tables: tables}}} = Ops.attach(account.id, nil)
    boot = by_id(tables)

    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Around", ordinal: 9, status: :draft_prep, fire: :hold})
      |> Repo.insert()

    Repo.update_all(
      from(a in Hireme.Accounts.Account, where: a.id == ^account.id),
      [inc: [desk_rev: 1]],
      skip_account: true
    )

    other =
      Task.async(fn ->
        Repo.put_account(account.id)
        Ops.attach(account.id, nil)
      end)

    assert {:ok, rev, {:boot, %{tables: seen}}} = Task.await(other)
    assert Enum.any?(seen.batches, &(&1.id == batch.id))

    assert [{^rev, delta}] = drain([])
    assert rev == boot_rev + 2
    assert apply_delta(boot, delta) == fresh_view()
  end
end
