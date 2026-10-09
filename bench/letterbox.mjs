// Letterbox benchmark: a fleet of hireme-mcp agents, each holding one block of
// applications, driven over stdio as agents drive it, once over WebTransport
// (through the gate) and once over the WebSocket fallback, against the same
// testbed. Times are from the agent's side of stdio, so they include
// hireme-mcp itself.
//   node bench/letterbox.mjs --bin native/mcp/target/release/hireme-mcp --key hm_... \
//     --port PORT --wt https://127.0.0.1:4433/wt --hash _build/gate.hash \
//     --rev LABEL [--out FILE.jsonl] [--carriers wt,ws] \
//     [--agents 10] [--block 16] [--seconds 10] [--inflight 1]
//
// Each agent leases {"count":block}, then keeps `inflight` writes going
// across its block for `seconds`. Halfway through, agent 0 is killed with its
// block held, and a spare agent asks for exactly that block until it gets it:
// the time it waits is how long a dead agent's block stays out.
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
const AGENTS = Number(args.agents ?? "10")
const BLOCK = Number(args.block ?? "16")
const SECONDS = Number(args.seconds ?? "10")
const INFLIGHT = Number(args.inflight ?? "1")
const carriers = (args.carriers ?? "wt,ws").split(",")
const pct = (s, q) => s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))]
const r3 = (x) => Math.round(x * 1000) / 1000
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function emit(carrier, interaction, ms, extra = {}) {
  const sorted = [...ms].sort((a, b) => a - b)
  const row = {
    page: `letterbox/${carrier}`, interaction, rev: args.rev, n: sorted.length,
    mean: r3(ms.reduce((a, b) => a + b, 0) / Math.max(1, ms.length)),
    p0_1: r3(pct(sorted, 0.001) ?? 0), p1: r3(pct(sorted, 0.01) ?? 0), p50: r3(pct(sorted, 0.5) ?? 0),
    p99: r3(pct(sorted, 0.99) ?? 0), p99_9: r3(pct(sorted, 0.999) ?? 0),
    fixture: "canonical-1000", profile: "loopback", harness: "hireme-mcp-stdio",
    agents: AGENTS, block: BLOCK, inflight: INFLIGHT, ...extra,
  }
  if (args.out) appendFileSync(args.out, JSON.stringify({ ...row, samples: ms.map(r3) }) + "\n")
  const more = Object.entries(extra).map(([k, v]) => `${k}=${typeof v === "object" ? JSON.stringify(v) : v}`).join(" ")
  console.log(`${row.page.padEnd(14)} ${interaction.padEnd(34)} n=${String(row.n).padStart(6)} p50=${row.p50.toFixed(3).padStart(8)} p99=${row.p99.toFixed(3).padStart(8)} ${more}`)
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
  let id = 0
  createInterface({ input: child.stdout }).on("line", (line) => {
    const m = JSON.parse(line)
    if (m.id !== undefined && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id) }
  })
  child.stdin.on("error", () => {})
  // A killed agent answers nothing more: settle what it still owed.
  child.on("exit", () => {
    for (const done of waiting.values()) done({ error: { message: "agent exited" } })
    waiting.clear()
  })
  const rpc = (method, params = {}) => new Promise((resolve) => {
    const my = ++id
    const t0 = performance.now()
    waiting.set(my, (m) => resolve({ ms: performance.now() - t0, m }))
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: my, method, params }) + "\n")
  })
  return {
    rpc,
    // A refusal is an answer, not an exception: its code is the diagnostic's.
    async tool(name, a = {}) {
      const r = await rpc("tools/call", { name, arguments: a })
      const text = r.m.result?.content?.[0]?.text ?? JSON.stringify(r.m.error)
      const code = r.m.error ? "rpc" : r.m.result.isError ? (text.match(/^error\[(\w+)\]/)?.[1] ?? "?") : null
      return { ms: r.ms, code, text, v: r.m.result?.structuredContent }
    },
    start: () => rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bench", version: "0" } }),
    kill: () => child.kill("SIGKILL"),
    close: () => child.kill(),
  }
}

async function run(carrier) {
  const fleet = Array.from({ length: AGENTS }, () => agent(carrier))
  const spare = agent(carrier)
  let t = performance.now()
  await Promise.all([...fleet, spare].map((a) => a.start()))
  // The first tool call opens the session: HELLO, BOOT, the desk in the kernel.
  const opened = await Promise.all([...fleet, spare].map((a) => a.tool("block")))
  emit(carrier, `start ${AGENTS + 1} agents (to first call)`, [performance.now() - t], { per_agent_p50: r3(pct(opened.map((o) => o.ms).sort((a, b) => a - b), 0.5)) })

  // Every agent asks for a block of its size at once; the desk picks.
  t = performance.now()
  const leased = await Promise.all(fleet.map((a) => a.tool("lease", { count: BLOCK })))
  const refusedLeases = leased.filter((l) => l.code).map((l) => l.code)
  emit(carrier, `lease {"count":${BLOCK}} x${AGENTS} at once`, leased.map((l) => l.ms), { wall_ms: r3(performance.now() - t), refused: refusedLeases })
  const blocks = leased.map((l) => l.v)
  if (refusedLeases.length) console.log(leased.find((l) => l.code).text)

  // Writes: each agent keeps INFLIGHT set_score calls going across its block.
  const writes = []
  const refusals = {}
  let stop = false
  const work = fleet.map(async (a, i) => {
    const b = blocks[i]
    if (!b) return
    let k = 0
    await Promise.all(Array.from({ length: INFLIGHT }, async () => {
      while (!stop && !a.dead) {
        const entry = b.from + (k++ % (b.to - b.from + 1))
        const w = await a.tool("set_score", { entry, score: (k * 7) % 101 })
        if (a.dead) return
        if (w.code && !refusals[w.code]) console.log(`agent ${i}, block ${b.from}..${b.to}:\n${w.text}`)
        if (w.code) refusals[w.code] = (refusals[w.code] ?? 0) + 1
        else writes.push(w.ms)
      }
    }))
  })

  // Halfway, agent 0 dies holding its block; the spare asks for that block.
  const dead = blocks[0]
  let back = null
  const killer = (async () => {
    await sleep((SECONDS * 1000) / 2)
    if (!dead) return
    fleet[0].dead = true
    fleet[0].kill()
    const k = performance.now()
    let tries = 0
    for (;;) {
      tries++
      const r = await spare.tool("lease", { from: dead.from, to: dead.to })
      if (!r.code) { back = { ms: performance.now() - k, tries }; return }
      if (r.code !== "busy" || performance.now() - k > 30_000) { console.log(r.text); return }
      await sleep(5)
    }
  })()

  t = performance.now()
  await sleep(SECONDS * 1000)
  stop = true
  await Promise.all([...work, killer])
  const wall = performance.now() - t
  emit(carrier, `set_score, ${AGENTS} blocks of ${BLOCK}`, writes, {
    writes_per_s: Math.round((writes.length / wall) * 1000), refusals,
  })
  if (back) emit(carrier, "dead agent's block back to spare", [back.ms], { tries: back.tries })

  await Promise.all([...fleet.slice(1), spare].map((a) => a.tool("release")))
  for (const a of [...fleet, spare]) a.close()
}

for (const c of carriers) {
  try { await run(c) } catch (e) { console.error(`letterbox ${c} failed:`, e.message) }
  await sleep(500)
}
process.exit(0)
