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

## The probe that settles it

Not built yet. One message, identical bytes, sent through both paths — Gmail
SMTP and `smtp.mx.cloudflare.net:465` — to a fixed set of seed mailboxes the
operator controls (Gmail, Outlook/M365, Yahoo, Fastmail, self-hosted). Compare
per receiver: `Authentication-Results`, `dkim=`, `dmarc=`, `Received-SPF`, the
folder it was filed in, and the raw headers of both copies. That separates a
domain problem from a relay problem from a content problem, which is the
distinction every deliverability argument otherwise blurs.

Decide on the result: clean, and the domain pipe plus Cloudflare sending removes
the app password from the threat model entirely; dirty on M365 only, and Gmail
keeps the sending half.
