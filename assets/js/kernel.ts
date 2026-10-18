// The kernel's bindings, and the page's one way to read and write.
//
// Resident rows live in the wasm kernel (the same crate the sequencer
// judges with); server-side tables (the world, the mail) and the account
// are read over RPC. A lens reads through this file and writes through
// it: a write is judged and applied locally in the input's frame, sent as
// an op, and settled or rolled back by its ACK or NACK.

import type { Boot } from "./early.ts"
import type { Reply, Wire } from "./wire.ts"
import { KIND, OPS_MAX, OP_TEXT_MAX, acks, encodeOp, nacks, opText, opsFrame, type Bytes, type Header, type Op } from "./wire.ts"
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
