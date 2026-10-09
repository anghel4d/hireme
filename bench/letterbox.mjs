// Letterbox benchmark: drives hireme-mcp over stdio, as an agent would, once
// over WebTransport (through the gate) and once over the WebSocket fallback,
// against the same testbed. Times are from the agent's side of stdio, so they
// include hireme-mcp itself.
//   node bench/letterbox.mjs --bin native/mcp/target/release/hireme-mcp --key hm_... \
//     --port PORT --wt https://127.0.0.1:4433/wt --hash _build/gate.hash \
//     --rev LABEL [--out FILE.jsonl] [--carriers wt,ws] [--leases 3] [--scale 1]
//
// The key comes from bench/mint.exs (MINT=key). Never point this at production.
import { spawn } from "node:child_process"
import { appendFileSync } from "node:fs"
import { performance } from "node:perf_hooks"
import { createInterface } from "node:readline"

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "1"])
  return acc
}, []))
const scale = Number(args.scale ?? "1")
const N = (n) => Math.max(1, Math.round(n * scale))
const LEASES = Number(args.leases ?? "3")
const carriers = (args.carriers ?? "wt,ws").split(",")
const pct = (s, q) => s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))]
const r3 = (x) => Math.round(x * 1000) / 1000

function emit(carrier, interaction, ms, extra = {}) {
  const sorted = [...ms].sort((a, b) => a - b)
  const row = {
    page: `letterbox/${carrier}`, interaction, rev: args.rev, n: sorted.length,
    mean: r3(ms.reduce((a, b) => a + b, 0) / ms.length),
    p0_1: r3(pct(sorted, 0.001)), p1: r3(pct(sorted, 0.01)), p50: r3(pct(sorted, 0.5)),
    p99: r3(pct(sorted, 0.99)), p99_9: r3(pct(sorted, 0.999)),
    fixture: "canonical-1000", profile: "loopback", harness: "hireme-mcp-stdio",
    samples: ms.map(r3), ...extra,
  }
  if (args.out) appendFileSync(args.out, JSON.stringify(row) + "\n")
  console.log(`${row.page.padEnd(14)} ${interaction.padEnd(30)} n=${String(row.n).padStart(4)} p50=${row.p50.toFixed(3).padStart(8)} p99=${row.p99.toFixed(3).padStart(8)}`)
}

// One hireme-mcp process on one carrier; JSON-RPC over its stdio.
function agent(carrier) {
  const env = {
    ...process.env,
    HIREME_API_KEY: args.key,
    HIREME_TRANSPORT: carrier,
    HIREME_WS_URL: `ws://127.0.0.1:${args.port}`,
  }
  if (args.wt) env.HIREME_WT_URL = args.wt
  if (args.hash) env.HIREME_WT_CERT_SHA256_FILE = args.hash
  const child = spawn(args.bin, [], { env, stdio: ["pipe", "pipe", "inherit"] })
  const waiting = new Map()
  let notes = 0
  let id = 0
  createInterface({ input: child.stdout }).on("line", (line) => {
    const m = JSON.parse(line)
    if (m.id !== undefined && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id) }
    else if (m.method === "notifications/message") notes++
  })
  const rpc = (method, params = {}) => new Promise((resolve) => {
    const my = ++id
    const t0 = performance.now()
    waiting.set(my, (m) => resolve({ ms: performance.now() - t0, m }))
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: my, method, params }) + "\n")
  })
  return {
    rpc,
    async tool(name, a = {}) {
      const r = await rpc("tools/call", { name, arguments: a })
      if (r.m.error || r.m.result?.isError) throw new Error(`${name}: ${JSON.stringify(r.m.error ?? r.m.result.content)}`)
      return { ms: r.ms, v: r.m.result.structuredContent }
    },
    notes: () => notes,
    close: () => child.kill(),
  }
}

async function run(carrier) {
  const a = agent(carrier)
  const t0 = performance.now()
  await a.rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bench", version: "0" } })
  const listed = await a.rpc("tools/list")
  if (!listed.m.result) throw new Error(JSON.stringify(listed.m.error))
  emit(carrier, "start: initialize + tools/list", [performance.now() - t0])

  // A tool the server does not know: one round trip through every hop, no work.
  const noop = []
  for (let i = 0; i < N(500); i++) noop.push((await a.rpc("tools/call", { name: "no_such_tool", arguments: {} })).ms)
  emit(carrier, "round trip (unknown tool)", noop)

  // One lease per employer: a shared CV lineage refuses a second.
  const boxes = (await a.tool("list_letterboxes")).v.letterboxes.filter((b) => !b.leased)
  const seen = new Set()
  const picks = []
  for (const b of boxes) {
    if (!seen.has(b.company)) { seen.add(b.company); picks.push(b) }
    if (picks.length === LEASES) break
  }

  // Over websockets every lease is a key authentication, and the key limiter
  // admits 20 per peer per minute; one WebTransport session pays for one.
  const rounds = carrier === "ws" ? 2 : N(5)
  const leaseMs = []
  for (let round = 0; round < rounds; round++) {
    const t = performance.now()
    await Promise.all(picks.map((b) => a.tool("lease_letterbox", { letterbox_id: b.letterbox_id })))
    leaseMs.push(performance.now() - t)
    for (const b of picks) await a.tool("release_letterbox", { letterbox_id: b.letterbox_id })
    await new Promise((r) => setTimeout(r, 50))
  }
  emit(carrier, `lease x${picks.length} in parallel`, leaseMs)
  await Promise.all(picks.map((b) => a.tool("lease_letterbox", { letterbox_id: b.letterbox_id })))

  for (const k of [1, picks.length]) {
    const reads = []
    const writes = []
    const t = performance.now()
    await Promise.all(picks.slice(0, k).map(async (b) => {
      for (let i = 0; i < N(60); i++) {
        reads.push((await a.tool("get_application", { letterbox_id: b.letterbox_id })).ms)
        writes.push((await a.tool("set_next_action", { letterbox_id: b.letterbox_id, next_action: `bench ${i}` })).ms)
      }
    }))
    const wall = performance.now() - t
    emit(carrier, `get_application, ${k} lease(s)`, reads)
    emit(carrier, `set_next_action, ${k} lease(s)`, writes, { calls_per_s: Math.round(((reads.length + writes.length) / wall) * 1000) })
  }
  const state = (await a.tool("list_leases")).v
  console.log(`  ${carrier}: carrier=${state.carrier} frames=${state.frames} rows_decoded=${state.rows_decoded} notifications=${a.notes()}`)
  a.close()
}

for (const c of carriers) {
  try { await run(c) } catch (e) { console.error(`letterbox ${c} failed:`, e.message) }
}
process.exit(0)
