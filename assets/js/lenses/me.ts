// Me: everything that is the operator's own rather than a listing's.
//
//   /me        passports, residence, regions, work modes, pay, languages, the place weights
//   /me/cv     the CV roots: files (markdown, pdf, docx) or compositions, each a line of versions
//   /me/rules  the ordered match that gives each application its root, the named masks, and
//              the applications more than one arm takes, to pin
//
// The rows are `me` (one), `languages`, `cv_roots`, `cv_versions`, `cv_rules` and `cv_masks`.
// The kernel owns the mask language and the match (mask_check, cv_picks, mask_fields); this lens
// draws what they answer and writes rows. The bytes of a pdf or docx go to /blobs by hash first.

import type { View } from "../app.ts"
import { ENUMS } from "../gen/schema.ts"
import { command, drop, failed, atlas, ids, meId, put, putMe, query, value, type Input, type Row } from "../kernel.ts"
import { EMPTY, esc, fields, flag, html, resetAfter, str, type Html } from "../morph.ts"
import { go, model, notice } from "../state.ts"

const SEP = "\u001f"
const mine = (col: string): string => {
  const id = meId()
  const x = id === 0 ? null : value("me", id, col)
  return x === null ? "" : str(x)
}
const list = (col: string): string[] => mine(col).split(SEP).filter((x) => x !== "")

/** The saved values are normalised ("de, fr" becomes "DE FR"): resetting the form lets its fields follow them. */
const save = (set: Record<string, Input>, form?: HTMLFormElement): void => void (form ? resetAfter(form, () => putMe(set)) : putMe(set)).catch(failed)

/** Codes out of free text: "de, fr" is DE␟FR; `len` 2 for ISO alpha-2, 0 for any word. */
const codes = (s: string, upper: boolean, re = /^[a-zA-Z]{2}$/): string | null => {
  const xs = s.split(/[\s,;]+/).map((x) => (upper ? x.toUpperCase() : x.toLowerCase())).filter((x) => re.test(x))
  return xs.length === 0 ? null : xs.join(SEP)
}

/** A work_modes / employments set: bit (1 << code) per enum value. */
const bits = (col: string, name: string): Html => {
  const set = Number(mine(col) || 0)
  return html`<fieldset class="row"><legend>${col.replace("_", " ")}</legend>${(ENUMS[name] ?? []).map((x, i) => html`<label><input type="checkbox" name="${col}" value="${i}"${flag("checked", (set & (1 << i)) !== 0)}> ${x.replace("_", " ")}</label>`)}</fieldset>`
}

// ------------------------------------------------------------------ you

