// The atlas: every country and city in the world's places, ordered for the
// person behind the account and shown as the figures themselves. Who that
// person is and which figures matter to them are the one `me` row (the Me
// lens, or an agent through the MCP); the route, the language match and
// the order are the kernel's (`atlas`). Nothing personal is in source. A
// figure is the place's own metric with its as-of day and citations, as in
// World, and the order only sorts: it never hides a number.

import type { View } from "../app.ts"
import { TABLES } from "../gen/schema.ts"
import { atlas, ids, meId, page, row, value } from "../kernel.ts"
import { EMPTY, html, type Html } from "../morph.ts"
import { model, query } from "../state.ts"
import { FIGURES, figureName, list } from "./me.ts"
import { cited, cites, label, rowHref, views } from "./world.ts"

type Fit = { id: number; kind: string; name: string; iso2: string | null; country: string | null; languages: string | null; route: string; speaks: boolean | null; preferred: boolean; avoided: boolean; fit: number | null }
type Doc = { known: boolean; recipe: { key: string; weight: number }[]; unknown: string[]; places: Fit[] }

const PLACES = TABLES.places
const PAGE = 100
/** The facts of the me row the summary names, in order. */
const FACTS: [string, string][] = [["citizenships", "Citizenships"], ["work_permits", "Work permits or residence held"], ["field", "Field"], ["prefer", "Countries wanted"], ["avoid", "Countries never"]]
/** What a route means, from the person's citizenships and permits and the place's no-permit list (kernel atlas.rs). */
const ROUTE: Record<string, [string, string]> = {
  citizen: ["citizen", "You hold this country's citizenship"],
  permit_held: ["permit held", "You already hold a work permit or a residence right here"],
  free: ["no permit needed", "One of your citizenships needs no work permit here"],
  needs_permit: ["needs a permit", "None of your citizenships is on this place's no-permit list"],
  unknown: ["unknown", "Set your citizenships in Me; or this place's country and no-permit list are not known yet"],
}

function you(d: Doc): Html {
  if (!d.known)
    return html`<section class="card" data-key="me"><h2>You</h2>
      <p class="warn" data-key="none">Nothing about you yet: every route below reads unknown until your citizenships are set. <a href="/me" data-nav>Fill in Me</a>, or ask an agent to (<code>put me</code> over the MCP, with a key that writes corpus).</p>
    </section>`
  const notes = String(row("me", meId())?.notes ?? "")
  const langs = [...ids("languages")].map((id) => String(value("languages", id, "code") ?? "")).sort().join(" ")
  return html`<section class="card" data-key="me"><h2>You <a class="ghost" href="/me" data-nav>Edit in Me</a></h2>
    <p class="facts">${FACTS.map(([col, text]) => (list(col).length > 0 ? html`<span data-key="${col}"><span class="muted">${text}</span> ${list(col).join(" ")}</span>` : EMPTY))}${langs ? html`<span data-key="languages"><span class="muted">Languages</span> ${langs}</span>` : EMPTY}</p>
    ${notes ? html`<p class="notes muted" data-key="notes">${notes}</p>` : EMPTY}
  </section>`
}

function recipe(d: Doc): Html {
  return html`<section class="card" data-key="recipe"><h2>What matters <a class="ghost" href="/me" data-nav>Edit in Me</a></h2>
    ${d.recipe.length === 0
      ? html`<p class="hint">No weights yet: places are in route order, wanted first and never last. Pick the figures that matter to you in Me and weight them; a negative weight ranks a lower figure higher.</p>`
      : html`<p class="terms">${d.recipe.map((r) => html`<span class="term" data-key="${r.key}" title="${r.key}">${figureName(r.key)} <b>×${String(r.weight)}</b></span>`)}</p>`}
    ${d.unknown.length === 0 ? EMPTY : html`<p class="hint">Not a figure of places, so ignored: ${d.unknown.join(", ")}</p>`}
  </section>`
}

