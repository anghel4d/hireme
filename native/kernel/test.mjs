// The kernel's contract, tested through its WebAssembly exports.
//
//   node native/kernel/test.mjs [path/to/kernel.wasm] [seed]
//
// An independent model in this file (frames encoded from schema.txt, the
// board order of Hireme.Desk.Card.order/1, the board filters and
// search, the refusal rules) is driven through seeded random sequences of
// boots, patches, deletes, ops, ACKs and NACKs; after every step the
// kernel's view and selection must equal the model's. The golden frames
// in test/fixtures/wire/ must decode to what they carry, a snapshot must
// restore to the same state, and corrupted frames must never trap.
import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, "../..")
const wasmPath = process.argv[2] ?? path.join(repo, "priv/static/wasm/kernel.wasm")
const seed0 = Number(process.argv[3] ?? 1)
const wasm = fs.readFileSync(wasmPath)
const te = new TextEncoder()
const td = new TextDecoder()

// ---- schema -------------------------------------------------------------

const S = { frame: {}, table: {}, col: {}, op: {}, refusal: {}, opFields: {} }
const schemaBytes = fs.readFileSync(path.join(repo, "priv/wire/schema.txt"))
for (const line of td.decode(schemaBytes).split("\n")) {
  const w = line.trim().split(/\s+/)
  if (w[0] === "frame") S.frame[w[1]] = +w[2]
  if (w[0] === "table") (S.table[w[1]] = +w[2]), (S.col[w[1]] = {})
  if (w[0] === "col") S.col[w[1]][w[2]] = { id: +w[3], kind: w[4] }
  if (w[0] === "op") (S.op[w[1]] = +w[2]), (S.opFields[w[1]] = w.slice(4))
  if (w[0] === "refusal") S.refusal[w[1]] = +w[2]
}
let h = 0x811c9dc5
for (const b of schemaBytes) h = Math.imul(h ^ b, 0x01000193) >>> 0
const HASH = (h >>> 16) ^ (h & 0xffff)
const NONE = 0xffffffff
const wireType = (kind) => ({ u32: 1, day: 1, time: 1, str: 2, u64: 3, f64: 4 })[kind]

// ---- encoding -----------------------------------------------------------

class W {
  bytes = []
  u8(v) { this.bytes.push(v & 0xff) }
  u16(v) { this.u8(v); this.u8(v >>> 8) }
  u32(v) { this.u16(v & 0xffff); this.u16(v >>> 16) }
  u64(v) { this.u32(Number(BigInt(v) & 0xffffffffn)); this.u32(Number(BigInt(v) >> 32n)) }
  raw(a) { for (const b of a) this.bytes.push(b) }
  pad(from) { while ((this.bytes.length - from) % 8) this.u8(0) }
}

// tables: [[name, {col: [values]}]]
function frame(kind, rev, tables = [], body = null) {
  const w = new W()
  w.u32(0), w.u8(S.frame[kind]), w.u8(0), w.u16(HASH), w.u64(rev)
  if (body) w.raw(body)
  for (const [name, cols] of tables) {
    const names = Object.keys(cols)
    const n = names.length ? cols[names[0]].length : 0
    w.u16(S.table[name]), w.u16(names.length), w.u32(n)
    for (const c of names) {
      const def = S.col[name][c]
      const ty = wireType(def.kind)
      w.u16(def.id), w.u8(ty), w.u8(0)
      if (ty === 2) {
        const enc = cols[c].map((s) => te.encode(s))
        w.u32(4 * (n + 1) + enc.reduce((a, b) => a + b.length, 0))
        let at = 0
        w.u32(0)
        for (const e of enc) w.u32((at += e.length))
        for (const e of enc) w.raw(e)
      } else {
        w.u32(n * 4)
        for (const v of cols[c]) w.u32(v)
      }
      w.pad(0)
    }
  }
  w.pad(0)
  const b = new Uint8Array(w.bytes)
  new DataView(b.buffer).setUint32(0, b.length, true)
  return b
}

