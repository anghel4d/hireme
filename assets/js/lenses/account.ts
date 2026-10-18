// The account lens: identities, factors, sessions, keys with masks, live
// leases with revoke, trusted hosts and the audit trail, all over
// `account.*` RPC on the wire session (lib/hireme_web/account.ex lists the
// methods). Linking a provider is the one HTTP step: it leaves the page.
//
// A change that needs a fresh session is refused `step_up`; the lens keeps
// the action, asks for a factor (passkey, TOTP or a recovery code), and
// retries it once the session is fresh. `account.watch` parks on the
// server and answers when anything audited changes, so a revoke made on
// another device redraws this lens without a reload.

import type { View } from "../app.ts"
import { create, get, supported, why } from "../auth/webauthn.ts"
import { Refused, rpc } from "../kernel.ts"
import { EMPTY, flag, html, trusted, type Html } from "../morph.ts"
import { model, notice, query, set, type AccountView } from "../state.ts"

type Row = Record<string, unknown>

const DOMAINS = ["world", "desk", "mail", "lanes", "corpus"] as const
const PRESETS = [
  ["read_only", "Read only"],
  ["write_only", "Write only"],
  ["read_write", "Read and write"],
  ["custom", "Custom"],
] as const

const v = (): AccountView => model.account
const patch = (p: Partial<AccountView>) => set({ account: { ...model.account, ...p } })
const list = (k: string): Row[] => (Array.isArray(v().overview?.[k]) ? (v().overview?.[k] as Row[]) : [])
const str = (x: unknown): string => (x === null || x === undefined ? "" : String(x))
const num = (x: unknown): number => (typeof x === "number" ? x : Number(x ?? 0))

function bits(): Record<string, number> {
  const d = v().overview?.domains as Record<string, number> | undefined
  return d ?? { world: 1, desk: 2, mail: 4, lanes: 8, corpus: 16 }
}

const maskNames = (mask: number): string => {
  const b = bits()
  const on = DOMAINS.filter((d) => (mask & (b[d] ?? 0)) !== 0)
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

// ------------------------------------------------------------------ calls

async function load(): Promise<void> {
  patch({ loading: true })
  try {
    patch({ overview: await rpc("account.overview"), loading: false, error: "" })
  } catch (e) {
    patch({ loading: false, error: e instanceof Error ? e.message : String(e) })
  }
}

let watching = false

/**
 * One parked watch at a time. It re-parks with the cursor of the overview it
 * last drew (the newest audit event id), so a change that lands between one
 * answer and the next park answers the next park at once instead of being
 * lost. A dropped carrier ends the loop; the shell's refresh after the
 * reconnect starts it again.
 */
async function watch(): Promise<void> {
  if (watching) return
  watching = true
  try {
    for (;;) {
      const since = v().overview?.cursor
      const r = await rpc<{ changed?: boolean }>("account.watch", typeof since === "number" ? { since } : {})
      if (r.changed) await load()
      if (model.address.lens !== "account") return
    }
  } catch {
    // The carrier dropped or the session ended: refresh() parks again once a session is back.
  } finally {
    watching = false
  }
}

const MESSAGES: Record<string, string> = {
  scope: "This session cannot do that.",
  not_found: "That no longer exists.",
  invalid: "That is not valid.",
  masks: "Pick a preset or at least one domain.",
  limit: "A limit was reached.",
  rate_limited: "Too many attempts; wait a little.",
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
}

/** Run an account method; a `step_up` refusal parks it until the session is fresh. */
async function call<T = Row>(method: string, params: Record<string, unknown> = {}, done?: (r: T) => void): Promise<void> {
  try {
    const r = await rpc<T>(method, params)
    patch({ error: "" })
    done?.(r)
    await load()
  } catch (e) {
    if (e instanceof Refused && e.code === "step_up") {
      patch({ stepUp: { method, params }, error: "" })
      return
    }
    const msg = e instanceof Refused ? MESSAGES[e.code] ?? e.message : e instanceof Error ? e.message : String(e)
    patch({ error: msg })
  }
}

async function stepped(method: string, params: Record<string, unknown>): Promise<void> {
  const waiting = v().stepUp
  try {
    await rpc(method, params)
  } catch (e) {
    patch({ error: e instanceof Refused ? MESSAGES[e.code] ?? e.message : why(e) })
    return
  }
  patch({ stepUp: null })
  // Linking a way in is HTTP, not an account.* method: it is retried as itself.
  if (waiting?.method === "link") await link(String(waiting.params.provider ?? ""), typeof waiting.params.email === "string" ? waiting.params.email : undefined)
  else if (waiting) await call(waiting.method, waiting.params, (r) => reveal(waiting.method, r as Row))
  else await load()
}

/** What a call returned that is shown once: a key's secret, recovery codes. */
function reveal(method: string, r: Row): void {
  if (method === "account.key.mint" && typeof r.secret === "string") {
    patch({ reveal: { title: "The new key. It is shown once; store it now.", lines: [r.secret] }, open: "" })
  } else if (Array.isArray(r.recovery_codes) && r.recovery_codes.length > 0) {
    patch({ reveal: { title: "Recovery codes. Each works once; they are shown once.", lines: r.recovery_codes.map(String) }, totp: null, open: "" })
  }
}

function fields(form: HTMLFormElement): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [k, val] of new FormData(form)) out[k] = String(val)
  return out
}

