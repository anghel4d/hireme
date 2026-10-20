# Rebuild

This is the design hireme is built to. One Rust kernel holds every rule
and runs in the browser (wasm) and in the sequencer (NIF, which also
answers MCP), so a prediction and its verdict are one function. One
declaration, `schema/hireme.schema`, emits the database, the Ecto rows,
the wire catalog, the Rust constants and the TypeScript types. Tables the
kernel derives from are resident on the wire; the world (places,
corporations, offices, sources, citations) and the mail (contacts,
messages) are read server-side. Every write is a `put`, `drop` or
`command`, judged in six checks by one sequencer per account. A lease
opens an agent's write channel; a key's read and write masks bound it.
v2 starts from an empty database.

The nuke is the premise. A replaced file is deleted and its replacement is
written as if the old one never existed. No compatibility paths, no dual
readers, no "keep this until phase 3". The cutover commit is the nuke.

## The operator's mandate

> I am expanding the scope of the redesign to encompass the entire application. Every single elixir, rust, and web file is in scope. We are doing it all over and performing a major overhaul, on one condition: everything replaced completely NUKES the old file and old thing, and reinvents it from scratch. There is no room for partial migration here.

> You should both design the whole, than converge, is the unique thought I had just now.

The original ask, verbatim, the product truth:

