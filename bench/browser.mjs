// Browser interaction benchmark and cross-tab check for the hireme shell,
// against a testbed started from bench/testbed.exs.
//
//   NODE_PATH=<dir holding playwright-core 1.63> CHROME=<chromium binary> \
//   taskset -c 16-31 node bench/browser.mjs --base http://localhost:PORT \
//     --meta BENCH_DIR/testbed.json --rev LABEL --out FILE.jsonl \
//     [--only load,search,...] [--scale 1] [--mint CMD] [--bundle app.js] [--verify]
//
// --mint is an executable that prints a fresh session cookie (bench/mint.exs);
// key writes need a sign-in under five minutes old, and a write refused
// with step_up is counted as refused, never timed. --bundle serves that
// build of the shell in place of the release's. --verify runs the cross-tab
// correctness checks instead of timing; it needs an account with no second
// factor, so give it a fresh testbed. Scenarios run in the order --only
// names them; webauthn enrols a factor, so it runs last.
//
// Every sample is one real input, timed in the page from the input event's
// timeStamp to the later of the paint after the last DOM change and the
// frame after the last request it caused, once nothing is in flight and
// nothing changed for a quiet window. Requests started inside the sample
// are recorded with their status, so fanout per operation is in the result.

import { createRequire } from "node:module"
import { readFileSync, appendFileSync } from "node:fs"
import { execFileSync } from "node:child_process"

const { chromium } = createRequire(import.meta.url)("playwright-core")
const CHROME = process.env.CHROME ?? "chromium"

// Injected before the page's own scripts. Records input timestamps, every
// fetch and websocket frame, and DOM mutations with the time of the first
// rendered frame after them, so an interaction can be timed from its input
// event to the paint of its last DOM change once the network is quiet.
function probe() {
  const P = {
    input: 0,
    inputs: [],
    inflight: 0,
    lastNet: 0,
    lastMut: 0,
    lastPaint: 0,
    lastDone: 0,
    netPaint: 0,
    reqs: [],
    ws: 0,
    wsTimes: [],
    sockets: [],
  }
  window.__perf = P

  for (const type of ["keydown", "click", "input", "submit", "wheel", "change", "scroll"]) {
    window.addEventListener(type, (e) => { P.input = e.timeStamp; P.inputs.push([type, e.timeStamp]) }, true)
  }

  // A request ends when its body has been read (json/text/arrayBuffer), or
  // at its headers when the body goes to a streaming consumer (the kernel).
  const realFetch = window.fetch.bind(window)
  window.fetch = (input, init) => {
    const url = typeof input === "string" ? input : input.url
    const method = (init && init.method) || "GET"
    const r = { url, method, start: performance.now(), headers: 0, end: 0, status: 0 }
    P.reqs.push(r)
    P.inflight++
    P.lastNet = r.start
    // The frame after a request's body is read follows whatever the page
    // drew from it, even a draw that changed nothing.
    const done = (status) => {
      if (r.end) return
      r.end = performance.now()
      r.status = status
      P.inflight--
      P.lastNet = r.end
      P.lastDone = r.end
      requestAnimationFrame(() => setTimeout(() => { P.netPaint = Math.max(P.netPaint, performance.now()) }, 0))
    }
    return realFetch(input, init).then(
      (res) => {
        r.headers = performance.now()
        P.lastNet = r.headers
        if (url.endsWith(".wasm")) { done(res.status); return res }
        for (const name of ["json", "text", "arrayBuffer"]) {
          const orig = res[name].bind(res)
          res[name] = () => orig().finally(() => done(res.status))
        }
        return res
      },
      (err) => { done(-1); throw err },
    )
  }

  const RealWS = window.WebSocket
  window.WebSocket = class extends RealWS {
    constructor(...args) {
      super(...args)
      P.sockets.push(this)
      this.addEventListener("message", () => { P.ws++; P.lastNet = performance.now(); P.wsTimes.push(P.lastNet) })
    }
  }

  let paintQueued = false
  const onMut = () => {
    P.lastMut = performance.now()
    if (paintQueued) return
    paintQueued = true
    requestAnimationFrame(() => setTimeout(() => {
      paintQueued = false
      P.lastPaint = performance.now()
      if (P.lastMut > P.lastPaint) onMut()
    }, 0))
  }
  const mo = new MutationObserver(onMut)
  const observe = () => mo.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true })
  if (document.documentElement) observe()
  else document.addEventListener("readystatechange", observe, { once: true })

  // Settled: no request in flight, nothing on the network or in the DOM for
  // `quiet` ms, and the last mutation painted. Resolves with the later of that
  // paint and the frame after the last request.
  // With `since`, a DOM change after that time is required first.
  // An input that changes nothing within `noop` ms resolves NaN.
  P.settle = (quiet = 40, timeout = 20000, since = -1, noop = 2000) => new Promise((resolve, reject) => {
    const began = performance.now()
    const tick = () => {
      const now = performance.now()
      const last = Math.max(P.lastNet, P.lastMut, since)
      if (P.lastMut > since && P.inflight === 0 && now - last >= quiet && P.lastPaint >= P.lastMut && P.netPaint >= P.lastDone) return resolve(Math.max(P.lastPaint, P.netPaint))
      if (since >= 0 && P.lastMut <= since && P.lastNet <= since && P.inflight === 0 && now - since > noop) return resolve(NaN)
      if (now - began > timeout) return reject(new Error(`unsettled: inflight=${P.inflight}`))
      setTimeout(tick, 2)
    }
    tick()
  })
}

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : "1"])
  return acc
}, []))
const base = args.base
const rev = args.rev ?? "unknown"
const out = args.out
const scale = Number(args.scale ?? "1")
const only = args.only ? new Set(args.only.split(",")) : null
const meta = () => JSON.parse(readFileSync(args.meta, "utf8"))

