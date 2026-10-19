// The outreach lens: contacts and their message threads, keyed to
// corporations and applications. Both tables are in the kernel's replica,
// read in the frame they are drawn (`find`, `get`, `text` answered locally)
// and written with `put`, predicted at once and confirmed or rolled back by
// the sequencer. A message body opens on demand, marked as someone else's
// text. The lens writes drafts; nothing here sends mail.

import type { View } from "../app.ts"
import { DOMAIN, TABLES, type ColumnDef } from "../gen/schema.ts"
import { failed, page, put, query as read, row, values, type Input, type Row } from "../kernel.ts"
import { EMPTY, fields, flag, href, html, str, type Html } from "../morph.ts"
import { model, query, set, type OutreachView } from "../state.ts"

const PAGE = 100
const v = (): OutreachView => model.outreach
const patch = (p: Partial<OutreachView>) => set({ outreach: { ...model.outreach, ...p } })
const writable = (): boolean => (model.writeMask & DOMAIN.mail) !== 0

const selected = (): number => Number(model.address.q.get("contact") ?? 0)
/** The contact columns the lens edits, in declaration order. */
const CONTACT: ColumnDef[] = TABLES.contacts.cols.filter((c) => !c.implied && !c.readonly && !c.serverOnly)

/** The first `limit` contacts of the list (search, corporation), from the replica. */
function contacts(limit: number): { rows: Row[]; more: boolean } {
  const q = model.address.q.get("q") ?? ""
  const corp = Number(model.address.q.get("corporation") ?? 0)
  const where: Record<string, unknown> = {}
  if (q !== "") where.name = { prefix: q }
  if (corp > 0) where.corporation_id = corp
  return page({ table: "contacts", order: ["last_touch_on", "desc"], where }, limit)
}

// A body comes as its byte count here: its opening is a text chunk, its whole a get, each read when drawn.
const messages = (id: number): Row[] => read<{ rows: Row[] }>("find", { table: "messages", where: { contact_id: id }, order: ["sent_at", "asc"], limit: 500, sizes: ["body"] }).rows
/** A message's first lines (a 240-byte chunk), so a thread reads without a click; `more` when the body goes on. */
function opening(id: number): { text: string; more: boolean } {
  const r = read<{ text: string | null; next: number | null }>("text", { table: "messages", id, column: "body", length: 240 })
  const lines = (r.text ?? "").split("\n").filter((l) => l.trim() !== "")
  return { text: lines.slice(0, 3).join("\n"), more: r.next !== null || lines.length > 3 }
}
/** A corporation by its name in the replica, or by number when it is not there. */
const corpLink = (id: unknown): Html => {
  const name = str(row("corporations", Number(id))?.name)
  return name === "" ? html`corporation #${str(id)}` : html`<a href="/world/corporations?q=${encodeURIComponent(name)}" data-nav>${name}</a>`
}

// ------------------------------------------------------------------ view

