// Passkey ceremonies. The server sends options in WebAuthn's JSON form
// (binary fields base64url, no padding) and takes the credential back the
// same way. Where the browser parses that form itself
// (parseCreationOptionsFromJSON), it does; otherwise the binary fields are
// decoded here. Used by the factor page (assertion) and the account lens
// (enrollment, over account.passkey.begin/finish).

const b64u = {
  decode(s: string): Uint8Array<ArrayBuffer> {
    const b = atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "="))
    const out = new Uint8Array(b.length)
    for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i)
    return out
  },
  encode(buf: ArrayBuffer | ArrayBufferView): string {
    const bytes = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength)
    let s = ""
    for (const b of bytes) s += String.fromCharCode(b)
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  },
}

type Json = Record<string, unknown>

interface Parsers {
  parseCreationOptionsFromJSON?: (o: Json) => PublicKeyCredentialCreationOptions
  parseRequestOptionsFromJSON?: (o: Json) => PublicKeyCredentialRequestOptions
}

const PKC = (typeof PublicKeyCredential === "undefined" ? {} : PublicKeyCredential) as Parsers

const ids = (list: unknown): PublicKeyCredentialDescriptor[] | undefined =>
  Array.isArray(list)
    ? list.map((c: Json) => ({ ...(c as object), type: "public-key", id: b64u.decode(String(c.id)) }) as PublicKeyCredentialDescriptor)
    : undefined

function creation(o: Json): PublicKeyCredentialCreationOptions {
  if (PKC.parseCreationOptionsFromJSON) return PKC.parseCreationOptionsFromJSON(o)
  const user = o.user as Json
  const exclude = ids(o.excludeCredentials)
  return {
    ...(o as object),
    challenge: b64u.decode(String(o.challenge)),
    user: { ...(user as object), id: b64u.decode(String(user.id)) } as unknown as PublicKeyCredentialUserEntity,
    ...(exclude ? { excludeCredentials: exclude } : {}),
  } as unknown as PublicKeyCredentialCreationOptions
}

function request(o: Json): PublicKeyCredentialRequestOptions {
  if (PKC.parseRequestOptionsFromJSON) return PKC.parseRequestOptionsFromJSON(o)
  const allow = ids(o.allowCredentials)
  return {
    ...(o as object),
    challenge: b64u.decode(String(o.challenge)),
    ...(allow ? { allowCredentials: allow } : {}),
  } as unknown as PublicKeyCredentialRequestOptions
}

export const supported = (): boolean => typeof PublicKeyCredential !== "undefined" && !!navigator.credentials

/** Enrollment: the attestation fields account.passkey.finish takes. */
export async function create(options: Json): Promise<{ attestationObject: string; clientDataJSON: string; transports: string[] }> {
  const cred = (await navigator.credentials.create({ publicKey: creation(options) })) as PublicKeyCredential | null
  if (!cred) throw new Error("No passkey was created.")
  const r = cred.response as AuthenticatorAttestationResponse
  return {
    attestationObject: b64u.encode(r.attestationObject),
    clientDataJSON: b64u.encode(r.clientDataJSON),
    transports: typeof r.getTransports === "function" ? r.getTransports() : [],
  }
}

/** Assertion: the fields the factor page's verify endpoint takes. */
export async function get(options: Json): Promise<Record<string, string | null>> {
  const cred = (await navigator.credentials.get({ publicKey: request(options) })) as PublicKeyCredential | null
  if (!cred) throw new Error("No passkey was used.")
  const r = cred.response as AuthenticatorAssertionResponse
  return {
    rawId: b64u.encode(cred.rawId),
    authenticatorData: b64u.encode(r.authenticatorData),
    clientDataJSON: b64u.encode(r.clientDataJSON),
    signature: b64u.encode(r.signature),
    userHandle: r.userHandle ? b64u.encode(r.userHandle) : null,
  }
}

/** What a person should read when a ceremony fails: a cancel is not an error. */
export function why(e: unknown): string {
  if (e instanceof DOMException && (e.name === "NotAllowedError" || e.name === "AbortError")) return "The passkey prompt was dismissed."
  if (e instanceof DOMException && e.name === "InvalidStateError") return "This passkey is already enrolled."
  return e instanceof Error ? e.message : "The passkey did not work."
}
