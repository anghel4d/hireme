// The desk the shell reads. View = base ⊕ pending: the base is what the
// server last said, the pending layer is this tab's ops not yet folded
// into it. Every read is synchronous; nothing here returns a Promise.
//
// The account's raw rows live in the kernel (WebAssembly): every frame is
// copied into it once, it applies this tab's pending ops to the rows, and
// it derives the board from them: card columns, heat, order, verdicts,
// the heat chart and the scoreboard. Because a prediction lands on the
// raw rows, every derived field is exact at once; nothing "settles". An
// ACK retires the op (its PATCH came first); a NACK drops it, and the
// view is the base again, so rollback is free.
//
// The documents a person opens (a focus, a root CV, the lanes) are
// composed by the kernel too, as JSON, when first read, and kept until a
// row they read changes; the account page is read from its own tables.

import type { Focus, Identity, Key, Lanes, Method, Root, Scoreboard, Session, Settings } from "./api.ts"
import { FLAG, HEADER, KIND, NONE, opFrame, type Bytes, type Host } from "./wire.ts"

// ---- the lookups the card columns index into ----

export interface Stage { key: string; label: string; hint: string }
export interface Band { key: string; label: string; min: number; max: number }
export interface Batch { id: number; code: string; ordinal: number; fire: "hold" | "open_fire"; status: string }
export interface Profile { id: number; slug: string; name: string }

export interface Tables {
  stages: Stage[]
  statuses: string[]
  freshness: string[]
  gates: string[]
  bands: Band[]
  batches: Batch[]
  profiles: Profile[]
  heat_states: string[]
}

// ---- the interface the shell draws from ----

export interface Selection {
  readonly min: number
  readonly lo: number
  readonly hi: number
  readonly stage: number
  readonly status: number
  readonly batch: number
  readonly profile: number
  readonly heat: number
  readonly q: string
}

export type Status = "connecting" | "webtransport" | "websocket" | "offline"
export type Refusal = "fire_hold" | "heat" | "cooldown" | "leased" | "not_additive" | "invalid" | string
export type Run = { ok: true; opId: bigint; jobId: number | null } | { ok: false; refusal: Refusal }
export type Mark = "pending" | null

export type Op =
  | { kind: "stage"; job: number; stage: string }
  | { kind: "next"; job: number; next_action: string; next_due: string }
  | { kind: "note"; job: number; stage: string; note: string }
  | { kind: "score"; job: number; score: number }
  | { kind: "overlay"; job: number; item: number; mode: "hidden" | "emphasized" | "altered" | "inherit"; body?: string; reason?: string }
  | { kind: "heat_override"; job: number; reason: string }
  | { kind: "open_fire"; batch: string }
  | { kind: "narrative"; job: number | null; narrative: number; body: string }
  | { kind: "gym_log"; fields: Record<string, string> }
  | { kind: "gym_target"; target: string }
  | { kind: "net_log"; fields: Record<string, string> }
  | { kind: "net_lane"; url: string }

export interface Change {
  /** Any card column or the board changed. */
  rows?: boolean
  /** Job ids whose focus changed, or every focus. */
  focus?: readonly number[] | "all"
  root?: boolean
  scoreboard?: boolean
  lanes?: boolean
  status?: boolean
  /** The account page's tables changed. */
  account?: boolean
  /** The server accepted this op. */
  acked?: bigint
  /** The server refused this op; it is already rolled back. */
  refused?: { opId: bigint; jobId: number | null; op: Op; refusal: Refusal; message: string }
}

export interface StrColumn { at(row: number): string }

export interface Desk {
  readonly tables: Tables
  readonly n: number
  select(s: Selection): number
  /** Row indices of the last selection, in board order. */
  selection(): Uint32Array
  /** Position of a job id within the selection, or -1. */
  find(id: number): number
  column(name: string): Uint32Array
  str(name: string): StrColumn
  /** Row index of a job id, or -1. */
  rowOf(id: number): number

  /** A job's focus, composed from its rows with pending ops applied; null before the first BOOT. */
  focus(id: number): Focus | null
  root(profileId: number): Root | null
  scoreboard(): Scoreboard | null
  lanes(): Lanes | null
  /** The Account page, once its tables have arrived. */
  account(): Settings | null

  /** Apply locally in this tick and send. A predicted refusal applies nothing. */
  run(op: Op): Run
  mark(jobId: number): Mark
  readonly status: Status
  subscribe(fn: (c: Change) => void): () => void
}

/** What carries ops up. */
export interface Link {
  send(p: Pending): void
}

const DECODER = new TextDecoder()
const ENCODER = new TextEncoder()

// ---- the kernel ----

export interface WireKernel {
  memory: WebAssembly.Memory
  schema_hash(): number
  scratch(len: number): number
  table_id(len: number): number
  col_id(table: number, len: number): number
  ingest_reserve(len: number): number
  ingest_commit(len: number): number
  rows(table: number): number
  col_ptr(table: number, col: number): number
  arena_ptr(): number
  epoch(): number
  row_of(table: number, key: number): number
  select(min: number, lo: number, hi: number, stage: number, status: number, batch: number, profile: number, heat: number, qlen: number): number
  selection_ptr(): number
  find(id: number): number
  pending_push(len: number): number
  pending_count(): number
  focus_json(job: number): number
  root_json(profile: number): number
  lanes_json(): number
  result_ptr(): number
  touched_len(): number
  touched_ptr(): number
  derive(): number
  counter(k: number): number
  set_today(day: number): void
  snapshot(): number
  snapshot_ptr(): number
  rev_lo(): number
  rev_hi(): number
}

