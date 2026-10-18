// The kernel's bindings, and the page's one way to read and write.
//
// Resident rows live in the wasm kernel (the same crate the sequencer
// judges with); server-side tables (the world, the mail) and the account
// are read over RPC. A lens reads through this file and writes through
// it: a write is judged and applied locally in the input's frame, sent as
// an op, and settled or rolled back by its ACK or NACK.

import type { Boot } from "./early.ts"
import type { Reply, Wire } from "./wire.ts"
import { AS_OF, COMMANDS, ENUMS, REFUSAL, SCHEMA_REV, SOURCE, TABLES, WIRE_HASH, type ColumnDef, type CommandName, type TableDef, type TableName } from "./gen/schema.ts"
import { CELL, KIND, OPS_MAX, OP_FLAG, OP_TEXT_MAX, VERB, acks, encodeOp, header, nackFrame, nacks, opText, opsFrame, type Bytes, type Cell, type Header, type Op } from "./wire.ts"
import { notice, set } from "./state.ts"

let wire: Wire | null = null

/** app.ts hands over the session once the carrier exists. */
export function attach(w: Wire): void {
  wire = w
}

/** A refusal from the server: the catalog's refusal name (or an account.* error code) and its data. */
export class Refused extends Error {
  constructor(readonly code: string, message: string, readonly data: unknown = null) {
    super(message)
  }
}

function refusal(r: Reply & { ok: false }): Refused {
  // Sequencer and world refusals say {code, message, data}; account.* says {error}.
  const e = r.error as { code?: string; error?: string; message?: string; data?: unknown } | null
  const code = e?.code ?? e?.error ?? "internal"
  // The node's message is often the code again; the data says what decided it.
  const message = e?.message && e.message !== code ? e.message : refusalText(code, e?.data ?? null)
  return new Refused(code, message, e?.data ?? null)
}

/** One RPC: its result, or a `Refused`. A dropped carrier rejects with a plain Error. */
export async function rpc<T = Record<string, unknown>>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!wire) throw new Error("not connected")
  const r = await wire.call(method, params)
  if (!r.ok) throw refusal(r)
  return r.result as T
}

// ------------------------------------------------------------------ rows

/** The wasm exports, per native/kernel/src/abi.rs: one result buffer, read before the next call. */
interface Exports {
  memory: WebAssembly.Memory
  alloc(len: number): number
  dealloc(ptr: number, len: number): void
  result_ptr(): number
  wire_hash(): number
  set_today(day: number): void
  ingest(ptr: number, len: number): number
  predict(op: number, opLen: number, ctx: number, ctxLen: number): number
  judge(op: number, opLen: number, ctx: number, ctxLen: number): number
  view(ptr: number, len: number): number
  step(ptr: number, len: number, selected: number, dir: number, columns: number): number
  card(id: number): number
  scoreboard(): number
  application(id: number): number
  overview(top: number): number
  atlas(ptr: number, len: number): number
  lanes(): number
  snapshot(): number
  restore(ptr: number, len: number): bigint
  rows(t: number): number
  ids_ptr(t: number): number
  col_ptr(t: number, c: number): number
  col_kind(t: number, c: number): number
  str_ptr(t: number, c: number, id: number): number
  str_len(t: number, c: number, id: number): number
}

let k: Exports | null = null
/** Frames that land before the instance does, in order. */
const early: Bytes[] = []
const ENC = new TextEncoder()
const DEC = new TextDecoder()

/** Calls `fn` with `bytes` copied into the module's memory, freed after. */
function withBytes<T>(bytes: Uint8Array, fn: (ptr: number, len: number) => T): T {
  const x = k!
  const ptr = x.alloc(bytes.byteLength)
  new Uint8Array(x.memory.buffer, ptr, bytes.byteLength).set(bytes)
  try {
    return fn(ptr, bytes.byteLength)
  } finally {
    x.dealloc(ptr, bytes.byteLength)
  }
}

const result = (len: number): Uint8Array => new Uint8Array(k!.memory.buffer, k!.result_ptr(), len)
const resultJson = <T>(len: number): T | null => (len < 0 ? null : (JSON.parse(DEC.decode(result(len))) as T))

export const ready = (): boolean => k !== null

/** The rev the rows stand at: from BOOT, PATCH and TICK headers and the snapshot, never from WELCOME. */
let rowsRev = 0n

/** What HELLO names on a reconnect, so the server sends only what moved since. */
export function snapshotRev(): bigint {
  return k ? rowsRev : 0n
}

