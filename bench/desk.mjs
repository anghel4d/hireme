// Input-to-paint for every surface of the desk shell, on a private copy of
// the canonical fixture, in a fresh browser profile.
//
//   NODE_PATH=<dir holding playwright-core 1.63> CHROME=<chromium binary> \
//   node bench/desk.mjs [--release DIR | --mix] [--fixture /tmp/hireme-perf-canonical] \
//     [--port 4471] [--n 200] [--only hjkl,search,...] [--rtt MS] [--bundle DIR] [--rev LABEL] [--out FILE.jsonl]
//   node bench/desk.mjs --base http://localhost:PORT --meta BENCH_DIR/testbed.json [...]
//
// Without --base it copies the fixture's hireme.db into a fresh temporary
// BENCH_DIR (the fixture itself is never opened for writing), starts
// bench/testbed.exs against the copy, either from a release (--release DIR,
// `DIR/bin/hireme eval`) or from this checkout (--mix: `mix run` in prod with
// synthetic secrets, assets as last built into priv/static), runs, then stops
// it and deletes the copy. Every scenario opens a new browser context, so no
// IndexedDB snapshot or cache survives between them. --bundle DIR serves that
// build's app.js and app.css in place of the testbed's, so a client change is
// measured against the same server. Never point it at production.
//
// Every input is fired inside the page, not through the harness, so no CDP
// round trip is timed. A sample runs from the input event's timeStamp to the
// task after the first frame in which the expected state is in the DOM: that
// frame has been painted. "same frame" counts samples whose state was there
// at the first animation frame after the input. "frame js" is the time the
// page's own requestAnimationFrame callbacks took in that frame (the shell's
// draw). "http" counts fetch() calls made during the scenario: the desk runs
// on its session, so anything above 0 is a regression.
//
// The stage scenario also checks the kin cards (the moved job's company) on
// the board in the first frame after Escape against what they show once the
// server has answered: derived fields are predicted exactly, so every round
// must match. Form writes pause after Playwright's fill, whose input events
// queue a frame of their own that would otherwise be counted.
//
// This replaces bench/browser.mjs, which timed each interaction until the
// network went quiet and matched writes to the desk's HTTP routes; those
// routes are gone and the desk now answers in the input's frame.

import { createRequire } from "node:module"
import { copyFileSync, chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, appendFileSync } from "node:fs"
import { spawn } from "node:child_process"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

const { chromium } = createRequire(import.meta.url)("playwright-core")

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "1"])
  return acc
}, []))
const N = Number(args.n ?? "200")
const only = args.only ? new Set(args.only.split(",")) : null
const want = (name) => !only || only.has(name)
const rev = args.rev ?? "unknown"
const repo = resolve(new URL("..", import.meta.url).pathname)

// ---- the testbed ----

async function startTestbed() {
  const fixture = args.fixture ?? "/tmp/hireme-perf-canonical"
  const dir = mkdtempSync(join(tmpdir(), "hireme-desk-bench-"))
  for (const f of ["hireme.db", "hireme.db-wal", "hireme.db-shm"]) {
    if (!existsSync(join(fixture, f))) continue
    copyFileSync(join(fixture, f), join(dir, f))
    chmodSync(join(dir, f), 0o600)
  }
  const port = args.port ?? "4471"
  const env = {
    ...process.env,
    BENCH_DIR: dir, DATABASE_PATH: join(dir, "hireme.db"), PORT: port, PHX_SERVER: "1", PHX_HOST: "localhost",
    SECRET_KEY_BASE: "desk-bench-".repeat(8), CLOUDFLARE_ACCOUNT_ID: "none", CLOUDFLARE_EMAIL_TOKEN: "none",
    ERL_FLAGS: process.env.ERL_FLAGS ?? "+S 4:4",
  }
  const [cmd, argv, cwd] = args.release
    ? [join(args.release, "bin/hireme"), ["eval", 'Code.eval_file("bench/testbed.exs")'], repo]
    : ["mix", ["run", "--no-start", "bench/testbed.exs"], repo]
  if (!args.release) env.MIX_ENV = "prod"
  const child = spawn(cmd, argv, { cwd, env, stdio: ["ignore", "pipe", "pipe"] })
  let log = ""
  await new Promise((ok, fail) => {
    const timer = setTimeout(() => fail(new Error(`testbed did not start:\n${log.slice(-2000)}`)), 600_000)
    const read = (b) => {
      log += b
      if (log.includes("HIREME_BENCH_READY")) { clearTimeout(timer); ok() }
    }
    child.stdout.on("data", read)
    child.stderr.on("data", read)
    child.on("exit", (code) => { clearTimeout(timer); fail(new Error(`testbed exited ${code}:\n${log.slice(-2000)}`)) })
  })
  return {
    base: `http://localhost:${port}`,
    meta: JSON.parse(readFileSync(join(dir, "testbed.json"), "utf8")),
    stop() { child.removeAllListeners("exit"); child.kill("SIGTERM"); rmSync(dir, { recursive: true, force: true }) },
  }
}

