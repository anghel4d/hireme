// Escaping templates and a keyed DOM morph.
//
// Every lens is a function from the model to `Html`; `morph` makes the
// live DOM match it without rebuilding what did not change. Text an agent
// wrote (a listing, a corporation's culture, a message body) reaches the
// page only through `html`, which escapes every interpolation, and links
// only through `href`, which refuses every scheme but http(s) and mailto.
//
// Children with `data-key` are matched by key across the whole parent, so
// a re-ranked board moves rows instead of rewriting them; unkeyed children
// are matched by position and tag. A subtree marked `data-morph="own"` is
// left alone after it first lands: its owner writes it value by value.
//
// Focus is a requirement: the focused control keeps its value, caret and
// selection while the model catches up, and a move that would blur it
// (insertBefore is a remove and an insert) is undone afterwards.

const ESC: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }

export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ESC[c] ?? c)
}

/** Markup that is already safe: built by `html`, or vouched for by `trusted`. */
export class Html {
  constructor(readonly text: string) {}
  toString(): string {
    return this.text
  }
}

export type Part = Html | string | number | bigint | boolean | null | undefined | readonly Part[]

function part(p: Part): string {
  if (p instanceof Html) return p.text
  if (p === null || p === undefined || p === false || p === true) return ""
  if (Array.isArray(p)) return p.map(part).join("")
  return esc(String(p))
}

/** A template whose every interpolation is escaped; booleans, `null` and `undefined` print nothing (so `x && html`…``
 * reads as a condition): a boolean attribute value is interpolated as `String(b)`. */
export function html(strings: TemplateStringsArray, ...parts: readonly Part[]): Html {
  let out = strings[0] ?? ""
  for (let i = 0; i < parts.length; i++) out += part(parts[i]) + (strings[i + 1] ?? "")
  return new Html(out)
}

/** A form's entries as they stand, to compare with later. */
export function entries(form: HTMLFormElement): string {
  return JSON.stringify([...new FormData(form)].map(([k, x]) => [k, String(x)]))
}

/** Clears a form after its write is answered, unless it left the page or someone typed the next entry meanwhile. */
export function resetIfUnchanged(form: HTMLFormElement, before: string): void {
  if (form.isConnected && entries(form) === before) form.reset()
}

/** Markup from this codebase's own constants. Never a value from a row. */
export const trusted = (s: string): Html => new Html(s)

export const EMPTY = new Html("")

/** A boolean attribute, present or absent. */
export const flag = (name: string, on: boolean): Html => new Html(on ? ` ${name}` : "")

/** A host as people read it: each punycode label (xn--) decoded (RFC 3492), so xn--mller-kva.example is müller.example. */
export function unicodeHost(host: string): string {
  const u = host.split(".").map((l) => (l.startsWith("xn--") ? punyDecode(l.slice(4)) ?? l : l)).join(".")
  // In doubt (a decode the browser's own URL parser would not give back as this host), the xn-- form stands.
  try {
    return u === host || new URL(`http://${u}/`).hostname === host.toLowerCase() ? u : host
  } catch {
    return host
  }
}
/** One punycode label's Unicode (RFC 3492 decode, its xn-- prefix already off), or null when it is not punycode. */
export function punyDecode(s: string): string | null {
  const out: number[] = []
  const dash = s.lastIndexOf("-")
  for (const ch of dash > 0 ? s.slice(0, dash) : "") out.push(ch.charCodeAt(0))
  let n = 128, i = 0, bias = 72, p = dash > 0 ? dash + 1 : 0
  while (p < s.length) {
    const old = i
    for (let w = 1, k = 36; ; k += 36) {
      if (p >= s.length) return null
      const c = s.charCodeAt(p++)
      const d = c >= 48 && c <= 57 ? c - 22 : c >= 97 && c <= 122 ? c - 97 : c >= 65 && c <= 90 ? c - 65 : -1
      if (d < 0) return null
      i += d * w
      const t = k <= bias ? 1 : k >= bias + 26 ? 26 : k - bias
      if (d < t) break
      w *= 36 - t
    }
    const len = out.length + 1
    let delta = old === 0 ? Math.floor((i - old) / 700) : (i - old) >> 1
    delta += Math.floor(delta / len)
    let k = 0
    for (; delta > 455; k += 36) delta = Math.floor(delta / 35)
    bias = k + Math.floor((36 * delta) / (delta + 38))
    n += Math.floor(i / len)
    i %= len
    out.splice(i++, 0, n)
  }
  return String.fromCodePoint(...out)
}

