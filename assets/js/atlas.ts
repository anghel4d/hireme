// Career geography. Cities and the holder arrive as rows. This view only
// scores them: passports, languages, and the field are never named here
// except as the country table the scorer reads. Hireme.Geography is the spec.

import type { AtlasCountry, AtlasPlace, AtlasProfile, AtlasRows } from "./store.ts"

export interface Weights {
  energy: number
  qol: number
  afford: number
  lang: number
  route: number
  tech: number
  ease: number
}

const AXES = ["energy", "qol", "afford", "lang", "route", "tech", "ease"] as const
type Axis = (typeof AXES)[number]

const AXIS_LABEL: Record<Axis, string> = {
  energy: "Energy use",
  qol: "Quality of life",
  afford: "Affordability",
  lang: "Language",
  route: "Right to live",
  tech: "Tech scene",
  ease: "Online paperwork",
}

const PRESETS: { name: string; weights: Weights }[] = [
  { name: "Balanced", weights: { energy: 3, qol: 3, afford: 2, lang: 3, route: 3, tech: 3, ease: 2 } },
  { name: "Career first", weights: { energy: 1, qol: 2, afford: 1, lang: 2, route: 3, tech: 5, ease: 1 } },
  { name: "Cheap and calm", weights: { energy: 1, qol: 4, afford: 5, lang: 2, route: 3, tech: 0, ease: 2 } },
  { name: "Zero friction", weights: { energy: 1, qol: 2, afford: 1, lang: 5, route: 5, tech: 1, ease: 5 } },
  { name: "Energy first", weights: { energy: 5, qol: 2, afford: 1, lang: 1, route: 2, tech: 1, ease: 1 } },
  { name: "Best life", weights: { energy: 2, qol: 5, afford: 1, lang: 2, route: 2, tech: 1, ease: 1 } },
]

const REGION: Record<string, string> = {
  south: "Southern Europe",
  west: "Western Europe",
  central: "Central Europe",
  nordic: "Nordics & Baltics",
  east: "Eastern Europe & Balkans",
}

interface Country {
  name: string
  adjective: string
  people: string
  eu: boolean
  eea: boolean
  youth: boolean
  lang: string | null
}

const COUNTRIES: Record<string, Country> = {
  AT: { name: "Austria", adjective: "Austrian", people: "Austrians", eu: true, eea: true, youth: false, lang: "de" },
  AU: { name: "Australia", adjective: "Australian", people: "Australians", eu: false, eea: false, youth: true, lang: "en" },
  BE: { name: "Belgium", adjective: "Belgian", people: "Belgians", eu: true, eea: true, youth: false, lang: "fr" },
  BG: { name: "Bulgaria", adjective: "Bulgarian", people: "Bulgarians", eu: true, eea: true, youth: false, lang: null },
  CA: { name: "Canada", adjective: "Canadian", people: "Canadians", eu: false, eea: false, youth: true, lang: "en" },
  CH: { name: "Switzerland", adjective: "Swiss", people: "Swiss", eu: false, eea: false, youth: false, lang: "de" },
  CY: { name: "Cyprus", adjective: "Cypriot", people: "Cypriots", eu: true, eea: true, youth: false, lang: "en" },
  CZ: { name: "Czechia", adjective: "Czech", people: "Czechs", eu: true, eea: true, youth: false, lang: null },
  DE: { name: "Germany", adjective: "German", people: "Germans", eu: true, eea: true, youth: false, lang: "de" },
  DK: { name: "Denmark", adjective: "Danish", people: "Danes", eu: true, eea: true, youth: false, lang: "en" },
  EE: { name: "Estonia", adjective: "Estonian", people: "Estonians", eu: true, eea: true, youth: false, lang: "en" },
  ES: { name: "Spain", adjective: "Spanish", people: "Spaniards", eu: true, eea: true, youth: false, lang: null },
  FI: { name: "Finland", adjective: "Finnish", people: "Finns", eu: true, eea: true, youth: false, lang: "en" },
  FR: { name: "France", adjective: "French", people: "French", eu: true, eea: true, youth: false, lang: "fr" },
  GB: { name: "United Kingdom", adjective: "British", people: "Britons", eu: false, eea: false, youth: false, lang: "en" },
  GR: { name: "Greece", adjective: "Greek", people: "Greeks", eu: true, eea: true, youth: false, lang: null },
  HR: { name: "Croatia", adjective: "Croatian", people: "Croatians", eu: true, eea: true, youth: false, lang: null },
  HU: { name: "Hungary", adjective: "Hungarian", people: "Hungarians", eu: true, eea: true, youth: false, lang: null },
  IE: { name: "Ireland", adjective: "Irish", people: "Irish", eu: true, eea: true, youth: false, lang: "en" },
  IN: { name: "India", adjective: "Indian", people: "Indians", eu: false, eea: false, youth: true, lang: "en" },
  IS: { name: "Iceland", adjective: "Icelandic", people: "Icelanders", eu: false, eea: true, youth: true, lang: "en" },
  IT: { name: "Italy", adjective: "Italian", people: "Italians", eu: true, eea: true, youth: false, lang: null },
  JP: { name: "Japan", adjective: "Japanese", people: "Japanese", eu: false, eea: false, youth: true, lang: null },
  KR: { name: "South Korea", adjective: "South Korean", people: "South Koreans", eu: false, eea: false, youth: true, lang: null },
  LT: { name: "Lithuania", adjective: "Lithuanian", people: "Lithuanians", eu: true, eea: true, youth: false, lang: null },
  LU: { name: "Luxembourg", adjective: "Luxembourgish", people: "Luxembourgers", eu: true, eea: true, youth: false, lang: "fr" },
  LV: { name: "Latvia", adjective: "Latvian", people: "Latvians", eu: true, eea: true, youth: false, lang: null },
  NL: { name: "Netherlands", adjective: "Dutch", people: "Dutch", eu: true, eea: true, youth: false, lang: "en" },
  NO: { name: "Norway", adjective: "Norwegian", people: "Norwegians", eu: false, eea: true, youth: false, lang: "en" },
  NZ: { name: "New Zealand", adjective: "New Zealand", people: "New Zealanders", eu: false, eea: false, youth: true, lang: "en" },
  PL: { name: "Poland", adjective: "Polish", people: "Poles", eu: true, eea: true, youth: false, lang: null },
  PT: { name: "Portugal", adjective: "Portuguese", people: "Portuguese", eu: true, eea: true, youth: false, lang: null },
  RO: { name: "Romania", adjective: "Romanian", people: "Romanians", eu: true, eea: true, youth: false, lang: "ro" },
  SE: { name: "Sweden", adjective: "Swedish", people: "Swedes", eu: true, eea: true, youth: false, lang: "en" },
  SI: { name: "Slovenia", adjective: "Slovenian", people: "Slovenians", eu: true, eea: true, youth: false, lang: null },
  SK: { name: "Slovakia", adjective: "Slovak", people: "Slovaks", eu: true, eea: true, youth: false, lang: null },
  US: { name: "United States", adjective: "American", people: "Americans", eu: false, eea: false, youth: false, lang: "en" },
}

const LANG_NAME: Record<string, string> = {
  fr: "French",
  en: "English",
  de: "German",
  ro: "Romanian",
  other: "Local language",
}