function opBody(id, kind, target, fields) {
  const w = new W()
  w.u64(id), w.u8(S.op[kind]), w.u8(fields.length), w.u16(0), w.u32(target)
  for (const f of fields) {
    const e = te.encode(f)
    w.u16(e.length), w.raw(e)
  }
  return new Uint8Array(w.bytes)
}

const ack = (id) => frame("ACK", 0, [], opBody(id, "note", 0, []).slice(0, 8))
function nack(id, code, msg) {
  const w = new W()
  const m = te.encode(msg)
  w.u64(id), w.u8(code), w.u8(0), w.u16(m.length), w.raw(m)
  return frame("NACK", 0, [], w.bytes)
}

// ---- the kernel through its exports --------------------------------------

async function kernel() {
  const { instance } = await WebAssembly.instantiate(wasm, {})
  const k = instance.exports
  const mem = () => k.memory.buffer
  const put = (reserve, bytes) => {
    const at = reserve(bytes.length) // may grow memory: take the view after
    new Uint8Array(mem(), at, bytes.length).set(bytes)
  }
  return {
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
    card(id) {
      const t = S.table.cards
      const row = k.row_of(t, id)
      if (row < 0) return null
      const out = {}
      for (const [name, def] of Object.entries(S.col.cards)) {
        if (wireType(def.kind) === 2) {
          out[name] = td.decode(new Uint8Array(mem(), k.str_ptr(t, def.id, row), k.str_len(t, def.id, row)))
        } else {
          const p = k.col_ptr(t, def.id)
          out[name] = p ? new Uint32Array(mem(), p, k.rows(t))[row] : 0
        }
      }
      return out
    },
    events() {
      const n = k.events_len()
      const r = new Uint32Array(mem(), k.events_ptr(), n * 4)
      return Array.from({ length: n }, (_, i) => ({
        id: r[i * 4] + r[i * 4 + 1] * 2 ** 32, code: r[i * 4 + 2], mis: r[i * 4 + 3],
        msg: td.decode(new Uint8Array(mem(), k.event_msg_ptr(i), k.event_msg_len(i))),
      }))
    },
    snapshot() { const n = k.snapshot(); return new Uint8Array(mem(), k.snapshot_ptr(), n).slice() },
  }
}

// ---- the model --------------------------------------------------------

const STAGES = ["discovered", "freshness", "gated", "in_batch", "draft_ready", "fire_ready", "open_fire", "submitted", "reply", "closed"]
// Rank deliberately differs from ix so the order must read `rank`.
const RANK = STAGES.map((_, i) => (i * 7) % 10)
const HOT = new Set(["fire_ready", "open_fire", "submitted", "reply", "closed"])
const QUEUE = new Set(["fire_ready", "open_fire", "submitted"])
const LOCKED = new Set(["open_fire", "submitted"])
const HEAT_STATES = ["cool", "warm", "hot", "blocked"]
const COMPANIES = ["Acme", "acme", "Globex", "Ölund", "Initech", "Zeta", "Ab", ""]
const U32_COLS = Object.keys(S.col.cards).filter((c) => wireType(S.col.cards[c].kind) === 1)
const STR_COLS = Object.keys(S.col.cards).filter((c) => wireType(S.col.cards[c].kind) === 2)

function rng(seed) {
  // Scramble the seed so small seeds do not start xorshift near zero.
  let s = Math.imul((seed ^ 0x9e3779b9) >>> 0, 0x85ebca6b) >>> 0 || 1
  const next = () => ((s ^= s << 13), (s ^= s >>> 17), (s ^= s << 5), (s >>> 0) / 2 ** 32)
  return { f: next, int: (n) => Math.floor(next() * n), pick: (a) => a[Math.floor(next() * a.length)] }
}

