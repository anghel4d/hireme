# hireme

An agentic tool with a theoretical 6767% effectiveness at getting a qualified candidate hired.

A local desk for a large set of job applications. Each application is a card. Focusing a card opens a side pane. Fullscreening that pane opens the application's battleplan. The interaction follows the same grid rule as a card browser: `h` `j` `k` `l` or the arrows, edge clamped. `Enter` opens the battleplan. `Esc` steps back, then clears search. `/` focuses search.

SQLite holds the corpus, a per-application mask over that corpus, batches, a scoreboard snapshot, and a private narrative. The narrative is one text blob per user, with a version and `updated_at`. It is not the root CV and it is not a mask. Application export omits it while it is private, which is the default.

The BEAM owns the data and the rules. The browser owns every view: it holds the account's raw rows in a Rust WebAssembly kernel, derives the cards, heat, scoreboard, focus and lanes from them itself, and predicts each write before the server answers. Nothing round-trips to draw anything; the server sends rows and settles writes.

## Run

Elixir 1.17+ and Erlang/OTP 27+. Rust 1.96.1 with the `wasm32-unknown-unknown` target to rebuild the kernel (`native/kernel/build.sh`); the built `priv/static/wasm/kernel.wasm` is committed, so a clone runs without it, and `native/kernel/build.sh --check` proves a rebuild reproduces it byte for byte.

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
Wait for that analysis to finish; a successful compile alone does not clear its diagnostics.

Check TypeScript with `tsc -p assets/tsconfig.json --noEmit --noUnusedLocals --noUnusedParameters`.
For each crate under `native/{wire,kernel,mcp,gate}`, run `cargo clippy --all-targets -- -D warnings`
and `cargo test` in that crate: dependency checks do not replace linting the kernel itself.
Also check the kernel with `cargo clippy --lib --target wasm32-unknown-unknown -- -D warnings`;
after kernel changes, rebuild with `native/kernel/build.sh`, verify `--check`, and run its JS fixtures and oracle parity.

### Performance testbed

`bench/testbed.exs` starts a production release against synthetic data confined to
`BENCH_DIR`, with a test mail adapter and local authenticated session. Never point
these harnesses at a production database. Keep its `testbed.json` private: it holds
synthetic session credentials.

`bench/server.exs` measures domain reads, packet construction, a 55-application
pack import and the account's committed writes (keys, sessions, factors, links),
each prepared and validated outside the timer. `bench/security.exs` isolates hot
authentication primitives. Each emits JSONL with raw millisecond samples and
nearest-rank quantiles; set `BENCH_REV`, `BENCH_OUTPUT`, and optionally `BENCH_N`.
`BENCH_VARIETY=1` seeds a testbed whose string columns carry real entropy (every
listing its own text, forty locations, mixed stages and statuses) beside the canonical one.
Known-ATS scaling uses `bench/ats_fixture.exs` on a disposable canonical fixture
copy under `/tmp/hireme-perf-ats-`, with `BENCH_HOT_JOBS` selecting the hot cohort.
For browser WebAuthn, the testbed sets Wax's origin to `http://localhost:$PORT`;
the relying-party ID remains automatic and user verification remains required.

The [performance audit](docs/performance.md) records baseline/final latency
quantiles, achieved throughput, correctness checks, raw evidence and limitations.

## Production deployment

The flake is the build and the NixOS half of a deployment, and knows no host.
`nix build .#hireme` is the OTP release (`bin/hireme`, and `bin/hireme-gate`
beside it), built with nixpkgs' `mixRelease` from the flake's own tree at its
revision; `.#hireme-gate` is the gate alone. The package
(`nix/package.nix`) builds SQLite's extension against Nix's SQLite, uses the
committed WASM kernel and Nix's esbuild, digests the assets, and admits only
application sources. It is reproducible: `nix build .#hireme .#hireme-gate
--rebuild` fails on any differing byte. The release is not under a free
licence, so nixpkgs is imported with `allowUnfree`. When `mix.lock` changes,
build with `mixDepsHash = lib.fakeHash` and pin the hash it reports.

`nixosModules.hireme` (`nix/module.nix`) is the application's half of a
host: the `hireme` user and one systemd unit that only starts and sandboxes
the node (no capabilities, `ProtectSystem=strict`, state in
`/var/lib/hireme`), with its secrets read from `services.hireme.environmentFile`
(an agenix path on a host). A host flake imports it with
`inputs.hireme.inputs.nixpkgs.follows = "nixpkgs"`, or the mix dependency
hash goes stale, and adds what is its own: addresses, firewall, certificates,
the reverse proxy. The deploy lives with the host, so there is no cycle
between the flakes.

