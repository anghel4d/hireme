// Cutover acceptance 4, the browser half (docs/rebuild.md, 'Cutover
// acceptance'): with the desk and world lenses open, a real hireme-mcp on a
// key minted in the account lens leases 16, moves one application to
// draft_ready and adds a corporation with a cited headcount and an office;
// the browser shows all three without a reload; then a reload from the
// snapshot paints the desk restoring before its cards, and a kernel that
// traps never leaves it restoring. Run by test/e2e/run.sh,
// which boots the node; this script needs BASE, HIREME_MCP, CHROMIUM, OUT.

import { chromium } from "playwright";

const { BASE, HIREME_MCP, CHROMIUM, OUT } = process.env;
const STEP_MS = 20_000;
let failed = 0;
const errors = [];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Polls `probe` until it returns a truthy value or the step's time runs out. */
async function until(probe, what, ms = STEP_MS) {
  const end = Date.now() + ms;
  let last;
  while (Date.now() < end) {
    last = await probe().catch((e) => String(e));
    if (last && last !== "false") return last;
    await sleep(200);
  }
  throw new Error(`${what} (last: ${String(last).slice(0, 200)})`);
}

async function step(name, pages, fn) {
  try {
    const detail = await fn();
    console.log(`PASS ${name}${detail ? `: ${detail}` : ""}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${name}: ${String(e.message ?? e).slice(0, 400)}`);
    for (const [label, p] of Object.entries(pages)) {
      await p.screenshot({ path: `${OUT}/${name.replace(/\W+/g, "_")}-${label}.png`, fullPage: true }).catch(() => {})
    }
  }
}