const TECH = [
  "",
  "Small tech market; mostly remote work from here.",
  "Solid tech scene with real local employers.",
  "Major European tech and AI hub.",
]
const EASE = [
  "",
  "Expect several in-person appointments (registration, tax ID, sometimes police or bank visits).",
  "One or two in-person visits; the rest is online or by letter.",
  "Mostly online, or a single office visit.",
]

const COST_FULL = { x0: 40, x1: 175, y0: -8, y1: 108 }
const ENERGY_FULL = { x0: Math.log10(7000), x1: Math.log10(190000), y0: -8, y1: 108 }
const COST_MED = 81.3
const MEDY = 50
/** EU average primary energy per person, kWh a year. Hireme.Geography.eu_energy/0. */
const EU_ENERGY = 35318
const ENERGY_LO = Math.log10(8000)
const ENERGY_HI = Math.log10(160000)
const PL = { l: 58, r: 16, t: 14, b: 46, w: 1000, h: 620 }
const NS = "http://www.w3.org/2000/svg"

interface Parts {
  energy: number
  qol: number
  afford: number
  lang: number
  route: number
  tech: number
  ease: number
}

interface Reading {
  key: string
  label: string
  short: string
  tone: string
  score: number
  text: string
}

interface Filters {
  free: boolean
  lang: boolean
  tech: boolean
  remote: boolean
  covered: boolean
  cell: [string, string] | null
}

const EMPTY_WEIGHTS: Weights = { energy: 5, qol: 3, afford: 2, lang: 3, route: 3, tech: 3, ease: 2 }

function energyNorm(kwh: number): number {
  const t = (Math.log10(kwh) - ENERGY_LO) / (ENERGY_HI - ENERGY_LO)
  return Math.max(0, Math.min(1, t))
}

function fmtK(kwh: number): string {
  return Math.round(kwh).toLocaleString("en-US")
}

function codes(text: string): string[] {
  return text.split(",").map((s) => s.trim()).filter((s) => s !== "")
}

function known(code: string): Country | null {
  return COUNTRIES[code] ?? null
}

function euCode(code: string): boolean {
  return known(code)?.eu === true
}

function holderCodes(profile: AtlasProfile | null, field: "citizenships" | "languages"): string[] {
  return codes(profile?.[field] ?? "")
}

function euHolder(profile: AtlasProfile | null): boolean {
  return holderCodes(profile, "citizenships").some(euCode)
}

function eeaHolder(profile: AtlasProfile | null): boolean {
  return holderCodes(profile, "citizenships").some((code) => {
    const c = known(code)
    return c?.eu === true || c?.eea === true
  })
}

function youthCountries(profile: AtlasProfile | null): Country[] {
  return holderCodes(profile, "citizenships").flatMap((code) => {
    const c = known(code)
    return c?.youth ? [c] : []
  })
}

function home(place: AtlasPlace, profile: AtlasProfile | null): boolean {
  const country = place.country.toLowerCase()
  return holderCodes(profile, "citizenships").some((code) => known(code)?.name.toLowerCase() === country)
}

function spoken(profile: AtlasProfile | null): string[] {
  return holderCodes(profile, "languages").filter((code) => code === "fr" || code === "en" || code === "de" || code === "ro")
}

function homeLangs(profile: AtlasProfile | null): string[] {
  return holderCodes(profile, "citizenships").flatMap((code) => {
    const lang = known(code)?.lang
    return lang === "fr" || lang === "en" || lang === "de" || lang === "ro" ? [lang] : []
  })
}

function joinOr(items: string[]): string {
  if (items.length <= 1) return items[0] ?? ""
  if (items.length === 2) return `${items[0]} or ${items[1]}`
  return `${items.slice(0, -1).join(", ")} or ${items[items.length - 1]}`
}

function routeOf(place: AtlasPlace, profile: AtlasProfile | null): Reading {
  if (home(place, profile)) {
    return { key: "home", label: "Your own country", short: "Home", tone: "good", score: 1, text: `You're a citizen of ${place.country}. Nothing to apply for.` }
  }
  if (place.mobility === "eu" && euHolder(profile)) {
    const adjectives = holderCodes(profile, "citizenships").filter(euCode).map((code) => known(code)?.adjective ?? code)
    const text = adjectives.length === 1
      ? `Move with your ${adjectives[0]} passport. Register locally within about three months; no visa or permit.`
      : `Move with your EU passports (${adjectives.join(", ")}). Register locally within about three months; no visa or permit.`
    return { key: "eu", label: "EU free movement", short: "Free", tone: "good", score: 1, text }
  }
  if (place.mobility === "eea" && eeaHolder(profile)) {
    const text = euHolder(profile)
      ? "Outside the EU but in the EEA, so your EU passport works the same way: register locally, no permit."
      : `Your ${holderCodes(profile, "citizenships").map(known).find((c) => c && c.eea && !c.eu)?.adjective ?? "EEA"} passport is EEA free movement: register locally, no permit.`
    return { key: "eea", label: "EEA free movement", short: "Free", tone: "good", score: 1, text }
  }
  if (place.mobility === "ch" && euHolder(profile)) {
    return {
      key: "ch",
      label: "Swiss free-movement agreement",
      short: "Contract",
      tone: "warn",
      score: 0.8,
      text: "EU citizens may enter and look for work without a permit. A Swiss job contract of a year or more gets a B permit valid for five years, applied for alongside the employer. Self-employment also qualifies if you can show a real, viable business. Register in person at the commune within 14 days of arriving.",
    }
  }
  if (place.mobility === "uk" && youthCountries(profile).length > 0) {
    const youth = youthCountries(profile)
    const people = joinOr(youth.map((c) => c.people))
    const adjectives = youth.map((c) => c.adjective)
    const label = adjectives.length === 1 ? `UK Youth Mobility (${adjectives[0]} passport)` : `UK Youth Mobility (${adjectives.join(", ")} passports)`
    const body = `${people} aged 18 to 35 can apply for the Youth Mobility Scheme: up to three years, no sponsor or job offer, employment or limited self-employment allowed. Costs are an application fee, the health surcharge paid up front, and proof of about £2,500 in savings. Staying longer needs a sponsored work visa.`
    const text = euHolder(profile) ? `The EU passport gives no right to live here. ${body}` : body
    return { key: "uk", label, short: "Visa", tone: "warn", score: 0.6, text }
  }
  return { key: "permit", label: "Residence permit", short: "Permit", tone: "bad", score: 0.3, text: permitText(place) }
}

function permitText(place: AtlasPlace): string {
  if (place.mobility === "eu" || place.mobility === "eea") {
    const bloc = place.mobility === "eu" ? "EU" : "EEA"
    return `This country is in the ${bloc}. None of the passports on file grant free movement here, so living here means a national residence permit.`
  }
  if (place.mobility === "ch") return "No Swiss free-movement agreement from the passports on file. A national permit is the path in."
  if (place.mobility === "uk") return "No Youth Mobility passport is on file. A sponsored work visa is the path in."
  return "Visa-free visits, but living there means a national residence permit, usually with in-person steps."
}

