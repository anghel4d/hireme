// What an audit trail row says beyond its kind: the fields of its meta this
// kind is known to carry and that are fit to show (a key's name and access,
// a host, a provider, a label, a count). Nothing else of the meta is
// printed: not a hash (a link's email_hash would let a screenshot confirm a
// guessed address), not an internal id, and nothing a later kind adds until
// it is listed here.

import { EMPTY, html, type Html } from "../morph.ts"

type Row = Record<string, unknown>

/** Per kind, the meta fields shown and how each reads, in order. A kind not listed shows none. */
const SHOWN: ReadonlyMap<string, readonly (readonly [field: string, label: string])[]> = new Map([
  ["api_key_created", [["name", "key"], ["preset", "access"]]],
  ["api_key_renamed", [["name", "now named"]]],
  ["api_key_changed", [["name", "key"], ["preset", "access"], ["may_delete", "may delete"]]],
  ["api_key_revoked", [["name", "key"]]],
  ["key_resumed", [["name", "key"]]],
  ["key_paused", [["key_id", "key"]]],
  ["host_trusted", [["host", "host"]]],
  ["account_created", [["provider", "via"]]],
  ["signed_in", [["provider", "via"]]],
  ["sign_in_refused", [["provider", "via"], ["reason", "reason"]]],
  ["identity_linked", [["provider", "provider"]]],
  ["identity_unlinked", [["provider", "provider"]]],
  ["factor_added", [["kind", "factor"], ["name", "named"]]],
  ["factor_verified", [["kind", "factor"]]],
  ["factor_failed", [["kind", "factor"]]],
  ["factor_locked", [["kind", "factor"]]],
  ["factor_removed", [["kind", "factor"], ["name", "named"]]],
  ["recovery_codes_issued", [["count", "codes"]]],
  ["recovery_code_used", [["left", "codes left"]]],
  ["wire_key", [["label", "label"], ["carrier", "over"]]],
  ["wire_key_refused", [["carrier", "over"]]],
  ["lease_opened", [["label", "label"], ["count", "claims"]]],
  ["lease_released", [["label", "label"], ["count", "claims"]]],
  ["lease_revoked", [["label", "label"], ["count", "claims released"]]],
  ["agent_ops", [["count", "ops"], ["nacks", "refused"]]],
])

/** The row's shown meta, " key: research agent · access: read_write", or nothing. `keyName` names a key by its id. */
export function detail(e: Row, keyName: (id: string) => string): Html {
  const m = e.meta && typeof e.meta === "object" ? (e.meta as Row) : {}
  const parts: string[] = []
  for (const [f, label] of SHOWN.get(String(e.kind)) ?? []) {
    if (!Object.hasOwn(m, f)) continue
    const x = m[f]
    if (typeof x !== "string" && typeof x !== "number" && typeof x !== "boolean") continue
    // A key id reads as the key's name, unless the row's own key tag already names it.
    if (f === "key_id") {
      if (e.key_id === undefined || e.key_id === null) parts.push(`${label}: ${keyName(String(x))}`)
      continue
    }
    // A key's name the row's key tag already shows is not repeated; a name it has since changed is kept.
    if (label === "key" && e.key_id !== undefined && e.key_id !== null && keyName(String(e.key_id)) === String(x)) continue
    parts.push(`${label}: ${String(x)}`)
  }
  return parts.length === 0 ? EMPTY : html` <span class="muted">${parts.join(" · ")}</span>`
}