/** What an ingest changed, as the kernel answers it. */
export const INGEST = { cards: 1, tables: 2, settled: 16, dropped: 32, tick: 64, error: 1 << 30 } as const

/** Refusal codes from schema.txt. */
const REFUSAL = ["", "fire_hold", "heat", "leased", "cooldown", "not_additive", "argument", "not_found", "batch", "invalid", "internal"]
export const refusalName = (code: number): Refusal => REFUSAL[code] ?? "internal"

type Kind = "u32" | "f64" | "str" | "day" | "time" | "secs?" | "bool"
type Spec = Record<string, readonly [string, Kind]>
type Cell = number | string | boolean | null

const NAN_SAFE = (x: number) => (Number.isNaN(x) ? 0 : x)
const days = new Map<number, string>()
const isoDay = (day: number) => {
  let s = days.get(day)
  if (s === undefined) {
    s = new Date(day * 86_400_000).toISOString().slice(0, 10)
    days.set(day, s)
  }
  return s
}
const stamp = (secs: number) => new Date(secs * 1000).toISOString().replace(".000Z", "Z")

/**
 * The kernel through its exports. Tables and columns are found by the
 * names schema.txt gives them, once; rows are read in place and decoded
 * into plain objects. A table read whole (the lookups, the scoreboard,
 * the account: small ones) is kept until an ingest or push touches it.
 */
export class Kernel {
  private readonly ids = new Map<string, number>()
  private readonly kept = new Map<number, unknown[]>()
  /** Strings by their arena offset: an interned value is decoded once, until a compaction moves the arena. */
  private readonly decoded = new Map<number, string>()
  private epoch = -1
  private words = new Uint32Array(0)
  private count = 0
  private trapped = false
  /** The exports, guarded: a trap marks the instance dead, and a dead one answers as an empty desk. */
  k: WireKernel

  constructor(source: WireKernel, private readonly onTrap: (cause: unknown) => void) {
    this.k = this.guard(source)
  }

  /**
   * A plain object of the instance's exports, each wrapped once in a try:
   * no proxy and no lookup on the hot path, where the string and column
   * reads call into the kernel per cell.
   */
  private guard(live: WireKernel): WireKernel {
    const out: Record<string, unknown> = { memory: live.memory }
    for (const [name, value] of Object.entries(live as unknown as Record<string, unknown>)) {
      if (typeof value !== "function") continue
      const fn = value as (a?: number, b?: number, c?: number, d?: number, e?: number, f?: number, g?: number, h?: number, i?: number, j?: number) => number
      const empty = name === "row_of" || name === "find" || name === "table_id" || name === "col_id" ? -1 : 0
      out[name] = (a?: number, b?: number, c?: number, d?: number, e?: number, f?: number, g?: number, h?: number, i?: number, j?: number) => {
        if (this.trapped) return empty
        try {
          return fn(a, b, c, d, e, f, g, h, i, j)
        } catch (cause) {
          if (!(cause instanceof WebAssembly.RuntimeError)) throw cause
          this.trapped = true
          this.onTrap(cause)
          return empty
        }
      }
    }
    return out as unknown as WireKernel
  }

  /** A fresh instance in place of a trapped one: nothing decoded from the old one is kept. */
  swap(fresh: WireKernel): void {
    this.k = this.guard(fresh)
    this.trapped = false
    this.ids.clear()
    this.kept.clear()
    this.decoded.clear()
    this.count = 0
  }

  get mem(): ArrayBuffer { return this.k.memory.buffer }
  get rev(): bigint { return (BigInt(this.k.rev_hi() >>> 0) << 32n) | BigInt(this.k.rev_lo() >>> 0) }

  /** Bytes into kernel memory through one of its reserve calls; memory may grow, so view it after. */
  put(reserve: (len: number) => number, bytes: Uint8Array): number {
    const at = reserve(bytes.byteLength)
    new Uint8Array(this.mem, at, bytes.byteLength).set(bytes)
    return bytes.byteLength
  }

  table(name: string): number {
    let id = this.ids.get(name)
    if (id === undefined) {
      id = this.k.table_id(this.put((n) => this.k.scratch(n), ENCODER.encode(name)))
      this.ids.set(name, id)
    }
    return id
  }

  col(table: number, name: string): number {
    const key = `${table}.${name}`
    let id = this.ids.get(key)
    if (id === undefined) {
      id = this.k.col_id(table, this.put((n) => this.k.scratch(n), ENCODER.encode(name)))
      this.ids.set(key, id)
    }
    return id
  }

  /** Row `row` of a string column: its (offset, len) in the column, its text from the cache or the arena. */
  str(t: number, c: number, row: number): string {
    const p = c < 0 ? 0 : this.k.col_ptr(t, c)
    if (p === 0) return ""
    if (this.words.buffer !== this.mem) this.words = new Uint32Array(this.mem)
    const at = (p >>> 2) + 2 * row
    const off = this.words[at] ?? 0
    const len = this.words[at + 1] ?? 0
    if (len === 0) return ""
    let s = this.decoded.get(off)
    if (s === undefined) this.decoded.set(off, (s = DECODER.decode(new Uint8Array(this.mem, this.k.arena_ptr() + off, len))))
    return s
  }

  /** A u32 column of a table, in row order; empty when the table has no such column. */
  u32(t: number, c: number): Uint32Array {
    const n = this.k.rows(t)
    const p = c < 0 ? 0 : this.k.col_ptr(t, c)
    return p === 0 ? new Uint32Array(n).fill(NONE) : new Uint32Array(this.mem, p, n)
  }

