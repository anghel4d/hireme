// Me: everything that is the operator's own rather than a listing's.
//
//   /me        passports, permits, residence, regions, the countries wanted or never, work modes, pay,
//              languages, notes for agents, and the weights the atlas orders places by
//   /me/cv     the CV roots: files (markdown, pdf, docx) or compositions, each a line of versions
//   /me/rules  the ordered match that gives each application its root, the named masks, and
//              the applications more than one arm takes, to pin
//
// The rows are `me` (one), `languages`, `cv_roots`, `cv_versions`, `cv_rules` and `cv_masks`.
// The kernel owns the mask language and the match (mask_check, cv_picks, mask_fields); this lens
// draws what they answer and writes rows. The bytes of a pdf or docx go to /blobs by hash first.

import type { View } from "../app.ts"
import { ENUMS, TABLES, type ColumnDef } from "../gen/schema.ts"
import { command, drop, failed, ids, meId, page, put, putMe, query, value, type Input, type Row } from "../kernel.ts"
import { EMPTY, esc, fields, flag, html, resetAfter, str, type Html } from "../morph.ts"
import { drafts, model, notice, query as setQuery, schedule, slug } from "../state.ts"
import { appItem } from "./focus.ts"
import { label } from "./world.ts"

const SEP = "\u001f"
export const mine = (col: string): string => {
  const id = meId()
  const x = id === 0 ? null : value("me", id, col)
  return x === null ? "" : str(x)
}
export const list = (col: string): string[] => mine(col).split(SEP).filter((x) => x !== "")

