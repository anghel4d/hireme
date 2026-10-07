// WebAuthn as the browser speaks it: the server's options (binary fields
// base64url) into the credentials API, and the credential back out.

const b64 = {
  decode(s: string): ArrayBuffer {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"))
    const out = new Uint8Array(bin.length)
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
    return out.buffer
  },
  encode(buf: ArrayBuffer): string {
    let bin = ""
    for (const b of new Uint8Array(buf)) bin += String.fromCharCode(b)
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  },
}

interface Descriptor { type: "public-key"; id: string; transports?: string[] }

interface CreationJSON {
  publicKey: {
    challenge: string
    rp: { id: string; name: string }
    user: { id: string; name: string; displayName: string }
    pubKeyCredParams: { type: "public-key"; alg: number }[]
    timeout: number
    attestation: AttestationConveyancePreference
    authenticatorSelection: AuthenticatorSelectionCriteria
    excludeCredentials: Descriptor[]
  }
}

interface RequestJSON {
  publicKey: { challenge: string; rpId: string; timeout: number; userVerification: UserVerificationRequirement; allowCredentials: Descriptor[] }
}

const descriptor = (d: Descriptor): PublicKeyCredentialDescriptor => ({
  type: "public-key",
  id: b64.decode(d.id),
  transports: d.transports as AuthenticatorTransport[] | undefined,
})

export function supported(): boolean {
  return typeof PublicKeyCredential !== "undefined"
}

/** Register: returns the attestation response the server verifies. */
export async function create(json: CreationJSON): Promise<Record<string, unknown>> {
  const pk = json.publicKey
  const cred = (await navigator.credentials.create({
    publicKey: {
      challenge: b64.decode(pk.challenge),
      rp: pk.rp,
      user: { id: b64.decode(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
      pubKeyCredParams: pk.pubKeyCredParams,
      timeout: pk.timeout,
      attestation: pk.attestation,
      authenticatorSelection: pk.authenticatorSelection,
      excludeCredentials: pk.excludeCredentials.map(descriptor),
    },
  })) as PublicKeyCredential | null
  if (!cred) throw new Error("No credential was created.")
  const response = cred.response as AuthenticatorAttestationResponse
  return {
    rawId: b64.encode(cred.rawId),
    attestationObject: b64.encode(response.attestationObject),
    clientDataJSON: b64.encode(response.clientDataJSON),
    transports: typeof response.getTransports === "function" ? response.getTransports() : [],
  }
}

/** Assert: returns the assertion response the server verifies. */
export async function get(json: RequestJSON): Promise<Record<string, unknown>> {
  const pk = json.publicKey
  const cred = (await navigator.credentials.get({
    publicKey: {
      challenge: b64.decode(pk.challenge),
      rpId: pk.rpId,
      timeout: pk.timeout,
      userVerification: pk.userVerification,
      allowCredentials: pk.allowCredentials.map(descriptor),
    },
  })) as PublicKeyCredential | null
  if (!cred) throw new Error("No credential was presented.")
  const response = cred.response as AuthenticatorAssertionResponse
  return {
    rawId: b64.encode(cred.rawId),
    authenticatorData: b64.encode(response.authenticatorData),
    signature: b64.encode(response.signature),
    clientDataJSON: b64.encode(response.clientDataJSON),
  }
}
