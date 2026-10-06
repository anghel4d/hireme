function cssLen(name, fallbackRem, rem) {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  if (raw.endsWith("rem")) return parseFloat(raw) * rem
  if (raw.endsWith("px")) return parseFloat(raw)
  return fallbackRem * rem
}

const Grid = {
  mounted() {
    this.onScroll = () => {
      if (this.silence) return
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.pushMetrics(), 40)
    }
    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.ro = new ResizeObserver(() => this.pushMetrics())
    this.ro.observe(this.el)
    this.handleEvent("scroll_to", ({top}) => {
      this.silence = true
      this.el.scrollTop = top
      this.silence = false
    })
    const initial = Number(this.el.dataset.scroll || 0)
    if (initial) this.el.scrollTop = initial
    this.pushMetrics()
  },
  destroyed() {
    if (this.ro) this.ro.disconnect()
    this.el.removeEventListener("scroll", this.onScroll)
    clearTimeout(this.timer)
  },
  pushMetrics() {
    if (this.el.clientWidth <= 0) return
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    const width = cssLen("--card-width", 14.5, rem)
    const gap = cssLen("--card-gap", 0.5, rem)
    const inset = cssLen("--card-inset", 0.5, rem)
    const inner = this.el.clientWidth - inset * 2
    const cols = Math.max(1, Math.floor((inner + gap) / (width + gap)))
    this.pushEvent("grid", {
      cols,
      scroll_top: this.el.scrollTop,
      viewport: this.el.clientHeight || 640,
      rem
    })
  }
}

const Desk = {
  mounted() {
    this.handleEvent("focus_search", () => {
      const input = document.getElementById("q")
      if (!input) return
      input.focus()
      input.select()
    })
    this.report = () => this.pushEvent("chrome", {compact: window.innerWidth <= 980})
    window.addEventListener("resize", this.report)
    this.report()
  },
  destroyed() {
    window.removeEventListener("resize", this.report)
  }
}

export default {Desk, Grid}
