// The desk: the board of applications ranked by score_100, then heat,
// narrowed by band, stage, heat and search (all in the address), with the
// scoreboard above it and keyboard movement across it.
//
// Order, filter, selection geometry and every card's numbers are the
// kernel's (`board`, `step`, `card`, `scoreboard`); this file only lays
// them out. The board's frame is morphed like any lens, but each card is
// owned (`data-morph="own"`) once it lands and written value by value in
// `after`, so a PATCH that moves one score rewrites one text node, not the
// board.

import type { View } from "../app.ts"
import { BAND, STAGE } from "../gen/schema.ts"
import { DIR, board, card, scoreboard, step, value, type Filter } from "../kernel.ts"
import { EMPTY, html, type Html } from "../morph.ts"
import { go, model, query, set } from "../state.ts"

const CLASSES = ["cool", "warm", "hot", "blocked"] as const
const PAGE = 120

const list = (k: string): string[] => (model.address.q.get(k) ?? "").split(",").filter((s) => s !== "")

function filter(): Filter {
  const f: Filter = {}
  const bands = list("band")
  const stages = list("stage")
  const classes = list("heat")
  const q = model.address.q.get("q") ?? ""
  const min = Number(model.address.q.get("min") ?? 0)
  if (bands.length > 0) f.bands = bands
  if (stages.length > 0) f.stages = stages
  if (classes.length > 0) f.classes = classes
  if (q !== "") f.search = q
  if (min > 0) f.min_score = Math.min(100, min)
  return f
}

function toggle(key: string, v: string): void {
  const now = list(key)
  query(key, (now.includes(v) ? now.filter((x) => x !== v) : [...now, v]).join(","))
  set({ deskLimit: PAGE })
}

function chips(key: string, all: readonly string[], counts: readonly number[] | undefined, label: string): Html {
  const on = list(key)
  return html`<div class="chips" role="group" aria-label="${label}" data-key="chips-${key}">${all.map((x, i) => html`<button type="button"
      class="chip${on.includes(x) ? " on" : ""} chip-${x}" aria-pressed="${String(on.includes(x))}" data-act="toggle" data-k="${key}" data-v="${x}" data-key="${x}">
      ${x.replace(/_/g, " ")}${counts ? html` <span class="n">${counts[i] ?? 0}</span>` : EMPTY}</button>`)}</div>`
}

function scores(): Html {
  const s = scoreboard() as {
    total?: number; by_stage?: number[]; by_band?: number[]; by_class?: number[]; submitted?: number; submitted_today?: number
    goal_total?: number | null; goal_daily?: number | null; goal_days_left?: number | null
  } | null
  if (!s) return EMPTY
  const goal = s.goal_total ?? null
  return html`<section class="scoreboard" data-key="scoreboard" aria-label="Scoreboard">
      <div class="stat"><b>${s.total ?? 0}</b><span>applications</span></div>
      <div class="stat"><b>${s.submitted ?? 0}${goal ? html`<small>/${goal}</small>` : EMPTY}</b><span>submitted</span></div>
      <div class="stat"><b>${s.submitted_today ?? 0}${s.goal_daily ? html`<small>/${s.goal_daily}</small>` : EMPTY}</b><span>today</span></div>
      ${s.goal_days_left !== null && s.goal_days_left !== undefined ? html`<div class="stat"><b>${s.goal_days_left}</b><span>days to goal</span></div>` : EMPTY}
    </section>
    ${chips("stage", STAGE, s.by_stage, "Stage")}
    ${chips("band", BAND, s.by_band, "Band")}
    ${chips("heat", CLASSES, s.by_class, "Heat")}`
}

/** A card's first landing; `after` keeps it current from then on. */
function cardShell(id: number): Html {
  return html`<article class="app-card" data-key="a${id}" data-id="${id}" data-morph="own" data-act="open" data-click tabindex="-1">
    <header><span class="no"></span><span class="score"></span></header>
    <h3 class="company"></h3>
    <p class="role"></p>
    <p class="where muted"></p>
    <footer><span class="stage tag"></span><span class="band tag"></span><span class="heat"></span><span class="pips"></span></footer>
  </article>`
}

function view(): Html {
  const ids = board(filter())
  const shown = ids.subarray(0, model.deskLimit)
  const any = model.address.q.size > 0
  return html`<div class="desk">
    <div class="toolbar" data-key="toolbar">
      <input type="search" class="search" placeholder="Search company, role, place or #no" value="${model.address.q.get("q") ?? ""}"
        data-act="search" data-on="input" data-bound aria-label="Search the board" id="desk-search">
      <label class="inline">min score <input type="number" min="0" max="100" step="5" value="${model.address.q.get("min") ?? ""}" data-act="min" data-on="change" data-bound class="narrow"></label>
      <span class="muted">${ids.length} shown</span>
      ${any ? html`<a href="/desk" data-nav class="ghost">clear filters</a>` : EMPTY}
    </div>
    ${scores()}
    <div class="board" role="list" aria-label="Applications" data-key="board">${Array.from(shown, (id) => cardShell(id))}</div>
    ${ids.length === 0 ? html`<p class="empty">${any ? "Nothing matches these filters." : "No applications yet. An agent adds them through the MCP, or import a pack."}</p>` : EMPTY}
    ${ids.length > shown.length ? html`<button type="button" data-act="more" class="more">Show ${Math.min(PAGE, ids.length - shown.length)} more of ${ids.length - shown.length}</button>` : EMPTY}
    <p class="hint keys">j/k or arrows move · Enter opens · / searches · 1–7 switch lenses</p>
  </div>`
}