function lookups(profiles, batches) {
  return [
    ["stages", {
      ix: STAGES.map((_, i) => i), key: STAGES, label: STAGES, hint: STAGES.map(() => ""), rank: RANK,
      fire_locked: STAGES.map((s) => +LOCKED.has(s)), hot: STAGES.map((s) => +HOT.has(s)), queue: STAGES.map((s) => +QUEUE.has(s)),
    }],
    ["heat_states", { ix: HEAT_STATES.map((_, i) => i), key: HEAT_STATES }],
    ["profiles", { id: profiles.map((p) => p.id), slug: profiles.map((p) => p.name.toLowerCase()), name: profiles.map((p) => p.name) }],
    ["batches", { id: batches.map((b) => b.id), code: batches.map((b) => b.code), ordinal: batches.map((b) => b.ordinal), fire: batches.map((b) => b.fire), status: batches.map((b) => b.status) }],
  ]
}

const cardsTable = (cards, cols = [...U32_COLS, ...STR_COLS]) =>
  ["cards", Object.fromEntries(cols.map((c) => [c, cards.map((x) => x[c])]))]

function randomCard(r, id, profiles, batches) {
  const c = {}
  for (const n of U32_COLS) c[n] = r.int(4)
  for (const n of STR_COLS) c[n] = r.pick(["", "x", "Call back", "Ünïcode", "Staff Engineer"])
  Object.assign(c, {
    id, score: r.pick([0, 50, 50, 73, 100, r.int(101)]), heat: 1 + r.int(5), stage: r.int(STAGES.length),
    batch: r.f() < 0.3 ? 0 : r.pick(batches).id, profile: r.pick(profiles).id, heat_state: r.int(4),
    load_pct: r.pick([0, 40, 40, 100, 250]), leased: +(r.f() < 0.1), company: r.pick(COMPANIES),
    stage_on: r.f() < 0.2 ? NONE : 20000 + r.int(50), next_due: r.f() < 0.5 ? NONE : 20000 + r.int(50),
    role: r.f() < 0.04 ? "Ł".repeat(40000) : r.pick(["Engineer", "Staff Engineer", "SRE"]), location: r.pick(["Berlin", "Bucureşti", ""]),
  })
  return c
}

// Overlays: each job's focus lists items 1-4, each line interned by
// (item, mode); an overlay moves the card's mask counts by one.
const MODES = ["inherit", "hidden", "altered", "emphasized"]
const ITEMS = [1, 2, 3, 4]
const lineIx = (item, m) => 1000 + item * 4 + m
const linesFrame = (rev) => {
  const all = ITEMS.flatMap((item) => MODES.map((_, m) => [item, m]))
  return frame("LINES", rev, [["lines", { ix: all.map(([i, m]) => lineIx(i, m)), item: all.map(([i]) => i), mode: all.map(([, m]) => MODES[m]) }]])
}
const focusFrame = (rev, job, modes) => frame("FOCUS", rev, [
  ["focus", { job: [job] }],
  ["focus_lines", { slot: ITEMS.map((_, i) => i), section: ITEMS.map(() => 0), line: ITEMS.map((i) => lineIx(i, modes.get(i))) }],
])

const dayOf = (s) => (s === "" ? NONE : Math.round(Date.parse(s + "T00:00:00Z") / 86400000))
const dateOf = (d) => new Date(d * 86400000).toISOString().slice(0, 10)

class Model {
  constructor(cards, profiles, batches, today) {
    this.base = new Map(cards.map((c) => [c.id, { ...c }]))
    this.batches = new Map(batches.map((b) => [b.id, { ...b }]))
    this.profiles = profiles
    this.pending = []
    this.today = today
    this.focus = new Map()
    this.narratives = new Map([1, 2].map((id) => [id, { id, profile: 7, body: `story ${id}`, version: 1 }]))
  }

