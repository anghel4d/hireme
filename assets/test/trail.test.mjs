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

test("each kind reads its own labels and never a hash, token or internal id", () => {
  const rows = [
    [{ kind: "link_requested", key_id: null, meta: { email_hash: "059ed3567ee841b4", token: "t0k", secret: "s", code: "123456" } }, ""],
    [{ kind: "link_redeemed", key_id: null, meta: { email_hash: "059ed3567ee841b4", token: "t0k" } }, ""],
    [{ kind: "factor_verified", meta: { factor_id: 9, kind: "totp" } }, "factor: totp"],
    [{ kind: "identity_linked", meta: { provider: "github", display: "me@example.com", identity_id: 4 } }, "provider: github"],
    [{ kind: "host_distrusted", meta: { id: 12 } }, ""],
    [{ kind: "recovery_codes_issued", meta: { count: 10 } }, "codes: 10"],
    [{ kind: "recovery_code_used", meta: { left: 7 } }, "codes left: 7"],
    [{ kind: "lease_opened", key_id: 3, meta: { lease_id: 41, label: "agent A", count: 16 } }, "label: agent A · claims: 16"],
    [{ kind: "lease_revoked", key_id: 3, meta: { lease_id: 41, label: "agent A", count: 4 } }, "label: agent A · claims released: 4"],
    [{ kind: "agent_ops", key_id: 3, meta: { count: 3, acks: 2, nacks: 1 } }, "ops: 3 · refused: 1"],
    [{ kind: "signed_in", meta: { provider: "email", identity_id: 1 } }, "via: email"],
    [{ kind: "sign_in_refused", meta: { reason: "rate_limited", provider: "email" } }, "via: email · reason: rate_limited"],
    [{ kind: "factor_added", meta: { kind: "webauthn", name: "laptop", factor_id: 2 } }, "factor: webauthn · named: laptop"],
    [{ kind: "wire_key", meta: { label: { nested: true }, carrier: "websocket" } }, "over: websocket"],
    [{ kind: "host_trusted" }, ""],
  ]
  for (const [row, text] of rows) expect(shown(row)).toBe(text ? muted(text) : "")
})

test("a key's lifecycle names the key and the access an owner audits", () => {
  const rows = [
    [{ kind: "api_key_created", key_id: null, meta: { key_id: 3, name: "research agent", preset: "read_write" } }, "key: research agent · access: read_write"],
    [{ kind: "api_key_changed", key_id: null, meta: { key_id: 3, name: "research agent", preset: "custom", may_delete: true } }, "key: research agent · access: custom · may delete: true"],
    [{ kind: "api_key_renamed", key_id: null, meta: { key_id: 3, name: "scraper" } }, "now named: scraper"],
    [{ kind: "api_key_revoked", key_id: null, meta: { key_id: 3, name: "research agent" } }, "key: research agent"],
    [{ kind: "key_resumed", key_id: null, meta: { key_id: 3, name: "research agent" } }, "key: research agent"],
    [{ kind: "key_paused", key_id: null, meta: { key_id: 3, lease_id: 5 } }, "key: research agent"],
    // A row whose own key tag already names the key does not name it again; a name the key has since changed is still shown.
    [{ kind: "key_paused", key_id: 3, meta: { key_id: 3 } }, ""],
    [{ kind: "api_key_created", key_id: 3, meta: { key_id: 3, name: "research agent", preset: "read_write" } }, "access: read_write"],
    [{ kind: "api_key_revoked", key_id: 3, meta: { key_id: 3, name: "old name" } }, "key: old name"],
  ]
  for (const [row, text] of rows) expect(shown(row)).toBe(text ? muted(text) : "")
})

test("a kind not listed or named like an Object member shows nothing and never throws; hostile values are escaped, objects not printed", () => {
  for (const kind of ["something_new", "constructor", "__proto__", "toString", "hasOwnProperty"]) {
    expect(shown({ kind, meta: { anything: "x", email_hash: "y", name: "n" } })).toBe("")
  }
  // A meta whose field is only inherited is not shown either.
  expect(shown({ kind: "host_trusted", meta: Object.create({ host: "inherited.example" }) })).toBe("")
  const h = shown({ kind: "host_trusted", meta: { host: '<img src=x onerror="alert(1)">' } })
  expect(!h.includes("<img") && h.includes("&lt;img")).toBeTruthy()
})
