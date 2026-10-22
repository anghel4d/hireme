# The domain pipe: anghel4d.com mail into hireme

The brief's point 3 (`docs/mail/passthrough.md`): anghel4d.com's mail already
forwards to the operator's Gmail through Cloudflare Email Routing's catch-all,
so the Gmail link sees it. The domain pipe adds a second, independent copy: a
Cloudflare Email Worker posts each message, signed, to the node. If Google ever
stops app passwords, the domain's mail still reaches hireme. The node keeps one
copy per Message-ID (`Hireme.Gmail.ingest/3`, rules agreed with the connector):

- **The key:** the Message-ID, stored as given (brackets and case kept); ingest finds it in either form, and the filer lowercases only to compare. Both pipes see the same header bytes, so the two copies carry the same value. With none, a SHA-256 over From, Date, Subject and the first 4 KiB of the decoded body, the same through both pipes (the raw bytes differ: Gmail adds its own headers).
- **Gmail copy after the domain copy:** it fills in what only Gmail knows (thread and message ids, labels, UID), and the message gets the `hireme` label. The domain copy after the Gmail copy is a no-op.
- **Filing:** it happens once, on the first copy. A later copy never refiles a message or moves its links.

## The Worker (`workers/mail`)

For every message it:

1. buffers the raw stream once;
2. starts the node's copy (`deliver`, in `waitUntil`);
3. forwards to the operator's Gmail and awaits it.

The forward is exactly what the catch-all did, and it happens whatever the node answers. A busy or absent node (5xx, 429, no connection) is tried four times over about 40 s. A refusal for good (401, 404, 413, 415, 422) is not retried. The Gmail copy reaches the node anyway through the Gmail link.

The node's copy is a POST of the raw RFC 822 bytes to `https://<host>/mail/inbound/<pipe id>` with:

| Header | Value |
| --- | --- |
| `Content-Type` | `message/rfc822` |
| `X-Hireme-Timestamp` | unix seconds |
| `X-Hireme-Signature` | `v1=` + hex HMAC-SHA256(pipe secret, `"<timestamp>.<hex SHA-256 of the body>"`) |
| `X-Hireme-Envelope-From`, `X-Hireme-Envelope-To` | the SMTP envelope Email Routing vouches for, believed only once the signature holds |

The Elixir and TypeScript tests assert one shared vector, so the two sides cannot drift.

## The endpoint (`HiremeWeb.MailInbound`)

A pipe belongs to one account: the operator enables it in the account lens
(step-up), the node mints a 32-byte secret, keeps it sealed on the mailbox row
(server only) and shows it once. Each refusal carries a JSON body saying why:

| Status | When |
| --- | --- |
| 404 | an unknown or disabled pipe |
| 429 | past `mail_inbound`, 600 per pipe per 10 min |
| 413 | a body over 25 MiB (read under that bound first) |
| 415 | not `message/rfc822` |
| 401 | a missing or wrong signature, or a timestamp more than 300 s off |
| 503 | ingestion is not ready yet or the account is unavailable (`{:error, :not_ready}` or `{:error, :unavailable}`); the Worker retries |
| 422 | ingestion refused the message |

There is no nonce store: a replay inside the window is a duplicate by Message-ID. Nothing here strikes or bans an address, since every request comes from Cloudflare's Worker egress.

## Deploying and cutting over

Secrets are set in a real terminal, never through a chat's `!` prefix, which
uploads an empty value:

```sh
cd workers/mail
npx wrangler@4 deploy
npx wrangler@4 secret put FORWARD_TO    # the verified Email Routing destination
npx wrangler@4 secret put PIPE_URL      # https://hireme.anghel4d.com/mail/inbound/<pipe id>
npx wrangler@4 secret put PIPE_SECRET   # shown once by the account lens
```

1. **Prove it on one address first.** Add an Email Routing rule for a test address (say `pipe-test@anghel4d.com`) with the action "Send to a Worker: anghel4d-mail". Send it mail from outside, and check that it lands in Gmail and that the node shows one message, then a single one again after the Gmail link syncs.
2. **Switch the catch-all.** Change its action from "Send to an email: <Gmail>" to "Send to a Worker: anghel4d-mail". The literal rules stay as they are.
3. **Rollback.** Set the catch-all back to "Send to an email" with the same Gmail destination. The Worker can stay deployed; nothing routes to it.

## Sending as the domain, later

Sending as `matei@anghel4d.com` through Gmail's "Send mail as" relays through
smtp.gmail.com. The mail is then signed `d=gmail.com` and leaves from Google's
servers, so it does not align with anghel4d.com for DMARC. That is acceptable
only while anghel4d.com's DMARC policy is `p=none`.

The aligned route is Cloudflare Email Service's sending for the domain. `wrangler email sending enable anghel4d.com` publishes its DKIM and SPF records, and the domain then gets a DMARC record moving from `p=none` to `quarantine` once reports are clean. That is the setup for cold outreach from the domain, kept apart from the application identity (the Gmail address), as the brief says.
