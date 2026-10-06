defmodule HiremeWeb.BoardLiveTest do
  use HiremeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Seed

  test "cards take focus, and the battleplan shows the masked CV", %{conn: conn} do
    {job, experience, education} = sample_job()

    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#card-#{job.id}.is-active")
    assert has_element?(view, "#focus", "Lumen Field")

    html = render_keydown(view, "key", %{"key" => "Enter"})
    assert html =~ "battleplan"
    assert has_element?(view, "#battleplan")
    assert html =~ "columnar ECS"
    assert html =~ "Masked out"
    assert html =~ "Theatre elective"

    render_click(view, "set_mask", %{"item" => education.id, "mode" => "inherit"})
    restored = render(view)
    refute restored =~ "Masked out"
    assert restored =~ "Theatre elective"

    render_click(view, "set_mask", %{"item" => experience.id, "mode" => "hidden"})
    hidden = render(view)
    refute hidden =~ "columnar ECS"
    assert hidden =~ "structure-of-arrays"
  end

  test "escape clears a search, including from the search field", %{conn: conn} do
    profile = profile()

    alpha =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Alpha",
        role: "Runtime",
        heat: 5,
        stage: "recon"
      })

    glass =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Glass Orchard",
        role: "Scientist",
        heat: 4,
        stage: "recon"
      })

    {:ok, view, _html} = live(conn, "/")

    render_change(view, "filter", %{
      "q" => "Glass",
      "stage" => "all",
      "profile" => "all",
      "status" => "open"
    })

    assert has_element?(view, "#card-#{glass.id}")
    refute has_element?(view, "#card-#{alpha.id}")

    render_keydown(view, "key", %{"key" => "Escape", "typing" => true, "field" => "q"})
    assert has_element?(view, "#card-#{alpha.id}")
    assert has_element?(view, "#card-#{glass.id}")
  end

  test "l moves to the next card on the row", %{conn: conn} do
    profile = profile()

    alpha =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Alpha",
        role: "Runtime",
        heat: 5,
        stage: "recon"
      })

    bravo =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Bravo",
        role: "Tools",
        heat: 2,
        stage: "recon"
      })

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#card-#{alpha.id}.is-active")

    render_keydown(view, "key", %{"key" => "l"})
    assert has_element?(view, "#card-#{bravo.id}.is-active")
  end

  test "the grid paints a window when the desk is large", %{conn: conn} do
    profile()

    Corpus.create_item!(%{
      profile_id: hd(Corpus.list_profiles()).id,
      kind: :fact,
      key: "fact.one",
      title: "Location",
      body: "Montréal",
      position: 1
    })

    assert Seed.flood(40) == 40

    {:ok, view, html} = live(conn, "/")
    painted = length(Regex.scan(~r/id="card-/, html))

    assert painted > 0
    assert painted < 40
    assert has_element?(view, "#grid")
  end

  defp profile do
    Corpus.create_profile!(%{
      slug: "systems",
      name: "Systems",
      headline: "Runtime",
      summary: "Plain data."
    })
  end

  defp sample_job do
    profile = profile()

    experience =
      Corpus.create_item!(%{
        profile_id: profile.id,
        kind: :experience,
        key: "exp.tick",
        title: "Engineer",
        body: "An entity store laid out as structure-of-arrays.",
        org: "Northwind",
        span: "2023 — 2026",
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
        profile_id: profile.id,
        company: "Lumen Field",
        role: "Runtime engineer",
        stage: "screen",
        heat: 5,
        theme: %{"targets" => ["ecs", "theatre"]},
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

    {job, experience, education}
  end
end
