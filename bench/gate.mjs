// Timing of the WebTransport gate: cold connects, and with a local echoing
// Session (bench/gate_echo.exs, run under native/gate/netem.sh) the control
// round trip and a bulk transfer on it.
//
//   node bench/gate.mjs --url https://GATE_HOST/wt [--n 10] [--origin https://APP_HOST]
//     [--hash-file FILE --bytes N --boot N] [--out FILE.jsonl] [--rev LABEL]
//
// Every sample is a fresh connection (no session resumption, no address
// token), so every sample is a cold start.
//
// - probe: native/gate's Rust probe (built on first use). It times QUIC plus
//   the accepted CONNECT, then reads quinn's smoothed RTT after a second of
//   keep-alives. With no Origin and no ticket the production BEAM holds a
//   pending agent session for at most 2 s and drops it, so no credential is
//   involved.
// - chromium (with --origin; NODE_PATH and CHROME as for bench/desk.mjs): a
//   page served locally under that origin opens a session. Against production
//   it carries no ticket, so the BEAM refuses it with 403 after the CONNECT:
//   the time until `ready` rejects is exactly the cold connection cost a desk
//   pays before its first byte, and nothing is allocated.
// - --hash-file (local only): the self-signed certificate's hash file. The
//   echoing Session is then expected, and both clients also time the first
//   control echo and --bytes sent back on the control stream. With --boot N
//   the Session pushes N bytes on a server uni stream as it accepts, the way
//   a ticketed browser's BOOT arrives, and both clients time its first and
//   last byte from the start of the connect.
//
// The production gate's host is never committed; pass it on the command line.

import { createRequire } from "node:module"
import { appendFileSync, existsSync, readFileSync } from "node:fs"
import { execFileSync } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
)
if (!args.url) {
  console.error("usage: node bench/gate.mjs --url https://GATE_HOST/wt [--n 10] [--origin URL] [--hash-file F --bytes N] [--out FILE] [--rev LABEL]")
  process.exit(2)
}
const n = Number(args.n ?? 10)
const bytes = Number(args.bytes ?? 1 << 20)
const hash = args["hash-file"] ? readFileSync(args["hash-file"], "utf8").trim() : null
const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const gate = join(root, "native/gate")
const probe = join(gate, "target/release/examples/probe")
const at = new Date().toISOString()

function emit(record) {
  const line = JSON.stringify({ at, rev: args.rev ?? null, n, ...record })
  console.log(line)
  if (args.out) appendFileSync(args.out, line + "\n")
}

function quantiles(xs) {
  const s = [...xs].sort((a, b) => a - b)
  const q = (p) => +s[Math.min(s.length - 1, Math.floor((s.length * p) / 100))].toFixed(2)
  return { min: q(0), p50: q(50), p90: q(90), max: q(100) }
}

function runProbe(mode, ...extra) {
  const flags = hash ? ["--hash", hash] : []
  const out = execFileSync(probe, [mode, args.url, ...flags, ...extra], { encoding: "utf8" })
  return JSON.parse(out.trim().split("\n").pop())
}

if (!existsSync(probe)) {
  execFileSync(process.env.CARGO ?? "cargo", ["build", "--release", "--example", "probe", "--manifest-path", join(gate, "Cargo.toml")], { stdio: "inherit" })
}
const shake = runProbe("handshake", "--n", String(n))
emit({ client: "probe", connect_ms: shake.connect_ms, rtt_ms: shake.rtt_ms })
if (hash) {
  const echo = runProbe("echo", "--n", "50")
  const bulk = runProbe("bulk", "--bytes", String(bytes), "--rounds", "3")
  emit({ client: "probe", echo_ms: echo.rtt_ms, bytes, bulk_ms: bulk.bulk_ms })
  if (args.boot) {
    const b = JSON.parse(execFileSync(probe, ["boot", `${args.url}?boot=${args.boot}`, "--hash", hash, "--n", String(n)], { encoding: "utf8" }))
    emit({ client: "probe", boot_bytes: Number(args.boot), ready_ms: b.ready_ms, first_byte_ms: b.first_byte_ms, last_byte_ms: b.last_byte_ms })
  }
}

if (args.origin) {
  const { chromium } = createRequire(import.meta.url)("playwright-core")
  const browser = await chromium.launch({
    executablePath: process.env.CHROME ?? "chromium",
    // A route-fulfilled page has no known address space; let it reach loopback.
    args: hash ? ["--no-sandbox", "--disable-features=LocalNetworkAccessChecks"] : [],
  })
  const runs = []
  for (let i = 0; i < n; i++) {
    const ctx = await browser.newContext()
    const page = await ctx.newPage()
    await page.route(`${args.origin}/`, (r) => r.fulfill({ contentType: "text/html", body: "<!doctype html><title>gate</title>" }))
    await page.goto(`${args.origin}/`)
    runs.push(
      await page.evaluate(
        async ({ url, hash, bytes, boot }) => {
          const opts = hash
            ? { serverCertificateHashes: [{ algorithm: "sha-256", value: new Uint8Array(hash.match(/../g).map((h) => parseInt(h, 16))) }] }
            : {}
          const t0 = performance.now()
          const wt = new WebTransport(boot ? `${url}?boot=${boot}` : url, opts)
          const pushed = boot
            ? wt.incomingUnidirectionalStreams.getReader().read().then(async ({ value }) => {
                const r = value.getReader()
                let first = 0
                for (;;) {
                  const x = await r.read()
                  if (x.done) return { first, last: performance.now() - t0 }
                  first ||= performance.now() - t0
                }
              })
            : null
          try {
            await wt.ready
          } catch (e) {
            return { ready: performance.now() - t0, outcome: String(e) }
          }
          const ready = performance.now() - t0
          const b = pushed ? await pushed : {}
          if (!hash) {
            wt.close()
            return { ready, outcome: "accepted" }
          }
          const s = await wt.createBidirectionalStream()
          const w = s.writable.getWriter()
          const r = s.readable.getReader()
          const e = new Uint8Array(9)
          e[0] = 69
          await w.write(e)
          for (let got = 0; got < 9; ) got += (await r.read()).value.length
          const echo = performance.now() - t0
          const req = new Uint8Array(5)
          req[0] = 66
          new DataView(req.buffer).setUint32(1, bytes, true)
          const tb = performance.now()
          await w.write(req)
          for (let got = 0; got < bytes; ) got += (await r.read()).value.length
          const bulk = performance.now() - tb
          wt.close()
          return { ready, echo, bulk, boot_first: b.first, boot_last: b.last, outcome: "accepted" }
        },
        { url: args.url, hash, bytes, boot: args.boot ? Number(args.boot) : 0 },
      ),
    )
    await ctx.close()
  }
  await browser.close()
  const pick = (k) => (runs[0][k] === undefined ? undefined : quantiles(runs.map((r) => r[k])))
  emit({
    client: "chromium",
    ready_ms: pick("ready"),
    echo_ms: pick("echo"),
    bytes: hash ? bytes : undefined,
    bulk_ms: pick("bulk"),
    boot_first_byte_ms: pick("boot_first"),
    boot_last_byte_ms: pick("boot_last"),
    outcome: runs.at(-1).outcome,
  })
}
