// Boot. The desk exists at once and fills as its link brings it. On the
// wire, the early script in <head> has already started the handshake, the
// snapshot read and HELLO; the snapshot paints the board before the
// network answers, and HELLO names its rev so the server replays only
// what moved since.

import "../css/app.css"
import { csrf, useAccountLink } from "./api.ts"
import type { Settings } from "./api.ts"
import { Shell } from "./shell.ts"
import { loadWireKernel, LocalDesk } from "./store.ts"
import { boardIn, header, Wire } from "./wire.ts"

const root = document.getElementById("desk")
if (!(root instanceof HTMLElement)) throw new Error("Missing #desk")

const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ""

try {
  const early = window.__hw
  const kernel = await loadWireKernel("/wasm/kernel.wasm", early?.kernel)
  const desk = new LocalDesk(kernel, meta("wire-scope"), early?.clientId)
  const wire = new Wire(desk, csrf(), { gate: meta("wire-gate"), ticket: meta("wire-ticket"), hashes: meta("wire-gate-hashes") }, early)
  desk.attach({ send: (p) => void wire.control(p.frame) })
  desk.onReset = () => wire.reconnect()
  useAccountLink({
    call: (method, params) => wire.call(method, params),
    settings: () => desk.account(),
    ready: () => new Promise<Settings>((resolve) => {
      const now = desk.account()
      if (now) return resolve(now)
      const off = desk.subscribe((c) => {
        const s = c.account ? desk.account() : null
        if (s) {
          off()
          resolve(s)
        }
      })
    }),
  })
  new Shell(root, desk)
  // The board came in the page: the first card waits on no socket.
  if (early?.board) {
    const h = header(early.board)
    desk.frame(early.board, h.kind, h.flags)
    boardIn()
  }
  wire.run()
  // The saved desk paints if it is back before the network's, which replaces it.
  void desk.snapshot?.load(early?.snap).then((snap) => {
    if (snap && desk.restore(snap.bytes, snap.ops)) performance.mark("desk:snapshot")
  })
  Object.assign(window, { __desk: desk, __wire: wire })
} catch (cause) {
  root.textContent = cause instanceof Error ? cause.message : String(cause)
  console.error(cause)
}
