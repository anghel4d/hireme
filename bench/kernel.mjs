// The kernel's bounds under WebAssembly (docs/rebuild.md "Tests, bench,
// bounds"): at 10k applications, a derive after a change in ≤ 8 ms and
// the first derive after BOOT in ≤ 30 ms; over 50k places, every read of
// the replica (find with a filter, a sort, a next page; get; text) in
// ≤ 1 ms at p99, the touch budget.
//
//   [DISTINCT=1] bun bench/kernel.mjs <kernel.wasm> [applications=10000] [hot share=0.1]
//
// Seeded synthetic desk: 10k applications over 2,500 companies, a tenth
// of them hot, half with a stored score, listing URLs across a few ATS
// vendors. Measures the derive after BOOT (every card cold) and after a
// one-row PATCH (the steady state a write or a TICK causes), medians of
// repeated runs. Exits 1 when a median passes its bound.

import { W, bootFrame, enc, instance } from "../native/kernel/wasm.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: bun bench/kernel.mjs <kernel.wasm> [applications]");
  process.exit(2);
}
const N = Number(process.argv[3] ?? 10000);
// The share of applications queued, sent or answered: a young campaign is
// mostly cold, a mature one mostly hot.
const HOT = Number(process.argv[4] ?? 0.1);
const BOUND_MS = 8;
const FIRST_BOUND_MS = 30;
// DISTINCT=1: every company, role and location is its own text (one
// application per company, the usual job hunt): the worst-case desk.
const DISTINCT = process.env.DISTINCT === "1";
const bytes = await Bun.file(wasmPath).bytes();

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
    company: DISTINCT ? `Company ${id} Systems` : c < 5 ? ["Google", "Meta", "Anthropic", "Stripe", "Valve"][c] : `Company ${c} Systems`,
    role: DISTINCT ? `${ROLES[rand(ROLES.length)]}, Team ${id}` : ROLES[rand(ROLES.length)],
    location: DISTINCT ? `Remote - City ${id}` : rand(2) ? "Remote" : "Onsite",
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

// Reads of the replica: the replies the world lens and MCP draw from.
const QUERY_BOUND_MS = 1;
const query = {};
{
  // Notes about 5 KB each, packed as the server packs a text cell (tag 1,
  // a zstd frame): a text read unpacks one on touch.
  const WORDS = "walkable transit river rent old town tech scene harbour hills museum quiet loud cheap dear sunny rainy cafes trams bikes startups banks universities parks markets coast north south".split(" ");
  const note = () => Array.from({ length: 820 }, () => WORDS[rand(WORDS.length)]).join(" ");
  const pack = (text) => {
    const z = Bun.zstdCompressSync(new TextEncoder().encode(text));
    const p = new Uint8Array(z.length + 1);
    p[0] = 1;
    p.set(z, 1);
    return p;
  };
  const places = Array.from({ length: 50000 }, (_, i) => ({
    id: i + 1, kind: i < 250 ? "country" : "city", iso2: i < 250 ? `C${i}` : null, name: `${["Lis", "Ber", "Tok"][rand(3)]}${["bon", "lin", "yo"][rand(3)]} ${i}`,
    region: ["Europe", "Asia", "Americas"][rand(3)], population: rand(10) ? rand(10_000_000) : null, population_on: today, notes: rand(10) ? null : pack(note()),
  }));
  const { x, out, call } = await instance(bytes);
  x.set_grants(15, 15, 1, 1);
  if (call(x.ingest, bootFrame(JSON.parse(out(x.catalog())), { places })) < 0) throw new Error("BOOT refused");
  const ask = (q) => { const n = call(x.query, enc.encode(JSON.stringify(q))); if (n < 0) throw new Error(`refused ${JSON.stringify(q)}`); return n; };
  const next = JSON.parse(out(ask({ op: "find", table: "places", order: ["population", "desc"], limit: 50 }))).next;
  const noted = places.find((p) => p.notes).id;
  const cases = {
    find_like: { op: "find", table: "places", where: { name: { like: "berlin" } }, limit: 50 },
    find_sorted: { op: "find", table: "places", order: ["population", "desc"], limit: 50 },
    find_filter_sort: { op: "find", table: "places", where: { region: "Asia", kind: "city" }, order: "name", limit: 50 },
    find_next_page: { op: "find", table: "places", order: ["population", "desc"], limit: 50, after: next },
    get_key: { op: "get", table: "places", key: { iso2: "C7" } },
    text_packed: { op: "text", table: "places", id: noted, column: "notes" },
    find_sizes: { op: "find", table: "places", where: { kind: "city" }, sizes: ["notes"], limit: 50 },
  };
  for (const [name, q] of Object.entries(cases)) {
    for (let i = 0; i < 20; i++) ask(q);
    const ts = [];
    for (let i = 0; i < 200; i++) { const t = performance.now(); ask(q); ts.push(performance.now() - t); }
    query[name] = +ts.sort((a, b) => a - b)[198].toFixed(3);
  }
}

const report = {
  applications: N,
  hot_share: HOT,
  distinct: DISTINCT,
  derive_after_boot_ms: +median(cold).toFixed(2),
  derive_after_patch_ms: +median(warm).toFixed(2),
  filtered_view_ms: +median(filtered).toFixed(2),
  bound_ms: BOUND_MS,
  first_bound_ms: FIRST_BOUND_MS,
  query_p99_ms: query,
  query_bound_ms: QUERY_BOUND_MS,
  wasm_bytes: bytes.length,
};
console.log(JSON.stringify(report));
const queries = Object.values(query).every((p99) => p99 <= QUERY_BOUND_MS);
process.exit(report.derive_after_patch_ms <= BOUND_MS && report.derive_after_boot_ms <= FIRST_BOUND_MS && queries ? 0 : 1);
