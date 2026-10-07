defmodule Hireme.DeskTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Batch
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
