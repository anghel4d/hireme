// Timing of the WebTransport gate: cold connects, and with a local echoing
// Session (bench/gate_echo.exs, run under native/gate/netem.sh) the control
// round trip and a BOOT pushed as the session is accepted.
//
//   node bench/gate.mjs --url https://GATE_HOST/wt [--n 10] [--origin https://APP_HOST]
//     [--hash-file FILE [--boot BYTES]] [--out FILE.jsonl] [--rev LABEL]
//
// Every sample is a fresh connection (no session resumption, no address
// token), so every sample is a cold start.
//
// - probe: native/gate's Rust probe (built on first use). It times QUIC plus
//   the accepted CONNECT, then reads quinn's smoothed RTT after a second of
//   keep-alives. With no Origin and no ticket the production BEAM holds a
//   pending agent session for at most 2 s and drops it, so no credential is
//   involved.
// - chromium (with --origin; NODE_PATH and CHROME as for bench/browser.mjs): a
//   page served locally under that origin opens a session. Against production
//   it carries no ticket, so the BEAM refuses it with 403 after the CONNECT:
//   the time until `ready` rejects is exactly the cold connection cost a desk
//   pays before its first byte, and nothing is allocated.
// - --hash-file (local only): the self-signed certificate's hash file. The
//   echoing Session is then expected: both clients time the first and last
//   byte of a BOOT of --boot bytes (1 MiB by default) that the Session pushes
//   on a server uni stream as it accepts, from the start of the connect, and
//   Chromium then times a control-stream echo.
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
  console.error("usage: node bench/gate.mjs --url https://GATE_HOST/wt [--n 10] [--origin URL] [--hash-file F [--boot BYTES]] [--out FILE] [--rev LABEL]")
  process.exit(2)
}
const n = Number(args.n ?? 10)
const hash = args["hash-file"] ? readFileSync(args["hash-file"], "utf8").trim() : null
const boot = hash ? Number(args.boot ?? 1 << 20) : 0
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

function runProbe(mode, url, ...extra) {
  const out = execFileSync(probe, [mode, url, ...(hash ? ["--hash", hash] : []), ...extra], { encoding: "utf8" })
  return JSON.parse(out.trim().split("\n").pop())
}

if (!existsSync(probe)) {
  execFileSync(process.env.CARGO ?? "cargo", ["build", "--release", "--example", "probe", "--manifest-path", join(gate, "Cargo.toml")], { stdio: "inherit" })
}
const shake = runProbe("handshake", args.url, "--n", String(n))
emit({ client: "probe", connect_ms: shake.connect_ms, rtt_ms: shake.rtt_ms })
if (hash) {
  const pushed = runProbe("boot", `${args.url}?boot=${boot}`, "--n", String(n))
  emit({ client: "probe", boot, ready_ms: pushed.ready_ms, boot_first_ms: pushed.first_byte_ms, boot_last_ms: pushed.last_byte_ms })
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
        async ({ url, hash, boot }) => {
          const opts = hash
            ? { serverCertificateHashes: [{ algorithm: "sha-256", value: new Uint8Array(hash.match(/../g).map((h) => parseInt(h, 16))) }] }
            : {}
          const t0 = performance.now()
          const since = () => performance.now() - t0
          const wt = new WebTransport(boot ? `${url}?boot=${boot}` : url, opts)
          try {
            await wt.ready
          } catch (e) {
            return { ready: since(), outcome: String(e) }
          }
          const ready = since()
          if (!hash) {
            wt.close()
            return { ready, outcome: "accepted" }
          }
          const uni = (await wt.incomingUnidirectionalStreams.getReader().read()).value.getReader()
          await uni.read()
          const first = since()
          while (!(await uni.read()).done);
          const last = since()
          const s = await wt.createBidirectionalStream()
          const w = s.writable.getWriter()
          const r = s.readable.getReader()
          const te = performance.now()
          await w.write(new Uint8Array([69, 0, 0, 0, 0, 0, 0, 0, 0]))
          for (let got = 0; got < 9; ) got += (await r.read()).value.length
          const echo = performance.now() - te
          wt.close()
          return { ready, first, last, echo, outcome: "accepted" }
        },
        { url: args.url, hash, boot },
      ),
    )
    await ctx.close()
  }
  await browser.close()
  const pick = (k) => (runs[0][k] === undefined ? undefined : quantiles(runs.map((r) => r[k])))
  emit({
    client: "chromium",
    ready_ms: pick("ready"),
    boot: boot || undefined,
    boot_first_ms: pick("first"),
    boot_last_ms: pick("last"),
    echo_ms: pick("echo"),
    outcome: runs.at(-1).outcome,
  })
}
