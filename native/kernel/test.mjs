// The kernel's contract, tested through its WebAssembly exports.
//
//   node native/kernel/test.mjs [path/to/kernel.wasm] [seed]
//
// An independent model in this file (raw rows encoded from schema.txt,
// the board's projection of a job row, the order of Card.order/1, the
// board filters and search, Ops' rules for score, next and stage moves
// and the rail they write) is driven through seeded random sequences of
// boots, raw-row patches and deletions, ops, ACKs and NACKs; after every
// step the kernel's cards and selection must equal the model's. The heat
// decoration itself is checked against the Elixir oracle by parity.mjs;
// here the model reads load_pct from the kernel. The golden frames in
// test/fixtures/wire/ must ingest whole, a snapshot must restore to the
// same state, and corrupted frames must never trap.
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { S, NONE, frame, opBody, ack, nack, concat, kernel as instantiate, repo } from "./frames.mjs"

const wasmPath = process.argv[2] ?? path.join(repo, "priv/static/wasm/kernel.wasm")
const seed0 = Number(process.argv[3] ?? 1)
const wasm = fs.readFileSync(wasmPath)
const kernel = () => instantiate(wasm)

// ---- the model ----------------------------------------------------------

const STAGES = ["discovered", "freshness", "gated", "in_batch", "draft_ready", "fire_ready", "open_fire", "submitted", "reply", "closed"]
// Moves that never enter the heat queue, so no governor verdict decides them.
const SAFE = ["discovered", "freshness", "gated", "in_batch", "draft_ready", "reply", "closed"]
const STATUSES = ["open", "paused", "hired", "closed"]
const FRESHNESS = ["unknown", "open", "thin", "closed", "blocked"]
const GATES = ["unset", "pursue", "maybe", "skip"]
const COMPANIES = ["Acme", "acme", "Globex", "Ölund", "Initech", "Zeta", "Ab", ""]
const JOB_COLS = ["id", "profile_id", "batch_id", "company", "role", "location", "heat", "status", "next_action", "next_due",
  "stage_on", "current_stage", "pips", "freshness", "gate", "fit", "score_100", "keyword_hits", "keyword_total",
  "mask_hidden", "mask_altered", "mask_emphasized", "listing_url", "canonical_url", "department", "squad",
  "heat_override", "heat_override_reason"]

function rng(seed) {
  // Scramble the seed so small seeds do not start xorshift near zero.
  let s = Math.imul((seed ^ 0x9e3779b9) >>> 0, 0x85ebca6b) >>> 0 || 1
  const next = () => ((s ^= s << 13), (s ^= s >>> 17), (s ^= s << 5), (s >>> 0) / 2 ** 32)
  return { f: next, int: (n) => Math.floor(next() * n), pick: (a) => a[Math.floor(next() * a.length)] }
}

function randomJob(r, id, profiles, batches) {
  const stage = r.pick(STAGES)
  return {
    id, profile_id: r.f() < 0.9 ? r.pick(profiles).id : 999, batch_id: r.f() < 0.3 ? null : r.pick(batches).id,
    company: r.pick(COMPANIES), role: r.f() < 0.04 ? "Ł".repeat(40000) : r.pick(["Engineer", "Staff Engineer", "SRE"]),
    location: r.pick(["Berlin", "Bucureşti", ""]), heat: 1 + r.int(5), status: r.pick(STATUSES),
    next_action: r.pick(["", "x", "Call back", "Ünïcode"]), next_due: r.f() < 0.5 ? null : 20000 + r.int(50),
    stage_on: r.f() < 0.2 ? null : 20000 + r.int(50), current_stage: stage,
    pips: r.f() < 0.8 ? rail("", STAGES.indexOf(stage)).join("") : r.pick(["", "XX", "DDDDDAPPPP"]),
    freshness: r.pick(FRESHNESS), gate: r.pick(GATES), fit: r.pick(["", "fit"]), score_100: r.pick([0, 50, 50, 73, 100, r.int(101)]),
    keyword_hits: r.int(5), keyword_total: r.int(9), mask_hidden: r.int(3), mask_altered: r.int(3), mask_emphasized: r.int(3),
    listing_url: "", canonical_url: "", department: "", squad: "", heat_override: 0, heat_override_reason: "",
  }
}

