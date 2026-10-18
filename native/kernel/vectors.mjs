// Runs tests/vectors.json against kernel.wasm, through the exports the
// browser calls; tests/vectors.rs runs the same file natively.
//
//   bun native/kernel/vectors.mjs path/to/kernel.wasm

import { W, asU32, bootFrame, enc, instance, op } from "./wasm.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: bun vectors.mjs <kernel.wasm>");
  process.exit(2);
}
const file = await Bun.file(`${import.meta.dir}/tests/vectors.json`).json();
const bytes = await Bun.file(wasmPath).bytes();
const OP_ID = 7n;
const KEY_ID = 3;

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
  const { x, mem, out, call } = await instance(bytes);
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
      const ctx = enc.encode(JSON.stringify({ today: kase.today, now: (kase.today - 719528) * 86400, human: step.human ?? false, key_id: KEY_ID, held: [] }));
      const raw = op(catalog, step, OP_ID);
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

// The text-keyed maps' hash seed comes from the host's crypto RNG, never a
// constant: the module cannot be instantiated without the import, and a
// desk's derive draws from it.
{
  const imports = WebAssembly.Module.imports(new WebAssembly.Module(bytes));
  if (!imports.some((i) => i.module === "host" && i.name === "random_u32" && i.kind === "function"))
    failures.push("seed: the module does not import host.random_u32");
  const { x, out, call, draws } = await instance(bytes);
  const catalog = JSON.parse(out(x.catalog()));
  call(x.ingest, bootFrame(catalog, { applications: [{ id: 1, no: 1, company: "Acme", role: "Engineer", stage: "discovered" }] }));
  call(x.view, enc.encode("{}"));
  if (draws.n === 0) failures.push("seed: a derive never drew from host.random_u32");
}

if (failures.length) {
  console.error(`${failures.length} vector failures:\n${failures.join("\n")}`);
  process.exit(1);
}
console.log(`${file.cases.length} vector cases pass under wasm`);
