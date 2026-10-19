# Security

How Hireme keeps one account's desk its own, what an agent holding a key
may do with it, and what the design answers to. Standards are cited by the
editions in force on 2026-10-18: NIST SP 800-63B-4 (final, July 2025),
OWASP ASVS 5.0, CIS Controls v8.1, W3C WebAuthn Level 3 (Recommendation,
2026-08-25), RFC 6238, and for OAuth RFC 9700 (Security BCP, January 2025)
and RFC 7636. Every number below lives in `Hireme.Security`, by name; a
call site names the policy it applies, never a number.

## Threat model

Assets: an account's rows (applications, CVs, lanes, the world and mail it
has gathered), its sessions, factors and keys. Actors: a browser signed in
to the account; an agent holding one of its API keys, possibly confused or
prompt-injected by the text it reads; and everyone else. Answered here: a
stolen or guessed credential, a replayed code, a forged cross-origin
request, a cloned authenticator, a leaked key, a key doing more than its
masks allow, a leaked database, one account reading another. Out of scope:
a compromised browser, operating system or host, and the signed-in
operator acting against their own account.

## Tenancy

Every account-owned row names its account. `Hireme.Repo` adds
`account_id = ?` to every query from the account named on the process
and raises on a query with none; the few lookups that must run before the
account is known (a session or key resolved by its secret, a magic link)
say `skip_account: true` on purpose. A session or key yields exactly one
account, and no request path sets the account from user input. One
sequencer per account is the only writer of the account's desk, world,
mail, lanes and corpus rows; its `system` rows are written by the modules
that own them (accounts, keys, factors, the trail, the outbox).

## Sign-in

Passwordless: a link mailed to an address, GitHub, or X. The first sign-in
by any of them makes an account; an account may add any number of ways in
and remove any but the last. Email is a primary factor only (63B-4 Sec.
3.1.3.1 does not allow it as an out-of-band authenticator), so a link never
counts as a second factor.

A mailed link carries a 256-bit random token; the server keeps its SHA-256
and the address. It works once, for ten minutes. Opening it is a GET that
shows the address and spends nothing, so a mail scanner that follows every
link leaves it good; the page's button, a POST with the page's CSRF token,
spends it atomically. The token rides in the query, is filtered from the
log with `token`, `ticket`, `code`, `state`, `email`, `key` and `secret`
(and the host's proxy logs a request's path, never its query; its error
log can still carry a mailed link's token for that link's ten-minute life),
and the page is `no-store` with no referrer. The link itself is never
written to a table: it lives in the sending task's memory only. Any
well-formed address gets the same answer whether or not an account has it.

GitHub and X use the authorization code flow with PKCE (S256) and a
`state` in the browser's encrypted cookie, spent on the first callback and
good for ten minutes (RFC 9700 Sec. 2.1, 4.7; RFC 7636). Redirect URIs come
from the configured host, never the request. The provider's immutable user
id is the identity; nothing a provider says about an email address is
read, so no account is reached or joined through an asserted address
(account pre-hijacking).

Adding a way in starts in the account lens behind step-up. A mailed link
adds an address only in the browser that asked, signed in as the account
that asked, within ten minutes; any other signed-in browser is told to sign
out first and the link stays good. A GitHub or X round trip that adds a
way in finishes only in the browser and account that started it. Binding
and removing are audited and mailed to every address on the account, and a
removed address hears it too (63B-4 Sec. 4.1.2).

## Sessions

A browser holds one cookie, `__Host-hireme`: Secure, HttpOnly,
SameSite=Lax, path `/`, no Domain, encrypted and signed, carrying a 256-bit
token whose SHA-256 names the session row (ASVS 7.2.1, 3.3.1). A session
ends after 24 hours, or one hour idle (63B-4 AAL2 reauthentication; ASVS
7.3). The row is read with its account on every request, so a revoke or a
suspension takes effect on the next request and ends the session's wire
sessions at once (BYE `revoked`, BYE `suspended`). The account lens lists
sessions and revokes any of them; signing out revokes the row, so a copied
cookie is dead on the server, and answers `Clear-Site-Data: "storage"`, so
the desk snapshot the browser kept in IndexedDB is gone too; a page
request carrying a cookie whose session ended elsewhere answers the same
(ASVS 7.4.1,
7.4.3).

