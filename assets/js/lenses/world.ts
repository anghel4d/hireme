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
import { Refused, put, query as read, table, today, values, wholeText, type Input } from "../kernel.ts"
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

/** The columns a grid shows: declared, not secret, and no twin (a metric's `_on` shows inside its metric; a deferred text's `_sha` is only its fingerprint). */
const shown = (t: TableDef): ColumnDef[] => t.cols.filter((c) => !c.implied && !c.serverOnly && !c.private && c.metricOf === null && c.shaOf === null)

/** What `find` must name: its default leaves metrics out, and the grid draws each metric with its `_on`. */
const cols = (t: TableDef): string[] => ["id", "rev", ...shown(t).flatMap((c) => (c.metric ? [c.name, `${c.name}_on`] : [c.name]))]

/** What find can order by: the node refuses deferred, text, json and bytes columns. */
const sortable = (c: ColumnDef): boolean => !c.deferred && c.type !== "text" && c.type !== "json" && c.type !== "bytes"

/** A source's identity is fixed once written (the node refuses a change): its url, host, publisher, title and kind. */
const FIXED: Partial<Record<string, readonly string[]>> = { sources: ["url", "host", "publisher", "title", "kind"] }

const editable = (c: ColumnDef): boolean =>
  writable() && !c.readonly && !c.implied && c.type !== "bytes" && !(FIXED[current().name] ?? []).includes(c.name)

function order(t: TableDef): [string, string] | null {
  const s = model.address.q.get("sort") ?? ""
  const name = s.replace(/^-/, "")
  return t.cols.some((c) => c.name === name) ? [name, s.startsWith("-") ? "desc" : "asc"] : null
}

