// The model: the only mutable state on the page.
//
// Rows live in the kernel; this file holds what the kernel does not: where
// the operator is (the address), what is selected, what the connection is
// doing, each lens's view state, and notices. A change goes through
// `set`, which schedules one render on the next frame; lenses read
// `model` and return markup, they never write it.
//
// The address is the URL path, one lens per first segment:
//
//     /desk?band=a&stage=draft_ready&heat=hot&q=rust
//     /focus/<no>
//     /world/<table>?sort=-headcount&q=berlin
//     /atlas?preset=<name>
//     /outreach?contact=<id>
//     /lanes/<gym|net>
//     /account

export const LENSES = ["desk", "focus", "world", "atlas", "outreach", "lanes", "account"] as const
export type Lens = (typeof LENSES)[number]

export interface Address {
  lens: Lens
  /** The second path segment: an application's `no`, a world table, a lane. */
  sub: string
  /** Filters, sort and search, in the order they were set. */
  q: ReadonlyMap<string, string>
}

export type Link = "connecting" | "open" | "lost" | "ended"

export interface Notice {
  id: number
  tone: "info" | "ok" | "warn" | "error"
  text: string
  /** Epoch ms after which it fades; 0 stays until dismissed. */
  until: number
  /** How many times the same words were noticed. */
  times?: number
  /** A root cause (the kernel did not load): newer notices never push it out. */
  pinned?: boolean
}

export interface Model {
  address: Address
  /** The selected row of the current lens (an application id on the desk). */
  selected: number
  link: Link
  carrier: "webtransport" | "websocket" | null
  /** The account's rev as of this session's WELCOME. */
  rev: bigint
  /** From WELCOME: the domains this session may write. */
  writeMask: number
  /** This browser's session (WELCOME's): the account lens marks it, and times its step-up from it. */
  sessionId: number
  /** How many ops are sent and not yet answered. */
  pending: number
  notices: Notice[]
  /** Bumped by the kernel ingest so lenses know rows moved. */
  rows: number
  account: AccountView
  world: WorldView
  outreach: OutreachView
  focus: FocusView
  /** How many board cards are drawn; grows with "more" and with keyboard movement past the end. */
  deskLimit: number
}

/** The focus lens: what one application needs beyond its resident rows. */
export interface FocusView {
  /** The application shown. */
  id: number
  /** Whether its raw listing is unfolded. */
  listing: boolean
  /** The application whose open-fire button is armed (0: none); it disarms by itself after a few seconds. */
  fireArmed: number
  /** The prose field open for editing, or "". */
  edit: string
  /** The application's rev when that editor opened: the save's expect_rev, so a write since is refused, not overwritten. */
  editRev: number
  /** The text that editor opened on. It stays the editor's while open, whatever an agent writes meanwhile. */
  editText: string
}

/** The outreach lens: contacts, and the selected one's threads. */
export interface OutreachView {
  /** How many contacts the list shows; "more" raises it. */
  limit: number
  /** Messages whose bodies are open. */
  open: number[]
  /** "contact" (editing the contact), "new" (a new contact), "draft" (a new message), or "". */
  edit: string
}

/** The world lens: one table of the replica as a sparse grid. */
export interface WorldView {
  /** How many rows the grid shows; "more" raises it. */
  limit: number
  /** The cell being edited, `id:column`, or "new" for a new row. */
  edit: string
  /** The row's rev when that editor opened: a prose save's expect_rev, so an agent's write since is refused, not overwritten. */
  editRev: number
  /** The cell whose citations are open. */
  cites: { id: number; column: string } | null
  /** The text being read, whole, in the reader panel. */
  text: { id: number; column: string } | null
}

/** The account lens: the server's projection, and the ceremony in progress. */
export interface AccountView {
  /** A secret or recovery codes shown once, until dismissed. */
  reveal: { title: string; lines: string[] } | null
  /** TOTP enrollment between begin and confirm. */
  totp: { uri: string; secret: string; svg: string } | null
  /** The action waiting on a step-up, retried once the session is fresh. */
  stepUp: { method: string; params: Record<string, unknown>; mailed?: boolean } | null
  /** Which form is open: "mint", "rename", "trust", "change:<key id>". */
  open: string
  error: string
  /** The trail as shown: security events by default, or the activity view, and how many. */
  audit: { view: "security" | "activity"; limit: number } | null
  /** The access being chosen in the open key form ("mint" or "k<id>"), so a redraw never resets it. */
  masks: { form: string; preset: string; read: number; write: number; mayDelete: boolean } | null
  /** A mint in flight: a second click must not mint a second key whose secret is never shown. */
  minting: boolean
}

/** The shell answers /world/:table and /lanes/:lane only, so those lenses always name one. */
const DEFAULT_SUB: Partial<Record<Lens, string>> = { world: "corporations", lanes: "gym" }

export function parse(path: string, search: string): Address {
  const parts = path.split("/").filter((s) => s !== "")
  const first = parts[0] ?? "desk"
  const lens = (LENSES as readonly string[]).includes(first) ? (first as Lens) : "desk"
  let sub = ""
  try {
    sub = decodeURIComponent(parts[1] ?? "")
  } catch {
    // A malformed escape is no sub at all.
  }
  return { lens, sub: sub === "" ? DEFAULT_SUB[lens] ?? "" : sub, q: new Map(new URLSearchParams(search)) }
}

