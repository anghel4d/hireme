// The views the desk derives from raw rows, ported from the Elixir that
// is still the reference: Hireme.Mask, Hireme.Theme, Hireme.Cv, the rail
// (Hireme.Pipeline), Hireme.Desk.focuses/2 and root/1, and the gym and
// net progress behind the lanes. Pure functions over plain rows; no
// kernel, no DOM, so a node test can hold them against the oracle.
// Keyword coverage is the kernel's: it comes in as `cover`.
//
// Shapes out are api.ts's, which is HiremeWeb.JSON's.

import type { Coverage, Doc, Focus, HeatVerdict, Identity, Lanes, Line, Method, Mode, Root, Rung, Settings } from "./api.ts"

// ---- raw rows, as the client holds them ----

export interface ItemRow { id: number; profile_id: number | null; kind: string; key: string; title: string; body: string; org: string; span: string; position: number }
export interface OverlayRow { lineage_id: number; item_id: number; mode: string; title: string | null; body: string | null; reason: string | null }
export interface ProfileRow { id: number; slug: string; name: string; headline: string; summary: string; user_id: number | null }
export interface VariantRow { id: number; job_app_id: number | null; profile_id: number | null; lineage_id: number | null; label: string; theme: Json }
export interface LineageRow { id: number; theme: Json }
export interface EventRow { id: number; job_app_id: number; kind: string; body: string; inserted_at: string }
export interface KvRow { namespace: string; key: string; value: string }
export interface NarrativeRow { id: number; user_id: number; body: string; version: number }
export interface StageRow { key: string; label: string; hint: string }
export interface BandRow { key: string; min: number; max: number }
export interface ProblemRow { id: number; platform: string; slug: string; title: string; topic: string; difficulty: string; url: string }
export interface RepRow { id: number; problem_id: number; done_on: string | null; minutes: number; outcome: string; note: string }
export interface NetRow { id: number; kind: string; channel: string; title: string; url: string; body: string; shipped_on: string | null }

/** The job row a focus opens, as the board's view holds it (predictions applied). */
export interface JobRow {
  id: number; company: string; role: string; location: string; listing: string; listing_url: string
  heat: number; status: string; stage: string; pips: string; stage_notes: Json; score_100: number
  next_action: string; next_due: string | null; stage_on: string | null; freshness: string; gate: string; fit: string
  keyword_hits: number; keyword_total: number; mask_hidden: number; mask_altered: number; mask_emphasized: number
  heat_override: boolean; heat_override_reason: string; profile_id: number
  batch: { code: string; fire: "hold" | "open_fire" } | null
}

/** Keyword coverage of `text`: the theme's targets when it names any (null: the listing's own words). */
export type Cover = (targets: readonly string[] | null, text: string) => Coverage

// ---- Elixir's string and order semantics ----

/** String.trim: Unicode whitespace at both ends, as JS's trim. */
const trim = (s: string) => s.trim()

/** Binary order, as SQLite and Erlang compare UTF-8: by code point, not UTF-16 unit. */
export function byBytes(a: string, b: string): number {
  if (a === b) return 0
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    const x = a.codePointAt(i) ?? 0
    const y = b.codePointAt(i) ?? 0
    if (x !== y) return x < y ? -1 : 1
    if (x > 0xffff) i++
  }
  return a.length - b.length
}

const capitalize = (s: string) => (s === "" ? s : s.charAt(0).toUpperCase() + s.slice(1).toLowerCase())

// ---- Theme ----

export interface Theme { lead: string | null; lead_reason: string | null; accent: string; density: string; targets: string[] }

const ACCENTS = ["ink", "signal", "paper"]
const DENSITIES = ["cv", "tight", "narrative"]

/** A stored JSON object, as text or already parsed; anything else is empty. */
export type Json = string | Record<string, unknown> | null | undefined

function jsonObject(raw: Json): Record<string, unknown> {
  let v: unknown = raw
  if (typeof raw === "string") {
    try {
      v = raw === "" ? null : JSON.parse(raw)
    } catch {
      v = null
    }
  }
  return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {}
}

