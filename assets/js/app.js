import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/hireme"
import Hooks from "./hooks"
import "../css/app.css"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
  metadata: {
    keydown: (e) => ({
      typing: ["INPUT", "TEXTAREA", "SELECT"].includes(e.target && e.target.tagName),
      field: (e.target && e.target.id) || "",
      meta: e.metaKey || e.ctrlKey || e.altKey
    })
  }
})

const navKeys = new Set([
  "h", "j", "k", "l",
  "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
  "Enter", "f", "Escape", "/"
])

// The server owns the keymap. The browser only keeps these keys from
// scrolling the page, and lets Escape leave a field.
window.addEventListener("keydown", (e) => {
  const el = document.activeElement
  const tag = el && el.tagName
  const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT"
  if (e.key === "Escape" && typing && el.id !== "q") {
    e.preventDefault()
    e.stopPropagation()
    el.blur()
    return
  }
  if (e.key === "Escape" && el && el.id === "q") el.blur()
  if (typing) return
  if (navKeys.has(e.key)) e.preventDefault()
}, true)

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    window.liveReloader = reloader
  })
}
