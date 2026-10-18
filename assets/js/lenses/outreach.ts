// The outreach lens: contacts and their message threads, keyed to
// corporations and applications. Both tables are server-side (the mail
// domain), so everything is read over `find`/`get`/`text` and written with
// `put`. A message body is deferred and arrives only when opened, marked as
// someone else's text. The lens writes drafts; nothing here sends mail.

import type { View } from "../app.ts"
import { DOMAIN, TABLES, type ColumnDef } from "../gen/schema.ts"
import { Refused, put, rpc, values, type Input } from "../kernel.ts"
import { EMPTY, flag, href, html, type Html } from "../morph.ts"
import { model, notice, query, set, type OutreachView } from "../state.ts"

type Row = Record<string, unknown>

const PAGE = 100
const v = (): OutreachView => model.outreach
const patch = (p: Partial<OutreachView>) => set({ outreach: { ...model.outreach, ...p } })
const str = (x: unknown): string => (x === null || x === undefined ? "" : String(x))
const writable = (): boolean => (model.writeMask & DOMAIN.mail) !== 0

const selected = (): number => Number(model.address.q.get("contact") ?? 0)
const listKey = (): string => `${model.address.q.get("q") ?? ""}|${model.address.q.get("corporation") ?? ""}`

/** The contact columns the lens edits, in declaration order. */
const CONTACT: ColumnDef[] = TABLES.contacts.cols.filter((c) => !c.implied && !c.readonly && !c.serverOnly)

async function fetchContacts(more: boolean): Promise<void> {
  const key = listKey()
  const q = model.address.q.get("q") ?? ""
  const corp = Number(model.address.q.get("corporation") ?? 0)
  const where: Record<string, unknown> = {}
  if (q !== "") where.name = { prefix: q }
  if (corp > 0) where.corporation_id = corp
  const params: Record<string, unknown> = { table: "contacts", order: ["last_touch_on", "desc"], limit: PAGE, where }
  if (more && v().next !== null) params.after = v().next
  patch({ loading: true, ...(more ? {} : { key, contacts: [], next: null }) })
  try {
    const r = await rpc<{ rows: Row[]; next: unknown }>("find", params)
    if (listKey() !== key) return
    patch({ contacts: more ? [...v().contacts, ...r.rows] : r.rows, next: r.next ?? null, loading: false, error: "" })
  } catch (e) {
    patch({ loading: false, error: e instanceof Error ? e.message : String(e) })
  }
}

async function fetchMessages(): Promise<void> {
  const id = selected()
  if (id === 0) return patch({ messages: [] })
  try {
    const r = await rpc<{ rows: Row[] }>("find", { table: "messages", where: { contact_id: id }, order: ["sent_at", "asc"], limit: 500 })
    if (selected() === id) patch({ messages: r.rows })
  } catch (e) {
    patch({ error: e instanceof Error ? e.message : String(e) })
  }
}

function failed(e: unknown): void {
  notice("error", e instanceof Refused ? `${e.code}: ${e.message}` : e instanceof Error ? e.message : String(e))
}

// ------------------------------------------------------------------ view

