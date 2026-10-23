// The account lens: identities, factors, sessions, keys with masks, live
// leases with revoke, trusted hosts and the audit trail. It reads the
// replica's account views (acct_*, leases, trusted), patched when anything
// audited changes, so a revoke made on another device redraws it at once;
// it changes the account with `account.*` RPC on the wire session
// (lib/hireme_web/account.ex lists them). Linking a provider is the one
// HTTP step: it leaves the page.
//
// Mail: the account's Gmail is linked here with an app password (account.mail.link), and its state
// (linked, retrying, password refused, last sync) is the replica's one `mailboxes` row.
//
// A change that needs a fresh session is refused `step_up`; the lens keeps
// the action, asks for a factor (passkey, TOTP or a recovery code), and
// retries it once the session is fresh.

import type { View } from "../app.ts"
import { create, get, supported, why } from "../auth/webauthn.ts"
import { DOMAIN } from "../gen/schema.ts"
import { Refused, ask, ids, page, rpc, value, type Row } from "../kernel.ts"
import { EMPTY, attempt, entries, fields, flag, html, resetIfUnchanged, str, trusted, type Html } from "../morph.ts"
import { detail } from "./trail.ts"
import { model, notice, query, set, type AccountView } from "../state.ts"

const DOMAINS = ["world", "desk", "mail", "corpus"] as const
const PRESETS = [
  ["read_only", "Read only"],
  ["write_only", "Write only"],
  ["read_write", "Read and write"],
  ["custom", "Custom"],
] as const

const v = (): AccountView => model.account
const patch = (p: Partial<AccountView>) => set({ account: { ...model.account, ...p } })
const list = (k: string): Row[] => (overview()?.[k] as Row[] | undefined) ?? []
const num = (x: unknown): number => (typeof x === "number" ? x : Number(x ?? 0))

const maskNames = (mask: number): string => {
  const on = DOMAINS.filter((d) => (mask & DOMAIN[d]) !== 0)
  return on.length === 0 ? "none" : on.length === DOMAINS.length ? "all" : on.join(", ")
}

function when(x: unknown): string {
  const s = str(x)
  if (s === "") return ""
  const t = Date.parse(s)
  if (Number.isNaN(t)) return s
  const d = (Date.now() - t) / 1000
  if (d > -60 && d < 60) return "just now"
  if (d > 0 && d < 3600) return `${Math.round(d / 60)} min ago`
  if (d > 0 && d < 86400) return `${Math.round(d / 3600)} h ago`
  return new Date(t).toISOString().slice(0, 10)
}

const time = (x: unknown): Html => (str(x) === "" ? EMPTY : html`<time datetime="${str(x)}">${when(x)}</time>`)

// ------------------------------------------------------------------ the account, from the replica

/** A step-up proof's life (Security's step_up_window): sensitive changes need one this fresh. */
const STEP_UP_S = 300
const ALL = DOMAIN.world | DOMAIN.desk | DOMAIN.mail | DOMAIN.corpus
/** Each preset's masks (Grants.preset). */
const PRESET_MASKS: Record<string, { read: number; write: number }> = { read_only: { read: ALL, write: 0 }, write_only: { read: 0, write: ALL }, read_write: { read: ALL, write: ALL } }
/** Up to `limit` rows of a replica view, in find's pages of 500. */
const rowsOf = (table: string, params: Record<string, unknown> = {}, limit = 500): Row[] => page({ table, ...params }, limit).rows
/** A session lapses a day after sign-in or an hour idle (Security's session_ttl and session_idle). */
const IDLE_S = 3600
const later = (x: unknown): boolean => str(x) !== "" && Date.parse(str(x)) > Date.now()

/**
 * The account page's data, as account.overview answered it, from the replica's account views
 * (acct_*, the leases and the trusted hosts), so the page reads in its frame and a change reaches it as a
 * PATCH. Null until the replica answers.
 */
function overview(): Row | null {
  // acct_info is one wire row with no id column (find orders by id): read its first row's cells.
  const at = ids("acct_info")[0]
  return at === undefined ? null : attempt(() => {
    const factors = rowsOf("acct_factors")
    // The view keeps every unrevoked session; the page lists the live ones, the latest seen first.
    const sessions: Row[] = rowsOf("acct_sessions")
      .filter((x) => later(x.expires_at) && Date.parse(str(x.last_seen_at)) > Date.now() - IDLE_S * 1000)
      .sort((a, b) => str(b.last_seen_at).localeCompare(str(a.last_seen_at)))
      .map((x) => ({ ...x, current: num(x.id) === model.sessionId }))
    const me = sessions.find((x) => x.current)
    // A step-up is the factor's proof when the account has one, the sign-in's when it has none.
    const proof = Date.parse(str(factors.length > 0 ? me?.mfa_at : me?.authenticated_at))
    const keys = rowsOf("acct_keys", { order: ["id", "desc"] }).map((k) => {
      const preset = k.may_delete === true ? undefined : Object.keys(PRESET_MASKS).find((p) => PRESET_MASKS[p]!.read === num(k.read_mask) && PRESET_MASKS[p]!.write === num(k.write_mask))
      return { ...k, display: `hm_${str(k.prefix)}…`, preset: preset ?? "custom", live: str(k.revoked_at) === "" && (str(k.expires_at) === "" || later(k.expires_at)), paused: str(k.paused_at) !== "" }
    })
    const leases = rowsOf("leases").map((l) => ({ ...l, ids: str(l.held).split("\u001f").filter((x) => x !== "") }))
    return {
      name: value("acct_info", at, "name"),
      fresh_for: Number.isNaN(proof) ? 0 : Math.min(STEP_UP_S, Math.max(0, STEP_UP_S - (Date.now() - proof) / 1000)),
      recovery_codes_left: value("acct_info", at, "recovery_codes_left"),
      identities: rowsOf("acct_identities"),
      factors,
      sessions,
      keys,
      leases,
      trusted_hosts: rowsOf("trusted"),
    }
  }, null)
}