const pct = (s, q) => s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))]
const r3 = (x) => Math.round(x * 1000) / 1000

function emit(page, interaction, samples, extra = {}) {
  // A sample whose requests were refused (4xx/5xx) is not the operation; it is counted, not timed.
  const refused = samples.filter((s) => s.reqs.some((r) => r[4] >= 400)).length
  const ms = samples.filter((s) => !s.reqs.some((r) => r[4] >= 400)).map((s) => s.ms).filter((x) => Number.isFinite(x))
  const noops = samples.filter((s) => s.noop).length
  const sorted = [...ms].sort((a, b) => a - b)
  const fanout = {}
  for (const s of samples) for (const [m, u] of s.reqs) {
    const key = `${m} ${u.replace(/\?.*$/, "").replace(/\/\d+(?=\/|$)/g, "/:id")}`
    fanout[key] = (fanout[key] ?? 0) + 1
  }
  for (const k of Object.keys(fanout)) fanout[k] = r3(fanout[k] / samples.length)
  const row = {
    page, interaction, rev, n: sorted.length,
    mean: r3(ms.reduce((a, b) => a + b, 0) / Math.max(ms.length, 1)),
    p0_1: r3(pct(sorted, 0.001)), p1: r3(pct(sorted, 0.01)), p50: r3(pct(sorted, 0.5)),
    p99: r3(pct(sorted, 0.99)), p99_9: r3(pct(sorted, 0.999)),
    failed: samples.length - ms.length - noops - refused, noops, refused,
    requests_per_op: r3(samples.reduce((a, s) => a + s.reqs.length, 0) / samples.length),
    signals_per_op: r3(samples.reduce((a, s) => a + s.ws, 0) / samples.length),
    fanout, fixture: "canonical-1000", profile: "loopback", harness: "browser", bundle: args.bundle ? "intercepted" : "release",
    samples: ms.map(r3), trace: samples.slice(0, 5).map((s) => s.reqs), ...extra,
  }
  if (out) appendFileSync(out, JSON.stringify(row) + "\n")
  console.log(`${page.padEnd(11)} ${interaction.padEnd(22)} n=${String(row.n).padStart(4)} p50=${row.p50.toFixed(2).padStart(8)} p99=${row.p99.toFixed(2).padStart(8)} req/op=${row.requests_per_op} ${JSON.stringify(fanout)}`)
}

// One sample: run `act`, then wait in the page for the settle and time it.
let failures = 0
const miss = (e) => { if (failures++ < 3) console.error("sample failed:", e.message.split("\n")[0]); return { ms: NaN, reqs: [], ws: 0 } }

// With ref "fetch", the sample starts when the first request matching `match` starts.
async function sample(page, act, opts = {}) {
  return measure(page, act, opts).catch(miss)
}

async function measure(page, act, { quiet = 40, ref = "input", match = "", timeout = 30000 } = {}) {
  const before = await page.evaluate(() => ({ reqs: __perf.reqs.length, inputs: __perf.inputs.length, ws: __perf.ws }))
  await act()
  return page.evaluate(async ([b, quiet, ref, match, timeout]) => {
    const P = __perf
    const began = performance.now()
    const first = () => P.reqs.slice(b.reqs).find((r) => r.url.includes(match))
    while (match !== "" && !first()) {
      if (performance.now() - began > timeout) throw new Error(`no request matching ${match}`)
      await new Promise((r) => setTimeout(r, 2))
    }
    const inputs = P.inputs.slice(b.inputs)
    let t0 = ref === "fetch" ? first().start : inputs.length ? inputs[0][1] : NaN
    const paint = await P.settle(quiet, timeout, t0)
    const reqs = P.reqs.slice(b.reqs)
    return {
      noop: Number.isNaN(paint),
      ms: paint - t0,
      reqs: reqs.map((r) => [r.method, r.url.replace(location.origin, ""), Math.round(r.start - t0), Math.round(r.end - t0), r.status]),
      ws: P.ws - b.ws,
    }
  }, [before, quiet, ref, match, timeout])
}