function field(c: ColumnDef, value: unknown): Html {
  const x = str(value)
  const label = c.name.replace(/_/g, " ")
  if (c.type === "enum")
    return html`<label>${label}<select name="${c.name}"><option value=""></option>${values(c.enum).map((e) => html`<option${flag("selected", e === x)}>${e}</option>`)}</select></label>`
  // HTML drops a textarea's first newline, so a text that begins with one gets a second.
  if (c.type === "text") return html`<label>${label}<textarea name="${c.name}" rows="4">${x.startsWith("\n") ? `\n${x}` : x}</textarea></label>`
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
    ${c.corporation_id ? html`<p class="muted">${corpLink(c.corporation_id)} ·
      <a href="/outreach?corporation=${str(c.corporation_id)}" data-nav>everyone there</a></p>` : EMPTY}
    ${c.notes ? html`<p class="notes">${str(c.notes)}</p>` : EMPTY}
    <p class="muted">${c.last_touch_on ? `last touch ${str(c.last_touch_on)}` : "no touch yet"}</p>
  </section>`
}

function threads(id: number): Html {
  const by = new Map<string, Row[]>()
  for (const m of messages(id)) {
    const k = str(m.thread_key) || `m${str(m.id)}`
    by.set(k, [...(by.get(k) ?? []), m])
  }
  return html`${[...by.entries()].map(([k, ms]) => html`<section class="card thread" data-key="t${k}">
    <h3>${str(ms[0]?.subject) || "(no subject)"} <span class="muted">${ms.length} message${ms.length === 1 ? "" : "s"}</span></h3>
    <ol class="messages">${ms.map((m) => {
      const id = Number(m.id)
      const body = v().open.includes(id) ? str(read<{ row: Row }>("get", { table: "messages", id }).row.body) : undefined
      const first = body === undefined && m.body ? opening(id) : null
      return html`<li data-key="m${id}" class="msg ${str(m.direction)}">
        <div class="meta"><b>${m.direction === "inbound" ? str(m.from_addr) || "them" : "you"}</b>
          ${m.status === "sent" ? EMPTY : html`<span class="tag">${str(m.status)}</span> `}<span class="muted">${str(m.sent_at).slice(0, 16).replace("T", " ")} · ${str(m.channel)}</span>
          ${m.application_id ? html`<span class="muted">application #${str(m.application_id)}</span>` : EMPTY}</div>
        ${body === undefined
          ? first ? html`<p class="opening untrusted">${first.text}</p>${first.more ? html`<button type="button" class="ghost" data-act="open-body" data-id="${id}">Show all</button>` : EMPTY}` : html`<p class="muted">no body</p>`
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
  const c = row("contacts", id)
  const corp = model.address.q.get("corporation")
  const list = contacts(v().limit)
  return html`<div class="outreach split">
    <aside class="list" data-key="list">
      <div class="toolbar"><input type="search" class="search" placeholder="Name starts with…" value="${model.address.q.get("q") ?? ""}" data-act="search" data-on="input" data-bound aria-label="Search contacts">
        ${writable() ? html`<button type="button" data-act="new-contact">New</button>` : EMPTY}</div>
      ${corp ? html`<p class="muted">At ${corpLink(corp)} <button type="button" class="ghost" data-act="all">show all</button></p>` : EMPTY}
      ${v().edit === "new" ? html`<form class="stack card" data-submit="create-contact" data-act="create-contact" data-key="new">
          ${CONTACT.filter((x) => x.required || x.name === "email" || x.name === "title" || x.name === "corporation_id").map((x) => field(x, x.name === "corporation_id" ? corp : null))}
          <span class="row"><button class="primary">Add</button><button type="button" class="ghost" data-act="cancel">Cancel</button></span></form>` : EMPTY}
      <ul class="rows pick" role="listbox" aria-label="Contacts">${list.rows.map((x) => html`<li data-key="c${str(x.id)}" role="option" aria-selected="${String(Number(x.id) === id)}">
        <a href="/outreach?${new URLSearchParams({ ...(corp ? { corporation: corp } : {}), contact: str(x.id) }).toString()}" data-nav class="${Number(x.id) === id ? "on" : ""}">
          <b>${str(x.name)}</b> <span class="muted">${str(x.title)}</span></a></li>`)}</ul>
      ${list.rows.length === 0 ? html`<p class="empty">No contacts yet.</p>` : EMPTY}
      ${list.more ? html`<button type="button" data-act="more">More</button>` : EMPTY}
    </aside>
    <section class="detail" data-key="detail">
      ${c ? html`${contactCard(c)}${draft(c)}${threads(id)}` : html`<p class="empty">Pick a contact.</p>`}
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
      return query("q", (el as HTMLInputElement).value)
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
    case "new-draft":
      return patch({ edit: "draft" })
    case "create-contact": {
      const f = form(el)
      const email = f.email
      // Predicted: the contact is listed now and the form closes (a local refusal threw here and kept it
      // open); the sequencer's refusal rolls it back and says why. Opened unless a contact is open by then.
      void put("contacts", f, email ? { key: { email }, createOnly: true } : {})
        .then((r) => {
          if (model.address.lens === "outreach" && selected() === 0) query("contact", String(r.id))
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
    case "save-draft": {
      const c = row("contacts", id)
      const f = form(el)
      void put("messages", {
        channel: f.channel ?? "email",
        direction: "outbound",
        status: "draft",
        subject: f.subject ?? null,
        body: f.body ?? null,
        to_addr: c ? (str(c.email) || null) : null,
        contact_id: id,
        corporation_id: c && c.corporation_id ? Number(c.corporation_id) : null,
      }).catch(failed)
      return patch({ edit: "" })
    }
    case "open-body": {
      return patch({ open: [...v().open, Number(el.dataset.id)] })
    }
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
      patch({ open: [], edit: "" })
    }
  },
  act,
}

export default outreach
