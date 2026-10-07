// Pure views: model in, HTML out. Nothing here touches the DOM.

import type { Doc, Focus, HeatRow, Key, Lanes, Line, Option, Root, Scoreboard, Session, Settings } from "./api.ts"
import { type Filters, value } from "./board.ts"
import { h, raw, when, type Raw } from "./html.ts"
import type { Store, Tables } from "./store.ts"

const EPOCH_MS = Date.UTC(1970, 0, 1)
const NONE = 0xffffffff

function bandOf(score: number, t: Tables): string {
  return t.bands.find((b) => score >= b.min && score <= b.max)?.key ?? "mid"
}

export function topbar(f: Filters, t: Tables, count: number): Raw {
  const showcase = t.batches.some((b) => b.code === "Batch-001")
  return h`
    <header class="topbar">
      <div class="brand">
        <h1>HIREME</h1>
        <p class="lede">
          <kbd>hjkl</kbd> cards · <kbd>enter</kbd> battleplan · <kbd>esc</kbd> back · <kbd>/</kbd> search
          ${when(showcase, () => h`<a href="/?batch=Batch-001" class="showcase" data-link>Batch-001</a>`)}
        </p>
      </div>
      <form id="filters" class="filters">
        <input id="q" type="search" name="q" value="${f.q}" placeholder="Company, role, JobApp, CV" autocomplete="off" aria-label="Search the desk" />
        <select name="stage" aria-label="Stage">
          <option value="all" ${sel(f.stage.kind === "all")}>All stages</option>
          ${t.stages.map((s) => h`<option value="${s.key}" ${sel(value(f.stage) === s.key)}>${s.label}</option>`)}
        </select>
        <select name="profile" aria-label="Profile">
          <option value="all" ${sel(f.profile.kind === "all")}>All profiles</option>
          ${t.profiles.map((p) => h`<option value="${p.slug}" ${sel(value(f.profile) === p.slug)}>${p.name}</option>`)}
        </select>
        <select name="batch" aria-label="Batch">
          <option value="all" ${sel(f.batch.kind === "all")}>All batches</option>
          <option value="leftover" ${sel(f.batch.kind === "leftover")}>Leftover</option>
          ${t.batches.map((b) => h`<option value="${b.code}" ${sel(value(f.batch) === b.code)}>${b.code}</option>`)}
        </select>
        <select name="status" aria-label="Status">
          ${[...t.statuses, "all"].map((s) => h`<option value="${s}" ${sel(value(f.status) === s)}>${s}</option>`)}
        </select>
        <select name="band" aria-label="score_100 band">
          <option value="all" ${sel(f.band.kind === "all")}>All bands</option>
          ${t.bands.map((b) => h`<option value="${b.key}" ${sel(value(f.band) === b.key)}>${b.label} ${b.min}–${b.max}</option>`)}
        </select>
        <input id="min_score" type="number" name="min_score" min="0" max="100" value="${f.minScore > 0 ? f.minScore : ""}" placeholder="min score_100" aria-label="Minimum score_100" class="min-score" />
        <select name="heat" aria-label="Company heat">
          <option value="all" ${sel(f.heat.kind === "all")}>All heat</option>
          ${t.heat_states.map((s) => h`<option value="${s}" ${sel(value(f.heat) === s)}>${s}</option>`)}
        </select>
        <span class="count">${count} showing</span>
      </form>
      <button type="button" id="root-cv" class="ghost" data-action="root">Root CV</button>
      <button type="button" id="open-gym" class="ghost" data-action="lens" data-lens="gym">Gym</button>
      <button type="button" id="open-net" class="ghost" data-action="lens" data-lens="net">Net</button>
      <button type="button" id="open-settings" class="ghost" data-action="lens" data-lens="settings">Account</button>
    </header>`
}

function sel(on: boolean): Raw {
  return raw(on ? "selected" : "")
}

