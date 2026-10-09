// Frames and the kernel's exports, for the kernel's test scripts.
//
// The schema is read from priv/wire/schema.txt, frames are encoded here
// independently of both the Elixir encoder and native/wire, and `kernel()`
// wraps one WebAssembly instance with the calling pattern a TypeScript
// facade uses.
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

export const here = path.dirname(fileURLToPath(import.meta.url))
export const repo = path.resolve(here, "../..")
const te = new TextEncoder()
const td = new TextDecoder()

// ---- schema -------------------------------------------------------------

export const S = { frame: {}, table: {}, col: {}, op: {}, refusal: {}, opFields: {}, tableName: {} }
const schemaBytes = fs.readFileSync(path.join(repo, "priv/wire/schema.txt"))
for (const line of td.decode(schemaBytes).split("\n")) {
  const w = line.trim().split(/\s+/)
  if (w[0] === "frame") S.frame[w[1]] = +w[2]
  if (w[0] === "table") (S.table[w[1]] = +w[2]), (S.col[w[1]] = {}), (S.tableName[+w[2]] = w[1])
  if (w[0] === "col") S.col[w[1]][w[2]] = { id: +w[3], kind: w[4] }
  if (w[0] === "op") (S.op[w[1]] = +w[2]), (S.opFields[w[1]] = w.slice(4))
  if (w[0] === "refusal") S.refusal[w[1]] = +w[2]
}
let h = 0x811c9dc5
for (const b of schemaBytes) h = Math.imul(h ^ b, 0x01000193) >>> 0
export const HASH = (h >>> 16) ^ (h & 0xffff)
export const NONE = 0xffffffff
export const wireType = (kind) => ({ u32: 1, day: 1, time: 1, str: 2, u64: 3, f64: 4 })[kind]

// ---- encoding -----------------------------------------------------------

class W {
  bytes = []
  u8(v) { this.bytes.push(v & 0xff) }
  u16(v) { this.u8(v); this.u8(v >>> 8) }
  u32(v) { this.u16(v & 0xffff); this.u16(v >>> 16) }
  u64(v) { this.u32(Number(BigInt(v) & 0xffffffffn)); this.u32(Number(BigInt(v) >> 32n)) }
  f64(v) { const b = new Uint8Array(new Float64Array([v]).buffer); this.raw(b) }
  raw(a) { for (const b of a) this.bytes.push(b) }
  pad(from) { while ((this.bytes.length - from) % 8) this.u8(0) }
}

// tables: [[name, {col: [values]}]]. null is "none": 0xFFFFFFFF, NaN, "".
export function frame(kind, rev, tables = [], body = null) {
  const w = new W()
  w.u32(0), w.u8(S.frame[kind]), w.u8(0), w.u16(HASH), w.u64(rev)
  if (body) w.raw(body)
  for (const [name, cols] of tables) {
    const names = Object.keys(cols)
    const n = names.length ? cols[names[0]].length : 0
    w.u16(S.table[name]), w.u16(names.length), w.u32(n)
    for (const c of names) {
      const def = S.col[name][c]
      if (!def) throw new Error(`no column ${name}.${c}`)
      const ty = wireType(def.kind)
      w.u16(def.id), w.u8(ty), w.u8(0)
      if (ty === 2) {
        const enc = cols[c].map((s) => te.encode(s ?? ""))
        w.u32(4 * (n + 1) + enc.reduce((a, b) => a + b.length, 0))
        let at = 0
        w.u32(0)
        for (const e of enc) w.u32((at += e.length))
        for (const e of enc) w.raw(e)
      } else if (ty === 4) {
        w.u32(n * 8)
        for (const v of cols[c]) w.f64(v ?? NaN)
      } else {
        w.u32(n * 4)
        for (const v of cols[c]) w.u32(v ?? NONE)
      }
      w.pad(0)
    }
  }
  w.pad(0)
  const b = new Uint8Array(w.bytes)
  new DataView(b.buffer).setUint32(0, b.length, true)
  return b
}

export function opBody(id, kind, target, fields) {
  const w = new W()
  w.u64(id), w.u8(S.op[kind]), w.u8(fields.length), w.u16(0), w.u32(target)
  for (const f of fields) {
    const e = te.encode(f)
    w.u16(e.length), w.raw(e)
  }
  return new Uint8Array(w.bytes)
}

export const ack = (id) => frame("ACK", 0, [], opBody(id, "note", 0, []).slice(0, 8))

export function nack(id, code, msg) {
  const w = new W()
  const m = te.encode(msg)
  w.u64(id), w.u8(code), w.u8(0), w.u16(m.length), w.raw(m)
  return frame("NACK", 0, [], w.bytes)
}

export const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((a, p) => a + p.length, 0))
  let at = 0
  for (const p of parts) out.set(p, at), (at += p.length)
  return out
}

// ---- the kernel through its exports --------------------------------------

export async function kernel(wasm) {
  const { instance } = await WebAssembly.instantiate(wasm, {})
  const k = instance.exports
  const mem = () => k.memory.buffer
  const put = (reserve, bytes) => {
    const at = reserve(bytes.length) // may grow memory: take the view after
    new Uint8Array(mem(), at, bytes.length).set(bytes)
  }
  const K = {
    k,
    ingest(bytes) { put(k.ingest_reserve, bytes); return k.ingest_commit(bytes.length) },
    push(bytes) { put(k.scratch, bytes); return k.pending_push(bytes.length) },
    select(f, q) {
      const qb = te.encode(q)
      put(k.scratch, qb)
      const n = k.select(f.min, f.lo, f.hi, f.stage, f.status, f.batch, f.profile, f.heat, qb.length)
      const rows = new Uint32Array(mem(), k.selection_ptr(), n)
      const ids = new Uint32Array(mem(), k.col_ptr(S.table.cards, S.col.cards.id.id), k.rows(1))
      return Array.from(rows, (r) => ids[r])
    },
    str(t, c, row) {
      return td.decode(new Uint8Array(mem(), k.str_ptr(t, c, row), k.str_len(t, c, row)))
    },
    /** One row of any table as {column: value}; absent columns are left out. */
    row(name, row, only = null) {
      const t = S.table[name]
      const out = {}
      for (const [c, def] of Object.entries(S.col[name])) {
        if (only && !only.includes(c)) continue
        const ty = k.col_type(t, def.id)
        if (ty === 0) continue
        if (ty === 2) out[c] = K.str(t, def.id, row)
        else if (ty === 4) out[c] = new Float64Array(mem(), k.col_ptr(t, def.id), k.rows(t))[row]
        else if (ty === 1) out[c] = new Uint32Array(mem(), k.col_ptr(t, def.id), k.rows(t))[row]
      }
      return out
    },
    rows(name, only = null) {
      return Array.from({ length: k.rows(S.table[name]) }, (_, r) => K.row(name, r, only))
    },
    card(id, only = null) {
      const row = k.row_of(S.table.cards, id)
      return row < 0 ? null : K.row("cards", row, only)
    },
    snapshot() { const n = k.snapshot(); return new Uint8Array(mem(), k.snapshot_ptr(), n).slice() },
  }
  return K
}
