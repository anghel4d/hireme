// The wire: frames to and from the Session, over WebTransport when the
// network lets UDP through and over a WebSocket when it does not. Both
// carriers feed the same framer and the same sink.
//
// A frame is a 16-byte header, then the body, 8-byte aligned:
//
//     u32 len (whole frame) | u8 kind | u8 flags | u16 schema_hash | u64 rev
//
// On WebTransport everything rides bidi stream 0, in order: HELLO, OPs and
// RPC requests up; BOOT, PATCH, ACK, NACK, RPC replies and TICK down, so a
// PATCH always lands before the ACK it settles. PING goes up as a datagram,
// where a loss costs nothing. Stream bytes are read BYOB into one staging
// buffer, and a complete frame is handed to the sink as a view of it: the
// sink's copy into the kernel is the only copy. A deflated frame (the BOOT)
// is inflated first.

export const KIND = {
  HELLO: 1, BOOT: 3, PATCH: 4, OP: 8, ACK: 9, NACK: 10,
  TICK: 11, PING: 13, PONG: 14, TICKET: 15, BYE: 16, RPC: 33,
} as const

export const FLAG = { DEFLATE: 0x01, END: 0x02 } as const
export const HEADER = 16

/** Bytes over a plain ArrayBuffer: what a carrier can send and a BYOB read can fill. */
export type Bytes = Uint8Array<ArrayBuffer>

export type Carrier = "webtransport" | "websocket"

/** Where whole frames go. The view is only valid during the call. */
export interface Sink {
  frame(frame: Bytes, kind: number, flags: number, rev: bigint): void
}

export function header(frame: Bytes): { len: number; kind: number; flags: number; hash: number; rev: bigint } {
  const v = new DataView(frame.buffer, frame.byteOffset, HEADER)
  return { len: v.getUint32(0, true), kind: v.getUint8(4), flags: v.getUint8(5), hash: v.getUint16(6, true), rev: v.getBigUint64(8, true) }
}

const pad8 = (n: number) => (n + 7) & ~7

/** A frame of `kind` around a body the writer fills; the length is padded to 8. */
export function frame(kind: number, hash: number, bodyLen: number, fill: (v: DataView, at: number) => void, rev = 0n): Bytes {
  const len = HEADER + pad8(bodyLen)
  const out = new Uint8Array(len)
  const v = new DataView(out.buffer)
  v.setUint32(0, len, true)
  v.setUint8(4, kind)
  v.setUint16(6, hash, true)
  v.setBigUint64(8, rev, true)
  fill(v, HEADER)
  return out
}

const ENCODER = new TextEncoder()
const DECODER = new TextDecoder()

/** HELLO's option word: bit 0 asks for raw tables, from which the client derives every view. */
export const RAW = 0x01

/** HELLO: u16 cred_len | cred | pad8 | u64 snapshot_rev | u32 client_id | u32 options. */
export function hello(hash: number, snapshotRev: bigint, clientId: number, options = RAW, cred = ""): Bytes {
  const c = ENCODER.encode(cred)
  const at = pad8(2 + c.byteLength)
  return frame(KIND.HELLO, hash, at + 16, (v, o) => {
    v.setUint16(o, c.byteLength, true)
    new Uint8Array(v.buffer, o + 2, c.byteLength).set(c)
    v.setBigUint64(o + at, snapshotRev, true)
    v.setUint32(o + at + 8, clientId, true)
    v.setUint32(o + at + 12, options, true)
  })
}

/** RPC: u32 json_len | u32 0 | JSON, a request `{id, method, params}` or its reply. */
export function rpc(hash: number, message: unknown): Bytes {
  const json = ENCODER.encode(JSON.stringify(message))
  return frame(KIND.RPC, hash, 8 + json.byteLength, (v, o) => {
    v.setUint32(o, json.byteLength, true)
    new Uint8Array(v.buffer, o + 8, json.byteLength).set(json)
  })
}

/** A command's answer: its result, or the status and message an HTTP route would have sent. */
export type Reply = { result: Record<string, unknown> } | { error: { code: number; message: string } }

