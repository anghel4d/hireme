// The board: its filter and its geometry.
//
// The filter is parsed once from the address, written back to it, and
// lowered to the kernel's integer arguments against the packet's tables;
// a value the tables do not know falls back to its default. The geometry
// is row-major card movement (h and l stay on the row, k and j stay on
// the column, the edge clamps) and the painted window; tile size is the
// CSS --card-* lengths.

import type { Band, Selection, Tables } from "./store.ts"

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

// ---- geometry ----

export type Dir = "h" | "j" | "k" | "l"

export interface Metrics { width: number; height: number; gap: number; inset: number }

const WIDTH_REM = 14.5
const HEIGHT_REM = 11.25
const GAP_REM = 0.5
const INSET_REM = 0.5

export function metrics(rem: number): Metrics {
  return { width: WIDTH_REM * rem, height: HEIGHT_REM * rem, gap: GAP_REM * rem, inset: INSET_REM * rem }
}

export function dirFromKey(key: string): Dir | null {
  switch (key) {
    case "h": case "ArrowLeft": return "h"
    case "j": case "ArrowDown": return "j"
    case "k": case "ArrowUp": return "k"
    case "l": case "ArrowRight": return "l"
    default: return null
  }
}

export function move(index: number, cols: number, count: number, dir: Dir): number {
  if (count <= 0) return 0
  const columns = Math.max(Math.trunc(cols), 1)
  const i = Math.min(Math.max(index, 0), count - 1)
  const row = Math.floor(i / columns)
  const col = i % columns
  let nr = row, nc = col
  switch (dir) {
    case "h": nc = col - 1; break
    case "l": nc = col + 1; break
    case "k": nr = row - 1; break
    case "j": nr = row + 1; break
  }
  if (nr < 0 || nc < 0 || nc >= columns) return i
  const next = nr * columns + nc
  return next < 0 || next >= count ? i : next
}

export function columns(containerWidth: number, m: Metrics): number {
  if (containerWidth <= 0) return 1
  const inner = containerWidth - m.inset * 2
  return Math.max(Math.trunc((inner + m.gap) / (m.width + m.gap)), 1)
}

/** Inclusive index range of the painted window, or [-1, -1]. */
export function slice(count: number, cols: number, scrollTop: number, viewport: number, m: Metrics, overscan = 2): [number, number] {
  if (count <= 0) return [-1, -1]
  const c = Math.max(Math.trunc(cols), 1)
  const stride = m.height + m.gap
  const scrolled = Math.max(scrollTop - m.inset, 0)
  const firstRow = Math.max(Math.trunc(scrolled / stride) - overscan, 0)
  const visibleRows = Math.max(Math.ceil(Math.max(viewport, 1) / stride), 1) + overscan * 2
  const start = firstRow * c
  const last = Math.min(count - 1, start + visibleRows * c - 1)
  return start > last ? [-1, -1] : [start, last]
}

export function origin(index: number, cols: number, m: Metrics): [number, number] {
  const c = Math.max(Math.trunc(cols), 1)
  return [m.inset + (index % c) * (m.width + m.gap), m.inset + Math.floor(index / c) * (m.height + m.gap)]
}

export function contentHeight(count: number, cols: number, m: Metrics): number {
  if (count <= 0) return 0
  const c = Math.max(Math.trunc(cols), 1)
  const rows = Math.ceil(count / c)
  return m.inset * 2 + rows * m.height + (rows - 1) * m.gap
}

/** Scroll offset keeping `index` in view; unchanged when already visible. */
export function scrollTo(index: number, cols: number, scrollTop: number, viewport: number, m: Metrics): number {
  const c = Math.max(Math.trunc(cols), 1)
  const y = m.inset + Math.floor(Math.max(index, 0) / c) * (m.height + m.gap)
  const bottom = y + m.height
  if (y < scrollTop) return y
  if (bottom > scrollTop + viewport) return Math.max(bottom - viewport, 0)
  return scrollTop
}
