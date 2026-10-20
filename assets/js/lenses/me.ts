// Me: everything that is the operator's own rather than a listing's, in
// one place: passports, languages, field, and the weights the atlas and
// the score read. The values are columns of the one `settings` row; the
// kernel reads them where it scores (atlas.rs), so this lens only writes.

import type { View } from "../app.ts"
import { failed, atlas, putSettings, settingsId, value, type Input } from "../kernel.ts"
import { html, resetAfter, type Html } from "../morph.ts"
import { notice } from "../state.ts"

const SEP = "\u001f"
const setting = (col: string): string => {
  const id = settingsId()
  const x = id === 0 ? null : value("settings", id, col)
  return x === null ? "" : String(x)
}

/** The saved values are normalised ("de, fr" becomes "DE FR"): resetting the form lets its fields follow them. */
const save = (set: Record<string, Input>, form?: HTMLFormElement): void => void (form ? resetAfter(form, () => putSettings(set)) : putSettings(set)).catch(failed)

const codes = (s: string, upper: boolean): string | null => {
  const list = s.split(/[\s,;]+/).map((x) => (upper ? x.toUpperCase() : x.toLowerCase())).filter((x) => /^[a-zA-Z]{2}$/.test(x))
  return list.length === 0 ? null : list.join(SEP)
}

function view(): Html {
  const d = atlas("") as { parts: string[]; weights: number[] } | null
  if (!d) return html`<p class="empty">Loading…</p>`
  return html`<div class="me">
    <section class="card" data-key="me"><h2>You</h2>
      <form class="row" data-submit="me" data-act="me">
        <label>Citizenships (ISO alpha-2) <input name="citizenships" value="${setting("citizenships").split(SEP).join(" ")}" placeholder="e.g. DE FR" autocomplete="off"></label>
        <label>Languages (ISO 639-1) <input name="languages" value="${setting("languages").split(SEP).join(" ")}" placeholder="e.g. en de" autocomplete="off"></label>
        <label>Field <input name="field" value="${setting("field")}" placeholder="software"></label>
        <button>Save</button>
      </form>
    </section>
    <section class="card" data-key="weights"><h2>Place weights</h2>
      <form class="weights" data-submit="weights" data-act="weights">${d.parts.map((p, i) => html`<label>${p} <output>${String(d.weights[i] ?? 1)}</output>
          <input type="range" name="w_${p}" min="0" max="5" step="0.5" value="${String(d.weights[i] ?? 1)}" data-act="weight" data-on="input"></label>`)}
        <button>Save weights</button></form>
      <p class="hint">The atlas scores every charted place with these; its presets can be adopted there.</p>
    </section>
  </div>`
}

const meLens: View = {
  title: "Me",
  view,
  act(name, el) {
    switch (name) {
      case "weight":
        // The number beside a slider follows it as it moves; Save weights stores them.
        return void (el.previousElementSibling as HTMLOutputElement | null)?.replaceChildren((el as HTMLInputElement).value)
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
    }
  },
}

export default meLens