function view(): Html {
  const d = atlas() as Doc | null
  if (!d) return html`<p class="empty">Loading…</p>`
  const q = model.address.q
  const kind = q.get("kind") ?? ""
  const search = (q.get("q") ?? "").toLowerCase()
  const sort = q.get("sort") ?? ""
  const limit = PAGE * Number(q.get("more") ?? 1)
  const weighted = d.recipe.flatMap((r) => FIGURES.filter((c) => c.name === r.key))
  // The figure columns: the weighted ones, a declared group, or all; with nothing weighted, the economy.
  const pick = q.get("cols") ?? (weighted.length > 0 ? "weighted" : "economy")
  const figures = pick === "all" ? FIGURES : pick === "weighted" ? weighted : FIGURES.filter((c) => c.group === pick)
  const groups = [...new Set(FIGURES.flatMap((c) => (c.group === null ? [] : [c.group])))]
  // The kernel's order, or the replica's by one figure; the rank is always the kernel's.
  const rank = new Map(d.places.map((f, i) => [f.id, i + 1]))
  const byId = new Map(d.places.map((f) => [f.id, f]))
  const ordered = sort === "" ? d.places : page({ table: "places", cols: ["id"], order: [sort.replace(/^-/, ""), sort.startsWith("-") ? "desc" : "asc"] }, 100_000).rows.flatMap((r) => byId.get(Number(r.id)) ?? [])
  const kept = ordered.filter((f) => (kind === "" || f.kind === kind) && (search === "" || f.name.toLowerCase().startsWith(search)))
  const shown = kept.slice(0, limit)
  const cols = ["id", "rev", "name", ...figures.flatMap((c) => [c.name, `${c.name}_on`])]
  // The page's rows, a hundred ids a find (its `in` is bounded).
  const rows = new Map(Array.from({ length: Math.ceil(shown.length / PAGE) }, (_, i) => shown.slice(i * PAGE, (i + 1) * PAGE)).flatMap((part) =>
    page({ table: "places", cols, where: { id: { in: part.map((f) => f.id) } } }, part.length).rows.map((r) => [Number(r.id), r] as const)))
  const c = (q.get("cites") ?? "").split(":")
  const tab = (k: string, text: string): Html =>
    html`<a href="/world/atlas${k === "" ? "" : `?kind=${k}`}" data-nav data-key="k${k}" class="${kind === k ? "on" : ""}"${kind === k ? html` aria-current="page"` : EMPTY}>${text}</a>`
  const header = (col: string, text: string, title: string): Html => {
    const dir = sort === col ? "asc" : sort === `-${col}` ? "desc" : ""
    return html`<th scope="col" data-key="${col}"${dir ? html` aria-sort="${dir === "asc" ? "ascending" : "descending"}"` : EMPTY}>
      <button type="button" class="ghost" data-act="sort" data-col="${col}" title="${title}">${text}${dir === "asc" ? " ↑" : dir === "desc" ? " ↓" : ""}</button></th>`
  }
  return html`<div class="atlas">
    <div class="toolbar" data-key="views">${views()}</div>
    ${you(d)}${recipe(d)}
    <div class="toolbar" data-key="toolbar">
      <nav class="kinds" aria-label="Which places">${tab("", "all")}${tab("country", "countries")}${tab("city", "cities")}</nav>
      <input type="search" class="search" placeholder="name starts with…" value="${q.get("q") ?? ""}" data-act="search" data-on="input" data-bound aria-label="Search places">
      <span class="muted">${kept.length} place${kept.length === 1 ? "" : "s"}</span>
    </div>
    <div class="chips" role="group" aria-label="Which figures" data-key="groups">${[["weighted", "Weighted"], ...groups.map((g) => [g, g.charAt(0).toUpperCase() + g.slice(1)]), ["all", "All figures"]].map(([x, text]) =>
      html`<button type="button" class="chip${x === pick ? " on" : ""}" aria-pressed="${String(x === pick)}" data-act="cols" data-v="${x}" data-key="${x}">${text}</button>`)}</div>
    ${c.length === 2 ? cites(PLACES, { id: Number(c[0]), column: c[1]! }) : EMPTY}
    ${d.places.length === 0 ? html`<p class="empty">No places yet. Agents add countries and cities through the MCP (<code>put places</code>); you can add one in World.</p>` : html`<div class="grid-wrap" data-key="grid">
      <table class="grid sparse">
        <thead><tr><th scope="col" class="id" title="Your order: wanted first, never last, then by what matters">#</th><th scope="col" class="anchor" data-key="name"><span title="name">Place</span></th>
          <th scope="col" data-key="route"><span title="From your citizenships and permits and the place's no-permit list">Route</span></th>
          <th scope="col" data-key="language"><span title="What the place speaks (a city, its country's); ✓ when one of them is yours">Languages</span></th>
          ${figures.map((f) => header(f.name, label(f.name), `${f.name}: sort`))}</tr></thead>
        <tbody>${shown.map((f) => {
          const r = rows.get(f.id)
          return html`<tr data-key="p${f.id}" data-id="${f.id}" class="${f.avoided ? "avoided" : ""}">
            <th scope="row" class="id">${String(rank.get(f.id) ?? "")}</th>
            <td data-key="name"><a href="${rowHref("places", f.id, { name: f.name })}" data-nav title="Open in World">${f.name}</a> <span class="muted">${f.kind === "city" ? f.country ?? "" : f.iso2 ?? ""}</span>${
              f.preferred ? html` <span class="tag" title="A country you want: ordered first">wanted</span>` : EMPTY}${f.avoided ? html` <span class="tag" title="A country you never want: ordered last">never</span>` : EMPTY}</td>
            <td data-key="route"><span class="tag route-${f.route}" title="${ROUTE[f.route]?.[1] ?? ""}">${ROUTE[f.route]?.[0] ?? f.route}</span></td>
            <td data-key="language">${(f.languages ?? "").split("\u001f").join(", ")}${f.speaks ? html` <span title="Speaks one of your languages">✓</span>` : EMPTY}</td>
            ${figures.map((col) => html`<td data-key="${col.name}" class="metric">${r ? cited(col, r, r[col.name]) : EMPTY}</td>`)}</tr>`
        })}</tbody>
      </table>
    </div>
    ${kept.length > shown.length ? html`<button type="button" data-act="more">Show ${PAGE} more</button>` : EMPTY}`}
  </div>`
}

const lens: View = {
  title: "Atlas",
  view,
  act(name, el, ev) {
    switch (name) {
      case "cols":
        return query("cols", el.dataset.v ?? "")
      case "sort": {
        const col = el.dataset.col ?? ""
        const s = model.address.q.get("sort") ?? ""
        return query("sort", s === col ? `-${col}` : s === `-${col}` ? "" : col)
      }
      case "search":
        return query("q", (el as HTMLInputElement).value)
      case "more":
        return query("more", String(Number(model.address.q.get("more") ?? 1) + 1))
      case "cites":
        ev.stopPropagation()
        return query("cites", `${el.dataset.id ?? ""}:${el.dataset.col ?? ""}`)
      case "close-panel":
        return query("cites", "")
    }
  },
  key(ev) {
    if (ev.key !== "Escape" || !model.address.q.has("cites")) return false
    query("cites", "")
    return true
  },
}

export default lens
