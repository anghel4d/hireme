// The desk: the board of applications ranked by score_100, then heat,
// narrowed by band, stage, heat and search (all in the address), with the
// scoreboard above it and keyboard movement across it: /desk, /desk/pro/<item> (the board beside the
// selected application whole), /desk/<item> (one application opened in place; Escape backs out).
//
// The kernel's board (score, then heat) narrowed by its filters is the
// start; work modes narrow it further here, a sort reorders it and a group-by
// cuts it into bands with headers, and every card's numbers are the
// kernel's (`card`, `scoreboard`). Possible duplicates (one posting by its
// URL, or the same company, role and place) are counted on each card and
// gathered by grouping on them, where one click keeps the furthest along. The board's frame is morphed like any lens, but each card is
// owned (`data-morph="own"`) once it lands and written value by value in
// `after`, so a PATCH that moves one score rewrites one text node, not the
// board.

import type { View } from "../app.ts"
import { BAND, ENUMS, STAGE } from "../gen/schema.ts"
import { board, card, drop, failed, ids, lookup, page as rowsOf, query as read, scoreboard, value, type Filter, type Row } from "../kernel.ts"
import { EMPTY, html, str, type Html } from "../morph.ts"
import { format, go, itemNo, model, query, set } from "../state.ts"
import { act as focusAct, appItem, body } from "./focus.ts"

