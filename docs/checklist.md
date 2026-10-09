# Verification checklist for agents

What to fuzz and what to assert on the account, session, key, and
factor surface of this desk. Written for an agent with a shell, the
test suite, and a browser driver; not a click-through. Each block
names the invariant, the inputs worth mutating, and the oracle. A
failed oracle is a finding; file it with the request, the response,
and the commit hash.

Ground truth for policy numbers is `Hireme.Security`; for standards
mapping, `SECURITY.md`. When this document and the code disagree, the
code is the fact and this document is the bug.

## Gate and harness

```
mix format --check-formatted && mix credo --strict \
  && MIX_ENV=test mix compile --warnings-as-errors && mix test
tsc -p assets/tsconfig.json && mix esbuild hireme
```

- `Hireme.DataCase` opens a fresh account on the process and clears
  the Hammer ETS table per test; sandboxed ids repeat, so limiter keys
  collide across tests without that.
- `HiremeWeb.ConnCase` gives a signed-in `conn` and `anonymous/0`.
  `Phoenix.ConnTest` skips CSRF and hands params straight to the
  router; anything about parsers, CSRF, or cookies must go through the
  real endpoint (`test/hireme_web/sign_in_test.exs` posts a urlencoded
  form with `HiremeWeb.Endpoint.call/2` as the model).
- Mail in test is `Swoosh.Adapters.Test`: every delivery arrives in the
  calling process as `{:email, %Swoosh.Email{}}`.
- Time: age a row rather than sleeping. `authenticated_at`, `mfa_at`,
  `last_seen_at`, `expires_at` on `sessions`; `expires_at` and
  `used_at` on `magic_links`; `expires_at` on `mfa_challenges`.
- No property-testing library is a dependency. Add `stream_data` under
  `only: :test` if a generator is worth more than a loop.

Mutation checks that the suite is known to catch (each should turn at
least one test red when applied): drop `:urlencoded` from the parsers;
let `GET /sign-in/email` call `redeem_link`; let a signed-in browser
link through a bare link; remove the `exists(another)` guard from
`unlink/2`; make `fresh?/1` true for no-factor accounts; drop
`code_verifier: true`; accept a callback whose `state` is absent; store
`now` instead of the matched step as `totp_last_used`; skip the
checksum in `ApiKeys.authenticate/2`.

## Tenancy

Invariant: a row written under account A is unreachable under account
B through every read path: the wire session (a browser's or an agent's),
the account routes, mix tasks, and direct `Repo` calls without `put_account`.

- `Hireme.Repo.prepare_query/3` adds `account_id = ?` to every query
  and raises `ArgumentError` with no account on the process. Enumerate
  every `skip_account: true` in `lib/` and justify each: it must be a
  lookup that happens before the account is known (session token, API
  key, identity by provider and subject, magic link) or an explicit
  cross-account write (`revoke_other_sessions`, `list_sessions`).
  Anything else is a finding.
- `Hireme.Schema.tenant/1` refuses inserts without an account. Fuzz:
  every changeset in `lib/hireme/schema.ex` with `account_id` in the
  attrs map from another account; the cast must drop it (whole-field
  casts exclude `:account_id`).
- Every op whose target is owned by B, sent as A: refused `not_found`,
  the same answer as for an id no one owns (existence must not leak).
- A LEASE of B's letterbox on a session authenticated with A's key:
  refused.
- Deltas: with both accounts subscribed, a write under A publishes only
  on `desk:<A>`; grep `Phoenix.PubSub.broadcast` for any topic that is
  not `Hireme.Desk.topic/1`.
- Audit: `Hireme.Audit.recent/1` under B never returns A's events.
- Concurrency: `Task.async` without `Repo.put_account/1` raises; the
  tests pin the account inside the task on purpose.

## Sessions and cookies

Invariant: a session is a server row; the cookie carries only a
256-bit random token; nothing about the cookie can be forged, fixed,
or reused after revocation.

- Cookie `__Host-hireme`: `Secure`, `HttpOnly`, `SameSite=Lax`,
  `Path=/`, `Max-Age` 86400, encrypted and signed by `Plug.Session`.
  Fuzz the cookie value: flip bytes, truncate, replace with another
  session's value, replace with a validly encrypted blob holding a
  random token. Oracle: 401 on JSON, 302 to `/sign-in` on HTML, never
  500.
