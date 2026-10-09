// The kernel's derivations against the Elixir reference.
//
//   node native/kernel/parity.mjs [--wasm path] oracle.jsonl...
//
// Each file is a dump from test/oracle/run.exs: the account's raw tables
// (the input) and what the Elixir functions answer over them (the oracle).
// The tables are encoded as a BOOT frame the way HiremeWeb.Packet.raw/2
// does, ingested, and every derived table the kernel exposes is compared
// with the oracle, value for value and float bit for bit. Exits non-zero
// on any difference and prints the first few of each kind.
import fs from "node:fs"
import path from "node:path"
import { S, NONE, wireType, frame, opBody, ack, nack, concat, kernel, repo } from "./frames.mjs"

const args = process.argv.slice(2)
let wasmPath = path.join(repo, "priv/static/wasm/kernel.wasm")
const files = []
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--wasm") wasmPath = args[++i]
  else files.push(args[i])
}
const wasm = fs.readFileSync(wasmPath)

const STAGES = ["discovered", "freshness", "gated", "in_batch", "draft_ready", "fire_ready", "open_fire", "submitted", "reply", "closed"]
const STATUSES = ["open", "paused", "hired", "closed"]
const FRESHNESS = ["unknown", "open", "thin", "closed", "blocked"]
const GATES = ["unset", "pursue", "maybe", "skip"]
const HEAT_STATES = ["cool", "warm", "hot", "blocked"]
const ix = (list, v) => Math.max(0, list.indexOf(v))
const none = (v) => (v === null || v === undefined ? NONE : v)

// HiremeWeb.Packet.raw/2: one database row as its wire columns.
function rawValue(row, col, kind) {
  const unit = (list) => (Array.isArray(list) ? list.map(String).join("\u001f") : "")
  if (col === "theme_targets") return unit(row.theme?.targets)
  if (col === "variety_flags") return unit(row.variety?.flags)
  if (col.startsWith("variety_") && kind === "u32") {
    const v = row.variety?.[col.slice(8)]
    return Number.isInteger(v) && v >= 0 ? v : null
  }
  if (col === "keywords") return unit(row.keywords)
  if (col === "fire" && kind === "u32") return ["open_fire", true, 1].includes(row.fire) ? 1 : 0
  const v = row[col]
  if (v === undefined || v === null) return null
  if (typeof v === "boolean") return v ? 1 : 0
  if (typeof v === "object" && !Array.isArray(v) && wireType(kind) === 2) return JSON.stringify(v)
  return v
}

function rawTable(name, rows) {
  const cols = {}
  for (const [c, def] of Object.entries(S.col[name])) cols[c] = rows.map((r) => rawValue(r, c, def.kind))
  return [name, cols]
}

const diffs = new Map()
function check(kind, what, got, want) {
  const same = typeof want === "number" && typeof got === "number"
    ? Object.is(got, want) || (Number.isNaN(got) && Number.isNaN(want))
    : got === want
  if (same) return
  const list = diffs.get(kind) ?? []
  list.push(`${what}: kernel ${JSON.stringify(got)} oracle ${JSON.stringify(want)}`)
  diffs.set(kind, list)
}

