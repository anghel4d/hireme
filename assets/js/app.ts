import "../css/app.css"
import { fetchPacket } from "./api.ts"
import { Shell } from "./shell.ts"
import { loadKernel, Store } from "./store.ts"

const root = document.getElementById("desk")
if (!(root instanceof HTMLElement)) throw new Error("Missing #desk")

try {
  const kernel = await loadKernel("/wasm/desk.wasm")
  const loadStore = async () => new Store(kernel, await fetchPacket())
  new Shell(root, await loadStore(), loadStore)
} catch (cause) {
  root.textContent = cause instanceof Error ? cause.message : String(cause)
  console.error(cause)
}
