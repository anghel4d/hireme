# Run with a disposable copied fixture, BENCH_DIR/BENCH_REV/BENCH_OUTPUT, and +S 2:2.
# Defaults: 20 warmups, 1000 samples; imports of 55 applications use BENCH_BATCH_N=100.
# All fixture preparation, assertions and cleanup are outside timed/query-count intervals.
# Operations use public APIs and commit normally: there is never an outer rollback.
defmodule HiremeBench.Actions do
  import Ecto.Query

  alias Hireme.{
    Corpus,
    CvPair,
    Desk,
    Gym,
    Heat,
    Import,
    Kv,
    Letterbox,
    Narrative,
    Net,
    Pipeline,
    Repo
  }

  alias Hireme.Desk.{Batch, Employer, Event, Job, Overlay}
  @prefix "Actions benchmark "

  def run do
    dir = Path.expand(System.fetch_env!("BENCH_DIR"))
    database = Application.fetch_env!(:hireme, Repo) |> Keyword.fetch!(:database) |> Path.expand()

    unless String.starts_with?(dir, "/tmp/hireme-perf-actions-") and
             String.starts_with?(database, dir <> "/") and
             File.lstat!(database).type == :regular and File.lstat!(dir).type == :directory,
           do: raise("use a regular copied database in /tmp/hireme-perf-actions-* only")

    true = :erlang.system_info(:schedulers_online) == 2
    Logger.configure(level: :warning)
    endpoint = Application.fetch_env!(:hireme, HiremeWeb.Endpoint)
    Application.put_env(:hireme, HiremeWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Application.put_env(:hireme, Hireme.Mailer, adapter: Swoosh.Adapters.Test)
    {:ok, _} = Application.ensure_all_started(:hireme)
    metadata = dir |> Path.join("testbed.json") |> File.read!() |> Jason.decode!()
    Repo.put_account(metadata["account_id"])
    Process.put(:coverage, [])
    Process.put(:sizes, sizes())
    cleanup_jobs(@prefix)
    profile = Corpus.get_profile!(hd(metadata["profile_ids"]))
    items = Corpus.list_items(profile.id)
    true = length(items) > 0
    item = hd(items)
    Process.put(:profile_items, length(items))
    Process.put(:profile_item_bytes, Enum.reduce(items, 0, &(byte_size(&1.body || "") + &2)))
    n = positive_env("BENCH_N", "1000")
    batch_n = positive_env("BENCH_BATCH_N", "100")
    no_prepare = fn _ -> nil end
    no_cleanup = fn _, _ -> :ok end

    attrs = attrs(profile, "shared", "one")
    job = Desk.create_job!(attrs)
    sibling = Desk.create_job!(attrs(profile, "shared", "two"))
    pair = CvPair.bind!(job.id)
    lineage_id = CvPair.lineage_id(pair)
    true = lineage_id == CvPair.lineage_id(CvPair.bind!(sibling.id))

    measure(
      "Desk",
      "job_add_new_employer",
      n,
      no_prepare,
      fn _ -> Desk.create_job(attrs(profile, "new employer", "new")) end,
      fn result, _ ->
        added = ok(result)
        true = added == Repo.get!(Job, added.id)
        true = added.company == @prefix <> "new employer"
        true = CvPair.job_id(CvPair.bind!(added.id)) == added.id
      end,
      fn _, _ -> cleanup_jobs(@prefix <> "new employer") end
    )

    ok(
      Desk.put_overlay(job.id, item.id, %{mode: :altered, body: "Elixir systems shared wording"})
    )

    shared_before = Repo.get!(Job, job.id)

    measure(
      "Desk",
      "job_add_existing_employer_shared_overlay",
      n,
      no_prepare,
      fn _ ->
        Desk.create_job(
          Map.merge(attrs(profile, "shared", "third"), %{
            theme: %{targets: ["missing"]},
            stage_notes: %{discovered: "Ready for review"}
          })
        )
      end,
      fn result, _ ->
        added = ok(result)
        true = added == Repo.get!(Job, added.id)

        pair = CvPair.bind!(added.id)
        true = CvPair.lineage_id(pair) == lineage_id and CvPair.job_id(pair) == added.id
        focus = Desk.focus(added.id)
        true = focus.cv.sections == Desk.focus(job.id).cv.sections
        true = focus.coverage.hits == ["elixir", "systems"] and focus.coverage.misses == []
        true = Enum.find(Desk.rail(added), &(&1.key == :discovered)).note == "Ready for review"
        true = Repo.get!(Job, job.id) == shared_before
      end,
      fn result, _ -> Repo.delete!(ok(result)) end
    )

    ok(Desk.put_overlay(job.id, item.id, :inherit))

    for {name, reset, operation, expected} <- [
          {"score_change", %{score_100: 40}, fn -> Desk.set_score(job.id, 81) end,
           %{score_100: 81}},
          {"next_action", %{next_action: "", next_due: nil},
           fn -> Desk.set_next(job.id, "Prepare systems interview", ~D[2026-10-31]) end,
           %{next_action: "Prepare systems interview", next_due: ~D[2026-10-31]}},
          {"note_save", %{stage_notes: %{}},
           fn -> Desk.set_note(job.id, :gated, "Strong systems fit; review the listing.") end,
           %{stage_notes: %{"gated" => "Strong systems fit; review the listing."}}}
        ] do
      measure(
        "Desk",
        name,
        n,
        fn _ -> reset_job(job.id, reset) end,
        fn _ -> operation.() end,
        fn result, _ -> assert_job(result, job.id, expected) end,
        no_cleanup
      )
    end

    for {name, stage} <- [
          {"stage_non_entering", :freshness},
          {"stage_entering_heat_gate", :fire_ready}
        ] do
      measure(
        "Desk",
        name,
        n,
        fn _ -> reset_stage(job.id, :discovered) end,
        fn _ -> Desk.set_stage(job.id, stage) end,
        fn result, _ ->
          assert_job(result, job.id, %{current_stage: stage})

          true =
            Repo.exists?(from e in Event, where: e.job_app_id == ^job.id and e.kind == "stage")
        end,
        no_cleanup
      )
    end

    reset_stage(job.id, :discovered)

    measure(
      "Heat",
      "override_with_reason",
      n,
      fn _ ->
        prune_events(job.id)
        reset_job(job.id, %{heat_override: false, heat_override_reason: ""})
      end,
      fn _ -> Heat.set_override(job.id, "Confirmed a distinct team opening") end,
      fn result, _ ->
        assert_job(result, job.id, %{
          heat_override: true,
          heat_override_reason: "Confirmed a distinct team opening"
        })

        true = Repo.exists?(from e in Event, where: e.job_app_id == ^job.id and e.kind == "heat")
      end,
      no_cleanup
    )

    for {name, mode} <- [
          {"mask_hide_shared_2", :hidden},
          {"mask_alter_shared_2", :altered},
          {"mask_emphasize_shared_2", :emphasized},
          {"mask_restore_shared_2", :inherit}
        ] do
      change =
        if mode == :inherit,
          do: :inherit,
          else: %{
            mode: mode,
            body: "Synthetic systems runtime evidence",
            reason: "Role relevance"
          }

      measure(
        "CV",
        name,
        n,
        fn _ ->
          ok(Desk.put_overlay(job.id, item.id, :inherit))

          if mode == :inherit,
            do:
              ok(
                Desk.put_overlay(job.id, item.id, %{mode: :hidden, reason: "Restore preparation"})
              )
        end,
        fn _ -> Desk.put_overlay(job.id, item.id, change) end,
        fn result, _ ->
          assert_job(result, job.id, %{})

          overlay = Repo.get_by(Overlay, lineage_id: lineage_id, item_id: item.id)
          if mode == :inherit, do: true = is_nil(overlay), else: true = overlay.mode == mode
          true = Corpus.get_item_by_key!(item.key).body == item.body
        end,
        no_cleanup
      )
    end

    user =
      Repo.get_by(Corpus.User, email: "actions-benchmark@example.test") ||
        Narrative.create_user!(%{
          name: "Synthetic benchmark candidate",
          email: "actions-benchmark@example.test"
        })

    profile |> Ecto.Changeset.change(user_id: user.id) |> Repo.update!()
    narrative_body = String.duplicate("Private synthetic systems engineering narrative. ", 40)
    Narrative.write!(user, narrative_body)

    measure(
      "Narrative",
      "save_private",
      n,
      fn i ->
        {Narrative.get_by_user(user.id).version, narrative_body <> Integer.to_string(i)}
      end,
      fn {_, body} -> Narrative.write!(user, body) end,
      fn result, {version, body} ->
        true = result.version == version + 1 and result.body == body and result.private
        true = Narrative.for_profile(Corpus.get_profile!(profile.id)).body == body
        true = Narrative.for_application(result) == nil
      end,
      no_cleanup,
      %{body_base_bytes: byte_size(narrative_body), body_suffix: "decimal sample index"}
    )

    for kind <- [:existing, :new] do
      slug = "actions-benchmark-#{kind}"

      gym_attrs = %{
        "title" => "Synthetic graph traversal",
        "slug" => slug,
        "topic" => "graphs",
        "outcome" => "solved",
        "minutes" => "25"
      }

      Repo.delete_all(from p in Gym.Problem, where: p.slug == ^slug)

      if kind == :existing do
        rep = ok(Gym.log(gym_attrs))
        Repo.delete!(rep)
      end

      measure(
        "Gym",
        "log_#{kind}_problem",
        n,
        no_prepare,
        fn _ -> Gym.log(gym_attrs) end,
        fn result, _ ->
          rep = ok(result)
          true = rep.problem.slug == slug and rep.outcome == :solved and rep.minutes == 25
          true = Repo.get!(Gym.Rep, rep.id).problem_id == rep.problem_id
        end,
        fn result, _ ->
          rep = ok(result)
          Repo.delete!(rep)
          if kind == :new, do: Repo.delete!(rep.problem)
        end
      )

      Repo.delete_all(from p in Gym.Problem, where: p.slug == ^slug)
    end

    measure(
      "Gym",
      "set_target",
      n,
      fn _ -> ok(Gym.set_target(3)) end,
      fn _ -> Gym.set_target(5) end,
      fn result, _ -> true = ok(result) == 5 and Gym.target() == 5 end,
      no_cleanup
    )

    for kind <- ["draft", "post"] do
      measure(
        "Net",
        "log_#{if kind == "post", do: "shipped", else: "draft"}",
        n,
        no_prepare,
        fn _ ->
          Net.log(%{
            "kind" => kind,
            "title" => "Synthetic benchmark entry",
            "body" => "No external post is sent",
            "url" => "https://example.test/post"
          })
        end,
        fn result, _ ->
          entry = ok(result)
          true = Atom.to_string(entry.kind) == kind
          true = Repo.get!(Net.Entry, entry.id).body == "No external post is sent"

          true =
            if kind == "draft",
              do: is_nil(entry.shipped_on),
              else: entry.shipped_on == Date.utc_today()
        end,
        fn result, _ -> Repo.delete!(ok(result)) end
      )
    end

    measure(
      "Net",
      "set_lane",
      n,
      fn _ -> ok(Net.set_lane("https://example.test/before")) end,
      fn _ -> Net.set_lane("https://example.test/bench-lane") end,
      fn result, _ ->
        true =
          ok(result) == "https://example.test/bench-lane" and
            Net.lane() == "https://example.test/bench-lane"
      end,
      no_cleanup
    )

    measure(
      "KV",
      "put_existing",
      n,
      fn _ -> Kv.put("bench:actions", "value", "before") end,
      fn _ -> Kv.put("bench:actions", "value", "after") end,
      fn result, _ ->
        true = result.value == "after" and Kv.get("bench:actions", "value").value == "after"
      end,
      no_cleanup
    )

    batch =
      Repo.get_by(Batch, code: "Actions-Batch-999") ||
        %Batch{} |> Batch.changeset(%{code: "Actions-Batch-999", ordinal: 999}) |> Repo.insert!()

    measure(
      "Campaign",
      "batch_open_fire",
      n,
      fn _ ->
        Repo.get!(Batch, batch.id)
        |> Ecto.Changeset.change(fire: :hold, status: :fire_ready)
        |> Repo.update!()
      end,
      fn _ -> Desk.name_open_fire(batch.code) end,
      fn result, _ ->
        true = ok(result).fire == :open_fire and Repo.get!(Batch, batch.id).status == :open_fire
      end,
      no_cleanup
    )

    measure(
      "Letterbox",
      "claim",
      n,
      no_prepare,
      fn _ -> Letterbox.claim(job.id) end,
      fn result, _ ->
        ok(result)
        true = MapSet.member?(Letterbox.leased_jobs(), job.id)
      end,
      fn result, _ -> :ok = Letterbox.release(ok(result)) end
    )

    # A lease's write: the holder runs the op through the sequencer.
    measure(
      "Letterbox",
      "op_score_commit",
      n,
      fn _ ->
        reset_job(job.id, %{score_100: 40})
        ok(Letterbox.claim(job.id))
      end,
      fn _pair ->
        op = %{op_id: System.unique_integer([:positive]), kind: :score, target: job.id, fields: ["82"]}
        {:ok, _rev} = Hireme.Ops.run(Repo.account_id!(), op)
        {:ok, Repo.get!(Job, job.id)}
      end,
      fn result, _ -> assert_job(result, job.id, %{score_100: 82}) end,
      fn _, pair -> :ok = Letterbox.release(pair) end
    )

    measure(
      "Letterbox",
      "release",
      n,
      fn _ -> ok(Letterbox.claim(job.id)) end,
      &Letterbox.release/1,
      fn result, _ ->
        :ok = result
        false = MapSet.member?(Letterbox.leased_jobs(), job.id)
      end,
      no_cleanup
    )

    for count <- [1, 55], mode <- [:new, :update, :idempotent] do
      import_prefix = @prefix <> "import #{count} "
      code = "Actions-Import-#{count}"
      cleanup_import(import_prefix, code)
      body = import_body(count, code, import_prefix)
      if mode != :new, do: ok(Import.import_body(body, "synthetic.json", profile))

      measure(
        "Import",
        "batch_#{mode}_#{count}_apps",
        if(count == 55, do: batch_n, else: n),
        fn _ ->
          if mode == :update,
            do:
              Repo.update_all(from(j in Job, where: like(j.company, ^(import_prefix <> "%"))),
                set: [role: "Prior role"]
              )

          nil
        end,
        fn _ -> Import.import_body(body, "synthetic.json", profile) end,
        fn result, _ ->
          report = ok(result)
          true = report.kind == :apps and report.count == count
          rows = Repo.all(from j in Job, where: like(j.company, ^(import_prefix <> "%")))
          true = length(rows) == count

          true =
            Enum.all?(
              rows,
              &(&1.role == "Systems engineer" and &1.current_stage == :gated and
                  &1.profile_id == profile.id)
            )

          true = Repo.get_by!(Batch, code: code).fire == :hold

          for row <- rows do
            true = CvPair.job_id(CvPair.bind!(row.id)) == row.id
          end
        end,
        fn _, _ -> if mode == :new, do: cleanup_import(import_prefix, code) end,
        %{input_bytes: byte_size(body), applications: count, batch_governance: true}
      )

      cleanup_import(import_prefix, code)
    end

    cleanup_jobs(@prefix)
    write_coverage()
  end

  defp attrs(profile, company, suffix) do
    %{
      profile_id: profile.id,
      company: @prefix <> company,
      role: "Systems engineer",
      canonical_url: "https://actions.example.test/" <> suffix,
      stage: :discovered,
      listing: "Elixir systems runtime databases",
      theme: %{targets: ["elixir", "systems"], density: "tight", accent: "signal"}
    }
  end

  defp import_body(count, code, prefix) do
    Jason.encode!(%{
      batch: code,
      fire: "hold",
      status: "draft_prep",
      queued_on: "2026-10-09",
      target_size: count,
      apps:
        for(
          i <- 1..count,
          do: %{
            company: prefix <> Integer.to_string(i),
            role: "Systems engineer",
            location: "Remote",
            url: "https://actions-import-#{count}-#{i}.example.test/role",
            stage: "gated",
            gate: "pursue",
            freshness: "open"
          }
        )
    })
  end

  defp reset_job(id, attrs),
    do: Repo.get!(Job, id) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp reset_stage(id, stage) do
    prune_events(id)

    reset_job(id, %{
      current_stage: stage,
      pips: Pipeline.encode(Pipeline.initial(stage)),
      heat_override: false,
      heat_override_reason: ""
    })
  end

  defp prune_events(id), do: Repo.delete_all(from e in Event, where: e.job_app_id == ^id)

  defp cleanup_jobs(prefix) do
    pattern = prefix <> "%"
    Repo.delete_all(from j in Job, where: like(j.company, ^pattern))
    Repo.delete_all(from e in Employer, where: like(e.name, ^pattern))
  end

  defp cleanup_import(prefix, code) do
    cleanup_jobs(prefix)
    Repo.delete_all(from b in Batch, where: b.code == ^code)
  end

  defp assert_job(result, id, attrs) do
    job = ok(result)
    true = job.id == id
    persisted = Repo.get!(Job, id)

    Enum.each(attrs, fn {key, value} ->
      true = Map.fetch!(job, key) == value and Map.fetch!(persisted, key) == value
    end)
  end

  defp ok({:ok, value}), do: value
  defp ok(other), do: raise("operation did not succeed: #{inspect(other)}")

  defp positive_env(key, default) do
    n = System.get_env(key, default) |> String.to_integer()
    true = n > 0
    n
  end

  defp measure(page, interaction, n, prepare, operation, validate, cleanup, metadata \\ %{}) do
    full = "Domain/" <> page <> "/" <> interaction
    only = System.get_env("BENCH_ONLY", "")
    selected = only == "" or String.contains?(full, only)

    Process.put(:coverage, [
      %{
        page: "Domain/" <> page,
        interaction: interaction,
        status: if(selected, do: "measured", else: "filtered_by_BENCH_ONLY")
      }
      | Process.get(:coverage)
    ])

    if selected do
      for i <- -20..-1 do
        arg = prepare.(i)
        result = operation.(arg)
        validate.(result, arg)
        cleanup.(result, arg)
      end

      :erlang.garbage_collect()

      samples =
        for i <- 0..(n - 1) do
          arg = prepare.(i)
          started = System.monotonic_time()
          result = operation.(arg)
          elapsed = System.monotonic_time() - started
          validate.(result, arg)
          cleanup.(result, arg)
          System.convert_time_unit(elapsed, :native, :nanosecond) / 1_000_000
        end

      arg = prepare.(n)
      counter = :atomics.new(1, [])
      handler = {__MODULE__, make_ref()}
      :ok = :telemetry.attach(handler, [:hireme, :repo, :query], &__MODULE__.query/4, counter)

      {result, queries} =
        try do
          result = operation.(arg)
          {result, :atomics.get(counter, 1)}
        after
          :telemetry.detach(handler)
        end

      validate.(result, arg)
      cleanup.(result, arg)
      sorted = Enum.sort(samples)
      percentile = fn p -> Enum.at(sorted, max(0, ceil(n * p) - 1)) end

      row =
        Map.merge(
          %{
            page: "Domain/" <> page,
            interaction: interaction,
            rev: System.fetch_env!("BENCH_REV"),
            n: length(samples),
            mean: Enum.sum(samples) / length(samples),
            p0_1: percentile.(0.001),
            p1: percentile.(0.01),
            p50: percentile.(0.5),
            p99: percentile.(0.99),
            p99_9: percentile.(0.999),
            samples: samples,
            layer: "domain",
            queries: queries,
            query_scope:
              "all Repo processes; separate untimed operation; includes BEGIN/COMMIT; excludes preparation/assertions/cleanup",
            schedulers: :erlang.system_info(:schedulers_online),
            warmup: 20,
            unit: "ms",
            fixture: Process.get(:sizes),
            profile_items: Process.get(:profile_items),
            profile_item_body_bytes: Process.get(:profile_item_bytes)
          },
          metadata
        )

      File.write!(System.fetch_env!("BENCH_OUTPUT"), Jason.encode!(row) <> "\n", [:append])
      IO.puts(Jason.encode!(Map.delete(row, :samples)))
    end
  end

  def query(_event, _measurements, _metadata, counter), do: :atomics.add(counter, 1, 1)

  defp sizes do
    Map.new(
      [
        Job,
        Corpus.Profile,
        Corpus.Item,
        Corpus.Narrative,
        Employer,
        Batch,
        Gym.Problem,
        Gym.Rep,
        Net.Entry
      ],
      fn schema -> {schema.__schema__(:source), Repo.aggregate(schema, :count)} end
    )
  end

  defp write_coverage do
    coverage = %{
      rev: System.fetch_env!("BENCH_REV"),
      rows: Enum.reverse(Process.get(:coverage)),
      fixture: Process.get(:sizes),
      mail: "Swoosh.Adapters.Test; explicitly synthetic, excludes all provider transport latency",
      included_modules: %{
        Desk: "committed add, score, next, note, stage, overlay, open fire",
        Corpus:
          "profile/items read by CV operations; local synthetic user bound to existing profile",
        CvPair: "real shared lineage binding, verification and tailoring",
        Narrative: "private versioned save",
        Gym: "existing/new problem logging and target",
        Net: "draft/shipped local records and lane",
        Kv: "upsert",
        Import: "new/update/idempotent batches of 1 and 55; includes governance",
        Letterbox: "real actor claim, committed command, release",
        Pipeline: "stage transitions",
        LifeEv: "scored job creation",
        Mask: "all four modes through shared-lineage writes",
        Theme: "themed job creation and CV refresh"
      },
      unsupported: [
        %{
          interaction: "external_mail_delivery",
          reason: "No real mail; provider latency is intentionally excluded."
        },
        %{
          interaction: "external_job_submission",
          reason:
            "Desk stage/open-fire records do not submit to an external ATS; no remote credentials or side effects."
        },
        %{
          interaction: "external_social_shipping",
          reason: "Net.log records a shipped post locally; it does not publish to X/Broadside."
        },
        %{
          interaction: "CvPair.open_generation",
          reason:
            "90-day generation transition is not a normal mask write; additive/cooldown guards remain enabled and are not bypassed."
        },
        %{
          interaction: "pure_helper_microbenchmarks",
          reason:
            "Pipeline/LifeEv/Mask/Theme are exercised by end-to-end domain operations; redundant isolated timings omitted."
        }
      ]
    }

    File.write!(
      System.fetch_env!("BENCH_OUTPUT") <> ".coverage.json",
      Jason.encode!(coverage, pretty: true)
    )
  end
end

HiremeBench.Actions.run()