A page reaches the wire with a ticket, never the cookie: a single-use,
encrypted token naming the session and bound to eight bytes of its token
hash, good for 60 seconds, minted only for a live session past its second
factor. Spending it re-reads the session row. A wire session keeps the
browser session's lifetime: every `account.*` call and the wire's tick
check it, and wire activity counts as activity. A session that owes a
second factor (one was enrolled after it signed in) holds no wire: its
open wire ends when the factor is bound.

## Second factor

An authenticator app, a passkey in a platform keychain, a roaming security
key, or any mix. Never SMS, never email. With any factor enrolled, a new
session owes it before the page, the ticket or any JSON is served; every
sensitive change asks for one presented within five minutes (ASVS 7.5.1).
An account with no factor steps up by signing in again.

| Factor | Standard | What is checked |
| --- | --- | --- |
| Authenticator app | RFC 6238; 63B-4 Sec. 3.2.9; ASVS 6.5.1, 6.5.5 | 6 digits, 30 s step, one step of grace either side; the matched step is recorded, so a code is good once. The seed is sealed at rest with the application key; a seed that does not unseal (the key rotated, a damaged row) matches no code. |
| Passkey or security key | WebAuthn L3; 63B-4 Sec. 3.2.5; ASVS 6.6 | User verification required at registration and every assertion. Ed25519, ES256, RS256. Origin and RP ID pinned to the host. A counter that fails to advance disables the credential as cloned (WebAuthn L3 Sec. 6.1.1). Attestation is not demanded, so syncable passkeys are accepted: AAL2, not AAL3. The user handle is an opaque per-account value, not the account id. |
| Recovery codes | 63B-4 Sec. 3.2.4; ASVS 6.5.2, 6.5.4 | Ten 80-bit codes, salted and hashed, each spent once (atomically), issued with the first factor and replaceable behind step-up. |

Factor attempts are limited per account, and a factor that fails one
hundred times in a row is disabled (63B-4 Sec. 3.2.2; ASVS 6.6.3). A
disabled factor, worn out or cloned, still counts as the account having
one: new sessions stay pending and only a recovery code (or another live
factor) lets one in, so wearing a factor out is never a way past it. An
account that has lost its factors and its codes is recovered by the
operator, not by the desk. Each
ceremony's challenge is sealed, bound to its session, deleted by the
statement that takes it, and expires after five minutes. Binding, removing
or disabling a factor and using a recovery code are audited and mailed.

## Keys and masks

An agent holds a named key, `hm_<id>_<secret><check>`: a 12-character
public id, 43 base62 characters of secret (about 256 bits) and a CRC
checksum, so a mistyped or invented key is refused before any lookup. The
server keeps the secret's SHA-256 and shows the secret once. A key
expires if asked to, is revocable at once, and an account holds at most
one hundred live, unexpired ones. A key's name, which notices mail, holds
no control or format character. An agent presents its key once, in its
wire session's HELLO, never in a URL; every failure looks the same, and a
peer is limited in failed attempts per minute (a throttled HELLO is told
to retry later; successes never spend the budget).

What a key may do is two masks over the five domains, world 1, desk 2,
mail 4, lanes 8, corpus 16, and `may_delete`:

- `read_mask` bounds BOOT and PATCH: a table outside it is never sent,
  and every read is the client's own replica of what was sent.
- `write_mask` bounds every op (`scope`); a `drop` also needs `may_delete`.
- The presets are read only, write only and read/write; anything else is
  custom. A write-only key's BOOT carries no table.
- `system` tables (accounts, sessions, identities, keys, factors, the
  trail, the outbox, the ledger) and `trusted_hosts` are in no mask: no
  key reads or writes them. `citations` replicates under the world read
  bit, and only the server writes it.
- A key never mints, widens or revokes keys: only a browser session can
  call `account.*`, and minting, widening a mask and granting
  `may_delete` need that session stepped up. Narrowing does not.
