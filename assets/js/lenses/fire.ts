// Fire: the operator's console for fire keys (docs/mail/passthrough.md, docs/mail/kernel.md).
//
//   /fire              the live keys (scope, burned, remaining, the countdown, revoke) and the
//                      agents' open requests
//   /fire/<request>    an agent's request reviewed: every mission's draft and target in full, the
//                      ones that cannot fire and why; the operator narrows it, then creates the key
//   /fire?missions=…   the same review for missions the operator names (a card's Authorize)
//
// A link only opens a review: a key exists only once the operator creates it here, under a step-up,
// echoing the review's digest so the key fires exactly what was read. Nothing on this page sends.

import type { View } from "../app.ts"
import { ask, command, failed, page, Refused, row, type Row } from "../kernel.ts"
import { EMPTY, flag, html, str, type Html } from "../morph.ts"
import { go, model, notice, schedule } from "../state.ts"
import { askStepUp, stepAct, stepUpPanel } from "./account.ts"

/** A live key as `live_keys` answers it. */
type Key = { id: number; scope: string; usable_by: number | null; request_id: number | null; burned: string; remaining: string; in_flight: string; changed: string; first_used_at: string | null; expires_at: string; expires_in_s: number }
/** One mission as `fire_review` answers it: its draft and target in full, and whether it can fire. */
type Draft = { to?: string; cc?: string | null; subject?: string; body?: string; in_reply_to?: string | null; markdown?: string }
type Mission = { id: number; kind: string; target: string; state: string; application: { id: number; no: number; company: string; role: string; stage: string }; draft: Draft | null; cv_version_id: number | null; hash: string; eligible: boolean; why: string | null }
type Review = { request: { id: number; missions: string; reason: string; requested_by: number | null; status: string } | null; missions: Mission[]; scope: string; count: number; digest: string }


/** HH:MM:SS left until `at`, from the page's clock; "expired" once it passes. */
function left(at: string): string {
  const s = Math.floor((Date.parse(at) - Date.now()) / 1000)
  if (!(s > 0)) return "expired"
  const d = Math.floor(s / 86400)
  const hms = [Math.floor((s % 86400) / 3600), Math.floor((s % 3600) / 60), s % 60].map((x) => String(x).padStart(2, "0")).join(":")
  return d > 0 ? `${d}d ${hms}` : hms
}

/** The countdowns tick while the console is open: one redraw a second, nothing else moves. */
let ticking = 0
function tick(): void {
  if (ticking !== 0) return
  ticking = window.setInterval(() => {
    if (model.address.lens !== "fire") {
      window.clearInterval(ticking)
      ticking = 0
      return
    }
    for (const el of document.querySelectorAll<HTMLElement>("#lens [data-countdown]")) {
      const t = left(el.dataset.countdown ?? "")
      if (el.textContent !== t) el.textContent = t
    }
  }, 1000)
}

const ranges = (r: string): Html => (r === "" ? html`<span class="muted">none</span>` : html`<code>${r}</code>`)

function liveKeys(): Html {
  const keys = ask<{ keys: Key[] }>("live_keys")?.keys ?? []
  return html`<section class="card" data-key="keys"><h2>Live fire keys</h2>
    ${keys.length === 0 ? html`<p class="empty">No live key: agents draft and prepare, and nothing they hold can fire.</p>` : html`<table class="grid compact"><thead><tr>
      <th scope="col">Key</th><th scope="col">Missions</th><th scope="col">Burned</th><th scope="col">Remaining</th><th scope="col">Left</th><th scope="col"></th></tr></thead>
      <tbody>${keys.map((k) => html`<tr data-key="k${k.id}">
        <th scope="row">#${k.id}${k.request_id ? html` <a href="/fire/${k.request_id}" data-nav class="muted">request ${k.request_id}</a>` : EMPTY}${k.usable_by ? html` <span class="tag">key ${k.usable_by} only</span>` : EMPTY}</th>
        <td>${ranges(k.scope)}</td><td>${ranges(k.burned)}${k.in_flight ? html`<p class="muted">in flight: <code>${k.in_flight}</code></p>` : EMPTY}</td>
        <td>${ranges(k.remaining)}${k.changed ? html`<p class="warn">edited since approval, out of scope: <code>${k.changed}</code></p>` : EMPTY}</td>
        <td><span data-countdown="${k.expires_at}">${left(k.expires_at)}</span><br><span class="muted">${k.first_used_at ? "24 h from first use" : "unused: a week"}</span></td>
        <td><button type="button" class="danger" data-act="revoke" data-id="${k.id}">Revoke</button></td></tr>`)}</tbody></table>`}
  </section>`
}

