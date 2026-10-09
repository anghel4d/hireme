// The shell: one model, pure views, a draw that morphs. The address is
// the board's identity; the desk's resident state is what it is drawn
// from. Nothing on the board waits on the network: a selection draws its
// focus in the frame of the input, a write is applied by the desk and
// drawn in that same frame, and the server's answer only settles it or,
// on a refusal, rolls it back with a notice. Only the account screens
// (keys, sessions, ways in, second factors) still talk HTTP, because each
// of those writes must be confirmed before it is shown.

import * as api from "./api.ts"
import { csrf, type Focus, type Settings } from "./api.ts"
import * as grid from "./board.ts"
import { fromParams, lower, toParams, type Filters } from "./board.ts"
import { h, Keyed, morph, raw, type Raw } from "./html.ts"
import * as webauthn from "./webauthn.ts"
import type { Change, Desk, Mark, Op, Refusal, Tables } from "./store.ts"
import * as views from "./views.ts"

type Lens = "board" | "battleplan" | "root" | "gym" | "net" | "settings"

interface Model {
  filters: Filters
  lens: Lens
  appId: number | null
  index: number
  count: number
  laneError: string | null
  settings: Settings | null
  reveal: views.Reveal | null
  renaming: number | null
  settingsError: string | null
  settingsNotice: string | null
  enrolling: views.Enrolling
  stepUp: views.StepUp | null
  editing: number | null
  /** The CV line whose actions are showing. */
  line: number | null
  alterError: string | null
  /** Why the selected application's last write was refused, predicted or by the server. */
  refusal: string | null
  notices: views.Notice[]
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
  | { t: "line"; item: number | null }
  | { t: "grid"; cols?: number; scroll?: number; viewport?: number; rem?: number }
  | { t: "desk"; change: Change }
  | { t: "ran"; op: Op; refusal: Refusal | null }
  | { t: "dismiss"; id: number }
  | { t: "settings"; settings: Settings | null; reveal?: views.Reveal | null; error?: string | null; notice?: string | null }
  | { t: "rename"; id: number | null }
  | { t: "enrolling"; enrolling: views.Enrolling }
  | { t: "step-up"; prompt: views.StepUp | null }
  | { t: "sheet"; open: boolean }

/** How long a rollback notice stays up unless dismissed. */
const NOTICE_MS = 8000

/** Keystrokes in a free-text field coalesce into one write after this pause. */
const TYPING_MS = 300

/** The address follows the model this long after the last change. */
const ADDRESS_MS = 150

export class Shell {
  private model: Model
  private readonly desk: Desk
  private root: HTMLElement
  private readonly compactQuery = matchMedia("(max-width: 980px)")
  private drawQueued = false
  private tables: Tables
  private noticeSeq = 0

  constructor(root: HTMLElement, desk: Desk) {
    this.root = root
    this.desk = desk
    this.tables = desk.tables
    const params = new URLSearchParams(location.search)
    this.model = {
      filters: fromParams(params, desk.tables),
      lens: lensOf(params.get("lens")),
      appId: parseId(params.get("app")),
      index: -1,
      count: 0,
      laneError: null,
      settings: null,
      reveal: null,
      renaming: null,
      settingsError: null,
      settingsNotice: LINKED.get(params.get("linked") ?? "") ?? null,
      enrolling: null,
      stepUp: null,
      editing: null,
      line: null,
      alterError: null,
      refusal: null,
      notices: [],
      sheet: false,
      grid: { cols: 3, scroll: 0, viewport: 640, rem: remPx() },
    }
    this.linkErrors = LINK_ERRORS.get(params.get("link_error") ?? "") ?? null
    desk.subscribe((change) => { if (!this.unseen(change)) this.dispatch({ t: "desk", change }) })
    this.build()
  }

  private plane: HTMLElement | null = null
  private cards: views.Cards | null = null
  private linkErrors: string | null

