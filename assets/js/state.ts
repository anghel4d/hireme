// The model: the only mutable state on the page.
//
// Rows live in the kernel; this file holds what the kernel does not: where
// the operator is (the address), what is selected, what the connection is
// doing, drafts of fields being typed, and notices. A change goes through
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
}

export interface Model {
  address: Address
  /** The selected row of the current lens (an application id on the desk). */
  selected: number
  link: Link
  carrier: "webtransport" | "websocket" | null
  /** The last rev the page has applied. */
  rev: bigint
  /** From WELCOME. */
  readMask: number
  writeMask: number
  mayDelete: boolean
  leased: boolean
  /** Ops sent and not yet settled, by op id. */
  pending: number
  /** What is being typed, keyed `table:id:column`; a NACK keeps the draft, an ACK drops it. */
  drafts: Map<string, string>
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
  /** The application id these were fetched for. */
  id: number
  listing: { text: string; total: number } | null
  messages: Record<string, unknown>[]
  contact: Record<string, unknown> | null
  corporation: Record<string, unknown> | null
  /** The prose field open for editing, or "". */
  edit: string
  error: string
}

/** The outreach lens: contacts, and the selected one's threads. */
export interface OutreachView {
  key: string
  contacts: Record<string, unknown>[]
  next: unknown
  messages: Record<string, unknown>[]
  /** Message bodies read so far, by message id. */
  bodies: Map<number, string>
  /** "contact" (editing the contact), "new" (a new contact), "draft" (a new message), or "". */
  edit: string
  loading: boolean
  error: string
}

/** The world lens: one server-side table as a sparse grid, paged by keyset. */
export interface WorldView {
  /** The table, sort and search the rows were fetched for; a change refetches. */
  key: string
  rows: Record<string, unknown>[]
  next: unknown
  loading: boolean
  /** The cell being edited, `id:column`, or "new" for a new row. */
  edit: string
  /** The citations of one cell. */
  cites: { id: number; column: string; list: Record<string, unknown>[] } | null
  /** Deferred text being read. */
  text: { id: number; column: string; body: string; total: number } | null
  error: string
}

/** The account lens: the server's projection, and the ceremony in progress. */
export interface AccountView {
  overview: Record<string, unknown> | null
  loading: boolean
  /** A secret or recovery codes shown once, until dismissed. */
  reveal: { title: string; lines: string[] } | null
  /** TOTP enrollment between begin and confirm. */
  totp: { uri: string; secret: string; svg: string } | null
  /** The action waiting on a step-up, retried once the session is fresh. */
  stepUp: { method: string; params: Record<string, unknown> } | null
  /** Which form is open: "mint", "rename", "trust", "change:<key id>". */
  open: string
  error: string
  audit: Record<string, unknown>[] | null
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
  readMask: 0,
  writeMask: 0,
  mayDelete: false,
  leased: false,
  pending: 0,
  drafts: new Map(),
  notices: [],
  rows: 0,
  account: { overview: null, loading: false, reveal: null, totp: null, stepUp: null, open: "", error: "", audit: null },
  world: { key: "", rows: [], next: null, loading: false, edit: "", cites: null, text: null, error: "" },
  deskLimit: 120,
  focus: { id: 0, listing: null, messages: [], contact: null, corporation: null, edit: "", error: "" },
  outreach: { key: "", contacts: [], next: null, messages: [], bodies: new Map(), edit: "", loading: false, error: "" },
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
  const url = format(address)
  if (url !== `${location.pathname}${location.search}`) {
    if (replace) history.replaceState(null, "", url)
    else history.pushState(null, "", url)
  }
  set({ address })
}

/** One query parameter of the address, set or cleared in place. */
export function query(key: string, value: string): void {
  const q = new Map(model.address.q)
  if (value === "") q.delete(key)
  else q.set(key, value)
  go({ q }, true)
}

let nextNotice = 1

export function notice(tone: Notice["tone"], text: string, ms = tone === "error" ? 0 : 6000): void {
  const until = ms === 0 ? 0 : Date.now() + ms
  set({ notices: [...model.notices.slice(-4), { id: nextNotice++, tone, text, until }] })
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

export const draftKey = (table: string, id: number, column: string): string => `${table}:${id}:${column}`

addEventListener("popstate", () => set({ address: parse(location.pathname, location.search) }))
