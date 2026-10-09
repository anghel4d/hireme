import "../css/app.css"
import { fetchPacket } from "./api.ts"
import { Shell } from "./shell.ts"
import { loadKernel, Store } from "./store.ts"

const root = document.getElementById("desk")
if (!(root instanceof HTMLElement)) throw new Error("Missing #desk")

try {
  // The kernel and the first packet are independent requests.
  const [kernel, packet] = await Promise.all([loadKernel("/wasm/desk.wasm"), fetchPacket()])
  const loadStore = async () => new Store(kernel, await fetchPacket())
  new Shell(root, new Store(kernel, packet), loadStore)
} catch (cause) {
  root.textContent = cause instanceof Error ? cause.message : String(cause)
  console.error(cause)
}