  // Nothing is laid out or painted before the board arrives (or the link
  // gives up): until then the main thread belongs to the socket.
  private build(): void {
    if (this.plane || (this.desk.n === 0 && this.desk.status !== "offline")) return
    this.root.innerHTML = `
      <div id="topbar"></div>
      <div id="notice-slot"></div>
      <div id="scoreboard-slot"></div>
      <div id="heat-slot"></div>
      <div class="desk-stage">
        <div id="workspace" class="workspace">
          <div id="grid" class="grid-scroll"><div id="plane" class="grid-plane"></div><div id="empty"></div></div>
          <div id="focus-slot"></div>
        </div>
        <div id="lens"></div>
      </div>`
    this.plane = this.root.querySelector<HTMLElement>("#plane") as HTMLElement
    this.cards = new views.Cards(this.plane)
    this.bind()
    this.select()
    if (this.model.appId === null) this.model.appId = this.idAt(0)
    if (this.model.lens === "settings") void this.loadSettings(this.linkErrors)
    this.queueDraw()
  }

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
          m.line = null
          m.alterError = null
          m.refusal = null
          m.index = this.desk.find(msg.id)
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
        if (msg.lens === "settings") void this.loadSettings()
        break
      case "escape":
        if (m.lens !== "board") m.lens = "board"
        else if (this.compactQuery.matches && m.sheet) m.sheet = false
        else if (m.filters.q !== "") this.dispatch({ t: "filters", filters: { ...m.filters, q: "" } })
        break
      case "line":
        m.line = msg.item
        break
      case "edit":
        m.editing = msg.item
        m.alterError = msg.error ?? null
        break
      case "grid": {
        const g = { ...m.grid, ...strip(msg) }
        const colsChanged = g.cols !== m.grid.cols
        m.grid = g
        if (colsChanged) this.reveal()
        break
      }
      case "desk":
        this.build()
        this.onDesk(msg.change)
        break
      case "ran": {
        // A refusal predicted here was never applied; an accepted write is
        // already in the desk's view and needs nothing from the shell.
        const text = msg.refusal === null ? null : refusalText(msg.refusal)
        if (isLaneOp(msg.op)) m.laneError = text
        else m.refusal = text
        break
      }
      case "dismiss":
        m.notices = m.notices.filter((n) => n.id !== msg.id)
        break
      case "settings":
        m.settings = msg.settings
        if (msg.reveal !== undefined) m.reveal = msg.reveal
        m.settingsError = msg.error ?? null
        if (msg.notice !== undefined) m.settingsNotice = msg.notice
        m.renaming = null
        break
      case "rename":
        m.renaming = msg.id
        break
      case "enrolling":
        m.enrolling = msg.enrolling
        break
      case "step-up":
        m.stepUp = msg.prompt
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

  // The desk changed under the board: its rows (a PATCH, a BOOT, or a
  // write applied or rolled back), a focus, the lanes, the link, or the
  // server refused a write already drawn.
  private onDesk(c: Change): void {
    const m = this.model
    if (this.desk.tables !== this.tables) {
      // New tables (the first BOOT, a new batch) can name values the
      // address asked for that the old tables did not know.
      if (this.tables.stages.length > 0) this.writeAddress()
      this.tables = this.desk.tables
      m.filters = fromParams(new URLSearchParams(location.search), this.tables)
      this.select()
    } else if (c.rows) {
      this.select()
    }
    if (m.appId === null && m.count > 0) m.appId = this.idAt(0)
    // Keys, sessions, ways in or factors changed: this tab's write, another
    // tab's, an agent's, or a sign-in elsewhere.
    if (c.account) m.settings = this.desk.account() ?? m.settings
    const r = c.refused
    if (r) {
      const text = refusalText(r.refusal)
      const id = ++this.noticeSeq
      // The same refusal again replaces its notice rather than stacking a copy.
      const notice = `Rolled back ${this.describe(r.op)}. ${text}`
      m.notices = [...m.notices.filter((n) => n.text !== notice).slice(-2), { id, text: notice }]
      window.setTimeout(() => this.dispatch({ t: "dismiss", id }), NOTICE_MS)
      if (isLaneOp(r.op)) m.laneError = text
      else if (r.jobId !== null && r.jobId === m.appId) m.refusal = text
    }
  }

  /**
   * A change nothing on screen draws from: focuses streaming in for cards
   * other than the selected one. Those land by the hundred after a BOOT
   * and each would otherwise cost a draw that changes nothing.
   */
  private unseen(c: Change): boolean {
    if (c.rows || c.root || c.scoreboard || c.lanes || c.status || c.acked !== undefined || c.refused || c.account) return false
    if (this.desk.tables !== this.tables) return false
    const id = this.model.appId
    // "all": a write that touches a profile, lineage, items or narratives recomposes every focus.
    const focus = c.focus
    return id === null || (focus !== "all" && !(focus ?? []).includes(id))
  }