async function openDesk(context, path = "/") {
  const page = await context.newPage()
  page.on("dialog", (d) => d.accept())
  page.on("pageerror", (e) => console.error("pageerror", e.message))
  await page.goto(base + path)
  await page.waitForSelector("#plane .card, #lens .lane-wrap, #lens .root-wrap, #lens .battleplan-wrap", { timeout: 30000 })
  await page.evaluate(() => __perf.settle(100))
  return page
}

const N = (n) => Math.max(1, Math.round(n * scale))

// Another tab's change, followed here: timed from the first signal frame
// this page receives after `act` to the paint of its last DOM change.
async function follow(page, act, opts = {}) {
  return followed(page, act, opts).catch(miss)
}

async function followed(page, act, { signals = 1, quiet = 60, timeout = 5000 } = {}) {
  const before = await page.evaluate(() => ({ reqs: __perf.reqs.length, ws: __perf.ws }))
  const acted = await act()
  if (typeof signals === "function") signals = signals(acted)
  return page.evaluate(async ([b, signals, quiet, timeout]) => {
    const P = __perf
    const began = performance.now()
    while (P.ws - b.ws < signals) {
      if (performance.now() - began > timeout) throw new Error("no signal")
      await new Promise((r) => setTimeout(r, 2))
    }
    const t0 = P.wsTimes[b.ws]
    const paint = await P.settle(quiet, timeout, t0)
    const reqs = P.reqs.slice(b.reqs)
    return { ms: paint - t0, reqs: reqs.map((r) => [r.method, r.url.replace(location.origin, ""), Math.round(r.start - t0), Math.round(r.end - t0), r.status]), ws: P.ws - b.ws }
  }, [before, signals, quiet, timeout])
}

