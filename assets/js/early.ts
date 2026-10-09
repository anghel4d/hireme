// Inlined in <head>, after the wire meta tags, before the bundle. It
// starts what the desk needs first, so it overlaps the bundle download:
// the connection's handshake, the read of the last snapshot from
// IndexedDB, and HELLO, which names that snapshot's rev. The gate wants
// HELLO within 2 s of CONNECT, and a bundle on a slow link may not be
// running by then. The bundle adopts all of it from `window.__hw`;
// frames that arrive before it does wait in the stream, or, on the
// socket, in a queue. This file imports nothing: its built text is
// hashed into the CSP.

{
  const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ""
  const gate = meta("wire-gate")
  const ticket = meta("wire-ticket")
  const scope = meta("wire-scope")
  const schema = Number.parseInt(meta("wire-schema"), 10)
  // A dev gate's self-signed certificate is pinned by its hash.
  const hashes = meta("wire-gate-hashes").split(" ").filter((h) => h !== "")
    .map((h) => ({ algorithm: "sha-256", value: new Uint8Array((h.match(/../g) ?? []).map((b) => Number.parseInt(b, 16))) }))
  const hw: {
    wt?: WebTransport
    ws?: WebSocket
    snap?: Promise<unknown>
    clientId: number
    hello?: Promise<{ rev: bigint; writer?: WritableStreamDefaultWriter<Uint8Array>; readable?: ReadableStream<Uint8Array> } | null>
    queue: ArrayBuffer[]
  } = { clientId: crypto.getRandomValues(new Uint32Array(1))[0] ?? 1, queue: [] }

  // The snapshot record for this account, or undefined.
  const snap: Promise<{ rev?: bigint; hash?: number } | undefined> = new Promise((resolve) => {
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
  })
  hw.snap = snap

  // HELLO: u16 cred_len (0) | pad to 8 | u64 snapshot_rev | u32 client_id | u32 0, in a 16-byte header.
  // A snapshot written under another schema is no snapshot.
  const hello = async () => {
    const rec = await snap
    const rev = rec && rec.hash === schema && typeof rec.rev === "bigint" ? rec.rev : 0n
    const f = new Uint8Array(40)
    const v = new DataView(f.buffer)
    v.setUint32(0, 40, true)
    v.setUint8(4, 1)
    v.setUint16(6, schema, true)
    v.setBigUint64(24, rev, true)
    v.setUint32(32, hw.clientId, true)
    return { rev, f }
  }

  if (gate !== "" && ticket !== "" && "WebTransport" in window) {
    try {
      const wt = new WebTransport(`${gate}${gate.includes("?") ? "&" : "?"}t=${encodeURIComponent(ticket)}`, hashes.length > 0 ? { serverCertificateHashes: hashes } : {})
      wt.closed.catch(() => {})
      hw.wt = wt
      if (Number.isFinite(schema)) {
        hw.hello = (async () => {
          await wt.ready
          const stream = await wt.createBidirectionalStream()
          const writer = stream.writable.getWriter()
          const { rev, f } = await hello()
          await writer.write(f)
          return { rev, writer, readable: stream.readable }
        })().catch(() => null)
      }
    } catch {
      delete hw.wt
    }
  }
  if (!hw.wt) {
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/wire/websocket?_csrf_token=${encodeURIComponent(meta("csrf-token"))}`)
    ws.binaryType = "arraybuffer"
    ws.onmessage = (e) => { hw.queue.push(e.data as ArrayBuffer) }
    hw.ws = ws
    if (Number.isFinite(schema)) {
      hw.hello = new Promise((resolve) => {
        ws.onopen = () => void hello().then(({ rev, f }) => { ws.send(f); resolve({ rev }) }, () => resolve(null))
        ws.onerror = () => resolve(null)
      })
    }
  }

  ;(window as { __hw?: unknown }).__hw = hw
}
