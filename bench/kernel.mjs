// The board's bound under WebAssembly (docs/rebuild.md "Tests, bench,
// bounds"): a full board derive at 10k applications in ≤ 8 ms.
//
//   node bench/kernel.mjs <kernel.wasm> [applications=10000] [hot share=0.1]
//
// Seeded synthetic desk: 10k applications over 2,500 companies, a tenth
// of them hot, half with a stored score, listing URLs across a few ATS
// vendors. Measures the derive after BOOT (every card cold) and after a
// one-row PATCH (the steady state a write or a TICK causes), medians of
// repeated runs. Exits 1 when the steady-state median passes the bound.

import { readFileSync } from "node:fs";
import { W, bootFrame, enc, instance } from "../native/kernel/wasm.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: node bench/kernel.mjs <kernel.wasm> [applications]");
  process.exit(2);
}
const N = Number(process.argv[3] ?? 10000);
// The share of applications queued, sent or answered: a young campaign is
// mostly cold, a mature one mostly hot.
const HOT = Number(process.argv[4] ?? 0.1);
const BOUND_MS = 8;
const bytes = readFileSync(wasmPath);

let seed = 0x9e3779b9;
const rand = (n) => {
  seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
  return (seed >>> 0) % n;
};
const STAGES = ["discovered", "freshness", "gated", "in_batch", "draft_ready", "fire_ready", "open_fire", "submitted", "reply", "closed"];
const ROLES = ["Software Engineer", "Senior Software Engineer", "Rust Systems Engineer", "Research Engineer", "SRE", "Full Stack Engineer", "Data Engineer", "Staff Infrastructure Engineer"];
const HOSTS = (c) => [`https://boards.greenhouse.io/c${c}/jobs/1`, `https://jobs.lever.co/c${c}/x`, `https://jobs.ashbyhq.com/c${c}`, `https://c${c}.wd5.myworkdayjobs.com/en-US/x`, `https://c${c}.example.com/careers`];
const today = 739528;

const apps = [];
for (let id = 1; id <= N; id++) {
  const c = rand(2500);
  const hot = rand(1000) < HOT * 1000;
  apps.push({
    id, no: id,
    company: c < 5 ? ["Google", "Meta", "Anthropic", "Stripe", "Valve"][c] : `Company ${c} Systems`,
    role: ROLES[rand(ROLES.length)],
    location: rand(2) ? "Remote" : "Onsite",
    stage: hot ? STAGES[5 + rand(5)] : STAGES[rand(5)],
    stage_on: today - rand(120),
    listing_url: HOSTS(c)[rand(5)],
    score_100: rand(2) ? rand(101) : null,
    heat_override: false,
    keywords: "rust\u001fkernels\u001fgpu",
  });
}

const median = (xs) => xs.slice().sort((a, b) => a - b)[xs.length >> 1];
const cold = [];
const warm = [];
const filtered = [];
for (let run = 0; run < 7; run++) {
  const { x, out, call } = await instance(bytes);
  const catalog = JSON.parse(out(x.catalog()));
  x.set_today(today);
  if (call(x.ingest, bootFrame(catalog, { applications: apps })) < 0) throw new Error("BOOT refused");
  const all = enc.encode("{}");
  let t = performance.now();
  call(x.view, all);
  cold.push(performance.now() - t);
  for (let i = 0; i < 9; i++) {
    const id = 1 + rand(N);
    const patch = bootFrame(catalog, { applications: [{ id, stage: STAGES[rand(10)], stage_on: today }] }, W.PATCH);
    if (call(x.ingest, patch) < 0) throw new Error("PATCH refused");
    t = performance.now();
    call(x.view, all);
    warm.push(performance.now() - t);
    t = performance.now();
    call(x.view, enc.encode(JSON.stringify({ bands: ["systems", "craft"], search: "engineer" })));
    filtered.push(performance.now() - t);
  }
}

const report = {
  applications: N,
  hot_share: HOT,
  derive_after_boot_ms: +median(cold).toFixed(2),
  derive_after_patch_ms: +median(warm).toFixed(2),
  filtered_view_ms: +median(filtered).toFixed(2),
  bound_ms: BOUND_MS,
  wasm_bytes: bytes.length,
};
console.log(JSON.stringify(report));
process.exit(report.derive_after_patch_ms <= BOUND_MS ? 0 : 1);
