// The focus lens: one application. Everything derived about it (the rail,
// the score and its suggestion, heat, keyword coverage, the CV composed
// through its lineage's overlays, events) is the kernel's one document,
// the same the MCP reads. The raw listing is deferred and fetched only when
// asked for; the application's messages, contact and corporation are
// server-side and read over RPC. Moves along the rail are the `stage`
// command, judged by the kernel here before the sequencer judges it again.

import type { View } from "../app.ts"
import { ENUMS } from "../gen/schema.ts"
import { Refused, application, command, lookup, put, rpc, type Input } from "../kernel.ts"
import { EMPTY, flag, href, html, type Html } from "../morph.ts"
import { go, model, notice, set, type FocusView } from "../state.ts"

type Row = Record<string, unknown>
type Doc = {
  application: Row
  card: { score_100: number; stored: boolean; band: string; class: string; suggestion: Row; heat: Row } | null
  rail: { stage: string; label: string; hint: string; pip: string; fire_locked: boolean }[]
  coverage: { hits: number; total: number; percent: number; terms: { term: string; hit: boolean }[] }
  cv: { theme: Row; lines: Row[] }
  events: Row[]
  batch: Row | null
  lineage: Row | null
}

const v = (): FocusView => model.focus
const patch = (p: Partial<FocusView>) => set({ focus: { ...model.focus, ...p } })
const str = (x: unknown): string => (x === null || x === undefined ? "" : String(x))
const id = (): number => lookup("applications", "no", model.address.sub)

const PROSE = ["notes", "battleplan", "letter_raw"] as const

/**
 * A text column as the kernel's document holds it: inline, or deferred as a
 * `{length, sha}` stub whose bytes come over RPC `text` once, on demand.
 * Answers the text, null while it is on its way, or "" when there is none.
 */
const reading = new Set<string>()
/** Texts whose read failed: shown as such until the operator retries, never re-asked on every render. */
const unread = new Set<string>()
/** An event the kernel predicted but the node has not answered yet: a temp id (or none), nothing to read. */
const unsaved = (id: number): boolean => !Number.isFinite(id) || id <= 0 || id >= 0xc000_0000

function textOf(table: string, rowId: number, column: string, v_: unknown): string | null {
  if (v_ === null || v_ === undefined) return ""
  if (typeof v_ === "string") return v_
  const stub = v_ as { length?: number; sha?: string }
  if (!stub.length) return ""
  if (unsaved(rowId)) return null
  const key = `${table}:${rowId}:${column}:${stub.sha ?? ""}`
  const have = v().texts.get(key)
  if (have !== undefined) return have
  if (!reading.has(key) && !unread.has(key)) {
    reading.add(key)
    void readAll(table, rowId, column, stub.sha ?? "")
      .then((t) => {
        if (v().id === rowId || table !== "applications") patch({ texts: new Map(v().texts).set(key, t) })
      })
      .catch(() => {
        unread.add(key)
        patch({})
      })
      .finally(() => reading.delete(key))
  }
  return null
}

const failedText = (table: string, rowId: number, column: string, v_: unknown): boolean => {
  const stub = v_ as { sha?: string } | null
  return typeof v_ === "object" && v_ !== null && unread.has(`${table}:${rowId}:${column}:${stub?.sha ?? ""}`)
}

/**
 * Every chunk of one deferred text (prose is small; a listing has its own paged reader). A read
 * that races a write can answer the old text under the new stub, so the answer is kept only
 * when its sha is the stub's; a few short retries cover the gap until the write commits.
 */
async function readAll(table: string, rowId: number, column: string, sha: string): Promise<string> {
  for (let attempt = 0; attempt < 4; attempt++) {
    let out = ""
    let offset = 0
    let full = ""
    for (;;) {
      const r = await rpc<{ text: string; total: number; sha?: string }>("text", { table, id: rowId, column, offset, length: 262_144 })
      out += r.text
      full = r.sha ?? ""
      offset += new TextEncoder().encode(r.text).byteLength
      if (r.text === "" || offset >= r.total) break
    }
    if (sha === "" || full === "" || full.toLowerCase().startsWith(sha.toLowerCase())) return out
    await new Promise((res) => setTimeout(res, 150 * (attempt + 1)))
  }
  throw new Error("the text changed while it was being read")
}