  /** Apply a write: the desk predicts it locally or refuses it at once. */
  private run(op: Op): boolean {
    const r = this.desk.run(op)
    this.dispatch({ t: "ran", op, refusal: r.ok ? null : r.refusal })
    return r.ok
  }

  private describe(op: Op): string {
    const job = "job" in op && op.job !== null ? op.job : null
    const row = job === null ? -1 : this.desk.rowOf(job)
    const on = job === null ? "" : ` on ${row < 0 ? `JobApp${job}` : this.desk.str("company").at(row)}`
    return op.kind === "open_fire" ? `open fire on ${op.batch}` : `the ${WHAT[op.kind]}${on}`
  }

  private select(): void {
    const m = this.model
    m.count = this.desk.select(lower(m.filters, this.desk.tables))
    m.index = m.appId === null ? -1 : this.desk.find(m.appId)
  }

  private idAt(pos: number): number | null {
    const row = this.desk.selection()[pos]
    if (row === undefined) return null
    return this.desk.column("id")[row] ?? null
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

  // ---- the account: confirmed HTTP writes ----

  // The account tables are resident once BOOT lands; before that, wait for them.
  private async loadSettings(error: string | null = null): Promise<void> {
    const resident = this.desk.account()
    if (resident) {
      this.dispatch({ t: "settings", settings: resident, error })
      return
    }
    try {
      this.dispatch({ t: "settings", settings: await api.fetchSettings(), error })
    } catch {
      this.dispatch({ t: "settings", settings: null, error: "The account could not be read." })
    }
  }

  private async settingsWrite(run: () => Promise<api.Outcome<api.SettingsReply>>, reveal?: views.Reveal | null): Promise<void> {
    const r = await this.stepped(run)
    if (r === null) return
    if (r.ok) {
      const made = r.value.secret && r.value.created ? { name: r.value.created.name, secret: r.value.secret } : reveal
      this.dispatch({ t: "settings", settings: r.value, reveal: made, notice: null })
    } else this.dispatch({ t: "settings", settings: this.model.settings, error: r.error, notice: null })
  }

  // A sensitive write refused with step_up waits for a factor, then runs again; null if the person cancels.
  private async stepped<T>(run: () => Promise<api.Outcome<T>>): Promise<api.Outcome<T> | null> {
    const first = await run()
    if (first.ok || first.error !== "step_up") return first
    const proven = await this.stepUp()
    if (!proven) return null
    return run()
  }

  private pendingStepUp: ((proven: boolean) => void) | null = null

  private stepUp(): Promise<boolean> {
    const methods = this.model.settings?.security.methods ?? []
    const passkeys = methods.some((x) => x.kind === "webauthn")
    this.dispatch({ t: "step-up", prompt: { passkeys, factors: methods.length > 0, error: null } })
    return new Promise((resolve) => { this.pendingStepUp = resolve })
  }

  private settleStepUp(proven: boolean, error: string | null = null): void {
    if (proven || error === null) {
      this.dispatch({ t: "step-up", prompt: null })
      this.pendingStepUp?.(proven)
      this.pendingStepUp = null
    } else {
      const prompt = this.model.stepUp ?? { passkeys: false, factors: true, error: null }
      this.dispatch({ t: "step-up", prompt: { ...prompt, error } })
    }
  }

  private async securityWrite(run: () => Promise<api.Outcome<api.SecurityReply>>): Promise<api.SecurityReply | null> {
    const r = await this.stepped(run)
    if (r === null) return null
    if (!r.ok) {
      this.dispatch({ t: "settings", settings: this.model.settings, error: r.error })
      return null
    }
    const settings = this.model.settings ? { ...this.model.settings, security: r.value } : null
    this.dispatch({ t: "settings", settings, reveal: this.model.reveal })
    if (r.value.recovery_codes && r.value.recovery_codes.length > 0) this.dispatch({ t: "enrolling", enrolling: { kind: "codes", codes: r.value.recovery_codes } })
    else this.dispatch({ t: "enrolling", enrolling: null })
    return r.value
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
    if (!this.plane) return
    const m = this.model
    const d = this.desk
    const t = d.tables
    const lanes = d.lanes()
    const focus = m.appId === null ? null : d.focus(m.appId)
    const mark = m.appId === null ? null : d.mark(m.appId)
    this.set("#topbar", views.topbar(t, d.status))
    this.set("#count", h`${m.count} showing`)
    // The controls hold the filters' values; a control in use keeps what is in it.
    const form = this.root.querySelector<HTMLFormElement>("#filters")
    for (const [name, v] of form ? grid.fields(m.filters) : []) {
      const el = form?.elements.namedItem(name)
      if ((el instanceof HTMLInputElement || el instanceof HTMLSelectElement) && el !== document.activeElement && el.value !== v) el.value = v
    }
    this.set("#notice-slot", views.notices(m.notices))
    this.set("#scoreboard-slot", views.scoreboard(d.scoreboard()))
    this.set("#lane-pills", views.lanePills(lanes))
    this.set("#heat-slot", views.heatChart(lanes, m.filters))

    const lens = this.root.querySelector<HTMLElement>("#lens")
    const workspace = this.root.querySelector<HTMLElement>("#workspace")
    if (!lens || !workspace) return

    // A lens covers the board rather than replacing it: the board keeps its
    // layout underneath, so coming back costs a paint, not a relayout of
    // every card. Covered, it renders nothing and takes no focus.
    if (m.lens === "board") {
      morph(lens, raw(""))
      if (workspace.dataset["covered"]) delete workspace.dataset["covered"]
      this.drawBoard(focus, mark)
    } else {
      morph(lens, this.lensView(focus, lanes))
      if (m.lens === "battleplan" && focus) this.drawBattleplanSlots(lens, focus, mark)
      if ((m.lens === "gym" || m.lens === "net") && lanes) this.list(lens.querySelector("#lane-recent"), views.laneRecent(lanes, m.lens))
      if (!workspace.dataset["covered"]) workspace.dataset["covered"] = "1"
    }
    // Assigning the title rewrites the <title> node even when it is the same.
    const title = titleOf(m, focus)
    if (document.title !== title) document.title = title
  }

  private lensView(focus: Focus | null, lanes: api.Lanes | null): Raw {
    const m = this.model
    switch (m.lens) {
      case "battleplan":
        return focus
          ? h`<div class="battleplan-wrap">${views.battleplan(focus, m.refusal)}</div>`
          : raw("")
      case "root": {
        const root = this.rootProfile()
        const r = root === null ? null : this.desk.root(root)
        return r ? h`<div class="root-wrap">${views.rootView(r)}</div>` : raw("")
      }
      case "gym":
        return lanes ? h`<div class="lane-wrap">${views.gymView(lanes, m.laneError)}</div>` : raw("")
      case "net":
        return lanes ? h`<div class="lane-wrap">${views.netView(lanes, m.laneError)}</div>` : raw("")
      case "settings":
        return h`<div class="lane-wrap">${views.settingsView(m.settings, m.reveal, m.renaming, m.settingsError, csrf(), m.enrolling, m.stepUp, m.settingsNotice)}</div>`
      case "board":
        return raw("")
    }
  }

  // The battleplan frame leaves its slots alone; each is morphed here and
  // skipped outright when its HTML is what it last drew.
  // The pending mark is a class set here, not part of the frame's HTML, so
  // a write's mark alone never re-walks the frame.
  private drawBattleplanSlots(lens: HTMLElement, focus: Focus, mark: Mark): void {
    const m = this.model
    const parts = views.battleplanSlots(focus)
    const slot = (id: string, html: Raw) => {
      const el = lens.querySelector(id)
      if (el) morph(el, html)
    }
    slot("#bp-bar", parts.bar)
    slot("#bp-narrative", parts.narrative)
    this.list(lens.querySelector("#bp-events"), parts.events)
    this.list(lens.querySelector("#bp-paper"), views.paperBlocks(focus.cv, true, m.editing, m.alterError, m.line))
    this.list(lens.querySelector("#bp-rail"), parts.rail)
    lens.querySelector("#battleplan")?.classList.toggle("is-pending", mark === "pending")
  }

  // An ordered keyed list per slot element; a reopened lens has new elements.
  private readonly lists = new WeakMap<Element, Keyed>()
  private list(el: Element | null, items: [number, Raw][]): void {
    if (!el) return
    let keyed = this.lists.get(el)
    if (!keyed) this.lists.set(el, (keyed = new Keyed(el)))
    keyed.set(items)
  }

  // The root CV shown: the filtered profile's, else the selected application's, else the first.
  private rootProfile(): number | null {
    const m = this.model
    const profiles = this.desk.tables.profiles
    const slug = m.filters.profile.kind === "one" ? m.filters.profile.value : null
    const bySlug = profiles.find((p) => p.slug === slug)
    if (bySlug) return bySlug.id
    const row = m.appId === null ? -1 : this.desk.rowOf(m.appId)
    const ix = row < 0 ? undefined : this.desk.column("profile")[row]
    return (ix === undefined ? undefined : profiles[ix])?.id ?? profiles[0]?.id ?? null
  }

  private drawBoard(focus: Focus | null, mark: Mark): void {
    const m = this.model
    const d = this.desk
    const metrics = grid.metrics(m.grid.rem)
    const [start, last] = grid.slice(m.count, m.grid.cols, m.grid.scroll, m.grid.viewport, metrics)
    const sel = d.selection()
    const ids = d.column("id")
    const parts: [number, string, () => string[]][] = []
    const place = (pos: number) => {
      const row = sel[pos]
      if (row === undefined) return
      const id = ids[row] ?? 0
      const [x, y] = grid.origin(pos, m.grid.cols, metrics)
      const [cx, cy, active, mark] = [Math.round(x), Math.round(y), id === m.appId, d.mark(id)]
      parts.push([id, `${d.version(id)} ${cx} ${cy} ${active} ${mark}`, () => views.cardValues(d, row, cx, cy, active, mark)])
    }
    if (m.index >= 0 && (m.index < start || m.index > last)) place(m.index)
    if (start >= 0) for (let p = start; p <= last; p++) place(p)

    const height = `${Math.round(grid.contentHeight(m.count, m.grid.cols, metrics))}px`
    if (this.plane && this.plane.style.height !== height) this.plane.style.height = height
    this.cards?.set(parts)
    this.set("#empty", m.count === 0 && d.n > 0 ? views.emptyBoard() : raw(""))
    this.set("#focus-slot", focus ? views.focusPanel(focus, m.index >= 0, m.sheet, m.refusal, mark) : views.emptyFocus())
  }

  private set(selector: string, html: Raw): void {
    const el = this.root.querySelector<HTMLElement>(selector)
    if (el) morph(el, html)
  }

  // The address is not drawn: writing it (history.replaceState costs about
  // 0.4 ms) waits until input pauses, off the frame that answers the input.
  private addressTimer = 0

  private syncAddress(): void {
    if (this.addressTimer) return
    this.addressTimer = window.setTimeout(() => this.writeAddress(), ADDRESS_MS)
  }

  private writeAddress(): void {
    clearTimeout(this.addressTimer)
    this.addressTimer = 0
    // Until the first BOOT names its tables the filters are defaults; the
    // address keeps what was asked for until it can be read.
    if (this.desk.tables.stages.length === 0) return
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
        this.dispatch({ t: "filters", filters: fromParams(u.searchParams, this.desk.tables) })
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
        this.dispatch({ t: "filters", filters: fromParams(p, this.desk.tables) })
        return
      }
      // Typed text is already on screen; the write coalesces keystrokes and
      // goes to the application the text was typed into, even if another
      // is selected before it fires. A picked date writes at once.
      const job = this.model.appId
      if (job === null) return
      if (form.dataset["form"] === "next") {
        const write = () => {
          const data = new FormData(form)
          this.run({ kind: "next", job, next_action: String(data.get("next_action") ?? "").trim(), next_due: String(data.get("next_due") ?? "") })
        }
        if (target instanceof HTMLInputElement && target.type === "date") this.flush(`next-${job}`, write)
        else this.debounce(`next-${job}`, TYPING_MS, write)
      } else if (form.dataset["form"] === "note") {
        const stage = form.dataset["stage"]
        if (!stage) return
        this.debounce(`note-${job}`, TYPING_MS, () => {
          this.run({ kind: "note", job, stage, note: String(new FormData(form).get("note") ?? "") })
        })
      }
    })