const bed = args.base
  ? { base: args.base, meta: JSON.parse(readFileSync(args.meta, "utf8")), stop() {} }
  : await startTestbed()

// ---- in-page probe ----

function probe() {
  window.__t0 = 0
  window.__http = 0
  window.__js = []
  for (const type of ["keydown", "click", "submit", "input"]) window.addEventListener(type, (e) => { window.__t0 = e.timeStamp }, true)
  const f = window.fetch.bind(window)
  window.fetch = (...a) => { window.__http++; return f(...a) }
  // The page's own rAF callbacks are timed; the probe's go through __raf untimed.
  const raf = window.requestAnimationFrame.bind(window)
  window.__raf = raf
  window.requestAnimationFrame = (cb) => raf((t) => {
    const s = performance.now()
    try { cb(t) } finally { window.__js.push([s, performance.now() - s]) }
  })
  // First card on the board, for the load scenario.
  new MutationObserver((_, mo) => {
    if (document.querySelector("#plane .card")) { window.__firstCard = performance.now(); mo.disconnect() }
  }).observe(document, { subtree: true, childList: true })
  window.__act = (fire, src, timeout = 5000) => new Promise((resolve) => {
    const cond = new Function(`return (${src})`)
    const js0 = window.__js.length
    new Function(fire)()
    const began = performance.now()
    let frames = 0
    const check = () => {
      frames++
      if (cond()) {
        const js = window.__js.slice(js0).reduce((a, [, d]) => a + d, 0)
        const ch = new MessageChannel()
        ch.port1.onmessage = () => resolve({ ms: performance.now() - window.__t0, frames, js })
        ch.port2.postMessage(0)
      } else if (performance.now() - began > timeout) resolve({ ms: NaN, frames, js: NaN })
      else window.__raf(check)
    }
    window.__raf(check)
  })
}

// ---- reporting ----

const pct = (xs, p) => { const s = xs.filter(Number.isFinite).sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.ceil(p * s.length) - 1)] : NaN }
const f2 = (x) => (Number.isFinite(x) ? x.toFixed(2) : "-").padStart(7)
const rows = []
function report(name, rs, http, extra = "") {
  const ms = rs.map((r) => r.ms)
  const same = rs.filter((r) => r.frames === 1 && Number.isFinite(r.ms)).length
  const row = {
    interaction: name, rev, n: rs.length, p50: pct(ms, 0.5), p90: pct(ms, 0.9), p99: pct(ms, 0.99), max: pct(ms, 1),
    same_frame: same, frame_js_p50: pct(rs.map((r) => r.js), 0.5), http, missed: ms.filter((x) => !Number.isFinite(x)).length,
    fixture: "canonical-1000", harness: "desk", bundle: args.bundle ? "intercepted" : "release", samples: ms,
  }
  rows.push(row)
  if (args.out) appendFileSync(args.out, JSON.stringify(row) + "\n")
  console.log(`${name.padEnd(24)} ${String(rs.length).padStart(4)} ${f2(row.p50)} ${f2(row.p90)} ${f2(row.p99)}   ${`${same}/${rs.length}`.padStart(7)} ${f2(row.frame_js_p50)} ${String(http).padStart(5)}${row.missed ? `  missed ${row.missed}` : ""} ${extra}`)
}

// ---- browser ----

const browser = await chromium.launch({
  executablePath: process.env.CHROME,
  args: ["--disable-gpu-vsync", "--disable-frame-rate-limit", "--disable-background-timer-throttling", "--disable-renderer-backgrounding"],
})