function failed(e: unknown): void {
  notice("error", e instanceof Refused ? `${e.code}: ${e.message}` : e instanceof Error ? e.message : String(e))
}

/** The sha of the listing the application's row names now. */
const listingSha = (appId: number): string => {
  const raw = (application(appId) as Doc | null)?.application.listing_raw as { sha?: string } | null | undefined
  return raw?.sha ?? ""
}

/** A reply about one application lands only while that application is the one shown. */
const mine = (appId: number, p: Partial<FocusView>) => {
  if (v().id === appId) patch(p)
}

async function fetchAround(appId: number, a: Row): Promise<void> {
  // Deferred text read for the last application is dropped: only this one's is wanted now.
  patch({ id: appId, listing: null, messages: [], contact: null, corporation: null, edit: "", error: "", texts: new Map() })
  const jobs: Promise<void>[] = [
    rpc<{ rows: Row[] }>("find", { table: "messages", where: { application_id: appId }, order: ["sent_at", "asc"], limit: 200 })
      .then((r) => mine(appId, { messages: r.rows }))
      .catch(() => {}),
  ]
  if (a.contact_id) jobs.push(rpc<{ row: Row }>("get", { table: "contacts", id: Number(a.contact_id) }).then((r) => mine(appId, { contact: r.row })).catch(() => {}))
  if (a.corporation_id) jobs.push(rpc<{ row: Row }>("get", { table: "corporations", id: Number(a.corporation_id) }).then((r) => mine(appId, { corporation: r.row })).catch(() => {}))
  await Promise.all(jobs)
}

// ------------------------------------------------------------------ view

/**
 * The rail. Every move is the `stage` command except opening fire, which is
 * the operator's own act: the human_only `open_fire` command, armed by one
 * click and done by a second, and the only way to `submitted` (FIRE HOLD).
 */
function rail(d: Doc, appId: number): Html {
  const stage = str(d.application.stage)
  const armed = v().fireArmed === appId
  return html`<ol class="rail" aria-label="Pipeline" data-key="rail">${d.rail.map((r) => {
    const fire = r.stage === "open_fire"
    return html`<li data-key="${r.stage}" class="pip-${r.pip}${r.stage === stage ? " now" : ""}">
    <button type="button" data-act="${fire ? "fire" : "stage"}" data-stage="${r.stage}" data-id="${appId}" title="${fire ? "Open fire: you, not an agent, send this application" : r.hint}"
      class="${fire && armed ? "danger" : ""}"${flag("disabled", r.stage === stage)}>
      ${fire && armed ? "Open fire: click again" : r.label}${r.fire_locked ? html` <span class="lock" aria-label="FIRE HOLD">⏸</span>` : EMPTY}</button></li>`
  })}</ol>`
}

function score(d: Doc): Html {
  const c = d.card
  if (!c) return EMPTY
  const s = c.suggestion as { score_100?: number; band?: string; kill?: string | null; anchored?: boolean }
  const h = c.heat as { allow?: boolean; reason?: string; company_load?: number; company_cap?: number; size?: string; ats_vendor?: string; ats_tenant?: string | null }
  return html`<section class="card facts" data-key="score">
    <div class="stat"><b>${c.score_100}</b><span>${c.stored ? "score" : "suggested score"}</span></div>
    <div class="stat"><b>${c.band.replace(/_/g, " ")}</b><span>band</span></div>
    <div class="stat"><b class="heat-${c.class}">${c.class}</b><span>heat ${str(h.company_load ?? "")}${h.company_cap ? ` / ${h.company_cap}` : ""}</span></div>
    ${s.kill ? html`<p class="error">Hard kill: ${s.kill.replace(/_/g, " ")}</p>` : EMPTY}
    ${!c.stored ? html`<p class="hint">The kernel suggests ${str(s.score_100)} (${str(s.band)}). It never overwrites a stored score.
      <button type="button" data-act="keep-score" data-score="${str(s.score_100)}">Keep it</button></p>` : EMPTY}
    <p class="muted">${str(h.size)} company · ATS ${str(h.ats_vendor)}${h.ats_tenant ? ` (${h.ats_tenant})` : ""}${h.allow === false ? html` · <b class="error">${str(h.reason).replace(/_/g, " ")}</b>` : EMPTY}</p>
  </section>`
}