const MESSAGES: Record<string, string> = {
  scope: "This session cannot do that.",
  not_found: "That no longer exists.",
  invalid: "That is not valid.",
  masks: "Pick a preset or at least one domain.",
  limit: "A limit was reached.",
  rate_limited: "Too many attempts. Wait a few minutes.",
  last: "That is the last way in; add another first.",
  taken: "That is already linked to another account.",
  challenge: "The ceremony expired; start again.",
  code: "That code is not right.",
  attestation: "The passkey could not be verified.",
  assertion: "The passkey was not accepted.",
  duplicate: "That is already enrolled.",
  clone: "That authenticator looks cloned; it was refused.",
  revoked: "That was already revoked.",
  no_factor: "Enroll a factor first.",
  no_email: "Add an email under Ways in first, or sign out and back in.",
  factor: "Confirm with your second factor.",
  cap: "That is past the limit of 100; remove one first.",
}

/** What a failed call says to the operator: a refusal by its code, a ceremony by why(). */
const said = (e: unknown): string => (e instanceof Refused ? MESSAGES[e.code] ?? e.message : e instanceof Error ? why(e) : String(e))

/**
 * What a change refused `step_up` does once the session is fresh: the call again, finishing the same
 * way (closing its form, revealing a secret); a ceremony or a link as itself, since its answer (a QR
 * code, passkey options) is what the next step needs; another lens's action (a fire key) there. Kept
 * beside the dialog, not in the model: it is a function.
 */
let resume: (() => void | Promise<void>) | undefined

/** Ask for a fresh factor before an action, and run `then` once it is given. */
export function askStepUp(then: () => void | Promise<void>, more: Partial<AccountView> = {}): void {
  resume = then
  patch({ stepUp: {}, error: "", ...more })
}

/** Run an account method, its answer to `done` (by default, the secret it shows once); a `step_up` refusal parks it until the session is fresh. */
async function call(method: string, params: Record<string, unknown> = {}, done = (r: Row): void => reveal(method, r)): Promise<void> {
  try {
    const r = await rpc(method, params)
    patch({ error: "" })
    done(r)
  } catch (e) {
    if (e instanceof Refused && e.code === "step_up") return askStepUp(() => call(method, params, done))
    patch({ error: said(e) })
  }
}

async function stepped(method: string, params: Record<string, unknown>): Promise<void> {
  try {
    await rpc(method, params)
  } catch (e) {
    return patch({ error: said(e) })
  }
  const then = resume
  resume = undefined
  patch({ stepUp: null })
  await then?.()
}

// ------------------------------------------------------------------ mail: the linked Gmail

/** What the node answers a link that failed (nothing was stored), in the operator's terms. */
const MAIL_ERR: Record<string, string> = {
  auth: "Gmail refused this app password. Make a new one and link again.",
  imap_disabled: "IMAP is off for this Gmail account: turn it on in Gmail's settings (Forwarding and POP/IMAP), then link again.",
  unreachable: "Gmail could not be reached. Try again in a minute.",
  address: "Only a gmail.com or googlemail.com address can be linked for now.",
  limit: "Too many link attempts: wait ten minutes, then try again.",
  all_mail_hidden: "All Mail is hidden from IMAP in this Gmail account: in Gmail's settings, Labels, tick Show in IMAP for All Mail, then link again.",
}
/** The address a link parked behind a step-up, to fill the form again (never the password). */
let mailAddress = ""

/** The account's one mailbox row, null before any link. */
const mailbox = (): Row | null => ask<{ rows: Row[] }>("find", { table: "mailboxes", limit: 1 })?.rows[0] ?? null

function mail(): Html {
  const m = mailbox()
  const status = str(m?.status) || "unlinked"
  const linked = m !== null && status !== "unlinked"
  const tag = { live: html`<span class="tag ok">linked</span>`, linking: html`<span class="tag">linking…</span>`, auth_failed: html`<span class="tag bad">password refused</span>`, error: html`<span class="tag warn">retrying</span>` }[status] ?? EMPTY
  const form = html`<form class="stack" data-submit="mail-link" data-act="mail-link" data-key="mail-form">
      <label>Gmail address <input name="address" type="email" required autocomplete="email" value="${mailAddress || str(m?.address)}"></label>
      <label>App password <input name="app_password" type="password" required autocomplete="off" spellcheck="false" minlength="16" maxlength="24"></label>
      <p class="hint">An app password, not your Google password: Google Account, Security, 2-Step Verification, App passwords. Sixteen letters, with or without spaces. hireme checks it with one sign-in, keeps it sealed, and never shows it again.</p>
      <span class="row"><button class="primary">Link</button><button type="button" class="ghost" data-act="close">Cancel</button></span></form>`
  return html`<section class="card" data-key="mail"><h2>Mail</h2>
    ${linked
      ? html`<p><b>${str(m!.address)}</b> ${tag}${m!.last_sync_at ? html` <span class="muted">last sync ${time(m!.last_sync_at)}</span>` : EMPTY}</p>
        ${status === "auth_failed" ? html`<p class="error">${str(m!.last_error) || MAIL_ERR.auth} Link it again with a new app password.</p>` : status === "error" && m!.last_error ? html`<p class="muted">${MAIL_ERR[str(m!.last_error)] ?? str(m!.last_error)}; retrying.</p>` : EMPTY}
        <p class="row">${status === "auth_failed" && v().open !== "mail" ? html`<button type="button" data-act="open" data-form="mail">Relink</button>` : EMPTY}<button type="button" class="ghost" data-act="mail-pipe">Domain pipe secret</button><button type="button" class="ghost" data-act="mail-unlink">Unlink</button></p>`
      : html`<p class="muted">Link your Gmail: replies to your applications file themselves here, and mail sent from hireme sits in Gmail's Sent. hireme reads only the job search's mail, labels it hireme, and never moves, archives or deletes anything.</p>`}
    ${v().open === "mail" ? form : linked ? EMPTY : html`<button type="button" data-act="open" data-form="mail">Link Gmail</button>`}
  </section>`
}

