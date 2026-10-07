// Views for the lanes beside the desk: gym, networking, and company heat.

import type { Focus, HeatRow, Lanes, Option } from "./api.ts"
import type { Filters } from "./filters.ts"
import { h, raw, when, type Raw } from "./html.ts"

export function lanePills(l: Lanes | null): Raw {
  if (!l) return raw("")
  return h`
    <button type="button" id="score-gym" class="lane-pill" data-action="lens" data-lens="gym">
      gym ${l.gym.solved_today}/${l.gym.target} · ${l.gym.streak}d · pace ${l.gym.score}
    </button>
    <button type="button" id="score-net" class="lane-pill" data-action="lens" data-lens="net">
      net ${l.net.shipped_week} shipped · ${l.net.drafts} drafts · obs ${l.net.observer_runs}
    </button>`
}

export function heatChart(l: Lanes | null, f: Filters): Raw {
  if (!l) return h`<div id="heat-chart" class="heat-chart"></div>`
  const q = f.q.toLowerCase()
  const row = (prefix: string, r: HeatRow, cooldown: boolean) => h`
    <a href="/?q=${encodeURIComponent(r.label)}" data-link id="${prefix}-${r.key}"
       class="ev-band ${q !== "" && r.label.toLowerCase().includes(q) ? "is-on" : ""}"
       title="${r.label} ${r.load}/${r.cap}${cooldown ? ` cooldown ${r.cooldown_days ?? 0}d` : ""}">
      <span class="ev-band-label">${r.label}</span>
      <span class="ev-band-bar" style="width: ${Math.round(Math.min(r.ratio, 1) * 100)}%"></span>
      <span class="ev-band-n">${r.load}/${r.cap}</span>
    </a>`
  return h`
    <div id="heat-chart" class="heat-chart">
      <div class="ev-meta"><span class="pill">HEAT</span><span>${l.heat.companies.length} companies</span><span>${l.heat.vendors.length} ATS</span></div>
      <div class="heat-cols">
        <div class="heat-col">
          ${l.heat.companies.slice(0, 8).map((r) => row("heat-co", r, true))}
          ${when(l.heat.companies.length === 0, () => h`<p class="sub">No queued company heat.</p>`)}
        </div>
        <div class="heat-col">
          ${l.heat.vendors.slice(0, 8).map((r) => row("heat-ats", r, false))}
          ${when(l.heat.vendors.length === 0, () => h`<p class="sub">No ATS heat.</p>`)}
        </div>
      </div>
    </div>`
}

export function heatLine(f: Focus): Raw {
  const v = f.heat
  const eta = v.cooldown_days ? ` · cooldown ${v.cooldown_days}d` : ""
  return h`
    <p class="sub" id="heat-line">heat ${v.decision} · ${v.company_load}/${v.company_cap} ${v.size ?? ""} · ${v.ats_vendor}${eta}</p>
    ${when(!v.override, () => h`
      <form id="heat-override" class="field" data-form="heat-override">
        <label for="heat-reason">HEAT override reason</label>
        <div class="row">
          <input id="heat-reason" type="text" name="reason" placeholder="Why this role may exceed cap" />
          <button type="submit" class="ghost">Override</button>
        </div>
      </form>`)}
    ${when(v.override, () => h`<p class="sub">HEAT override · ${v.override_reason}</p>`)}`
}