/** The pro view: the board beside the selected card's whole application. */
const dense = (): boolean => model.address.sub === "pro"
/** One application opened in place of the board. */
const opened = (): boolean => !dense() && model.address.item !== ""
const openedId = (): number => lookup("applications", "no", String(itemNo()))

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
    ${chips("heat", CLASSES, s.by_class, "Heat")}
    ${chips("mode", MODES, layout().modes, "Work")}`
}

// ------------------------------------------------------------------ order and groups

const MODES = ENUMS.work_mode ?? []
const HEAT_ORDER = ["hot", "warm", "cool", "blocked"]
/** Every key a card shows, and when it was added: its name in Sort by, in Group by, and the direction it reads in first (1 rising). */
const KEYS: [string, string, string, 1 | -1][] = [
  ["score", "score", "score, by tens", -1], ["no", "#", "#, by hundreds", 1], ["company", "company", "company", 1], ["role", "role", "role", 1],
  ["place", "location", "location", 1], ["mode", "work mode", "work mode", 1], ["stage", "stage", "stage", 1], ["band", "band", "band", 1],
  ["heat", "heat", "heat", 1], ["why", "heat reason", "heat reason", 1], ["lease", "leased by", "leased by", 1],
  ["dupes", "duplicates", "possible duplicates", -1], ["added", "added", "day added", -1],
]
const SORTS: [string, string][] = KEYS.map(([k, l]) => [k, l])
const GROUPS: [string, string][] = [["", "nothing"], ...KEYS.map(([k, , g]): [string, string] => [k, g])]
const firstDir = (k: string): 1 | -1 => KEYS.find(([x]) => x === k)?.[3] ?? 1
/** The sort in the address, and the direction it runs in: as asked, else the key's own. */
const sortKey = (): string => model.address.q.get("sort") ?? "score"
const sortDir = (): number => ({ asc: 1, desc: -1 })[model.address.q.get("dir") ?? ""] ?? firstDir(sortKey())

/** Every application's sorting and grouping fields, and its duplicates, worked out once per change of the rows. */
let fields: { rows: number; by: Map<number, Row>; dupes: Map<number, number[]>; sets: number; mode: Map<number, number>; modes: boolean } | null = null
function rowsById(): Map<number, Row> {
  if (fields?.rows !== model.rows) {
    const cols = ["id", "no", "company", "role", "location", "work_mode", "stage", "inserted_at", "listing_url", "canonical_url"]
    const by = new Map(rowsOf({ table: "applications", cols }, 100_000).rows.map((r) => [Number(r.id), r]))
    const mode = new Map([...by].map(([id, r]) => [id, MODES.indexOf(str(r.work_mode))]))
    const dupes = duplicates(by)
    fields = { rows: model.rows, by, dupes, sets: new Set(dupes.values()).size, mode, modes: [...mode.values()].some((i) => i >= 0) }
  }
  return fields.by
}

/** Text as compared: case, accents, punctuation and a company's legal form left out. */
const norm = (x: unknown): string => str(x).toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
  .replace(/[^\p{L}\p{N}]+/gu, " ").replace(/\b(inc|llc|ltd|gmbh|ag|sa|bv|plc|corp|corporation|co|limited|the)\b/g, "").replace(/\s+/g, " ").trim()
/** A posting's URL as the server keys it (Provenance.canonical): host without www, no fragment or tracking, sorted query. */
function posting(x: unknown): string {
  try {
    const u = new URL(str(x))
    const q = [...u.searchParams].filter(([k]) => !/^(utm_.*|gclid|fbclid|msclkid|mc_cid|mc_eid|ref|ref_src|refid|trk|trkinfo|trackingid|src|source|origin|from|lever-source|lever-origin|gh_src|sid|share_?id|campaign|medium)$/i.test(k)).sort()
    return `${u.host.toLowerCase().replace(/^www\./, "")}${u.pathname.replace(/\/+$/, "")}?${new URLSearchParams(q)}`
  } catch {
    return ""
  }
}

/** Sets of applications that look like one posting: the same URL, or the same company, role and place. */
function duplicates(by: Map<number, Row>): Map<number, number[]> {
  const parent = new Map<number, number>()
  const root = (id: number): number => {
    let r = id
    while (parent.get(r) !== undefined && parent.get(r) !== r) r = parent.get(r)!
    return r
  }
  const seen = new Map<string, number>()
  for (const [id, r] of by) {
    const keys = [posting(r.canonical_url || r.listing_url), norm(r.company) && norm(r.role) ? `${norm(r.company)}|${norm(r.role)}|${norm(r.location)}` : ""]
    for (const k of keys) {
      if (k === "" || k === "?") continue
      const other = seen.get(k)
      if (other === undefined) seen.set(k, id)
      else parent.set(root(id), root(other))
    }
  }
  const sets = new Map<number, number[]>()
  for (const id of by.keys()) {
    const r = root(id)
    sets.set(r, [...(sets.get(r) ?? []), id])
  }
  const of = new Map<number, number[]>()
  for (const set of sets.values()) if (set.length > 1) for (const id of set) of.set(id, set)
  return of
}

type Group = { key: string; label: string; ids: Uint32Array | number[]; keep?: number | undefined }
type Layout = { key: string; groups: Group[]; order: Uint32Array | number[]; dupes: Map<number, number[]>; grouped: boolean; modes: number[]; sets: number }
let laid: Layout | null = null

type Val = string | number | null
/** A key's value on a card (null when the card has none: last whichever way), and its group: a key and a label; null leaves the card out. */
type Key = { value: (id: number) => Val; group: (id: number) => [string, string] | null }

function keys(by: Map<number, Row>, dupes: Map<number, number[]>, held: Map<number, string>): Record<string, Key> {
  const row = (id: number): Row => by.get(id) ?? {}
  const text = (get: (id: number) => unknown): Key => ({
    value: (id) => norm(get(id)) || null,
    group: (id) => [norm(get(id)), str(get(id)) || "(none)"],
  })
  // An enum reads in its declared order (the pipeline's, the bands', hot to blocked).
  const listed = (all: readonly string[], get: (id: number) => string): Key => ({
    value: (id) => (all.indexOf(get(id)) < 0 ? null : all.indexOf(get(id))),
    group: (id) => [get(id), get(id).replace(/_/g, " ") || "(none)"],
  })
  // A number groups by ranges of `size`, the last one from `top` up.
  const ranged = (get: (id: number) => number | null, size: number, show: (lo: number) => string, top = Infinity): Key => ({
    value: get,
    group: (id) => {
      const v = get(id)
      if (v === null) return ["", "(none)"]
      const lo = Math.min(top, Math.floor(v / size) * size)
      return [String(lo), show(lo)]
    },
  })
  const score = (id: number): number | null => card(id)?.score_100 ?? null
  const reason = (id: number): string => (card(id)?.reason ?? "ok") === "ok" ? "" : card(id)!.reason
  return {
    score: ranged(score, 10, (lo) => `${lo}–${lo === 90 ? 100 : lo + 9}`, 90),
    no: ranged((id) => Number(row(id).no ?? 0) || null, 100, (lo) => `#${Math.max(1, lo)}–${lo + 99}`),
    company: text((id) => row(id).company),
    role: text((id) => row(id).role),
    place: text((id) => row(id).location),
    mode: listed(MODES, (id) => str(row(id).work_mode)),
    stage: listed(STAGE, (id) => str(row(id).stage)),
    band: listed(BAND, (id) => card(id)?.band ?? ""),
    heat: listed(HEAT_ORDER, (id) => card(id)?.class ?? ""),
    why: { value: (id) => reason(id) || null, group: (id) => [reason(id), reason(id).replace(/_/g, " ") || "(none)"] },
    lease: { value: (id) => held.get(id) ?? null, group: (id) => (held.has(id) ? [`l${held.get(id)}`, `leased by ${held.get(id) || "an agent"}`] : ["", "not leased"]) },
    dupes: {
      value: (id) => dupes.get(id)?.length ?? null,
      group: (id) => (dupes.has(id) ? [String(Math.min(...dupes.get(id)!)), `${str(row(id).company) || "(no company)"} · ${str(row(id).role)}`] : null),
    },
    added: { value: (id) => str(row(id).inserted_at) || null, group: (id) => [str(row(id).inserted_at).slice(0, 10), str(row(id).inserted_at).slice(0, 10) || "(none)"] },
  }
}

