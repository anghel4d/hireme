// The resident column store: the packet body copied into WebAssembly
// memory, typed-array views over its columns, and the selection the
// kernel writes. Strings are decoded on demand and remembered.

import { column, type Packet, type Tables } from "./packet.ts"

interface Kernel {
  mem: WebAssembly.Memory
  reset(): void
  alloc(size: number): number
  select(
    n: number, cols: number,
    min: number, lo: number, hi: number,
    stage: number, status: number, batch: number, profile: number, heat: number,
    q: number, qlen: number,
    out: number,
  ): number
  find(out: number, count: number, ids: number, id: number): number
}

export interface Selection {
  readonly min: number
  readonly lo: number
  readonly hi: number
  readonly stage: number
  readonly status: number
  readonly batch: number
  readonly profile: number
  readonly heat: number
  readonly q: string
}

export class StrColumn {
  private readonly cache = new Map<number, string>()
  private readonly decoder = new TextDecoder()

  constructor(
    private readonly mem: WebAssembly.Memory,
    private readonly offsets: number,
    private readonly bytes: number,
    private readonly n: number,
  ) {}

  at(i: number): string {
    const hit = this.cache.get(i)
    if (hit !== undefined) return hit
    const offs = new Uint32Array(this.mem.buffer, this.offsets, this.n + 1)
    const start = offs[i] ?? 0
    const end = offs[i + 1] ?? start
    const text = this.decoder.decode(new Uint8Array(this.mem.buffer, this.bytes + start, end - start))
    this.cache.set(i, text)
    return text
  }
}

export class Store {
  readonly n: number
  readonly tables: Tables
  private readonly base: number
  private readonly cols: number
  private readonly out: number
  private readonly scratch: number
  private readonly scratchSize = 256
  private readonly u32s = new Map<string, number>()
  private readonly strs = new Map<string, StrColumn>()
  private count = 0

  constructor(private readonly k: Kernel, packet: Packet) {
    this.n = packet.header.n
    this.tables = packet.header.tables
    k.reset()
    this.base = k.alloc(packet.body.byteLength)
    new Uint8Array(k.mem.buffer, this.base, packet.body.byteLength).set(packet.body)

    for (const c of packet.header.columns) {
      if (c.kind === "u32") {
        this.u32s.set(c.name, this.base + c.at)
      } else {
        const offsets = this.base + c.at
        this.strs.set(c.name, new StrColumn(k.mem, offsets, offsets + 4 * (this.n + 1), this.n))
      }
    }

    const search = column(packet.header, "search")
    const searchOffsets = this.base + search.at
    const table = [
      this.u32("score"), this.u32("heat"), this.u32("stage"), this.u32("status"),
      this.u32("freshness"), this.u32("gate"), this.u32("batch"), this.u32("profile"),
      searchOffsets, searchOffsets + 4 * (this.n + 1), this.u32("heat_state"),
    ]
    this.cols = k.alloc(table.length * 4)
    new Uint32Array(k.mem.buffer, this.cols, table.length).set(table)
    this.out = k.alloc(Math.max(this.n, 1) * 4)
    this.scratch = k.alloc(this.scratchSize)
  }

  u32(name: string): number {
    const p = this.u32s.get(name)
    if (p === undefined) throw new Error(`no u32 column ${name}`)
    return p
  }

  column(name: string): Uint32Array {
    return new Uint32Array(this.k.mem.buffer, this.u32(name), this.n)
  }

  str(name: string): StrColumn {
    const c = this.strs.get(name)
    if (!c) throw new Error(`no str column ${name}`)
    return c
  }

  /** Run the kernel. Returns the number of rows selected. */
  select(s: Selection): number {
    const q = new TextEncoder().encode(s.q.toLowerCase().trim()).slice(0, this.scratchSize)
    new Uint8Array(this.k.mem.buffer, this.scratch, q.byteLength).set(q)
    this.count = this.k.select(
      this.n, this.cols, s.min, s.lo, s.hi, s.stage, s.status, s.batch, s.profile, s.heat,
      this.scratch, q.byteLength, this.out,
    )
    return this.count
  }

  /** The current selection as row indices, in board order. */
  selection(): Uint32Array {
    return new Uint32Array(this.k.mem.buffer, this.out, this.count)
  }

  /** Position of a job id within the selection, or -1. */
  find(id: number): number {
    return this.k.find(this.out, this.count, this.u32("id"), id)
  }

  /** Row index of a job id in the whole packet, or -1. */
  rowOf(id: number): number {
    return this.column("id").indexOf(id)
  }
}

export async function loadKernel(url: string): Promise<Kernel> {
  const { instance } = await WebAssembly.instantiateStreaming(fetch(url), {})
  return instance.exports as unknown as Kernel
}
