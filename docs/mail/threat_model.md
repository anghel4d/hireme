# Threat model: mail, missions and fire keys

What the passthrough (docs/mail/passthrough.md) puts at risk and what answers each risk. SECURITY.md carries the binding summary and the policy numbers; this note is the reasoning behind them. Built on opus-turing's interfaces of 2026-10-22 08:59 (the link handover, the connector, the inbound pipe, the key shape).

## Assets

- **The Gmail app password.** Full IMAP and SMTP access to the operator's primary mailbox: the most valuable secret the node has ever held.
- **The mailbox itself.** Years of unrelated personal mail, of which the job search is a sliver.
- **The power to send.** Mail from the operator's own address to employers, and form submissions in their name: reputation that cannot be taken back.
- **Fire keys.** Authority, bounded in scope and time, to spend that power.
- **The desk's record.** Missions, drafts, reports and threads: what was sent where, and what came back.

## Actors

- The operator in a signed-in browser (the only principal who may link a mailbox or create a fire key).
- Agents holding API keys, through `/mcp` or the local daemon: capable, and possibly confused or prompt-injected by what they read (listings, careers pages, inbound mail, other agents' reports).
- Anyone who can send mail to the operator, or post to the inbound endpoint.
- Google and Cloudflare, trusted for transport and delivery, not for content.

Out of scope: a compromised Google account, browser, OS or host, and the operator acting against their own interest.

## Threats and answers

**T1. The app password leaks.**
It is entered only in the account lens, behind step-up, over the browser's wire RPC (`account.mail.link`): never through MCP, the daemon, a URL, argv, a log line or a chat. The node verifies it with one IMAP LOGIN before storing anything; on failure nothing is stored. At rest it is sealed with the application secret under its own purpose ("hireme mailbox app password"), in a server-only column no key or replica ever carries, so a copy of the database alone yields no credential. The field is never echoed, drafted or kept in browser storage. Unlinking erases the sealed secret and the sync cursor at once. Linking and unlinking are on the trail and mailed, like a key's minting and revoking.

**T2. The node reads more of the mailbox than the search.**
The connector reads envelopes and lets the matcher decide. Only candidates (mail it files, or puts in the unfiled tray) are stored and labelled `hireme`; everything else is read and dropped, never stored, never labelled. The backfill is bounded to 180 days. The node never moves, archives, deletes or marks anything read; its one write to Gmail is adding the label. Logs carry the mailbox id and the server's tagged response code, never a subject, body or address.

**T3. An agent sends without the operator's say-so.**
A write key reaches fire ready and stops. Firing needs a fire key, and only a signed-in, stepped-up browser session creates one. An agent's request-a-key returns a predialed link that only *pre-fills the review*: opening it (a GET) creates nothing, and the page shows every mission's target and full draft. Creating the key is a POST with the page's CSRF token, behind step-up. A key is a grant with a public id, not a secret, so nothing leaks by showing it. The sequencer judges every shot:
- the key is unrevoked and within its window (one week unused, 24 hours from first use);
- the mission is in its scope and not burned;
- the mission's target and draft still hash to what the key froze at creation;
- the account's daily cap (25) is not spent.

A shot moves the mission to in-flight (no re-fire, no edit), burns it on success only, and returns a failure to fire ready under the same key. Before any resend the node searches Gmail for the Message-ID it minted, so a crash never double-sends. Outside that, a send attempt is not an error: the agent is told what happened and how firing works.

**T4. Prompt injection through what agents read.**
Inbound mail, reports, listings and careers pages are someone else's text, returned to agents marked untrusted. Injection can make an agent draft badly or request a key; the operator reviews every draft before creating one. It cannot change a shot already authorized: a draft or target edited after the key is created no longer matches the frozen hash and falls out of scope. Recipients are the mission's own target only, so a hijacked agent cannot mail someone else under a key.

**T5. Forged mail through the domain pipe.**
The Worker signs each message: HMAC-SHA256 over `<timestamp>.<sha256 of the body>`, accepted within ±300 seconds, compared in constant time, under a per-pipe secret the node mints when the operator enables the pipe in the account lens (stepped up), stores sealed on the mailbox row, shows once for `wrangler secret put` in a real terminal, and rotates on request. The URL names the pipe's public id; the node unseals that pipe's secret to verify. Nothing lives in the host's environment. Bodies are bounded at 25 MiB, must be `message/rfc822`, and are rate-limited per pipe; a replay is deduped by Message-ID (else the body's hash). The Worker forwards to Gmail whatever the node answers, so a node outage never loses mail.

**T6. Hostile mail content.**
Plain text only: no HTML rendering, no remote content, no attachments fetched. Parsing is bounded (25 MiB, 200 parts, depth 10, 8 KiB per header, canonical Message-IDs). The lexer is a finite automaton: no backtracking, linear in the input, so no message can make filing slow.

**T7. Damage to the operator's Google standing.**
An authentication failure stops that mailbox's connector, marks it `auth_failed`, notifies the operator, and tries the credential again at most once an hour, so a revoked app password never trips Google's lockout. Network failures back off exponentially (1 to 30 minutes, with jitter). Sends are capped at 25 a day across every key, come from the linked address only, and go to bounded recipients.

**T8. One account reaching another's mail.**
A mailbox, its messages, missions and keys are account rows like any other: tenancy-scoped by `Hireme.Repo`, written only by the account's sequencer, and an inbound pipe resolves to exactly one account by its id.

**T9. Interception on the way to Google.**
TLS 1.2 or 1.3 with peer verification against the system CAs, SNI, a hostname check, and hosts pinned to `imap.gmail.com:993` and `smtp.gmail.com:465`. For now the linked address must be `@gmail.com` or `@googlemail.com`.

**T10. A self-reported shot that never happened.**
A careers-page or LinkedIn mission counts as submitted on its report, provisionally; the job board's confirmation mail, filed against it by the matcher, makes it confirmed. The desk shows the difference.

**T11. Applying twice.**
Missions on the 137 applications whose earlier send is unresolved (the crucible ledger's `sync.applied_on`) cannot be fired until the operator settles them; the backfill's filed confirmations are the evidence.
