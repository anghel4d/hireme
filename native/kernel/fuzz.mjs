// Arbitrary text through the wasm exports, seeded: a desk whose every text
// column is arbitrary, then the board, every document, writes of arbitrary
// text, and a snapshot round trip. Passes when nothing traps and each seed
// stays under its time bound. tests/unicode.rs is the native twin.
//
//   bun native/kernel/fuzz.mjs <kernel.wasm>

import { bootFrame, enc, instance, op } from "./wasm.mjs";

const wasmPath = process.argv[2];
if (!wasmPath) {
  console.error("usage: bun fuzz.mjs <kernel.wasm>");
  process.exit(2);
}
const bytes = await Bun.file(wasmPath).bytes();
const TODAY = 739528;
const SEEDS = 12;
const BOUND_MS = 3000;

const PIECES = [
  "0", "7", "250", "401", "1.2", "45.000", ",", ".", "k", "K", "m", "M", "$", "€", "£", "¥", "°", "%", "+", "#",
  "&", ";", "&amp;", "&#x26;", "<", ">", "<style>", "</script>", "<!--", "-->", "(", ")", "(k)", "[", "](", "http://",
  "www.", "://", "?", "=", "/", " ", " ", "\t", "\n", "\u001f", "\u0000", "é", "é", "̈", "İ", "ß", "ẞ",
  "Ƕ", "ɓ", "Æ", "ø", "ł", "й", "한", "日本", "🙂", "👩‍💻", "‮", "مهندس", "מהנדס", "﻿", "�",
  "퟿", "", "\u{10ffff}", "usd", "eur", "rust", "c++", "c#", "node.js", "e.g.", "Engineer", "Senior",
  "Google", "Anthropic", "staffing", "intern", "onsite only", "remote", "greenhouse.io", "jobs.lever.co",
];

let state = 0n;
const rand = (n) => {
  state ^= (state << 13n) & 0xffffffffffffffffn;
  state ^= state >> 7n;
  state ^= (state << 17n) & 0xffffffffffffffffn;
  return Number(state % BigInt(n));
};
const text = (max) => {
  if (rand(16) === 0) return PIECES[rand(PIECES.length)].repeat(1 + rand(20000));
  let s = "";
  for (let i = rand(max + 1); i > 0; i--) s += PIECES[rand(PIECES.length)];
  return s;
};

const failures = [];
for (let seed = 1; seed <= SEEDS; seed++) {
  state = (BigInt(seed) * 0x9e3779b97f4a7c15n) & 0xffffffffffffffffn || 1n;
  const t0 = performance.now();
  try {
    const { x, out, call } = await instance(bytes);
    const catalog = JSON.parse(out(x.catalog()));
    x.set_today(TODAY);
    const n = 30;
    const applications = Array.from({ length: n }, (_, i) => ({
      id: i + 1, no: i + 1, stage: catalog.enums.stage[i % 10], corporation_id: 1 + (i % 3), place_id: 1,
      stage_on: TODAY, company: text(12), role: text(12), location: text(12), comp_raw: text(12),
      listing_url: text(12), keywords: text(12), stage_notes: text(6), cv_theme: text(6),
    }));
    const rows = {
      applications,
      items: applications.map((a) => ({ id: a.id, key: text(4), title: text(8), body: text(12) })),
      settings: [{ id: 1, heat_config: text(6) }],
      me: [{ id: 1, citizenships: text(6), work_permits: text(3), prefer: text(3), avoid: text(3), weights: text(8) }],
      languages: [{ id: 1, code: text(6), level: "b2" }],
      places: [{ id: 1, kind: "country", iso2: text(3), name: text(6), language: text(6), work_permit: text(6) }],
    };
    if (call(x.ingest, bootFrame(catalog, rows)) < 0) throw new Error("BOOT refused");
    call(x.view, enc.encode(JSON.stringify({ search: text(4) })));
    for (let id = 1; id <= n; id++) x.application(id);
    x.overview(10);
    x.atlas();
    x.lanes();
    const ctx = enc.encode(JSON.stringify({ today: TODAY, now: 0, human: false, key_id: 1, held: [] }));
    for (let id = 1; id <= 4; id++) {
      const put = op(catalog, { put: "applications", target: id, cells: { listing_raw: text(40), comp_raw: text(6), company: text(6) } }, BigInt(id));
      call(x.judge, put, ctx);
      call(x.predict, put, ctx);
      const note = op(catalog, { command: "note", target: id, params: { stage: "discovered", body: text(8) } }, BigInt(100 + id));
      call(x.predict, note, ctx);
    }
    x.overview(10);
    x.application(1);
    const n2 = x.snapshot();
    const snap = new Uint8Array(x.memory.buffer).slice(x.result_ptr(), x.result_ptr() + n2);
    const again = await instance(bytes);
    if (again.call(again.x.restore, snap) < 0) throw new Error("snapshot did not restore");
  } catch (e) {
    failures.push(`seed ${seed}: ${e && e.message}`);
    continue;
  }
  const ms = performance.now() - t0;
  if (ms > BOUND_MS) failures.push(`seed ${seed}: ${ms.toFixed(0)} ms`);
}

if (failures.length) {
  console.error(`${failures.length} fuzz failures:\n${failures.join("\n")}`);
  process.exit(1);
}
console.log(`${SEEDS} arbitrary-text desks pass under wasm`);