  /** Copy whole frames into the kernel's ring and ingest them: the one copy on the way in. */
  ingest(frames: Uint8Array): number {
    return this.k.ingest_commit(this.put((n) => this.k.ingest_reserve(n), frames))
  }

  /**
   * What the last ingest or push touched: each table with the keys of the
   * rows it moved (null: the whole table), and the job rows among them.
   * Null: everything (a BOOT).
   */
  touched(): { tables: Map<number, Set<number> | null> | null; jobs: number[] | "all" } {
    // The derived views follow the rows lazily: derive now, so the rows
    // that moved with them are listed too, and read fresh.
    this.k.derive()
    const epoch = this.k.epoch()
    if (epoch !== this.epoch) {
      this.epoch = epoch
      this.decoded.clear()
    }
    const n = this.k.touched_len()
    const pairs = new Uint32Array(this.mem, this.k.touched_ptr(), n * 2)
    const jobTable = this.table("job_apps")
    const tables = new Map<number, Set<number> | null>()
    for (let i = 0; i < n; i++) {
      const t = pairs[2 * i] ?? NONE
      const key = pairs[2 * i + 1] ?? NONE
      if (t === NONE) return { tables: null, jobs: "all" }
      const keys = tables.get(t)
      if (key === NONE) tables.set(t, null)
      else if (keys) keys.add(key)
      else if (keys === undefined) tables.set(t, new Set([key]))
    }
    const jobs = tables.get(jobTable)
    return { tables, jobs: jobs === null ? "all" : [...(jobs ?? [])] }
  }

  /** Drop the decoded rows of what moved (null: everything). */
  forget(tables: ReadonlyMap<number, unknown> | null): void {
    if (tables === null) this.kept.clear()
    else for (const t of tables.keys()) this.kept.delete(t)
  }

  /** Every row of a named table, decoded once and kept until it moves. */
  all<T>(name: string, spec: Spec): T[] {
    const t = this.table(name)
    if (t < 0) return []
    let rows = this.kept.get(t)
    if (!rows) this.kept.set(t, (rows = this.read(t, spec)))
    return rows as T[]
  }

  private read<T>(t: number, spec: Spec): T[] {
    const n = this.k.rows(t)
    const out: Record<string, Cell>[] = Array.from({ length: n }, () => ({}))
    for (const [field, [name, kind]] of Object.entries(spec)) {
      const c = this.col(t, name)
      if (kind === "str") {
        for (let i = 0; i < n; i++) (out[i] as Record<string, Cell>)[field] = c < 0 ? "" : this.str(t, c, i)
        continue
      }
      if (kind === "f64") {
        const p = c < 0 ? 0 : this.k.col_ptr(t, c)
        const col = p === 0 ? null : new Float64Array(this.mem, p, n)
        for (let i = 0; i < n; i++) (out[i] as Record<string, Cell>)[field] = NAN_SAFE(col?.[i] ?? 0)
        continue
      }
      const col = this.u32(t, c)
      for (let i = 0; i < n; i++) {
        const v = col[i] ?? NONE
        ;(out[i] as Record<string, Cell>)[field] =
          kind === "u32" ? (v === NONE ? 0 : v)
          : kind === "bool" ? v === 1
          : v === NONE ? null
          : kind === "secs?" ? v
          : kind === "day" ? isoDay(v)
          : stamp(v)
      }
    }
    return out as T[]
  }

  // -- the board --

  select(min: number, lo: number, hi: number, stage: number, status: number, batch: number, profile: number, heat: number, q: string): number {
    const len = this.put((n) => this.k.scratch(n), ENCODER.encode(q).slice(0, 256))
    this.count = this.k.select(min, lo, hi, stage, status, batch, profile, heat, len)
    return this.count
  }

  selection(): Uint32Array { return new Uint32Array(this.mem, this.k.selection_ptr(), this.count) }

  /** Hand an op to the pending layer: 0, or the refusal it predicts. */
  push(frame: Bytes): number {
    return this.k.pending_push(this.put((n) => this.k.scratch(n), frame.subarray(HEADER)))
  }

  /** A document the kernel composed (`len` bytes of JSON at result_ptr), or null when it knows no such thing. */
  document<T>(len: number): T | null {
    return len === 0 ? null : (JSON.parse(DECODER.decode(new Uint8Array(this.mem, this.k.result_ptr(), len))) as T)
  }

  /** The kernel's base as frames that restore it. */
  snapshot(): Bytes {
    const len = this.k.snapshot()
    return new Uint8Array(this.mem, this.k.snapshot_ptr(), len).slice()
  }

  /** Predictions settled exact, mispredicted, refused by the server, refused locally. */
  counters(): { settled: number; mispredicted: number; nacked: number; refused: number } {
    return { settled: this.k.counter(1), mispredicted: this.k.counter(2), nacked: this.k.counter(3), refused: this.k.counter(4) }
  }
}

/** The kernel module, compiled once, and its first instance; a trap re-instantiates the module. */
export interface KernelModule { module: WebAssembly.Module; instance: WireKernel }

/** The kernel, from the module the page started compiling, or fetched now. */
export async function loadWireKernel(url: string, early?: Promise<WebAssembly.Module>): Promise<KernelModule> {
  const module = (await early?.catch(() => undefined)) ?? (await WebAssembly.compileStreaming(fetch(url)))
  return { module, instance: (await WebAssembly.instantiate(module, {})).exports as unknown as WireKernel }
}

// ---- what rows are read as ----