/** Text as people order it: "Company 2" before "Company 10". */
const COLLATE = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" })

/** Two values in `dir` (1 rising), a missing one last either way. */
function compare(a: Val, b: Val, dir: number): number {
  if (a === null || b === null) return a === b ? 0 : a === null ? 1 : -1
  return dir * (typeof a === "number" && typeof b === "number" ? a - b : COLLATE.compare(String(a), String(b)))
}

/** The board as drawn: the kernel's filtered order, narrowed by work mode, sorted by any key a card shows, and grouped by any. */
function layout(): Layout {
  const q = model.address.q
  const key = `${model.rows}|${[...q].map(([k, v]) => `${k}=${v}`).join("&")}`
  if (laid?.key === key) return laid
  const by = rowsById()
  const dupes = fields!.dupes
  const modes = list("mode")
  const base = board(filter())
  // One pass: the work modes' counts over the filtered board, and the board narrowed to the modes picked.
  const counts = MODES.map(() => 0)
  const kept: number[] = []
  const picked = modes.map((m) => MODES.indexOf(m))
  if (fields!.modes || picked.length > 0)
    for (const id of base) {
      const i = fields!.mode.get(id) ?? -1
      if (i >= 0) counts[i]!++
      if (picked.length > 0 && picked.includes(i)) kept.push(id)
    }
  const sets = fields!.sets
  const sk = sortKey()
  const gk = q.get("group") ?? ""
  // The common case, the kernel's order as it is (score, then heat): no copy, no sort, one group.
  if (modes.length === 0 && sk === "score" && sortDir() === -1 && gk === "") {
    laid = { key, groups: [{ key: "", label: "", ids: base }], order: base, dupes, grouped: false, modes: counts, sets }
    return laid
  }
  const K = keys(by, dupes, claims())
  let order = modes.length > 0 ? kept : [...base]
  // Sorted on each card's value read once; equal values keep the kernel's order.
  const S = K[sk]
  if (S && !(sk === "score" && sortDir() === -1)) {
    const v = new Map(order.map((id) => [id, S.value(id)]))
    order = order.map((id, i) => [id, i] as const).sort((x, y) => compare(v.get(x[0])!, v.get(y[0])!, sortDir()) || x[1] - y[1]).map(([id]) => id)
  }
  const G = K[gk]
  let groups: Group[] = [{ key: "", label: "", ids: order }]
  if (G) {
    // Groups keep the sort inside them, and stand in their key's order: the sort's own way when it is the same key.
    const at = new Map<string, Group & { v: Val }>()
    for (const id of order) {
      const g = G.group(id)
      if (!g) continue
      if (!at.has(g[0])) at.set(g[0], { key: g[0], label: g[1], ids: [], v: G.value(id) })
      ;(at.get(g[0])!.ids as number[]).push(id)
    }
    const dir = gk === sk ? sortDir() : firstDir(gk)
    groups = [...at.values()].sort((a, b) => compare(a.v, b.v, dir))
  }
  // Of each set of duplicates, the one furthest along (then the first made) is the one to keep.
  if (gk === "dupes") {
    const stageAt = (id: number): number => (STAGE as readonly string[]).indexOf(str(by.get(id)?.stage))
    for (const x of groups) x.keep = [...x.ids].sort((a, b) => stageAt(b) - stageAt(a) || Number(by.get(a)?.no) - Number(by.get(b)?.no))[0]
  }
  laid = { key, groups, order: groups.flatMap((x) => [...x.ids]), dupes, grouped: Boolean(G), modes: counts, sets }
  return laid
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
  <header><span class="no"></span><span class="dupes"></span><span class="score"></span></header>
  <h3 class="company"></h3>
  <p class="role"></p>
  <p class="where muted"></p>
  <footer><span class="stage tag"></span><span class="band tag"></span><span class="heat"></span><span class="pips" role="img"></span></footer>
  <p class="lease muted"></p>
</article>`

const tiles = new Map<number, HTMLElement>()
const spare: HTMLElement[] = []
let cols = 1

/** An opened application, or the page saying it is gone. */
function page(): Html {
  const id = openedId()
  if (id === 0) return html`<div class="empty" data-key="gone"><p>${model.rows === 0 ? "Loading…" : `No application #${itemNo()} on this desk: it was deleted, or the link is from another account.`}</p>
    <p><a href="/desk" data-act="back" class="button">Back to the desk</a></p></div>`
  return html`${body(id, false)}<p class="hint keys">j k next and previous · Esc back to the desk · 1–5 switch lenses</p>`
}

function view(): Html {
  if (opened()) return page()
  const L = layout()
  const ids = L.order
  const any = model.address.q.size > 0
  const sets = L.sets
  // The selects are owned: their options are written once in after(), so the markup redrawn on every
  // keystroke stays short (parsing it is most of a redraw).
  const pick = (k: string, label: string): Html => html`<label class="inline" data-key="pick-${k}">${label} <select data-act="${k}" data-on="change" data-morph="own" aria-label="${label}"></select></label>`
  return html`<div class="desk${dense() ? " pro" : ""}">
    <div class="desk-top" data-key="top">
    <div class="toolbar" data-key="toolbar">
      <input type="search" class="search" placeholder="Search company, role, place or #no"
        data-act="search" data-on="input" data-morph="own" aria-label="Search the board" id="desk-search">
      <label class="inline">Score at least <input type="number" min="0" max="100" step="5" value="${model.address.q.get("min") ?? ""}" data-act="min" data-on="change" data-bound class="narrow" placeholder="0"></label>
      ${pick("sort", "Sort by")}<button type="button" class="ghost dir" data-act="dir" data-key="dir" aria-label="Sort direction" title="${sortDir() > 0 ? "Rising; click for falling" : "Falling; click for rising"}">${sortDir() > 0 ? "↑" : "↓"}</button>${pick("group", "Group by")}
      <span class="muted">${ids.length} shown</span>
      ${sets > 0 && model.address.q.get("group") !== "dupes" ? html`<button type="button" class="ghost dupes-link" data-act="group-dupes">${sets} possible duplicate${sets === 1 ? "" : "s"}</button>` : EMPTY}
      <nav class="subtabs views" aria-label="Desk view">${["", "pro"].map((k) => html`<a href="${viewHref(k, model.address.q)}" data-nav data-key="v${k}" class="${model.address.sub === k ? "on" : ""}${k === "pro" ? " pro" : ""}">${k || "noob"}</a>`)}</nav>
      ${any ? html`<a href="${viewHref(model.address.sub, new Map())}" data-nav class="ghost">clear filters</a>` : EMPTY}
    </div>
    ${scores()}
    </div>
    <div class="desk-split${dense() ? " dense" : ""}" data-key="split">
      <div class="board" role="list" aria-label="Applications" data-key="board" data-morph="own"></div>
      ${dense() ? html`<aside class="desk-detail" data-key="detail" aria-label="The selected application">${model.selected !== 0
        ? body(model.selected, true)
        : html`<p class="empty">No application matches these filters.</p>`}</aside>` : EMPTY}
    </div>
    ${ids.length === 0 ? html`<p class="empty">${any ? "Nothing matches these filters." : "No applications yet. An agent adds them through the MCP, or import a pack."}</p>` : EMPTY}
    <p class="hint keys">h j k l or arrows move · Enter or a second click opens · v pro view · / searches · 1–5 switch lenses</p>
  </div>`
}

const viewHref = (sub: string, q: ReadonlyMap<string, string>): string => format({ lens: "desk", sub, item: "", q })

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

// The pro view's item selects its card once the rows are in, once per address.
let linked = 0
/** The open application came from the board (history's entry before it), and where the board was scrolled. */
let fromBoard = false
let returnY = -1

function after(root: HTMLElement): void {
  if (opened()) {
    // The item's slug follows the application's company and role: an old link is rewritten to the current one.
    const id = openedId()
    if (id !== 0 && model.selected !== id) set({ selected: id })
    if (id !== 0 && appItem(id) !== model.address.item) go({ item: appItem(id) }, true)
    return
  }
  const no = dense() ? itemNo() : 0
  if (no !== linked) {
    const id = no === 0 ? 0 : lookup("applications", "no", String(no))
    if (no === 0 || id !== 0) linked = no
    if (id !== 0 && model.selected !== id) {
      set({ selected: id })
      queueMicrotask(() => reveal(id))
    }
  }
  // Something is always selected: the first card in view, whenever none is or the filter hid it.
  const order = layout().order
  const first = order[0]
  if (first !== undefined && !order.includes(model.selected)) set({ selected: first })
  // The pro view's address names the selected card, rewritten in place as the selection moves.
  if (dense() && model.selected !== 0) {
    const want = appItem(model.selected)
    if (want !== model.address.item) {
      linked = itemNo(want)
      go({ item: want }, true)
    }
  }
  for (const [k, opts] of [["sort", SORTS], ["group", GROUPS]] as const) {
    const sel = root.querySelector<HTMLSelectElement>(`select[data-act="${k}"]`)
    if (!sel) continue
    if (sel.options.length === 0) sel.append(...opts.map(([v, l]) => new Option(l, v)))
    const want = k === "sort" ? sortKey() : model.address.q.get(k) ?? ""
    if (sel.value !== want) sel.value = want
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
  if (returnY >= 0) {
    window.scrollTo(0, returnY)
    returnY = -1
  }
}

/** Where each group's header and rows stand on the board, for drawing, moving and revealing. */
type Placed = { g: Group; top: number; rowsTop: number }
let placed: Placed[] = []
const HEAD = 36

/** Lays out the window of tiles (and group headers) for the current layout and scroll; writes each tile that changed. */
function paint(el: HTMLElement, measure: boolean): void {
  const L = layout()
  if (measure) {
    scrolled = window.scrollY
    width = el.clientWidth
    boardTop = el.getBoundingClientRect().top + scrolled
  }
  cols = Math.max(1, Math.floor((width + GAP) / ((dense() ? TILE_W_DENSE : TILE_W) + GAP)))
  const w = (width - GAP * (cols - 1)) / cols
  const step = tileH() + GAP
  let y = 0
  placed = L.groups.map((g) => {
    const top = y
    if (L.grouped) y += HEAD
    const p = { g, top, rowsTop: y }
    y += Math.ceil(g.ids.length / cols) * step + (L.grouped ? GAP : 0)
    return p
  })
  const h = `${Math.max(0, y - GAP)}px`
  if (el.style.height !== h) el.style.height = h
  const top = boardTop - scrolled
  const v0 = -top - SPARE * step
  const v1 = window.innerHeight - top + SPARE * step
  const at = new Map<number, string>()
  const heads = new Set<string>()
  for (const p of placed) {
    if (L.grouped && p.top + HEAD > v0 && p.top < v1) heads.add(p.g.key)
    const r0 = Math.max(0, Math.floor((v0 - p.rowsTop) / step))
    const r1 = Math.min(Math.ceil(p.g.ids.length / cols) - 1, Math.floor((v1 - p.rowsTop) / step))
    for (let r = r0; r <= r1; r++)
      for (let c = 0; c < cols; c++) {
        const id = p.g.ids[r * cols + c]
        if (id !== undefined) at.set(id, `translate(${c * (w + GAP)}px, ${p.rowsTop + r * step}px)`)
      }
  }
  headers(el, L, heads, width)
  // A tile leaving the window is hidden in place, not removed: taking it back is a write, not an insert.
  for (const [id, t] of tiles) {
    if (at.has(id)) continue
    tiles.delete(id)
    t.hidden = true
    spare.push(t)
  }
  const held = claims()
  const wpx = `${w}px`
  for (const [id, transform] of at) {
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
    if (t.style.transform !== transform) t.style.transform = transform
    if (t.style.width !== wpx) t.style.width = wpx
  }
  // Every tile is placed before any is filled, so the board stands even if one card's numbers fail.
  // The tiles that changed read their rows in one find, not a kernel call per field.
  const stale = [...at.keys()].filter((id) => tiles.get(id)?.dataset.sig !== sig(id, held.get(id)))
  if (stale.length === 0) return
  const found = new Map<number, Row>()
  for (const r of read<{ rows: Row[] }>("find", { table: "applications", where: { id: { in: stale } }, cols: COLS, limit: stale.length }).rows) found.set(Number(r.id), r)
  for (const id of stale) {
    const t = tiles.get(id)
    if (t) tile(t, id, held.get(id), found.get(id) ?? {})
  }
}

/** The group headers in view: a band across the board naming the group and its count; a set of duplicates offers to keep one. */
const heads = new Map<string, HTMLElement>()
function headers(el: HTMLElement, L: Layout, want: Set<string>, w: number): void {
  for (const [k, h] of heads) if (!want.has(k) || h.parentElement !== el) (h.remove(), heads.delete(k))
  for (const p of placed) {
    if (!want.has(p.g.key)) continue
    let h = heads.get(p.g.key)
    if (!h) {
      h = document.createElement("div")
      h.className = "group-head"
      h.setAttribute("role", "heading")
      h.setAttribute("aria-level", "3")
      heads.set(p.g.key, h)
      el.append(h)
    }
    const sig_ = `${p.g.label}|${p.g.ids.length}|${p.g.keep ?? ""}|${model.rows}`
    if (h.dataset.sig !== sig_) {
      h.dataset.sig = sig_
      const b = document.createElement("b")
      b.textContent = p.g.label
      const n = document.createElement("span")
      n.className = "muted"
      n.textContent = String(p.g.ids.length)
      h.replaceChildren(b, n)
      if (p.g.keep !== undefined) {
        const keep = p.g.keep
        const others = L.dupes.get(keep)?.filter((x) => x !== keep) ?? []
        const btn = document.createElement("button")
        btn.type = "button"
        btn.className = "ghost"
        btn.dataset.act = "dedupe"
        btn.dataset.keep = String(keep)
        btn.dataset.drop = others.join(",")
        btn.textContent = `Keep #${str(value("applications", keep, "no"))}, delete the other ${others.length}`
        h.append(btn)
      }
    }
    const t = `translate(0px, ${p.top}px)`
    if (h.style.transform !== t) h.style.transform = t
    if (h.style.width !== `${w}px`) h.style.width = `${w}px`
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
  const twins = layout().dupes.get(id)?.length ?? 0
  write(el.querySelector(".dupes"), twins > 1 ? `×${twins}` : "")
  el.querySelector(".dupes")?.setAttribute("title", twins > 1 ? `${twins} applications look like this posting` : "")
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