/** Theme.parse over the stored JSON object. */
export function parseTheme(raw: Json): Theme {
  const map = raw === null || raw === undefined ? null : jsonObject(raw)
  if (!map) return { lead: null, lead_reason: null, accent: "ink", density: "cv", targets: [] }
  const text = (v: unknown) => (typeof v === "string" && trim(v) !== "" ? trim(v) : null)
  const choice = (v: unknown, allowed: string[], fallback: string) => (typeof v === "string" && allowed.includes(v) ? v : fallback)
  const words = (v: unknown) =>
    Array.isArray(v) ? v.map((w) => (w === null || w === undefined ? "" : trim(String(w)))).filter((w) => w !== "") : []
  return { lead: text(map["lead"]), lead_reason: text(map["lead_reason"]), accent: choice(map["accent"], ACCENTS, "ink"), density: choice(map["density"], DENSITIES, "cv"), targets: words(map["targets"]) }
}

/** An empty stored theme (nil or {}) leaves the variant's in place. */
function emptyStored(raw: Json): boolean {
  return raw === null || raw === undefined || Object.keys(jsonObject(raw)).length === 0
}

/** Desk.theme_of: the lineage's theme when it has one, else the variant's. */
export function themeOf(variant: VariantRow, lineage: LineageRow | undefined): Theme {
  return lineage && !emptyStored(lineage.theme) ? parseTheme(lineage.theme) : parseTheme(variant.theme)
}

// ---- Mask ----

export interface MaskLine extends Line { key: string; position: number }

const MODES = new Set(["hidden", "altered", "emphasized"])
const blankTo = (v: string | null, fallback: string) => (v === null || v === "" ? fallback : v)

/** Mask.apply: each item through its overlay, in (position, id) order. */
export function maskApply(items: readonly ItemRow[], overlays: readonly OverlayRow[]): MaskLine[] {
  const by = new Map<number, OverlayRow>()
  for (const o of overlays) if (MODES.has(o.mode)) by.set(o.item_id, o)
  const out = items.map((item) => {
    const o = by.get(item.id)
    const mode = (o ? o.mode : "canonical") as Mode
    const altered = mode === "altered" && o
    return {
      id: item.id, key: item.key, kind: item.kind,
      title: altered ? blankTo(o.title, item.title) : item.title,
      body: altered ? blankTo(o.body, item.body) : item.body,
      org: item.org ?? "", span: item.span ?? "", position: item.position,
      shown: mode !== "hidden", mode, reason: o ? o.reason : null,
      canonical_title: item.title, canonical_body: item.body,
    }
  })
  return stableSort(out, (a, b) => a.position - b.position || a.id - b.id)
}

/** Keywords.visible_text before its downcase, which the kernel does. */
export function visibleText(lines: readonly Line[]): string {
  return lines.filter((l) => l.shown).map((l) => `${l.title}\n${l.body}`).join("\n")
}

function stableSort<T>(xs: T[], cmp: (a: T, b: T) => number): T[] {
  return xs.map((x, i) => [x, i] as const).sort((a, b) => cmp(a[0], b[0]) || a[1] - b[1]).map((p) => p[0])
}

/** The line as HiremeWeb.JSON writes it. */
function line(l: MaskLine): Line {
  return { id: l.id, kind: l.kind, title: l.title, body: l.body, org: l.org, span: l.span, shown: l.shown, mode: l.mode, reason: l.reason, canonical_title: l.canonical_title, canonical_body: l.canonical_body }
}

// ---- Cv ----

const SECTIONS: readonly [string, string][] = [
  ["experience", "Experience"], ["project", "Projects"], ["education", "Education"], ["skill", "Skills"], ["timeline", "Timeline"],
]

/** Cv.compose: facts in the masthead, sections in their order, hidden lines in the tray. */
export function compose(profile: ProfileRow, resolved: readonly MaskLine[], theme: Theme, label: string, person: string | null): Doc {
  const summary = theme.lead ?? profile.summary
  const shown = resolved.filter((l) => l.shown)
  return {
    label, person, headline: profile.headline, summary,
    summary_canonical: summary === profile.summary ? null : profile.summary,
    summary_reason: theme.lead_reason,
    accent: theme.accent, density: theme.density,
    facts: shown.filter((l) => l.kind === "fact").map(line),
    sections: SECTIONS.flatMap(([kind, label]) => {
      const lines = shown.filter((l) => l.kind === kind)
      return lines.length === 0 ? [] : [{ kind, label, lines: lines.map(line) }]
    }),
    hidden: resolved.filter((l) => !l.shown).map(line),
  }
}

