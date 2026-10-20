// Boot: adopt what early.ts started, route the wire's frames, and draw.
//
// One renderer: the model in, the shell and the current lens out, morphed
// into #app on the next frame after any change. Events are delegated from
// #app: an element names its action with `data-act` (and a form with
// `data-submit`), and the current lens's `act` runs it, so no lens holds a
// listener and a morph never strands one. A link with `data-nav` moves
// the address without a page load.

import type { Boot } from "./early.ts"
import * as kernel from "./kernel.ts"
import { guard, type Part } from "./guard.ts"
import { EMPTY, html, morph, type Html } from "./morph.ts"
import { LENSES, dismiss, format, go, model, notice, onRender, parse, schedule, set, type Lens } from "./state.ts"
import { SCHEMA_REV } from "./gen/schema.ts"
import { KIND, Wire, bye, welcome, type Bytes, type Header } from "./wire.ts"
import account from "./lenses/account.ts"
import atlas from "./lenses/atlas.ts"
import desk from "./lenses/desk.ts"
import focus from "./lenses/focus.ts"
import lanes from "./lenses/lanes.ts"
import me from "./lenses/me.ts"
import outreach from "./lenses/outreach.ts"
import world from "./lenses/world.ts"

/** What every lens is: a view of the model, and the actions its markup names. */
export interface View {
  title: string
  view(): Html
  /** The lens became current (`fresh`), or its address (sub or query) changed while it was current. */
  enter?(fresh: boolean): void
  /** An element with `data-act` was used; `ev` is the click, input, change, keydown or submit. */
  act?(name: string, el: HTMLElement, ev: Event): void
  /** After every morph: a lens that owns subtrees (the board's cards) writes them here. */
  after?(root: HTMLElement): void
  /** A key with no focused field; true when handled. */
  key?(ev: KeyboardEvent): boolean
}

/** Every lens, in the one bundle: a chunk per lens was a request per lens on every load. */
const VIEWS: Record<Lens, View> = { desk, focus, world, atlas, outreach, lanes, me, account }

const NAV: { lens: Lens; label: string; key: string }[] = [
  { lens: "desk", label: "Desk", key: "1" },
  { lens: "focus", label: "Focus", key: "2" },
  { lens: "world", label: "World", key: "3" },
  { lens: "atlas", label: "Atlas", key: "4" },
  { lens: "outreach", label: "Outreach", key: "5" },
  { lens: "lanes", label: "Lanes", key: "6" },
  { lens: "me", label: "Me", key: "7" },
  { lens: "account", label: "Account", key: "8" },
]

const root = document.getElementById("app")
let enteredLens = ""
let entered = ""

function link(): Html {
  const label = { connecting: "connecting", open: model.carrier === "webtransport" ? "live (WT)" : "live", lost: "reconnecting", ended: "offline" }[model.link]
  return html`<span class="link link-${model.link}" role="status" title="account rev ${model.rev.toString()} at connect">${label}${model.pending > 0 ? html` · ${model.pending} pending` : EMPTY}</span>`
}

/**
 * The lenses that read the board derive wait for it after a snapshot restore, one paint later; every
 * lens that reads the replica waits for the kernel to load.
 */
const DERIVES: readonly Lens[] = ["desk", "focus"]
const REPLICA: readonly Lens[] = ["desk", "focus", "world", "outreach", "me", "account"]
const waiting = (lens: Lens): boolean => (DERIVES.includes(lens) && kernel.warming()) || (REPLICA.includes(lens) && !rowsIn())

/** Rows are in: a BOOT or PATCH reached the kernel, or it restored a snapshot. A loaded kernel with neither holds nothing to draw. */
let framed = false
const rowsIn = (): boolean => kernel.loaded() && (framed || kernel.snapshotRev() > 0n)

// The first paint waits for the rows, up to HOLD_MS from navigation: a fast load paints the desk
// itself rather than "Restoring…" a frame before it, and its main thread is free for the BOOT.
const HOLD_MS = 100
let holding = true
function held(): boolean {
  if (holding && !rowsIn() && !kernel.broken() && performance.now() < HOLD_MS) return true
  holding = false
  return false
}

