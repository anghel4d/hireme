// The world lens: corporations, places, offices and sources as sparse
// grids. Columns are the declared fields, straight from gen/schema.ts, so a
// metric added to the declaration is a column here with no change to this
// file. Rows are server-side and read over `find`, keyset-paged; a cell
// shows its `_on` and opens its citations (`history`); empty is empty.
// An edit is a `put`: a metric carries as_of (and a source when there is
// one), prose carries its source and the row's rev, and the server's
// verdict is the answer.

import type { View } from "../app.ts"
import { DOMAIN, type ColumnDef, type TableDef, type TableName } from "../gen/schema.ts"
import { Refused, put, rpc, table, today, values, type Input } from "../kernel.ts"
import { EMPTY, flag, href, html, type Html } from "../morph.ts"
import { go, model, notice, query, set, type WorldView } from "../state.ts"

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

/** The columns a grid shows: declared, not secret, and not a metric's `_on` twin (shown inside its metric). */
const shown = (t: TableDef): ColumnDef[] => t.cols.filter((c) => !c.implied && !c.serverOnly && !c.private && c.metricOf === null)

const editable = (c: ColumnDef): boolean => writable() && !c.readonly && !c.implied && c.type !== "bytes"

const fetchKey = (): string => `${current().name}|${model.address.q.get("sort") ?? ""}|${model.address.q.get("q") ?? ""}`

function order(t: TableDef): [string, string] | null {
  const s = model.address.q.get("sort") ?? ""
  const name = s.replace(/^-/, "")
  return t.cols.some((c) => c.name === name) ? [name, s.startsWith("-") ? "desc" : "asc"] : null
}

/** Re-reads the rows already shown, one page at a time from the start, without closing an open editor. */
async function reread(): Promise<void> {
  const t = current()
  const key = fetchKey()
  const params: Record<string, unknown> = { table: t.name, limit: Math.max(PAGE, Math.min(500, v().rows.length)) }
  const o = order(t)
  if (o) params.order = o
  const q = model.address.q.get("q") ?? ""
  const search = SEARCH[t.name as Shown]
  if (q !== "" && search) params.where = { [search]: { prefix: q } }
  try {
    const r = await rpc<{ rows: Row[]; next: unknown }>("find", params)
    if (fetchKey() === key) patch({ rows: r.rows, next: r.next ?? null })
  } catch {
    // The next advance tries again.
  }
}

async function fetchRows(more: boolean): Promise<void> {
  const t = current()
  const key = fetchKey()
  const q = model.address.q.get("q") ?? ""
  const search = SEARCH[t.name as Shown]
  const params: Record<string, unknown> = { table: t.name, limit: PAGE }
  const o = order(t)
  if (o) params.order = o
  if (q !== "" && search) params.where = { [search]: { prefix: q } }
  if (more && v().next !== null) params.after = v().next
  patch({ loading: true, ...(more ? {} : { key, rows: [], next: null, edit: "", cites: null, text: null }) })
  try {
    const r = await rpc<{ rows: Row[]; next: unknown }>("find", params)
    if (fetchKey() !== key) return
    patch({ rows: more ? [...v().rows, ...r.rows] : r.rows, next: r.next ?? null, loading: false, error: "" })
  } catch (e) {
    patch({ loading: false, error: e instanceof Error ? e.message : String(e) })
  }
}

async function refresh(id: number): Promise<void> {
  const r = await rpc<{ row: Row }>("get", { table: current().name, id })
  patch({ rows: v().rows.map((x) => (Number(x.id) === id ? r.row : x)) })
}

// ------------------------------------------------------------------ cells

const NUM = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 })
const BIG = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 2 })

function display(c: ColumnDef, x: unknown): Html {
  if (x === null || x === undefined || x === "") return EMPTY
  if (c.deferred) {
    const len = typeof x === "object" && x !== null ? Number((x as { len?: number }).len ?? 0) : 0
    return html`<button type="button" class="ghost text-ref" data-act="read" data-col="${c.name}">${len.toLocaleString()} chars</button>`
  }
  if (typeof x === "number") {
    if (c.type === "f64" && Math.abs(x) < 1 && x !== 0 && /share|growth|margin|inflation|unemployment|rate|tax/.test(c.name)) return html`${NUM.format(x * 100)}%`
    return html`${Math.abs(x) >= 1e6 ? BIG.format(x) : NUM.format(x)}`
  }
  if (typeof x === "boolean") return html`${x ? "yes" : "no"}`
  const s = String(x)
  if (c.ref !== null) return html`<span class="ref">#${s}</span>`
  if (/_url$|^url$/.test(c.name)) return html`<a href="${href(s)}" rel="noopener noreferrer" target="_blank">${s.replace(/^https?:\/\//, "").slice(0, 48)}</a>`
  if (c.type === "str" && c.name.endsWith("language") || c.name === "work_permit") return html`${s.split("\u001f").join(", ")}`
  return html`${s.length > 80 ? `${s.slice(0, 80)}…` : s}`
}

