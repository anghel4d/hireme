// The focus lens: one application. Everything derived about it (the rail,
// the score and its suggestion, heat, keyword coverage, the CV composed
// through its lineage's overlays, events) is the kernel's one document,
// the same the MCP reads. The raw listing is in the replica and unfolded only when
// asked for; the application's messages, contact and corporation are in
// the replica too, read in the frame they are drawn. Moves along the rail are the `stage`
// command, judged by the kernel here before the sequencer judges it again.

import type { View } from "../app.ts"
import { ENUMS } from "../gen/schema.ts"
import { failed, application, command, lookup, put, query as read, type Input } from "../kernel.ts"
import { EMPTY, entries, flag, href, html, resetIfUnchanged, type Html } from "../morph.ts"
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

/** A text column of the replica: its text, "" when there is none. */
const textOf = (v_: unknown): string => (typeof v_ === "string" ? v_ : "")
// One formatter: toLocaleString builds a new one per call.
const NUM = new Intl.NumberFormat()
/** UTF-8 bytes of a string, counted without encoding it. */
function utf8(s: string): number {
  let n = s.length
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) continue
    // A surrogate pair is 4 bytes (2 units + 2); a lone surrogate is encoded as U+FFFD, 3.
    const pair = c >= 0xd800 && c <= 0xdbff && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00
    n += c < 0x800 ? 1 : 2
    if (pair) i++
  }
  return n
}

