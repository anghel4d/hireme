// The world lens: corporations, places, offices and sources as sparse
// grids. Columns are the declared fields, straight from gen/schema.ts, so a
// metric added to the declaration is a column here with no change to this
// file. Rows are the kernel's replica, read in the frame they are drawn
// (`find`, `get`, `text`, `history` answered locally); a cell shows its `_on`
// and opens its citations; empty is empty. An edit is a `put`: the kernel
// predicts it at once (a metric carries as_of, prose its source and the
// row's rev) and the sequencer's verdict confirms it or rolls it back.

import type { View } from "../app.ts"
import { DOMAIN, type ColumnDef, type TableDef, type TableName } from "../gen/schema.ts"
import { Refused, failed, put, query as read, table, today, values, type Input } from "../kernel.ts"
import { EMPTY, flag, href, html, unicodeHost, type Html } from "../morph.ts"
import { go, model, query, set, type WorldView } from "../state.ts"

type Row = Record<string, unknown>

const TABLES_SHOWN = ["corporations", "places", "offices", "sources"] as const satisfies readonly TableName[]
type Shown = (typeof TABLES_SHOWN)[number]
const SEARCH: Record<Shown, string | null> = { corporations: "name", places: "name", offices: null, sources: "url" }
const PAGE = 100

const v = (): WorldView => model.world
const patch = (p: Partial<WorldView>) => set({ world: { ...model.world, ...p } })

function current(): TableDef {
  const sub = model.address.sub as Shown
  return table(TABLES_SHOWN.includes(sub) ? sub : "corporations")
}

const writable = (): boolean => (model.writeMask & DOMAIN.world) !== 0

/** The columns a grid shows: declared, not secret, and no twin (a metric's `_on` shows inside its metric). */
const shown = (t: TableDef): ColumnDef[] => {
  const all = t.cols.filter((c) => !c.implied && !c.serverOnly && !c.private && c.metricOf === null)
  // The column a row is known by (its search column: a name, a url) leads, held in view beside # while the grid scrolls.
  const lead = SEARCH[t.name as Shown]
  return [...all.filter((c) => c.name === lead), ...all.filter((c) => c.name !== lead)]
}

/** The declaration's abbreviations, spelled as people write them; every other word of a column's name is itself. */
const WORDS: Record<string, string> = {
  usd: "(USD)", swe: "SWE", url: "URL", urls: "URLs", ats: "ATS", hq: "HQ", pe: "P/E", wlb: "work-life balance", iso2: "ISO 2", iso3: "ISO 3",
  geonames: "GeoNames", gdp: "GDP", ppp: "PPP", km2: "km²", twh: "TWh", kwh: "kWh", mbps: "Mbps", co2: "CO₂", t: "(t)", qol: "quality of life", hdi: "HDI", lat: "latitude", lon: "longitude", id: "",
}
/** A column's label, generated from its declared name: hq_place_id is "HQ place", comp_swe_median_usd "Comp SWE median (USD)". */
export function label(name: string): string {
  const words = name.split("_").map((w) => WORDS[w] ?? w).filter((w) => w !== "").join(" ")
  return words.charAt(0).toUpperCase() + words.slice(1)
}

/**
 * The columns drawn: the lead and the declaration's group picked in the address (`cols`), the first
 * group (identity) by default, or every column for `all` and for a table the declaration does not group.
 */
const groups = (t: TableDef): string[] => [...new Set(shown(t).flatMap((c) => (c.group === null ? [] : [c.group])))]
function drawn(t: TableDef): ColumnDef[] {
  const g = groups(t)
  const pick = model.address.q.get("cols") ?? g[0]
  const lead = SEARCH[t.name as Shown]
  return g.length < 2 || pick === "all" ? shown(t) : shown(t).filter((c) => c.name === lead || c.group === pick)
}

/** What `find` must name: its default leaves metrics out, and the grid draws each metric with its `_on`. */
// A text column is drawn as its byte count: the grid asks find for its size, never its text.
const cols = (cs: ColumnDef[]): string[] => ["id", "rev", ...cs.filter((c) => c.type !== "text").flatMap((c) => (c.metric ? [c.name, `${c.name}_on`] : [c.name]))]

/** What find can order by: the node refuses text, json and bytes columns. */
const sortable = (c: ColumnDef): boolean => c.type !== "text" && c.type !== "json" && c.type !== "bytes"

/** A source's identity is fixed once written (the node refuses a change): its url, host, publisher, title and kind. */
const FIXED: Partial<Record<string, readonly string[]>> = { sources: ["url", "host", "publisher", "title", "kind"] }

