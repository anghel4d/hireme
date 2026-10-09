// The desk the shell reads. View = base ⊕ pending: the base is what the
// server last said, the pending layer is this tab's ops not yet folded
// into it. Every read is synchronous; nothing here returns a Promise.
//
// The base board is a column store in WebAssembly memory. A pending op
// that touches a column gives that column a copy-on-write shadow; the
// kernel's selection reads the shadow, so a predicted stage moves the
// card between filters in the same frame. Dropping an op (a refusal)
// recomputes the shadows from the base, so rollback is free.
//
// What carries ops and brings the base is a Link: today's HTTP routes,
// then the wire. The desk does not know which.

import type { Doc, Focus, Lanes, Line, Root, Scoreboard } from "./api.ts"
import { KIND, NONE, tables, type Bytes, type Table } from "./wire.ts"

// ---- the packet ----

export type ColumnKind = "u32" | "str"
export interface ColumnEntry { name: string; kind: ColumnKind; at: number; size: number }
export interface Stage { key: string; label: string; hint: string }
export interface Band { key: string; label: string; min: number; max: number }
export interface Batch { code: string; ordinal: number; fire: "hold" | "open_fire"; status: string }
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

export interface Header { v: 1; n: number; columns: ColumnEntry[]; tables: Tables }
export interface Packet { header: Header; body: Uint8Array }

// HDP1 is "HDP1" | u32 header_len | header JSON | body (4-byte aligned).
const MAGIC = 0x31504448

export function parsePacket(buffer: ArrayBuffer): Packet {
  const view = new DataView(buffer)
  if (buffer.byteLength < 8 || view.getUint32(0, true) !== MAGIC) throw new Error("not an HDP1 packet")
  const headerLen = view.getUint32(4, true)
  const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 8, headerLen))) as Header
  const bodyAt = 8 + headerLen + ((4 - (headerLen % 4)) % 4)
  return { header, body: new Uint8Array(buffer, bodyAt) }
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
export type Mark = "pending" | "settling" | null

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
  /** Any column changed, base or pending. */
  rows?: boolean
  /** Job ids whose focus changed. */
  focus?: readonly number[]
  root?: boolean
  scoreboard?: boolean
  lanes?: boolean
  status?: boolean
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

  /** The resident focus with pending ops applied; null until it has arrived. */
  focus(id: number): Focus | null
  root(profileId: number): Root | null
  scoreboard(): Scoreboard | null
  lanes(): Lanes | null

  /** Apply locally in this tick and send. A predicted refusal applies nothing. */
  run(op: Op): Run
  mark(jobId: number): Mark
  /** Visible card ids, the selected one first. */
  hint(ids: readonly number[]): void
  readonly status: Status
  subscribe(fn: (c: Change) => void): () => void
}

/** What carries ops up and brings the base down. */
export interface Link {
  send(opId: bigint, op: Op): void
  /** A read found these documents missing. Called on every such read: the link dedupes. */
  want(focus: readonly number[], root: readonly number[]): void
  /** The visible cards, the selected one first: the link brings their focuses ahead of need. */
  hint(ids: readonly number[]): void
}

// ---- the board: the base columns in WebAssembly memory ----

export interface Kernel {
  mem: WebAssembly.Memory
  reset(): void
  alloc(size: number): number
  select(
    n: number, cols: number,
    min: number, lo: number, hi: number,
    stage: number, status: number, batch: number, profile: number, heat: number,
    q: number, qlen: number,
    out: number,
  ): number
  find(out: number, count: number, ids: number, id: number): number
}

export async function loadKernel(url: string): Promise<Kernel> {
  const { instance } = await WebAssembly.instantiateStreaming(fetch(url), {})
  return instance.exports as unknown as Kernel
}

// The kernel's column table, by slot.
const SLOTS = ["score", "heat", "stage", "status", "freshness", "gate", "batch", "profile"] as const
const SEARCH = 8
const HEAT_STATE = 10

class Strings implements StrColumn {
  private readonly cache = new Map<number, string>()
  constructor(
    private readonly mem: WebAssembly.Memory,
    private readonly offsets: number,
    private readonly bytes: number,
    private readonly n: number,
    readonly over: Map<number, string> = new Map(),
  ) {}

  at(row: number): string {
    const o = this.over.get(row)
    if (o !== undefined) return o
    const hit = this.cache.get(row)
    if (hit !== undefined) return hit
    const offs = new Uint32Array(this.mem.buffer, this.offsets, this.n + 1)
    const start = offs[row] ?? 0
    const end = offs[row + 1] ?? start
    const text = DECODER.decode(new Uint8Array(this.mem.buffer, this.bytes + start, end - start))
    this.cache.set(row, text)
    return text
  }
}

const DECODER = new TextDecoder()
const ENCODER = new TextEncoder()

export class Board {
  readonly n: number
  readonly tables: Tables
  private readonly base = new Map<string, number>()
  private readonly live = new Map<string, number>()
  private readonly shadows = new Map<string, number>()
  private readonly strs = new Map<string, Strings>()
  private readonly rows = new Map<number, number>()
  private readonly cols: number
  private readonly out: number
  private readonly scratch: number
  private count = 0

  constructor(private readonly k: Kernel, packet: Packet) {
    this.n = packet.header.n
    this.tables = packet.header.tables
    k.reset()
    const at = k.alloc(packet.body.byteLength)
    new Uint8Array(k.mem.buffer, at, packet.body.byteLength).set(packet.body)
    for (const c of packet.header.columns) {
      if (c.kind === "u32") this.base.set(c.name, at + c.at)
      else this.strs.set(c.name, new Strings(k.mem, at + c.at, at + c.at + 4 * (this.n + 1), this.n))
    }
    const search = packet.header.columns.find((c) => c.name === "search")
    if (!search) throw new Error("packet has no search column")
    this.cols = k.alloc(11 * 4)
    const table = new Uint32Array(k.mem.buffer, this.cols, 11)
    table[SEARCH] = at + search.at
    table[SEARCH + 1] = at + search.at + 4 * (this.n + 1)
    this.out = k.alloc(Math.max(this.n, 1) * 4)
    this.scratch = k.alloc(256)
    for (const name of this.base.keys()) this.live.set(name, this.ptr(name))
    this.relink()
    const ids = this.column("id")
    for (let r = 0; r < this.n; r++) this.rows.set(ids[r] ?? 0, r)
  }

