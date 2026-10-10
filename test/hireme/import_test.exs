defmodule Hireme.ImportTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk.Batch
  alias Hireme.Desk.Employer
  alias Hireme.Desk.Job
  alias Hireme.Desk.Snapshot
  alias Hireme.Import
  alias Hireme.Repo

  test "a leftover table imports once per canonical URL" do
    profile = profile()

    table = """
    | Company | Role | Location | Fit | Source | URL |
    | --- | --- | --- | --- | --- | --- |
    | Keel Systems | Runtime engineer | Remote | systems | ashby | https://jobs.example.test/keel |
    """

    assert {:ok, %{kind: :apps, count: 1}} = Import.import_body(table, "leftover.md", profile)
    assert {:ok, %{count: 1}} = Import.import_body(table, "leftover.md", profile)
    assert Repo.aggregate(Job, :count) == 1

    job = Repo.get_by!(Job, canonical_url: "https://jobs.example.test/keel")
    assert job.company == "Keel Systems"
    assert job.gate == :pursue
    assert job.fit == "systems"
    assert job.current_stage == :gated
  end

  test "canonical import lookups isolate matching employer names and URLs by account" do
    first_profile = profile()
    first_account = Repo.account_id!()
    body = ~s({"apps":[{"company":"Same name","url":"https://jobs.example.test/same"}]})
    assert {:ok, %{count: 1}} = Import.import_body(body, "same.json", first_profile)
    first_job = Repo.one!(Job)

    Hireme.DataCase.open_account("Other import")
    second_profile = profile()

    for _ <- 1..2 do
      assert {:ok, %{count: 1}} = Import.import_body(body, "same.json", second_profile)
    end

    second_job = Repo.one!(Job)
    assert second_job.id != first_job.id
    assert second_job.employer_id != first_job.employer_id
    assert second_job.account_id == Repo.account_id!()
    assert Repo.with_account(first_account, fn -> Repo.one!(Job) end) == first_job
  end

  test "a later blank URL does not match an unkeyed job or roll back earlier applications" do
    profile = profile()
    unkeyed = job(profile, %{company: "Unkeyed", canonical_url: ""})

    body = """
    {"apps":[
      {"company":"Committed first","url":"https://jobs.example.test/committed"},
      {"company":"Rejected second","url":"   "}
    ]}
    """

    assert_raise ArgumentError, fn ->
      Import.import_body(body, "partial.json", profile)
    end

    assert Repo.get_by!(Job, canonical_url: "https://jobs.example.test/committed")
    assert Repo.get_by!(Employer, name: "Committed first")
    assert Repo.get!(Job, unkeyed.id).company == "Unkeyed"
    assert Repo.aggregate(Job, :count) == 2
    refute Repo.get_by(Employer, name: "Rejected second")
  end

  test "a snapshot and a day pack import as rows, and the pack stays on HOLD" do
    profile = profile()

    snapshot =
      ~s({"noted_on":"2026-10-06","leftover_unique":2337,"target_total":10000,"target_on":"2026-10-31","daily_batches":8,"daily_apps":440})

    assert {:ok, %{kind: :snapshot}} = Import.import_body(snapshot, "scoreboard.json", profile)

    pack = """
    {"batch":"Batch-001","status":"fire_ready","fire":"hold","queued_on":"2026-10-06","squad":"red","apps":[
      {"company":"Lantern Agents","role":"Agent systems","location":"Remote · EU","fit":"agentic","source":"sample-pack","url":"https://jobs.example.test/lantern/1","freshness":"open","gate":"pursue","stage":"fire_ready"},
      {"company":"Redcedar Runtime","role":"Rust engineer","location":"Cluj-Napoca","fit":"rust","source":"sample-pack","url":"https://jobs.example.test/redcedar/2","freshness":"open","gate":"pursue","stage":"submitted"}
    ]}
    """

    assert {:ok, %{count: 2}} = Import.import_body(pack, "batch-001.json", profile)

    held = Repo.get_by!(Job, canonical_url: "https://jobs.example.test/redcedar/2")
    assert held.current_stage == :fire_ready

    snapshot = Repo.one!(Snapshot)
    assert {snapshot.noted_on, snapshot.leftover_unique} == {~D[2026-10-06], 2337}
    assert {snapshot.daily_batches, snapshot.daily_apps} == {8, 440}

    batch = Repo.get_by!(Batch, code: "Batch-001")
    assert {batch.status, batch.fire, batch.queued_on} == {:fire_ready, :hold, ~D[2026-10-06]}
    assert Enum.count(Repo.all(Job), &(&1.batch_id == batch.id)) == 2
  end
end