/** PING: u64 t (ms since page start, as micros). */
export function ping(hash: number, t: bigint): Bytes {
  return frame(KIND.PING, hash, 8, (v, o) => v.setBigUint64(o, t, true))
}

/** OP body: u64 op_id | u8 kind | u8 nfields | u16 0 | u32 target | (u16 len, utf8) × nfields; the frame pads it with zeros. */
export function opFrame(hash: number, opId: bigint, kind: number, target: number, fields: readonly string[]): Bytes {
  const bytes = fields.map((f) => ENCODER.encode(f))
  const len = 16 + bytes.reduce((n, b) => n + 2 + b.byteLength, 0)
  return frame(KIND.OP, hash, len, (v, o) => {
    v.setBigUint64(o, opId, true)
    v.setUint8(o + 8, kind)
    v.setUint8(o + 9, bytes.length)
    v.setUint32(o + 12, target, true)
    let at = o + 16
    for (const b of bytes) {
      v.setUint16(at, b.byteLength, true)
      new Uint8Array(v.buffer, at + 2, b.byteLength).set(b)
      at += 2 + b.byteLength
    }
  })
}

/** A u16-prefixed string at `at` in a frame's body, and where the next field starts. */
export function text(frame: Bytes, at: number): [string, number] {
  const v = new DataView(frame.buffer, frame.byteOffset)
  const n = v.getUint16(at, true)
  return [DECODER.decode(frame.subarray(at + 2, at + 2 + n)), at + 2 + n]
}

/** A raw-deflate body (u32 raw_len | u32 deflate_len | bytes) as a plain frame, flags cleared. */
async function inflate(f: Bytes): Promise<Bytes> {
  const v = new DataView(f.buffer, f.byteOffset, f.byteLength)
  const raw = v.getUint32(HEADER, true)
  const packed = v.getUint32(HEADER + 4, true)
  const out = new Uint8Array(HEADER + pad8(raw))
  out.set(f.subarray(0, HEADER))
  const o = new DataView(out.buffer)
  o.setUint32(0, out.byteLength, true)
  o.setUint8(5, v.getUint8(5) & ~FLAG.DEFLATE)
  const stream = new Blob([f.slice(HEADER + 8, HEADER + 8 + packed)]).stream().pipeThrough(new DecompressionStream("deflate-raw"))
  const reader = stream.getReader()
  let at = HEADER
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    out.set(value, at)
    at += value.byteLength
  }
  return out
}

/**
 * Cuts a byte stream into frames. Bytes land in one staging buffer that
 * grows to the largest frame seen; a complete frame is passed as a view
 * of it. Deflated frames inflate off the hot path, and later frames wait
 * behind them so order holds.
 */
export class Framer {
  private buf = new ArrayBuffer(64 * 1024)
  private filled = 0
  private chain: Promise<void> | null = null
  private readonly held: Bytes[] = []

  constructor(private readonly sink: Sink, private readonly broken: (why: string) => void) {}

  /** Free space for a BYOB read. */
  space(min = 16 * 1024): Bytes {
    if (this.buf.byteLength - this.filled < min) this.grow(this.filled + min)
    return new Uint8Array(this.buf, this.filled)
  }

  /** A BYOB read returned `view` (whose buffer is the transferred staging buffer). */
  wrote(view: Bytes): void {
    this.buf = view.buffer as ArrayBuffer
    this.filled += view.byteLength
    this.cut()
  }

  /** Bytes from a carrier that hands whole messages (the WebSocket). */
  push(bytes: Bytes): void {
    if (this.filled === 0 && bytes.byteOffset % 8 === 0) {
      // The common case: whole frames, parsed in place, no staging copy.
      let at = 0
      while (bytes.byteLength - at >= HEADER) {
        const len = new DataView(bytes.buffer, bytes.byteOffset + at, 4).getUint32(0, true)
        if (len < HEADER || len > bytes.byteLength - at) break
        this.deliver(bytes.subarray(at, at + len))
        at += len
      }
      bytes = bytes.subarray(at)
      if (bytes.byteLength === 0) return
    }
    this.space(bytes.byteLength).set(bytes)
    this.filled += bytes.byteLength
    this.cut()
  }