  narrativesTable(st = this) {
    const ns = [...st.narratives.values()]
    return ["narratives", { id: ns.map((n) => n.id), profile: ns.map((n) => n.profile), body: ns.map((n) => n.body), version: ns.map((n) => n.version) }]
  }

  // Applies an op to (cards, batches); returns a refusal or 0.
  // `writes` collects what the op says each field becomes.
  static apply(st, o, check, writes = []) {
    const card = st.cards.get(o.target)
    if (o.kind !== "open_fire" && o.kind !== "narrative") {
      if (!card) return S.refusal.not_found
      if (check && card.leased) return S.refusal.leased
    }
    if (o.kind === "stage") {
      const to = STAGES.indexOf(o.fields[0])
      const b = st.batches.get(card.batch)
      if (check && LOCKED.has(o.fields[0]) && !(card.batch && b && b.fire)) return S.refusal.fire_hold
      if (check && !HOT.has(STAGES[card.stage]) && QUEUE.has(o.fields[0]) && card.heat_state === 3) return S.refusal.heat
      if (to !== card.stage) {
        card.stage = to, card.stage_on = st.today
        writes.push(["cards", o.target, { stage: to, stage_on: st.today }])
      }
    } else if (o.kind === "next") {
      const due = /^\d{4}-\d\d-\d\d$/.test(o.fields[1]) ? dayOf(o.fields[1]) : NONE
      card.next_action = o.fields[0].trim(), card.next_due = due
      writes.push(["cards", o.target, { next_action: card.next_action, next_due: card.next_due }])
    } else if (o.kind === "score") {
      card.score = +o.fields[0]
      writes.push(["cards", o.target, { score: card.score }])
    } else if (o.kind === "open_fire") {
      const b = [...st.batches.values()].find((x) => x.code === o.fields[0])
      if (!b) return S.refusal.batch
      b.fire = 1, b.status = "open_fire"
      writes.push(["batches", b.id, { fire: 1, status: "open_fire" }])
    } else if (o.kind === "narrative") {
      const n = st.narratives.get(o.target)
      if (!n) return S.refusal.not_found
      n.body = o.fields[0]
      writes.push(["narratives", n.id, { body: n.body }])
    } else if (o.kind === "overlay") {
      const modes = st.focus.get(o.target)
      const item = +o.fields[0]
      const to = MODES.indexOf(o.fields[1])
      if (item === 0 || (o.fields[1] === "altered" && !o.fields[2].trim())) return S.refusal.argument
      if (!modes || !modes.has(item)) return 0
      const from = modes.get(item)
      modes.set(item, to)
      if (from !== to) {
        const vals = {}
        if (from) vals[MODES[from]] = card[MODES[from]] = Math.max(0, card[MODES[from]] - 1)
        if (to) vals[MODES[to]] = card[MODES[to]] += 1
        writes.push(["cards", o.target, vals])
      }
    }
    return 0
  }