const SPEC = {
  profiles: { id: ["id", "u32"], slug: ["slug", "str"], name: ["name", "str"] },
  batches: { id: ["id", "u32"], code: ["code", "str"], ordinal: ["ordinal", "u32"], fire: ["fire", "u32"], status: ["status", "str"] },
  clock: { today: ["today", "u32"], now: ["now", "u32"] },
  acct: { id: ["id", "u32"], name: ["name", "str"], me: ["me", "u32"], recovery_left: ["recovery_left", "u32"], fresh_until: ["fresh_until", "secs?"], sign_in_methods: ["sign_in_methods", "str"] },
  acct_keys: {
    id: ["id", "u32"], key_id: ["key_id", "str"], name: ["name", "str"], display: ["display", "str"], scope: ["scope", "str"], created_at: ["created_at", "time"],
    last_used_at: ["last_used_at", "time"], expires_at: ["expires_at", "time"], revoked_at: ["revoked_at", "time"], live: ["live", "bool"],
  },
  acct_sessions: {
    id: ["id", "u32"], authenticated_at: ["authenticated_at", "time"], last_seen_at: ["last_seen_at", "time"], expires_at: ["expires_at", "time"],
    mfa_at: ["mfa_at", "time"], ip: ["ip", "str"], user_agent: ["user_agent", "str"],
  },
  acct_identities: { id: ["id", "u32"], provider: ["provider", "str"], display: ["display", "str"], created_at: ["created_at", "time"] },
  acct_factors: {
    id: ["id", "u32"], kind: ["kind", "str"], name: ["name", "str"], created_at: ["created_at", "time"], last_used_at: ["last_used_at", "time"],
    backed_up: ["backed_up", "bool"], transports: ["transports", "str"],
  },
  // Lookups and what the kernel derives.
  stages: { ix: ["ix", "u32"], key: ["key", "str"], label: ["label", "str"], hint: ["hint", "str"] },
  keyed: { ix: ["ix", "u32"], key: ["key", "str"] },
  bands: { ix: ["ix", "u32"], key: ["key", "str"], label: ["label", "str"], min: ["min", "u32"], max: ["max", "u32"] },
  score: {
    fire: ["fire", "u32"], leftover_unique: ["leftover_unique", "u32"], leftover_noted_on: ["leftover_noted_on", "day"], batches_today: ["batches_today", "u32"],
    batches_target: ["batches_target", "u32"], apps_today: ["apps_today", "u32"], apps_target: ["apps_target", "u32"], submitted_today: ["submitted_today", "u32"],
    cumulative: ["cumulative", "u32"], chart_n: ["chart_n", "u32"], chart_mean: ["chart_mean", "f64"],
  },
  varieties: { code: ["code", "str"], fire: ["fire", "str"], status: ["status", "str"], label: ["label", "str"] },
  chart_bands: { key: ["key", "str"], label: ["label", "str"], min: ["min", "u32"], max: ["max", "u32"], count: ["count", "u32"] },
  chart_bins: { lo: ["lo", "u32"], hi: ["hi", "u32"], count: ["count", "u32"] },
} as const satisfies Record<string, Spec>

interface RawBatch { id: number; code: string; ordinal: number; fire: number; status: string }

// ---- the board: the kernel's derived cards ----

/**
 * The cards the kernel derives, read in place. Two columns keep the
 * shell's encoding: the kernel's `batch` and `profile` are ids, the
 * board's are batch ordinal + 1 and profile index.
 */
class Board {
  private readonly strs = new Map<string, StrColumn>()
  private readonly remapped = new Map<string, Uint32Array>()
  private tableDoc: Tables | null = null

  constructor(private readonly k: Kernel) {}

  private get t(): number { return this.k.table("cards") }

  /** Cards, lookups or pending ops changed. */
  changed(tables: ReadonlyMap<number, unknown> | null): void {
    const t = (name: string) => tables === null || tables.has(this.k.table(name))
    // The lookups keep their identity unless a lookup moved: the shell
    // re-reads its filters from the address whenever they change.
    const lookups = ["stages", "statuses", "freshness", "gates", "heat_states", "bands", "batches", "profiles"].some(t)
    if (lookups) this.tableDoc = null
    if (lookups || t("cards")) this.remapped.clear()
  }

  get n(): number { return this.k.k.rows(this.t) }

  get tables(): Tables {
    if (this.tableDoc) return this.tableDoc
    const k = this.k
    const byIx = <T extends { ix: number }>(rows: T[]) => [...rows].sort((a, b) => a.ix - b.ix)
    const keyed = (name: string) => byIx(k.all<{ ix: number; key: string }>(name, SPEC.keyed)).map((r) => r.key)
    this.tableDoc = {
      stages: byIx(k.all<Stage & { ix: number }>("stages", SPEC.stages)).map(({ key, label, hint }) => ({ key, label, hint })),
      statuses: keyed("statuses"),
      freshness: keyed("freshness"),
      gates: keyed("gates"),
      heat_states: keyed("heat_states"),
      bands: byIx(k.all<Band & { ix: number }>("bands", SPEC.bands)).map(({ key, label, min, max }) => ({ key, label, min, max })),
      batches: [...k.all<RawBatch>("batches", SPEC.batches)].sort((a, b) => a.ordinal - b.ordinal)
        .map((b) => ({ id: b.id, code: b.code, ordinal: b.ordinal, fire: b.fire === 1 ? "open_fire" as const : "hold" as const, status: b.status })),
      profiles: [...k.all<Profile>("profiles", SPEC.profiles)].sort((a, b) => a.id - b.id).map(({ id, slug, name }) => ({ id, slug, name })),
    }
    return this.tableDoc
  }