async function linkMail(address: string, password: string): Promise<void> {
  try {
    const r = await rpc<{ ok?: boolean; error?: string }>("account.mail.link", { address, app_password: password })
    if (r.error) return patch({ error: MAIL_ERR[r.error] ?? r.error })
    mailAddress = ""
    patch({ open: "", error: "" })
    notice("ok", `Gmail linked: ${address}.`)
  } catch (e) {
    // A step-up parks the address only: the password is typed again, never kept while a factor is asked for.
    if (e instanceof Refused && e.code === "step_up") {
      mailAddress = address
      return askStepUp(() => (patch({ open: "mail" }), notice("info", "Verified. Enter the app password again to link.")), { open: "" })
    }
    patch({ error: e instanceof Refused && MAIL_ERR[e.code] !== undefined ? MAIL_ERR[e.code]! : said(e) })
  }
}

// ------------------------------------------------------------------ the step-up, for other lenses

/** The factor dialog and the last error, as the account lens draws them, for a lens that asked. */
export const stepUpPanel = (): Html => html`${v().error !== "" ? html`<p class="error" role="alert" data-key="step-err">${v().error}</p>` : EMPTY}${stepUp()}`
/** The dialog's own actions (passkey, codes, cancel), run for a lens that drew it; false for any other. */
export const stepAct = (name: string, el: HTMLElement): boolean => name.startsWith("step-") && (act(name, el), true)

/** What a call returned that is shown once: a key's secret, recovery codes. */
function reveal(method: string, r: Row): void {
  if (method === "account.key.mint" && typeof r.secret === "string") {
    patch({ reveal: { title: "The new key. It is shown once; store it now.", lines: [r.secret] }, open: "" })
  } else if (method === "account.mail.pipe" && typeof r.secret === "string") {
    // The domain pipe's two Worker secrets, set with wrangler in a real terminal (docs/mail/domain_pipe.md).
    const url = `${location.origin}/mail/inbound/${str(r.pipe_id)}`
    patch({ reveal: { title: "The domain pipe. Set these as the mail Worker's PIPE_URL and PIPE_SECRET; the secret is shown once, and a new one replaces it.", lines: [url, str(r.secret)] }, open: "" })
  } else if (Array.isArray(r.recovery_codes) && r.recovery_codes.length > 0) {
    patch({ reveal: { title: "Recovery codes. Each works once; they are shown once.", lines: r.recovery_codes.map(String) }, totp: null, open: "" })
  }
}

type Draft = NonNullable<AccountView["masks"]>

const presetMasks = (preset: string): { read: number; write: number } => PRESET_MASKS[preset] ?? { read: 0, write: 0 }

/** The form's access: what was chosen in it, or what it opened with. */
function draft(form: string, read: number, write: number, preset: string, mayDelete: boolean): Draft {
  const d = v().masks
  return d && d.form === form ? d : { form, preset, read, write, mayDelete }
}

/** The masks a draft grants: a preset's own, or the custom checkboxes. */
const grants = (d: Draft): { read: number; write: number } => (d.preset === "custom" ? { read: d.read, write: d.write } : presetMasks(d.preset))

const masksFrom = (d: Draft): Record<string, unknown> =>
  d.preset !== "custom" ? { preset: d.preset, may_delete: d.mayDelete } : { read_mask: d.read, write_mask: d.write, may_delete: d.mayDelete }

/** The form's controls, read back into its draft after any change. */
function redraft(form: HTMLFormElement, prev: Draft): Draft {
  const preset = (form.elements.namedItem("preset") as HTMLSelectElement | null)?.value ?? prev.preset
  const mayDelete = (form.elements.namedItem("may_delete") as HTMLInputElement | null)?.checked ?? prev.mayDelete
  if (preset !== "custom") return { ...prev, preset, mayDelete }
  // Turning to custom starts from what the previous preset granted.
  const start = prev.preset === "custom" ? null : presetMasks(prev.preset)
  let read = 0
  let write = 0
  for (const d of DOMAINS) {
    if (start ? (start.read & DOMAIN[d]) !== 0 : (form.elements.namedItem(`r_${d}`) as HTMLInputElement | null)?.checked) read |= DOMAIN[d]
    if (start ? (start.write & DOMAIN[d]) !== 0 : (form.elements.namedItem(`w_${d}`) as HTMLInputElement | null)?.checked) write |= DOMAIN[d]
  }
  return { ...prev, preset, read, write, mayDelete }
}