function you(): Html {
  const d = atlas("") as { parts: string[]; weights: number[] } | null
  const res = Number(mine("residence_id") || 0)
  const langs = [...ids("languages")].map((id) => ({ id, code: str(value("languages", id, "code")), level: str(value("languages", id, "level")) })).sort((a, b) => a.code.localeCompare(b.code))
  return html`<section class="card" data-key="me"><h2>You</h2>
      <form class="stack" data-submit="me" data-act="me">
        <div class="row">
          <label>Citizenships (ISO alpha-2) <input name="citizenships" value="${list("citizenships").join(" ")}" placeholder="e.g. DE FR" autocomplete="off"></label>
          <label>Residence (ISO alpha-2) <input name="residence" value="${res ? str(value("places", res, "iso2")) : ""}" placeholder="e.g. NL" autocomplete="off" class="narrow"></label>
          <label>Regions (ISO 3166) <input name="regions" value="${list("regions").join(" ")}" placeholder="e.g. DE NL GB-ENG" autocomplete="off"></label>
          <label><input type="checkbox" name="relocate"${flag("checked", mine("relocate") === "true")}> will relocate</label>
        </div>
        <div class="row">
          <label>Field <input name="field" value="${mine("field")}" placeholder="software"></label>
          <label>Subfields <input name="subfields" value="${list("subfields").join(" ")}" placeholder="e.g. infra compilers"></label>
        </div>
        ${bits("work_modes", "work_mode")}
        ${bits("employments", "employment")}
        <div class="row">
          <label>Pay floor (a year) <input type="number" name="pay_floor" min="0" step="1000" value="${mine("pay_floor")}"></label>
          <label>Currency (ISO 4217) <input name="pay_currency" value="${mine("pay_currency")}" placeholder="EUR" class="narrow"></label>
          <label>Available on <input type="date" name="available_on" value="${mine("available_on")}"></label>
          <label>Notice (days) <input type="number" name="notice_days" min="0" value="${mine("notice_days")}" class="narrow"></label>
        </div>
        <button>Save</button>
      </form>
    </section>
    <section class="card" data-key="languages"><h2>Languages</h2>
      <ul class="rows">${langs.map((l) => html`<li data-key="l${l.id}"><b>${l.code}</b>
        <select data-act="level" data-on="change" data-id="${l.id}" aria-label="${l.code} level">${(ENUMS.language_level ?? []).map((x) => html`<option${flag("selected", x === l.level)}>${x}</option>`)}</select>
        <button type="button" data-act="unlang" data-id="${l.id}" aria-label="Remove ${l.code}">Remove</button></li>`)}</ul>
      <form class="row" data-submit="lang" data-act="lang">
        <label>Language (ISO 639-1) <input name="code" required pattern="[a-zA-Z]{2}" placeholder="de" class="narrow" autocomplete="off"></label>
        <label>Level <select name="level">${(ENUMS.language_level ?? []).map((x) => html`<option${flag("selected", x === "b2")}>${x}</option>`)}</select></label>
        <button>Add</button>
      </form>
    </section>
    ${d ? html`<section class="card" data-key="weights"><h2>Place weights</h2>
      <form class="weights" data-submit="weights" data-act="weights">${d.parts.map((p, i) => html`<label>${p} <output>${String(d.weights[i] ?? 1)}</output>
          <input type="range" name="w_${p}" min="0" max="5" step="0.5" value="${String(d.weights[i] ?? 1)}" data-act="weight" data-on="input"></label>`)}
        <button>Save weights</button></form>
      <p class="hint">The atlas scores every charted place with these; its presets can be adopted there.</p>
    </section>` : EMPTY}`
}

// ------------------------------------------------------------------ the kernel's answers

type Pick = { application: number; state: "default" | "matched" | "pinned" | "stale" | "empty" | "none"; root: number | null; arm: number | null; by: string | null; also: number[]; version_id: number | null }
type Check = { ok: boolean; error: { pos: number; len: number; msg: string } | null; shadowed: number[]; never_matches?: boolean }
type Field = { path: string; type: "bool" | "text" | "num" | "day" | "code" | "enum" | "list"; values?: string[]; list_of?: string }

/** A kernel answer, or null while the kernel cannot give it (still loading, or an older kernel). */
function ask<T>(op: Parameters<typeof query>[0], params: Record<string, unknown>): T | null {
  try {
    return query<T>(op, params)
  } catch {
    return null
  }
}
const picks = (): Pick[] => ask<{ picks: Pick[] }>("cv_picks", {})?.picks ?? []

const rootName = (id: number | null): string => (id ? str(value("cv_roots", id, "name")) || `#${id}` : "none")
const roots = (): number[] => [...ids("cv_roots")].sort((a, b) => rootName(a).localeCompare(rootName(b)))
const rootOptions = (pick: number | null, none = false): Html =>
  html`${none ? html`<option value="">none</option>` : EMPTY}${roots().map((id) => html`<option value="${id}"${flag("selected", id === pick)}>${rootName(id)}</option>`)}`

/** The text with the byte span [pos, pos+len) marked (positions are UTF-8 bytes). */
function marked(text: string, pos: number, len: number): Html {
  const b = new TextEncoder().encode(text)
  const dec = new TextDecoder()
  const at = (n: number): string => dec.decode(b.slice(0, Math.min(n, b.length)))
  const head = at(pos)
  const mid = at(pos + Math.max(len, 1)).slice(head.length)
  return html`<code>${head}<mark>${mid || " "}</mark>${text.slice(head.length + mid.length)}</code>`
}

