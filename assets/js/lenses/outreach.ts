// The outreach lens: everything said or done on any channel (the
// OutreachItem type, docs/mail/outreach_type.md), and the contacts it was
// said to. One kernel op, `outreach`, answers every list here: the hub (all
// items, searched, filtered by kind and date, grouped as the operator likes),
// the unfiled tray (what the filer could not place, with its candidates) and
// a contact's items. Each item is a collapsible row drawn by its kind; what
// someone else wrote is shown as text, never read as markup. Drafts are
// missions (the desk card); the items are the record, and a manual one
// (a call, a note, a message sent by hand) is a put of its cells.

import type { View } from "../app.ts"
import { DOMAIN, ENUMS, TABLES, type ColumnDef } from "../gen/schema.ts"
import { ask, command, failed, page, put, row, type Input, type Row } from "../kernel.ts"
import { EMPTY, fields, flag, href, html, str, type Html } from "../morph.ts"
import { go, item, itemNo, model, query, set, type OutreachView } from "../state.ts"
import { control } from "./world.ts"

const PAGE = 100
const v = (): OutreachView => model.outreach
const patch = (p: Partial<OutreachView>) => set({ outreach: { ...model.outreach, ...p } })
const writable = (): boolean => (model.writeMask & DOMAIN.mail) !== 0

const selected = (): number => itemNo()
/** The contact columns the lens edits, in declaration order. */
const CONTACT: ColumnDef[] = TABLES.contacts.cols.filter((c) => !c.implied && !c.readonly && !c.serverOnly)

/** The first `limit` contacts of the list (search, corporation), from the replica. */
function contacts(limit: number): { rows: Row[]; more: boolean } {
  const q = model.address.q.get("who") ?? ""
  const corp = Number(model.address.q.get("corporation") ?? 0)
  const where: Record<string, unknown> = {}
  if (q !== "") where.name = { prefix: q }
  if (corp > 0) where.corporation_id = corp
  return page({ table: "contacts", order: ["last_touch_on", "desc"], where }, limit)
}
/** A corporation by its name in the replica, or by number when it is not there. */
const corpLink = (id: unknown): Html => {
  const name = str(row("corporations", Number(id))?.name)
  return name === "" ? html`corporation #${str(id)}` : html`<a href="/world/corporations/${item(id, name)}" data-nav>${name}</a>`
}

// ------------------------------------------------------------------ items

/** One item as the `outreach` op answers it: the core flat, the variant's own fields under its kind. */
export type Item = {
  id: number; kind: string; direction: string | null; status: string | null; at: string | null; subject: string | null; body: string | null
  link: string | null; report: string | null; actor: string; filing: string; filed_by: string | null; seen: boolean
  corporation_id: number | null; application_id: number | null; contact_id: number | null; mission_id: number | null
  company: string | null; contact: string | null; application: string | null; confirmation: string | null
  email?: { from: string | null; to: string[]; cc: string[]; reply_to: string | null; message_id: string | null; in_reply_to: string | null; pipe: string | null; bounced_at: string | null; labels: string[] }
  careers_page?: { fields: unknown; reference: string | null }
  linkedin?: { handle: string | null }; x_dm?: { handle: string | null }; discord?: { handle: string | null }
  other?: { channel: string | null; handle: string | null }
  evidence: { evidence: unknown[]; candidates: { table: string; id: number; label: string; score: number }[] } | null
}
type Answer = { rows: Item[]; groups: { key: string; label: string; start: number; count: number }[]; total: number; next: number | null; counts: { unfiled: number; unseen: number } }

/** The hub's one read: the kernel's `outreach` op; null while the desk loads or when the account cannot read mail. */
export const outreachQuery = (params: Record<string, unknown>): Answer | null => ask<Answer>("outreach", params)

