# Security

How Hireme keeps one account's desk its own, and what it answers to. Standards are cited by the editions in force on 2026-10-07: NIST SP 800-63B-4 (final, July 2025), OWASP ASVS 5.0, CIS Controls v8.1, W3C WebAuthn Level 3 (Recommendation, 2026-08-25), RFC 6238, and for OAuth RFC 9700 (Security Best Current Practice, January 2025) and RFC 7636.

## Threat model

Assets: the applications, CVs, lanes, letterboxes, and keys that belong to an account. Actors: a browser signed in to an account, an agent holding one of its API keys, and everyone else. Threats answered here: a stolen or guessed credential, a replayed code, a forged request from another origin, a cloned authenticator, a leaked key, a leaked database, one account reading another. Out of scope: a compromised browser or operating system, a compromised host, and a signed-in person acting against their own account.

## Tenancy

Every row names its account. `Hireme.Repo` adds `account_id = ?` to every query from the account on the process and refuses to run one without it; an insert that names no account is refused. A key or session yields exactly one account, and there is no request path that sets the account from user input. Only schema migrations, preloads, and the explicitly marked lookups that resolve a session or key run unscoped.

## Sign-in

Passwordless. The ways in are a link mailed to an address, GitHub, and X. The first sign-in by any of them makes an account; an account may add any number and remove any but the last. Email is a primary factor only: 63B-4 does not permit email as an out-of-band authenticator (Sec. 3.1.3.1), so a link never counts as a second factor, and an account with one enrolled still owes it after the link.

A mailed link carries a 256-bit random token; the server keeps its SHA-256 and the address it was sent to. It works once, for ten minutes, for that address only. Opening it is a GET that shows the address and spends nothing, so a mail scanner that follows every link leaves it good; the page's button, a POST with the page's CSRF token, spends it, and spends it atomically, so two clicks cannot both succeed. The token rides in the query, never the path, and `token` (with `code`, `state`, and `email`) is filtered from the log, so no request line records it; the page is `no-store` and sends no referrer. An address is normalised once, trimmed and lowercased. Any well-formed address gets the same answer whether or not an account has it. Requests are limited to five per address and twenty per peer in ten minutes, and redemptions to twenty per peer. Link URLs and OAuth redirect URIs come from the configured host, never the request's `Host`.

GitHub and X use the OAuth 2.0 authorization code flow with PKCE (S256) and a `state` held in the browser's encrypted session cookie, spent on the first callback and good for ten minutes (RFC 9700 Sec. 2.1, 4.7; RFC 7636). Redirect URIs are registered for exact match. X is a confidential client that authenticates with HTTP Basic, GitHub with its client secret. GitHub is asked for no scope and X for `users.read tweet.read`, enough to read the user's id and handle. The provider's immutable user id is the identity; the handle is only shown. Nothing a provider says about an email address is read, so no account is reached, made, or joined through an address a provider asserts (account pre-hijacking).

Adding a way in starts on the Account page, behind step-up. A mailed link adds an address only when it is opened in the browser that asked, signed in as the account that asked, within ten minutes. A signed-in browser that opens any other link is told to sign out first, and the link stays good, so neither a victim's address nor an attacker's can be joined to an account by getting a signed-in browser to open a link. A GitHub or X round trip that adds a way in carries the account that started it and finishes only in that browser, still signed in as that account; a bare GET of `/auth/<provider>` only ever signs a visitor in. An identity that belongs to another account is refused. Removing one needs step-up and the last one stays; afterwards the Account page offers to end every other session (ASVS 7.4.3). Binding and removing are audited and mailed to every address on the account, and a removed address hears it too (63B-4 Sec. 4.1.2). A refused callback is audited with its reason (CIS 8.2, 8.5).

A browser holds one session cookie, `__Host-hireme`: Secure, HttpOnly, SameSite=Lax, encrypted and signed, carrying a 256-bit random token whose SHA-256 is the session row (ASVS 7.2.1, 7.2.2, 3.3.1). Sessions end after 24 hours or an hour idle, and the Account page lists and revokes them (63B-4 Sec. 4.2.3 AAL2 reauthentication; ASVS 7.4). Signing out, or revoking the other sessions, deletes the rows, so a copied cookie is dead on the server side (ASVS 7.4.1).

## Second factor

Enrol an authenticator app, a passkey held in an Apple, Google, or other platform keychain, a roaming security key such as a YubiKey, or any mix. Never SMS, never email (63B-4 Sec. 3.1.3.1 restricts the one; email is not an authenticator at all). With any factor enrolled, a new session owes it before anything else is served, and every sensitive change on the Account page asks for one presented in the last five minutes (ASVS 7.5.1, 7.5.3). An account with no factor steps up by signing in again: its sensitive changes need a sign-in from the last five minutes.