- Fixation: capture the cookie before sign-in; after sign-in it must
  differ (`configure_session(renew: true)`); after sign-out it must be
  gone and the old value dead.
- Lifetimes: age `last_seen_at` by 3601 s → dead; `expires_at` in the
  past → dead; `revoked_at` set → dead on the very next request.
  Touch happens at most once per 60 s; two requests inside a minute
  must not write `last_seen_at` twice.
- Suspension: set `accounts.status = suspended`; every open session
  dies on the next request; `sign_in_with/3` answers
  `{:error, :suspended}` and the page says so with 403.
- `revoke_other_sessions/1` keeps exactly the caller; concurrent calls
  from two sessions leave at least one alive.
- Pending: a session with `mfa_at = nil` on an enrolled account is
  routed to `/sign-in/factor` by `require_account`; JSON gets 401
  `{"error":"second_factor"}`. A pending session must not read or
  write anything under `/api/` except the factor routes.

## CSRF, headers, parsers

- Every `POST`, `PATCH`, `DELETE` under `/` and `/api` without a valid
  token: 403 (`Plug.CSRFProtection`). JSON takes `x-csrf-token`;
  forms take `_csrf_token`. Fuzz: token from another session, token
  with one byte changed, token in the wrong place.
- `/wire/websocket` without `_csrf_token` in the query, or with a stale
  one, gets no session: it is admitted only as far as an API-key HELLO
  and closed without one.
- `Plug.Parsers` has `:urlencoded` and `:json`; a multipart body or
  an unknown content type must not crash the request (`pass: ["*/*"]`
  means the body is simply not parsed; the controller must then
  refuse, not raise).
- HTML responses carry exactly the CSP in `HiremeWeb.Auth`
  (`script-src 'self' 'wasm-unsafe-eval'`, `frame-ancestors 'none'`, `base-uri 'none'`,
  `object-src 'none'`, `form-action 'self'`), `permissions-policy`,
  `cross-origin-opener-policy: same-origin`, and Phoenix's
  `x-content-type-options`, `x-frame-options`, `referrer-policy`.
  Diff the headers of `/sign-in`, `/sign-in/factor`, `/`, the link
  page, and every page `SignInController` renders.
- The link page (`GET /sign-in/email?token=`) adds `cache-control:
  no-store` and `referrer-policy: no-referrer`.
- Production (`config/prod.exs`): `force_ssl` with `rewrite_on:
  [:x_forwarded_proto]`; assert the 301 and the HSTS header behind
  the proxy.

## Magic links

Invariant: a link proves control of one address, once, within ten
minutes, and does nothing else by itself.

- Token: 32 bytes from `:crypto.strong_rand_bytes`, base64url without
  padding (43 chars); only `sha256(raw)` is stored. Assert the
  `magic_links` table holds no value that base64url-decodes to a
  token that was mailed.
- `peek_link/1` never writes. `redeem_link/2` spends with one
  `UPDATE ... WHERE used_at IS NULL`; fire 20 concurrent redeems of one
  token and expect exactly one `{:ok, _}`.
- Expiry boundary: `expires_at` = now → invalid; now + 1 s → valid.
- Address normalization (`Accounts.normalize_email/1`): trim,
  downcase, `\A[^\s@]+@[^\s@]+\.[^\s@]+\z`, at most 254 bytes. Fuzz:
  CR/LF inside (header injection into the mail), unicode and RTL
  characters, `+` addressing, trailing dots, 255 bytes, empty, nil,
  a list, a map. Oracle: `{:error, :invalid}` or a normalized string,
  never an exception, never a mail with a folded header.
- Enumeration: the response to `POST /sign-in/email` for an address
  with an account and for one without must be byte-identical apart
  from the address itself, and the timing within noise.
- Limits: `link_address` 5 per 10 min, `link_peer` 20 per 10 min,
  `redeem_peer` 20 per 10 min; the sixth and twenty-first answer 429.
  Confirm the limiter key is `"<policy>:<key>"` so an address and a
  peer never share a bucket.
