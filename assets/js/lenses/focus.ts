// One application, opened on the desk or beside its board. Everything derived about it (the rail,
// the score and its suggestion, heat, keyword coverage, the CV composed
// through its lineage's overlays, events) is the kernel's one document,
// the same the MCP reads. The raw listing is in the replica and unfolded only when
// asked for; the application's messages, contact and corporation are in
// the replica too, read in the frame they are drawn. Moves along the rail are the `stage`
// command, judged by the kernel here before the sequencer judges it again.

import { ENUMS } from "../gen/schema.ts"
import { application, ask, command, failed, ids, put, Refused, row, value, type Input, type Row } from "../kernel.ts"
import { EMPTY, fields, flag, href, html, resetAfter, str, type Html } from "../morph.ts"
import { drafts, item, model, notice, set, type FocusView } from "../state.ts"
import { ROUTE, WHY as HOLD } from "./fire.ts"
import { inSpam, itemAct, itemList, outreachQuery, SPAM } from "./outreach.ts"
import { rowHref } from "./world.ts"

type Doc = {
  application: Row
  card: { score_100: number; stored: boolean; band: string; class: string; suggestion: Row; heat: Row } | null
  rail: { stage: string; label: string; hint: string; pip: string; fire_locked: boolean }[]
  coverage: { hits: number; total: number; percent: number; terms: { term: string; hit: boolean }[] }
  cv: { theme: Row; lines: Row[]; file: { format: string; version_id: number; n: number; text: string } | null }
  events: Row[]
  batch: Row | null
  lineage: Row | null
  missions: Mission[]
  cv_pick: { state: string; root: number | null; arm: number | null; by: string | null; also: number[]; version_id: number | null } | null
}

const v = (): FocusView => model.focus
/** The fold and the editor belong to the application they were opened on. */
const mine = (appId: number): boolean => v().id === appId
const patch = (p: Partial<FocusView>) => set({ focus: { ...model.focus, ...p } })

/** An application's item segment: its number, then its company and role. */
export const appItem = (appId: number): string => item(value("applications", appId, "no"), value("applications", appId, "company"), value("applications", appId, "role"))

const PROSE = ["notes", "battleplan", "letter_raw"] as const

/** A text column of the replica: its text, "" when there is none. */
const textOf = (v_: unknown): string => (typeof v_ === "string" ? v_ : "")
// One formatter: toLocaleString builds a new one per call.
const NUM = new Intl.NumberFormat()
const LOAD = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1 })
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
      ${fire && armed ? "Open fire: click again" : r.label}${r.fire_locked ? html` <span class="lock" aria-label="FIRE HOLD">‖</span>` : EMPTY}</button></li>`
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
    <div class="stat"><b class="heat-${c.class}">${c.class}</b><span title="Sent applications at this company, weighted by what happened to each and how close each role is to this one, against the company's capacity">heat · ${LOAD.format(h.company_load ?? 0)}${h.company_cap ? ` of ${LOAD.format(h.company_cap)}` : ""} at this company${h.allow === false && h.reason ? ` · ${h.reason.replace(/_/g, " ")}` : ""}</span></div>
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

/** Why the kernel gives this application its CV root, in words. */
const WHY: Record<string, (p: NonNullable<Doc["cv_pick"]>) => string> = {
  pinned: (p) => `pinned by the ${p.by ?? "operator"}`,
  matched: (p) => `rule #${p.arm}${p.also.length > 0 ? `; #${p.also.join(", #")} matched too` : ""}`,
  default: () => "no rule matches: the default",
  none: () => "no rule matches and there is no default",
  stale: () => "pinned to a deleted CV",
  empty: () => "that CV has no versions yet",
}

/** The root this application goes out with: the ordered match's pick, or a pin over it. */
function pick(d: Doc, appId: number): Html {
  const p = d.cv_pick
  if (!p) return EMPTY
  const rootName = (id: number): string => str(value("cv_roots", id, "name")) || `#${id}`
  const sent = Number(d.application.cv_version_id ?? 0)
  return html`<form class="row cv-pick" data-submit="pick" data-act="pick" data-id="${appId}" data-key="pick">
    <label>Goes out as <select name="root">${p.root === null ? html`<option value="">none</option>` : EMPTY}${[...ids("cv_roots")].map((r) => html`<option value="${r}"${flag("selected", r === p.root)}>${rootName(r)}</option>`)}</select></label>
    <button>Pin</button>${p.state === "pinned" ? html`<button type="button" class="ghost" data-act="unpin" data-id="${appId}">Unpin</button>` : EMPTY}
    <a href="/me/rules" data-nav class="muted" title="The rules that pick a CV">${WHY[p.state]?.(p) ?? p.state}${sent ? ` · sent v${str(value("cv_versions", sent, "n"))}` : ""}</a></form>`
}