  column(name: string): Uint32Array {
    const raw = this.k.u32(this.t, this.k.col(this.t, name))
    if (name !== "batch" && name !== "profile") return raw
    let m = this.remapped.get(name)
    if (!m || m.length !== raw.length) {
      const to = new Map<number, number>()
      if (name === "batch") for (const b of this.tables.batches) to.set(b.id, b.ordinal + 1)
      else this.tables.profiles.forEach((p, i) => to.set(p.id, i))
      m = raw.map((v) => to.get(v) ?? (name === "batch" ? 0 : NONE))
      this.remapped.set(name, m)
    }
    return m
  }

  str(name: string): StrColumn {
    let s = this.strs.get(name)
    if (!s) {
      const [k, t, c] = [this.k, this.t, this.k.col(this.t, name)]
      this.strs.set(name, (s = { at: (row) => k.str(t, c, row) }))
    }
    return s
  }

  rowOf(id: number): number { return this.k.k.row_of(this.t, id) }

  select(s: Selection): number {
    const t = this.tables
    const batch = s.batch > 0 ? t.batches.find((b) => b.ordinal + 1 === s.batch)?.id ?? NONE : s.batch
    const profile = s.profile >= 0 ? t.profiles[s.profile]?.id ?? NONE : s.profile
    return this.k.select(s.min, s.lo, s.hi, s.stage, s.status, batch, profile, s.heat, s.q)
  }

  selection(): Uint32Array { return this.k.selection() }
  find(id: number): number { return this.k.k.find(id) }
}

// ---- the documents ----
//
// A focus, a root CV and the lanes are composed by the kernel (compose.rs,
// shared with hireme-mcp) as JSON in HiremeWeb.JSON's shapes, and parsed
// here once; each is kept until a row it reads changes. The scoreboard
// reads the kernel's derived tables, the account page its own.

class Documents {
  private readonly focuses = new Map<number, Focus>()
  private readonly roots = new Map<number, Root>()
  private laneDoc: Lanes | null = null
  private scoreDoc: Scoreboard | null | undefined
  private acctDoc: Settings | null | undefined

  constructor(private readonly k: Kernel) {}

  /** Rows of these tables changed (null: any); `jobs` are the job rows among them. */
  changed(tables: ReadonlyMap<number, ReadonlySet<number> | null> | null, jobs: readonly number[] | "all"): Change {
    const k = this.k
    const t = (name: string) => tables === null || tables.has(k.table(name))
    const c: Change = {}
    const wide = ["items", "overlays", "profiles", "cv_variants", "cv_lineages", "narratives", "kv_pairs", "batches", "events", "stages", "bands"].some(t)
    // A job's focus also reads its card's glance and its verdict, which a kin's move can change.
    const keys = (name: string) => tables?.get(k.table(name))
    const moved = [keys("cards"), keys("verdicts")]
    if (wide || jobs === "all" || moved.some((m) => m === null)) {
      this.focuses.clear()
      c.focus = "all"
    } else {
      const ids = new Set([...jobs, ...moved.flatMap((m) => [...(m ?? [])])])
      for (const id of ids) this.focuses.delete(id)
      if (ids.size > 0) c.focus = [...ids]
    }
    if (["profiles", "items", "cv_variants", "kv_pairs", "narratives"].some(t)) {
      this.roots.clear()
      c.root = true
    }
    if (["kv_pairs", "gym_problems", "gym_reps", "net_entries", "clock", "heat_rows"].some(t)) {
      this.laneDoc = null
      c.lanes = true
    }
    if (["score", "varieties", "chart_bands", "chart_bins"].some(t)) {
      this.scoreDoc = undefined
      c.scoreboard = true
    }
    if (["acct", "acct_keys", "acct_sessions", "acct_identities", "acct_factors", "clock"].some(t)) {
      this.acctDoc = undefined
      c.account = true
    }
    return c
  }

  focus(id: number): Focus | null {
    let f = this.focuses.get(id)
    if (!f) {
      f = this.k.document<Focus>(this.k.k.focus_json(id)) ?? undefined
      if (f) this.focuses.set(id, f)
    }
    return f ?? null
  }

  root(profileId: number): Root | null {
    let r = this.roots.get(profileId)
    if (!r) {
      r = this.k.document<Root>(this.k.k.root_json(profileId)) ?? undefined
      if (r) this.roots.set(profileId, r)
    }
    return r ?? null
  }

  lanes(): Lanes | null {
    if (this.laneDoc) return this.laneDoc
    if (this.k.k.rows(this.k.table("clock")) === 0) return null
    this.laneDoc = this.k.document<Lanes>(this.k.k.lanes_json())
    return this.laneDoc
  }

  scoreboard(): Scoreboard | null {
    if (this.scoreDoc !== undefined) return this.scoreDoc
    const k = this.k
    const s = k.all<Record<string, number | string | null>>("score", SPEC.score)[0]
    this.scoreDoc = s
      ? {
        fire: s["fire"] === 1 ? "open_fire" : "hold",
        leftover_unique: Number(s["leftover_unique"]), leftover_noted_on: (s["leftover_noted_on"] as string | null) ?? null,
        batches_today: Number(s["batches_today"]), batches_target: Number(s["batches_target"]),
        apps_today: Number(s["apps_today"]), apps_target: Number(s["apps_target"]),
        submitted_today: Number(s["submitted_today"]), cumulative: Number(s["cumulative"]),
        varieties: k.all<Scoreboard["varieties"][number]>("varieties", SPEC.varieties).map((v) => ({ ...v })),
        chart: {
          n: Number(s["chart_n"]),
          mean: Number(s["chart_n"]) === 0 ? null : Number(s["chart_mean"]),
          bands: k.all<Scoreboard["chart"]["bands"][number]>("chart_bands", SPEC.chart_bands).map((b) => ({ ...b })),
          bins: k.all<Scoreboard["chart"]["bins"][number]>("chart_bins", SPEC.chart_bins).map((b) => ({ ...b })),
        },
      }
      : null
    return this.scoreDoc
  }