function coverage(d: Doc): Html {
  const c = d.coverage
  if (c.total === 0) return html`<section class="card" data-key="coverage"><h2>Coverage</h2><p class="hint">No target words yet: the listing has no extracted keywords.</p></section>`
  return html`<section class="card" data-key="coverage"><h2>Coverage <span class="muted">${c.hits}/${c.total} · ${Math.round(c.percent)}%</span></h2>
    <div class="terms">${c.terms.map((t) => html`<span class="term ${t.hit ? "hit" : "miss"}" data-key="${t.term}">${t.term}</span>`)}</div></section>`
}

function cv(d: Doc): Html {
  const theme = d.cv.theme as { lead?: string | null; accent?: string; density?: string }
  return html`<section class="card cv cv-${str(theme.accent)} cv-${str(theme.density)}" data-key="cv">
    <h2>CV <span class="muted">${str(theme.density)} · ${str(theme.accent)}${d.lineage ? html` · generation ${str(d.lineage.generation)}, ${str(d.lineage.phase)}` : EMPTY}</span></h2>
    ${theme.lead ? html`<p class="lead">${theme.lead}</p>` : EMPTY}
    ${d.cv.lines.length === 0 ? html`<p class="hint">No CV items yet. Agents add them to the corpus (profiles and items).</p>` : EMPTY}
    <ul class="cv-lines">${d.cv.lines.map((l) => html`<li data-key="i${str(l.item_id)}" class="kind-${str(l.kind)}${l.mode ? ` mode-${str(l.mode)}` : ""}">
      <b>${str(l.title)}</b>${l.org ? html` <span class="muted">${str(l.org)}</span>` : EMPTY}${l.span ? html` <span class="muted">${str(l.span)}</span>` : EMPTY}
      ${l.mode ? html`<span class="tag" title="${str(l.reason)}">${str(l.mode)}</span>` : EMPTY}
      ${l.body ? html`<p>${str(l.body)}</p>` : EMPTY}</li>`)}</ul>
  </section>`
}

function listing(a: Row, appId: number): Html {
  const raw = a.listing_raw as { length?: number; sha?: string } | null
  // A listing rewritten since it was read is read afresh: its sha names the version shown.
  const l = v().listing && v().listing?.sha === (raw?.sha ?? "") ? v().listing : null
  return html`<section class="card" data-key="listing"><h2>Listing ${a.listing_url ? html`<a href="${href(str(a.listing_url))}" rel="noopener noreferrer" target="_blank">open</a>` : EMPTY}</h2>
    ${raw && raw.length ? l === null
      ? html`<button type="button" data-act="listing" data-id="${appId}">Show the raw listing (${raw.length.toLocaleString()} bytes)</button>`
      : html`<p class="hint">As it was captured; shown as text, never run.</p><pre class="untrusted">${l.text}</pre>
          ${l.bytes < l.total ? html`<button type="button" data-act="listing-more" data-id="${appId}">More</button>` : EMPTY}`
      : html`<p class="hint">No listing: this application came another way${a.channel ? ` (${str(a.channel)})` : ""}.</p>`}
  </section>`
}

function prose(a: Row, appId: number): Html {
  return html`${PROSE.map((f) => {
    const t = textOf("applications", appId, f, a[f])
    const lost = t === null && failedText("applications", appId, f, a[f])
    const moved = v().edit === f && Number(a.rev) !== v().editRev
    const title = f.replace(/_raw$/, "").replace(/_/g, " ")
    // An edit starts from the whole text (Edit is enabled only once it is in), and stays on that text
    // while open: an agent's write meanwhile is announced, never swapped in under the operator's typing.
    return v().edit === f
      ? html`<form class="card stack" data-submit="save-prose" data-act="save-prose" data-field="${f}" data-id="${appId}" data-key="p-${f}">
          <h2>${title}</h2>${moved ? html`<p class="notice" role="alert">This application changed after you opened it; saving will be refused rather than overwrite the change. Copy your text, cancel, and reopen.</p>` : EMPTY}
          <textarea name="value" rows="10" data-autofocus>${v().editText.startsWith("\n") ? `\n${v().editText}` : v().editText}</textarea>
          <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>`
      : html`<section class="card" data-key="p-${f}"><h2>${title} <button type="button" class="ghost" data-act="edit" data-field="${f}"${flag("disabled", t === null)}>Edit</button></h2>
          ${lost ? html`<p class="hint">The text could not be read. <button type="button" class="ghost" data-act="retry-text" data-field="${f}">Try again</button></p>`
            : t === null ? html`<p class="hint">Loading…</p>` : t !== "" ? html`<p class="notes">${t}</p>` : html`<p class="hint">Empty.</p>`}</section>`
  })}`
}

