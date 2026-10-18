// The wire: frames to and from the session, over WebTransport when the
// network lets UDP through and over a WebSocket at /wire when it does not.
// Both carriers feed one framer and one sink. The layouts are
// native/wire's (its lib.rs doc is the authority); this is their mirror.
//
// Header, 16 bytes, little-endian, bodies padded to 8:
//
//     u32 len (whole frame) | u8 kind | u8 flags | u16 wire_hash | u64 rev
//
// A field is `u32 len | bytes | zero pad to 8`. On WebTransport the first
// bidi stream is control (HELLO, OPS, RPC, PING up; WELCOME, PATCH, ACK,
// NACK, REPLY, TICK, PONG, BYE down) and the server may push the BOOT on a
// uni stream. A PATCH must never be applied before the BOOT it follows, so
// control frames after WELCOME wait until a frame flagged END lands from
// any stream: on the socket, everything is one ordered stream and nothing
// waits longer than it would anyway.

import { FRAME, WIRE_TYPE } from "./gen/schema.ts"

/** Frame kinds and cell types are the schema's: one declaration names them for every language. */
export const KIND = FRAME

export const FLAG = { DEFLATE: 0x01, END: 0x02 } as const
export const HEADER = 16

export const VERB = { put: 1, drop: 2, command: 3 } as const
export const OP_FLAG = { KEYED: 0x01, CREATE_ONLY: 0x02, EXPECT_REV: 0x04 } as const
/**
 * Cell wire types, the schema's WIRE_TYPE plus null (0, length 0, clears).
 * id, ref, bool, u8, enum codes, days (since 1970-01-01) and times (unix
 * seconds) all ride as u32; str, text and json as utf8. Deferred (5) only
 * comes down, as `u32 len | 8 bytes of SHA-256`.
 */
export const CELL = WIRE_TYPE
export const CRED = { ticket: 1, key: 2 } as const
export const BYE_REASON = ["", "revoked", "grants", "restart", "schema", "suspended"] as const

/** Liveness, as SECURITY.md states it: a ping every 15 s, a session ends after 45 s of silence. */
export const PING_MS = 15_000
export const SILENT_MS = 45_000

/** One op carries up to 1 MiB of text; one OPS frame up to 256 ops. */
export const OP_TEXT_MAX = 1 << 20
export const OPS_MAX = 256

export type Bytes = Uint8Array<ArrayBuffer>

const pad8 = (n: number): number => (n + 7) & ~7
const ENC = new TextEncoder()
const DEC = new TextDecoder()

export interface Header {
  len: number
  kind: number
  flags: number
  hash: number
  rev: bigint
}

export function header(f: Bytes): Header {
  const v = new DataView(f.buffer, f.byteOffset, HEADER)
  return { len: v.getUint32(0, true), kind: v.getUint8(4), flags: v.getUint8(5), hash: v.getUint16(6, true), rev: v.getBigUint64(8, true) }
}

/** Builds one frame: fixed parts and fields, each field padded to 8 from the frame start. */
class Writer {
  private buf = new Uint8Array(256)
  private at = HEADER
  private view = new DataView(this.buf.buffer)

  private room(n: number): void {
    if (this.at + n <= this.buf.byteLength) return
    let size = this.buf.byteLength * 2
    while (size < this.at + n) size *= 2
    const next = new Uint8Array(size)
    next.set(this.buf)
    this.buf = next
    this.view = new DataView(next.buffer)
  }

  u8(x: number): this { this.room(1); this.view.setUint8(this.at, x); this.at += 1; return this }
  u16(x: number): this { this.room(2); this.view.setUint16(this.at, x, true); this.at += 2; return this }
  u32(x: number): this { this.room(4); this.view.setUint32(this.at, x, true); this.at += 4; return this }
  u64(x: bigint): this { this.room(8); this.view.setBigUint64(this.at, x, true); this.at += 8; return this }
  i64(x: bigint): this { this.room(8); this.view.setBigInt64(this.at, x, true); this.at += 8; return this }

  bytes(b: Uint8Array): this {
    this.room(b.byteLength)
    this.buf.set(b, this.at)
    this.at += b.byteLength
    return this
  }

  pad(): this {
    const to = pad8(this.at)
    this.room(to - this.at)
    this.buf.fill(0, this.at, to)
    this.at = to
    return this
  }

  field(b: Uint8Array | string): this {
    const bytes = typeof b === "string" ? ENC.encode(b) : b
    return this.u32(bytes.byteLength).bytes(bytes).pad()
  }