  /** The Account page's document, as /api/account answered it; `clock.now` decides freshness. */
  account(): Settings | null {
    if (this.acctDoc !== undefined) return this.acctDoc
    const k = this.k
    const a = k.all<AcctRow>("acct", SPEC.acct)[0]
    if (!a) return (this.acctDoc = null)
    const clock = k.all<{ now: number }>("clock", SPEC.clock)[0]
    const now = clock && clock.now > 0 ? clock.now : Math.floor(Date.now() / 1000)
    const lines = (s: string) => s.split("\n").filter((x) => x !== "")
    this.acctDoc = {
      account: { id: a.id, name: a.name },
      keys: k.all<Key>("acct_keys", SPEC.acct_keys).map((x) => ({ ...x })),
      sessions: k.all<Omit<Session, "current">>("acct_sessions", SPEC.acct_sessions).map((s) => ({ ...s, current: s.id === a.me })),
      security: {
        methods: k.all<Omit<Method, "transports"> & { transports: string }>("acct_factors", SPEC.acct_factors).map((f) => ({ ...f, transports: lines(f.transports) })),
        recovery_codes_left: a.recovery_left,
        fresh: a.fresh_until !== null && now < a.fresh_until,
      },
      identities: k.all<Identity>("acct_identities", SPEC.acct_identities).map((x) => ({ ...x })),
      sign_in_methods: lines(a.sign_in_methods) as Identity["provider"][],
    }
    return this.acctDoc
  }
}

interface AcctRow { id: number; name: string; me: number; recovery_left: number; fresh_until: number | null; sign_in_methods: string }

// ---- ops ----

function jobOf(op: Op): number | null {
  return "job" in op ? op.job : null
}

const OP_KIND: Record<Op["kind"], number> = {
  stage: 1, next: 2, note: 3, score: 4, overlay: 5, heat_override: 6, open_fire: 7, narrative: 8,
  gym_log: 9, gym_target: 10, net_log: 11, net_lane: 12,
}

const pairs = (fields: Record<string, string>) => Object.entries(fields).flat()

/** An op as its OP frame: target and fields in the order schema.txt names. */
export function encodeOp(hash: number, opId: bigint, op: Op): Bytes {
  const [target, fields]: [number, string[]] =
    op.kind === "stage" ? [op.job, [op.stage]]
    : op.kind === "next" ? [op.job, [op.next_action, op.next_due]]
    : op.kind === "note" ? [op.job, [op.stage, op.note]]
    : op.kind === "score" ? [op.job, [String(op.score)]]
    : op.kind === "overlay" ? [op.job, [String(op.item), op.mode, op.body ?? "", op.reason ?? ""]]
    : op.kind === "heat_override" ? [op.job, [op.reason]]
    : op.kind === "open_fire" ? [0, [op.batch]]
    : op.kind === "narrative" ? [op.narrative, [op.body]]
    : op.kind === "gym_target" ? [0, [op.target]]
    : op.kind === "net_lane" ? [0, [op.url]]
    : [0, pairs(op.fields)]
  return opFrame(hash, opId, OP_KIND[op.kind], target, fields)
}

export interface Pending { opId: bigint; op: Op; job: number | null; frame: Bytes }

// ---- the desk ----

export class LocalDesk implements Desk, Host {
  private readonly kernel: Kernel
  private readonly board: Board
  private readonly docs: Documents
  private link: Link | null = null
  private pending: Pending[] = []
  private readonly listeners = new Set<(c: Change) => void>()
  readonly clientId: number
  private counter = 0
  private statusNow: Status = "connecting"
  readonly hash: number
  readonly snapshot: Snapshot | null
  private replaying = false

  /** Ops sent and refused before sending; the kernel's counters hold the rest. Read by the bench. */
  readonly counters = { predicted: 0, refusedLocally: 0, nacked: 0 }

  constructor(private readonly source: KernelModule, scope: string, clientId = crypto.getRandomValues(new Uint32Array(1))[0] ?? 1) {
    this.clientId = clientId
    const kernel = source.instance
    this.hash = kernel.schema_hash()
    this.kernel = new Kernel(kernel, (cause) => void this.recover(cause))
    this.board = new Board(this.kernel)
    this.docs = new Documents(this.kernel)
    kernel.set_today(Math.floor(Date.now() / 86_400_000))
    const k = this.kernel
    this.snapshot = scope === "" ? null : new Snapshot(scope, this.hash, () => (this.board.n > 0 ? { rev: k.rev, bytes: k.snapshot() } : null))
  }

  attach(link: Link): void { this.link = link }

  /** Called once a trapped kernel is replaced, so the link can ask the server for what the new one lacks. */
  onReset: (() => void) | null = null
  private recoveries: number[] = []

