// The kernel's bindings, and the page's one way to read and write.
//
// Resident rows live in the wasm kernel (the same crate the sequencer
// judges with); every lens reads them here, in the frame it draws. The
// account is changed over RPC. A write is judged and applied locally in the
// input's frame, sent as an op, and settled or rolled back by its ACK or
// NACK.

import type { Boot } from "./early.ts"
import type { Wire } from "./wire.ts"
import { AS_OF, COMMANDS, DAY_MAX, ENUMS, REFUSAL, SCHEMA_REV, SOURCE, TABLES, WIRE_HASH, type ColumnDef, type CommandName, type TableDef, type TableName } from "./gen/schema.ts"
import { describe } from "./guard.ts"
import { CELL, KIND, OPS_MAX, OP_FLAG, OP_TEXT_MAX, VERB, acks, encodeOp, header, nackFrame, nacks, opText, opsFrame, type Bytes, type Cell, type Header, type Op } from "./wire.ts"
import { notice, set } from "./state.ts"

/** A row as the kernel answers it: a column name to its value. */
export type Row = Record<string, unknown>

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

/** A failed write told in a notice: a refusal by its catalog code. */
export const failed = (e: unknown): void => notice("error", e instanceof Refused ? said(e) : describe(e))

/** What a refusal means to the person who made the write: a plain sentence first, the node's words after it. */
const SAID: Partial<Record<string, string>> = {
  rev: "Someone changed this before your edit landed, so your edit was undone. Open it again to see their version.",
  stale: "A newer figure is already stored, so this older one was not saved.",
  leased: "An agent is working on this application right now, so the change was not saved.",
  lease_missing: "This session cannot write right now.",
  scope: "This key is not allowed to change that.",
  human_only: "Only you can do that, from the desk.",
  fire_hold: "Fire is on hold for this batch.",
  rate: "Too many changes at once. Wait a moment and try again.",
  internal: "Something went wrong on the server. Nothing was saved.",
}

function said(e: Refused): string {
  const lead = SAID[e.code]
  // The node's own words name the mechanism (expect_rev, a table); a mapped refusal keeps them for the console.
  if (lead) console.info(`refused ${e.code}: ${e.message}`)
  return lead ?? e.message.charAt(0).toUpperCase() + e.message.slice(1)
}

/** One RPC: its result, or a `Refused`. A dropped carrier rejects with a plain Error. */
export async function rpc<T = Row>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!wire) throw new Error("not connected")
  const r = await wire.call(method, params)
  if (r.ok) return r.result as T
  // Sequencer and world refusals say {code, message, data}; account.* says {error}.
  const e = r.error as { code?: string; error?: string; message?: string; data?: unknown } | null
  const code = e?.code ?? e?.error ?? "internal"
  // The node's message is often the code again; the data says what decided it.
  throw new Refused(code, e?.message && e.message !== code ? e.message : refusalText(code, e?.data ?? null), e?.data ?? null)
}

// ------------------------------------------------------------------ rows