- Peer identity is `conn.remote_ip`; there is no `RemoteIp` plug.
  Behind a reverse proxy every client shares one bucket. Flag this at
  deployment time; it is a configuration gap, not a code bug.
- A signed-in browser opening a sign-in link gets 409 and the token is
  not spent. A browser with a matching `hireme_expect_email` intent
  (address, account id, under 10 min, signed in as that account, not
  pending) links instead of signing in. Fuzz the intent: wrong
  account id, different address case, pending session, aged `at`.
- `Audit` stores `email_hash` (first 16 hex of sha256) and `domain`
  for `:link_requested` and `:link_redeemed`, never the address.
- Logs: `config :phoenix, :filter_parameters` covers `token`, `code`,
  `state`, `email`, `password`, `secret`. Grep a full run's log for
  any mailed token, any six-digit code that was submitted, and any
  address.

## OAuth (GitHub, X)

Invariant: a callback is accepted only for the trip this browser
started, once, within ten minutes, with the code bound by PKCE.

- `HiremeWeb.SignIn.begin/3` stores `{provider, params, mode,
  account_id, at}` in the encrypted session; `finish/3` deletes it
  before judging. Fuzz the callback: no `state`, `state` from another
  session, `state` replayed after success, `code` missing, `provider`
  not configured (404), `provider` configured but a different one than
  the trip's, trip aged past `magic_link_ttl`, `error=access_denied`.
  Oracle: a redirect with `?error=failed` or `?error=denied` (or
  `link_error=` when signed in), an audit `:sign_in_refused` with the
  reason, and no session or identity written.