The node owns its upkeep: pending migrations run as the first boot step
(`Hireme.Release`), and a failed one stops the boot. A supervised
`Hireme.Release.Backup` writes a daily online copy (`VACUUM INTO`) to
`backups/` beside the database and keeps 13 days, logging a failure as an
error and retrying within the hour; `bin/hireme rpc
'Hireme.Release.Backup.run()'` takes one now. On SIGTERM (the unit's
`KillMode=mixed` sends it to the node alone) no new session is admitted and
every live one hears BYE `restart`, from which clients reconnect and resume at
their revision. With `services.hireme.gate.enable` the node runs the gate as
its own Port on a high UDP port (the host forwards 443 to it), and the gate
exits when the node does. `Hireme.Release.migrate/0` remains for
`bin/hireme eval` without starting the application. Do not run `mix setup`,
`mix ecto.setup`, or `mix ecto.reset` against production.

The secrets file holds, as `KEY=value` lines:

| Variable | Requirement |
| --- | --- |
| `SECRET_KEY_BASE` | A persistent random secret, generated with `mix phx.gen.secret` |
| `RELEASE_COOKIE` | A separate persistent random release cookie; the package removes the build-time cookie |
| `CLOUDFLARE_ACCOUNT_ID` | The account with Cloudflare Email Sending enabled |
| `CLOUDFLARE_EMAIL_TOKEN` | A dedicated API token with only Email Sending Write for that account |
| `MAIL_FROM` | A sender address on an onboarded sending domain |

Its ciphertext in Git is the design; its plaintext never enters the Nix
store. On a host it is an agenix secret, rekeyed per host from hardware-held
master identities; moving values into it keeps them byte-identical, or every
session and agent breaks.

`checks.x86_64-linux.dev` is the dev profile, for testing until a vault
exists and after: a NixOS VM running the module with plaintext secrets it
generates for itself, no hardware key, and the gate's own self-signed ECDSA
P-256 certificate pinned by hash (Chrome accepts only those, for at most 14
days, so the gate signs a new one at each start). It proves the node
migrates, backs up, serves, runs the gate on its high port as its own user
with no capability, restarts a gate that dies, and takes it down when it
stops. `nix build .#checks.x86_64-linux.dev -L` runs it. Nothing of it ships.

Mail uses Cloudflare's HTTPS API because Hetzner blocks outbound SMTP port 465.
Req verifies TLS certificates; keep the host's CA trust store available. Serve traffic through an HTTPS
reverse proxy with WebSocket support and `X-Forwarded-Proto: https`; production
HTTPS redirects, HSTS, and secure session cookies remain enabled. Optional OAuth
credentials and callback URLs are described below under Accounts.

## Accounts

An account is the standalone thing a desk belongs to. Every row the desk stores names its account, and `Hireme.Repo` adds that predicate to every read, so one account's applications, batches, CVs, lanes, and leases do not exist for another. Sign-in is passwordless, with three ways in: a link mailed to an address, GitHub, and X. The first sign-in by any of them makes an account. The Account page adds more (another address, a GitHub user, an X user) and removes any but the last. A mailed link works once, for ten minutes; it opens a page that names the address, and only that page's button spends it, so a mail scanner that follows links spends nothing. In development, the sign-in page also offers a one-click sign-in to the local desk's account; that route is not compiled into other environments.

GitHub and X are offered once their client id and secret are set: `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` for a GitHub OAuth app, `X_CLIENT_ID` and `X_CLIENT_SECRET` for an X app with OAuth 2.0 as a confidential client. Register `https://<host>/auth/github/callback` and `https://<host>/auth/x/callback` exactly. Production mail uses Cloudflare Email Sending over HTTPS (`CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_EMAIL_TOKEN`, `MAIL_FROM`); development mail lands at `/dev/mailbox`. Queued delivery counts as accepted; permanent bounces and missing recipients are delivery errors. Requests are not automatically retried, avoiding duplicate sign-in messages.

A browser holds a session: one `__Host-hireme` cookie (Secure, HttpOnly, SameSite=Lax) carrying a random token whose hash is a row, so sessions can be listed and revoked from the Account page. Sessions end after 24 hours or an hour idle (NIST SP 800-63B-4, AAL2). Writes carry the page's CSRF token.

