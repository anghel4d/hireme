// Reads of what is opened and the human's writes. Every refusal is a
// typed outcome, not a thrown string.

import { parsePacket, type Packet } from "./packet.ts"

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

async function get<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: { accept: "application/json" } })
  if (!res.ok) throw new Error(`${url}: ${res.status}`)
  return (await res.json()) as T
}

async function post<T>(url: string, body: unknown): Promise<Outcome<T>> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(body),
  })
  const data = (await res.json().catch(() => ({}))) as Record<string, unknown>
  if (res.ok) return { ok: true, value: data as T }
  return { ok: false, status: res.status, error: typeof data["error"] === "string" ? data["error"] : `http ${res.status}` }
}

export async function fetchPacket(): Promise<Packet> {
  const res = await fetch("/api/pack", { cache: "no-store" })
  if (!res.ok) throw new Error(`pack: ${res.status}`)
  return parsePacket(await res.arrayBuffer())
}

export const fetchFocus = (id: number) => get<Focus>(`/api/focus/${id}`)
export const fetchRoot = (profileId: number) => get<Root>(`/api/root/${profileId}`)
export const fetchScoreboard = () => get<Scoreboard>("/api/scoreboard")

type FocusReply = { ok: true; focus: Focus }

export const setStage = (id: number, stage: string) => post<FocusReply>(`/api/jobs/${id}/stage`, { stage })
export const setNext = (id: number, next_action: string, next_due: string) =>
  post<FocusReply>(`/api/jobs/${id}/next`, { next_action, next_due })
export const setNote = (id: number, stage: string, note: string) => post<FocusReply>(`/api/jobs/${id}/note`, { stage, note })
export const putOverlay = (id: number, item_id: number, mode: string, body?: string, reason?: string) =>
  post<FocusReply>(`/api/jobs/${id}/overlay`, { item_id, mode, body, reason })
export const nameOpenFire = (code: string) => post<{ ok: true }>(`/api/batches/${encodeURIComponent(code)}/open_fire`, {})
export const saveNarrative = (id: number, body: string) =>
  post<{ ok: true; narrative: Narrative }>(`/api/narratives/${id}`, { body })
export const heatOverride = (id: number, reason: string) => post<FocusReply>(`/api/jobs/${id}/heat_override`, { reason })

export const fetchLanes = () => get<Lanes>("/api/lanes")
type LanesReply = Lanes & { ok: true }
export const gymLog = (fields: Record<string, string>) => post<LanesReply>("/api/gym/log", fields)
export const gymTarget = (target: string) => post<LanesReply>("/api/gym/target", { target })
export const netLog = (fields: Record<string, string>) => post<LanesReply>("/api/net/log", fields)
export const netLane = (url: string) => post<LanesReply>("/api/net/lane", { url })