type Draft = NonNullable<AccountView["masks"]>

/** A preset's masks, as the server's overview states them. */
function presetMasks(preset: string): { read: number; write: number } {
  const p = (v().overview?.presets as Record<string, { read_mask?: number; write_mask?: number }> | undefined)?.[preset]
  return { read: num(p?.read_mask), write: num(p?.write_mask) }
}

/** The form's access: what was chosen in it, or what it opened with. */
function draft(form: string, read: number, write: number, preset: string, mayDelete: boolean): Draft {
  const d = v().masks
  return d && d.form === form ? d : { form, preset, read, write, mayDelete }
}

/** The masks a draft grants: a preset's own, or the custom checkboxes. */
function grants(d: Draft): { read: number; write: number } {
  return d.preset === "custom" ? { read: d.read, write: d.write } : presetMasks(d.preset)
}

function masksFrom(d: Draft): Record<string, unknown> {
  if (d.preset !== "custom") return { preset: d.preset, may_delete: d.mayDelete }
  return { read_mask: d.read, write_mask: d.write, may_delete: d.mayDelete }
}

/** The form's controls, read back into its draft after any change. */
function redraft(form: HTMLFormElement, prev: Draft): Draft {
  const preset = (form.elements.namedItem("preset") as HTMLSelectElement | null)?.value ?? prev.preset
  const mayDelete = (form.elements.namedItem("may_delete") as HTMLInputElement | null)?.checked ?? prev.mayDelete
  if (preset !== "custom") return { ...prev, preset, mayDelete }
  // Turning to custom starts from what the previous preset granted.
  const start = prev.preset === "custom" ? null : presetMasks(prev.preset)
  const b = bits()
  let read = 0
  let write = 0
  for (const d of DOMAINS) {
    if (start ? (start.read & (b[d] ?? 0)) !== 0 : (form.elements.namedItem(`r_${d}`) as HTMLInputElement | null)?.checked) read |= b[d] ?? 0
    if (start ? (start.write & (b[d] ?? 0)) !== 0 : (form.elements.namedItem(`w_${d}`) as HTMLInputElement | null)?.checked) write |= b[d] ?? 0
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
  if (body.error === "step_up") return patch({ stepUp: { method: "link", params: { provider, ...(email ? { email } : {}) } } })
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
  const b = bits()
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
        <tr><th scope="row">read</th>${DOMAINS.map((x) => html`<td><input type="checkbox" name="r_${x}" aria-label="read ${x}"${flag("checked", (g.read & (b[x] ?? 0)) !== 0)}></td>`)}</tr>
        <tr><th scope="row">write</th>${DOMAINS.map((x) => html`<td><input type="checkbox" name="w_${x}" aria-label="write ${x}"${flag("checked", (g.write & (b[x] ?? 0)) !== 0)}></td>`)}</tr>
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
  return html`<section class="card step-up" role="dialog" aria-labelledby="step-up-h" data-key="step-up">
    <h2 id="step-up-h">Confirm it is you</h2>
    <p class="lede">That change needs a factor from the last few minutes.</p>
    ${passkey ? html`<button type="button" class="primary" data-act="step-passkey">Use a passkey</button>` : EMPTY}
    ${totp ? html`<form data-submit="step-totp" data-act="step-totp" class="row"><label>Authenticator code
      <input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9 ]{6,8}" required></label>
      <button class="primary">Confirm</button></form>` : EMPTY}
    <form data-submit="step-recovery" data-act="step-recovery" class="row"><label>Or a recovery code
      <input name="code" autocomplete="off" required></label><button>Use code</button></form>
    ${!passkey && !totp ? html`<p class="hint">No factor is enrolled, so a fresh sign-in counts: sign out and back in, then retry.</p>` : EMPTY}
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
  const left = num(v().overview?.recovery_codes_left)
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
    <p class="muted">${left} recovery code${left === 1 ? "" : "s"} left.
      ${confirmButton("recovery", "Make new codes", "recovery", {})}</p>
  </section>`
}