function around(): Html {
  const c = v().contact
  const corp = v().corporation
  return html`<section class="card" data-key="around"><h2>People and company</h2>
    ${corp ? html`<p><b>${str(corp.name)}</b> <a href="/world/corporations?q=${encodeURIComponent(str(corp.name))}" data-nav>in the world</a>
      ${corp.careers_url ? html` · <a href="${href(str(corp.careers_url))}" rel="noopener noreferrer" target="_blank">careers</a>` : EMPTY}</p>
      ${corp.headcount ? html`<p class="muted">${Number(corp.headcount).toLocaleString()} people${corp.headcount_on ? ` as of ${str(corp.headcount_on)}` : ""}</p>` : EMPTY}` : html`<p class="hint">No corporation linked.</p>`}
    ${c ? html`<p><a href="/outreach?contact=${str(c.id)}" data-nav><b>${str(c.name)}</b></a> ${str(c.title)}</p>` : EMPTY}
    ${v().messages.length > 0 ? html`<ul class="rows">${v().messages.map((m) => html`<li data-key="m${str(m.id)}"><span class="tag">${str(m.direction)}</span>
      ${str(m.subject) || "(no subject)"} <span class="muted">${str(m.sent_at).slice(0, 10)} · ${str(m.status)}</span></li>`)}</ul>` : EMPTY}
  </section>`
}

function events(d: Doc, appId: number): Html {
  const stage = str(d.application.stage)
  return html`<section class="card" data-key="events"><h2>Events</h2>
    <form class="row" data-submit="note" data-act="note" data-id="${appId}" data-stage="${stage}"><input name="body" placeholder="Add a note to the history" aria-label="Note" required>
      <button>Add</button></form>
    <ol class="rows">${d.events.map((e) => html`<li data-key="e${str(e.id)}"><span class="tag">${str(e.kind)}</span> ${textOf("events", Number(e.id), "body", e.body) ?? "…"}
      <span class="muted">${str(e.actor)}${e.key_id ? ` · key ${str(e.key_id)}` : ""}</span></li>`)}</ol></section>`
}

function view(): Html {
  const appId = id()
  if (appId === 0) {
    return model.address.sub === ""
      ? html`<p class="empty">Pick an application on the <a href="/desk" data-nav>desk</a>.</p>`
      : html`<p class="empty">No application #${model.address.sub} on this desk${model.rows === 0 ? " yet" : ""}.</p>`
  }
  const d = application(appId) as Doc | null
  if (!d) return html`<p class="empty">Loading…</p>`
  const a = d.application
  return html`<div class="focus">
    <header class="focus-head" data-key="head">
      <a href="/desk" data-nav class="ghost">← desk</a>
      <h1>#${str(a.no)} ${str(a.company) || "(no company)"} <span class="muted">${str(a.role)}</span></h1>
      <p class="muted">${[a.location, a.work_mode, a.employment, a.comp_raw].filter((x) => x).map(str).join(" · ")}</p>
    </header>
    ${rail(d, appId)}
    <div class="focus-grid">
      <div class="col">${score(d)}${coverage(d)}${cv(d)}${listing(a, appId)}</div>
      <div class="col">${around()}${prose(a, appId)}${events(d, appId)}
        <section class="card" data-key="override"><h2>Heat override</h2>
          ${a.heat_override ? html`<p>Overridden: ${str(a.heat_override_reason)}</p>` : html`<form class="row" data-submit="override" data-act="override" data-id="${appId}">
            <input name="reason" placeholder="Why this one goes over the cap" aria-label="Reason" required><button>Override</button></form>`}</section>
      </div>
    </div>
  </div>`
}

// ------------------------------------------------------------------ actions

const form = (el: HTMLElement): Record<string, string> => Object.fromEntries([...new FormData(el as HTMLFormElement)].map(([k, x]) => [k, String(x)]))

