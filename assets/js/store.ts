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

import type { Focus, Lanes, Line, Root, Scoreboard } from "./api.ts"

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
  /** The desk wants these documents resident, most wanted first. */
  want(focus: readonly number[], root: readonly number[]): void
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
const NONE = 0xffffffff

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
const PIP: Record<string, string> = { done: "D", active: "A", pending: "P", skipped: "S", blocked: "B" }
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
  private readonly asked = new Set<number>()
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

  focus(id: number): Focus | null {
    const hit = this.views.get(id)
    if (hit) return hit
    const base = this.focuses.get(id)
    if (!base) {
      if (!this.asked.has(id)) {
        this.asked.add(id)
        this.link?.want([id], [])
      }
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
      if (!this.asked.has(-profileId)) {
        this.asked.add(-profileId)
        this.link?.want([], [profileId])
      }
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
    const missing = ids.filter((id) => !this.focuses.has(id) && !this.asked.has(id))
    for (const id of missing) this.asked.add(id)
    if (missing.length > 0) this.link?.want(missing, [])
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
    this.asked.delete(f.job.id)
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
    this.asked.delete(-r.profile.id)
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

const EMPTY_U32 = new Uint32Array(0)
const EMPTY_STR: StrColumn = { at: () => "" }
const EMPTY_TABLES: Tables = { stages: [], statuses: [], freshness: [], gates: [], bands: [], batches: [], profiles: [], heat_states: [] }
export { PIP }