/** app.ts: early's compiled module and snapshot. The snapshot goes in before any frame. */
export function load(hw: Boot): void {
  void (async () => {
    const module = await hw.kernel
    const inst = await WebAssembly.instantiate(module, {})
    const x = inst.exports as unknown as Exports
    if (x.wire_hash() !== WIRE_HASH) throw new Error("kernel.wasm was built against another schema")
    x.set_today(Math.floor(Date.now() / DAY_MS))
    // The snapshot goes in before any frame: frames wait in `early` until `k` is set, so a
    // BOOT that beat a slow snapshot read is never replaced by the older snapshot.
    // A BOOT already queued replaces every table anyway: go live now rather than wait on the read.
    const booted = early.some((f) => header(f).kind === KIND.BOOT)
    const snap = booted ? undefined : await hw.snap.catch(() => undefined)
    k = x
    if (snap) {
      const rev = withBytes(snap.bytes, (p, n) => x.restore(p, n))
      if (rev >= 0n) {
        rowsRev = rev
      } else if (wire) {
        // HELLO named a snapshot the kernel refused: only a whole BOOT puts the rows right.
        rowsRev = 0n
        early.length = 0
        wire.restart()
      }
    }
    for (const f of early.splice(0)) if (!ingest(f)) break
    moved()
  })().catch((e: unknown) => notice("error", `The kernel did not load: ${String(e)}`))
}

/** Bumped whenever rows move; derived views are cached against it. */
let version = 0
const slots = new Map<number, { version: number; at: Map<number, number> }>()

function moved(): void {
  version++
  set({ rows: version })
  saveSoon()
}

/**
 * One frame into the kernel. The rows' rev moves only once the frame has
 * applied: on a failure the kernel has already dropped its derived state, so
 * the rev goes to 0 and the session restarts, and HELLO asks for a whole BOOT
 * instead of resuming from a frame that never landed.
 */
function ingest(f: Uint8Array): boolean {
  if (withBytes(f, (p, n) => k!.ingest(p, n)) < 0) {
    rowsRev = 0n
    early.length = 0
    notice("warn", "The desk fell out of step with the server; reloading it.")
    wire?.restart()
    return false
  }
  const h = header(f as Bytes)
  if ((h.kind === KIND.BOOT || h.kind === KIND.PATCH || h.kind === KIND.TICK) && h.rev > rowsRev) rowsRev = h.rev
  return true
}

let advanced: () => void = () => {}

/** app.ts: called when a PATCH moves the account's rev, so server-side reads go stale. */
export function onAdvance(fn: () => void): void {
  advanced = fn
}

/** Every frame the shell does not handle itself. */
export function frame(f: Bytes, h: Header): void {
  if (h.kind === KIND.PATCH && h.rev > rowsRev && rowsRev !== 0n) advanced()
  if (h.kind === KIND.ACK) for (const a of acks(f)) settle(a.opId, { ok: true, id: a.id, rev: a.rev })
  if (h.kind === KIND.NACK) for (const n of nacks(f)) settle(n.opId, { ok: false, code: n.code, data: n.data })
  // The kernel takes the whole frame: rows, and the settle or rollback of pending writes.
  if (h.kind === KIND.BOOT || h.kind === KIND.PATCH || h.kind === KIND.TICK || h.kind === KIND.ACK || h.kind === KIND.NACK) {
    if (k) {
      if (ingest(f)) moved()
    } else {
      early.push(f.slice())
    }
  }
}

// ------------------------------------------------------------------ reading rows

/** A resident table's ids in slot order. */
export function ids(name: TableName): Uint32Array {
  if (!k) return new Uint32Array(0)
  const t = TABLES[name].id
  const n = k.rows(t)
  return n === 0 ? new Uint32Array(0) : new Uint32Array(k.memory.buffer, k.ids_ptr(t), n).slice()
}

function slot(t: number, id: number): number {
  let s = slots.get(t)
  if (!s || s.version !== version) {
    const at = new Map<number, number>()
    const n = k!.rows(t)
    const view = new Uint32Array(k!.memory.buffer, k!.ids_ptr(t), n)
    for (let i = 0; i < n; i++) at.set(view[i]!, i)
    s = { version, at }
    slots.set(t, s)
  }
  return s.at.get(id) ?? -1
}