// Pipeline.decode/initial, move_to and current, over pip characters.
function rail(pips, current) {
  if (pips.length === 10 && [...pips].every((c) => "DAPSB".includes(c))) return [...pips]
  return STAGES.map((_, i) => (i < current ? "D" : i === current ? "A" : "P"))
}
const currentOf = (rail) => {
  const a = rail.indexOf("A")
  if (a >= 0) return a
  const p = rail.indexOf("P")
  return p >= 0 ? p : 9
}
const moveTo = (rail, to) => rail.map((c, i) => (i === to ? "A" : c === "S" || c === "B" ? c : i < to ? "D" : "P"))

const isoDay = (s) => (/^\d{4}-\d\d-\d\d$/.test(s) && !Number.isNaN(Date.parse(s + "T00:00:00Z")) ? Math.round(Date.parse(s + "T00:00:00Z") / 86400000) : null)
const dateOf = (d) => new Date(d * 86400000).toISOString().slice(0, 10)

class Model {
  constructor(jobs, profiles, batches, variants, today) {
    this.jobs = new Map(jobs.map((j) => [j.id, { ...j }]))
    this.batches = new Map(batches.map((b) => [b.id, { ...b }]))
    this.profiles = profiles
    this.variants = variants // job id → label
    this.leases = new Set()
    this.pending = []
    this.today = today
  }

  // Ops.run's rules for the kinds this test sends; returns a refusal code
  // or 0, and collects what the op writes.
  static apply(st, o, check, writes = []) {
    const job = st.jobs.get(o.target)
    const lease = () => check && st.leases.has(o.target)
    if (o.kind === "score") {
      const n = /^[+-]?\d+$/.test(o.fields[0]) ? Number(o.fields[0]) : NaN
      if (!(n >= 0 && n <= 100)) return S.refusal.argument
      if (lease()) return S.refusal.leased
      if (!job) return S.refusal.not_found
      job.score_100 = n
      writes.push(["job_apps", o.target, { score_100: n }])
    } else if (o.kind === "next") {
      if (lease()) return S.refusal.leased
      if (!job) return S.refusal.not_found
      job.next_action = o.fields[0].trim(), job.next_due = isoDay(o.fields[1])
      writes.push(["job_apps", o.target, { next_action: job.next_action, next_due: job.next_due }])
    } else if (o.kind === "stage") {
      const to = STAGES.indexOf(o.fields[0])
      if (to < 0) return S.refusal.argument
      if (lease()) return S.refusal.leased
      if (!job) return S.refusal.not_found
      const before = rail(job.pips, STAGES.indexOf(job.current_stage))
      const moved = moveTo(before, to)
      const changed = currentOf(before) !== currentOf(moved)
      job.current_stage = STAGES[currentOf(moved)], job.pips = moved.join("")
      if (changed) job.stage_on = st.today
      writes.push(["job_apps", o.target, { current_stage: job.current_stage, pips: job.pips, ...(changed ? { stage_on: st.today } : {}) }])
    } else if (o.kind === "open_fire") {
      const b = [...st.batches.values()].find((x) => x.code === o.fields[0])
      if (!b) return S.refusal.batch
      b.fire = 1, b.status = "open_fire"
      writes.push(["batches", b.id, { fire: 1, status: "open_fire" }])
    }
    return 0
  }

  state(withPending) {
    const st = {
      jobs: new Map([...this.jobs].map(([k, v]) => [k, { ...v }])),
      batches: new Map([...this.batches].map(([k, v]) => [k, { ...v }])),
      leases: this.leases, today: this.today,
    }
    if (withPending) for (const o of this.pending) Model.apply(st, o, false)
    return st
  }

  push(o) {
    const st = this.state(true)
    o.writes = []
    const code = Model.apply(st, o, true, o.writes)
    if (code === 0) this.pending.push(o)
    return code
  }

  // The board's projection of a job row (the columns heat does not paint).
  card(st, j) {
    return {
      id: j.id, score: j.score_100, heat: j.heat, stage: STAGES.indexOf(j.current_stage), status: STATUSES.indexOf(j.status),
      freshness: FRESHNESS.indexOf(j.freshness), gate: GATES.indexOf(j.gate), batch: j.batch_id ?? 0, profile: j.profile_id,
      hits: j.keyword_hits, total: j.keyword_total, hidden: j.mask_hidden, altered: j.mask_altered, emphasized: j.mask_emphasized,
      stage_on: j.stage_on ?? NONE, next_due: j.next_due ?? NONE, leased: st.leases.has(j.id) ? 1 : 0,
      company: j.company, role: j.role, location: j.location, next_action: j.next_action, cv_label: this.variants.get(j.id),
      fit: j.fit, pips: j.pips,
    }
  }

