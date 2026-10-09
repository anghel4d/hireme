// Parity of the client's documents (assets/js/compose.ts) with the Elixir
// that stays the reference: the same raw rows in must give the same focus,
// root and lanes documents out. The rows and the expected documents come
// from the oracle (test/oracle/run.exs), for the canonical fixture or a
// seeded random desk after random ops:
//
//   MIX_ENV=test mix run --no-start test/oracle/run.exs --out DIR --today 2026-10-09 --seed N --ops 80
//   esbuild bench/compose.ts --bundle --platform=node --format=esm --outfile=DIR/compose.mjs
//   node DIR/compose.mjs DIR/seed-N.jsonl [...]
//
// Keyword coverage is the kernel's contract, so it is fed from the
// oracle's keywords lines. Exits non-zero on any mismatch.

import { readFileSync } from "node:fs"
import * as C from "../assets/js/compose.ts"

let failed = 0
for (const file of process.argv.slice(2)) failed += check(file)
process.exit(failed > 0 ? 1 : 0)

function check(file: string): number {
  const lines = readFileSync(file, "utf8").split("\n").filter((l) => l !== "").map((l) => JSON.parse(l))
  const tables: Record<string, any[]> = {}
  const want: Record<string, Map<number, any>> = { focus: new Map(), root: new Map() }
  const keywords = new Map<number, any>()
  let lanes: any = null
  let meta: any = null
  for (const o of lines) {
    if (o.kind === "table") tables[o.table] = o.rows
    else if (o.kind === "focus" || o.kind === "root") want[o.kind]!.set(o.id, o.value)
    else if (o.kind === "keywords") keywords.set(o.id, o)
    else if (o.kind === "lanes") lanes = o.value
    else if (o.kind === "meta") meta = o
    else if (o.kind === "verdict") (want["verdict"] ??= new Map()).set(o.id, o)
  }
  const iso = (d: number | null) => (d === null || d === undefined ? null : new Date(d * 86_400_000).toISOString().slice(0, 10))
  const stamp = (s: number | null) => (s === null || s === undefined ? null : new Date(s * 1000).toISOString().replace(".000Z", "Z"))
  const today = iso(meta.today) as string
  const T = (n: string) => tables[n] ?? []

  const stages = [
    ["discovered", "Discovered", "Listing captured"], ["freshness", "Freshness", "Open, thin, closed, or blocked"], ["gated", "Gated", "Pursue, maybe, or skip"],
    ["in_batch", "In batch", "Named batch"], ["draft_ready", "Draft ready", "Tailored CV drafted"], ["fire_ready", "Fire ready", "Packed. Submit stays locked."],
    ["open_fire", "Open fire", "Batch named. Submit is allowed."], ["submitted", "Submitted", "Sent by hand. This desk does not submit."], ["reply", "Reply", "Reply or interview"], ["closed", "Closed", "Done"],
  ].map(([key, label, hint]) => ({ key: key!, label: label!, hint: hint! }))
  const bands = [["frontier", 100, 100], ["labs", 90, 99], ["big_tech", 85, 89], ["systems", 70, 84], ["craft", 55, 69], ["mid", 40, 54], ["thin", 20, 39], ["kill", 0, 19]].map(([key, min, max]) => ({ key: key as string, min: min as number, max: max as number }))

  const items: C.ItemRow[] = T("items")
  const profiles = new Map<number, C.ProfileRow>(T("profiles").map((p) => [p.id, p]))
  const variants: C.VariantRow[] = T("cv_variants")
  const lineages = new Map<number, C.LineageRow>(T("cv_lineages").map((l) => [l.id, l]))
  const overlays: C.OverlayRow[] = T("overlays")
  const events: C.EventRow[] = T("events").map((e) => ({ ...e, inserted_at: stamp(e.inserted_at) }))
  const kv: C.KvRow[] = T("kv_pairs")
  const narratives: C.NarrativeRow[] = T("narratives")
  const batches = new Map<number, any>(T("batches").map((b) => [b.id, b]))

  // Normalize the oracle's day numbers and seconds to the client's strings.
  function norm(v: any, path: string): any {
    if (Array.isArray(v)) return v.map((x) => norm(x, path))
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, norm(x, `${path}.${k}`)]))
    if (typeof v === "number" && /\.(next_due|stage_on|done_on|shipped_on|leftover_noted_on|today)$/.test(path)) return iso(v)
    if (typeof v === "number" && /\.at$/.test(path)) return stamp(v)
    return v
  }

  let bad = 0
  function diff(a: any, b: any, path: string, out: string[]): void {
    if (out.length > 8) return
    if (a === b) return
    if (typeof a === "number" && typeof b === "number" && Math.abs(a - b) < 1e-9) return
    if (Array.isArray(a) && Array.isArray(b)) {
      if (a.length !== b.length) out.push(`${path}: length ${a.length} != ${b.length}`)
      for (let i = 0; i < Math.min(a.length, b.length); i++) diff(a[i], b[i], `${path}[${i}]`, out)
      return
    }
    if (a && b && typeof a === "object" && typeof b === "object") {
      for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
        if (!(k in a)) out.push(`${path}.${k}: missing in ours`)
        else if (!(k in b)) out.push(`${path}.${k}: extra in ours`)
        else diff(a[k], b[k], `${path}.${k}`, out)
      }
      return
    }
    out.push(`${path}: ours ${JSON.stringify(a)?.slice(0, 120)} != ${JSON.stringify(b)?.slice(0, 120)}`)
  }

  const report = (what: string, ours: any, theirs: any) => {
    const out: string[] = []
    diff(ours, norm(theirs, ""), "", out)
    if (out.length > 0) {
      bad++
      if (bad <= 6) console.log(`MISMATCH ${what}\n  ${out.join("\n  ")}`)
    }
  }

  const t0 = performance.now()
  let n = 0
  for (const [id, theirs] of want.focus) {
    const job = T("job_apps").find((j) => j.id === id)
    const variant = variants.find((v) => v.job_app_id === id)!
    const profile = profiles.get(job.profile_id)!
    const b = job.batch_id ? batches.get(job.batch_id) : null
    const kw = keywords.get(id)
    const lineage = variant.lineage_id === null ? undefined : lineages.get(variant.lineage_id)
    const resolved = C.resolve(C.profileItems(items, profile.id), overlays.filter((o) => o.lineage_id === variant.lineage_id))
    const v = want["verdict"]!.get(id)
    const { id: _i, kind: _k, ...verdict } = v
    let call = 0
    const f = C.focus(
      {
        job: { ...job, stage: job.current_stage, next_due: iso(job.next_due), stage_on: iso(job.stage_on), batch: b ? { code: b.code, fire: b.fire } : null },
        profile, variant, lineage, items: [], overlays: [],
        events: events.filter((e) => e.job_app_id === id), kv,
        narrative: profile.user_id === null ? undefined : narratives.find((x) => x.user_id === profile.user_id),
        person: C.person(kv), verdict, stages, bands,
      },
      resolved,
      () => (call++ === 0 ? { hits: kw.hits, misses: kw.misses } : { hits: kw.root_hits, misses: kw.root_misses }),
    )
    report(`focus ${id}`, f, theirs)
    n++
  }
  const t1 = performance.now()
  for (const [id, theirs] of want.root) {
    const p = profiles.get(id)!
    report(`root ${id}`, C.root(p, items, variants, kv, p.user_id === null ? undefined : narratives.find((x) => x.user_id === p.user_id)), theirs)
  }
  if (lanes) {
    const l = C.lanes(today, kv, T("gym_problems"), T("gym_reps").map((r) => ({ ...r, done_on: iso(r.done_on) })), T("net_entries").map((e) => ({ ...e, shipped_on: iso(e.shipped_on) })), { companies: [], vendors: [] })
    report("lanes.gym", { ...l.gym, platforms: undefined, topics_all: undefined, difficulties: undefined, outcomes: undefined }, { ...lanes.gym, platforms: undefined, topics_all: undefined, difficulties: undefined, outcomes: undefined })
    report("lanes.net", { ...l.net, kinds: undefined, channels: undefined }, { ...lanes.net, kinds: undefined, channels: undefined })
  }
  console.log(`${file}: ${n} focuses, ${want.root.size} roots, lanes ${lanes ? "yes" : "no"}; mismatching documents: ${bad}; compose ${((t1 - t0) / Math.max(n, 1) * 1000).toFixed(0)} µs per focus`)
  return bad
}