// ---- the rail ----

const PIP_STATE: Record<string, string> = { D: "done", A: "active", P: "pending", S: "skipped", B: "blocked" }

/** Desk.rail: the pips decoded (or the stage's initial rail), each rung with its note. */
export function rail(stages: readonly StageRow[], pips: string, stage: string, stageNotes: Json): Rung[] {
  const notes = jsonObject(stageNotes)
  const chars = [...pips]
  const decoded = chars.length === stages.length && chars.every((c) => c in PIP_STATE)
  const at = stages.findIndex((s) => s.key === stage)
  return stages.map((s, i) => ({
    key: s.key, label: s.label, hint: s.hint,
    state: decoded ? (PIP_STATE[chars[i] ?? ""] ?? "pending") : i < at ? "done" : i === at ? "active" : "pending",
    note: typeof notes[s.key] === "string" ? (notes[s.key] as string) : "",
  }))
}

// ---- focus and root ----

/** The rows one focus reads; the store finds them by key. */
export interface FocusRows {
  job: JobRow
  profile: ProfileRow
  variant: VariantRow
  lineage: LineageRow | undefined
  items: readonly ItemRow[]
  overlays: readonly OverlayRow[]
  events: readonly EventRow[]
  kv: readonly KvRow[]
  narrative: NarrativeRow | undefined
  person: string | null
  verdict: Omit<HeatVerdict, "override" | "override_reason">
  stages: readonly StageRow[]
  bands: readonly BandRow[]
}

/** The lines a lineage resolves to, shared by every application on it. */
export interface Resolved { lines: MaskLine[]; text: string; root: string }

export function resolve(items: readonly ItemRow[], overlays: readonly OverlayRow[]): Resolved {
  const lines = maskApply(items, overlays)
  return { lines, text: visibleText(lines), root: visibleText(maskApply(items, [])) }
}

/** Desk.focuses/2 for one application, in HiremeWeb.JSON.focus/1's shape. */
export function focus(r: FocusRows, resolved: Resolved, cover: Cover): Focus {
  const j = r.job
  const theme = themeOf(r.variant, r.lineage)
  const targets = theme.targets.length > 0 ? theme.targets : null
  const stage = r.stages.find((s) => s.key === j.stage)
  return {
    job: {
      id: j.id, code: `JobApp${j.id}`, company: j.company, role: j.role, location: j.location,
      listing: j.listing, listing_url: j.listing_url, heat: j.heat, status: j.status,
      stage: j.stage, stage_label: stage?.label ?? "", stage_hint: stage?.hint ?? "",
      pips: j.pips, score_100: j.score_100, band: r.bands.find((b) => j.score_100 >= b.min && j.score_100 <= b.max)?.key ?? "",
      next_action: j.next_action, next_due: j.next_due, stage_on: j.stage_on,
      freshness: j.freshness, gate: j.gate, fit: j.fit,
      keyword_hits: j.keyword_hits, keyword_total: j.keyword_total,
      mask_hidden: j.mask_hidden, mask_altered: j.mask_altered, mask_emphasized: j.mask_emphasized,
      batch: j.batch,
    },
    profile: { id: r.profile.id, slug: r.profile.slug, name: r.profile.name, headline: r.profile.headline, summary: r.profile.summary },
    variant: { id: r.variant.id, label: r.variant.label },
    rail: rail(r.stages, j.pips, j.stage, j.stage_notes),
    events: [...r.events].sort((a, b) => b.id - a.id).slice(0, 12).map((e) => ({ id: e.id, kind: e.kind, body: e.body })),
    cv: compose(r.profile, resolved.lines, theme, r.variant.label, r.person),
    narrative: r.narrative ? { id: r.narrative.id, body: r.narrative.body, version: r.narrative.version } : null,
    coverage: cover(targets, resolved.text),
    root_coverage: cover(targets, resolved.root),
    kv: kvList(r.kv, `app:${j.id}`),
    masks: resolved.lines.filter((l) => l.mode !== "canonical").map(line),
    heat: { ...r.verdict, override: j.heat_override, override_reason: j.heat_override_reason },
  }
}

