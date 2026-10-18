# Rebuild: opus-shannon's design

Written before reading `docs/rebuild-whalechan.md`, so the two designs are
independent. Converge into `docs/rebuild-agreed.md`.

## The operator's words

> "I am expanding the scope of the redesign to encompass the entire application. Every single elixir, rust, and web file is in scope. We are doing it all over and performing a major overhaul, on one condition: everything replaced completely NUKES the old file and old thing, and reinvents it from scratch. There is no room for partial migration here."

> "You should both design the whole, than converge, is the unique thought I had just now."

Carried forward from the first round, still binding:

> "a connected AI agent should be given a full duplex (r/w) channel when it gets a "lease", and that it should be able to add new data"

> "this is a fat table with all those rows and more as needed. Not a soup of many different tables and schemas"

> "Fat table, many columns, nullables are ok (and this applies to every table btw, its a pricniple of modern data-oriented design to have sparse matrices)"

> "We do not care about parsing job listings out into more database columns(at all!)"

> "the API key-provisioning improved so that perms can be a bit more granular (read only, write only, r/w, etc)"

> "I would reinvent the contents of PR8 altogether, rather than merge directly."

## The one idea everything hangs on

**One implementation of every rule, run in three places.** Today the heat
governor, keyword coverage, pipeline rules and op prediction exist twice:
in Elixir (the authority) and in Rust (`native/kernel`, the browser's and
the agent's prediction), held together by a bit-for-bit parity oracle
(`test/support/oracle.ex`, `native/kernel/parity.mjs`). The rebuild has
one: the Rust kernel judges every domain write on the server too, linked
into the BEAM as a NIF. The browser (wasm), `hireme-mcp` (native) and the
sequencer (NIF) run the same function on the same rows, so a prediction
cannot disagree with the verdict, and the parity machinery is deleted
rather than rebuilt. Elixir keeps what Elixir is for: order, transactions,
identity, grants, leases, mail, supervision.

## What the app is

Hireme is a personal job-campaign desk for one operator and the agents
they lease to. FIRE HOLD stands: nothing in it submits an application;
naming open fire is a human act.

Surfaces (one page, one wire session, lenses in the address):

| Lens | What it is |
| --- | --- |
| `desk` | The board: applications ranked by `score_100`, then heat, filtered by band, stage, heat state; keyboard movement; the scoreboard |
| `focus` | One application: the raw listing, the composed CV through its overlays, the rail, events, its messages and contact, its corporation's card |
| `world` | Corporations and places as sortable sparse grids; every cell shows its `_on` and opens its citations |
| `atlas` | Where to live: places scored against the operator's own passports, languages and weights |
| `outreach` | Contacts and message threads, tied to corporations and applications |
| `lanes` | Gym (reps, target, streak) and net (observer runs, artifacts, posts, drafts) |
| `account` | Identities, factors, sessions, API keys with masks, live leases with revoke, trusted hosts |

Plus HTTP-only ceremonies: sign-in (email link, GitHub, X), the factor page.

## The schema compiler

One declaration, `schema/hireme.schema` (a plain text file, line-oriented
like today's `priv/wire/schema.txt`, so Rust's `build.rs`, an Elixir
compile-time reader and a mix task all parse it without a shared runtime).
It declares, once:

- `domain` lines: `world`, `desk`, `mail`, `lanes`, `corpus`, `system` (key
  masks are over the first five; `system` is never key-visible).
- `table` lines: name, wire id, domain, residency (`resident` | `server`),
  natural key(s), `append_only`, `soft_delete`.
- `col` lines: name, wire id, type (`id`, `u32`, `u64`, `f64`, `bool`,
  `day`, `time`, `str`, `text`, `sym`, `json`), nullability, flags
  (`metric` = gets a `<name>_on` day column, `prose` = needs `expect_rev`
  and a citation on world tables, `private`, `deferred`, `server_only` =
  never writable by `put`), and `ref <table>`.
- `enum` lines: closed sets (stages, pips, channels, bands...).
- `command` lines: name, id, params (name, type), required domain, `human`
  (refused to keys).

Emitters (`mix hireme.schema` runs them; `mix test` fails if any checked-in
output differs from a fresh emit):

| Emitter | Output | Checked in? |
| --- | --- | --- |
| Ecto | row modules defined at compile time by `Hireme.Schema` macros reading the file (`@external_resource`) | no (macro) |
| SQL | `priv/db/baseline.sql`: the whole database at cutover | yes |
| SQL diff | `priv/db/NNNN_<name>.sql`: additive changes after cutover (new table, new column, new index), emitted from declaration minus `PRAGMA table_info` | yes |
| Wire catalog | the `catalog` table in every BOOT and `schema_rev` | no (runtime) |
| JSON Schema | the MCP's `put`/`find`/command argument schemas, built from the catalog at runtime | no |
| Rust | `kernel::schema` consts (table/col/enum/command ids) via `build.rs` | no |
| TypeScript | `assets/js/gen/schema.ts` (ids, enums, row interfaces) | yes |

Two hashes, not one: `wire_hash` covers frame layouts and the resident
tables the kernel is compiled against (a change forces a client rebuild);
`schema_rev` counts catalog changes to server-side tables (a new metric on
`places` bumps it; clients refetch `schema`, nothing rebuilds).

After cutover there is still a forward path, because "no migration chain"
is about the nuke, not about never changing a column again: the SQL diff
emitter writes additive files only; a destructive change is written by
hand, named `NNNN_drop_<what>.sql`, and reviewed.

## Tables

Every table has `id`, `account_id` (except `accounts`, `magic_links`),
`inserted_at`, `updated_at`, `rev` (+1 per write). Soft-delete tables
carry `deleted_at`. Ids and `applications.no` are never reused.

### system (server, never key-visible)

| Table | Notes |
| --- | --- |
| `accounts` | `name`, `status` (active, suspended), `desk_rev`, `next_no` |
| `sessions` | `token_hash`, `authenticated_at`, `mfa_at`, `last_seen_at`, `expires_at`, `revoked_at`, `ip`, `user_agent` |
| `identities` | `provider` (email, github, x), `subject`, `display`, `verified_at`; unique (provider, subject) |
| `magic_links` | `email`, `token_hash`, `expires_at`, `used_at`, `ip`, `user_agent` |
| `api_keys` | `key_id`, `name`, `secret_hash`, `prefix`, `read_mask`, `write_mask`, `may_delete`, `last_used_at`, `expires_at`, `revoked_at` |
| `factors` | one fat table for TOTP and WebAuthn: `kind`, `name`, `totp_secret`, `totp_last_step`, `credential_id`, `public_key`, `sign_count`, `aaguid`, `transports`, `backup_eligible`, `backed_up`, `verified_at`, `last_used_at`, `failures`, `disabled_at` |
| `challenges` | `kind` (totp_enroll, webauthn_register, webauthn_assert), `payload`, `expires_at`, `session_id` |
| `recovery_codes` | `salt`, `code_hash`, `used_at` |
| `audit` | append-only: `kind`, `ip`, `user_agent`, `meta` (json), `key_id` |
| `outbox` | system mail: `address`, `kind`, `meta`, `attempts`, `next_at`, `sent_at`, `last_error` |
| `op_ledger` | `op_id` (u64), `outcome` (json), `expires_at` (24 h): a resend gets the first answer |
| `trusted_hosts` | `host`, `note`; written only from a browser session behind step-up |

### corpus (resident)

| Table | Notes |
| --- | --- |
| `profiles` | `slug`, `name`, `headline`, `summary`, `narrative` (private text; the old `narratives` table folds in) |
| `items` | CV atoms: `profile_id` (null = shared), `kind` (experience, project, education, skill, timeline, fact), `key`, `title`, `body`, `org`, `span`, `position`, `keywords` |

### desk (resident)

| Table | Notes |
| --- | --- |
| `applications` | `no`, `corporation_id`, `place_id`, `contact_id`, `profile_id`, `batch_id`, `company` (as typed, until a corporation is linked), `role`, `location`, `channel` (listing, cold, referral, inbound, recruiter, other), `listing_url`, `canonical_url` (natural key when set), `listing_raw` (**deferred** text), `listing_on`, `keywords` (server-extracted from `listing_raw` by the kernel at write time; what the client derives coverage from), `stage`, `pips`, `stage_on`, `stage_notes` (json), `status`, `gate`, `freshness`, `fit`, `department`, `heat_override`, `heat_override_reason`, `score_100`, `next_action`, `next_due`, `applied_on`, `outcome`, `cv_theme` (json; the old `cv_variants` fold in), `notes`, `battleplan` |
| `events` | append-only: `application_id`, `kind`, `body`, `actor` (human, agent, system, mail), `key_id`, `op_id` |
| `batches` | `code`, `ordinal`, `kind`, `status`, `fire` (hold, open_fire), `target_size`, `queued_on`, `note` |
| `cv_lineages` | per corporation: `corporation_id`, `generation`, `opened_on`, `rewrites_allowed`, `theme` |
| `cv_overlays` | `application_id`, `item_id`, `lineage_id`, `mode` (replace, hide, add), `title`, `body`, `reason`, `generation` |
| `settings` | **one fat row per account**, replacing `kv_pairs`, `geography_profiles` and `scoreboard_snapshots`: `gym_target`, `net_lane_url`, `citizenships`, `languages`, `field`, `w_energy`, `w_qol`, `w_afford`, `w_lang`, `w_route`, `w_tech`, `w_ease`, `goal_total`, `goal_on`, `goal_daily`, `heat_config` (json overrides of the governor's defaults) |

### world (server-side; one resident projection)

| Table | Notes |
| --- | --- |
| `places` | countries and cities, `kind` + `country_id` (self ref); partial uniques `iso2 WHERE kind='country'`, `geonames_id WHERE kind='city'`. Identity, demography, economy, liveability, energy, career (`mobility`, `language`, `tech`, `ease`, `work_permit`) column groups as agreed in round one; every figure a `metric`; `liveability`, `notes` prose |
| `corporations` | `domain` (natural key), identity, size, private and public economics, comp and reputation, hiring (`careers_url`, `ats`, `ats_tenant`, `remote_policy`), desk columns (`score_100`, `freshness`, `freshness_on`, `eng_urls`, `note`), prose `about`, `culture` |
| `offices` | `corporation_id`, `place_id`, `kind`, `headcount` (metric), `opened_on`; unique (corporation, place, kind) |
| `sources` | `url` (natural key), `host` (server-derived), `publisher`, `title`, `kind`, `retrieved_at` |
| `citations` | append-only, `server_only`: `table`, `row_id`, `column`, `source_id`, `value`, `as_of`, `actor`, `key_id`, `op_id` |
| `atlas` | **resident projection**, not stored: places with `atlas` flag set, only the columns the atlas fit reads |

### mail (server-side)

| Table | Notes |
| --- | --- |
| `contacts` | `corporation_id`, `place_id`, `name`, `title`, `email`, `linkedin_url`, `x_handle`, `relation`, `last_touch_on`, `notes` |
| `messages` | `channel` (email, linkedin, x, call, meeting), `direction`, `from_addr`, `to_addrs`, `cc_addrs`, `subject`, `body` (deferred), `message_id` (natural key), `thread_key`, `sent_at`, `status`, `corporation_id`, `application_id`, `contact_id` |

### lanes (resident)

| Table | Notes |
| --- | --- |
| `gym_reps` | fat: `platform`, `slug`, `title`, `topic`, `difficulty`, `url`, `done_on`, `minutes`, `outcome`, `note` (the old `gym_problems` folds in; a problem is a `(platform, slug)` read) |
| `net_entries` | `kind` (observer, artifact, post, draft), `channel`, `title`, `url`, `body`, `shipped_on` |

Derived on the wire, never stored: `leases` (session label, key id,
application ids held, since), `clock` (server day and time), `catalog`.

Gone, with no successor: `claims`, `squad` columns, `freshness_verdicts`
(two columns on `corporations`), `scoreboard_snapshots`, `kv_pairs`,
`cv_variants`, `narratives`, `gym_problems`, `employers`, `geography_*`.

## Wire v2

Header unchanged in shape: `u32 len | u8 kind | u8 flags | u16 wire_hash |
u64 rev`, 16 bytes, bodies 8-aligned, flags `DEFLATE 0x01`, `END 0x02`.

| Frame | Id | Direction | Body |
| --- | --- | --- | --- |
| `HELLO` | 1 | up | credential kind (ticket, key), credential, `snapshot_rev`, `schema_rev`, client label |
| `WELCOME` | 2 | down | account id, session id, `read_mask`, `write_mask`, `may_delete`, `schema_rev`, lease state |
| `BOOT` | 3 | down | every resident table the read mask allows, plus `catalog`, `leases`, `clock` |
| `PATCH` | 4 | down | changed rows (id + moved columns) and `gone` |
| `OPS` | 8 | up | a batch of ops (below) |
| `ACK` | 9 | down | per op: `op_id`, `rev`, `id` (the row's, for an insert) |
| `NACK` | 10 | down | per op: `op_id`, `code` (u16 from the catalog's refusal enum), `data` (json) |
| `TICK` | 11 | down | `clock` |
| `PING`/`PONG` | 13/14 | both | carrier liveness, 15 s interval, 45 s timeout ends the session |
| `RPC` | 33 | up | `u32 id`, method (str), params (json) |
| `REPLY` | 34 | down | `u32 id`, result or error (json) |
| `BYE` | 16 | down | reason (revoked, grants, restart, schema, suspended) |

An op in `OPS`: `u64 op_id | u8 verb (put 1, drop 2, command 3) | u8 flags
(KEYED 0x01, CREATE_ONLY 0x02, EXPECT_REV 0x04) | u16 table_or_command |
u32 target (row id, 0 when keyed or new) | u16 ncols | u16 0 | u32
expect_rev`, then `ncols` typed cells `u16 col_id | u8 type | u8 0 | u32
len | bytes | pad to 8`. Cells are typed on the wire (no string casting
on the server); `as_of` and `source` are reserved col ids `0xFFF0`/`0xFFF1`;
a command's params are its declared columns. One op carries up to 1 MiB of
text (`too_large` past it); one `OPS` frame carries up to 256 ops.

Deferred text (`listing_raw`, `messages.body`, prose on world tables
when a projection carries them) travels in BOOT/PATCH as `u32 len | 8
bytes of SHA-256`; `RPC text {table, id, column, offset, length}` returns
256 KiB chunks and re-checks the read mask per chunk.

Server-side reads are RPC methods: `schema`, `find`, `get`, `history`,
`text`, plus `account.*` (the account page's commands) and `lease.*`.

## The kernel

One Cargo workspace, `native/Cargo.toml`, one `Cargo.lock`:

| Crate | Role |
| --- | --- |
| `native/schema` | parser + emitters for `schema/hireme.schema` (used by every `build.rs` and by `mix hireme.schema` through a small binary) |
| `native/wire` | the frame codec |
| `native/kernel` | rows, derivations, judging; `no_std`-friendly core, `wasm32` and native targets |
| `native/nif` | Rustler wrapper of `kernel` for the sequencer |
| `native/gate` | WebTransport front door (unchanged role) |
| `native/mcp` | `hireme-mcp` |

Kernel modules (`native/kernel/src/`), each one owner:

| Module | Owns |
| --- | --- |
| `rows.rs` | resident columns, arena strings, BOOT/PATCH ingest, base ⊕ pending |
| `judge.rs` | the domain checks of every put, drop and command (below), returning the refusal code and its data; the browser predicts with it, the sequencer decides with it |
| `pipeline.rs` | stages, pips, rail encode/decode, legal moves, fire hold |
| `heat.rs` | the governor: decaying loads per company, ATS vendor and tenant, caps by size tier, department and clone penalties, the board's cool/hot ratios, `mix` (keep highest score, defer the rest) |
| `ats.rs` | vendor and tenant from an apply URL |
| `org.rs` | size tier, department, role family |
| `score.rs` | Life-EV: named anchors, band ladder, the hard-kill floor; suggests `score_100`, never overwrites a set one |
| `keywords.rs` | target words from `listing_raw` (run once, at write time, on the server) and their coverage by the composed CV |
| `cv.rs` | a CV composed from profile items through the lineage's overlays |
| `board.rs` | order, filter, select, search, keyboard geometry inputs |
| `atlas.rs` | route (right to live), language fit, the seven axis parts, weighted fit, presets; the only implementation |
| `lanes.rs` | gym streak, pace, today; net counts |
| `compose.rs` | the JSON documents the MCP and the focus lens read |
| `abi.rs` (wasm only) | exports; columns read by pointer |

## Elixir

```
lib/hireme/
  application.ex   supervision: Repo, PubSub, Registry, Sequencer.Supervisor, Release, Mail, Endpoint, Drain
  repo.ex          tenancy: put_account/1, every read scoped, skip_account explicit
  schema.ex        the compile-time reader and row macros; every row module is generated here
  store.ex         SQLite: pragmas, writer lock, busy backoff, VACUUM INTO
  sequencer.ex     one process per account: order, batch of 64, transaction, ledger, rev, deltas
  kernel.ex        the NIF: one kernel resource per sequencer, fed the same deltas clients get
  grants.ex        masks, presets, domain of a table or command
  lease.ex         the channel, application claims, since, operator revoke
  world.ex         server-side reads: find, get, history, text; keyset paging
  provenance.ex    sources (host derived), citations, trusted_hosts
  import.ex        packs (JSON, markdown) lowered to put ops through the sequencer
  accounts.ex      accounts, sessions, identities, magic links
  keys.ex          API keys: mint, authenticate, revoke, mask changes
  mfa.ex           TOTP, recovery codes; mfa/webauthn.ex internal
  security.ex      every policy number and named limit
  audit.ex
  mail.ex          outbox, Cloudflare Email Sending adapter, notices
  release.ex       baseline/diff migration at boot, daily backup
lib/hireme_web/
  endpoint.ex router.ex auth.ex sign_in.ex factor.ex
  session.ex       one wire session per tab or agent: HELLO, masks, BOOT filter, OPS, RPC, BYE
  gate.ex          the BEAM end of the gate
  account.ex       account.* RPC methods
  wire/codec.ex    frame codec, layouts from the schema file
lib/mix/tasks/hireme.ex   schema, import
```

The sequencer's checks, in order, inside the op's savepoint:

1. `grant`: write mask covers the table's domain (`scope`); drop needs
   `may_delete` (`scope`); `human` commands from a key (`human_only`).
2. `lease`: a key's session holds the channel (`lease_missing`); an
   application held by another session (`leased`).
3. `shape`: table, columns, types and natural key exist and are writable
   (`column`, `type`, `natural_key` for create_only collisions,
   `not_found`).
4. `domain`: `judge.rs` on the account's resident kernel: pipeline moves,
   fire hold, heat caps without an override (`heat`, `fire_hold`,
   `stage`, `lineage_busy`, `cooldown`).
5. `provenance`: metrics need `as_of` (`freshness`), older than stored
   `_on` (`stale`), prose needs `expect_rev` (`rev`) and a source
   (`source_missing`), culture and rating sources on `trusted_hosts`
   (`source_trust`).
6. `limits`: `too_large` (1 MiB), `rate` (`Security.limit(:agent_write,
   key_id)`, 600/min), `cap` (rows per table per account, from the schema
   file: places 100k, corporations 50k, contacts 50k, messages 200k,
   citations 5M, applications 50k).

Then the write, one citation per metric/prose cell, `rev + 1`, the ledger
entry, the delta to subscribers and to the sequencer's own kernel.

## Lease and keys

- One lease per session; taking it opens the write channel. Browser
  sessions hold one implicitly.
- Claims are explicit application ids, not number blocks: `lease
  {"count":16}` claims the 16 highest-ranked unclaimed applications in
  board order (what an agent actually wants to work on), `lease
  {"ids":[...]}` names them, `lease {"stage":"draft_ready","count":8}`
  filters by stage. Applications the agent creates are claimed by it.
  The buddy allocator goes.
- Lifetime = the session. `leases` on the wire carries `since`; the
  account page lists live leases with a revoke.
- Keys: `read_mask`, `write_mask` over world 1, desk 2, mail 4, lanes 8,
  corpus 16; `may_delete`. Presets: read only, write only, read/write,
  custom. Mint, widen and `may_delete` need step-up; any change sends
  `BYE grants`. `system` tables and `citations`/`trusted_hosts` are in no
  mask.

## Web

```
assets/
  css/app.css
  js/
    early.ts      inlined in <head>: connect, compile wasm, read snapshot
    app.ts        boot
    wire.ts       carriers (WebTransport, WebSocket), framer
    kernel.ts     wasm bindings over gen/schema.ts
    state.ts      the model: address, lens, selection, pending notices
    morph.ts      escaping templates and the DOM morph (old html.ts)
    lenses/desk.ts focus.ts world.ts atlas.ts outreach.ts lanes.ts account.ts
    auth/sign_in.ts factor.ts webauthn.ts
    gen/schema.ts emitted
```

State is the kernel's rows plus `state.ts`; every lens is model in, HTML
out, morphed, except the board's cards, written value by value. A write is
judged and applied locally by the kernel in the input's frame, then settled
or rolled back by ACK/NACK, as today. The account lens speaks `account.*`
RPC; sign-in and the factor page stay HTTP forms. `kernel.wasm` is built
by Nix and by a mix alias in dev, never committed.

## Release, edge, nix

- `flake.nix`: packages `hireme` (OTP release with the NIF and
  `hireme-gate`), `hireme-mcp`, `kernel-wasm`; `nixosModules.hireme` as
  committed in `1157dbe` (proxy, vault, gate forwarding); `nix/deploy.sh`;
  `checks.dev` (the VM) and `checks.unit` (mix test, cargo test, tsc).
- Baseline DB: `Hireme.Release` applies `priv/db/baseline.sql` to an empty
  database, then the additive files in order, under the sidecar exclusive
  lock. Backups daily by `VACUUM INTO`, 13 kept. Drain: BYE `restart` to
  every session, 5 s, then the node stops the gate.
- Cutover: the v1 database file is deleted; v2's baseline creates a
  fresh one.

## Security

Same standards (NIST SP 800-63B-4, OWASP ASVS 5.0, CIS v8.1, WebAuthn L3),
same mechanisms rebuilt: `__Host-` session cookie, server-side sessions,
pending-MFA gate, 5-minute step-up, TOTP + passkeys + recovery codes, no
SMS or email factors, CSP, named limits in `security.ex`. New: masks,
`human_only` commands, `BYE grants`, server-derived source hosts, citations
out of every mask, an `audit` row for every agent write batch (key, lease,
ops, outcome counts), raw text marked untrusted in MCP replies.

## Tests, parity, bench

- One behavioral suite per public contract, driven through that contract
  only: `test/hireme/{sequencer,grants,lease,world,provenance,import,accounts,keys,mfa,mail,release}_test.exs`,
  `test/hireme_web/{session,sign_in,account,gate}_test.exs`, `native/kernel/tests/*.rs`,
  `assets` through the kernel's own tests. Seeded property tests where a
  rule has a law (base ⊕ deltas = fresh read; a resend writes nothing;
  `stale` is monotonic; masks never leak a row).
- Parity becomes trivial: the same `kernel` test vectors run native and
  under wasm (`node native/kernel/wasm_test.mjs`). The Elixir oracle is not
  rebuilt.
- Bounds (bench, not prose): BOOT deflated <= 2 MiB at 10k applications
  with `listing_raw` deferred; PATCH <= 64 KiB per burst; full board
  derive <= 8 ms in wasm at 10k; `judge` <= 200 µs per op in the NIF
  (dirty scheduler past 1 ms); `find` p99 <= 10 ms at 50k places; op round
  trip p50 <= 5 ms on loopback.

## Nuke manifest

| v1 | v2 owner |
| --- | --- |
| `lib/hireme/ops.ex`, `store.ex` | `sequencer.ex`, `store.ex` (rewritten) |
| `lib/hireme/desk.ex`, `pipeline.ex`, `heat/*`, `life_ev.ex` | `native/kernel` (`judge`, `pipeline`, `heat`, `ats`, `org`, `score`) |
| `lib/hireme/letterbox.ex` | `lease.ex` |
| `lib/hireme/api_keys.ex` | `keys.ex` |
| `lib/hireme/cv.ex` | `native/kernel/src/cv.rs` + puts on `profiles`/`items` |
| `lib/hireme/gym.ex`, `net.ex` | puts on `gym_reps`/`net_entries` + `kernel/lanes.rs` |
| `lib/hireme/import.ex` | `import.ex` (rewritten over put) |
| `lib/hireme/mailer.ex`, `cloudflare_mail.ex` | `mail.ex` |
| `lib/hireme/mfa/*`, `accounts.ex`, `security.ex`, `audit.ex`, `release.ex` | same names, rewritten |
| `lib/hireme/schema.ex`, `types.ex` | `schema/hireme.schema` + `schema.ex` (macros) |
| `lib/hireme_web/packet.ex` | `wire/codec.ex` |
| `lib/hireme_web/*` others | same roles, rewritten |
| `priv/wire/schema.txt` | `schema/hireme.schema` |
| `priv/repo/migrations/*` | `priv/db/baseline.sql` |
| `native/{wire,kernel,mcp,gate}` (4 lockfiles) | `native/` workspace, 6 crates, 1 lockfile |
| `priv/static/wasm/kernel.wasm` | built, not committed |
| `test/support/oracle.ex`, `test/oracle/`, `native/kernel/parity.mjs`, `frames.mjs` | deleted, not replaced |
| `assets/js/*` | `assets/js/` tree above |
| `bench/*` | `bench/` rewritten against v2 bounds; `bench/results/*.gz` deleted |
| `alchemy/*.md` | `docs/heat.md`, `docs/score.md` (the rules' prose next to `heat.rs`, `score.rs`) |

Untouched: `nix/module.nix`, `nix/package.nix` (adjusted for the NIF and
wasm), `nix/deploy.sh`, `secrets/`, `LICENSE`, `SECURITY.md` (rewritten
to the new mechanisms).

## Cutover acceptance

1. `rg` finds no v1 module name, no `job_apps`, `letterbox`, `packet`,
   `kv_pairs`, `geography`, `oracle`.
2. `mix test`, `cargo test --workspace`, wasm vectors, `tsc`, `nix flake
   check` (dev VM included) pass.
3. A fresh account signs in by email link, enrolls a passkey, mints a
   read-only and a write-only key; the read-only key's put is `scope`, the
   write-only key's BOOT is empty and its put ACKs an id.
4. An agent leases 16, moves one to `draft_ready`, adds a corporation with
   a cited headcount and an office; the browser shows all three without
   reload.
5. Bounds above hold on the bench.

## Refused

- A second implementation of any rule in Elixir.
- The parity oracle and its fixtures.
- Committed build outputs (`kernel.wasm`, bench result archives).
- `kv_pairs` and any key/value side table; `settings` is one typed row.
- The buddy allocator and number-range leases.
- `claims`, squads, scoreboard snapshots, freshness verdicts as a table.
- String-typed op fields cast by Ecto.
- Four Cargo lockfiles.
- Any personal datum in source (`@local_desk`).

## The v1 data

> "The application is preprod and has 0 users."

v2 starts empty. The cutover deletes the v1 database file; the node's
existing daily backups are the only copy kept. No export, no rescue
script, no archive.

## Review of `docs/rebuild-whalechan.md`

### Where it is wrong, under-specified, or too clever

1. **Architecture, promise 1; Kernel; Testing.** Rules still live twice:
   the server decides in Elixir (`desk.ex` heat and pipeline,
   `commands.ex`) and the kernel predicts in Rust, held together by
   `oracle.ex` + `parity.mjs`. That is the v1 duplication rebuilt on
   purpose. Make the kernel the authority too (Rustler NIF in the
   sequencer); delete the oracle instead of rewriting it.
2. **Data model, Resident and Desk/corpus.** A nuke that carries
   `kv_pairs`, `claims`, `scoreboard_snapshots`, `cv_variants`,
   `narratives` and `gym_problems` forward unexamined. `kv_pairs` is the
   soup the operator rejected; `claims` and squads serve a campaign mode
   nothing uses. Fold into one `settings` row per account (gym target, net
   lane, passports, languages, field, atlas weights, goals, heat config),
   `profiles.narrative`, `applications.cv_theme`, fat `gym_reps`; drop
   `claims` and snapshots. `atlas_profile` becomes columns of `settings`.
3. **The schema compiler, the declaration.** An Elixir DSL that names
   `Hireme.Pipeline.keys()` makes the stage enum Elixir code while the
   pipeline's rules are the kernel's; Rust and TS can only see it through
   committed emissions. Put the declaration in a neutral text file
   (`schema/hireme.schema`) that `build.rs`, the Elixir macros and the
   mix task all parse; enums are declared there.
4. **The schema compiler, "migrations are generated, never
   hand-written".** A diff cannot tell a rename from drop+add and cannot
   choose what to do with data on a narrowing change. Generate additive
   changes; require destructive ones by hand, named `drop_*`, reviewed.
5. **Wire v2, OP body.** Fields "in the order the declaration names them"
   as length-prefixed strings cannot express a sparse put (which 3 of 120
   columns?) without padding every column, and makes the server cast
   strings. Cells need a `col_id` and a wire type each; `as_of`/`source`
   as reserved col ids.
6. **Wire v2, frames.** `LEASE 32` survives beside RPC `lease`/`release`:
   two lease paths. The HELLO answer that carries masks and `schema_rev`
   has no frame (name it `WELCOME`). Drop `LEASE`.
7. **Wire v2, large text; Bounds.** `listing_raw` resident with keyword
   extraction on the client, and an 8 MiB BOOT bound, buys a slow first
   paint to defer a decision. With the kernel on the server, keywords are
   extracted once at write time into `applications.keywords`, so
   `listing_raw` is deferred from day one and BOOT can be held to 2 MiB.
8. **Leases and keys.** The buddy allocator survives the nuke. Number
   blocks were a v1 artefact of entries 1..n; an agent wants "the next 16
   applications worth working". Claim by explicit ids, by count in board
   order, or by stage + count; claims are an id set.
9. **The product; Web.** No `world` or `outreach` lens: corporations,
   places, contacts and messages are reachable only by agents. The
   operator asked for those tables; the operator needs to see and correct
   them, with each cell's `_on` and citations.
10. **Elixir tree.** `wire.ex`, `wire/session.ex`, `wire/ws.ex` under
    `lib/hireme/` puts the wire format outside the web boundary (the
    tree's own convention: wire formats live in `hireme_web/`);
    `atlas.ex` "delegation notes" is a module with no algebra or state
    (law 10). `pages/account.ex` as server-rendered EEx loses live
    updates (a revoke elsewhere) and still needs JS for passkey
    enrollment; the account lens should ride the wire as RPC.
11. **Release and edge; manifest.** "The committed wasm kernel" and
    committed cross-language emissions keep build outputs in git. Build
    `kernel.wasm` in Nix (and a mix alias in dev). `nix/edge.nix` splits
    what `1157dbe` already shipped inside `nix/module.nix` behind
    `public.enable`; that is churn, not design.
### Three ideas from mine that yours is missing

1. **The kernel judges on the server** (NIF): predict and verdict are one
   function, the oracle and parity suite are deleted, and server-side
   derivations (keywords at write, Life-EV suggestion, heat) cost nothing
   extra.
2. **`settings`: one fat typed row per account**, replacing `kv_pairs`,
   `atlas_profile`, `scoreboard_snapshots` and `geography_profiles`, and
   the folds that remove `cv_variants`, `narratives`, `gym_problems`,
   `claims`, `freshness_verdicts`.
3. **Typed cells on the wire, keywords extracted at write time**: sparse
   puts by `col_id`, no string casting, `listing_raw` deferred from the
   first BOOT, BOOT <= 2 MiB at 10k applications.

### File tree

```
schema/hireme.schema
lib/hireme/
  application.ex repo.ex schema.ex store.ex sequencer.ex kernel.ex grants.ex
  lease.ex world.ex provenance.ex import.ex accounts.ex keys.ex mfa.ex
  mfa/webauthn.ex security.ex audit.ex mail.ex release.ex
lib/hireme_web/
  endpoint.ex router.ex auth.ex sign_in.ex factor.ex session.ex gate.ex
  account.ex wire/codec.ex
lib/mix/tasks/hireme.ex
priv/db/baseline.sql
native/Cargo.toml Cargo.lock
native/schema/  native/wire/  native/nif/  native/gate/  native/mcp/
native/kernel/src/
  rows.rs judge.rs pipeline.rs heat.rs ats.rs org.rs score.rs keywords.rs
  cv.rs board.rs atlas.rs lanes.rs compose.rs abi.rs lib.rs
native/kernel/tests/  native/kernel/wasm_test.mjs
assets/css/app.css
assets/js/
  early.ts app.ts wire.ts kernel.ts state.ts morph.ts
  lenses/{desk,focus,world,atlas,outreach,lanes,account}.ts
  auth/{sign_in,factor,webauthn}.ts
  gen/schema.ts
test/hireme/{sequencer,grants,lease,world,provenance,import,accounts,keys,mfa,mail,release}_test.exs
test/hireme_web/{session,sign_in,account,gate}_test.exs
test/support/{data_case,conn_case,fixtures}.ex
bench/{boot,ops,find,derive,gate}.*
docs/{heat,score}.md  README.md  SECURITY.md
flake.nix flake.lock nix/{package,module}.nix nix/deploy.sh
config/{config,dev,test,prod,runtime}.exs mix.exs mix.lock
```