/** The figures a weight may name: every metric of places, plus the two personal parts. */
export const FIGURES: ColumnDef[] = TABLES.places.cols.filter((c) => c.metric)
const PARTS: [string, string][] = [["route", "Citizen or permit held 1, no permit needed 0.9, needs a permit 0.3"], ["language", "Speaks one of your languages"]]
export const figureName = (key: string): string => (key === "route" ? "Route" : key === "language" ? "Speaks your language" : label(key))
/** The weights as saved: `{"<places metric>": w, "route": w, "language": w}`. */
const weights = (): Record<string, unknown> => {
  try {
    const w: unknown = JSON.parse(mine("weights") || "{}")
    return typeof w === "object" && w !== null ? (w as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

/** The saved values are normalised ("de, fr" becomes "DE FR"): resetting the form lets its fields follow them. */
const save = (set: Record<string, Input>, form?: HTMLFormElement): void => void (form ? resetAfter(form, () => putMe(set)) : putMe(set)).catch(failed)

/** The world's countries by ISO alpha-2 and by name, any case, read again when rows move. */
let countries: { rows: number; by: Map<string, { iso2: string; name: string }> } | null = null
function country(t: string): { iso2: string; name: string } | null {
  if (countries?.rows !== model.rows) {
    const by = new Map<string, { iso2: string; name: string }>()
    for (const r of page({ table: "places", where: { kind: "country" }, cols: ["iso2", "name"] }, 500).rows) {
      const c = { iso2: str(r.iso2).toUpperCase(), name: str(r.name) }
      if (c.iso2 !== "") by.set(c.iso2.toLowerCase(), c).set(c.name.toLowerCase(), c)
    }
    countries = { rows: model.rows, by }
  }
  return countries.by.get(t.toLowerCase()) ?? null
}

type Parsed = { codes: string[]; names: (string | null)[]; missed: string[] }
/**
 * Countries out of free text, by code or by name ("ca, Romania" is CA␟RO; the longest run of words
 * that names a country is taken). A two-letter code the world does not know yet is kept, a region
 * (GB-ENG) where `regions`; anything else is missed, and the lens says so.
 */
function countriesIn(s: string, regions = false): Parsed {
  const out: Parsed = { codes: [], names: [], missed: [] }
  const ts = s.split(/[\s,;]+/).filter((t) => t !== "")
  for (let i = 0, j = ts.length; i < ts.length; i = j, j = ts.length) {
    while (j > i + 1 && !country(ts.slice(i, j).join(" "))) j--
    const t = ts.slice(i, j).join(" ")
    const c = country(t) ?? (regions && /^[a-z]{2}-[a-z0-9]{1,3}$/i.test(t) ? { iso2: t.toUpperCase(), name: `in ${country(t.slice(0, 2))?.name ?? t.slice(0, 2).toUpperCase()}` } : null)
    const code = c?.iso2 ?? (/^[a-z]{2}$/i.test(t) ? t.toUpperCase() : null)
    if (code === null) out.missed.push(t)
    else if (!out.codes.includes(code)) out.codes.push(code), out.names.push(c?.name ?? null)
  }
  return out
}
const joined = (xs: string[]): string | null => (xs.length === 0 ? null : xs.join(SEP))
const words = (s: string): string[] => [...new Set(s.toLowerCase().split(/[\s,;]+/).filter((x) => x !== ""))]

/** The form as typed (or as saved): what the list beside it reads and what a save writes. */
type Draft = { text: Record<string, string>; work_modes: number; employments: number; relocate: boolean }
/** The form as typed and not saved, kept in this browser (state.ts drafts) until saved or discarded. */
let draft: Draft | null = drafts.get<Draft>("me")
const fromForm = (form: HTMLFormElement): Draft => {
  const f = new FormData(form)
  return { text: fields(form), work_modes: bitsOf(f, "work_modes"), employments: bitsOf(f, "employments"), relocate: f.has("relocate") }
}
function saved(): Draft {
  const res = Number(mine("residence_id") || 0)
  const text: Record<string, string> = { residence: res ? str(value("places", res, "iso2")) : "", notes: str(value("me", meId(), "notes")) }
  for (const c of ["citizenships", "regions", "work_permits", "prefer", "avoid", "subfields"]) text[c] = list(c).join(" ")
  for (const c of ["field", "pay_floor", "pay_currency", "available_on", "notice_days"]) text[c] = mine(c)
  return { text, work_modes: Number(mine("work_modes") || 0), employments: Number(mine("employments") || 0), relocate: mine("relocate") === "true" }
}

/** A work_modes / employments set: bit (1 << code) per enum value. */
const bits = (col: string, name: string, legend: string, set: number): Html =>
  html`<fieldset class="row"><legend>${legend}</legend>${(ENUMS[name] ?? []).map((x, i) => html`<label><input type="checkbox" name="${col}" value="${i}"${flag("checked", (set & (1 << i)) !== 0)}> ${x.replace("_", " ")}</label>`)}</fieldset>`
const named = (name: string, set: number): string => (ENUMS[name] ?? []).filter((_, i) => (set & (1 << i)) !== 0).map((x) => x.replace("_", " ")).join(", ")

/** What the form says, read back: every code with its country, every word that was not understood marked. */
function understood(d: Draft): Html {
  const t = d.text
  const chips = (p: Parsed): Html => html`${p.codes.map((c, i) => html`<span class="term ${p.names[i] ? "hit" : "warn"}" data-key="${c}"${p.names[i] ? EMPTY : html` title="Kept, but no country the world tables know has this code"`}><b>${c}</b> ${p.names[i] ?? "unknown code"}</span>`)}${p.missed.map((m) => html`<span class="term bad" data-key="x${m}" title="Not a country code or name">${m}?</span>`)}`
  const row = (k: string, title: string, body: Html | string): Html => html`<dt data-key="t${k}">${title}</dt><dd data-key="d${k}">${body === "" ? html`<span class="muted">nothing yet</span>` : body}</dd>`
  const codes = (k: string, title: string, regions = false): Html => {
    const p = countriesIn(t[k] ?? "", regions)
    return row(k, title, p.codes.length + p.missed.length === 0 ? "" : chips(p))
  }
  const pay = Number(t.pay_floor || 0)
  const cur = (t.pay_currency ?? "").trim().toUpperCase()
  return html`<aside class="understood" data-key="understood" aria-label="What this says"><h3>Understood${draft ? html` <span class="muted">(not saved yet)</span>` : EMPTY}</h3><dl>
    ${codes("citizenships", "Citizen of")}${codes("residence", "Lives in")}${codes("work_permits", "May already work in")}
    ${codes("prefer", "Ranked first")}${codes("avoid", "Ranked last, still shown")}${codes("regions", "Regions", true)}
    ${row("relocate", "Relocation", d.relocate ? "open to it" : "")}
    ${row("field", "Field", [t.field?.trim() ?? "", ...words(t.subfields ?? "")].filter((x) => x !== "").join(" · "))}
    ${row("modes", "Favours", [named("work_mode", d.work_modes), named("employment", d.employments)].filter((x) => x !== "").join(" · "))}
    ${row("pay", "Priority up from", pay > 0 ? html`${pay.toLocaleString()} ${/^[A-Z]{3}$/.test(cur) ? cur : html`<span class="term bad">${cur || "no currency"}?</span>`} a year` : "")}
    ${row("when", "Available", [t.available_on ? `from ${t.available_on}` : "", t.notice_days ? `${t.notice_days} days' notice` : ""].filter((x) => x !== "").join(" · "))}
    ${row("notes", "Notes", t.notes?.trim() ? `${words(t.notes).length} words for your agents` : "")}
  </dl></aside>`
}

// ------------------------------------------------------------------ you

function you(): Html {
  const d = draft ?? saved()
  const t = d.text
  const w = weights()
  const groups = [...new Set(FIGURES.map((c) => c.group ?? "other"))]
  const weightField = (key: string, text: string, title: string): Html =>
    html`<label title="${title}">${text} <input type="number" name="${key}" step="0.5" min="-10" max="10" value="${String(w[key] ?? "")}" class="narrow"></label>`
  const langs = [...ids("languages")].map((id) => ({ id, code: str(value("languages", id, "code")), level: str(value("languages", id, "level")) })).sort((a, b) => a.code.localeCompare(b.code))
  return html`<section class="card" data-key="me"><h2>You</h2>
      <p class="hint">Nothing here filters or hides anything. It is what your agents keep in mind and what bumps an option up: the atlas orders places by it, your CV rules can read it, and everything stays in view. Countries by code or name, any separator.</p>
      <div class="you-grid">
      <form class="stack" data-submit="me" data-act="me-draft" data-on="input">
        <div class="row">
          <label>Citizenships <input name="citizenships" value="${t.citizenships}" placeholder="e.g. DE France" autocomplete="off"></label>
          <label>Lives in <input name="residence" value="${t.residence}" placeholder="e.g. NL" autocomplete="off" class="narrow"></label>
          <label>Regions <input name="regions" value="${t.regions}" placeholder="e.g. DE NL GB-ENG" autocomplete="off"></label>
          <label class="check"><input type="checkbox" name="relocate"${flag("checked", d.relocate)}> open to relocating</label>
        </div>
        <div class="row">
          <label>Work permits or residence held <input name="work_permits" value="${t.work_permits}" placeholder="e.g. US" autocomplete="off"></label>
          <label>Countries to rank first <input name="prefer" value="${t.prefer}" placeholder="e.g. CH Norway" autocomplete="off"></label>
          <label>Countries to rank last (still shown) <input name="avoid" value="${t.avoid}" placeholder="e.g. RU" autocomplete="off"></label>
        </div>
        <div class="row">
          <label>Field <input name="field" value="${t.field}" placeholder="software"></label>
          <label>Subfields <input name="subfields" value="${t.subfields}" placeholder="e.g. infra compilers"></label>
        </div>
        ${bits("work_modes", "work_mode", "Work modes to favour", d.work_modes)}
        ${bits("employments", "employment", "Employment to favour", d.employments)}
        <div class="row">
          <label>Pay that bumps priority (a year) <input type="number" name="pay_floor" min="0" step="1000" value="${t.pay_floor}"></label>
          <label>Currency <input name="pay_currency" value="${t.pay_currency}" placeholder="EUR" class="narrow"></label>
          <label>Available from <input type="date" name="available_on" value="${t.available_on}"></label>
          <label>Notice (days) <input type="number" name="notice_days" min="0" value="${t.notice_days}" class="narrow"></label>
        </div>
        <label>Notes for your agents: what to keep in mind, what bumps priority <textarea name="notes" rows="4" placeholder="e.g. partner works in hospitals, so cities with a big one rank up; mild winters are a plus">${t.notes}</textarea></label>
        <span class="row"><button>Save</button>${draft ? html`<button type="button" class="ghost" data-act="me-discard">Discard changes</button>` : EMPTY}</span>
      </form>
      ${understood(d)}
      </div>
      <p class="hint">Your agents fill this too: <code>put</code> the <code>me</code> row through the MCP, with a key that writes corpus.</p>
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
    <section class="card" data-key="recipe"><h2>What matters</h2>
      <p class="hint">A weight per figure orders the atlas; blank or 0 leaves a figure out, a negative weight ranks a lower figure higher (cost of living, rent, pollution). Every figure stays in the atlas's table either way.</p>
      <form data-submit="weights" data-act="weights">
        <div class="weights" data-key="parts">${PARTS.map(([k, title]) => weightField(k, figureName(k), title))}</div>
        ${groups.map((g) => html`<h3 data-key="h-${g}">${g.charAt(0).toUpperCase() + g.slice(1)}</h3><div class="weights" data-key="g-${g}">${FIGURES.filter((c) => (c.group ?? "other") === g).map((c) => weightField(c.name, label(c.name), c.name))}</div>`)}
        <button class="primary">Save weights</button>
      </form>
    </section>`
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
  if (c.shadowed.length > 0) return html`<span class="warn">never wins: ${c.shadowed.map((a) => `#${a}`).join(", ")} ${c.shadowed.length === 1 ? "takes" : "take"} every application it matches</span>`
  return html`<span class="ok">ok</span>`
}

// ------------------------------------------------------------------ cv roots

/** A file's format and type by its name; null for a file no CV can be. */
const FORMATS: [RegExp, string, string][] = [
  [/\.(md|markdown|txt)$/i, "markdown", "text/markdown"],
  [/\.pdf$/i, "pdf", "application/pdf"],
  [/\.docx$/i, "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
  [/\.doc$/i, "doc", "application/msword"],
]
const formatOf = (f: File): [string, string] | null => FORMATS.flatMap(([re, fmt, type]) => (re.test(f.name) ? [[fmt, type] as [string, string]] : []))[0] ?? null
const BLOB_MAX = 10 * 1024 * 1024

/** The open CVs (in the address, so a link opens them) and those whose text is being edited in place. */
const opened = (): number[] => (model.address.q.get("open") ?? "").split(",").map(Number).filter((n) => n > 0)
const editing = new Set<number>()
/** What a file dragged over the page would land on: a CV's id, 0 for a new CV, -1 for no drag. */
let over = -1

function cv(): Html {
  const count = new Map<number, number>()
  for (const p of picks()) if (p.root) count.set(p.root, (count.get(p.root) ?? 0) + 1)
  const def = Number(mine("cv_default_root_id") || 0)
  // In the order they were made: a rename never moves a strip from under the pointer.
  const rs = [...ids("cv_roots")].sort((a, b) => a - b)
  return html`<section class="card cv-roots${over === 0 ? " over" : ""}" data-key="roots"><h2>CVs</h2>
      <p class="hint">Drop CVs anywhere here: markdown, PDF or Word (.docx, .doc), the format read from the file. Dropped on a CV, a file is its next version. Click a CV to open it; double-click its text to edit right where you click, and Ctrl+S or Save keeps it.</p>
      <div class="row"><label class="button">Choose files<input type="file" multiple class="sr" accept=".md,.markdown,.txt,.pdf,.docx,.doc" data-act="files" data-on="change"></label>
        <button type="button" data-act="write">Write one</button></div>
      ${rs.length === 0 ? html`<p class="empty">No CVs yet. Drop one here, or let an agent add one over the MCP.</p>`
        : html`<div class="cv-list">${rs.map((id) => card(id, id === def, count.get(id) ?? 0))}</div>`}
    </section>`
}

/** One CV as a strip: its name editable in place, its facts; open, its addendum below. */
function card(id: number, isDefault: boolean, apps: number): Html {
  const format = str(value("cv_roots", id, "format"))
  const head = Number(value("cv_roots", id, "version_id") ?? 0)
  const v = (c: string): string => (head ? str(value("cv_versions", head, c)) : "")
  const open = opened().includes(id)
  return html`<article class="cv-card${open ? " open" : ""}${over === id ? " over" : ""}" data-key="c${id}" data-root="${id}">
    <header data-act="toggle" data-click data-id="${id}" aria-expanded="${String(open)}">
      <span class="chev" aria-hidden="true"></span>
      <input class="cv-name" value="${rootName(id)}" data-act="meta" data-col="name" data-on="change" data-id="${id}" aria-label="Name" spellcheck="false" autocomplete="off">
      <span class="tag">${format}</span>
      <span class="muted">${head ? `v${v("n")} · ${v("inserted_at").slice(0, 10)}` : "no versions yet"}</span>
      <span class="muted">${apps} application${apps === 1 ? "" : "s"}</span>
      ${isDefault ? html`<span class="tag">default</span>` : EMPTY}
      ${v("blob_sha") ? html`<a href="/blobs/${v("blob_sha")}?name=${encodeURIComponent(v("blob_name"))}" target="_blank" rel="noopener" class="ghost">${v("blob_name") || "the file"} ↗</a>` : EMPTY}
    </header>
    ${open ? addendum(id, format, head, isDefault) : EMPTY}
  </article>`
}

function addendum(id: number, format: string, head: number, isDefault: boolean): Html {
  const ed = editing.has(id)
  const profile = Number(value("cv_roots", id, "profile_id") ?? 0)
  const versions = ask<{ rows: Row[] }>("find", { table: "cv_versions", where: { root_id: id }, order: ["id", "desc"], cols: ["id", "n", "note", "actor", "blob_name", "inserted_at"], limit: 50 })?.rows ?? []
  return html`<div class="addendum" data-key="a${id}">
    <div class="row">
      <label>Slug <input value="${str(value("cv_roots", id, "slug"))}" data-act="meta" data-col="slug" data-on="change" data-id="${id}" class="mono narrow" spellcheck="false"></label>
      <label class="grow">Notes <input value="${str(value("cv_roots", id, "notes"))}" data-act="meta" data-col="notes" data-on="change" data-id="${id}"></label>
      ${isDefault ? html`<span class="tag">the default</span>` : html`<button type="button" data-act="default" data-id="${id}">Make default</button>`}
      <button type="button" class="danger" data-act="unroot" data-id="${id}">Delete…</button>
    </div>
    ${format === "composed" ? html`<p class="hint">Composed from ${profile ? html`the <b>${str(value("profiles", profile, "name"))}</b> profile's items` : "a profile"}: the kernel builds it for each application.</p>`
      : html`<pre class="cv-text${ed ? " editing" : ""}" data-act="edit-text" data-on="dblclick" data-id="${id}" data-empty="Nothing yet: double-click to write."${ed ? html` contenteditable="plaintext-only" data-morph="own" data-autofocus` : EMPTY}>${drafts.get<string>(`cv:${id}`) ?? (head ? str(value("cv_versions", head, format === "markdown" ? "body" : "text")) : "")}</pre>
      ${ed ? html`<div class="row"><button type="button" class="primary" data-act="save-text" data-id="${id}">Save</button><button type="button" class="ghost" data-act="cancel-text" data-id="${id}">Cancel</button>
        <span class="hint">Ctrl+S saves.${format === "markdown" ? "" : " The file stays as it is; this is its text as the rules, coverage and your agents read it."}</span></div>` : EMPTY}`}
    ${versions.length === 0 ? EMPTY : html`<details data-key="versions"><summary>${versions.length} version${versions.length === 1 ? "" : "s"}</summary><ol class="rows">${versions.map((x) => html`<li data-key="v${str(x.id)}">
      <b>v${str(x.n)}</b> <span class="muted">${str(x.inserted_at).slice(0, 10)} · ${str(x.actor)}</span>${x.blob_name ? html` <span>${str(x.blob_name)}</span>` : EMPTY}${x.note ? html` <span class="muted">${str(x.note)}</span>` : EMPTY}</li>`)}</ol></details>`}
  </div>`
}

/** Files to CVs: each a new CV named after it, or, dropped on a CV, that CV's next version (its format following the file). */
async function take(files: File[], onto: number): Promise<void> {
  for (const file of files) {
    const f = formatOf(file)
    if (!f) {
      notice("warn", `${file.name} is not a CV this can read: markdown, PDF, .docx or .doc.`)
      continue
    }
    if (file.size > BLOB_MAX) {
      notice("warn", `${file.name} is over 10 MiB.`)
      continue
    }
    let root = onto
    if (root === 0) root = await newRoot(file.name.replace(/\.[^.]+$/, ""), f[0])
    else if (str(value("cv_roots", root, "format")) !== f[0]) await put("cv_roots", { format: f[0] }, { id: root })
    if (f[0] === "markdown") await put("cv_versions", { root_id: root, body: await file.text(), blob_name: file.name })
    else await put("cv_versions", { root_id: root, blob_sha: await blob(file, f[1]), blob_name: file.name })
    if (!opened().includes(root)) setQuery("open", [...opened(), root].join(","))
  }
}

/** A new CV of `format`, its slug from its name and free; opened. */
async function newRoot(name: string, format: string): Promise<number> {
  const taken = new Set([...ids("cv_roots")].map((r) => str(value("cv_roots", r, "slug"))))
  const base = slug(name) || "cv"
  let s = base
  for (let n = 2; taken.has(s); n++) s = `${base}-${n}`
  const id = (await put("cv_roots", { name, slug: s, format })).id
  setQuery("open", [...opened(), id].join(","))
  return id
}

/** The bytes to /blobs (content-addressed: the same file again is the same sha); its sha. */
async function blob(file: File, type: string): Promise<string> {
  const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
  const res = await fetch("/blobs", { method: "PUT", headers: { "content-type": type, "x-csrf-token": csrf }, body: file, credentials: "same-origin" })
  if (!res.ok) throw new Error(res.status === 415 ? `${file.name}: the server does not take this kind of file.` : `The upload was refused (${res.status}).`)
  return ((await res.json()) as { sha: string }).sha
}

/** An edited text as the CV's next version: a markdown CV's body, or a file's text corrected beside the same file. */
function saveText(id: number): void {
  const el = document.querySelector<HTMLElement>(`.cv-card[data-root="${id}"] .cv-text`)
  if (!el) return
  const head = Number(value("cv_roots", id, "version_id") ?? 0)
  const markdown = str(value("cv_roots", id, "format")) === "markdown"
  const text = el.innerText.replace(/\n$/, "")
  const was = head ? str(value("cv_versions", head, markdown ? "body" : "text")) : ""
  editing.delete(id)
  drafts.drop(`cv:${id}`)
  if (text === was) return schedule()
  void put("cv_versions", markdown || !head ? { root_id: id, body: text, note: "edited here" }
    : { root_id: id, body: text, blob_sha: str(value("cv_versions", head, "blob_sha")), blob_name: str(value("cv_versions", head, "blob_name")) || null, note: "text edited here" })
    .then(() => notice("ok", `${rootName(id)} saved as its next version.`), failed)
  schedule()
}

// A text being edited is kept as it is typed; a CV with one kept opens back into editing it.
addEventListener("input", (ev) => {
  const el = (ev.target as Element | null)?.closest?.<HTMLElement>(".cv-text.editing")
  if (el) drafts.set(`cv:${el.dataset.id}`, el.innerText.replace(/\n$/, ""))
})
function resume(): void {
  const kept = [...ids("cv_roots")].filter((id) => !editing.has(id) && drafts.get(`cv:${id}`) !== null)
  if (kept.length === 0) return
  for (const id of kept) editing.add(id)
  setQuery("open", [...new Set([...opened(), ...kept])].join(","))
}

// A file dragged anywhere over the CVs page lands where it is let go: on a CV, or as a new one.
const onCvs = (): boolean => model.address.lens === "me" && model.address.sub === "cv"
const target = (ev: DragEvent): number => Number((ev.target as Element | null)?.closest?.<HTMLElement>(".cv-card")?.dataset.root ?? 0)
addEventListener("dragover", (ev) => {
  if (!onCvs() || !ev.dataTransfer?.types.includes("Files")) return
  ev.preventDefault()
  ev.dataTransfer.dropEffect = "copy"
  if (over !== target(ev)) (over = target(ev)), schedule()
})
addEventListener("dragleave", (ev) => {
  if (onCvs() && ev.relatedTarget === null) (over = -1), schedule()
})
addEventListener("drop", (ev) => {
  if (!onCvs() || !ev.dataTransfer?.files.length) return
  ev.preventDefault()
  over = -1
  schedule()
  void take([...ev.dataTransfer.files], target(ev)).catch(failed)
})
// Ctrl+S keeps every text being edited; the browser's save page is not what it means here.
addEventListener("keydown", (ev) => {
  if (!onCvs() || !(ev.ctrlKey || ev.metaKey) || ev.key.toLowerCase() !== "s") return
  ev.preventDefault()
  for (const id of [...editing]) saveText(id)
}, { capture: true })

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
        <label class="grow">When <input name="pattern" required data-act="check" data-on="input" data-position="${rs.length}" placeholder="country in [DE, AT, CH] &amp; field = :research" spellcheck="false" autocomplete="off" class="mono"></label>
        <label>use <select name="root_id">${rootOptions(null)}</select></label>
        <label>Name <input name="name" class="narrow"></label>
        <button class="primary">Add rule</button>
        <output class="verdict"></output></form>`}
      ${fs.length > 0 ? builder(fs) : EMPTY}
    </section>
    <section class="card" data-key="masks"><h2>Named masks</h2>
      <p class="hint">A mask is a pattern with a name; a rule names it like a field: <code>dach &amp; field = :research</code>.</p>
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
      ${multi.length === 0 ? html`<p class="empty">No unpinned application matches a second rule.</p>` : html`<ul class="rows">${multi.map((p) => html`<li data-key="a${p.application}">${appLink(p.application)}
          gets <b>${rootName(p.root)}</b> by #${String(p.arm)}; also matched
          ${[...new Set(p.also.map((a) => Number(value("cv_rules", a, "root_id") ?? 0)))].filter((r) => r && r !== p.root).map((r) => html`<button type="button" data-act="pin" data-app="${p.application}" data-root="${r}">${rootName(r)}</button>`)}
          ${p.root ? html`<button type="button" data-act="pin" data-app="${p.application}" data-root="${p.root}">Keep ${rootName(p.root)}</button>` : EMPTY}</li>`)}</ul>`}
    </section>
    ${broken.length === 0 ? EMPTY : html`<section class="card" data-key="broken"><h2>Needs a CV</h2>
      <ul class="rows">${broken.map((p) => html`<li data-key="b${p.application}">${appLink(p.application)}
        ${p.state === "stale" ? html`<span class="tag bad">pinned to a deleted CV</span>` : html`gets <a href="/me/cv?open=${String(p.root)}" data-nav>${rootName(p.root)}</a><span class="tag warn">no versions yet</span>`}</li>`)}</ul>
    </section>`}`
}

const appLink = (id: number): Html => {
  const no = str(value("applications", id, "no"))
  return html`<a href="/desk/${appItem(id)}" data-nav>#${no} ${str(value("applications", id, "company"))} ${str(value("applications", id, "role"))}</a>`
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
  enter() {
    if (model.address.sub === "cv") resume()
  },
  view,
  act(name, el, ev) {
    const id = Number(el.dataset.id ?? 0)
    const form = el as HTMLFormElement
    switch (name) {
      case "me-draft":
        draft = fromForm(form)
        drafts.set("me", draft)
        return schedule()
      case "me-discard":
        draft = null
        drafts.drop("me")
        schedule()
        // After the redraw puts the saved values back as the fields' defaults.
        return void requestAnimationFrame(() => el.closest("form")?.reset())
      case "me": {
        const d = fromForm(form)
        const x = d.text
        const iso = countriesIn(x.residence ?? "").codes[0] ?? ""
        const place = iso === "" ? null : ask<{ rows: Row[] }>("find", { table: "places", where: { iso2: iso, kind: "country" }, cols: ["id"], limit: 1 })?.rows[0]
        if (iso !== "" && !place) return notice("warn", `No country ${iso} in the world tables yet.`)
        draft = null
        drafts.drop("me")
        const codes = (k: string, regions = false): string | null => joined(countriesIn(x[k] ?? "", regions).codes)
        return save({
          citizenships: codes("citizenships"),
          work_permits: codes("work_permits"),
          prefer: codes("prefer"),
          avoid: codes("avoid"),
          notes: x.notes || null,
          residence_id: place ? Number(place.id) : null,
          regions: codes("regions", true),
          relocate: d.relocate,
          field: x.field?.trim() || null,
          subfields: joined(words(x.subfields ?? "")),
          work_modes: d.work_modes,
          employments: d.employments,
          pay_floor: num(x.pay_floor),
          pay_currency: (x.pay_currency ?? "").trim().toUpperCase() || null,
          available_on: x.available_on || null,
          notice_days: num(x.notice_days),
        }, form)
      }
      case "weights": {
        const w: Record<string, number> = {}
        for (const [k, x] of new FormData(form)) {
          const n = Number(x)
          if (x !== "" && Number.isFinite(n) && n !== 0) w[k] = n
        }
        return save({ weights: Object.keys(w).length === 0 ? null : JSON.stringify(w) })
      }
      case "lang": {
        const x = fields(form)
        return void resetAfter(form, () => put("languages", { level: x.level ?? "b2" }, { key: { code: (x.code ?? "").toLowerCase() } })).catch(failed)
      }
      case "level":
        return void put("languages", { level: (el as HTMLSelectElement).value }, { id }).catch(failed)
      case "unlang":
        return void drop("languages", id).catch(failed)
      case "toggle": {
        const open = opened().includes(id) ? opened().filter((x) => x !== id) : [...opened(), id]
        return setQuery("open", open.join(","))
      }
      case "meta": {
        const col = el.dataset.col ?? ""
        const x = (el as HTMLInputElement).value.trim()
        if (col === "name" && x === "") return schedule()
        return void put("cv_roots", { [col]: col === "slug" ? slug(x) : x || null }, { id }).catch(failed)
      }
      case "default":
        return save({ cv_default_root_id: id })
      case "unroot":
        if (!confirm(`Delete the CV ${rootName(id)}? Its versions stay on record; rules that name it stop matching.`)) return
        return void drop("cv_roots", id).catch(failed)
      case "files":
        return void take([...((el as HTMLInputElement).files ?? [])], 0).then(() => ((el as HTMLInputElement).value = "")).catch(failed)
      case "write":
        // A new markdown CV, open and being written: its first Save is its first version.
        return void newRoot("Untitled CV", "markdown").then((r) => (editing.add(r), schedule())).catch(failed)
      case "edit-text": {
        // Editable where it stands, the caret where the double-click landed.
        if (editing.has(id)) return
        editing.add(id)
        const e = ev as MouseEvent
        const at = document.caretPositionFromPoint?.(e.clientX, e.clientY)
        el.setAttribute("contenteditable", "plaintext-only")
        el.focus()
        if (at) getSelection()?.collapse(at.offsetNode, at.offset)
        return schedule()
      }
      case "save-text":
        return saveText(id)
      case "cancel-text":
        editing.delete(id)
        drafts.drop(`cv:${id}`)
        el.closest(".cv-card")?.querySelector(".cv-text")?.removeAttribute("contenteditable")
        return schedule()
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