const scenarios = {
  // Page load to a settled board: HTML, bundle, kernel, packet, and every follow-up read.
  async load(context) {
    const samples = []
    for (let i = 0; i < N(150); i++) {
      const page = await context.newPage()
      await page.goto(base + "/")
      await page.waitForSelector("#plane .card")
      const s = await page.evaluate(async () => {
        const paint = await __perf.settle(100)
        return { ms: paint, reqs: __perf.reqs.map((r) => [r.method, r.url.replace(location.origin, ""), Math.round(r.start), Math.round(r.end)]), ws: __perf.ws }
      })
      samples.push(s)
      await page.close()
    }
    emit("desk", "page load", samples)
  },

  // One keystroke in the search box, then one clear.
  async search(context) {
    const page = await openDesk(context)
    const words = ["systems", "company 4", "engineer 9", "jobapp1", "cv77", "remote"]
    const samples = [], clears = []
    let i = 0
    while (samples.length < N(1000)) {
      const w = words[i++ % words.length]
      await page.click("#q")
      for (const ch of w) {
        if (samples.length >= N(1000)) break
        samples.push(await sample(page, () => page.keyboard.press(ch === " " ? "Space" : ch), { quiet: 20 }))
      }
      clears.push(await sample(page, async () => { await page.keyboard.press("Control+A"); await page.keyboard.press("Backspace") }, { quiet: 20 }))
    }
    emit("desk", "search keystroke", samples)
    emit("desk", "search clear", clears)
    await page.close()
  },

  // hjkl over the grid: the highlight moves and the focus panel loads the card.
  async move(context) {
    const page = await openDesk(context)
    await page.click("#grid", { position: { x: 5, y: 5 } }).catch(() => {})
    await page.evaluate(() => document.activeElement && document.activeElement.blur())
    // A square from the first card: every press moves, none meets an edge.
    const pattern = ["l", "j", "h", "k"]
    const samples = []
    for (let i = 0; i < N(1000); i++) {
      samples.push(await sample(page, () => page.keyboard.press(pattern[i % pattern.length]), { quiet: 30 }))
    }
    emit("desk", "hjkl move", samples)
    await page.close()
  },

  // Click a different visible card.
  async click(context) {
    const page = await openDesk(context)
    const samples = []
    for (let i = 0; i < N(500); i++) {
      const id = await page.evaluate((i) => {
        const cards = [...document.querySelectorAll("#plane .card:not(.is-active)")].filter((c) => {
          const r = c.getBoundingClientRect(), g = document.querySelector("#grid").getBoundingClientRect()
          return r.top >= g.top && r.bottom <= g.bottom
        })
        return cards.length ? cards[i % cards.length].id : null
      }, i)
      if (!id) break
      samples.push(await sample(page, () => page.click(`#${id}`), { quiet: 30 }))
    }
    emit("desk", "click card", samples)
    await page.close()
  },

  // Scroll the grid by 400 px, down to the end and back, timed from the scroll event.
  async scroll(context) {
    const page = await openDesk(context)
    const samples = []
    let y = 0, dir = 1
    for (let i = 0; i < N(500); i++) {
      const max = await page.evaluate(() => { const g = document.querySelector("#grid"); return g.scrollHeight - g.clientHeight })
      if (y + 400 * dir > max || y + 400 * dir < 0) dir = -dir
      y += 400 * dir
      samples.push(await sample(page, () => page.evaluate((y) => { document.querySelector("#grid").scrollTop = y }, y), { quiet: 30, timeout: 5000 }))
    }
    emit("desk", "scroll 400px", samples)
    await page.close()
  },

  // Filter selects in the top bar.
  async filter(context) {
    const page = await openDesk(context)
    const bands = await page.$$eval('select[name="band"] option', (os) => os.map((o) => o.value))
    const heats = await page.$$eval('select[name="heat"] option', (os) => os.map((o) => o.value))
    const b = [], h = []
    for (let i = 0; i < N(300); i++) b.push(await sample(page, () => page.selectOption('select[name="band"]', bands[(i + 1) % bands.length]), { quiet: 20 }))
    await page.selectOption('select[name="band"]', "all")
    await page.evaluate(() => __perf.settle(40))
    for (let i = 0; i < N(300); i++) h.push(await sample(page, () => page.selectOption('select[name="heat"]', heats[(i + 1) % heats.length]), { quiet: 20 }))
    emit("desk", "filter band", b)
    emit("desk", "filter heat", h)
    await page.close()
  },

  // Enter opens the battleplan; Escape steps back.
  async battleplan(context) {
    const page = await openDesk(context)
    await page.evaluate(() => document.activeElement && document.activeElement.blur())
    const open = [], back = []
    for (let i = 0; i < N(300); i++) {
      open.push(await sample(page, () => page.keyboard.press("Enter"), { quiet: 20 }))
      back.push(await sample(page, () => page.keyboard.press("Escape"), { quiet: 20 }))
    }
    emit("battleplan", "open (enter)", open)
    emit("battleplan", "back (esc)", back)
    await page.close()
  },

  // Stage writes on the selected card, alternating between two free stages.
  async stage(context) {
    const page = await openDesk(context, "/?lens=battleplan")
    await page.waitForSelector("#battleplan")
    await page.evaluate(() => __perf.settle(100))
    const samples = []
    for (let i = 0; i < N(300); i++) {
      const key = i % 2 === 0 ? "gated" : "freshness"
      samples.push(await sample(page, () => page.click(`#stage-${key}`), { quiet: 60 }))
    }
    emit("battleplan", "set stage", samples)
    await page.close()
  },

  // The same autosaves timed from the input event, debounce included.
  async autosave_input(context) {
    const page = await openDesk(context, "/?lens=battleplan")
    await page.waitForSelector("#stage-note")
    await page.evaluate(() => __perf.settle(100))
    const note = []
    for (let i = 0; i < N(100); i++) note.push(await sample(page, () => page.fill("#stage-note", `typed note ${i}`), { quiet: 80, match: "/note" }))
    emit("battleplan", "note autosave (from input, incl. 500 ms debounce)", note)
    await page.keyboard.press("Escape")
    await page.keyboard.press("Escape")
    await page.waitForSelector("#next_action")
    await page.evaluate(() => __perf.settle(60))
    const next = []
    for (let i = 0; i < N(100); i++) next.push(await sample(page, () => page.fill("#next_action", `typed follow up ${i}`), { quiet: 80, match: "/next" }))
    emit("desk", "next action autosave (from input, incl. 400 ms debounce)", next)
    await page.close()
  },

  // Page load under Chromium's network emulation: 80 ms added to every HTTP
  // request (WebSocket frames are not delayed). Emulated, not a live deployment.
  async load_wan(context) {
    const samples = []
    for (let i = 0; i < N(50); i++) {
      const page = await context.newPage()
      const cdp = await context.newCDPSession(page)
      await cdp.send("Network.enable")
      await cdp.send("Network.emulateNetworkConditions", { offline: false, latency: 80, downloadThroughput: -1, uploadThroughput: -1 })
      await page.goto(base + "/")
      await page.waitForSelector("#plane .card")
      samples.push(await page.evaluate(async () => {
        const paint = await __perf.settle(250)
        return { ms: paint, reqs: __perf.reqs.map((r) => [r.method, r.url.replace(location.origin, ""), Math.round(r.start), Math.round(r.end), r.status]), ws: __perf.ws }
      }))
      await page.close()
    }
    emit("desk", "page load (emulated 80 ms RTT)", samples, { profile: "emulated-rtt-80ms" })
  },

  // Hide a CV line, then restore it.
  async mask(context) {
    const page = await openDesk(context, "/?lens=battleplan")
    await page.waitForSelector("#battleplan .line")
    await page.evaluate(() => __perf.settle(100))
    const hide = [], restore = [], emph = []
    for (let i = 0; i < N(150); i++) {
      const id = await page.$eval("#battleplan [id^=mask-hide-]", (b) => b.id.replace("mask-hide-", ""))
      hide.push(await sample(page, () => page.click(`#mask-hide-${id}`), { quiet: 60 }))
      restore.push(await sample(page, () => page.click(`#mask-restore-${id}`), { quiet: 60 }))
      emph.push(await sample(page, () => page.click(`#mask-emphasize-${id}`), { quiet: 60 }))
      await sample(page, () => page.click(`#mask-restore-${id}`), { quiet: 60 })
    }
    emit("battleplan", "mask hide", hide)
    emit("battleplan", "mask restore", restore)
    emit("battleplan", "mask emphasize", emph)
    await page.close()
  },

  // Alter a line through its form.
  async alter(context) {
    const page = await openDesk(context, "/?lens=battleplan")
    await page.waitForSelector("#battleplan .line")
    await page.evaluate(() => __perf.settle(100))
    const open = [], save = []
    for (let i = 0; i < N(150); i++) {
      const id = await page.$eval("#battleplan [id^=mask-alter-]", (b) => b.id.replace("mask-alter-", ""))
      open.push(await sample(page, () => page.click(`#mask-alter-${id}`), { quiet: 20 }))
      await page.fill(`#alter-${id} textarea`, `Altered line ${i} for the benchmark.`)
      save.push(await sample(page, () => page.click(`#alter-${id} button[type=submit]`), { quiet: 60 }))
      await sample(page, () => page.click(`#mask-restore-${id}`), { quiet: 60 })
    }
    emit("battleplan", "alter open", open)
    emit("battleplan", "alter save", save)
    await page.close()
  },

  // Debounced writes: next action (400 ms) and stage note (500 ms), timed from the POST.
  async autosave(context) {
    const page = await openDesk(context, "/?lens=battleplan")
    await page.waitForSelector("#stage-note")
    await page.evaluate(() => __perf.settle(100))
    const note = []
    for (let i = 0; i < N(150); i++) {
      note.push(await sample(page, () => page.fill("#stage-note", `note ${i}`), { quiet: 80, ref: "fetch", match: "/note" }))
    }
    emit("battleplan", "note autosave", note)
    await page.keyboard.press("Escape")
    await page.keyboard.press("Escape")
    await page.waitForSelector("#next_action")
    await page.evaluate(() => __perf.settle(60))
    const next = []
    for (let i = 0; i < N(150); i++) {
      next.push(await sample(page, () => page.fill("#next_action", `follow up ${i}`), { quiet: 80, ref: "fetch", match: "/next" }))
    }
    emit("desk", "next action autosave", next)
    await page.close()
  },

  // Heat override: once per job, opening successive jobs by address.
  async heat(context) {
    const page = await context.newPage()
    page.on("pageerror", (e) => console.error("pageerror", e.message))
    const ids = meta().job_ids
    const samples = []
    for (let i = 0; samples.length < N(60) && i < ids.length; i++) {
      await page.goto(`${base}/?app=${ids[(i * 37) % ids.length]}`)
      await page.waitForSelector("#focus h2")
      await page.evaluate(() => __perf.settle(60))
      if (!(await page.$("#heat-reason"))) continue
      await page.fill("#heat-reason", `benchmark override ${i}`)
      samples.push(await sample(page, () => page.click("#heat-override button[type=submit]"), { quiet: 60 }))
    }
    emit("desk", "heat override", samples)
    await page.close()
  },

  // Lenses: root CV (a read), gym and net (resident), and their writes.
  async lenses(context) {
    const page = await openDesk(context)
    const root = [], gym = [], net = [], back = []
    for (let i = 0; i < N(200); i++) {
      root.push(await sample(page, () => page.click("#root-cv"), { quiet: 30 }))
      back.push(await sample(page, () => page.keyboard.press("Escape"), { quiet: 20 }))
      gym.push(await sample(page, () => page.click("#open-gym"), { quiet: 30 }))
      await sample(page, () => page.keyboard.press("Escape"), { quiet: 20 })
      net.push(await sample(page, () => page.click("#open-net"), { quiet: 30 }))
      await sample(page, () => page.keyboard.press("Escape"), { quiet: 20 })
    }
    emit("root", "open root cv", root)
    emit("desk", "back to board", back)
    emit("gym", "open gym", gym)
    emit("net", "open net", net)
    await page.close()
  },

  async gym(context) {
    const page = await openDesk(context, "/?lens=gym")
    await page.waitForSelector("#gym")
    await page.evaluate(() => __perf.settle(100))
    const log = [], target = []
    for (let i = 0; i < N(150); i++) {
      await page.fill('#gym-log input[name="title"]', `Bench problem ${i}`)
      log.push(await sample(page, () => page.click("#gym-log button[type=submit]"), { quiet: 40 }))
      await page.fill("#gym-target-n", String(3 + (i % 5)))
      target.push(await sample(page, () => page.click("#gym-target button[type=submit]"), { quiet: 40 }))
    }
    emit("gym", "log rep", log)
    emit("gym", "set target", target)
    await page.close()
  },

  async net(context) {
    const page = await openDesk(context, "/?lens=net")
    await page.waitForSelector("#net")
    await page.evaluate(() => __perf.settle(100))
    const log = [], lane = []
    for (let i = 0; i < N(150); i++) {
      await page.fill('#net-log input[name="title"]', `Bench entry ${i}`)
      log.push(await sample(page, () => page.click("#net-log button[type=submit]"), { quiet: 40 }))
      await page.fill("#net-lane-url", `https://observer.example.test/run/${i}`)
      lane.push(await sample(page, () => page.click("#net-lane button[type=submit]"), { quiet: 40 }))
    }
    emit("net", "log entry", log)
    emit("net", "set lane", lane)
    await page.close()
  },

  // A second tab writes; the first follows the feed: one stage change, one
  // mask change, and a burst of five stage changes.
  async feed(context) {
    const watcher = await openDesk(context)
    const writer = await openDesk(context, "/?lens=battleplan")
    await writer.waitForSelector("#battleplan .line")
    await writer.evaluate(() => __perf.settle(100))
    await watcher.evaluate(() => __perf.settle(100))
    const stage = [], mask = [], burst = []
    for (let i = 0; i < N(100); i++) {
      const key = i % 2 === 0 ? "gated" : "freshness"
      stage.push(await follow(watcher, () => writer.click(`#stage-${key}`)))
      await writer.evaluate(() => __perf.settle(60))
    }
    for (let i = 0; i < N(50); i++) {
      const id = await writer.$eval("#battleplan [id^=mask-hide-]", (b) => b.id.replace("mask-hide-", ""))
      mask.push(await follow(watcher, () => writer.click(`#mask-hide-${id}`)))
      await writer.evaluate(() => __perf.settle(60))
      mask.push(await follow(watcher, () => writer.click(`#mask-restore-${id}`)))
      await writer.evaluate(() => __perf.settle(60))
    }
    for (let i = 0; i < N(30); i++) {
      // Five clicks without waiting; the watcher expects one signal per write that landed.
      burst.push(await follow(watcher, async () => {
        const from = await writer.evaluate(() => __perf.reqs.length)
        for (let k = 0; k < 5; k++) await writer.click(`#stage-${(i + k) % 2 === 0 ? "gated" : "freshness"}`, { noWaitAfter: true })
        await writer.evaluate(() => __perf.settle(60))
        return writer.evaluate((from) => __perf.reqs.slice(from).filter((r) => r.method === "POST" && r.status === 200).length, from)
      }, { signals: (landed) => landed, quiet: 100 }))
      await writer.evaluate(() => __perf.settle(100))
      await watcher.evaluate(() => __perf.settle(100))
    }
    emit("feed", "other tab: stage", stage)
    emit("feed", "other tab: mask", mask)
    emit("feed", "other tab: 5 stages", burst)
    await watcher.close()
    await writer.close()
  },

  // Passkeys through a CDP virtual authenticator (no physical key): enrolling
  // one from the Account page, then the step-up ceremony's two round trips
  // and the signature, called from the page. The account's factor throttle
  // admits 10 assertions per 15 minutes, so step-up has n=10.
  async webauthn(context) {
    await freshSession(context)
    const page = await openDesk(context)
    const cdp = await context.newCDPSession(page)
    await cdp.send("WebAuthn.enable")
    let auth = null
    const replace = async () => {
      if (auth) await cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId: auth })
      auth = (await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } })).authenticatorId
    }
    await page.click("#open-settings")
    await page.waitForSelector("#settings [data-action=enroll-webauthn]")
    await page.evaluate(() => __perf.settle(60))
    const enroll = []
    for (let i = 0; i < N(30); i++) {
      await replace()
      enroll.push(await sample(page, () => page.click("#settings [data-action=enroll-webauthn]"), { quiet: 60 }))
      if (await page.$("#settings [data-action=cancel-enroll]")) await sample(page, () => page.click("#settings [data-action=cancel-enroll]"), { quiet: 20 })
    }
    emit("account", "enroll passkey (virtual authenticator)", enroll, { authenticator: "CDP virtual, ctap2 internal, UV" })
    const step = []
    for (let i = 0; i < 10; i++) {
      step.push(await page.evaluate(async () => {
        const csrf = document.querySelector('meta[name="csrf-token"]').content
        const post = (url, body) => fetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json", "x-csrf-token": csrf }, body: JSON.stringify(body) })
        const dec = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)).buffer
        const enc = (b) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
        const t0 = performance.now()
        const pk = (await (await post("/api/account/step-up/webauthn", {})).json()).publicKey
        const cred = await navigator.credentials.get({ publicKey: { challenge: dec(pk.challenge), rpId: pk.rpId, timeout: pk.timeout, userVerification: pk.userVerification, allowCredentials: pk.allowCredentials.map((d) => ({ type: "public-key", id: dec(d.id), transports: d.transports })) } })
        const r = cred.response
        const res = await post("/api/account/step-up/webauthn/confirm", { rawId: enc(cred.rawId), authenticatorData: enc(r.authenticatorData), signature: enc(r.signature), clientDataJSON: enc(r.clientDataJSON) })
        await res.json()
        if (!res.ok) throw new Error(`step-up ${res.status}`)
        return { ms: performance.now() - t0, reqs: [["POST", "/api/account/step-up/webauthn"], ["POST", "/api/account/step-up/webauthn/confirm"]], ws: 0 }
      }).catch(miss))
    }
    emit("account", "step-up passkey ceremony (virtual authenticator)", step, { authenticator: "CDP virtual, ctap2 internal, UV", note: "API + navigator.credentials.get, no UI; throttle caps n at 10 per 15 min" })
    await page.close()
  },

  // The Account page: open it, then mint, rename, and revoke keys. Key
  // writes need a sign-in under five minutes old, so a fresh session is minted.
  async account(context) {
    await freshSession(context)
    const page = await openDesk(context)
    const open = [], back = []
    for (let i = 0; i < N(200); i++) {
      open.push(await sample(page, () => page.click("#open-settings"), { quiet: 30 }))
      back.push(await sample(page, () => page.keyboard.press("Escape"), { quiet: 20 }))
    }
    emit("account", "open account", open)
    await page.click("#open-settings")
    await page.waitForSelector("#create-key")
    await page.evaluate(() => __perf.settle(60))
    const create = [], rename = [], revoke = []
    for (let i = 0; i < N(100); i++) {
      await page.fill('#create-key input[name="name"]', `bench-key-${i}`)
      create.push(await sample(page, () => page.click("#create-key button[type=submit]"), { quiet: 40 }))
      await sample(page, () => page.click('[data-action="dismiss-secret"]'), { quiet: 20 })
      const id = await page.$eval("table.keys tr[id^=key-]:not(.is-revoked)", (r) => r.id.replace("key-", ""))
      await sample(page, () => page.click(`#key-${id} [data-action="rename"]`), { quiet: 20 })
      await page.fill(`#key-${id} input[name="name"]`, `bench-key-${i}-renamed`)
      rename.push(await sample(page, () => page.click(`#key-${id} button[type=submit]`), { quiet: 40 }))
      revoke.push(await sample(page, () => page.click(`#key-${id} [data-action="revoke-key"]`), { quiet: 40 }))
    }
    emit("account", "create api key", create)
    emit("account", "rename api key", rename)
    emit("account", "revoke api key", revoke)
    await page.close()
  },
}