/** One decoded value of a resident row: enum by name, day as YYYY-MM-DD, time as a Date; null when empty. */
export function value(name: TableName, id: number, col: string): string | number | boolean | Date | null {
  if (!k) return null
  const t = TABLES[name]
  const c = t.cols.find((x) => x.name === col)
  if (!c) return null
  const kind = k.col_kind(t.id, c.id)
  if (kind === 2) {
    const len = k.str_len(t.id, c.id, id)
    return len === 0 ? null : DEC.decode(new Uint8Array(k.memory.buffer, k.str_ptr(t.id, c.id, id), len))
  }
  const i = slot(t.id, id)
  if (i < 0 || kind === 0) return null
  const ptr = k.col_ptr(t.id, c.id)
  if (kind === 1) {
    const x = new Uint32Array(k.memory.buffer, ptr, i + 1)[i]!
    if (x === 0xffff_ffff) return null
    switch (c.type) {
      case "enum":
        return values(c.enum)[x] ?? null
      case "bool":
        return x === 1
      case "day":
        return dayText(x)
      case "time":
        return new Date(x * 1000)
      default:
        return x
    }
  }
  if (kind === 3) {
    const x = new BigInt64Array(k.memory.buffer, ptr, i + 1)[i]!
    return x === -(2n ** 63n) ? null : Number(x)
  }
  if (kind === 4) {
    const x = new Float64Array(k.memory.buffer, ptr, i + 1)[i]!
    return Number.isNaN(x) ? null : x
  }
  return null
}

// ------------------------------------------------------------------ derived documents

export interface Filter {
  bands?: string[]
  stages?: string[]
  classes?: string[]
  min_score?: number
  search?: string
}

const views = new Map<string, { version: number; ids: Uint32Array }>()

/** Application ids the filter keeps, in board order (score, then heat). */
export function board(f: Filter): Uint32Array {
  if (!k) return new Uint32Array(0)
  const key = JSON.stringify(f)
  const hit = views.get(key)
  if (hit && hit.version === version) return hit.ids
  const len = withBytes(ENC.encode(key), (p, n) => k!.view(p, n))
  const out = len <= 0 ? new Uint32Array(0) : new Uint32Array(result(len).slice().buffer)
  if (views.size > 16) views.clear()
  views.set(key, { version, ids: out })
  return out
}

export const DIR = { next: 0, prev: 1, up: 2, down: 3, first: 4, last: 5 } as const

/** The card after `selected` in a direction, over the filtered board; 0 for none. */
export function step(f: Filter, selected: number, dir: number, columns: number): number {
  if (!k) return 0
  // An id comes back through an i32: read it unsigned, or a temp id past 2^31 turns negative.
  return withBytes(ENC.encode(JSON.stringify(f)), (p, n) => k!.step(p, n, selected, dir, columns)) >>> 0
}

export interface Card {
  score_100: number
  stored: boolean
  band: string
  class: string
  stage: string
  ratio: number
  reason: string
}

export const card = (id: number): Card | null => (k ? resultJson<Card>(k.card(id)) : null)
export const scoreboard = (): Record<string, unknown> | null => (k ? resultJson(k.scoreboard()) : null)
export const application = (id: number): Record<string, unknown> | null => (k ? resultJson(k.application(id)) : null)
export const lanes = (): Record<string, unknown> | null => (k ? resultJson(k.lanes()) : null)
export const atlas = (preset: string): Record<string, unknown> | null =>
  k ? resultJson(withBytes(ENC.encode(preset), (p, n) => k!.atlas(p, n))) : null

/** The ctx the kernel judges a browser write in: the operator, today. */
function ctx(): Uint8Array {
  return ENC.encode(JSON.stringify({ today: Math.floor(Date.now() / DAY_MS), now: Math.floor(Date.now() / 1000), human: true, key_id: null, held: [] }))
}

/** Judges an op on the local rows and applies it as pending; a refusal is the kernel's own verdict. */
function predict(op: Op): void {
  if (!k) return
  const bytes = encodeOp(op)
  const c = ctx()
  const r = withBytes(bytes, (p, n) => withBytes(c, (q, m) => k!.predict(p, n, q, m)))
  if (r < 0) {
    const refusal = JSON.parse(DEC.decode(result(-r - 1))) as { refusal: string; data: unknown }
    throw new Refused(refusal.refusal, refusalText(refusal.refusal, refusal.data), refusal.data)
  }
  moved()
}

// ------------------------------------------------------------------ snapshot

let saving = 0

/** The base rows go to IndexedDB a few seconds after they stop moving, keyed by the shell's scope. */
function saveSoon(): void {
  clearTimeout(saving)
  saving = window.setTimeout(save, 4000)
}

let savedRev = -1n