  cards(st) {
    return [...st.jobs.values()].filter((j) => this.variants.has(j.id) && this.profiles.some((p) => p.id === j.profile_id))
  }

  select(st, f, q, loadPct) {
    const ordinal = (j) => (j.batch_id && st.batches.get(j.batch_id) ? st.batches.get(j.batch_id).ordinal : 999)
    const cmp = (a, b) =>
      b.score_100 - a.score_100 || loadPct(a.id) - loadPct(b.id) || ordinal(a) - ordinal(b) ||
      STAGES.indexOf(a.current_stage) - STAGES.indexOf(b.current_stage) || b.heat - a.heat ||
      Buffer.compare(Buffer.from(a.company), Buffer.from(b.company)) || a.id - b.id
    const needle = q.trim().toLowerCase()
    const name = (j) => this.profiles.find((p) => p.id === j.profile_id)?.name ?? ""
    const text = (j) => [j.company, j.role, j.location, j.next_action, name(j), this.variants.get(j.id), `jobapp${j.id}`, `cv${j.id}`, `${j.id}`].join("\n").toLowerCase()
    const eq = (want, v) => want === -1 || want === v
    return this.cards(st)
      .filter((j) => j.score_100 >= f.min && j.score_100 >= f.lo && j.score_100 <= f.hi)
      .filter((j) => eq(f.stage, STAGES.indexOf(j.current_stage)) && eq(f.status, STATUSES.indexOf(j.status)) && eq(f.profile, j.profile_id))
      .filter((j) => (f.batch === -2 ? !j.batch_id : eq(f.batch, j.batch_id ?? 0)))
      .filter((j) => !needle || text(j).includes(needle))
      .sort(cmp)
      .map((j) => j.id)
  }
}

const rowsTable = (name, rows, cols = Object.keys(S.col[name])) =>
  [name, Object.fromEntries(cols.filter((c) => rows.length === 0 || c in rows[0]).map((c) => [c, rows.map((r) => r[c])]))]

function boot(rev, M, profiles, today) {
  return frame("BOOT", rev, [
    rowsTable("profiles", profiles),
    rowsTable("batches", [...M.batches.values()]),
    rowsTable("job_apps", [...M.jobs.values()], JOB_COLS),
    rowsTable("cv_variants", [...M.variants].map(([job, label], i) => ({ id: i + 1, job_app_id: job, profile_id: 0, lineage_id: 0, label }))),
    rowsTable("leases", [...M.leases].map((id) => ({ id }))),
    ["clock", { today: [today], now: [today * 86400] }],
  ])
}

// ---- tests --------------------------------------------------------------

const all = { min: -1, lo: -1000, hi: 1000, stage: -1, status: -1, batch: -1, profile: -1, heat: -1 }

async function fixtures() {
  const dir = path.join(repo, "test/fixtures/wire")
  const read = (f) => new Uint8Array(fs.readFileSync(path.join(dir, f)))
  const K = await kernel()
  for (const f of ["boot.bin", "patch.bin"]) {
    const bits = K.ingest(read(f))
    assert.equal(bits & (1 << 30), 0, `${f} rejected`)
  }
  assert.equal(K.k.counter(6), 0)
  assert.ok(K.k.rows(S.table.job_apps) > 0, "the fixture desk has job rows")
  console.log(`fixtures: ${K.k.rows(S.table.job_apps)} job rows, ${K.k.rows(S.table.cards)} cards after boot+patch`)
}

const totals = new Array(8).fill(0)

