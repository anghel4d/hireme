// The shell: one model, pure views, a draw that morphs. The address is
// the board's identity; the resident columns are what it is drawn from.

import * as api from "./api.ts"
import type { Focus, Root, Scoreboard } from "./api.ts"
import { openFeed, type Signal } from "./feed.ts"
import { fromParams, lower, toParams, type Filters } from "./filters.ts"
import * as grid from "./grid.ts"
import { h, morph, raw, type Raw } from "./html.ts"
import { assertNever } from "./never.ts"
import { Store } from "./store.ts"
import * as views from "./views.ts"

type Lens = "board" | "battleplan" | "root"

interface Model {
  filters: Filters
  lens: Lens
  appId: number | null
  index: number
  count: number
  focus: Focus | null
  root: Root | null
  scoreboard: Scoreboard | null
  editing: number | null
  alterError: string | null
  holdError: string | null
  sheet: boolean
  grid: { cols: number; scroll: number; viewport: number; rem: number }
}

type Msg =
  | { t: "filters"; filters: Filters }
  | { t: "select"; id: number }
  | { t: "move"; dir: grid.Dir }
  | { t: "lens"; lens: Lens }
  | { t: "escape" }
  | { t: "edit"; item: number | null; error?: string | null }
  | { t: "hold"; error: string | null }
  | { t: "grid"; cols?: number; scroll?: number; viewport?: number; rem?: number }
  | { t: "focus"; focus: Focus | null }
  | { t: "root"; root: Root | null }
  | { t: "scoreboard"; scoreboard: Scoreboard }
  | { t: "sheet"; open: boolean }

export class Shell {
  private model: Model
  private store: Store
  private root: HTMLElement
  private readonly compactQuery = matchMedia("(max-width: 980px)")
  private drawQueued = false
  private focusToken = 0

  constructor(root: HTMLElement, store: Store, loadStore: () => Promise<Store>) {
    this.root = root
    this.store = store
    this.reloadStore = loadStore
    const params = new URLSearchParams(location.search)
    const filters = fromParams(params, store.tables)
    this.model = {
      filters,
      lens: lensOf(params.get("lens")),
      appId: parseId(params.get("app")),
      index: -1,
      count: 0,
      focus: null,
      root: null,
      scoreboard: null,
      editing: null,
      alterError: null,
      holdError: null,
      sheet: false,
      grid: { cols: 3, scroll: 0, viewport: 640, rem: remPx() },
    }
    this.root.innerHTML = `
      <div id="topbar"></div>
      <div id="scoreboard-slot"></div>
      <div id="lens"></div>
      <div id="workspace" class="workspace">
        <div id="grid" class="grid-scroll"><div id="plane" class="grid-plane"></div><div id="empty"></div></div>
        <div id="focus-slot"></div>
      </div>`
    this.bind()
    this.select()
    if (this.model.appId === null) this.model.appId = this.idAt(0)
    void this.loadFocus()
    void this.loadRoot()
    void api.fetchScoreboard().then((s) => this.dispatch({ t: "scoreboard", scoreboard: s }))
    openFeed((s) => this.onSignal(s))
    this.draw()
  }

  private readonly reloadStore: () => Promise<Store>

  // ---- update ----

  dispatch(msg: Msg): void {
    const m = this.model
    switch (msg.t) {
      case "filters":
        m.filters = msg.filters
        this.select()
        if (m.index < 0 && m.appId === null) m.appId = this.idAt(0)
        break
      case "select":
        if (m.appId !== msg.id) {
          m.appId = msg.id
          m.editing = null
          m.alterError = null
          m.holdError = null
          m.index = this.store.find(msg.id)
          void this.loadFocus()
        }
        m.sheet = true
        this.reveal()
        break
      case "move": {
        if (m.count === 0) break
        const next = grid.move(Math.max(m.index, 0), m.grid.cols, m.count, msg.dir)
        const id = this.idAt(next)
        if (id !== null && id !== m.appId) this.dispatch({ t: "select", id })
        break
      }
      case "lens":
        if (msg.lens === "battleplan" && m.appId === null) break
        m.lens = msg.lens
        if (msg.lens === "root") void this.loadRoot()
        break
      case "escape":
        if (m.lens !== "board") m.lens = "board"
        else if (this.compactQuery.matches && m.sheet) m.sheet = false
        else if (m.filters.q !== "") this.dispatch({ t: "filters", filters: { ...m.filters, q: "" } })
        break
      case "edit":
        m.editing = msg.item
        m.alterError = msg.error ?? null
        break
      case "hold":
        m.holdError = msg.error
        break
      case "grid": {
        const g = { ...m.grid, ...strip(msg) }
        const colsChanged = g.cols !== m.grid.cols
        m.grid = g
        if (colsChanged) this.reveal()
        break
      }
      case "focus":
        m.focus = msg.focus
        if (msg.focus === null && m.lens === "battleplan") m.lens = "board"
        break
      case "root":
        m.root = msg.root
        break
      case "scoreboard":
        m.scoreboard = msg.scoreboard
        break
      case "sheet":
        m.sheet = msg.open
        break
      default:
        assertNever(msg)
    }
    this.syncAddress()
    this.queueDraw()
  }

