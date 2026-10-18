// The kernel's wasm exports from JavaScript: instantiate, build BOOT and
// PATCH frames from rows named by the catalog, encode one op. Shared by
// vectors.mjs and bench/kernel.mjs; run directly it does nothing.

export const NONE = 0xffffffff;
export const enc = new TextEncoder();
export const dec = new TextDecoder();

// Wire constants from the codec's doc (native/wire/src/lib.rs).
export const W = { NULL: 0, U32: 1, STR: 2, I64: 3, F64: 4, DEFERRED: 5, BOOT: 3, PATCH: 4, PUT: 1, COMMAND: 3 };

export class Bytes {
  constructor() { this.a = []; }
  u8(v) { this.a.push(v & 255); return this; }
  u16(v) { return this.u8(v).u8(v >> 8); }
  u32(v) { const b = new DataView(new ArrayBuffer(4)); b.setUint32(0, v >>> 0, true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  u64(v) { const b = new DataView(new ArrayBuffer(8)); b.setBigUint64(0, BigInt(v), true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  i64(v) { const b = new DataView(new ArrayBuffer(8)); b.setBigInt64(0, BigInt(v), true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  f64(v) { const b = new DataView(new ArrayBuffer(8)); b.setFloat64(0, v, true); this.a.push(...new Uint8Array(b.buffer)); return this; }
  raw(u8s) { for (const b of u8s) this.a.push(b); return this; }
  pad() { while (this.a.length % 8) this.a.push(0); return this; }
  get length() { return this.a.length; }
  bytes() { return Uint8Array.from(this.a); }
}

// The host's crypto RNG, the kernel's one import: it seeds the hash of
// text-keyed maps, which must not be predictable (lib.rs `keyed`).
export const host = (draws = { n: 0 }) => ({
  imports: { host: { random_u32: () => (draws.n++, crypto.getRandomValues(new Uint32Array(1))[0]) } },
  draws,
});

export async function instance(bytes) {
  const h = host();
  const { instance } = await WebAssembly.instantiate(bytes, h.imports);
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
  return { x, mem, out, call, draws: h.draws };
}

export function enumCode(catalog, target, name) {
  const i = (catalog.enums[target] ?? []).indexOf(name);
  if (i < 0) throw new Error(`no ${name} in enum ${target}`);
  return i;
}

// type_code 3 is enum (schema::Type::code order: id ref enum bool ...).
const ENUM = 3;

export function asU32(catalog, v, type, target) {
  if (v === null || v === undefined) return NONE;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (typeof v === "string" && type === ENUM) return enumCode(catalog, target, v);
  if (typeof v === "number") return v;
  throw new Error(`${JSON.stringify(v)} is not a u32`);
}

export function bootFrame(catalog, rows, kind = W.BOOT) {
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
  frame.u32(16 + body.length).u8(kind).u8(0).u16(catalog.wire_hash).u64(1).raw(body.a);
  return frame.bytes();
}

export function cell(o, catalog, id, wire, type, target, v) {
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

export function op(catalog, step, opId = 7n) {
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
  o.u64(opId).u8(verb).u8(0).u16(subject).u32(target).u16(cells.length).u16(0).u32(0);
  for (const [c, v] of cells) cell(o, catalog, c.id, c.wire, c.type, c.target, v);
  return o.bytes();
}
