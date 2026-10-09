# hireme

An agentic tool with a theoretical 6767% effectiveness at getting a qualified candidate hired.

A local desk for a large set of job applications. Each application is a card. Focusing a card opens a side pane. Fullscreening that pane opens the application's battleplan. The interaction follows the same grid rule as a card browser: `h` `j` `k` `l` or the arrows, edge clamped. `Enter` opens the battleplan. `Esc` steps back, then clears search. `/` focuses search.

SQLite holds the corpus, a per-application mask over that corpus, batches, a scoreboard snapshot, and a private narrative. The narrative is one text blob per user, with a version and `updated_at`. It is not the root CV and it is not a mask. Application export omits it while it is private, which is the default.

The BEAM owns the data and the rules. The browser owns the board: the desk arrives as one columnar packet, lives in a hand-written WebAssembly column store, and every keystroke on the grid is a selection over resident columns. Nothing round-trips to draw a card.

## Run

Elixir 1.17+ and Erlang/OTP 27+. `wat2wasm` (wabt) to rebuild the kernel; the built `priv/static/wasm/desk.wasm` is committed, so a clone runs without it.

```bash
mix setup
mix phx.server
```

Open http://localhost:4000.

`mix ecto.reset` rebuilds the database and loads `seed/` when that directory is present.

### Verify

Run `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix credo --strict`, and `mix test`. ElixirLS with `mixEnv: "test"` and
Dialyzer enabled checks success typings beyond compiler and Credo warnings.
Keep those diagnostics enabled: CV composition accepts a corpus profile struct,
socket authentication returns an expiry alongside the account and key IDs, and
URL canonicalization updates a parsed URI rather than rebuilding its opaque fields.

## Accounts

An account is the standalone thing a desk belongs to. Every row the desk stores names its account, and `Hireme.Repo` adds that predicate to every read, so one account's applications, batches, CVs, lanes, and letterboxes do not exist for another. Sign-in is passwordless, with three ways in: a link mailed to an address, GitHub, and X. The first sign-in by any of them makes an account. The Account page adds more (another address, a GitHub user, an X user) and removes any but the last. A mailed link works once, for ten minutes; it opens a page that names the address, and only that page's button spends it, so a mail scanner that follows links spends nothing. In development, the sign-in page also offers a one-click sign-in to the local desk's account; that route is not compiled into other environments.