export const KIND: Record<string, string> = { email: "Email", careers_page: "Careers page", linkedin: "LinkedIn", x_dm: "X DM", discord: "Discord", other: "Other", note: "Note" }
const when = (at: string | null): string => (at ? new Date(at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "")
/** Who said it, by kind: the sender of a mail, the handle of a message, the channel of anything else. */
function who(i: Item): string {
  if (i.direction === "outbound") return "you"
  const h = i.email?.from ?? i.linkedin?.handle ?? (i.x_dm?.handle ? `@${i.x_dm.handle}` : null) ?? i.discord?.handle ?? i.other?.handle ?? null
  return h ?? i.contact ?? (i.kind === "note" ? "" : "them")
}
/** Someone else's text, as text: markup is shown, never read. */
const text = (t: string | null): Html => (t ? html`<pre class="untrusted">${t}</pre>` : EMPTY)
/** A link as its own address: the href is what is shown. */
const shown = (url: string | null): Html => (url ? html`<a href="${href(url)}" rel="noopener noreferrer" target="_blank">${url}</a>` : EMPTY)

/** The variant's own fields, under the body. */
function own(i: Item): Html {
  const e = i.email
  if (e) return html`<dl class="mail">
    <dt>From</dt><dd><code>${e.from ?? ""}</code></dd>${e.to.length ? html`<dt>To</dt><dd><code>${e.to.join(", ")}</code></dd>` : EMPTY}
    ${e.cc.length ? html`<dt>Cc</dt><dd><code>${e.cc.join(", ")}</code></dd>` : EMPTY}
    ${e.reply_to ? html`<dt>Reply-To</dt><dd><code>${e.reply_to}</code></dd>` : EMPTY}
    ${e.message_id ? html`<dt>Message-ID</dt><dd><code>${e.message_id}</code></dd>` : EMPTY}
    ${e.pipe ? html`<dt>Came by</dt><dd>${e.pipe}</dd>` : EMPTY}</dl>`
  if (i.careers_page) return html`${i.careers_page.reference ? html`<p>Reference <code>${i.careers_page.reference}</code></p>` : EMPTY}
    ${i.careers_page.fields ? text(JSON.stringify(i.careers_page.fields, null, 2)) : EMPTY}`
  if (i.other) return html`<p class="muted">${i.other.channel ?? ""}${i.other.handle ? ` · ${i.other.handle}` : ""}</p>`
  return EMPTY
}

/** Where an unfiled item could go: the filer's candidates, each one click away; or out of the tray. */
const REF: Record<string, string> = { applications: "application_id", corporations: "corporation_id", contacts: "contact_id", missions: "mission_id" }
function tray(i: Item): Html {
  if (!writable() || i.filing !== "unfiled") return EMPTY
  const cands = (i.evidence?.candidates ?? []).filter((c) => REF[c.table])
  return html`<div class="actions">${cands.map((c) => html`<button type="button" data-act="file" data-id="${i.id}" data-ref="${REF[c.table]}" data-to="${c.id}">File to ${c.label}</button>
    <span class="muted">${c.score}</span>`)}
    <button type="button" class="ghost" data-act="ignore" data-id="${i.id}">Not about the search</button></div>`
}

/** A mail the node found in Gmail's Spam (its \\Spam label, as Gmail reports it): hireme never moves mail, so the operator rescues it there. */
export const inSpam = (i: Item): boolean => (i.email?.labels ?? []).some((l) => /^\\(spam|junk)$/i.test(l))
export const SPAM = html`<span class="tag bad" title="Gmail filed this as spam. hireme never moves mail: open Spam in Gmail and mark it Not spam.">in Gmail Spam: rescue it there</span>`

/** One item, collapsed to a line; opened, its whole text and its own fields. Opening an unseen reply marks it seen. */
export function itemRow(i: Item): Html {
  const unseen = i.direction === "inbound" && !i.seen
  return html`<details class="item ${i.direction ?? "note"}${unseen ? " unseen" : ""}" data-key="o${i.id}">
    <summary data-act="seen" data-click data-id="${i.id}"${flag("data-unseen", unseen)}>
      <span class="tag">${KIND[i.kind] ?? i.kind}</span>
      <span class="who">${i.direction === "inbound" ? "←" : i.direction === "outbound" ? "→" : ""} ${who(i)}</span>
      <span class="subject">${i.subject ?? ""}</span>
      ${i.company || i.application ? html`<span class="muted">${i.application ?? i.company}</span>` : EMPTY}
      ${inSpam(i) ? SPAM : EMPTY}
      ${i.status === "bounced" ? html`<span class="tag warn">bounced</span>` : EMPTY}
      ${i.confirmation === "provisional" ? html`<span class="tag warn">provisional</span>` : EMPTY}
      ${i.filing === "unfiled" ? html`<span class="tag">unfiled</span>` : EMPTY}
      <time class="muted">${when(i.at)}</time></summary>
    ${own(i)}${text(i.body)}
    ${i.report ? html`<p class="muted">Report</p>${text(i.report)}` : EMPTY}
    ${i.link ? html`<p>${shown(i.link)}</p>` : EMPTY}
    ${i.application_id ? html`<p class="muted"><a href="/desk/${str(row("applications", i.application_id)?.no ?? "")}" data-nav>${i.application ?? "the application"}</a></p>` : EMPTY}
    ${tray(i)}
  </details>`
}

/** An answer's rows under the page's group headings. */
export function itemList(a: Answer): Html {
  const heads = new Map(a.groups.map((g) => [g.start, g]))
  return html`<div class="items">${a.rows.map((i, n) => {
    const g = heads.get(n)
    return html`${g ? html`<h3 class="group-head" data-key="g${g.key}">${g.label} <span class="muted">${g.count}</span></h3>` : EMPTY}${itemRow(i)}`
  })}</div>`
}

/** An item row's own actions, wherever it is drawn (the hub, the desk card); false for any other. */
export function itemAct(name: string, el: HTMLElement): boolean {
  switch (name) {
    case "seen":
      // Opening a reply reads it: the marker clears (a put, as the type says).
      if (el.dataset.unseen !== undefined && writable()) void put("outreach", { seen: true }, { id: Number(el.dataset.id) }).catch(failed)
      return true
    case "file":
      return void command("file", Number(el.dataset.id), { [el.dataset.ref ?? ""]: Number(el.dataset.to) }).catch(failed), true
    case "ignore":
      return void command("ignore", Number(el.dataset.id)).catch(failed), true
  }
  return false
}

const GROUPS = ["", "kind", "day", "month", "company", "application", "contact", "thread", "direction", "status", "filing"]

/** The record form: something said or done that hireme did not see (a call, a message sent by hand, a note). */
function record(refs: Record<string, number>): Html {
  if (!writable()) return EMPTY
  if (v().edit !== "record") return html`<button type="button" data-act="new-record">Record something</button>`
  return html`<form class="stack card" data-submit="save-record" data-act="save-record" data-key="record">
    <h3>Record what was said or done</h3>
    <label>Kind <select name="kind">${(ENUMS.outreach_kind ?? []).map((k) => html`<option value="${k}"${flag("selected", k === "note")}>${KIND[k] ?? k}</option>`)}</select></label>
    <label>Direction <select name="direction"><option value="">none (a note)</option><option value="outbound">I sent it</option><option value="inbound">They sent it</option></select></label>
    <label>When <input type="datetime-local" name="at"></label>
    <label>Subject or title <input name="subject" maxlength="300"></label>
    <label>What was said <textarea name="body" rows="6"></textarea></label>
    <label>Handle or address <input name="handle" placeholder="their LinkedIn name, @x, discord user"></label>
    <label>Channel (for other) <input name="channel" placeholder="phone, slack, meetup"></label>
    <label>Link <input name="link" type="url" placeholder="https://"></label>
    ${Object.entries(refs).map(([k, x]) => html`<input type="hidden" name="${k}" value="${x}">`)}
    <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span>
  </form>`
}

/** The hub's filters, all in the address: search, kind, group, a date range. */
function hub(where: Record<string, unknown>, tray_: boolean): Html {
  const q = model.address.q
  const w: Record<string, unknown> = { ...where }
  const kind = q.get("kind") ?? ""
  if (kind !== "") w.kind = kind
  const from = q.get("from") ?? "", to = q.get("to") ?? ""
  if (from !== "" || to !== "") w.at = { ...(from ? { ge: `${from}T00:00:00Z` } : {}), ...(to ? { le: `${to}T23:59:59Z` } : {}) }
  if (tray_) w.filing = "unfiled"
  const group = q.get("group") ?? ""
  const a = outreachQuery({ where: w, search: q.get("q") ?? "", sort: ["at", "desc"], group, after: 0, limit: Math.min(500, v().items) })
  if (!a) return html`<p class="empty">Outreach is loading, or this account cannot read mail.</p>`
  return html`<div class="toolbar" data-key="hub-bar">
      <input type="search" class="search" placeholder="Search what was said…" value="${q.get("q") ?? ""}" data-act="find" data-on="input" data-bound aria-label="Search outreach">
      <select data-act="kind" data-on="change" data-bound aria-label="Kind"><option value="">every kind</option>${(ENUMS.outreach_kind ?? []).map((k) => html`<option value="${k}"${flag("selected", k === kind)}>${KIND[k] ?? k}</option>`)}</select>
      <select data-act="group" data-on="change" data-bound aria-label="Group by">${GROUPS.map((g) => html`<option value="${g}"${flag("selected", g === group)}>${g === "" ? "no grouping" : `by ${g}`}</option>`)}</select>
      <label>from <input type="date" data-act="from" data-on="change" data-bound value="${from}"></label>
      <label>to <input type="date" data-act="to" data-on="change" data-bound value="${to}"></label>
    </div>
    <p class="muted" data-key="hub-count">${a.total} item${a.total === 1 ? "" : "s"}${a.counts.unseen ? html` · <b>${a.counts.unseen} unread</b>` : EMPTY}
      · <a href="/outreach/unfiled" data-nav>unfiled tray (${a.counts.unfiled})</a>${tray_ ? html` · <a href="/outreach" data-nav>everything</a>` : EMPTY}</p>
    ${tray_ ? html`<p class="hint">What the filer could not place with certainty. File each to where it belongs, or take it out of the tray.</p>` : EMPTY}
    ${a.rows.length === 0 ? html`<p class="empty">${tray_ ? "The tray is empty." : "Nothing recorded yet."}</p>` : itemList(a)}
    ${a.next !== null ? html`<button type="button" data-act="more-items">More</button>` : EMPTY}`
}

// ------------------------------------------------------------------ view

const field = (c: ColumnDef, value: unknown): Html => html`<label>${c.name.replace(/_/g, " ")}${control(c, c.name, str(value), EMPTY, 4)}</label>`

function contactCard(c: Row): Html {
  if (v().edit === "contact")
    return html`<form class="stack card" data-submit="save-contact" data-act="save-contact" data-key="contact-edit">
      ${CONTACT.map((col) => field(col, c[col.name]))}
      <span class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>`
  return html`<section class="card" data-key="contact">
    <h2>${str(c.name)} ${writable() ? html`<button type="button" class="ghost" data-act="edit-contact">Edit</button>` : EMPTY}</h2>
    <p>${str(c.title)}${c.relation ? html` · <span class="tag">${str(c.relation)}</span>` : EMPTY}</p>
    <p class="row">${c.email ? html`<a href="${href(`mailto:${str(c.email)}`)}">${str(c.email)}</a>` : EMPTY}
      ${c.linkedin_url ? html`<a href="${href(str(c.linkedin_url))}" rel="noopener noreferrer" target="_blank">LinkedIn</a>` : EMPTY}
      ${c.x_handle ? html`<span>@${str(c.x_handle).replace(/^@/, "")}</span>` : EMPTY}</p>
    ${c.corporation_id ? html`<p class="muted">${corpLink(c.corporation_id)} ·
      <a href="/outreach?corporation=${str(c.corporation_id)}" data-nav>everyone there</a></p>` : EMPTY}
    ${c.notes ? html`<p class="notes">${str(c.notes)}</p>` : EMPTY}
    <p class="muted">${c.last_touch_on ? `last touch ${str(c.last_touch_on)}` : "no touch yet"}</p>
  </section>`
}

function view(): Html {
  const id = selected()
  const c = row("contacts", id)
  const corp = model.address.q.get("corporation")
  const list = contacts(v().limit)
  return html`<div class="outreach split">
    <aside class="list" data-key="list">
      <div class="toolbar"><input type="search" class="search" placeholder="Name starts with…" value="${model.address.q.get("who") ?? ""}" data-act="search" data-on="input" data-bound aria-label="Search contacts">
        ${writable() ? html`<button type="button" data-act="new-contact">New</button>` : EMPTY}</div>
      ${corp ? html`<p class="muted">At ${corpLink(corp)} <button type="button" class="ghost" data-act="all">show all</button></p>` : EMPTY}
      ${v().edit === "new" ? html`<form class="stack card" data-submit="create-contact" data-act="create-contact" data-key="new">
          ${CONTACT.filter((x) => x.required || x.name === "email" || x.name === "title" || x.name === "corporation_id").map((x) => field(x, x.name === "corporation_id" ? corp : null))}
          <span class="row"><button class="primary">Add</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>` : EMPTY}
      <ul class="rows pick" role="listbox" aria-label="Contacts">${list.rows.map((x) => html`<li data-key="c${str(x.id)}" role="option" aria-selected="${String(Number(x.id) === id)}">
        <a href="/outreach/${item(x.id, x.name)}${corp ? `?corporation=${encodeURIComponent(corp)}` : ""}" data-nav class="${Number(x.id) === id ? "on" : ""}">
          <b>${str(x.name)}</b> <span class="muted">${str(x.title)}</span></a></li>`)}</ul>
      ${list.rows.length === 0 ? html`<p class="empty">No contacts yet.</p>` : EMPTY}
      ${list.more ? html`<button type="button" data-act="more">More</button>` : EMPTY}
    </aside>
    <section class="detail" data-key="detail">
      ${c ? html`${contactCard(c)}${record({ contact_id: id })}${hub({ contact_id: id }, false)}`
        : id > 0 && model.rows > 0 ? html`<p class="empty">No contact #${id}: it was deleted, or the link is from another account.</p>`
        : html`${record({})}${hub({}, model.address.sub === "unfiled")}`}
    </section>
  </div>`
}

// ------------------------------------------------------------------ actions

/** The form's fields, an empty one as null (the cell clears). */
const form = (el: HTMLElement): Record<string, Input> => Object.fromEntries(Object.entries(fields(el as HTMLFormElement)).map(([k, x]) => [k, x === "" ? null : x]))

function act(name: string, el: HTMLElement): void {
  const id = selected()
  switch (name) {
    case "search":
      // The replica answers in the keystroke's frame: no wait before asking.
      return query("who", (el as HTMLInputElement).value)
    case "all":
      return query("corporation", "")
    case "more":
      return patch({ limit: v().limit + PAGE })
    case "cancel":
      return patch({ edit: "" })
    case "new-contact":
      return patch({ edit: "new" })
    case "edit-contact":
      return patch({ edit: "contact" })
    case "create-contact": {
      const f = form(el)
      const email = f.email
      // Predicted: the contact is listed now and the form closes (a local refusal threw here and kept it
      // open); the sequencer's refusal rolls it back and says why. Opened unless a contact is open by then.
      void put("contacts", f, email ? { key: { email }, createOnly: true } : {})
        .then((r) => {
          if (model.address.lens === "outreach" && selected() === 0) go({ item: item(r.id, f.name) }, true)
        })
        .catch(failed)
      return patch({ edit: "" })
    }
    case "save-contact": {
      const c = row("contacts", id)
      if (!c) return
      const changed: Record<string, Input> = {}
      for (const [k, x] of Object.entries(form(el))) if (str(c[k]) !== str(x)) changed[k] = x
      if (Object.keys(changed).length === 0) return patch({ edit: "" })
      void put("contacts", changed, { id }).catch(failed)
      return patch({ edit: "" })
    }
    case "save-record": {
      const f = form(el)
      const cells: Record<string, Input> = {}
      for (const k of ["kind", "direction", "subject", "body", "handle", "channel", "link"]) if (f[k] !== null && f[k] !== undefined) cells[k] = f[k]!
      if (f.at) cells.at = new Date(String(f.at)).toISOString()
      for (const k of ["contact_id", "application_id"]) if (f[k]) cells[k] = Number(f[k])
      // An email has no handle: the address is its sender, or its recipient when it went out.
      if (cells.kind === "email" && cells.handle) {
        cells[cells.direction === "outbound" ? "to_addr" : "from_addr"] = cells.handle
        delete cells.handle
      }
      void put("outreach", cells).catch(failed)
      return patch({ edit: "" })
    }
    case "new-record":
      return patch({ edit: "record" })
    case "find":
      return query("q", (el as HTMLInputElement).value)
    case "kind":
    case "group":
    case "from":
    case "to":
      return query(name, (el as HTMLInputElement | HTMLSelectElement).value)
    case "more-items":
      return patch({ items: v().items + PAGE })
    default:
      itemAct(name, el)
  }
}

let shownContact = -1

const outreach: View = {
  title: "Outreach",
  view,
  enter() {
    // Another contact: its open bodies and editors close.
    if (selected() !== shownContact) {
      shownContact = selected()
      patch({ edit: "", items: PAGE })
    }
  },
  after() {
    // The item's slug follows the contact's name: an old link is rewritten to the current one.
    const c = row("contacts", selected())
    if (c && item(c.id, c.name) !== model.address.item) go({ item: item(c.id, c.name) }, true)
  },
  act,
}

export default outreach