/**
 * The session ended for good (signed out, revoked, suspended): the desk's
 * snapshot leaves this browser's storage with it, and nothing more is saved.
 */
export function forget(): void {
  clearTimeout(saving)
  savedRev = -2n
  try {
    indexedDB.deleteDatabase("hireme")
  } catch {
    // Storage is blocked: there is nothing stored to delete.
  }
}

function save(): void {
  const scope = document.querySelector<HTMLMetaElement>('meta[name="hireme-scope"]')?.content ?? ""
  // A TICK moves no row: the snapshot is written only when the rows' rev has.
  if (!k || scope === "" || !("indexedDB" in window) || pending.size > 0 || rowsRev === savedRev || rowsRev === 0n || savedRev === -2n) return
  const len = k.snapshot()
  if (len <= 0) return
  const bytes = result(len).slice()
  const record = { rev: rowsRev, schemaRev: BigInt(SCHEMA_REV), wireHash: WIRE_HASH, bytes }
  let open: IDBOpenDBRequest
  try {
    open = indexedDB.open("hireme", 1)
  } catch {
    return
  }
  savedRev = rowsRev
  open.onerror = () => {}
  open.onupgradeneeded = () => open.result.createObjectStore("snap")
  open.onsuccess = () => {
    try {
      open.result.transaction("snap", "readwrite").objectStore("snap").put(record, scope)
    } catch {
      // A private window or a full disk: the next BOOT is whole, nothing else changes.
    }
  }
}

// ------------------------------------------------------------------ writes

export type Verdict = { ok: true; id: number; rev: bigint } | { ok: false; code: number; data: unknown }

/** Ops sent and not yet answered, with their bytes and how often a new session has resent them. */
const pending = new Map<bigint, { done: (v: Verdict) => void; bytes: Bytes; resent: number }>()
/** A write resent into this many fresh sessions without an answer is one the server cannot read. */
const RESENDS = 3
// Unique per session for the ledger's 24 h: the page's start in the high bits, a counter below.
let nextOp = (BigInt(Date.now()) << 20n) | BigInt(crypto.getRandomValues(new Uint16Array(1))[0] ?? 0)

export const opId = (): bigint => nextOp++

function settle(id: bigint, v: Verdict): void {
  const done = pending.get(id)
  if (!done) return
  pending.delete(id)
  set({ pending: pending.size })
  done.done(v)
}

/** What send() would refuse, checked before a prediction is applied. */
function sendable(op: Op): void {
  if (!wire) throw new Error("not connected")
  if (opText(op) > OP_TEXT_MAX) throw new Refused("too_large", "More than 1 MiB of text in one write.")
}

/** Sends ops in OPS frames (at most OPS_MAX each, under the frame limit); each resolves with its own verdict. */
export function send(ops: readonly Op[]): Promise<Verdict>[] {
  if (!wire) throw new Error("not connected")
  if (ops.length === 0 || ops.length > OPS_MAX) throw new Error(`1..${OPS_MAX} ops per frame`)
  for (const op of ops) sendable(op)
  const bytes = ops.map(encodeOp)
  const out = ops.map((op, i) => new Promise<Verdict>((resolve) => pending.set(op.opId, { done: resolve, bytes: bytes[i]!, resent: 0 })))
  set({ pending: pending.size })
  // Offline, the ops wait: the reconnect resends them, and the ledger answers a resent op once.
  for (const f of frames(bytes)) wire.send(opsFrame(wire.hash, f))
  return out
}

/** The node takes WebSocket frames up to 2 MiB: ops go in as many OPS frames as that needs. */
const FRAME_BYTES = 1_900_000

function frames(ops: readonly Bytes[]): Bytes[][] {
  const out: Bytes[][] = []
  let size = 0
  for (const op of ops) {
    const last = out[out.length - 1]
    if (!last || last.length >= OPS_MAX || size + op.byteLength > FRAME_BYTES) {
      out.push([op])
      size = 24 + op.byteLength
    } else {
      last.push(op)
      size += op.byteLength
    }
  }
  return out
}

/** app.ts, when a session opens: every unanswered op again, as it was. */
export function resend(): void {
  if (!wire || pending.size === 0) return
  // A write that ends every session it is sent into (a frame the server refuses to read) is
  // dropped after RESENDS tries: rolled back in the kernel and refused to its caller, so it
  // cannot hold the page in a reconnect loop.
  for (const [id, p] of pending) {
    if (++p.resent <= RESENDS) continue
    if (k) ingest(nackFrame(wire.hash, id, REFUSAL.indexOf("internal"), "the server could not read this write"))
    settle(id, { ok: false, code: REFUSAL.indexOf("internal"), data: { message: "the server never answered this write; check whether it landed before writing it again" } })
    moved()
  }
  if (pending.size === 0) return
  for (const f of frames([...pending.values()].map((p) => p.bytes))) wire.send(opsFrame(wire.hash, f))
}

