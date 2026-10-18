// Cutover acceptance 4, the browser half (docs/rebuild.md, 'Cutover
// acceptance'): with the desk and world lenses open, a real hireme-mcp on a
// key minted in the account lens leases 16, moves one application to
// draft_ready and adds a corporation with a cited headcount and an office;
// the browser shows all three without a reload. Run by test/e2e/run.sh,
// which boots the node; this script needs BASE, HIREME_MCP, CHROMIUM, OUT.

import { chromium } from "playwright";
import { spawn } from "node:child_process";

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
  const p = spawn(HIREME_MCP, [], { env: { ...process.env, HIREME_KEY: key, HIREME_URL: BASE }, stdio: ["pipe", "pipe", "pipe"] });
  const waiting = new Map();
  let buf = "", next = 1;
  p.stdout.on("data", (d) => {
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
  });
  const ask = (method, params) => new Promise((resolve, reject) => {
    const id = next++;
    const timer = setTimeout(() => reject(new Error(`no MCP answer to ${method}`)), STEP_MS);
    waiting.set(id, (j) => { clearTimeout(timer); resolve(j) });
    p.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const text = (j) => (j.result?.content ?? []).map((c) => c.text ?? "").join("\n") || JSON.stringify(j.error ?? j);
  return {
    async start() {
      await ask("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "acceptance4", version: "1" } });
      p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
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
const ctx = await browser.newContext();
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
  await until(async () => (await desk.locator("article.app-card").count()) >= 20, "20 article.app-card on the desk");
  await corps.goto(`${BASE}/world/corporations`);
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
  await until(async () => (await desk.locator("article.app-card").count()) >= 20, "the search keeps the 20 cards");
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
  await until(async () => (await desk.locator("article.app-card[data-leased]").count()) === 16, "16 article.app-card[data-leased]");
  await until(async () => (await desk.locator(`article.app-card[data-id="${cardId}"][data-stage="draft_ready"]`).count()) === 1, `article.app-card[data-id="${cardId}"][data-stage="draft_ready"]`);
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

agent?.stop();
await browser.close();
console.log(`res=${failed === 0 ? 0 : 1}`);
process.exit(failed === 0 ? 0 : 1);