/** The selection moved in the board as drawn: along it, or a row up or down, across groups. */
function move(dir: "next" | "prev" | "up" | "down" | "first" | "last"): void {
  const order = layout().order
  if (order.length === 0) return
  const gi = placed.findIndex((p) => p.g.ids.includes(model.selected))
  const p = placed[gi]
  const i = p ? p.g.ids.indexOf(model.selected) : -1
  let next: number | undefined
  if (!p || dir === "first") next = order[0]
  else if (dir === "last") next = order[order.length - 1]
  else if (dir === "next" || dir === "prev") next = order[order.indexOf(model.selected) + (dir === "next" ? 1 : -1)]
  else if (dir === "down") {
    const below = placed[gi + 1]
    next = i + cols < p.g.ids.length ? p.g.ids[i + cols] : Math.floor(i / cols) < Math.floor((p.g.ids.length - 1) / cols) ? p.g.ids[p.g.ids.length - 1] : below?.g.ids[Math.min(i % cols, below.g.ids.length - 1)]
  } else {
    const above = placed[gi - 1]
    const lastRow = above ? Math.floor((above.g.ids.length - 1) / cols) * cols : 0
    next = i - cols >= 0 ? p.g.ids[i - cols] : above?.g.ids[Math.min(lastRow + (i % cols), above.g.ids.length - 1)]
  }
  if (next === undefined) return
  set({ selected: next })
  reveal(next)
}