// ------------------------------------------------------------------ typed puts

/** What a field holds before it is a cell: an input's text, a checkbox, a number, or null to clear. */
export type Input = string | number | boolean | null

export const table = (name: TableName): TableDef => TABLES[name]

export function column(t: TableDef, name: string): ColumnDef {
  const c = t.cols.find((x) => x.name === name)
  if (!c) throw new Refused("column", `${t.name} has no column ${name}`)
  return c
}

/** An enum's values by its declared name (`stage` → STAGE). */
export const values = (name: string | null): readonly string[] => (name === null ? [] : ENUMS[name] ?? [])

export const refusalName = (code: number): string => REFUSAL[code] ?? (code < 0 ? "session" : `refusal ${code}`)

/** A refusal's words: its message if it has one, else the data that decided it ("gated → submitted: needs_batch"). */
export function refusalText(code: string, data: unknown): string {
  const d = (data ?? {}) as Record<string, unknown>
  if (typeof d.message === "string" && d.message !== "") return d.message
  const parts: string[] = []
  if (d.from !== undefined || d.to !== undefined) parts.push(`${String(d.from ?? "?")} → ${String(d.to ?? "?")}`)
  for (const [k2, x] of Object.entries(d)) {
    if (k2 === "from" || k2 === "to" || k2 === "refusal") continue
    parts.push(`${k2.replace(/_/g, " ")} ${typeof x === "object" ? JSON.stringify(x) : String(x)}`)
  }
  return parts.length > 0 ? parts.join(", ") : code.replace(/_/g, " ")
}

const DAY_MS = 86_400_000

export function day(s: string): number | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null
  const t = Date.parse(`${s}T00:00:00Z`)
  return Number.isNaN(t) || new Date(t).toISOString().slice(0, 10) !== s ? null : t / DAY_MS
}

export const dayText = (d: number): string => new Date(d * DAY_MS).toISOString().slice(0, 10)

export const today = (): string => new Date().toISOString().slice(0, 10)

/** A typed cell for one column; the server never casts, so the type is decided here. */
export function cell(c: { id: number; name: string; type: ColumnDef["type"]; enum: string | null }, raw: Input): Cell {
  const bad = (what: string): never => {
    throw new Refused("type", `${c.name} needs ${what}`)
  }
  const text = typeof raw === "string" && c.type !== "str" && c.type !== "text" ? raw.trim() : raw
  if (text === null || text === "") return { col: c.id, type: CELL.null, value: null }
  // Number() reads "0x10", "1e3" and " " too; a cell takes plain digits only.
  const whole = (t: string | number | boolean): number => (typeof t === "number" ? t : /^-?\d+$/.test(String(t)) ? Number(t) : Number.NaN)
  switch (c.type) {
    case "id":
    case "ref":
    case "u32":
    case "u8": {
      const n = whole(text)
      if (!Number.isInteger(n) || n < 0 || n >= (c.type === "u8" ? 256 : 0xffff_ffff)) bad("a whole number")
      return { col: c.id, type: CELL.u32, value: n }
    }
    case "bool":
      return { col: c.id, type: CELL.u32, value: text === true || text === "true" || text === "on" ? 1 : text === false || text === "false" ? 0 : bad("yes or no") }
    case "enum": {
      const i = values(c.enum).indexOf(String(text))
      if (i < 0) bad(`one of ${values(c.enum).join(", ")}`)
      return { col: c.id, type: CELL.u32, value: i }
    }
    case "day": {
      const d = day(String(text))
      return { col: c.id, type: CELL.u32, value: d ?? bad("a day, YYYY-MM-DD") }
    }
    case "time": {
      const t = Date.parse(String(text))
      if (Number.isNaN(t)) bad("a time")
      return { col: c.id, type: CELL.u32, value: Math.floor(t / 1000) }
    }
    case "i64":
      if (typeof text !== "number" && !/^-?\d+$/.test(String(text))) return bad("a whole number")
      return { col: c.id, type: CELL.i64, value: BigInt(text) }
    case "f64": {
      // A comma is refused rather than guessed: "3,5" is three and a half in half the world.
      const n = typeof text === "number" ? text : /^-?\d+(\.\d+)?([eE][-+]?\d+)?$/.test(String(text)) ? Number(text) : Number.NaN
      if (!Number.isFinite(n)) bad("a number, with a point for decimals")
      return { col: c.id, type: CELL.f64, value: n }
    }
    case "json":
      try {
        return { col: c.id, type: CELL.str, value: JSON.stringify(typeof text === "string" ? JSON.parse(text) : text) }
      } catch {
        return bad("JSON")
      }
    case "str":
    case "text":
      return { col: c.id, type: CELL.str, value: String(raw) }
    default:
      return bad("a value this page cannot write")
  }
}