function field(c: ColumnDef, value: unknown): Html {
  const x = str(value)
  const label = c.name.replace(/_/g, " ")
  if (c.type === "enum")
    return html`<label>${label}<select name="${c.name}"><option value=""></option>${values(c.enum).map((e) => html`<option${flag("selected", e === x)}>${e}</option>`)}</select></label>`
  if (c.type === "text") return html`<label>${label}<textarea name="${c.name}" rows="4">${x}</textarea></label>`
  if (c.type === "day") return html`<label>${label}<input type="date" name="${c.name}" value="${x}"></label>`
  return html`<label>${label}<input name="${c.name}" value="${x}"${flag("required", c.required)}${c.name === "email" ? html` type="email"` : EMPTY}></label>`
}

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
    ${c.corporation_id ? html`<p class="muted">corporation #${str(c.corporation_id)} ·
      <a href="/outreach?corporation=${str(c.corporation_id)}" data-nav>everyone there</a></p>` : EMPTY}
    ${c.notes ? html`<p class="notes">${str(c.notes)}</p>` : EMPTY}
    <p class="muted">${c.last_touch_on ? `last touch ${str(c.last_touch_on)}` : "no touch yet"}</p>
  </section>`
}

function threads(): Html {
  const by = new Map<string, Row[]>()
  for (const m of v().messages) {
    const k = str(m.thread_key) || `m${str(m.id)}`
    by.set(k, [...(by.get(k) ?? []), m])
  }
  return html`${[...by.entries()].map(([k, ms]) => html`<section class="card thread" data-key="t${k}">
    <h3>${str(ms[0]?.subject) || "(no subject)"} <span class="muted">${ms.length} message${ms.length === 1 ? "" : "s"}</span></h3>
    <ol class="messages">${ms.map((m) => {
      const id = Number(m.id)
      const body = v().bodies.get(id)
      return html`<li data-key="m${id}" class="msg ${str(m.direction)}">
        <div class="meta"><b>${m.direction === "inbound" ? str(m.from_addr) || "them" : "you"}</b>
          <span class="tag">${str(m.status)}</span> <span class="muted">${str(m.sent_at).slice(0, 16).replace("T", " ")} · ${str(m.channel)}</span>
          ${m.application_id ? html`<span class="muted">application #${str(m.application_id)}</span>` : EMPTY}</div>
        ${body === undefined
          ? m.body ? html`<button type="button" class="ghost" data-act="open-body" data-id="${id}">Read</button>` : html`<p class="muted">no body</p>`
          : html`<pre class="untrusted">${body}</pre>`}
      </li>`
    })}</ol></section>`)}`
}

function draft(c: Row): Html {
  if (!writable()) return EMPTY
  if (v().edit !== "draft") return html`<button type="button" data-act="new-draft">Draft a message</button>`
  return html`<form class="stack card" data-submit="save-draft" data-act="save-draft" data-key="draft">
    <h3>Draft to ${str(c.name)}</h3>
    <label>Channel <select name="channel">${values(TABLES.messages.cols.find((x) => x.name === "channel")?.enum ?? null).map((e) => html`<option${flag("selected", e === "email")}>${e}</option>`)}</select></label>
    <label>Subject <input name="subject" maxlength="300"></label>
    <label>Body <textarea name="body" rows="10" required></textarea></label>
    <p class="hint">Saved as a draft. Nothing is sent from here.</p>
    <span class="row"><button class="primary">Save draft</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span>
  </form>`
}

function view(): Html {
  const id = selected()
  const c = v().contacts.find((x) => Number(x.id) === id)
  const corp = model.address.q.get("corporation")
  return html`<div class="outreach split">
    <aside class="list" data-key="list">
      <div class="toolbar"><input type="search" class="search" placeholder="Name starts with…" value="${model.address.q.get("q") ?? ""}" data-act="search" data-on="input" aria-label="Search contacts">
        ${writable() ? html`<button type="button" data-act="new-contact">New</button>` : EMPTY}</div>
      ${corp ? html`<p class="muted">At corporation #${corp} <button type="button" class="ghost" data-act="all">show all</button></p>` : EMPTY}
      ${v().edit === "new" ? html`<form class="stack card" data-submit="create-contact" data-act="create-contact" data-key="new">
          ${CONTACT.filter((x) => x.required || x.name === "email" || x.name === "title" || x.name === "corporation_id").map((x) => field(x, x.name === "corporation_id" ? corp : null))}
          <span class="row"><button class="primary">Add</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>` : EMPTY}
      <ul class="rows pick" role="listbox" aria-label="Contacts">${v().contacts.map((x) => html`<li data-key="c${str(x.id)}" role="option" aria-selected="${Number(x.id) === id}">
        <a href="/outreach?${new URLSearchParams({ ...(corp ? { corporation: corp } : {}), contact: str(x.id) }).toString()}" data-nav class="${Number(x.id) === id ? "on" : ""}">
          <b>${str(x.name)}</b> <span class="muted">${str(x.title)}</span></a></li>`)}</ul>
      ${v().loading ? html`<p class="empty">Loading…</p>` : v().contacts.length === 0 ? html`<p class="empty">No contacts yet.</p>` : EMPTY}
      ${v().next !== null ? html`<button type="button" data-act="more">More</button>` : EMPTY}
    </aside>
    <section class="detail" data-key="detail">
      ${v().error !== "" ? html`<p class="error" role="alert">${v().error}</p>` : EMPTY}
      ${c ? html`${contactCard(c)}${draft(c)}${threads()}` : html`<p class="empty">Pick a contact.</p>`}
    </section>
  </div>`
}

// ------------------------------------------------------------------ actions

let typing = 0

function form(el: HTMLElement): Record<string, Input> {
  const out: Record<string, Input> = {}
  for (const [k, x] of new FormData(el as HTMLFormElement)) out[k] = String(x) === "" ? null : String(x)
  return out
}

function act(name: string, el: HTMLElement): void {
  const id = selected()
  switch (name) {
    case "search": {
      const value = (el as HTMLInputElement).value
      clearTimeout(typing)
      typing = window.setTimeout(() => query("q", value), 200)
      return
    }
    case "all":
      return query("corporation", "")
    case "more":
      return void fetchContacts(true)
    case "cancel":
      return patch({ edit: "" })
    case "new-contact":
      return patch({ edit: "new" })
    case "edit-contact":
      return patch({ edit: "contact" })
    case "new-draft":
      return patch({ edit: "draft" })
    case "create-contact": {
      const f = form(el)
      const email = f.email
      return void put("contacts", f, email ? { key: { email }, createOnly: true } : {})
        .then((r) => {
          patch({ edit: "" })
          query("contact", String(r.id))
          return fetchContacts(false)
        })
        .catch(failed)
    }
    case "save-contact": {
      const c = v().contacts.find((x) => Number(x.id) === id)
      if (!c) return
      const f = form(el)
      const changed: Record<string, Input> = {}
      for (const [k, x] of Object.entries(f)) if (str(c[k]) !== str(x)) changed[k] = x
      if (Object.keys(changed).length === 0) return patch({ edit: "" })
      return void put("contacts", changed, { id })
        .then(async () => {
          const r = await rpc<{ row: Row }>("get", { table: "contacts", id })
          patch({ edit: "", contacts: v().contacts.map((x) => (Number(x.id) === id ? r.row : x)) })
        })
        .catch(failed)
    }
    case "save-draft": {
      const c = v().contacts.find((x) => Number(x.id) === id)
      const f = form(el)
      return void put("messages", {
        channel: f.channel ?? "email",
        direction: "outbound",
        status: "draft",
        subject: f.subject ?? null,
        body: f.body ?? null,
        to_addr: c ? (str(c.email) || null) : null,
        contact_id: id,
        corporation_id: c && c.corporation_id ? Number(c.corporation_id) : null,
      })
        .then(() => {
          patch({ edit: "" })
          return fetchMessages()
        })
        .catch(failed)
    }
    case "open-body": {
      const mid = Number(el.dataset.id)
      return void rpc<{ text: string }>("text", { table: "messages", id: mid, column: "body", length: 262_144 })
        .then((r) => patch({ bodies: new Map(v().bodies).set(mid, r.text) }))
        .catch(failed)
    }
  }
}

let shownContact = -1

const outreach: View = {
  title: "Outreach",
  view,
  enter() {
    if (v().key !== listKey()) void fetchContacts(false)
    if (selected() !== shownContact) {
      shownContact = selected()
      patch({ messages: [], bodies: new Map(), edit: "" })
      void fetchMessages()
    }
  },
  act,
}

export default outreach
