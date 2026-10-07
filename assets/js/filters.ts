// The board's filter: parsed once from the address, written back to it,
// and lowered to the kernel's integer arguments against the packet's
// tables. A value the tables do not know falls back to its default.

import type { Band, Tables } from "./packet.ts"
import type { Selection } from "./store.ts"

export type Pick<T> = { kind: "all" } | { kind: "one"; value: T }
const ALL: Pick<never> = { kind: "all" }

export interface Filters {
  q: string
  stage: Pick<string>
  profile: Pick<string>
  status: Pick<string>
  batch: Pick<string> | { kind: "leftover" }
  band: Pick<string>
  heat: Pick<string>
  minScore: number
}

export function fromParams(p: URLSearchParams, t: Tables): Filters {
  return {
    q: p.get("q") ?? "",
    stage: pick(p.get("stage"), t.stages.map((s) => s.key)),
    profile: pick(p.get("profile"), t.profiles.map((x) => x.slug)),
    status: p.get("status") === "all" ? ALL : one(p.get("status"), t.statuses, "open"),
    batch: p.get("batch") === "leftover" ? { kind: "leftover" } : pick(p.get("batch"), t.batches.map((b) => b.code)),
    band: pick(p.get("band"), t.bands.map((b) => b.key)),
    heat: pick(p.get("heat"), t.heat_states),
    minScore: clamp(Number.parseInt(p.get("min_score") ?? "0", 10)),
  }
}

export function toParams(f: Filters, p = new URLSearchParams()): URLSearchParams {
  if (f.q !== "") p.set("q", f.q); else p.delete("q")
  put(p, "stage", f.stage)
  put(p, "profile", f.profile)
  if (f.status.kind === "all") p.set("status", "all")
  else if (f.status.value !== "open") p.set("status", f.status.value)
  else p.delete("status")
  if (f.batch.kind === "leftover") p.set("batch", "leftover"); else put(p, "batch", f.batch)
  put(p, "band", f.band)
  put(p, "heat", f.heat)
  if (f.minScore > 0) p.set("min_score", String(f.minScore)); else p.delete("min_score")
  return p
}

export function lower(f: Filters, t: Tables): Selection {
  const wanted = f.band.kind === "one" ? f.band.value : null
  const band: Band | undefined = wanted === null ? undefined : t.bands.find((b) => b.key === wanted)
  return {
    min: f.minScore,
    lo: band ? band.min : 0,
    hi: band ? band.max : 100,
    stage: index(f.stage, t.stages.map((s) => s.key)),
    status: index(f.status, t.statuses),
    batch: f.batch.kind === "leftover" ? -2 : batchIndex(f.batch, t),
    profile: index(f.profile, t.profiles.map((x) => x.slug)),
    heat: index(f.heat, t.heat_states),
    q: f.q,
  }
}

export function value(p: Pick<string> | { kind: "leftover" }): string {
  return p.kind === "all" ? "all" : p.kind === "leftover" ? "leftover" : p.value
}

function pick(v: string | null, allowed: string[]): Pick<string> {
  return v && allowed.includes(v) ? { kind: "one", value: v } : ALL
}

function one(v: string | null, allowed: string[], fallback: string): Pick<string> {
  return { kind: "one", value: v && allowed.includes(v) ? v : fallback }
}

function put(p: URLSearchParams, key: string, pk: Pick<string>): void {
  if (pk.kind === "one") p.set(key, pk.value); else p.delete(key)
}

function index(pk: Pick<string>, list: string[]): number {
  if (pk.kind === "all") return -1
  const i = list.indexOf(pk.value)
  return i < 0 ? -1 : i
}

function batchIndex(pk: Pick<string>, t: Tables): number {
  if (pk.kind === "all") return -1
  const b = t.batches.find((x) => x.code === pk.value)
  return b ? b.ordinal + 1 : -1
}

function clamp(n: number): number {
  return Number.isFinite(n) ? Math.min(Math.max(n, 0), 100) : 0
}