  private grow(size: number): void {
    const next = new ArrayBuffer(Math.max(size, this.buf.byteLength * 2))
    new Uint8Array(next).set(new Uint8Array(this.buf, 0, this.filled))
    this.buf = next
  }

  private cut(): void {
    let at = 0
    while (this.filled - at >= HEADER) {
      const len = new DataView(this.buf, at, 4).getUint32(0, true)
      if (len < HEADER || len % 8 !== 0) {
        this.broken(`bad frame length ${len}`)
        this.filled = 0
        return
      }
      if (this.filled - at < len) {
        if (at === 0 && len > this.buf.byteLength) this.grow(len)
        break
      }
      this.deliver(new Uint8Array(this.buf, at, len))
      at += len
    }
    if (at > 0) {
      new Uint8Array(this.buf).copyWithin(0, at, this.filled)
      this.filled -= at
    }
  }

  private deliver(f: Bytes): void {
    const flags = f[5] ?? 0
    if (this.chain === null && (flags & FLAG.DEFLATE) === 0) {
      this.emit(f)
      return
    }
    const own = f.slice()
    this.held.push(own)
    if (this.chain !== null) return
    this.chain = (async () => {
      while (this.held.length > 0) {
        const next = this.held.shift() as Bytes
        try {
          this.emit((next[5] ?? 0) & FLAG.DEFLATE ? await inflate(next) : next)
        } catch (cause) {
          this.broken(`inflate: ${String(cause)}`)
        }
      }
      this.chain = null
    })()
  }

  private emit(f: Bytes): void {
    const h = header(f)
    this.sink.frame(f, h.kind, h.flags, h.rev)
  }
}

/** Read a stream to its end, BYOB when the browser offers it, into a framer. */
export async function pump(stream: ReadableStream<Bytes>, framer: Framer): Promise<void> {
  let byob: ReadableStreamBYOBReader | null = null
  try {
    byob = stream.getReader({ mode: "byob" })
  } catch {
    byob = null
  }
  if (byob) {
    for (;;) {
      const { done, value } = await byob.read(framer.space())
      if (value) framer.wrote(value)
      if (done) return
    }
  }
  const reader = stream.getReader()
  for (;;) {
    const { done, value } = await reader.read()
    if (done) return
    framer.push(value)
  }
}

// ---- carriers ----

/** One connection, whichever carrier. A datagram rides the socket itself on a WebSocket. */
export interface Conn {
  readonly carrier: Carrier
  control(f: Bytes): void
  datagram(f: Bytes): void
  close(): void
  readonly closed: Promise<string>
}

/** What the page's early script started before the bundle arrived. */
export interface Early {
  wt?: WebTransport
  ws?: WebSocket
  snap?: Promise<unknown>
  /** The client id the early HELLO carried; the desk's ops use it too. */
  clientId?: number
  /** The early HELLO, once written: the rev it named, and on WebTransport the control stream it opened. */
  hello?: Promise<{ rev: bigint; writer?: WritableStreamDefaultWriter<Uint8Array>; readable?: ReadableStream<Bytes> } | null>
  /** Socket messages that arrived before the bundle took over. */
  queue?: ArrayBuffer[]
}

/** A control stream the early script opened and already wrote HELLO on. */
export interface Adopted { writer: WritableStreamDefaultWriter<Uint8Array>; readable: ReadableStream<Bytes> }

declare global {
  interface Window { __hw?: Early }
}