function editor(t: TableDef, c: ColumnDef, row: Row): Html {
  const id = Number(row.id)
  const x = row[c.name]
  const value = x === null || x === undefined ? "" : typeof x === "object" ? "" : String(x)
  let field: Html
  switch (c.type) {
    case "enum":
      field = html`<select name="value" autofocus><option value=""></option>${values(c.enum).map((e) => html`<option${flag("selected", e === value)}>${e}</option>`)}</select>`
      break
    case "bool":
      field = html`<select name="value" autofocus><option value=""></option><option value="true"${flag("selected", value === "true")}>yes</option><option value="false"${flag("selected", value === "false")}>no</option></select>`
      break
    case "day":
      field = html`<input type="date" name="value" value="${value}" autofocus>`
      break
    case "text":
      field = html`<textarea name="value" rows="8" autofocus>${c.deferred ? v().text?.id === id && v().text?.column === c.name ? v().text?.body ?? "" : "" : value}</textarea>`
      break
    default:
      field = html`<input name="value" value="${value}" autofocus${flag("required", c.required)}
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
      : c.prose && row[c.name] ? html`<button type="button" class="on" data-act="cites" data-id="${id}" data-col="${c.name}">cited</button>` : EMPTY
  }</td>`
}

// ------------------------------------------------------------------ panels

function cites(): Html {
  const c = v().cites
  if (!c) return EMPTY
  return html`<section class="card panel" data-key="cites" aria-labelledby="cites-h">
    <h2 id="cites-h">${current().name} #${c.id} · ${c.column}</h2>
    ${c.list.length === 0 ? html`<p class="hint">No citations.</p>` : html`<ol class="rows">${c.list.map((x) => {
      const s = (x.source ?? {}) as Row
      return html`<li data-key="c${String(x.id)}"><b>${typeof x.value === "object" ? JSON.stringify(x.value) : String(x.value ?? "")}</b>
        <span class="muted">as of ${String(x.as_of ?? "")} · ${String(x.actor ?? "")}${x.key_id ? ` (key ${String(x.key_id)})` : ""}</span>
        ${s.url ? html`<a href="${href(String(s.url))}" rel="noopener noreferrer" target="_blank">${String(s.title ?? s.host ?? s.url)}</a>` : EMPTY}</li>`
    })}</ol>`}
    <button type="button" class="ghost" data-act="close-panel">Close</button>
  </section>`
}

function reader(): Html {
  const t = v().text
  if (!t || v().edit !== "") return EMPTY
  return html`<section class="card panel" data-key="text" aria-labelledby="text-h">
    <h2 id="text-h">${current().name} #${t.id} · ${t.column}</h2>
    <p class="hint">Written by a person or an agent; shown as text, never run.</p>
    <pre class="untrusted">${t.body}</pre>
    ${t.body.length < t.total ? html`<button type="button" data-act="read-more">Read more (${(t.total - t.body.length).toLocaleString()} left)</button>` : EMPTY}
    <button type="button" class="ghost" data-act="close-panel">Close</button>
  </section>`
}

function adder(t: TableDef): Html {
  if (!writable()) return EMPTY
  if (v().edit !== "new") return html`<button type="button" data-act="new">Add a row</button>`
  const key = new Set(t.natural.flatMap((k) => k.cols))
  const cols = t.cols.filter((c) => !c.implied && !c.readonly && (c.required || key.has(c.name)) && c.metricOf === null)
  return html`<form class="stack card" data-submit="create" data-act="create" data-key="new">
    <h2>New ${t.name.replace(/s$/, "")}</h2>
    ${cols.map((c) => html`<label>${c.name}${c.type === "enum"
      ? html`<select name="${c.name}"${flag("required", c.required)}><option value=""></option>${values(c.enum).map((e) => html`<option>${e}</option>`)}</select>`
      : html`<input name="${c.name}"${flag("required", c.required || key.has(c.name))}>`}</label>`)}
    <span class="row"><button class="primary">Create</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span>
  </form>`
}

// ------------------------------------------------------------------ view

function view(): Html {
  const t = current()
  const cols = shown(t)
  const sort = model.address.q.get("sort") ?? ""
  const search = SEARCH[t.name as Shown]
  return html`<div class="world">
    <div class="toolbar" data-key="toolbar">
      <nav class="subtabs" aria-label="World tables">${TABLES_SHOWN.map((n) => html`<a href="/world/${n}" data-nav data-key="${n}" class="${n === t.name ? "on" : ""}"${n === t.name ? html` aria-current="page"` : EMPTY}>${n}</a>`)}</nav>
      ${search ? html`<input type="search" class="search" placeholder="${search} starts with…" value="${model.address.q.get("q") ?? ""}" data-act="search" data-on="input" aria-label="Search ${t.name}">` : EMPTY}
      <span class="muted">${v().rows.length}${v().next !== null ? "+" : ""} rows</span>
    </div>
    ${v().error !== "" ? html`<p class="error" role="alert">${v().error}</p>` : EMPTY}
    ${adder(t)}${cites()}${reader()}
    <div class="grid-wrap" data-key="grid-${t.name}">
      <table class="grid sparse">
        <thead><tr><th scope="col" class="id">#</th>${cols.map((c) => {
          const dir = sort === c.name ? "asc" : sort === `-${c.name}` ? "desc" : ""
          return html`<th scope="col" data-key="${c.name}"${dir ? html` aria-sort="${dir === "asc" ? "ascending" : "descending"}"` : EMPTY}>
            <button type="button" class="ghost" data-act="sort" data-col="${c.name}">${c.name}${dir === "asc" ? " ↑" : dir === "desc" ? " ↓" : ""}</button></th>`
        })}</tr></thead>
        <tbody>${v().rows.map((r) => html`<tr data-key="r${String(r.id)}"><th scope="row" class="id">${String(r.id)}</th>${cols.map((c) => cellOf(t, c, r))}</tr>`)}</tbody>
      </table>
    </div>
    ${v().loading ? html`<p class="empty">Loading…</p>` : v().rows.length === 0 && v().error === "" ? html`<p class="empty">No ${t.name} yet. Agents add them through the MCP; you can add one above.</p>` : EMPTY}
    ${v().next !== null && !v().loading ? html`<button type="button" data-act="more">Load ${PAGE} more</button>` : EMPTY}
  </div>`
}

// ------------------------------------------------------------------ actions

let typing = 0

function failed(e: unknown): void {
  if (e instanceof Refused) notice("error", `${e.code}: ${e.message}`)
  else notice("error", e instanceof Error ? e.message : String(e))
}

async function readText(id: number, column: string, offset: number): Promise<{ body: string; total: number }> {
  const r = await rpc<{ text: string; total: number }>("text", { table: current().name, id, column, offset, length: 262_144 })
  return { body: r.text, total: r.total }
}

function act(name: string, el: HTMLElement, ev: Event): void {
  const t = current()
  const id = Number(el.dataset.id ?? el.closest<HTMLElement>("tr")?.dataset.key?.slice(1))
  const col = el.dataset.col ?? ""
  switch (name) {
    case "sort": {
      const s = model.address.q.get("sort") ?? ""
      return query("sort", s === col ? `-${col}` : s === `-${col}` ? "" : col)
    }
    case "search": {
      const value = (el as HTMLInputElement).value
      clearTimeout(typing)
      typing = window.setTimeout(() => query("q", value), 200)
      return
    }
    case "more":
      return void fetchRows(true)
    case "edit": {
      const c = t.cols.find((x) => x.name === col)
      if (!c || (ev instanceof KeyboardEvent && ev.key !== "Enter")) return
      if (c.deferred && c.prose) {
        return void readText(id, col, 0).then((r) => patch({ edit: `${id}:${col}`, text: { id, column: col, ...r } })).catch(failed)
      }
      return patch({ edit: `${id}:${col}` })
    }
    case "cancel":
      return patch({ edit: "" })
    case "save": {
      const form = el as HTMLFormElement
      const c = t.cols.find((x) => x.name === col)
      const row = v().rows.find((r) => Number(r.id) === id)
      if (!c || !row) return
      const data = new FormData(form)
      const raw = String(data.get("value") ?? "")
      const source = String(data.get("source") ?? "")
      return void put(t.name as TableName, { [col]: raw === "" ? null : (raw as Input) }, {
        id,
        ...(c.metric ? { asOf: String(data.get("as_of") ?? today()) } : {}),
        ...(source !== "" ? { source } : {}),
        ...(c.prose ? { expectRev: Number(row.rev) } : {}),
      })
        .then(() => {
          patch({ edit: "", text: null })
          return refresh(id)
        })
        .catch(failed)
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
      return void put(t.name as TableName, rest, keyed ? { key, createOnly: true } : {})
        .then(() => {
          patch({ edit: "" })
          return fetchRows(false)
        })
        .catch(failed)
    }
    case "cites":
      ev.stopPropagation()
      return void rpc<{ citations: Row[] }>("history", { table: t.name, id, column: col, limit: 50 })
        .then((r) => patch({ cites: { id, column: col, list: r.citations } }))
        .catch(failed)
    case "read":
      ev.stopPropagation()
      return void readText(id, col, 0).then((r) => patch({ text: { id, column: col, ...r }, cites: null })).catch(failed)
    case "read-more": {
      const cur = v().text
      if (!cur) return
      return void readText(cur.id, cur.column, new TextEncoder().encode(cur.body).byteLength)
        .then((r) => patch({ text: { ...cur, body: cur.body + r.body, total: r.total } }))
        .catch(failed)
    }
    case "close-panel":
      return patch({ cites: null, text: null })
  }
}

const world: View = {
  title: "World",
  view,
  enter() {
    if (!TABLES_SHOWN.includes(model.address.sub as Shown)) return go({ sub: "corporations" }, true)
    if (v().key !== fetchKey()) void fetchRows(false)
  },
  act,
  refresh() {
    if (v().key === fetchKey() && !v().loading) void reread()
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