  private ptr(name: string): number {
    const p = this.base.get(name)
    if (p === undefined) throw new Error(`no u32 column ${name}`)
    return p
  }

  private relink(): void {
    const table = new Uint32Array(this.k.mem.buffer, this.cols, 11)
    SLOTS.forEach((name, i) => { table[i] = this.live.get(name) ?? 0 })
    table[HEAT_STATE] = this.live.get("heat_state") ?? 0
  }

  has(name: string): boolean { return this.base.has(name) }

  column(name: string): Uint32Array {
    const p = this.live.get(name)
    if (p === undefined) throw new Error(`no u32 column ${name}`)
    return new Uint32Array(this.k.mem.buffer, p, this.n)
  }

  baseColumn(name: string): Uint32Array {
    return new Uint32Array(this.k.mem.buffer, this.ptr(name), this.n)
  }

  str(name: string): Strings {
    const c = this.strs.get(name)
    if (!c) throw new Error(`no str column ${name}`)
    return c
  }

  rowOf(id: number): number { return this.rows.get(id) ?? -1 }

  /**
   * Point the named columns at writable copies of their base, and every
   * other column back at the base. The copies live in kernel memory, so
   * the selection reads them. Returns the copies for the caller to edit.
   */
  shade(names: ReadonlySet<string>, strNames: ReadonlySet<string>): Map<string, Uint32Array> {
    const out = new Map<string, Uint32Array>()
    for (const name of this.base.keys()) {
      if (!names.has(name)) {
        this.live.set(name, this.ptr(name))
        continue
      }
      let p = this.shadows.get(name)
      if (p === undefined) {
        p = this.k.alloc(Math.max(this.n, 1) * 4)
        this.shadows.set(name, p)
      }
      const copy = new Uint32Array(this.k.mem.buffer, p, this.n)
      copy.set(this.baseColumn(name))
      this.live.set(name, p)
      out.set(name, copy)
    }
    for (const [name, s] of this.strs) if (!strNames.has(name)) s.over.clear()
    this.relink()
    return out
  }

  select(s: Selection): number {
    const q = ENCODER.encode(s.q.toLowerCase().trim()).slice(0, 256)
    new Uint8Array(this.k.mem.buffer, this.scratch, q.byteLength).set(q)
    this.count = this.k.select(
      this.n, this.cols, s.min, s.lo, s.hi, s.stage, s.status, s.batch, s.profile, s.heat,
      this.scratch, q.byteLength, this.out,
    )
    return this.count
  }

  selection(): Uint32Array { return new Uint32Array(this.k.mem.buffer, this.out, this.count) }

  find(id: number): number { return this.k.find(this.out, this.count, this.ptr("id"), id) }
}

// ---- prediction ----

const FIRE_LOCKED = new Set(["open_fire", "submitted"])
const HOT = new Set(["fire_ready", "open_fire", "submitted", "reply", "closed"])
const QUEUE = new Set(["fire_ready", "open_fire", "submitted"])
const STATE: Record<string, string> = { D: "done", A: "active", P: "pending", S: "skipped", B: "blocked" }
const today = () => Math.floor(Date.now() / 86_400_000)
const isoDay = (day: number) => new Date(day * 86_400_000).toISOString().slice(0, 10)
const epochDay = (iso: string) => (iso === "" ? NONE : Math.floor(Date.parse(`${iso}T00:00:00Z`) / 86_400_000))

/** Pipeline.move_to over a pip string: the target is active, skipped and blocked stay, the rest fall in order. */
function moveTo(pips: string, stages: readonly Stage[], key: string): string {
  const target = stages.findIndex((s) => s.key === key)
  if (target < 0 || pips.length !== stages.length) return pips
  let out = ""
  for (let i = 0; i < stages.length; i++) {
    const c = pips[i] ?? "P"
    out += i === target ? "A" : c === "S" || c === "B" ? c : i < target ? "D" : "P"
  }
  return out
}

function jobOf(op: Op): number | null {
  return "job" in op ? op.job : null
}

interface Pending { opId: bigint; op: Op; job: number | null; state: "pending" | "settling" }

// ---- the desk ----

export class LocalDesk implements Desk {
  private board: Board | null = null
  private link: Link | null = null
  private pending: Pending[] = []
  private readonly focuses = new Map<number, Focus>()
  private readonly roots = new Map<number, Root>()
  private score: Scoreboard | null = null
  private lane: Lanes | null = null
  private readonly views = new Map<number, Focus>()
  private laneView: Lanes | null = null
  private tableView: Tables | null = null
  private readonly listeners = new Set<(c: Change) => void>()
  private readonly client = crypto.getRandomValues(new Uint32Array(1))[0] ?? 1
  private counter = 0
  private statusNow: Status = "connecting"

  /** Predictions the server later contradicted, and refusals predicted; read by the bench. */
  readonly counters = { predicted: 0, refusedLocally: 0, nacked: 0 }

  attach(link: Link): void { this.link = link }

  // -- reads --

  get n(): number { return this.board?.n ?? 0 }

  get tables(): Tables {
    if (this.tableView) return this.tableView
    const base = this.board?.tables ?? EMPTY_TABLES
    const fired = new Set<string>()
    for (const p of this.pending) if (p.op.kind === "open_fire") fired.add(p.op.batch)
    this.tableView = fired.size === 0 ? base : {
      ...base,
      batches: base.batches.map((b) => (fired.has(b.code) ? { ...b, fire: "open_fire" as const, status: "open_fire" } : b)),
    }
    return this.tableView
  }