/** The wasm exports, per native/kernel/src/abi.rs: one result buffer, read before the next call. */
export interface Exports {
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
  atlas(): number
  snapshot(): number
  restore(ptr: number, len: number): bigint
  set_grants(readMask: number, writeMask: number, mayDelete: number, human: number): void
  query(ptr: number, len: number): number
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
let bootArrived: () => void = () => {}
/** Settles when a BOOT is queued before the kernel is live. */
const bootQueued = new Promise<void>((r) => (bootArrived = r))
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
/** The kernel's refusal in its result buffer (a negative return, -n - 1 its length). */
function refused(r: number): Refused {
  const e = JSON.parse(DEC.decode(result(-r - 1))) as { refusal?: string; code?: unknown; data?: unknown }
  const code = typeof e.refusal === "string" ? e.refusal : String(e.code ?? "internal")
  return new Refused(code, refusalText(code, e.data ?? null), e.data ?? null)
}

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
    // The kernel's one import: the host's crypto RNG seeds its text-keyed hash maps,
    // which agent-written names must not be able to aim collisions at.
    const inst = await WebAssembly.instantiate(module, { host: { random_u32: () => crypto.getRandomValues(new Uint32Array(1))[0] } })
    const x = inst.exports as unknown as Exports
    if (x.wire_hash() !== WIRE_HASH) throw new Error("kernel.wasm was built against another schema")
    x.set_today(todayDay())
    // Frames wait in `early` until `k` is set, so a BOOT that beat a slow snapshot read is never
    // replaced by the older snapshot; and a BOOT replaces every table anyway, so if one is queued, or
    // arrives before the read answers, the kernel goes live without the snapshot.
    const snap = early.some((f) => header(f).kind === KIND.BOOT)
      ? undefined
      : await Promise.race([hw.snap.catch(() => undefined), bootQueued.then(() => undefined)])
    // The page's BOOT goes ahead of the socket's train, which resumes from it.
    const boot = snap ? undefined : hw.boot()
    k = x
    x.set_grants(...grants, 1)
    let restored = false
    if (snap) {
      const rev = withBytes(snap.bytes, (p, n) => x.restore(p, n))
      if (rev >= 0n) {
        rowsRev = rev
        restored = true
      } else if (wire) {
        // HELLO named a snapshot the kernel refused: only a whole BOOT puts the rows right.
        rowsRev = 0n
        early.length = 0
        wire.restart()
      }
    }
    if (boot) early.unshift(boot)
    for (const f of early.splice(0)) if (!ingest(f)) break
    // The snapshot paints first; the cold derive (the board, a card) runs once that paint is on
    // screen, so first paint never waits on it. Warm is set only together with what ends it, so a
    // load that fails before here never leaves the lenses waiting.
    warm = restored
    moved()
    if (warm) afterPaint(() => {
      warm = false
      moved()
    })
  })().catch((e: unknown) => {
    warm = false
    broke = true
    // The root cause of whatever fails after it: pinned, so the symptoms' notices never push it out.
    notice("error", `The kernel did not load: ${describe(e).slice(0, 300)}`, 0, true)
  })
}

/**
 * This session's grants from WELCOME, for the replica's reads: what it may read answers, the rest is
 * scope. Until WELCOME, a browser's session is the operator's (every domain), which WELCOME narrows.
 */
let grants: [number, number, number] = [31, 31, 1]
export function setGrants(read: number, write: number, mayDelete: boolean): void {
  grants = [read, write, mayDelete ? 1 : 0]
  k?.set_grants(...grants, 1)
  version++
}

let broke = false
/** Whether the kernel failed to load: then no lens that reads the replica will draw, and the page says so. */
export const broken = (): boolean => broke

/** Whether the replica is in: before it is, its lenses wait rather than draw nothing. */
export const loaded = (): boolean => k !== null

/** Restored rows whose first derive has not run yet: the lenses that derive wait one paint. */
let warm = false
export const warming = (): boolean => warm

/** `fn` once the next frame has painted (a frame, then a task), or after 250 ms where frames do not
 * come (a background tab). */
function afterPaint(fn: () => void): void {
  let done = false
  const go = () => {
    if (done) return
    done = true
    fn()
  }
  requestAnimationFrame(() => setTimeout(go, 0))
  setTimeout(go, 250)
}

/** Bumped whenever rows move; derived views are cached against it. */
let version = 0

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

/** Every frame the shell does not handle itself. */
export function frame(f: Bytes, h: Header): void {
  if (h.kind === KIND.ACK) for (const a of acks(f)) settle(a.opId, { ok: true, id: a.id, rev: a.rev })
  if (h.kind === KIND.NACK) for (const n of nacks(f)) settle(n.opId, { ok: false, code: n.code, data: n.data })
  // The kernel takes the whole frame: rows, and the settle or rollback of pending writes.
  if (h.kind === KIND.BOOT || h.kind === KIND.PATCH || h.kind === KIND.TICK || h.kind === KIND.ACK || h.kind === KIND.NACK) {
    if (k) {
      if (ingest(f)) moved()
    } else {
      early.push(f.slice())
      if (h.kind === KIND.BOOT) bootArrived()
    }
  }
}

// ------------------------------------------------------------------ reading rows

/**
 * Answers of the replica's reads and documents, per version: a view drawn twice in a frame asks once,
 * and drawn again with no row moved (a filter chip, a subtab, a fold, a form opening) it is not
 * composed and parsed again. Lenses only read them.
 */
const answers = new Map<string, unknown>()
let answered = -1
function memo<T>(key: string, make: () => T): T {
  if (answered !== version) {
    answers.clear()
    answered = version
  }
  if (answers.has(key)) return answers.get(key) as T
  const doc = make()
  answers.set(key, doc)
  return doc
}