export function scoreboard(s: Scoreboard | null, pills: Raw): Raw {
  if (!s) return h`<div id="scoreboard" class="scoreboard"></div>`
  const peak = Math.max(1, ...s.chart.bands.map((b) => b.count))
  return h`
    <div id="scoreboard" class="scoreboard">
      <span class="pill ${s.fire === "hold" ? "is-hold" : "is-open"}">${s.fire === "hold" ? "FIRE HOLD" : "OPEN FIRE"}</span>
      ${pills}
      <span>leftover ${s.leftover_unique}${s.leftover_noted_on ? ` · ${s.leftover_noted_on}` : ""}</span>
      <span>batches ${s.batches_today}/${s.batches_target}</span>
      <span>queued ${s.apps_today}/${s.apps_target}</span>
      <span>submitted today ${s.submitted_today}</span>
      <span>cumulative ${s.cumulative}</span>
      <span>pace ${s.submitted_today}/${s.apps_target}</span>
      ${s.varieties.map((v) => h`<span class="variety">${v.code} ${v.label}</span>`)}
      <span id="ev-chart" class="bands" aria-label="Applications by score_100 band">
        <span class="ev-meta">score_100 · n ${s.chart.n}${s.chart.mean !== null ? ` · mean ${s.chart.mean}` : ""}</span>
        ${s.chart.bands.map((b) => h`
          <a href="/?band=${b.key}" data-link class="band band-${b.key}" title="${b.label} ${b.min}–${b.max} · ${b.count}">
            <i style="height: ${b.count === 0 ? 4 : Math.max(Math.round((b.count / peak) * 100), 8)}%"></i><b>${b.count}</b>
          </a>`)}
      </span>
    </div>`
}

export function card(store: Store, row: number, x: number, y: number, active: boolean): Raw {
  const t = store.tables
  const id = store.column("id")[row] ?? 0
  const score = store.column("score")[row] ?? 0
  const heat = store.column("heat")[row] ?? 0
  const stage = t.stages[store.column("stage")[row] ?? 0]
  const batchIx = store.column("batch")[row] ?? 0
  const batch = batchIx > 0 ? t.batches.find((b) => b.ordinal + 1 === batchIx) : undefined
  const company = store.str("company").at(row)
  const role = store.str("role").at(row)
  const pips = store.str("pips").at(row)
  const heatState = t.heat_states[store.column("heat_state")[row] ?? 0] ?? "cool"
  const loadPct = store.column("load_pct")[row] ?? 0
  const next = store.str("next_action").at(row)
  const due = days(store.column("next_due")[row] ?? NONE)
  const age = days(store.column("stage_on")[row] ?? NONE)
  const profile = t.profiles[store.column("profile")[row] ?? 0]
  return h`
    <button type="button" id="card-${id}" class="card ${active ? "is-active" : ""}" style="left: ${x}px; top: ${y}px"
      data-action="select" data-id="${id}" aria-current="${active ? "true" : "false"}" title="${company} — ${role}">
      <div class="card-kicker">
        <span class="code">${batch ? batch.code : `JobApp${id}`}</span>
        <span class="score band-${bandOf(score, t)}" aria-label="score_100 ${score}">${score}</span>
        <span class="heat-load ${heatState === "blocked" ? "is-blocked" : heatState === "hot" ? "is-hot" : ""}" title="company heat ${loadPct}% of cap">${heatState}</span>
        <span class="stage-name">${stage?.label ?? ""}${batch?.fire === "hold" ? " · HOLD" : ""}</span>
      </div>
      <h2>${company}</h2>
      <p class="role">${role}</p>
      <div class="meta">
        <span class="pips" aria-label="Battleplan ${stage?.label ?? ""}">${[...pips].map((p) => h`<i class="pip pip-${p}"></i>`)}</span>
        <span class="heat" aria-label="Heat ${heat} of 5">${[1, 2, 3, 4, 5].map((n) => h`<span class="${n <= heat ? "on" : ""}"></span>`)}</span>
      </div>
      <p class="glance">
        <span>${store.str("cv_label").at(row)} · ${profile?.name ?? ""}</span>
        <span>${store.column("hits")[row] ?? 0}/${store.column("total")[row] ?? 0}</span>
      </p>
      <p class="next">
        <span>${next === "" ? "No next action" : next}${due ? ` · ${shortDate(due)}` : ""}</span>
        ${when(age, () => h`<span>${ageLabel(age as Date)}</span>`)}
      </p>
    </button>`
}

