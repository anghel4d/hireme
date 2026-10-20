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
import { DIR, board, card, ids, lookup, query as read, scoreboard, step, value, type Filter, type Row } from "../kernel.ts"
import { EMPTY, html, str, type Html } from "../morph.ts"
import { format, go, model, query, set } from "../state.ts"
import { act as focusAct, body } from "./focus.ts"

/** The dense view: the board beside the selected card's whole application. */
const dense = (): boolean => model.address.q.get("view") === "dense"

const CLASSES = ["cool", "warm", "hot", "blocked"] as const

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
}

function chips(key: string, all: readonly string[], counts: readonly number[] | undefined, label: string): Html {
  const on = list(key)
  const shown = all.flatMap((x, i) => ((counts?.[i] ?? 0) > 0 || on.includes(x) ? [[x, i] as const] : []))
  if (shown.length === 0) return EMPTY
  return html`<div class="chips" role="group" aria-label="${label}" data-key="chips-${key}"><span class="chips-label">${label}</span>${shown.map(([x, i]) => html`<button type="button"
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

// The board is a window of fixed-size tiles placed by position (v1's geometry): only the rows in
// view (and one either side) are in the page, and a tile leaving the window is reused for one
// entering it, so search, filters and a return to the desk rewrite tiles instead of laying out a
// new grid.
const TILE_W = 250
/** The dense view packs narrower tiles: more of the board in view beside the application. */
const TILE_W_DENSE = 200
const TILE_H = 146
/** A narrow dense tile wraps its footer onto a second line: it is this much taller (app.css matches). */
const tileH = (): number => (dense() ? 166 : TILE_H)
const GAP = 10
const SPARE = 1

const shell = document.createElement("template")
shell.innerHTML = `<article class="app-card" data-act="open" data-click tabindex="-1" role="listitem">
  <header><span class="no"></span><span class="score"></span></header>
  <h3 class="company"></h3>
  <p class="role"></p>
  <p class="where muted"></p>
  <footer><span class="stage tag"></span><span class="band tag"></span><span class="heat"></span><span class="pips" role="img"></span></footer>
  <p class="lease muted"></p>
</article>`

const tiles = new Map<number, HTMLElement>()
const spare: HTMLElement[] = []
let cols = 1

function view(): Html {
  const ids = board(filter())
  // The view and a linked card are not filters.
  const any = [...model.address.q.keys()].some((k) => k !== "view" && k !== "card")
  return html`<div class="desk">
    <div class="toolbar" data-key="toolbar">
      <input type="search" class="search" placeholder="Search company, role, place or #no"
        data-act="search" data-on="input" data-morph="own" aria-label="Search the board" id="desk-search">
      <label class="inline">Score at least <input type="number" min="0" max="100" step="5" value="${model.address.q.get("min") ?? ""}" data-act="min" data-on="change" data-bound class="narrow" placeholder="0"></label>
      <span class="muted">${ids.length} shown</span>
      <nav class="subtabs views" aria-label="Desk view">${[["", "noob"], ["dense", "pro"]].map(([k, l]) => html`<a href="${viewHref(k!)}" data-nav data-key="v${k}" class="${(model.address.q.get("view") ?? "") === k ? "on" : ""}${k === "dense" ? " pro" : ""}">${l}</a>`)}</nav>
      ${any ? html`<a href="/desk" data-nav class="ghost">clear filters</a>` : EMPTY}
    </div>
    ${scores()}
    <div class="desk-split${dense() ? " dense" : ""}" data-key="split">
      <div class="board" role="list" aria-label="Applications" data-key="board" data-morph="own"></div>
      ${dense() ? html`<aside class="desk-detail" data-key="detail" aria-label="The selected application">${model.selected !== 0
        ? body(model.selected, true)
        : html`<p class="empty">Move to a card (h j k l or the arrows) and it opens here.</p>`}</aside>` : EMPTY}
    </div>
    ${ids.length === 0 ? html`<p class="empty">${any ? "Nothing matches these filters." : "No applications yet. An agent adds them through the MCP, or import a pack."}</p>` : EMPTY}
    <p class="hint keys">h j k l or arrows move · Enter opens · v pro view · / searches · 1–7 switch lenses</p>
  </div>`
}

/** The desk's query with its view set (and the card a link named dropped). */
const viewQ = (view: string): Map<string, string> => new Map([...[...model.address.q].filter(([k]) => k !== "view" && k !== "card"), ...(view === "" ? [] : [["view", view] as [string, string]])])
const viewHref = (view: string): string => format({ lens: "desk", sub: "", q: viewQ(view) })

function write(el: Element | null, s: string): void {
  if (el && el.textContent !== s) el.textContent = s
}

/** Which session's lease claims each application: the node's live lease rows (`held` is the claimed ids). */
function claims(): Map<number, string> {
  const by = new Map<number, string>()
  for (const l of ids("leases")) {
    const label = String(value("leases", l, "label") ?? "")
    for (const a of String(value("leases", l, "held") ?? "").split("\u001f")) if (a !== "") by.set(Number(a), label)
  }
  return by
}

/** Each drawn card, value by value. Its stage and claim are also attributes (data-stage, data-leased). */
// The board's width and document offset, measured where layout is already clean (a resize
// observer's turn, a scroll) and reused in `after`, so drawing never forces a layout mid-script.
let width = 0
let boardTop = 0
// window.scrollY flushes layout when the page is dirty, so the scroll is read where it is clean.
let scrolled = 0
let watched: HTMLElement | null = null
const sized = new ResizeObserver(() => {
  if (watched?.isConnected) paint(watched, true)
})

// A link to a card (`?card=<no>`) selects it once the rows are in, once per link.
let linked = ""

function after(root: HTMLElement): void {
  const no = model.address.q.get("card") ?? ""
  if (no !== linked) {
    const id = no === "" ? 0 : lookup("applications", "no", no)
    if (no === "" || id !== 0) linked = no
    if (id !== 0 && model.selected !== id) {
      set({ selected: id })
      queueMicrotask(() => reveal(id))
    }
  }
  // The search box is owned: its value is written here, so a keystroke leaves the desk's markup as it
  // was and the shell's morph is skipped. The box being typed in keeps what is in it.
  const q = root.querySelector<HTMLInputElement>("#desk-search")
  const want = model.address.q.get("q") ?? ""
  if (q && q !== document.activeElement && q.value !== want) q.value = want
  const el = root.querySelector<HTMLElement>(".board")
  if (!el) return
  if (watched !== el) {
    sized.disconnect()
    sized.observe(el)
    watched = el
  }
  // The first draw estimates the board from the window (reading it would force a layout of a page
  // that has not had one); the resize observer's turn, after layout and before paint, corrects it.
  if (width === 0) {
    width = Math.min(window.innerWidth, 1400) - (window.innerWidth <= 760 ? 20 : 32)
    boardTop = 0
  }
  paint(el, false)
}

/** Lays out the window of tiles for the current filter and scroll; writes each tile that changed. */
function paint(el: HTMLElement, measure: boolean): void {
  const ids = board(filter())
  if (measure) {
    scrolled = window.scrollY
    width = el.clientWidth
    boardTop = el.getBoundingClientRect().top + scrolled
  }
  cols = Math.max(1, Math.floor((width + GAP) / ((dense() ? TILE_W_DENSE : TILE_W) + GAP)))
  const w = (width - GAP * (cols - 1)) / cols
  const rows = Math.ceil(ids.length / cols)
  const h = `${Math.max(0, rows * (tileH() + GAP) - GAP)}px`
  if (el.style.height !== h) el.style.height = h
  const top = boardTop - scrolled
  const r0 = Math.max(0, Math.floor(-top / (tileH() + GAP)) - SPARE)
  const r1 = Math.min(rows - 1, Math.floor((window.innerHeight - top) / (tileH() + GAP)) + SPARE)
  const first = r0 * cols
  const last = Math.min(ids.length, (r1 + 1) * cols)
  const want = new Set(ids.subarray(first, last))
  // A tile leaving the window is hidden in place, not removed: taking it back is a write, not an insert.
  for (const [id, t] of tiles) {
    if (want.has(id)) continue
    tiles.delete(id)
    t.hidden = true
    spare.push(t)
  }
  const held = claims()
  for (let i = first; i < last; i++) {
    const id = ids[i] ?? 0
    let t = tiles.get(id)
    // Tiles from a board that was left (another lens drew over it) are taken back into this one.
    if (t && t.parentElement !== el) el.append(t)
    if (!t) {
      t = spare.pop() ?? (shell.content.firstElementChild!.cloneNode(true) as HTMLElement)
      t.dataset.id = String(id)
      t.dataset.sig = ""
      t.hidden = false
      tiles.set(id, t)
      if (t.parentElement !== el) el.append(t)
    }
    const at = `translate(${(i % cols) * (w + GAP)}px, ${Math.floor(i / cols) * (tileH() + GAP)}px)`
    if (t.style.transform !== at) t.style.transform = at
    const wpx = `${w}px`
    if (t.style.width !== wpx) t.style.width = wpx
  }
  // Every tile is placed before any is filled, so the board stands even if one card's numbers fail.
  // The tiles that changed read their rows in one find, not a kernel call per field.
  const stale: number[] = []
  for (let i = first; i < last; i++) {
    const id = ids[i] ?? 0
    if (tiles.get(id)?.dataset.sig !== sig(id, held.get(id))) stale.push(id)
  }
  if (stale.length === 0) return
  const found = new Map<number, Row>()
  for (const r of read<{ rows: Row[] }>("find", { table: "applications", where: { id: { in: stale } }, cols: COLS, limit: stale.length }).rows) found.set(Number(r.id), r)
  for (const id of stale) {
    const t = tiles.get(id)
    if (t) tile(t, id, held.get(id), found.get(id) ?? {})
  }
}

const COLS = ["id", "no", "company", "role", "location", "work_mode", "pips", "stage"]
const sig = (id: number, by: string | undefined): string => `${id}|${model.rows}|${id === model.selected ? 1 : 0}|${by ?? ""}`

/** One tile's values, rewritten only when the rows moved, its selection flipped or its claim changed. */
function tile(el: HTMLElement, id: number, by: string | undefined, r: Row): void {
  el.dataset.sig = sig(id, by)
  const c = card(id)
  const stage = c?.stage ?? str(r.stage)
  if (el.dataset.stage !== stage) el.dataset.stage = stage
  if (by === undefined) delete el.dataset.leased
  else if (el.dataset.leased !== by) el.dataset.leased = by
  write(el.querySelector(".lease"), by === undefined ? "" : `leased by ${by || "an agent"}`)
  write(el.querySelector(".no"), `#${str(r.no)}`)
  write(el.querySelector(".score"), c ? `${c.score_100}${c.stored ? "" : "?"}` : "")
  write(el.querySelector(".company"), str(r.company) || "(no company)")
  write(el.querySelector(".role"), str(r.role))
  write(el.querySelector(".where"), [r.location, r.work_mode].filter((x) => x).map(str).join(" · "))
  write(el.querySelector(".stage"), `${stage === "fire_ready" || stage === "open_fire" ? "draft · " : ""}${stage.replace(/_/g, " ")}`)
  write(el.querySelector(".band"), c?.band.replace(/_/g, " ") ?? "")
  write(el.querySelector(".heat"), c ? `${c.class}${c.reason !== "ok" ? ` · ${c.reason.replace(/_/g, " ")}` : ""}` : "")
  rail(el.querySelector(".pips"), str(r.pips))
  const heat = c?.class ?? "cool"
  if (el.dataset.heat !== heat) el.dataset.heat = heat
  const cls = `app-card band-${c?.band ?? "mid"}${id === model.selected ? " selected" : ""}`
  if (el.className !== cls) el.className = cls
  el.setAttribute("aria-current", id === model.selected ? "true" : "false")
  el.title = c && !c.stored ? "score is the kernel's suggestion; it never overwrites a stored score" : ""
}

// Scrolling or resizing moves the window without a render: the tiles in view are re-placed.
let queued = false
function repaint(): void {
  if (queued || model.address.lens !== "desk") return
  queued = true
  requestAnimationFrame(() => {
    queued = false
    const el = document.querySelector<HTMLElement>("#lens .board")
    if (el) paint(el, true)
  })
}
// A scroll event is dispatched in the frame it paints in, so the window is placed right there.
addEventListener("scroll", () => {
  scrolled = window.scrollY
  const el = model.address.lens === "desk" ? document.querySelector<HTMLElement>("#lens .board") : null
  if (el) paint(el, false)
}, { passive: true })
addEventListener("resize", repaint)

const PIP: Record<string, string> = { D: "done", A: "now", P: "to do", S: "skipped", B: "blocked" }

const HUE: Record<string, string> = { D: "var(--ok)", A: "var(--accent)", B: "var(--bad)" }
const wide = (p: string | undefined): number => (p === "A" ? 12 : 7)

// The stage rail is one element: each segment is a shadow of a 7×5 box parked left of the rail
// (`.pips::before`), so a new tile's rail is one style write, not nine elements to style and lay
// out. A 12 px segment is three overlapping shadows; a skipped one is a ring (a panel-coloured
// shadow 1 px smaller over a line-coloured one).
const RAILS = new Map<string, string>()
function look(pips: string): string {
  let css = RAILS.get(pips)
  if (css !== undefined) return css
  const shadows: string[] = []
  let x = 9
  for (const p of pips) {
    if (p === "S") shadows.push(`${x}px 0 0 -1px var(--panel)`, `${x}px 0 var(--line)`)
    else for (const dx of p === "A" ? [0, 2.5, 5] : [0]) shadows.push(`${x + dx}px 0 ${HUE[p] ?? "var(--line)"}`)
    x += wide(p) + 2
  }
  css = `width: ${Math.max(0, x - 11)}px; --rail: ${shadows.join(", ") || "none"}`
  RAILS.set(pips, css)
  return css
}

/** The stage rail as one small segment per stage; the segment under the pointer names itself in the title. */
function rail(el: HTMLElement | null, pips: string): void {
  if (!el || el.dataset.pips === pips) return
  el.dataset.pips = pips
  el.style.cssText = look(pips)
  const now = pips.indexOf("A")
  el.setAttribute("aria-label", now >= 0 ? `stage ${now + 1} of ${pips.length}` : "")
}

addEventListener("mousemove", (ev) => {
  const el = ev.target as HTMLElement
  if (!el.classList?.contains("pips")) return
  const pips = el.dataset.pips ?? ""
  let i = 0
  for (let x = 0; i < pips.length - 1; i++) if (ev.offsetX < (x += wide(pips[i]) + 2) - 1) break
  const t = pips === "" ? "" : `${(STAGE[i] ?? "").replace(/_/g, " ")}: ${PIP[pips[i] ?? ""] ?? pips[i]}`
  if (el.title !== t) el.title = t
}, { passive: true })


function move(dir: number): void {
  const f = filter()
  const next = step(f, model.selected, dir, cols)
  if (next === 0) return
  set({ selected: next })
  reveal(next)
}

/** Brings a card's row into view; the window follows the scroll. */
function reveal(id: number): void {
  const at = board(filter()).indexOf(id)
  if (at < 0) return
  const y = boardTop + Math.floor(at / cols) * (tileH() + GAP)
  if (y < scrolled + 56) window.scrollTo(0, y - 56)
  else if (y + tileH() > scrolled + window.innerHeight) window.scrollTo(0, y + tileH() - window.innerHeight + GAP)
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
        // The board is the kernel's, so the answer is drawn in the keystroke's frame (no debounce).
        return query("q", (el as HTMLInputElement).value)
      }
      case "min":
        return query("min", (el as HTMLInputElement).value)
      case "open": {
        const id = Number(el.dataset.id)
        if (model.selected === id) return open(id)
        return set({ selected: id })
      }
      // The dense pane is the focus lens's own markup: its controls are its actions.
      default:
        if (model.selected !== 0) focusAct(name, el, model.selected)
    }
  },
  key(ev) {
    const k = ev.key
    // Vim's grid: h left, j down, k up, l right; the arrows the same.
    if (k === "l" || k === "ArrowRight") move(DIR.next)
    else if (k === "h" || k === "ArrowLeft") move(DIR.prev)
    else if (k === "j" || k === "ArrowDown") move(DIR.down)
    else if (k === "k" || k === "ArrowUp") move(DIR.up)
    else if (k === "v") go({ q: viewQ(dense() ? "" : "dense") }, true)
    else if (k === "Escape" && dense() && (model.focus.edit !== "" || model.focus.fireArmed !== 0)) set({ focus: { ...model.focus, edit: "", fireArmed: 0 } })
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