/** An index over the rows, built once per version. */
function indexed<K, V>(store: Map<K, { version: number; at: V }>, key: K, build: () => V): V {
  let s = store.get(key)
  if (!s || s.version !== version) {
    s = { version, at: build() }
    store.set(key, s)
  }
  return s.at
}

/**
 * A read of the replica, in the input's frame: World's find, get, text and history, answered by the
 * kernel from the rows it holds (op and params as World's RPC took them). A refusal is a `Refused`.
 */
export function query<T = Row>(op: "find" | "get" | "text" | "history" | "cv_pick" | "cv_picks" | "cv_explain" | "mask_check" | "mask_fields", params: Record<string, unknown>): T {
  if (!k) throw new Error("the desk is still loading")
  const req = JSON.stringify({ op, ...params })
  return memo(req, () => {
    const n = withBytes(ENC.encode(req), (p, len) => k!.query(p, len))
    if (n < 0) throw refused(n)
    return JSON.parse(DEC.decode(result(n))) as T
  })
}

/** A row of the replica by id, or null when there is none (or no id). */
export function row(table: string, id: number): Row | null {
  if (!id) return null
  try {
    return query<{ row: Row }>("get", { table, id }).row
  } catch {
    return null
  }
}

/** The first `limit` rows a find names (its table, cols, where, order), in pages of find's 500; `more` when the table goes on. */
export function page(params: Record<string, unknown>, limit: number): { rows: Row[]; more: boolean } {
  const rows: Row[] = []
  let after: unknown = null
  while (rows.length < limit) {
    const r = query<{ rows: Row[]; next: unknown }>("find", { ...params, limit: Math.min(500, limit - rows.length), ...(after === null ? {} : { after }) })
    rows.push(...r.rows)
    after = r.next ?? null
    if (after === null) return { rows, more: false }
  }
  return { rows, more: true }
}

/** A table's ids in slot order, as a view of the kernel's memory (good until the next call). */
function idsOf(t: number): Uint32Array {
  const n = k!.rows(t)
  return n === 0 ? new Uint32Array(0) : new Uint32Array(k!.memory.buffer, k!.ids_ptr(t), n)
}

/** A resident table's ids in slot order. */
export const ids = (name: TableName): Uint32Array => (k ? idsOf(TABLES[name].id).slice() : new Uint32Array(0))

