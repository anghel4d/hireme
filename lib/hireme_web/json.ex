defmodule HiremeWeb.JSON do
  @moduledoc """
  The wire shape of everything the desk answers over HTTP: a focus, a
  root, a scoreboard, the lanes, and a refusal. Every field is named
  here on purpose; nothing is serialised by reflection.
  """

  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias Hireme.Campaign.Scoreboard
  alias Hireme.Cv.Document
  alias Hireme.Desk
  alias Hireme.Desk.Focus
  alias Hireme.Desk.Job
  alias Hireme.Desk.Root
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Keywords.Coverage
  alias Hireme.LifeEv
  alias Hireme.Mask.Line
  alias Hireme.Net
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
        bands: Enum.map(s.chart.bands, &Map.take(&1, [:key, :label, :min, :max, :count])),
        bins: s.chart.bins
      }
    }
  end

  @doc "The lanes beside the desk, read as one document: gym, net, and company heat."
  @spec lanes() :: map()
  def lanes do
    gym = Gym.progress()
    net = Net.progress()
    chart = Heat.chart()

    %{
      gym: %{
        target: gym.target,
        streak: gym.streak,
        solved_today: gym.solved_today,
        solved_week: gym.solved_week,
        score: gym.score,
        topics: Enum.map(gym.topics, &Map.take(&1, [:key, :label, :count])),
        recent:
          Enum.map(gym.recent, fn rep ->
            %{
              id: rep.id,
              done_on: rep.done_on,
              outcome: rep.outcome,
              minutes: rep.minutes,
              note: rep.note,
              title: rep.problem.title,
              url: rep.problem.url,
              platform: Gym.label(rep.problem.platform),
              topic: Gym.label(rep.problem.topic),
              difficulty: Gym.label(rep.problem.difficulty)
            }
          end),
        platforms: options(Gym.platforms(), &Gym.label/1),
        topics_all: options(Gym.topics(), &Gym.label/1),
        difficulties: options(Gym.difficulties(), &Gym.label/1),
        outcomes: options(Gym.outcomes(), &Gym.label/1)
      },
      net: %{
        lane: net.lane,
        shipped_week: net.shipped_week,
        drafts: net.drafts,
        observer_runs: net.observer_runs,
        recent:
          Enum.map(net.recent, fn e ->
            %{
              id: e.id,
              kind: Net.label(e.kind),
              channel: Net.label(e.channel),
              title: e.title,
              url: e.url,
              body: e.body,
              shipped_on: e.shipped_on
            }
          end),
        kinds: options(Net.kinds(), &Net.label/1),
        channels: options(Net.channels(), &Net.label/1)
      },
      heat: %{
        companies: Enum.map(chart.companies, &heat_row/1),
        vendors: Enum.map(chart.vendors, &heat_row/1)
      }
    }
  end

  @doc """
  Answer a refusal. A reason atom or changeset maps to the status and
  message the shell expects; `{status, message}` says both outright.
  """
  @spec refuse(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def refuse(conn, reason) do
    {status, message} =
      case reason do
        {status, message} when is_integer(status) -> {status, message}
        :not_found -> {404, "not found"}
        :batch -> {404, "batch"}
        :leased -> {423, "leased"}
        {:argument, name} -> {400, "bad argument #{name}"}
        %Ecto.Changeset{} -> {422, "invalid"}
        other when is_atom(other) -> {409, Atom.to_string(other)}
        other -> {400, inspect(other)}
      end

    conn |> put_status(status) |> json(%{error: message})
  end

  defp heat(%Job{} = job) do
    v = Heat.can_apply(job)

    %{
      decision: v.decision,
      reason: v.reason,
      company_load: Float.round(v.company_load * 1.0, 1),
      company_cap: Float.round(v.company_cap * 1.0, 1),
      size: v.size,
      ats_vendor: Atom.to_string(v.ats_vendor),
      cooldown_days: v.cooldown_days,
      note: v.note,
      override: job.heat_override,
      override_reason: job.heat_override_reason
    }
  end

  defp heat_row(row) do
    row
    |> Map.take([:key, :label, :ratio, :n, :cooldown_days])
    |> Map.merge(%{load: Float.round(row.load * 1.0, 1), cap: Float.round(row.cap * 1.0, 1)})
  end

  defp options(keys, label), do: Enum.map(keys, &%{key: Atom.to_string(&1), label: label.(&1)})

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
        Enum.map(
          d.sections,
          fn s -> %{kind: s.kind, label: s.label, lines: Enum.map(s.lines, &line/1)} end
        ),
      hidden: Enum.map(d.hidden, &line/1)
    }
  end

  defp line(%Line{} = l) do
    Map.take(l, [
      :id,
      :kind,
      :title,
      :body,
      :org,
      :span,
      :shown,
      :mode,
      :reason,
      :canonical_title,
      :canonical_body
    ])
  end
end