export function focusPanel(f: Focus, inFilter: boolean, sheet: boolean, holdError: string | null): Raw {
  const j = f.job
  const pct = f.coverage.hits.length + f.coverage.misses.length === 0
    ? 0
    : Math.round((f.coverage.hits.length / (f.coverage.hits.length + f.coverage.misses.length)) * 100)
  return h`
    <aside id="focus" class="focus ${sheet ? "is-sheet" : ""}">
      <header>
        <p class="kicker"><span>${j.code}</span> ${scorePill(j.score_100, j.band)} <span>${f.variant.label}</span> <span>${f.profile.name}</span></p>
        <h2>${j.company}</h2>
        <p class="sub">${j.role}</p>
        <p class="sub">${j.location}</p>
        <p class="sub">${fireLine(j)}</p>
        ${heatLine(f)}
      </header>
      ${when(!inFilter, () => h`<p class="banner">This application is outside the current filter.</p>`)}
      ${when(holdError, () => h`<p id="hold-error" class="banner hold-error">${holdError}</p>`)}
      <div>
        <div class="meta">
          <span class="pips">${[...j.pips].map((p) => h`<i class="pip pip-${p}"></i>`)}</span>
          <span class="stage-name">${j.stage_label}</span>
        </div>
        <p class="sub">${j.stage_hint}</p>
      </div>
      <button type="button" id="open-battleplan" class="primary" data-action="battleplan">Open battleplan</button>
      <form id="next-form" class="field" data-form="next">
        <label for="next_action">Next</label>
        <div class="row">
          <input id="next_action" type="text" name="next_action" value="${j.next_action}" />
          <input type="date" name="next_due" value="${j.next_due ?? ""}" aria-label="Due" class="${overdue(j.next_due) ? "is-due" : ""}" />
        </div>
      </form>
      <div>
        <p class="section-label">Keywords ${f.coverage.hits.length}/${f.coverage.hits.length + f.coverage.misses.length} · root ${f.root_coverage.hits.length}/${f.root_coverage.hits.length + f.root_coverage.misses.length}</p>
        <div class="meter" aria-hidden="true"><span style="width: ${pct}%"></span></div>
        <ul class="chips">
          ${f.coverage.hits.map((w) => h`<li class="hit">${w}</li>`)}
          ${f.coverage.misses.map((w) => h`<li class="miss">${w}</li>`)}
        </ul>
      </div>
      <div>
        <p class="section-label">Mask · ${j.mask_hidden} hidden · ${j.mask_altered} altered · ${j.mask_emphasized} emphasized</p>
        <ul class="mask-list">
          ${f.masks.slice(0, 4).map((m) => h`<li><span class="mode mode-${m.mode}">${m.mode}</span> ${m.title}${m.reason ? h`<span class="reason"> — ${m.reason}</span>` : ""}</li>`)}
        </ul>
      </div>
      ${when(excerpt(j.listing) !== "", () => h`<p class="sub">${excerpt(j.listing)}</p>`)}
      ${when(f.kv.length, () => h`<ul class="kv">${f.kv.map((p) => h`<li><strong>${p.key}</strong> ${p.value}</li>`)}</ul>`)}
      ${narrative(f.narrative)}
    </aside>`
}

