// Boot. The desk exists at once and fills as its link brings it. On the
// wire, the early script in <head> has already started the handshake and
// the snapshot read; the snapshot paints the board before the network
// answers, and HELLO names its rev so the server sends only what moved.

import "../css/app.css"
import { csrf } from "./api.ts"
import { Shell } from "./shell.ts"
import { loadWireKernel, LocalDesk, type Link } from "./store.ts"
import { hint, Wire } from "./wire.ts"

const root = document.getElementById("desk")
if (!(root instanceof HTMLElement)) throw new Error("Missing #desk")

const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ""

try {
  const kernel = await loadWireKernel("/wasm/kernel.wasm")
  const early = window.__hw
  const desk = new LocalDesk(kernel, meta("wire-scope"), early?.clientId)
  const snap = await desk.snapshot?.load(early?.snap)
  if (snap) {
    desk.restore(snap.bytes, snap.ops)
    performance.mark("desk:snapshot")
  }
  const wire = new Wire(desk, csrf(), { gate: meta("wire-gate"), ticket: meta("wire-ticket"), hashes: meta("wire-gate-hashes") }, early)
  desk.attach(wireLink(wire, desk.hash))
  new Shell(root, desk)
  wire.run()
  Object.assign(window, { __desk: desk, __wire: wire })
} catch (cause) {
  root.textContent = cause instanceof Error ? cause.message : String(cause)
  console.error(cause)
}

/**
 * The desk's link over the wire. Ops go on the control stream (sent again
 * after a reconnect if unacknowledged); the visible set goes out as a HINT
 * datagram when it changes, and a focus a draw is missing jumps to the
 * front of the next one.
 */
function wireLink(wire: Wire, hash: number): Link {
  let visible: readonly number[] = []
  let sent = ""
  const asked = new Map<number, number>()
  const send = (ids: readonly number[]) => {
    const key = ids.join(",")
    if (key === sent) return
    sent = key
    wire.datagram(hint(hash, ids.slice(0, 256)))
  }
  return {
    send(p) {
      wire.control(p.frame)
    },
    want(focus) {
      const now = performance.now()
      const fresh = focus.filter((id) => (asked.get(id) ?? 0) < now)
      if (fresh.length === 0) return
      for (const id of fresh) asked.set(id, now + 2000)
      send([...fresh, ...visible.filter((id) => !fresh.includes(id))])
    },
    hint(ids) {
      visible = ids
      send(ids)
    },
  }
}