  /**
   * The kernel trapped. Until a fresh instance is up the desk reads as
   * empty; then it is rebuilt from the IndexedDB snapshot (or nothing),
   * the ops still pending are predicted again, and the link reconnects so
   * HELLO names the rev it now holds and the server replays the rest.
   * Three traps within a minute load the page again instead.
   */
  private async recover(cause: unknown): Promise<void> {
    console.error("kernel trapped", cause)
    const now = performance.now()
    this.recoveries = this.recoveries.filter((t) => now - t < 60_000)
    this.recoveries.push(now)
    if (this.recoveries.length > 3) {
      location.reload()
      return
    }
    this.emit({ rows: true, focus: "all", lanes: true, root: true, scoreboard: true, account: true })
    const fresh = (await WebAssembly.instantiate(this.source.module, {})) as unknown as WebAssembly.Instance
    this.kernel.swap(fresh.exports as unknown as WireKernel)
    this.kernel.k.set_today(Math.floor(Date.now() / 86_400_000))
    const snap = await this.snapshot?.load()
    if (snap) {
      this.replaying = true
      try {
        this.kernel.ingest(snap.bytes)
      } finally {
        this.replaying = false
      }
    }
    for (const p of this.pending) this.kernel.push(p.frame)
    this.kernel.touched()
    this.kernel.forget(null)
    this.board.changed(null)
    this.emit({ ...this.docs.changed(null, "all"), rows: true })
    this.onReset?.()
  }

  /** In-memory counters for the bench: ops sent and refused here, and the kernel's settled, mispredicted and refused. */
  stats(): Record<string, number> {
    const k = this.kernel.counters()
    return { ...this.counters, settled: k.settled, mispredicted: k.mispredicted, kernelNacked: k.nacked, kernelRefused: k.refused, pending: this.pending.length }
  }

  // -- reads --

  get n(): number { return this.board.n }
  get tables(): Tables { return this.board.tables }
  select(s: Selection): number { return this.board.select(s) }
  selection(): Uint32Array { return this.board.selection() }
  find(id: number): number { return this.board.find(id) }
  column(name: string): Uint32Array { return this.board.column(name) }
  str(name: string): StrColumn { return this.board.str(name) }
  rowOf(id: number): number { return this.board.rowOf(id) }
  get status(): Status { return this.statusNow }

  focus(id: number): Focus | null { return this.docs.focus(id) }
  root(profileId: number): Root | null { return this.docs.root(profileId) }
  scoreboard(): Scoreboard | null { return this.docs.scoreboard() }
  lanes(): Lanes | null { return this.docs.lanes() }
  account(): Settings | null { return this.docs.account() }

  /** An op on the wire for this job: its PATCH and ACK are a round trip away. */
  mark(jobId: number): Mark {
    return this.pending.some((p) => p.job === jobId) ? "pending" : null
  }

  subscribe(fn: (c: Change) => void): () => void {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  // -- writes --

  run(op: Op): Run {
    const opId = (BigInt(this.clientId) << 32n) | BigInt(this.counter + 1)
    const job = jobOf(op)
    const p: Pending = { opId, op, job, frame: encodeOp(this.hash, opId, op) }
    const code = this.kernel.push(p.frame)
    if (code !== 0) {
      this.counters.refusedLocally++
      return { ok: false, refusal: refusalName(code) }
    }
    this.counter++
    this.pending.push(p)
    this.counters.predicted++
    const c = this.settle()
    this.emit({ ...c, rows: true })
    this.link?.send(p)
    return { ok: true, opId, jobId: job }
  }

  /** The kernel's rows changed (an ingest or a push): forget what read them, and say what changed. */
  private settle(): Change {
    const { tables, jobs } = this.kernel.touched()
    this.kernel.forget(tables)
    this.board.changed(tables)
    this.snapshot?.queue(this.pending)
    return this.docs.changed(tables, jobs)
  }

  // -- the wire (Host) --

  rev(): bigint { return this.kernel.rev }

  unacked(): readonly Bytes[] {
    return this.pending.map((p) => p.frame)
  }

  connection(s: "connecting" | "webtransport" | "websocket" | "offline"): void {
    if (s === this.statusNow) return
    this.statusNow = s
    this.emit({ status: true })
  }

  bye(): void {
    this.snapshot?.clear()
  }

  /**
   * Paint from saved frames, then predict again and resend the ops never
   * acknowledged. Only before the network's desk has landed: the BOOT
   * replaces a restored desk, never the other way round.
   */
  restore(bytes: Bytes, ops: readonly { opId: bigint; op: Op }[]): boolean {
    if (this.kernel.rev !== 0n) return false
    this.replaying = true
    try {
      this.ingest(bytes, FLAG.END)
    } finally {
      this.replaying = false
    }
    for (const { opId, op } of ops) {
      const p: Pending = { opId, op, job: jobOf(op), frame: encodeOp(this.hash, opId, op) }
      if (this.kernel.push(p.frame) === 0) {
        this.pending.push(p)
        this.link?.send(p)
      }
    }
    if (ops.length > 0) this.emit({ ...this.settle(), rows: true })
    return true
  }

  frame(f: Bytes, kind: number, flags: number): void {
    this.ingest(f, flags)
    if (kind === KIND.ACK) this.retire(new DataView(f.buffer, f.byteOffset, f.byteLength).getBigUint64(HEADER, true), null)
    if (kind === KIND.NACK) {
      const v = new DataView(f.buffer, f.byteOffset, f.byteLength)
      const len = v.getUint16(HEADER + 10, true)
      this.retire(v.getBigUint64(HEADER, true), { refusal: refusalName(v.getUint8(HEADER + 8)), message: DECODER.decode(f.subarray(HEADER + 12, HEADER + 12 + len)) })
    }
  }

  private ingest(f: Bytes, flags: number): void {
    const start = performance.now()
    const bits = this.kernel.ingest(f)
    const c = this.settle()
    // A whole desk arriving (a BOOT or a snapshot): a measure the bench reads.
    if (f.byteLength > 65_536) performance.measure(this.replaying ? "desk:restore" : "desk:ingest", { start, detail: f.byteLength })
    if (bits & (INGEST.cards | INGEST.settled | INGEST.dropped | INGEST.tick) || flags & FLAG.END) c.rows = true
    if (bits & INGEST.tick) this.kernel.forget(null)
    if (!this.replaying) {
      if (bits & (INGEST.cards | INGEST.tables)) this.snapshot?.touch()
      if (flags & FLAG.END && performance.getEntriesByName("desk:ready").length === 0) performance.mark("desk:ready")
    }
    if (c.rows || c.focus || c.lanes || c.root || c.scoreboard || c.account) this.emit(c)
  }

  /** An ACK or NACK for an op of ours. The kernel has already settled or dropped it. */
  private retire(opId: bigint, refused: { refusal: Refusal; message: string } | null): void {
    const p = this.pending.find((x) => x.opId === opId)
    if (!p) return
    this.pending = this.pending.filter((x) => x !== p)
    this.snapshot?.queue(this.pending)
    if (refused) {
      this.counters.nacked++
      this.emit({ rows: true, focus: p.job === null ? "all" : [p.job], refused: { opId, jobId: p.job, op: p.op, ...refused } })
    } else {
      this.emit({ acked: opId, focus: p.job === null ? [] : [p.job] })
    }
  }

  private emit(c: Change): void {
    for (const fn of this.listeners) fn(c)
  }
}

// ---- the snapshot ----
//
// The kernel's base as frames (a raw BOOT), written to
// IndexedDB under the account's scope once the desk is quiet for a second
// (or five seconds into a steady stream) and when the page hides, so the
// next load paints before the network answers. Replaying them through the same sink restores the desk, and
// HELLO then names their rev so the server sends only what changed.

/**
 * The snapshot's own format. Bumped when a saved snapshot must not be
 * trusted any more: 2 drops those written while the server's partial rows
 * could blank a job's columns, so a desk that lost a row on a write gets
 * it back on its next load instead of resuming from the loss.
 */
const FORMAT = 2

export class Snapshot {
  private ops: { opId: bigint; op: Op }[] | null = null
  private timer = 0
  private dirty = false
  private first = 0
  private last = 0