const editable = (c: ColumnDef): boolean =>
  writable() && !c.readonly && !c.implied && c.type !== "bytes" && !(FIXED[current().name] ?? []).includes(c.name)

function order(t: TableDef): [string, string] | null {
  const s = model.address.q.get("sort") ?? ""
  const name = s.replace(/^-/, "")
  return t.cols.some((c) => c.name === name && sortable(c)) ? [name, s.startsWith("-") ? "desc" : "asc"] : null
}

/** The first `limit` rows of the grid's table, sort and search, from the replica (pages of find's 500). */
function rows(t: TableDef, cs: ColumnDef[], limit: number): { rows: Row[]; more: boolean } {
  const params: Record<string, unknown> = { table: t.name, cols: cols(cs), sizes: cs.filter((c) => c.type === "text").map((c) => c.name) }
  const o = order(t)
  if (o) params.order = o
  const q = model.address.q.get("q") ?? ""
  const search = SEARCH[t.name as Shown]
  if (q !== "" && search) params.where = { [search]: { prefix: q } }
  const out: Row[] = []
  let after: unknown = null
  while (out.length < limit) {
    const r = read<{ rows: Row[]; next: unknown }>("find", { ...params, limit: Math.min(500, limit - out.length), ...(after === null ? {} : { after }) })
    out.push(...r.rows)
    after = r.next ?? null
    if (after === null) return { rows: out, more: false }
  }
  return { rows: out, more: true }
}

const rowOf = (t: TableDef, id: number): Row | null => {
  try {
    return read<{ row: Row }>("get", { table: t.name, id }).row
  } catch {
    return null
  }
}

// ------------------------------------------------------------------ cells

const NUM = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 })
const BIG = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 2 })

function display(c: ColumnDef, x: unknown): Html {
  if (x === null || x === undefined || x === "") return EMPTY
  if (c.type === "text") return x === 0 ? EMPTY : html`<button type="button" class="ghost text-ref" data-act="read" data-col="${c.name}">${Number(x).toLocaleString()} bytes</button>`
  if (c.ref !== null) {
    // A ref is the row it names, by its name, from the replica; a world table's row is a link to it there.
    const to = TABLES_SHOWN.find((n) => n === c.ref)
    const named = to ? rowOf(table(to), Number(x)) : null
    const name = named ? String(named[SEARCH[to!] ?? "id"] ?? "") : ""
    if (!to || name === "") return html`<span class="ref">#${String(x)}</span>`
    return html`<a class="ref" href="/world/${to}?q=${encodeURIComponent(name)}" data-nav title="${to} #${String(x)}">${to === "sources" ? unicodeHost(name.replace(/^https?:\/\//, "")) : name}</a>`
  }
  // A plain whole-number column (a year, a count of URLs) is shown as written, not grouped like a quantity.
  if (typeof x === "number" && !c.metric && c.type !== "f64") return html`${String(x)}`
  if (typeof x === "number") {
    if (c.type === "f64" && Math.abs(x) < 1 && x !== 0 && /share|growth|margin|inflation|unemployment|rate|tax/.test(c.name)) return html`${NUM.format(x * 100)}%`
    return html`${Math.abs(x) >= 1e6 ? BIG.format(x) : NUM.format(x)}`
  }
  if (typeof x === "boolean") return html`${x ? "yes" : "no"}`
  const s = String(x)
  if (c.name === "domain" || c.name === "host") return html`<span title="${s}">${unicodeHost(s)}</span>`
  if (/_url$|^url$/.test(c.name)) {
    const [, host = "", rest = ""] = s.match(/^https?:\/\/([^/]*)(.*)$/) ?? []
    return html`<a href="${href(s)}" rel="noopener noreferrer" target="_blank" title="${s}">${(unicodeHost(host) + rest).slice(0, 48)}</a>`
  }
  if (c.type === "str" && c.name.endsWith("language") || c.name === "work_permit") return html`${s.split("\u001f").join(", ")}`
  return html`${s.length > 80 ? `${s.slice(0, 80)}…` : s}`
}