/** What the kernel says of a pattern: its error marked in place, or the arms that leave it nothing. */
function verdict(text: string, position?: number): Html {
  if (text.trim() === "") return EMPTY
  const c = ask<Check>("mask_check", position === undefined ? { text } : { text, position })
  if (!c) return EMPTY
  if (c.error) return html`<span class="bad">${c.error.msg}</span> ${marked(text, c.error.pos, c.error.len)}`
  if (c.never_matches) return html`<span class="muted">matches no application yet</span>`
  if (c.shadowed.length > 0) return html`<span class="warn">never wins: ${c.shadowed.map((a) => `#${a}`).join(", ")} take every application it matches</span>`
  return html`<span class="ok">ok</span>`
}

// ------------------------------------------------------------------ cv roots

function cv(): Html {
  const sel = Number(model.address.q.get("root") ?? 0)
  const count = new Map<number, number>()
  for (const p of picks()) if (p.root) count.set(p.root, (count.get(p.root) ?? 0) + 1)
  const def = Number(mine("cv_default_root_id") || 0)
  return html`<section class="card" data-key="roots"><h2>CVs</h2>
      ${ids("cv_roots").length === 0 ? html`<p class="empty">No CVs yet. Add one below, or let an agent add one over the MCP.</p>` : html`<table class="grid compact"><thead><tr><th scope="col">CV</th><th scope="col">Format</th><th scope="col">Newest</th><th scope="col">Applications</th></tr></thead>
      <tbody>${roots().map((id) => {
        const v = Number(value("cv_roots", id, "version_id") ?? 0)
        return html`<tr data-key="r${id}"${flag("aria-selected", id === sel)}><th scope="row"><a href="/me/cv?root=${id}" data-nav>${rootName(id)}</a>${id === def ? html` <span class="tag">default</span>` : EMPTY}</th>
          <td><span class="tag">${str(value("cv_roots", id, "format"))}</span></td><td>${v ? `v${str(value("cv_versions", v, "n"))}` : html`<span class="muted">no versions</span>`}</td><td>${count.get(id) ?? 0}</td></tr>`
      })}</tbody></table>`}
      <form class="row" data-submit="root" data-act="root">
        <label>Name <input name="name" required placeholder="Research, DACH"></label>
        <label>Slug <input name="slug" placeholder="research-dach" pattern="[a-z0-9-]+" class="narrow"></label>
        <label>Format <select name="format">${(ENUMS.cv_format ?? []).filter((x) => x !== "composed").map((x) => html`<option>${x}</option>`)}</select></label>
        <button>Add CV</button>
      </form>
    </section>
    ${sel && value("cv_roots", sel, "name") !== null ? root(sel, sel === def) : EMPTY}`
}