// A new session row and its cookie, minted by a second VM against the bed's database.
async function freshSession(context) {
  if (!args.mint) return
  const cookie = execFileSync(args.mint, { encoding: "utf8" }).trim().split("\n").pop()
  await context.addCookies([{ name: "__Host-hireme", value: cookie, domain: "localhost", path: "/", secure: true, httpOnly: true, sameSite: "Lax" }])
}


// ---- cross-tab correctness ----

// After concurrent writes from two tabs settle, both tabs show what the server holds.
async function verify(context, rounds) {
  const open = async (path) => {
    const p = await context.newPage()
    p.on("pageerror", (e) => console.error("pageerror", e.message))
    await p.goto(base + path)
    await p.waitForSelector("#plane .card, #battleplan")
    await p.evaluate(() => __perf.settle(100))
    return p
  }
  const settle = (p) => p.evaluate(() => __perf.settle(150, 20000))
  // What the server holds, read through the page's own session.
  const server = (p, id) => p.evaluate(async (id) => (await (await fetch(`/api/focus/${id}`, { headers: { accept: "application/json" } })).json()).job, id)

  let failures = 0
  const check = (what, ok, detail) => { if (!ok) { failures++; console.log("FAIL", what, detail) } }

  // 1. Same job, two tabs, both writing its stage at once.
  {
    const a = await open("/?lens=battleplan")
    const b = await open("/?lens=battleplan")
    const id = await a.evaluate(() => Number(new URLSearchParams(location.search).get("app")))
    const stages = ["gated", "freshness", "discovered"]
    for (let i = 0; i < rounds; i++) {
      const sa = stages[i % stages.length], sb = stages[(i + 1) % stages.length]
      await Promise.all([a.click(`#stage-${sa}`, { noWaitAfter: true }), b.click(`#stage-${sb}`, { noWaitAfter: true })])
      await Promise.all([settle(a), settle(b)])
      await Promise.all([settle(a), settle(b)])
      const truth = await server(a, id)
      for (const [name, p] of [["A", a], ["B", b]]) {
        const shown = await p.evaluate(() => document.querySelector("#battleplan .stage.is-active .label")?.textContent?.trim())
        check(`same-job round ${i} tab ${name} battleplan stage`, shown === truth.stage_label, { shown, truth: truth.stage_label })
      }
    }
    // Back on the board, each tab's card for the job shows the server's stage.
    for (const p of [a, b]) { await p.keyboard.press("Escape"); await settle(p) }
    const truth = await server(a, id)
    for (const [name, p] of [["A", a], ["B", b]]) {
      const card = await p.evaluate((id) => document.querySelector(`#card-${id} .stage-name`)?.textContent?.trim(), id)
      check(`same-job board card tab ${name}`, card?.startsWith(truth.stage_label), { card, truth: truth.stage_label })
    }
    await a.close(); await b.close()
  }

  // 2. Shared lineage: a CV change on one job shows on a sibling's card (same
  // employer) in the other tab, and that tab's focus of the changed job updates.
  {
    const watcher = await open("/")
    const writer = await open("/?lens=battleplan")
    const id = await writer.evaluate(() => Number(new URLSearchParams(location.search).get("app")))
    const company = (await server(writer, id)).company
    const sibling = await watcher.evaluate(async ([company, id]) => {
      const cards = [...document.querySelectorAll("#plane .card")].map((c) => [Number(c.dataset.id), c.querySelector("h2")?.textContent])
      return cards.find(([cid, co]) => co === company && cid !== id)?.[0] ?? null
    }, [company, id])
    for (let i = 0; i < Math.min(rounds, 10); i++) {
      const line = await writer.$eval("#battleplan [id^=mask-hide-]", (b) => b.id.replace("mask-hide-", ""))
      await writer.click(`#mask-hide-${line}`)
      await Promise.all([settle(writer), settle(watcher)])
      for (const job of [id, sibling].filter((x) => x !== null)) {
        const truth = await server(watcher, job)
        const glance = await watcher.evaluate((job) => document.querySelector(`#card-${job} .glance span:last-child`)?.textContent?.trim(), job)
        if (glance !== undefined) check(`lineage round ${i} card ${job} keyword glance`, glance === `${truth.keyword_hits}/${truth.keyword_total}`, { glance, truth: `${truth.keyword_hits}/${truth.keyword_total}` })
      }
      await writer.click(`#mask-restore-${line}`)
      await Promise.all([settle(writer), settle(watcher)])
    }
    // Select the written job in the watcher, then write it from the other tab.
    await watcher.click(`#card-${id}`)
    await settle(watcher)
    const line = await writer.$eval("#battleplan [id^=mask-hide-]", (b) => b.id.replace("mask-hide-", ""))
    await writer.click(`#mask-hide-${line}`)
    await Promise.all([settle(writer), settle(watcher)])
    const truth = await server(watcher, id)
    const label = await watcher.evaluate(() => [...document.querySelectorAll("#focus .section-label")].map((e) => e.textContent).find((t) => t.startsWith("Mask")))
    check("lineage watcher focus mask counts", label?.includes(`${truth.mask_hidden} hidden`), { label, truth: truth.mask_hidden })
    await writer.click(`#mask-restore-${line}`)
    await Promise.all([settle(writer), settle(watcher)])
    console.log(`sibling job ${sibling ?? "none on screen"} for company ${company}`)
    await watcher.close(); await writer.close()
  }
  return failures
}