const slots = new Map<number, { version: number; at: Map<number, number> }>()
function slot(t: number, id: number): number {
  return indexed(slots, t, () => {
    const at = new Map<number, number>()
    idsOf(t).forEach((x, i) => at.set(x, i))
    return at
  }).get(id) ?? -1
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

const lookups = new Map<string, { version: number; at: Map<string, number> }>()

/** The id of the resident row whose `col` equals `key` (an application by its no). */
export function lookup(name: TableName, col: string, key: string): number {
  const k2 = `${name}.${col}`
  // A write seldom moves the key: an id found before is checked alone, and the map rebuilt only
  // when it no longer answers (a unique key, like an application's no).
  const l = lookups.get(k2)
  const was = l?.at.get(key)
  if (l && l.version !== version && was !== undefined && String(value(name, was, col)) === key) return was
  return indexed(lookups, k2, () => {
    const at = new Map<string, number>()
    for (const id of ids(name)) {
      const x = value(name, id, col)
      if (x !== null) at.set(String(x), id)
    }
    return at
  }).get(key) ?? 0
}

/** The one me row's id, 0 before the operator has saved anything about themself. */
export const meId = (): number => ids("me")[0] ?? 0

// ------------------------------------------------------------------ derived documents

export interface Filter {
  bands?: string[]
  stages?: string[]
  classes?: string[]
  min_score?: number
  search?: string
}

/** Application ids the filter keeps, in board order (score, then heat). */
export function board(f: Filter): Uint32Array {
  if (!k) return new Uint32Array(0)
  const key = JSON.stringify(f)
  return memo(`board:${key}`, () => {
    const len = withBytes(ENC.encode(key), (p, n) => k!.view(p, n))
    return len <= 0 ? new Uint32Array(0) : new Uint32Array(result(len).slice().buffer)
  })
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

export const card = (id: number): Card | null => (k ? memo(`card:${id}`, () => resultJson<Card>(k!.card(id))) : null)
export const scoreboard = (): Row | null => (k ? memo("scoreboard", () => resultJson(k!.scoreboard())) : null)
export const application = (id: number): Row | null => (k ? memo(`application:${id}`, () => resultJson(k!.application(id))) : null)
export const atlas = (): Row | null => (k ? memo("atlas", () => resultJson(k!.atlas())) : null)

/** Judges an op on the local rows and applies it as pending; a refusal is the kernel's own verdict. */
function predict(op: Op): void {
  if (!k) return
  const bytes = encodeOp(op)
  // The ctx the kernel judges a browser write in: the operator, today.
  const c = ENC.encode(JSON.stringify({ today: todayDay(), now: Math.floor(Date.now() / 1000), human: true, key_id: null, held: [] }))
  const r = withBytes(bytes, (p, n) => withBytes(c, (q, m) => k!.predict(p, n, q, m)))
  if (r < 0) throw refused(r)
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
    for (const key of Object.keys(localStorage)) if (key.startsWith(SNAP_FLAG)) localStorage.removeItem(key)
  } catch {
    // Storage is blocked: there is nothing stored to delete.
  }
}
/** early.ts reads it before HELLO, synchronously: a snapshot is stored for this scope (set once one is written). */
const SNAP_FLAG = "hireme-snap:"

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
    // Closed as soon as the write settles (and whenever a delete asks), so forget() is never blocked by this page.
    const db = open.result
    db.onversionchange = () => db.close()
    try {
      const tx = db.transaction("snap", "readwrite")
      tx.onerror = tx.onabort = () => db.close()
      tx.oncomplete = () => {
        db.close()
        try {
          localStorage.setItem(SNAP_FLAG + scope, "1")
        } catch {
          // Without the flag the next load simply asks the server for a whole BOOT.
        }
      }
      tx.objectStore("snap").put(record, scope)
    } catch {
      db.close()
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

function settle(id: bigint, v: Verdict): void {
  const done = pending.get(id)
  if (!done) return
  pending.delete(id)
  set({ pending: pending.size })
  done.done(v)
}

/** The node takes WebSocket frames up to 2 MiB: ops go in as many OPS frames as that needs, at most OPS_MAX each. */
const FRAME_BYTES = 1_900_000

function sendAll(ops: readonly Bytes[]): void {
  const frames: Bytes[][] = []
  let size = 0
  for (const op of ops) {
    const last = frames[frames.length - 1]
    if (!last || last.length >= OPS_MAX || size + op.byteLength > FRAME_BYTES) {
      frames.push([op])
      size = 24 + op.byteLength
    } else {
      last.push(op)
      size += op.byteLength
    }
  }
  for (const f of frames) wire!.send(opsFrame(wire!.hash, f))
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
  if (pending.size > 0) sendAll([...pending.values()].map((p) => p.bytes))
}

/**
 * One op: judged by the replica first (its refusal throws here, in the caller's frame, so a form can
 * stay open with its input), applied as pending when its table is resident, and sent; the
 * sequencer's verdict is the promise, a refusal named from the catalog. Offline, the op waits: the
 * reconnect resends it, and the ledger answers a resent op once.
 */
function write(op: Op, resident: boolean): Promise<{ id: number; rev: bigint }> {
  if (!wire) throw new Error("not connected")
  // Refused before the prediction is applied, so the page never shows a write that will not be sent.
  if (wire.ended) throw new Refused("session", "This session has ended; sign in again to write.")
  if (opText(op) > OP_TEXT_MAX) throw new Refused("too_large", "More than 1 MiB of text in one write.")
  if (resident) predict(op)
  const bytes = encodeOp(op)
  const verdict = new Promise<Verdict>((resolve) => pending.set(op.opId, { done: resolve, bytes, resent: 0 }))
  set({ pending: pending.size })
  sendAll([bytes])
  return verdict.then((v) => {
    if (v.ok) return { id: v.id, rev: v.rev }
    const code = REFUSAL[v.code] ?? (v.code < 0 ? "session" : `refusal ${v.code}`)
    throw new Refused(code, refusalText(code, v.data), v.data)
  })
}

// ------------------------------------------------------------------ typed puts

/** What a field holds before it is a cell: an input's text, a checkbox, a number, or null to clear. */
export type Input = string | number | boolean | null

function column(t: TableDef, name: string): ColumnDef {
  const c = t.cols.find((x) => x.name === name)
  if (!c) throw new Refused("column", `${t.name} has no column ${name}`)
  return c
}

/** An enum's values by its declared name (`stage` → STAGE). */
export const values = (name: string | null): readonly string[] => (name === null ? [] : ENUMS[name] ?? [])

/** A refusal's words: its message if it has one, else the data that decided it ("gated → submitted: needs_batch"). */
function refusalText(code: string, data: unknown): string {
  const d = (data ?? {}) as Record<string, unknown>
  if (typeof d.message === "string" && d.message !== "") return d.message
  // The reason leads in its own words (the node gives every refusal one, its code's if the site named
  // none); the other fields follow in parentheses. reason_default only says which it was.
  const reason = typeof d.reason === "string" && d.reason !== "" ? d.reason : null
  const parts: string[] = []
  if (d.from !== undefined || d.to !== undefined) parts.push(`${String(d.from ?? "?")} → ${String(d.to ?? "?")}`)
  for (const [k2, x] of Object.entries(d)) {
    if (["from", "to", "refusal", "reason", "reason_default", "message"].includes(k2)) continue
    parts.push(`${k2.replace(/_/g, " ")} ${typeof x === "object" ? JSON.stringify(x) : String(x)}`)
  }
  if (reason) return parts.length > 0 ? `${reason} (${parts.join(", ")})` : reason
  return parts.length > 0 ? parts.join(", ") : code.replace(/_/g, " ")
}

// The wire's `day` counts days from 0000-01-01 (proleptic Gregorian, Elixir's
// Date.to_gregorian_days/1); the clock counts from 1970-01-01. Every day the
// client reads, writes or hands the kernel goes through these.
const DAY_MS = 86_400_000
/** Days from 0000-01-01 to 1970-01-01. */
const EPOCH_DAYS = 719_528

/** A 'YYYY-MM-DD' day as the wire's day number, or null when malformed. */
function day(s: string): number | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return null
  const t = Date.parse(`${s}T00:00:00Z`)
  if (Number.isNaN(t) || new Date(t).toISOString().slice(0, 10) !== s) return null
  const d = t / DAY_MS + EPOCH_DAYS
  return d >= 0 && d <= DAY_MAX ? d : null
}

/** A wire day number as 'YYYY-MM-DD'. */
const dayText = (d: number): string => new Date((d - EPOCH_DAYS) * DAY_MS).toISOString().slice(0, 10)

/** Today by this browser's clock, as the wire's day number, and as 'YYYY-MM-DD'. */
const todayDay = (): number => Math.floor(Date.now() / DAY_MS) + EPOCH_DAYS
export const today = (): string => dayText(todayDay())

/** A typed cell for one column; the server never casts, so the type is decided here. */
function cell(c: { id: number; name: string; type: ColumnDef["type"]; enum: string | null }, raw: Input): Cell {
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

/** One put, predicted into the replica now and sent (see `write`). */
export function put(name: TableName, set: Record<string, Input>, p: Put = {}): Promise<{ id: number; rev: bigint }> {
  const t = TABLES[name]
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
  return write({ opId: nextOp++, verb: VERB.put, flags, target: t.id, id: p.key ? 0 : p.id ?? 0, expectRev: p.expectRev ?? 0, cells }, t.residency === "resident")
}


/** A put to the one me row (Me), created when there is none yet. */
export const putMe = (set: Record<string, Input>): Promise<{ id: number; rev: bigint }> => put("me", set, meId() === 0 ? {} : { id: meId() })

/** A row dropped (soft-deleted where its table keeps them), predicted like a put. */
export function drop(name: TableName, id: number): Promise<{ id: number; rev: bigint }> {
  const t = TABLES[name]
  return write({ opId: nextOp++, verb: VERB.drop, flags: 0, target: t.id, id, expectRev: 0, cells: [] }, t.residency === "resident")
}

/** A declared command on one row, judged locally first (a refusal throws here), its verdict the promise. */
export function command(name: CommandName, target: number, params: Record<string, Input> = {}): Promise<{ id: number; rev: bigint }> {
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
  return write({ opId: nextOp++, verb: VERB.command, flags: 0, target: c.id, id: target, expectRev: 0, cells }, TABLES[c.table as TableName].residency === "resident")
}