An account may enrol a second factor: an authenticator app, a passkey in an Apple, Google, or other keychain, or a hardware key such as a YubiKey, with recovery codes issued alongside the first. Never SMS, never email. Once one is enrolled, a new session must present it before anything is served, and the Account page asks for one again, within five minutes, before a key is minted or revoked, a factor or a way in is added or removed, or other sessions are ended. An account with no factor confirms those by having signed in within the last five minutes. `SECURITY.md` says which standards each piece answers.

An agent holds an API key. The Account page mints as many named keys as you like, each shown exactly once as `hm_<id>_<secret><check>` and stored as a hash, optionally expiring, revocable at any time. An agent presents it once, in its session's HELLO (see Agents). A key reads and writes its own account and nothing else; a wrong, revoked, expired, or foreign key is refused at HELLO with no detail. Key authentications are throttled per peer, including successful ones; one session carries every lease.

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

The board orders by `score_100` first, then cooler company heat, then batch, rung, and interest heat. The top bar filters by band, a minimum score, or heat state. The scoreboard draws one bar per band and each bar is that band's filter; every card shows its number. Agents' tools (`list_applications`, `recommend_applications`, `score_distribution`) rank the same board on `score_100` and take `min_score`, `band`, and `heat`; an agent can `set_score` on the applications its block holds. `mix hireme.score` prints the chart. Scoring does not submit.

## HEAT governor

The pipeline does not snap onto a company or an ATS. `Hireme.Heat` is a decaying load with caps, enforced in batch mix and `set_stage` into the submit queue. It does not send applications. FIRE HOLD still owns submit.

Company load rises for `fire_ready` / `open_fire` / `submitted` / `reply` / `closed`, halves every 35 days, and the cap scales with org size (Google/Amazon/Meta/NVIDIA/Microsoft = 4.0 across departments; a small shop = 1.0). Same department and cloned titles cost extra. ATS vendor and tenant are inferred from the apply URL; one day pack may not put more than 20 on a single vendor. Overrides need an explicit flag and a logged reason.

Heatmap sits under the Life-EV chart. MCP: `heat_status`, `can_apply`. Defaults: [`alchemy/heat.md`](alchemy/heat.md).

## Gym

Jumping jacks / lifting for the fight: LeetCode, Codeforces, systems drills. Necessary conditioning, not the job. `Hireme.Gym` tracks problems (platform, topic, difficulty) and reps (solved / attempt / skip). Daily target lives in kv (`gym` / `daily_target`, default 3). Streak is consecutive days with a solved rep. Weekly pace (`score` 0–100) is solved-this-week against `target × 7`. It is **not** Life-EV `score_100`.

The desk scoreboard shows `gym today/target · streak · pace`. The Gym lens (`?lens=gym`) logs a rep and sets the target. Directory MCP: `gym_status`, `gym_log`, `gym_set_target`.

## Networking

Not CRM. No contacts, no sequences, no follow-up spam. The lane is: run Broadside Observer, ship the artifact, post the work (X and similar), keep outreach drafts here until they ship.

`Hireme.Net` entries are a closed set: `observer`, `artifact`, `post`, `draft`. Channels: `broadside`, `x`, `other`. The Observer research URL lives in kv (`net` / `broadside_lane`). The scoreboard shows shipped-this-week, open drafts, and observer runs. The Net lens (`?lens=net`) sets the lane and logs an entry. Directory MCP: `net_status`, `net_log`, `net_set_lane`. FIRE HOLD — networking does not submit jobs.

## Board

The desk travels as columnar frames over one session per tab (`priv/wire/schema.txt` is the one definition: Elixir encodes, `native/wire` decodes, the hash rides in every frame header). The browser connects to the WebTransport gate (`native/gate`, its own address, UDP 443) with a single-use ticket from the page, or to the `/wire` WebSocket where UDP is blocked; the early script in `<head>` sends HELLO before the bundle loads. HELLO carries the revision of the browser's saved copy: the session answers with every raw table of the account (BOOT, deflated), or only the revisions since that copy (PATCH frames from the sequencer's ring), then a fresh ticket for the next reconnect.