const browser = await chromium.launch({
  executablePath: CHROME,
  args: ["--disable-gpu-vsync", "--disable-frame-rate-limit", "--disable-background-timer-throttling", "--disable-renderer-backgrounding"],
})
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } })
await context.addInitScript(probe)
// --bundle FILE serves that build of the shell in place of the release's, so a
// client-only change is measured against the same server.
if (args.bundle) {
  const js = readFileSync(args.bundle)
  await context.route(/\/assets\/js\/app-[0-9a-f]+\.js/, (route) => route.fulfill({ status: 200, contentType: "text/javascript", body: js }))
}
await context.addCookies([{ name: "__Host-hireme", value: meta().cookie, domain: "localhost", path: "/", secure: true, httpOnly: true, sameSite: "Lax" }])

if (args.verify) {
  const failures = await verify(context, Number(args.rounds ?? "20"))
  console.log(failures === 0 ? "verify: all checks passed" : `verify: ${failures} checks failed`)
  await browser.close()
  process.exit(failures === 0 ? 0 : 1)
}

// Scenarios run in the order --only names them.
for (const name of only ? [...only] : Object.keys(scenarios)) {
  const run = scenarios[name]
  if (!run) { console.error(`no scenario ${name}`); continue }
  const t = Date.now()
  try { await run(context) } catch (e) { console.error(`scenario ${name} failed:`, e.message) }
  console.log(`  (${name}: ${((Date.now() - t) / 1000).toFixed(1)}s)`)
}
await browser.close()