/** The lens hooks' guard (guard.ts): a failing hook's fallback stands in, told once, logged once. */
const hooks = guard(
  (text) => notice("error", text),
  (what, e) => console.error(`hireme: ${what}`, e),
)
const guarded = <T>(lens: Lens, part: Part, fn: () => T, fallback: T): T => hooks.run(lens, part, fn, fallback)

const lensView = (lens: Lens, v: View): Html => guarded(lens, "view", () => v.view(), html`<p class="error" role="alert">This view failed to draw.</p>`)

// Every lens, once drawn, stays in the page when another is current, parked under
// content-visibility: hidden, which keeps its style and layout: going back to it uncovers a
// laid-out lens instead of building one. A parked lens is left alone by morph (data-morph="own").
const parked = new Set<Lens>()

const active = (lens: Lens, v: View | undefined): Html => html`<main id="lens" class="lens lens-${lens}" data-key="lens-${lens}">${
  v ? lensView(lens, v)
  : kernel.broken() ? html`<div class="empty"><p class="error" role="alert">This page could not load its data: the kernel did not load.</p>
      <p><a class="button" href="${format(model.address)}">Reload</a> If it keeps failing, sign out and sign in again.</p></div>`
  : html`<p class="empty">Restoring the desk…</p>`}</main>`

// A parking lens keeps the children it has (morph leaves an owned subtree's children alone), so it is never redrawn to park.
const parkedMain = (l: Lens): Html => html`<main class="lens lens-${l} parked" data-key="lens-${l}" data-morph="own" inert aria-hidden="true"></main>`

function shell(): Html {
  const lens = model.address.lens
  const v = waiting(lens) ? undefined : VIEWS[lens]
  if (v) parked.add(lens)
  return html`<header class="bar">
      <a class="brand" href="/desk" data-nav>hireme</a>
      <nav aria-label="Lenses">${NAV.map((n) => html`<a href="${format({ lens: n.lens, sub: "", q: new Map() })}" data-nav data-key="${n.lens}"
        class="tab${n.lens === lens ? " on" : ""}"${n.lens === lens ? html` aria-current="page"` : EMPTY} title="${n.label} (${n.key})">${n.label}</a>`)}</nav>
      ${link()}
      <form method="post" action="/sign-out" data-submit="sign-out" class="sign-out">
        <input type="hidden" name="_csrf_token" value="${document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""}">
        <button class="ghost">Sign out</button>
      </form>
    </header>
    ${LENSES.filter((l) => l === lens || parked.has(l)).map((l) => (l === lens ? active(lens, v) : parkedMain(l)))}
    <aside class="notices" aria-live="polite">${model.notices.map((n) => html`<div class="notice notice-${n.tone}" data-key="n${n.id}">
      <span>${n.text}${(n.times ?? 1) > 1 ? html` <b class="times">×${n.times}</b>` : EMPTY}</span><button type="button" class="ghost" data-act="dismiss" data-id="${n.id}" aria-label="Dismiss">×</button></div>`)}</aside>`
}

function render(): void {
  if (!root || held()) return
  const hold = waiting(model.address.lens)
  const v = hold ? undefined : VIEWS[model.address.lens]
  const where = format(model.address)
  // A lens that waits for the first derive is entered once it has run, not before.
  if (where !== entered && !hold) {
    entered = where
    const fresh = model.address.lens !== enteredLens
    enteredLens = model.address.lens
    // A lens whose enter throws (focus derives there) still reaches morph, its failure told once.
    guarded(model.address.lens, "enter", () => v?.enter?.(fresh), undefined)
    document.title = `${v?.title ?? "hireme"} · hireme`
  }
  // Markup is a function of the model, so the same markup as the last morph is the same page: skipped.
  const next = shell()
  if (next.text !== drawn) {
    morph(root, next)
    drawn = next.text
  }
  const lens = document.getElementById("lens")
  // A lens whose view failed has nothing of its own on the page to keep current.
  if (lens && !hooks.failing(model.address.lens, "view")) guarded(model.address.lens, "after", () => v?.after?.(lens), undefined)
  // A control a lens just opened for editing takes focus once (autofocus does not fire for morphed-in markup).
  if (lens) mark(lens)
  const want = lens?.querySelector<HTMLElement>("[data-autofocus]")
  if (want && !focusedOnce.has(want)) {
    focusedOnce.add(want)
    want.focus({ preventScroll: false })
  }
}