export function format(a: Address): string {
  const sub = a.sub === "" ? DEFAULT_SUB[a.lens] ?? "" : a.sub
  const path = sub === "" ? `/${a.lens}` : `/${a.lens}/${encodeURIComponent(sub)}`
  const q = new URLSearchParams()
  for (const [k, v] of a.q) if (v !== "") q.set(k, v)
  const s = q.toString()
  return s === "" ? path : `${path}?${s}`
}

export const model: Model = {
  address: parse(location.pathname, location.search),
  selected: 0,
  link: "connecting",
  carrier: null,
  rev: 0n,
  writeMask: 0,
  sessionId: 0,
  pending: 0,
  notices: [],
  rows: 0,
  account: { reveal: null, totp: null, stepUp: null, open: "", error: "", audit: null, masks: null, minting: false },
  world: { limit: 100, edit: "", editRev: 0, cites: null, text: null },
  deskLimit: 30,
  focus: { id: 0, listing: false, fireArmed: 0, edit: "", editRev: 0, editText: "" },
  outreach: { limit: 100, open: [], edit: "" },
}

type Render = () => void
let render: Render = () => {}
let queued = false

/** app.ts installs the one renderer. */
export function onRender(fn: Render): void {
  render = fn
}

export function schedule(): void {
  if (queued) return
  queued = true
  requestAnimationFrame(() => {
    queued = false
    render()
  })
}

export function set(patch: Partial<Model>): void {
  Object.assign(model, patch)
  schedule()
}

/** Move to an address; a filter change replaces the history entry, a lens change pushes one. */
export function go(next: Partial<Address>, replace = false): void {
  const address: Address = { ...model.address, ...next }
  // A new lens starts from its own defaults: the old lens's sub and query mean nothing there.
  if (next.lens !== undefined && next.lens !== model.address.lens) {
    if (next.q === undefined) address.q = new Map()
    if (next.sub === undefined) address.sub = ""
  }
  // The address holds its canonical sub, as parse() gives it: a lens's redirect to its default is then
  // no address change at all, and a view that enters on "" sees what format() prints.
  if (address.sub === "") address.sub = DEFAULT_SUB[address.lens] ?? ""
  const url = format(address)
  if (replace && address.lens === model.address.lens && address.sub === model.address.sub) {
    // A filter change writes the address when input pauses (v1's way): replaceState costs ~0.3 ms, off
    // the frame that answers the keystroke. Any other move writes what was owed first.
    owed = url
    clearTimeout(owing)
    owing = window.setTimeout(settle, ADDRESS_MS)
  } else {
    settle()
    if (url !== here()) history[replace ? "replaceState" : "pushState"](null, "", url)
  }
  set({ address })
}

const ADDRESS_MS = 150
let owed = ""
let owing = 0
const here = (): string => `${location.pathname}${location.search}`
function settle(): void {
  clearTimeout(owing)
  if (owed !== "" && owed !== here()) history.replaceState(null, "", owed)
  owed = ""
}
// A page left mid-search keeps its address for reload and back.
addEventListener("pagehide", settle)

/** One query parameter of the address, set or cleared in place. */
export function query(key: string, value: string): void {
  const q = new Map(model.address.q)
  if (value === "") q.delete(key)
  else q.set(key, value)
  go({ q }, true)
}

let nextNotice = 1

export function notice(tone: Notice["tone"], text: string, ms = tone === "error" ? 0 : 6000, pinned = false): void {
  const until = ms === 0 ? 0 : Date.now() + ms
  // The same words again count up on the notice already shown rather than stacking a copy.
  const same = model.notices.find((n) => n.text === text && n.tone === tone)
  if (same) {
    set({ notices: model.notices.map((n) => (n === same ? { ...n, times: (n.times ?? 1) + 1, until: Math.max(n.until, until) } : n)) })
    if (ms !== 0) setTimeout(expire, ms + 50)
    return
  }
  // Five at most: the oldest unpinned give way; a pinned root cause stays until dismissed.
  const kept = model.notices.filter((n) => n.pinned)
  const rest = model.notices.filter((n) => !n.pinned).slice(-Math.max(0, 4 - kept.length))
  set({ notices: [...kept, ...rest, { id: nextNotice++, tone, text, until, ...(pinned ? { pinned } : {}) }] })
  if (ms !== 0) setTimeout(expire, ms + 50)
}

export function dismiss(id: number): void {
  set({ notices: model.notices.filter((n) => n.id !== id) })
}

function expire(): void {
  const now = Date.now()
  const left = model.notices.filter((n) => n.until === 0 || n.until > now)
  if (left.length !== model.notices.length) set({ notices: left })
}

addEventListener("popstate", () => {
  // Back or forward leaves the entry an owed filter belonged to: it is not written over the new one.
  clearTimeout(owing)
  owed = ""
  set({ address: parse(location.pathname, location.search) })
})