export function battleplan(f: Focus, editing: number | null, alterError: string | null, holdError: string | null): Raw {
  const j = f.job
  const active = f.rail.find((r) => r.state === "active") ?? f.rail.find((r) => r.state === "pending")
  return h`
    <div id="battleplan" class="battleplan">
      <div class="bp-bar">
        <button type="button" id="back-to-desk" class="ghost" data-action="back">Back</button>
        <div class="grow">
          <p class="kicker">${j.code} · ${scorePill(j.score_100, j.band)} ${f.variant.label} · ${f.profile.name}</p>
          <h2>${j.company}</h2>
          <p class="sub">${j.role}</p>
          <p class="sub">${fireLine(j)}</p>
          ${heatLine(f)}
        </div>
        <p class="count">${f.coverage.hits.length}/${f.coverage.hits.length + f.coverage.misses.length} keywords · root ${f.root_coverage.hits.length}/${f.root_coverage.hits.length + f.root_coverage.misses.length}</p>
      </div>
      <div class="bp-body">
        <div class="campaign">
          ${narrative(f.narrative)}
          ${when(holdError, () => h`<p id="hold-error" class="banner hold-error">${holdError}</p>`)}
          ${when(j.batch && j.batch.fire === "hold", () => h`
            <button type="button" id="name-open-fire" class="ghost" data-action="open-fire" data-batch="${j.batch?.code}">Name open fire</button>`)}
          ${f.rail.map((r) => h`
            <button type="button" id="stage-${r.key}" class="stage ${r.state === "active" ? "is-active" : ""}" data-action="stage" data-stage="${r.key}">
              <span class="meta"><span class="pip pip-${pipChar(r.state)}"></span><span class="label">${r.label}</span></span>
              <span class="hint">${r.hint}</span>
              ${when(r.note !== "", () => h`<span class="note-preview">${r.note}</span>`)}
            </button>`)}
          ${when(active, () => h`
            <form id="note-form" class="note" data-form="note" data-stage="${active?.key}">
              <label for="stage-note">Note · ${active?.label}</label>
              <textarea id="stage-note" name="note">${active?.note}</textarea>
            </form>`)}
          <ul class="events">${f.events.map((e) => h`<li>${e.body}</li>`)}</ul>
        </div>
        <div class="paper-scroll">
          ${paper(f.cv, true, editing, alterError)}
          ${when(j.listing !== "", () => h`<p class="sub">${j.listing.trim()}</p>`)}
        </div>
      </div>
    </div>`
}

export function rootView(r: Root): Raw {
  return h`
    <div class="root-wrap">
      <div class="bp-bar">
        <button type="button" id="back-to-desk" class="ghost" data-action="back">Back</button>
        <div class="grow"><p class="kicker">Root · ${r.profile.name}</p><h2>${r.cv.headline}</h2></div>
      </div>
      <div class="paper-scroll">
        ${narrative(r.narrative)}
        ${paper(r.cv, false, null, null)}
      </div>
    </div>`
}

function narrative(n: Focus["narrative"]): Raw {
  if (!n) return raw("")
  return h`
    <section id="narrative" class="narrative">
      <form id="narrative-form" data-form="narrative" data-narrative="${n.id}">
        <label class="section-label" for="narrative-body">Narrative · private · v${n.version}</label>
        <textarea id="narrative-body" name="body" rows="8">${n.body}</textarea>
        <button type="submit" class="ghost">Save narrative</button>
      </form>
    </section>`
}