function requests(): Html {
  const open = ask<{ rows: Row[] }>("find", { table: "fire_requests", where: { status: "open" }, order: ["id", "desc"], limit: 100 })?.rows ?? []
  if (open.length === 0) return EMPTY
  return html`<section class="card" data-key="requests"><h2>Requests from agents</h2>
    <ul class="rows">${open.map((r: Row) => html`<li data-key="r${str(r.id)}"><a href="/fire/${str(r.id)}" data-nav>Request ${str(r.id)}</a>
      ${ranges(str(r.missions))} <span class="muted">${str(r.reason)}</span>
      <button type="button" class="ghost" data-act="decline" data-id="${str(r.id)}">Decline</button></li>`)}</ul>
  </section>`
}

// ------------------------------------------------------------------ the review

/** Why a mission cannot go under a key now, in the operator's terms (the fire judge's holds). */
export const WHY: Record<string, string> = {
  not_ready: "not fire ready: its draft is not finished",
  incomplete: "the email is not complete: it needs a To (up to 10 addresses), a subject and a body",
  in_flight: "in flight: a shot is being sent",
  fired: "already fired",
  unlinked: "its application has no company",
  app_stage: "its application is not at fire ready (or is closed)",
  unsettled: "an earlier send for this application is unresolved: settle it first",
  mailbox: "no live Gmail link to send from",
  cv_file: "a first email carries the CV as a file: pick a PDF or DOCX version for its application",
}
export const ROUTE: Record<string, string> = { email: "Email", careers_page: "Careers page", linkedin: "LinkedIn", x_dm: "X message", discord: "Discord", other: "Other" }

/** The review being read: missions the operator unticked, and which key may use it, kept across redraws. */
let reading = ""
let unticked = new Set<number>()
let usableBy = ""
let creating = false

/** What a review address asks for: a request by id, or missions named by ranges. */
function asked(): Record<string, unknown> | null {
  const sub = model.address.sub
  if (/^\d+$/.test(sub)) return { request: Number(sub) }
  const m = model.address.q.get("missions") ?? ""
  return m !== "" ? { missions: m } : null
}

/** Inbound and agent-written text is shown as text: no markup is read, a link is its href. */
const text = (t: string | null | undefined): Html => html`<pre class="untrusted">${t ?? ""}</pre>`

function draft(m: Mission): Html {
  const d = m.draft
  if (!d) return html`<p class="warn">No draft: nothing would be sent.</p>`
  if (d.markdown !== undefined) return text(d.markdown)
  return html`<dl class="mail">
    <dt>To</dt><dd><code>${d.to ?? ""}</code></dd>
    ${d.cc ? html`<dt>Cc</dt><dd><code>${d.cc}</code></dd>` : EMPTY}
    ${d.in_reply_to ? html`<dt>In reply to</dt><dd><code>${d.in_reply_to}</code></dd>` : EMPTY}
    <dt>Subject</dt><dd>${d.subject ?? ""}</dd></dl>${text(d.body)}`
}

/** What a first email attaches: the CV version's file. Whether it may go without one is the judge's `cv_file`. */
function attachment(m: Mission): Html {
  if (m.kind !== "email" || m.draft?.in_reply_to) return EMPTY
  const v = m.cv_version_id ? row("cv_versions", m.cv_version_id) : null
  return v && str(v.blob_sha) !== ""
    ? html`<p>Attachment: <code>${str(v.blob_name) || "the CV"}</code> <span class="muted">CV version ${m.cv_version_id}, ${str(v.blob_type)}</span></p>`
    : html`<p class="muted">No file attached.</p>`
}

function mission(m: Mission): Html {
  const on = m.eligible && !unticked.has(m.id)
  return html`<article class="card mission${m.eligible ? "" : " held"}" data-key="m${m.id}">
    <header><label class="check"><input type="checkbox" data-act="tick" data-on="change" data-id="${m.id}"${flag("checked", on)}${flag("disabled", !m.eligible)}>
      <strong>#${m.id} ${ROUTE[m.kind] ?? m.kind}</strong></label>
      <a href="/desk/${m.application.no}" data-nav>${m.application.company}: ${m.application.role}</a>
</header>
    <p>Target: <code>${m.target}</code></p>
    ${m.eligible ? EMPTY : html`<p class="warn">Cannot go under a key: ${WHY[m.why ?? ""] ?? m.why}.</p>`}
    ${attachment(m)}${draft(m)}
  </article>`
}