function editor(t: TableDef, c: ColumnDef, row: Row): Html {
  const id = Number(row.id)
  const x = c.type === "text" ? rowOf(t, id)?.[c.name] : row[c.name]
  const value = x === null || x === undefined ? "" : typeof x === "object" ? "" : String(x)
  let field: Html
  switch (c.type) {
    case "enum":
      field = html`<select name="value" data-autofocus><option value=""></option>${values(c.enum).map((e) => html`<option${flag("selected", e === value)}>${e}</option>`)}</select>`
      break
    case "bool":
      field = html`<select name="value" data-autofocus><option value=""></option><option value="true"${flag("selected", value === "true")}>yes</option><option value="false"${flag("selected", value === "false")}>no</option></select>`
      break
    case "day":
      field = html`<input type="date" name="value" value="${value}" data-autofocus>`
      break
    case "text":
      // HTML drops a textarea's first newline, so a text that begins with one gets a second.
      field = html`<textarea name="value" rows="8" data-autofocus>${value.startsWith("\n") ? `\n${value}` : value}</textarea>`
      break
    default:
      field = html`<input name="value" value="${value}" data-autofocus${flag("required", c.required)}
        ${c.type === "f64" || c.type === "u32" || c.type === "u8" || c.type === "i64" ? html` inputmode="decimal"` : EMPTY}>`
  }
  return html`<form class="cell-edit" data-submit="save" data-act="save" data-id="${id}" data-col="${c.name}">
    <label class="sr">${t.name}.${c.name}</label>${field}
    ${c.metric ? html`<label>as of <input type="date" name="as_of" value="${today()}" required></label>` : EMPTY}
    ${c.metric || c.prose ? html`<label>source <input type="url" name="source" placeholder="https://"${flag("required", c.prose)}></label>` : EMPTY}
    <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span>
  </form>`
}

function cellOf(t: TableDef, c: ColumnDef, row: Row): Html {
  const id = Number(row.id)
  if (v().edit === `${id}:${c.name}`) return html`<td class="editing" data-key="${c.name}">${editor(t, c, row)}</td>`
  const on = c.metric ? row[`${c.name}_on`] : null
  const can = editable(c)
  return html`<td data-key="${c.name}" class="${c.metric ? "metric" : ""}${can ? " can" : ""}"${can ? html` data-act="edit" data-click data-on="keydown" data-id="${id}" data-col="${c.name}" tabindex="0"` : EMPTY}>${display(c, row[c.name])}${
    on ? html`<button type="button" class="on" data-act="cites" data-id="${id}" data-col="${c.name}" title="as of ${String(on)}; citations">${String(on)}</button>`
      : c.prose && row[c.name] ? html`<button type="button" class="on cite" data-act="cites" data-id="${id}" data-col="${c.name}" title="Sources: where this text came from" aria-label="Sources for ${label(c.name)}">❝</button>` : EMPTY
  }</td>`
}

// ------------------------------------------------------------------ panels

function cites(t: TableDef): Html {
  const c = v().cites
  if (!c) return EMPTY
  let list: Row[]
  try {
    list = read<{ citations: Row[] }>("history", { table: t.name, id: c.id, column: c.column, limit: 50 }).citations
  } catch (e) {
    // The row went (an agent dropped it) while its citations were open: said in the panel, not the lens.
    if (!(e instanceof Refused)) throw e
    list = []
  }
  return html`<section class="card panel" data-key="cites" aria-labelledby="cites-h">
    <h2 id="cites-h">${t.name} #${c.id} · ${c.column}</h2>
    ${list.length === 0 ? html`<p class="hint">No citations.</p>` : html`<ol class="rows">${list.map((x) => {
      const s = (x.source ?? {}) as Row
      // A citation keeps the value it cited as {"v": value} (provenance.ex).
      const cited = (x.value as { v?: unknown } | null)?.v ?? x.value
      return html`<li data-key="c${String(x.id)}"><b>${typeof cited === "object" ? JSON.stringify(cited) : String(cited ?? "")}</b>
        <span class="muted">as of ${String(x.as_of ?? "")} · ${String(x.actor ?? "")}${x.key_id ? ` (key ${String(x.key_id)})` : ""}</span>
        ${s.url ? html`<a href="${href(String(s.url))}" rel="noopener noreferrer" target="_blank">${String(s.title ?? s.host ?? s.url)}</a>` : EMPTY}</li>`
    })}</ol>`}
    <button type="button" class="ghost" data-act="close-panel">Close</button>
  </section>`
}

function reader(t: TableDef): Html {
  const x = v().text
  if (!x || v().edit !== "") return EMPTY
  return html`<section class="card panel" data-key="text" aria-labelledby="text-h">
    <h2 id="text-h">${t.name} #${x.id} · ${x.column}</h2>
    <p class="hint">Written by a person or an agent; shown as text, never run.</p>
    <pre class="untrusted">${String(rowOf(t, x.id)?.[x.column] ?? "")}</pre>
    <button type="button" class="ghost" data-act="close-panel">Close</button>
  </section>`
}

