defmodule Hireme.Seed do
  @moduledoc """
  DESERT STORM sample desk for Matei Anghel / Red cabal.

  The sample is a thin stand-in: Batch-001 has 55 fire-ready cards on
  HOLD, batches 002–008 are locked shells, 009–010 are draft prep, and a
  handful of leftover pursue cards stand in for the 2337-URL snapshot.
  Import the real `red/` packs to replace the sample URLs.
  """

  import Ecto.Query
  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Batch
  alias Hireme.Desk.Job
  alias Hireme.Desk.Variant
  alias Hireme.Import
  alias Hireme.Kv
  alias Hireme.Narrative
  alias Hireme.Repo

  @sample ~w(
    scoreboard.json
    batches.json
    batch-001.json
    leftover-pursue.md
    universe-gaps-batch1-freshness.md
    linkedin.json
    claims.json
  )

  def run do
    if Desk.batch_exists?("Batch-001") do
      IO.puts("DESERT STORM already seeded. mix ecto.reset to start over.")
      :already_seeded
    else
      profile = corpus!()
      dir = sample_dir()

      Enum.each(@sample, fn file ->
        {:ok, _} = Import.import_path(Path.join(dir, file), profile: profile)
      end)

      tailor!()
      IO.puts("DESERT STORM sample desk. FIRE HOLD. Batch-001 is fire-ready and locked.")
      :ok
    end
  end

  def flood(0), do: 0

  def flood(n) when is_integer(n) and n > 0 do
    profile = Repo.get_by(Hireme.Corpus.Profile, slug: "matei") || hd(Corpus.list_profiles())
    start = max(Repo.aggregate(Job, :max, :id) || 0, 19_999) + 1

    Enum.each(0..(n - 1), fn i ->
      id = start + i

      Desk.create_job!(%{
        id: id,
        profile_id: profile.id,
        company: "Flood #{rem(i, 40)}",
        role: "Systems engineer",
        location: "Remote",
        stage: "discovered",
        heat: rem(i, 5) + 1,
        fit: "systems",
        gate: :pursue,
        freshness: :open,
        canonical_url: "https://jobs.example.test/flood/#{id}",
        listing_url: "https://jobs.example.test/flood/#{id}",
        source: "flood"
      })
    end)

    n
  end

  defp corpus! do
    user =
      Narrative.create_user!(%{
        name: "Matei Anghel",
        email: "matei3d@gmail.com"
      })

    Narrative.write!(user, Narrative.seed_body())

    profile =
      Corpus.create_profile!(%{
        slug: "matei",
        name: "Matei Anghel",
        headline: "Systems engineer, agentic tooling",
        summary:
          "Out of self-employment. The game work was tumultuous, so the hunt broadens. Anoptic is the systems depth: a data-oriented engine, not an apology.",
        user_id: user.id
      })

    Enum.each(items(profile.id), &Corpus.create_item!/1)

    %Variant{}
    |> Variant.changeset(%{
      profile_id: profile.id,
      label: "Root",
      theme: %{"accent" => "ink", "density" => "cv"},
      note: "Thin root until red/CV.md is imported. Password is never stored."
    })
    |> Repo.insert!()

    Kv.put("global", "candidate", "Matei Anghel")
    Kv.put("global", "cabal", "red")
    Kv.put("global", "campaign", "DESERT STORM")
    Kv.put("global", "email", "matei3d@gmail.com")
    Kv.put("global", "citizenship", "CA + RO (EU)")
    profile
  end

  defp items(profile_id) do
    [
      item(nil, :fact, "fact.email", "Email", "matei3d@gmail.com", "", "", 10),
      item(nil, :fact, "fact.auth", "Citizenship", "Canada and Romania (EU)", "", "", 11),
      item(nil, :fact, "fact.location", "Location", "Remote, and open to relocation", "", "", 12),
      item(
        profile_id,
        :experience,
        "exp.anoptic",
        "Systems",
        "Self-employed work on Anoptic, a data-oriented engine. Rust and C++ where the layout matters. The game-shaped years around it were tumultuous. The depth is the engine.",
        "Self-employed",
        "ongoing",
        20
      ),
      item(
        profile_id,
        :experience,
        "exp.broadside",
        "Builder",
        "Broadside Observer, the garden, and the agent harness. Research radar, then a desk that can hold a campaign.",
        "Broadside",
        "2026",
        21
      ),
      item(
        profile_id,
        :project,
        "proj.anoptic",
        "Anoptic",
        "Data-oriented engine work. Systems depth, stated as the work itself.",
        "",
        "",
        30
      ),
      item(
        profile_id,
        :skill,
        "skill.core",
        "Stack",
        "Rust, C++, Elixir, SQLite, systems programming, agentic tooling.",
        "",
        "",
        40
      )
    ]
  end

  defp item(profile_id, kind, key, title, body, org, span, position) do
    %{
      profile_id: profile_id,
      kind: kind,
      key: key,
      title: title,
      body: body,
      org: org,
      span: span,
      position: position,
      keywords: []
    }
  end

  defp tailor! do
    batch = Repo.get_by!(Batch, code: "Batch-001")
    job = Repo.one!(from j in Job, where: j.batch_id == ^batch.id, order_by: j.id, limit: 1)
    item = Corpus.get_item_by_key!("exp.anoptic")

    Desk.put_overlay(job.id, item.id, %{
      mode: :altered,
      body:
        "Anoptic is the systems depth: a data-oriented engine in Rust and C++, built while self-employed. The hunt broadens past a tumultuous game stretch. This line leads with the runtime.",
      reason: "Batch-001 systems/Rust framing. Same work."
    })

    %Variant{id: variant_id} = Repo.get_by!(Variant, job_app_id: job.id)

    variant = Repo.get!(Variant, variant_id)

    variant
    |> Variant.changeset(%{
      theme:
        Map.merge(variant.theme || %{}, %{
          "density" => "tight",
          "accent" => "signal",
          "targets" => ["rust", "systems", "remote", "engine"],
          "lead" =>
            "Systems engineer. Anoptic is the depth. Remote, and open to relocation in Canada or the EU.",
          "lead_reason" => "Fit line for a systems pack."
        })
    })
    |> Repo.update!()

    Desk.refresh_glance!(job.id)
  end

  defp sample_dir do
    Path.join(:code.priv_dir(:hireme), "desert_storm/sample")
  end
end