async function one(file) {
  const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l))
  const meta = lines.find((l) => l.kind === "meta")
  const tables = lines.filter((l) => l.kind === "table" && S.table[l.table])
  const K = await kernel(wasm)
  // With ops, boot from the tables as they stood before the first one.
  const before = lines.filter((l) => l.kind === "table_before" && S.table[l.table])
  const boot = frame("BOOT", 1, [
    ...(before.length ? before : tables).map((t) => rawTable(t.table, t.rows)),
    ["clock", { today: [meta.today], now: [meta.today * 86400] }],
  ])
  const t0 = performance.now()
  const bits = K.ingest(boot)
  const bootMs = performance.now() - t0
  check("ingest", "boot accepted", bits & (1 << 30), 0)

  // Ops, in order: the kernel's prediction (refusal or raw rows) against
  // what Ops.run answered and wrote, then the server's rows and its ACK.
  const CODES = { fire_hold: 1, heat: 2, leased: 3, cooldown: 4, not_additive: 5, argument: 6, not_found: 7, batch: 8, invalid: 9 }
  const UNPREDICTED = new Set(["events", "gym_reps", "net_entries", "kv_pairs", "gym_problems"])
  const SKIP_COLS = new Set(["inserted_at", "updated_at"])
  let rev = 1
  for (const line of lines.filter((l) => l.kind === "op")) {
    const o = line.op
    const what = `op ${o.op_id} ${o.kind}(${o.target}, ${JSON.stringify(o.fields)})`
    const code = K.push(opBody(o.op_id, o.kind, o.target, o.fields))
    const want = line.result.error ? CODES[line.result.error] ?? 10 : 0
    check(`ops.refusal.${o.kind}`, `${what} → ${JSON.stringify(line.result)}`, code, want)
    if (code !== 0 || want !== 0) {
      if (code === 0) K.ingest(nack(o.op_id, want, "refused"))
      continue
    }
    // The predicted raw rows, before the server's arrive.
    for (const [table, rows] of Object.entries(line.rows)) {
      if (UNPREDICTED.has(table) || !S.table[table]) continue
      for (const row of rows) {
        const r = K.k.row_of(S.table[table], row.id)
        if (r < 0) {
          // A predicted insert carries a provisional id; find it by its
          // natural key (overlays: lineage and item).
          continue
        }
        const got = K.row(table, r)
        const [, cols] = rawTable(table, [row])
        for (const [c, [v]] of Object.entries(cols)) {
          if (SKIP_COLS.has(c) || !(c in got)) continue
          const def = S.col[table][c]
          const norm = v === null ? (wireType(def.kind) === 2 ? "" : wireType(def.kind) === 4 ? NaN : NONE) : v
          check(`ops.rows.${table}.${c}`, what, got[c], norm)
        }
      }
    }
    const tablesOut = Object.entries(line.rows).filter(([t]) => S.table[t]).map(([t, rows]) => rawTable(t, rows))
    const gone = Object.entries(line.gone ?? {}).flatMap(([t, ids]) => ids.map((id) => [S.table[t], id]))
    if (gone.length) tablesOut.push(["gone", { table: gone.map((g) => g[0]), id: gone.map((g) => g[1]) }])
    K.ingest(concat(frame("PATCH", ++rev, tablesOut), ack(o.op_id)))
    const ev = K.events()
    check(`ops.settled.${o.kind}`, what, JSON.stringify(ev.map((e) => [e.code, e.mis])), JSON.stringify([[0, 0]]))
  }

  const batchId = new Map((tables.find((t) => t.table === "batches")?.rows ?? []).map((b) => [b.code, b.id]))
  const profileId = new Map((tables.find((t) => t.table === "profiles")?.rows ?? []).map((p) => [p.slug, p.id]))

  // Cards.
  const cards = lines.filter((l) => l.kind === "card")
  check("cards", "count", K.k.rows(S.table.cards), cards.length)
  for (const c of cards) {
    const got = K.card(c.id)
    if (!got) {
      check("cards", `card ${c.id}`, "missing", "present")
      continue
    }
    const want = {
      score: c.score_100, heat: c.heat, stage: ix(STAGES, c.stage), status: ix(STATUSES, c.status),
      freshness: ix(FRESHNESS, c.freshness), gate: ix(GATES, c.gate),
      batch: c.batch_code === null ? 0 : batchId.get(c.batch_code), profile: profileId.get(c.profile_slug),
      hits: c.keyword_hits, total: c.keyword_total, hidden: c.mask_hidden, altered: c.mask_altered,
      emphasized: c.mask_emphasized, stage_on: none(c.stage_on), next_due: none(c.next_due),
      heat_state: ix(HEAT_STATES, c.heat_state), cooldown: none(c.cooldown_days), leased: c.leased ? 1 : 0,
      company: c.company, role: c.role, location: c.location ?? "", next_action: c.next_action ?? "",
      cv_label: c.cv_label, fit: c.fit ?? "", pips: c.pips, load: c.load, cap: c.cap,
      ats_vendor: c.ats_vendor, load_pct: c.cap <= 0 ? 100 : Math.round(c.load / c.cap * 100),
    }
    for (const [k, v] of Object.entries(want)) check(`cards.${k}`, `card ${c.id}`, got[k], v)
  }

  // Board order.
  const order = lines.find((l) => l.kind === "order")
  if (order) {
    const all = { min: -1, lo: -1000, hi: 1000, stage: -1, status: -1, batch: -1, profile: -1, heat: -1 }
    check("order", "ids", JSON.stringify(K.select(all, "")), JSON.stringify(order.ids))
  }

  // Verdicts.
  for (const v of lines.filter((l) => l.kind === "verdict")) {
    const row = K.k.row_of(S.table.verdicts, v.id)
    if (row < 0) {
      check("verdicts", `verdict ${v.id}`, "missing", "present")
      continue
    }
    const got = K.row("verdicts", row)
    for (const k of ["decision", "reason", "company", "company_load", "company_cap", "company_increment", "size",
      "ats_vendor", "vendor_load", "vendor_cap", "tenant_load", "tenant_cap", "note"]) {
      check(`verdicts.${k}`, `job ${v.id}`, got[k], v[k])
    }
    check("verdicts.ats_tenant", `job ${v.id}`, got.has_tenant ? got.ats_tenant : null, v.ats_tenant)
    check("verdicts.cooldown_days", `job ${v.id}`, got.cooldown_days, none(v.cooldown_days))
  }

  // The heat chart.
  const chart = lines.find((l) => l.kind === "heat_chart")?.value
  if (chart) {
    const rows = K.rows("heat_rows")
    for (const [g, list] of [[0, chart.companies], [1, chart.vendors]]) {
      const mine = rows.filter((r) => r.group === g)
      check("heat_chart", `group ${g} rows`, mine.length, list.length)
      list.forEach((want, i) => {
        const got = mine[i] ?? {}
        for (const k of ["key", "label", "load", "cap", "ratio", "n"]) check(`heat_chart.${k}`, `group ${g} #${i}`, got[k], want[k])
        check("heat_chart.cooldown_days", `group ${g} #${i}`, got.cooldown_days, none(want.cooldown_days))
        check("heat_chart.size", `group ${g} #${i}`, got.size, want.size ?? "")
      })
    }
  }

  // The scoreboard and its chart.
  const sb = lines.find((l) => l.kind === "scoreboard")?.value
  if (sb) {
    const got = K.rows("score")[0] ?? {}
    for (const k of ["leftover_unique", "batches_today", "batches_target", "apps_today", "apps_target",
      "submitted_today", "cumulative", "target_total"]) check(`score.${k}`, "scoreboard", got[k], sb[k])
    check("score.fire", "scoreboard", got.fire, sb.fire === "open_fire" ? 1 : 0)
    check("score.leftover_noted_on", "scoreboard", got.leftover_noted_on, none(sb.leftover_noted_on))
    check("score.target_on", "scoreboard", got.target_on, none(sb.target_on))
    const c = sb.chart
    check("score.chart_n", "chart", got.chart_n, c.n)
    check("score.chart_mean", "chart", got.chart_mean, c.mean ?? NaN)
    check("score.chart_max", "chart", got.chart_max, c.max ?? NaN)
    check("score.chart_min", "chart", got.chart_min, c.min ?? NaN)
    const bands = K.rows("chart_bands")
    c.bands.forEach((b, i) => {
      for (const k of ["key", "label", "min", "max", "count", "share"]) check(`chart_bands.${k}`, `#${i}`, bands[i]?.[k], b[k])
    })
    const bins = K.rows("chart_bins")
    c.bins.forEach((b, i) => {
      for (const k of ["lo", "hi", "count"]) check(`chart_bins.${k}`, `#${i}`, bins[i]?.[k], b[k])
    })
    const vs = K.rows("varieties")
    check("varieties", "count", vs.length, sb.varieties.length)
    sb.varieties.forEach((v, i) => {
      for (const k of ["code", "fire", "status", "label"]) check(`varieties.${k}`, `#${i}`, vs[i]?.[k], v[k])
    })
  }
  // Timing: a one-row PATCH re-derives everything that reads it.
  const jobs = tables.find((t) => t.table === "job_apps")?.rows ?? []
  const times = []
  for (let i = 0; i < 40 && jobs.length; i++) {
    const row = { ...jobs[i % jobs.length], score_100: (jobs[i % jobs.length].score_100 + 1) % 101 }
    const patch = frame("PATCH", 2 + i, [rawTable("job_apps", [row])])
    const t = performance.now()
    K.ingest(patch)
    times.push(performance.now() - t)
  }
  times.sort((a, b) => a - b)
  return { cards: cards.length, bootMs, patchMs: times[times.length >> 1] ?? 0 }
}

let failed = false
for (const f of files) {
  diffs.clear()
  const r = await one(f)
  const n = [...diffs.values()].reduce((a, l) => a + l.length, 0)
  console.log(`${path.basename(f)}: ${r.cards} cards, boot+derive ${r.bootMs.toFixed(2)} ms, one-row patch+derive ${r.patchMs.toFixed(2)} ms, ${n} differences`)
  for (const [kind, list] of diffs) {
    console.log(`  ${kind}: ${list.length}`)
    for (const d of list.slice(0, 4)) console.log(`    ${d}`)
  }
  if (n) failed = true
}
process.exit(failed ? 1 : 0)