> Let's get creative and design an ideal system. Right now, the MCP allows reads in a very narrow sense I am a little unhappy with. MCPs cannot yet write in any useful sense. What I need is that a connected AI agent should be given a full duplex (r/w) channel when it gets a "lease", and that it should be able to add new data. In this system, that being hireme, we care about it like this:
>
> 1. A country: its population, gdp, gdp per capita, PPP, QoL ratings, energy consumption, energy production, energy consumption per capita, energy production per capita, etc. Date of last update for each of those rows. Think of data-oriented programming designs and fat structs: this is a fat table with all those rows and more as needed. Not a soup of many different tables and schemas.
>
> 2. A city. Same info as above (particularly a city's pop count, demographics, economics, liveability metrics, energy use / production). A col for the country it belongs to.
>
> 3. A corporation. The cities it has offices in. Its headcount, known economics (if private, valuations raised, estimated revenue, if public, its known market cap, revenue, p/e ratio). Fat table, many columns, nullables are ok (and this applies to every table btw, its a pricniple of modern data-oriented design to have sparse matrices). A row description-blob about what the company does, another row for its culture and what people have said its like from reputable sources only (like levels.fyi and stuff, not bottom of the barrel crap).
>
> Job listings themselves are folded *into* this next table:
> 4. A job application and its progress. The listing this is targetting, along with the entire raw blob of that listing's details/text is just a few more columns here. We do not care about parsing job listings out into more database columns(at all!). Just throw the entire RAW unedited text a job listing came with into this text row, for any given listing. This job listing col is nullable, it can go completely blank, as a job *app* does not require a listing to exist, it can also be done through cold outreach etc.
>
> 5. All misc glue and helping tables related to the above. Eg, email tracking, what emails were sent to whom and the relational ties to what company that has to do with, etc.
>
> This is the broad strokes, you can think of it as an algebraic view of what I want. The database schema itself is yours.
>
> And, we'll need an MCP that securely lets an agent with an API key work on any part of this, with the API-key-provisioning improved so that perms can be a bit more granular (read only, write only, r/w, etc).

## What the nuke rule changes

It repeals every decision made only to avoid churn. Names are re-chosen:

| v1 name | Rebuild | Why |
| --- | --- | --- |
| `job_apps` | `applications` | it is an application |
| `listing` | `listing_raw` | the name says unparsed |
| `letterbox` | `lease` | the capability, not a mailbox |
| `packet` | `hireme_web/wire/codec` | frames and tables are the wire's |
| `employers` | gone | `corporations` owns the company |
| `geography_*` | gone | `places` owns geography |
| `kv_pairs` | `settings` | one typed row, not a key/value soup |
| `narratives` | `profiles.narrative` | one holder, one profile |
| `cv_variants` | `applications.cv_theme` | a theme, not a table |
| `gym_problems`, `gym_reps`, `net_entries` | gone | the lanes went with their lens |
| `claims`, squads, snapshots | gone | campaign scaffolding with no reader |
| `atlas_weights` command | `put` on `me` | weights are a row |
| 13 positional op kinds | `put`, `drop`, `command` | one op grammar |
| buddy-allocated number blocks | explicit application id sets | blocks were a v1 artefact |

It also repeals the migration chain. The rebuild's database is one
generated baseline, and a fresh database is the only supported starting
state.

## The one idea everything hangs on

**One implementation of every rule, run in three places.**

Today the heat governor, keyword coverage, pipeline rules, Life-EV and op
prediction exist twice: in Elixir (the authority) and in Rust
(`native/kernel`, the browser's and agent's prediction), held together by
a parity oracle that dumps both and compares. The rebuild has one
implementation: the Rust kernel judges every domain write on the server
too, linked into the BEAM as a NIF.

- the browser runs `kernel` as WebAssembly;
- the sequencer calls `kernel` through `native/nif`.

Same rows, same function, same verdict. The oracle and the parity suite
are deleted, not rebuilt. Elixir keeps what Elixir is for: order,
transactions, identity, grants, leases, mail, supervision, HTTP.

## What the app is

A personal job-campaign desk for one operator and the agents they lease
to. FIRE HOLD stands: nothing submits an application; naming open fire is
a human act (`open_fire` is a `human_only` command).

One page, one wire session, lenses in the address:

| Lens | What it is |
| --- | --- |
| `desk` | the board: applications ranked by `score_100`, then heat, filtered by band, stage, heat and search; keyboard movement; the scoreboard |
| `focus` | one application: the raw listing, the composed CV through its overlays, the rail, events, its messages and contact, its corporation |
| `world` | corporations and places as sortable sparse grids; every cell shows its `_on` and opens its citations; edits write through `put` |
| `atlas` | every country and city ordered for the person behind the account (`me`: citizenships, permits held, languages, the countries wanted or never wanted, weights over any figure of `places`); each figure shown as itself with its `_on` and citations; the order only sorts |
| `outreach` | contacts and message threads, tied to corporations and applications |
| `account` | identities, factors, sessions, keys with masks, live leases with revoke, trusted hosts |

HTTP-only ceremonies: sign-in (email link, GitHub, X) and the factor
page. The account lens rides the wire, so a revoke elsewhere appears
without a reload; only passkey ceremonies need a small script.

## The schema compiler

One neutral declaration, parsed once (`native/schema`) and read by every
language. Not an Elixir DSL:
enums and commands belong to the kernel, so the file is the only place
that can name them without a language owning them.

`schema/hireme.schema` is line-oriented text, in the spirit of the old
`priv/wire/schema.txt`:

```
domain world desk mail corpus system

table places world server
  natural iso2 where kind = 'country'
  natural geonames_id where kind = 'city'
  cap 100000
  col kind enum place_kind !
  col country_id ref places
  col iso2 str ?
  col name str !
  metric population u32
  metric gdp_usd f64
  metric energy_consumption_per_capita_kwh f64
  prose liveability text ?
  prose notes text ?

table applications desk resident
  natural canonical_url where canonical_url is not null
  cap 50000
  col no u32 ! unique readonly
  col corporation_id ref corporations ?
  col listing_raw text ?
  col listing_on day ?
  col keywords str ? readonly
  col stage enum stage ! = discovered readonly
  ...
  command stage stage note:text?
  command open_fire human_only

enum stage discovered freshness gated in_batch draft_ready fire_ready open_fire submitted reply closed
enum place_kind country city
enum refusal scope human_only lease_missing leased column type not_found natural_key stage fire_hold heat lineage_busy cooldown freshness stale rev source_missing source_trust too_large rate cap internal
```

The grammar is stated once, in the header of `schema/hireme.schema`, and
the parser refuses anything else. In outline: `domain`, `frame`,
`layout`, `enum`, `table` (residency `resident` | `server` | `wire`, and
`append_only`, `soft_delete`, `global`, `account_optional`, `singleton`),
`projection` with `pick`, `natural`/`unique`/`index` (optionally `where`),
a mandatory `cap` on every stored table, `col`, `metric` (implies
`<name>_on day`), `prose` (implies citation and CAS), and `command`. `id`
and `account_id` are implied, never declared. A `day` is days since
0000-01-01 in the proleptic Gregorian calendar (0 to 3652424, which is
9999-12-31), so an office opened in 1897 is a plain day; a `time` is unix
seconds. Types include `ref <table>`;
flags include `!`, `?`, `= default`, `private`,
`server_only`, `human_only`, `readonly`, `unique`, and `loose` (a plain id
with no foreign key, for references from append-only tables that a purge
must never rewrite).

Emitters (`mix hireme.schema`). `--check`, and `mix test`, fail when a
checked-in output differs from a fresh emit, when the baseline does not
apply, when an existing id moved, or when a frozen baseline no longer matches `priv/db/baseline.lock`.
`--migration NAME` writes an additive step, `--renumber` allows an id move
before the freeze, and `--freeze` locks the deployed baseline at cutover:

| Emitter | Output | Checked in? |
| --- | --- | --- |
| model JSON | `priv/schema.json`, the resolved declaration `Hireme.Schema` and its Ecto row macros compile from | yes |
| baseline SQL | `priv/db/baseline.sql` | yes |
| additive SQL | `priv/db/NNNN_<name>.sql`, declaration minus `PRAGMA table_info` | yes |
| wire catalog | the `catalog` table in every BOOT, built at runtime | no |
| JSON schema | `schema` / `find` / `get` / `put` argument shapes, built at runtime | no |
| Rust constants | `native/schema` crate (its own `build.rs`), a dependency of every crate | no |
| TypeScript | `assets/js/gen/schema.ts` (ids, enums, row interfaces) | yes |

Two hashes, because two different things can change:

- `wire_hash` — frame layouts plus the **resident** tables the kernel is
  compiled against. A change forces a client rebuild.
- `schema_rev` — the whole catalog, server-side tables included. A new
  `places` metric bumps it; the wasm kernel needs no
  rebuild; the browser's checked-in `gen/schema.ts` is re-emitted.

Rules:

- **Same-language generation is compile-time** (Ecto macros, Rust
  constants); **cross-language output is a checked artifact** (SQL,
  TypeScript). The wire catalog and JSON schema are runtime reads of the
  parsed declaration, so they cannot drift.
- **Adding a metric is one line.** Resident tables change `wire_hash`;
  server tables change only `schema_rev`.
- **Migrations are generated additively.** A diff cannot tell a rename
  from drop+add, and cannot decide what to do with data on a narrowing
  change. Additive changes are emitted; a destructive change is written
  by hand as `NNNN_drop_<what>.sql` and reviewed. The baseline is the
  whole schema at cutover.

## Data model

One rule decides residency: **a table is resident iff the kernel derives
from it**, and the corpus (`profiles`, `items`) is resident as a unit.
Everything else is read over RPC, server-side, under `Repo`'s account
predicate.

Every table has `id`, `account_id` (except `accounts`, `magic_links`),
`inserted_at`, `updated_at`, `rev` (+1 per domain write; bookkeeping such
as a key's `last_used_at` does not move it). Soft-delete tables
carry `deleted_at`. Ids and `applications.no` are never reused.

### `system` — server, never key-visible

`accounts` (`name`, `status`, `desk_rev`, `next_no`,
`text_bytes`), `sessions`, `identities`,
`magic_links`, `api_keys` (`read_mask`, `write_mask`, `may_delete`),
`factors` (one fat table for TOTP and WebAuthn), `challenges`,
`recovery_codes`, `audit` (append-only; loose `key_id`/`session_id`),
`outbox`, `op_ledger` (24 h, acknowledged ops only), `trusted_hosts`; and
`schema_files`, the release's own record of applied SQL (not declared).

### `corpus` — resident

`profiles` (`slug`, `name`, `headline`, `summary`, `narrative`,
`narrative_private`), `items` (CV atoms; `profile_id` null = shared),
`me` (one row, the person's own: `citizenships`, `field`, `subfields`,
`residence_id`, `regions`, `relocate`, work modes and employments, pay,
availability, and the atlas's side, `work_permits`, `prefer`, `avoid`,
`notes`, `weights` json over any figure of places; what the atlas orders
by and what an agent drafting for the operator should know, in no key's
hands without the corpus bit), `languages` (a row per ISO 639-1 code with
its level).

### `desk` — resident

| Table | Notes |
| --- | --- |
| `applications` | `no`, `corporation_id`, `place_id`, `contact_id`, `profile_id`, `batch_id`, typed card fields (`company`, `role`, `location`, `work_mode`, `employment`, `comp_raw`), `channel`, listing (`listing_raw`, `listing_format`, `listing_url`, `canonical_url`, `listing_on`, `keywords`, `keywords_version`, `source_id`), pipeline (`stage`, `pips`, `stage_on`, `stage_notes`, `status`, `gate`, `freshness`, `heat_override`, `heat_override_reason`, `score_100`), dates (`applied_on`, `replied_on`, `closed_on`, readonly, written by `stage`; `outcome`), long text (`notes`, `battleplan`, `letter_raw`; plain text, no citation or CAS), `cv_theme` |
| `events` | append-only: `application_id`, `kind`, `body`, `actor`, `key_id`, `op_id` |
| `batches` | `code`, `ordinal`, `kind`, `status`, `fire`, `target_size`, `queued_on`, `note` |
| `cv_lineages` | per corporation: `corporation_id`, `generation`, `opened_on`, `rewrites_allowed`, `theme` |
| `cv_overlays` | `application_id`, `item_id`, `lineage_id`, `mode`, `title`, `body`, `reason`, `generation` |
| `settings` | one fat typed row per account: `goal_total`, `goal_on`, `goal_daily`, `heat_config` (json) |

No parsed listing columns. `keywords` is the kernel's extraction from
`listing_raw`, written once at write time and versioned, and it is what
the CV and coverage derivations read.

### `world` — resident

| Table | Notes |
| --- | --- |
| `places` | countries and cities, `kind` + self `country_id`; identity, demography, economy, liveability, energy, career (`mobility`, `language`, `tech`, `ease`, `work_permit`); every figure a `metric`; prose `liveability`, `notes`; partial uniques for `iso2` and `geonames_id` |
| `corporations` | `domain` natural key; identity, size, private and public economics, comp and reputation, hiring (`careers_url`, `ats`, `ats_tenant`, `remote_policy`), desk columns (`score_100`, `freshness`, `freshness_on`, `eng_urls`, `note`), prose `about`, `culture` |
| `offices` | `corporation_id`, `place_id`, `kind`, `headcount` (metric), `opened_on`; unique triple |
| `sources` | soft-delete; `url` natural key over live rows, at most 2,048 bytes (refused `type`, "a source URL is at most 2048 bytes", with `max`, before any parsing), its port absent, empty or ASCII digits up to 65535 (WHATWG); `host` server-derived, `publisher`, `title`, `kind`, `retrieved_at`, `doc` (long text); identity fixed once written; a cited source is tombstoned, never deleted |
| `citations` | append-only, `server_only`: `table`, `row_id`, `column`, loose `source_id`, `value`, `as_of`, `actor`, loose `key_id`, `op_id`; indexes `(account_id, table, row_id, column, id desc)` and `(account_id, source_id)` |

`citations` is the only provenance authority. The newest citation for a
cell is the source; the rest are history, series and undo. `trusted_hosts`
is operator-owned, browser plus step-up, in no key's mask.

### `mail` — server-side

`contacts` (`corporation_id`, `place_id`, `name`, `title`, `email`,
`linkedin_url`, `x_handle`, `relation`, `last_touch_on`, `notes`) and
`messages` (`channel`, `direction`, addresses, `subject`, `body`,
`message_id` natural key, `thread_key`, `sent_at`, `status`,
links to corporation, application, contact). No tracking pixels.

Derived on the wire, never stored: `leases` (session label, key, held
application ids, since), `clock`, `catalog`.

Gone with no successor: `claims`, squads, `scoreboard_snapshots`,
`application_event`, the lanes. Folded into a successor (see the rename table):
`kv_pairs`, `cv_variants`, `narratives`, `employers`,
`geography_*`, `freshness_verdicts`.

## Wire v2

Header: `u32 len | u8 kind | u8 flags | u16 wire_hash | u64 rev`, 16
bytes, bodies 8-aligned. Flags: `ZSTD 0x01`, `END 0x02`.

| Frame | Id | Direction | Body |
| --- | --- | --- | --- |
| `HELLO` | 1 | up | credential kind (ticket, key), credential, `snapshot_rev`, `schema_rev`, client label |
| `WELCOME` | 2 | down | account id, session id, session label, `read_mask`, `write_mask`, `may_delete`, `schema_rev`, lease state |
| `BOOT` | 3 | down | every resident table the read mask allows, plus `catalog`, `leases`, `clock` |
| `PATCH` | 4 | down | changed rows (id + moved columns) and `gone` |
| `OPS` | 8 | up | a batch of ops (below) |
| `ACK` | 9 | down | per op: `op_id`, `rev`, `id` for an insert |
| `NACK` | 10 | down | per op: `op_id`, `code` (u16 from the catalog's refusal enum), `data` (json) |
| `TICK` | 11 | down | `clock` |
| `PING`/`PONG` | 13/14 | both | liveness, 15 s interval, 45 s timeout ends the session |
| `RPC` | 33 | up | `u32 id`, method (str), params (json) |
| `REPLY` | 34 | down | `u32 id`, result or error (json) |
| `BYE` | 16 | down | reason (`revoked`, `grants`, `restart`, `schema`, `suspended`) and a message |

There is no `LEASE` frame: lease and release are RPC methods. There is no
`WRITE` frame: `OPS` is the only write path.

An op in `OPS`:

```
u64 op_id
u8  verb          (put 1, drop 2, command 3)
u8  flags         (KEYED 0x01, CREATE_ONLY 0x02, EXPECT_REV 0x04)
u16 table_or_command
u32 target        (row id; 0 when keyed or new)
u16 ncols
u16 0
u32 expect_rev
u16 ncols cells:  u16 col_id | u8 type | u8 0 | u32 len | bytes | pad to 8
```

Cells are **named and typed**: a sparse put sends only the columns it
changes, each with its wire type, and the server does not cast strings.
`as_of` and `source` are reserved column ids (`0xFFF0`, `0xFFF1`). A
command's params are its declared columns or typed free params. One op carries up to 1 MiB of
text (`too_large` past it); one `OPS` frame carries up to 256 ops.

Texts travel whole in BOOT/PATCH, packed at rest and read on touch: a
text column is a zstr run whose cells of 256 bytes or more are zstd 19
against `priv/wire/text.zdict`, unpacked one by one (`wire::Texts`). A
BOOT or PATCH body of 256 bytes or more is shuffled (byte planes) and
packed with zstd 9 against `priv/wire/frame.zdict`. Both dictionaries
are declared in the schema (`dict` lines), so retraining one moves
`wire_hash`. Every read (`find`, `get`, `text`,
`history`) is the replica's own: the browser's kernel answers it
locally, and MCP's is answered from the sequencer's kernel under the key's
grants. The RPC methods left are `account.*` (the account
lens) and `lease.*`.

## Kernel and NIF

One Cargo workspace, `native/Cargo.toml`, one lockfile:

| Crate | Role |
| --- | --- |
| `native/schema` | parser + emitters for `schema/hireme.schema`, also a small binary for the mix task |
| `native/wire` | frame codec |
| `native/kernel` | rows, derivations, judging; core is embeddable, `wasm32` and native targets |
| `native/nif` | Rustler wrapper of `kernel` for the sequencer |
| `native/gate` | WebTransport front door |
| `native/mcp` | the MCP surface, linked into the NIF and served at `/mcp` |

Kernel modules, one owner each:

| Module | Owns |
| --- | --- |
| `rows.rs` | resident columns, BOOT/PATCH ingest, base ⊕ pending, deltas |
| `judge.rs` | every domain check of a put, drop or command; returns the refusal code and its data |
| `pipeline.rs` | stages, pips, rail encode/decode, legal moves, fire hold |
| `heat.rs` | decaying company/vendor loads, caps by size tier, department and clone penalties, mix |
| `ats.rs` / `org.rs` | vendor and tenant from an apply URL; size tier, department, role family |
| `score.rs` | Life-EV anchors, band ladder, hard-kill floor; suggests, never overwrites |
| `keywords.rs` | target words from `listing_raw`, and coverage by the composed CV |
| `cv.rs` | a CV composed from items through the lineage's overlays |
| `board.rs` | order, filter, select, search, keyboard geometry |
| `atlas.rs` | route, language match, the person's weighted figures ranked within kind, the order — the only copy |
| `text.rs` | Unicode-safe normalising and folding every text reader shares |
| `compose.rs` | the documents the focus lens and the MCP read |
| `abi.rs` | wasm exports; native facade for the NIF and MCP |

### One authority, one cache

SQLite is the authority. The sequencer's kernel resource is a cache of the
account's resident rows, built from SQLite at boot and after any restart,
and fed the same deltas subscribers get in the same sequencer turn.

- `judge` is pure and fast (< 200 µs); past 1 ms it moves to a dirty
  scheduler. A NIF panic is caught, the resource rebuilt from SQLite, and
  the op retried once or refused `internal`.
- A property test proves `base ⊕ deltas = fresh read` for every resident
  table, and a resync path exists for recovery.
- The browser and the MCP hold the same base rows and apply the same
  deltas; they call the same `judge`. Prediction and verdict cannot
  disagree by construction, so the oracle and parity fixtures are gone.

### Keywords at write time

On `put` of `listing_raw`, the sequencer runs `keywords.rs` over the raw text and stores
`applications.keywords` + `keywords_version`. The CV composition and
coverage read the extracted words, not the blob. A kernel upgrade that
changes extraction bumps the version and re-extracts in a backfill task;
clients never need the raw listing to derive.

## Elixir

```
lib/hireme/
  application.ex   supervision: Repo, Store, PubSub, rate limits, tickets, the audit coalescer, Registry, Sequencer.Supervisor, Release, Mail, Gate, Endpoint, Drain
  repo.ex          tenancy: put_account/1, every read scoped, skip_account explicit; SQLite pragmas
  schema.ex        compile-time reader and row macros
  store.ex         the writer lock (granted in order), savepoints, VACUUM INTO
  sequencer.ex     one process per account: order, batch of 64, transaction, ledger, rev, deltas
  kernel.ex        the NIF: one kernel resource per sequencer
  grants.ex        masks, presets, domain of a table or command
  lease.ex         the channel, application claims, since, operator revoke
  provenance.ex    sources (host derived), citations, trusted_hosts
  import.ex        packs (JSON, markdown) lowered to put ops through the sequencer
  accounts.ex      accounts, sessions, identities, magic links
  keys.ex          API keys: mint, authenticate, revoke, mask changes
  mfa.ex           TOTP, recovery codes; mfa/webauthn.ex internal
  security.ex      policy numbers and named limits
  audit.ex
  mail.ex          outbox, Cloudflare Email Sending adapter, notices
  release.ex       baseline + additive migrations, backup
lib/hireme_web/
  endpoint.ex router.ex auth.ex sign_in.ex factor.ex
  session.ex       one wire session per tab or agent: HELLO, masks, BOOT filter, OPS, RPC, BYE
  gate.ex          the BEAM end of the gate
  account.ex       account.* RPC methods (a projection, never raw system rows)
  wire/codec.ex    frame codec, layouts from the schema file
lib/mix/tasks/hireme.ex   schema, import
```

Boundaries: row modules exist only in `schema.ex`; the sequencer is the
only writer of account tables (`import` writes through it); `world` is the
only reader of server-side tables; `hireme_web/session` never touches a
table directly; `accounts`/`keys`/`mfa` never touch desk rows; `release`
runs SQL, not domain code.

### The sequencer's checks

Per submission, before any op: a key's `:agent_write` circuit breaker (clear
abuse only, not a pace), which a lease's bulk contract stands outside of up
to its count. Then, per op and inside its savepoint,
in this order:

1. **grant** — write mask covers the domain (`scope`); drop needs
   `may_delete`, and a key may not drop a row a loose ref names, such as
   a cited source (`scope`); a keyed op needs the read bit too; a
   `human_only` command or column from a key (`human_only`).
2. **lease** — the session holds the channel (`lease_missing`); an
   agent's write to an application held by another session (`leased`;
   the operator's browser session is exempt, see 'Lease and keys'); a
   paused key's write (`lease_missing`, "paused by the operator").
3. **shape** — table, columns, types, natural key exist and are writable
   (`column`, `type`, `not_found`; `natural_key` when a `create_only` key
   already exists, or when a keyed op's cells hold none of the table's
   natural keys: its data lists every key as `{cols, where, reads}` and,
   under `unmet`, the keys whose columns were given but whose condition
   failed, with the condition columns `missing`; and any other unique
   violation). `expect_rev` applies to any verb. Every refusal carries a
   `reason` naming the cause in the server's words.
4. **domain** — `judge.rs` on the sequencer's kernel: pipeline moves, fire
   hold, heat caps without an override, lineage and cooldown (`stage`,
   `fire_hold`, `heat`, `lineage_busy`, `cooldown`).
5. **provenance** — metric without `as_of` (`freshness`), an `as_of` in
   the future (`freshness`), older than the stored `_on` (`stale`), prose
   without `expect_rev` (`rev`) or source (`source_missing`, also for an
   id that is no live source), culture/rating hosts (`source_trust`).
6. **limits** — `too_large` (1 MiB of text in one op, checked with
   shape), `cap` (every stored table's declared row cap), and at commit
   the account's text budget (`cap`, 1 GiB).

Then the write, one citation per metric/prose cell, `rev + 1`, the ledger
entry (acknowledged ops only; a resend is answered from it, a refused op
is judged again), and the delta to subscribers and to the sequencer's
kernel. A put that restates its row exactly (every cell as stored and, for
a cited cell, the same `as_of` and the same source as its last citation)
is acknowledged at the row's current `rev` and writes nothing; the same
value from another source is cited, as corroboration. The rule is per
cell: a put that changes some cells cites only the cells it changes or
corroborates. A restatement is decided before the limits check, so at a
cap it is still acknowledged.

## Lease and keys

- **One lease per session**; taking it opens the write channel for the
  key's domains. A browser session holds one implicitly.
- **Claims are explicit application ids**, not number blocks. `lease
  {"count":16}` claims the 16 highest-ranked unclaimed applications in
  board order; `lease {"ids":[...]}` names them; `lease
  {"stage":"draft_ready","count":8}` filters. An agent's new applications
  are claimed by it. The buddy allocator is gone. Claims keep agent
  sessions off each other's applications; the operator's browser session
  is never refused `leased` (the owner's write, a human act like
  `open_fire`, always lands, and the claiming agent sees it as a PATCH and
  has its pending ops judged at their turn as usual). An operator lease revoke pauses that key: none of its sessions may open
  the channel or claim (refused, "paused by the operator") until the operator
  resumes it from the account lens or the key is revoked. The revoke ends
  each of that key's sessions with the reason "paused by the operator" and
  `paused: true`, never advice to reconnect.
- `lease.claim` needs desk read and write, takes at most 1,000 ids per
  request, and answers the ids granted; a `count` larger than the
  unclaimed set grants what exists with a `truncated` warning; naming an
  id another session holds is refused `leased` with that session's label
  and `since`; nothing is partially granted for `ids`.
- Lifetime is the session: `release`, exit, key revoked, mask changed,
  account suspended, or operator revoke. `leases` carries `since`. No TTL;
  liveness is the carrier and PING/PONG (15 s / 45 s, stated in
  `SECURITY.md`).
- **Keys**: `read_mask`, `write_mask` over world 1, desk 2, mail 4,
  corpus 8; `may_delete`. Presets: read only, write only,
  read/write, custom. Mint, widen and `may_delete` need step-up; a change
  sends `BYE grants`. `system` tables, `citations` and `trusted_hosts` are
  in no mask. A key never mints keys.

## The MCP

The node serves MCP over HTTP at `/mcp` (`HiremeWeb.Mcp`): the API key is
the bearer token, checked before the body is read, and each MCP session is
a wire session the node holds for the key, so grants, lease, revocation and
verdicts are a carrier's. A request without a valid key is a strike against
its address; past five in an hour the address is banned for good and
refused before anything of a request is read. Reads answer from the
sequencer's kernel under the key's grants; writes are encoded by the NIF
(`native/mcp`). A lease with `bulk: n` grants a contract for n writes, and
a put under it is one atomic burst. Tools: `hireme`
(overview, masks, lease, next step), `schema`, `find`, `get`, `text`,
`history`, `put`, `drop`, `lease`, `release`, and one tool per declared
command (generated from the catalog; a `human_only` command is never
listed). Tools the key's masks forbid are not listed. Rows are MCP
resources (`hireme://corporations/<domain>`, `hireme://places/<iso2>`,
`hireme://applications/<no>`) with `resources/subscribe`. A blank call
prints the call shape; a refusal is a rustc-style diagnostic with
`hireme {"explain":code}`; raw text (`listing_raw`, `body`, prose) is
returned marked untrusted.

## Web

```
assets/
  css/app.css
  js/
    early.ts      inline in <head>: connect, compile wasm, read snapshot
    app.ts        boot
    wire.ts       carriers (WebTransport, WebSocket), framer
    kernel.ts     wasm bindings over gen/schema.ts
    state.ts      model: address, lens, selection, notices
    morph.ts      escaping templates and keyed DOM morph
    lenses/desk.ts focus.ts world.ts atlas.ts outreach.ts me.ts trail.ts account.ts
    auth/factor.ts webauthn.ts   (sign-in itself is plain HTML forms)
    gen/schema.ts emitted
```

- No framework. `state.ts` holds the model, the one shared state; the
  transport, the kernel bindings and a lens may keep their own bookkeeping
  (in-flight counters, the entered address), never the model. Every lens is
  model in, HTML out, morphed keyed, except the board's cards, written value by
  value. Focus preservation is a requirement, not a nicety.
- A write is judged and applied locally by the kernel in the input's
  frame, then settled or rolled back by ACK/NACK.
- The account lens speaks `account.*` RPC; sign-in and the factor page
  stay HTTP forms; the factor page's passkey assertion is its one script
  (`auth/factor.ts`); enrollment lives in the account lens.
- The `world` lens is a sparse grid: columns are the declared fields, a
  cell shows `_on` and opens its citations; empty is empty, not a dash.
  The `outreach` lens is contacts and threads keyed to corporations and
  applications. These are operator surfaces for the data agents write.
- `kernel.wasm` is built by Nix and a mix alias in dev, never committed.

## Release, edge, nix

- `flake.nix`: packages `hireme` (OTP release with the NIF and
  `hireme-gate`), `kernel-wasm`; `nixosModules.hireme`
  (proxy and its query-free log format, vault, gate forwarding, deploy
  script);
  `checks.dev` (the VM) and `checks.unit` (mix test, cargo test, bun check).
- Baseline: `Hireme.Release` applies `priv/db/baseline.sql` to an empty
  database and records every additive file present as contained; an
  existing database runs only the files it has not recorded, in order,
  under the sidecar lock. Backups daily by `VACUUM INTO`, the newest 13 of
  v2's own prefix kept (v1's backups are never pruned automatically). SIGTERM drains with BYE `restart`, 5 s,
  then the node stops the gate.
- Nix builds the wasm, the NIF and the release; no build output is
  committed. `nix build --rebuild` proves reproducibility.

## Security

Same standards (NIST SP 800-63B-4, OWASP ASVS 5.0, CIS v8.1, WebAuthn
L3), same mechanisms rebuilt: `__Host-` session cookie, server-side
sessions, pending-MFA gate, five-minute step-up, TOTP + passkeys +
recovery codes, no SMS or email factors, CSP, named limits.

New: masks enforced on BOOT, PATCH and every RPC; `human_only` commands;
`BYE grants`; server-derived source hosts; citations and trusted hosts out
of every mask; an audit row per agent op batch within a per-account activity
budget, past which activity is coalesced into one counted row per window
(each key's first connection from an address is always its own row); the
node has a ceiling on activity rows per window across all accounts, and
past it each account still keeps a floor of 100 rows per window; raw
text marked untrusted
in MCP replies; an operator revoke for leases and sessions; the carrier
timeout written down.

## Tests, bench, bounds

- One behavioral suite per public contract, through that contract only:
  `test/hireme/{sequencer,grants,lease,world,provenance,import,accounts,keys,mfa,mail,release}_test.exs`,
  `test/hireme_web/{session,sign_in,account,gate}_test.exs`,
  `native/kernel/tests/*.rs`, and the wasm vectors.
- Seeded property tests where a law exists: base ⊕ deltas = fresh read; a
  resent op writes nothing; `stale` is monotonic; masks never leak a row;
  a refusal rolls back exactly one op.
- The kernel's own vectors run native and under wasm. No Elixir oracle, no
  parity fixtures.
- `bench/` is rewritten for v2.
- Bounds: BOOT ≤ 2 MiB packed (ZSTD) at 10k applications; PATCH ≤ 64 KiB per burst; board derive after a change ≤ 8 ms in
  wasm at 10k, and the first derive after BOOT (which follows the snapshot's
  paint) ≤ 30 ms on the worst-case bench desk; `judge` ≤ 200 µs in the NIF; op
  round trip p50 ≤ 5 ms on loopback; 256 ops per `OPS` frame.

## The nuke manifest

Everything below was deleted at cutover (`f8430dd`); no shim was left
behind. A v2 file may carry text quarried from v1, as the operator allowed:
"Anything from those can be stolen as needed only."

| v1 | v2 owner |
| --- | --- |
| `lib/hireme/ops.ex`, `store.ex` | `sequencer.ex`, `store.ex` (rewritten) |
| `lib/hireme/desk.ex`, `pipeline.ex`, `heat/*`, `life_ev.ex` | `native/kernel` (`judge`, `pipeline`, `heat`, `ats`, `org`, `score`) |
| `lib/hireme/letterbox.ex` | `lease.ex` |
| `lib/hireme/api_keys.ex` | `keys.ex` |
| `lib/hireme/cv.ex` | `native/kernel/src/cv.rs` + puts on `profiles`/`items` |
| `lib/hireme/gym.ex`, `net.ex` | gone with the lanes |
| `lib/hireme/import.ex` | `import.ex` (rewritten over put) |
| `lib/hireme/mailer.ex`, `cloudflare_mail.ex` | `mail.ex` |
| `lib/hireme/{accounts,security,audit,release}.ex`, `mfa/*` | same roles, rewritten |
| `lib/hireme/schema.ex`, `types.ex` | `schema/hireme.schema` + `schema.ex` macros |
| `lib/hireme_web/packet.ex` | `hireme_web/wire/codec.ex` |
| `lib/hireme_web/*` (all) | same roles, rewritten |
| `lib/mix/tasks/hireme.ex` | `mix hireme.schema`, `mix hireme.import` |
| `test/**/*.exs` | new suites, one per contract; oracle and parity deleted |
| `native/{wire,kernel,mcp,gate}` sources (16 files) and 4 lockfiles | `native/` workspace, 6 crates, 1 lockfile |
| `priv/wire/schema.txt` | `schema/hireme.schema` |
| `priv/repo/migrations/*.exs` | `priv/db/baseline.sql` + additive files |
| `priv/static/*` (v1's `priv/static/wasm/kernel.wasm`) | built artifacts, not committed |
| `assets/js/*`, `assets/css/*` | the tree above |
| `config/*.exs`, `mix.exs`, `.formatter.exs`, `.credo.exs` | re-derived for the new tree |
| `bench/*`, `docs/checklist.md`, `docs/performance.md`, `README.md`, `SECURITY.md`, `alchemy/*` | re-authored as `bench/`, `docs/heat.md`, `docs/score.md`, new README and SECURITY |
| `flake.nix` (app half) | re-derived with the NIF and wasm packages |
| `nix/package.nix` | rewritten: release with the NIF, `kernel-wasm` |

Kept: `nix/module.nix`, `nix/deploy.sh`, `secrets/`, `LICENSE`,
`flake.lock` (the nixpkgs pin), `.gitignore` (the allowlist) and `.agents/`
(team tooling).
Kept as input: the design docs. `seed/` is local, untracked, and not part
of the tree.

## Cutover acceptance

1. A word-bound search finds no v1 identifier (`HiremeWeb.Packet`,
   `Hireme.Letterbox`, `job_apps`, `kv_pairs`, `geography_*`, an oracle or
   parity module or file); Erlang's `:gen_tcp` `packet` options and the
   company Oracle in employer data are not v1 names.
2. `mix test`, `cargo test --workspace`, the wasm vectors, `bun check`, and
   `nix flake check` (dev VM included) pass.
3. A fresh account signs in by email link, enrolls a passkey, mints a
   read-only and a write-only key; the read-only key's put is `scope`; the
   write-only key's BOOT is empty and its put ACKs an id.
4. An agent leases 16, moves one to `draft_ready`, adds a corporation with
   a cited headcount and an office; the browser shows all three without a
   reload.
5. The bounds above hold on the bench.
6. No in-scope v1 file survives as v1 content (the nuke commit removed
   them all; paths reused by v2 rewrites are new files).
7. The cutover deletes the v1 database file; the node's existing daily
   backups are the only copy kept, and v2 never prunes them.

## The v1 data

> "The application is preprod and has 0 users."

v2 starts empty. The cutover deletes the v1 database file; the node's
existing daily backups are the only copy kept. No export, no rescue
script, no archive directory, no archive acceptance step.

The ordinary importer (`mix hireme.import`, the documented pack format)
stays a product feature for new data. It is not a rescue path and has no
reader for the v1 database.

## Refused

- A second implementation of any rule in Elixir.
- The parity oracle and its fixtures.
- Committed build outputs (`kernel.wasm`, bench archives).
- `kv_pairs` or any key/value side table; `settings` is one typed row.
- The buddy allocator and number-range leases.
- `claims`, squads, scoreboard snapshots, freshness verdicts as a table.
- String-typed op fields cast by Ecto.
- Four Cargo lockfiles.
- Any personal datum in source (the old `@local_desk`).
- A compat reader, a rescue export, an archive directory, a dual wire, or
  a "v1 mode" flag.

## Measurements, not decisions

- BOOT at 10k applications with keywords stored: if it exceeds 2 MiB, the next lever is a projection, not a
  compat path.
- The `:agent_write` breaker (100,000/min) and the 64-op batch, against the bench;
  the 15 s/45 s liveness, against a silent session in the final
  certification.
- Whether the gate earns its keep against `wire.ws`; the bench answers,
  and dropping it is a deletion, not a deprecation.