- PKCE: `code_verifier: true` is in every config; a token request
  without the verifier must fail at the provider. Mock the provider
  (the suite's `http_adapter` hook) and assert the verifier is sent.
- `redirect_uri` is built from `HiremeWeb.Endpoint.url/0`; send a
  forged `Host` header and assert the authorize URL does not change.
- Claims: only `sub` (as the subject) and `preferred_username`. Assent
  casts an integer `sub` to a string; an empty or missing `sub` is
  `{:error, :claim}`. No provider email is read; assert no identity
  with `provider: :email` is ever created by an OAuth callback.
- Link mode: starts only from `POST /api/account/identities` in the
  `:step_up` block; a bare `GET /auth/:provider` while signed in
  redirects to `/` without storing a trip. A link callback where the
  signed-in account differs from the trip's `account_id`, or is
  pending, is refused as `:state`.
- `link/3` with a subject already on another account: `{:error,
  :taken}`; same subject on the same account: idempotent `{:ok, _}`
  with the display refreshed.
- Display: `String.slice(display, 0, 100)`; fuzz handles with CRLF,
  `<script>`, RTL overrides, and 100+ code points; the settings page
  must escape them and the notice mail's subject must not fold.

## TOTP

Invariant: a code is accepted once, in its own 30-second step, with
one step of grace either side, and the secret never rests in clear.

- Enrolment challenge: sealed with `Plug.Crypto.encrypt` under
  `:secret_key_base`, one `mfa_challenges` row per session and kind,
  single-use, 300 s. Fuzz: confirm with the challenge of another
  session; confirm twice; confirm after 301 s; confirm with a code
  from a different secret.
- `totp_last_used` records the matched step, not the clock. Property:
  for any secret and any step `s` in `{now-1, now, now+1}`, a code
  accepted at `s` is refused at every step `<= s` afterwards, and the
  code for `s+1` is still accepted.
- Codes two steps away in either direction are refused.
- Input normalization strips spaces; fuzz non-digits, 5 and 7 digits,
  unicode digits, empty, nil.
- Limits: `mfa_account` 10 per 15 min across all factors of the
  account; the eleventh attempt, right or wrong, is `:rate_limited`.
  `consecutive_failures` reaches 100 → `disabled_at` set, audit
  `:mfa_method_locked`, notice `:authenticator_disabled`; a disabled
  method is skipped by `verify_totp/3` and listed as such.
- At rest: `mfa_methods.totp_secret` must not base32-decode to the
  secret that was shown; `Security.unseal/2` with a different key
  must fail.
- Secret display: the `otpauth://` URI and the SVG are only in the
  `begin_totp/2` reply, never persisted.

## WebAuthn

Invariant: user verification on every ceremony, challenge bound to the
session and spent once, counter monotonic, credential bound to one
account.

- Registration options: `rp.id` is the host, `userVerification:
  "required"`, `residentKey: "preferred"`, `pubKeyCredParams` are
  `[-8, -7, -257]`, `excludeCredentials` lists every credential the
  account already has.
- Forge the response: random `attestationObject`, valid CBOR with the
  wrong `rpIdHash`, `clientDataJSON` with `type: webauthn.get` during
  registration, a different `challenge`, a different `origin`, flags
  without UV. Oracle: `{:error, :attestation}` or `{:error,
  :assertion}`, never a raise (the `wax_` bang functions are rescued
  at the boundary in `Hireme.Mfa.WebAuthn`).
- Challenge: taken once; a second confirm with the same challenge is
  `{:error, :challenge}`; a challenge from another session is refused.
- Assertion: `allowCredentials` lists only this account's credentials;
  an assertion with a credential id owned by another account is
  refused.
- Sign count: replay an assertion with a counter equal to or lower
  than the stored one → the method is disabled with reason `:clone`,
  audited and notified. A counter of 0 on both sides (authenticators
  that do not count) must not trigger it.
- `backup_eligible` and `backed_up` are stored from the flags and
  shown as "passkey, synced" versus "security key"; they are not
  trusted for anything else.
- Origin: `config :wax_, origin` per environment; a mismatch (test
  `www.example.com` against a `localhost` client) is refused.

## Recovery codes

- Ten codes of 16 symbols from a 32-symbol alphabet (80 bits), shown
  once, stored as salted sha256. Assert the `recovery_codes` table
  holds nothing that matches `[a-z2-9]{16}`.
- Normalization: case-insensitive, dashes optional, whitespace
  stripped. A used code is refused forever; `recovery_codes_left/0`
  decrements by one per use; the use is audited and notified with the
  count left.
- `recovery_codes!/1` replaces the set: every old code must be refused
  immediately after.
- Removing the last factor deletes every code; `required?/1` turns
  false; a new session is no longer pending.
- Attempts count against the same `mfa_account` limit as TOTP.

## Step-up

Invariant: every route in the router's `:step_up` block is refused
with 403 `{"error":"step_up"}` unless `Hireme.Mfa.fresh?/1`.

- Enumerate the block (`mix phx.routes`): keys create and revoke,
  sessions revoke-others, every `/mfa/*` write, identities link and
  unlink. Call each with a stale session and assert 403 before any
  side effect (no row written, no mail).
- Freshness: with a factor, `mfa_at` within 300 s; without one,
  `authenticated_at` within 300 s. Age both and assert the flip at the
  boundary. A stale no-factor account cannot step up with a code (it
  has none); the only path is a new sign-in.
- Step-up routes (`/api/account/step-up/*`) require a non-pending
  session; a pending session must not be able to mark `mfa_at` through
  them (that is the factor page's job).
- The shell retries exactly once after a proof; fuzz by proving and
  then failing the retried request (revoke the key between) and
  assert no duplicate action.

## API keys and agent sessions

Invariant: a key reaches one account; a wrong key is refused at HELLO
with no detail; the secret rests only as a hash.

- Shape `hm_<12 base62>_<43 base62><6 base62 CRC32>`; fuzz the
  checksum (one char changed anywhere in the 55-char tail) and assert
  refusal before any database read (observe query count or time).
- Comparison is `Plug.Crypto.secure_compare` on hashes, length-checked;
  a key of the right id with a wrong secret and one with a wrong id
  must take the same time within noise.
- `expires_at` in the past, `revoked_at` set, account suspended: all
  refused at the next HELLO. Known gap to confirm and file: a session
  that is already open is not torn down on revoke or expiry until it
  closes (the browser session rechecks its own every minute; confirm
  the agent session does the same for its key).
- Transport: the key travels only in the agent's HELLO on its wire
  session, through the gate or `/wire`, never in a header; fuzz a HELLO
  with a malformed key, with two keys, and with a browser ticket in its
  place.
- Cap: 100 live keys per account; the 101st `create/3` is refused.
  Concurrency: 20 parallel creates at 99 must leave at most 100.
- `last_used_at` is written at most once a minute per key.
- Limit `api_key_peer`: 20 failures per minute per peer; a valid key
  from the throttled peer is refused until the window passes. Same
  proxy caveat as magic links.
- Display: `prefix` (4 chars after `hm_`) only; the JSON never carries
  the secret after the create reply.
- Notices: create and revoke mail every email identity.

## Identities and the account page

- `unlink/2` is one `DELETE ... WHERE id = ? AND EXISTS (another)`;
  fire concurrent unlinks on an account with two identities and assert
  at least one survives. `{:error, :last}` with one; `{:error,
  :not_found}` for an id on another account.
- `sign_in_with/3` on a never-seen subject creates account and
  identity in one transaction; two parallel first sign-ins with the
  same subject leave one account and one identity.
- Settings JSON shape: `account`, `keys`, `sessions`, `security`
  (`methods`, `recovery_codes_left`, `fresh`), `identities`,
  `sign_in_methods`. Nothing in it is a secret: grep the response for
  `hm_`, base32, or a 43-char base64url string.
- XSS: key names, method names, identity displays, and the `?linked=`
  and `?link_error=` query values are rendered by the shell's escaping
  template tag or mapped through a fixed table. Fuzz each with
  `<img src=x onerror=alert(1)>`, `"onmouseover=`, and `javascript:`
  and assert the DOM contains text, not nodes.

## Mail

- Every message is plain text, from `config :hireme, :mail_from`, with
  a subject starting `Hireme:` for notices. Subjects interpolate a key
  name, a method kind, or an identity display: fuzz those with CRLF,
  very long strings, and non-ASCII, and assert the SMTP conversation
  (or the `%Swoosh.Email{}` in test) shows one subject header,
  RFC 2047 encoded where needed.
- `Accounts.notify/3` mails every `provider: :email` identity of the
  account and records `:notified`; an account with no email identity
  still gets the audit row.
- Production SMTP (`config/runtime.exs`): `verify: :verify_peer`,
  system `cacerts`, SNI, https hostname match, `depth: 99`, TLS 1.2 or
  1.3; port 465 is implicit TLS (`ssl: true`, `sockopts`), any other
  port is STARTTLS `:always` (`tls_options`, empty `sockopts`).
  Prove it with `:gen_smtp_client.open/1` against the real relay with
  `auth: :never`, which sends nothing.

## Rate limiter

- `Hireme.RateLimit` is Hammer on ETS, per node. Policies and keys are
  `Hireme.Security.limit/2` only; grep `lib/` for `RateLimit.hit` and
  expect exactly one call site.
- Named policies: `link_address`, `link_peer`, `redeem_peer`,
  `mfa_account`, `api_key_peer`. Assert each cap at the boundary and
  that windows do not bleed between names.
- Multi-node deployments need a shared backend; a single-node deploy
  is the stated limit.

## Configuration and release

- `SECRET_KEY_BASE` present and 64+ bytes; `:secret_key_base` under
  `:hireme` is what seals TOTP secrets and challenges, so rotating it
  invalidates every enrolled app and every in-flight ceremony. File
  that as an operational note, not a bug.
- `PHX_HOST` drives `check_origin`, the WebAuthn origin, the OAuth
  `redirect_uri`, and mailed link URLs; one wrong host breaks all four.
- `SMTP_HOST` is required in prod; the release must refuse to boot
  without it.
- `/dev/sign-in` and `/dev/mailbox` are behind `compile_env
  :dev_routes`; assert 404 in a prod build.
- `mix assets.deploy` then `mix release`; the digest manifest exists;
  the WASM and `factor.js` are served with long-cache digested names.

## What is deliberately out of scope

- A compromised browser, OS, or host.
- A signed-in person acting against their own account.
- Login CSRF through a sign-in link opened by someone other than the
  asker: the page names the address before the button spends it, and
  linking is never affected. Documented in `SECURITY.md`.
