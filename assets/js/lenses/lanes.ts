// The lanes: gym (reps, the daily target, the streak) and net (observer
// runs, artifacts, posts, drafts). Both tables are resident; the counts are
// the kernel's (`lanes`), the rows are read value by value, and a new rep
// or entry is a put judged locally first.

import type { View } from "../app.ts"
import { ENUMS, type TableName } from "../gen/schema.ts"
import { Refused, ids, lanes, put, today, value, type Input } from "../kernel.ts"
import { EMPTY, entries, flag, href, html, resetIfUnchanged, type Html } from "../morph.ts"
import { model, notice } from "../state.ts"

type Gym = { today: number; streak: number; week: number; target: number | null; pace: number | null; owed: number | null }
type Net = Record<string, { total: number; week: number } | number>

const str = (x: unknown): string => (x === null || x === undefined ? "" : x instanceof Date ? x.toISOString().slice(0, 10) : String(x))
const settingsId = (): number => ids("settings")[0] ?? 0

function failed(e: unknown): void {
  notice("error", e instanceof Refused ? `${e.code}: ${e.message}` : e instanceof Error ? e.message : String(e))
}

const options = (name: string, pick: string): Html => html`${(ENUMS[name] ?? []).map((x) => html`<option${flag("selected", x === pick)}>${x}</option>`)}`

/** A resident table's rows, newest first by a day column. */
function newest(t: TableName, by: string, n: number): number[] {
  return [...ids(t)].sort((a, b) => str(value(t, b, by)).localeCompare(str(value(t, a, by))) || b - a).slice(0, n)
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
        <label>Topic <select name="topic"><option value=""></option>${options("topic", "")}</select></label>
        <label>Difficulty <select name="difficulty"><option value=""></option>${options("difficulty", "")}</select></label>
        <label>Minutes <input type="number" name="minutes" min="0" max="600" class="narrow"></label>
        <label>Outcome <select name="outcome">${options("rep_outcome", "solved")}</select></label>
        <label>Day <input type="date" name="done_on" value="${today()}" required></label>
      </div>
      <button class="primary">Log</button>
    </form>
    <section class="card" data-key="reps"><h2>Recent reps</h2>
      <div class="table-scroll"><table class="grid compact"><thead><tr><th scope="col">Day</th><th scope="col">Problem</th><th scope="col">Topic</th><th scope="col">Difficulty</th><th scope="col">Outcome</th><th scope="col">Min</th></tr></thead>
      <tbody>${newest("gym_reps", "done_on", 60).map((id) => html`<tr data-key="r${id}"><td>${str(value("gym_reps", id, "done_on"))}</td>
        <td>${value("gym_reps", id, "url") ? html`<a href="${href(str(value("gym_reps", id, "url")))}" rel="noopener noreferrer" target="_blank">${str(value("gym_reps", id, "title")) || str(value("gym_reps", id, "slug"))}</a>` : str(value("gym_reps", id, "title")) || str(value("gym_reps", id, "slug"))}
          <span class="muted">${str(value("gym_reps", id, "platform"))}</span></td>
        <td>${str(value("gym_reps", id, "topic"))}</td><td>${str(value("gym_reps", id, "difficulty"))}</td><td>${str(value("gym_reps", id, "outcome"))}</td><td>${str(value("gym_reps", id, "minutes"))}</td></tr>`)}</tbody></table></div>
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
      <ul class="rows">${newest("net_entries", "shipped_on", 80).map((id) => html`<li data-key="e${id}"><span class="tag">${str(value("net_entries", id, "kind"))}</span>
        ${value("net_entries", id, "url") ? html`<a href="${href(str(value("net_entries", id, "url")))}" rel="noopener noreferrer" target="_blank">${str(value("net_entries", id, "title")) || "untitled"}</a>` : str(value("net_entries", id, "title")) || "untitled"}
        <span class="muted">${str(value("net_entries", id, "channel"))} · ${str(value("net_entries", id, "shipped_on")) || "not shipped"}</span></li>`)}</ul>
    </section>`
}

function view(): Html {
  const lane = model.address.sub === "net" ? "net" : "gym"
  const d = lanes() as { gym: Gym; net: Net } | null
  return html`<div class="lanes">
    <div class="toolbar"><nav class="subtabs" aria-label="Lanes">${["gym", "net"].map((l) => html`<a href="/lanes/${l}" data-nav data-key="${l}" class="${l === lane ? "on" : ""}"${l === lane ? html` aria-current="page"` : EMPTY}>${l}</a>`)}</nav></div>
    ${!d ? html`<p class="empty">Loading…</p>` : lane === "gym" ? gym(d.gym) : net(d.net)}
  </div>`
}

function fields(el: HTMLElement): Record<string, Input> {
  const out: Record<string, Input> = {}
  for (const [k, x] of new FormData(el as HTMLFormElement)) if (String(x) !== "") out[k] = String(x)
  return out
}

function setting(set: Record<string, Input>): void {
  const id = settingsId()
  void put("settings", set, id === 0 ? {} : { id }).catch(failed)
}

const lanesLens: View = {
  title: "Lanes",
  view,
  act(name, el) {
    switch (name) {
      case "rep":
        return void (() => { const before = entries(el as HTMLFormElement); return put("gym_reps", fields(el)).then(() => resetIfUnchanged(el as HTMLFormElement, before)) })().catch(failed)
      case "entry":
        return void (() => { const before = entries(el as HTMLFormElement); return put("net_entries", fields(el)).then(() => resetIfUnchanged(el as HTMLFormElement, before)) })().catch(failed)
      case "target":
        return setting({ gym_target: fields(el).gym_target ?? null })
      case "net-url":
        return setting({ net_lane_url: fields(el).net_lane_url ?? null })
    }
  },
}

export default lanesLens