async function property(seed) {
  const r = rng(seed)
  const K = await kernel()
  const today = 20100
  const profiles = [{ id: 7, slug: "platform", name: "Platform" }, { id: 9, slug: "data", name: "Data Ünit" }]
  const batches = [
    { id: 3, code: "B1", ordinal: 2, fire: 0, status: "hold" },
    { id: 5, code: "B2", ordinal: 1, fire: 1, status: "open_fire" },
  ]
  let nextId = 1
  const jobs = Array.from({ length: r.int(40) }, () => randomJob(r, nextId++, profiles, batches))
  const variants = new Map(jobs.filter(() => r.f() < 0.9).map((j) => [j.id, `CV${j.id}`]))
  const M = new Model(jobs, profiles, batches, variants, today)
  for (const j of jobs) if (r.f() < 0.1) M.leases.add(j.id)
  let rev = 1
  K.ingest(boot(rev, M, profiles, today))
  let opId = 1
  const log = []

  const check = (step) => {
    K.k.derive() // as a reader does after a push, before it reads
    const view = M.state(true)
    const cards = M.cards(view)
    assert.equal(K.k.rows(S.table.cards), cards.length, `seed ${seed} step ${step}: card count\n${log.join("\n")}`)
    const cols = Object.keys(M.card(view, cards[0] ?? randomJob(r, 0, profiles, batches)))
    for (const j of cards) {
      assert.deepEqual(K.card(j.id, cols), M.card(view, j), `seed ${seed} step ${step}: card ${j.id}\n${log.join("\n")}`)
    }
    const loadPct = (id) => K.card(id, ["load_pct"]).load_pct
    const f = {
      ...all,
      ...(r.f() < 0.3 ? { min: r.int(101) } : {}),
      ...(r.f() < 0.2 ? { lo: r.int(60), hi: 40 + r.int(61) } : {}),
      ...(r.f() < 0.2 ? { stage: r.int(STAGES.length) } : {}),
      ...(r.f() < 0.2 ? { status: r.int(4) } : {}),
      ...(r.f() < 0.2 ? { batch: r.pick([-2, 3, 5, 4]) } : {}),
      ...(r.f() < 0.2 ? { profile: r.pick([7, 9]) } : {}),
    }
    const q = r.f() < 0.4 ? r.pick(["", " acme ", "ÖLUND", "engineer", "jobapp1", "cv2", "data ü", "\nb"]) : ""
    assert.deepEqual(K.select(f, q), M.select(view, f, q, loadPct), `seed ${seed} step ${step}: select ${JSON.stringify(f)} ${q}\n${log.join("\n")}`)
  }

  for (let step = 0; step < 120; step++) {
    const roll = r.f()
    const ids = [...M.jobs.keys()]
    if (roll < 0.35 && ids.length) {
      // The client predicts an op, or a quick burst of them.
      for (let burst = r.f() < 0.3 ? 2 + r.int(3) : 1; burst > 0; burst--) {
        const kind = r.pick(["stage", "stage", "next", "score", "open_fire"])
        const target = r.f() < 0.95 ? r.pick(ids) : 999
        const fields = {
          stage: () => [r.f() < 0.05 ? "nowhere" : r.pick(SAFE)],
          next: () => [r.pick(["call", " Ünïcode ", ""]), r.f() < 0.5 ? r.pick(["", "soon"]) : dateOf(20000 + r.int(80))],
          score: () => [r.pick([String(r.int(101)), "101", "+5"])],
          open_fire: () => [r.pick(["B1", "B2", "B9"])],
        }[kind]()
        const o = { id: opId++, kind, target: kind === "open_fire" ? 0 : target, fields }
        log.push(`push ${JSON.stringify(o)}`)
        assert.equal(K.push(opBody(o.id, kind, o.target, fields)), M.push(o), `seed ${seed} step ${step}: refusal for ${JSON.stringify(o)}\n${log.join("\n")}`)
      }
    } else if (roll < 0.55 && M.pending.length) {
      // The server settles the oldest op: raw rows then ACK, or a NACK.
      const o = M.pending.shift()
      const st = M.state(false)
      const code = Model.apply(st, o, true)
      if (code || r.f() < 0.15) {
        log.push(`nack ${o.id}`)
        K.ingest(nack(o.id, code || S.refusal.cooldown, "no"))
        assert.deepEqual(K.events().map((e) => [e.id, e.code, e.msg]), [[o.id, code || S.refusal.cooldown, "no"]])
      } else {
        // Sometimes the server's result differs from the prediction.
        const j = st.jobs.get(o.target)
        if (o.kind === "score" && j && r.f() < 0.3) j.score_100 = (j.score_100 + 1) % 101
        const differ = o.writes.some(([t, key, vals]) => {
          const row = (t === "job_apps" ? st.jobs : st.batches).get(key)
          return row && Object.entries(vals).some(([k, v]) => row[k] !== v)
        })
        M.jobs = st.jobs, M.batches = st.batches
        const tables = []
        if (j) tables.push(rowsTable("job_apps", [j], JOB_COLS))
        if (o.kind === "open_fire") tables.push(rowsTable("batches", [...st.batches.values()]))
        log.push(`ack ${o.id} differ=${differ}`)
        K.ingest(concat(frame("PATCH", ++rev, tables), ack(o.id)))
        assert.deepEqual(K.events().map((e) => [e.id, e.code, e.mis]), [[o.id, 0, +differ]])
      }
    } else if (roll < 0.8) {
      // Another tab or agent wrote rows: a PATCH, maybe partial, maybe
      // inserting, maybe deleting.
      const touched = ids.filter(() => r.f() < 0.15)
      const fresh = r.f() < 0.3 ? [randomJob(r, nextId++, profiles, batches)] : []
      for (const j of fresh) if (r.f() < 0.8) M.variants.set(j.id, `CV${j.id}`)
      const rows = [...touched.map((id) => randomJob(r, id, profiles, batches)), ...fresh]
      const partial = r.f() < 0.5 && !fresh.length
      const cols = partial ? ["id", r.pick(JOB_COLS.slice(1)), r.pick(["company", "next_action", "pips"])] : JOB_COLS
      for (const j of rows) {
        const old = M.jobs.get(j.id) ?? {}
        M.jobs.set(j.id, partial ? { ...old, ...Object.fromEntries(cols.map((k) => [k, j[k]])) } : j)
      }
      const gone = ids.filter(() => r.f() < 0.05)
      for (const id of gone) M.jobs.delete(id)
      log.push(`patch ${rows.map((j) => j.id)} cols=${partial ? cols : "all"} gone=${gone}`)
      const tables = [rowsTable("job_apps", rows, cols)]
      if (fresh.length) {
        tables.push(rowsTable("cv_variants", fresh.filter((j) => M.variants.has(j.id)).map((j) => ({ id: 1000 + j.id, job_app_id: j.id, profile_id: 0, lineage_id: 0, label: M.variants.get(j.id) }))))
      }
      if (gone.length) tables.push(["gone", { table: gone.map(() => S.table.job_apps), id: gone }])
      K.ingest(frame("PATCH", ++rev, tables))
    } else if (roll < 0.83) {
      log.push("boot")
      K.ingest(boot(++rev, M, profiles, today))
    } else if (roll < 0.85) {
      log.push("empty boot")
      K.ingest(frame("BOOT", ++rev, []))
    }
    check(step)
  }
  for (let i = 0; i < totals.length; i++) totals[i] += K.k.counter(i)

  // A snapshot restores the base: a fresh kernel ingesting it shows the
  // model's base and snapshots back to the same bytes.
  const snap = K.snapshot()
  const R = await kernel()
  assert.equal(R.ingest(snap) & (1 << 30), 0)
  const base = M.state(false)
  for (const j of M.cards(base)) assert.deepEqual(R.card(j.id, Object.keys(M.card(base, j))), M.card(base, j), `seed ${seed}: restored card ${j.id}`)
  assert.deepEqual(R.snapshot(), snap)

  // Corrupted frames are refused or absorbed, never a trap.
  const good = frame("PATCH", 99, [rowsTable("job_apps", [randomJob(r, 1, profiles, batches)], JOB_COLS)])
  for (let i = 0; i < 200; i++) {
    const bad = good.slice(0, r.int(good.length + 1))
    if (bad.length) bad[r.int(bad.length)] = r.int(256)
    R.ingest(bad)
    R.select(all, "a")
  }
}

await fixtures()
const seeds = Number(process.env.SEEDS ?? 40)
for (let s = seed0; s < seed0 + seeds; s++) await property(s)
const names = ["predicted", "settled", "mispredicted", "nacked", "refused", "unknown_ack", "bad_frames", "compactions"]
console.log(`property: ${seeds} seeds from ${seed0} ok; ${names.map((n, i) => `${n} ${totals[i]}`).join(", ")}`)
