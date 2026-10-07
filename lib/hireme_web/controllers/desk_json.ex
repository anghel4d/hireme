defmodule HiremeWeb.DeskJSON do
  @moduledoc """
  The wire shape of a focus, a root, and a scoreboard. Every field is
  named here on purpose; nothing is serialised by reflection.
  """

  alias Hireme.Campaign.Scoreboard
  alias Hireme.Cv.Document
  alias Hireme.Desk
  alias Hireme.Desk.Focus
  alias Hireme.Desk.Job
  alias Hireme.Desk.Root
  alias Hireme.Keywords.Coverage
  alias Hireme.LifeEv
  alias Hireme.Mask.Line
  alias Hireme.Pipeline
  alias Hireme.Pipeline.Rung
  alias Hireme.Theme

  @spec focus(Focus.t()) :: map()
  def focus(%Focus{} = f) do
    %{
      job: job(f.job),
      profile: profile(f.profile),
      variant: %{id: f.variant.id, label: f.variant.label},
      theme: Theme.to_map(f.theme),
      rail: Enum.map(f.rail, &rung/1),
      events: Enum.map(f.events, &%{id: &1.id, kind: &1.kind, body: &1.body, at: &1.inserted_at}),
      cv: document(f.cv),
      narrative: narrative(f.narrative),
      coverage: coverage(f.coverage),
      root_coverage: coverage(f.root_coverage),
      kv: Enum.map(f.kv, &%{key: &1.key, value: &1.value}),
      masks: Enum.map(f.masks, &line/1),
      heat: heat(f.job)
    }
  end

  defp heat(%Job{} = job) do
    v = Hireme.Heat.can_apply(job)

    %{
      decision: v.decision,
      reason: v.reason,
      company_load: Float.round(v.company_load * 1.0, 1),
      company_cap: Float.round(v.company_cap * 1.0, 1),
      size: v.size,
      ats_vendor: Hireme.Heat.Ats.name(v.ats_vendor),
      cooldown_days: v.cooldown_days,
      note: v.note,
      override: job.heat_override,
      override_reason: job.heat_override_reason
    }
  end

  @spec root(Root.t()) :: map()
  def root(%Root{} = r) do
    %{
      profile: profile(r.profile),
      cv: document(r.cv),
      kv: Enum.map(r.kv, &%{key: &1.key, value: &1.value}),
      narrative: narrative(r.narrative)
    }
  end

  @spec job(Job.t()) :: map()
  def job(%Job{} = j) do
    %{
      id: j.id,
      code: Desk.code(j.id),
      company: j.company,
      role: j.role,
      location: j.location,
      listing: j.listing,
      listing_url: j.listing_url,
      heat: j.heat,
      status: j.status,
      stage: Pipeline.name(j.current_stage),
      stage_label: Pipeline.label(j.current_stage),
      stage_hint: Pipeline.hint(j.current_stage),
      pips: j.pips,
      score_100: j.score_100,
      band: LifeEv.name(LifeEv.band(j.score_100)),
      next_action: j.next_action,
      next_due: j.next_due,
      stage_on: j.stage_on,
      freshness: j.freshness,
      gate: j.gate,
      fit: j.fit,
      keyword_hits: j.keyword_hits,
      keyword_total: j.keyword_total,
      mask_hidden: j.mask_hidden,
      mask_altered: j.mask_altered,
      mask_emphasized: j.mask_emphasized,
      batch: batch(Map.get(j, :batch))
    }
  end

  @spec scoreboard(Scoreboard.t()) :: map()
  def scoreboard(%Scoreboard{} = s) do
    %{
      fire: s.fire,
      leftover_unique: s.leftover_unique,
      leftover_noted_on: s.leftover_noted_on,
      batches_today: s.batches_today,
      batches_target: s.batches_target,
      apps_today: s.apps_today,
      apps_target: s.apps_target,
      submitted_today: s.submitted_today,
      cumulative: s.cumulative,
      target_total: s.target_total,
      target_on: s.target_on,
      varieties:
        Enum.map(
          s.varieties,
          &%{code: &1.code, fire: &1.fire, status: &1.status, label: &1.label}
        ),
      chart: %{
        n: s.chart.n,
        mean: s.chart.mean,
        max: s.chart.max,
        min: s.chart.min,
        bands:
          Enum.map(
            s.chart.bands,
            &%{key: &1.key, label: &1.label, min: &1.min, max: &1.max, count: &1.count}
          ),
        bins: s.chart.bins
      }
    }
  end

  defp batch(%{code: code, fire: fire}), do: %{code: code, fire: fire}
  defp batch(_), do: nil

  defp profile(p),
    do: %{id: p.id, slug: p.slug, name: p.name, headline: p.headline, summary: p.summary}

  defp narrative(nil), do: nil
  defp narrative(n), do: %{id: n.id, body: n.body, version: n.version}

  defp rung(%Rung{} = r) do
    %{
      key: Pipeline.name(r.key),
      label: Pipeline.label(r.key),
      hint: Pipeline.hint(r.key),
      state: r.state,
      note: r.note
    }
  end

  defp coverage(%Coverage{} = c), do: %{hits: c.hits, misses: c.misses}

  defp document(%Document{} = d) do
    %{
      label: d.label,
      person: d.person,
      headline: d.headline,
      summary: d.summary,
      summary_canonical: d.summary_canonical,
      summary_reason: d.summary_reason,
      accent: d.accent,
      density: d.density,
      facts: Enum.map(d.facts, &line/1),
      sections:
        Enum.map(d.sections, fn s ->
          %{kind: s.kind, label: s.label, lines: Enum.map(s.lines, &line/1)}
        end),
      hidden: Enum.map(d.hidden, &line/1)
    }
  end

  defp line(%Line{} = l) do
    %{
      id: l.id,
      kind: l.kind,
      title: l.title,
      body: l.body,
      org: l.org,
      span: l.span,
      shown: l.shown,
      mode: l.mode,
      reason: l.reason,
      canonical_title: l.canonical_title,
      canonical_body: l.canonical_body
    }
  end
end