/** Brings a card's row into view; the window follows the scroll. */
function reveal(id: number): void {
  const p = placed.find((x) => x.g.ids.includes(id))
  if (!p) return
  const i = p.g.ids.indexOf(id)
  const y = boardTop + p.rowsTop + Math.floor(i / cols) * (tileH() + GAP)
  if (y < scrolled + 56 + (layout().grouped ? HEAD : 0)) window.scrollTo(0, y - 56 - (layout().grouped ? HEAD : 0))
  else if (y + tileH() > scrolled + window.innerHeight) window.scrollTo(0, y + tileH() - window.innerHeight + GAP)
}

/** Opens an application in place of the board; the board's address and scroll are kept to come back to. */
function open(id: number): void {
  if (value("applications", id, "no") === null) return
  fromBoard = true
  returnY = scrolled
  set({ selected: id })
  go({ sub: "", item: appItem(id), q: new Map() })
  window.scrollTo(0, 0)
}

/** Back to the board the application was opened from, else to the board. */
function back(): void {
  if (fromBoard) history.back()
  else go({ sub: "", item: "", q: new Map() })
  fromBoard = false
}

/** The next or previous application in board order, opened in the same place. */
function next(dir: 1 | -1): void {
  const order = board({})
  const at = order.indexOf(openedId())
  const id = order[at < 0 ? 0 : at + dir]
  if (id === undefined) return
  set({ selected: id })
  go({ item: appItem(id) }, true)
  window.scrollTo(0, 0)
}