`native/kernel` (Rust, built reproducibly to `priv/static/wasm/kernel.wasm`) holds those raw tables and derives the rest: the cards with their heat load, cooldown and verdicts, the board order and search, the heat chart, the scoreboard and its chart, keyword coverage and batch mixes, re-deriving only the jobs a change reaches and their heat kin. A write is an OP: the kernel predicts its rows and its refusals (lease, fire hold, heat) in the same tick, keeps it as pending over the base rows, and settles it when the PATCH and ACK arrive, or drops it on a NACK, so a refusal rolls back by itself. The kernel also composes the focus, root CV, lanes and account documents from those rows; `store.ts` keeps them until a row they read changes, saves the tables to IndexedDB when the page is idle, and restores the kernel from that copy if it ever traps. `shell.ts`, `views.ts`, `board.ts` and `html.ts` draw from the desk synchronously in the input's frame, morphing only what changed.

The server stays the authority. `Hireme.Ops` runs every write for an account in one sequencer (op ledger, validation, commit, a delta of the columns that changed) and keeps the ring that serves resumes; Elixir keeps no view logic: `test/support/oracle.ex` dumps what the server decides (raw deltas and refusals, `can_apply`, the batch mix), and `native/kernel/parity.mjs` requires the kernel's ports to equal it exactly.

## Types

Every closed set is a set of atoms with a `parse/1` at the edge: `Hireme.Pipeline` for stages and pips, `Hireme.Desk.Overlay.parse_mode/1` for mask modes. A string from the wire, a pack, or a form becomes one of those atoms once or is refused there. Past the edge nothing is compared to a string.

Values that cross a module boundary are structs with enforced keys: `Pipeline.Rung`, `Theme`, `CvPair`, `Heat.Config`, `Heat.Verdict`. Where a struct is stored as JSON (`Theme`) the module has a `to_map`/`parse` pair, and where a rail is stored as a pip string `Pipeline.encode/1` and `Pipeline.decode/1` are inverse. Tests check those round trips.

## CV pairs

One application has one CV variant. One employer has one CV lineage. `Hireme.CvPair.bind/1` loads that pair with a join that requires the lineage to belong to the application's employer. `JobId`, `VariantId`, `EmployerId`, and `LineageId` are different structs. Writes take the pair and load it again; the two structs must be equal.

For 90 days after a generation opens, the lineage can be rewritten. After that, edits wait. `open_cv_generation` starts the next quarter and accepts new lines only. A database trigger aborts a variant or a line that points at another employer's lineage.

## Agents

An agent is a client of the desk exactly as a browser is. **`hireme-mcp`** (`native/mcp`) is the stdio MCP server an agent such as Claude Code runs locally: it opens one session (WebTransport through the gate, or the `/wire` WebSocket where UDP is blocked), authenticates once with the API key in its HELLO, and receives the account's raw tables and every delta, which it keeps resident in the desk kernel (`native/kernel`, linked natively; the browser runs the same code as WebAssembly). Every read tool is answered from that copy: the ranked board, heat and `can_apply`, the score chart, gym and net progress, one application's composed CV. Writes go up as the ops the browser sends, and Elixir decides them.

Applications are changed under a lease on a block: a contiguous run of the account's application numbers (`no`, from 1, never reused), taken with `lease {"count":16}` or `lease {"from":1,"to":16}`. Asked for a size, the desk grants an aligned power-of-two block, as a buddy allocator would; asked for a range, exactly that, with a warning when it runs past the desk or sits off its alignment. A block is all or nothing, and one session holds one, on its own lane. While it lives, every other write to those applications is refused, and the first CV write for an employer claims that employer's CV lineage from other agents. `release {}`, the session ending, or the key being revoked gives it back. Any tool called with `{}` prints its call shape, a refusal reads like a rustc diagnostic, and `hireme {"explain":"<code>"}` gives a code's long form. Changes to leased applications arrive as log notifications and are kept for `letterbox_events`. Naming open fire stays on the desk, and nothing submits an application.

```
cargo build --release --manifest-path native/mcp/Cargo.toml
claude mcp add hireme \
  -e HIREME_API_KEY=hm_... \
  -e HIREME_WT_URL=https://<gate host>/wt \
  -e HIREME_WS_URL=wss://<host> \
  -- /path/to/native/mcp/target/release/hireme-mcp
```

