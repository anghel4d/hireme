defmodule Hireme.ImportTest do
  use Hireme.DataCase, async: false

  alias Hireme.Campaign
  alias Hireme.Corpus
  alias Hireme.Desk.Job
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

  test "the scoreboard snapshot is a reading, and a day pack stays on HOLD" do
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

    board = Campaign.scoreboard(~D[2026-10-06])
    assert board.leftover_unique == 2337
    assert board.fire == :hold
    assert board.batches_today == 1
    assert board.apps_today == 2
    assert board.submitted_today == 0
    assert board.apps_target == 440
  end

  defp profile do
    Corpus.create_profile!(%{
      slug: "candidate",
      name: "Sample Candidate",
      headline: "Engineer",
      summary: "A sample profile."
    })
  end
end
