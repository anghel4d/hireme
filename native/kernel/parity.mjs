// The kernel against what the server still decides.
//
//   node native/kernel/parity.mjs [--wasm path] oracle.jsonl...
//
// Each file is a dump from test/oracle/run.exs: the account's raw tables
// and what Elixir answers over them. The kernel's predictions stay on
// purpose (the optimistic path, which the server confirms or rolls back),
// so they are held to the server exactly: every op's refusal and the raw
// rows it writes against Ops.run, the heat verdicts a stage write is
// judged by against Heat.verdict, and the batch mixes against
// Heat.mix_batch, value for value and float bit for bit. Exits non-zero on
// any difference and prints the first few of each kind.
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

// A delta row carries only the columns that moved (plus id): encode just
// those, one block per row, so the upsert leaves the rest alone.
const SOURCE = { theme_targets: "theme", variety_flags: "variety", variety_apps: "variety", variety_companies: "variety",
  variety_roles: "variety", variety_locations: "variety", variety_fits: "variety" }
function deltaTables(name, rows) {
  return rows.map((row) => {
    const cols = {}
    for (const [c, def] of Object.entries(S.col[name])) {
      if (!(c in row) && !((SOURCE[c] ?? "") in row)) continue
      cols[c] = [rawValue(row, c, def.kind)]
    }
    return [name, cols]
  })
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
  // Events carry the server's clock and ids; they come with the PATCH.
  const UNPREDICTED = new Set(["events"])
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
        const [, cols] = deltaTables(table, [row])[0]
        let r = K.k.row_of(S.table[table], row.id)
        if (r < 0) {
          // A predicted insert carries a provisional id until this PATCH:
          // find the provisional row with the same values.
          const n = K.k.rows(S.table[table])
          const same = (got) => Object.entries(cols).every(([c, [v]]) => {
            // A provisional id stands for the row the same PATCH numbers.
            if (c === "id" || SKIP_COLS.has(c) || !(c in got) || (c.endsWith("_id") && got[c] >= 0x80000000)) return true
            const def = S.col[table][c]
            const norm = v === null ? (wireType(def.kind) === 2 ? "" : wireType(def.kind) === 4 ? NaN : NONE) : v
            return Object.is(got[c], norm)
          })
          r = Array.from({ length: n }, (_, i) => i).find((i) => K.row(table, i).id >= 0x80000000 && same(K.row(table, i))) ?? -1
          if (r < 0) {
            check(`ops.rows.${table}.insert`, what, "no matching predicted row", JSON.stringify(row))
            continue
          }
        }
        const got = K.row(table, r)
        for (const [c, [v]] of Object.entries(cols)) {
          if (SKIP_COLS.has(c) || !(c in got) || ((c === "id" || c.endsWith("_id")) && got[c] >= 0x80000000)) continue
          const def = S.col[table][c]
          const norm = v === null ? (wireType(def.kind) === 2 ? "" : wireType(def.kind) === 4 ? NaN : NONE) : v
          check(`ops.rows.${table}.${c}`, what, got[c], norm)
        }
      }
    }
    const tablesOut = Object.entries(line.rows).filter(([t]) => S.table[t]).flatMap(([t, rows]) => deltaTables(t, rows))
    const gone = Object.entries(line.gone ?? {}).flatMap(([t, ids]) => ids.map((id) => [S.table[t], id]))
    if (gone.length) tablesOut.push(["gone", { table: gone.map((g) => g[0]), id: gone.map((g) => g[1]) }])
    K.ingest(concat(frame("PATCH", ++rev, tablesOut), ack(o.op_id)))
    const ev = K.events()
    check(`ops.settled.${o.kind}`, what, JSON.stringify(ev.map((e) => [e.code, e.mis])), JSON.stringify([[0, 0]]))
  }

  const batchId = new Map((tables.find((t) => t.table === "batches")?.rows ?? []).map((b) => [b.code, b.id]))

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

  // Heat.mix_batch per batch.
  for (const m of lines.filter((l) => l.kind === "mix_batch")) {
    const id = batchId.get(m.code)
    K.k.mix(id)
    const rows = K.rows("mix")
    check("mix.kept", m.code, JSON.stringify(rows.filter((r) => r.kept).map((r) => r.job)), JSON.stringify(m.kept))
    const deferred = rows.filter((r) => !r.kept)
    check("mix.deferred", m.code, JSON.stringify(deferred.map((r) => [r.job, r.reason, r.note])),
      JSON.stringify(m.deferred.map((d) => [d.id, d.reason, d.note])))
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
  return { jobs: jobs.length, bootMs, patchMs: times[times.length >> 1] ?? 0 }
}

let failed = false
for (const f of files) {
  diffs.clear()
  const r = await one(f)
  const n = [...diffs.values()].reduce((a, l) => a + l.length, 0)
  console.log(`${path.basename(f)}: ${r.jobs} jobs, boot+derive ${r.bootMs.toFixed(2)} ms, one-row patch+derive ${r.patchMs.toFixed(2)} ms, ${n} differences`)
  for (const [kind, list] of diffs) {
    console.log(`  ${kind}: ${list.length}`)
    for (const d of list.slice(0, 4)) console.log(`    ${d}`)
  }
  if (n) failed = true
}
process.exit(failed ? 1 : 0)