function review(params: Record<string, unknown>): Html {
  const r = ask<Review>("fire_review", params)
  if (!r) return html`<section class="card"><h2>Review</h2><p class="empty">Nothing to review here: no such request, or no such missions.</p></section>`
  const key = JSON.stringify(params)
  if (key !== reading) {
    reading = key
    unticked = new Set()
    usableBy = r.request?.requested_by ? String(r.request.requested_by) : ""
  }
  const chosen = r.missions.filter((m) => m.eligible && !unticked.has(m.id))
  const keys = page({ table: "acct_keys", order: ["id", "desc"] }, 100).rows
  const closed = r.request !== null && r.request.status !== "open"
  return html`<div class="review">
    <section class="card" data-key="head"><h2>${r.request ? html`Request ${r.request.id}` : "Authorize missions"}</h2>
      ${r.request ? html`<p>${r.request.reason}</p><p class="muted">Asked for <code>${r.request.missions}</code>${r.request.requested_by ? ` by API key ${r.request.requested_by}` : ""}${closed ? `; ${r.request.status}` : ""}.</p>` : EMPTY}
      <p class="hint">Read every draft and target below: the key fires exactly these, one shot each. A mission edited after the key is made falls out of it.</p></section>
    ${r.missions.map(mission)}
    ${closed ? EMPTY : html`<section class="card" data-key="create"><h2>Create the key</h2>
      <p>${chosen.length === 0 ? "No mission ticked: nothing can be authorized." : html`${chosen.length} mission${chosen.length === 1 ? "" : "s"}: <code>${chosen.map((m) => m.id).join(", ")}</code>`}</p>
      <label>Usable by <select data-act="usable" data-on="change">
        <option value=""${flag("selected", usableBy === "")}>this session and any of my API keys</option>
        ${keys.map((k: Row) => html`<option value="${str(k.id)}"${flag("selected", usableBy === str(k.id))}>API key ${str(k.id)} ${str(k.name)} only</option>`)}</select></label>
      <p class="hint">Unused, the key lives a week; from its first shot, 24 hours. You will be asked for a factor.</p>
      <div class="actions"><button type="button" class="danger" data-act="create"${flag("disabled", chosen.length === 0 || creating)}>Create fire key</button>
        ${r.request ? html`<button type="button" class="ghost" data-act="decline" data-id="${r.request.id}">Decline</button>` : EMPTY}</div>
      ${stepUpPanel()}</section>`}
  </div>`
}

/** The key over the ticked missions: a narrowed set is reviewed again, and only if every hash is still what was read. */
async function create(): Promise<void> {
  const params = asked()
  const r = params && ask<Review>("fire_review", params)
  if (!r) return
  const read = new Map(r.missions.filter((m) => m.eligible && !unticked.has(m.id)).map((m) => [m.id, m.hash]))
  let { scope, digest } = r
  if (read.size !== r.count) {
    const narrowed = ask<Review>("fire_review", { missions: [...read.keys()].join(",") })
    if (!narrowed || narrowed.count !== read.size || narrowed.missions.some((m) => m.eligible && read.get(m.id) !== m.hash)) {
      notice("error", "A mission changed while you read it: read the review again.")
      return schedule()
    }
    ;({ scope, digest } = narrowed)
  }
  creating = true
  schedule()
  try {
    const p: Record<string, string | number> = { missions: scope, digest }
    if (usableBy !== "") p.usable_by = Number(usableBy)
    if (r.request) p.request = r.request.id
    const { id } = await command("create_fire_key", 0, p)
    notice("ok", `Fire key #${id} created over ${scope}.`)
    go({ lens: "fire", sub: "", q: new Map() })
  } catch (e) {
    if (e instanceof Refused && e.code === "step_up") askStepUp(create)
    else if (e instanceof Refused && e.code === "fire") {
      notice("error", "A mission changed since this review was drawn: read it again.")
    } else failed(e)
  } finally {
    creating = false
    schedule()
  }
}

function view(): Html {
  tick()
  const params = asked()
  if (params) return html`<div class="fire">${review(params)}</div>`
  return html`<div class="fire">
    ${liveKeys()}${requests()}
    <p class="hint">A key covers missions by id, one shot each. Unused it lives a week; from its first use, 24 hours. A mission edited after the key was made falls out of its scope.</p>
  </div>`
}

const fire: View = {
  title: "Fire",
  view,
  act(name, el) {
    if (stepAct(name, el)) return
    const id = Number(el.dataset.id ?? 0)
    switch (name) {
      case "tick":
        if ((el as HTMLInputElement).checked) unticked.delete(id)
        else unticked.add(id)
        return schedule()
      case "usable":
        usableBy = (el as HTMLSelectElement).value
        return
      case "create":
        return void create()
      case "revoke":
        return void command("revoke_fire_key", id).then(() => notice("ok", `Fire key #${id} revoked: nothing more fires under it.`)).catch(failed)
      case "decline":
        return void command("decline", id).then(() => {
          notice("ok", `Request ${id} declined.`)
          if (model.address.sub === String(id)) go({ lens: "fire", sub: "", q: new Map() })
        }).catch(failed)
    }
  },
}

export default fire
