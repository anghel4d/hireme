defmodule Hireme.HeatTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Heat
  alias Hireme.Heat.Ats
  alias Hireme.Heat.Org
  alias Hireme.Repo

  @today ~D[2026-10-07]

  test "decay halves over one half-life" do
    assert Heat.decay(1.0, 0, 35) == 1.0
    assert Heat.decay(1.0, 35, 35) == 0.5
    assert Heat.decay(1.0, 70, 35) == 0.25
  end

  test "caps scale with company size" do
    cfg = Heat.config()
    assert Org.size("Google") == :mega
    assert Org.size("Amazon") == :mega
    assert Org.size("NVIDIA") == :mega
    assert Org.size("OpenAI") == :large
    assert Org.size("Obscure Shop LLC") == :small
    assert Heat.cap("Google", cfg) == cfg.mega_cap
    assert Heat.cap("OpenAI", cfg) == cfg.large_cap
    assert Heat.cap("Obscure Shop LLC", cfg) == cfg.small_cap
  end

  test "ATS vendor and tenant come from the apply URL" do
    assert Ats.parse("https://boards.greenhouse.io/stripe/jobs/123") == %{
             vendor: :greenhouse,
             tenant: "stripe"
           }

    assert Ats.parse("https://jobs.lever.co/openai/abcd") == %{vendor: :lever, tenant: "openai"}

    assert Ats.parse("https://jobs.ashbyhq.com/anthropic/role") == %{
             vendor: :ashby,
             tenant: "anthropic"
           }

    assert Ats.parse("https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite/job/x") == %{
             vendor: :workday,
             tenant: "nvidia"
           }

    assert Ats.parse("https://careers-acme.icims.com/jobs/1") == %{vendor: :icims, tenant: "acme"}

    assert Ats.parse("https://jobs.smartrecruiters.com/Acme/123") == %{
             vendor: :smartrecruiters,
             tenant: "acme"
           }

    assert Ats.parse("https://jobs.example.test/plain") == %{vendor: :unknown, tenant: nil}

    for {url, vendor, tenant} <- [
          {"https://acme.greenhouse.net/jobs", :greenhouse, "acme"},
          {"https://greenhouse.net/acme", :unknown, nil},
          {"https://lever.co/jobs", :lever, nil},
          {"https://acme.workable.com/careers", :workable, "acme"},
          {"https://acme.taleo.net/jobs", :taleo, "acme"},
          {"https://acme.successfactors.eu/jobs", :successfactors, "acme"},
          {"https://successfactors.com/acme", :unknown, nil},
          {"https://acme.bamboohr.com/jobs", :bamboohr, "acme"},
          {"https://rippling.com/acme", :unknown, nil},
          {"https://ats.rippling.com/ACME/jobs", :rippling, "acme"},
          {"https://acme.eightfold.ai/jobs", :eightfold, "acme"},
          {"https://gem.com/jobs/ACME", :gem, "acme"},
          {"https://jobs.lever.co.evil.test/acme", :unknown, nil}
        ] do
      assert Ats.parse(url) == %{vendor: vendor, tenant: tenant}, url
    end
  end

  test "same department and cloned titles cost extra; spread does not" do
    cfg = Heat.config()

    first = probe("Google", "Staff Software Engineer", 100, 1)
    clone = probe("Google", "Senior Software Engineer", 90, 2)
    spread = probe("Google", "Staff SRE", 85, 3)

    %{kept: kept, deferred: deferred} =
      Heat.mix([first, clone, spread], existing: [], today: @today, config: cfg)

    assert Enum.map(kept, & &1.id) == [1, 2, 3]
    assert deferred == []

    fourth = probe("Google", "Software Engineer II", 70, 4)

    %{kept: kept2, deferred: deferred2} =
      Heat.mix([first, clone, spread, fourth], existing: [], today: @today, config: cfg)

    assert Enum.map(kept2, & &1.id) == [1, 2, 3]
    assert hd(deferred2) |> elem(0) |> Map.get(:id) == 4
    assert hd(deferred2) |> elem(1) |> Map.get(:reason) == :company_cap
  end

  test "the governor keeps the highest score_100 and defers the rest at a small company" do
    high = probe("Obscure Shop", "Engineer", 90, 1)
    low = probe("Obscure Shop", "Engineer", 40, 2)

    %{kept: kept, deferred: deferred} =
      Heat.mix([low, high], existing: [], today: @today)

    assert Enum.map(kept, & &1.id) == [1]
    assert hd(deferred) |> elem(0) |> Map.get(:id) == 2
    assert hd(deferred) |> elem(1) |> Map.get(:decision) == :defer
  end

  test "one batch does not slam a single ATS vendor" do
    cfg = %{Heat.config() | ats_batch_cap: 2}

    jobs =
      for i <- 1..3 do
        probe("Co #{i}", "Engineer", 80 - i, i, "https://boards.greenhouse.io/co#{i}/jobs/#{i}")
      end

    %{kept: kept, deferred: deferred} =
      Heat.mix(jobs, existing: [], today: @today, config: cfg)

    assert length(kept) == 2
    assert hd(deferred) |> elem(1) |> Map.get(:reason) == :ats_batch_cap
    assert hd(kept).score_100 >= 77
  end

  test "an explicit override with a reason is allowed through" do
    high = probe("Obscure Shop", "Engineer", 90, 1)

    low =
      Map.merge(probe("Obscure Shop", "Engineer", 40, 2), %{
        heat_override: true,
        heat_override_reason: "lab referral"
      })

    %{kept: kept, deferred: deferred} = Heat.mix([high, low], existing: [], today: @today)
    assert length(kept) == 2
    assert deferred == []
  end

  test "set_stage refuses a queue move that would exceed company heat" do
    profile = profile()

    first =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Obscure Shop",
        role: "Engineer",
        stage: "discovered",
        canonical_url: "https://jobs.example.test/obscure-1"
      })

    second =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Obscure Shop",
        role: "Engineer",
        stage: "discovered",
        canonical_url: "https://jobs.example.test/obscure-2"
      })

    assert {:ok, _} = Desk.set_stage(first.id, :fire_ready)
    assert {:error, :heat} = Desk.set_stage(second.id, :fire_ready)

    assert {:ok, _} = Heat.set_override(second.id, "Matei said this one")
    assert {:ok, moved} = Desk.set_stage(second.id, :fire_ready)
    assert moved.current_stage == :fire_ready

    snapshot = Heat.snapshot()
    assert Heat.decorate(moved, snapshot) == Heat.decorate(moved, Map.delete(snapshot, :ats))
    assert Heat.chart().companies |> Enum.any?(&(&1.n == 2))
  end

  test "govern_batch unassigns the lower-score role and leaves it leftover" do
    profile = profile()

    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Batch-HEAT", ordinal: 9, status: :fire_ready, fire: :hold})
      |> Repo.insert()

    high =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Obscure Shop",
        role: "Engineer",
        stage: "fire_ready",
        score_100: 90,
        batch_id: batch.id,
        canonical_url: "https://jobs.example.test/heat-high"
      })

    low =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Obscure Shop",
        role: "Engineer",
        stage: "fire_ready",
        score_100: 40,
        batch_id: batch.id,
        canonical_url: "https://jobs.example.test/heat-low"
      })

    result = Desk.govern_batch(batch)
    assert Enum.any?(result.kept, &(&1.id == high.id))
    assert Enum.any?(result.deferred, fn {job, _} -> job.id == low.id end)

    leftover = Repo.get!(Hireme.Desk.Job, low.id)
    assert leftover.batch_id == nil
    assert leftover.current_stage == :gated
    assert leftover.next_action =~ "HEAT DEFER"
  end

  test "can_apply reports cooldown when company heat is over cap" do
    existing = [
      Map.put(probe("Obscure Shop", "Engineer", 50, 9), :stage_on, Date.add(@today, -10))
    ]

    cand = probe("Obscure Shop", "Engineer", 90, 10)
    verdict = Heat.can_apply(cand, existing: existing, today: @today)
    assert verdict.decision == :defer
    assert verdict.reason == :company_cap
    assert is_nil(verdict.cooldown_days) or verdict.cooldown_days >= 0
  end

  test "cached mix agrees with sequential verdicts, including overrides and dated peers" do
    cfg = %{Heat.config() | ats_batch_cap: 3, ats_vendor_cap: 4.0, ats_tenant_cap: 2.0}

    jobs =
      for id <- 1..40 do
        company = Enum.at(["Google", "OpenAI", "SmallCo", "GOOGLE"], rem(id, 4))
        host = Enum.at(["jobs.lever.co", "boards.greenhouse.io", "jobs.example.test"], rem(id, 3))

        probe(
          company,
          "Engineer",
          rem(id * 13, 101),
          id,
          "https://#{host}/tenant#{rem(id, 5)}/#{id}"
        )
        |> Map.merge(%{
          stage_on: Date.add(@today, -id),
          heat_override: rem(id, 7) == 0,
          heat_override_reason: "referral"
        })
      end

    opts = [existing: Enum.take(jobs, 6), today: @today, config: cfg]

    expected =
      jobs
      |> Enum.sort_by(&{-&1.score_100, Org.company_key(&1.company), &1.id})
      |> Enum.reduce(%{kept: [], deferred: []}, fn job, acc ->
        verdict = Heat.can_apply(job, Keyword.put(opts, :batch_kept, acc.kept))

        if verdict.decision == :allow,
          do: %{acc | kept: acc.kept ++ [job]},
          else: %{acc | deferred: acc.deferred ++ [{job, verdict}]}
      end)

    assert expected.kept != [] and expected.deferred != []
    assert Heat.mix(Enum.reverse(jobs), opts) == expected
  end

  test "self IDs are excluded from loads, but still count against the batch vendor cap" do
    job = probe("Google", "Engineer", 90, 1, "https://jobs.lever.co/google/1")
    opts = [existing: [job], batch_kept: [job], today: @today]
    verdict = Heat.can_apply(job, opts)
    assert {verdict.company_load, verdict.vendor_load, verdict.tenant_load} == {0.0, 0.0, 0.0}
    assert verdict.reason == :ok

    assert Heat.can_apply(job, Keyword.put(opts, :config, %{Heat.config() | ats_batch_cap: 1})).reason ==
             :ats_batch_cap

    anonymous = %{job | id: nil}
    assert Heat.can_apply(anonymous, existing: [anonymous], today: @today).company_load == 1.0
    unknown = %{job | listing_url: "https://jobs.example.test/1"}

    assert Heat.can_apply(
             unknown,
             Keyword.put(opts, :config, %{Heat.config() | ats_batch_cap: 0})
           ).reason == :ok
  end

  test "empty heat charts and the closed heat-state parser keep their wire forms" do
    assert Heat.ascii(%Hireme.Heat.Chart{companies: [], vendors: []}) ==
             "HEAT companies\n(none)\nHEAT ATS\n(none)\nFIRE HOLD. Governor gates the queue. It does not submit."

    for state <- [:all, :cool, :warm, :hot, :blocked] do
      assert Heat.parse_state(state) == {:ok, state}
      assert Heat.parse_state(Atom.to_string(state)) == {:ok, state}
    end

    for invalid <- [nil, "", "COOL", :unknown, 1], do: assert(Heat.parse_state(invalid) == :error)
  end

  defp probe(company, role, score, id, url \\ nil) do
    %{
      id: id,
      company: company,
      role: role,
      score_100: score,
      listing_url: url || "https://jobs.example.test/#{id}",
      canonical_url: url || "https://jobs.example.test/#{id}",
      department: "",
      squad: "",
      fit: "",
      current_stage: :gated,
      stage_on: @today,
      heat_override: false,
      heat_override_reason: ""
    }
  end

  defp profile do
    Corpus.create_profile!(%{
      slug: "heat-#{System.unique_integer([:positive])}",
      name: "Heat",
      headline: "Runtime",
      summary: "A sample profile."
    })
  end
end