export interface Put {
  /** Update this row. */
  id?: number
  /** Or upsert by a natural key. */
  key?: Record<string, Input>
  asOf?: string
  /** A URL, or an existing sources id. */
  source?: string | number
  expectRev?: number
  createOnly?: boolean
}

export function putOp(name: TableName, set: Record<string, Input>, p: Put = {}): Op {
  const t = table(name)
  const cells: Cell[] = []
  let flags = 0
  if (p.key) {
    flags |= OP_FLAG.KEYED
    for (const [k, val] of Object.entries(p.key)) cells.push(cell(column(t, k), val))
  }
  for (const [k, val] of Object.entries(set)) {
    // A key column named again in set is the same cell; the server refuses a frame that names one twice.
    if (p.key && k in p.key) {
      if (String(p.key[k] ?? "") !== String(val ?? "")) throw new Refused("column", `${k} is the key; change it by id, not in the same put`)
      continue
    }
    cells.push(cell(column(t, k), val))
  }
  if (p.asOf !== undefined) cells.push({ col: AS_OF, type: CELL.u32, value: day(p.asOf) ?? (() => { throw new Refused("freshness", "as_of needs a day, YYYY-MM-DD") })() })
  if (p.source !== undefined && p.source !== "") cells.push({ col: SOURCE, type: typeof p.source === "number" ? CELL.u32 : CELL.str, value: p.source })
  if (p.expectRev !== undefined) flags |= OP_FLAG.EXPECT_REV
  if (p.createOnly) flags |= OP_FLAG.CREATE_ONLY
  return { opId: opId(), verb: VERB.put, flags, target: t.id, id: p.key ? 0 : p.id ?? 0, expectRev: p.expectRev ?? 0, cells }
}

/** One put, sent and settled: the new rev and id, or a `Refused` named from the catalog. */
export async function put(name: TableName, set: Record<string, Input>, p: Put = {}): Promise<{ id: number; rev: bigint }> {
  const op = putOp(name, set, p)
  sendable(op)
  if (TABLES[name].residency === "resident") predict(op)
  const [verdict] = send([op])
  const v = await verdict!
  if (v.ok) return { id: v.id, rev: v.rev }
  throw new Refused(refusalName(v.code), refusalText(refusalName(v.code), v.data), v.data)
}

/** A declared command on one row, judged locally first when its table is resident. */
export async function command(name: CommandName, target: number, params: Record<string, Input> = {}): Promise<{ id: number; rev: bigint }> {
  const c = COMMANDS[name]
  const cells: Cell[] = []
  for (const p of c.params) {
    const raw = params[p.name]
    if (raw === undefined) {
      if (p.required) throw new Refused("column", `${name} needs ${p.name}`)
      continue
    }
    cells.push(cell(p, raw))
  }
  const op: Op = { opId: opId(), verb: VERB.command, flags: 0, target: c.id, id: target, expectRev: 0, cells }
  sendable(op)
  if (TABLES[c.table as TableName].residency === "resident") predict(op)
  const [verdict] = send([op])
  const v = await verdict!
  if (v.ok) return { id: v.id, rev: v.rev }
  throw new Refused(refusalName(v.code), refusalText(refusalName(v.code), v.data), v.data)
}

const lookups = new Map<string, { version: number; at: Map<string, number> }>()

/** The id of the resident row whose `col` equals `key` (an application by its no). */
export function lookup(name: TableName, col: string, key: string): number {
  const k2 = `${name}.${col}`
  let l = lookups.get(k2)
  if (!l || l.version !== version) {
    const at = new Map<string, number>()
    for (const id of ids(name)) {
      const x = value(name, id, col)
      if (x !== null) at.set(String(x), id)
    }
    l = { version, at }
    lookups.set(k2, l)
  }
  return l.at.get(key) ?? 0
}
