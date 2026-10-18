// The lens hooks' guard (assets/js/guard.ts): a failing hook's fallback stands in, its failure latches
// per lens and hook, is told once in a clipped notice and logged once, and lifts when the hook works.
// bun test assets/test/guard.test.mjs
import { expect, test } from "bun:test"
import { guard, describe, CLIP } from "../js/guard.ts"

function setup() {
  const notes = [], logs = []
  const g = guard((t) => notes.push(t), (what, e) => logs.push([what, e]), (fn) => fn())
  return { g, notes, logs }
}
const boom = (msg) => () => { throw new Error(msg) }

test("a hook's value passes through, and a throwing one gives its fallback", () => {
  const { g, notes } = setup()
  expect(g.run("desk", "view", () => 7, 0)).toBe(7)
  expect(g.run("desk", "view", boom("x"), "fallback")).toBe("fallback")
  expect(notes.length).toBe(1)
})

test("the latch is per lens and per part", () => {
  const { g, notes } = setup()
  g.run("focus", "enter", boom("a"), undefined)
  g.run("focus", "enter", boom("a"), undefined)
  g.run("focus", "view", boom("a"), undefined)
  g.run("desk", "enter", boom("a"), undefined)
  expect(notes.length).toBe(3)
  expect(g.failing("focus", "enter") && g.failing("focus", "view") && g.failing("desk", "enter")).toBeTruthy()
  expect(!g.failing("desk", "view")).toBeTruthy()
  expect(notes[0]).toMatch(/The focus lens failed to load/)
  expect(notes[1]).toMatch(/The focus lens failed to draw/)
})

test("a message that changes on every throw still raises one notice and one log", () => {
  const { g, notes, logs } = setup()
  for (let n = 0; n < 50; n++) g.run("desk", "view", boom(`boom ${n}`), null)
  expect(notes.length).toBe(1)
  expect(logs.length).toBe(1)
  expect(logs[0][0]).toBe("the desk lens failed to draw")
  expect(logs[0][1] instanceof Error && logs[0][1].message === "boom 0").toBeTruthy()
})

test("the notice clips the message to 200 characters and folds its whitespace", () => {
  const { g, notes } = setup()
  g.run("world", "after", boom(`start\n\n  ${"x".repeat(5000)}`), undefined)
  const inside = notes[0].match(/\((.*)\)\. Reload/)[1]
  expect(inside.length).toBe(CLIP)
  expect(inside.startsWith("start x")).toBeTruthy()
  expect(notes[0].length < 300).toBeTruthy()
})

test("a hook that works again lifts its latch: the next failure is told again", () => {
  const { g, notes, logs } = setup()
  g.run("lanes", "after", boom("down"), undefined)
  g.run("lanes", "after", () => "ok", undefined)
  expect(!g.failing("lanes", "after")).toBeTruthy()
  g.run("lanes", "after", boom("down again"), undefined)
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

test("a log that throws loses the log, not the notice", () => {
  const notes = []
  const g = guard((t) => notes.push(t), () => { throw new Error("console gone") }, (fn) => fn())
  expect(g.run("desk", "view", boom("x"), 0)).toBe(0)
  expect(notes.length).toBe(1)
})

test("the notice is deferred, not raised inside the hook's paint", () => {
  const notes = [], queued = []
  const g = guard((t) => notes.push(t), () => {}, (fn) => queued.push(fn))
  g.run("desk", "view", boom("x"), 0)
  expect(notes.length).toBe(0)
  queued.forEach((fn) => fn())
  expect(notes.length).toBe(1)
})
