// The atlas: the charted places scored against the operator's own
// passports, languages and weights. The fit (route, language, seven parts,
// the weighted sum, presets) is the kernel's only copy (`atlas`); this
// lens draws it and writes the inputs, which are columns of the one
// `settings` row. No passport or language is in source: they are rows.

import type { View } from "../app.ts"
import { Refused, atlas, ids, put, value, type Input } from "../kernel.ts"
import { EMPTY, flag, html, type Html } from "../morph.ts"
import { model, notice, query } from "../state.ts"

/** A place's fit; `fit` is null for a place with no part the kernel can score, and a part may be null too. */
type Fit = { id: number; name: string; iso2: string | null; kind: string; route: string; speaks: boolean; fit: number | null; parts: Record<string, number | null>; labeled: boolean | null }
type Doc = { parts: string[]; weights: number[]; presets: Record<string, number[]>; places: Fit[] }

const SEP = "\u001f"
const settingsId = (): number => ids("settings")[0] ?? 0
const setting = (col: string): string => {
  const id = settingsId()
  const x = id === 0 ? null : value("settings", id, col)
  return x === null ? "" : String(x)
}

function failed(e: unknown): void {
  notice("error", e instanceof Refused ? `${e.code}: ${e.message}` : e instanceof Error ? e.message : String(e))
}

function save(set: Record<string, Input>, form?: HTMLFormElement): void {
  const id = settingsId()
  // The saved values are normalised ("de, fr" becomes "DE FR"): resetting the form lets its fields follow them.
  void put("settings", set, id === 0 ? {} : { id }).then(() => form?.reset()).catch(failed)
}

const scale = (xs: (number | null)[]): number => (xs.some((x) => x !== null && x > 1) ? 100 : 1)

function meter(x: number | null, max: number): Html {
  if (x === null) return html`<span class="muted">unscored</span>`
  return html`<meter min="0" max="${max}" value="${x}" title="${x.toFixed(2)}"></meter>`
}

function view(): Html {
  const preset = model.address.q.get("preset") ?? ""
  const d = atlas(preset) as Doc | null
  if (!d) return html`<p class="empty">Loading…</p>`
  const max = scale(d.places.flatMap((p) => [p.fit, ...Object.values(p.parts)]))
  const kind = model.address.q.get("kind") ?? ""
  const places = kind === "" ? d.places : d.places.filter((p) => p.kind === kind)
  return html`<div class="atlas">
    <section class="card" data-key="me"><h2>You</h2>
      <form class="row" data-submit="me" data-act="me">
        <label>Citizenships (ISO alpha-2) <input name="citizenships" value="${setting("citizenships").split(SEP).join(" ")}" placeholder="e.g. DE FR" autocomplete="off"></label>
        <label>Languages (ISO 639-1) <input name="languages" value="${setting("languages").split(SEP).join(" ")}" placeholder="e.g. en de" autocomplete="off"></label>
        <label>Field <input name="field" value="${setting("field")}" placeholder="software"></label>
        <button>Save</button>
      </form>
    </section>
    <section class="card" data-key="weights"><h2>Weights</h2>
      <div class="row">
        <label>Preset <select data-act="preset" data-on="change"><option value="">your weights</option>
          ${Object.keys(d.presets).map((p) => html`<option${flag("selected", p === preset)}>${p}</option>`)}</select></label>
        ${preset !== "" ? html`<button type="button" data-act="adopt" data-preset="${preset}">Use ${preset} as mine</button>` : EMPTY}
      </div>
      ${preset === "" ? html`<form class="weights" data-submit="weights" data-act="weights">${d.parts.map((p, i) => html`<label>${p}
          <input type="range" name="w_${p}" min="0" max="5" step="0.5" value="${String(d.weights[i] ?? 1)}"></label>`)}
          <button>Save weights</button></form>` : html`<p class="muted">${d.parts.map((p, i) => `${p} ${d.presets[preset]?.[i] ?? 1}`).join(" · ")}</p>`}
    </section>
    <div class="toolbar"><nav class="subtabs">${[["", "all"], ["country", "countries"], ["city", "cities"]].map(([k, l]) => html`<a href="/atlas?${new URLSearchParams({ ...(preset ? { preset } : {}), ...(k ? { kind: k! } : {}) }).toString()}" data-nav class="${kind === k ? "on" : ""}" data-key="k${k}">${l}</a>`)}</nav>
      <span class="muted">${places.length} charted</span></div>
    ${places.length === 0 ? html`<p class="empty">No charted places. A place is charted when its atlas_position is set; agents fill places through the MCP.</p>` : html`<div class="grid-wrap"><table class="grid atlas-grid">
      <thead><tr><th scope="col">Place</th><th scope="col">Route</th><th scope="col">Fit</th>${d.parts.map((p) => html`<th scope="col">${p}</th>`)}</tr></thead>
      <tbody>${places.map((p) => html`<tr data-key="p${p.id}" class="route-${p.route}">
        <th scope="row">${p.name} <span class="muted">${p.iso2 ?? ""}</span></th>
        <td><span class="tag">${p.route}</span>${p.speaks ? html` <span class="tag" title="you speak a language spoken here">speaks</span>` : EMPTY}</td>
        <td>${meter(p.fit, max)}${p.fit === null ? EMPTY : html` ${max === 1 ? Math.round(p.fit * 100) : Math.round(p.fit)}`}</td>
        ${d.parts.map((part) => html`<td>${meter(p.parts[part] ?? null, max)}</td>`)}</tr>`)}</tbody></table></div>`}
  </div>`
}

const codes = (s: string, upper: boolean): string | null => {
  const list = s.split(/[\s,;]+/).map((x) => (upper ? x.toUpperCase() : x.toLowerCase())).filter((x) => /^[a-zA-Z]{2}$/.test(x))
  return list.length === 0 ? null : list.join(SEP)
}

const atlasLens: View = {
  title: "Atlas",
  view,
  act(name, el) {
    switch (name) {
      case "preset":
        return query("preset", (el as HTMLSelectElement).value)
      case "me": {
        const f = new FormData(el as HTMLFormElement)
        return save({ citizenships: codes(String(f.get("citizenships") ?? ""), true), languages: codes(String(f.get("languages") ?? ""), false), field: String(f.get("field") ?? "") || null }, el as HTMLFormElement)
      }
      case "weights": {
        const f = new FormData(el as HTMLFormElement)
        const set: Record<string, Input> = {}
        for (const [k, x] of f) set[k] = Number(x)
        // Every weight at zero scores nothing at all.
        if (Object.values(set).every((x) => x === 0)) return notice("warn", "Give at least one part a weight above zero.")
        return save(set)
      }
      case "adopt": {
        const d = atlas(el.dataset.preset ?? "") as Doc | null
        const w = d?.presets[el.dataset.preset ?? ""]
        if (!d || !w) return
        const set: Record<string, Input> = {}
        d.parts.forEach((p, i) => (set[`w_${p}`] = w[i] ?? 1))
        save(set)
        return query("preset", "")
      }
    }
  },
}

export default atlasLens