  constructor(private readonly scope: string, private readonly hash: number, private readonly take: () => { rev: bigint; bytes: Bytes } | null) {
    addEventListener("pagehide", () => this.save())
  }

  /** The base changed. Save once it has been quiet a second, or five seconds into a steady stream. */
  touch(): void {
    const now = performance.now()
    if (!this.dirty) this.first = now
    this.dirty = true
    this.last = now
    if (this.timer === 0) this.timer = window.setTimeout(() => this.due(), 1000)
  }

  private due(): void {
    this.timer = 0
    const now = performance.now()
    if (now - this.last < 1000 && now - this.first < 5000) this.timer = window.setTimeout(() => this.due(), 1000 - (now - this.last))
    // Exporting ~2 MB of rows and handing them to IndexedDB is a few ms of
    // main thread: do it when the page is idle, never between an input and
    // its frame.
    else idle(() => this.save(), 2000)
  }

  private save(): void {
    if (!this.dirty) return
    const snap = this.take()
    if (!snap) return
    this.dirty = false
    void idb((store) => store.put({ format: FORMAT, rev: snap.rev, hash: this.hash, blob: new Blob([snap.bytes]) }, this.scope), "readwrite").catch(() => {})
  }

  /** The ops not yet acknowledged, kept beside the frames so a reload predicts and resends them. */
  /** Keep the unacknowledged ops; written after the input's task, never inside it. */
  queue(pending: readonly Pending[]): void {
    const first = this.ops === null
    this.ops = pending.map(({ opId, op }) => ({ opId, op }))
    if (!first) return
    idle(() => {
      const ops = this.ops
      this.ops = null
      void idb((store) => store.put(ops, `${this.scope}:ops`), "readwrite").catch(() => {})
    }, 250)
  }

  clear(): void {
    this.dirty = false
    void idb((store) => store.delete(this.scope), "readwrite").catch(() => {})
    void idb((store) => store.delete(`${this.scope}:ops`), "readwrite").catch(() => {})
  }

  /** The saved frames and op queue for this account, if they were written under this schema. */
  async load(early?: Promise<unknown>): Promise<{ rev: bigint; bytes: Bytes; ops: { opId: bigint; op: Op }[] } | null> {
    const [rec, ops] = (await Promise.all([
      (early ?? idb((store) => store.get(this.scope), "readonly")).catch(() => undefined),
      idb((store) => store.get(`${this.scope}:ops`), "readonly").catch(() => undefined),
    ])) as [{ format?: number; rev?: bigint; hash?: number; blob?: Blob } | undefined, { opId: bigint; op: Op }[] | undefined]
    if (!rec?.blob || rec.format !== FORMAT || rec.hash !== this.hash || typeof rec.rev !== "bigint") return null
    return { rev: rec.rev, bytes: new Uint8Array(await rec.blob.arrayBuffer()), ops: Array.isArray(ops) ? ops : [] }
  }
}

/** Run when the main thread is idle, and within `timeout` ms at the latest. */
function idle(fn: () => void, timeout: number): void {
  if (typeof requestIdleCallback === "function") requestIdleCallback(() => fn(), { timeout })
  else setTimeout(fn, 50)
}

function idb(run: (store: IDBObjectStore) => IDBRequest, mode: IDBTransactionMode): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open("hireme", 1)
    open.onupgradeneeded = () => open.result.createObjectStore("snap")
    open.onerror = () => reject(open.error)
    open.onsuccess = () => {
      try {
        const req = run(open.result.transaction("snap", mode).objectStore("snap"))
        req.onsuccess = () => resolve(req.result)
        req.onerror = () => reject(req.error)
      } catch (e) {
        reject(e)
      }
    }
  })
}
