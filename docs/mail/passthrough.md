# Mail passthrough: Gmail linked, replies filed, the domain as a second pipe

Brief for the team, 2026-10-22. The operator's words, verbatim:

> All right. The time has come to prime job apps to be sent out... Wow. So, how exactly does outreach work? How *is* it going to work? Can we add a way to link one's own email or gmail so its a passthrough, such that you can use it to send/receive emails directly in hireme, but also if I receive any replies to my job applications it'll show up in my gmail inbox?

> We can do 1 2 *and* 3 right now. Per application reply addresses, ehh. Damn how do we do this? Is it normal to have nongmail addresses? I think matei+a123 and stuff like that might get filtered out by ATS and stuff. Let's thin.

> Let's do it. **1 2 and 3** all together. Build the feature out with all your helpers here in herdr, subdividing the task however is needed.

> And the hireme inbox can just do lexiomatic parsing over the incoming emails to try to correlate them to what thread and task they're supposed to be on. Really consider how advanced the tech is. Make sure the parsing itself is a simple and regular machine.

## What was agreed in the main chat

- **No per-application addresses.** ATSs key a candidate by email; a different address per application makes several candidate profiles at one company, and `+tags` look like tracking. One address for every application: the operator's Gmail (`matei3d@gmail.com`, the address on the CV and on what was already sent).
- **1. Gmail link, the core.** The account links its Gmail with an app password (Google's OAuth route for full mail access is a restricted scope: an unverified personal app's refresh token dies every 7 days). IMAP to read (IDLE, Gmail's X-GM-THRID / X-GM-MSGID / X-GM-LABELS), SMTP through Gmail to send, so sent mail sits in Gmail's Sent and replies land in the inbox as always. hireme reads only mail that belongs to the job search, adds the Gmail label `hireme`, and never moves, archives or deletes anything.
- **2. Filing replies without tags.** A reply to mail hireme sent is matched exactly by its In-Reply-To / References. ATS mail is matched by the sending system plus the tenant hireme already stores per corporation (`ats`, `ats_tenant`), and the company and role named in it. Whatever is not certain goes to an **unfiled** tray the operator (or an agent) assigns in one click. Nothing is filed on a guess.
  Per the operator's last word: the correlation is lexical, and the parser is a simple, regular machine. A lexer (a finite automaton, nothing that backtracks or calls a model) reads headers and text into tokens (Message-IDs, addresses and their domains, ATS sender and tenant markers, a corporation's names and domains, role titles, numbers); correlation is lookups of those tokens against what the replica already holds (sent Message-IDs, corporations' domains and `ats_tenant`, applications' roles), ranked by a fixed table of evidence. Same input, same filing, explainable token by token.
- **3. anghel4d.com as a second pipe.** Its mail already forwards to Gmail (Cloudflare Email Routing, catch-all), so the Gmail link sees it. A Cloudflare Email Worker also posts each message to the node (signed), as a backup if Google ever stops app passwords; the node dedupes by Message-ID. `matei@anghel4d.com` can later serve cold outreach without touching the application identity.
- **Sending: the operator, or an agent holding a fire token.** The operator, verbatim: "Actually, the whole point is that agents can send when we're in AUTHORIZED with a fire token." So:
  - Only the operator mints a fire token, by a human-only command (as `open_fire` is human-only today). Minting puts its scope in AUTHORIZED.
  - A token is scoped: to a batch or named applications, with an expiry and a maximum number of sends; the daily cap (25 to start) still binds across all tokens.
  - An agent (MCP, the daemon) presents it on `send`; the node checks scope, expiry, remaining count and the cap on every send, and records the token on each message it sends.
  - The operator can revoke a token at any moment; a revoked or spent token sends nothing.
  - Without a token, agents draft only; the operator can always send by hand. Inbound mail is someone else's text: untrusted data for agents and the page (plain text, no remote content).
- The app password reaches the node without passing through any chat or argv; it is sealed at rest (`Hireme.Security`'s authenticated encryption or better).

## Lanes

Subdivide further as you see fit, talk to each other directly (herdr prompt), and settle interfaces between you rather than through me. Claim files in the team log before writing them; never write another lane's file.

- **opus-lovelace — schema and kernel.** The mailbox (linked account: provider, address, status, sync cursor, the sealed secret server-only), what `messages` needs (thread and Gmail ids, In-Reply-To/References, filed or unfiled, labels), drafts, the human-only `send` command and the cap's refusal, and the matcher as the one judge (kernel), so the page, the daemon and the node file mail the same way.
- **opus-hopper — the node's Gmail connector.** IMAP (IDLE, catch-up by UID after a gap, the X-GM extensions, labelling), SMTP send through the account's own Gmail, MIME parsing, per-account supervision with backoff, and ingestion through the sequencer. Test against a local IMAP/SMTP server, not the operator's mailbox.
- **opus-eliza — the domain pipe.** The Cloudflare Email Worker on anghel4d.com (keep forwarding to Gmail, copy to the node), the node's signed inbound endpoint, dedupe across both pipes, and anything DNS needs for sending as the domain later.
- **opus-noether — the page.** Linking Gmail in the account lens (status, last sync, unlink), threads on an application and in outreach, compose / reply / send for the operator (with the cap shown), the unfiled tray, and the desk showing a reply arrived.
- **opus-turing — security and production.** The threat model (credentials on the server, the inbound endpoint, mail as untrusted input, what the MCP may and may not do), SECURITY.md, the nix module and secrets, a `checks.dev` scenario, the operator's way to hand over the app password safely, and the deploy once the gates pass.
- **opus-shannon** coordinates, answers design questions, runs the end-to-end check, and reports to the operator.

Usual rules: the clean-HEAD gates in BRIEF.md, explicit-pathspec commits, no amend / revert / stash in the shared tree, fix bugs on sight, report progress and each landing in /home/pyrus/workspace/hireme-team.log as `<name> mail: ...`. fable-review is not to be messaged.