  private select(): void {
    const m = this.model
    m.count = this.store.select(lower(m.filters, this.store.tables))
    m.index = m.appId === null ? -1 : this.store.find(m.appId)
  }

  private idAt(pos: number): number | null {
    const sel = this.store.selection()
    const row = sel[pos]
    if (row === undefined) return null
    return this.store.column("id")[row] ?? null
  }

  private reveal(): void {
    const m = this.model
    if (m.index < 0) return
    const metrics = grid.metrics(m.grid.rem)
    const scroll = Math.round(grid.scrollTo(m.index, m.grid.cols, m.grid.scroll, m.grid.viewport, metrics))
    if (scroll !== m.grid.scroll) {
      m.grid.scroll = scroll
      const el = this.root.querySelector<HTMLElement>("#grid")
      if (el) el.scrollTop = scroll
    }
  }

  // ---- effects ----

  private async loadFocus(): Promise<void> {
    const id = this.model.appId
    const token = ++this.focusToken
    if (id === null) {
      this.dispatch({ t: "focus", focus: null })
      return
    }
    try {
      const focus = await api.fetchFocus(id)
      if (token === this.focusToken) this.dispatch({ t: "focus", focus })
    } catch {
      if (token === this.focusToken) this.dispatch({ t: "focus", focus: null })
    }
  }

  private async loadRoot(): Promise<void> {
    const m = this.model
    const slug = m.filters.profile.kind === "one" ? m.filters.profile.value : null
    const profile =
      this.store.tables.profiles.find((p) => p.slug === slug) ??
      (m.focus ? this.store.tables.profiles.find((p) => p.id === m.focus?.profile.id) : undefined) ??
      this.store.tables.profiles[0]
    if (!profile) return
    try {
      this.dispatch({ t: "root", root: await api.fetchRoot(profile.id) })
    } catch {
      this.dispatch({ t: "root", root: null })
    }
  }

  private async refreshBoard(): Promise<void> {
    this.store = await this.reloadStore()
    this.select()
    void api.fetchScoreboard().then((s) => this.dispatch({ t: "scoreboard", scoreboard: s }))
    this.queueDraw()
  }

  private onSignal(s: Signal): void {
    void this.refreshBoard()
    if (s.job_id !== undefined && s.job_id === this.model.appId) void this.loadFocus()
    if (s.type === "cv" || s.type === "open_fire") void this.loadRoot()
  }

  private async write(outcome: Promise<api.Outcome<{ ok: true; focus: Focus }>>): Promise<boolean> {
    const r = await outcome
    if (r.ok) {
      this.dispatch({ t: "hold", error: null })
      this.dispatch({ t: "focus", focus: r.value.focus })
      void this.refreshBoard()
      return true
    }
    const message =
      r.error === "fire_hold" ? "FIRE HOLD. Name open fire on this batch before a submit."
      : r.error === "leased" ? "This application is leased to an agent."
      : r.error === "cooldown" ? "This CV is in its quarterly cooldown."
      : r.error === "not_additive" ? "This generation accepts new lines only."
      : r.error
    this.dispatch({ t: "hold", error: message })
    return false
  }

  // ---- draw ----

  private queueDraw(): void {
    if (this.drawQueued) return
    this.drawQueued = true
    requestAnimationFrame(() => {
      this.drawQueued = false
      this.draw()
    })
  }

  private draw(): void {
    const m = this.model
    const t = this.store.tables
    this.set("#topbar", views.topbar(m.filters, t, m.count))
    this.set("#scoreboard-slot", views.scoreboard(m.scoreboard))

    const lens = this.root.querySelector<HTMLElement>("#lens")
    const workspace = this.root.querySelector<HTMLElement>("#workspace")
    if (!lens || !workspace) return

    if (m.lens === "battleplan" && m.focus) {
      morph(lens, h`<div class="battleplan-wrap">${views.battleplan(m.focus, m.editing, m.alterError, m.holdError)}</div>`)
      workspace.hidden = true
    } else if (m.lens === "root" && m.root) {
      morph(lens, h`<div class="root-wrap">${views.rootView(m.root)}</div>`)
      workspace.hidden = true
    } else {
      morph(lens, raw(""))
      workspace.hidden = false
      this.drawBoard()
    }
    document.title = titleOf(m)
  }