  done(kind: number, hash: number, rev = 0n, flags = 0): Bytes {
    this.pad()
    const out = this.buf.slice(0, this.at)
    const v = new DataView(out.buffer)
    v.setUint32(0, this.at, true)
    v.setUint8(4, kind)
    v.setUint8(5, flags)
    v.setUint16(6, hash, true)
    v.setBigUint64(8, rev, true)
    return out
  }
}

/** Reads fixed parts and fields of one frame's body. */
class Reader {
  private at = HEADER
  private readonly v: DataView
  constructor(private readonly f: Bytes) {
    this.v = new DataView(f.buffer, f.byteOffset, f.byteLength)
  }
  u8(): number { return this.v.getUint8(this.at++) }
  u16(): number { const x = this.v.getUint16(this.at, true); this.at += 2; return x }
  u32(): number { const x = this.v.getUint32(this.at, true); this.at += 4; return x }
  u64(): bigint { const x = this.v.getBigUint64(this.at, true); this.at += 8; return x }
  skip(n: number): this { this.at += n; return this }
  field(): Bytes {
    const n = this.u32()
    const out = this.f.subarray(this.at, this.at + n)
    this.at = pad8(this.at + n)
    return out
  }
  text(): string { return DEC.decode(this.field()) }
}

export interface Hello {
  cred: number
  credential: string
  snapshotRev: bigint
  schemaRev: bigint
  label: string
}

export function hello(hash: number, h: Hello): Bytes {
  return new Writer().u8(h.cred).u8(0).u16(0).u32(0).u64(h.snapshotRev).u64(h.schemaRev)
    .field(h.credential).field(h.label).done(KIND.HELLO, hash)
}

export interface Welcome {
  accountRev: bigint
  accountId: bigint
  sessionId: bigint
  schemaRev: bigint
  readMask: number
  writeMask: number
  mayDelete: boolean
  leased: boolean
  label: string
}

export function welcome(f: Bytes): Welcome {
  const r = new Reader(f)
  const accountId = r.u64()
  const sessionId = r.u64()
  const schemaRev = r.u64()
  const readMask = r.u16()
  const writeMask = r.u16()
  const mayDelete = r.u8() === 1
  const leased = r.u8() === 1
  r.skip(2)
  return { accountRev: header(f).rev, accountId, sessionId, schemaRev, readMask, writeMask, mayDelete, leased, label: r.text() }
}

export interface Ack {
  opId: bigint
  rev: bigint
  id: number
}

export function acks(f: Bytes): Ack[] {
  const r = new Reader(f)
  const n = r.u32()
  r.skip(4)
  const out: Ack[] = []
  for (let i = 0; i < n; i++) {
    const opId = r.u64()
    const rev = r.u64()
    const id = r.u32()
    r.skip(4)
    out.push({ opId, rev, id })
  }
  return out
}

export interface Nack {
  opId: bigint
  code: number
  data: unknown
}

export function nacks(f: Bytes): Nack[] {
  const r = new Reader(f)
  const n = r.u32()
  r.skip(4)
  const out: Nack[] = []
  for (let i = 0; i < n; i++) {
    const opId = r.u64()
    const code = r.u16()
    r.skip(6)
    const json = r.text()
    out.push({ opId, code, data: json === "" ? null : JSON.parse(json) })
  }
  return out
}

/** An RPC error: `code` is the refusal's name from the catalog. */
export interface RpcError {
  code: string
  message: string
  data?: unknown
}

export type Reply = { id: number; ok: true; result: unknown } | { id: number; ok: false; error: RpcError }

export function rpc(hash: number, id: number, method: string, params: unknown): Bytes {
  return new Writer().u32(id).u32(0).field(method).field(JSON.stringify(params ?? {})).done(KIND.RPC, hash)
}

export function reply(f: Bytes): Reply {
  const r = new Reader(f)
  const id = r.u32()
  const ok = r.u8() === 1
  r.skip(3)
  const json = r.text()
  const value: unknown = json === "" ? null : JSON.parse(json)
  return ok ? { id, ok, result: value } : { id, ok, error: value as RpcError }
}

export function bye(f: Bytes): { reason: string; message: string } {
  const r = new Reader(f)
  const code = r.u8()
  r.skip(7)
  return { reason: BYE_REASON[code] ?? `bye ${code}`, message: r.text() }
}

export function ping(hash: number, nonce: bigint): Bytes {
  return new Writer().u64(nonce).done(KIND.PING, hash)
}

export function pong(f: Bytes): bigint {
  return new Reader(f).u64()
}

export type CellValue = null | number | bigint | string | boolean

export interface Cell {
  col: number
  type: number
  value: CellValue
}