/** The first `limit` rows of the grid's table, sort and search, from the replica (pages of find's 500). */
function rows(t: TableDef, limit: number): { rows: Row[]; more: boolean } {
  const params: Record<string, unknown> = { table: t.name, cols: cols(t) }
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
  if (c.deferred) {
    const len = typeof x === "object" && x !== null ? Number((x as { len?: number }).len ?? 0) : 0
    return html`<button type="button" class="ghost text-ref" data-act="read" data-col="${c.name}">${len.toLocaleString()} bytes</button>`
  }
  // A plain whole-number column (a year, a count of URLs) is shown as written, not grouped like a quantity.
  if (typeof x === "number" && !c.metric && c.type !== "f64") return html`${String(x)}`
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
      field = html`<select name="value" data-autofocus><option value=""></option>${values(c.enum).map((e) => html`<option${flag("selected", e === value)}>${e}</option>`)}</select>`
      break
    case "bool":
      field = html`<select name="value" data-autofocus><option value=""></option><option value="true"${flag("selected", value === "true")}>yes</option><option value="false"${flag("selected", value === "false")}>no</option></select>`
      break
    case "day":
      field = html`<input type="date" name="value" value="${value}" data-autofocus>`
      break
    case "text":
      {
        const body = c.deferred ? wholeText(t.name, id, c.name) : value
        // HTML drops a textarea's first newline, so a text that begins with one gets a second.
        field = html`<textarea name="value" rows="8" data-autofocus>${body.startsWith("\n") ? `\n${body}` : body}</textarea>`
      }
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
      : c.prose && row[c.name] ? html`<button type="button" class="on" data-act="cites" data-id="${id}" data-col="${c.name}">cited</button>` : EMPTY
  }</td>`
}

// ------------------------------------------------------------------ panels

function cites(t: TableDef): Html {
  const c = v().cites
  if (!c) return EMPTY
  const list = read<{ citations: Row[] }>("history", { table: t.name, id: c.id, column: c.column, limit: 50 }).citations
  return html`<section class="card panel" data-key="cites" aria-labelledby="cites-h">
    <h2 id="cites-h">${t.name} #${c.id} · ${c.column}</h2>
    ${list.length === 0 ? html`<p class="hint">No citations.</p>` : html`<ol class="rows">${list.map((x) => {
      const s = (x.source ?? {}) as Row
      return html`<li data-key="c${String(x.id)}"><b>${typeof x.value === "object" ? JSON.stringify(x.value) : String(x.value ?? "")}</b>
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
    <pre class="untrusted">${wholeText(t.name, x.id, x.column)}</pre>
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
  const cols = shown(t)
  const sort = model.address.q.get("sort") ?? ""
  const search = SEARCH[t.name as Shown]
  const got = rows(t, v().limit)
  return html`<div class="world">
    <div class="toolbar" data-key="toolbar">
      <nav class="subtabs" aria-label="World tables">${TABLES_SHOWN.map((n) => html`<a href="/world/${n}" data-nav data-key="${n}" class="${n === t.name ? "on" : ""}"${n === t.name ? html` aria-current="page"` : EMPTY}>${n}</a>`)}</nav>
      ${search ? html`<input type="search" class="search" placeholder="${search} starts with…" value="${model.address.q.get("q") ?? ""}" data-act="search" data-on="input" data-bound aria-label="Search ${t.name}">` : EMPTY}
      <span class="muted">${got.rows.length}${got.more ? "+" : ""} rows</span>
    </div>
    ${adder(t)}${cites(t)}${reader(t)}
    <div class="grid-wrap" data-key="grid-${t.name}">
      <table class="grid sparse">
        <thead><tr><th scope="col" class="id">#</th>${cols.map((c) => {
          const dir = sort === c.name ? "asc" : sort === `-${c.name}` ? "desc" : ""
          return html`<th scope="col" data-key="${c.name}"${dir ? html` aria-sort="${dir === "asc" ? "ascending" : "descending"}"` : EMPTY}>
            ${sortable(c) ? html`<button type="button" class="ghost" data-act="sort" data-col="${c.name}">${c.name}${dir === "asc" ? " ↑" : dir === "desc" ? " ↓" : ""}</button>` : html`<span class="muted">${c.name}</span>`}</th>`
        })}</tr></thead>
        <tbody>${got.rows.map((r) => html`<tr data-key="r${String(r.id)}" data-id="${String(r.id)}"><th scope="row" class="id">${String(r.id)}</th>${cols.map((c) => cellOf(t, c, r))}</tr>`)}</tbody>
      </table>
    </div>
    ${got.rows.length === 0 ? html`<p class="empty">No ${t.name} yet. Agents add them through the MCP; you can add one above.</p>` : EMPTY}
    ${got.more ? html`<button type="button" data-act="more">Show ${PAGE} more</button>` : EMPTY}
  </div>`
}

// ------------------------------------------------------------------ actions

function failed(e: unknown): void {
  if (e instanceof Refused) notice("error", `${e.code}: ${e.message}`)
  else notice("error", e instanceof Error ? e.message : String(e))
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
    case "search":
      // The replica answers in the keystroke's frame: no wait before asking.
      return query("q", (el as HTMLInputElement).value)
    case "more":
      return patch({ limit: v().limit + PAGE })
    case "edit": {
      const c = t.cols.find((x) => x.name === col)
      if (!c || (ev instanceof KeyboardEvent && ev.key !== "Enter")) return
      // A deferred cell (prose or a source's doc) opens on its whole text, read in the editor: a save replaces all of it.
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
      return void put(t.name as TableName, { [col]: raw === "" ? null : (raw as Input) }, {
        id,
        ...(c.metric ? { asOf: String(data.get("as_of") ?? today()) } : {}),
        ...(source !== "" ? { source } : {}),
        // The rev the editor opened on, not the row's rev now: a re-read since must not let this save overwrite it.
        ...(c.prose ? { expectRev: v().editRev } : {}),
      })
        .catch(failed)
      // Predicted: the grid shows the write now; a refusal rolls it back and says why.
      patch({ edit: "", text: null })
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

const world: View = {
  title: "World",
  view,
  enter() {
    if (!TABLES_SHOWN.includes(model.address.sub as Shown)) return go({ sub: "corporations" }, true)
  },
  act,
  key(ev) {
    if (ev.key === "Escape" && (v().edit !== "" || v().cites || v().text)) {
      patch({ edit: "", cites: null, text: null })
      return true
    }
    return false
  },
}

export default world