  private drawBoard(): void {
    const m = this.model
    const metrics = grid.metrics(m.grid.rem)
    const [start, last] = grid.slice(m.count, m.grid.cols, m.grid.scroll, m.grid.viewport, metrics)
    const sel = this.store.selection()
    const ids = this.store.column("id")
    const parts: Raw[] = []
    const place = (pos: number) => {
      const row = sel[pos]
      if (row === undefined) return
      const [x, y] = grid.origin(pos, m.grid.cols, metrics)
      parts.push(views.card(this.store, row, Math.round(x), Math.round(y), ids[row] === m.appId))
    }
    if (m.index >= 0 && (m.index < start || m.index > last)) place(m.index)
    if (start >= 0) for (let p = start; p <= last; p++) place(p)

    const plane = this.root.querySelector<HTMLElement>("#plane")
    if (plane) {
      plane.style.height = `${Math.round(grid.contentHeight(m.count, m.grid.cols, metrics))}px`
      morph(plane, h`${parts}`)
    }
    this.set("#empty", m.count === 0 ? views.emptyBoard() : raw(""))
    this.set(
      "#focus-slot",
      m.focus ? views.focusPanel(m.focus, m.index >= 0, m.sheet, m.holdError) : views.emptyFocus(),
    )
  }

  private set(selector: string, html: Raw): void {
    const el = this.root.querySelector<HTMLElement>(selector)
    if (el) morph(el, html)
  }

  private syncAddress(): void {
    const m = this.model
    const p = toParams(m.filters)
    if (m.lens !== "board") p.set("lens", m.lens)
    if (m.appId !== null) p.set("app", String(m.appId))
    const q = p.toString()
    const url = q === "" ? location.pathname : `${location.pathname}?${q}`
    if (url !== location.pathname + location.search) history.replaceState(null, "", url)
  }

  // ---- wiring ----

  private bind(): void {
    const root = this.root

    window.addEventListener("keydown", (e) => this.onKey(e), true)

    root.addEventListener("click", (e) => {
      const el = (e.target as Element).closest<HTMLElement>("[data-action], [data-link]")
      if (!el) return
      if (el.hasAttribute("data-link")) {
        e.preventDefault()
        const u = new URL((el as HTMLAnchorElement).href)
        this.dispatch({ t: "filters", filters: fromParams(u.searchParams, this.store.tables) })
        this.dispatch({ t: "lens", lens: "board" })
        return
      }
      void this.onAction(el)
    })

    root.addEventListener("input", (e) => {
      const target = e.target as HTMLElement
      const form = target.closest<HTMLFormElement>("form")
      if (!form) return
      if (form.id === "filters") {
        const data = new FormData(form)
        const p = new URLSearchParams()
        for (const [k, v] of data.entries()) p.set(k, String(v))
        this.dispatch({ t: "filters", filters: fromParams(p, this.store.tables) })
      } else if (form.dataset["form"] === "next") {
        this.debounce("next", 400, () => {
          const data = new FormData(form)
          if (this.model.appId === null) return
          void this.write(api.setNext(this.model.appId, String(data.get("next_action") ?? "").trim(), String(data.get("next_due") ?? "")))
        })
      } else if (form.dataset["form"] === "note") {
        this.debounce("note", 500, () => {
          const data = new FormData(form)
          const stage = form.dataset["stage"]
          if (this.model.appId === null || !stage) return
          void this.write(api.setNote(this.model.appId, stage, String(data.get("note") ?? "")))
        })
      }
    })

    root.addEventListener("submit", (e) => {
      const form = e.target as HTMLFormElement
      e.preventDefault()
      void this.onSubmit(form)
    })

    const gridEl = root.querySelector<HTMLElement>("#grid")
    if (gridEl) {
      gridEl.addEventListener("scroll", () => this.dispatch({ t: "grid", scroll: Math.round(gridEl.scrollTop) }), { passive: true })
      const measure = () => {
        const rem = remPx()
        this.dispatch({
          t: "grid",
          rem,
          cols: grid.columns(gridEl.clientWidth, grid.metrics(rem)),
          viewport: Math.max(gridEl.clientHeight, 1),
        })
      }
      new ResizeObserver(measure).observe(gridEl)
      measure()
    }

    window.addEventListener("popstate", () => {
      const p = new URLSearchParams(location.search)
      this.dispatch({ t: "filters", filters: fromParams(p, this.store.tables) })
      const id = parseId(p.get("app"))
      if (id !== null) this.dispatch({ t: "select", id })
      this.dispatch({ t: "lens", lens: lensOf(p.get("lens")) })
    })
  }

