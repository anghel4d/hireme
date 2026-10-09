// Inlined in <head>, after the wire meta tags, before the bundle. It
// starts everything the desk needs at once, so none of it waits on the
// bundle or on another: the connection, the kernel's compile, and the read
// of the last snapshot from IndexedDB. The connection asks for the whole
// desk, so it waits on nothing: the server pushes the BOOT the moment it
// accepts (on WebTransport, on a stream of its own that this script drains
// at once; on the socket, at the upgrade), and HELLO only opens control.
// The snapshot paints the board if it comes back first, and the BOOT
// replaces it. The bundle adopts all of it from `window.__hw`: what arrived
// before it did waits in a queue. This file imports nothing: its built
// text is hashed into the CSP.

{
  const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ""
  const gate = meta("wire-gate")
  const ticket = meta("wire-ticket")
  const scope = meta("wire-scope")
  const schema = Number.parseInt(meta("wire-schema"), 10)
  // A dev gate's self-signed certificate is pinned by its hash.
  const hashes = meta("wire-gate-hashes").split(" ").filter((h) => h !== "")
    .map((h) => ({ algorithm: "sha-256", value: new Uint8Array((h.match(/../g) ?? []).map((b) => Number.parseInt(b, 16))) }))
  type Uni = { chunks: Uint8Array[]; done: boolean; wake: (() => void) | null }
  const hw: {
    ws?: WebSocket
    snap?: Promise<unknown>
    kernel?: Promise<WebAssembly.Module>
    clientId: number
    hello?: Promise<{ wt?: WebTransport; uni?: Uni; writer?: WritableStreamDefaultWriter<Uint8Array>; readable?: ReadableStream<Uint8Array> } | null>
    queue: ArrayBuffer[]
  } = { clientId: crypto.getRandomValues(new Uint32Array(1))[0] ?? 1, queue: [] }
  // The whole desk (rev 0), as raw tables, for this client id.
  const ask = `rev=0&raw=1&cid=${hw.clientId}`

  // HELLO: u16 cred_len (0) | pad to 8 | u64 snapshot_rev | u32 client_id | u32 options (1: raw tables), in a 16-byte header.
  const hello = () => {
    const f = new Uint8Array(40)
    const v = new DataView(f.buffer)
    v.setUint32(0, 40, true)
    v.setUint8(4, 1)
    v.setUint16(6, schema, true)
    v.setUint32(32, hw.clientId, true)
    v.setUint32(36, 1, true)
    return f
  }

  if (gate !== "" && ticket !== "" && "WebTransport" in window && Number.isFinite(schema)) {
    hw.hello = (async () => {
      const wt = new WebTransport(`${gate}${gate.includes("?") ? "&" : "?"}t=${encodeURIComponent(ticket)}&${ask}`,
        hashes.length > 0 ? { serverCertificateHashes: hashes } : {})
      wt.closed.catch(() => {})
      // The BOOT stream: every chunk queued for the bundle as it comes.
      const uni: Uni = { chunks: [], done: false, wake: null }
      const end = () => { uni.done = true; uni.wake?.() }
      void (async () => {
        const { value: stream } = await wt.incomingUnidirectionalStreams.getReader().read()
        if (!stream) return end()
        const reader = stream.getReader()
        for (;;) {
          const { done, value } = await reader.read()
          if (done) return end()
          uni.chunks.push(value)
          uni.wake?.()
        }
      })().catch(end)
      await wt.ready
      const stream = await wt.createBidirectionalStream()
      const writer = stream.writable.getWriter()
      await writer.write(hello())
      return { wt, uni, writer, readable: stream.readable }
    })().catch(() => null)
  } else {
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/wire/websocket?_csrf_token=${encodeURIComponent(meta("csrf-token"))}&${ask}`)
    ws.binaryType = "arraybuffer"
    ws.onmessage = (e) => { hw.queue.push(e.data as ArrayBuffer) }
    hw.ws = ws
    if (Number.isFinite(schema)) {
      hw.hello = new Promise((resolve) => {
        ws.onopen = () => {
          ws.send(hello())
          resolve({})
        }
        ws.onerror = () => resolve(null)
      })
    }
  }

  // The connection first, then the kernel's compile, then the snapshot.
  hw.kernel = WebAssembly.compileStreaming(fetch("/wasm/kernel.wasm"))
  hw.kernel.catch(() => {})

  // The snapshot record for this account, or undefined: read a task later,
  // since opening IndexedDB in a fresh profile holds the main thread.
  const snap: Promise<{ format?: number; rev?: bigint; hash?: number } | undefined> = new Promise((resolve) => setTimeout(() => {
    if (scope === "" || !("indexedDB" in window)) return resolve(undefined)
    const open = indexedDB.open("hireme", 1)
    open.onupgradeneeded = () => open.result.createObjectStore("snap")
    open.onerror = () => resolve(undefined)
    open.onsuccess = () => {
      try {
        const get = open.result.transaction("snap").objectStore("snap").get(scope)
        get.onsuccess = () => resolve(get.result)
        get.onerror = () => resolve(undefined)
      } catch {
        resolve(undefined)
      }
    }
  }))
  hw.snap = snap

  ;(window as { __hw?: unknown }).__hw = hw
}