- Any change to a live key's masks ends its wire sessions with BYE
  `grants`, so the next HELLO carries the new masks; a revoke ends them
  with BYE `revoked`. Minting, widening and revoking are mailed.
- A `human_only` command (naming open fire) and `human_only` columns are
  refused to any key (`human_only`): FIRE HOLD is a human act.

## Leases

A wire session writes only while it holds the lease: taking it opens the
write channel for the domains in its key's write mask (a browser session
holds one implicitly, with every domain), and a write without it is
refused `lease_missing`. Claims are explicit application ids, at most
1,000 per request, and taking one needs both read and write on the desk,
so two agents do not work one application at once: an agent's write to an
application another session holds is refused `leased`, with that
session's label. The operator's browser session is never refused
`leased`: the owner's write lands, and the claiming agent receives it as a
PATCH. A lease lives exactly as long as its session: release, disconnect,
a revoked key, a mask change, a suspended account, or the operator's revoke
in the account lens. There is no TTL.

An operator lease revoke pauses that key: until you resume it from the
account lens, none of its sessions may open the channel or claim
(refused, "paused by the operator"), however often the agent reconnects.
Resuming a key needs a step-up. A key revoke stops it for good.

## Carrier

Liveness is the carrier. Each side sends PING every **15 seconds**; a
session that hears no frame for **45 seconds** ends, and its lease with it.
The same holds over WebTransport through the gate and over the `/wire`
WebSocket. Frames are length-prefixed and bounded: one frame is at most
16 MiB (larger closes the carrier), one OPS frame at most 256 ops, and one
op at most 1 MiB of text (`too_large`); a client fills frames by bytes as
well as by count.

## Writes

Every write is a `put`, `drop` or `command`, judged in order by the
account's sequencer: grant, lease, shape, domain, provenance, limits. A
refusal rolls back exactly its own op. Cells are typed on the wire and
never cast from strings; a day counts from 0000-01-01 (0 to 3,652,424,
9999-12-31) and one outside that range is refused `type`. Each key may write 600 ops per wall-clock minute
(`agent_write`; a fixed window, so a burst straddling a minute boundary
can land up to 1,200 in a moment). The ledger keeps each writer's ACKs for
24 hours: an ACKed op id resent, whatever it now carries, answers its first
ACK and writes nothing; a refused op id is not kept, so resent it is judged
afresh. Every agent op batch leaves one row on the trail naming its key,
with its counts, until the account's activity budget is spent; past it the
batches are counted into the window's coalesced row instead.

Provenance is server-side: a metric needs `as_of` and is never older than
the stored one; prose needs a source and the row's current revision; a
source's host is derived by the server from its URL, which must name a
real hostname, never taken from the writer; a source's identity (URL,
publisher, title, kind) is fixed once written, so no later write can
rewrite the citations that name it; a put that restates its row exactly
(every cell as stored and, for a cited cell, the same `as_of` and the
source of its last citation) writes nothing, so a re-run cannot inflate a
cell's citations, while the same value from another source is still cited,
as corroboration; culture and ratings need a host on the
operator's trusted list, which only the operator edits, from a browser,
stepped up. A JSON value's integers must fit in 64 bits. A refusal never
carries a stored value from a table the key cannot read.

## Text an agent reads

Raw text (a listing, a message body, any prose) is returned by
`hireme-mcp` marked untrusted. It is data, not instructions; an agent's
masks and lease bound what any instruction hidden in it could cause.

The browser kernel's text-keyed hash maps (company names, ATS tenants, the board's distinct texts) are seeded per kernel instance from crypto.getRandomValues (the wasm module's one import, host.random_u32; natively from the OS RNG), so agent-written text cannot craft colliding keys to slow a derive.

## Requests

Behind the host's nginx every request arrives from loopback; from
loopback only, nginx's `X-Real-IP` (which it overwrites with the
connecting address) names the client, so per-peer limits and the trail
see real peers. `X-Forwarded-For` is never read. A per-peer limit counts
an IPv6 peer by its /64, since one host holds a whole /64.

