// The shapes the desk's documents take, and the HTTP routes that remain:
// the account, its keys and sessions, and its second factors. Those are
// security ceremonies, not hot paths; the desk itself rides the wire.
// Every refusal is a typed outcome, not a thrown string.


export type Mode = "canonical" | "hidden" | "altered" | "emphasized"

export interface Line {
  id: number
  kind: string
  title: string
  body: string
  org: string
  span: string
  shown: boolean
  mode: Mode
  reason: string | null
  canonical_body: string
}

export interface Doc {
  label: string
  person: string | null
  headline: string | null
  summary: string | null
  summary_canonical: string | null
  summary_reason: string | null
  accent: string
  density: string
  facts: Line[]
  sections: { kind: string; label: string; lines: Line[] }[]
  hidden: Line[]
}

export interface Job {
  id: number
  code: string
  company: string
  role: string
  location: string
  listing: string
  heat: number
  status: string
  stage: string
  stage_label: string
  stage_hint: string
  pips: string
  score_100: number
  band: string
  next_action: string
  next_due: string | null
  stage_on: string | null
  freshness: string
  gate: string
  fit: string
  keyword_hits: number
  keyword_total: number
  mask_hidden: number
  mask_altered: number
  mask_emphasized: number
  batch: { code: string; fire: "hold" | "open_fire" } | null
}

export interface Rung { key: string; label: string; hint: string; state: string; note: string }
export interface Narrative { id: number; body: string; version: number }
export interface Coverage { hits: string[]; misses: string[] }

export interface HeatVerdict {
  decision: "allow" | "defer"
  company_load: number
  company_cap: number
  size: string | null
  ats_vendor: string
  cooldown_days: number | null
  override: boolean
  override_reason: string
}

export interface Focus {
  job: Job
  profile: { id: number; slug: string; name: string; headline: string; summary: string }
  variant: { id: number; label: string; lineage_id: number | null }
  rail: Rung[]
  events: { id: number; kind: string; body: string; at: string }[]
  cv: Doc
  narrative: Narrative | null
  coverage: Coverage
  root_coverage: Coverage
  kv: { key: string; value: string }[]
  masks: Line[]
  heat: HeatVerdict
}

export interface Option { key: string; label: string }
export interface HeatRow { key: string; label: string; load: number; cap: number; ratio: number; n: number; cooldown_days: number | null }

export interface Lanes {
  gym: {
    target: number
    streak: number
    solved_today: number
    solved_week: number
    score: number
    topics: { key: string; label: string; count: number }[]
    recent: { id: number; done_on: string; outcome: string; minutes: number; note: string; slug: string; title: string; url: string; platform: string; topic: string; difficulty: string }[]
    platforms: Option[]
    topics_all: Option[]
    difficulties: Option[]
    outcomes: Option[]
  }
  net: {
    lane: string
    shipped_week: number
    drafts: number
    observer_runs: number
    recent: { id: number; kind: string; channel: string; title: string; url: string; body: string; shipped_on: string | null }[]
    kinds: Option[]
    channels: Option[]
  }
  heat: { companies: HeatRow[]; vendors: HeatRow[] }
}

export interface Root {
  profile: Focus["profile"]
  cv: Doc
  kv: { key: string; value: string }[]
  narrative: Narrative | null
}

export interface Scoreboard {
  fire: "hold" | "open_fire"
  leftover_unique: number
  leftover_noted_on: string | null
  batches_today: number
  batches_target: number
  apps_today: number
  apps_target: number
  submitted_today: number
  cumulative: number
  varieties: { code: string; fire: string; status: string; label: string }[]
  chart: {
    n: number
    mean: number | null
    bands: { key: string; label: string; min: number; max: number; count: number }[]
    bins: { lo: number; hi: number; count: number }[]
  }
}

export type Outcome<T> = { ok: true; value: T } | { ok: false; status: number; error: string }

