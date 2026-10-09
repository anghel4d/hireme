defmodule Hireme.DeskTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Event
  alias Hireme.Desk.Filters
  alias Hireme.Repo

  test "glance numbers follow the mask, and the root text stays put" do
    profile = profile()

    experience =
      item(profile, %{title: "Engineer", body: "An entity store laid out as structure-of-arrays."})

    education =
      item(profile, %{kind: :education, title: "DEC", body: "Theatre elective.", position: 2})

    job =
      job(profile, %{
        id: 14_413,
        company: "Lumen Field",
        role: "Runtime engineer",
        stage: "fire_ready",
        listing: "columnar ECS and a theatre program",
        theme: %{"targets" => ["ecs", "theatre"], "density" => "tight", "accent" => "signal"},
        overlays: [
          %{
            item_id: experience.id,
            mode: :altered,
            body: "A columnar ECS.",
            reason: "their word"
          },
          %{item_id: education.id, mode: :hidden, reason: "noise"}
        ]
      })

    assert job.keyword_hits == 1
    assert job.keyword_total == 2
    assert job.mask_altered == 1
    assert job.mask_hidden == 1
    assert job.current_stage == :fire_ready
    assert job.pips == "DDDDDAPPPP"

    focus = Desk.focus(14_413)
    assert focus.cv.label == "CV14413"
    assert focus.coverage.hits == ["ecs"]
    assert focus.coverage.misses == ["theatre"]
    assert focus.root_coverage.hits == ["theatre"]
    assert focus.root_coverage.misses == ["ecs"]
    assert Enum.any?(focus.cv.hidden, &(&1.body == "Theatre elective."))
    refute Enum.any?(focus.cv.sections |> Enum.flat_map(& &1.lines), &(&1.body =~ "Theatre"))

    root = Desk.root(profile.id)
    lines = Enum.flat_map(root.cv.sections, & &1.lines)
    assert root.cv.label == "Root"
    assert Enum.any?(lines, &(&1.body =~ "Theatre"))
    assert Enum.any?(lines, &(&1.body =~ "structure-of-arrays"))
  end

  test "a bare opening returns the persisted glance using its newly stored lineage theme" do
    profile = profile()
    item(profile, %{body: "Elixir systems"})

    added =
      job(profile, %{
        company: "New themed employer",
        listing: "databases",
        theme: %{targets: ["elixir", "databases"]},
        stage_notes: %{discovered: "Ready for review"}
      })

    assert added == Repo.get!(Hireme.Desk.Job, added.id)
    assert {added.keyword_hits, added.keyword_total} == {1, 2}
    assert {added.mask_hidden, added.mask_altered, added.mask_emphasized} == {0, 0, 0}
    assert Enum.find(Desk.rail(added), &(&1.key == :discovered)).note == "Ready for review"
    focus = Desk.focus(added.id)
    assert focus.coverage.hits == ["elixir"]
    assert focus.coverage.misses == ["databases"]
    assert focus.variant.lineage.theme == focus.variant.theme
    assert Hireme.CvPair.job_id(Hireme.CvPair.bind!(added.id)) == added.id
    assert Hireme.Letterbox.for_job(added.id).job_app_id == added.id
  end

  test "a bare opening inherits shared masks and lineage targets without rewriting a leased sibling" do
    profile = profile()
    altered = item(profile, %{body: "Original wording"})
    hidden = item(profile, %{body: "Theatre"})
    emphasized = item(profile, %{body: "Systems"})

    first =
      job(profile, %{
        company: "Inherited employer",
        theme: %{targets: ["elixir", "theatre", "systems"]},
        overlays: [
          %{item_id: altered.id, mode: :altered, body: "Elixir"},
          %{item_id: hidden.id, mode: :hidden},
          %{item_id: emphasized.id, mode: :emphasized}
        ]
      })

    {:ok, lease} = Hireme.Letterbox.lease(Hireme.Letterbox.for_job(first.id).id, self())

    try do
      added =
        job(profile, %{
          company: "Inherited employer",
          listing: "unmatched",
          theme: %{targets: ["unmatched"]}
        })

      assert added == Repo.get!(Hireme.Desk.Job, added.id)
      assert {added.keyword_hits, added.keyword_total} == {2, 3}
      assert {added.mask_hidden, added.mask_altered, added.mask_emphasized} == {1, 1, 1}
      assert Repo.get!(Hireme.Desk.Job, first.id) == first
      focus = Desk.focus(added.id)
      original = Desk.focus(first.id)
      assert focus.coverage.hits == ["elixir", "systems"]
      assert focus.coverage.misses == ["theatre"]
      assert focus.cv.sections == original.cv.sections
      assert focus.cv.hidden == original.cv.hidden
      pair = Hireme.CvPair.bind!(added.id)
      original_pair = Hireme.CvPair.bind!(first.id)
      assert Hireme.CvPair.lineage_id(pair) == Hireme.CvPair.lineage_id(original_pair)
      assert Hireme.CvPair.variant_id(pair) != Hireme.CvPair.variant_id(original_pair)
      assert {:error, :leased} = Desk.put_overlay(first.id, altered.id, %{mode: :hidden})
    after
      :ok = Hireme.Letterbox.release(lease)
    end
  end

  test "bare openings remain tenant scoped even for the same employer name" do
    profile = profile()
    own_item = item(profile, %{body: "Elixir"})

    own =
      job(profile, %{
        company: "Tenant employer",
        overlays: [%{item_id: own_item.id, mode: :hidden}]
      })

    other = Hireme.Accounts.create!(%{name: "Creation tenant"})

    foreign =
      Repo.with_account(other.id, fn ->
        other_profile = profile()
        item(other_profile, %{body: "Elixir"})
        added = job(other_profile, %{company: "Tenant employer", theme: %{targets: ["elixir"]}})
        assert added == Repo.get!(Hireme.Desk.Job, added.id)
        assert {added.keyword_hits, added.keyword_total, added.mask_hidden} == {1, 1, 0}
        added
      end)

    refute own.employer_id == foreign.employer_id
    assert Repo.get!(Hireme.Desk.Job, own.id).mask_hidden == 1
    assert Repo.get(Hireme.Desk.Job, foreign.id) == nil
  end

  test "focus keeps optional batches and the variant's original job association" do
    profile = profile()

    batch =
      %Batch{}
      |> Batch.changeset(%{code: "Focus batch", ordinal: 1})
      |> Repo.insert!()

    for batch <- [nil, batch] do
      job = job(profile, %{batch_id: batch && batch.id})
      focus = Desk.focus(job.id)

      assert focus.profile == profile
      assert focus.job.profile == profile
      assert focus.job.batch == batch
      assert focus.variant.job_app == job
      assert focus.variant.lineage.id == focus.variant.lineage_id
    end
  end

  test "focus returns only the twelve newest events and keeps application KV ordered" do
    job = job(profile())
    Hireme.Kv.put("global", "candidate", "Global Candidate")
    Hireme.Kv.put("app:#{job.id}", "zeta", "last")
    Hireme.Kv.put("app:#{job.id}", "candidate", "Application Metadata")
    Hireme.Kv.put("app:#{job.id}", "alpha", "first")

    events =
      for i <- 1..15 do
        %Event{}
        |> Event.changeset(%{job_app_id: job.id, kind: "note", body: "Event #{i}"})
        |> Repo.insert!()
      end

    focus = Desk.focus(job.id)
    assert focus.events == events |> Enum.reverse() |> Enum.take(12)
    assert Enum.map(focus.kv, & &1.key) == ["alpha", "candidate", "zeta"]
    assert focus.cv.person == "Global Candidate"
  end

  test "focus hides foreign and missing jobs but still refuses a missing variant" do
    own_job = job(profile())
    foreign_account = Hireme.Accounts.create!(%{name: "Other focus desk"})

    foreign_job =
      Repo.with_account(foreign_account.id, fn ->
        job(profile(), %{company: "Foreign Co"})
      end)

    assert Desk.focus(nil) == nil
    assert Desk.focus(-1) == nil
    assert Desk.focus(foreign_job.id) == nil
    assert Desk.focus(own_job.id).job.id == own_job.id
    assert Repo.with_account(foreign_account.id, fn -> Desk.focus(own_job.id) end) == nil

    Repo.delete_all(from v in Hireme.Desk.Variant, where: v.job_app_id == ^own_job.id)
    assert_raise Ecto.NoResultsError, fn -> Desk.focus(own_job.id) end
  end

  test "an opening casts wire strings once and refuses an unknown stage" do
    profile = profile()

    assert {:ok, job} =
             Desk.create_job(%{
               profile_id: profile.id,
               company: "Cast Co",
               role: "Engineer",
               stage: "gated",
               freshness: "open",
               gate: :pursue
             })

    assert job.current_stage == :gated
    assert job.freshness == :open
    assert job.pips == "DDAPPPPPPP"

    assert {:error, %Ecto.Changeset{}} =
             Desk.create_job(%{
               profile_id: profile.id,
               company: "Cast Co",
               role: "x",
               stage: "sent"
             })

    assert {:ok, noted} = Desk.set_note(job.id, :gated, "Pursue: strong fit")
    assert Enum.find(Desk.rail(noted), &(&1.key == :gated)).note == "Pursue: strong fit"
  end

  test "a submit stays locked until that batch is named open fire" do
    {:ok, batch} =
      %Batch{}
      |> Batch.changeset(%{code: "Batch-001", ordinal: 1, status: :fire_ready, fire: :hold})
      |> Repo.insert()

    job = job(profile(), %{company: "Keel Systems", stage: "fire_ready", batch_id: batch.id})

    assert {:error, :fire_hold} = Desk.set_stage(job.id, :submitted)
    assert {:error, :fire_hold} = Desk.set_stage(job.id, :open_fire)
    assert {:ok, _} = Desk.name_open_fire("Batch-001")
    assert {:ok, moved} = Desk.set_stage(job.id, :submitted)
    assert moved.current_stage == :submitted
  end

  test "cards sort by score_100 and filter by band" do
    profile = profile()
    low = job(profile, %{company: "Thin Shop", role: "CRUD intern"})
    high = job(profile, %{company: "Anthropic", role: "Systems engineer"})

    assert high.score_100 == 100
    assert low.score_100 < 20

    assert hd(Desk.list_cards(%Filters{status: :all})).id == high.id

    assert Enum.map(Desk.list_cards(%Filters{status: :all, band: :frontier}), & &1.id) == [
             high.id
           ]

    assert Enum.map(Desk.list_cards(%Filters{status: :all, min_score: 90}), & &1.id) == [high.id]
  end
end