export interface Op {
  opId: bigint
  verb: number
  flags: number
  /** A table id for put and drop, a command id for command. */
  target: number
  /** The row id; 0 when keyed or new. */
  id: number
  expectRev: number
  cells: readonly Cell[]
}

/** One op as its own 8-aligned bytes: what OPS carries and what the kernel judges. */
export function encodeOp(op: Op): Bytes {
  const w = new Writer()
  // The writer starts past a frame header; an op is laid out from 0, so encode and cut.
  w.u64(op.opId).u8(op.verb).u8(op.flags).u16(op.target).u32(op.id).u16(op.cells.length).u16(0).u32(op.expectRev)
  for (const c of op.cells) {
    w.u16(c.col).u8(c.type).u8(0)
    const v = c.value
    switch (c.type) {
      case CELL.null:
        w.u32(0)
        break
      case CELL.u32:
        w.u32(4).u32(typeof v === "boolean" ? (v ? 1 : 0) : Number(v))
        break
      case CELL.i64:
        w.u32(8).i64(BigInt(v as number | bigint))
        break
      case CELL.f64: {
        const b = new Uint8Array(8)
        new DataView(b.buffer).setFloat64(0, Number(v), true)
        w.u32(8).bytes(b)
        break
      }
      case CELL.str:
        w.field(String(v))
        continue
      default:
        throw new Error(`cell type ${c.type}`)
    }
    w.pad()
  }
  return w.done(0, 0).slice(HEADER)
}

/** Text bytes an op carries, against OP_TEXT_MAX before it is sent. */
export function opText(op: Op): number {
  let n = 0
  for (const c of op.cells) if (c.type === CELL.str) n += ENC.encode(String(c.value)).byteLength
  return n
}

export function opsFrame(hash: number, ops: readonly Bytes[]): Bytes {
  const w = new Writer().u32(ops.length).u32(0)
  for (const op of ops) w.bytes(op)
  return w.done(KIND.OPS, hash)
}

/** Where whole frames go. A frame view is valid only during the call. */
export type Sink = (f: Bytes, h: Header) => void

/** Cuts a byte stream into frames, in one staging buffer that grows to the largest frame. */
export class Framer {
  private buf = new Uint8Array(64 * 1024)
  private filled = 0

  constructor(private readonly sink: Sink, private readonly broken: (why: string) => void) {}

  push(bytes: Uint8Array): void {
    if (this.filled === 0 && bytes.byteOffset % 8 === 0 && bytes.buffer instanceof ArrayBuffer) {
      // Whole frames, parsed in place.
      let at = 0
      const whole = bytes as Bytes
      while (whole.byteLength - at >= HEADER) {
        const len = new DataView(whole.buffer, whole.byteOffset + at, 4).getUint32(0, true)
        if (len < HEADER || len % 8 !== 0) return this.fail(len)
        if (len > whole.byteLength - at) break
        const f = whole.subarray(at, at + len)
        this.sink(f, header(f))
        at += len
      }
      if (at === whole.byteLength) return
      bytes = whole.subarray(at)
    }
    if (this.buf.byteLength - this.filled < bytes.byteLength) {
      const next = new Uint8Array(Math.max(this.buf.byteLength * 2, this.filled + bytes.byteLength))
      next.set(this.buf.subarray(0, this.filled))
      this.buf = next
    }
    this.buf.set(bytes, this.filled)
    this.filled += bytes.byteLength
    let at = 0
    while (this.filled - at >= HEADER) {
      const len = new DataView(this.buf.buffer, at, 4).getUint32(0, true)
      if (len < HEADER || len % 8 !== 0) return this.fail(len)
      if (this.filled - at < len) break
      const f = this.buf.subarray(at, at + len)
      this.sink(f, header(f))
      at += len
    }
    this.buf.copyWithin(0, at, this.filled)
    this.filled -= at
  }

  private fail(len: number): void {
    this.filled = 0
    this.broken(`bad frame length ${len}`)
  }
}

/** What early.ts started before the bundle loaded: an open carrier and what it already heard. */
export interface Early {
  ws?: WebSocket
  wt?: WebTransport
  writer?: WritableStreamDefaultWriter<Uint8Array>
  control?: ReadableStream<Uint8Array>
  /** Frames (or stream chunks) that arrived before the bundle. */
  queue: ArrayBuffer[]
  helloSent: boolean
}

export interface Hooks {
  /** Every frame, in order, once the BOOT train allows it. */
  frame: Sink
  /** The carrier is up and HELLO is sent. */
  open(carrier: "webtransport" | "websocket"): void
  /** The carrier dropped; `retry` is when the next attempt starts (0: none). */
  lost(why: string, retryMs: number): void
  /** What HELLO should say on the next (re)connect. */
  hello(): Omit<Hello, "credential" | "cred">
}

