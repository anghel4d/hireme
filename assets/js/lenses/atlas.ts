// The atlas: the charted places scored against the operator's own
// passports, languages and weights. The fit (route, language, seven parts,
// the weighted sum, presets) is the kernel's only copy (`atlas`); this
// lens draws it; the inputs (passports, languages, weights) are the
// operator's own and are set in Me. No passport or language is in source.

import type { View } from "../app.ts"
import { failed, atlas, putMe, type Input } from "../kernel.ts"
import { EMPTY, flag, html, type Html } from "../morph.ts"
import { model, query } from "../state.ts"

/** A place's fit; `fit` is null for a place with no part the kernel can score, and a part may be null too. */
type Fit = { id: number; name: string; iso2: string | null; kind: string; route: string; speaks: boolean; fit: number | null; parts: Record<string, number | null>; labeled: boolean | null }
type Doc = { parts: string[]; weights: number[]; presets: Record<string, number[]>; places: Fit[] }

/** What a route means for you, from your citizenships and the place's work-permit list (kernel atlas.rs). */
const ROUTE: Record<string, [string, string]> = {
  citizen: ["citizen", "You hold this country's citizenship"],
  free: ["no permit needed", "One of your citizenships needs no work permit here"],
  permit: ["needs a permit", "None of your citizenships is on this place's no-permit list"],
  unknown: ["visa unknown", "No citizenship or work-permit figures for this place yet"],
}

function meter(x: number | null, max: number): Html {
  if (x === null) return html`<span class="muted" title="No figure for this place yet">—</span>`
  // A figure is its bar and its number (a zero is a figure, not a gap: its bar is empty, its number 0).
  return html`<meter min="0" max="${max}" value="${x}"></meter> ${Math.round(max === 1 ? x * 100 : x)}`
}

function view(): Html {
  const preset = model.address.q.get("preset") ?? ""
  const d = atlas(preset) as Doc | null
  if (!d) return html`<p class="empty">Loading…</p>`
  const kind = model.address.q.get("kind") ?? ""
  const places = kind === "" ? d.places : d.places.filter((p) => p.kind === kind)
  return html`<div class="atlas">
    <section class="card" data-key="weights"><h2>Weights</h2>
      <div class="row">
        <label>Preset <select data-act="preset" data-on="change" data-bound><option value="">your weights</option>
          ${Object.keys(d.presets).map((p) => html`<option${flag("selected", p === preset)}>${p}</option>`)}</select></label>
        ${preset !== "" ? html`<button type="button" data-act="adopt" data-preset="${preset}">Use ${preset} as mine</button>` : EMPTY}
      </div>
      <p class="muted">${d.parts.map((p, i) => `${p} ${(preset === "" ? d.weights : d.presets[preset])?.[i] ?? 1}`).join(" · ")}${preset === "" ? html` · <a href="/me" data-nav>set in Me</a>` : EMPTY}</p>
    </section>
    <div class="toolbar"><nav class="subtabs">${[["", "all"], ["country", "countries"], ["city", "cities"]].map(([k, l]) => html`<a href="/atlas?${new URLSearchParams({ ...(preset ? { preset } : {}), ...(k ? { kind: k! } : {}) }).toString()}" data-nav class="${kind === k ? "on" : ""}" data-key="k${k}">${l}</a>`)}</nav>
      <span class="muted">${places.length} charted</span></div>
    ${places.length === 0 ? html`<p class="empty">No charted places. A place is charted when its atlas_position is set; agents fill places through the MCP.</p>` : html`<div class="grid-wrap"><table class="grid atlas-grid">
      <thead><tr><th scope="col">Place</th><th scope="col">Route</th><th scope="col">Fit</th>${d.parts.map((p) => html`<th scope="col">${p}</th>`)}</tr></thead>
      <tbody>${places.map((p) => html`<tr data-key="p${p.id}" class="route-${p.route}">
        <th scope="row">${p.name} <span class="muted">${p.iso2 ?? ""}</span></th>
        <td><span class="tag" title="${ROUTE[p.route]?.[1] ?? ""}">${ROUTE[p.route]?.[0] ?? p.route}</span>${p.speaks ? html` <span class="tag" title="You speak a language spoken here">speaks your language</span>` : EMPTY}</td>
        <td>${meter(p.fit, 100)}</td>
        ${d.parts.map((part) => html`<td>${meter(p.parts[part] ?? null, 1)}</td>`)}</tr>`)}</tbody></table></div>
      <p class="hint">— no figure for that place yet. Each part is 0–100 among the places charted; fit is the weighted mean of the parts a place has.</p>`}
  </div>`
}

const atlasLens: View = {
  title: "Atlas",
  view,
  act(name, el) {
    switch (name) {
      case "preset":
        return query("preset", (el as HTMLSelectElement).value)
      case "adopt": {
        const d = atlas(el.dataset.preset ?? "") as Doc | null
        const w = d?.presets[el.dataset.preset ?? ""]
        if (!d || !w) return
        const set: Record<string, Input> = {}
        d.parts.forEach((p, i) => (set[`w_${p}`] = w[i] ?? 1))
        putMe(set).catch(failed)
        return query("preset", "")
      }
    }
  },
}

export default atlasLens
