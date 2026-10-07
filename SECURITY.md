# Security

How Hireme keeps one account's desk its own, and what it answers to. Standards are cited by the editions in force on 2026-10-07: NIST SP 800-63B-4 (final, July 2025), OWASP ASVS 5.0, CIS Controls v8.1, W3C WebAuthn Level 3 (Recommendation, 2026-08-25), RFC 6238.

## Threat model

Assets: the applications, CVs, lanes, letterboxes, and keys that belong to an account. Actors: a browser signed in to an account, an agent holding one of its API keys, and everyone else. Threats answered here: a stolen or guessed credential, a replayed code, a forged request from another origin, a cloned authenticator, a leaked key, a leaked database, one account reading another. Out of scope: a compromised browser or operating system, a compromised host, and a signed-in person acting against their own account.

## Tenancy

Every row names its account. `Hireme.Repo` adds `account_id = ?` to every query from the account on the process and refuses to run one without it; an insert that names no account is refused. A key or session yields exactly one account, and there is no request path that sets the account from user input. Only schema migrations, preloads, and the explicitly marked lookups that resolve a session or key run unscoped.

## Sign-in

Passwordless. The entry methods are a link to the account's email, GitHub, and X, and an account may link any number of them (ASVS 6.5; 63B-4 does not permit email as an out-of-band authenticator, so the link is the primary factor and never counts as a second). Unlinking a method needs a fresh second factor.

A browser holds one session cookie, `__Host-hireme`: Secure, HttpOnly, SameSite=Lax, encrypted and signed, carrying a 256-bit random token whose SHA-256 is the session row (ASVS 7.2.1, 7.2.2, 3.3.1). Sessions end after 24 hours or an hour idle, and the Account page lists and revokes them (63B-4 Sec. 4.2.3 AAL2 reauthentication; ASVS 7.4). Signing out, or revoking the other sessions, deletes the rows, so a copied cookie is dead on the server side (ASVS 7.4.1).

## Second factor

Enrol an authenticator app, a passkey held in an Apple, Google, or other platform keychain, a roaming security key such as a YubiKey, or any mix. Never SMS, never email (63B-4 Sec. 3.1.3.1 restricts the one; email is not an authenticator at all). With any factor enrolled, a new session owes it before anything else is served, and every sensitive change on the Account page asks for one presented in the last five minutes (ASVS 7.5.1, 7.5.3).

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

All in `Hireme.Security`, so one place states the policy.

| Policy | Value |
| --- | --- |
| Session lifetime | 24 hours |
| Session idle | 1 hour |
| Step-up window | 5 minutes |
| Challenge and magic-link life | 5 and 10 minutes |
| Factor attempts | 10 per 15 minutes per account |
| Consecutive failures before lockout | 100 |
| Key failures per peer | 20 per minute |
| Keys per account | 100 |

## Limits

- The WebAuthn verifier is the `wax_` library, which has not been independently audited; its interface is the only thing this code trusts, and its bang functions are rescued at the boundary.
- An account with no second factor cannot step up, so its sensitive changes need only the live session. Enrol one.
- The second-channel notification is recorded in the audit trail and logged; delivery by mail is pending the mailer.
- The rate limiter is per node, in memory. A multi-node deployment needs a shared backend before the limits hold across nodes.
- Email magic links and the GitHub and X sign-in methods are under construction; until they land, development offers a one-click sign-in to the local desk, compiled only into the development environment.

## Reporting

Report a weakness by opening a private issue or writing to the maintainer named in the repository. Please do not include another account's data in a report.