Every state-changing browser request carries the page's CSRF token. Pages
are served with a Content Security Policy: scripts from the origin plus
the inlined early script by its hash, WebAssembly compilation but never
`eval`, styles from the origin only, connections to the origin and the
gate, no framing, no objects, `base-uri 'none'`, forms to the origin.
Alongside it a Permissions-Policy denying camera, microphone,
geolocation, payment and USB, same-origin opener and resource policies,
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and no
cross-domain policies (ASVS 3.4). JSON endpoints answer 401, 403
or 409 with a code and never redirect.

## Secrets at rest

Session tokens, key secrets and recovery codes are stored only as hashes;
TOTP seeds and ceremonies in flight are sealed with the application
secret, so a copy of the database alone yields no working credential.
The application secret, the release cookie and the mail token come from
the host's vault at runtime, never the store or the repository.

## Backups

The node copies its database once a day (`VACUUM INTO`, after the day's
purge) to `backups/` beside it, `/var/lib/hireme/backups/` on a server, as
`hireme-v2-<UTC stamp>.db`: the directory mode 0700 and each copy 0600,
owned by the service's user. It keeps the newest 13 of its own and deletes
older ones, and a copy a stop cut short. A copy holds what the database
holds: the trail, hashed tokens and secrets, and sealed TOTP secrets
(their key is in the environment, not the copy). v1's backups,
`hireme-<stamp>.db` (old accounts, hashed tokens, sealed secrets), do not
carry v2's prefix and are never pruned: they stay until the operator
deletes them.

## The trail

Append-only (`audit`), its rows never edited (they name keys and
sessions by id, so a purge of either rewrites nothing): every sign-in,
refusal, session, factor, key,
identity and lease event, every key HELLO, and one row per agent op
batch, each with its time, kind, key or session, and the address and
user agent of the request or wire connection that caused it, where one
did (CIS 8.2, 8.5); a lease the sequencer ends by itself carries no
address. A
sign-in link request is recorded by a hash of the address and its domain,
since the asker may be a stranger; the hash stays on the server, and the
account lens is never sent a row's meta key, at any depth, naming a hash,
secret, token, code, password or passwd, an API, private, signing or
session key, a credential, a bearer, a cookie, a JWT or an OTP; the one
exemption is a coalesced row's counts (kind, key, integer), which pass by
their shape. The lens's own allowlist of the fields it shows is the real
control. Notices go to the account's addresses
through a durable outbox with bounded retries.

Past its budgets an account's activity is not written row by row: the
window's events become one `activity_coalesced` row (or
`revokes_coalesced` for lease revokes) when the window closes, holding the
counts by kind and key and the distinct addresses and user agents they
came from (20 of each named, the rest counted, up to 1,000 tracked a
window; events from any past those are counted as such). A key's HELLO from a peer
(an IPv6 address counts by its /64) it has not used in the window is its
own row, for the first 50 peers of the key in the window, so which
addresses held a key is not only a count. The counts are
held in memory until their window closes; they are written as the node
stops, after its sessions and sequencers, but an unclean exit of the VM
loses the open windows' counts.

Security events are kept forever: sign-ins and their refusals, sessions,
factors, identities, keys, mask changes, lease revokes (and their
coalesced rows), keys paused and resumed, suspension and step-up.
Activity is kept 90 days (`Security.activity_retention_days/0`) and then
deleted by the daily purge: an agent's op batches (`agent_ops`),
its HELLOs (`wire_key`, `wire_key_refused`) and its leases opening and
closing (`lease_opened`, `lease_released`). Refused key HELLOs, which
anyone can cause, are kept 7 days (`Security.refusal_retention_days/0`).
The purge deletes in batches, a pause between, so it never holds the
writer for long.

## Policy numbers

