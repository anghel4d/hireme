defmodule Hireme.Seed do
  @moduledoc """
  Sample desk. Avery Quinn is a fixture, not a biography.

  JobApp14413 is the worked example: a root CV, and CV14413 with a sparse
  mask that rephrases true lines for one listing. `flood/1` fills the grid
  so the board has to window its cards.
  """

  alias Hireme.Corpus
  alias Hireme.Corpus.Profile
  alias Hireme.Desk
  alias Hireme.Desk.Event
  alias Hireme.Desk.Job
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Stage
  alias Hireme.Desk.Variant
  alias Hireme.Kv
  alias Hireme.Pipeline
  alias Hireme.Repo

  @flood_default 400

  @companies [
    "Keel & Pine",
    "Bracket Works",
    "Sable Orbit",
    "Marlowe Systems",
    "Copper Lantern",
    "Halide",
    "Quiet Vector",
    "Paper Telescope",
    "Redcedar",
    "Ion Parish",
    "Lowland",
    "Meter & Grain",
    "Falk Studio",
    "Juniper Compute",
    "Arroyo",
    "Nimbus Foundry",
    "Hollow Instrument",
    "Northline",
    "Kindling Lab",
    "Glasshouse",
    "Little Gauge",
    "Orchard Compute",
    "Field Note",
    "Second Lantern"
  ]

  @roles [
    "Runtime engineer",
    "Graphics tools",
    "Simulation engineer",
    "Platform engineer",
    "Language engineer",
    "Research engineer",
    "Build engineer",
    "Gameplay systems",
    "Data systems",
    "Infrastructure engineer"
  ]

  @actions [
    "Read the listing again",
    "Draft the variant",
    "Send the application",
    "Wait on the screen",
    "Prep the first conversation",
    "Write the thank-you",
    "Ask for the next stage"
  ]

  @pool ~w(
    columnar ecs simd replay nix telemetry vulkan schedulers sqlite
    agents traces ablation simulation elixir rust deterministic policy
  )

  def run(opts \\ []) do
    flood_n = Keyword.get(opts, :flood, @flood_default)

    if Repo.exists?(Profile) do
      IO.puts("Desk already seeded. mix ecto.reset to start over.")
      :already_seeded
    else
      {systems, research} = insert_corpus!()
      insert_showcase!(systems, research)
      n = flood(flood_n)
      IO.puts("Seeded the sample desk: JobApp14413, JobApp14414, and #{n} more.")
      :ok
    end
  end

  def flood(n) when is_integer(n) and n > 0 do
    profiles = Corpus.list_profiles()

    if profiles == [] do
      raise "seed a profile before flooding the desk"
    end

    items = Map.new(profiles, fn profile -> {profile.id, Corpus.list_items(profile.id)} end)
    start_id = max(Repo.aggregate(Job, :max, :id) || 0, 19_999) + 1
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    today = Date.utc_today()

    rows =
      Enum.map(0..(n - 1), fn i ->
        build_flood(i, start_id + i, profiles, items, now, today)
      end)

    Repo.transaction(fn ->
      insert_chunk(Job, Enum.map(rows, & &1.job))
      insert_chunk(Variant, Enum.map(rows, & &1.variant))
      insert_chunk(Stage, Enum.flat_map(rows, & &1.stages))
      insert_chunk(Overlay, Enum.flat_map(rows, & &1.overlays))
      insert_chunk(Event, Enum.map(rows, & &1.event))
    end)

    n
  end

  def flood(0), do: 0

  defp insert_corpus! do
    systems =
      Corpus.create_profile!(%{
        slug: "systems",
        name: "Systems",
        headline: "Data-oriented runtime engineer",
        summary:
          "I build simulation runtimes that stay fast when the world gets wide: explicit schedules, plain data, and tools that can rewind a bug."
      })

    research =
      Corpus.create_profile!(%{
        slug: "research",
        name: "Research",
        headline: "Research engineer, agents and simulation",
        summary:
          "I turn papers and traces into small, runnable experiments: what the agent did, why the sim diverged, and which idea is worth another week."
      })

    Enum.each(
      shared_items() ++ systems_items(systems.id) ++ research_items(research.id),
      fn attrs ->
        Corpus.create_item!(attrs)
      end
    )

    root_variant!(systems, "Canonical systems CV. No masks.")
    root_variant!(research, "Canonical research CV. No masks.")

    Kv.put("global", "candidate", "Avery Quinn")
    Kv.put("global", "desk", "sample")

    {systems, research}
  end

  defp insert_showcase!(systems, research) do
    today = Date.utc_today()
    northwind = Corpus.get_item_by_key!("exp.northwind")
    skills = Corpus.get_item_by_key!("skill.core")
    cegep = Corpus.get_item_by_key!("edu.cegep")
    site = Corpus.get_item_by_key!("time.site")
    columnar = Corpus.get_item_by_key!("proj.columnar")

    Desk.create_job!(%{
      id: 14_413,
      profile_id: systems.id,
      company: "Lumen Field Systems",
      role: "Runtime engineer, simulation platform",
      location: "Remote · Montréal overlap",
      listing_url: "https://example.com/jobs/lumen-field-runtime",
      source: "listing",
      heat: 5,
      stage: "screen",
      stage_on: Date.add(today, -6),
      next_action: "Reply to Nia with the replay note",
      next_due: Date.add(today, 2),
      listing: lumen_listing(),
      theme: %{
        "density" => "tight",
        "accent" => "signal",
        "targets" => [
          "columnar",
          "ecs",
          "simd",
          "deterministic",
          "replay",
          "nix",
          "telemetry",
          "vulkan",
          "schedulers",
          "kubernetes"
        ],
        "lead" =>
          "I build columnar simulation runtimes: deterministic replay, explicit schedulers, and a tick you can audit.",
        "lead_reason" => "First lines use the listing's words. The work underneath is the same."
      },
      note: "Tailored for the Lumen Field runtime listing.",
      overlays: [
        %{
          item_id: cegep.id,
          mode: :hidden,
          reason: "A general DEC is noise on a runtime listing."
        },
        %{
          item_id: site.id,
          mode: :hidden,
          reason: "A personal page from 2014 does not help this screen."
        },
        %{
          item_id: northwind.id,
          mode: :altered,
          body:
            "Owned the simulation tick for a columnar ECS: deterministic replay, a job graph of schedulers, and SIMD culling off the render thread.",
          reason:
            "The listing leads with a columnar ECS and deterministic replay. Same job, their words."
        },
        %{
          item_id: skills.id,
          mode: :altered,
          body: "SIMD, schedulers, Vulkan, Nix, telemetry, SQLite, Rust, C, Elixir.",
          reason: "Front-load the stack the listing names. SQLite stays because it is true."
        },
        %{
          item_id: columnar.id,
          mode: :emphasized,
          reason: "Closest public artifact to their platform."
        }
      ]
    })

    Kv.put("app:14413", "recruiter", "Nia Pell")
    Kv.put("app:14413", "req", "LF-RT-204")

    traces = Corpus.get_item_by_key!("exp.traces")
    methods = Corpus.get_item_by_key!("skill.research")
    orchard = Corpus.get_item_by_key!("proj.orchard")

    Desk.create_job!(%{
      id: 14_414,
      profile_id: research.id,
      company: "Glass Orchard",
      role: "Applied scientist, multi-agent simulation",
      location: "Montréal",
      listing_url: "https://example.com/jobs/glass-orchard-agents",
      source: "referral",
      heat: 4,
      stage: "tailor",
      stage_on: Date.add(today, -2),
      next_action: "Finish the variant, then submit",
      next_due: Date.add(today, 1),
      listing: orchard_listing(),
      theme: %{
        "density" => "narrative",
        "accent" => "paper",
        "targets" => [
          "agents",
          "traces",
          "ablation",
          "simulation",
          "policy",
          "elixir",
          "audit",
          "replay"
        ],
        "lead" =>
          "I build a small simulation where agents leave traces that can be audited, and where an ablation is a file rather than a feeling.",
        "lead_reason" => "Research positioning, pointed at their eval loop."
      },
      note: "Research profile. The systems CV would bury the traces.",
      overlays: [
        %{
          item_id: traces.id,
          mode: :altered,
          body:
            "Ran eval harnesses for agents and their traces. Each policy left an audit trail, and each ablation was a file.",
          reason: "Their loop is traces and ablations. The reading group did that work."
        },
        %{
          item_id: methods.id,
          mode: :altered,
          body: "Experiment logs, ablation notes, Elixir, trace corpora.",
          reason: "Name the method they asked for."
        },
        %{
          item_id: orchard.id,
          mode: :emphasized,
          reason: "The sandbox is the thing they would click."
        }
      ]
    })

    Kv.put("app:14414", "recruiter", "Eden Cho")
    Kv.put("app:14414", "req", "GO-AGT-18")
  end

  defp root_variant!(profile, note) do
    %Variant{}
    |> Variant.changeset(%{
      profile_id: profile.id,
      label: "Root",
      theme: %{"accent" => "ink", "density" => "cv"},
      note: note
    })
    |> Repo.insert!()
  end

  defp shared_items do
    [
      item(nil, :fact, "fact.location", "Location", "Montréal", "", "", 10),
      item(nil, :fact, "fact.email", "Email", "avery.quinn@example.com", "", "", 11),
      item(nil, :fact, "fact.auth", "Work", "Canada · open to remote", "", "", 12)
    ]
  end

  defp systems_items(profile_id) do
    [
      item(
        profile_id,
        :experience,
        "exp.northwind",
        "Engineer",
        "Owned the simulation tick: an entity store laid out as structure-of-arrays, a job graph, and a log that could rewind a session. Moved culling off the render thread.",
        "Northwind Runtime",
        "2023 — 2026",
        20
      ),
      item(
        profile_id,
        :experience,
        "exp.harbor",
        "Tools engineer",
        "Built the editor shell, a telemetry ring buffer, and a capture tool that could rewind a session without a second machine.",
        "Harbor Lab",
        "2021 — 2023",
        21
      ),
      item(
        profile_id,
        :experience,
        "exp.contract",
        "Build engineer",
        "Packaged a multi-platform CI image with Nix. The interesting part was the cache, not the YAML.",
        "Independent",
        "2020",
        22
      ),
      item(
        profile_id,
        :project,
        "proj.columnar",
        "Columnar runtime",
        "A public experiment in data-oriented game state: typed columns, explicit systems, and a rewind oracle.",
        "",
        "2024 —",
        30
      ),
      item(
        profile_id,
        :project,
        "proj.rowlang",
        "Rowlang",
        "A small array language for poking at column stores. The compiler is the least interesting part; the memory layout is the product.",
        "",
        "2025",
        31
      ),
      item(
        profile_id,
        :education,
        "edu.eng",
        "B.Eng. Software engineering",
        "Systems, graphics, and a thesis prototype on lock-free queues.",
        "École des Ponts Numériques",
        "2016 — 2020",
        40
      ),
      item(
        profile_id,
        :education,
        "edu.cegep",
        "DEC, computer science",
        "General formation. Algorithms, a bit of theatre, a lot of C.",
        "Cégep des Quais",
        "2014 — 2016",
        41
      ),
      item(
        profile_id,
        :skill,
        "skill.core",
        "Languages and tools",
        "Rust, C, Elixir, SQLite, Nix, SIMD intrinsics, Vulkan, telemetry.",
        "",
        "",
        50
      ),
      item(
        profile_id,
        :timeline,
        "time.sessions",
        "Session files",
        "A failing session became a file you could step.",
        "",
        "2024",
        60
      ),
      item(
        profile_id,
        :timeline,
        "time.nix",
        "One toolchain",
        "A Nix flake so the laptop and CI build the same engine.",
        "",
        "2025",
        61
      ),
      item(
        profile_id,
        :timeline,
        "time.site",
        "First public page",
        "A personal site. Kept because it is true.",
        "",
        "2014",
        62
      )
    ]
  end

  defp research_items(profile_id) do
    [
      item(
        profile_id,
        :experience,
        "exp.traces",
        "Research engineer",
        "Ran eval harnesses for multi-agent traces. The useful output was a timeline a human could audit, not a leaderboard.",
        "Glass reading group",
        "2024 — 2026",
        20
      ),
      item(
        profile_id,
        :project,
        "proj.orchard",
        "Orchard sim",
        "A small sandbox for testing policies against a world that does not drift between runs.",
        "",
        "2025 —",
        30
      ),
      item(
        profile_id,
        :skill,
        "skill.research",
        "Methods",
        "Experiment logs, Python, Elixir, trace corpora.",
        "",
        "",
        50
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

  defp lumen_listing do
    """
    Lumen Field Systems is hiring a runtime engineer for the simulation platform.

    You will own the tick: a columnar ECS, deterministic replay, and schedulers that keep SIMD culling off the render thread. We care about Nix in CI, Vulkan frame timing, and telemetry you can trust. Kubernetes shows up in the platform team's postings; this role does not run the cluster.

    Remote, with overlap to Montréal.
    """
  end

  defp orchard_listing do
    """
    Glass Orchard is hiring an applied scientist for multi-agent simulation.

    You will own the eval loop: agent traces, policy ablations, and an audit a human can read. Elixir is in the harness. Replay of a past run is a plus, not the job.
    """
  end

  defp build_flood(i, id, profiles, items_by_profile, now, today) do
    profile = Enum.at(profiles, rem(i, length(profiles)))
    items = Map.fetch!(items_by_profile, profile.id)
    stage = Enum.at(Pipeline.keys(), rem(i, length(Pipeline.keys())))
    stage_rows = Pipeline.initial(stage)
    company = Enum.at(@companies, rem(i * 3, length(@companies)))
    role = Enum.at(@roles, rem(i * 5, length(@roles)))
    targets = for k <- 0..5, do: Enum.at(@pool, rem(i + k * 3, length(@pool)))
    planted = hd(targets)
    overlay_rows = flood_overlays(id, items, i, planted)

    listing =
      "#{company} is hiring a #{String.downcase(role)}. The listing keeps returning to #{Enum.join(targets, ", ")}."

    theme = %{
      "density" => Enum.at(["tight", "cv", "narrative"], rem(i, 3)),
      "accent" => Enum.at(["ink", "signal", "paper"], rem(i, 3)),
      "targets" => targets
    }

    stats = Desk.glance(items, overlay_rows, %{theme: theme}, listing)

    %{
      job:
        Map.merge(
          %{
            id: id,
            profile_id: profile.id,
            company: company,
            role: role,
            location: Enum.at(["Remote", "Montréal", "Toronto", "Ottawa"], rem(i, 4)),
            listing_url: "https://example.com/jobs/#{id}",
            listing: listing,
            heat: rem(i, 5) + 1,
            status: status_for(i),
            next_action: Enum.at(@actions, rem(i, length(@actions))),
            next_due: if(rem(i, 4) == 0, do: nil, else: Date.add(today, rem(i, 21) - 7)),
            source: Enum.at(["listing", "referral", "direct"], rem(i, 3)),
            stage_on: Date.add(today, -rem(i, 45)),
            current_stage: stage,
            pips: Pipeline.encode(stage_rows),
            inserted_at: now,
            updated_at: now
          },
          stats
        ),
      variant: %{
        job_app_id: id,
        profile_id: profile.id,
        label: "CV#{id}",
        theme: theme,
        note: "",
        inserted_at: now,
        updated_at: now
      },
      stages:
        Enum.map(stage_rows, fn row ->
          Map.merge(row, %{job_app_id: id, inserted_at: now, updated_at: now})
        end),
      overlays:
        Enum.map(overlay_rows, fn overlay ->
          Map.merge(overlay, %{title: nil, inserted_at: now, updated_at: now})
        end),
      event: %{
        job_app_id: id,
        kind: "open",
        body: "Opened at #{Pipeline.label(stage)}",
        inserted_at: now,
        updated_at: now
      }
    }
  end

  defp flood_overlays(job_id, items, i, planted) do
    specs = [
      {:hidden, nil, "Out of scope for this listing"},
      {:altered, :plant, "Lead with the listing's word"},
      {:emphasized, nil, "Closest artifact"}
    ]

    pool =
      case Enum.reject(items, &(&1.kind == :fact)) do
        [] -> items
        lines -> lines
      end

    pool
    |> Enum.sort_by(fn item -> rem(item.position * 13 + item.id + i * 3, 997) end)
    |> Enum.take(3)
    |> Enum.zip(specs)
    |> Enum.map(fn {item, {mode, body_kind, reason}} ->
      body =
        if body_kind == :plant,
          do: String.trim("#{item.body} Emphasis for this listing: #{planted}."),
          else: nil

      %{
        job_app_id: job_id,
        item_id: item.id,
        mode: mode,
        title: nil,
        body: body,
        reason: reason
      }
    end)
  end

  defp status_for(i) do
    cond do
      rem(i, 41) == 0 -> :hired
      rem(i, 29) == 0 -> :closed
      rem(i, 17) == 0 -> :paused
      true -> :open
    end
  end

  defp insert_chunk(_schema, []), do: :ok

  defp insert_chunk(schema, rows) do
    rows
    |> Enum.chunk_every(120)
    |> Enum.each(&Repo.insert_all(schema, &1))
  end
end