/** A file root's newest version: its text as written or extracted (what coverage reads), and the file itself. */
function file(f: NonNullable<Doc["cv"]["file"]>): Html {
  const sha = str(value("cv_versions", f.version_id, "blob_sha"))
  const name = str(value("cv_versions", f.version_id, "blob_name"))
  return html`<p class="muted">v${f.n} · ${f.format}${sha ? html` · <a href="/blobs/${sha}?name=${encodeURIComponent(name)}" target="_blank" rel="noopener">${name || "the file"} ↗</a>` : EMPTY}</p>
    ${f.text ? html`<pre class="untrusted">${f.text}</pre>` : html`<p class="hint">No text could be read from this file.</p>`}`
}

function cv(d: Doc, appId: number): Html {
  const theme = d.cv.theme as { lead?: string | null; accent?: string; density?: string }
  return html`<section class="card cv cv-${str(theme.accent)} cv-${str(theme.density)}" data-key="cv">
    <h2>CV for this application${!d.cv.file && d.lineage ? html` <span class="muted">version ${str(d.lineage.generation)}</span>` : EMPTY}
      ${d.cv.file ? EMPTY : html`<span class="muted" title="CV layout and lineage phase">${str(theme.density)} · ${str(theme.accent)}${d.lineage ? ` · ${str(d.lineage.phase)}` : ""}</span>`}</h2>
    ${pick(d, appId)}
    ${d.cv.file ? file(d.cv.file) : html`${theme.lead ? html`<p class="lead">${theme.lead}</p>` : EMPTY}
    ${d.cv.lines.length === 0 ? html`<p class="hint">No CV items yet. Agents add them to the corpus (profiles and items).</p>` : EMPTY}
    <ul class="cv-lines">${d.cv.lines.map((l) => html`<li data-key="i${str(l.item_id)}" class="kind-${str(l.kind)}${l.mode ? ` mode-${str(l.mode)}` : ""}">
      <b>${str(l.title)}</b>${l.org ? html` <span class="muted">${str(l.org)}</span>` : EMPTY}${l.span ? html` <span class="muted">${str(l.span)}</span>` : EMPTY}
      ${l.mode ? html`<span class="tag" title="${str(l.reason)}">${str(l.mode)}</span>` : EMPTY}
      ${l.body ? html`<p>${str(l.body)}</p>` : EMPTY}</li>`)}</ul>`}
  </section>`
}

function listing(a: Row, appId: number): Html {
  const text = textOf(a.listing_raw)
  return html`<section class="card" data-key="listing"><h2>Listing ${a.listing_url ? html`<a href="${href(str(a.listing_url))}" rel="noopener noreferrer" target="_blank">open the posting ↗</a>` : EMPTY}</h2>
    ${text !== "" ? !(mine(appId) && v().listing)
      ? html`<button type="button" data-act="listing" data-id="${appId}">Show the raw listing (${NUM.format(utf8(text))} bytes)</button>`
      : html`<p class="hint">As it was captured; shown as text, never run.</p><pre class="untrusted">${text}</pre>`
      : html`<p class="hint">No listing: this application came another way${a.channel ? ` (${str(a.channel)})` : ""}.</p>`}
  </section>`
}

