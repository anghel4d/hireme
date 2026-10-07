// Desk signals from the server, one JSON frame each. Reconnects with
// backoff; nothing is sent upstream.

export interface Signal {
  type: "application_opened" | "stage" | "cv" | "open_fire"
  job_id?: number
  lineage_id?: number
  stage?: string
  batch?: string
}

export function openFeed(onSignal: (s: Signal) => void): void {
  let delay = 500
  const connect = () => {
    const proto = location.protocol === "https:" ? "wss" : "ws"
    const ws = new WebSocket(`${proto}://${location.host}/feed/websocket`)
    ws.onmessage = (e) => {
      try {
        onSignal(JSON.parse(String(e.data)) as Signal)
      } catch {
        // a frame that is not a signal is dropped
      }
    }
    ws.onopen = () => { delay = 500 }
    ws.onclose = () => {
      setTimeout(connect, delay)
      delay = Math.min(delay * 2, 10_000)
    }
  }
  connect()
}
