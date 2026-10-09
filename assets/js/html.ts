// Templates that escape everything, and a morph that changes only what
// differs so focus, selection, scroll, and half-typed text survive.

const ESC: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }

function esc(v: unknown): string {
  return String(v ?? "").replace(/[&<>"']/g, (c) => ESC[c] ?? c)
}

/** Marks a string as already-safe HTML. */
export class Raw {
  constructor(readonly html: string) {}
}

export function raw(html: string): Raw {
  return new Raw(html)
}

/** Tagged template: interpolations are escaped unless Raw or an array of Raw. */
export function h(strings: TemplateStringsArray, ...values: unknown[]): Raw {
  let out = ""
  strings.forEach((s, i) => {
    out += s
    if (i < values.length) out += part(values[i])
  })
  return new Raw(out)
}

function part(v: unknown): string {
  if (v instanceof Raw) return v.html
  if (Array.isArray(v)) return v.map(part).join("")
  if (v === null || v === undefined || v === false) return ""
  return esc(v)
}

const EMPTY = new Raw("")
export function when(cond: unknown, then: () => Raw): Raw {
  return cond ? then() : EMPTY
}

// The HTML each target was last patched to. Only morph changes those
// subtrees, so the same HTML again would patch nothing.
const drawn = new WeakMap<Element, string>()

/** Patch `target`'s children to match `html`, keeping nodes that already match. */
export function morph(target: Element, html: Raw): void {
  if (drawn.get(target) === html.html) return
  drawn.set(target, html.html)
  const tpl = document.createElement("template")
  tpl.innerHTML = html.html
  patchChildren(target, tpl.content)
}

/**
 * A keyed set of sibling elements, each one patched alone and only when its
 * own HTML changed. A board of cards where one card changes then costs one
 * card's parse and patch, not a walk of every card.
 */
export class Keyed {
  private readonly els = new Map<number, { el: Element; html: string }>()
  private readonly tpl = document.createElement("template")

  /** `ordered`: the children follow the items' order (a list); otherwise they place themselves (cards). */
  constructor(private readonly parent: Element, private readonly ordered = false) {}

  /**
   * Make the children exactly `items` (key, single-root HTML). Everything that changed is parsed in
   * one pass. (Reusing a departed card's element for an arriving one was
   * measured: patching every node of it costs more than inserting fresh.)
   */
  set(items: readonly [number, Raw][]): void {
    const live = new Set<number>()
    const changed: [number, string][] = []
    for (const [key, html] of items) {
      live.add(key)
      if (this.els.get(key)?.html !== html.html) changed.push([key, html.html])
    }
    const gone: Element[] = []
    for (const [key, { el }] of this.els) {
      if (live.has(key)) continue
      gone.push(el)
      this.els.delete(key)
    }
    if (changed.length > 0) {
      this.tpl.innerHTML = changed.map(([, html]) => html).join("")
      const fresh = Array.from(this.tpl.content.children)
      changed.forEach(([key, html], i) => {
        const want = fresh[i]
        if (!want) return
        const have = this.els.get(key)?.el
        if (have) patchNode(have, want)
        else this.parent.append(want)
        this.els.set(key, { el: have ?? want, html })
      })
    }
    for (const el of gone) el.remove()
    if (!this.ordered) return
    let next = this.parent.firstElementChild
    for (const [key] of items) {
      const el = this.els.get(key)?.el
      if (!el) continue
      if (el !== next) this.parent.insertBefore(el, next)
      next = el.nextElementSibling
    }
  }
}

// The HTML each element with an id was last patched to.
const same = new WeakMap<ChildNode, string>()

function patchChildren(target: Node, from: Node): void {
  const want = Array.from(from.childNodes)
  const have = Array.from(target.childNodes)
  const byId = new Map<string, Element>()
  for (const n of have) if (n instanceof Element && n.id) byId.set(n.id, n)

  let cursor: ChildNode | null = target.firstChild
  for (const w of want) {
    let match: ChildNode | null = null
    if (w instanceof Element && w.id && byId.has(w.id)) {
      match = byId.get(w.id) ?? null
    } else if (cursor && sameKind(cursor, w) && !(cursor instanceof Element && cursor.id)) {
      match = cursor
    }

    // An innermost element with an id, last patched to this very HTML, is
    // left alone, subtree and all; new nodes move over from the template.
    const html = w instanceof Element && w.id && !w.querySelector("[id]") ? w.outerHTML : null
    if (match) {
      if (match !== cursor) target.insertBefore(match, cursor)
      if (html === null || same.get(match) !== html) patchNode(match, w)
      if (html !== null) same.set(match, html)
      cursor = match.nextSibling
    } else {
      target.insertBefore(w, cursor)
      if (html !== null) same.set(w, html)
    }
  }
  while (cursor) {
    const next: ChildNode | null = cursor.nextSibling
    cursor.remove()
    cursor = next
  }
}

function sameKind(a: Node, b: Node): boolean {
  return a.nodeType === b.nodeType && a.nodeName === b.nodeName
}

function patchNode(have: ChildNode, want: ChildNode): void {
  if (have.nodeType === Node.TEXT_NODE) {
    if (have.nodeValue !== want.nodeValue) have.nodeValue = want.nodeValue
    return
  }
  if (!(have instanceof Element) || !(want instanceof Element)) return

  for (const attr of Array.from(have.attributes)) {
    if (!want.hasAttribute(attr.name)) have.removeAttribute(attr.name)
  }
  for (const attr of Array.from(want.attributes)) {
    if (have.getAttribute(attr.name) !== attr.value) have.setAttribute(attr.name, attr.value)
  }

  // A slot's children are drawn by their own morph.
  if (have.hasAttribute("data-slot")) return

  // A field the person is typing in keeps its text.
  if (have instanceof HTMLInputElement && want instanceof HTMLInputElement) {
    if (document.activeElement !== have && have.value !== want.value) have.value = want.value
    if (have.checked !== want.checked) have.checked = want.checked
    return
  }
  if (have instanceof HTMLTextAreaElement && want instanceof HTMLTextAreaElement) {
    if (document.activeElement !== have && have.value !== want.value) have.value = want.value
    return
  }
  if (have instanceof HTMLSelectElement && want instanceof HTMLSelectElement) {
    patchChildren(have, want)
    if (have.value !== want.value) have.value = want.value
    return
  }

  patchChildren(have, want)
}