  select(s: Selection): number { return this.board?.select(s) ?? 0 }
  selection(): Uint32Array { return this.board?.selection() ?? EMPTY_U32 }
  find(id: number): number { return this.board?.find(id) ?? -1 }
  column(name: string): Uint32Array { return this.board?.column(name) ?? EMPTY_U32 }
  str(name: string): StrColumn { return this.board?.str(name) ?? EMPTY_STR }
  rowOf(id: number): number { return this.board?.rowOf(id) ?? -1 }
  get status(): Status { return this.statusNow }
  hasFocus(id: number): boolean { return this.focuses.has(id) }

  focus(id: number): Focus | null {
    const hit = this.views.get(id)
    if (hit) return hit
    const base = this.focuses.get(id)
    if (!base) {
      this.link?.want([id], [])
      return null
    }
    let f = base
    for (const p of this.pending) if (p.job === id || p.op.kind === "open_fire" || p.op.kind === "narrative") f = applyFocus(f, p.op, this.tables)
    this.views.set(id, f)
    return f
  }

  root(profileId: number): Root | null {
    const base = this.roots.get(profileId)
    if (!base) {
      this.link?.want([], [profileId])
      return null
    }
    let r = base
    for (const p of this.pending) {
      if (p.op.kind === "narrative" && r.narrative?.id === p.op.narrative) r = { ...r, narrative: { ...r.narrative, body: p.op.body } }
    }
    return r
  }

  scoreboard(): Scoreboard | null { return this.score }

  lanes(): Lanes | null {
    if (this.laneView || !this.lane) return this.laneView
    let l = this.lane
    for (const p of this.pending) if (p.state === "pending") l = applyLanes(l, p.op)
    this.laneView = l
    return l
  }

  mark(jobId: number): Mark {
    let mark: Mark = null
    for (const p of this.pending) {
      if (p.job !== jobId) continue
      if (p.state === "pending") return "pending"
      mark = "settling"
    }
    return mark
  }

  hint(ids: readonly number[]): void {
    this.link?.hint(ids)
  }