/** An href for a value someone else wrote: http(s), mailto and same-origin paths only. */
export function href(url: string | null | undefined): string {
  if (url === null || url === undefined || url === "") return "#"
  // A backslash or a control character lets a browser read "/\\host" or "/<tab>/host" as another origin.
  if (/[\\\u0000-\u001f\u007f]/.test(url)) return "#"
  if (url.startsWith("/") && !url.startsWith("//")) return url
  try {
    const u = new URL(url)
    return u.protocol === "https:" || u.protocol === "http:" || u.protocol === "mailto:" ? u.href : "#"
  } catch {
    return "#"
  }
}

const KEY = "data-key"
const OWN = "data-morph"

type Movable = ParentNode & Node & { moveBefore?: (node: Node, child: Node | null) => void }

const keyOf = (n: Node): string | null => (n.nodeType === Node.ELEMENT_NODE ? (n as Element).getAttribute(KEY) : null)

const sameKind = (a: Node, b: Node): boolean => a.nodeType === b.nodeType && a.nodeName === b.nodeName

// Chrome's moveBefore keeps focus, selection and running animations across a move.
function place(into: Movable, node: Node, before: Node | null): void {
  if (into.moveBefore && node.parentNode === into) into.moveBefore(node, before)
  else into.insertBefore(node, before)
}

/**
 * The control that had focus when this morph began. A keyed move without
 * moveBefore blurs it mid-morph, so "is this the user's field?" is asked of
 * this, never of document.activeElement.
 */
let focused: Element | null = null

/** Make `target`'s children match `next`. */
export function morph(target: Element, next: Html): void {
  const active = document.activeElement
  focused = active
  const field = active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement ? active : null
  const caret = field ? [field.selectionStart, field.selectionEnd, field.selectionDirection] as const : null
  const tpl = document.createElement("template")
  tpl.innerHTML = next.text
  children(target, tpl.content)
  focused = null
  if (active instanceof HTMLElement && active !== document.activeElement && active.isConnected) {
    active.focus({ preventScroll: true })
    if (field && caret) {
      try {
        field.setSelectionRange(caret[0], caret[1], caret[2] ?? undefined)
      } catch {
        // Not every input type has a selection (number, email).
      }
    }
  }
}

function children(into: Movable, from: ParentNode): void {
  const wanted = new Set<string>()
  for (let n = from.firstChild; n; n = n.nextSibling) {
    const k = keyOf(n)
    if (k !== null) wanted.add(k)
  }
  const keyed = new Map<string, Element>()
  for (let c = into.firstChild; c; c = c.nextSibling) {
    const k = keyOf(c)
    if (k !== null && wanted.has(k) && !keyed.has(k)) keyed.set(k, c as Element)
  }
  let cur = into.firstChild
  for (let n = from.firstChild; n; ) {
    const after = n.nextSibling
    // An old keyed child the new tree does not want, or one already used, is dropped where it stands.
    while (cur) {
      const k = keyOf(cur)
      if (k === null || keyed.get(k) === cur) break
      const gone = cur
      cur = cur.nextSibling
      into.removeChild(gone)
    }
    const k = keyOf(n)
    let match: Node | null = null
    if (k !== null) {
      const old = keyed.get(k)
      if (old && sameKind(old, n)) {
        match = old
        keyed.delete(k)
      }
    } else if (cur && keyOf(cur) === null && sameKind(cur, n)) {
      match = cur
    }
    if (match) {
      if (match === cur) cur = cur.nextSibling
      else place(into, match, cur)
      patch(match, n)
    } else {
      into.insertBefore(n, cur)
    }
    n = after
  }
  while (cur) {
    const gone = cur
    cur = cur.nextSibling
    into.removeChild(gone)
  }
}

