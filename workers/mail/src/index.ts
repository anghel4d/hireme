// The anghel4d.com Email Worker: every message to the domain goes on to the
// operator's Gmail exactly as Email Routing's catch-all sent it before, and a
// signed copy goes to the node's domain pipe (HiremeWeb.MailInbound), which
// dedupes it against the Gmail link's copy by Message-ID.
//
// Secrets (wrangler secret put, in a real terminal): FORWARD_TO, the verified
// Email Routing destination; PIPE_URL, https://<host>/mail/inbound/<pipe id>;
// PIPE_SECRET, shown once by the account lens when the pipe is enabled.

import { signature } from "./sign"

export interface Env {
  FORWARD_TO: string
  PIPE_URL: string
  PIPE_SECRET: string
}

interface Mail {
  from: string
  to: string
  raw: ReadableStream<Uint8Array>
  forward(rcptTo: string, headers?: Headers): Promise<unknown>
}

interface Ctx {
  waitUntil(p: Promise<unknown>): void
}

// Attempts at the node, and the wait before each retry: a node mid-deploy
// comes back within a minute; past that the Gmail copy still reaches it.
const BACKOFF_MS = [0, 2_000, 10_000, 30_000]

export async function deliver(env: Env, raw: ArrayBuffer, from: string, to: string, fetcher: typeof fetch = fetch, sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))): Promise<number> {
  let status = 0
  for (const wait of BACKOFF_MS) {
    if (wait) await sleep(wait)
    const ts = Math.floor(Date.now() / 1000)
    try {
      const r = await fetcher(env.PIPE_URL, {
        method: "POST",
        body: raw,
        headers: {
          "content-type": "message/rfc822",
          "x-hireme-timestamp": `${ts}`,
          "x-hireme-signature": await signature(env.PIPE_SECRET, ts, raw),
          "x-hireme-envelope-from": from,
          "x-hireme-envelope-to": to,
        },
      })
      status = r.status
      // Taken, or refused for good (a bad signature, a disabled pipe, a body the node will never
      // take): retrying cannot help. Only a busy or absent node is worth another try.
      if (r.ok || (r.status < 500 && r.status !== 429)) return status
    } catch {
      status = 0
    }
  }
  return status
}

export default {
  async email(message: Mail, env: Env, ctx: Ctx): Promise<void> {
    // The raw stream is single use: buffer it once, start the node's copy, then forward.
    // Forwarding is awaited, so a forwarding failure is the handler's failure, never a
    // silent drop; the node's copy does not wait on it.
    const raw = await new Response(message.raw).arrayBuffer()
    ctx.waitUntil(deliver(env, raw, message.from, message.to))
    await message.forward(env.FORWARD_TO)
  },
}