  state(withPending) {
    const st = {
      cards: new Map([...this.base].map(([k, v]) => [k, { ...v }])),
      batches: new Map([...this.batches].map(([k, v]) => [k, { ...v }])),
      today: this.today,
      focus: new Map([...this.focus].map(([k, v]) => [k, new Map(v)])),
      narratives: new Map([...this.narratives].map(([k, v]) => [k, { ...v }])),
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

  select(st, f, q) {
    const ordinal = (c) => (c.batch && st.batches.get(c.batch) ? st.batches.get(c.batch).ordinal : 999)
    const cmp = (a, b) =>
      b.score - a.score || a.load_pct - b.load_pct || ordinal(a) - ordinal(b) ||
      RANK[a.stage] - RANK[b.stage] || b.heat - a.heat ||
      Buffer.compare(Buffer.from(a.company), Buffer.from(b.company)) || a.id - b.id
    const needle = q.trim().toLowerCase()
    const name = (c) => this.profiles.find((p) => p.id === c.profile)?.name ?? ""
    const text = (c) => [c.company, c.role, c.location, c.next_action, name(c), c.cv_label, `jobapp${c.id}`, `cv${c.id}`, `${c.id}`].join("\n").toLowerCase()
    const eq = (want, v) => want === -1 || want === v
    return [...st.cards.values()]
      .filter((c) => c.score >= f.min && c.score >= f.lo && c.score <= f.hi)
      .filter((c) => eq(f.stage, c.stage) && eq(f.status, c.status) && eq(f.profile, c.profile) && eq(f.heat, c.heat_state))
      .filter((c) => (f.batch === -2 ? c.batch === 0 : eq(f.batch, c.batch)))
      .filter((c) => !needle || text(c).includes(needle))
      .sort(cmp)
      .map((c) => c.id)
  }
}

// ---- tests ------------------------------------------------------------

const all = { min: -1, lo: -1000, hi: 1000, stage: -1, status: -1, batch: -1, profile: -1, heat: -1 }

async function fixtures() {
  const dir = path.join(repo, "test/fixtures/wire")
  const read = (f) => new Uint8Array(fs.readFileSync(path.join(dir, f)))
  const K = await kernel()
  // Each golden frame is accepted whole, against this schema.
  for (const f of ["boot.bin", "lines.bin", "focus.bin", "patch.bin"]) {
    const bits = K.ingest(read(f))
    assert.equal(bits & (1 << 30), 0, `${f} rejected`)
  }
  assert.equal(K.k.counter(6), 0)
  const ids = K.select(all, "")
  assert.ok(ids.length > 0, "the fixture desk has cards")
  for (const id of ids) assert.equal(K.card(id).id, id)
  assert.ok(K.k.rows(S.table.lines) > 0, "lines resident")
  console.log(`fixtures: ${ids.length} cards after boot+patch, ${K.k.rows(S.table.lines)} lines`)
}

async function property(seed) {
  const r = rng(seed)
  const K = await kernel()
  const profiles = [{ id: 7, name: "Platform" }, { id: 9, name: "Data Ünit" }]
  const batches = [
    { id: 3, code: "B1", ordinal: 2, fire: 0, status: "hold" },
    { id: 5, code: "B2", ordinal: 1, fire: 1, status: "open_fire" },
  ]
  const today = 20100
  K.k.set_today(today)
  let nextId = 1
  const cards = Array.from({ length: r.int(40) }, () => randomCard(r, nextId++, profiles, batches))
  const M = new Model(cards, profiles, batches, today)
  for (const c of cards) if (r.f() < 0.6) M.focus.set(c.id, new Map(ITEMS.map((i) => [i, r.int(4)])))
  K.ingest(new Uint8Array([
    ...frame("BOOT", 1, [...lookups(profiles, batches), M.narrativesTable(), cardsTable(cards)]),
    ...linesFrame(1),
    ...[...M.focus].flatMap(([job, modes]) => [...focusFrame(1, job, modes)]),
  ]))
  let opId = 1
  let rev = 1
  const log = []

  const check = (step) => {
    const view = M.state(true)
    for (const c of view.cards.values()) {
      assert.deepEqual(K.card(c.id), c, `seed ${seed} step ${step}: card ${c.id} view\n${log.join("\n")}`)
    }
    assert.equal(K.k.rows(1), view.cards.size)
    for (const n of view.narratives.values()) {
      assert.equal(K.str(S.table.narratives, S.col.narratives.body.id, K.k.row_of(S.table.narratives, n.id)), n.body, `seed ${seed} step ${step}: narrative ${n.id}`)
    }
    const f = {
      ...all,
      ...(r.f() < 0.3 ? { min: r.int(101) } : {}),
      ...(r.f() < 0.2 ? { lo: r.int(60), hi: 40 + r.int(61) } : {}),
      ...(r.f() < 0.2 ? { stage: r.int(STAGES.length) } : {}),
      ...(r.f() < 0.2 ? { status: r.int(4) } : {}),
      ...(r.f() < 0.2 ? { batch: r.pick([-2, 3, 5, 4]) } : {}),
      ...(r.f() < 0.2 ? { profile: r.pick([7, 9]) } : {}),
      ...(r.f() < 0.2 ? { heat: r.int(4) } : {}),
    }
    const q = r.f() < 0.4 ? r.pick(["", " acme ", "ÖLUND", "engineer", "jobapp1", "cv2", "data ü", "\nb"]) : ""
    assert.deepEqual(K.select(f, q), M.select(view, f, q), `seed ${seed} step ${step}: select ${JSON.stringify(f)} ${q}\n${log.join("\n")}`)
  }

  for (let step = 0; step < 120; step++) {
    const roll = r.f()
    const ids = [...M.base.keys()]
    if (roll < 0.35 && ids.length) {
      // The client predicts an op, or a quick burst of them.
      for (let burst = r.f() < 0.3 ? 2 + r.int(3) : 1; burst > 0; burst--) {
      const kind = r.pick(["stage", "stage", "next", "score", "open_fire", "note", "overlay", "overlay", "narrative"])
      const target = kind === "narrative" ? r.pick([1, 2, 3]) : r.f() < 0.95 ? r.pick(ids) : 999
      const fields = {
        stage: () => [r.pick(STAGES)],
        next: () => [r.pick(["call", " Ünïcode ", ""]), r.f() < 0.5 ? r.pick(["", "soon"]) : dateOf(20000 + r.int(80))],
        score: () => [String(r.int(101))],
        open_fire: () => [r.pick(["B1", "B2", "B9"])],
        note: () => [r.pick(STAGES), "n"],
        overlay: () => [String(r.pick([...ITEMS, 9, 0])), r.pick(MODES), r.pick(["body", " "]), "why"],
        narrative: () => [r.pick(["new story", ""])],
      }[kind]()
      const o = { id: opId++, kind, target, fields }
      log.push(`push ${JSON.stringify(o)}`)
      assert.equal(K.push(opBody(o.id, kind, target, fields)), M.push(o), `seed ${seed} step ${step}: refusal for ${JSON.stringify(o)}\n${log.join("\n")}`)
      }
    } else if (roll < 0.55 && M.pending.length) {
      // The server settles the oldest op: PATCH then ACK, or a NACK.
      const o = M.pending.shift()
      const st = M.state(false)
      const code = Model.apply(st, o, true)
      if (code || r.f() < 0.15) {
        log.push(`nack ${o.id}`)
        K.ingest(nack(o.id, code || S.refusal.cooldown, "no"))
        assert.deepEqual(K.events().map((e) => [e.id, e.code, e.msg]), [[o.id, code || S.refusal.cooldown, "no"]])
      } else {
        // Sometimes the server's result differs from the prediction.
        const c = st.cards.get(o.target)
        if (o.kind === "score" && r.f() < 0.3) c.score = (c.score + 1) % 101
        // Mispredicted: the server's row differs from what the op said.
        const differ = o.writes.some(([t, key, vals]) => {
          const row = st[t].get(key)
          return row && Object.entries(vals).some(([k, v]) => row[k] !== v)
        })
        M.base = st.cards, M.batches = st.batches, M.focus = st.focus, M.narratives = st.narratives
        const changed = c ? [cardsTable([c])] : []
        const b = [...st.batches.values()]
        // A write to a job with an open focus brings its fresh FOCUS.
        const focus = o.kind === "overlay" && st.focus.has(o.target) ? [...focusFrame(++rev, o.target, st.focus.get(o.target))] : []
        log.push(`ack ${o.id} differ=${differ}`)
        K.ingest(new Uint8Array([...frame("PATCH", ++rev, [...changed, lookups(profiles, b)[3], M.narrativesTable()]), ...focus, ...ack(o.id)]))
        assert.deepEqual(K.events().map((e) => [e.id, e.code, e.mis]), [[o.id, 0, +differ]])
      }
    } else if (roll < 0.8) {
      // Another tab or agent changed rows: a PATCH, maybe partial, maybe
      // inserting, maybe deleting.
      const touched = ids.filter(() => r.f() < 0.15)
      const fresh = r.f() < 0.3 ? [randomCard(r, nextId++, profiles, batches)] : []
      const rows = [...touched.map((id) => ({ ...randomCard(r, id, profiles, batches) })), ...fresh]
      const partial = r.f() < 0.5 && !fresh.length
      const cols = partial ? ["id", r.pick(U32_COLS.slice(1)), r.pick(STR_COLS)] : [...U32_COLS, ...STR_COLS]
      for (const c of rows) {
        const old = M.base.get(c.id) ?? {}
        M.base.set(c.id, partial ? { ...old, ...Object.fromEntries(cols.map((k) => [k, c[k]])) } : c)
      }
      const gone = ids.filter(() => r.f() < 0.05)
      for (const id of gone) M.base.delete(id)
      log.push(`patch ${rows.map((c) => c.id)} cols=${partial ? cols : "all"} gone=${gone}`)
      const tables = [cardsTable(rows, cols)]
      if (gone.length) tables.push(["cards_gone", { id: gone }])
      K.ingest(frame("PATCH", ++rev, tables))
    } else if (roll < 0.83) {
      // A fresh boot replaces the desk; pending stays, and so do the
      // lines and the focuses of jobs still on it.
      const cs = [...M.base.values()]
      for (const job of M.focus.keys()) if (!M.base.has(job)) M.focus.delete(job)
      log.push("boot")
      K.ingest(frame("BOOT", ++rev, [...lookups(profiles, [...M.batches.values()]), M.narrativesTable(), cardsTable(cs)]))
    } else if (roll < 0.85) {
      // An empty BOOT: "what you have is current". Nothing changes.
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
  R.k.set_today(today)
  assert.equal(R.ingest(snap) & (1 << 30), 0)
  const base = M.state(false)
  for (const c of base.cards.values()) assert.deepEqual(R.card(c.id), c, `seed ${seed}: restored card ${c.id}`)
  assert.deepEqual(R.select(all, ""), M.select(base, all, ""))
  assert.deepEqual(R.snapshot(), snap)
  for (const [job, modes] of M.focus) {
    if (!base.cards.has(job)) continue
    assert.equal(R.k.focus_open(job), 1, `seed ${seed}: restored focus ${job}`)
    const lines = new Uint32Array(R.k.memory.buffer, R.k.col_ptr(S.table.focus_lines, S.col.focus_lines.line.id), R.k.rows(S.table.focus_lines))
    assert.deepEqual([...lines], ITEMS.map((i) => lineIx(i, modes.get(i))))
    for (const ix of lines) assert.ok(R.k.row_of(S.table.lines, ix) >= 0, `seed ${seed}: restored line ${ix}`)
  }

  // Corrupted frames are refused or absorbed, never a trap.
  const good = frame("PATCH", 99, [cardsTable([randomCard(r, 1, profiles, batches)])])
  for (let i = 0; i < 200; i++) {
    const bad = good.slice(0, r.int(good.length + 1))
    if (bad.length) bad[r.int(bad.length)] = r.int(256)
    R.ingest(bad)
    R.select(all, "a")
  }
}

const totals = new Array(8).fill(0)
await fixtures()
const seeds = Number(process.env.SEEDS ?? 40)
for (let s = seed0; s < seed0 + seeds; s++) await property(s)
const names = ["predicted", "settled", "mispredicted", "nacked", "refused", "unknown_ack", "bad_frames", "compactions"]
console.log(`property: ${seeds} seeds from ${seed0} ok; ${names.map((n, i) => `${n} ${totals[i]}`).join(", ")}`)