  subscribe(fn: (c: Change) => void): () => void {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  // -- writes --

  run(op: Op): Run {
    const refusal = this.refuse(op)
    if (refusal !== null) {
      this.counters.refusedLocally++
      return { ok: false, refusal }
    }
    const opId = (BigInt(this.client) << 32n) | BigInt(++this.counter)
    const job = jobOf(op)
    this.pending.push({ opId, op, job, state: "pending" })
    this.counters.predicted++
    this.recompute()
    this.emit(touched(op, job))
    this.link?.send(opId, op)
    return { ok: true, opId, jobId: job }
  }

  /** Unacknowledged ops, oldest first, for a resend after reconnect. */
  unacked(): readonly { opId: bigint; op: Op }[] {
    return this.pending.filter((p) => p.state === "pending")
  }

  private refuse(op: Op): Refusal | null {
    if (op.kind !== "stage") return null
    const row = this.rowOf(op.job)
    if (row < 0) return null
    const t = this.tables
    const current = t.stages[this.column("stage")[row] ?? 0]?.key ?? ""
    if (FIRE_LOCKED.has(op.stage)) {
      const ix = this.column("batch")[row] ?? 0
      const batch = ix > 0 ? t.batches.find((b) => b.ordinal + 1 === ix) : undefined
      if (batch?.fire !== "open_fire") return "fire_hold"
    }
    if (!HOT.has(current) && QUEUE.has(op.stage)) {
      const heat = t.heat_states[this.column("heat_state")[row] ?? 0]
      const overridden = this.focuses.get(op.job)?.heat.override === true || this.pending.some((p) => p.job === op.job && p.op.kind === "heat_override")
      if (heat === "blocked" && !overridden) return "heat"
    }
    if (this.board?.has("leased") && (this.column("leased")[row] ?? 0) !== 0) return "leased"
    return null
  }

  // -- the link reports --

  setStatus(s: Status): void {
    if (s === this.statusNow) return
    this.statusNow = s
    this.emit({ status: true })
  }

  /** A new base board. Settled ops are in it; ops still pending are applied over it. */
  rebase(board: Board): void {
    this.board = board
    this.pending = this.pending.filter((p) => p.state === "pending")
    this.recompute()
    this.emit({ rows: true, focus: [...this.focuses.keys()] })
  }

  putFocus(f: Focus): void {
    this.focuses.set(f.job.id, f)
    this.views.delete(f.job.id)
    this.emit({ focus: [f.job.id] })
  }

  /** A focus is stale: drop it and ask again if anyone still reads it. */
  staleFocus(id: number): void {
    this.views.delete(id)
    if (this.focuses.has(id)) this.link?.want([id], [])
  }

  putRoot(r: Root): void {
    this.roots.set(r.profile.id, r)
    this.emit({ root: true })
  }

  staleRoots(): void {
    const ids = [...this.roots.keys()]
    if (ids.length > 0) this.link?.want([], ids)
  }

  putScoreboard(s: Scoreboard): void {
    this.score = s
    this.emit({ scoreboard: true })
  }

  putLanes(l: Lanes): void {
    this.lane = l
    this.laneView = null
    this.emit({ lanes: true })
  }

  /** The server accepted an op; its row effects hold until the next base. */
  acked(opId: bigint): void {
    const p = this.pending.find((x) => x.opId === opId)
    if (!p) return
    p.state = "settling"
    this.laneView = null
    this.emit({ acked: opId, focus: p.job === null ? [] : [p.job], lanes: true })
  }

  nacked(opId: bigint, refusal: Refusal, message = ""): void {
    const p = this.pending.find((x) => x.opId === opId)
    if (!p) return
    this.pending = this.pending.filter((x) => x !== p)
    this.counters.nacked++
    this.recompute()
    this.emit({ ...touched(p.op, p.job), refused: { opId, jobId: p.job, op: p.op, refusal, message } })
  }

  // -- the view --

  private recompute(): void {
    this.views.clear()
    this.laneView = null
    this.tableView = null
    const board = this.board
    if (!board) return
    const u32 = new Set<string>()
    const strs = new Set<string>()
    for (const p of this.pending) {
      if (p.job === null || board.rowOf(p.job) < 0) continue
      switch (p.op.kind) {
        case "stage": u32.add("stage"); u32.add("stage_on"); strs.add("pips"); break
        case "next": u32.add("next_due"); strs.add("next_action"); break
        case "score": u32.add("score"); break
        case "overlay": u32.add("hidden"); u32.add("altered"); u32.add("emphasized"); break
        default: break
      }
    }
    const cols = board.shade(u32, strs)
    const pips = board.str("pips").over
    const next = board.str("next_action").over
    pips.clear()
    next.clear()
    const stages = board.tables.stages
    for (const p of this.pending) {
      const row = p.job === null ? -1 : board.rowOf(p.job)
      if (row < 0) continue
      const op = p.op
      switch (op.kind) {
        case "stage": {
          const ix = stages.findIndex((s) => s.key === op.stage)
          const stage = cols.get("stage")
          if (ix < 0 || !stage) break
          if (stage[row] !== ix) {
            stage[row] = ix
            const on = cols.get("stage_on")
            if (on) on[row] = today()
          }
          pips.set(row, moveTo(board.str("pips").at(row), stages, op.stage))
          break
        }
        case "next": {
          next.set(row, op.next_action)
          const due = cols.get("next_due")
          if (due) due[row] = epochDay(op.next_due)
          break
        }
        case "score": {
          const s = cols.get("score")
          if (s) s[row] = Math.max(0, Math.min(100, Math.round(op.score)))
          break
        }
        case "overlay": {
          const f = this.focuses.get(op.job)
          const line = f && findLine(f, op.item)
          if (!line) break
          const from = line.mode === "canonical" ? null : line.mode
          const to = op.mode === "inherit" ? null : op.mode
          if (from === to) break
          if (from) { const c = cols.get(from); if (c) c[row] = Math.max(0, (c[row] ?? 0) - 1) }
          if (to) { const c = cols.get(to); if (c) c[row] = (c[row] ?? 0) + 1 }
          break
        }
        default: break
      }
    }
  }

  private emit(c: Change): void {
    for (const fn of this.listeners) fn(c)
  }
}

function touched(op: Op, job: number | null): Change {
  switch (op.kind) {
    case "gym_log": case "gym_target": case "net_log": case "net_lane": return { lanes: true }
    case "open_fire": return { rows: true, scoreboard: true, focus: [] }
    case "narrative": return { root: true, focus: job === null ? [] : [job] }
    default: return { rows: true, focus: job === null ? [] : [job] }
  }
}

// ---- predicted documents ----

function allLines(f: Focus): Line[] {
  return [...f.cv.facts, ...f.cv.sections.flatMap((s) => s.lines), ...f.cv.hidden]
}

function findLine(f: Focus, id: number): Line | undefined {
  return allLines(f).find((l) => l.id === id)
}

function applyFocus(f: Focus, op: Op, t: Tables): Focus {
  switch (op.kind) {
    case "stage": {
      const stage = t.stages.find((s) => s.key === op.stage)
      if (!stage) return f
      const pips = moveTo(f.job.pips, t.stages, op.stage)
      const changed = f.job.stage !== op.stage
      return {
        ...f,
        job: {
          ...f.job, stage: op.stage, stage_label: stage.label, stage_hint: stage.hint, pips,
          stage_on: changed ? isoDay(today()) : f.job.stage_on,
        },
        rail: f.rail.map((r, i) => ({ ...r, state: STATE[pips[i] ?? ""] ?? r.state })),
      }
    }
    case "next":
      return { ...f, job: { ...f.job, next_action: op.next_action, next_due: op.next_due === "" ? null : op.next_due } }
    case "note":
      return { ...f, rail: f.rail.map((r) => (r.key === op.stage ? { ...r, note: op.note } : r)) }
    case "score":
      return { ...f, job: { ...f.job, score_100: op.score } }
    case "heat_override":
      return { ...f, heat: { ...f.heat, override: true, override_reason: op.reason, decision: "allow" } }
    case "open_fire":
      return f.job.batch?.code === op.batch ? { ...f, job: { ...f.job, batch: { ...f.job.batch, fire: "open_fire" } } } : f
    case "narrative":
      return f.narrative?.id === op.narrative ? { ...f, narrative: { ...f.narrative, body: op.body } } : f
    case "overlay": {
      const mode = op.mode === "inherit" ? "canonical" : op.mode
      const edit = (l: Line): Line => {
        if (l.id !== op.item) return l
        const body = op.mode === "altered" && op.body !== undefined ? op.body : op.mode === "inherit" ? l.canonical_body : l.body
        const title = op.mode === "inherit" ? l.canonical_title : l.title
        return { ...l, mode, shown: mode !== "hidden", body, title, reason: op.mode === "inherit" ? null : op.reason ?? l.reason }
      }
      const cv = {
        ...f.cv,
        facts: f.cv.facts.map(edit),
        sections: f.cv.sections.map((s) => ({ ...s, lines: s.lines.map(edit) })),
        hidden: f.cv.hidden.map(edit),
      }
      const lines = [...cv.facts, ...cv.sections.flatMap((s) => s.lines), ...cv.hidden]
      const count = (m: string) => lines.filter((l) => l.mode === m).length
      return {
        ...f,
        cv,
        masks: f.masks.map(edit),
        job: { ...f.job, mask_hidden: count("hidden"), mask_altered: count("altered"), mask_emphasized: count("emphasized") },
      }
    }
    default:
      return f
  }
}

function applyLanes(l: Lanes, op: Op): Lanes {
  switch (op.kind) {
    case "gym_target": {
      const target = Number.parseInt(op.target, 10)
      return Number.isFinite(target) ? { ...l, gym: { ...l.gym, target } } : l
    }
    case "gym_log": {
      const f = op.fields
      const entry = {
        id: -1, done_on: f["done_on"] || isoDay(today()), outcome: f["outcome"] ?? "", minutes: Number(f["minutes"] ?? 0) || 0,
        note: f["note"] ?? "", title: f["title"] ?? "", url: f["url"] ?? "", platform: f["platform"] ?? "",
        topic: f["topic"] ?? "", difficulty: f["difficulty"] ?? "",
      }
      return { ...l, gym: { ...l.gym, recent: [entry, ...l.gym.recent] } }
    }
    case "net_lane":
      return { ...l, net: { ...l.net, lane: op.url } }
    case "net_log": {
      const f = op.fields
      const entry = { id: -1, kind: f["kind"] ?? "", channel: f["channel"] ?? "", title: f["title"] ?? "", url: f["url"] ?? "", body: f["body"] ?? "", shipped_on: f["shipped_on"] || null }
      return { ...l, net: { ...l.net, recent: [entry, ...l.net.recent] } }
    }
    default:
      return l
  }
}

// ---- the resident documents, from wire tables ----
//
// Table frames carry everything beside the cards: the lookups the card
// columns index into, the scoreboard, the lanes, the interned CV lines,
// root CVs, and one FOCUS frame per job. The small tables are replaced
// whole when a frame carries them; lines upsert by ix; a FOCUS frame is
// kept and decoded when its job is read.

const T = {
  batches: 3, profiles: 4, stages: 5, statuses: 6, freshness: 7, gates: 8, heat_states: 9, bands: 10,
  score: 11, varieties: 12, chart_bands: 13, chart_bins: 14,
  gym: 15, gym_topics: 16, gym_reps: 17, options: 18, net: 19, net_entries: 20, heat_rows: 21,
  narratives: 22, kv: 23, lines: 24, roots: 25, root_sections: 26, root_lines: 27,
  focus: 30, focus_rungs: 31, focus_events: 32, focus_cover: 33, focus_sections: 34, focus_lines: 35, focus_kv: 36,
} as const

type Spec = Record<string, readonly [number, "u32" | "str" | "f64"]>
type Row = Record<string, number | string>

const day = (d: number | string | undefined): string | null => (typeof d !== "number" || d === NONE ? null : isoDay(d))
const opt = (s: number | string | undefined): string | null => (typeof s !== "string" || s === "" ? null : s)
const num = (x: number | string | undefined): number => (typeof x !== "number" || Number.isNaN(x) ? 0 : x)
const s = (x: number | string | undefined): string => (typeof x === "string" ? x : "")
const u = (x: number | string | undefined): number => (typeof x === "number" ? x : 0)

/** Rows of a table as objects, one decode per column. */
function rows(t: Table | undefined, spec: Spec): Row[] {
  if (!t) return []
  const cols = Object.entries(spec).map(([k, [id, type]]) => [k, type === "str" ? t.strs(id) : type === "f64" ? t.f64(id) : t.u32(id)] as const)
  const out: Row[] = []
  for (let i = 0; i < t.n; i++) {
    const r: Row = {}
    for (const [k, col] of cols) r[k] = col[i] ?? 0
    out.push(r)
  }
  return out
}

export interface ProfileFull { id: number; slug: string; name: string; headline: string; summary: string }
interface Ref { slot: number; section: number; line: number }

export class Resident {
  stages: Stage[] = []
  stageFlags: { fireLocked: boolean; hot: boolean; queue: boolean }[] = []
  statuses: string[] = []
  freshness: string[] = []
  gates: string[] = []
  heatStates: string[] = []
  bands: Band[] = []
  batches: (Batch & { id: number })[] = []
  profiles: ProfileFull[] = []
  scoreboard: Scoreboard | null = null
  lanes: Lanes | null = null
  readonly lines = new Map<number, Line>()
  readonly narratives = new Map<number, { id: number; body: string; version: number }>()
  readonly roots = new Map<number, Root>()
  private readonly score = new Map<number, Table>()
  private readonly lane = new Map<number, Table>()
  private kv: { scope: number; key: string; value: string }[] = []
  private rootTables = new Map<number, Table>()
  private readonly focusDocs = new Map<number, Map<number, Table>>()
  private tablesView: Tables | null = null