function adder(t: TableDef): Html {
  if (!writable()) return EMPTY
  if (v().edit !== "new") return html`<button type="button" data-act="new">Add a row</button>`
  const key = new Set(t.natural.flatMap((k) => k.cols))
  // A table with one natural key needs it; one with several (places: iso2 or geonames_id) needs one of them, so none is forced.
  const needed = (c: ColumnDef) => c.required || (t.natural.length === 1 && key.has(c.name))
  const cols = t.cols.filter((c) => !c.implied && !c.readonly && (c.required || key.has(c.name)) && c.metricOf === null)
  return html`<form class="stack card" data-submit="create" data-act="create" data-key="new">
    <h2>New ${t.name.replace(/s$/, "")}</h2>
    ${cols.map((c) => html`<label>${c.name}${c.type === "enum"
      ? html`<select name="${c.name}"${flag("required", c.required)}><option value=""></option>${values(c.enum).map((e) => html`<option>${e}</option>`)}</select>`
      : c.type === "bool"
        ? html`<select name="${c.name}"${flag("required", c.required)}><option value=""></option><option value="true">yes</option><option value="false">no</option></select>`
        : html`<input name="${c.name}"${flag("required", needed(c))}>`}</label>`)}
    <span class="row"><button class="primary">Create</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span>
  </form>`
}

// ------------------------------------------------------------------ view

function view(): Html {
  const t = current()
  const all = drawn(t)
  const g = groups(t)
  const pick = model.address.q.get("cols") ?? g[0]
  const sort = model.address.q.get("sort") ?? ""
  const search = SEARCH[t.name as Shown]
  const got = rows(t, all, v().limit)
  // A column empty on every row drawn is left out, said and undoable: the grid shows what there is.
  const showEmpty = model.address.q.get("empty") === "show"
  const blank = all.filter((c) => c.name !== search && got.rows.length > 0 && got.rows.every((r) => r[c.name] === null || r[c.name] === undefined || r[c.name] === ""))
  const cols = showEmpty ? all : all.filter((c) => !blank.includes(c))
  return html`<div class="world">
    <div class="toolbar" data-key="toolbar">
      <nav class="subtabs" aria-label="World tables">${TABLES_SHOWN.map((n) => html`<a href="/world/${n}" data-nav data-key="${n}" class="${n === t.name ? "on" : ""}"${n === t.name ? html` aria-current="page"` : EMPTY}>${n}</a>`)}</nav>
      ${search ? html`<input type="search" class="search" placeholder="${search} starts with…" value="${model.address.q.get("q") ?? ""}" data-act="search" data-on="input" data-bound aria-label="Search ${t.name}">` : EMPTY}
      <span class="muted">${got.rows.length}${got.more ? "+" : ""} row${got.rows.length === 1 && !got.more ? "" : "s"}</span>
    </div>
    ${g.length < 2 && blank.length === 0 ? EMPTY : html`<div class="chips" role="group" aria-label="Which columns" data-key="groups">${g.length < 2 ? EMPTY : [...g, "all"].map((x) => html`<button type="button" class="chip${x === pick ? " on" : ""}" aria-pressed="${String(x === pick)}" data-act="cols" data-v="${x}" data-key="${x}">${x === "all" ? "All columns" : x.charAt(0).toUpperCase() + x.slice(1)}</button>`)}
      ${blank.length === 0 ? EMPTY : html`<button type="button" class="ghost" data-act="empty" data-key="empty" title="${blank.map((c) => label(c.name)).join(", ")}">${showEmpty ? `Hide the ${blank.length} empty column${blank.length === 1 ? "" : "s"}` : `${blank.length} empty column${blank.length === 1 ? "" : "s"} hidden · show`}</button>`}</div>`}
    ${adder(t)}${cites(t)}${reader(t)}
    <div class="grid-wrap" data-key="grid-${t.name}">
      <table class="grid sparse">
        <thead><tr><th scope="col" class="id">#</th>${cols.map((c, n) => {
          const dir = sort === c.name ? "asc" : sort === `-${c.name}` ? "desc" : ""
          return html`<th scope="col" data-key="${c.name}"${n === 0 && search ? html` class="anchor"` : EMPTY}${dir ? html` aria-sort="${dir === "asc" ? "ascending" : "descending"}"` : EMPTY}>
            ${sortable(c) ? html`<button type="button" class="ghost" data-act="sort" data-col="${c.name}" title="${c.name}: sort">${label(c.name)}${dir === "asc" ? " ↑" : dir === "desc" ? " ↓" : ""}</button>` : html`<span title="${c.name}">${label(c.name)}</span>`}</th>`
        })}</tr></thead>
        <tbody>${got.rows.map((r) => html`<tr data-key="r${String(r.id)}" data-id="${String(r.id)}"><th scope="row" class="id">${String(r.id)}</th>${cols.map((c) => cellOf(t, c, r))}</tr>`)}</tbody>
      </table>
    </div>
    ${got.rows.length === 0 ? html`<p class="empty">No ${t.name} yet. Agents add them through the MCP; you can add one above.</p>` : EMPTY}
    ${got.more ? html`<button type="button" data-act="more">Show ${PAGE} more</button>` : EMPTY}
  </div>`
}