/** An MCP client over stdio: `call(tool, args)` answers the tool's text. */
function mcp(key) {
  const p = Bun.spawn([HIREME_MCP], { env: { ...process.env, HIREME_KEY: key, HIREME_URL: BASE }, stdin: "pipe", stdout: "pipe", stderr: "ignore" });
  const waiting = new Map();
  let buf = "", next = 1;
  const write = (line) => { p.stdin.write(line); p.stdin.flush() };
  (async () => {
    for await (const d of p.stdout.pipeThrough(new TextDecoderStream())) {
      buf += d;
      for (let i; (i = buf.indexOf("\n")) >= 0; ) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        try {
          const j = JSON.parse(line);
          if (j.id && waiting.has(j.id)) { waiting.get(j.id)(j); waiting.delete(j.id) }
        } catch {}
      }
    }
  })();
  const ask = (method, params) => new Promise((resolve, reject) => {
    const id = next++;
    const timer = setTimeout(() => reject(new Error(`no MCP answer to ${method}`)), STEP_MS);
    waiting.set(id, (j) => { clearTimeout(timer); resolve(j) });
    write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const text = (j) => (j.result?.content ?? []).map((c) => c.text ?? "").join("\n") || JSON.stringify(j.error ?? j);
  return {
    async start() {
      await ask("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "acceptance4", version: "1" } });
      write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
      await until(async () => !/not connected|error\[session\]/.test(text(await ask("tools/call", { name: "hireme", arguments: {} }))), "hireme-mcp connected");
    },
    async call(name, args) {
      const j = await ask("tools/call", { name, arguments: args });
      const t = text(j);
      if (j.error || j.result?.isError) throw new Error(`${name} ${JSON.stringify(args)}: ${t.slice(0, 300)}`);
      return { text: t, data: j.result?.structuredContent };
    },
    stop() { p.kill() },
  };
}

/** The id an MCP write answered ("-> id 7, rev 1"). */
const idOf = (t) => Number((t.match(/id (\d+)/) ?? [])[1]);

const browser = await chromium.launch({ executablePath: CHROMIUM, headless: true, args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"] });
// The desk draws only the rows in view (its board is a window of tiles), so the
// pages are tall enough for this 20-application fixture's whole board.
const VIEW = { viewport: { width: 1440, height: 1400 } };
const ctx = await browser.newContext(VIEW);
const account = await ctx.newPage();
const watch = (label, p) => {
  p.on("pageerror", (e) => errors.push(`${label}: ${String(e).slice(0, 200)}`));
  p.on("console", (m) => { if (m.type() === "error") errors.push(`${label} console: ${m.text().slice(0, 200)}`) });
  return p;
};
watch("account", account);
let secret = "", seeded = [], agent;
const pages = { account };

await step("sign in (dev)", pages, async () => {
  await account.goto(`${BASE}/sign-in`);
  const button = account.locator('form[action="/dev/sign-in"] button');
  if ((await button.count()) === 0) throw new Error('missing form[action="/dev/sign-in"] button (is this a dev node?)');
  await button.click();
  await until(async () => !account.url().includes("/sign-in"), "left /sign-in");
  await until(async () => (await account.locator(".link-open").count()) > 0, ".link-open (the shell's carrier is up)");
  return account.url().replace(BASE, "");
});

await step("mint a read_write key in the account lens", pages, async () => {
  await account.goto(`${BASE}/account`);
  const open = account.locator('button[data-act="open"][data-form="mint"]');
  await until(async () => (await open.count()) > 0, 'button[data-act="open"][data-form="mint"]');
  await open.click();
  const form = account.locator('form[data-act="mint"]');
  await form.locator('input[name="name"]').fill("acceptance agent");
  await form.locator('select[name="preset"]').selectOption("read_write");
  await form.locator("button.primary").click();
  secret = await until(async () => {
    if ((await account.locator("section.step-up").count()) > 0) throw new Error("the lens asked for a step-up");
    const s = account.locator(".reveal pre.secret");
    return (await s.count()) > 0 ? (await s.textContent()).trim() : "";
  }, ".reveal pre.secret (the one-time secret)");
  await account.locator('[data-act="reveal-done"]').click();
  return `${secret.slice(0, 6)}…`;
});

await step("seed 20 applications through hireme-mcp", pages, async () => {
  const seeder = mcp(secret);
  try {
    await seeder.start();
    await seeder.call("lease", {});
    for (let i = 1; i <= 20; i++) {
      const r = await seeder.call("put", { table: "applications", set: { company: `Company ${i}`, role: "Engineer" } });
      seeded.push(idOf(r.text));
    }
  } finally { seeder.stop() }
  if (seeded.some((x) => !x)) throw new Error(`an id was not read: ${seeded}`);
  return `${seeded.length} applications`;
});

const desk = watch("desk", await ctx.newPage());
const corps = watch("world corporations", await ctx.newPage());
const offices = watch("world offices", await ctx.newPage());
Object.assign(pages, { desk, corps, offices });
// A marker set in each page once its lens is open: a reload would clear it.
// (The lenses keep their state in the address with history.replaceState,
// which is not a reload.)
const marked = async () => {
  const gone = [];
  for (const [label, p] of [["desk", desk], ["corporations", corps], ["offices", offices]])
    if (!(await p.evaluate(() => window.__acceptance === 1).catch(() => false))) gone.push(label);
  return gone;
};
let cardId = 0, corpId = 0, officeId = 0;

await step("open the desk and world lenses", pages, async () => {
  await desk.goto(`${BASE}/desk`);
  await until(async () => (await desk.locator("#lens article.app-card").count()) >= 20, "20 article.app-card on the desk");
  // Every column group, empty columns too: the domain is in Identity, the headcount in Size.
  await corps.goto(`${BASE}/world/corporations?cols=all&empty=show`);
  await offices.goto(`${BASE}/world/offices`);
  await until(async () => (await corps.locator("table").count()) > 0, "a table in world/corporations");
  await until(async () => (await offices.locator("table").count()) > 0, "a table in world/offices");
  return "desk, world/corporations, world/offices";
});

// Focus preservation (docs/rebuild.md, 'Web'): the operator is typing in the
// desk's search while the agent writes; the morph must keep the input, its
// text and its caret.
const typed = "Company";
await step("type in the desk search", pages, async () => {
  await desk.locator("#desk-search").click();
  await desk.keyboard.type(typed);
  await until(async () => (await desk.locator("#lens article.app-card").count()) >= 20, "the search keeps the 20 cards");
  for (const p of [desk, corps, offices]) await p.evaluate(() => { window.__acceptance = 1 });
  return `"${typed}"`;
});

await step("hireme-mcp: lease 16, move one to draft_ready, add a cited corporation and an office", pages, async () => {
  agent = mcp(secret);
  await agent.start();
  const lease = await agent.call("lease", { count: 16 });
  const ids = lease.data?.ids ?? (lease.text.match(/\d+/g) ?? []).map(Number).filter((x) => seeded.includes(x));
  if (ids.length !== 16) throw new Error(`lease answered ${ids.length} ids: ${lease.text.slice(0, 200)}`);
  cardId = ids[0];
  const batch = idOf((await agent.call("put", { table: "batches", set: { code: "B-1", ordinal: 1 } })).text);
  await agent.call("put", { table: "applications", id: cardId, set: { batch_id: batch } });
  await agent.call("stage", { id: cardId, stage: "draft_ready" });
  corpId = idOf((await agent.call("put", { table: "corporations", key: { domain: "acme.example" }, set: { name: "Acme", headcount: 120 }, as_of: "2026-10-01", source: "https://acme.example/about" })).text);
  const place = idOf((await agent.call("put", { table: "places", key: { iso2: "AC", kind: "country" }, set: { name: "Acmeland" } })).text);
  officeId = idOf((await agent.call("put", { table: "offices", set: { corporation_id: corpId, place_id: place, kind: "hq" } })).text);
  return `application ${cardId}, corporation ${corpId}, office ${officeId}`;
});

await step("the desk shows the 16 claims and the move, without a reload", pages, async () => {
  await until(async () => (await desk.locator("#lens article.app-card[data-leased]").count()) === 16, "16 article.app-card[data-leased]");
  await until(async () => (await desk.locator(`#lens article.app-card[data-id="${cardId}"][data-stage="draft_ready"]`).count()) === 1, `article.app-card[data-id="${cardId}"][data-stage="draft_ready"]`);
  return `16 leased, #${cardId} draft_ready`;
});

await step("world shows the corporation with its cited headcount, without a reload", pages, async () => {
  const row = corps.locator(`tr[data-id="${corpId}"]`);
  await until(async () => (await row.count()) === 1, `tr[data-id="${corpId}"] in world/corporations`);
  await until(async () => /acme\.example/.test(await row.innerText()), "the row names acme.example");
  await until(async () => (await row.locator('button[data-act="cites"][data-col="headcount"]').count()) === 1, 'button[data-act="cites"][data-col="headcount"] (the cited headcount)');
  return `row ${corpId}: ${(await row.innerText()).replace(/\s+/g, " ").slice(0, 80)}`;
});

await step("the desk search kept focus, text and caret through the writes", pages, async () => {
  const s = await desk.evaluate(() => {
    const el = document.activeElement;
    return { id: el?.id, value: el?.value, caret: el?.selectionStart };
  });
  if (s.id !== "desk-search" || s.value !== typed || s.caret !== typed.length)
    throw new Error(`focus ${JSON.stringify(s)}, expected #desk-search with "${typed}", caret ${typed.length}`);
  return JSON.stringify(s);
});

await step("world shows the office, without a reload", pages, async () => {
  const row = offices.locator(`tr[data-id="${officeId}"]`);
  await until(async () => (await row.count()) === 1, `tr[data-id="${officeId}"] in world/offices`);
  return `row ${officeId}`;
});

await step("no reload and no page error", pages, async () => {
  const reloaded = await marked();
  if (reloaded.length) throw new Error(`reloaded: ${reloaded.join(", ")}`);
  if (errors.length) throw new Error(errors.join(" | "));
  return "none";
});

// After a reload that resumes from the IndexedDB snapshot, the desk paints
// before its first board derive: "Restoring the desk…" shows first, the
// cards after it, and the first contentful paint does not wait for them.
await step("a reload from the snapshot paints the desk restoring before its cards", pages, async () => {
  await until(async () => (await desk.evaluate(async () => (await indexedDB.databases()).map((d) => d.name))).includes("hireme"), "the snapshot database (saved a few seconds after rows move)");
  await sleep(6000);
  await desk.addInitScript(() => {
    const t = (globalThis.__order = []);
    new PerformanceObserver((l) => { for (const e of l.getEntries()) t.push({ at: e.startTime, what: e.name }) }).observe({ type: "paint", buffered: true });
    const watch = () => {
      const lens = document.getElementById("lens");
      if (!lens) return void requestAnimationFrame(watch);
      const note = () => t.push({ at: performance.now(), what: lens.querySelector("article.app-card") ? "cards" : lens.textContent.includes("Restoring the desk") ? "restoring" : "other" });
      note();
      new MutationObserver(note).observe(lens, { childList: true, subtree: true, characterData: true });
    };
    watch();
  });
  await desk.reload();
  await until(async () => (await desk.locator("#lens article.app-card").count()) >= 20, "20 article.app-card after the reload");
  const order = await desk.evaluate(() => globalThis.__order);
  const first = (w) => order.find((x) => x.what === w)?.at;
  const [fcp, restoring, cards] = [first("first-contentful-paint"), first("restoring"), first("cards")];
  if (restoring === undefined) throw new Error(`never painted "Restoring the desk…": ${JSON.stringify(order.slice(0, 8))}`);
  if (!(cards > restoring)) throw new Error(`restoring at ${restoring} is not before the cards at ${cards}`);
  if (!(fcp < cards)) throw new Error(`first contentful paint at ${fcp} waited for the cards at ${cards}`);
  if (errors.length) throw new Error(errors.join(" | "));
  return `restoring ${restoring.toFixed(1)} ms, first contentful paint ${fcp.toFixed(1)} ms, cards ${cards.toFixed(1)} ms`;
});

// No path leaves the desk on "Restoring the desk…": a fresh page in the same
// context (the same IndexedDB snapshot) with one of the kernel module's
// exports replaced, before the page instantiates it, by one that traps. The
// exports object's properties are read-only, so it is a plain copy, not a
// Proxy (which may not answer for them).
async function faulted(fault, { context = ctx, path = "/desk", changing = false } = {}) {
  const p = await context.newPage();
  p.consoleErrors = [];
  p.on("console", (m) => { if (m.type() === "error") p.consoleErrors.push(m.text()) });
  await p.addInitScript(({ fault, changing }) => {
    const real = WebAssembly.instantiate.bind(WebAssembly);
    let n = 0;
    WebAssembly.instantiate = async (m, imports) => {
      if (fault === "ingest") await new Promise((r) => setTimeout(r, 1500)); // frames queue meanwhile
      const out = await real(m, imports);
      const inst = out.instance ?? out;
      const boom = () => { throw new WebAssembly.RuntimeError(changing ? `boom ${n++} ${"x".repeat(5000)}` : `unreachable (injected in ${fault})`) };
      const fake = { exports: { ...inst.exports, [fault]: boom } };
      return out.instance ? { module: out.module, instance: fake } : fake;
    };
  }, { fault, changing });
  await p.goto(`${BASE}${path}`);
  return p;
}
const lensText = async (p) => (await p.locator("#lens").innerText()).replace(/\s+/g, " ");
const notices = (p) => p.locator(".notices").innerText();

await step("a view that throws after a restore shows its error line and one notice, never restoring", pages, async () => {
  const p = await faulted("view");
  try {
    const t = await until(async () => { const x = await lensText(p); return /failed to draw/.test(x) ? x : ""; }, "the lens's error line");
    await sleep(1500);
    if (/Restoring the desk/.test(await lensText(p))) throw new Error("still restoring");
    const n = await p.locator(".notices .notice", { hasText: "failed to draw" }).count();
    if (n !== 1) throw new Error(`${n} "failed to draw" notices, not one`);
    if ((await p.locator('nav a[href="/world/corporations"]').count()) !== 1) throw new Error("the nav did not paint");
    return `lens "${t.trim().slice(0, 60)}", one notice, nav painted`;
  } finally { await p.close() }
});

await step("focus's derive trapping after a restore paints its failure with one notice, logged, never restoring", pages, async () => {
  // Its own signed-in context and snapshot, so nothing the other pages did is in it.
  const own = await browser.newContext(VIEW);
  try {
    const p0 = await own.newPage();
    await p0.goto(`${BASE}/sign-in`);
    await p0.locator('form[action="/dev/sign-in"] button').click();
    await until(async () => !p0.url().includes("/sign-in"), "signed in");
    await p0.goto(`${BASE}/desk`);
    await until(async () => (await p0.locator("#lens article.app-card").count()) >= 20, "20 article.app-card");
    await sleep(6000); // the snapshot is saved
    const no = (await p0.locator("#lens article.app-card .no").first().textContent()).replace("#", "").trim();
    const p = await faulted("application", { context: own, path: `/focus/${no}` });
    await until(async () => /focus lens failed to (load|draw)/.test(await notices(p)), "the focus lens's failure notice");
    await sleep(1500);
    const t = await lensText(p);
    if (/Restoring the desk/.test(t)) throw new Error(`lens: ${t.slice(0, 80)}`);
    const n = await p.locator(".notices .notice", { hasText: "focus lens failed" }).count();
    if (n !== 1) throw new Error(`${n} focus failure notices, not one`);
    if (!p.consoleErrors.some((x) => x.includes("focus lens failed"))) throw new Error("not logged to the console");
    return `one notice, logged, lens "${t.trim().slice(0, 60)}"`;
  } finally { await own.close() }
});

await step("a trap in ingest while loading says the kernel did not load, never restoring", pages, async () => {
  const p = await faulted("ingest");
  try {
    await until(async () => /did not load/.test(await notices(p)), '"The kernel did not load" notice');
    await sleep(1500);
    const t = await lensText(p);
    if (/Restoring the desk/.test(t)) throw new Error(`lens: ${t.slice(0, 80)}`);
    return `lens "${t.trim().slice(0, 60)}"`;
  } finally { await p.close() }
});

await step("a view throwing a new long message each time raises one clipped notice and one console error, no repaint loop", pages, async () => {
  const p = await faulted("view", { changing: true });
  try {
    await until(async () => /failed to draw/.test(await notices(p)), "the notice");
    const count = () => p.evaluate(() => document.querySelectorAll(".notices .notice").length);
    const before = await count();
    await sleep(3000);
    const after = await count();
    const shown = await p.locator(".notices .notice", { hasText: "failed to draw" }).allInnerTexts();
    if (shown.length !== 1 || after !== before) throw new Error(`${shown.length} draw notices; notices ${before} -> ${after}`);
    if (shown[0].length >= 400) throw new Error(`a notice of ${shown[0].length} characters`);
    const logged = p.consoleErrors.filter((x) => x.includes("failed to draw")).length;
    if (logged !== 1) throw new Error(`${logged} console errors, not one`);
    return `1 notice (${shown[0].length} chars), steady at ${after}, 1 console error`;
  } finally { await p.close() }
});

// A page whose kernel export `name` traps while window.__trap is true (from
// the start if `now`): each lens hook (enter, view, after) that runs it must
// fail into its notice, not out of the frame.
async function trapping(path, now, name = "application") {
  const p = await ctx.newPage();
  await p.addInitScript(([now, name]) => {
    window.__trap = now;
    const real = WebAssembly.instantiate.bind(WebAssembly);
    WebAssembly.instantiate = async (m, imports) => {
      const out = await real(m, imports);
      const inst = out.instance ?? out;
      const real_ = inst.exports[name];
      const trapped = (...a) => { if (window.__trap) throw new WebAssembly.RuntimeError(`unreachable (injected in ${name})`); return real_(...a) };
      const fake = { exports: { ...inst.exports, [name]: trapped } };
      return out.instance ? { module: out.module, instance: fake } : fake;
    };
  }, [now, name]);
  await p.goto(`${BASE}${path}`);
  return p;
}
const cardNo = async () => (await desk.locator(`#lens article.app-card[data-id="${cardId}"] .no`).textContent()).replace("#", "").trim();

// Focus's enter resolves its application by number in the replica (kernel lookup, over the
// ids_ptr export), so that is the export its enter runs: trapped once the desk is drawn.
await step("enter: from a drawn desk to focus with the replica's ids trapping, focus shows its failure and the load notice", pages, async () => {
  const p = await trapping("/desk", false, "ids_ptr");
  try {
    await until(async () => (await p.locator("#lens article.app-card").count()) >= 20, "the desk drawn");
    const no = await cardNo();
    await p.evaluate(() => { window.__trap = true });
    await p.evaluate((no) => { history.pushState(null, "", `/focus/${no}`); dispatchEvent(new PopStateEvent("popstate")) }, no);
    await until(async () => /focus lens failed to load/.test(await notices(p)), '"focus lens failed to load" notice');
    const t = await lensText(p);
    if (!/failed to draw/.test(t) || (await p.locator("#lens article.app-card").count()) !== 0) throw new Error(`lens: ${t.slice(0, 80)}`);
    return `lens "${t.trim().slice(0, 40)}", load notice`;
  } finally { await p.close() }
});

// No lens has a refresh hook since every read is the replica's (the PATCH redraws what it moved), so
// the refresh step that trapped one is retired with the hook.
await step("after: the desk's cards failing to fill (card traps) raises the update notice, the board drawn", pages, async () => {
  const p = await faulted("card");
  try {
    await until(async () => /desk lens failed to update/.test(await notices(p)), '"desk lens failed to update" notice');
    const n = await p.locator("#lens article.app-card").count();
    if (n < 20) throw new Error(`${n} card shells`);
    return `${n} card shells, update notice`;
  } finally { await p.close() }
});

await step("the same page, unwrapped, restores and shows its cards", pages, async () => {
  const p = await ctx.newPage();
  try {
    await p.goto(`${BASE}/desk`);
    await until(async () => (await p.locator("#lens article.app-card").count()) >= 20, "20 article.app-card");
    return "20 cards";
  } finally { await p.close() }
});

agent?.stop();
await browser.close();
console.log(`res=${failed === 0 ? 0 : 1}`);
process.exit(failed === 0 ? 0 : 1);