async function link(provider: string, email?: string): Promise<void> {
  const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
  const res = await fetch("/api/account/identities", {
    method: "POST",
    credentials: "same-origin",
    headers: { "content-type": "application/json", "x-csrf-token": csrf },
    body: JSON.stringify(email === undefined ? { provider } : { provider, email }),
  })
  const body = (await res.json().catch(() => ({}))) as { url?: string; sent?: boolean; error?: string }
  if (body.error === "step_up") return askStepUp(() => link(provider, email))
  if (body.url) return location.assign(body.url)
  if (body.sent) return notice("ok", "A link is on its way; open it to add that address.")
  patch({ error: MESSAGES[body.error ?? ""] ?? body.error ?? "Linking failed." })
}

// ------------------------------------------------------------------ view

/**
 * The key's access, chosen in the open: the preset, the per-domain grid it
 * grants (editable only for custom), and a sentence of what the key will do,
 * all drawn from the form's draft before anything is minted.
 */
function maskPicker(prefix: string, read: number, write: number, preset: string, mayDelete: boolean): Html {
  const d = draft(prefix, read, write, preset, mayDelete)
  const g = grants(d)
  const custom = d.preset === "custom"
  return html`<div class="mask-picker" data-act="masks" data-on="change" data-form="${prefix}" data-key="${prefix}-picker">
    <label>Access <select name="preset">
      ${PRESETS.map(([p, label]) => html`<option value="${p}"${flag("selected", p === d.preset)}>${label}</option>`)}
    </select></label>
    <fieldset class="masks" data-key="${prefix}-masks"${flag("disabled", !custom)}>
      <legend>${custom ? "Choose per domain" : "What this preset grants"}</legend>
      <table class="grid compact"><thead><tr><th></th>${DOMAINS.map((x) => html`<th scope="col">${x}</th>`)}</tr></thead>
      <tbody>
        <tr><th scope="row">read</th>${DOMAINS.map((x) => html`<td><input type="checkbox" name="r_${x}" aria-label="read ${x}"${flag("checked", (g.read & DOMAIN[x]) !== 0)}></td>`)}</tr>
        <tr><th scope="row">write</th>${DOMAINS.map((x) => html`<td><input type="checkbox" name="w_${x}" aria-label="write ${x}"${flag("checked", (g.write & DOMAIN[x]) !== 0)}></td>`)}</tr>
      </tbody></table>
    </fieldset>
    <label class="check"><input type="checkbox" name="may_delete"${flag("checked", d.mayDelete)}> may delete rows</label>
    <p class="mask-summary" role="status">This key reads ${maskNames(g.read)}, writes ${maskNames(g.write)}${d.mayDelete ? ", and may delete rows" : ", and cannot delete"}.
      ${g.write === 0 ? html`<b>An agent with it cannot add or change data</b>: choose Read and write for one that should.` : EMPTY}</p>
  </div>`
}

function stepUp(): Html {
  const s = v().stepUp
  if (!s) return EMPTY
  const factors = list("factors")
  const passkey = factors.some((f) => f.kind === "webauthn") && supported()
  const totp = factors.some((f) => f.kind === "totp")
  // No factor: a code mailed to the account's addresses renews the sign-in.
  return html`<section class="card step-up" role="dialog" aria-labelledby="step-up-h" data-key="step-up">
    <h2 id="step-up-h">Confirm it is you</h2>
    ${factors.length === 0 ? (s.mailed
      ? html`<form data-submit="step-mail-code" data-act="step-mail-code" class="row"><label>The code we emailed you
      <input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,7}" required></label>
      <button class="primary">Confirm</button></form>`
      : html`<p class="lede">We'll email you a code.</p><button type="button" class="primary" data-act="step-mail">Email me a code</button>`) : html`
    <p class="lede">That change needs a factor from the last few minutes.</p>
    ${passkey ? html`<button type="button" class="primary" data-act="step-passkey">Use a passkey</button>` : EMPTY}
    ${totp ? html`<form data-submit="step-totp" data-act="step-totp" class="row"><label>Authenticator code
      <input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,8}" required></label>
      <button class="primary">Confirm</button></form>` : EMPTY}
    ${num(overview()?.recovery_codes_left) > 0 ? html`<form data-submit="step-recovery" data-act="step-recovery" class="row"><label>Or a recovery code
      <input name="code" autocomplete="off" required></label><button>Use code</button></form>` : EMPTY}`}
    <button type="button" class="ghost" data-act="step-cancel">Cancel</button>
  </section>`
}

function revealed(): Html {
  const r = v().reveal
  if (!r) return EMPTY
  return html`<section class="card reveal" role="alert" data-key="reveal">
    <h2>${r.title}</h2>
    <pre class="secret">${r.lines.join("\n")}</pre>
    <div class="row"><button type="button" data-act="copy">Copy</button><button type="button" class="primary" data-act="reveal-done">I stored it</button></div>
  </section>`
}

function confirmButton(id: string, label: string, act: string, data: Record<string, string | number>): Html {
  const attrs = Object.entries(data).map(([k, x]) => html` data-${k}="${x}"`)
  return v().open === `confirm:${id}`
    ? html`<span class="confirm"><button type="button" class="danger" data-act="${act}"${attrs}>${label}?</button>
        <button type="button" class="ghost" data-act="close">No</button></span>`
    : html`<button type="button" class="ghost" data-act="open" data-form="confirm:${id}">${label}</button>`
}