function prose(a: Row, appId: number): Html {
  return html`${PROSE.map((f) => {
    const t = textOf(a[f])
    const editing = mine(appId) && v().edit === f
    const moved = editing && Number(a.rev) !== v().editRev
    const title = f.replace(/_raw$/, "").replace(/_/g, " ")
    // An edit starts from the whole text, and stays on that text
    // while open: an agent's write meanwhile is announced, never swapped in under the operator's typing.
    return editing
      ? html`<form class="card stack" data-submit="save-prose" data-act="save-prose" data-field="${f}" data-id="${appId}" data-key="p-${f}">
          <h2>${title}</h2>${moved ? html`<p class="notice" role="alert">This application changed after you opened it; saving will be refused rather than overwrite the change. Copy your text, cancel, and reopen.</p>` : EMPTY}
          <textarea name="value" rows="10" data-autofocus>${v().editText.startsWith("\n") ? `\n${v().editText}` : v().editText}</textarea>
          <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>`
      : html`<section class="card" data-key="p-${f}"><h2>${title} <button type="button" class="ghost" data-act="edit" data-field="${f}">${t !== "" ? "Edit" : "Write"}</button></h2>
          ${drafts.get(`app:${appId}:${f}`) ? html`<p class="notice" data-key="kept">An unsaved edit of this is kept in this browser.
            <button type="button" data-act="edit" data-field="${f}" data-kept>Resume it</button> <button type="button" class="ghost" data-act="drop-kept" data-field="${f}">Discard</button></p>` : EMPTY}
          ${t !== "" ? html`<p class="notes">${t}</p>` : html`<p class="hint">No ${title} yet.</p>`}</section>`
  })}`
}

function around(a: Row, appId: number): Html {
  const c = row("contacts", Number(a.contact_id ?? 0))
  const corp = row("corporations", Number(a.corporation_id ?? 0))
  const said = outreachQuery({ where: { application_id: appId }, sort: ["at", "desc"], group: "", limit: 100 })
  return html`<section class="card" data-key="around"><h2>People and company</h2>
    ${corp ? html`<p><b>${str(corp.name)}</b> <a href="${rowHref("corporations", Number(corp.id), corp)}" data-nav>in the world</a>
      ${corp.careers_url ? html` · <a href="${href(str(corp.careers_url))}" rel="noopener noreferrer" target="_blank">careers</a>` : EMPTY}</p>
      ${corp.headcount ? html`<p class="muted">${NUM.format(Number(corp.headcount))} people${corp.headcount_on ? ` as of ${str(corp.headcount_on)}` : ""}</p>` : EMPTY}` : html`<p class="hint">No corporation linked.</p>`}
    ${c ? html`<p><a href="/outreach/${item(c.id, c.name)}" data-nav><b>${str(c.name)}</b></a> ${str(c.title)}</p>` : EMPTY}
  </section>
  ${said && said.rows.length > 0 ? html`<section class="card" data-key="said"><h2>Outreach <span class="muted">${said.total}</span> ${said.rows.some(inSpam) ? SPAM : EMPTY}</h2>${itemList(said)}</section>` : EMPTY}`
}

function events(d: Doc, appId: number): Html {
  const stage = str(d.application.stage)
  return html`<section class="card" data-key="events"><h2>Events</h2>
    <form class="row grow" data-submit="note" data-act="note" data-id="${appId}" data-stage="${stage}"><input name="body" placeholder="Add a note to the history" aria-label="Note" required>
      <button>Add</button></form>
    <ol class="rows">${d.events.map((e) => html`<li data-key="e${str(e.id)}"><span class="tag">${str(e.kind)}</span> ${str(e.kind) === "stage" ? textOf(e.body).replace(/_/g, " ") : textOf(e.body)}
      <span class="muted">${str(e.actor)}${e.key_id ? ` · key ${str(e.key_id)}` : ""}</span></li>`)}</ol></section>`
}

const LINK = html`<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>`
const COPY = html`<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>`

// ------------------------------------------------------------------ missions: the routes it goes out by

type Mission = { id: number; kind: string; sender: string; target: string | null; cc: string | null; subject: string | null; draft: string | null; in_reply_to: string | null; state: string; last_error: string | null; fired_at: string | null; fired_by: string | null; fire_key_id: number | null; in_flight_at: string | null; confirmation: string | null; cv_version_id: number | null; covered_by: number[]; hold: string | null }

/** The commander's answer to a refused shot, as a sentence: why, and what the key still holds. */
export function commander(d: Row): string {
  const why: Record<string, string> = {
    no_key: "no live fire key covers it: authorize it first",
    burned: `its shot under key #${str(d.key)} is spent`,
    changed: `it was edited after key #${str(d.key)} was made, so that key no longer covers it`,
    expired: `key #${str(d.key)} has expired`,
    revoked: `key #${str(d.key)} was revoked`,
    out_of_scope: `key #${str(d.key)} does not cover it`,
    not_yours: `key #${str(d.key)} is for another API key`,
    domain_sender: "it goes out as the domain address, and none is set (Account → Mail)",
    mailbox: "Gmail is not linked and live",
  }
  const left = d.key ? ` Key #${str(d.key)} has ${str(d.remaining) || "nothing"} left${d.expires_in ? `, ${str(d.expires_in)} to go` : ""}.` : ""
  return `Mission ${str(d.mission)} did not fire: ${why[str(d.why)] ?? str(d.why)}.${left}`
}