/** A WebTransport session as a Conn: HELLO goes first on a new control stream, unless one was adopted. */
export async function openTransport(wt: WebTransport, sink: Sink, first: Bytes | Adopted): Promise<Conn> {
  await wt.ready
  let failed = (_: string) => {}
  const closed = new Promise<string>((resolve) => {
    failed = resolve
    wt.closed.then(() => resolve("closed"), (e: unknown) => resolve(String(e)))
  })
  let writer: WritableStreamDefaultWriter<Uint8Array>
  let readable: ReadableStream<Bytes>
  if (first instanceof Uint8Array) {
    const control = await wt.createBidirectionalStream()
    writer = control.writable.getWriter()
    readable = control.readable
    void writer.write(first)
  } else {
    ;({ writer, readable } = first)
  }
  void pump(readable, new Framer(sink, failed)).then(() => failed("control ended"), (e: unknown) => failed(String(e)))
  const dwriter = wt.datagrams.writable.getWriter()

  return {
    carrier: "webtransport",
    control: (f) => void writer.write(f).catch(() => {}),
    datagram: (f) => {
      const max = wt.datagrams.maxDatagramSize
      if (f.byteLength <= max) void dwriter.write(f).catch(() => {})
      else void writer.write(f).catch(() => {})
    },
    close: () => wt.close(),
    closed,
  }
}

/** A WebSocket as a Conn: HELLO goes first, unless the early script sent it (`null`), and queued messages are taken in order. */
export function openSocket(ws: WebSocket, sink: Sink, first: Bytes | null, queued: readonly ArrayBuffer[] = []): Promise<Conn> {
  ws.binaryType = "arraybuffer"
  let failed = (_: string) => {}
  const closed = new Promise<string>((resolve) => { failed = resolve })
  const framer = new Framer(sink, (why) => {
    failed(why)
    ws.close()
  })
  for (const m of queued) framer.push(new Uint8Array(m))
  ws.onmessage = (e) => {
    if (e.data instanceof ArrayBuffer) framer.push(new Uint8Array(e.data))
  }
  ws.onclose = (e) => failed(`ws ${e.code}`)
  const conn: Conn = {
    carrier: "websocket",
    control: (f) => { if (ws.readyState === WebSocket.OPEN) ws.send(f) },
    datagram: (f) => { if (ws.readyState === WebSocket.OPEN) ws.send(f) },
    close: () => ws.close(),
    closed,
  }
  return new Promise((resolve, reject) => {
    const go = () => {
      if (first) ws.send(first)
      resolve(conn)
    }
    if (ws.readyState === WebSocket.OPEN) go()
    else if (ws.readyState > WebSocket.OPEN) reject(new Error("socket closed"))
    else {
      ws.onopen = go
      ws.onerror = () => reject(new Error("socket failed"))
    }
  })
}

export function socketUrl(csrf: string): string {
  const proto = location.protocol === "https:" ? "wss" : "ws"
  return `${proto}://${location.host}/wire/websocket?_csrf_token=${encodeURIComponent(csrf)}`
}

export function gateUrl(gate: string, ticket: string): string {
  return `${gate}${gate.includes("?") ? "&" : "?"}t=${encodeURIComponent(ticket)}`
}

// ---- the session ----

/** What the wire serves: the desk's side of the connection. */
export interface Host extends Sink {
  readonly hash: number
  readonly clientId: number
  /** The rev of the resident base, 0n when there is none. */
  rev(): bigint
  /** Op frames sent but not acknowledged, oldest first, to resend after a reconnect. */
  unacked(): readonly Bytes[]
  connection(s: "connecting" | Carrier | "offline"): void
  /** The server ended this session for good: sign-out, revocation. */
  bye(): void
}

const CONNECT_MS = 3000
const PING_MS = 5000

/**
 * Keeps one connection up. WebTransport first when the page names a gate,
 * the WebSocket when the gate does not answer in time or the browser has
 * no WebTransport; once the gate fails, this page stays on the socket and
 * tries the gate again only after a minute. Every connection opens with
 * HELLO, then resends what was never acknowledged: the ledger on the
 * server answers a duplicate with its first outcome, so a resend is safe.
 */
export class Wire {
  private conn: Conn | null = null
  private ticket: string
  private gate: string
  private gateDownUntil = 0
  private backoff = 250
  private early: Early | undefined
  private readonly start = performance.now()
  /** Round-trip time of the last PING, in ms; -1 before the first. */
  rtt = -1
  /** Server clock minus ours at the last PONG, in ms. */
  skew = 0
  readonly stats = { connects: 0, resent: 0, frames: 0, bytes: 0 }
  private calls = new Map<number, (r: Reply) => void>()
  private callId = 0