function root(id: number, isDefault: boolean): Html {
  const format = str(value("cv_roots", id, "format"))
  const head = Number(value("cv_roots", id, "version_id") ?? 0)
  const versions = ask<{ rows: Row[] }>("find", { table: "cv_versions", where: { root_id: id }, order: ["id", "desc"], cols: ["id", "n", "note", "actor", "blob_sha", "blob_name", "blob_bytes", "inserted_at"], limit: 50 })?.rows ?? []
  const profile = Number(value("cv_roots", id, "profile_id") ?? 0)
  return html`<section class="card stack" data-key="root${id}"><h2>${rootName(id)} <span class="tag">${format}</span></h2>
      <form class="row" data-submit="rename" data-act="rename" data-id="${id}">
        <label>Name <input name="name" required value="${rootName(id)}"></label>
        <label>Notes <input name="notes" value="${str(value("cv_roots", id, "notes"))}"></label>
        <button>Save</button>
        ${isDefault ? html`<span class="tag">the default</span>` : html`<button type="button" data-act="default" data-id="${id}">Make default</button>`}
        <button type="button" class="danger" data-act="unroot" data-id="${id}">Delete…</button>
      </form>
      ${format === "composed" ? html`<p class="hint">Composed from ${profile ? html`the <b>${str(value("profiles", profile, "name"))}</b> profile's items` : "a profile"}: the kernel builds it for each application.</p>` : EMPTY}
      ${format === "markdown" ? html`<form class="stack" data-submit="body" data-act="body" data-id="${id}">
        <label>Markdown <textarea name="body" rows="18" spellcheck="true">${head ? str(value("cv_versions", head, "body")) : ""}</textarea></label>
        <div class="row"><label>Note <input name="note" placeholder="what changed"></label><button class="primary">Save as v${versions.length + 1}</button>
          <label>or upload a .md <input type="file" name="file" accept=".md,.markdown,text/markdown" data-act="file" data-on="change" data-id="${id}"></label></div>
      </form>` : EMPTY}
      ${format === "pdf" || format === "docx" ? html`<form class="row" data-submit="upload" data-act="upload" data-id="${id}">
        <label>${format === "pdf" ? "PDF" : "Word document"} <input type="file" name="file" required accept="${format === "pdf" ? ".pdf,application/pdf" : ".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document"}"></label>
        <label>Note <input name="note" placeholder="what changed"></label><button class="primary">Upload v${versions.length + 1}</button>
      </form>` : EMPTY}
      ${versions.length === 0 ? EMPTY : html`<table class="grid compact"><thead><tr><th scope="col">Version</th><th scope="col">Day</th><th scope="col">By</th><th scope="col">Note</th><th scope="col">File</th></tr></thead>
      <tbody>${versions.map((v) => html`<tr data-key="v${str(v.id)}"><th scope="row">v${str(v.n)}</th><td>${str(v.inserted_at).slice(0, 10)}</td><td>${str(v.actor)}</td><td>${str(v.note)}</td>
        <td>${v.blob_sha ? html`<a href="/blobs/${str(v.blob_sha)}?name=${encodeURIComponent(str(v.blob_name))}" target="_blank" rel="noopener">${str(v.blob_name) || "file"}</a> <span class="muted">${Math.ceil(Number(v.blob_bytes ?? 0) / 1024)} KiB</span>` : html`<span class="muted">text</span>`}</td></tr>`)}</tbody></table>`}
      ${head && format !== "markdown" && value("cv_versions", head, "text") ? html`<details><summary>What rules and agents read of v${str(value("cv_versions", head, "n"))}</summary><pre class="prose">${str(value("cv_versions", head, "text"))}</pre></details>` : EMPTY}
    </section>`
}