  get tables(): Tables {
    this.tablesView ??= {
      stages: this.stages, statuses: this.statuses, freshness: this.freshness, gates: this.gates,
      bands: this.bands, batches: this.batches, profiles: this.profiles, heat_states: this.heatStates,
    }
    return this.tablesView
  }

  hasFocus(id: number): boolean { return this.focusDocs.has(id) }

  /** Take what a table frame carries, beside the cards. Answers what changed. */
  ingest(frame: Bytes, kind: number): Change {
    if (kind === KIND.FOCUS) {
      const ts = tables(frame.slice())
      const job = ts.get(T.focus)?.u32(1)[0]
      if (job === undefined) return {}
      this.focusDocs.set(job, ts)
      return { focus: [job] }
    }
    let ts = tables(frame)
    const has = (...ids: number[]) => ids.some((id) => ts.has(id))
    if (!has(T.batches, T.profiles, T.stages, T.statuses, T.freshness, T.gates, T.heat_states, T.bands, T.score, T.varieties,
      T.chart_bands, T.chart_bins, T.gym, T.gym_topics, T.gym_reps, T.options, T.net, T.net_entries, T.heat_rows,
      T.narratives, T.kv, T.lines, T.roots, T.root_sections, T.root_lines)) return {}
    // Some of these tables are kept: read them from a copy the frame's reuse cannot touch.
    ts = tables(frame.slice())
    const c: Change = {}
    if (has(T.stages, T.statuses, T.freshness, T.gates, T.heat_states, T.bands, T.batches, T.profiles)) {
      this.lookups(ts)
      c.rows = true
    }
    if (has(T.score, T.varieties, T.chart_bands, T.chart_bins)) {
      for (const id of [T.score, T.varieties, T.chart_bands, T.chart_bins]) { const t = ts.get(id); if (t) this.score.set(id, t) }
      this.scoreboard = this.buildScore()
      c.scoreboard = true
    }
    if (has(T.gym, T.gym_topics, T.gym_reps, T.options, T.net, T.net_entries, T.heat_rows)) {
      for (const id of [T.gym, T.gym_topics, T.gym_reps, T.options, T.net, T.net_entries, T.heat_rows]) { const t = ts.get(id); if (t) this.lane.set(id, t) }
      this.lanes = this.buildLanes()
      c.lanes = true
    }
    if (has(T.lines)) {
      for (const r of rows(ts.get(T.lines), LINE)) this.lines.set(u(r["ix"]), line(r))
      c.focus = [...this.focusDocs.keys()]
      c.root = true
    }
    if (has(T.narratives)) {
      this.narratives.clear()
      for (const r of rows(ts.get(T.narratives), { id: [1, "u32"], profile: [2, "u32"], body: [3, "str"], version: [4, "u32"] })) {
        this.narratives.set(u(r["profile"]), { id: u(r["id"]), body: s(r["body"]), version: u(r["version"]) })
      }
      c.focus = [...this.focusDocs.keys()]
      c.root = true
    }
    if (has(T.kv)) {
      this.kv = rows(ts.get(T.kv), { scope: [1, "u32"], key: [2, "str"], value: [3, "str"] }).map((r) => ({ scope: u(r["scope"]), key: s(r["key"]), value: s(r["value"]) }))
      c.root = true
    }
    if (has(T.roots, T.root_sections, T.root_lines)) {
      for (const id of [T.roots, T.root_sections, T.root_lines]) { const t = ts.get(id); if (t) this.rootTables.set(id, t) }
      c.root = true
    }
    if (c.root) this.buildRoots()
    return c
  }