let enteredItem = ""

const desk: View = {
  get title() {
    return opened() && openedId() !== 0 ? `#${itemNo()} ${String(value("applications", openedId(), "company") ?? "")}` : "Desk"
  },
  view,
  after,
  enter(fresh) {
    // Another application: its listing folds and its editors close. Coming from another lens is not coming from the board.
    const it = opened() ? model.address.item : ""
    if (itemNo(it) !== itemNo(enteredItem)) set({ focus: { ...model.focus, id: openedId(), listing: false, edit: "", fireArmed: 0 } })
    enteredItem = it
    if (fresh) fromBoard = false
  },
  act(name, el) {
    switch (name) {
      case "back":
        return back()
      case "open-app":
        return open(Number(el.dataset.id))
      case "toggle":
        return toggle(el.dataset.k ?? "", el.dataset.v ?? "")
      case "search": {
        // The board is the kernel's, so the answer is drawn in the keystroke's frame (no debounce).
        return query("q", (el as HTMLInputElement).value)
      }
      case "min":
        return query("min", (el as HTMLInputElement).value)
      case "sort": {
        // Another key reads its own way first: the direction asked for the last one goes.
        const q = new Map(model.address.q)
        const k = (el as HTMLSelectElement).value
        if (k === "score") q.delete("sort")
        else q.set("sort", k)
        q.delete("dir")
        return go({ q }, true)
      }
      case "dir": {
        const next = -sortDir()
        return query("dir", next === firstDir(sortKey()) ? "" : next > 0 ? "asc" : "desc")
      }
      case "group":
        return query(name, (el as HTMLSelectElement).value)
      case "group-dupes":
        return query("group", "dupes")
      case "dedupe": {
        const keep = Number(el.dataset.keep)
        const gone = (el.dataset.drop ?? "").split(",").map(Number).filter((x) => x > 0)
        const name = (x: number): string => `#${str(value("applications", x, "no"))} (${str(value("applications", x, "stage")).replace(/_/g, " ")})`
        if (!confirm(`Keep ${name(keep)} and delete ${gone.map(name).join(", ")}?\n\nEach deleted one takes its events and CV overlays with it; its messages stay, no longer linked to it.`)) return
        for (const x of gone) void drop("applications", x).catch(failed)
        return
      }
      case "open": {
        const id = Number(el.dataset.id)
        if (model.selected === id) return open(id)
        return set({ selected: id })
      }
      // The pane and the opened page are one application's markup: its controls are its actions.
      default: {
        const id = opened() ? openedId() : model.selected
        if (id !== 0) focusAct(name, el, id)
      }
    }
  },
  key(ev) {
    const k = ev.key
    if (opened()) {
      if (k === "j" || k === "ArrowDown") next(1)
      else if (k === "k" || k === "ArrowUp") next(-1)
      else if (k === "Escape" && (model.focus.edit !== "" || model.focus.fireArmed !== 0)) set({ focus: { ...model.focus, edit: "", fireArmed: 0 } })
      else if (k === "Escape" || k === "Backspace") back()
      else return false
      return true
    }
    // Vim's grid: h left, j down, k up, l right; the arrows the same.
    if (k === "l" || k === "ArrowRight") move("next")
    else if (k === "h" || k === "ArrowLeft") move("prev")
    else if (k === "j" || k === "ArrowDown") move("down")
    else if (k === "k" || k === "ArrowUp") move("up")
    else if (k === "v") go({ sub: dense() ? "" : "pro", item: "" })
    else if (k === "Escape" && dense() && (model.focus.edit !== "" || model.focus.fireArmed !== 0)) set({ focus: { ...model.focus, edit: "", fireArmed: 0 } })
    else if (k === "g" || k === "Home") move("first")
    else if (k === "G" || k === "End") move("last")
    else if ((k === "Enter" || k === "o") && model.selected !== 0) open(model.selected)
    else if (k === "/") document.getElementById("desk-search")?.focus()
    else if (k === "Escape" && model.address.q.size > 0) go({ q: new Map() }, true)
    else return false
    return true
  },
}

export default desk