async function fresh(path = "/", { rtt = 0 } = {}) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, bypassCSP: true })
  await context.addInitScript(probe)
  await context.addCookies([{ name: "__Host-hireme", value: bed.meta.cookie, domain: "localhost", path: "/", secure: true, httpOnly: true, sameSite: "Lax" }])
  if (args.bundle) {
    for (const name of ["app.js", "app.css"]) {
      const body = readFileSync(join(args.bundle, name))
      await context.route(`**/assets/js/${name}`, (r) => r.fulfill({ status: 200, contentType: name.endsWith(".js") ? "text/javascript" : "text/css", body }))
    }
  }
  const page = await context.newPage()
  page.on("pageerror", (e) => console.error("pageerror", e.message))
  if (rtt > 0) {
    // Chromium's emulation delays HTTP requests and the WebSocket handshake, not WebSocket frames.
    const cdp = await context.newCDPSession(page)
    await cdp.send("Network.enable")
    await cdp.send("Network.emulateNetworkConditions", { offline: false, latency: rtt, downloadThroughput: -1, uploadThroughput: -1 })
  }
  await page.goto(bed.base + path)
  await page.waitForSelector("#plane .card, #lens .battleplan-wrap, #lens .lane-wrap", { timeout: 30000 })
  await page.waitForTimeout(1500)
  await page.evaluate(() => { window.__http = 0 })
  return { page, close: () => context.close() }
}

const key = (k) => `window.dispatchEvent(new KeyboardEvent("keydown", { key: ${JSON.stringify(k)}, bubbles: true }))`
const act = (page, fire, cond) => page.evaluate(([f, c]) => window.__act(f, c), [fire, cond])
const http = (page) => page.evaluate(() => { const n = window.__http; window.__http = 0; return n })
const FOCUS_SHOWN = `(() => { const a = document.querySelector("#plane .card.is-active h2"); const f = document.querySelector("#focus h2")
  return !!a && !!f && a.textContent === f.textContent })()`

console.log(`desk bench · rev ${rev} · ${bed.base}${args.bundle ? ` · bundle ${args.bundle}` : ""}`)
console.log(`${"scenario".padEnd(24)} ${"n".padStart(4)} ${"p50".padStart(7)} ${"p90".padStart(7)} ${"p99".padStart(7)}   ${"frame1".padStart(7)} ${"js".padStart(7)} ${"http".padStart(5)}   (ms, input to paint)`)

