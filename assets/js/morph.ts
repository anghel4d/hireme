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

/** A template whose every interpolation is escaped; `false`, `null` and `undefined` print nothing. */
export function html(strings: TemplateStringsArray, ...parts: readonly Part[]): Html {
  let out = strings[0] ?? ""
  for (let i = 0; i < parts.length; i++) out += part(parts[i]) + (strings[i + 1] ?? "")
  return new Html(out)
}

/** Markup from this codebase's own constants. Never a value from a row. */
export const trusted = (s: string): Html => new Html(s)

export const EMPTY = new Html("")

/** A boolean attribute, present or absent. */
export const flag = (name: string, on: boolean): Html => new Html(on ? ` ${name}` : "")

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
  if (a.getAttribute(OWN) === "own" && b.getAttribute(OWN) === "own") return
  attributes(a, b)
  if (a instanceof HTMLInputElement || a instanceof HTMLTextAreaElement || a instanceof HTMLSelectElement) {
    // control() has already matched a select's options; a second pass would undo it.
    control(a, b)
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
// A focused control is the user's: the model catches up to it, not the reverse.
function control(a: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, b: Element): void {
  const value = b instanceof HTMLTextAreaElement ? b.value : b.getAttribute("value") ?? ""
  if (a instanceof HTMLSelectElement) {
    children(a, b)
    const chosen = b.querySelector("option[selected]")?.getAttribute("value")
    if (chosen !== undefined && chosen !== null && a !== focused) a.value = chosen
    return
  }
  if (a === focused) return
  if (a instanceof HTMLInputElement && (a.type === "checkbox" || a.type === "radio")) {
    a.checked = b.hasAttribute("checked")
    return
  }
  if (a.value !== value) a.value = value
}