    root.addEventListener("submit", (e) => {
      const form = e.target as HTMLFormElement
      // Shell forms carry data-form. A posted form with an action, such as
      // sign-out, must actually navigate; the filter form has no action.
      if (form.dataset["form"]) {
        e.preventDefault()
        void this.onSubmit(form)
      } else if (!form.getAttribute("action")) {
        e.preventDefault()
      }
    })

    const gridEl = root.querySelector<HTMLElement>("#grid")
    if (gridEl) {
      gridEl.addEventListener("scroll", () => this.dispatch({ t: "grid", scroll: Math.round(gridEl.scrollTop) }), { passive: true })
      const measure = () => {
        // A hidden board (another lens is open) measures 0×0. Keeping the
        // last real geometry lets the board come back whole in one frame.
        if (gridEl.clientWidth === 0) return
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
      this.dispatch({ t: "filters", filters: fromParams(p, this.desk.tables) })
      const id = parseId(p.get("app"))
      if (id !== null) this.dispatch({ t: "select", id })
      this.dispatch({ t: "lens", lens: lensOf(p.get("lens")) })
    })
  }

  private readonly timers = new Map<string, number>()
  private debounce(key: string, ms: number, fn: () => void): void {
    const prev = this.timers.get(key)
    if (prev) clearTimeout(prev)
    this.timers.set(key, window.setTimeout(() => { this.timers.delete(key); fn() }, ms))
  }

  /** Run now, dropping the same write still waiting on its debounce. */
  private flush(key: string, fn: () => void): void {
    const prev = this.timers.get(key)
    if (prev) clearTimeout(prev)
    this.timers.delete(key)
    fn()
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
      case "lens": this.dispatch({ t: "lens", lens: lensOf(el.dataset["lens"] ?? null) }); return
      case "stage": {
        const stage = el.dataset["stage"]
        if (m.appId !== null && stage) this.run({ kind: "stage", job: m.appId, stage })
        return
      }
      case "open-fire": {
        const batch = el.dataset["batch"]
        if (batch) this.run({ kind: "open_fire", batch })
        return
      }
      case "mask": {
        const item = parseId(el.dataset["item"] ?? null)
        const mode = maskMode(el.dataset["mode"])
        if (m.appId !== null && item !== null && mode && this.run({ kind: "overlay", job: m.appId, item, mode })) this.dispatch({ t: "edit", item: null })
        return
      }
      case "dismiss-notice": {
        const id = parseId(el.dataset["id"] ?? null)
        if (id !== null) this.dispatch({ t: "dismiss", id })
        return
      }
      case "edit": this.dispatch({ t: "edit", item: parseId(el.dataset["item"] ?? null) }); return
      case "line": this.dispatch({ t: "line", item: parseId(el.dataset["item"] ?? null) }); return
      case "cancel-edit": this.dispatch({ t: "edit", item: null }); return
      case "copy": {
        const text = el.dataset["copy"]
        if (text) void navigator.clipboard.writeText(text)
        return
      }
      case "dismiss-secret": this.dispatch({ t: "settings", settings: m.settings, reveal: null }); return
      case "rename": this.dispatch({ t: "rename", id: parseId(el.dataset["id"] ?? null) }); return
      case "cancel-rename": this.dispatch({ t: "rename", id: null }); return
      case "revoke-key": {
        const id = parseId(el.dataset["id"] ?? null)
        if (id !== null && confirm(`Revoke the key "${el.dataset["name"] ?? ""}"? Agents using it stop at once.`)) await this.settingsWrite(() => api.revokeKey(id))
        return
      }
      case "enroll-totp": {
        const r = await this.stepped(() => api.beginTotp())
        if (r === null) return
        if (r.ok) this.dispatch({ t: "enrolling", enrolling: { kind: "totp", svg: r.value.svg, secret: r.value.secret } })
        else this.dispatch({ t: "settings", settings: m.settings, error: r.error })
        return
      }
      case "enroll-webauthn": {
        if (!webauthn.supported()) { this.dispatch({ t: "settings", settings: m.settings, error: "This browser has no passkey support." }); return }
        const options = await this.stepped(() => api.beginWebauthn())
        if (options === null) return
        if (!options.ok) { this.dispatch({ t: "settings", settings: m.settings, error: options.error }); return }
        try {
          const credential = await webauthn.create(options.value as never)
          const name = prompt("Name this passkey or key", "") ?? ""
          await this.securityWrite(() => api.confirmWebauthn(credential, name))
        } catch (cause) {
          this.dispatch({ t: "settings", settings: m.settings, error: cause instanceof Error ? cause.message : String(cause) })
        }
        return
      }
      case "cancel-enroll": this.dispatch({ t: "enrolling", enrolling: null }); return
      case "new-codes": {
        if (confirm("Replace your recovery codes? The old ones stop working.")) await this.securityWrite(() => api.newRecoveryCodes())
        return
      }
      case "remove-method": {
        const id = parseId(el.dataset["id"] ?? null)
        if (id !== null && confirm(`Remove "${el.dataset["name"] || "this factor"}"?`)) await this.securityWrite(() => api.removeMethod(id))
        return
      }
      case "step-up-webauthn": {
        try {
          const options = await api.stepUpWebauthn()
          if (!options.ok) { this.settleStepUp(false, options.error); return }
          const assertion = await webauthn.get(options.value as never)
          const r = await api.stepUpWebauthnConfirm(assertion)
          this.settleStepUp(r.ok, r.ok ? null : r.error)
        } catch (cause) {
          this.settleStepUp(false, cause instanceof Error ? cause.message : String(cause))
        }
        return
      }
      case "cancel-step-up": this.settleStepUp(false); return
      case "revoke-session": {
        const id = parseId(el.dataset["id"] ?? null)
        if (id === null) return
        const r = await api.revokeSession(id)
        if (r.ok && r.value.signed_out) location.assign("/sign-in")
        else if (r.ok) this.dispatch({ t: "settings", settings: r.value })
        else this.dispatch({ t: "settings", settings: m.settings, error: r.error })
        return
      }
      case "revoke-others": await this.settingsWrite(() => api.revokeOtherSessions()); return
      case "link-provider": {
        const provider = el.dataset["provider"]
        if (!provider) return
        const r = await this.stepped(() => api.linkProvider(provider))
        if (r === null) return
        if (r.ok) location.assign(r.value.url)
        else this.dispatch({ t: "settings", settings: m.settings, error: r.error })
        return
      }
      case "unlink-identity": {
        const id = parseId(el.dataset["id"] ?? null)
        if (id === null || !confirm(`Remove ${el.dataset["name"] ?? "this way in"}? It stops signing you in at once.`)) return
        const r = await this.stepped(() => api.unlinkIdentity(id))
        if (r === null) return
        if (!r.ok) { this.dispatch({ t: "settings", settings: m.settings, error: r.error }); return }
        this.dispatch({ t: "settings", settings: r.value, notice: "Removed. It no longer signs you in." })
        // ASVS 7.4.3: after removing a way in, offer to end the sessions that may have come through it.
        if (r.value.sessions.length > 1 && confirm("Sign out every other browser too? Any of them may have signed in that way.")) await this.settingsWrite(() => api.revokeOtherSessions())
        return
      }
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
          const ok = this.run({ kind: "overlay", job: m.appId, item, mode: "altered", body, reason: String(data.get("reason") ?? "") })
          this.dispatch({ t: "edit", item: ok ? null : item, error: ok ? null : this.model.refusal })
        }
        return
      }
      case "narrative": {
        const narrative = parseId(form.dataset["narrative"] ?? null)
        if (narrative === null) return
        const job = m.lens === "root" ? null : m.appId
        this.run({ kind: "narrative", job, narrative, body: String(data.get("body") ?? "") })
        return
      }
      case "heat-override": {
        if (m.appId !== null) this.run({ kind: "heat_override", job: m.appId, reason: String(data.get("reason") ?? "") })
        return
      }
      case "create-key": {
        const days = String(data.get("expires_in_days") ?? "")
        const name = String(data.get("name") ?? "").trim()
        await this.settingsWrite(() => api.createKey(name, days === "" ? null : Number(days)))
        form.reset()
        return
      }
      case "rename-key": {
        const id = parseId(form.dataset["id"] ?? null)
        const name = String(data.get("name") ?? "").trim()
        if (id !== null) await this.settingsWrite(() => api.renameKey(id, name), m.reveal)
        return
      }
      case "confirm-totp": {
        const code = String(data.get("code") ?? "")
        const name = String(data.get("name") ?? "").trim() || "Authenticator app"
        await this.securityWrite(() => api.confirmTotp(code, name))
        return
      }
      case "link-email": {
        const email = String(data.get("email") ?? "").trim()
        const r = await this.stepped(() => api.linkEmail(email))
        if (r === null) return
        if (!r.ok) { this.dispatch({ t: "settings", settings: m.settings, error: r.error }); return }
        this.dispatch({ t: "settings", settings: r.value, notice: `A link is on its way to ${r.value.sent_to ?? email}. Open it in this browser to add the address.` })
        form.reset()
        return
      }
      case "step-up-code": {
        const code = String(data.get("code") ?? "").trim()
        const r = code.replace(/[^0-9]/g, "").length === 6 ? await api.stepUpTotp(code) : await api.stepUpRecovery(code)
        this.settleStepUp(r.ok, r.ok ? null : r.error)
        return
      }
      case "gym-target": this.run({ kind: "gym_target", target: String(data.get("target") ?? "") }); return
      case "gym-log": if (this.run({ kind: "gym_log", fields: fields(data) })) form.reset(); return
      case "net-lane": this.run({ kind: "net_lane", url: String(data.get("url") ?? "") }); return
      case "net-log": if (this.run({ kind: "net_log", fields: fields(data) })) form.reset(); return
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