const focusedOnce = new WeakSet<Element>()
let drawn = ""

onRender(render)

// ------------------------------------------------------------------ events

function actOn(ev: Event): void {
  const target = ev.target
  if (!(target instanceof Element)) return
  const nav = target.closest<HTMLAnchorElement>("a[data-nav]")
  if (nav && ev.type === "click") {
    const me = ev as MouseEvent
    if (me.button !== 0 || me.metaKey || me.ctrlKey || me.shiftKey || me.altKey) return
    ev.preventDefault()
    const url = new URL(nav.href)
    const next = parse(url.pathname, url.search)
    go(next)
    return
  }
  const el = ev.type === "submit" ? (target as HTMLElement) : target.closest<HTMLElement>("[data-act]")
  if (!el) return
  const name = ev.type === "submit" ? el.dataset.submit : el.dataset.act
  if (!name) return
  // A click acts on buttons and links; input/change/keydown act on fields that ask for them.
  if (ev.type === "click" && !(el instanceof HTMLButtonElement || el instanceof HTMLAnchorElement || el.dataset.click !== undefined)) return
  // A link inside a clickable cell is followed, not taken as the cell's click.
  const inner = target.closest("a[href]")
  if (ev.type === "click" && inner && inner !== el && el.contains(inner)) return
  if (ev.type !== "click" && ev.type !== "submit" && el.dataset.on !== ev.type) return
  if (ev.type === "submit" || el instanceof HTMLAnchorElement) ev.preventDefault()
  if (name === "dismiss") return dismiss(Number(el.dataset.id))
  // Signing out takes the desk's snapshot out of this browser before the form goes.
  if (name === "sign-out") {
    kernel.forget()
    return (el as HTMLFormElement).submit()
  }
  // A write the replica refuses throws here, in the input's frame: told, and the form it came from stays open.
  try {
    VIEWS[model.address.lens]?.act?.(name, el, ev)
  } catch (e) {
    if (!(e instanceof kernel.Refused)) console.error("hireme: an action failed", e)
    kernel.failed(e)
  }
}

if (root) {
  for (const type of ["click", "input", "change", "submit", "keydown"]) root.addEventListener(type, actOn)
}

const typing = (t: EventTarget | null) =>
  t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement || t instanceof HTMLSelectElement || (t instanceof HTMLElement && t.isContentEditable)

addEventListener("keydown", (ev) => {
  // Escape leaves a field (a search box clears itself first), so the lens's keys work again at once.
  if (ev.key === "Escape" && typing(ev.target) && ev.target instanceof HTMLElement) {
    ev.target.blur()
    return
  }
  if (ev.defaultPrevented || ev.metaKey || ev.ctrlKey || ev.altKey || typing(ev.target)) return
  // Enter and Space on a focused button or link are that control's own.
  if ((ev.key === "Enter" || ev.key === " ") && ev.target instanceof Element && ev.target.closest("button, a, summary, [role=button]")) return
  const n = NAV.find((x) => x.key === ev.key)
  if (n) {
    ev.preventDefault()
    go({ lens: n.lens, sub: "" })
    return
  }
  if (VIEWS[model.address.lens]?.key?.(ev) || rowKey(ev.key)) ev.preventDefault()
})

// ------------------------------------------------------------------ rows

// Every lens's rows answer the same keys (vim's and the arrows'), unless the lens
// takes the key itself: j/k move a cursor through its table rows and listed items, g/G
// jump to the ends, Enter or o opens the row (its own action, else its first link or
// button), and h/l step through the lens's tabs. The cursor is the row's data-key, per
// lens, so it survives a redraw.
const ROWS = "tbody tr, ul.rows > li, ol.rows > li"
const cursor = new Map<Lens, string>()

function rows(lens: HTMLElement): HTMLElement[] {
  return [...lens.querySelectorAll<HTMLElement>(ROWS)].filter((r) => r.offsetParent !== null)
}

const keyOf = (r: HTMLElement, i: number): string => r.dataset.key ?? `#${i}`

