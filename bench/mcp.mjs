// MCP socket benchmark: JSON-RPC round trips on the directory socket and on
// a leased letterbox socket, timed from send to the matching reply.
//   node bench/mcp.mjs --port PORT --key hm_... --rev LABEL --out FILE.jsonl [--only directory,lanes,lease] [--scale 1]
//
// The key comes from bench/mint.exs (MINT=key).
import { appendFileSync } from "node:fs"
import { performance } from "node:perf_hooks"

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "1"])
  return acc
}, []))
const scale = Number(args.scale ?? "1")
const only = args.only ? new Set(args.only.split(",")) : null
const N = (n) => Math.max(1, Math.round(n * scale))
const pct = (s, q) => s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))]
const r3 = (x) => Math.round(x * 1000) / 1000

function emit(page, interaction, ms, extra = {}) {
  const sorted = [...ms].sort((a, b) => a - b)
  const row = {
    page, interaction, rev: args.rev, n: sorted.length,
    mean: r3(ms.reduce((a, b) => a + b, 0) / ms.length),
    p0_1: r3(pct(sorted, 0.001)), p1: r3(pct(sorted, 0.01)), p50: r3(pct(sorted, 0.5)),
    p99: r3(pct(sorted, 0.99)), p99_9: r3(pct(sorted, 0.999)),
    requests_per_op: 1, fixture: "canonical-1000", profile: "loopback", harness: "mcp-websocket",
    samples: ms.map(r3), ...extra,
  }
  if (args.out) appendFileSync(args.out, JSON.stringify(row) + "\n")
  console.log(`${page.padEnd(14)} ${interaction.padEnd(26)} n=${String(row.n).padStart(4)} p50=${row.p50.toFixed(3).padStart(9)} p99=${row.p99.toFixed(3).padStart(9)}`)
}

function open(path) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://localhost:${args.port}${path}`, { headers: { "x-api-key": args.key } })
    const waiting = new Map()
    let id = 0
    ws.onmessage = (e) => {
      const msg = JSON.parse(String(e.data))
      const w = waiting.get(msg.id)
      if (w) { waiting.delete(msg.id); w(msg) }
    }
    ws.onerror = (e) => reject(new Error(`socket error ${path}: ${e.message ?? ""} ${e.error?.message ?? ""}`))
    ws.onopen = () => resolve({
      ws,
      call(method, params) {
        return new Promise((res) => {
          const my = ++id
          const t0 = performance.now()
          waiting.set(my, (msg) => res({ ms: performance.now() - t0, msg }))
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: my, method, params }))
        })
      },
      close() { ws.close() },
    })
  })
}

const tool = (s, name, args = {}) => s.call("tools/call", { name, arguments: args })

async function series(s, n, f) {
  const out = []
  for (let i = 0; i < n; i++) {
    const { ms, msg } = await f(i)
    if (msg.error) throw new Error(JSON.stringify(msg.error))
    out.push(ms)
  }
  return out
}

const dir = await open("/mcp/websocket")
const boxes = (await tool(dir, "list_letterboxes")).msg.result.letterboxes
const jobs = boxes.map((b) => b.job_id)

const scenarios = {
  async directory() {
    emit("mcp/directory", "tools/list", await series(dir, N(1000), () => dir.call("tools/list", {})))
    emit("mcp/directory", "list_batches", await series(dir, N(1000), () => tool(dir, "list_batches")))
    emit("mcp/directory", "list_letterboxes", await series(dir, N(300), () => tool(dir, "list_letterboxes")))
    emit("mcp/directory", "list_applications", await series(dir, N(200), () => tool(dir, "list_applications")))
    emit("mcp/directory", "recommend_applications", await series(dir, N(200), () => tool(dir, "recommend_applications", { min_score: 50 })))
    emit("mcp/directory", "score_distribution", await series(dir, N(200), () => tool(dir, "score_distribution")))
    emit("mcp/directory", "heat_status", await series(dir, N(1000), () => tool(dir, "heat_status")))
    emit("mcp/directory", "can_apply", await series(dir, N(1000), (i) => tool(dir, "can_apply", { job_id: jobs[i % jobs.length] })))
    emit("mcp/directory", "gym_status", await series(dir, N(1000), () => tool(dir, "gym_status")))
    emit("mcp/directory", "net_status", await series(dir, N(1000), () => tool(dir, "net_status")))
  },
  async lanes() {
    emit("mcp/directory", "gym_log", await series(dir, N(300), (i) => tool(dir, "gym_log", { title: `MCP bench ${i}`, slug: `mcp-bench-${i % 50}` })))
    emit("mcp/directory", "gym_set_target", await series(dir, N(300), (i) => tool(dir, "gym_set_target", { target: 3 + (i % 5) })))
    emit("mcp/directory", "net_log", await series(dir, N(300), (i) => tool(dir, "net_log", { kind: "artifact", title: `MCP bench ${i}` })))
    emit("mcp/directory", "net_set_lane", await series(dir, N(300), (i) => tool(dir, "net_set_lane", { url: `https://observer.example.test/mcp/${i}` })))
  },
  async lease() {
    const box = boxes[0]
    const leaseMs = []
    // The key limiter admits 20 authentications per peer per minute.
    for (let i = 0; i < 15; i++) {
      const t0 = performance.now()
      const s = await open(box.socket)
      const { msg } = await s.call("tools/list", {})
      leaseMs.push(performance.now() - t0)
      if (msg.error) throw new Error(JSON.stringify(msg.error))
      await new Promise((r) => { s.ws.onclose = r; s.close() })
      await new Promise((r) => setTimeout(r, 100))
    }
    emit("mcp/letterbox", "lease + tools/list", leaseMs)
    const s = await open(box.socket)
    emit("mcp/letterbox", "get_application", await series(s, N(500), () => tool(s, "get_application")))
    emit("mcp/letterbox", "set_stage", await series(s, N(300), (i) => tool(s, "set_stage", { stage: i % 2 === 0 ? "gated" : "freshness" })))
    emit("mcp/letterbox", "set_next_action", await series(s, N(300), (i) => tool(s, "set_next_action", { next_action: `mcp follow up ${i}` })))
    emit("mcp/letterbox", "set_score", await series(s, N(300), (i) => tool(s, "set_score", { score: 40 + (i % 50) })))
    s.close()
  },
}

for (const [name, run] of Object.entries(scenarios)) {
  if (only && !only.has(name)) continue
  try { await run() } catch (e) { console.error(`mcp scenario ${name} failed:`, e.message) }
}
dir.close()
