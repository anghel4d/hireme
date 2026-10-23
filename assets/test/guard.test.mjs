// The lens hooks' guard (assets/js/guard.ts): a failing hook's fallback stands in, its failure latches
// per lens and hook, is told once in a clipped notice and logged once, and lifts when the hook works.
// bun test assets/test/guard.test.mjs
import { expect, test } from "bun:test"
import { guard, describe, CLIP } from "../js/guard.ts"

function setup(log, defer = (fn) => fn()) {
  const notes = [], logs = []
  const g = guard((t) => notes.push(t), log ?? ((what, e) => logs.push([what, e])), defer)
  return { g, notes, logs }
}
const boom = (msg) => () => { throw new Error(msg) }

test("a hook's value passes through, a throwing one gives its fallback, and the latch is per lens and per part", () => {
  const { g, notes } = setup()
  expect(g.run("desk", "view", () => 7, 0)).toBe(7)
  expect(g.run("desk", "view", boom("x"), "fallback")).toBe("fallback")
  g.run("focus", "enter", boom("a"), undefined)
  g.run("focus", "enter", boom("a"), undefined)
  g.run("focus", "view", boom("a"), undefined)
  expect(notes.length).toBe(3)
  expect(g.failing("desk", "view") && g.failing("focus", "enter") && g.failing("focus", "view")).toBeTruthy()
  expect(!g.failing("desk", "enter")).toBeTruthy()
  expect(notes[1]).toMatch(/The focus lens failed to load/)
  expect(notes[2]).toMatch(/The focus lens failed to draw/)
})

test("a message that changes on every throw still raises one notice, clipped to 200 characters with its whitespace folded, and one log; a hook that works again lifts its latch", () => {
  const { g, notes, logs } = setup()
  for (let n = 0; n < 50; n++) g.run("desk", "view", boom(`start ${n}\n\n  ${"x".repeat(5000)}`), null)
  expect(notes.length).toBe(1)
  expect(logs.length).toBe(1)
  const inside = notes[0].match(/\((.*)\)\. Reload/)[1]
  expect(inside.length === CLIP && inside.startsWith("start 0 x") && notes[0].length < 300).toBeTruthy()
  expect(logs[0][0]).toBe("the desk lens failed to draw")
  expect(logs[0][1] instanceof Error && logs[0][1].message.startsWith("start 0\n")).toBeTruthy()
  g.run("desk", "view", () => "ok", undefined)
  expect(!g.failing("desk", "view")).toBeTruthy()
  g.run("desk", "view", boom("down again"), undefined)
  expect(notes.length).toBe(2)
  expect(logs.length).toBe(2)
  expect(notes[1]).toMatch(/down again/)
})

test("odd thrown values are told, never thrown again from the catch", () => {
  const odd = [
    null,
    undefined,
    42,
    "a bare string",
    Object.create(null),
    { toString() { throw new Error("no") } },
    { [Symbol.toPrimitive]() { throw new Error("no") } },
    Symbol("s"),
  ]
  for (const v of odd) {
    const { g, notes } = setup()
    expect(g.run("account", "view", () => { throw v }, "fb")).toBe("fb")
    expect(notes.length).toBe(1)
    expect(notes[0]).toMatch(/The account lens failed to draw \(.*\)\./)
  }
  expect(describe(Object.create(null))).toBe("[object Object]")
  expect(describe(new Error("m"))).toBe("m")
})

test("the notice is deferred past the hook's paint, and a log that throws loses the log, not the notice", () => {
  const queued = []
  const deferred = setup(() => { throw new Error("console gone") }, (fn) => queued.push(fn))
  expect(deferred.g.run("desk", "view", boom("x"), 0)).toBe(0)
  expect(deferred.notes.length).toBe(0)
  queued.forEach((fn) => fn())
  expect(deferred.notes.length).toBe(1)
})
