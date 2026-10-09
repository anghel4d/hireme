// Inlined in <head>, after the wire meta tags, before the bundle. It
// starts the two slow things the desk needs first, so they overlap the
// bundle download: the connection's handshake, and the read of the last
// snapshot from IndexedDB. The bundle adopts both from `window.__hw`.
//
// Nothing is sent here. The server speaks only after HELLO, which the
// bundle writes once it knows the snapshot's rev. This file imports
// nothing: its built text is hashed into the CSP.

{
  const meta = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ""
  const gate = meta("wire-gate")
  const ticket = meta("wire-ticket")
  const scope = meta("wire-scope")
  const hw: { wt?: WebTransport; ws?: WebSocket; snap?: Promise<unknown> } = {}

  if (gate !== "" && ticket !== "" && "WebTransport" in window) {
    try {
      hw.wt = new WebTransport(`${gate}${gate.includes("?") ? "&" : "?"}t=${encodeURIComponent(ticket)}`)
      hw.wt.ready.catch(() => {})
      hw.wt.closed.catch(() => {})
    } catch {
      delete hw.wt
    }
  }
  if (!hw.wt) {
    const csrf = meta("csrf-token")
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/wire/websocket?_csrf_token=${encodeURIComponent(csrf)}`)
    ws.binaryType = "arraybuffer"
    hw.ws = ws
  }

  // The snapshot record for this account: { rev, bytes } or undefined.
  if (scope !== "" && "indexedDB" in window) {
    hw.snap = new Promise((resolve) => {
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
  }

  ;(window as { __hw?: unknown }).__hw = hw
}