/** A namespace's pairs in key order, as Kv.list reads them. */
export function kvList(kv: readonly KvRow[], namespace: string): { key: string; value: string }[] {
  return kv.filter((p) => p.namespace === namespace).sort((a, b) => byBytes(a.key, b.key)).map((p) => ({ key: p.key, value: p.value }))
}

/** Kv.get("global", "candidate"): the person a CV is for. */
export function person(kv: readonly KvRow[]): string | null {
  return kv.find((p) => p.namespace === "global" && p.key === "candidate")?.value ?? null
}

/** A profile's lines: its own items and the shared ones, in (position, id) order. */
export function profileItems(items: readonly ItemRow[], profileId: number): ItemRow[] {
  return items.filter((i) => i.profile_id === null || i.profile_id === profileId).sort((a, b) => a.position - b.position || a.id - b.id)
}

/** Desk.root/1: every line as written, under the profile's root variant (or "Root"). */
export function root(profile: ProfileRow, items: readonly ItemRow[], variants: readonly VariantRow[], kv: readonly KvRow[], narrative: NarrativeRow | undefined): Root {
  const variant = variants.find((v) => v.profile_id === profile.id && v.job_app_id === null)
  const theme = parseTheme(variant?.theme ?? null)
  return {
    profile: { id: profile.id, slug: profile.slug, name: profile.name, headline: profile.headline, summary: profile.summary },
    cv: compose(profile, maskApply(profileItems(items, profile.id), []), theme, variant?.label ?? "Root", person(kv)),
    kv: kvList(kv, "global"),
    narrative: narrative ? { id: narrative.id, body: narrative.body, version: narrative.version } : null,
  }
}

// ---- gym and net ----

const GYM_PLATFORMS = ["leetcode", "codeforces", "other"]
const GYM_TOPICS = ["arrays", "graphs", "strings", "dp", "trees", "systems", "other"]
const GYM_DIFFICULTIES = ["easy", "medium", "hard", "unknown"]
const GYM_OUTCOMES = ["solved", "attempt", "skip"]
const NET_KINDS = ["observer", "artifact", "post", "draft"]
const NET_CHANNELS = ["broadside", "x", "other"]

const gymLabel = (k: string) => (k === "dp" ? "DP" : k === "leetcode" ? "LeetCode" : k === "codeforces" ? "Codeforces" : capitalize(k))
const netLabel = (k: string) => (k === "x" ? "X" : capitalize(k))
const options = (keys: readonly string[], label: (k: string) => string) => keys.map((key) => ({ key, label: label(key) }))