  private lookups(ts: Map<number, Table>): void {
    const keyed = (id: number, was: string[]) => {
      const t = ts.get(id)
      if (!t) return was
      const out: string[] = []
      const ix = t.u32(1)
      const keys = t.strs(2)
      for (let i = 0; i < t.n; i++) out[ix[i] ?? i] = keys[i] ?? ""
      return out
    }
    const byIx = (a: Row, b: Row) => u(a["ix"]) - u(b["ix"])
    const stages = ts.get(T.stages)
    if (stages) {
      const r = rows(stages, { ix: [1, "u32"], key: [2, "str"], label: [3, "str"], hint: [4, "str"], fire_locked: [6, "u32"], hot: [7, "u32"], queue: [8, "u32"] }).sort(byIx)
      this.stages = r.map((x) => ({ key: s(x["key"]), label: s(x["label"]), hint: s(x["hint"]) }))
      this.stageFlags = r.map((x) => ({ fireLocked: x["fire_locked"] === 1, hot: x["hot"] === 1, queue: x["queue"] === 1 }))
    }
    this.statuses = keyed(T.statuses, this.statuses)
    this.freshness = keyed(T.freshness, this.freshness)
    this.gates = keyed(T.gates, this.gates)
    this.heatStates = keyed(T.heat_states, this.heatStates)
    const bands = ts.get(T.bands)
    if (bands) {
      this.bands = rows(bands, { ix: [1, "u32"], key: [2, "str"], label: [3, "str"], min: [4, "u32"], max: [5, "u32"] }).sort(byIx)
        .map((b) => ({ key: s(b["key"]), label: s(b["label"]), min: u(b["min"]), max: u(b["max"]) }))
    }
    const batches = ts.get(T.batches)
    if (batches) {
      this.batches = rows(batches, { id: [1, "u32"], code: [2, "str"], ordinal: [3, "u32"], fire: [4, "u32"], status: [5, "str"] }).map((b) => ({
        id: u(b["id"]), code: s(b["code"]), ordinal: u(b["ordinal"]), fire: b["fire"] === 1 ? "open_fire" as const : "hold" as const, status: s(b["status"]),
      }))
    }
    const profiles = ts.get(T.profiles)
    if (profiles) {
      this.profiles = rows(profiles, { id: [1, "u32"], slug: [2, "str"], name: [3, "str"], headline: [4, "str"], summary: [5, "str"] })
        .map((p) => ({ id: u(p["id"]), slug: s(p["slug"]), name: s(p["name"]), headline: s(p["headline"]), summary: s(p["summary"]) }))
    }
    this.tablesView = null
  }

  private buildScore(): Scoreboard | null {
    const r = rows(this.score.get(T.score), {
      fire: [1, "u32"], leftover_unique: [2, "u32"], leftover_noted_on: [3, "u32"], batches_today: [4, "u32"], batches_target: [5, "u32"],
      apps_today: [6, "u32"], apps_target: [7, "u32"], submitted_today: [8, "u32"], cumulative: [9, "u32"], chart_n: [12, "u32"], chart_mean: [13, "f64"],
    })[0]
    if (!r) return null
    const mean = r["chart_mean"]
    return {
      fire: r["fire"] === 1 ? "open_fire" : "hold",
      leftover_unique: u(r["leftover_unique"]),
      leftover_noted_on: day(r["leftover_noted_on"]),
      batches_today: u(r["batches_today"]),
      batches_target: u(r["batches_target"]),
      apps_today: u(r["apps_today"]),
      apps_target: u(r["apps_target"]),
      submitted_today: u(r["submitted_today"]),
      cumulative: u(r["cumulative"]),
      varieties: rows(this.score.get(T.varieties), { code: [1, "str"], fire: [2, "str"], status: [3, "str"], label: [4, "str"] })
        .map((v) => ({ code: s(v["code"]), fire: s(v["fire"]), status: s(v["status"]), label: s(v["label"]) })),
      chart: {
        n: u(r["chart_n"]),
        mean: typeof mean === "number" && !Number.isNaN(mean) ? mean : null,
        bands: rows(this.score.get(T.chart_bands), { key: [1, "str"], label: [2, "str"], min: [3, "u32"], max: [4, "u32"], count: [5, "u32"] })
          .map((b) => ({ key: s(b["key"]), label: s(b["label"]), min: u(b["min"]), max: u(b["max"]), count: u(b["count"]) })),
        bins: rows(this.score.get(T.chart_bins), { lo: [1, "u32"], hi: [2, "u32"], count: [3, "u32"] })
          .map((b) => ({ lo: u(b["lo"]), hi: u(b["hi"]), count: u(b["count"]) })),
      },
    }
  }

