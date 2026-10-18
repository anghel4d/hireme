// Runs tests/vectors.json against kernel.wasm, through the exports the
// browser calls; tests/vectors.rs runs the same file natively.
//
//   node native/kernel/vectors.mjs path/to/kernel.wasm

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: node vectors.mjs <kernel.wasm>");
  process.exit(2);
}
const file = JSON.parse(readFileSync(join(here, "tests/vectors.json"), "utf8"));
const bytes = readFileSync(wasmPath);
const OP_ID = 7n;
const KEY_ID = 3;
const NONE = 0xffffffff;
const enc = new TextEncoder();
const dec = new TextDecoder();

// Wire constants from the codec's doc (native/wire/src/lib.rs).
const W = { NULL: 0, U32: 1, STR: 2, I64: 3, F64: 4, DEFERRED: 5, BOOT: 3, PUT: 1, COMMAND: 3 };

class Bytes {
  constructor() { this.a = []; }
  u8(v) { this.a.push(v & 255); return this; }
  u16(v) { return this.u8(v).u8(v >> 8); }
  u32(v) { const b = new DataView(new ArrayBuffer(4)); b.setUint32(0, v >>> 0, true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  u64(v) { const b = new DataView(new ArrayBuffer(8)); b.setBigUint64(0, BigInt(v), true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  i64(v) { const b = new DataView(new ArrayBuffer(8)); b.setBigInt64(0, BigInt(v), true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  f64(v) { const b = new DataView(new ArrayBuffer(8)); b.setFloat64(0, v, true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  raw(u8s) { this.a.push(...u8s); return this; }
  pad() { while (this.a.length % 8) this.a.push(0); return this; }
  get length() { return this.a.length; }
  bytes() { return Uint8Array.from(this.a); }
}

async function instance() {
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const x = instance.exports;
  const mem = () => new Uint8Array(x.memory.buffer);
  const put = (u8s) => {
    const p = x.alloc(u8s.length);
    mem().set(u8s, p);
    return [p, u8s.length];
  };
  const out = (n) => dec.decode(mem().slice(x.result_ptr(), x.result_ptr() + n));
  const call = (fn, ...bufs) => {
    const args = bufs.flatMap((b) => put(b));
    const n = fn(...args);
    for (let i = 0; i < args.length; i += 2) x.dealloc(args[i], args[i + 1]);
    return n;
  };
  return { x, mem, out, call };
}

function enumCode(catalog, target, name) {
  const i = (catalog.enums[target] ?? []).indexOf(name);
  if (i < 0) throw new Error(`no ${name} in enum ${target}`);
  return i;
}

// type_code 3 is enum (schema::Type::code order: id ref enum bool ...).
const ENUM = 3;

function asU32(catalog, v, type, target) {
  if (v === null || v === undefined) return NONE;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (typeof v === "string" && type === ENUM) return enumCode(catalog, target, v);
  if (typeof v === "number") return v;
  throw new Error(`${JSON.stringify(v)} is not a u32`);
}

function bootFrame(catalog, rows) {
  const body = new Bytes();
  for (const [name, list] of Object.entries(rows)) {
    const t = catalog.tables[name];
    const cols = [...new Set(list.flatMap((r) => Object.keys(r)))].map((k) => {
      if (!t.cols[k]) throw new Error(`no column ${name}.${k}`);
      return [k, t.cols[k]];
    });
    body.u16(t.id).u16(cols.length).u32(list.length);
    for (const [k, c] of cols) {
      const data = new Bytes();
      const vals = list.map((r) => r[k] ?? null);
      if (c.wire === W.U32) vals.forEach((v) => data.u32(asU32(catalog, v, c.type, c.target)));
      else if (c.wire === W.STR) {
        const strs = vals.map((v) => enc.encode(v ?? ""));
        let o = 0;
        data.u32(0);
        for (const s of strs) data.u32((o += s.length));
        for (const s of strs) data.raw(s);
      } else if (c.wire === W.I64) vals.forEach((v) => data.i64(v ?? -(2n ** 63n)));
      else if (c.wire === W.F64) vals.forEach((v) => data.f64(v ?? NaN));
      else throw new Error(`wire type ${c.wire} in a vector`);
      body.u16(c.id).u8(c.wire).u8(0).u32(data.length).raw(data.a).pad();
    }
  }
  const frame = new Bytes();
  frame.u32(16 + body.length).u8(W.BOOT).u8(0).u16(catalog.wire_hash).u64(1).raw(body.a);
  return frame.bytes();
}

function cell(o, catalog, id, wire, type, target, v) {
  const data = new Bytes();
  let ty;
  if (v === null) ty = W.NULL;
  else if (wire === W.U32) { ty = W.U32; data.u32(asU32(catalog, v, type, target)); }
  else if (wire === W.STR || wire === W.DEFERRED) { ty = W.STR; data.raw(enc.encode(v)); }
  else if (wire === W.I64) { ty = W.I64; data.i64(v); }
  else if (wire === W.F64) { ty = W.F64; data.f64(v); }
  else throw new Error(`cell ${id} = ${v}`);
  o.u16(id).u8(ty).u8(0).u32(data.length).raw(data.a).pad();
}

function op(catalog, step) {
  const target = step.target ?? 0;
  const o = new Bytes();
  let verb, subject, cells;
  if (step.put) {
    const t = catalog.tables[step.put];
    verb = W.PUT; subject = t.id;
    cells = Object.entries(step.cells).map(([k, v]) => [t.cols[k], v]);
  } else {
    const c = catalog.commands[step.command];
    verb = W.COMMAND; subject = c.id;
    cells = Object.entries(step.params ?? {}).map(([k, v]) => {
      if (!c.params[k]) throw new Error(`no param ${step.command}.${k}`);
      return [c.params[k], v];
    });
  }
  o.u64(OP_ID).u8(verb).u8(0).u16(subject).u32(target).u16(cells.length).u16(0).u32(0);
  for (const [c, v] of cells) cell(o, catalog, c.id, c.wire, c.type, c.target, v);
  return o.bytes();
}

function holds(expected, actual, at) {
  if (expected !== null && typeof expected === "object" && !Array.isArray(expected)) {
    if (actual === null || typeof actual !== "object") return `${at}: ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`;
    for (const [k, v] of Object.entries(expected)) {
      const e = holds(v, actual[k] ?? null, `${at}.${k}`);
      if (e) return e;
    }
    return null;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length)
      return `${at}: ${JSON.stringify(actual)}, expected ${expected.length} items`;
    for (let i = 0; i < expected.length; i++) {
      const e = holds(expected[i], actual[i], `${at}[${i}]`);
      if (e) return e;
    }
    return null;
  }
  if (typeof expected === "number" && typeof actual === "number")
    return Math.abs(expected - actual) <= 1e-12 * Math.max(Math.abs(expected), 1) ? null : `${at}: ${actual}, expected ${expected}`;
  return expected === actual ? null : `${at}: ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`;
}

function expectedEffects(catalog, effects) {
  return effects.map((row) => {
    const t = catalog.tables[row.table];
    const cells = {};
    for (const [k, v] of Object.entries(row.cells)) {
      const c = t.cols[k];
      cells[k] = c && c.wire === W.U32 && (typeof v === "string" || typeof v === "boolean") ? asU32(catalog, v, c.type, c.target) : v;
    }
    return { table: row.table, id: row.id, cells };
  });
}

const failures = [];
for (const kase of file.cases) {
  const { x, mem, out, call } = await instance();
  const catalog = JSON.parse(out(x.catalog()));
  x.set_today(kase.today);
  if (call(x.ingest, bootFrame(catalog, kase.rows)) < 0) {
    failures.push(`${kase.name}: BOOT refused`);
    continue;
  }
  kase.steps.forEach((step, i) => {
    const at = `${kase.name} / step ${i}`;
    let err;
    if (step.view) {
      const n = call(x.view, enc.encode(JSON.stringify(step.view)));
      const ids = [...new Uint32Array(mem().slice(x.result_ptr(), x.result_ptr() + n).buffer)];
      err = holds(step.ids, ids, at);
    } else if (step.doc) {
      let n;
      if (step.doc === "atlas") n = call(x.atlas, enc.encode(step.arg ?? ""));
      else if (step.doc === "lanes") n = x.lanes();
      else if (step.doc === "overview") n = x.overview(10);
      else if (step.doc === "application") n = x.application(step.arg);
      err = n < 0 ? `${at}: no document` : holds(step.expect, JSON.parse(out(n)), at);
    } else {
      const ctx = enc.encode(JSON.stringify({ today: kase.today, now: kase.today * 86400, human: step.human ?? false, key_id: KEY_ID, held: [] }));
      const raw = op(catalog, step);
      const n = call(x.judge, raw, ctx);
      if (n >= 0) {
        const got = JSON.parse(out(n));
        if (step.refusal) err = `${at}: allowed ${JSON.stringify(got)}, expected ${step.refusal}`;
        else {
          err = holds(expectedEffects(catalog, step.effects), got, at);
          if (step.apply && call(x.predict, raw, ctx) < 0) err = `${at}: predict refused`;
        }
      } else {
        const got = JSON.parse(out(-n - 1));
        err = step.refusal ? holds({ refusal: step.refusal, data: step.data ?? {} }, got, at) : `${at}: refused ${JSON.stringify(got)}`;
      }
    }
    if (err) failures.push(err);
  });
}

if (failures.length) {
  console.error(`${failures.length} vector failures:\n${failures.join("\n")}`);
  process.exit(1);
}
console.log(`${file.cases.length} vector cases pass under wasm`);