function languageOf(place: AtlasPlace, profile: AtlasProfile | null): Reading {
  const key = place.language
  const said = spoken(profile)
  const homeLang = homeLangs(profile)
  const name = LANG_NAME[key] ?? key
  let score = 0.3
  let text = "Expect to need the local language for paperwork and much of daily life."
  if (said.includes(key) && key === "en") {
    score = 0.95
    text = "English is widely spoken and common at work, especially in tech."
  } else if (said.includes(key) && (key === "fr" || key === "de" || key === "ro")) {
    score = 1
    text = key === "fr"
      ? "French is an everyday language here. You're fully at home."
      : key === "de"
        ? "German is a language stored for this desk. Daily life and paperwork can run in it."
        : "Romanian is a language stored for this desk."
  } else if (homeLang.includes(key)) {
    score = 0.75
    text = `Your ${name} covers daily life; English is common in tech.`
  } else if (key === "de") {
    score = 0.4
    text = "Tech jobs often run in English, but daily life and paperwork are in German."
  } else if (key === "en") {
    text = "English is common here, and it is not a language stored for this desk."
  } else if (key === "fr") {
    text = "French is the local language, and it is not one stored for this desk."
  }
  const tone = score >= 0.75 ? "good" : score >= 0.4 ? "warn" : "bad"
  const label = key === "en" ? "English works" : name
  return { key, label, short: label, tone, score, text }
}

function partsOf(place: AtlasPlace, profile: AtlasProfile | null, direction: 1 | -1): Parts {
  const norm = energyNorm(place.energy)
  return {
    energy: direction > 0 ? norm : 1 - norm,
    qol: place.qol / 100,
    afford: Math.max(0, Math.min(1, (175 - place.cost) / 125)),
    lang: languageOf(place, profile).score,
    route: routeOf(place, profile).score,
    tech: (place.tech - 1) / 2,
    ease: (place.ease - 1) / 2,
  }
}

function fitOf(parts: Parts, w: Weights): number {
  let sum = 0
  let total = 0
  for (const axis of AXES) {
    sum += w[axis] * parts[axis]
    total += w[axis]
  }
  return total === 0 ? 0 : (100 * sum) / total
}

function passportLine(profile: AtlasProfile | null): string {
  const list = holderCodes(profile, "citizenships")
  if (list.length === 0) return "none on file"
  const eu = list.filter(euCode)
  const rest = list.filter((code) => !euCode(code))
  const parts = []
  if (eu.length > 0) parts.push(`EU (${eu.join(", ")})`)
  parts.push(...rest)
  return parts.join(" + ")
}

function languageLine(profile: AtlasProfile | null): string {
  const list = spoken(profile)
  return list.length === 0 ? "none on file" : list.map((code) => code.toUpperCase()).join(" · ")
}

function languageFilterLabel(profile: AtlasProfile | null): string {
  const list = spoken(profile)
  if (list.length === 0) return "A language on file"
  if (list.length === 1) return `${list[0]?.toUpperCase()} is enough`
  return `${list.slice(0, -1).map((code) => code.toUpperCase()).join(", ")} or ${list[list.length - 1]?.toUpperCase()} is enough`
}

function sweetLabel(profile: AtlasProfile | null): string {
  const list = spoken(profile)
  const tag = list.length === 0 ? "a language on file" : list.map((code) => code.toUpperCase()).join("/")
  return `Free + ${tag} + real tech`
}

function lede(profile: AtlasProfile | null, count: number): string {
  const field = profile?.field ? `, field ${profile.field}` : ""
  return `${count} European cities from the livability chart, scored for the passports (${passportLine(profile)}) and languages (${languageLine(profile)}) stored on this desk${field}. Every panel is linked: pick a city anywhere and it lights up everywhere.`
}

function esc(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] ?? c))
}

function svgEl(tag: string, attrs: Record<string, string | number>, parent?: Element): SVGElement {
  const el = document.createElementNS(NS, tag)
  for (const [key, value] of Object.entries(attrs)) {
    const text = String(value)
    if ((key === "fill" || key === "stroke") && text.includes("var(")) el.style.setProperty(key, text)
    else el.setAttribute(key, text)
  }
  parent?.appendChild(el)
  return el
}

export class Atlas {
  private readonly onWeights: (weights: Weights) => boolean
  private ac = new AbortController()
  private booted = false
  private waiting = false
  private places: AtlasPlace[] = []
  private profile: AtlasProfile | null = null
  private parts = new Map<number, Parts>()
  private routes = new Map<number, Reading>()
  private langs = new Map<number, Reading>()
  private w: Weights = { ...EMPTY_WEIGHTS }
  private chart: "energy" | "cost" = "energy"
  private energyDir: 1 | -1 = 1
  private countries = new Map<string, AtlasCountry>()
  private energyMed = Math.log10(EU_ENERGY)
  private colorBy = "region"
  private query = ""
  private filters: Filters = { free: false, lang: false, tech: false, remote: false, covered: false, cell: null }
  private sel: number | null = null
  private pins: number[] = []
  private rank: { id: number; score: number }[] = []
  private rankPos = new Map<number, number>()
  private domain = { ...ENERGY_FULL }
  private moved = false
  private svg: SVGSVGElement | null = null
  private frameG: SVGGElement | null = null
  private dotsG: SVGGElement | null = null
  private dots = new Map<number, { g: SVGGElement; cir: SVGElement; label: SVGElement }>()

  constructor(private readonly root: HTMLElement, rows: AtlasRows | null, onWeights: (weights: Weights) => boolean) {
    this.onWeights = onWeights
    if (rows) this.setCatalog(rows)
    else this.showWaiting()
  }

  destroy(): void {
    this.ac.abort()
  }

  setCatalog(rows: AtlasRows): void {
    if (this.booted) return
    if (rows.places.length === 0) {
      this.showWaiting()
      return
    }
    this.boot(rows)
  }

  private showWaiting(): void {
    if (this.waiting) return
    this.waiting = true
    this.root.innerHTML = `<p class="empty">The chart has not arrived yet.</p>`
  }

  private boot(rows: AtlasRows): void {
    this.ac.abort()
    this.ac = new AbortController()
    this.waiting = false
    this.booted = true
    this.places = rows.places
    this.profile = rows.profile
    this.countries = new Map(rows.countries.map((country) => [country.name, country]))
    const logs = this.places.map((place) => Math.log10(place.energy)).sort((a, b) => a - b)
    const mid = logs.length >> 1
    const median = logs.length === 0 ? Math.log10(EU_ENERGY) : logs.length % 2 === 1 ? logs[mid] : ((logs[mid - 1] ?? 0) + (logs[mid] ?? 0)) / 2
    this.energyMed = median ?? Math.log10(EU_ENERGY)
    this.chart = "energy"
    this.domain = { ...ENERGY_FULL }
    this.w = rows.profile
      ? {
          energy: rows.profile.weight_energy,
          qol: rows.profile.weight_qol,
          afford: rows.profile.weight_afford,
          lang: rows.profile.weight_lang,
          route: rows.profile.weight_route,
          tech: rows.profile.weight_tech,
          ease: rows.profile.weight_ease,
        }
      : { ...EMPTY_WEIGHTS }
    for (const place of this.places) {
      this.routes.set(place.id, routeOf(place, this.profile))
      this.langs.set(place.id, languageOf(place, this.profile))
      this.parts.set(place.id, partsOf(place, this.profile, this.energyDir))
    }
    this.root.innerHTML = this.frame()
    this.bind()
    this.recompute()
    const top = this.rank[0]
    this.sel = top?.id ?? null
    this.pins = this.rank.slice(0, 3).map((row) => row.id)
    this.drawFrame()
    this.paint()
  }

