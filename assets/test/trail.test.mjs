// The account trail's meta line (assets/js/lenses/trail.ts): only the fields a kind is known to carry
// and fit to show, each read by its kind's own label, escaped; never a hash or an internal id.
// Fixtures are rows as the server writes them: a key's lifecycle row has key_id null at row level and
// the key in its meta.
// bun test assets/test/trail.test.mjs
import { expect, test } from "bun:test"
import { detail } from "../js/lenses/trail.ts"

const names = (id) => (id === "3" ? "research agent" : `key ${id}`)
const shown = (e) => detail(e, names).text
const muted = (s) => ` <span class="muted">${s}</span>`

test("a link's email_hash, a token and internal ids are never shown", () => {
  for (const kind of ["link_requested", "link_redeemed"]) {
    expect(shown({ kind, key_id: null, meta: { email_hash: "059ed3567ee841b4", token: "t0k", secret: "s", code: "123456" } })).toBe("")
  }
  expect(shown({ kind: "factor_verified", meta: { factor_id: 9, kind: "totp" } })).toBe(muted("factor: totp"))
  expect(shown({ kind: "identity_linked", meta: { provider: "github", display: "me@example.com", identity_id: 4 } })).toBe(muted("provider: github"))
  expect(shown({ kind: "host_distrusted", meta: { id: 12 } })).toBe("")
})

test("a key's lifecycle names the key and the access an owner audits", () => {
  expect(shown({ kind: "api_key_created", key_id: null, meta: { key_id: 3, name: "research agent", preset: "read_write" } })).toBe(muted("key: research agent · access: read_write"))
  expect(shown({ kind: "api_key_changed", key_id: null, meta: { key_id: 3, name: "research agent", preset: "custom", may_delete: true } })).toBe(muted("key: research agent · access: custom · may delete: true"))
  expect(shown({ kind: "api_key_renamed", key_id: null, meta: { key_id: 3, name: "scraper" } })).toBe(muted("now named: scraper"))
  expect(shown({ kind: "api_key_revoked", key_id: null, meta: { key_id: 3, name: "research agent" } })).toBe(muted("key: research agent"))
  expect(shown({ kind: "key_resumed", key_id: null, meta: { key_id: 3, name: "research agent" } })).toBe(muted("key: research agent"))
  expect(shown({ kind: "key_paused", key_id: null, meta: { key_id: 3, lease_id: 5 } })).toBe(muted("key: research agent"))
  // A row whose own key tag already names the key does not name it again (eliza's b47b0e8 sets it on
  // every lifecycle row); a name the key has since changed is still shown.
  expect(shown({ kind: "key_paused", key_id: 3, meta: { key_id: 3 } })).toBe("")
  expect(shown({ kind: "api_key_created", key_id: 3, meta: { key_id: 3, name: "research agent", preset: "read_write" } })).toBe(muted("access: read_write"))
  expect(shown({ kind: "api_key_revoked", key_id: 3, meta: { key_id: 3, name: "old name" } })).toBe(muted("key: old name"))
})

test("each kind reads its own labels: a count is codes, claims or ops by kind", () => {
  expect(shown({ kind: "recovery_codes_issued", meta: { count: 10 } })).toBe(muted("codes: 10"))
  expect(shown({ kind: "recovery_code_used", meta: { left: 7 } })).toBe(muted("codes left: 7"))
  expect(shown({ kind: "lease_opened", key_id: 3, meta: { lease_id: 41, label: "agent A", count: 16 } })).toBe(muted("label: agent A · claims: 16"))
  expect(shown({ kind: "lease_revoked", key_id: 3, meta: { lease_id: 41, label: "agent A", count: 4 } })).toBe(muted("label: agent A · claims released: 4"))
  expect(shown({ kind: "agent_ops", key_id: 3, meta: { count: 3, acks: 2, nacks: 1 } })).toBe(muted("ops: 3 · refused: 1"))
  expect(shown({ kind: "signed_in", meta: { provider: "email", identity_id: 1 } })).toBe(muted("via: email"))
  expect(shown({ kind: "sign_in_refused", meta: { reason: "rate_limited", provider: "email" } })).toBe(muted("via: email · reason: rate_limited"))
  expect(shown({ kind: "factor_added", meta: { kind: "webauthn", name: "laptop", factor_id: 2 } })).toBe(muted("factor: webauthn · named: laptop"))
})

test("a kind not listed, or one named like an Object member, shows nothing and never throws", () => {
  for (const kind of ["something_new", "constructor", "__proto__", "toString", "hasOwnProperty"]) {
    expect(shown({ kind, meta: { anything: "x", email_hash: "y", name: "n" } })).toBe("")
  }
  // A meta whose field is only inherited is not shown either.
  expect(shown({ kind: "host_trusted", meta: Object.create({ host: "inherited.example" }) })).toBe("")
})

test("hostile values are escaped, and objects are not printed", () => {
  const h = shown({ kind: "host_trusted", meta: { host: '<img src=x onerror="alert(1)">' } })
  expect(!h.includes("<img") && h.includes("&lt;img")).toBeTruthy()
  expect(shown({ kind: "wire_key", meta: { label: { nested: true }, carrier: "websocket" } })).toBe(muted("over: websocket"))
  expect(shown({ kind: "host_trusted" })).toBe("")
})
