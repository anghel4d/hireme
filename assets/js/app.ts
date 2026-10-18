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
import { EMPTY, html, morph, type Html } from "./morph.ts"
import { dismiss, format, go, model, notice, onRender, parse, schedule, set, type Lens } from "./state.ts"
import { KIND, Wire, bye, welcome, type Bytes, type Header } from "./wire.ts"
import account from "./lenses/account.ts"
import desk from "./lenses/desk.ts"
import focus from "./lenses/focus.ts"
import outreach from "./lenses/outreach.ts"
import world from "./lenses/world.ts"

/** What every lens is: a view of the model, and the actions its markup names. */
export interface View {
  title: string
  view(): Html
  /** The lens became current, or its address (sub or query) changed. */
  enter?(): void
  /** An element with `data-act` was used; `ev` is the click, input, change, keydown or submit. */
  act?(name: string, el: HTMLElement, ev: Event): void
  /** After every morph: a lens that owns subtrees (the board's cards) writes them here. */
  after?(root: HTMLElement): void
  /** A key with no focused field; true when handled. */
  key?(ev: KeyboardEvent): boolean
}

const VIEWS: Partial<Record<Lens, View>> = { account, desk, focus, outreach, world }

const NAV: { lens: Lens; label: string; key: string }[] = [
  { lens: "desk", label: "Desk", key: "1" },
  { lens: "focus", label: "Focus", key: "2" },
  { lens: "world", label: "World", key: "3" },
  { lens: "atlas", label: "Atlas", key: "4" },
  { lens: "outreach", label: "Outreach", key: "5" },
  { lens: "lanes", label: "Lanes", key: "6" },
  { lens: "account", label: "Account", key: "7" },
]

export function register(lens: Lens, v: View): void {
  VIEWS[lens] = v
}

const root = document.getElementById("app")
let entered = ""

function link(): Html {
  const label = { connecting: "connecting", open: model.carrier === "webtransport" ? "live (WT)" : "live", lost: "reconnecting", ended: "offline" }[model.link]
  return html`<span class="link link-${model.link}" role="status" title="wire rev ${model.rev.toString()}">${label}${model.pending > 0 ? html` · ${model.pending} pending` : EMPTY}</span>`
}

function shell(): Html {
  const lens = model.address.lens
  const v = VIEWS[lens]
  return html`<header class="bar">
      <a class="brand" href="/desk" data-nav>hireme</a>
      <nav aria-label="Lenses">${NAV.map((n) => html`<a href="/${n.lens}" data-nav data-key="${n.lens}"
        class="tab${n.lens === lens ? " on" : ""}"${n.lens === lens ? html` aria-current="page"` : EMPTY} title="${n.label} (${n.key})">${n.label}</a>`)}</nav>
      ${link()}
    </header>
    <main id="lens" class="lens lens-${lens}" data-key="lens-${lens}">${v ? v.view() : html`<p class="empty">Loading…</p>`}</main>
    <aside class="notices" aria-live="polite">${model.notices.map((n) => html`<div class="notice notice-${n.tone}" data-key="n${n.id}">
      <span>${n.text}</span><button type="button" class="ghost" data-act="dismiss" data-id="${n.id}" aria-label="Dismiss">×</button></div>`)}</aside>`
}

function render(): void {
  if (!root) return
  const v = VIEWS[model.address.lens]
  const where = format(model.address)
  if (where !== entered) {
    entered = where
    v?.enter?.()
    document.title = `${v?.title ?? "hireme"} · hireme`
  }
  morph(root, shell())
  const lens = document.getElementById("lens")
  if (lens) v?.after?.(lens)
}

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
  if (ev.type !== "click" && ev.type !== "submit" && el.dataset.on !== ev.type) return
  if (ev.type === "submit" || el instanceof HTMLAnchorElement) ev.preventDefault()
  if (name === "dismiss") return dismiss(Number(el.dataset.id))
  VIEWS[model.address.lens]?.act?.(name, el, ev)
}

if (root) {
  for (const type of ["click", "input", "change", "submit", "keydown"]) root.addEventListener(type, actOn)
}

const typing = (t: EventTarget | null) =>
  t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement || t instanceof HTMLSelectElement || (t instanceof HTMLElement && t.isContentEditable)

addEventListener("keydown", (ev) => {
  if (ev.defaultPrevented || ev.metaKey || ev.ctrlKey || ev.altKey || typing(ev.target)) return
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
      set({ readMask: w.readMask, writeMask: w.writeMask, mayDelete: w.mayDelete, leased: w.leased, rev: w.accountRev, link: "open" })
      kernel.resend()
      return
    }
    case KIND.BYE: {
      const b = bye(f)
      if (b.reason === "revoked" || b.reason === "suspended") {
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
    if (retry === 0 && why === "signed out") location.assign("/sign-in")
  },
  hello: () => ({ snapshotRev: kernel.snapshotRev(), schemaRev: 0n, label: navigator.userAgent.slice(0, 120) }),
})
kernel.attach(wire)

void (async () => {
  await hw?.ready
  wire.start(hw)
  if (hw) kernel.load(hw)
})()

schedule()