function paper(cv: Doc, editable: boolean, editing: number | null, alterError: string | null): Raw {
  return h`
    <article id="cv" class="paper" data-accent="${cv.accent}" data-density="${cv.density}">
      <header>
        <p class="kicker">${cv.label}</p>
        ${when(cv.person, () => h`<h2>${cv.person}</h2>`)}
        <p class="headline">${cv.headline}</p>
        <p class="summary">${cv.summary}</p>
        ${when(cv.summary_canonical, () => h`<p class="canonical">Root: ${cv.summary_canonical}${cv.summary_reason ? h`<span> — ${cv.summary_reason}</span>` : ""}</p>`)}
        <div class="facts">${cv.facts.map((f) => h`<span>${f.title}: ${f.body}</span>`)}</div>
      </header>
      ${cv.sections.map((s) => h`<section><h3>${s.label}</h3>${s.lines.map((l) => cvLine(l, editable, editing, alterError))}</section>`)}
      ${when(cv.hidden.length, () => h`<section class="masked"><h3>Masked out</h3>${cv.hidden.map((l) => cvLine(l, editable, editing, alterError))}</section>`)}
    </article>`
}

function cvLine(l: Line, editable: boolean, editing: number | null, alterError: string | null): Raw {
  const isEditing = editable && editing === l.id
  return h`
    <div id="line-${l.id}" class="line is-${l.mode}">
      <h4>${when(l.org !== "", () => h`<span class="org">${l.org} · </span>`)}${l.title}${when(l.span !== "", () => h`<span class="org"> · ${l.span}</span>`)}</h4>
      ${when(!isEditing, () => h`<p>${l.body}</p>`)}
      ${when(l.mode === "altered" && l.canonical_body !== l.body, () => h`<p class="canonical">Root: ${l.canonical_body}</p>`)}
      ${when(l.reason, () => h`<p class="reason">${l.reason}</p>`)}
      ${when(editable && !isEditing, () => h`
        <div class="line-actions">
          ${when(l.shown, () => h`<button type="button" id="mask-hide-${l.id}" class="text-btn" data-action="mask" data-item="${l.id}" data-mode="hidden">Hide</button>`)}
          ${when(l.shown && l.mode !== "emphasized", () => h`<button type="button" id="mask-emphasize-${l.id}" class="text-btn" data-action="mask" data-item="${l.id}" data-mode="emphasized">Emphasize</button>`)}
          ${when(l.shown, () => h`<button type="button" id="mask-alter-${l.id}" class="text-btn" data-action="edit" data-item="${l.id}">Alter</button>`)}
          ${when(l.mode !== "canonical", () => h`<button type="button" id="mask-restore-${l.id}" class="text-btn" data-action="mask" data-item="${l.id}" data-mode="inherit">Restore</button>`)}
        </div>`)}
      ${when(isEditing, () => h`
        <form id="alter-${l.id}" class="alter" data-form="alter" data-item="${l.id}">
          <textarea name="body" aria-label="Variant line">${l.body}</textarea>
          <input type="text" name="reason" value="${l.reason ?? ""}" placeholder="Why this line changed" />
          ${when(alterError, () => h`<p class="alter-error">${alterError}</p>`)}
          <button type="submit" class="primary">Save line</button>
          <button type="button" class="ghost" data-action="cancel-edit">Cancel</button>
        </form>`)}
    </div>`
}

function scorePill(score: number, band: string): Raw {
  return h`<span class="score band-${band}" aria-label="score_100 ${score}">${score}</span>`
}

function fireLine(j: Focus["job"]): string {
  if (j.batch) return `${j.batch.code} · ${j.batch.fire === "hold" ? "FIRE HOLD" : "OPEN FIRE"}`
  return `${j.gate} · ${j.freshness}`
}

function pipChar(state: string): string {
  return { done: "D", active: "A", pending: "P", skipped: "S", blocked: "B" }[state] ?? "?"
}

function days(d: number): Date | null {
  return d === NONE ? null : new Date(EPOCH_MS + d * 86_400_000)
}

function shortDate(d: Date): string {
  return `${d.toLocaleString("en", { month: "short", timeZone: "UTC" })} ${d.getUTCDate()}`
}

function ageLabel(d: Date): string {
  const today = Math.floor(Date.now() / 86_400_000)
  const n = today - Math.floor(d.getTime() / 86_400_000)
  return n === 0 ? "today" : `${n}d`
}