function identities(): Html {
  const rows = list("identities")
  const email = v().open === "link-email"
  return html`<section class="card" data-key="identities"><h2>Ways in</h2>
    <ul class="rows">${rows.map((i) => html`<li data-key="i${num(i.id)}"><b>${str(i.provider)}</b> <span>${str(i.display)}</span>
      <span class="muted">verified ${time(i.verified_at)}</span>
      ${rows.length > 1 ? confirmButton(`i${num(i.id)}`, "Unlink", "unlink", { id: num(i.id) }) : EMPTY}</li>`)}</ul>
    <div class="row">
      <button type="button" data-act="link" data-provider="github">Link GitHub</button>
      <button type="button" data-act="link" data-provider="x">Link X</button>
      <button type="button" data-act="open" data-form="link-email">Add an email</button>
    </div>
    ${email ? html`<form class="row" data-submit="link-email" data-act="link-email"><label>Email <input type="email" name="email" required autocomplete="email"></label>
      <button class="primary">Send link</button><button type="button" class="ghost" data-act="close">Cancel</button></form>` : EMPTY}
  </section>`
}

function factors(): Html {
  const rows = list("factors")
  const left = num(overview()?.recovery_codes_left)
  const t = v().totp
  return html`<section class="card" data-key="factors"><h2>Second factors</h2>
    ${rows.length === 0 ? html`<p class="hint">No second factor yet. A passkey is the strongest; an authenticator app works too.</p>` : EMPTY}
    <ul class="rows">${rows.map((f) => html`<li data-key="f${num(f.id)}"><b>${f.kind === "webauthn" ? "Passkey" : "Authenticator"}</b> ${str(f.name)}
      ${f.backed_up === true ? html`<span class="tag">synced</span>` : EMPTY}
      <span class="muted">${str(f.last_used_at) === "" ? html`added ${time(f.verified_at)}` : html`used ${time(f.last_used_at)}`}</span>
      ${confirmButton(`f${num(f.id)}`, "Remove", "factor-remove", { id: num(f.id) })}</li>`)}</ul>
    <div class="row">
      ${supported() ? html`<form class="row" data-submit="passkey" data-act="passkey"><input name="name" placeholder="Passkey name" aria-label="Passkey name" maxlength="100"><button class="primary">Add a passkey</button></form>` : EMPTY}
      ${t ? EMPTY : html`<button type="button" data-act="totp-begin">Add an authenticator app</button>`}
    </div>
    ${t ? html`<div class="totp" data-key="totp">
        <div class="qr" data-morph="own">${trusted(t.svg)}</div>
        <p>Scan it, or enter <code class="secret">${t.secret}</code> by hand.</p>
        <form class="row" data-submit="totp-confirm" data-act="totp-confirm">
          <label>Code <input name="code" inputmode="numeric" autocomplete="one-time-code" required></label>
          <label>Name <input name="name" maxlength="100" placeholder="Phone"></label>
          <button class="primary">Confirm</button><button type="button" class="ghost" data-act="totp-cancel">Cancel</button>
        </form></div>` : EMPTY}
    ${rows.length === 0 ? EMPTY : html`<p class="${left === 0 ? "warn" : "muted"}">${left === 0 ? "No recovery codes left: if you lose your factors you cannot get back in." : `${left} recovery code${left === 1 ? "" : "s"} left.`}
      ${confirmButton("recovery", "Make new codes", "recovery", {})}</p>`}
  </section>`
}

function sessions(): Html {
  const rows = list("sessions")
  return html`<section class="card" data-key="sessions"><h2>Sessions</h2>
    <ul class="rows">${rows.map((s) => html`<li data-key="s${num(s.id)}">
      <b title="${str(s.user_agent)}">${s.current === true ? "This browser" : browserName(str(s.user_agent))}</b>
      <span class="muted">${str(s.ip)} · seen ${time(s.last_seen_at)} · signed in ${time(s.authenticated_at)}</span>
      ${s.current === true ? EMPTY : confirmButton(`s${num(s.id)}`, "Revoke", "session-revoke", { id: num(s.id) })}</li>`)}</ul>
    ${rows.length > 1 ? confirmButton("others", "Sign out everywhere else", "session-others", {}) : EMPTY}
  </section>`
}