interface Meta {
  ticket: string
  gate: string
  hashes: { algorithm: string; value: Uint8Array<ArrayBuffer> }[]
  hash: number
}

export function meta(): Meta {
  const m = (name: string) => document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ?? ""
  return {
    ticket: m("hireme-ticket"),
    gate: m("hireme-gate"),
    hashes: m("hireme-gate-hashes").split(" ").filter((h) => h !== "").map((h) => ({
      algorithm: "sha-256",
      value: new Uint8Array((h.match(/../g) ?? []).map((b) => Number.parseInt(b, 16))),
    })),
    hash: Number.parseInt(m("hireme-wire"), 16),
  }
}

/**
 * One wire session, reconnecting. It owns the carrier, the framer, the
 * BOOT-train hold, liveness, and the ticket for each attempt; it knows
 * nothing about rows.
 */
export class Wire {
  readonly hash: number
  private send_: ((f: Bytes) => void) | null = null
  private close_: (() => void) | null = null
  private ticket: string
  private gate: string
  private readonly hashes: Meta["hashes"]
  private held: Bytes[] | null = null
  private heard = 0
  private pinger = 0
  private attempt = 0
  private nonce = 0n
  private ended = false
  private nextCall = 1
  private readonly calls = new Map<number, { resolve: (r: Reply) => void; reject: (e: Error) => void }>()
  /** RPCs asked for before this session's WELCOME, sent the moment it lands. */
  private early: Bytes[] = []
  private welcomed = false

  constructor(private readonly hooks: Hooks) {
    const m = meta()
    this.hash = m.hash
    this.ticket = m.ticket
    this.gate = m.gate
    this.hashes = m.hashes
  }

  /** Adopt what early.ts opened, or connect from nothing. Early spent the page's ticket either way. */
  start(early: Early | undefined): void {
    if (early) this.ticket = ""
    if (early?.wt && early.writer && early.control) this.adoptTransport(early.wt, early.writer, early.control, early.queue, early.helloSent)
    else if (early?.ws && early.ws.readyState <= WebSocket.OPEN) this.adoptSocket(early.ws, early.queue, early.helloSent)
    else void this.connect()
  }

  send(f: Bytes): boolean {
    if (!this.send_) return false
    this.send_(f)
    return true
  }

  /**
   * One RPC; resolves with its REPLY, rejects if the carrier drops first.
   * A parked method (account.watch) simply resolves late.
   */
  call(method: string, params: unknown = {}): Promise<Reply> {
    const id = this.nextCall++
    return new Promise((resolve, reject) => {
      if (this.ended) return reject(new Error("the session has ended"))
      this.calls.set(id, { resolve, reject })
      const f = rpc(this.hash, id, method, params)
      // Before WELCOME (or while reconnecting) the call waits rather than fails: a lens may ask on its first draw.
      if (!this.welcomed || !this.send(f)) this.early.push(f)
    })
  }

  /** The session is over for good (BYE revoked, suspended): no reconnect. */
  end(): void {
    this.ended = true
    this.close_?.()
    for (const c of this.calls.values()) c.reject(new Error("the session has ended"))
    this.calls.clear()
    this.early = []
  }

  private credential(): Bytes {
    const t = this.ticket
    this.ticket = ""
    const h = this.hooks.hello()
    return hello(this.hash, { ...h, cred: CRED.ticket, credential: t })
  }

