// The worker early.ts starts the moment the page parses. It takes the
// kernel's compiled module and the node's made-up BOOT (Codec.warm/0) and
// runs the page's first calls over them: ingest, the board, cards, the
// scoreboard, a find, an application. Wasm compiles a function the first
// time it is called, for every instance of the module, so the page's own
// first ingest and draw find them compiled instead of compiling them on
// the main thread while the desk waits. Then it closes; nothing it holds
// is read by the page.

import type { Exports } from "./kernel.ts"

interface Warm {
  module: WebAssembly.Module
  boot: Uint8Array
  today: number
}

onmessage = async ({ data }: MessageEvent<Warm>) => {
  try {
    const inst = await WebAssembly.instantiate(data.module, { host: { random_u32: () => crypto.getRandomValues(new Uint32Array(1))[0] } })
    const x = inst.exports as unknown as Exports
    const put = (b: Uint8Array): [number, number] => {
      const p = x.alloc(b.byteLength)
      new Uint8Array(x.memory.buffer, p, b.byteLength).set(b)
      return [p, b.byteLength]
    }
    const json = (v: unknown) => put(new TextEncoder().encode(JSON.stringify(v)))
    x.set_today(data.today)
    x.set_grants(31, 31, 1, 1)
    x.ingest(...put(data.boot))
    const n = x.view(...json({}))
    const ids = n > 0 ? Array.from(new Uint32Array(new Uint8Array(x.memory.buffer, x.result_ptr(), n).slice().buffer)) : []
    for (const id of ids) x.card(id)
    x.scoreboard()
    x.query(...json({ op: "find", table: "applications", where: { id: { in: ids } }, cols: ["id", "no", "company", "role", "location", "work_mode", "pips", "stage"], limit: ids.length }))
    x.step(...json({}), ids[0] ?? 0, 0, 5)
    if (ids[0] !== undefined) x.application(ids[0])
    x.lanes()
  } finally {
    close()
  }
}
