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
  canonical_title: string
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
  listing_url: string
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
  reason: string
  company_load: number
  company_cap: number
  size: string | null
  ats_vendor: string
  cooldown_days: number | null
  note: string
  override: boolean
  override_reason: string
}

export interface Focus {
  job: Job
  profile: { id: number; slug: string; name: string; headline: string; summary: string }
  variant: { id: number; label: string }
  rail: Rung[]
  events: { id: number; kind: string; body: string }[]
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
    recent: { id: number; done_on: string; outcome: string; minutes: number; note: string; title: string; url: string; platform: string; topic: string; difficulty: string }[]
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

async function get<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: { accept: "application/json" } })
  gone(res)
  if (!res.ok) throw new Error(`${url}: ${res.status}`)
  return (await res.json()) as T
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

export const fetchSettings = () => get<Settings>("/api/account")
export const createKey = (name: string, expires_in_days: number | null) =>
  post<SettingsReply>("/api/account/keys", { name, expires_in_days })
export const renameKey = (id: number, name: string) => send<SettingsReply>("PATCH", `/api/account/keys/${id}`, { name })
export const revokeKey = (id: number) => send<SettingsReply>("DELETE", `/api/account/keys/${id}`, {})
export const revokeSession = (id: number) => send<SettingsReply & { signed_out?: boolean }>("DELETE", `/api/account/sessions/${id}`, {})
export const revokeOtherSessions = () => post<SettingsReply>("/api/account/sessions/revoke_others", {})

// Ways in. An address is added by a mailed link opened in this browser; GitHub and X answer with the URL to go to.
export const linkEmail = (email: string) => post<SettingsReply>("/api/account/identities", { provider: "email", email })
export const linkProvider = (provider: string) => post<{ ok: true; url: string }>("/api/account/identities", { provider })
export const unlinkIdentity = (id: number) => send<SettingsReply>("DELETE", `/api/account/identities/${id}`, {})

// Second factors. A reply may carry `recovery_codes`, shown exactly once.
export type SecurityReply = Security & { ok: true; recovery_codes?: string[] }
export interface TotpStart { uri: string; secret: string; svg: string }
export const beginTotp = () => post<TotpStart>("/api/account/mfa/totp", {})
export const confirmTotp = (code: string, name: string) => post<SecurityReply>("/api/account/mfa/totp/confirm", { code, name })
export const beginWebauthn = () => post<Record<string, unknown>>("/api/account/mfa/webauthn", {})
export const confirmWebauthn = (credential: Record<string, unknown>, name: string) =>
  post<SecurityReply>("/api/account/mfa/webauthn/confirm", { ...credential, name })
export const removeMethod = (id: number) => send<SecurityReply>("DELETE", `/api/account/mfa/${id}`, {})
export const newRecoveryCodes = () => post<SecurityReply>("/api/account/mfa/recovery", {})
export const stepUpTotp = (code: string) => post<{ ok: true }>("/api/account/step-up/totp", { code })
export const stepUpRecovery = (code: string) => post<{ ok: true }>("/api/account/step-up/recovery", { code })
export const stepUpWebauthn = () => post<Record<string, unknown>>("/api/account/step-up/webauthn", {})
export const stepUpWebauthnConfirm = (assertion: Record<string, unknown>) =>
  post<{ ok: true }>("/api/account/step-up/webauthn/confirm", assertion)