  private async connect(): Promise<void> {
    if (this.ended) return
    if (this.ticket === "") {
      try {
        const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
        const res = await fetch("/api/wire/ticket", { method: "POST", headers: { "x-csrf-token": csrf }, credentials: "same-origin" })
        if (res.status === 401 || res.status === 403) {
          this.ended = true
          this.hooks.lost("signed out", 0)
          return
        }
        if (!res.ok) throw new Error(`ticket ${res.status}`)
        const body = (await res.json()) as { ticket: string; gate?: string }
        this.ticket = body.ticket
        if (body.gate !== undefined) this.gate = body.gate
      } catch (e) {
        return this.retry(String(e))
      }
    }
    if (this.gate !== "" && "WebTransport" in window && this.attempt < 2) {
      try {
        const wt = new WebTransport(this.gate, this.hashes.length > 0 ? { serverCertificateHashes: this.hashes } : {})
        await wt.ready
        const stream = await wt.createBidirectionalStream()
        const writer = stream.writable.getWriter()
        this.adoptTransport(wt, writer, stream.readable, [], false)
        return
      } catch {
        // UDP blocked or the gate is down: the socket is the fallback, at once.
      }
    }
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/wire`)
    ws.binaryType = "arraybuffer"
    this.adoptSocket(ws, [], false)
  }

  private adoptSocket(ws: WebSocket, queue: ArrayBuffer[], helloSent: boolean): void {
    const framer = this.framer()
    const up = () => {
      this.send_ = (f) => ws.send(f)
      this.close_ = () => ws.close()
      if (!helloSent) ws.send(this.credential())
      this.up("websocket")
    }
    ws.onmessage = (e) => framer.push(new Uint8Array(e.data as ArrayBuffer))
    ws.onclose = () => this.down("socket closed")
    ws.onerror = () => {}
    for (const b of queue.splice(0)) framer.push(new Uint8Array(b))
    if (ws.readyState === WebSocket.OPEN) up()
    else ws.onopen = up
  }

  private adoptTransport(wt: WebTransport, writer: WritableStreamDefaultWriter<Uint8Array>, control: ReadableStream<Uint8Array>,
    queue: ArrayBuffer[], helloSent: boolean): void {
    const framer = this.framer()
    this.send_ = (f) => void writer.write(f).catch(() => {})
    this.close_ = () => wt.close()
    for (const b of queue.splice(0)) framer.push(new Uint8Array(b))
    if (!helloSent) void writer.write(this.credential())
    this.up("webtransport")
    const drain = async (s: ReadableStream<Uint8Array>, f: Framer) => {
      const r = s.getReader()
      for (;;) {
        const { done, value } = await r.read()
        if (done) return
        f.push(value)
      }
    }
    void drain(control, framer).catch(() => {})
    void (async () => {
      const uni = wt.incomingUnidirectionalStreams.getReader()
      for (;;) {
        const { done, value } = await uni.read()
        if (done) return
        void drain(value, this.framer()).catch(() => {})
      }
    })().catch(() => {})
    void wt.closed.then(() => this.down("transport closed"), () => this.down("transport failed"))
  }

  private framer(): Framer {
    return new Framer((f, h) => this.deliver(f, h), (why) => {
      this.hooks.lost(why, 0)
      this.close_?.()
    })
  }

  private up(carrier: "webtransport" | "websocket"): void {
    this.attempt = 0
    this.heard = Date.now()
    this.held = []
    clearInterval(this.pinger)
    this.pinger = window.setInterval(() => {
      if (Date.now() - this.heard > SILENT_MS) {
        this.close_?.()
        return
      }
      this.send(ping(this.hash, ++this.nonce))
    }, PING_MS)
    this.hooks.open(carrier)
  }

  // Frames are copied while held: a framer's view is only good during the call.
  private deliver(f: Bytes, h: Header): void {
    this.heard = Date.now()
    if (h.kind === KIND.REPLY) {
      const r = reply(f)
      const call = this.calls.get(r.id)
      if (call) {
        this.calls.delete(r.id)
        call.resolve(r)
      }
      return
    }
    if (h.kind === KIND.PING) {
      this.send(new Writer().u64(pong(f)).done(KIND.PONG, this.hash))
      return
    }
    const train = h.kind === KIND.BOOT || h.kind === KIND.WELCOME || h.kind === KIND.BYE || h.kind === KIND.PONG
    if (this.held && !train) {
      this.held.push(f.slice())
      return
    }
    this.hooks.frame(f, h)
    if (h.kind === KIND.WELCOME) {
      this.welcomed = true
      for (const g of this.early.splice(0)) this.send(g)
    }
    if (this.held && (h.flags & FLAG.END) !== 0) {
      const held = this.held
      this.held = null
      for (const g of held) this.hooks.frame(g, header(g))
    }
  }

  private down(why: string): void {
    if (this.send_ === null && this.close_ === null) return
    this.send_ = null
    this.close_ = null
    this.held = null
    this.welcomed = false
    clearInterval(this.pinger)
    // A call in flight may or may not have run; its caller decides. Queued ones wait for the next session.
    for (const [id, c] of this.calls) {
      if (this.early.some((f) => new DataView(f.buffer, f.byteOffset + HEADER, 4).getUint32(0, true) === id)) continue
      c.reject(new Error(why))
      this.calls.delete(id)
    }
    this.retry(why)
  }

  private retry(why: string): void {
    if (this.ended) {
      this.hooks.lost(why, 0)
      return
    }
    const ms = Math.min(30_000, 500 * 2 ** this.attempt) * (0.5 + Math.random() / 2)
    this.attempt++
    this.hooks.lost(why, ms)
    setTimeout(() => void this.connect(), ms)
  }
}
