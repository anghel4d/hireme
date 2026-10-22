// The signature HiremeWeb.MailInbound verifies: "v1=" + hex HMAC-SHA256(secret,
// "<unix seconds>.<hex SHA-256 of the body>"). Web Crypto only, so it runs the
// same in the Worker and under Bun's tests.

const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("")

export async function signature(secret: string, ts: number, body: ArrayBuffer | Uint8Array): Promise<string> {
  const digest = hex(await crypto.subtle.digest("SHA-256", body))
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return "v1=" + hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}.${digest}`)))
}
