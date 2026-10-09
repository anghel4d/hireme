import "../css/app.css"
import { httpLink } from "./api.ts"
import { Shell } from "./shell.ts"
import { loadKernel, LocalDesk } from "./store.ts"

const root = document.getElementById("desk")
if (!(root instanceof HTMLElement)) throw new Error("Missing #desk")

try {
  // The desk exists at once and fills as the link brings it.
  const desk = new LocalDesk()
  const kernel = await loadKernel("/wasm/desk.wasm")
  desk.attach(httpLink(desk, kernel))
  new Shell(root, desk)
} catch (cause) {
  root.textContent = cause instanceof Error ? cause.message : String(cause)
  console.error(cause)
}
