// Inlined in <head> before the bundle (its built text is hashed into the
// CSP). It starts the three slow things at once so none waits on the
// bundle or on another: the carrier's handshake, the kernel's compile, and
// the read of the last snapshot from IndexedDB. HELLO goes when the
// carrier is up and the snapshot has answered, or after SNAP_WAIT_MS
// without it: naming the snapshot's rev turns a full BOOT into a few
// PATCHes, which is worth a short wait but not a long one. The bundle
// adopts all of it from `window.__hw`; frames that land first wait in a
// queue. It imports only frame builders, which the bundler tree-shakes down.

import { SCHEMA_REV } from "./gen/schema.ts"
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
/** WebTransport's head start before the socket is used instead (UDP blocked fails slowly, not at once). */
const WT_WAIT_MS = 3000

{
  const m = meta()
  const scope = document.querySelector<HTMLMetaElement>('meta[name="hireme-scope"]')?.content ?? ""
  const hw: Boot = {
    queue: [],
    helloSent: false,
    ready: Promise.resolve(),
    kernel: WebAssembly.compileStreaming(fetch(document.querySelector<HTMLLinkElement>('link[rel="preload"][as="fetch"]')?.href ?? "/wasm/kernel.wasm")),
    snap: new Promise((resolve) => {
      if (scope === "" || !("indexedDB" in window)) return resolve(undefined)
      setTimeout(() => resolve(undefined), 2000)
      // A profile with no database has no snapshot: known at once, not after opening (creating) one.
      void (indexedDB.databases?.() ?? Promise.resolve([{ name: "hireme" }])).then((dbs) => dbs.some((d) => d.name === "hireme"), () => true).then((has) => {
        if (!has) return resolve(undefined)
        let open: IDBOpenDBRequest
        try {
          // Blocked storage throws here rather than failing the request.
          open = indexedDB.open("hireme", 1)
        } catch {
          return resolve(undefined)
        }
        open.onupgradeneeded = () => open.result.createObjectStore("snap")
        open.onerror = () => resolve(undefined)
        open.onsuccess = () => {
          const db = open.result
          // The read's connection closes when it is done, so a sign-out's deleteDatabase is not blocked.
          db.onversionchange = () => db.close()
          try {
            const tx = db.transaction("snap")
            tx.oncomplete = tx.onerror = tx.onabort = () => db.close()
            const get = tx.objectStore("snap").get(scope)
            get.onsuccess = () => {
              const s = get.result as Snapshot | undefined
              // A snapshot of another schema is refused by the kernel; naming its rev in HELLO would resume rows the page cannot hold.
              resolve(s && s.wireHash === m.hash && s.schemaRev === BigInt(SCHEMA_REV) ? s : undefined)
            }
            get.onerror = () => resolve(undefined)
          } catch {
            db.close()
            resolve(undefined)
          }
        }
      })
    }),
  }
  hw.kernel.catch(() => {})
  let settle = () => {}
  hw.ready = new Promise((r) => (settle = r))

  // The snapshot, or nothing after a short wait.
  const named = Promise.race([hw.snap, new Promise<undefined>((r) => setTimeout(r, SNAP_WAIT_MS))]).catch(() => undefined)
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
      }).finally(settle)
      ws.onerror = settle
      ws.onclose = settle
      hw.ws = ws
    }
    if (m.gate !== "" && "WebTransport" in window) {
      // Once HELLO is written the page's ticket is spent: a failure after that goes to the
      // bundle, which fetches a fresh ticket, never to the socket with the spent one.
      let spent = false
      let wt: WebTransport | null = null
      void (async () => {
        wt = new WebTransport(m.gate, m.hashes.length > 0 ? { serverCertificateHashes: m.hashes } : {})
        wt.closed.catch(() => {})
        await Promise.race([wt.ready, new Promise((_, no) => setTimeout(() => no(new Error("slow")), WT_WAIT_MS))])
        const stream = await wt.createBidirectionalStream()
        const writer = stream.writable.getWriter()
        const f = await first()
        spent = true
        await writer.write(f)
        // The bundle drains the streams; until then, nothing reads them, and the transport buffers.
        hw.wt = wt
        hw.writer = writer
        hw.control = stream.readable
        hw.helloSent = true
        settle()
      })().catch(() => {
        try {
          wt?.close()
        } catch {
          // Already closed.
        }
        if (spent) settle()
        else socket()
      })
    } else {
      socket()
    }
  } else {
    settle()
  }

  ;(window as { __hw?: Boot }).__hw = hw
}