GitHub and X are offered once their client id and secret are set: `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` for a GitHub OAuth app, `X_CLIENT_ID` and `X_CLIENT_SECRET` for an X app with OAuth 2.0 as a confidential client. Register `https://<host>/auth/github/callback` and `https://<host>/auth/x/callback` exactly. Mail goes out over SMTP in production (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`); in development it lands in the mailbox at `/dev/mailbox`.

A browser holds a session: one `__Host-hireme` cookie (Secure, HttpOnly, SameSite=Lax) carrying a random token whose hash is a row, so sessions can be listed and revoked from the Account page. Sessions end after 24 hours or an hour idle (NIST SP 800-63B-4, AAL2). Writes carry the page's CSRF token.

An account may enrol a second factor: an authenticator app, a passkey in an Apple, Google, or other keychain, or a hardware key such as a YubiKey, with recovery codes issued alongside the first. Never SMS, never email. Once one is enrolled, a new session must present it before anything is served, and the Account page asks for one again, within five minutes, before a key is minted or revoked, a factor or a way in is added or removed, or other sessions are ended. An account with no factor confirms those by having signed in within the last five minutes. `SECURITY.md` says which standards each piece answers.

An agent holds an API key. The Account page mints as many named keys as you like, each shown exactly once as `hm_<id>_<secret><check>` and stored as a hash, optionally expiring, revocable at any time. An agent presents it on `/mcp/websocket` and `/mcp/letterbox/<id>/websocket` as the `x-api-key` header, or as the `base64url.bearer.phx.<base64 key>` websocket subprotocol. A key reads and writes its own account and nothing else; a wrong, revoked, expired, or foreign key is refused at the upgrade with no detail, and a peer that keeps failing is throttled.

The migration was rewritten for accounts; an existing local database needs `mix ecto.reset`.

## `seed/`

Local data lives in `seed/` at the repository root. That directory is not in the gitignore whitelist, so Git does not track it. Put a profile, narrative, CV items, and import packs there. Nothing in `seed/` is committed.

`mix ecto.setup` reads these files when they exist:

| File | Role |
| --- | --- |
| `seed/profile.json` | User and profile: `slug`, `name`, `email`, `headline`, `summary`, optional `kv` object |
| `seed/narrative.md` | Private narrative body |
| `seed/items.json` | Corpus lines: `kind`, `key`, `title`, `body`, optional `org`, `span`, `position`, `profile` (`shared` or omitted for the profile) |
| `seed/overlay.json` | Optional one-line mask on a packed application |
| `seed/*.json`, `seed/*.md` | Packs, in the order listed in `seed/manifest.json` |

`seed/manifest.json` is a JSON list of filenames in `seed/` to import after the profile (batch packs, a pursue table, a freshness note, a scoreboard snapshot, claims).

`seed/overlay.json` fields: `batch`, `item_key`, `mode` (`altered`, `hidden`, or `emphasized`), optional `body`, `reason`, and `theme`.

## Import

`mix hireme.import PATH` is idempotent on the canonical job URL: lowercased host, no tracking query, no trailing slash. A second import updates the same card.

Shapes:

- Batch pack: `{batch, status, fire, queued_on, squad, apps: [...]}`
- Batch list: `{"batches": [...]}`
- Scoreboard snapshot: `{noted_on, leftover_unique, target_total, target_on, daily_batches, daily_apps}`
- Claims: `{"claims": [{"squad", "slice", "note"}]}`
- Pursue table: a markdown table with columns Company, Role, Location, Fit, Source, URL
- Freshness note: lines `OPEN n`, `THIN n`, `CLOSED n`, `BLOCKED n`, then `## OPEN` (and the other verdicts) as URL lists

A row marked `submitted` or `open_fire` is stored as `fire_ready` while that batch is on hold.

## Battleplan

Discovered, freshness, gated, in batch, draft ready, fire ready, open fire, submitted, reply, closed.

Freshness (`open`, `thin`, `closed`, `blocked`) and the gate (`pursue`, `maybe`, `skip`) are fields on the card. One stage is active. `open_fire` and `submitted` are refused while the batch fire is hold. Naming open fire records that decision. It does not send an application.

The scoreboard reads leftover URL counts from the latest snapshot, then counts batches and applications queued today, submits today, the cumulative submit count, and pace against the snapshot's daily target. Variety flags are computed per batch. Gym (daily reps / streak / weekly pace) and Net (shipped / drafts / Observer runs) sit on the same strip.

## Life-EV (`score_100`)

Every job and employer gets `score_100` (0–100). A pack may set it (`score_100` or `score`, or a `Score` column in a pursue table); otherwise `Hireme.LifeEv.score/1` assigns it from company, role, fit, location, and comp along the ladder in [`alchemy/score-ladder.md`](alchemy/score-ladder.md). Eight closed bands: `frontier` 100, `labs` 90–99, `big_tech` 85–89, `systems` 70–84, `craft` 55–69, `mid` 40–54, `thin` 20–39, `kill` 0–19. A re-import without a score leaves the card's score alone.

The board orders by `score_100` first, then cooler company heat, then batch, rung, and interest heat. The top bar filters by band, a minimum score, or heat state. The scoreboard draws one bar per band and each bar is that band's filter; every card shows its number. Directory MCP tools (`list_applications`, `recommend_applications`, `score_distribution`, `list_letterboxes`) rank on `score_100` and take `min_score`, `band`, and `heat`; a lease can `set_score` on the one application it holds. `mix hireme.score` prints the chart. Scoring does not submit.

## HEAT governor

The pipeline does not snap onto a company or an ATS. `Hireme.Heat` is a decaying load with caps, enforced in batch mix and `set_stage` into the submit queue. It does not send applications. FIRE HOLD still owns submit.

Company load rises for `fire_ready` / `open_fire` / `submitted` / `reply` / `closed`, halves every 35 days, and the cap scales with org size (Google/Amazon/Meta/NVIDIA/Microsoft = 4.0 across departments; a small shop = 1.0). Same department and cloned titles cost extra. ATS vendor and tenant are inferred from the apply URL; one day pack may not put more than 20 on a single vendor. Overrides need an explicit flag and a logged reason.

Heatmap sits under the Life-EV chart. MCP: `heat_status`, `can_apply`. CLI: `mix hireme.heat`. Defaults: [`alchemy/heat.md`](alchemy/heat.md).

## Gym

Jumping jacks / lifting for the fight: LeetCode, Codeforces, systems drills. Necessary conditioning, not the job. `Hireme.Gym` tracks problems (platform, topic, difficulty) and reps (solved / attempt / skip). Daily target lives in kv (`gym` / `daily_target`, default 3). Streak is consecutive days with a solved rep. Weekly pace (`score` 0–100) is solved-this-week against `target × 7`. It is **not** Life-EV `score_100`.

The desk scoreboard shows `gym today/target · streak · pace`. The Gym lens (`?lens=gym`) logs a rep and sets the target. Directory MCP: `gym_status`, `gym_log`, `gym_set_target`. CLI: `mix hireme.gym`.

## Networking

Not CRM. No contacts, no sequences, no follow-up spam. The lane is: run Broadside Observer, ship the artifact, post the work (X and similar), keep outreach drafts here until they ship.

`Hireme.Net` entries are a closed set: `observer`, `artifact`, `post`, `draft`. Channels: `broadside`, `x`, `other`. The Observer research URL lives in kv (`net` / `broadside_lane`). The scoreboard shows shipped-this-week, open drafts, and observer runs. The Net lens (`?lens=net`) sets the lane and logs an entry. Directory MCP: `net_status`, `net_log`, `net_set_lane`. CLI: `mix hireme.net`. FIRE HOLD — networking does not submit jobs.

## Board

`GET /api/pack` is the whole desk as one `HDP1` packet: `"HDP1"`, a u32 header length, a JSON directory, then the body. The directory names every column with its kind (`u32` or `str`) and byte offset, and carries the lookup tables the integer columns index into: stages, statuses, freshness, gates, bands, batches, profiles. Rows are already in board order (`score_100` first, then batch, rung, heat, company). A `str` column is `n + 1` offsets followed by UTF-8 bytes; one of them is a lowercase search haystack per card.

`assets/wasm/desk.wat` is the column store: a bump allocator, `select` (score floor, band range, stage, status, batch, profile, and a byte-level substring scan of the haystack) that writes passing row indices in packet order, and `find`. It is 656 bytes of WebAssembly and knows nothing about jobs.

`assets/js/` is the shell: `store.ts` reads the packet directory, copies the body into kernel memory, and views columns as typed arrays with strings decoded on demand; `board.ts` is the filter ADT parsed from and written to the address and the row-major `hjkl` rule with the painted window; `html.ts` is an escaping template tag and a `morph` that changes only what differs; `views.ts` are pure functions from model to HTML, lanes included; `api.ts` is every read and write over HTTP plus the signal feed; `shell.ts` is the model, the update, and the draw. Focus, battleplan, and root come from `/api/focus/:id` and `/api/root/:id`; writes are `POST /api/...` and answer with the new focus or a status code that says why not (`409 fire_hold`, `423 leased`). `/feed/websocket` pushes every desk signal so an open board refreshes when an agent writes.

## Types

Every closed set is a set of atoms with a `parse/1` at the edge: `Hireme.Pipeline` for stages and pips, `Hireme.Desk.Overlay.parse_mode/1` for mask modes, `Hireme.Desk.Job.parse_status/1`, `Hireme.Desk.Filters.from_params/1` for the URL. A string from the wire, a pack, or a form becomes one of those atoms once or is refused there. Past the edge nothing is compared to a string.

Values that cross a module boundary are structs with enforced keys: `Pipeline.Rung`, `Mask.Line`, `Keywords.Coverage`, `Cv.Document`, `Theme`, `Variety`, `Campaign.Scoreboard`, `Desk.Card`, `Desk.Focus`, `Desk.Signal`, `CvPair`, `Letterbox.Handle`, `Heat.Config`, `Heat.Verdict`, `Heat.Chart`. Where a struct is stored as JSON (`Theme`, `Variety`) the module has a `to_map`/`from_map` pair, and where a rail is stored as a pip string `Pipeline.encode/1` and `Pipeline.decode/1` are inverse. Tests check those round trips.

## CV pairs

One application has one CV variant. One employer has one CV lineage. `Hireme.CvPair.bind/1` loads that pair with a join that requires the lineage to belong to the application's employer. `JobId`, `VariantId`, `EmployerId`, and `LineageId` are different structs. Writes take the pair and load it again; the two structs must be equal.

For 90 days after a generation opens, the lineage can be rewritten. After that, edits wait. `open_cv_generation` starts the next quarter and accepts new lines only. A database trigger aborts a variant or a line that points at another employer's lineage.

## Agent socket

Letterboxes are single-producer, single-consumer. Each application has one letterbox. An agent leases that id and the lease opens a full-duplex websocket. The connection process is the only producer. The letterbox process is the only consumer. The handle closes over that application's CV pair. Commands do not carry an application id.

`/mcp/websocket` lists letterboxes and batches, ranks applications on `score_100`, reports heat (`heat_status`, `can_apply`), and logs gym reps plus networking entries. It cannot write an application.

`/mcp/letterbox/<id>/websocket` is the lease. A second connection to that id is refused. A second connection to another application on the same employer CV is refused while the lease is held. One connection cannot hold two leases.

Each text frame is one JSON object. `{"id": 1, "method": "tools/list"}` lists the tools. `tools/call` runs one. The server pushes `{"method": "notifications/desk", "params": {...}}` for this application only. A job id or variant id from a different application is rejected. Naming open fire stays on the desk. The socket does not submit an application.

## Layout

Three directories have internals behind one door: `heat/` (`heat.ex`; the ATS and org recognisers behind it), `letterbox/` (`letterbox.ex`; the consumer process behind it), and `lib/hireme_web/` (`endpoint.ex`; router, packet, JSON, MCP, and sockets behind it). Everything else is one file per concern, and every row the desk stores is in `schema.ex` in migration order.

| Path | Role |
| --- | --- |
| `lib/hireme/types.ex` | `Schema`, `Closed`, `Attrs`, `Form`, `Text`: the one way a loose value is read |
| `lib/hireme/accounts.ex` | The account, its sessions, and its ways in: identities, mailed links, notices |
| `lib/hireme/mailer.ex` | Sign-in links and account notices by mail, plain text |
| `lib/hireme/api_keys.ex` | Named, hashed, revocable keys an agent presents; one key, one account |
| `lib/hireme/security.ex` | The policy numbers and the primitives: tokens, hashes, base62, sealing, throttling |
| `lib/hireme/audit.ex` | The append-only security trail |
| `lib/hireme/mfa/mfa.ex` | Second factors: apps, passkeys and keys, recovery codes, step-up |
| `lib/hireme/mfa/webauthn.ex` | The WebAuthn ceremonies behind `Hireme.Mfa` |
| `lib/hireme/schema.ex` | Every row the desk stores |
| `lib/hireme/pipeline.ex` | Stage and pip atoms, `Rung`, encode/decode, the hold lock |
| `lib/hireme/cv.ex` | Corpus, narrative, kv, `Theme`, `Mask`, `Keywords`, the composed `Cv.Document`, `CvPair` and the quarterly cooldown |
| `lib/hireme/life_ev.ex` | `score_100` ladder, bands, histogram |
| `lib/hireme/gym.ex` | Conditioning grind: problems, reps, streak, daily target |
| `lib/hireme/net.ex` | Broadside Observer runs, posts, artifacts, drafts. Not CRM |
| `lib/hireme/desk.ex` | Cards, focus, stages, naming open fire, `Signal`, `Filters` |
| `lib/hireme/campaign.ex` | Scoreboard and batch variety |
| `lib/hireme/import.ex` | JSON, markdown table, freshness note; the `seed/` loader |
| `lib/hireme/heat/heat.ex` | Company/ATS heat governor: decay, caps, mix, `can_apply` |
| `alchemy/heat.md` | Heat defaults (half-lives, size tiers, ATS caps) |
| `lib/hireme/letterbox/letterbox.ex` | SPSC lease, one application per handle |
| `lib/hireme_web/endpoint.ex` | The web layer's entry: endpoint, static paths, error renderers |
| `lib/hireme_web/router.ex` | Routes and the one controller: packet, focus, root, scoreboard, lanes, writes |
| `lib/hireme_web/auth.ex` | Who is asking: the session cookie, the account on the process, the security headers, sign-out |
| `lib/hireme_web/sign_in.ex` | The sign-in pages: mailed links, GitHub and X over OAuth 2.0 with PKCE, adding a way in |
| `lib/hireme_web/account.ex` | The Account page's JSON: keys, sessions, and ways in |
| `lib/hireme_web/mfa.ex` | The factor page and the second-factor half of the Account page |
| `lib/hireme_web/packet.ex` | The desk as one HDP1 columnar packet |
| `lib/hireme_web/json.ex` | Wire shapes for the shell and the MCP tools, and refusals |
| `lib/hireme_web/mcp.ex` | Tool calls on the directory socket or a leased handle; directory ranks on `score_100`; gym/net log on the directory |
| `lib/hireme_web/sockets.ex` | Push feed, directory socket, letterbox socket |
| `assets/wasm/desk.wat` | The column store |
| `assets/js/shell.ts` | Model, update, draw |
| `assets/js/webauthn.ts` | The browser's half of a passkey ceremony, base64url in and out |
| `assets/js/factor.ts` | The factor page's passkey button |
| `alchemy/distillation-method.md` | DESERT STORM job-alchemy operator method (wide → crème → keepers) |
| `alchemy/score-ladder.md` | Life-EV `score_100` anchors and descending rungs |
| `.cursor/skills/job-alchemy-distillation/SKILL.md` | Cursor skill for the same distillation funnel |

## License

Copyright (c) 2026 Matei Anghel. All rights reserved. See [LICENSE](LICENSE).