function overdue(iso: string | null): boolean {
  return iso !== null && iso < new Date().toISOString().slice(0, 10)
}

function excerpt(text: string): string {
  const t = (text ?? "").trim()
  return t.length > 360 ? `${t.slice(0, 360)}…` : t
}

export function emptyBoard(): Raw {
  return h`<p class="empty">Nothing matches this filter.</p>`
}

export const emptyFocus = (): Raw => h`<div id="focus" class="focus"><p class="empty">The desk is empty.</p></div>`

// ---- lanes: gym, networking, and company heat ----

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
       title="${r.label} ${tenth(r.load)}/${tenth(r.cap)}${cooldown ? ` cooldown ${r.cooldown_days ?? 0}d` : ""}">
      <span class="ev-band-label">${r.label}</span>
      <span class="ev-band-bar" style="width: ${Math.round(Math.min(r.ratio, 1) * 100)}%"></span>
      <span class="ev-band-n">${tenth(r.load)}/${tenth(r.cap)}</span>
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
    <p class="sub" id="heat-line">heat ${v.decision} · ${tenth(v.company_load)}/${tenth(v.company_cap)} ${v.size ?? ""} · ${v.ats_vendor}${eta}</p>
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
              <span class="sub">${r.done_on} · ${labelOf(g.platforms, r.platform)} · ${r.outcome}${r.minutes ? ` · ${r.minutes} min` : ""}</span>
              <strong>${r.title}</strong>
              <span class="sub">${labelOf(g.topics_all, r.topic)} · ${labelOf(g.difficulties, r.difficulty)}</span>
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
              <span class="sub">${labelOf(n.kinds, e.kind)} · ${labelOf(n.channels, e.channel)}${e.shipped_on ? ` · ${e.shipped_on}` : ""}</span>
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

// Lane rows carry keys; each label arrives once, in the form's options.
function labelOf(options: Option[], key: string): string {
  return options.find((o) => o.key === key)?.label ?? key
}

function tenth(x: number): number {
  return Number(x.toFixed(1))
}

// ---- the account: API keys and sessions ----

export interface Reveal { name: string; secret: string }

export function settingsView(s: Settings | null, reveal: Reveal | null, renaming: number | null, error: string | null, csrf: string): Raw {
  return h`
    <div id="settings" class="lane">
      <div class="bp-bar">
        <button type="button" id="back-from-settings" class="ghost" data-action="back">Back</button>
        <div class="grow">
          <p class="kicker">Account${s ? ` · ${s.account.name}` : ""}</p>
          <h2>API keys for agents, and the browsers signed in. A key reads one account and nothing else.</h2>
        </div>
        <form method="post" action="/sign-out" class="inline">
          <input type="hidden" name="_csrf_token" value="${csrf}" />
          <button type="submit" class="ghost">Sign out</button>
        </form>
      </div>
      <div class="settings-body">
        ${when(error, () => h`<p class="banner hold-error">${error}</p>`)}
        ${when(reveal, () => h`
          <section id="reveal" class="secret-panel">
            <p class="section-label">Key created · ${reveal?.name}</p>
            <p class="sub">Copy it now. It is shown once and cannot be recovered; a lost key is revoked and replaced.</p>
            <div class="row">
              <input id="secret" type="text" readonly value="${reveal?.secret}" aria-label="API key" />
              <button type="button" class="primary" data-action="copy" data-copy="${reveal?.secret}">Copy</button>
              <button type="button" class="ghost" data-action="dismiss-secret">Done</button>
            </div>
            <p class="sub">Agents present it as the <code>x-api-key</code> header on <code>/mcp/websocket</code> and <code>/mcp/letterbox/&lt;id&gt;/websocket</code>.</p>
          </section>`)}
        <section class="settings-section">
          <div class="section-head">
            <p class="section-label">API keys</p>
            <form id="create-key" class="lane-form inline" data-form="create-key">
              <input type="text" name="name" placeholder="Name, e.g. agenix-pylon-wsl" required maxlength="100" aria-label="Key name" />
              <select name="expires_in_days" aria-label="Expiration">
                <option value="">Never expires</option>
                <option value="30">30 days</option>
                <option value="90">90 days</option>
                <option value="365">1 year</option>
              </select>
              <button type="submit" class="primary">Create API key</button>
            </form>
          </div>
          ${s ? keysTable(s.keys, renaming) : h`<p class="sub">Loading…</p>`}
        </section>
        <section class="settings-section">
          <div class="section-head">
            <p class="section-label">Sessions</p>
            <button type="button" class="ghost" data-action="revoke-others">Sign out other sessions</button>
          </div>
          ${s ? sessionsTable(s.sessions) : raw("")}
        </section>
      </div>
    </div>`
}

