// Inlined in <head> before the bundle (its built text is hashed into the
// CSP). It starts the three slow things at once so none waits on the
// bundle or on another: the carrier's handshake, the kernel's compile, and
// the read of the last snapshot from IndexedDB. HELLO goes when the
// carrier is up and the snapshot has answered, or after SNAP_WAIT_MS
// without it: naming the snapshot's rev turns a full BOOT into a few
// PATCHes, which is worth a short wait but not a long one. The bundle
// adopts all of it from `window.__hw`; frames that land first wait in a
// queue. It imports only frame builders, which esbuild tree-shakes down.

import { CRED, hello, meta, type Early } from "./wire.ts"

/** What the bundle finds on `window.__hw`. */
export interface Boot extends Early {
  kernel: Promise<WebAssembly.Module>
  snap: Promise<Snapshot | undefined>
  /** Settles when early's carrier attempt has an outcome: adopt it then, never beside it. */
  ready: Promise<void>
}

/** One snapshot per scope (the shell's opaque per-account id), in IndexedDB `hireme`/`snap`. */
export interface Snapshot {
  rev: bigint
  schemaRev: bigint
  wireHash: number
  bytes: Uint8Array<ArrayBuffer>
}

const SNAP_WAIT_MS = 120

{
  const m = meta()
  const scope = document.querySelector<HTMLMetaElement>('meta[name="hireme-scope"]')?.content ?? ""
  const hw: Boot = {
    queue: [],
    helloSent: false,
    ready: Promise.resolve(),
    kernel: WebAssembly.compileStreaming(fetch("/wasm/kernel.wasm")),
    snap: new Promise((resolve) => {
      if (scope === "" || !("indexedDB" in window)) return resolve(undefined)
      setTimeout(() => resolve(undefined), 2000)
      const open = indexedDB.open("hireme", 1)
      open.onupgradeneeded = () => open.result.createObjectStore("snap")
      open.onerror = () => resolve(undefined)
      open.onsuccess = () => {
        try {
          const get = open.result.transaction("snap").objectStore("snap").get(scope)
          get.onsuccess = () => {
            const s = get.result as Snapshot | undefined
            resolve(s && s.wireHash === m.hash ? s : undefined)
          }
          get.onerror = () => resolve(undefined)
        } catch {
          resolve(undefined)
        }
      }
    }),
  }
  hw.kernel.catch(() => {})
  let settle = () => {}
  hw.ready = new Promise((r) => (settle = r))

  // The snapshot, or nothing after a short wait.
  const named = Promise.race([hw.snap, new Promise<undefined>((r) => setTimeout(r, SNAP_WAIT_MS))])
  const first = async (): Promise<Uint8Array<ArrayBuffer>> => {
    const s = await named
    const ticket = m.ticket
    return hello(m.hash, {
      cred: CRED.ticket,
      credential: ticket,
      snapshotRev: s?.rev ?? 0n,
      schemaRev: s?.schemaRev ?? 0n,
      label: navigator.userAgent.slice(0, 120),
    })
  }

  if (m.ticket !== "" && Number.isFinite(m.hash)) {
    const socket = () => {
      const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/wire`)
      ws.binaryType = "arraybuffer"
      ws.onmessage = (e) => hw.queue.push(e.data as ArrayBuffer)
      ws.onopen = () => void first().then((f) => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(f)
          hw.helloSent = true
        }
        settle()
      })
      ws.onerror = settle
      hw.ws = ws
    }
    if (m.gate !== "" && "WebTransport" in window) {
      void (async () => {
        const wt = new WebTransport(m.gate, m.hashes.length > 0 ? { serverCertificateHashes: m.hashes } : {})
        wt.closed.catch(() => {})
        await wt.ready
        const stream = await wt.createBidirectionalStream()
        const writer = stream.writable.getWriter()
        await writer.write(await first())
        // The bundle drains the streams; until then, nothing reads them, and the transport buffers.
        hw.wt = wt
        hw.writer = writer
        hw.control = stream.readable
        hw.helloSent = true
        settle()
      })().catch(socket)
    } else {
      socket()
    }
  } else {
    settle()
  }

  ;(window as { __hw?: Boot }).__hw = hw
}
