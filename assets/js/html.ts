// Templates that escape everything, and a morph that changes only what
// differs so focus, selection, scroll, and half-typed text survive.

const ESC: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }

export function esc(v: unknown): string {
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

export function join(parts: Raw[]): Raw {
  return new Raw(parts.map((p) => p.html).join(""))
}

const EMPTY = new Raw("")
export function when(cond: unknown, then: () => Raw): Raw {
  return cond ? then() : EMPTY
}

/** Patch `target`'s children to match `html`, keeping nodes that already match. */
export function morph(target: Element, html: Raw): void {
  const tpl = document.createElement("template")
  tpl.innerHTML = html.html
  patchChildren(target, tpl.content)
}

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

    if (match) {
      if (match !== cursor) target.insertBefore(match, cursor)
      patchNode(match, w)
      cursor = match.nextSibling
    } else {
      const fresh = w.cloneNode(true)
      target.insertBefore(fresh, cursor)
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
