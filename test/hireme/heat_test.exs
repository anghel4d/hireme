defmodule Hireme.HeatTest do
  use Hireme.DataCase, async: false

  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Heat
  alias Hireme.Heat.Ats
  alias Hireme.Heat.Org
  alias Hireme.Repo

  @today ~D[2026-10-07]

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
    first = job(profile, %{company: "Obscure Shop"})
    second = job(profile, %{company: "Obscure Shop"})

    assert {:ok, _} = Desk.set_stage(first.id, :fire_ready)
    assert {:error, :heat} = Desk.set_stage(second.id, :fire_ready)

    assert {:ok, _} = Heat.set_override(second.id, "Matei said this one")
    assert {:ok, moved} = Desk.set_stage(second.id, :fire_ready)
    assert moved.current_stage == :fire_ready
  end

  test "govern_batch unassigns the lower-score role and leaves it leftover" do
    profile = profile()

    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Batch-HEAT", ordinal: 9, status: :fire_ready, fire: :hold})
      |> Repo.insert()

    hot = %{company: "Obscure Shop", stage: "fire_ready", batch_id: batch.id}
    high = job(profile, Map.put(hot, :score_100, 90))
    low = job(profile, Map.put(hot, :score_100, 40))

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
    aged = %{anonymous | stage_on: Date.add(@today, -Heat.config().company_half_life)}
    assert Heat.can_apply(anonymous, existing: [aged], today: @today).company_load == 0.5
    unknown = %{job | listing_url: "https://jobs.example.test/1"}

    assert Heat.can_apply(
             unknown,
             Keyword.put(opts, :config, %{Heat.config() | ats_batch_cap: 0})
           ).reason == :ok
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

  # The recognised vendors by a host each one owns; everything else, including
  # look-alikes past the registrable domain, is unknown and never raises.
  test "every vendor is recognised on its own host, look-alikes and junk are unknown, and no URL raises" do
    :rand.seed(:exsss, {2026, 10, 9})

    owned = [
      greenhouse: "boards.greenhouse.io",
      lever: "jobs.lever.co",
      ashby: "jobs.ashbyhq.com",
      workday: "acme.wd5.myworkdayjobs.com",
      icims: "careers-acme.icims.com",
      smartrecruiters: "jobs.smartrecruiters.com",
      workable: "acme.workable.com",
      jobvite: "jobs.jobvite.com",
      taleo: "acme.taleo.net",
      successfactors: "acme.successfactors.eu",
      bamboohr: "acme.bamboohr.com",
      rippling: "ats.rippling.com",
      eightfold: "acme.eightfold.ai",
      gem: "gem.com"
    ]

    vendors = Keyword.keys(owned) ++ [:unknown]

    for {vendor, host} <- owned do
      assert %{vendor: ^vendor} = Ats.parse("https://#{host}/acme/jobs/1"), host

      assert %{vendor: :unknown, tenant: nil} =
               Ats.parse("https://#{host}.evil.test/acme/jobs/1"),
             host
    end

    junk = [
      "",
      " ",
      "not a url",
      "https://",
      "mailto:x@y",
      "https://jobs.example.test/plain",
      nil,
      7,
      %{},
      ["https://gem.com"]
    ]

    hosts = Keyword.values(owned) ++ ["example.test", "jobs.example.test", "localhost"]

    for _ <- 1..300 do
      url =
        Enum.random([
          Enum.random(junk),
          "#{Enum.random(["https", "http", "ftp"])}://#{Enum.random(["", "x.", "a.b."])}#{Enum.random(hosts)}#{Enum.random(["", "/", "/#{:rand.uniform(99)}", "/Acme/jobs/1", "/?q=1"])}",
          Enum.map_join(1..:rand.uniform(40), "", fn _ ->
            Enum.random(String.graphemes("abc./:?#%-_ é"))
          end)
        ])

      assert %{vendor: vendor, tenant: tenant} = Ats.parse(url)

      assert vendor in vendors and
               (is_nil(tenant) or
                  (is_binary(tenant) and tenant == String.downcase(tenant) and tenant != "")),
             inspect(url)
    end
  end
end