  private frame(): string {
    const profile = this.profile
    const field = profile?.field ? `<br>Field · <b>${esc(profile.field)}</b>` : ""
    return `
      <div class="bp-bar">
        <button type="button" id="back-from-atlas" class="ghost" data-action="back">Back</button>
        <div class="grow">
          <p class="kicker">Career geography</p>
          <h2>Free movement atlas</h2>
        </div>
        <div class="atlas-passport">Holder · <b>${esc(passportLine(profile))}</b><br>Languages · <b>${esc(languageLine(profile))}</b>${field}</div>
      </div>
      <div class="atlas-body">
        <p class="atlas-lede">${esc(lede(profile, this.places.length))}</p>
        <section class="atlas-kpis" id="atlas-kpis"></section>
        <section class="atlas-grid">
          <div class="atlas-panel">
            <div class="atlas-ph">
              <h3 id="atlas-plot-title">Energy against comfort</h3>
              <div class="atlas-seg" id="atlas-mode">
                <button type="button" data-chart="energy" aria-pressed="true">Energy × comfort</button>
                <button type="button" data-chart="cost" aria-pressed="false">Cost × comfort</button>
              </div>
              <div class="atlas-seg" id="atlas-color">
                ${["energy", "region", "route", "lang", "tech", "fit"].map((key) => `<button type="button" data-color="${key}" aria-pressed="${key === "region"}">${key === "energy" ? "Energy use" : key === "region" ? "Region" : key === "route" ? "Right to live" : key === "lang" ? "Language" : key === "tech" ? "Tech scene" : "Your fit"}</button>`).join("")}
              </div>
            </div>
            <div class="atlas-ph">
              <div class="atlas-chips" id="atlas-filters">
                <button type="button" class="chip" data-filter="free" aria-pressed="false">Free movement only</button>
                <button type="button" class="chip" data-filter="lang" aria-pressed="false">${esc(languageFilterLabel(profile))}</button>
                <button type="button" class="chip" data-filter="tech" aria-pressed="false">Strong tech scene</button>
                <button type="button" class="chip" data-filter="remote" aria-pressed="false">Mostly online paperwork</button>
                <button type="button" class="chip" data-filter="covered" aria-pressed="false">Median pay covers it</button>
              </div>
              <input id="atlas-q" class="atlas-search" type="search" placeholder="Find a city" aria-label="Find a city" />
            </div>
            <div class="atlas-plotbox" id="atlas-plotbox">
              <svg id="atlas-plot" viewBox="0 0 1000 620" role="img" aria-label="Cities by cost share of median pay and quality of life"></svg>
              <div class="atlas-tip" id="atlas-tip"></div>
            </div>
            <div class="atlas-zoom">
              <button type="button" id="atlas-zin" aria-label="Zoom in">+</button>
              <button type="button" id="atlas-zout" aria-label="Zoom out">−</button>
              <button type="button" id="atlas-zall">Whole chart</button>
              <button type="button" id="atlas-zbest" hidden>Best value</button>
              <button type="button" id="atlas-zcov" hidden>Pay covers it</button>
              <button type="button" id="atlas-zsel">Around selection</button>
              <span id="atlas-zlvl">1.0×</span>
            </div>
            <div class="atlas-legend" id="atlas-legend"></div>
          </div>
          <aside class="atlas-panel atlas-dossier" id="atlas-dossier" aria-live="polite"></aside>
        </section>
        <section class="atlas-split">
          <div class="atlas-panel">
            <div class="atlas-ph"><h3>Your ranking</h3><span class="note">Energy use is the default, and the heaviest weight. Weights are saved on this desk.</span></div>
            <div class="atlas-seg" id="atlas-edir">
              <button type="button" data-edir="1" aria-pressed="true">More energy is better</button>
              <button type="button" data-edir="-1" aria-pressed="false">Less energy is better</button>
            </div>
            <div class="atlas-presets" id="atlas-presets">
              ${PRESETS.map((preset) => `<button type="button" data-preset="${esc(preset.name)}">${esc(preset.name)}</button>`).join("")}
            </div>
            <div class="atlas-weights" id="atlas-weights">
              ${AXES.map((axis) => `<label>${AXIS_LABEL[axis]} <b id="atlas-wv-${axis}">${this.w[axis]}</b><input id="atlas-w-${axis}" data-axis="${axis}" type="range" min="0" max="5" step="1" value="${this.w[axis]}" /></label>`).join("")}
            </div>
            <div class="atlas-ledger" id="atlas-ledger"></div>
          </div>
          <div class="atlas-panel">
            <div class="atlas-ph"><h3>Side by side</h3><span class="note">Pin up to four cities.</span></div>
            <div id="atlas-compare"></div>
            <div class="atlas-ph"><h3>How you'd get in</h3></div>
            <div id="atlas-board"></div>
          </div>
        </section>
        <section class="atlas-panel">
          <div class="atlas-ph"><h3>Language × right to live</h3><span class="note">Click a cell to filter the chart.</span></div>
          <div class="atlas-scroll"><table class="atlas-matrix" id="atlas-matrix"></table></div>
        </section>
        <p class="atlas-note"><b>Sources.</b> Energy is primary energy use per person, stored with its year on each country and each city. City figures are the climate-adjusted values kept with the city. Cost and quality of life are the October 2026 Numbeo chart, accurate to about ±2 points. Right to live and language are scored from the passports and languages stored for this desk. Tech scene and paperwork are judgments, not official data.</p>
      </div>`
  }