  private buildLanes(): Lanes | null {
    const g = rows(this.lane.get(T.gym), { target: [2, "u32"], streak: [3, "u32"], solved_today: [4, "u32"], solved_week: [5, "u32"], score: [6, "u32"] })[0]
    const n = rows(this.lane.get(T.net), { lane: [1, "str"], shipped_week: [2, "u32"], drafts: [3, "u32"], observer_runs: [4, "u32"] })[0]
    if (!g || !n) return null
    const options = rows(this.lane.get(T.options), { group: [1, "str"], key: [2, "str"], label: [3, "str"] })
    const group = (name: string) => options.filter((o) => o["group"] === name).map((o) => ({ key: s(o["key"]), label: s(o["label"]) }))
    const heat = rows(this.lane.get(T.heat_rows), {
      group: [1, "u32"], key: [2, "str"], label: [3, "str"], load: [4, "f64"], cap: [5, "f64"], ratio: [6, "f64"], n: [7, "u32"], cooldown_days: [8, "u32"],
    }).map((r) => ({
      group: u(r["group"]), key: s(r["key"]), label: s(r["label"]), load: num(r["load"]), cap: num(r["cap"]), ratio: num(r["ratio"]),
      n: u(r["n"]), cooldown_days: r["cooldown_days"] === NONE ? null : u(r["cooldown_days"]),
    }))
    const row = ({ group: _, ...rest }: (typeof heat)[number]) => rest
    return {
      gym: {
        target: u(g["target"]), streak: u(g["streak"]), solved_today: u(g["solved_today"]), solved_week: u(g["solved_week"]), score: u(g["score"]),
        topics: rows(this.lane.get(T.gym_topics), { key: [1, "str"], label: [2, "str"], count: [3, "u32"] })
          .map((t) => ({ key: s(t["key"]), label: s(t["label"]), count: u(t["count"]) })),
        recent: rows(this.lane.get(T.gym_reps), {
          id: [1, "u32"], done_on: [2, "u32"], outcome: [3, "str"], minutes: [4, "u32"], note: [5, "str"], platform: [6, "str"],
          title: [8, "str"], topic: [9, "str"], difficulty: [10, "str"], url: [11, "str"],
        }).map((r) => ({
          id: u(r["id"]), done_on: day(r["done_on"]) ?? "", outcome: s(r["outcome"]), minutes: u(r["minutes"]), note: s(r["note"]),
          title: s(r["title"]), url: s(r["url"]), platform: s(r["platform"]), topic: s(r["topic"]), difficulty: s(r["difficulty"]),
        })),
        platforms: group("platform"), topics_all: group("topic"), difficulties: group("difficulty"), outcomes: group("outcome"),
      },
      net: {
        lane: s(n["lane"]), shipped_week: u(n["shipped_week"]), drafts: u(n["drafts"]), observer_runs: u(n["observer_runs"]),
        recent: rows(this.lane.get(T.net_entries), { id: [1, "u32"], kind: [2, "str"], channel: [3, "str"], title: [4, "str"], url: [5, "str"], body: [6, "str"], shipped_on: [7, "u32"] })
          .map((r) => ({ id: u(r["id"]), kind: s(r["kind"]), channel: s(r["channel"]), title: s(r["title"]), url: s(r["url"]), body: s(r["body"]), shipped_on: day(r["shipped_on"]) })),
        kinds: group("net_kind"), channels: group("net_channel"),
      },
      heat: { companies: heat.filter((h) => h.group === 0).map(row), vendors: heat.filter((h) => h.group === 1).map(row) },
    }
  }

  private profile(id: number): ProfileFull {
    return this.profiles.find((p) => p.id === id) ?? { id, slug: "", name: "", headline: "", summary: "" }
  }

  private buildRoots(): void {
    const sections = rows(this.rootTables.get(T.root_sections), { profile: [1, "u32"], kind: [2, "str"], label: [3, "str"] })
    const refs = rows(this.rootTables.get(T.root_lines), { profile: [1, "u32"], slot: [2, "u32"], section: [3, "u32"], line: [4, "u32"] })
    this.roots.clear()
    for (const r of rows(this.rootTables.get(T.roots), ROOT_DOC)) {
      const profile = u(r["profile"])
      this.roots.set(profile, {
        profile: this.profile(profile),
        cv: this.doc(
          r,
          sections.filter((x) => x["profile"] === profile).map((x) => ({ kind: s(x["kind"]), label: s(x["label"]) })),
          refs.filter((x) => x["profile"] === profile).map((x) => ({ slot: u(x["slot"]), section: u(x["section"]), line: u(x["line"]) })),
        ),
        kv: this.kv.filter((k) => k.scope === profile).map(({ key, value }) => ({ key, value })),
        narrative: this.narratives.get(profile) ?? null,
      })
    }
  }

  /** A CV document from its fields, sections and line references (slot 0 facts, 1 sections, 2 hidden). */
  private doc(r: Row, sections: { kind: string; label: string }[], refs: Ref[]): Doc {
    const at = (slot: number, section = -1) =>
      refs.filter((x) => x.slot === slot && (section < 0 || x.section === section)).map((x) => this.lines.get(x.line)).filter((l): l is Line => l !== undefined)
    return {
      label: s(r["cv_label"]),
      person: opt(r["cv_person"]),
      headline: opt(r["cv_headline"]),
      summary: opt(r["cv_summary"]),
      summary_canonical: opt(r["cv_summary_canonical"]),
      summary_reason: opt(r["cv_summary_reason"]),
      accent: s(r["cv_accent"]),
      density: s(r["cv_density"]),
      facts: at(0),
      sections: sections.map((x, i) => ({ kind: x.kind, label: x.label, lines: at(1, i) })),
      hidden: at(2),
    }
  }

