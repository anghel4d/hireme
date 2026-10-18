// The lens hooks' guard (assets/js/guard.ts): a failing hook's fallback stands in, its failure latches
// per lens and hook, is told once in a clipped notice and logged once, and lifts when the hook works.
// node --experimental-transform-types --test assets/test/guard.test.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { guard, describe, CLIP } from "../js/guard.ts"

function setup() {
  const notes = [], logs = []
  const g = guard((t) => notes.push(t), (what, e) => logs.push([what, e]), (fn) => fn())
  return { g, notes, logs }
}
const boom = (msg) => () => { throw new Error(msg) }

test("a hook's value passes through, and a throwing one gives its fallback", () => {
  const { g, notes } = setup()
  assert.equal(g.run("desk", "view", () => 7, 0), 7)
  assert.equal(g.run("desk", "view", boom("x"), "fallback"), "fallback")
  assert.equal(notes.length, 1)
})

test("the latch is per lens and per part", () => {
  const { g, notes } = setup()
  g.run("focus", "enter", boom("a"), undefined)
  g.run("focus", "enter", boom("a"), undefined)
  g.run("focus", "view", boom("a"), undefined)
  g.run("desk", "enter", boom("a"), undefined)
  assert.equal(notes.length, 3)
  assert.ok(g.failing("focus", "enter") && g.failing("focus", "view") && g.failing("desk", "enter"))
  assert.ok(!g.failing("desk", "view"))
  assert.match(notes[0], /The focus lens failed to load/)
  assert.match(notes[1], /The focus lens failed to draw/)
})

test("a message that changes on every throw still raises one notice and one log", () => {
  const { g, notes, logs } = setup()
  for (let n = 0; n < 50; n++) g.run("desk", "view", boom(`boom ${n}`), null)
  assert.equal(notes.length, 1)
  assert.equal(logs.length, 1)
  assert.equal(logs[0][0], "the desk lens failed to draw")
  assert.ok(logs[0][1] instanceof Error && logs[0][1].message === "boom 0", "the log carries the error itself (its stack)")
})

test("the notice clips the message to 200 characters and folds its whitespace", () => {
  const { g, notes } = setup()
  g.run("world", "after", boom(`start\n\n  ${"x".repeat(5000)}`), undefined)
  const inside = notes[0].match(/\((.*)\)\. Reload/)[1]
  assert.equal(inside.length, CLIP)
  assert.ok(inside.startsWith("start x"), inside.slice(0, 20))
  assert.ok(notes[0].length < 300)
})

test("a hook that works again lifts its latch: the next failure is told again", () => {
  const { g, notes, logs } = setup()
  g.run("lanes", "refresh", boom("down"), undefined)
  g.run("lanes", "refresh", () => "ok", undefined)
  assert.ok(!g.failing("lanes", "refresh"))
  g.run("lanes", "refresh", boom("down again"), undefined)
  assert.equal(notes.length, 2)
  assert.equal(logs.length, 2)
  assert.match(notes[1], /down again/)
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
    assert.equal(g.run("account", "view", () => { throw v }, "fb"), "fb")
    assert.equal(notes.length, 1, String(typeof v))
    assert.match(notes[0], /The account lens failed to draw \(.*\)\./)
  }
  assert.equal(describe(Object.create(null)), "[object Object]")
  assert.equal(describe(new Error("m")), "m")
})

test("a log that throws loses the log, not the notice", () => {
  const notes = []
  const g = guard((t) => notes.push(t), () => { throw new Error("console gone") }, (fn) => fn())
  assert.equal(g.run("desk", "view", boom("x"), 0), 0)
  assert.equal(notes.length, 1)
})

test("the notice is deferred, not raised inside the hook's paint", () => {
  const notes = [], queued = []
  const g = guard((t) => notes.push(t), () => {}, (fn) => queued.push(fn))
  g.run("desk", "view", boom("x"), 0)
  assert.equal(notes.length, 0)
  queued.forEach((fn) => fn())
  assert.equal(notes.length, 1)
})