  private bind(): void {
    const signal = this.ac.signal
    const svg = this.root.querySelector<SVGSVGElement>("#atlas-plot")
    if (!svg) return
    this.svg = svg
    const defs = svgEl("defs", {}, svg)
    const clip = svgEl("clipPath", { id: "atlas-clip" }, defs)
    svgEl("rect", { x: PL.l, y: PL.t, width: PL.w - PL.l - PL.r, height: PL.h - PL.t - PL.b }, clip)
    this.frameG = svgEl("g", {}, svg) as SVGGElement
    this.dotsG = svgEl("g", { "clip-path": "url(#atlas-clip)" }, svg) as SVGGElement
    for (const place of this.places) {
      const g = svgEl("g", { class: "atlas-dot", tabindex: "0", role: "button", "aria-label": place.name }, this.dotsG) as SVGGElement
      svgEl("circle", { class: "halo", r: 11 }, g)
      const cir = svgEl("circle", { class: "d", r: 6 }, g)
      const label = svgEl("text", { x: 9, y: 4 }, g)
      label.textContent = place.name
      g.addEventListener("click", () => { if (!this.moved) this.select(place.id) }, { signal })
      g.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault()
          this.select(place.id)
        }
      }, { signal })
      this.dots.set(place.id, { g, cir, label })
    }
    svg.addEventListener("wheel", (event) => {
      event.preventDefault()
      const [x, y] = this.svgPoint(event)
      this.zoomAt(x, y, Math.exp(-event.deltaY * 0.0015))
    }, { signal, passive: false })
    svg.addEventListener("dblclick", (event) => {
      const [x, y] = this.svgPoint(event)
      this.zoomAt(x, y, 2)
    }, { signal })
    let last: [number, number] | null = null
    svg.addEventListener("pointerdown", (event) => {
      svg.setPointerCapture(event.pointerId)
      this.moved = false
      last = this.svgPoint(event)
      svg.parentElement?.classList.add("is-dragging")
    }, { signal })
    svg.addEventListener("pointermove", (event) => {
      if (last === null || !svg.hasPointerCapture(event.pointerId)) return
      const point = this.svgPoint(event)
      const dx = point[0] - last[0]
      const dy = point[1] - last[1]
      if (Math.abs(dx) + Math.abs(dy) > 3) this.moved = true
      if (this.moved) {
        const kx = (this.domain.x1 - this.domain.x0) / (PL.w - PL.l - PL.r)
        const ky = (this.domain.y1 - this.domain.y0) / (PL.h - PL.t - PL.b)
        this.setDomain({
          x0: this.domain.x0 - dx * kx,
          x1: this.domain.x1 - dx * kx,
          y0: this.domain.y0 + dy * ky,
          y1: this.domain.y1 + dy * ky,
        })
      }
      last = point
    }, { signal })
    const end = (event: PointerEvent) => {
      if (svg.hasPointerCapture(event.pointerId)) svg.releasePointerCapture(event.pointerId)
      last = null
      svg.parentElement?.classList.remove("is-dragging")
      window.setTimeout(() => { this.moved = false }, 0)
    }
    svg.addEventListener("pointerup", end, { signal })
    svg.addEventListener("pointercancel", end, { signal })
    this.root.querySelector("#atlas-zin")?.addEventListener("click", () => this.zoomAt(500, 310, 1.6), { signal })
    this.root.querySelector("#atlas-zout")?.addEventListener("click", () => this.zoomAt(500, 310, 1 / 1.6), { signal })
    this.root.querySelector("#atlas-zall")?.addEventListener("click", () => this.setDomain({ ...this.full() }), { signal })
    this.root.querySelector("#atlas-zbest")?.addEventListener("click", () => this.setDomain({ x0: 44, x1: 86, y0: 44, y1: 104 }), { signal })
    this.root.querySelector("#atlas-zcov")?.addEventListener("click", () => this.setDomain({ x0: 44, x1: 102, y0: -8, y1: 108 }), { signal })
    this.root.querySelector("#atlas-zsel")?.addEventListener("click", () => {
      const place = this.place(this.sel)
      if (place) {
        const x = this.xOf(place)
        const span = (this.full().x1 - this.full().x0) / 8
        this.setDomain({ x0: x - span, x1: x + span, y0: place.qol - 12, y1: place.qol + 12 })
      }
    }, { signal })
    this.root.querySelector("#atlas-q")?.addEventListener("input", (event) => {
      this.query = (event.target as HTMLInputElement).value.trim().toLowerCase()
      const hits = this.places.filter((place) => this.passes(place))
      if (this.query !== "" && hits.length === 1) this.sel = hits[0]?.id ?? this.sel
      this.paint()
    }, { signal })
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-chart]")) {
      button.addEventListener("click", () => {
        const chart = button.dataset["chart"]
        if (chart === "energy" || chart === "cost") this.setChart(chart)
      }, { signal })
    }
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-edir]")) {
      button.addEventListener("click", () => {
        const dir = Number(button.dataset["edir"])
        if (dir === 1 || dir === -1) this.setEnergyDir(dir)
      }, { signal })
    }
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-color]")) {
      button.addEventListener("click", () => {
        this.colorBy = button.dataset["color"] ?? "region"
        for (const other of this.root.querySelectorAll<HTMLButtonElement>("[data-color]")) other.setAttribute("aria-pressed", String(other === button))
        this.paint()
      }, { signal })
    }
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-filter]")) {
      button.addEventListener("click", () => {
        const key = button.dataset["filter"]
        if (key === "free" || key === "lang" || key === "tech" || key === "remote" || key === "covered") {
          this.filters[key] = !this.filters[key]
          button.setAttribute("aria-pressed", String(this.filters[key]))
          this.paint()
        }
      }, { signal })
    }
    for (const input of this.root.querySelectorAll<HTMLInputElement>("[data-axis]")) {
      input.addEventListener("input", () => {
        const axis = input.dataset["axis"]
        if (!axis || !(AXES as readonly string[]).includes(axis)) return
        const next = { ...this.w, [axis]: Number(input.value) }
        this.commit(next)
      }, { signal })
    }
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-preset]")) {
      button.addEventListener("click", () => {
        const preset = PRESETS.find((item) => item.name === button.dataset["preset"])
        if (preset) this.commit({ ...preset.weights })
      }, { signal })
    }
    this.root.addEventListener("click", (event) => {
      const target = event.target
      if (!(target instanceof Element)) return
      const pin = target.closest<HTMLElement>("[data-pin]")
      if (pin) this.togglePin(Number(pin.dataset["pin"]))
      const city = target.closest<HTMLElement>("[data-city]")
      if (city) this.select(Number(city.dataset["city"]))
      const cell = target.closest<HTMLElement>("[data-cell]")
      if (cell?.dataset["route"] && cell.dataset["lang"]) {
        const next: [string, string] = [cell.dataset["route"], cell.dataset["lang"]]
        const current = this.filters.cell
        this.filters.cell = current && current[0] === next[0] && current[1] === next[1] ? null : next
        this.paint()
      }
    }, { signal })
  }

  private commit(next: Weights): void {
    const prev = this.w
    this.w = next
    this.syncSliders()
    this.recompute()
    this.paint()
    if (!this.onWeights(next)) {
      this.w = prev
      this.syncSliders()
      this.recompute()
      this.paint()
    }
  }

  private syncSliders(): void {
    for (const axis of AXES) {
      const input = this.root.querySelector<HTMLInputElement>(`#atlas-w-${axis}`)
      const label = this.root.querySelector(`#atlas-wv-${axis}`)
      if (input) input.value = String(this.w[axis])
      if (label) label.textContent = String(this.w[axis])
    }
  }

  private recompute(): void {
    this.rank = this.places
      .map((place) => ({ id: place.id, score: fitOf(this.mustParts(place.id), this.w) }))
      .sort((a, b) => b.score - a.score || a.id - b.id)
    this.rankPos = new Map(this.rank.map((row, index) => [row.id, index]))
  }

  private place(id: number | null): AtlasPlace | null {
    return this.places.find((place) => place.id === id) ?? null
  }

  private mustParts(id: number): Parts {
    return this.parts.get(id) ?? { energy: 0, qol: 0, afford: 0, lang: 0, route: 0, tech: 0, ease: 0 }
  }

  private mustRoute(id: number): Reading {
    return this.routes.get(id) ?? { key: "permit", label: "Residence permit", short: "Permit", tone: "bad", score: 0.3, text: "" }
  }

  private mustLang(id: number): Reading {
    return this.langs.get(id) ?? { key: "other", label: "Local language", short: "Local language", tone: "bad", score: 0.3, text: "" }
  }

  private score(id: number): number {
    return this.rank.find((row) => row.id === id)?.score ?? 0
  }

  private passes(place: AtlasPlace): boolean {
    const route = this.mustRoute(place.id).key
    const lang = place.language
    const live = new Set([...spoken(this.profile), ...homeLangs(this.profile)])
    if (this.filters.free && route !== "eu" && route !== "eea" && route !== "home") return false
    if (this.filters.lang && !live.has(lang)) return false
    if (this.filters.tech && place.tech < 2) return false
    if (this.filters.remote && place.ease < 3) return false
    if (this.filters.covered && place.cost >= 100) return false
    if (this.filters.cell) {
      const group = route === "eu" || route === "eea" ? "free" : route
      if (group !== this.filters.cell[0] || lang !== this.filters.cell[1]) return false
    }
    if (this.query !== "" && !`${place.name} ${place.country}`.toLowerCase().includes(this.query)) return false
    return true
  }

  private select(id: number): void {
    if (!Number.isFinite(id)) return
    this.sel = id
    this.paint()
  }

  private togglePin(id: number): void {
    const at = this.pins.indexOf(id)
    if (at >= 0) this.pins.splice(at, 1)
    else {
      if (this.pins.length >= 4) this.pins.shift()
      this.pins.push(id)
    }
    this.paint()
  }

  private paint(): void {
    this.paintDots()
    this.paintLegend()
    this.paintDossier()
    this.paintLedger()
    this.paintCompare()
    this.paintBoard()
    this.paintMatrix()
    this.paintKpis()
  }

  private sx(value: number): number {
    return PL.l + ((value - this.domain.x0) / (this.domain.x1 - this.domain.x0)) * (PL.w - PL.l - PL.r)
  }

  private sy(value: number): number {
    return PL.h - PL.b - ((value - this.domain.y0) / (this.domain.y1 - this.domain.y0)) * (PL.h - PL.t - PL.b)
  }

  private ix(px: number): number {
    return this.domain.x0 + ((px - PL.l) / (PL.w - PL.l - PL.r)) * (this.domain.x1 - this.domain.x0)
  }

  private iy(py: number): number {
    return this.domain.y0 + ((PL.h - PL.b - py) / (PL.h - PL.t - PL.b)) * (this.domain.y1 - this.domain.y0)
  }

  private svgPoint(event: { clientX: number; clientY: number }): [number, number] {
    const rect = this.svg?.getBoundingClientRect()
    if (!rect || rect.width === 0) return [0, 0]
    return [((event.clientX - rect.left) / rect.width) * 1000, ((event.clientY - rect.top) / rect.height) * 620]
  }

  private zoomAt(px: number, py: number, factor: number): void {
    const x = this.ix(px)
    const y = this.iy(py)
    this.setDomain({
      x0: x - (x - this.domain.x0) / factor,
      x1: x + (this.domain.x1 - x) / factor,
      y0: y - (y - this.domain.y0) / factor,
      y1: y + (this.domain.y1 - y) / factor,
    })
  }

  private full(): { x0: number; x1: number; y0: number; y1: number } {
    return this.chart === "energy" ? ENERGY_FULL : COST_FULL
  }

  private medX(): number {
    return this.chart === "energy" ? this.energyMed : COST_MED
  }

  private xOf(place: AtlasPlace): number {
    return this.chart === "energy" ? Math.log10(place.energy) : place.cost
  }

  private setChart(chart: "energy" | "cost"): void {
    this.chart = chart
    this.domain = { ...this.full() }
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-chart]")) {
      button.setAttribute("aria-pressed", String(button.dataset["chart"] === chart))
    }
    const title = this.root.querySelector("#atlas-plot-title")
    if (title) title.textContent = chart === "energy" ? "Energy against comfort" : "Cost against comfort"
    const best = this.root.querySelector<HTMLButtonElement>("#atlas-zbest")
    const covered = this.root.querySelector<HTMLButtonElement>("#atlas-zcov")
    if (best) best.hidden = chart !== "cost"
    if (covered) covered.hidden = chart !== "cost"
    this.drawFrame()
    this.paint()
  }

  private setEnergyDir(direction: 1 | -1): void {
    this.energyDir = direction
    for (const button of this.root.querySelectorAll<HTMLButtonElement>("[data-edir]")) {
      button.setAttribute("aria-pressed", String(Number(button.dataset["edir"]) === direction))
    }
    for (const place of this.places) this.parts.set(place.id, partsOf(place, this.profile, direction))
    this.recompute()
    this.paint()
  }

  private setDomain(next: { x0: number; x1: number; y0: number; y1: number }): void {
    const full = this.full()
    const span = full.x1 - full.x0
    const width = Math.max(span / 14, Math.min(next.x1 - next.x0, span))
    const height = Math.max(8, Math.min(next.y1 - next.y0, full.y1 - full.y0))
    let cx = (next.x0 + next.x1) / 2
    let cy = (next.y0 + next.y1) / 2
    cx = Math.max(full.x0 + width / 2, Math.min(full.x1 - width / 2, cx))
    cy = Math.max(full.y0 + height / 2, Math.min(full.y1 - height / 2, cy))
    this.domain = { x0: cx - width / 2, x1: cx + width / 2, y0: cy - height / 2, y1: cy + height / 2 }
    this.drawFrame()
    this.placeDots()
  }

  private drawFrame(): void {
    const frame = this.frameG
    if (!frame) return
    frame.replaceChildren()
    const full = this.full()
    const med = this.medX()
    const names = this.chart === "energy"
      ? ["Livable, lighter use", "Livable, energy-rich", "Lighter use, less livable", "Energy-heavy, less livable"]
      : ["Best value", "Premium life", "Budget living", "Bad value"]
    const quads: [number, number, number, number, string, string][] = [
      [full.x0, med, MEDY, full.y1, "var(--q-best)", names[0] ?? ""],
      [med, full.x1, MEDY, full.y1, "var(--q-prem)", names[1] ?? ""],
      [full.x0, med, full.y0, MEDY, "var(--q-bud)", names[2] ?? ""],
      [med, full.x1, full.y0, MEDY, "var(--q-bad)", names[3] ?? ""],
    ]
    const layer = svgEl("g", { "clip-path": "url(#atlas-clip)" }, frame)
    for (const [a, b, c, d, fill, name] of quads) {
      svgEl("rect", { x: this.sx(a), y: this.sy(d), width: this.sx(b) - this.sx(a), height: this.sy(c) - this.sy(d), fill }, layer)
      const label = svgEl("text", { x: this.sx(a) + 8, y: this.sy(d) + 16, class: "qlab" }, layer)
      label.textContent = name
    }
    if (this.chart === "cost") {
      svgEl("line", { x1: this.sx(100), x2: this.sx(100), y1: PL.t, y2: PL.h - PL.b, stroke: "var(--bad)", "stroke-width": 2 }, layer)
    } else {
      const eu = Math.log10(EU_ENERGY)
      svgEl("line", { x1: this.sx(eu), x2: this.sx(eu), y1: PL.t, y2: PL.h - PL.b, stroke: "var(--warn)", "stroke-width": 2 }, layer)
      const tick = svgEl("text", { x: this.sx(eu) + 8, y: PL.t + 16, class: "qlab" }, layer)
      tick.textContent = "EU average"
      for (const kwh of [10000, 20000, 40000, 80000, 160000]) {
        const x = Math.log10(kwh)
        if (x < this.domain.x0 || x > this.domain.x1) continue
        const mark = svgEl("text", { x: this.sx(x), y: PL.h - PL.b + 16, class: "qlab" }, layer)
        mark.textContent = `${kwh / 1000}k`
      }
    }
    svgEl("line", { x1: this.sx(med), x2: this.sx(med), y1: PL.t, y2: PL.h - PL.b, stroke: "var(--muted)", "stroke-dasharray": "4 4" }, layer)
    svgEl("line", { x1: PL.l, x2: PL.w - PL.r, y1: this.sy(MEDY), y2: this.sy(MEDY), stroke: "var(--muted)", "stroke-dasharray": "4 4" }, layer)
    const level = this.root.querySelector("#atlas-zlvl")
    if (level) level.textContent = `${((full.x1 - full.x0) / (this.domain.x1 - this.domain.x0)).toFixed(1)}×`
    this.placeDots()
  }

  private placeDots(): void {
    const full = this.full()
    const zoom = (full.x1 - full.x0) / (this.domain.x1 - this.domain.x0)
    for (const place of this.places) {
      const dot = this.dots.get(place.id)
      if (!dot) continue
      dot.g.style.transform = `translate(${this.sx(this.xOf(place))}px, ${this.sy(place.qol)}px)`
      const show = zoom >= 1.8 || place.labeled || place.id === this.sel || this.pins.includes(place.id)
      dot.label.style.display = show && this.passes(place) ? "" : "none"
    }
  }

  private colorOf(place: AtlasPlace): string {
    if (this.colorBy === "region") return `var(--r-${place.region})`
    if (this.colorBy === "route") {
      const tone = this.mustRoute(place.id).tone
      return tone === "good" ? "var(--good)" : tone === "warn" ? "var(--warn)" : "var(--bad)"
    }
    if (this.colorBy === "lang") {
      const key = place.language
      if (key === "fr") return "var(--accent)"
      if (key === "en") return "var(--r-nordic)"
      if (key === "ro") return "var(--gold)"
      if (key === "de") return "var(--r-central)"
      return "var(--faint)"
    }
    if (this.colorBy === "tech") {
      if (place.tech >= 3) return "var(--accent)"
      if (place.tech === 2) return "color-mix(in srgb, var(--accent) 55%, var(--faint))"
      return "var(--faint)"
    }
    if (this.colorBy === "energy") {
      const t = energyNorm(place.energy)
      return `color-mix(in srgb, var(--warn) ${Math.round(15 + 85 * t)}%, var(--faint))`
    }
    const t = Math.max(0, Math.min(1, (this.score(place.id) - 35) / 45))
    return `color-mix(in srgb, var(--accent) ${Math.round(t * 100)}%, var(--faint))`
  }

  private paintDots(): void {
    for (const place of this.places) {
      const dot = this.dots.get(place.id)
      if (!dot) continue
      dot.cir.style.fill = this.colorOf(place)
      dot.cir.setAttribute("r", String(4.5 + place.tech * 2.2))
      dot.g.classList.toggle("is-dim", !this.passes(place))
      dot.g.classList.toggle("is-sel", place.id === this.sel)
      dot.g.classList.toggle("is-pin", this.pins.includes(place.id))
    }
    const selected = this.sel === null ? undefined : this.dots.get(this.sel)
    if (selected) this.dotsG?.appendChild(selected.g)
    this.placeDots()
  }

  private paintLegend(): void {
    const host = this.root.querySelector("#atlas-legend")
    if (!host) return
    const items: [string, string][] = this.colorBy === "region"
      ? Object.entries(REGION).map(([key, label]) => [`var(--r-${key})`, label])
      : this.colorBy === "route"
        ? [["var(--good)", "Free to move"], ["var(--warn)", "Open with conditions"], ["var(--bad)", "Residence permit"]]
        : this.colorBy === "lang"
          ? [["var(--accent)", "French"], ["var(--r-nordic)", "English works"], ["var(--gold)", "Romanian"], ["var(--r-central)", "German"], ["var(--faint)", "Other local language"]]
          : this.colorBy === "tech"
            ? [["var(--faint)", "Small market"], ["color-mix(in srgb, var(--accent) 55%, var(--faint))", "Solid scene"], ["var(--accent)", "Major hub"]]
            : this.colorBy === "energy"
              ? [["color-mix(in srgb, var(--warn) 30%, var(--faint))", "Under 15,000 kWh"], ["color-mix(in srgb, var(--warn) 65%, var(--faint))", "Around the EU average"], ["var(--warn)", "Over 80,000 kWh"]]
              : [["var(--faint)", "Weaker fit"], ["var(--accent)", "Stronger fit"]]
    host.innerHTML = items.map(([color, label]) => `<span><i style="background:${color}"></i>${esc(label)}</span>`).join("")
  }

  private paintKpis(): void {
    const host = this.root.querySelector("#atlas-kpis")
    if (!host) return
    const free = this.places.filter((place) => ["eu", "eea", "home"].includes(this.mustRoute(place.id).key)).length
    const said = new Set(spoken(this.profile))
    const sweet = this.places.filter((place) => {
      const key = this.mustRoute(place.id).key
      return (key === "eu" || key === "eea") && said.has(place.language) && place.tech >= 2
    }).length
    const covered = this.places.filter((place) => place.cost < 100).length
    const visible = this.places.filter((place) => this.passes(place))
    const best = this.rank.find((row) => {
      const place = this.place(row.id)
      return place ? this.passes(place) : false
    }) ?? this.rank[0]
    const bestPlace = best ? this.place(best.id) : null
    host.innerHTML = `
      <div><span>Open to your passport</span><b>${free}</b><small>/ ${this.places.length}</small></div>
      <div><span>${esc(sweetLabel(this.profile))}</span><b>${sweet}</b></div>
      <div><span>Median pay covers costs</span><b>${covered}</b><small>/ ${this.places.length}</small></div>
      <div><span>Matching filters</span><b>${visible.length}</b></div>
      <div><span>Top fit</span><b>${esc(bestPlace?.name ?? "—")}</b><small>${best ? Math.round(best.score) : ""}</small></div>`
  }

  private paintDossier(): void {
    const host = this.root.querySelector("#atlas-dossier")
    const place = this.place(this.sel)
    if (!host || !place) return
    const route = this.mustRoute(place.id)
    const lang = this.mustLang(place.id)
    const parts = this.mustParts(place.id)
    const rank = (this.rankPos.get(place.id) ?? 0) + 1
    const score = Math.round(this.score(place.id))
    const high = place.qol >= MEDY
    const leftSide = this.xOf(place) < this.medX()
    const quad = this.chart === "energy"
      ? (leftSide ? (high ? "Livable, lighter use" : "Lighter use, less livable") : (high ? "Livable, energy-rich" : "Energy-heavy, less livable"))
      : (leftSide ? (high ? "Best value" : "Budget living") : (high ? "Premium life" : "Bad value"))
    const pinned = this.pins.includes(place.id)
    const left = 100 - place.cost
    const country = this.countries.get(place.country)
    const meter = (label: string, value: number, max: number, text: string) =>
      `<div class="atlas-meter"><span>${label}</span><span class="bar"><span style="width:${Math.max(0, Math.min(100, (value / max) * 100))}%"></span></span><b>${text}</b></div>`
    host.innerHTML = `
      <div class="atlas-dtop"><span>${esc(place.country)} · ${esc(REGION[place.region] ?? place.region)}</span><button type="button" data-pin="${place.id}">${pinned ? "Pinned" : "Pin to compare"}</button></div>
      <h3>${esc(place.name)}</h3>
      <p class="atlas-rank">#${rank} of ${this.places.length} · fit ${score}/100 · ${quad}</p>
      ${meter("Energy use", energyNorm(place.energy), 1, `${fmtK(place.energy)} kWh`)}
      ${meter("Quality of life", place.qol, 100, place.qol.toFixed(0))}
      ${meter("Affordability", parts.afford, 1, `${Math.round(parts.afford * 100)}`)}
      ${meter("Language", lang.score, 1, `${Math.round(lang.score * 100)}`)}
      ${meter("Right to live", route.score, 1, `${Math.round(route.score * 100)}`)}
      ${meter("Tech scene", place.tech, 3, "●".repeat(place.tech) + "○".repeat(3 - place.tech))}
      ${meter("Online paperwork", place.ease, 3, "●".repeat(place.ease) + "○".repeat(3 - place.ease))}
      <p class="atlas-pay">About <b>${fmtK(place.energy)} kWh</b> of primary energy per person in ${place.energy_year}${country ? `. ${esc(place.country)} as a whole: <b>${fmtK(country.energy)} kWh</b> (${country.energy_year}).` : "."}</p>
      <p class="atlas-pay">Rent and living costs take <b>${place.cost.toFixed(0)}%</b> of local median take-home pay${left >= 0 ? `, leaving about <b>${left.toFixed(0)}%</b>.` : `, a shortfall of about <b>${(-left).toFixed(0)}%</b>.`}</p>
      <p><span class="atlas-pill is-${route.tone}">${esc(route.label)}</span><br>${esc(route.text)}</p>
      <p><span class="atlas-pill is-${lang.tone}">${esc(lang.label)}</span><br>${esc(lang.text)}</p>
      <p>${esc(TECH[place.tech] ?? "")}</p>
      <p>${esc(EASE[place.ease] ?? "")}</p>`
  }

  private paintLedger(): void {
    const host = this.root.querySelector("#atlas-ledger")
    if (!host) return
    const rows = this.rank.filter((row) => {
      const place = this.place(row.id)
      return place ? this.passes(place) : false
    }).slice(0, 15)
    host.innerHTML = rows.map((row) => {
      const place = this.place(row.id)
      if (!place) return ""
      return `<button type="button" class="atlas-row${row.id === this.sel ? " is-sel" : ""}" data-city="${row.id}"><span>${(this.rankPos.get(row.id) ?? 0) + 1}</span><span>${esc(place.name)}<small>${esc(place.country)}</small></span><b>${Math.round(row.score)}</b></button>`
    }).join("")
  }

  private paintCompare(): void {
    const host = this.root.querySelector("#atlas-compare")
    if (!host) return
    if (this.pins.length === 0) {
      host.innerHTML = `<p class="note">Nothing pinned yet.</p>`
      return
    }
    host.innerHTML = `<div class="atlas-pins">${this.pins.map((id) => {
      const place = this.place(id)
      return place ? `<button type="button" data-pin="${id}">${esc(place.name)} ×</button>` : ""
    }).join("")}</div>` + AXES.map((axis) => `<div class="atlas-cmprow"><span>${AXIS_LABEL[axis]}</span>${this.pins.map((id) => `<span class="atlas-cmpbar" style="width:${Math.max(2, this.mustParts(id)[axis] * 100)}%"></span>`).join("")}</div>`).join("")
  }

  private paintBoard(): void {
    const host = this.root.querySelector("#atlas-board")
    if (!host) return
    const youth = youthCountries(this.profile)
    const groups: [string, string, (key: string) => boolean][] = [
      ["Free movement", euHolder(this.profile) || eeaHolder(this.profile) ? "EU and EEA. Register locally; no permit." : "No EU or EEA passport on file.", (key) => key === "eu" || key === "eea"],
      ["Home", "Nothing to file.", (key) => key === "home"],
      ["Switzerland", euHolder(this.profile) ? "Job-hunt without a permit; a Swiss contract of a year or more gives a five-year B permit." : "No Swiss agreement from the passports on file.", (key) => key === "ch"],
      ["United Kingdom", youth.length > 0 ? `Via the ${youth[0]?.adjective ?? "Youth Mobility"} passport: Youth Mobility, ages 18 to 35, up to three years, no sponsor needed.` : "No Youth Mobility passport on file.", (key) => key === "uk"],
      ["Needs a permit", "National residence permits.", (key) => key === "permit"],
    ]
    host.innerHTML = groups.map(([title, text, pred]) => {
      const list = this.rank.filter((row) => pred(this.mustRoute(row.id).key))
      return `<div class="atlas-route"><h4>${title} <span class="note">· ${list.length}</span></h4><p>${esc(text)}</p><div>${list.slice(0, 12).map((row) => {
        const place = this.place(row.id)
        return place ? `<button type="button" data-city="${row.id}">${esc(place.name)} <span>${Math.round(row.score)}</span></button>` : ""
      }).join("")}</div></div>`
    }).join("")
  }

  private paintMatrix(): void {
    const host = this.root.querySelector("#atlas-matrix")
    if (!host) return
    const rows: [string, string][] = [["free", "EU / EEA"], ["home", this.homeLabel()], ["ch", "Switzerland"], ["uk", "United Kingdom"], ["permit", "Needs a permit"]]
    const cols = ["fr", "en", "ro", "de", "other"]
    const group = (key: string) => (key === "eu" || key === "eea" ? "free" : key)
    const cell = (route: string, lang: string) => this.places.filter((place) => group(this.mustRoute(place.id).key) === route && place.language === lang)
    const max = Math.max(1, ...rows.flatMap(([route]) => cols.map((lang) => cell(route, lang).length)))
    host.innerHTML = `<tr><th></th>${cols.map((lang) => `<th>${esc(LANG_NAME[lang] ?? lang)}</th>`).join("")}</tr>` + rows.map(([route, label]) => `<tr><th>${esc(label)}</th>${cols.map((lang) => {
      const list = cell(route, lang)
      if (list.length === 0) return `<td class="is-zero">·</td>`
      const best = [...list].sort((a, b) => this.score(b.id) - this.score(a.id))[0]
      const on = this.filters.cell?.[0] === route && this.filters.cell[1] === lang
      return `<td class="${on ? "is-on" : ""}" data-cell data-route="${route}" data-lang="${lang}" style="background:color-mix(in srgb, var(--accent) ${Math.round(12 + (70 * list.length) / max)}%, var(--panel))">${list.length}<small>${esc(best?.name ?? "")}</small></td>`
    }).join("")}</tr>`).join("")
  }

  private homeLabel(): string {
    const names = new Set(this.places.filter((place) => this.mustRoute(place.id).key === "home").map((place) => place.country))
    return names.size === 0 ? "Home" : [...names].join(" · ")
  }
}