/** ISO day arithmetic on "YYYY-MM-DD". */
export function addDays(iso: string, n: number): string {
  return new Date(Date.parse(`${iso}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10)
}

/** Gym.target: kv gym/daily_target when it is a whole number 1..30, else 3. */
function gymTarget(kv: readonly KvRow[]): number {
  const v = kv.find((p) => p.namespace === "gym" && p.key === "daily_target")?.value
  if (v === undefined || !/^[+-]?\d+$/.test(v)) return 3
  const n = Number.parseInt(v, 10)
  return n >= 1 && n <= 30 ? n : 3
}

/** Gym.progress/1 and Net.progress/1 as the lanes' gym and net halves; the heat half is the kernel's. */
export function lanes(today: string, kv: readonly KvRow[], problems: readonly ProblemRow[], reps: readonly RepRow[], net: readonly NetRow[], heat: Lanes["heat"]): Lanes {
  const target = gymTarget(kv)
  const week = addDays(today, -6)
  const solved = reps.filter((r) => r.outcome === "solved")
  const solvedWeek = solved.filter((r) => r.done_on !== null && r.done_on >= week).length
  const days = new Set(solved.map((r) => r.done_on))
  let day = days.has(today) ? today : addDays(today, -1)
  let streak = 0
  while (days.has(day)) {
    streak++
    day = addDays(day, -1)
  }
  const problem = new Map(problems.map((p) => [p.id, p]))
  const topicCount = new Map<string, number>()
  for (const r of solved) {
    const t = problem.get(r.problem_id)?.topic
    if (t !== undefined) topicCount.set(t, (topicCount.get(t) ?? 0) + 1)
  }
  const recent = [...reps]
    .sort((a, b) => byBytes(b.done_on ?? "", a.done_on ?? "") || b.id - a.id)
    .slice(0, 40)
    .map((r) => {
      const p = problem.get(r.problem_id)
      return { id: r.id, done_on: r.done_on ?? "", outcome: r.outcome, minutes: r.minutes, note: r.note, title: p?.title ?? "", url: p?.url ?? "", platform: p?.platform ?? "", topic: p?.topic ?? "", difficulty: p?.difficulty ?? "" }
    })
  const lane = trim(kv.find((p) => p.namespace === "net" && p.key === "broadside_lane")?.value ?? "")
  return {
    gym: {
      target, streak,
      solved_today: solved.filter((r) => r.done_on === today).length,
      solved_week: solvedWeek,
      score: Math.min(100, Math.round((solvedWeek / (target * 7)) * 100)),
      topics: GYM_TOPICS.map((key) => ({ key, label: gymLabel(key), count: topicCount.get(key) ?? 0 })),
      recent,
      platforms: options(GYM_PLATFORMS, gymLabel), topics_all: options(GYM_TOPICS, gymLabel),
      difficulties: options(GYM_DIFFICULTIES, gymLabel), outcomes: options(GYM_OUTCOMES, gymLabel),
    },
    net: {
      lane,
      shipped_week: net.filter((e) => (e.kind === "artifact" || e.kind === "post") && e.shipped_on !== null && e.shipped_on >= week).length,
      drafts: net.filter((e) => e.kind === "draft").length,
      observer_runs: net.filter((e) => e.kind === "observer").length,
      recent: [...net].sort((a, b) => b.id - a.id).slice(0, 40).map((e) => ({ id: e.id, kind: e.kind, channel: e.channel, title: e.title, url: e.url, body: e.body, shipped_on: e.shipped_on })),
      kinds: options(NET_KINDS, netLabel), channels: options(NET_CHANNELS, netLabel),
    },
    heat,
  }
}

// ---- the account page ----

export interface AcctRow { id: number; name: string; me: number; recovery_left: number; fresh_until: number | null; sign_in_methods: string }
export interface AcctKeyRow { id: number; key_id: string; name: string; display: string; scope: string; created_at: string; last_used_at: string | null; expires_at: string | null; revoked_at: string | null; live: boolean }
export interface AcctSessionRow { id: number; authenticated_at: string; last_seen_at: string; expires_at: string; mfa_at: string | null; ip: string; user_agent: string }
export interface AcctIdentityRow { id: number; provider: string; display: string; created_at: string }
export interface AcctFactorRow { id: number; kind: string; name: string; created_at: string; last_used_at: string | null; backed_up: boolean; transports: string }

const lines = (s: string) => s.split("\n").filter((x) => x !== "")

/** The Account page's document, as /api/account answered it: `now` in unix seconds decides freshness. */
export function account(a: AcctRow, keys: readonly AcctKeyRow[], sessions: readonly AcctSessionRow[], identities: readonly AcctIdentityRow[], factors: readonly AcctFactorRow[], now: number): Settings {
  return {
    account: { id: a.id, name: a.name },
    keys: keys.map((k) => ({ ...k })),
    sessions: sessions.map((s) => ({ ...s, current: s.id === a.me })),
    security: {
      methods: factors.map((f) => ({ id: f.id, kind: f.kind as Method["kind"], name: f.name, created_at: f.created_at, last_used_at: f.last_used_at, backed_up: f.backed_up, transports: lines(f.transports) })),
      recovery_codes_left: a.recovery_left,
      fresh: a.fresh_until !== null && now < a.fresh_until,
    },
    identities: identities.map((i) => ({ ...i, provider: i.provider as Identity["provider"] })),
    sign_in_methods: lines(a.sign_in_methods) as Identity["provider"][],
  }
}
