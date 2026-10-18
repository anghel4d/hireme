// The kernel's bindings, and the page's one way to read and write.
//
// Resident rows live in the wasm kernel (the same crate the sequencer
// judges with); server-side tables (the world, the mail) and the account
// are read over RPC. A lens reads through this file and writes through
// it: a write is judged and applied locally in the input's frame, sent as
// an op, and settled or rolled back by its ACK or NACK.

import type { Boot } from "./early.ts"
import type { Reply, Wire } from "./wire.ts"
import { AS_OF, ENUMS, REFUSAL, SOURCE, TABLES, type ColumnDef, type TableDef, type TableName } from "./gen/schema.ts"
import { CELL, KIND, OPS_MAX, OP_FLAG, OP_TEXT_MAX, VERB, acks, encodeOp, nacks, opText, opsFrame, type Bytes, type Cell, type Header, type Op } from "./wire.ts"
import { model, notice, set } from "./state.ts"

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
  return new Refused(code, e?.message ?? code, e?.data ?? null)
}

/** One RPC: its result, or a `Refused`. A dropped carrier rejects with a plain Error. */
export async function rpc<T = Record<string, unknown>>(method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!wire) throw new Error("not connected")
  const r = await wire.call(method, params)
  if (!r.ok) throw refusal(r)
  return r.result as T
}

// ------------------------------------------------------------------ rows

/** The instance, once compiled and instantiated; frames that land before it wait. */
let instance: WebAssembly.Instance | null = null
const early: Bytes[] = []

/** The rev the kernel's rows stand at, for HELLO on a reconnect. */
export function snapshotRev(): bigint {
  return instance ? model.rev : 0n
}

/** app.ts: early's compiled module. */
export function load(hw: Boot): void {
  void hw.kernel.then(async (module) => {
    instance = await WebAssembly.instantiate(module, {})
    for (const f of early.splice(0)) ingest(f)
  }).catch((e: unknown) => notice("error", `The kernel did not load: ${String(e)}`))
}

function ingest(f: Bytes): void {
  // The abi's ingest goes here; until it lands the rows are only counted.
  void f
  set({ rows: model.rows + 1 })
}

/** Every frame the shell does not handle itself. */
export function frame(f: Bytes, h: Header): void {
  switch (h.kind) {
    case KIND.BOOT:
    case KIND.PATCH:
    case KIND.TICK:
      if (h.rev > model.rev) model.rev = h.rev
      if (instance) ingest(f)
      else early.push(f.slice())
      return
    case KIND.ACK:
      for (const a of acks(f)) settle(a.opId, { ok: true, id: a.id, rev: a.rev })
      return
    case KIND.NACK:
      for (const n of nacks(f)) settle(n.opId, { ok: false, code: n.code, data: n.data })
      return
  }
}

// ------------------------------------------------------------------ writes

export type Verdict = { ok: true; id: number; rev: bigint } | { ok: false; code: number; data: unknown }

const pending = new Map<bigint, (v: Verdict) => void>()
// Unique per session for the ledger's 24 h: the page's start in the high bits, a counter below.
let nextOp = (BigInt(Date.now()) << 20n) | BigInt(crypto.getRandomValues(new Uint16Array(1))[0] ?? 0)

export const opId = (): bigint => nextOp++

function settle(id: bigint, v: Verdict): void {
  const done = pending.get(id)
  if (!done) return
  pending.delete(id)
  set({ pending: pending.size })
  done(v)
}

/** Sends ops in one OPS frame (at most OPS_MAX); each resolves with its own verdict. */
export function send(ops: readonly Op[]): Promise<Verdict>[] {
  if (!wire) throw new Error("not connected")
  if (ops.length === 0 || ops.length > OPS_MAX) throw new Error(`1..${OPS_MAX} ops per frame`)
  for (const op of ops) if (opText(op) > OP_TEXT_MAX) throw new Refused("too_large", "More than 1 MiB of text in one write.")
  const out = ops.map((op) => new Promise<Verdict>((resolve) => pending.set(op.opId, resolve)))
  set({ pending: pending.size })
  if (!wire.send(opsFrame(wire.hash, ops.map(encodeOp)))) {
    for (const op of ops) settle(op.opId, { ok: false, code: -1, data: { message: "not connected" } })
  }
  return out
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
  if (raw === null || raw === "") return { col: c.id, type: CELL.null, value: null }
  const text = typeof raw === "string" ? raw.trim() : raw
  switch (c.type) {
    case "id":
    case "ref":
    case "u32":
    case "u8": {
      const n = typeof text === "number" ? text : Number(text)
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
      try {
        return { col: c.id, type: CELL.i64, value: BigInt(text) }
      } catch {
        return bad("a whole number")
      }
    case "f64": {
      const n = typeof text === "number" ? text : Number(String(text).replace(/[_,\s]/g, ""))
      if (!Number.isFinite(n)) bad("a number")
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
  for (const [k, val] of Object.entries(set)) cells.push(cell(column(t, k), val))
  if (p.asOf !== undefined) cells.push({ col: AS_OF, type: CELL.u32, value: day(p.asOf) ?? (() => { throw new Refused("freshness", "as_of needs a day, YYYY-MM-DD") })() })
  if (p.source !== undefined && p.source !== "") cells.push({ col: SOURCE, type: typeof p.source === "number" ? CELL.u32 : CELL.str, value: p.source })
  if (p.expectRev !== undefined) flags |= OP_FLAG.EXPECT_REV
  if (p.createOnly) flags |= OP_FLAG.CREATE_ONLY
  return { opId: opId(), verb: VERB.put, flags, target: t.id, id: p.key ? 0 : p.id ?? 0, expectRev: p.expectRev ?? 0, cells }
}

/** One put, sent and settled: the new rev and id, or a `Refused` named from the catalog. */
export async function put(name: TableName, set: Record<string, Input>, p: Put = {}): Promise<{ id: number; rev: bigint }> {
  const [verdict] = send([putOp(name, set, p)])
  const v = await verdict!
  if (v.ok) return { id: v.id, rev: v.rev }
  const data = v.data as { message?: string } | null
  throw new Refused(refusalName(v.code), data?.message ?? refusalName(v.code), v.data)
}
