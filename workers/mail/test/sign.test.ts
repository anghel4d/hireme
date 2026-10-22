import { expect, test } from "bun:test"
import worker, { deliver, type Env } from "../src/index"
import { signature } from "../src/sign"

const env: Env = { FORWARD_TO: "operator@example.com", PIPE_URL: "https://node.example/mail/inbound/AbCdEfGh1234", PIPE_SECRET: "k".repeat(32) }
const raw = new TextEncoder().encode("Message-ID: <x1@example.com>\r\n\r\nHello\r\n").buffer

// The same vector is asserted by test/hireme_web/mail_inbound_test.exs.
test("the signature is the node's: v1 HMAC-SHA256 over the timestamp and the body's SHA-256", async () => {
  expect(await signature("k".repeat(32), 1_700_000_000, new TextEncoder().encode("hello"))).toBe("v1=0eaff2c0f990eb6053aeb018a2e84e9c505be66b0344dd5ec1f8e7efe2ff9675")
})

test("the node gets the raw message, signed, with its envelope", async () => {
  const seen: Request[] = []
  const status = await deliver(env, raw, "a@example.com", "matei@domain.example", async (url, init) => {
    seen.push(new Request(url as string, init))
    return new Response("{}", { status: 200 })
  })
  expect(status).toBe(200)
  const r = seen[0]
  expect(r.headers.get("content-type")).toBe("message/rfc822")
  expect(r.headers.get("x-hireme-envelope-to")).toBe("matei@domain.example")
  const ts = Number(r.headers.get("x-hireme-timestamp"))
  expect(r.headers.get("x-hireme-signature")).toBe(await signature(env.PIPE_SECRET, ts, raw))
  expect(new Uint8Array(await r.arrayBuffer())).toEqual(new Uint8Array(raw))
})

test("a busy or absent node is tried again; a refusal for good is not", async () => {
  const answers = (codes: number[]) => {
    let n = 0
    return { calls: () => n, fetch: async () => (n++, codes[n - 1] === -1 ? Promise.reject(new Error("down")) : new Response("{}", { status: codes[n - 1] })) }
  }
  const nap = async () => {}
  const flaky = answers([503, -1, 200])
  expect(await deliver(env, raw, "a", "b", flaky.fetch as typeof fetch, nap)).toBe(200)
  expect(flaky.calls()).toBe(3)
  const bad = answers([401])
  expect(await deliver(env, raw, "a", "b", bad.fetch as typeof fetch, nap)).toBe(401)
  expect(bad.calls()).toBe(1)
  const gone = answers([503, 503, 503, 503])
  expect(await deliver(env, raw, "a", "b", gone.fetch as typeof fetch, nap)).toBe(503)
  expect(gone.calls()).toBe(4)
})

test("every message is forwarded to the operator's inbox, and the node's copy runs beside it", async () => {
  const forwarded: string[] = []
  const pending: Promise<unknown>[] = []
  const posts: string[] = []
  const real = globalThis.fetch
  globalThis.fetch = (async (url: string) => (posts.push(url), new Response("{}", { status: 200 }))) as typeof fetch
  try {
    const message = { from: "a@example.com", to: "matei@domain.example", raw: new Response(raw).body!, forward: async (to: string) => void forwarded.push(to) }
    await worker.email(message, env, { waitUntil: (p) => void pending.push(p) })
    await Promise.all(pending)
  } finally {
    globalThis.fetch = real
  }
  expect(forwarded).toEqual(["operator@example.com"])
  expect(posts).toEqual([env.PIPE_URL])
})