/** A row of the replica by id, or null. */
function rowOf(table: string, rowId: number): Row | null {
  if (!rowId) return null
  try {
    return read<{ row: Row }>("get", { table, id: rowId }).row
  } catch {
    return null
  }
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
    <div class="stat"><b class="heat-${c.class}">${c.class}</b><span title="Applications in flight at this company, against the heat cap">heat · ${str(h.company_load ?? 0)}${h.company_cap ? ` of ${h.company_cap}` : ""} at this company</span></div>
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
    <h2>CV for this application${d.lineage ? html` <span class="muted">version ${str(d.lineage.generation)}</span>` : EMPTY}
      <span class="muted" title="CV layout and lineage phase">${str(theme.density)} · ${str(theme.accent)}${d.lineage ? ` · ${str(d.lineage.phase)}` : ""}</span></h2>
    ${theme.lead ? html`<p class="lead">${theme.lead}</p>` : EMPTY}
    ${d.cv.lines.length === 0 ? html`<p class="hint">No CV items yet. Agents add them to the corpus (profiles and items).</p>` : EMPTY}
    <ul class="cv-lines">${d.cv.lines.map((l) => html`<li data-key="i${str(l.item_id)}" class="kind-${str(l.kind)}${l.mode ? ` mode-${str(l.mode)}` : ""}">
      <b>${str(l.title)}</b>${l.org ? html` <span class="muted">${str(l.org)}</span>` : EMPTY}${l.span ? html` <span class="muted">${str(l.span)}</span>` : EMPTY}
      ${l.mode ? html`<span class="tag" title="${str(l.reason)}">${str(l.mode)}</span>` : EMPTY}
      ${l.body ? html`<p>${str(l.body)}</p>` : EMPTY}</li>`)}</ul>
  </section>`
}

function listing(a: Row, appId: number): Html {
  const text = a.listing_raw === null || a.listing_raw === undefined ? "" : textOf(a.listing_raw)
  return html`<section class="card" data-key="listing"><h2>Listing ${a.listing_url ? html`<a href="${href(str(a.listing_url))}" rel="noopener noreferrer" target="_blank">open the posting ↗</a>` : EMPTY}</h2>
    ${text !== "" ? !v().listing
      ? html`<button type="button" data-act="listing" data-id="${appId}">Show the raw listing (${NUM.format(utf8(text))} bytes)</button>`
      : html`<p class="hint">As it was captured; shown as text, never run.</p><pre class="untrusted">${text}</pre>`
      : html`<p class="hint">No listing: this application came another way${a.channel ? ` (${str(a.channel)})` : ""}.</p>`}
  </section>`
}

function prose(a: Row, appId: number): Html {
  return html`${PROSE.map((f) => {
    const t = textOf(a[f])
    const moved = v().edit === f && Number(a.rev) !== v().editRev
    const title = f.replace(/_raw$/, "").replace(/_/g, " ")
    // An edit starts from the whole text, and stays on that text
    // while open: an agent's write meanwhile is announced, never swapped in under the operator's typing.
    return v().edit === f
      ? html`<form class="card stack" data-submit="save-prose" data-act="save-prose" data-field="${f}" data-id="${appId}" data-key="p-${f}">
          <h2>${title}</h2>${moved ? html`<p class="notice" role="alert">This application changed after you opened it; saving will be refused rather than overwrite the change. Copy your text, cancel, and reopen.</p>` : EMPTY}
          <textarea name="value" rows="10" data-autofocus>${v().editText.startsWith("\n") ? `\n${v().editText}` : v().editText}</textarea>
          <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>`
      : html`<section class="card" data-key="p-${f}"><h2>${title} <button type="button" class="ghost" data-act="edit" data-field="${f}">${t !== "" ? "Edit" : "Write"}</button></h2>
          ${t !== "" ? html`<p class="notes">${t}</p>` : html`<p class="hint">No ${title} yet.</p>`}</section>`
  })}`
}

function around(a: Row, appId: number): Html {
  const c = rowOf("contacts", Number(a.contact_id ?? 0))
  const corp = rowOf("corporations", Number(a.corporation_id ?? 0))
  const messages = read<{ rows: Row[] }>("find", { table: "messages", where: { application_id: appId }, order: ["sent_at", "asc"], limit: 200 }).rows
  return html`<section class="card" data-key="around"><h2>People and company</h2>
    ${corp ? html`<p><b>${str(corp.name)}</b> <a href="/world/corporations?q=${encodeURIComponent(str(corp.name))}" data-nav>in the world</a>
      ${corp.careers_url ? html` · <a href="${href(str(corp.careers_url))}" rel="noopener noreferrer" target="_blank">careers</a>` : EMPTY}</p>
      ${corp.headcount ? html`<p class="muted">${NUM.format(Number(corp.headcount))} people${corp.headcount_on ? ` as of ${str(corp.headcount_on)}` : ""}</p>` : EMPTY}` : html`<p class="hint">No corporation linked.</p>`}
    ${c ? html`<p><a href="/outreach?contact=${str(c.id)}" data-nav><b>${str(c.name)}</b></a> ${str(c.title)}</p>` : EMPTY}
    ${messages.length > 0 ? html`<ul class="rows">${messages.map((m) => html`<li data-key="m${str(m.id)}"><span class="tag">${str(m.direction)}</span>
      ${str(m.subject) || "(no subject)"} <span class="muted">${str(m.sent_at).slice(0, 10)} · ${str(m.status)}</span></li>`)}</ul>` : EMPTY}
  </section>`
}

function events(d: Doc, appId: number): Html {
  const stage = str(d.application.stage)
  return html`<section class="card" data-key="events"><h2>Events</h2>
    <form class="row grow" data-submit="note" data-act="note" data-id="${appId}" data-stage="${stage}"><input name="body" placeholder="Add a note to the history" aria-label="Note" required>
      <button>Add</button></form>
    <ol class="rows">${d.events.map((e) => html`<li data-key="e${str(e.id)}"><span class="tag">${str(e.kind)}</span> ${str(e.kind) === "stage" ? textOf(e.body).replace(/_/g, " ") : textOf(e.body)}
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
      <div class="col">${around(a, appId)}${prose(a, appId)}${events(d, appId)}
        <section class="card" data-key="override"><h2>Heat override</h2>
          ${a.heat_override ? html`<p>Overridden: ${str(a.heat_override_reason)}</p>` : html`<form class="row grow" data-submit="override" data-act="override" data-id="${appId}">
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
      return patch({ listing: true })
    case "edit": {
      const d = application(appId) as Doc | null
      const field = el.dataset.field ?? ""
      if (!d) return
      return patch({ edit: field, editRev: Number(d.application.rev ?? 0), editText: textOf(d.application[field]) })
    }
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
    case "note": {
      const before = entries(el as HTMLFormElement)
      return void command("note", appId, { stage: el.dataset.stage ?? "", body: form(el).body ?? "" })
        .then(() => resetIfUnchanged(el as HTMLFormElement, before))
        .catch(failed)
    }
    case "override":
      return void command("heat_override", appId, { reason: form(el).reason ?? "" }).catch(failed)
  }
}

const focus: View = {
  title: "Focus",
  view,
  enter() {
    // Another application: its listing folds and its editor closes.
    const appId = id()
    if (appId !== v().id) patch({ id: appId, listing: false, edit: "" })
  },
  act,
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