function sessions(): Html {
  const rows = list("sessions")
  return html`<section class="card" data-key="sessions"><h2>Sessions</h2>
    <ul class="rows">${rows.map((s) => html`<li data-key="s${num(s.id)}">
      <b>${s.current === true ? "This browser" : str(s.user_agent).slice(0, 80) || "Unknown browser"}</b>
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
    <table class="grid"><thead><tr><th scope="col">Name</th><th scope="col">Key</th><th scope="col">Reads</th><th scope="col">Writes</th><th scope="col">Used</th><th scope="col"></th></tr></thead>
    <tbody>${rows.map((k) => {
      const id = num(k.id)
      const live = k.live === true
      return html`<tr data-key="k${id}" class="${live ? "" : "dead"}">
        <td>${str(k.name)}</td><td><code>${str(k.display)}</code></td>
        <td>${maskNames(num(k.read_mask))}</td><td>${maskNames(num(k.write_mask))}${k.may_delete === true ? html` <span class="tag">delete</span>` : EMPTY}</td>
        <td>${str(k.last_used_at) === "" ? html`<span class="muted">never</span>` : time(k.last_used_at)}${str(k.revoked_at) !== "" ? html` <span class="tag">revoked</span>` : EMPTY}</td>
        <td class="actions">${live ? html`<button type="button" class="ghost" data-act="open" data-form="change:${id}">Change</button>
          ${confirmButton(`k${id}`, "Revoke", "key-revoke", { id })}` : EMPTY}</td></tr>
        ${open === `change:${id}` ? html`<tr data-key="k${id}-change"><td colspan="6">
          <form class="stack" data-submit="key-change" data-act="key-change" data-id="${id}">
            <label>Name <input name="name" value="${str(k.name)}" maxlength="100" required></label>
            ${maskPicker(`k${id}`, num(k.read_mask), num(k.write_mask), str(k.preset) || "custom", k.may_delete === true)}
            <p class="hint">Widening a key or allowing deletes needs a fresh factor. The agent's session restarts with the new masks.</p>
            <div class="row"><button class="primary">Save</button><button type="button" class="ghost" data-act="close">Cancel</button></div>
          </form></td></tr>` : EMPTY}`
    })}</tbody></table>
    ${open === "mint" ? html`<form class="stack" data-submit="mint" data-act="mint" data-key="mint">
        <label>Name <input name="name" required maxlength="100" placeholder="research agent"></label>
        ${maskPicker("mint", 0, 0, "read_only", false)}
        <label>Expires after <select name="expires_in_days"><option value="">never</option><option value="7">7 days</option><option value="30">30 days</option><option value="90">90 days</option><option value="365">a year</option></select></label>
        <div class="row"><button class="primary">Mint key</button><button type="button" class="ghost" data-act="close">Cancel</button></div>
      </form>` : html`<button type="button" class="primary" data-act="open" data-form="mint">Mint a key</button>`}
  </section>`
}

function leases(): Html {
  const rows = list("leases")
  return html`<section class="card" data-key="leases"><h2>Live leases</h2>
    ${rows.length === 0 ? html`<p class="hint">No agent holds the write channel.</p>` : EMPTY}
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

function audit(): Html {
  const rows = v().audit
  return html`<section class="card" data-key="audit"><h2>Audit</h2>
    ${rows === null ? html`<button type="button" data-act="audit">Show recent events</button>` : html`<table class="grid compact">
      <thead><tr><th scope="col">When</th><th scope="col">What</th><th scope="col">From</th></tr></thead>
      <tbody>${rows.map((e) => html`<tr data-key="e${num(e.id)}"><td>${time(e.inserted_at)}</td><td>${str(e.kind)}${e.key_id ? html` <span class="tag">key ${num(e.key_id)}</span>` : EMPTY}</td>
        <td class="muted">${str(e.ip)}</td></tr>`)}</tbody></table>`}
  </section>`
}

function view(): Html {
  const o = v().overview
  if (!o) return v().error !== "" ? html`<p class="error" role="alert">${v().error}</p>` : html`<p class="empty">Loading the account…</p>`
  const account = (o.account ?? {}) as Row
  const fresh = num(o.fresh_for)
  return html`<div class="account">
    <section class="card head" data-key="head">
      ${v().open === "rename" ? html`<form class="row" data-submit="rename" data-act="rename"><input name="name" value="${str(account.name)}" required maxlength="200" aria-label="Account name">
          <button class="primary">Save</button><button type="button" class="ghost" data-act="close">Cancel</button></form>`
        : html`<h1>${str(account.name) || "Account"} <button type="button" class="ghost" data-act="open" data-form="rename">Rename</button></h1>`}
      <p class="muted">${fresh > 0 ? `Confirmed for another ${Math.ceil(fresh / 60)} min.` : "Sensitive changes will ask for a factor."}</p>
    </section>
    ${v().error !== "" ? html`<p class="error" role="alert" data-key="err">${v().error}</p>` : EMPTY}
    ${stepUp()}${revealed()}${identities()}${factors()}${keys()}${leases()}${sessions()}${hosts()}${audit()}
  </div>`
}

// ------------------------------------------------------------------ actions

function act(name: string, el: HTMLElement, ev: Event): void {
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
    case "session-revoke":
      return void call("account.session.revoke", { id })
    case "session-others":
      return void call("account.session.revoke_others")
    case "mint": {
      if (!form) return
      const days = Number(f.expires_in_days)
      const params = { name: f.name ?? "", ...masksFrom(draft("mint", 0, 0, "read_only", false)), ...(days > 0 ? { expires_in_days: days } : {}) }
      return void call("account.key.mint", params, (r) => {
        patch({ masks: null })
        reveal("account.key.mint", r)
      })
    }
    case "key-change": {
      if (!form) return
      const key = list("keys").find((k) => num(k.id) === id)
      const rename = key && str(key.name) !== f.name ? call("account.key.rename", { id, name: f.name ?? "" }) : Promise.resolve()
      const d = draft(`k${id}`, num(key?.read_mask), num(key?.write_mask), key ? str(key.preset) || "custom" : "custom", key?.may_delete === true)
      return void rename.then(() => call("account.key.change", { id, ...masksFrom(d) }, () => patch({ open: "", masks: null })))
    }
    case "key-revoke":
      return void call("account.key.revoke", { id }, () => patch({ open: "" }))
    case "lease-revoke":
      return void call("account.lease.revoke", { id }, () => patch({ open: "" }))
    case "factor-remove":
      return void call("account.factor.remove", { id }, () => patch({ open: "" }))
    case "recovery":
      return void call("account.recovery.regenerate", {}, (r) => reveal("account.recovery.regenerate", r))
    case "totp-begin":
      return void rpc<{ uri: string; secret: string; svg: string }>("account.totp.begin", {})
        .then((t) => patch({ totp: t, error: "" }))
        .catch((e: unknown) => (e instanceof Refused && e.code === "step_up" ? patch({ stepUp: { method: "account.totp.begin", params: {} } }) : patch({ error: String(e) })))
    case "totp-cancel":
      return patch({ totp: null })
    case "totp-confirm":
      return void call("account.totp.confirm", { code: (f.code ?? "").replace(/\s/g, ""), name: f.name ?? "" }, (r) => {
        patch({ totp: null })
        reveal("account.totp.confirm", r)
      })
    case "passkey":
      return void enroll(f.name ?? "")
    case "host-add":
      return void call("account.trusted_host.add", { host: (f.host ?? "").trim().toLowerCase(), ...(f.note ? { note: f.note } : {}) }, () => form?.reset())
    case "host-remove":
      return void call("account.trusted_host.remove", { id })
    case "audit":
      return void rpc<{ events: Row[] }>("account.audit", { limit: 100 }).then((r) => patch({ audit: r.events })).catch((e: unknown) => patch({ error: String(e) }))
    case "step-passkey":
      return void (async () => {
        try {
          const { publicKey } = await rpc<{ publicKey: Record<string, unknown> }>("account.step_up.passkey_options")
          await stepped("account.step_up.passkey", await get(publicKey))
        } catch (e) {
          patch({ error: why(e) })
        }
      })()
    case "step-totp":
      return void stepped("account.step_up.totp", { code: (f.code ?? "").replace(/\s/g, "") })
    case "step-recovery":
      return void stepped("account.step_up.recovery", { code: (f.code ?? "").trim() })
    case "step-cancel":
      return patch({ stepUp: null })
    case "copy":
      return void navigator.clipboard?.writeText(v().reveal?.lines.join("\n") ?? "").then(() => notice("ok", "Copied."))
    case "reveal-done":
      return patch({ reveal: null })
  }
  void ev
}

async function enroll(name: string): Promise<void> {
  try {
    const { publicKey } = await rpc<{ publicKey: Record<string, unknown> }>("account.passkey.begin", { name })
    const att = await create(publicKey)
    await call("account.passkey.finish", { name, ...att }, (r) => reveal("account.passkey.finish", r))
  } catch (e) {
    if (e instanceof Refused && e.code === "step_up") return patch({ stepUp: { method: "account.passkey.begin", params: { name } } })
    patch({ error: e instanceof Refused ? MESSAGES[e.code] ?? e.message : why(e) })
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
    if (failed) notice("error", failed === "taken" ? MESSAGES.taken ?? "" : failed === "denied" ? "Linking was cancelled." : "Linking failed.")
    if (linked || failed) {
      query("linked", "")
      query("link_error", "")
    }
    // The first park waits for the first overview, so it carries that overview's cursor.
    void load().then(watch)
  },
  act,
  refresh() {
    // After a reconnect (or a write elsewhere) the watch may have ended with the old carrier.
    if (!watching) void load().then(watch)
  },
}

export default view_