| Policy | Value |
| --- | --- |
| Session lifetime / idle | 24 hours / 1 hour |
| Step-up window | 5 minutes |
| Ceremony challenge / magic link / wire ticket | 5 minutes / 10 minutes / 60 seconds |
| OAuth round trip, and an address waiting to be added | 10 minutes |
| Carrier PING / timeout | 15 seconds / 45 seconds |
| Sign-in links | 5 per address, 20 per peer and 300 in all in 10 minutes |
| Link redemptions | 20 per peer in 10 minutes |
| Factor attempts | 10 per account in 15 minutes |
| Consecutive failures before a factor is disabled | 100 |
| Failed key attempts | 20 per peer a minute |
| OAuth refusals recorded | 20 per peer in 10 minutes |
| Wire tickets | 60 per peer a minute |
| Agent ops | 100,000 per key per wall-clock minute, a circuit breaker for clear abuse, not pacing; a lease's `bulk` contract (1 to 1,000,000 writes for 10 minutes) is outside it, drawn from 5,000,000 per key an hour |
| Agent lease RPCs | 3,000 per key per wall-clock minute |
| Text an account holds | 1 GiB (`accounts.text_bytes`; past it a write is refused `cap`) |
| Rows per table | every stored account table declares a cap; the sequencer enforces it for every table it writes; identities and factors refuse past theirs, keys past theirs (revoked keys count until purged a month on), and sessions make room by dropping the oldest ended ones (refused only when all are live); ceremonies by the daily purge; the outbox holds at most its declared 100,000 rows per account, past which only a digest already pending is counted up (the event stays on the trail); the trail's declared 10M is not enforced: its activity rows expire (refused HELLOs after 7 days, the rest after 90), and its security events, kept forever, grow only as fast as the rate-limited actions that write them |
| Account writes | every account.* call that writes the trail or mails a notice: 60 per account in 10 minutes, charged only when the call wrote (renames have their own 30); revoking a key, a session or a lease is outside it, so the owner can always revoke |
| Notices | 30 events per account in 10 minutes, however many addresses hear each; a factor added, removed or disabled, recovery codes issued or used, or a way in linked or unlinked have 10 more of their own, a key created or widened another 10, and a key's revoke notice spends none; past them, one pending digest per address ("N security changes since ..."), sent when the window ends; every event still lands on the trail |
| Trail activity | per account in 10 minutes: 1,000 activity rows (op batches, leases opening and closing), 600 key HELLOs, 120 lease revokes; 20,000 activity rows for the node, charged only for rows written, past which an account still writes 100 of its own; past them, one coalesced row per window; a revoke itself is never refused |
| Notice rows | 300 per account in 10 minutes (one per address an event reaches); past it, only the per-address digest |
| Ceremonies begun | 30 per browser session in 10 minutes (a TOTP QR, passkey options) |
| Pending notices | within the notice budget, one per linked address per change; each tries 8 times over about two days, then is given up; sent or given-up notices go a month later; the outbox sends round-robin across accounts |
| Trusted host note / passkey transports | 500 bytes / the WebAuthn transport names only |
| OAuth callbacks | 20 per peer and 300 in all in 10 minutes |
| Renames (account and keys) | 30 per account in 10 minutes; renaming to the same name records nothing |
| Names | key: 100 characters and 200 bytes; account: 200 and 400; no control or format characters, no run of over four combining marks |
| Trail activity rows | expire after 90 days |
| Key HELLOs | 60 per key per wall-clock minute |
| Wire sessions open per key / per peer | 16 / 16 |
| /wire upgrades | 300 per peer a minute |
| Refused key HELLOs recorded | 600 a minute in all |
| Live keys per account | 100 |
| Frame / ops per frame / text per op | 16 MiB / 256 / 1 MiB |
| Source URL | 2,048 bytes, refused before any parsing (as a cited put's source and as a `sources` row); a port, when one is written, is ASCII digits up to 65535 (leading zeros allowed), else the URL names no host and is refused |

## Limits

- The WebAuthn verifier is the `wax_` library, not independently
  audited; its bang functions are rescued at the boundary.
- An account is only as safe as the mailbox and the GitHub or X accounts
  that sign in to it. Enrol a second factor.
- A sign-in link opened by someone other than the asker signs that
  browser into the asker's account; the page names the address before
  the button spends it (login CSRF). Adding a way in is never affected.
- An account whose only ways in are GitHub or X has no address to mail;
  its notices are on the trail only.
- Rate limits and spent wire tickets are per node, in memory. A
  multi-node deployment needs a shared backend before they hold across
  nodes.
- Development offers a one-click local sign-in, compiled into the
  development environment only.

## Reporting

Report a weakness by opening a private security advisory on the
repository. Please do not include another account's data in a report.