  /** One job's focus over its card row, or null until its FOCUS frame has arrived. */
  focus(id: number, card: (col: string) => number, str: (col: string) => string): Focus | null {
    const ts = this.focusDocs.get(id)
    const f = rows(ts?.get(T.focus), FOCUS_DOC)[0]
    if (!ts || !f) return null
    const stage = this.stages[card("stage")]
    const score = card("score")
    const batch = this.batches.find((b) => b.id === card("batch"))
    const profile = this.profile(card("profile"))
    const refs = rows(ts.get(T.focus_lines), { slot: [1, "u32"], section: [2, "u32"], line: [3, "u32"] })
      .map((x) => ({ slot: u(x["slot"]), section: u(x["section"]), line: u(x["line"]) }))
    const cover = rows(ts.get(T.focus_cover), { root: [1, "u32"], hit: [2, "u32"], word: [3, "str"] })
    const coverage = (root: number) => ({
      hits: cover.filter((c) => c["root"] === root && c["hit"] === 1).map((c) => s(c["word"])),
      misses: cover.filter((c) => c["root"] === root && c["hit"] === 0).map((c) => s(c["word"])),
    })
    const cooldown = f["heat_cooldown_days"]
    return {
      job: {
        id, code: `JobApp${id}`,
        company: str("company"), role: str("role"), location: str("location"),
        listing: s(f["listing"]), listing_url: s(f["listing_url"]),
        heat: card("heat"), status: this.statuses[card("status")] ?? "",
        stage: stage?.key ?? "", stage_label: stage?.label ?? "", stage_hint: stage?.hint ?? "",
        pips: str("pips"), score_100: score,
        band: this.bands.find((b) => score >= b.min && score <= b.max)?.key ?? "",
        next_action: str("next_action"), next_due: day(card("next_due")), stage_on: day(card("stage_on")),
        freshness: this.freshness[card("freshness")] ?? "", gate: this.gates[card("gate")] ?? "", fit: str("fit"),
        keyword_hits: card("hits"), keyword_total: card("total"),
        mask_hidden: card("hidden"), mask_altered: card("altered"), mask_emphasized: card("emphasized"),
        batch: batch ? { code: batch.code, fire: batch.fire } : null,
      },
      profile,
      variant: { id: u(f["variant_id"]), label: s(f["variant_label"]) },
      rail: rows(ts.get(T.focus_rungs), { key: [1, "str"], state: [2, "str"], note: [3, "str"] }).map((r) => {
        const st = this.stages.find((x) => x.key === r["key"])
        return { key: s(r["key"]), label: st?.label ?? "", hint: st?.hint ?? "", state: s(r["state"]), note: s(r["note"]) }
      }),
      events: rows(ts.get(T.focus_events), { id: [1, "u32"], kind: [2, "str"], body: [3, "str"] }).map((e) => ({ id: u(e["id"]), kind: s(e["kind"]), body: s(e["body"]) })),
      cv: this.doc(f, rows(ts.get(T.focus_sections), { kind: [1, "str"], label: [2, "str"] }).map((x) => ({ kind: s(x["kind"]), label: s(x["label"]) })), refs),
      narrative: this.narratives.get(profile.id) ?? null,
      coverage: coverage(0),
      root_coverage: coverage(1),
      kv: rows(ts.get(T.focus_kv), { key: [1, "str"], value: [2, "str"] }).map((k) => ({ key: s(k["key"]), value: s(k["value"]) })),
      masks: refs.filter((x) => x.slot === 3).map((x) => this.lines.get(x.line)).filter((l): l is Line => l !== undefined),
      heat: {
        decision: f["heat_decision"] === "defer" ? "defer" : "allow",
        reason: s(f["heat_reason"]),
        company_load: num(f["heat_company_load"]),
        company_cap: num(f["heat_company_cap"]),
        size: opt(f["heat_size"]),
        ats_vendor: s(f["heat_ats_vendor"]),
        cooldown_days: cooldown === NONE ? null : u(cooldown),
        note: s(f["heat_note"]),
        override: f["heat_override"] === 1,
        override_reason: s(f["heat_override_reason"]),
      },
    }
  }
}

const LINE: Spec = {
  ix: [1, "u32"], item: [2, "u32"], kind: [3, "str"], title: [4, "str"], body: [5, "str"], org: [6, "str"], span: [7, "str"],
  shown: [8, "u32"], mode: [9, "str"], reason: [10, "str"], canonical_title: [11, "str"], canonical_body: [12, "str"],
}

function line(r: Row): Line {
  const mode = s(r["mode"])
  return {
    id: u(r["item"]), kind: s(r["kind"]), title: s(r["title"]), body: s(r["body"]), org: s(r["org"]), span: s(r["span"]),
    shown: r["shown"] === 1, mode: (mode === "" ? "canonical" : mode) as Line["mode"], reason: opt(r["reason"]),
    canonical_title: s(r["canonical_title"]), canonical_body: s(r["canonical_body"]),
  }
}

const ROOT_DOC: Spec = {
  profile: [1, "u32"], cv_label: [3, "str"], cv_person: [4, "str"], cv_headline: [5, "str"], cv_summary: [6, "str"],
  cv_summary_canonical: [7, "str"], cv_summary_reason: [8, "str"], cv_accent: [9, "str"], cv_density: [10, "str"],
}

const FOCUS_DOC: Spec = {
  job: [1, "u32"], listing: [2, "str"], listing_url: [3, "str"], variant_id: [4, "u32"], variant_label: [5, "str"],
  cv_label: [11, "str"], cv_person: [12, "str"], cv_headline: [13, "str"], cv_summary: [14, "str"], cv_summary_canonical: [15, "str"],
  cv_summary_reason: [16, "str"], cv_accent: [17, "str"], cv_density: [18, "str"],
  heat_decision: [19, "str"], heat_reason: [20, "str"], heat_company_load: [22, "f64"], heat_company_cap: [23, "f64"],
  heat_size: [25, "str"], heat_ats_vendor: [26, "str"], heat_cooldown_days: [32, "u32"], heat_note: [33, "str"],
  heat_override: [34, "u32"], heat_override_reason: [35, "str"],
}

const EMPTY_U32 = new Uint32Array(0)
const EMPTY_STR: StrColumn = { at: () => "" }
const EMPTY_TABLES: Tables = { stages: [], statuses: [], freshness: [], gates: [], bands: [], batches: [], profiles: [], heat_states: [] }