/** What a refusal tells the person. The desk predicts most of these before anything is sent. */
function refusalText(r: Refusal): string {
  switch (r) {
    case "fire_hold": return "FIRE HOLD. Name open fire on this batch before a submit."
    case "heat": return "HEAT. This role would snap onto a company or ATS. Override needs a reason, or wait for cooldown."
    case "leased": return "This application is leased to an agent."
    case "cooldown": return "This CV is in its quarterly cooldown."
    case "not_additive": return "This generation accepts new lines only."
    case "invalid": return "The server did not accept that value."
    default: return r
  }
}

// What a rolled-back write is called in its notice.
const WHAT: Record<Op["kind"], string> = {
  stage: "stage change", next: "next action", note: "note", overlay: "CV line change", heat_override: "HEAT override", score: "score",
  open_fire: "open fire", narrative: "narrative", gym_log: "gym rep", gym_target: "gym target", net_log: "net entry", net_lane: "observer lane",
}

function isLaneOp(op: Op): boolean {
  return op.kind === "gym_log" || op.kind === "gym_target" || op.kind === "net_log" || op.kind === "net_lane"
}

function maskMode(v: string | undefined): "hidden" | "emphasized" | "altered" | "inherit" | null {
  return v === "hidden" || v === "emphasized" || v === "altered" || v === "inherit" ? v : null
}