const TYPES: Record<string, string> = { pdf: "application/pdf", docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", markdown: "text/markdown" }
const BLOB_MAX = 10 * 1024 * 1024

/** The bytes to /blobs (content-addressed; the same file again is the same sha), then a version naming them. */
async function upload(root: number, file: File, note: string): Promise<unknown> {
  const format = str(value("cv_roots", root, "format"))
  if (file.size > BLOB_MAX) throw new Error("A CV file is at most 10 MiB.")
  const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
  const res = await fetch("/blobs", { method: "PUT", headers: { "content-type": TYPES[format] ?? file.type, "x-csrf-token": csrf }, body: file, credentials: "same-origin" })
  if (!res.ok) throw new Error(`The upload was refused (${res.status}).`)
  const b = (await res.json()) as { sha: string }
  return put("cv_versions", { root_id: root, blob_sha: b.sha, blob_name: file.name, note: note || null })
}

// ------------------------------------------------------------------ rules and masks

const rules = (): number[] => [...ids("cv_rules")].sort((a, b) => Number(value("cv_rules", a, "position") ?? 0) - Number(value("cv_rules", b, "position") ?? 0) || a - b)

function builder(fs: Field[]): Html {
  const targets = [["new", "the new rule"], ...rules().map((id) => [`r${id}`, `rule #${id}`]), ["mask", "the new mask"]]
  return html`<form class="row builder" data-submit="build" data-act="build">
      <label>Field <select name="path" data-act="bfield" data-on="change">${fs.map((f) => html`<option value="${f.path}" data-type="${f.type}">${f.path}</option>`)}</select></label>
      <label>Test <select name="op">${["=", "!=", "in", "~", "^=", "<", "<=", ">", ">=", "_"].map((o) => html`<option value="${o}">${o === "_" ? "is set" : o}</option>`)}</select></label>
      <label>Value <input name="value" list="mask-values" placeholder=":research, DE, &quot;text&quot;, me.citizenships"></label>
      <datalist id="mask-values">${(fs[0]?.values ?? []).map((x) => html`<option value=":${x}">`)}</datalist>
      <label>Join <select name="join"><option value="&">and</option><option value="|">or</option><option value="&!">and not</option></select></label>
      <label>Into <select name="into">${targets.map(([k, l]) => html`<option value="${k}">${l}</option>`)}</select></label>
      <button>Add test</button>
    </form>`
}

/** One test as mask text: a symbol for an enum value, an ISO code bare, quotes round other text. */
function test(f: Field | undefined, op: string, raw: string): string {
  const path = f?.path ?? ""
  if (op === "_") return `${path} _`
  const lit = (x: string): string => {
    const t = x.trim()
    if (/^(me|company|role)\.[a-z_]+$/.test(t) || /^:[a-z_]+$/.test(t) || /^-?\d+(\.\d+)?$/.test(t) || /^\d{4}-\d{2}-\d{2}$/.test(t) || /^".*"$/.test(t)) return t
    if (f?.type === "enum" || f?.list_of === "enum") return `:${t}`
    if ((f?.type === "code" || f?.list_of === "code") && /^[A-Za-z]{2}(-[A-Za-z0-9]{1,3})?$/.test(t)) return t.toUpperCase()
    return JSON.stringify(t)
  }
  const parts = raw.split(",").filter((x) => x.trim() !== "")
  return `${path} ${op} ${op === "in" && parts.length !== 1 ? `[${parts.map(lit).join(", ")}]` : lit(raw)}`
}

function rulesView(): Html {
  const fs = ask<{ fields: Field[] }>("mask_fields", {})?.fields ?? []
  const rs = rules()
  const all = picks()
  const multi = all.filter((p) => p.state === "matched" && p.also.length > 0)
  const broken = all.filter((p) => p.state === "stale" || p.state === "empty")
  const masks = [...ids("cv_masks")].sort((a, b) => str(value("cv_masks", a, "name")).localeCompare(str(value("cv_masks", b, "name"))))
  return html`<section class="card" data-key="rules"><h2>Which CV an application gets</h2>
      <p class="hint">Read top to bottom: the first enabled rule that matches an application gives it that CV; none matching gives it the default (${rootName(Number(mine("cv_default_root_id") || 0) || null)}). A pin on the application wins over every rule.</p>
      <ol class="rules">${rs.map((id, i) => {
        const pattern = str(value("cv_rules", id, "pattern"))
        return html`<li data-key="u${id}"><form class="row" data-submit="rule" data-act="rule" data-id="${id}">
          <span class="muted">#${id}</span>
          <label><input type="checkbox" name="enabled"${flag("checked", value("cv_rules", id, "enabled") !== false)}> on</label>
          <label>Name <input name="name" value="${str(value("cv_rules", id, "name"))}" class="narrow"></label>
          <label class="grow">When <input name="pattern" required value="${pattern}" data-act="check" data-on="input" data-position="${i}" spellcheck="false" autocomplete="off" class="mono"></label>
          <label>use <select name="root_id">${rootOptions(Number(value("cv_rules", id, "root_id") ?? 0))}</select></label>
          <button>Save</button>
          <button type="button" data-act="move" data-id="${id}" data-by="-1" aria-label="Move #${id} up"${flag("disabled", i === 0)}>↑</button>
          <button type="button" data-act="move" data-id="${id}" data-by="1" aria-label="Move #${id} down"${flag("disabled", i === rs.length - 1)}>↓</button>
          <button type="button" class="danger" data-act="unrule" data-id="${id}" aria-label="Delete #${id}">✕</button>
          <output class="verdict">${verdict(pattern, i)}</output></form></li>`
      })}</ol>
      ${ids("cv_roots").length === 0 ? html`<p class="empty">Add a CV first: a rule names the CV it gives.</p>` : html`<form class="row" data-submit="newrule" data-act="newrule" data-key="newrule">
        <label class="grow">When <input name="pattern" required data-act="check" data-on="input" data-position="${rs.length}" placeholder="country in [DE, AT, CH] &amp; role.field = :research" spellcheck="false" autocomplete="off" class="mono"></label>
        <label>use <select name="root_id">${rootOptions(null)}</select></label>
        <label>Name <input name="name" class="narrow"></label>
        <button class="primary">Add rule</button>
        <output class="verdict"></output></form>`}
      ${fs.length > 0 ? builder(fs) : EMPTY}
    </section>
    <section class="card" data-key="masks"><h2>Named masks</h2>
      <p class="hint">A mask is a pattern with a name; a rule names it like a field: <code>dach &amp; role.field = :research</code>.</p>
      <ul class="rows">${masks.map((id) => html`<li data-key="m${id}"><form class="row" data-submit="mask" data-act="mask" data-id="${id}">
        <b>${str(value("cv_masks", id, "name"))}</b>
        <label class="grow">= <input name="pattern" required value="${str(value("cv_masks", id, "pattern"))}" data-act="check" data-on="input" spellcheck="false" class="mono"></label>
        <label>Note <input name="note" value="${str(value("cv_masks", id, "note"))}"></label>
        <button>Save</button><button type="button" class="danger" data-act="unmask" data-id="${id}" aria-label="Delete ${str(value("cv_masks", id, "name"))}">✕</button>
        <output class="verdict">${verdict(str(value("cv_masks", id, "pattern")))}</output></form></li>`)}</ul>
      <form class="row" data-submit="newmask" data-act="newmask" data-key="newmask">
        <label>Name <input name="name" required pattern="[a-z][a-z0-9_]*" class="narrow" placeholder="dach"></label>
        <label class="grow">= <input name="pattern" required data-act="check" data-on="input" placeholder="[country in [DE, AT, CH]]" spellcheck="false" class="mono"></label>
        <label>Note <input name="note"></label><button>Add mask</button>
        <output class="verdict"></output></form>
    </section>
    <section class="card" data-key="multi"><h2>Taken by more than one rule</h2>
      ${multi.length === 0 && broken.length === 0 ? html`<p class="empty">Every application's CV is settled: no unpinned application matches a second rule.</p>` : EMPTY}
      <ul class="rows">${[...broken, ...multi].map((p) => {
        const no = value("applications", p.application, "no")
        return html`<li data-key="a${p.application}"><a href="/focus/${str(no)}" data-nav>#${str(no)} ${str(value("applications", p.application, "role"))}</a>
          ${p.state === "stale" ? html`<span class="tag bad">pinned to a deleted CV</span>` : p.state === "empty" ? html`<span class="tag warn">${rootName(p.root)} has no versions</span>` : html`gets <b>${rootName(p.root)}</b> by #${String(p.arm)}; also matched`}
          ${[...new Set(p.also.map((a) => Number(value("cv_rules", a, "root_id") ?? 0)))].filter((r) => r && r !== p.root).map((r) => html`<button type="button" data-act="pin" data-app="${p.application}" data-root="${r}">${rootName(r)}</button>`)}
          ${p.root && p.state === "matched" ? html`<button type="button" data-act="pin" data-app="${p.application}" data-root="${p.root}">Keep ${rootName(p.root)}</button>` : EMPTY}</li>`
      })}</ul>
    </section>`
}

/** The rules renumbered 10, 20, … with `id` moved `by` places, so an order of equal positions settles. */
function move(id: number, by: number): void {
  const rs = rules()
  const i = rs.indexOf(id)
  const j = i + by
  if (i < 0 || j < 0 || j >= rs.length) return
  ;[rs[i], rs[j]] = [rs[j]!, rs[i]!]
  rs.forEach((r, n) => {
    if (Number(value("cv_rules", r, "position") ?? 0) !== (n + 1) * 10) put("cv_rules", { position: (n + 1) * 10 }, { id: r }).catch(failed)
  })
}

// ------------------------------------------------------------------ the lens

function view(): Html {
  const sub = model.address.sub
  return html`<div class="me">
    <div class="toolbar"><nav class="subtabs" aria-label="Me">${[["", "you"], ["cv", "CVs"], ["rules", "rules"]].map(([s, l]) => html`<a href="/me${s ? `/${s}` : ""}" data-nav data-key="t${s}" class="${s === sub ? "on" : ""}"${s === sub ? html` aria-current="page"` : EMPTY}>${l}</a>`)}</nav></div>
    ${sub === "cv" ? cv() : sub === "rules" ? rulesView() : you()}
  </div>`
}

const num = (x: string | undefined): number | null => (x === undefined || x === "" ? null : Number(x))
const bitsOf = (f: FormData, col: string): number => f.getAll(col).reduce<number>((s, x) => s | (1 << Number(x)), 0)

const meLens: View = {
  title: "Me",
  view,
  act(name, el) {
    const id = Number(el.dataset.id ?? 0)
    const form = el as HTMLFormElement
    switch (name) {
      case "weight":
        // The number beside a slider follows it as it moves; Save weights stores them.
        return void (el.previousElementSibling as HTMLOutputElement | null)?.replaceChildren((el as HTMLInputElement).value)
      case "me": {
        const f = new FormData(form)
        const x = fields(form)
        const iso = (x.residence ?? "").trim().toUpperCase()
        const place = iso === "" ? null : ask<{ rows: Row[] }>("find", { table: "places", where: { iso2: iso, kind: "country" }, cols: ["id"], limit: 1 })?.rows[0]
        if (iso !== "" && !place) return notice("warn", `No country ${iso} in the world tables yet.`)
        return save({
          citizenships: codes(x.citizenships ?? "", true),
          residence_id: place ? Number(place.id) : null,
          regions: codes(x.regions ?? "", true, /^[A-Za-z]{2}(-[A-Za-z0-9]{1,3})?$/),
          relocate: f.has("relocate"),
          field: x.field || null,
          subfields: codes(x.subfields ?? "", false, /^[a-z0-9_-]+$/),
          work_modes: bitsOf(f, "work_modes"),
          employments: bitsOf(f, "employments"),
          pay_floor: num(x.pay_floor),
          pay_currency: (x.pay_currency ?? "").trim().toUpperCase() || null,
          available_on: x.available_on || null,
          notice_days: num(x.notice_days),
        }, form)
      }
      case "weights": {
        const f = new FormData(form)
        const set: Record<string, Input> = {}
        for (const [k, x] of f) set[k] = Number(x)
        // Every weight at zero scores nothing at all.
        if (Object.values(set).every((x) => x === 0)) return notice("warn", "Give at least one part a weight above zero.")
        return save(set)
      }
      case "lang": {
        const x = fields(form)
        return void resetAfter(form, () => put("languages", { level: x.level ?? "b2" }, { key: { code: (x.code ?? "").toLowerCase() } })).catch(failed)
      }
      case "level":
        return void put("languages", { level: (el as HTMLSelectElement).value }, { id }).catch(failed)
      case "unlang":
        return void drop("languages", id).catch(failed)
      case "root": {
        const x = fields(form)
        const slug = x.slug || (x.name ?? "").toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
        return void resetAfter(form, () => put("cv_roots", { name: x.name ?? "", slug, format: x.format ?? "markdown" }))
          .then((r) => go({ lens: "me", sub: "cv", q: new Map([["root", String(r.id)]]) }))
          .catch(failed)
      }
      case "rename": {
        const x = fields(form)
        return void put("cv_roots", { name: x.name ?? "", notes: x.notes || null }, { id }).catch(failed)
      }
      case "default":
        return save({ cv_default_root_id: id })
      case "unroot":
        if (!confirm(`Delete the CV ${rootName(id)}? Its versions stay on record; rules that name it stop matching.`)) return
        return void drop("cv_roots", id).then(() => go({ lens: "me", sub: "cv", q: new Map() })).catch(failed)
      case "body": {
        const x = fields(form)
        return void put("cv_versions", { root_id: id, body: x.body ?? "", note: x.note || null }).catch(failed)
      }
      case "file": {
        // A .md file fills the editor; Save makes it the next version.
        const file = (el as HTMLInputElement).files?.[0]
        const area = el.closest("form")?.querySelector<HTMLTextAreaElement>("textarea[name=body]")
        if (file && area) void file.text().then((t) => (area.value = t))
        return
      }
      case "upload": {
        const file = (form.elements.namedItem("file") as HTMLInputElement | null)?.files?.[0]
        if (!file) return
        const note = fields(form).note ?? ""
        return void resetAfter(form, () => upload(id, file, note)).catch(failed)
      }
      case "check": {
        // The kernel's verdict follows the pattern as it is typed.
        const input = el as HTMLInputElement
        const out = input.closest("form")?.querySelector("output.verdict")
        const pos = input.dataset.position
        if (out) out.innerHTML = verdict(input.value, pos === undefined ? undefined : Number(pos)).text
        return
      }
      case "bfield": {
        const s = el as HTMLSelectElement
        const fs = ask<{ fields: Field[] }>("mask_fields", {})?.fields ?? []
        const f = fs.find((x) => x.path === s.value)
        const dl = document.getElementById("mask-values")
        if (dl) dl.innerHTML = (f?.values ?? []).map((x) => `<option value=":${esc(x)}">`).join("")
        return
      }
      case "build": {
        const x = fields(form)
        const f = (ask<{ fields: Field[] }>("mask_fields", {})?.fields ?? []).find((y) => y.path === x.path)
        const t = test(f, x.op ?? "=", x.value ?? "")
        const sel = x.into === "new" ? '[data-key="newrule"] input[name=pattern]' : x.into === "mask" ? '[data-key="newmask"] input[name=pattern]' : `[data-key="u${(x.into ?? "").slice(1)}"] input[name=pattern]`
        const input = document.querySelector<HTMLInputElement>(`.me ${sel}`)
        if (!input) return
        const join = x.join === "&!" ? " & !" : ` ${x.join ?? "&"} `
        input.value = input.value.trim() === "" ? t : `${input.value.trim()}${join}${x.join === "&!" ? `(${t})` : t}`
        input.dispatchEvent(new Event("input", { bubbles: true }))
        input.focus()
        return
      }
      case "rule": {
        const f = new FormData(form)
        const x = fields(form)
        return void put("cv_rules", { name: x.name || null, pattern: x.pattern ?? "", root_id: Number(x.root_id), enabled: f.has("enabled") }, { id }).catch(failed)
      }
      case "newrule": {
        const x = fields(form)
        const last = rules().at(-1)
        const position = last === undefined ? 10 : Number(value("cv_rules", last, "position") ?? 0) + 10
        return void resetAfter(form, () => put("cv_rules", { name: x.name || null, pattern: x.pattern ?? "", root_id: Number(x.root_id), position, enabled: true })).catch(failed)
      }
      case "move":
        return move(id, Number(el.dataset.by ?? 0))
      case "unrule":
        return void drop("cv_rules", id).catch(failed)
      case "mask": {
        const x = fields(form)
        return void put("cv_masks", { pattern: x.pattern ?? "", note: x.note || null }, { id }).catch(failed)
      }
      case "newmask": {
        const x = fields(form)
        return void resetAfter(form, () => put("cv_masks", { name: x.name ?? "", pattern: x.pattern ?? "", note: x.note || null })).catch(failed)
      }
      case "unmask":
        return void drop("cv_masks", id).catch(failed)
      case "pin":
        return void command("pick_cv", Number(el.dataset.app ?? 0), { cv_root_id: Number(el.dataset.root ?? 0) }).catch(failed)
    }
  },
}

export default meLens