function patch(old: Node, next: Node): void {
  if (old.nodeType !== Node.ELEMENT_NODE) {
    if (old.nodeValue !== next.nodeValue) old.nodeValue = next.nodeValue
    return
  }
  const a = old as Element
  const b = next as Element
  // An owned subtree keeps its children: one that just became owned (a lens parking) takes the new attributes only.
  if (b.getAttribute(OWN) === "own") {
    if (a.getAttribute(OWN) !== "own") attributes(a, b)
    return
  }
  // A keyed element that is node for node what it was (a row a sort moved) stands: one native compare.
  if (a.hasAttribute(KEY) && a.isEqualNode(b)) return
  // Whether the user changed this control, read before the attributes move its default.
  // `data-bound` marks a control that mirrors the address (a search box): the model is its truth.
  const edited =
    b.hasAttribute("data-bound") ? false
    : a instanceof HTMLInputElement ? (a.type === "checkbox" || a.type === "radio" ? a.checked !== a.defaultChecked : a.value !== a.defaultValue)
    : a instanceof HTMLTextAreaElement ? a.value !== a.defaultValue
    : a instanceof HTMLSelectElement ? a.value !== defaultChoice(a)
    : false
  attributes(a, b)
  if (a instanceof HTMLInputElement || a instanceof HTMLTextAreaElement || a instanceof HTMLSelectElement) {
    // control() has already matched a select's options; a second pass would undo it.
    control(a, b, edited)
    return
  }
  children(a, b)
}

function attributes(a: Element, b: Element): void {
  // A <details> the user opened or closed keeps that state: `open` is theirs once it has landed.
  const theirs = a.localName === "details" ? "open" : null
  for (let i = a.attributes.length - 1; i >= 0; i--) {
    const name = a.attributes[i]?.name
    if (name !== undefined && name !== theirs && !b.hasAttribute(name)) a.removeAttribute(name)
  }
  for (const { name, value } of Array.from(b.attributes)) {
    if (name !== theirs && a.getAttribute(name) !== value) a.setAttribute(name, value)
  }
}

// The value attribute is only the default; the live value is a property.
// A control the user is in, or has typed into and left, is theirs: a redraw
// (a PATCH, the minute's TICK) moves its default, never what they typed.
/** What a select shows on a fresh page: its option marked selected, else its first. An option's value is its text when it has no value attribute. */
function defaultChoice(a: HTMLSelectElement): string {
  return (Array.from(a.options).find((o) => o.defaultSelected) ?? a.options[0])?.value ?? ""
}

function control(a: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, b: Element, edited: boolean): void {
  const value = b instanceof HTMLTextAreaElement ? b.value : b.getAttribute("value") ?? ""
  if (a instanceof HTMLSelectElement) {
    // The user's choice, read before the options are matched (matching moves the selected attributes).
    const theirs = a.value
    children(a, b)
    // A select the user changed (or is in) keeps their choice, like an edited input: a redraw
    // must not turn "Expires after: 30 days" back into "never".
    if (a === focused || edited) {
      if (Array.from(a.options).some((o) => o.value === theirs)) a.value = theirs
      return
    }
    // With no option marked selected, a fresh page shows the first: so does a redraw.
    a.value = defaultChoice(a)
    return
  }
  if (a instanceof HTMLTextAreaElement) a.defaultValue = value
  if (a === focused || edited) return
  if (a instanceof HTMLInputElement && (a.type === "checkbox" || a.type === "radio")) {
    a.checked = b.hasAttribute("checked")
    a.defaultChecked = a.checked
    return
  }
  if (a.value !== value) a.value = value
}