// What the Account page says after a provider or a mailed link sends the browser back.
const LINKED = new Map([
  ["email", "That address now signs you in."],
  ["github", "GitHub now signs you in."],
  ["x", "X now signs you in."],
])

const LINK_ERRORS = new Map([
  ["taken", "That sign-in already belongs to another Hireme account, so it was not added."],
  ["denied", "Linking was cancelled."],
  ["failed", "Linking did not finish. Try again."],
])

function lensOf(v: string | null): Lens {
  return v === "battleplan" || v === "root" || v === "gym" || v === "net" || v === "settings" ? v : "board"
}

function fields(data: FormData): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [k, v] of data.entries()) out[k] = String(v)
  return out
}

function parseId(v: string | null): number | null {
  if (v === null) return null
  const n = Number.parseInt(v, 10)
  return Number.isFinite(n) && String(n) === v.trim() ? n : null
}

function remPx(): number {
  return Number.parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
}

function titleOf(m: Model, focus: Focus | null): string {
  if (m.lens === "root") return "Root CV · Hireme"
  if (m.lens === "gym") return "Gym · Hireme"
  if (m.lens === "net") return "Net · Hireme"
  if (m.lens === "settings") return "Account · Hireme"
  if (focus) return `${focus.job.company} · ${focus.job.code} · Hireme`
  return "Desk · Hireme"
}

function assertNever(x: never): never {
  throw new Error(`unreachable: ${JSON.stringify(x)}`)
}
