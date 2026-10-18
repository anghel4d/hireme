// The account trail's meta line (assets/js/lenses/trail.ts): only the fields a kind is known to carry
// and fit to show, escaped; never a hash or an internal id.
// node --experimental-transform-types --test assets/test/trail.test.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { detail } from "../js/lenses/trail.ts"

const names = (id) => (id === "3" ? "research agent" : `key ${id}`)
const shown = (e) => detail(e, names).text

test("a link's email_hash, a token and internal ids are never shown", () => {
  for (const kind of ["link_requested", "link_redeemed"]) {
    assert.equal(shown({ kind, meta: { email_hash: "059ed3567ee841b4", token: "t0k", secret: "s", code: "123456" } }), "")
  }
  assert.equal(shown({ kind: "factor_verified", meta: { factor_id: 9, kind: "totp" } }), ' <span class="muted">kind: totp</span>')
  assert.equal(shown({ kind: "identity_linked", meta: { provider: "github", display: "me@example.com", identity_id: 4 } }), ' <span class="muted">provider: github</span>')
  assert.equal(shown({ kind: "host_distrusted", meta: { id: 12 } }), "")
})

test("a kind not listed shows nothing of its meta", () => {
  assert.equal(shown({ kind: "something_new", meta: { anything: "x", email_hash: "y" } }), "")
  assert.equal(shown({ kind: "api_key_created", key_id: 3, meta: { name: "research agent", preset: "read_write" } }), "")
})

test("listed fields read in order, a count and a key by name", () => {
  assert.equal(shown({ kind: "sign_in_refused", meta: { reason: "rate_limited", provider: "email" } }), ' <span class="muted">provider: email · reason: rate_limited</span>')
  assert.equal(shown({ kind: "recovery_code_used", meta: { left: 7 } }), ' <span class="muted">codes left: 7</span>')
  assert.equal(shown({ kind: "key_paused", meta: { key_id: 3, lease_id: 5 } }), ' <span class="muted">research agent</span>')
  // A row whose key tag already names the key does not name it again.
  assert.equal(shown({ kind: "key_paused", key_id: 3, meta: { key_id: 3 } }), "")
})

test("hostile values are escaped, and objects are not printed", () => {
  const h = shown({ kind: "host_trusted", meta: { host: '<img src=x onerror="alert(1)">' } })
  assert.ok(!h.includes("<img") && h.includes("&lt;img"), h)
  assert.equal(shown({ kind: "wire_key", meta: { label: { nested: true }, carrier: "websocket" } }), ' <span class="muted">over: websocket</span>')
  assert.equal(shown({ kind: "host_trusted" }), "")
})
