// The lanes: gym (reps, the daily target, the streak) and net (observer
// runs, artifacts, posts, drafts). Both tables are resident; the counts are
// the kernel's (`lanes`), the rows are read value by value, and a new rep
// or entry is a put judged locally first.

import type { View } from "../app.ts"
import { ENUMS, type TableName } from "../gen/schema.ts"
import { failed, lanes, put, putSettings, query, settingsId, today, value, type Input, type Row } from "../kernel.ts"
import { EMPTY, fields, flag, href, html, morph, resetAfter, str, type Html } from "../morph.ts"
import { model } from "../state.ts"

type Gym = { today: number; streak: number; week: number; target: number | null; pace: number | null; owed: number | null }
type Net = Record<string, { total: number; week: number } | number>

const options = (name: string, pick: string): Html => html`${(ENUMS[name] ?? []).map((x) => html`<option${flag("selected", x === pick)}>${x}</option>`)}`

/** A resident table's newest rows by a day column, whole, in one read of the kernel's order index. */
function newest(t: TableName, by: string, n: number, cols: string[]): Row[] {
  return query<{ rows: Row[] }>("find", { table: t, order: [by, "desc"], cols: ["id", ...cols], limit: n }).rows
}

function gym(g: Gym): Html {
  return html`<section class="card facts" data-key="gym-stats">
      <div class="stat"><b>${g.today}${g.target ? html`<small>/${g.target}</small>` : EMPTY}</b><span>today</span></div>
      <div class="stat"><b>${g.streak}</b><span>day streak</span></div>
      <div class="stat"><b>${g.week}</b><span>this week</span></div>
      ${g.pace !== null ? html`<div class="stat"><b>${Math.round(g.pace * 100)}%</b><span>pace</span></div>` : EMPTY}
      ${g.owed ? html`<p class="hint">${g.owed} more today meets the target.</p>` : EMPTY}
      <form class="row" data-submit="target" data-act="target"><label>Daily target <input type="number" name="gym_target" min="0" max="50" value="${g.target ?? ""}" class="narrow"></label><button>Set</button></form>
    </section>
    <form class="card stack" data-submit="rep" data-act="rep" data-key="rep">
      <h2>Log a rep</h2>
      <div class="row">
        <label>Platform <select name="platform">${options("platform", "leetcode")}</select></label>
        <label>Slug <input name="slug" required placeholder="two-sum"></label>
        <label>Title <input name="title"></label>
        <label>Topic <select name="topic"><option value="">Any topic</option>${options("topic", "")}</select></label>
        <label>Difficulty <select name="difficulty"><option value="">Not rated</option>${options("difficulty", "")}</select></label>
        <label>Minutes <input type="number" name="minutes" min="0" max="600" class="narrow"></label>
        <label>Outcome <select name="outcome">${options("rep_outcome", "solved")}</select></label>
        <label>Day <input type="date" name="done_on" value="${today()}" required></label>
      </div>
      <button class="primary">Log</button>
    </form>
    <section class="card" data-key="reps"><h2>Recent reps</h2>
      <div class="table-scroll"><table class="grid compact"><thead><tr><th scope="col">Day</th><th scope="col">Problem</th><th scope="col">Topic</th><th scope="col">Difficulty</th><th scope="col">Outcome</th><th scope="col">Min</th></tr></thead>
      <tbody>${newest("gym_reps", "done_on", 25, ["done_on", "url", "title", "slug", "platform", "topic", "difficulty", "outcome", "minutes"]).map((r) => html`<tr data-key="r${str(r.id)}"><td>${str(r.done_on)}</td>
        <td>${r.url ? html`<a href="${href(str(r.url))}" rel="noopener noreferrer" target="_blank">${str(r.title) || str(r.slug)}</a>` : str(r.title) || str(r.slug)}
          <span class="muted">${str(r.platform)}</span></td>
        <td>${str(r.topic)}</td><td>${str(r.difficulty)}</td><td>${str(r.outcome)}</td><td>${str(r.minutes)}</td></tr>`)}</tbody></table></div>
    </section>`
}