export function gymView(l: Lanes, error: string | null): Raw {
  const g = l.gym
  const peak = Math.max(1, ...g.topics.map((t) => t.count))
  return h`
    <div id="gym" class="lane">
      <div class="bp-bar">
        <button type="button" id="back-from-gym" class="ghost" data-action="back">Back</button>
        <div class="grow">
          <p class="kicker">Gym · conditioning</p>
          <h2>LeetCode, Codeforces, systems drills. Daily ${g.solved_today}/${g.target} · streak ${g.streak}d · week ${g.solved_week} · pace ${g.score}</h2>
        </div>
      </div>
      <div class="lane-body">
        <div class="campaign">
          ${when(error, () => h`<p class="banner hold-error">${error}</p>`)}
          <form id="gym-target" class="lane-form" data-form="gym-target">
            <label for="gym-target-n">Daily target</label>
            <input id="gym-target-n" type="number" name="target" min="1" max="30" value="${g.target}" />
            <button type="submit" class="ghost">Set</button>
          </form>
          <form id="gym-log" class="lane-form" data-form="gym-log">
            ${select("platform", "Platform", g.platforms)}
            <input type="text" name="title" placeholder="Two Sum" required aria-label="Problem title" />
            <input type="text" name="slug" placeholder="two-sum" aria-label="Slug" />
            ${select("topic", "Topic", g.topics_all)}
            ${select("difficulty", "Difficulty", g.difficulties)}
            ${select("outcome", "Outcome", g.outcomes)}
            <input type="number" name="minutes" min="0" placeholder="min" aria-label="Minutes" />
            <input type="url" name="url" placeholder="https://…" aria-label="URL" />
            <input type="text" name="note" placeholder="Note" aria-label="Note" />
            <button type="submit" class="primary">Log rep</button>
          </form>
          <div class="ev-bands">
            ${g.topics.map((t) => h`
              <div class="ev-band"><span class="ev-band-label">${t.label}</span><span class="ev-band-bar" style="width: ${Math.round((t.count / peak) * 100)}%"></span><span class="ev-band-n">${t.count}</span></div>`)}
          </div>
        </div>
        <ul class="events lane-recent">
          ${when(g.recent.length === 0, () => h`<li class="empty">No reps yet. Log the first jump.</li>`)}
          ${g.recent.map((r) => h`
            <li id="rep-${r.id}">
              <span class="sub">${r.done_on} · ${r.platform} · ${r.outcome}${r.minutes ? ` · ${r.minutes} min` : ""}</span>
              <strong>${r.title}</strong>
              <span class="sub">${r.topic} · ${r.difficulty}</span>
              ${when(r.note !== "", () => h`<span class="sub">${r.note}</span>`)}
            </li>`)}
        </ul>
      </div>
    </div>`
}

export function netView(l: Lanes, error: string | null): Raw {
  const n = l.net
  return h`
    <div id="net" class="lane">
      <div class="bp-bar">
        <button type="button" id="back-from-net" class="ghost" data-action="back">Back</button>
        <div class="grow">
          <p class="kicker">Net · lightweight networking</p>
          <h2>Posts, artifacts, outreach drafts. No contacts, no sequences. Shipped ${n.shipped_week}/7d · drafts ${n.drafts} · observer ${n.observer_runs}</h2>
        </div>
      </div>
      <div class="lane-body">
        <div class="campaign">
          ${when(error, () => h`<p class="banner hold-error">${error}</p>`)}
          <form id="net-lane" class="lane-form" data-form="net-lane">
            <label for="net-lane-url">Observer lane</label>
            <input id="net-lane-url" type="url" name="url" placeholder="https://…" value="${n.lane}" />
            <button type="submit" class="ghost">Save lane</button>
          </form>
          ${when(n.lane !== "", () => h`<p class="sub"><a href="${n.lane}" target="_blank" rel="noreferrer">Open Observer</a></p>`)}
          <form id="net-log" class="lane-form" data-form="net-log">
            ${select("kind", "Kind", n.kinds)}
            ${select("channel", "Channel", n.channels)}
            <input type="text" name="title" placeholder="Title" required aria-label="Title" />
            <input type="url" name="url" placeholder="https://…" aria-label="URL" />
            <textarea name="body" rows="4" placeholder="Draft body or note" aria-label="Body"></textarea>
            <button type="submit" class="primary">Log entry</button>
          </form>
        </div>
        <ul class="events lane-recent">
          ${when(n.recent.length === 0, () => h`<li class="empty">Nothing shipped yet.</li>`)}
          ${n.recent.map((e) => h`
            <li id="net-${e.id}">
              <span class="sub">${e.kind} · ${e.channel}${e.shipped_on ? ` · ${e.shipped_on}` : ""}</span>
              <strong>${e.title}</strong>
              ${when(e.url !== "", () => h`<span class="sub">${e.url}</span>`)}
              ${when(e.body !== "", () => h`<span class="sub">${e.body.length > 360 ? `${e.body.slice(0, 360)}…` : e.body}</span>`)}
            </li>`)}
        </ul>
      </div>
    </div>`
}

function select(name: string, label: string, options: Option[]): Raw {
  return h`<select name="${name}" aria-label="${label}">${options.map((o) => h`<option value="${o.key}">${o.label}</option>`)}</select>`
}