`HIREME_TRANSPORT` picks `auto` (the default), `wt` or `ws`; a development gate's self-signed certificate is pinned with `HIREME_WT_CERT_SHA256_FILE=_build/gate.hash`. **Rebuild `hireme-mcp` whenever you pull a change to `priv/wire/schema.txt`.** A build from another schema is refused at HELLO and says so: `hello refused (schema): this hireme-mcp speaks wire schema …; rebuild it from the server's commit`. `bench/letterbox.mjs` times both carriers through `hireme-mcp`.

## Layout

Directories with internals behind one door: `heat/` (`heat.ex`; the ATS and org recognisers behind it), `mfa/` (`mfa.ex`; WebAuthn behind it), and `lib/hireme_web/` (`endpoint.ex`; router, session, packet, gate bridge, JSON and account behind it). Everything else is one file per concern, and every row the desk stores is in `schema.ex` in migration order.

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
| `lib/hireme/cv.ex` | Corpus, narrative, kv, `Theme`, `CvPair` and the quarterly cooldown |
| `lib/hireme/life_ev.ex` | `score_100` ladder and bands |
| `lib/hireme/gym.ex` | Conditioning grind: problems, reps, daily target |
| `lib/hireme/net.ex` | Broadside Observer runs, posts, artifacts, drafts. Not CRM |
| `lib/hireme/desk.ex` | Opening, stage moves and their heat permits, naming open fire, overlays and CV generations (the domain the sequencer calls) |
| `lib/hireme/ops.ex` | One sequencer per account: op ledger, every write, raw-row deltas, the resume ring, the heat snapshot |
| `lib/hireme/import.ex` | JSON, markdown table, freshness note; the `seed/` loader |
| `lib/hireme/heat/heat.ex` | Company/ATS heat governor: decay, caps, mix, `can_apply` |
| `alchemy/heat.md` | Heat defaults (half-lives, size tiers, ATS caps) |
| `lib/hireme/letterbox.ex` | Leases: an agent session's one block of applications, and the employers' lineages its CV writes claim |
| `lib/hireme_web/endpoint.ex` | The web layer's entry: endpoint, static paths, error renderers |
| `lib/hireme_web/router.ex` | Routes; the desk page (ticket, gate, scope and schema metas) and the reconnect ticket |
| `lib/hireme_web/session.ex` | One wire session per tab or agent, on either carrier: HELLO, BOOT/resume, ops, deltas, account RPC, an agent's block and its lane; the `/wire` WebSocket carrier |
| `lib/hireme_web/gate.ex` | The gate's supervisor: its Unix socket, the gate binary as a Port, and the Session in each connection process |
| `lib/hireme_web/auth.ex` | Who is asking: the session cookie, the account on the process, the security headers, sign-out |
| `lib/hireme_web/sign_in.ex` | The sign-in pages: mailed links, GitHub and X over OAuth 2.0 with PKCE, adding a way in |
| `lib/hireme_web/account.ex` | The Account page over the session: its tables and commands, step-up and enrolment ceremonies |
| `lib/hireme_web/mfa.ex` | The sign-in factor page |
| `lib/hireme_web/packet.ex` | Frames and columnar table blocks from `priv/wire/schema.txt`; raw rows in, bytes out |
| `native/kernel/` | The desk kernel (WebAssembly): raw tables, derived cards/heat/scoreboard, predictions, board order, select |
| `native/gate/` | The WebTransport gate (Rust, quinn/wtransport): QUIC, TLS, admission, the Unix-socket bridge |
| `native/mcp/` | `hireme-mcp`, the stdio MCP server agents run: one session, the desk resident in the kernel, one block of applications |
| `priv/wire/schema.txt` | The wire: frames, tables, columns, ops, refusals; its hash is in every frame |
| `native/wire/` | The frame codec shared by the kernel, the gate and `hireme-mcp` |
| `flake.nix`, `nix/` | The release, the NixOS module (one unit: start and sandbox), the dev-profile VM check |
| `assets/js/shell.ts` | Model, update, draw |
| `assets/js/store.ts` | The desk: kernel facade, documents, op queue, IndexedDB snapshot, trap recovery |
| `assets/js/wire.ts` | WebTransport and WebSocket carriers, framing, HELLO/OP/PING |
| `assets/js/early.ts` | The inline `<head>` script that connects and sends HELLO before the bundle |
| `assets/js/webauthn.ts` | The browser's half of a passkey ceremony, base64url in and out |
| `assets/js/factor.ts` | The factor page's passkey button |
| `alchemy/distillation-method.md` | DESERT STORM job-alchemy operator method (wide → crème → keepers) |
| `alchemy/score-ladder.md` | Life-EV `score_100` anchors and descending rungs |

## License

Copyright (c) 2026 Matei Anghel. All rights reserved. See [LICENSE](LICENSE).
