# Deliverability: the domain question

Whether a hireme-sent application mail reaches the recruiter's inbox, rather
than their junk folder, decides between sending from Gmail (and carrying an app
password) and sending from the operator's own domain (no credential at all).
This file records the posture and the open decision. It is not yet settled.

## The posture (checked 2026-10-26)

Applies to `anghel4d.com`, `anoptic.io`, `broadside.tech` and
`hireme.anghel4d.com`, all on Cloudflare DNS and Cloudflare Email Routing.

| Record | Value |
| --- | --- |
| SPF (three apexes) | `v=spf1 include:_spf.mx.cloudflare.net -all` |
| SPF (`cf-bounce.*`) | `~all`, Cloudflare-owned: it carries Email Sending's Return-Path |
| DKIM | selector `cf2024-1` (RSA 2048) for each From domain; selector `cf-bounce` beside it, which is what Email Sending signs with |
| DMARC | `p=reject` on the apexes and on `hireme.anghel4d.com` |
| DMARC reporting | Cloudflare DMARC Management on all three zones: `rua=mailto:<prefix>@dmarc-reports.cloudflare.net` on each apex and on `hireme.anghel4d.com` |
| MX | `route{1,2,3}.mx.cloudflare.net`, catch-all forwards to `matei3d@gmail.com` |

`hireme.anghel4d.com` carries its own `_dmarc` record rather than inheriting the
apex's, because hireme's mail is `From: signin@hireme.anghel4d.com` (the
`MAIL_FROM` in its agenix `hireme-env`). A record at the subdomain overrides the
organizational domain, so it needs the `rua` spelled out itself or its reports
are dropped; it now carries the zone's Cloudflare `rua`, the same one the apex
has. Its DKIM is `cf-bounce._domainkey.hireme.anghel4d.com`, which is selector
`cf-bounce` for `d=hireme.anghel4d.com` — strictly aligned with that From.
Nothing needs an SPF record at the subdomain: the envelope is
`something@cf-bounce.hireme.anghel4d.com`, which has its own.

`-all` is safe because Cloudflare is the only path that sends with an envelope
from these domains; nothing else in the estate runs an MTA
(`nixos-server` has no smtp, msmtp or postfix anywhere in its modules).

DMARC Management was enabled through the `cf` CLI
(`cf email-auth dmarc-reports edit -z <zone> --enabled`), which writes the `rua`
into the existing `_dmarc` record itself and leaves `p=reject` alone. Reports
are visible in the zone's Email Security → DMARC dashboard; nothing arrives by
mail. Without it, `p=reject` with no `rua` is exactly the broken state where a
deliverability failure is silent.

## Why the domain choice is still open

The authentication is as strong as it can be made. What authentication does not
buy is reputation, and three things remain against a switch to sending
application mail as `matei@anghel4d.com`:

1. **Domain age and history.** M365/EOP, Proofpoint and Barracuda weight sending
   history. A young domain, first contact, one message per recipient is the
   textbook junk case; the 25/day cap and a human voice help, they do not
   purchase reputation.
2. **A shared relay pool.** Cloudflare Email Sending sends from shared IPs, so
   its neighbours' behaviour is inherited, and there is no per-tenant feedback
   loop to learn from.
3. **Identity mismatch.** The 137 applications went out as `matei3d@gmail.com`
   (`docs/mail/passthrough.md`: ATSs key candidates by email). A reply arriving
   from a different address is a visible change to a recruiter and a weighted
   signal to a filter. If the sender changes, the identity changes everywhere or
   not at all.

Against those: Gmail SMTP carries the best reputation available, but it costs
the app password — a full-scope bearer credential for the primary mailbox, with
no scopes, no expiry, and a deprecation shadow (`SECURITY.md`).

## Sending from this host: 587, not 465

Found while chasing a link that looked stuck. `smtp.gmail.com:465` times out
from fsn1-2 on IPv4 (checked twice, one A record at a time) while 587 answers;
25 is blocked as well. This is the same Hetzner constraint `nixos-server`'s
README records as why hireme's own notices go over Cloudflare's HTTPS API
rather than SMTP. `Hireme.Gmail.Smtp` had been written for implicit TLS on 465
only, so every send would have burned 60 seconds and failed `{:network,
:timeout}` — and nothing would have said so until the first fire key.

`Smtp` now opens according to the endpoint: 465 implicit TLS, anything else
plain, then EHLO, STARTTLS, `:ssl.connect` over the same socket, EHLO again
(RFC 3207 forgets the first), then the unchanged AUTH PLAIN, envelope and DATA.
`Hireme.Gmail.endpoint(:smtp)` defaults to 587 and `endpoint_tls/1` answers
`:implicit` on 465, `:starttls` elsewhere. The fake Gmail speaks both modes
(`smtp_tls:`, STARTTLS by default), so the suite and the deploy's dev check
exercise the path production actually uses.

Proven live on 2026-10-26 through the node's own link, sending as the linked
Gmail address — the mailbox's own, since Gmail refuses a From it does not own:

```
endpoint smtp.gmail.com:587 tls=starttls from=matei3d@gmail.com
deliver  {:ok, "2.0.0 OK … - gsmtp"}  in 2017ms
sent folder  uid 1389
```

Gmail accepted it and filed it in `[Gmail]/Sent Mail`, which is the whole
promise of the Gmail link: the mail lives in the operator's own mailbox as if
written there.

## What is still unproven

The probe I designed earlier — one identical message down both paths to
controlled seed mailboxes, compared on `Authentication-Results` — is still not
built, and it is still the only thing that answers the domain question. What
has changed is that the sending half is no longer a guess: a real message
leaves this host and lands in Gmail's Sent.

The other open item is the first sync. It is not a bug, but it is not gentle
either: linking a mailbox whose All Mail holds 131,032 messages walks the
180-day window (~30,000 envelopes) in about four minutes, and one transient
Gmail drop at 99% costs a backoff and a retry before `live`. The row says
`linking` for all of it, with no progress, which reads exactly like a hang.
Progress (`last_uid` against `listed`) is not in the replica projection, so the
lens has nothing to show; that is the next thing to fix here.