function keys(): Html {
  const rows = list("keys")
  const open = v().open
  return html`<section class="card" data-key="keys"><h2>API keys</h2>
    <p class="hint">A key opens one agent session over the MCP. Its read and write masks bound every row it sees and every write it makes.</p>
    <div class="table-scroll"><table class="grid"><thead><tr><th scope="col">Name</th><th scope="col">Key</th><th scope="col">Reads</th><th scope="col">Writes</th><th scope="col">Used</th><th scope="col"></th></tr></thead>
    <tbody>${rows.map((k) => {
      const id = num(k.id)
      const live = k.live === true
      const paused = live && str(k.paused_at) !== ""
      return html`<tr data-key="k${id}" class="${live ? "" : "dead"}">
        <td>${str(k.name)}</td><td><code>${str(k.display)}</code></td>
        <td>${maskNames(num(k.read_mask))}</td><td>${maskNames(num(k.write_mask))}${k.may_delete === true ? html` <span class="tag">delete</span>` : EMPTY}</td>
        <td>${str(k.last_used_at) === "" ? html`<span class="muted">never</span>` : time(k.last_used_at)}${str(k.revoked_at) !== "" ? html` <span class="tag">revoked</span>` : EMPTY}${paused ? html` <span class="tag paused" title="You revoked its lease: it reads, but writes nothing until you resume it">paused since ${time(k.paused_at)}</span>` : EMPTY}</td>
        <td class="actions">${paused ? html`<button type="button" class="primary" data-act="key-resume" data-id="${id}">Resume</button>` : EMPTY}${live ? html`<button type="button" class="ghost" data-act="open" data-form="change:${id}">Change</button>
          ${confirmButton(`k${id}`, "Revoke", "key-revoke", { id })}` : EMPTY}</td></tr>
        ${open === `change:${id}` ? html`<tr data-key="k${id}-change"><td colspan="6">
          <form class="stack" data-submit="key-change" data-act="key-change" data-id="${id}">
            <label>Name <input name="name" value="${str(k.name)}" maxlength="100" required></label>
            ${maskPicker(`k${id}`, num(k.read_mask), num(k.write_mask), str(k.preset) || "custom", k.may_delete === true)}
            <p class="hint">Widening a key or allowing deletes needs a fresh factor. The agent's session restarts with the new masks.</p>
            <div class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="close">Cancel</button></div>
          </form></td></tr>` : EMPTY}`
    })}</tbody></table></div>
    ${open === "mint" ? html`<form class="stack" data-submit="mint" data-act="mint" data-key="mint">
        <label>Name <input name="name" required maxlength="100" placeholder="research agent"></label>
        ${maskPicker("mint", 0, 0, "read_only", false)}
        <label>Expires after <select name="expires_in_days"><option value="">never</option><option value="7">7 days</option><option value="30">30 days</option><option value="90">90 days</option><option value="365">a year</option></select></label>
        <div class="row"><button class="primary"${flag("disabled", v().minting)}>${v().minting ? "Minting…" : "Mint key"}</button><button type="button" class="ghost" data-act="close">Cancel</button></div>
      </form>` : html`<button type="button" class="primary" data-act="open" data-form="mint">Mint a key</button>`}
  </section>`
}