| Factor | Standard | What is checked |
| --- | --- | --- |
| Authenticator app | RFC 6238; 63B-4 Sec. 3.2.9 single-factor OTP; ASVS 6.5.1, 6.5.5 | SHA-1, 6 digits, 30-second step, one step of grace either side. The matched step is recorded, so a code is good once. The secret is sealed at rest with the application key. |
| Passkey or security key | WebAuthn L3; 63B-4 Sec. 3.2.5 multi-factor cryptographic authenticator; ASVS 6.6 | User verification required at registration and every assertion, so the device's own PIN or biometric is the activation factor. Algorithms Ed25519, ES256, RS256. Origin and RP ID pinned to the host. A signature counter that fails to advance disables the credential as cloned (WebAuthn L3 Sec. 6.1.1). Attestation is not demanded, so syncable passkeys are accepted: that is AAL2, not AAL3. |
| Recovery codes | 63B-4 Sec. 3.2.4 look-up secrets; ASVS 6.5.2, 6.5.4 | Ten codes of 80 bits each, salted and hashed, each spent on use, issued with the first factor and replaceable on demand. |

Attempts on any factor are limited to ten per fifteen minutes per account, and a factor that fails one hundred times in a row is disabled until removed (63B-4 Sec. 3.2.2; ASVS 6.6.3). Each challenge is sealed, bound to its session, single-use, and expires after five minutes. Binding, removing, or disabling an authenticator, using a recovery code, and minting or revoking a key are audited and reported to the account through `Hireme.Accounts.notify/3` (63B-4 Sec. 4.1.2 notification of binding; CIS 8.2, 8.5).

The step-up window and the pending state are properties of the session row, so a second browser cannot inherit them.

## API keys

An agent holds a named key, `hm_<id>_<secret><check>`: a 12-character public id, a 43-character base62 secret (256 bits) and a 6-character checksum so a mistyped key is refused before any lookup. The server stores the SHA-256 of the secret and shows the secret once (ASVS 7.2.1). Keys may expire, are revocable at once, and are capped at one hundred per account. Authentication happens at the websocket upgrade from the `x-api-key` header or the `base64url.bearer.phx.<base64 key>` subprotocol; a wrong, revoked, expired, or foreign key is refused without detail, and a peer address is limited to twenty failures a minute. Comparison is constant-time. A key reaches its own account and nothing else.

## Requests

Every state-changing browser request carries the page's CSRF token; the feed websocket carries it in the upgrade query (ASVS 3.5). The pages are served with a Content Security Policy that allows scripts and connections only from the origin, no framing, no object embedding, and a `base-uri` of none; a Permissions-Policy that denies camera, microphone, geolocation, and payment; and a Cross-Origin-Opener-Policy of same-origin, alongside Phoenix's secure browser headers (ASVS 3.4). JSON endpoints refuse any request without a live, factor-complete session with 401 and never redirect.

## Secrets at rest

Session tokens, key secrets, and recovery codes are stored only as hashes. TOTP secrets and pending challenges are sealed with the application secret, so a database copy alone does not yield a working factor. The application secret comes from `SECRET_KEY_BASE` in production.

## Policy numbers

Lifetimes and caps are in `Hireme.Security`. Each rate limit is written at the one call that applies it, through `Hireme.Security.limit/3`.

| Policy | Value |
| --- | --- |
| Session lifetime | 24 hours |
| Session idle | 1 hour |
| Step-up window | 5 minutes |
| Challenge and magic-link life | 5 and 10 minutes |
| OAuth round trip, and an address waiting to be added | 10 minutes |
| Sign-in link requests | 5 per address and 20 per peer in 10 minutes |
| Sign-in link redemptions | 20 per peer in 10 minutes |
| Factor attempts | 10 per 15 minutes per account |
| Consecutive failures before lockout | 100 |
| Key failures per peer | 20 per minute |
| Keys per account | 100 |

## Limits

- The WebAuthn verifier is the `wax_` library, which has not been independently audited; its interface is the only thing this code trusts, and its bang functions are rescued at the boundary.
- An account is only as safe as the mailbox and the GitHub or X accounts that sign in to it. A mailed link proves control of a mailbox and nothing more; enrol a second factor.
- A sign-in link opened by someone other than the person who asked signs that browser into the asker's account. The page names the address before the button spends it, but a person who does not read it can be signed in to someone else's desk (login CSRF). Adding a way in is never affected.
- Notices go by mail to the addresses on the account. An account whose only ways in are GitHub or X has no address to mail, so its notices are on the audit trail only. Mail is sent on the request path, so a slow relay slows the request that asked.
- The rate limiter is per node, in memory. A multi-node deployment needs a shared backend before the limits hold across nodes.
- GitHub and X are trusted for the user id their own API returns over TLS; their account security is outside this desk. Development also offers a one-click sign-in to the local desk, compiled only into the development environment.

## Reporting

Report a weakness by opening a private issue or writing to the maintainer named in the repository. Please do not include another account's data in a report.