/** The CSRF token the page was served with; every write sends it back. */
export function csrf(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

// A session that has ended answers 401; the only thing to do is sign in again.
function gone(res: Response): void {
  if (res.status === 401) location.assign("/sign-in")
}

async function send<T>(method: "POST" | "PATCH" | "DELETE", url: string, body: unknown): Promise<Outcome<T>> {
  const res = await fetch(url, {
    method,
    headers: { "content-type": "application/json", accept: "application/json", "x-csrf-token": csrf() },
    body: JSON.stringify(body),
  })
  gone(res)
  const data = (await res.json().catch(() => ({}))) as Record<string, unknown>
  if (res.ok) return { ok: true, value: data as T }
  return { ok: false, status: res.status, error: typeof data["error"] === "string" ? data["error"] : `http ${res.status}` }
}

const post = <T,>(url: string, body: unknown) => send<T>("POST", url, body)

// The account: its API keys and its sessions.

export interface Key {
  id: number
  key_id: string
  name: string
  display: string
  scope: string
  created_at: string
  last_used_at: string | null
  expires_at: string | null
  revoked_at: string | null
  live: boolean
}

export interface Session {
  id: number
  current: boolean
  authenticated_at: string
  last_seen_at: string
  expires_at: string
  mfa_at: string | null
  ip: string
  user_agent: string
}

export interface Method {
  id: number
  kind: "totp" | "webauthn"
  name: string
  created_at: string
  last_used_at: string | null
  backed_up: boolean
  transports: string[]
}

export interface Security { methods: Method[]; recovery_codes_left: number; fresh: boolean }

/** One way into the account. A provider's user id stays on the server; `display` is the handle or address. */
export interface Identity { id: number; provider: "email" | "github" | "x"; display: string; created_at: string }

export interface Settings {
  account: { id: number; name: string }
  keys: Key[]
  sessions: Session[]
  security: Security
  identities: Identity[]
  /** The ways in this desk offers; GitHub and X only when configured. */
  sign_in_methods: Identity["provider"][]
}

/** After a create, `secret` is the whole key, shown exactly once; after asking to add an address, `sent_to` is it. */
export type SettingsReply = Settings & { ok: true; created?: Key; secret?: string; sent_to?: string }

// The account's commands ride the wire session; its data arrives as
// tables the desk reads (`desk.account()`), and a write's tables come
// before its reply, so a reply is that document plus what the command
// returned. What sets the cookie stays HTTP: linking a new way in.

/** What the account commands need from the wire: a command, and the document as the desk holds it. */
export interface AccountLink {
  call(method: string, params?: Record<string, unknown>): Promise<{ result: Record<string, unknown> } | { error: { code: number; message: string } }>
  settings(): Settings | null
  /** The document once the first tables arrive. */
  ready(): Promise<Settings>
}

let link: AccountLink | null = null

export function useAccountLink(l: AccountLink): void {
  link = l
}

async function command<T>(method: string, params: Record<string, unknown>, shape: (s: Settings | null, result: Record<string, unknown>) => T): Promise<Outcome<T>> {
  if (!link) return { ok: false, status: 0, error: "offline" }
  const r = await link.call(`account/${method}`, params)
  if ("error" in r) return { ok: false, status: r.error.code, error: r.error.message }
  return { ok: true, value: shape(link.settings(), r.result) }
}

const settingsReply = <T,>(s: Settings | null, result: Record<string, unknown>) => ({ ...s, ...result, ok: true }) as T
const securityReply = <T,>(s: Settings | null, result: Record<string, unknown>) => ({ ...s?.security, ...result, ok: true }) as T
const bare = <T,>(_s: Settings | null, result: Record<string, unknown>) => result as T

export const fetchSettings = (): Promise<Settings> => (link ? link.ready() : Promise.reject(new Error("offline")))
export const createKey = (name: string, expires_in_days: number | null) =>
  command<SettingsReply>("create_key", { name, expires_in_days }, settingsReply)
export const renameKey = (id: number, name: string) => command<SettingsReply>("rename_key", { id, name }, settingsReply)
export const revokeKey = (id: number) => command<SettingsReply>("revoke_key", { id }, settingsReply)
export const revokeSession = (id: number) => command<SettingsReply & { signed_out?: boolean }>("revoke_session", { id }, settingsReply)
export const revokeOtherSessions = () => command<SettingsReply>("revoke_other_sessions", {}, settingsReply)

// Ways in. An address is added by a mailed link opened in this browser; GitHub and X answer with the URL to go to.
// Both keep their trip in the cookie, so they stay HTTP.
export async function linkEmail(email: string): Promise<Outcome<SettingsReply>> {
  const r = await post<Record<string, unknown>>("/api/account/identities", { provider: "email", email })
  return r.ok ? { ok: true, value: settingsReply<SettingsReply>(link?.settings() ?? null, r.value) } : r
}
export const linkProvider = (provider: string) => post<{ ok: true; url: string }>("/api/account/identities", { provider })
export const unlinkIdentity = (id: number) => command<SettingsReply>("unlink", { id }, settingsReply)

// Second factors. A reply may carry `recovery_codes`, shown exactly once.
export type SecurityReply = Security & { ok: true; recovery_codes?: string[] }
export interface TotpStart { uri: string; secret: string; svg: string }
export const beginTotp = () => command<TotpStart>("begin_totp", {}, bare)
export const confirmTotp = (code: string, name: string) => command<SecurityReply>("confirm_totp", { code, name }, securityReply)
export const beginWebauthn = () => command<Record<string, unknown>>("begin_webauthn", {}, bare)
export const confirmWebauthn = (credential: Record<string, unknown>, name: string) =>
  command<SecurityReply>("confirm_webauthn", { ...credential, name }, securityReply)
export const removeMethod = (id: number) => command<SecurityReply>("remove_factor", { id }, securityReply)
export const newRecoveryCodes = () => command<SecurityReply>("recovery_codes", {}, securityReply)
export const stepUpTotp = (code: string) => command<{ ok: true }>("step_up_totp", { code }, bare)
export const stepUpRecovery = (code: string) => command<{ ok: true }>("step_up_recovery", { code }, bare)
export const stepUpWebauthn = () => command<Record<string, unknown>>("step_up_webauthn", {}, bare)
export const stepUpWebauthnConfirm = (assertion: Record<string, unknown>) => command<{ ok: true }>("step_up_webauthn_confirm", assertion, bare)
