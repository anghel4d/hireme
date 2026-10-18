// What an audit trail row says beyond its kind: the fields of its meta this
// kind is known to carry and that are fit to show (a host, a provider, a
// label, a count, a key by its name). Nothing else of the meta is printed:
// not a hash (a link's email_hash would let a screenshot confirm a guessed
// address), not an internal id, and nothing a later kind adds until it is
// listed here.

import { EMPTY, html, type Html } from "../morph.ts"

type Row = Record<string, unknown>

/** Per kind, the meta fields shown, in order. A kind not listed shows none. */
const SHOWN: Readonly<Record<string, readonly string[]>> = {
  host_trusted: ["host"],
  sign_in_refused: ["provider", "reason"],
  identity_linked: ["provider"],
  identity_unlinked: ["provider"],
  factor_verified: ["kind"],
  factor_failed: ["kind"],
  factor_removed: ["kind", "name"],
  recovery_codes_issued: ["count"],
  recovery_code_used: ["left"],
  wire_key: ["label", "carrier"],
  wire_key_refused: ["carrier"],
  key_paused: ["key_id"],
  lease_revoked: ["label"],
}

const LABEL: Readonly<Record<string, string>> = { left: "codes left", count: "codes", carrier: "over" }

/** The row's shown meta, " host: levels.fyi · …", or nothing. `keyName` names a key by its id. */
export function detail(e: Row, keyName: (id: string) => string): Html {
  const m = e.meta && typeof e.meta === "object" ? (e.meta as Row) : {}
  const parts: string[] = []
  for (const f of SHOWN[String(e.kind)] ?? []) {
    const x = m[f]
    if (typeof x !== "string" && typeof x !== "number" && typeof x !== "boolean") continue
    // A key the row already names (its key tag) is not named twice.
    if (f === "key_id") {
      if (e.key_id === undefined || e.key_id === null) parts.push(keyName(String(x)))
      continue
    }
    parts.push(`${LABEL[f] ?? f}: ${String(x)}`)
  }
  return parts.length === 0 ? EMPTY : html` <span class="muted">${parts.join(" · ")}</span>`
}