const scenarios = {
  // Navigation to the first painted card, each in a new profile (no
  // snapshot): on loopback, and with --rtt MS emulated on HTTP as well.
  async load() {
    for (const rtt of [0, Number(args.rtt ?? 0)].filter((r, i) => i === 0 || r > 0)) {
      const rs = []
      for (let i = 0; i < Math.min(N, 20); i++) {
        const { page, close } = await fresh("/", { rtt })
        rs.push({ ms: await page.evaluate(() => window.__firstCard ?? NaN), frames: 0, js: NaN })
        await close()
      }
      report(rtt ? `cold load, ${rtt} ms rtt` : "cold load, first card", rs, 0, "(from navigation start)")
    }
  },

  // hjkl: the focus panel names the newly active card.
  async hjkl() {
    const { page, close } = await fresh()
    const rs = []
    const pattern = ["l", "j", "h", "k", "l", "l", "j", "j", "h", "h", "k", "k"]
    for (let i = 0; i < N; i++) {
      rs.push(await act(page, key(pattern[i % pattern.length]), FOCUS_SHOWN))
      await page.waitForTimeout(20)
    }
    report("hjkl -> focus", rs, await http(page))
    await close()
  },

  // Click a visible card that is not the active one.
  async click() {
    const { page, close } = await fresh()
    const rs = []
    for (let i = 0; i < N; i++) {
      const id = await page.evaluate((i) => {
        const g = document.querySelector("#grid").getBoundingClientRect()
        const cards = [...document.querySelectorAll("#plane .card:not(.is-active)")].filter((c) => { const r = c.getBoundingClientRect(); return r.top >= g.top && r.bottom <= g.bottom })
        return cards.length ? cards[i % cards.length].id : null
      }, i)
      if (!id) break
      rs.push(await act(page, `document.getElementById(${JSON.stringify(id)}).click()`, `document.getElementById(${JSON.stringify(id)}).classList.contains("is-active") && ${FOCUS_SHOWN}`))
      await page.waitForTimeout(20)
    }
    report("click card -> focus", rs, await http(page))
    await close()
  },

  // One character into the search box; the next draw shows the kernel's answer.
  async search() {
    const { page, close } = await fresh()
    const rs = []
    const words = ["systems", "company 4", "engineer 9", "cv77", "remote"]
    for (let i = 0; rs.length < N; i++) {
      const w = words[i % words.length]
      for (let k = 1; k <= w.length && rs.length < N; k++) {
        const v = w.slice(0, k)
        // Done when the shell has drawn once since the keystroke.
        rs.push(await act(page, `window.__j0 = window.__js.length; const q = document.getElementById("q"); q.value = ${JSON.stringify(v)}; q.dispatchEvent(new Event("input", { bubbles: true }))`,
          `window.__js.length > window.__j0`))
      }
      await page.evaluate(() => { const q = document.getElementById("q"); q.value = ""; q.dispatchEvent(new Event("input", { bubbles: true })) })
      await page.waitForTimeout(40)
    }
    report("search keystroke", rs, await http(page))
    await close()
  },

  // Scroll the board by 400 px: a card is placed on the new top row.
  async scroll() {
    const { page, close } = await fresh()
    const rs = []
    let y = 0, dir = 1
    for (let i = 0; i < N; i++) {
      const max = await page.evaluate(() => { const g = document.querySelector("#grid"); return g.scrollHeight - g.clientHeight })
      if (y + 400 * dir > max || y + 400 * dir < 0) dir = -dir
      y += 400 * dir
      rs.push(await act(page, `window.__t0 = performance.now(); document.querySelector("#grid").scrollTop = ${y}`,
        `[...document.querySelectorAll("#plane .card")].some((c) => { const t = parseFloat(c.style.top); return t >= ${y} && t < ${y} + 200 })`))
    }
    report("scroll 400px", rs, await http(page), "(from the scroll assignment)")
    await close()
  },

  // Enter opens the battleplan with its CV; Escape brings the whole board back.
  async battleplan() {
    const { page, close } = await fresh()
    const open = [], back = []
    for (let i = 0; i < Math.min(N, 60); i++) {
      open.push(await act(page, key("Enter"), `!!document.querySelector("#battleplan #bp-paper .paper")`))
      back.push(await act(page, key("Escape"), `!document.getElementById("workspace").dataset.covered && !!document.querySelector("#plane .card.is-active")`))
      await page.evaluate((f) => new Function(f)(), key(i % 2 ? "l" : "h"))
      await page.waitForTimeout(30)
    }
    const n = await http(page)
    report("battleplan open", open, n)
    report("battleplan back (esc)", back, 0)
    await close()
  },

  // Stage writes in the battleplan of a card whose company has kin on the board.
  async stage() {
    const { page, close } = await fresh()
    const [company, ids] = await page.evaluate(() => {
      const by = new Map()
      for (const c of document.querySelectorAll("#plane .card")) {
        const k = c.querySelector("h2").textContent
        by.set(k, [...(by.get(k) ?? []), c.id])
      }
      return [...by].sort((a, b) => b[1].length - a[1].length)[0]
    })
    // A stage move can reorder the board: search the company so its cards stay on screen.
    await page.evaluate((c) => { const q = document.getElementById("q"); q.value = c; q.dispatchEvent(new Event("input", { bubbles: true })) }, company)
    await page.waitForTimeout(200)
    const kin = `[...document.querySelectorAll("#plane .card")].filter((c) => c.querySelector("h2").textContent === ${JSON.stringify(company)})
      .map((c) => [c.id, c.querySelector(".heat-load").getAttribute("title"), c.querySelector(".heat-load").textContent, c.querySelector(".stage-name").textContent, c.querySelector(".score")?.textContent, c.querySelector(".pips").innerHTML].join("|")).sort().join(",")`
    const rs = []
    let exact = 0, rounds = 0
    for (let i = 0; i < Math.min(N, 80); i++) {
      await page.evaluate((id) => document.getElementById(id)?.click(), ids[0])
      await page.evaluate((f) => new Function(f)(), key("Enter"))
      await page.waitForSelector("#battleplan button[id^=stage-]")
      const stages = await page.$$eval("#battleplan button[id^=stage-]", (bs) => bs.map((b) => b.id).filter((id) => id !== "stage-closed"))
      const target = stages[(i * 3) % stages.length]
      rs.push(await act(page, `document.getElementById(${JSON.stringify(target)}).click()`,
        `document.getElementById(${JSON.stringify(target)})?.classList.contains("is-active") || !!document.querySelector("#hold-error")`))
      const first = await page.evaluate(([f, k]) => new Promise((res) => { new Function(f)(); window.__raf(() => res(new Function(`return ${k}`)())) }), [key("Escape"), kin])
      await page.waitForTimeout(600)
      const settled = await page.evaluate((k) => new Function(`return ${k}`)(), kin)
      rounds++
      if (first === settled) exact++
    }
    report("stage write", rs, await http(page), `kin exact in first frame ${exact}/${rounds}`)
    await close()
  },

  // Each lens from the board, then back.
  async lenses() {
    const { page, close } = await fresh()
    const lens = { gym: ["#open-gym", "#gym-log"], net: ["#open-net", "#net-log"], root: ["#root-cv", "#lens .root-wrap .paper"], account: ["#open-settings", "#settings table.keys, #settings .settings-section"] }
    for (const [name, [button, shown]] of Object.entries(lens)) {
      const rs = []
      for (let i = 0; i < Math.min(N, 20); i++) {
        rs.push(await act(page, `document.querySelector(${JSON.stringify(button)}).click()`, `!!document.querySelector(${JSON.stringify(shown)})`))
        await page.evaluate((f) => new Function(f)(), key("Escape"))
        await page.waitForTimeout(80)
      }
      report(`${name} lens open`, rs, await http(page))
    }
    await close()
  },

  // The score band and heat selects in the top bar.
  async filter() {
    const { page, close } = await fresh()
    for (const name of ["band", "heat"]) {
      const values = await page.$$eval(`select[name="${name}"] option`, (os) => os.map((o) => o.value))
      const rs = []
      for (let i = 0; i < Math.min(N, 100); i++) {
        const v = values[(i + 1) % values.length]
        rs.push(await act(page, `window.__j0 = window.__js.length; const s = document.querySelector('select[name="${name}"]'); s.value = ${JSON.stringify(v)}; s.dispatchEvent(new Event("input", { bubbles: true }))`, `window.__js.length > window.__j0`))
      }
      report(`filter ${name}`, rs, await http(page))
    }
    await close()
  },

  // CV lines in the battleplan: hide then restore, and an altered line saved.
  async cv() {
    const { page, close } = await fresh(`/?app=${bed.meta.job_ids[0]}&lens=battleplan`)
    await page.waitForSelector("#bp-paper .line.is-canonical")
    const hide = [], restore = [], alter = []
    let failed = 0
    for (let i = 0; i < Math.min(N, 40); i++) {
      // A line shows its actions once chosen by a click.
      const id = await page.$eval("#bp-paper .line.is-canonical", (l) => { l.click(); return l.id.replace("line-", "") })
      await page.waitForSelector(`#mask-hide-${id}`)
      await page.waitForTimeout(100)
      hide.push(await act(page, `document.getElementById("mask-hide-${id}").click()`, `document.getElementById("line-${id}")?.classList.contains("is-hidden")`))
      restore.push(await act(page, `document.getElementById("mask-restore-${id}").click()`, `document.getElementById("line-${id}")?.classList.contains("is-canonical")`))
      // A refused or still-settling restore leaves no Alter button this round.
      if (!(await page.evaluate((id) => { const b = document.getElementById(`mask-alter-${id}`); b?.click(); return !!b }, id))) { failed++; continue }
      await page.waitForSelector(`#alter-${id} textarea`)
      await page.fill(`#alter-${id} textarea`, `Altered line ${i} for the desk bench.`)
      await page.waitForTimeout(200)
      alter.push(await act(page, `document.querySelector("#alter-${id} button[type=submit]").click()`, `document.getElementById("line-${id}")?.classList.contains("is-altered")`))
      await page.evaluate((id) => document.getElementById(`mask-restore-${id}`)?.click(), id)
      await page.waitForTimeout(100)
    }
    const n = await http(page)
    report("cv line hide", hide, n)
    report("cv line restore", restore, 0)
    report("cv line alter save", alter, 0, failed ? `(${failed} rounds had no Alter button)` : "")
    await close()
  },

  // A HEAT override with a reason, once per job, from the focus panel.
  async heat() {
    const rs = []
    let n = 0
    for (let i = 0; rs.length < Math.min(N, 20) && i < bed.meta.job_ids.length; i++) {
      const { page, close } = await fresh(`/?app=${bed.meta.job_ids[(i * 37) % bed.meta.job_ids.length]}`)
      if (await page.$("#focus #heat-reason")) {
        await page.fill("#focus #heat-reason", `desk bench override ${i}`)
        await page.waitForTimeout(200)
        rs.push(await act(page, `document.querySelector("#focus #heat-override button[type=submit]").click()`, `!document.querySelector("#focus #heat-override") || !!document.querySelector("#focus #hold-error")`))
        n += await http(page)
      }
      await close()
    }
    report("heat override", rs, n)
  },

  // A net entry logged from its lens.
  async net() {
    const { page, close } = await fresh("/?lens=net")
    await page.waitForSelector("#net-log")
    const rs = []
    for (let i = 0; i < Math.min(N, 20); i++) {
      const title = `Desk bench entry ${Date.now()}-${i}`
      await page.fill('#net-log input[name="title"]', title)
      await page.waitForTimeout(200)
      rs.push(await act(page, `document.querySelector("#net-log button[type=submit]").click()`, `document.querySelector("#net .lane-recent")?.textContent.includes(${JSON.stringify(title)})`))
    }
    report("net log write", rs, await http(page))
    await close()
  },

  // Another tab's stage write, followed on this tab's board: from the
  // writer's input to the watcher's paint of the card, on one clock.
  async follow() {
    const id = bed.meta.job_ids[1]
    const writer = await fresh(`/?app=${id}&lens=battleplan`)
    const watcher = await fresh(`/?app=${id}`)
    await writer.page.waitForSelector("#battleplan button[id^=stage-]")
    // Two stages no rule refuses, alternating.
    const stages = await writer.page.$$eval("#stage-gated, #stage-freshness", (bs) => bs.map((b) => [b.id, b.querySelector(".label").textContent]))
    const rs = []
    for (let i = 0; i < Math.min(N, 40); i++) {
      const [stage, label] = stages[i % stages.length]
      if (await writer.page.evaluate((s) => document.getElementById(s).classList.contains("is-active"), stage)) continue
      const seen = watcher.page.evaluate(([id, label]) => new Promise((res) => {
        const began = performance.now()
        const check = () => {
          if (document.querySelector(`#card-${id} .stage-name`)?.textContent.startsWith(label)) {
            const ch = new MessageChannel()
            ch.port1.onmessage = () => res(performance.timeOrigin + performance.now())
            ch.port2.postMessage(0)
          } else if (performance.now() - began > 5000) res(NaN)
          else window.__raf(check)
        }
        window.__raf(check)
      }), [id, label])
      const t0 = await writer.page.evaluate((stage) => { document.getElementById(stage).click(); return performance.timeOrigin + window.__t0 }, stage)
      rs.push({ ms: (await seen) - t0, frames: 0, js: NaN })
      await writer.page.waitForTimeout(150)
    }
    report("other tab: stage", rs, (await http(writer.page)) + (await http(watcher.page)), "(writer input to watcher paint)")
    await writer.close()
    await watcher.close()
  },

  // A gym rep logged from the lens: it is on the list in the input's frame.
  async gym() {
    const { page, close } = await fresh()
    await page.click("#open-gym")
    await page.waitForSelector("#gym-log")
    const rs = []
    for (let i = 0; i < Math.min(N, 20); i++) {
      const title = `Desk bench rep ${Date.now()}-${i}`
      await page.fill("#gym-log input[name=title]", title)
      await page.waitForTimeout(200)
      rs.push(await act(page, `document.querySelector("#gym-log button[type=submit]").click()`, `document.querySelector("#gym .lane-recent")?.textContent.includes(${JSON.stringify(title)})`))
    }
    report("gym log write", rs, await http(page))
    await close()
  },
}

try {
  for (const [name, run] of Object.entries(scenarios)) {
    if (!want(name)) continue
    try { await run() } catch (e) { console.error(`scenario ${name} failed:`, e.message.split("\n")[0]) }
  }
} finally {
  await browser.close()
  bed.stop()
}
