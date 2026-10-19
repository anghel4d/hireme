// Inlined in <head> before the bundle (its built text is hashed into the
// CSP). It starts the three slow things at once so none waits on the
// bundle or on another: the carrier's handshake, the kernel's compile, and
// the read of the last snapshot from IndexedDB. HELLO goes when the
// carrier is up and the snapshot has answered, or after SNAP_WAIT_MS
// without it: naming the snapshot's rev turns a full BOOT into a few
// PATCHes, which is worth a short wait but not a long one. Without a stored
// snapshot the page's own BOOT, which ends its body, plays that part, so the
// first cards wait on no round trip. The bundle
// adopts all of it from `window.__hw`; frames that land first wait in a
// queue. It imports only frame builders, which the bundler tree-shakes down.

import { SCHEMA_REV } from "./gen/schema.ts"
import { CRED, header, hello, meta, transport, webSocket, type Bytes, type Early } from "./wire.ts"

/** What the bundle finds on `window.__hw`. */
export interface Boot extends Early {
  kernel: Promise<WebAssembly.Module>
  snap: Promise<Snapshot | undefined>
  /** The page's own BOOT, once the body holding it is parsed, when no snapshot is stored: the kernel ingests it first and HELLO resumes from its rev. */
  boot(): Bytes | undefined
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

/** A base64 attribute's bytes (a loop: `Uint8Array.from` with a mapper calls back per character). */
function bytes(b64: string): Bytes {
  const s = atob(b64)
  const u = new Uint8Array(s.length)
  for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i)
  return u
}

{
  const m = meta()
  const scope = document.querySelector<HTMLMetaElement>('meta[name="hireme-scope"]')?.content ?? ""
  // Only a scope whose snapshot was written (kernel.ts sets the flag then) reads IndexedDB; any
  // other takes the page's BOOT and sends HELLO the moment the socket opens, never waiting on storage.
  let stored = false
  try {
    stored = scope !== "" && localStorage.getItem(`hireme-snap:${scope}`) !== null
  } catch {
    // Blocked storage: no snapshot either.
  }
  let boot: Bytes | undefined
  const hw: Boot = {
    queue: [],
    helloSent: false,
    ready: Promise.resolve(),
    boot: () => {
      const b = boot || stored ? "" : (document.querySelector<HTMLMetaElement>('meta[name="hireme-boot"]')?.content ?? "")
      if (b !== "") boot = bytes(b)
      return boot
    },
    kernel: WebAssembly.compileStreaming(fetch(document.querySelector<HTMLLinkElement>('link[rel="preload"][as="fetch"]')?.href ?? "/wasm/kernel.wasm")),
    snap: new Promise((resolve) => {
      if (!stored || !("indexedDB" in window)) return resolve(undefined)
      setTimeout(() => resolve(undefined), 2000)
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
    }),
  }
  hw.kernel.catch(() => {})
  let settle = () => {}
  hw.ready = new Promise((r) => (settle = r))

  // The snapshot, or nothing after a short wait.
  const named = Promise.race([hw.snap, new Promise<undefined>((r) => setTimeout(r, SNAP_WAIT_MS))]).catch(() => undefined)
  const first = async (): Promise<Uint8Array<ArrayBuffer>> => {
    const s = await named
    const b = hw.boot()
    const ticket = m.ticket
    return hello(m.hash, {
      cred: CRED.ticket,
      credential: ticket,
      snapshotRev: s?.rev ?? (b ? header(b).rev : 0n),
      schemaRev: s?.schemaRev ?? (b ? BigInt(SCHEMA_REV) : 0n),
      label: navigator.userAgent.slice(0, 120),
    })
  }

  if (m.ticket !== "" && Number.isFinite(m.hash)) {
    const socket = () => {
      const ws = webSocket()
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
        const t = await transport(m.gate, m.hashes)
        wt = t.wt
        const writer = t.stream.writable.getWriter()
        const f = await first()
        spent = true
        await writer.write(f)
        // The bundle drains the streams; until then, nothing reads them, and the transport buffers.
        hw.wt = t.wt
        hw.writer = writer
        hw.control = t.stream.readable
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
