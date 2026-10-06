defmodule Hireme.DeskTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus
  alias Hireme.Desk

  test "glance numbers follow the mask, and the root text stays put" do
    profile =
      Corpus.create_profile!(%{
        slug: "systems",
        name: "Systems",
        headline: "Runtime",
        summary: "Plain data and explicit schedules."
      })

    experience =
      Corpus.create_item!(%{
        profile_id: profile.id,
        kind: :experience,
        key: "exp.tick",
        title: "Engineer",
        body: "An entity store laid out as structure-of-arrays.",
        position: 1
      })

    education =
      Corpus.create_item!(%{
        profile_id: profile.id,
        kind: :education,
        key: "edu.general",
        title: "DEC",
        body: "Theatre elective.",
        position: 2
      })

    job =
      Desk.create_job!(%{
        id: 14_413,
        profile_id: profile.id,
        company: "Lumen Field",
        role: "Runtime engineer",
        stage: "screen",
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
    assert job.current_stage == "screen"
    assert job.pips == "DDDDAPPP"

    focus = Desk.focus(14_413)
    assert focus.cv.label == "CV14413"
    assert focus.coverage.hits == ["ecs"]
    assert focus.coverage.misses == ["theatre"]
    assert focus.root_coverage.hits == ["theatre"]
    assert focus.root_coverage.misses == ["ecs"]
    assert Enum.any?(focus.cv.hidden, &(&1.body == "Theatre elective."))
    refute Enum.any?(focus.cv.sections |> Enum.flat_map(& &1.lines), &(&1.body =~ "Theatre"))

    root = Desk.root(profile.id)
    assert root.cv.label == "Root"
    assert Enum.any?(root.cv.sections |> Enum.flat_map(& &1.lines), &(&1.body =~ "Theatre"))

    assert Enum.any?(
             root.cv.sections |> Enum.flat_map(& &1.lines),
             &(&1.body =~ "structure-of-arrays")
           )
  end
end