function act(name: string, el: HTMLElement): void {
  const appId = Number(el.dataset.id ?? id())
  switch (name) {
    case "stage": {
      const stage = el.dataset.stage ?? ""
      if (!(ENUMS.stage ?? []).includes(stage)) return
      return void command("stage", appId, { stage }).catch(failed)
    }
    case "fire":
      // Arming has its own slot (an open prose editor stays open) and lapses if the second click does not come.
      if (v().fireArmed !== appId) {
        patch({ fireArmed: appId })
        setTimeout(() => v().fireArmed === appId && patch({ fireArmed: 0 }), 6000)
        return
      }
      patch({ fireArmed: 0 })
      return void command("open_fire", appId)
        .then(() => notice("ok", "Fire is open for this application."))
        .catch(failed)
    case "keep-score":
      return void put("applications", { score_100: Number(el.dataset.score) }, { id: appId }).catch(failed)
    case "listing":
      return void rpc<{ text: string; total: number }>("text", { table: "applications", id: appId, column: "listing_raw", length: 262_144 })
        .then((r) => mine(appId, { listing: { text: r.text, bytes: new TextEncoder().encode(r.text).byteLength, total: r.total, sha: listingSha(appId) } }))
        .catch(failed)
    case "listing-more": {
      const l = v().listing
      if (!l) return
      return void rpc<{ text: string; total: number }>("text", { table: "applications", id: appId, column: "listing_raw", offset: l.bytes, length: 262_144 })
        .then((r) => {
          if (v().listing === l && l.sha === listingSha(appId)) mine(appId, { listing: { ...l, text: l.text + r.text, bytes: l.bytes + new TextEncoder().encode(r.text).byteLength, total: r.total } })
        })
        .catch(failed)
    }
    case "edit": {
      const d = application(appId) as Doc | null
      const field = el.dataset.field ?? ""
      const t = d ? textOf("applications", appId, field, d.application[field]) : null
      if (t === null) return
      return patch({ edit: field, editRev: Number(d?.application.rev ?? 0), editText: t })
    }
    case "retry-text":
      unread.clear()
      return patch({})
    case "cancel":
      return patch({ edit: "" })
    case "save-prose": {
      const f = form(el)
      const field = el.dataset.field ?? ""
      // The edit was made against the row's rev when the form opened; a write since then is refused, not overwritten.
      return void put("applications", { [field]: (f.value ?? "") === "" ? null : (f.value as Input) }, { id: appId, expectRev: v().editRev })
        .then(() => patch({ edit: "" }))
        .catch(failed)
    }
    case "note":
      return void command("note", appId, { stage: el.dataset.stage ?? "", body: form(el).body ?? "" })
        .then(() => (el as HTMLFormElement).reset())
        .catch(failed)
    case "override":
      return void command("heat_override", appId, { reason: form(el).reason ?? "" }).catch(failed)
  }
}

const focus: View = {
  title: "Focus",
  view,
  enter() {
    const appId = id()
    if (appId !== 0 && appId !== v().id) {
      const d = application(appId) as Doc | null
      if (d) void fetchAround(appId, d.application)
    } else if (appId !== 0) {
      // Back on the same application: what an agent changed meanwhile is read again.
      focus.refresh?.()
    }
  },
  after() {
    // The application may land after the address (a cold load straight to /focus/<no>).
    const appId = id()
    if (appId !== 0 && appId !== v().id) focus.enter?.()
  },
  act,
  refresh() {
    const appId = id()
    if (appId === 0) return
    // The application's current links, read from its row now: a changed contact or corporation is followed.
    const a = (application(appId) as Doc | null)?.application
    void rpc<{ rows: Row[] }>("find", { table: "messages", where: { application_id: appId }, order: ["sent_at", "asc"], limit: 200 })
      .then((r) => mine(appId, { messages: r.rows }))
      .catch(() => {})
    if (a?.corporation_id) void rpc<{ row: Row }>("get", { table: "corporations", id: Number(a.corporation_id) }).then((r) => mine(appId, { corporation: r.row })).catch(() => {})
    else mine(appId, { corporation: null })
    if (a?.contact_id) void rpc<{ row: Row }>("get", { table: "contacts", id: Number(a.contact_id) }).then((r) => mine(appId, { contact: r.row })).catch(() => {})
    else mine(appId, { contact: null })
  },
  key(ev) {
    if (ev.key === "Escape") {
      if (v().fireArmed !== 0) patch({ fireArmed: 0 })
      else if (v().edit !== "") patch({ edit: "" })
      else go({ lens: "desk", sub: "" })
      return true
    }
    return false
  },
}

export default focus
