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
import { dismiss, format, go, model, notice, onRender, parse, schedule, set, type Lens } from "./state.ts"
import { SCHEMA_REV } from "./gen/schema.ts"
import { KIND, Wire, bye, welcome, type Bytes, type Header } from "./wire.ts"
import account from "./lenses/account.ts"
import atlas from "./lenses/atlas.ts"
import desk from "./lenses/desk.ts"
import focus from "./lenses/focus.ts"
import lanes from "./lenses/lanes.ts"
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
  /** Server-side rows may have moved (a PATCH advanced the rev, or the session came back): re-read what is shown, keeping what is being edited. */
  refresh?(): void
  /** A key with no focused field; true when handled. */
  key?(ev: KeyboardEvent): boolean
}

const VIEWS: Partial<Record<Lens, View>> = { account, atlas, desk, focus, lanes, outreach, world }

const NAV: { lens: Lens; label: string; key: string }[] = [
  { lens: "desk", label: "Desk", key: "1" },
  { lens: "focus", label: "Focus", key: "2" },
  { lens: "world", label: "World", key: "3" },
  { lens: "atlas", label: "Atlas", key: "4" },
  { lens: "outreach", label: "Outreach", key: "5" },
  { lens: "lanes", label: "Lanes", key: "6" },
  { lens: "account", label: "Account", key: "7" },
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
const REPLICA: readonly Lens[] = ["desk", "focus", "world", "outreach", "account"]
const waiting = (lens: Lens): boolean => (DERIVES.includes(lens) && kernel.warming()) || (REPLICA.includes(lens) && !kernel.loaded())

/** The lens hooks' guard (guard.ts): a failing hook's fallback stands in, told once, logged once. */
const hooks = guard(
  (text) => notice("error", text),
  (what, e) => console.error(`hireme: ${what}`, e),
)
const guarded = <T>(lens: Lens, part: Part, fn: () => T, fallback: T): T => hooks.run(lens, part, fn, fallback)

const lensView = (lens: Lens, v: View): Html => guarded(lens, "view", () => v.view(), html`<p class="error" role="alert">This view failed to draw.</p>`)

function shell(): Html {
  const lens = model.address.lens
  const v = waiting(lens) ? undefined : VIEWS[lens]
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
    <main id="lens" class="lens lens-${lens}" data-key="lens-${lens}">${v ? lensView(lens, v) : html`<p class="empty">${waiting(lens) ? "Restoring the desk…" : "Loading…"}</p>`}</main>
    <aside class="notices" aria-live="polite">${model.notices.map((n) => html`<div class="notice notice-${n.tone}" data-key="n${n.id}">
      <span>${n.text}${(n.times ?? 1) > 1 ? html` <b class="times">×${n.times}</b>` : EMPTY}</span><button type="button" class="ghost" data-act="dismiss" data-id="${n.id}" aria-label="Dismiss">×</button></div>`)}</aside>`
}

function render(): void {
  if (!root) return
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
  morph(root, shell())
  const lens = document.getElementById("lens")
  // A lens whose view failed has nothing of its own on the page to keep current.
  if (lens && !hooks.failing(model.address.lens, "view")) guarded(model.address.lens, "after", () => v?.after?.(lens), undefined)
  // A control a lens just opened for editing takes focus once (autofocus does not fire for morphed-in markup).
  const want = lens?.querySelector<HTMLElement>("[data-autofocus]")
  if (want && !focusedOnce.has(want)) {
    focusedOnce.add(want)
    want.focus({ preventScroll: false })
  }
}

const focusedOnce = new WeakSet<Element>()

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
  if (VIEWS[model.address.lens]?.key?.(ev)) ev.preventDefault()
})

// ------------------------------------------------------------------ wire

const hw = (window as { __hw?: Boot }).__hw

function frame(f: Bytes, h: Header): void {
  switch (h.kind) {
    case KIND.WELCOME: {
      const w = welcome(f)
      kernel.setGrants(w.readMask, w.writeMask, w.mayDelete)
      set({ writeMask: w.writeMask, sessionId: Number(w.sessionId), rev: w.accountRev, link: "open" })
      kernel.resend()
      // After a reconnect the lens re-reads what it shows.
      if (++welcomes > 1) refresh()
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

// Server-side tables never ride PATCH as rows; a PATCH that advanced the rev
// says they may have moved, so the current lens re-reads: at once, then at
// most every 400 ms while writes keep coming, and once more after the last.
let lastRefresh = 0
let trailing = 0
function refresh(): void {
  const now = Date.now()
  clearTimeout(trailing)
  if (now - lastRefresh >= 400) {
    lastRefresh = now
    // A lens still waiting for the first derive reads everything when it enters.
    // Called from a frame's arrival: a lens whose refresh throws must not take the frame down with it.
    const lens = model.address.lens
    if (!waiting(lens)) guarded(lens, "refresh", () => VIEWS[lens]?.refresh?.(), undefined)
  } else {
    trailing = window.setTimeout(refresh, 400 - (now - lastRefresh))
  }
}
kernel.onAdvance(refresh)
let welcomes = 0

void (async () => {
  await hw?.ready
  wire.start(hw)
  // Without early.ts (the inline script blocked or stripped) the bundle compiles the kernel itself.
  kernel.load(hw ?? { queue: [], helloSent: false, ready: Promise.resolve(), kernel: WebAssembly.compileStreaming(fetch(document.querySelector<HTMLLinkElement>('link[rel="preload"][as="fetch"]')?.href ?? "/wasm/kernel.wasm")), snap: Promise.resolve(undefined) })
})()

schedule()