/** The states a put moves a mission among; in flight and fired are the commands'. */
const STAGED = ["draft", "draft_ready", "fire_ready", "cancelled"]

/** A mission's compose: an email's To, Cc, subject and body are the mission itself, as its key's hash freezes them. */
/** Who an email goes out as, by the account's mailbox row: the linked Gmail, or the domain address. */
function senders(): Record<string, string> {
  const box = ask<{ rows: Row[] }>("find", { table: "mailboxes", limit: 1 })?.rows[0]
  return { gmail: `Gmail · ${str(box?.address) || "not linked"}`, domain: `Domain · ${str(box?.domain_from) || "not set (Account → Mail)"}` }
}

function compose(m: Mission, appId: number): Html {
  const email = m.kind === "email"
  const from = senders()
  const moved = Number(row("missions", m.id)?.rev ?? 0) !== v().editRev
  return html`<form class="stack" data-submit="save-mission" data-act="save-mission" data-mission="${m.id}" data-id="${appId}">
    ${m.covered_by.length > 0 ? html`<p class="warn">Key #${m.covered_by[0]} covers this mission as it reads now: a saved edit takes it out of that key.</p>` : EMPTY}
    ${moved ? html`<p class="notice" role="alert">This mission changed after you opened it; saving will be refused rather than overwrite the change.</p>` : EMPTY}
    <label>${email ? "To (up to 10, comma-separated)" : "Target (a URL or a handle)"} <input name="target" value="${m.target ?? ""}"${flag("required", email)}></label>
    ${email ? html`<label>From <select name="sender">${Object.entries(from).map(([k, label]) => html`<option value="${k}"${flag("selected", k === m.sender)}>${label}</option>`)}</select></label>` : EMPTY}
    ${email ? html`<label>Cc <input name="cc" value="${m.cc ?? ""}"></label><label>Subject <input name="subject" value="${m.subject ?? ""}" required></label>` : EMPTY}
    <label>${email ? "Body" : "Draft (markdown: a form's fields, a message's text)"} <textarea name="draft" rows="12" data-autofocus>${m.draft ?? ""}</textarea></label>
    <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>`
}

function missions(d: Doc, appId: number): Html {
  const cv = d.cv.file
  const ms = d.missions ?? []
  const from = senders()
  return html`<section class="card" data-key="missions"><h2>Missions</h2>
    ${ms.length === 0 ? html`<p class="hint">No route yet: add one below (the hiring address, the careers page, a message).</p>` : EMPTY}
    <ul class="rows">${ms.map((m) => {
    const ready = m.state === "fire_ready"
    const covered = m.covered_by.length > 0
    const email = m.kind === "email"
    const staged = STAGED.includes(m.state)
    // A first email carries the picked CV as a file; a reply inside a thread goes without one (the judge's cv_file).
    const first = email && !m.in_reply_to
    if (mine(appId) && v().edit === `m${m.id}`) return html`<li data-key="mi${m.id}"><strong>${ROUTE[m.kind] ?? m.kind}</strong> #${m.id}${compose(m, appId)}</li>`
    return html`<li data-key="mi${m.id}"><strong>${ROUTE[m.kind] ?? m.kind}</strong> <code>${m.target ?? ""}</code>
      ${staged ? html`<select data-act="mission-state" data-on="change" data-mission="${m.id}" aria-label="State">${STAGED.map((x) => html`<option value="${x}"${flag("selected", x === m.state)}>${x.replace("_", " ")}</option>`)}</select>
        <button type="button" class="ghost" data-act="mission-edit" data-mission="${m.id}">Edit</button>` : html`<span class="tag">${m.state.replace("_", " ")}</span>`}
      ${email && m.subject ? html`<p>${m.subject}</p>` : EMPTY}
      ${email ? html`<p class="muted">${staged ? "From" : "Sent as"} ${from[m.sender] ?? m.sender}</p>` : EMPTY}
      ${first && cv ? html`<p class="muted">The picked CV: v${cv.n} · ${cv.format}</p>` : EMPTY}
      ${m.hold && staged && m.hold !== "not_ready" ? html`<p class="warn">Cannot fire: ${HOLD[m.hold] ?? m.hold}.</p>` : EMPTY}
      ${m.confirmation === "provisional" ? html`<span class="tag warn" title="Self-reported: it counts once a confirmation mail arrives">provisional</span>` : EMPTY}
      ${m.fired_at ? html`<p class="muted">Fired ${new Date(m.fired_at).toLocaleString()} by ${m.fired_by ?? "?"}${m.fire_key_id ? ` under key #${m.fire_key_id}` : ""}${m.cv_version_id ? `, carrying CV version ${m.cv_version_id}` : ""}.</p>` : EMPTY}
      ${m.last_error ? html`<p class="warn">Last shot failed: ${m.last_error}</p>` : EMPTY}
      ${ready ? html`<div class="actions">
        <button type="button" class="danger" data-act="mission-fire" data-mission="${m.id}" data-kind="${m.kind}"${flag("disabled", !covered)} title="${covered ? `Under key #${m.covered_by[0]}` : "No live fire key covers this mission"}">${email ? "Send" : "Fire"}</button>
        ${covered ? EMPTY : html`<a class="ghost" href="/fire?missions=${m.id}" data-nav>Authorize</a>`}
</div>` : EMPTY}
      ${m.state === "in_flight" && !email ? html`<div class="actions"><span class="muted">Submitted by hand? Report it.</span>
        <button type="button" data-act="mission-landed" data-mission="${m.id}">It went out</button>
        <form class="row grow" data-submit="mission-failed" data-mission="${m.id}"><input name="reason" placeholder="Or what refused it" aria-label="Why it failed" required><button class="ghost">It failed</button></form></div>` : EMPTY}
      ${m.state === "in_flight" && email ? html`<p class="muted">Sending since ${m.in_flight_at ?? ""}…</p>` : EMPTY}</li>`
  })}</ul>
    <form class="row grow" data-submit="mission-add" data-act="mission-add" data-id="${appId}">
      <select name="kind" aria-label="Route">${(ENUMS.outreach_kind ?? []).filter((k) => k !== "note").map((k) => html`<option value="${k}">${ROUTE[k] ?? k}</option>`)}</select>
      <input name="target" placeholder="Address, URL or handle" aria-label="Target"><button>Add route</button></form></section>`
}

/**
 * One application whole: opened on the desk, and the pro view's pane
 * (`embedded`), where the way back is the board beside it and the way on is
 * opening it.
 */
export function body(appId: number, embedded: boolean): Html {
  const d = application(appId) as Doc | null
  if (!d) return html`<p class="empty">Loading…</p>`
  const a = d.application
  return html`<div class="focus${embedded ? " embedded" : ""}">
    <header class="focus-head" data-key="head">
      ${embedded ? html`<a href="/desk/${appItem(appId)}" data-act="open-app" data-id="${appId}" class="ghost">Open it →</a>` : html`<a href="/desk" data-act="back" class="ghost">← desk</a>`}
      <div class="title-row">
        <h1>#${str(a.no)} ${str(a.company) || "(no company)"} <span class="muted">${str(a.role)}</span></h1>
        <span class="detail-actions">
          <button type="button" class="detail-action" data-act="copy-link" data-id="${appId}" title="Copy a link to this card" aria-label="Copy link">${LINK}</button>
          <button type="button" class="detail-action" data-act="copy-md" data-id="${appId}" title="Copy this application as Markdown" aria-label="Copy as Markdown">${COPY}</button>
        </span>
      </div>
      <p class="muted">${[a.location, a.work_mode, a.employment, a.comp_raw].filter((x) => x).map(str).join(" · ")}</p>
    </header>
    ${rail(d, appId)}
    <div class="focus-grid">
      <div class="col">${score(d)}${coverage(d)}${cv(d, appId)}${listing(a, appId)}</div>
      <div class="col">${missions(d, appId)}${around(a, appId)}${prose(a, appId)}${events(d, appId)}
        <section class="card" data-key="override"><h2>Heat override</h2>
          ${a.heat_override ? html`<p>Overridden: ${str(a.heat_override_reason)}</p>` : html`<form class="row grow" data-submit="override" data-act="override" data-id="${appId}">
            <input name="reason" placeholder="Why this one goes over the cap" aria-label="Reason" required><button>Override</button></form>`}</section>
      </div>
    </div>
  </div>`
}

/** A card's link: the application opened on the desk. */
export const link = (appId: number): string => `${location.origin}/desk/${encodeURIComponent(appItem(appId))}`

/** Markdown that a person or an agent's text could break is escaped; prose is kept as written. */
const md = (x: unknown): string => str(x).replace(/([\\*_~`|[\]#<>])/g, "\\$1")

/** One application as Markdown: its facts, its prose, its history, and the raw listing last. */
export function markdown(appId: number): string {
  const d = application(appId) as Doc | null
  if (!d) return ""
  const a = d.application
  const c = d.card
  const h = (c?.heat ?? {}) as { company_load?: number; company_cap?: number; reason?: string; allow?: boolean }
  const corp = row("corporations", Number(a.corporation_id ?? 0))
  const contact = row("contacts", Number(a.contact_id ?? 0))
  const field = (label: string, x: unknown): string | null => (x === null || x === undefined || x === "" ? null : `**${label}:** ${md(x)}`)
  const meta = [
    field("Stage", str(a.stage).replace(/_/g, " ")),
    c ? `**Score:** ${c.score_100}${c.stored ? "" : " (suggested)"} · ${md(c.band.replace(/_/g, " "))}` : null,
    c ? `**Heat:** ${c.class} · ${LOAD.format(h.company_load ?? 0)} of ${LOAD.format(h.company_cap ?? 0)}${h.allow === false && h.reason ? ` · ${h.reason.replace(/_/g, " ")}` : ""}` : null,
    field("Where", [a.location, a.work_mode, a.employment].filter((x) => x).map(str).join(" · ")),
    field("Comp", a.comp_raw),
    field("Channel", a.channel),
    a.listing_url ? `**Listing:** ${str(a.listing_url)}` : null,
    field("Applied", a.applied_on),
    field("Replied", a.replied_on),
    field("Outcome", a.outcome),
    field("Batch", d.batch?.code),
    corp ? `**Corporation:** ${md(corp.name)}${corp.domain ? ` (${str(corp.domain)})` : ""}` : null,
    contact ? `**Contact:** ${md(contact.name)}${contact.title ? `, ${md(contact.title)}` : ""}` : null,
    d.coverage.total > 0 ? `**Keywords:** ${d.coverage.hits} of ${d.coverage.total}${d.coverage.terms.some((t) => !t.hit) ? ` · missing ${d.coverage.terms.filter((t) => !t.hit).map((t) => md(t.term)).join(", ")}` : ""}` : null,
    `**Link:** ${link(appId)}`,
  ].filter((x): x is string => x !== null)
  const prose = PROSE.flatMap((f) => (textOf(a[f]) === "" ? [] : ["", `**${f.replace(/_raw$/, "").replace(/_/g, " ").replace(/^./, (x) => x.toUpperCase())}**`, "", textOf(a[f])]))
  const history = d.events.length === 0 ? [] : ["", "**History**", ...d.events.map((e) => `- ${str(e.kind)}: ${md(str(e.kind) === "stage" ? textOf(e.body).replace(/_/g, " ") : textOf(e.body)).replace(/\n/g, " ")}`)]
  const raw = textOf(a.listing_raw)
  const listingText = raw === "" ? [] : ["", "**Listing as captured**", "", "```", raw.replace(/```/g, "ʼʼʼ"), "```"]
  return [`# #${str(a.no)} ${md(a.company) || "(no company)"} — ${md(a.role)}`, "", ...meta, ...prose, ...history, ...listingText, ""].join("\n")
}

/** Copies `text` (the page is a secure context, so the clipboard API is there); the button says how it went. */
function copy(button: HTMLElement, text: string): void {
  const done = (ok: boolean) => {
    button.dataset.copied = String(ok)
    setTimeout(() => delete button.dataset.copied, 1200)
  }
  navigator.clipboard.writeText(text).then(() => done(true), () => done(false))
}

// A prose edit is kept as it is typed, with the rev it was begun on, until saved or discarded.
addEventListener("input", (ev) => {
  const form = (ev.target as Element | null)?.closest?.<HTMLFormElement>('form[data-act="save-prose"]')
  const text = form?.querySelector("textarea")?.value
  if (form && text !== undefined) drafts.set(`app:${form.dataset.id}:${form.dataset.field}`, { text, rev: v().editRev })
})

// ------------------------------------------------------------------ actions

/** An application's actions, on application `appId` unless the control names its own. */
export function act(name: string, el: HTMLElement, appId_: number): void {
  if (itemAct(name, el)) return
  const appId = Number(el.dataset.id ?? appId_)
  const f = el instanceof HTMLFormElement ? fields(el) : {}
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
    case "mission-fire":
      return void command("fire", Number(el.dataset.mission))
        .then(() => notice("ok", el.dataset.kind === "email" ? "Sent off: it shows here once it lands." : "In flight: submit it by hand, then report here whether it went out."))
        .catch((e) => (e instanceof Refused && e.code === "fire" && e.data ? notice("error", commander(e.data as Row)) : failed(e)))
    case "mission-edit": {
      const id = Number(el.dataset.mission)
      return patch({ id: appId, edit: `m${id}`, editRev: Number(row("missions", id)?.rev ?? 0), editText: "" })
    }
    case "save-mission": {
      const blank = (x: unknown): Input => (str(x).trim() === "" ? null : str(x).trim())
      const set: Record<string, Input> = { target: blank(f.target), draft: (f.draft ?? "") === "" ? null : (f.draft as Input) }
      if ("subject" in f) Object.assign(set, { cc: blank(f.cc), subject: blank(f.subject), sender: str(f.sender) || "gmail" })
      return void put("missions", set, { id: Number(el.dataset.mission), expectRev: v().editRev }).then(() => patch({ edit: "" })).catch(failed)
    }
    case "mission-state": {
      // The select acts at once; a refused move puts it back, since the morph keeps a select the user changed.
      const select = el as HTMLSelectElement
      const was = Array.from(select.options).find((o) => o.defaultSelected)?.value ?? "draft"
      const back = (e: unknown) => ((select.value = was), failed(e))
      // The replica's judge refuses in this frame; the node's, later.
      try {
        return void put("missions", { state: select.value }, { id: Number(el.dataset.mission) }).catch(back)
      } catch (e) {
        return back(e)
      }
    }
    case "mission-add":
      return void resetAfter(el as HTMLFormElement, () => put("missions", { application_id: appId, kind: str(f.kind), target: str(f.target).trim() === "" ? null : str(f.target).trim() })).catch(failed)
    case "mission-landed":
      return void command("landed", Number(el.dataset.mission)).catch(failed)
    case "mission-failed":
      return void command("failed", Number(el.dataset.mission), { reason: str(f.reason).trim() }).catch(failed)
    case "keep-score":
      return void put("applications", { score_100: Number(el.dataset.score) }, { id: appId }).catch(failed)
    case "listing":
      return patch({ id: appId, listing: true, edit: "" })
    case "copy-link":
      return copy(el, link(appId))
    case "copy-md":
      return copy(el, markdown(appId))
    case "edit": {
      const d = application(appId) as Doc | null
      const field = el.dataset.field ?? ""
      if (!d) return
      // A kept edit resumes against the rev it was begun on, so a write since is still refused, not overwritten.
      const kept = el.dataset.kept !== undefined ? drafts.get<{ text: string; rev: number }>(`app:${appId}:${field}`) : null
      return patch({ id: appId, edit: field, editRev: kept?.rev ?? Number(d.application.rev ?? 0), editText: kept?.text ?? textOf(d.application[field]) })
    }
    case "drop-kept":
      drafts.drop(`app:${appId}:${el.dataset.field ?? ""}`)
      return patch({})
    case "cancel":
      drafts.drop(`app:${appId}:${v().edit}`)
      return patch({ edit: "" })
    case "save-prose": {
      const field = el.dataset.field ?? ""
      // The edit was made against the row's rev when the form opened; a write since then is refused, not overwritten.
      return void put("applications", { [field]: (f.value ?? "") === "" ? null : (f.value as Input) }, { id: appId, expectRev: v().editRev })
        .then(() => (drafts.drop(`app:${appId}:${field}`), patch({ edit: "" })))
        .catch(failed)
    }
    case "note":
      return void resetAfter(el as HTMLFormElement, () => command("note", appId, { stage: el.dataset.stage ?? "", body: f.body ?? "" })).catch(failed)
    case "override":
      return void command("heat_override", appId, { reason: f.reason ?? "" }).catch(failed)
    case "pick":
      return void (f.root ? command("pick_cv", appId, { cv_root_id: Number(f.root) }) : command("unpin_cv", appId)).catch(failed)
    case "unpin":
      return void command("unpin_cv", appId).catch(failed)
  }
}