  private readonly options: WebTransportOptions

  constructor(private readonly host: Host, private readonly csrf: string, meta: { gate: string; ticket: string; hashes: string }, early?: Early) {
    this.gate = meta.gate
    this.ticket = meta.ticket
    const hashes = meta.hashes.split(" ").filter((h) => h !== "")
      .map((h) => ({ algorithm: "sha-256", value: new Uint8Array((h.match(/../g) ?? []).map((b) => Number.parseInt(b, 16))) }))
    this.options = hashes.length > 0 ? { serverCertificateHashes: hashes } : {}
    this.early = early
  }

  get carrier(): Carrier | null {
    return this.conn?.carrier ?? null
  }

  run(): void {
    void this.loop()
    setInterval(() => this.ping(), PING_MS)
  }

  /** Drop the connection and open another: its HELLO names the rev the desk holds now. */
  reconnect(): void {
    this.conn?.close()
  }

  control(f: Bytes): boolean {
    if (!this.conn) return false
    this.conn.control(f)
    return true
  }

  /**
   * One command on the control stream, answered on it. A write's tables
   * arrive before its reply. Without a connection, or if it drops first,
   * the answer is status 0: nothing is resent, since a command may not be
   * safe twice.
   */
  call(method: string, params: Record<string, unknown> = {}): Promise<Reply> {
    if (!this.conn) return Promise.resolve({ error: { code: 0, message: "offline" } })
    const id = ++this.callId
    return new Promise((resolve) => {
      this.calls.set(id, resolve)
      this.conn?.control(rpc(this.host.hash, { id, method, params }))
    })
  }

  private dropCalls(): void {
    const calls = this.calls
    this.calls = new Map()
    for (const resolve of calls.values()) resolve({ error: { code: 0, message: "offline" } })
  }

  private ping(): void {
    if (!this.conn) return
    const t = BigInt(Math.round((performance.now() - this.start) * 1000))
    this.conn.datagram(ping(this.host.hash, t))
  }

  private readonly sink: Sink = {
    frame: (f, kind, flags, rev) => {
      this.stats.frames++
      this.stats.bytes += f.byteLength
      const v = new DataView(f.buffer, f.byteOffset, f.byteLength)
      switch (kind) {
        case KIND.PONG: {
          const sent = Number(v.getBigUint64(HEADER, true)) / 1000
          const now = performance.now() - this.start
          this.rtt = now - sent
          this.skew = Number(v.getBigUint64(HEADER + 8, true)) - (performance.timeOrigin + now - this.rtt / 2)
          return
        }
        case KIND.RPC: {
          const len = v.getUint32(HEADER, true)
          try {
            const m = JSON.parse(DECODER.decode(f.subarray(HEADER + 8, HEADER + 8 + len))) as { id?: number } & Reply
            const resolve = m.id === undefined ? undefined : this.calls.get(m.id)
            if (resolve && m.id !== undefined) {
              this.calls.delete(m.id)
              resolve("error" in m && m.error ? { error: m.error } : { result: ("result" in m && m.result) || {} })
            }
          } catch {
            // not a reply this page is waiting on
          }
          return
        }
        case KIND.TICKET:
          this.ticket = text(f, HEADER)[0]
          return
        case KIND.BYE: {
          // The session is over. Signed out or a dead key: sign in again.
          // Another schema: this bundle is stale, so load the page once
          // more. Anything else is a protocol fault: reconnect with backoff.
          const why = text(f, HEADER)[0]
          this.conn?.close()
          if (why === "signed_out" || why === "key") {
            this.host.bye()
            location.assign("/sign-in")
          } else if (why === "schema" && !reloadedLately()) {
            location.reload()
          }
          return
        }
        default:
          this.host.frame(f, kind, flags, rev)
      }
    },
  }