function keysTable(keys: Key[], renaming: number | null): Raw {
  if (keys.length === 0) return h`<p class="sub">No keys yet. An agent needs one to open the socket.</p>`
  return h`
    <table class="keys">
      <thead><tr><th>Name</th><th>Secret key</th><th>Created</th><th>Last used</th><th>Expiration</th><th></th></tr></thead>
      <tbody>
        ${keys.map((k) => h`
          <tr id="key-${k.id}" class="${k.live ? "" : "is-revoked"}">
            <td>
              ${renaming === k.id
                ? h`<form class="inline" data-form="rename-key" data-id="${k.id}"><input type="text" name="name" value="${k.name}" maxlength="100" aria-label="New name" autofocus /><button type="submit" class="ghost">Save</button><button type="button" class="text-btn" data-action="cancel-rename">Cancel</button></form>`
                : h`<strong>${k.name}</strong>`}
              <span class="sub">ID: ${k.key_id} <button type="button" class="text-btn" data-action="copy" data-copy="${k.key_id}" title="Copy id">⧉</button></span>
            </td>
            <td><code>${k.display}</code></td>
            <td>${stamp(k.created_at)}</td>
            <td>${k.last_used_at ? stamp(k.last_used_at) : "Never"}</td>
            <td>${k.revoked_at ? `Revoked ${stamp(k.revoked_at)}` : k.expires_at ? stamp(k.expires_at) : "Never"}</td>
            <td class="actions">
              ${when(k.live && renaming !== k.id, () => h`<button type="button" class="text-btn" data-action="rename" data-id="${k.id}">Rename</button>`)}
              ${when(k.live, () => h`<button type="button" class="text-btn danger" data-action="revoke-key" data-id="${k.id}" data-name="${k.name}">Revoke</button>`)}
            </td>
          </tr>`)}
      </tbody>
    </table>`
}

function sessionsTable(sessions: Session[]): Raw {
  return h`
    <table class="keys">
      <thead><tr><th>Browser</th><th>Address</th><th>Signed in</th><th>Last seen</th><th>Second factor</th><th></th></tr></thead>
      <tbody>
        ${sessions.map((x) => h`
          <tr id="session-${x.id}">
            <td>${x.user_agent === "" ? "Unknown" : x.user_agent.slice(0, 60)}${x.current ? h`<span class="pill is-open"> this one</span>` : ""}</td>
            <td>${x.ip}</td>
            <td>${stamp(x.authenticated_at)}</td>
            <td>${stamp(x.last_seen_at)}</td>
            <td>${x.mfa_at ? stamp(x.mfa_at) : "—"}</td>
            <td class="actions"><button type="button" class="text-btn danger" data-action="revoke-session" data-id="${x.id}">${x.current ? "Sign out" : "Revoke"}</button></td>
          </tr>`)}
      </tbody>
    </table>`
}

function stamp(iso: string): string {
  const d = new Date(iso)
  return `${d.toLocaleDateString("en", { month: "short", day: "numeric", year: "numeric" })} ${d.toLocaleTimeString("en", { hour: "numeric", minute: "2-digit" })}`
}