const text = (x: unknown): string => (x === null || x === undefined ? "" : x instanceof Date ? x.toISOString().slice(0, 10) : String(x))

function write(el: Element | null, s: string): void {
  if (el && el.textContent !== s) el.textContent = s
}

/** Each drawn card, value by value. */
function after(root: HTMLElement): void {
  for (const el of root.querySelectorAll<HTMLElement>("article.app-card")) {
    const id = Number(el.dataset.id)
    const c = card(id)
    write(el.querySelector(".no"), `#${text(value("applications", id, "no"))}`)
    write(el.querySelector(".score"), c ? `${c.score_100}${c.stored ? "" : "?"}` : "")
    write(el.querySelector(".company"), text(value("applications", id, "company")) || "(no company)")
    write(el.querySelector(".role"), text(value("applications", id, "role")))
    write(el.querySelector(".where"), [value("applications", id, "location"), value("applications", id, "work_mode")].filter((x) => x).map(text).join(" · "))
    write(el.querySelector(".stage"), (c?.stage ?? text(value("applications", id, "stage"))).replace(/_/g, " "))
    write(el.querySelector(".band"), c?.band.replace(/_/g, " ") ?? "")
    write(el.querySelector(".heat"), c ? `${c.class}${c.reason !== "ok" ? ` · ${c.reason.replace(/_/g, " ")}` : ""}` : "")
    write(el.querySelector(".pips"), text(value("applications", id, "pips")))
    const cls = `app-card heat-${c?.class ?? "cool"} band-${c?.band ?? "mid"}${id === model.selected ? " selected" : ""}`
    if (el.className !== cls) el.className = cls
    el.setAttribute("aria-current", id === model.selected ? "true" : "false")
    el.title = c && !c.stored ? "score is the kernel's suggestion; it never overwrites a stored score" : ""
  }
}

let typing = 0

function columns(): number {
  const cards = document.querySelectorAll<HTMLElement>("article.app-card")
  const top = cards[0]?.offsetTop
  let n = 0
  for (const c of cards) {
    if (c.offsetTop !== top) break
    n++
  }
  return Math.max(1, n)
}

function move(dir: number): void {
  const f = filter()
  const next = step(f, model.selected, dir, columns())
  if (next === 0) return
  const ids = board(f)
  const at = ids.indexOf(next)
  set({ selected: next, ...(at >= model.deskLimit ? { deskLimit: Math.ceil((at + 1) / PAGE) * PAGE } : {}) })
  requestAnimationFrame(() => document.querySelector(`article.app-card[data-id="${next}"]`)?.scrollIntoView({ block: "nearest" }))
}

function open(id: number): void {
  const no = value("applications", id, "no")
  if (no !== null) go({ lens: "focus", sub: String(no), q: new Map() })
}

const desk: View = {
  title: "Desk",
  view,
  after,
  act(name, el) {
    switch (name) {
      case "toggle":
        return toggle(el.dataset.k ?? "", el.dataset.v ?? "")
      case "search": {
        const v = (el as HTMLInputElement).value
        clearTimeout(typing)
        typing = window.setTimeout(() => {
          query("q", v)
          set({ deskLimit: PAGE })
        }, 120)
        return
      }
      case "min":
        return query("min", (el as HTMLInputElement).value)
      case "more":
        return set({ deskLimit: model.deskLimit + PAGE })
      case "open": {
        const id = Number(el.dataset.id)
        if (model.selected === id) return open(id)
        return set({ selected: id })
      }
    }
  },
  key(ev) {
    const k = ev.key
    if (k === "j" || k === "ArrowRight") move(DIR.next)
    else if (k === "k" || k === "ArrowLeft") move(DIR.prev)
    else if (k === "ArrowDown") move(DIR.down)
    else if (k === "ArrowUp") move(DIR.up)
    else if (k === "g" || k === "Home") move(DIR.first)
    else if (k === "G" || k === "End") move(DIR.last)
    else if ((k === "Enter" || k === "o") && model.selected !== 0) open(model.selected)
    else if (k === "/") document.getElementById("desk-search")?.focus()
    else if (k === "Escape" && model.address.q.size > 0) go({ q: new Map() }, true)
    else return false
    return true
  },
}

export default desk