// ------------------------------------------------------------------ actions

function act(name: string, el: HTMLElement, ev: Event): void {
  const t = current()
  const id = Number(el.dataset.id ?? el.closest<HTMLElement>("tr")?.dataset.key?.slice(1))
  const col = el.dataset.col ?? ""
  switch (name) {
    case "cols":
      return query("cols", el.dataset.v ?? "")
    case "empty":
      return query("empty", model.address.q.get("empty") === "show" ? "" : "show")
    case "sort": {
      const s = model.address.q.get("sort") ?? ""
      return query("sort", s === col ? `-${col}` : s === `-${col}` ? "" : col)
    }
    case "search":
      // The replica answers in the keystroke's frame: no wait before asking.
      return query("q", (el as HTMLInputElement).value)
    case "more":
      return patch({ limit: v().limit + PAGE })
    case "edit": {
      const c = t.cols.find((x) => x.name === col)
      if (!c || (ev instanceof KeyboardEvent && ev.key !== "Enter")) return
      // A text cell (prose or a source's doc) opens on its whole text, read in the editor: a save replaces all of it.
      return patch({ edit: `${id}:${col}`, editRev: Number(rowOf(t, id)?.rev ?? 0) })
    }
    case "cancel":
      return patch({ edit: "" })
    case "save": {
      const form = el as HTMLFormElement
      const c = t.cols.find((x) => x.name === col)
      if (!c || !rowOf(t, id)) return
      const data = new FormData(form)
      const raw = String(data.get("value") ?? "")
      const source = String(data.get("source") ?? "")
      void put(t.name as TableName, { [col]: raw === "" ? null : (raw as Input) }, {
        id,
        ...(c.metric ? { asOf: String(data.get("as_of") ?? today()) } : {}),
        ...(source !== "" ? { source } : {}),
        // The rev the editor opened on, not the row's rev now: a re-read since must not let this save overwrite it.
        ...(c.prose ? { expectRev: v().editRev } : {}),
      })
        .catch(failed)
      // Predicted: the grid shows the write now (a local refusal threw above and kept the editor); the
      // sequencer's refusal rolls it back and says why.
      return patch({ edit: "", text: null })
    }
    case "new":
      return patch({ edit: "new" })
    case "create": {
      const data = new FormData(el as HTMLFormElement)
      const keyCols = new Set(t.natural.flatMap((k) => k.cols))
      const key: Record<string, Input> = {}
      const rest: Record<string, Input> = {}
      for (const [k, x] of data) {
        const s = String(x)
        if (s === "") continue
        if (keyCols.has(k) && t.natural.length === 1) key[k] = s
        else rest[k] = s
      }
      const keyed = Object.keys(key).length > 0
      void put(t.name as TableName, rest, keyed ? { key, createOnly: true } : {}).catch(failed)
      return patch({ edit: "" })
    }
    case "cites":
      ev.stopPropagation()
      return patch({ cites: { id, column: col }, text: null })
    case "read":
      ev.stopPropagation()
      return patch({ text: { id, column: col }, cites: null })
    case "close-panel":
      return patch({ cites: null, text: null })
  }
}

let shownTable = ""
let rescroll = false

const world: View = {
  title: "World",
  view,
  enter() {
    if (!TABLES_SHOWN.includes(model.address.sub as Shown)) return go({ sub: "corporations" }, true)
    // A new table, sort or search shows its first page with no editor; a new table closes its panels too.
    const fresh = model.address.sub !== shownTable
    shownTable = model.address.sub
    rescroll = true
    if (fresh) patch({ limit: PAGE, edit: "", cites: null, text: null })
    else if (v().limit !== PAGE || v().edit !== "") patch({ limit: PAGE, edit: "" })
  },
  act,
  after(root) {
    // A new table, sort or search starts at the grid's left edge, not where the last one was scrolled.
    if (rescroll) root.querySelector(".grid-wrap")?.scrollTo({ left: 0 })
    rescroll = false
  },
  key(ev) {
    if (ev.key === "Escape" && (v().edit !== "" || v().cites || v().text)) {
      patch({ edit: "", cites: null, text: null })
      return true
    }
    return false
  },
}

export default world