function leases(): Html {
  const rows = list("leases")
  return html`<section class="card" data-key="leases"><h2>Live leases</h2>
    ${rows.length === 0 ? html`<p class="hint">No agent holds the write channel.</p>` : html`<p class="hint">Revoking an agent's lease pauses its key: it keeps reading but writes nothing until you resume it under API keys. Revoking the key stops it for good.</p>`}
    <ul class="rows">${rows.map((l) => {
      const ids = Array.isArray(l.ids) ? l.ids.length : 0
      return html`<li data-key="l${num(l.id)}"><b>${str(l.label)}</b>
        <span class="muted">${l.key_id === null || l.key_id === undefined ? "browser" : `key ${num(l.key_id)}`} · ${ids} application${ids === 1 ? "" : "s"} · since ${time(l.since)}</span>
        ${l.key_id === null || l.key_id === undefined ? EMPTY : confirmButton(`l${num(l.id)}`, "Revoke", "lease-revoke", { id: num(l.id) })}</li>`
    })}</ul>
  </section>`
}

function hosts(): Html {
  const rows = list("trusted_hosts")
  return html`<section class="card" data-key="hosts"><h2>Trusted hosts</h2>
    <p class="hint">Corporations' culture and ratings may be cited only from these hosts.</p>
    <ul class="rows">${rows.map((h) => html`<li data-key="h${num(h.id)}"><b>${str(h.host)}</b> <span class="muted">${str(h.note)}</span>
      ${confirmButton(`h${num(h.id)}`, "Remove", "host-remove", { id: num(h.id) })}</li>`)}</ul>
    <form class="row" data-submit="host-add" data-act="host-add"><label>Host <input name="host" required placeholder="levels.fyi" autocomplete="off"></label>
      <label>Note <input name="note" maxlength="200"></label><button>Trust</button></form>
  </section>`
}

/** Who a coalesced count belongs to: a key by its name while the overview still lists it. */
function keyName(id: string): string {
  if (id === "none") return "no key"
  const k = list("keys").find((x) => String(x.id) === id)
  return k ? str(k.name) || `key ${id}` : `key ${id}`
}

/** A coalesced row: its window, its counts by kind and key, and the distinct addresses it came from. */
function coalesced(e: Row): Html {
  const m = (e.meta ?? {}) as Row & { from?: string; to?: string; counts?: Record<string, Record<string, number>> }
  const counts = Object.entries(m.counts ?? {})
  // Distinct values, capped by the node; `<field>_total` counts them all.
  const distinct = (field: string, one: string, many: string): Html => {
    const shown = Array.isArray(m[field]) ? (m[field] as unknown[]).map(str) : []
    if (shown.length === 0) return EMPTY
    const total = Math.max(shown.length, num(m[`${field}_total`]))
    // Past the node's tracking cap a window still counts events, but no longer which value each came from.
    const untracked = num(m[`${field}_untracked_events`])
    return html`<p class="muted">from ${total}${untracked > 0 ? "+" : ""} ${total === 1 && untracked === 0 ? one : many}: ${shown.join(", ")}${total > shown.length ? ` and ${total - shown.length} more` : ""}${
      untracked > 0 ? ` (${untracked} more event${untracked === 1 ? "" : "s"} from untracked ones)` : ""}</p>`
  }
  return html`<div class="coalesced">
      ${m.from ? html`<span class="muted">${time(m.from)} – ${time(m.to)}</span>` : EMPTY}
      <ul class="counts">${counts.map(([kind, by]) => {
        const per = Object.entries(by ?? {})
        const total = per.reduce((n, [, c]) => n + num(c), 0)
        return html`<li data-key="${kind}"><b>${total}</b> ${kind.replace(/_/g, " ")}${per.length > 0 ? html` <span class="muted">(${per.map(([k, c]) => `${keyName(k)}: ${num(c)}`).join(", ")})</span>` : EMPTY}</li>`
      })}</ul>
      ${distinct("addresses", "address", "addresses")}${distinct("user_agents", "user agent", "user agents")}
    </div>`
}

function audit(): Html {
  const a = v().audit
  const tab = (view: "security" | "activity", label: string) =>
    html`<button type="button" class="chip${a?.view === view ? " on" : ""}" aria-pressed="${String(a?.view === view)}" data-act="audit" data-view="${view}">${label}</button>`
  // The replica holds the newest events (acct_audit); each view is a filter of them, newest first.
  const all = a ? rowsOf("acct_audit", { where: { security: a.view === "security" }, order: ["id", "desc"] }, a.limit + 1) : []
  const events = all.slice(0, a?.limit ?? 0)
  return html`<section class="card" data-key="audit"><h2>Audit</h2>
    ${a === null ? html`<button type="button" data-act="audit" data-view="security">Show security events</button>` : html`
      <div class="chips" role="group" aria-label="Which events">${tab("security", "Security")}${tab("activity", "Activity")}</div>
      <p class="hint">${a.view === "security" ? "Sign-ins, factors, keys, sessions and revokes: kept for good." : "Agent writes, leases and connections, counted per window once busy; it expires."}</p>
      ${events.length === 0 ? html`<p class="empty">No events.</p>` : html`<div class="table-scroll"><table class="grid compact">
      <thead><tr><th scope="col">When</th><th scope="col">What</th><th scope="col">From</th></tr></thead>
      <tbody>${events.map((e) => {
        const kind = str(e.kind)
        const many = kind === "activity_coalesced" || kind === "revokes_coalesced"
        return html`<tr data-key="e${num(e.id)}"><td>${time(e.inserted_at)}</td><td>${kind.replace(/_/g, " ")}${e.key_id ? html` <span class="tag">${keyName(String(e.key_id))}</span>` : EMPTY}${many ? coalesced(e) : detail(e, keyName)}</td>
        <td class="muted">${str(e.ip)}</td></tr>`
      })}</tbody></table></div>`}
      ${all.length > events.length ? html`<button type="button" class="more" data-act="audit-more">Older events</button>` : EMPTY}`}
  </section>`
}

function view(): Html {
  const o = overview()
  if (!o) return html`<p class="empty">Loading the account…</p>`
  const fresh = num(o.fresh_for)
  return html`<div class="account">
    <section class="card head" data-key="head">
      ${v().open === "rename" ? html`<form class="row" data-submit="rename" data-act="rename"><input name="name" value="${str(o.name)}" required maxlength="200" aria-label="Account name">
          <button class="primary">Save</button><button type="button" class="ghost" data-act="close">Cancel</button></form>`
        : html`<h1>${str(o.name) || "Account"} <button type="button" class="ghost" data-act="open" data-form="rename">Rename</button></h1>`}
      <p class="muted">${fresh > 0 ? `Recently verified: sensitive changes go through for ${Math.ceil(fresh / 60)} more min.` : "Sensitive changes will ask for a second factor first."}</p>
    </section>
    <div class="alerts" data-key="alerts">${v().error !== "" ? html`<p class="error" role="alert" data-key="err">${v().error}</p>` : EMPTY}${stepUp()}</div>
    ${revealed()}${identities()}${mail()}${factors()}${keys()}${leases()}${sessions()}${hosts()}${audit()}
  </div>`
}

// ------------------------------------------------------------------ actions

function act(name: string, el: HTMLElement): void {
  const form = el instanceof HTMLFormElement ? el : null
  const f = form ? fields(form) : {}
  const id = Number(el.dataset.id)
  switch (name) {
    case "open":
      return patch({ open: el.dataset.form ?? "", error: "", masks: null })
    case "close":
      return patch({ open: "", masks: null })
    case "masks": {
      const f2 = el.closest("form")
      if (!f2) return
      const id2 = el.dataset.form ?? ""
      const key = list("keys").find((x) => `k${num(x.id)}` === id2)
      const prev = draft(id2, num(key?.read_mask), num(key?.write_mask), key ? str(key.preset) || "custom" : "read_only", key?.may_delete === true)
      return patch({ masks: redraft(f2, prev) })
    }
    case "rename":
      return void call("account.rename", { name: f.name ?? "" }, () => patch({ open: "" }))
    case "link":
      return void link(el.dataset.provider ?? "")
    case "link-email":
      return void link("email", f.email ?? "").then(() => patch({ open: "" }))
    case "unlink":
      return void call("account.identity.unlink", { id })
    case "mail-link": {
      if (!form) return
      const password = (f.app_password ?? "").replace(/\s/g, "")
      // The password leaves the field before the call: nothing on the page holds it once it is sent.
      const box = form.elements.namedItem("app_password") as HTMLInputElement | null
      if (box) box.value = ""
      return void linkMail((f.address ?? "").trim(), password)
    }
    case "mail-pipe":
      return void call("account.mail.pipe")
    case "mail-unlink":
      return void call("account.mail.unlink", {}, () => notice("ok", "Gmail unlinked: hireme stopped reading it and forgot the password."))
    case "session-revoke":
      return void call("account.session.revoke", { id })
    case "session-others":
      return void call("account.session.revoke_others")
    case "mint": {
      if (!form || v().minting) return
      const days = Number(f.expires_in_days)
      const params = { name: f.name ?? "", ...masksFrom(draft("mint", 0, 0, "read_only", false)), ...(days > 0 ? { expires_in_days: days } : {}) }
      patch({ minting: true })
      return void call("account.key.mint", params, (r) => {
        patch({ masks: null })
        reveal("account.key.mint", r)
      }).finally(() => patch({ minting: false }))
    }
    case "key-change": {
      if (!form) return
      const key = list("keys").find((k) => num(k.id) === id)
      const rename = key && str(key.name) !== f.name ? call("account.key.rename", { id, name: f.name ?? "" }) : Promise.resolve()
      const d = draft(`k${id}`, num(key?.read_mask), num(key?.write_mask), key ? str(key.preset) || "custom" : "custom", key?.may_delete === true)
      const g = grants(d)
      // Changing masks ends the agent's session (BYE grants) and its lease: only a real change does that.
      const changed = !key || g.read !== num(key.read_mask) || g.write !== num(key.write_mask) || d.mayDelete !== (key.may_delete === true)
      return void rename.then(() =>
        changed ? call("account.key.change", { id, ...masksFrom(d) }, () => patch({ open: "", masks: null })) : patch({ open: "", masks: null }))
    }
    case "key-resume":
      return void call("account.key.resume", { id })
    case "key-revoke":
      return void call("account.key.revoke", { id }, () => patch({ open: "" }))
    case "lease-revoke":
      return void call("account.lease.revoke", { id }, () => patch({ open: "" }))
    case "factor-remove":
      return void call("account.factor.remove", { id }, () => patch({ open: "" }))
    case "recovery":
      return void call("account.recovery.regenerate")
    case "totp-begin":
      return totpBegin()
    case "totp-cancel":
      return patch({ totp: null })
    case "totp-confirm":
      return void call("account.totp.confirm", { code: (f.code ?? "").replace(/\s/g, ""), name: f.name ?? "" }, (r) => {
        patch({ totp: null })
        reveal("account.totp.confirm", r)
      })
    case "passkey":
      return void enroll(f.name ?? "")
    case "host-add": {
      const before = form ? entries(form) : ""
      return void call("account.trusted_host.add", { host: (f.host ?? "").trim().toLowerCase(), ...(f.note ? { note: f.note } : {}) }, () => form && resetIfUnchanged(form, before))
    }
    case "host-remove":
      return void call("account.trusted_host.remove", { id })
    case "audit":
      return patch({ audit: { view: el.dataset.view === "activity" ? "activity" : "security", limit: 50 } })
    case "audit-more":
      return patch({ audit: { view: v().audit?.view ?? "security", limit: (v().audit?.limit ?? 50) + 50 } })
    case "step-passkey":
      return void (async () => {
        try {
          const { publicKey } = await rpc<{ publicKey: Record<string, unknown> }>("account.step_up.passkey_options")
          await stepped("account.step_up.passkey", await get(publicKey))
        } catch (e) {
          patch({ error: said(e) })
        }
      })()
    case "step-totp":
      return void stepped("account.step_up.totp", { code: (f.code ?? "").replace(/\s/g, "") })
    case "step-recovery":
      return void stepped("account.step_up.recovery", { code: (f.code ?? "").trim() })
    case "step-mail":
      return void rpc("account.step_up.mail").then(
        () => patch({ stepUp: v().stepUp && { ...v().stepUp!, mailed: true }, error: "" }),
        (e: unknown) => patch({ error: said(e) }),
      )
    case "step-mail-code":
      return void stepped("account.step_up.mail_code", { code: (f.code ?? "").replace(/\s/g, "") })
    case "step-cancel":
      resume = undefined
      return patch({ stepUp: null })
    case "copy":
      return void navigator.clipboard?.writeText(v().reveal?.lines.join("\n") ?? "").then(() => notice("ok", "Copied."))
    case "reveal-done":
      return patch({ reveal: null })
  }
}

function totpBegin(): void {
  void rpc<{ uri: string; secret: string; svg: string }>("account.totp.begin", {})
    .then((t) => patch({ totp: t, error: "" }))
    .catch((e: unknown) => (e instanceof Refused && e.code === "step_up" ? askStepUp(totpBegin) : patch({ error: said(e) })))
}

async function enroll(name: string): Promise<void> {
  try {
    const { publicKey } = await rpc<{ publicKey: Record<string, unknown> }>("account.passkey.begin", { name })
    const att = await create(publicKey)
    await call("account.passkey.finish", { name, ...att })
  } catch (e) {
    if (e instanceof Refused && e.code === "step_up") return askStepUp(() => enroll(name))
    patch({ error: said(e) })
  }
}

const view_: View = {
  title: "Account",
  view,
  enter() {
    const q = model.address.q
    const linked = q.get("linked")
    const failed = q.get("link_error")
    if (linked) notice("ok", `${linked} is linked.`)
    if (failed) notice("error", failed === "taken" ? MESSAGES.taken ?? "" : failed === "cap" ? "This account already has the most ways in it may hold (100)." : failed === "denied" ? "Linking was cancelled." : "Linking failed.")
    if (linked || failed) {
      query("linked", "")
      query("link_error", "")
    }
  },
  act,
}

export default view_

/** A user agent as a person names it ("Chrome on Linux"); the raw string stays in the row's title. */
function browserName(ua: string): string {
  if (ua === "") return "Unknown browser"
  const b = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\/|Chromium\//.test(ua) ? (/Headless/.test(ua) ? "Headless Chrome" : "Chrome")
    : /Safari\//.test(ua) ? "Safari" : /hireme-mcp/i.test(ua) ? "hireme-mcp" : "A browser"
  const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Mac OS X/.test(ua) ? "macOS" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : ""
  return os ? `${b} on ${os}` : b
}