  private readonly timers = new Map<string, number>()
  private debounce(key: string, ms: number, fn: () => void): void {
    const prev = this.timers.get(key)
    if (prev) clearTimeout(prev)
    this.timers.set(key, window.setTimeout(fn, ms))
  }

  private onKey(e: KeyboardEvent): void {
    const el = document.activeElement
    const tag = el?.tagName
    const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT"
    if (e.key === "Escape") {
      if (typing && el instanceof HTMLElement && el.id !== "q") {
        e.preventDefault()
        el.blur()
        return
      }
      if (el instanceof HTMLElement && el.id === "q") el.blur()
      this.dispatch({ t: "escape" })
      return
    }
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return
    const m = this.model
    if (e.key === "/" && m.lens === "board") {
      e.preventDefault()
      this.root.querySelector<HTMLInputElement>("#q")?.focus()
      return
    }
    if ((e.key === "Enter" || e.key === "f") && m.lens === "board") {
      e.preventDefault()
      this.dispatch({ t: "lens", lens: "battleplan" })
      return
    }
    const dir = grid.dirFromKey(e.key)
    if (dir && m.lens === "board") {
      e.preventDefault()
      this.dispatch({ t: "move", dir })
    }
  }

  private async onAction(el: HTMLElement): Promise<void> {
    const m = this.model
    const action = el.dataset["action"]
    switch (action) {
      case "select": {
        const id = parseId(el.dataset["id"] ?? null)
        if (id !== null) this.dispatch({ t: "select", id })
        return
      }
      case "battleplan": this.dispatch({ t: "lens", lens: "battleplan" }); return
      case "back": this.dispatch({ t: "escape" }); return
      case "root": this.dispatch({ t: "lens", lens: "root" }); return
      case "stage": {
        const stage = el.dataset["stage"]
        if (m.appId !== null && stage) await this.write(api.setStage(m.appId, stage))
        return
      }
      case "open-fire": {
        const code = el.dataset["batch"]
        if (!code) return
        const r = await api.nameOpenFire(code)
        if (r.ok) {
          this.dispatch({ t: "hold", error: null })
          void this.loadFocus()
          void this.refreshBoard()
        }
        return
      }
      case "mask": {
        const item = parseId(el.dataset["item"] ?? null)
        const mode = el.dataset["mode"]
        if (m.appId !== null && item !== null && mode) {
          if (await this.write(api.putOverlay(m.appId, item, mode))) this.dispatch({ t: "edit", item: null })
        }
        return
      }
      case "edit": this.dispatch({ t: "edit", item: parseId(el.dataset["item"] ?? null) }); return
      case "cancel-edit": this.dispatch({ t: "edit", item: null }); return
      default: return
    }
  }

  private async onSubmit(form: HTMLFormElement): Promise<void> {
    const m = this.model
    const data = new FormData(form)
    switch (form.dataset["form"]) {
      case "alter": {
        const item = parseId(form.dataset["item"] ?? null)
        const body = String(data.get("body") ?? "").trim()
        if (body === "") {
          this.dispatch({ t: "edit", item, error: "A variant line needs text." })
          return
        }
        if (m.appId !== null && item !== null) {
          const ok = await this.write(api.putOverlay(m.appId, item, "altered", body, String(data.get("reason") ?? "")))
          this.dispatch({ t: "edit", item: ok ? null : item, error: ok ? null : this.model.holdError })
        }
        return
      }
      case "narrative": {
        const id = parseId(form.dataset["narrative"] ?? null)
        if (id === null) return
        const r = await api.saveNarrative(id, String(data.get("body") ?? ""))
        if (r.ok) {
          void this.loadFocus()
          void this.loadRoot()
        }
        return
      }
      default:
        return
    }
  }
}

function strip(msg: { t: "grid"; cols?: number; scroll?: number; viewport?: number; rem?: number }) {
  const out: Partial<Model["grid"]> = {}
  if (msg.cols !== undefined) out.cols = Math.max(msg.cols, 1)
  if (msg.scroll !== undefined) out.scroll = msg.scroll
  if (msg.viewport !== undefined) out.viewport = msg.viewport
  if (msg.rem !== undefined) out.rem = msg.rem
  return out
}

function lensOf(v: string | null): Lens {
  return v === "battleplan" || v === "root" ? v : "board"
}

function parseId(v: string | null): number | null {
  if (v === null) return null
  const n = Number.parseInt(v, 10)
  return Number.isFinite(n) && String(n) === v.trim() ? n : null
}

function remPx(): number {
  return Number.parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
}

function titleOf(m: Model): string {
  if (m.lens === "root") return "Root CV · Hireme"
  if (m.focus) return `${m.focus.job.company} · ${m.focus.job.code} · Hireme`
  return "Desk · Hireme"
}