function mark(lens: HTMLElement): void {
  const all = rows(lens)
  // The first row is the cursor until a key moves it (or the row it was on is gone).
  let want = cursor.get(model.address.lens)
  if (all.length > 0 && !all.some((r, i) => keyOf(r, i) === want)) {
    want = keyOf(all[0]!, 0)
    cursor.set(model.address.lens, want)
  }
  all.forEach((r, i) => r.classList.toggle("cursor", want !== undefined && keyOf(r, i) === want))
}

function rowKey(k: string): boolean {
  const lens = document.getElementById("lens")
  if (!lens) return false
  if (k === "h" || k === "ArrowLeft" || k === "l" || k === "ArrowRight") {
    const tabs = [...lens.querySelectorAll<HTMLAnchorElement>(".subtabs a")]
    if (tabs.length < 2) return false
    const at = Math.max(0, tabs.findIndex((t) => t.classList.contains("on")))
    const next = tabs[(at + (k === "h" || k === "ArrowLeft" ? tabs.length - 1 : 1)) % tabs.length]
    next?.click()
    return true
  }
  const all = rows(lens)
  if (all.length === 0) return false
  const want = cursor.get(model.address.lens)
  const at = all.findIndex((r, i) => keyOf(r, i) === want)
  let i: number
  if (k === "j" || k === "ArrowDown") i = at < 0 ? 0 : Math.min(all.length - 1, at + 1)
  else if (k === "k" || k === "ArrowUp") i = at < 0 ? 0 : Math.max(0, at - 1)
  else if (k === "g" || k === "Home") i = 0
  else if (k === "G" || k === "End") i = all.length - 1
  else if ((k === "Enter" || k === "o") && at >= 0) {
    const r = all[at]!
    const target = r.dataset.act ? r : r.querySelector<HTMLElement>("a[href], button")
    target?.click()
    return target !== null
  } else return false
  const r = all[i]!
  cursor.set(model.address.lens, keyOf(r, i))
  mark(lens)
  r.scrollIntoView({ block: "nearest" })
  return true
}

// ------------------------------------------------------------------ wire

const hw = (window as { __hw?: Boot }).__hw

function frame(f: Bytes, h: Header): void {
  switch (h.kind) {
    case KIND.WELCOME: {
      const w = welcome(f)
      kernel.setGrants(w.readMask, w.writeMask, w.mayDelete)
      set({ writeMask: w.writeMask, sessionId: Number(w.sessionId), rev: w.accountRev, link: "open" })
      kernel.resend()
      return
    }
    case KIND.BYE: {
      const b = bye(f)
      if (b.reason === "revoked" || b.reason === "suspended") {
        kernel.forget()
        wire.end()
        set({ link: "ended" })
        notice("error", b.reason === "revoked" ? "This session was revoked. Sign in again." : "This account is suspended.")
      } else if (b.reason === "schema") {
        // The wire changed under this page: only a fresh bundle speaks it.
        location.reload()
      } else if (b.reason === "grants") {
        notice("info", "Permissions changed; reconnecting.")
      }
      return
    }
    default:
      if (h.kind === KIND.BOOT || h.kind === KIND.PATCH) framed = true
      kernel.frame(f, h)
  }
}

const wire = new Wire({
  frame,
  open: (carrier) => set({ carrier, link: "connecting" }),
  lost: (why, retry) => {
    set({ link: retry === 0 ? "ended" : "lost" })
    if (retry === 0 && why === "signed out") {
      kernel.forget()
      location.assign("/sign-in")
    }
  },
  // The node resumes from a snapshot rev only when the schema it was taken under is its own.
  hello: () => {
    const rev = kernel.snapshotRev()
    return { snapshotRev: rev, schemaRev: rev > 0n ? BigInt(SCHEMA_REV) : 0n, label: navigator.userAgent.slice(0, 120) }
  },
})
kernel.attach(wire)


void (async () => {
  await hw?.ready
  wire.start(hw)
  // Without early.ts (the inline script blocked or stripped) the bundle compiles the kernel itself.
  kernel.load(hw ?? { queue: [], helloSent: false, ready: Promise.resolve(), boot: () => undefined, kernel: WebAssembly.compileStreaming(fetch(document.querySelector<HTMLLinkElement>('link[rel="preload"][as="fetch"]')?.href ?? "/wasm/kernel.wasm")), snap: Promise.resolve(undefined) })
})()

schedule()
setTimeout(schedule, Math.max(0, HOLD_MS - performance.now()))
