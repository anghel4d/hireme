// HDP1: "HDP1" | u32 header_len | header JSON | body (4-byte aligned).
// The header is the directory. The body is the columns.

export type ColumnKind = "u32" | "str"

export interface ColumnEntry {
  name: string
  kind: ColumnKind
  at: number
  size: number
}

export interface Stage { key: string; label: string; hint: string }
export interface Band { key: string; label: string; min: number; max: number }
export interface Batch { code: string; ordinal: number; fire: "hold" | "open_fire"; status: string }
export interface Profile { id: number; slug: string; name: string }

export interface Tables {
  stages: Stage[]
  statuses: string[]
  freshness: string[]
  gates: string[]
  bands: Band[]
  batches: Batch[]
  profiles: Profile[]
}

export interface Header {
  v: 1
  n: number
  columns: ColumnEntry[]
  tables: Tables
}

export interface Packet {
  header: Header
  body: Uint8Array
}

const MAGIC = 0x31504448 // "HDP1" little-endian

export function parsePacket(buffer: ArrayBuffer): Packet {
  const view = new DataView(buffer)
  if (buffer.byteLength < 8 || view.getUint32(0, true) !== MAGIC) {
    throw new Error("not an HDP1 packet")
  }
  const headerLen = view.getUint32(4, true)
  const headerBytes = new Uint8Array(buffer, 8, headerLen)
  const header = JSON.parse(new TextDecoder().decode(headerBytes)) as Header
  const bodyAt = 8 + headerLen + ((4 - (headerLen % 4)) % 4)
  return { header, body: new Uint8Array(buffer, bodyAt) }
}

export function column(header: Header, name: string): ColumnEntry {
  const entry = header.columns.find((c) => c.name === name)
  if (!entry) throw new Error(`packet has no column ${name}`)
  return entry
}