function net(n: Net): Html {
  const kinds = ENUMS.net_kind ?? []
  const url = settingsId() === 0 ? "" : str(value("settings", settingsId(), "net_lane_url"))
  return html`<section class="card facts" data-key="net-stats">
      ${kinds.map((k) => {
        const x = n[k] as { total: number; week: number } | undefined
        return html`<div class="stat"><b>${x?.week ?? 0}<small>/${x?.total ?? 0}</small></b><span>${k}s this week</span></div>`
      })}
      <div class="stat"><b>${String(n.unshipped ?? 0)}</b><span>unshipped</span></div>
      <form class="row" data-submit="net-url" data-act="net-url"><label>Lane URL <input type="url" name="net_lane_url" value="${url}" placeholder="https://"></label><button>Set</button></form>
    </section>
    <form class="card stack" data-submit="entry" data-act="entry" data-key="entry">
      <h2>Add an entry</h2>
      <div class="row">
        <label>Kind <select name="kind">${options("net_kind", "post")}</select></label>
        <label>Channel <select name="channel">${options("net_channel", "other")}</select></label>
        <label>Title <input name="title"></label>
        <label>URL <input type="url" name="url"></label>
        <label>Shipped <input type="date" name="shipped_on"></label>
      </div>
      <label>Body <textarea name="body" rows="4"></textarea></label>
      <button class="primary">Add</button>
    </form>
    <section class="card" data-key="entries"><h2>Entries</h2>
      <ul class="rows">${newest("net_entries", "shipped_on", 25, ["kind", "url", "title", "channel", "shipped_on"]).map((r) => html`<li data-key="e${str(r.id)}"><span class="tag">${str(r.kind)}</span>
        ${r.url ? html`<a href="${href(str(r.url))}" rel="noopener noreferrer" target="_blank">${str(r.title) || "untitled"}</a>` : str(r.title) || "untitled"}
        <span class="muted">${str(r.channel)} · ${str(r.shipped_on) || "not shipped"}</span></li>`)}</ul>
    </section>`
}

function view(): Html {
  const lane = model.address.sub === "net" ? "net" : "gym"
  const d = lanes() as { gym: Gym; net: Net } | null
  return html`<div class="lanes">
    <div class="toolbar"><nav class="subtabs" aria-label="Lanes">${["gym", "net"].map((l) => html`<a href="/lanes/${l}" data-nav data-key="${l}" class="${l === lane ? "on" : ""}"${l === lane ? html` aria-current="page"` : EMPTY}>${l}</a>`)}</nav></div>
    ${!d ? html`<p class="empty">Loading…</p>` : html`<div data-key="panes" data-morph="own"></div>`}
  </div>`
}

// Each lane draws into a pane of its own, kept while the other is shown, so switching back to a lane whose
// markup has not moved is one compare and an attribute, not a parse and a new subtree.
const drawn = new WeakMap<Element, string>()
function after(root: HTMLElement): void {
  const panes = root.querySelector<HTMLElement>('.lanes [data-key="panes"]')
  const d = lanes() as { gym: Gym; net: Net } | null
  if (!panes || !d) return
  const lane = model.address.sub === "net" ? "net" : "gym"
  for (const l of ["gym", "net"]) {
    let pane = panes.querySelector<HTMLElement>(`:scope > [data-lane="${l}"]`)
    if (l !== lane) {
      if (pane) pane.hidden = true
      continue
    }
    if (!pane) {
      pane = document.createElement("div")
      pane.dataset.lane = l
      panes.append(pane)
    }
    const h = l === "gym" ? gym(d.gym) : net(d.net)
    if (drawn.get(pane) !== h.text) {
      morph(pane, h)
      drawn.set(pane, h.text)
    }
    pane.hidden = false
  }
}

/** The form's filled fields: an empty one is left out, so the row's default stands. */
const filled = (el: HTMLElement): Record<string, Input> => Object.fromEntries(Object.entries(fields(el as HTMLFormElement)).filter(([, x]) => x !== ""))

const lanesLens: View = {
  title: "Lanes",
  view,
  after,
  act(name, el) {
    switch (name) {
      case "rep":
        return void resetAfter(el as HTMLFormElement, () => put("gym_reps", filled(el))).catch(failed)
      case "entry":
        return void resetAfter(el as HTMLFormElement, () => put("net_entries", filled(el))).catch(failed)
      case "target":
        return void putSettings({ gym_target: filled(el).gym_target ?? null }).catch(failed)
      case "net-url":
        return void putSettings({ net_lane_url: filled(el).net_lane_url ?? null }).catch(failed)
    }
  },
}

export default lanesLens