  private async loop(): Promise<void> {
    for (;;) {
      this.host.connection("connecting")
      const conn = await this.connect().catch(() => null)
      if (!conn) {
        this.host.connection("offline")
        await sleep(this.backoff)
        this.backoff = Math.min(this.backoff * 2, 10_000)
        continue
      }
      this.conn = conn
      this.stats.connects++
      this.host.connection(conn.carrier)
      for (const f of this.host.unacked()) {
        conn.control(f)
        this.stats.resent++
      }
      this.ping()
      await conn.closed
      this.dropCalls()
      this.conn = null
      this.host.connection("offline")
      await sleep(this.backoff)
      this.backoff = Math.min(this.backoff * 2, 10_000)
    }
  }

  private async connect(): Promise<Conn> {
    const first = hello(this.host.hash, this.host.rev(), this.host.clientId)
    const early = this.early
    this.early = undefined
    // The early script's HELLO stands only if it named the rev the desk restored.
    const said = early?.hello ? await within(early.hello, CONNECT_MS).catch(() => null) : undefined
    const adopt = said !== undefined && said !== null && said.rev === this.host.rev()
    if (early?.wt) {
      const own = adopt && said.writer && said.readable ? { writer: said.writer, readable: said.readable } : null
      const c = said === null || (said && !own) ? null : await within(openTransport(early.wt, this.sink, own ?? first), CONNECT_MS).catch(() => null)
      if (c) return this.settled(c)
      early.wt.close()
      if (said === null) this.gateDownUntil = performance.now() + 60_000
    }
    if (early?.ws) {
      const c = said === null || (said && !adopt) ? null : await within(openSocket(early.ws, this.sink, said ? null : first, early.queue), CONNECT_MS).catch(() => null)
      if (c) return this.settled(c)
      early.ws.close()
    }
    if (this.gate !== "" && "WebTransport" in window && performance.now() >= this.gateDownUntil) {
      if (this.ticket === "") await this.freshTicket()
      if (this.ticket !== "" && this.gate !== "") {
        const ticket = this.ticket
        this.ticket = ""
        try {
          const wt = new WebTransport(gateUrl(this.gate, ticket), this.options)
          wt.closed.catch(() => {})
          const c = await within(openTransport(wt, this.sink, first), CONNECT_MS).catch((e: unknown) => {
            wt.close()
            throw e
          })
          return this.settled(c)
        } catch {
          this.gateDownUntil = performance.now() + 60_000
        }
      }
    }
    const ws = new WebSocket(socketUrl(this.csrf))
    return this.settled(await within(openSocket(ws, this.sink, first), CONNECT_MS).catch((e: unknown) => {
      ws.close()
      throw e
    }))
  }

  // A connection that lives a while resets the backoff.
  private settled(c: Conn): Conn {
    setTimeout(() => { if (this.conn === c) this.backoff = 250 }, 5000)
    return c
  }

  private async freshTicket(): Promise<void> {
    try {
      const res = await fetch("/api/wire/ticket", { method: "POST", headers: { "x-csrf-token": this.csrf, accept: "application/json" } })
      if (res.status === 401) location.assign("/sign-in")
      if (!res.ok) return
      const body = (await res.json()) as { ticket?: string; gate?: string | null }
      this.ticket = body.ticket ?? ""
      this.gate = body.gate ?? ""
    } catch {
      // offline: the socket attempt below decides
    }
  }
}

/** At most one reload a minute for a schema change, so a mismatch cannot loop. */
function reloadedLately(): boolean {
  try {
    const last = Number(sessionStorage.getItem("hireme:schema-reload") ?? 0)
    if (Date.now() - last < 60_000) return true
    sessionStorage.setItem("hireme:schema-reload", String(Date.now()))
  } catch {
    // storage blocked: reload anyway, the server's answer will not change within the minute
  }
  return false
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}

function within<T>(p: Promise<T>, ms: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("timeout")), ms)
    p.then((v) => { clearTimeout(t); resolve(v) }, (e: unknown) => { clearTimeout(t); reject(e) })
  })
}

/** The wire's none: an absent u32, day or time. */
export const NONE = 0xffffffff
