# Rebuild: whalechan's whole-application design

The redesign is no longer the MCP and its tables. It is the application.
This document designs the whole of it from scratch, under one rule: a
replaced file is deleted, and its replacement is written as if the old one
never existed. No compatibility paths, no dual readers, no "keep this
until phase 3". The cutover commit is the nuke.

`docs/full-duplex-agreed.md` is an input. Its data model, leases, grants
and MCP survive as ideas; its file names, frame layouts and phase plan do
not. Nothing here is a migration of it.

## The operator's mandate

> I am expanding the scope of the redesign to encompass the entire application. Every single elixir, rust, and web file is in scope. We are doing it all over and performing a major overhaul, on one condition: everything replaced completely NUKES the old file and old thing, and reinvents it from scratch. There is no room for partial migration here.

> You should both design the whole, than converge, is the unique thought I had just now.

The original ask (the fat world rows, the application with its raw
listing, the glue tables, the full-duplex lease, the granular keys) is
quoted verbatim in `docs/full-duplex-agreed.md`, and is not restated here.
This document assumes it as product truth and designs the machine that
delivers it.

## What the nuke rule changes

It repeals every decision that was made only to avoid churn. The agreed
document kept `job_apps`, kept `listing`, and kept the 13-op vocabulary
because renaming them cost four languages. In a rebuild those names are
free, so they are re-chosen:

| Agreed name | Rebuild name | Why |
| --- | --- | --- |
| `job_apps` | `applications` | it is an application, not a job app row |
| `listing` | `listing_raw` | it is the unparsed blob, and the name says so |
| `letterbox` | `lease` | the module is the capability, not a mailbox |
| `packet` | `wire.codec` | frames and tables are the wire's codec |
| `employers` | gone | `corporations` owns the company |
| `geography_*` | gone | `places` owns geography |
| `atlas_weights` command | `put` on `atlas_profile` | weights are a row |
| `OP` vocabulary of 13 kinds | `put`, `drop`, `command` | one frame, three op kinds |

It also repeals the old migration chain. There is no `0001..n` history to
preserve. The rebuild's baseline migration is generated from one
declaration and is the whole schema; a fresh database is the only
supported starting state.

## The product, in one page

A local desk for a job hunt, with an agent API.

- **Board.** Every application is a card. Order by Life-EV `score_100`,
  then company heat, then batch, rung and interest. Stage, freshness,
  gate and heat are fields on the card; the board filters by band,
  minimum score, heat, stage and search.
- **Focus and battleplan.** Opening a card shows the composed CV, the
  overlay, the listing, the contact, the thread, the next action and the
  pipeline pips. The battleplan is the same card full-screen.
- **Atlas.** Countries and cities scored against the holder's passports,
  languages, field and weights, on energy, quality of life,
  affordability, language, route, tech and ease. One derivation.
- **Gym and Net.** Conditioning and shipping, on the same strip.
- **Account.** Ways in, factors, sessions, API keys and their masks,
  trusted hosts, leases, audit.
- **Agents.** An MCP server with a full-duplex session, a leased write
  channel, cited writes, and a schema it can read.

The BEAM owns the data and the rules. The browser owns every view: it
holds the resident rows in a WebAssembly kernel, derives the cards, heat,
scoreboard, atlas fit and documents itself, predicts each write, and
settles it on the server's answer. The server sends rows and settles
writes; it never renders a desk view.

## Architecture

```
                    browser (TypeScript)                 agent (MCP)
                    ┌──────────────────┐                 ┌─────────────┐
                    │ views / state    │                 │ tools       │
                    │ kernel (wasm)    │                 │ kernel (lib)│
                    │ wire client      │                 │ wire client │
                    └────────┬─────────┘                 └──────┬──────┘
                             │                                  │
                    WebTransport (QUIC)                  WebTransport
                             │                                  │
                    ┌────────┴──────────────────────────────────┴───────┐
                    │ gate (Rust, quinn): admission, TLS, one session   │
                    └────────┬──────────────────────────────────────────┘
                             │ Unix socket, length-prefixed frames
                    ┌────────┴──────────────────────────────────────────┐
                    │ BEAM: wire.session (one process per session)      │
                    │       ops (one sequencer per account)             │
                    │       world / desk / holder / mail / keys / lease │
                    │       SQLite                                      │
                    └────────┬──────────────────────────────────────────┘
                             │
                    wire.ws (Bandit) as the fallback carrier
```

Three promises hold the shape together:

1. **Rows are the API.** A client is sent raw table rows, never a view
   model. Every derivation lives in the kernel, which is the same Rust
   compiled for wasm and linked into the MCP. The oracle and parity suite
   prove the server's decisions and the kernel's prediction agree.
2. **Writes are ops.** One frame family, three kinds (`put`, `drop`,
   `command`), one sequencer per account, per-op answers, columnar
   deltas back.
3. **One declaration.** Columns, types, metrics, residency, natural keys,
   unique indexes, caps, domains and commands are declared once in
   Elixir; the database baseline, Ecto modules, wire catalog, JSON schema,
   Rust constants and TypeScript types are emitted from it.

## The schema compiler

This is the piece the old app lacked and the rebuild is built around.

`lib/hireme/schema.ex` is data:

```elixir
defmodule Hireme.Schema do
  use Hireme.Decl

  table :places, domains: [:world], resident: false, cap: 100_000 do
    field :kind, :enum, values: [:country, :city], null: false
    field :country_id, :ref, to: :places
    field :iso2, :string, unique: [where: "kind = 'country'"]
    field :geonames_id, :integer, unique: [where: "kind = 'city'"]
    field :name, :string, null: false

    metric :population, :integer
    metric :gdp_usd, :float
    metric :energy_consumption_per_capita_kwh, :float
    prose :liveability
    prose :notes
  end

  table :applications, domains: [:desk], resident: true, cap: 200_000 do
    field :no, :integer, unique: true
    field :corporation_id, :ref, to: :corporations
    field :place_id, :ref, to: :places
    field :listing_raw, :text, deferred: true
    field :listing_on, :date
    field :stage, :enum, values: Hireme.Pipeline.keys()
    ...
  end

  command :stage, args: [:stage], domain: :desk, lease: :block
  command :gym_log, args: [:pairs], domain: :lanes
end
```

From that one declaration:

| Emitted | How | Checked |
| --- | --- | --- |
| Ecto schemas and changesets | compile-time macro expansion (`Hireme.Decl`) | compiler |
| `priv/repo/migrations/0001_baseline.exs` | `mix hireme.schema migration --baseline` | `mix hireme.schema --check` |
| future migrations | `mix hireme.schema diff` (schema vs database) | CI |
| `priv/wire/catalog.txt` | `mix hireme.schema wire` (resident tables only) | `--check`, byte-identical |
| wire hash | FNV-1a over `catalog.txt` | every frame header |
| JSON schema for RPC (`schema`, `find`, `get`) | `mix hireme.schema json` | `--check` |
| `native/wire/src/schema.rs` constants | generated | `--check` |
| `assets/js/schema.ts` types | generated | `--check` |
| mask bits, caps, private columns | runtime metadata | unit |
| command table (names, args, domain, lease) | runtime metadata + wire catalog | unit |

Rules:

- **Same-language generation is compile-time.** Ecto modules are macros over
  the declaration; there is no committed Elixir code to drift.
- **Cross-language generation is a committed artifact.** Rust, TypeScript,
  the wire catalog and the migration are files, checked byte-for-byte in
  CI the way `kernel.wasm` is checked today. `--check` fails on a diff.
- **Adding a metric is one line.** It changes `schema_rev` (JSON) and, if
  the table is resident, the wire hash. A world table is not resident, so
  its metrics never force an MCP rebuild.
- **Migrations are generated, never hand-written.** The baseline is the
  declaration. A future change is a generated diff; a hand-edited
  migration fails `--check`.

This replaces four authorities (`schema.ex`, `priv/wire/schema.txt`,
`native/wire` constants, `store.ts` types) with one.

## Data model

Two planes, decided by one rule: **a table is resident iff the kernel
derives from it.** Everything else is read over RPC, server-side, under
`Repo`'s account predicate.

### Resident (in BOOT, columnar, PATCH deltas)

`applications`, `profiles`, `items`, `narratives`, `batches`, `overlays`,
`cv_lineages`, `cv_variants`, `events`, `kv_pairs`,
`scoreboard_snapshots`, `gym_problems`, `gym_reps`, `net_entries`,
`atlas_profile`, `atlas` (derived projection), `leases` (derived), `clock`.

### Server-side (RPC `find`/`get`/`history`, never booted)

`places`, `corporations`, `offices`, `contacts`, `messages`, `sources`,
`citations`, `trusted_hosts`.

### Tables

**`places`** — countries and cities in one fat row; `kind`, self
`country_id`, ISO and geonames keys, lat/lon, admin1, timezone, region,
work permit, then demography, economy, liveability, energy and atlas
metrics, and prose. Every metric carries `_on`. Partial uniques for
`iso2` (countries) and `geonames_id` (cities). Country identity may be
seeded from ISO 3166; no metrics are seeded.

**`atlas_profile`** — one row per account: `field`, `citizenships`,
`languages`, seven weights. Written by its holder. Resident.

**`corporations`** — identity (`domain` natural key, `lei`, `cik`,
`ticker`), size, private and public economics, comp and reputation,
hiring/ATS, `freshness`, `score_100`, `note`, prose `about` and `culture`
with `_on`. Replaces `employers` entirely (no row migration; the table is
new).

**`offices`** — `corporation_id`, `place_id`, `kind`, `headcount`
(metric), `opened_on`, `source`. Unique on the triple.

**`applications`** — the application and its progress, with the raw
listing folded in: `no`, `corporation_id`, `place_id`, `contact_id`,
`batch_id`, `channel`, the typed card fields (`company`, `role`,
`location`, `work_mode`, `employment`, `comp_raw`), the listing
(`listing_raw` deferred text, `listing_format`, `listing_sha`,
`listing_url`, `listing_canonical_url`, `listing_on`, `source_id`), the
pipeline (`stage`, `pips`, `stage_on`, `status`, `score_100`, `gate`,
`freshness`, `heat`), dates (`applied_on`, `replied_on`, `closed_on`) and
`outcome`, prose (`notes`, `battleplan`, `letter_raw`), `cv_variant_id`.
No parsed listing columns, ever.

**`contacts`** — a person, not a CRM: `corporation_id`, `place_id`,
`name`, `title`, `email`, `linkedin_url`, `x_handle`, `relation`,
`last_touch_on`, `notes`.

**`messages`** — `channel`, `direction`, addresses, subject, `body`
(deferred), `message_id` (natural key), `thread_key`, sent/received,
`status`, and the links to corporation, application, contact. No tracking
pixels.

**`sources`** — `url` (natural key), `host` derived server-side, publisher,
title, retrieved_at, kind, `doc` (deferred; retention by mutability).

**`citations`** — append-only, one row per metric or prose cell written:
`table`, `row_id`, `column`, `source_id`, `value`, `as_of`, `key_id`,
`op_id`, `actor`, `inserted_at`. The newest citation is the authority;
the rest are history and undo.

**`trusted_hosts`** — `host` (unique), `note`, `added_on`. Browser session
plus step-up only; in no API key's mask.

**Desk/corpus** — `profiles`, `items`, `narratives`, `batches`,
`overlays`, `cv_lineages`, `cv_variants`, `events` (with `actor`,
`op_id`), `claims`, `kv_pairs`, `scoreboard_snapshots`, `gym_problems`,
`gym_reps`, `net_entries`.

**Derived on the wire** — `leases` (live claims) and `atlas` (places rows
with `atlas_position`, only the fit's columns). Like `clock`, they are
tables the server paints, not tables it stores.

## Wire v2

One frame family, 16-byte header:

```
u32 len | u8 kind | u8 flags | u16 schema_hash | u64 rev | body
```

Kinds: `HELLO 1`, `BOOT 3`, `PATCH 4`, `OP 8`, `ACK 9`, `NACK 10`,
`TICK 11`, `PING 13`, `PONG 14`, `TICKET 15`, `BYE 16`, `LEASE 32`,
`RPC 33`.

- **BOOT** carries every resident table, deflated, columnar.
- **PATCH** carries only the columns that moved; `gone` tombstones.
- **OP** carries `u64 op_id | u8 kind | u8 0 | u16 nfields | u32 target |
  (u32 len, utf8) * nfields`, fields in the order the declaration names
  them. Kinds:
  - `put` — upsert by id or natural key; column/value pairs, `as_of`,
    `source`, `expect_rev`, `create_only`.
  - `drop` — tombstone; needs `may_delete`.
  - `command` — a named, declared transition (stage, next, note, score,
    overlay, heat_override, open_fire, narrative, gym_log, gym_target,
    net_log, net_lane, generation) with its declared args.
- **ACK/NACK** answer per op, carrying the id for an insert and a refusal
  struct otherwise.
- **RPC** methods: `schema`, `find`, `get`, `history`, `lease`,
  `release`, `leases`, `blob` chunks (via `get` offset/length), and the
  account page's commands.
- **TICKET** is the single-use page ticket for the gate; **BYE** carries
  `restart` or `grants`.

No `WRITE` frame, no blob frame, no second op family. One decoder in
Elixir, Rust, TypeScript, and (for the gate) none — the gate forwards
bytes.

The wire catalog is generated from the declaration and carries, per
resident table and column: id, name, type, flags (`deferred`, `private`,
`natural`, `metric`, `prose`, `ref`, `derived`), unit, and the command
table. `schema_rev` (hash of the whole declaration) rides in HELLO and
TICK; it is what changes when a world metric is added, and it does **not**
change the wire hash.

`get` chunks text: `{table, id, column, offset, length}` ≤ 256 KiB per
response, authorised per chunk as a read.

Large text policy: `deferred` columns travel as `{sha, bytes}` in
BOOT/PATCH. `listing_raw` stays resident (the kernel extracts keywords
from it); deferring it is a measured later change that ships the extracted
keywords first.

## Kernel

One crate, two targets:

```
native/kernel/
  src/tables.rs      # columnar store, decode, indexes
  src/wire.rs        # frame + table decode (from catalog)
  src/derive/desk.rs # cards, order, search, bands
  src/derive/heat.rs # company/vendor load, verdicts, mix
  src/derive/score.rs# scoreboard, charts
  src/derive/atlas.rs# route, language, parts, fit (the only copy)
  src/derive/cv.rs   # composed CV, overlays, documents
  src/predict.rs     # refusals and pending ops
  src/keywords.rs    # listing extraction (shared by fit and CV)
  src/abi.rs         # wasm exports / native facade
  src/lib.rs
```

- The browser loads `kernel.wasm`; the MCP links the same crate natively.
- The atlas fit exists once, in `derive/atlas.rs`, over `atlas` rows plus
  the resident `atlas_profile`. The old `geography.ex`/`atlas.ts` pair is
  not rebuilt.
- `predict.rs` predicts `scope`, `column`, `leased`, `stale`,
  `natural_key`, `rev`, `freshness` for resident tables, and
  `scope`/`column`/`leased` for server-side tables from the resident lease
  and catalog. `budget`, `rate`, `cap`, `source_trust` and a lost
  natural-key race are server-only.
- The oracle (`test/support/oracle.ex`) dumps the server's decisions and
  the kernel's ports must equal them exactly, as today.

## Elixir tree

One app, no umbrella, contexts behind one door each:

```
lib/hireme/
  application.ex        # supervision: repo, sequencer supervisor, gate, mail
  repo.ex               # SQLite, account predicate, no skip without a reason
  store.ex              # writer lock, transactions, clock, ids
  schema.ex             # THE declaration
  schema/decl.ex        # the DSL; compile-time Ecto generation
  schema/emit.ex        # wire/json/rust/ts/migration emitters
  world.ex              # places, corporations, offices, sources, citations, trusted_hosts
  desk.ex               # applications, batches, stages, heat, scoreboard
  holder.ex             # profiles, items, narratives, atlas_profile
  cv.ex                 # lineages, variants, overlays, composition inputs
  gym.ex / net.ex
  mail.ex               # messages, contacts, outbox, cloudflare, dev mailbox
  keys.ex               # API keys, masks, presets, revocation
  lease.ex              # channel lease + optional block, registry, revoke
  ops.ex                # one sequencer per account: put/drop/command, checks, citations, deltas
  commands.ex           # the declared commands' implementations
  wire.ex               # frames, catalog, codec
  wire/boot.ex          # resident tables -> BOOT
  wire/session.ex       # one state machine per session
  wire/ws.ex            # Bandit adapter
  wire/quic.ex          # gate Port adapter
  gate.ex               # gate supervisor
  atlas.ex              # atlas rows, profile, delegation notes (fit is kernel)
  identity/account.ex
  identity/session.ex
  identity/sign_in.ex   # links, OAuth, adding a way in
  identity/mfa.ex       # TOTP, WebAuthn, recovery, step-up
  identity/audit.ex
  release.ex
  release/backup.ex
lib/hireme_web/
  endpoint.ex
  router.ex
  auth.ex               # cookie, account on the process, headers
  pages/sign_in.ex
  pages/mfa.ex
  pages/account.ex
  pages/templates/*.eex # server-rendered auth/account, no JS dependency
  json.ex
```

Boundaries:

- `world`, `desk`, `holder`, `mail` are the only modules that know table
  names. `ops` composes them and owns the transaction.
- `wire.session` never touches a table directly; it asks `wire.boot`,
  `ops` and the RPC methods.
- `identity` never touches desk rows; `auth` puts the account on the
  process and nothing else.
- `release` never imports application code paths; it runs the generated
  baseline and backups.

## Ops v2

One sequencer per account. It receives staged ops, seals up to 64 into one
transaction, and answers each in order.

Checks, in order, inside the op's savepoint:

1. grant — the key's `write_mask` covers the table's domain, else `scope`.
2. lease — a channel lease, else `lease_missing`; an `applications` row in
   another session's block → `leased`.
3. column — writable through `put`, else `column`; pipeline columns stay
   behind `stage`.
4. freshness — `freshness`, `stale`.
5. prose CAS — `rev`.
6. source — `source_missing`, `source_trust`.
7. limits — `too_large` (1 MiB), `rate` (600 ops/min, new `:agent_write`
   bucket), `cap`.

Then: one write, one citation per metric/prose cell, `rev + 1`, and the
columnar delta. `put` is a merge unless `create_only`; `drop` tombstones.

The 13 command implementations live in `commands.ex` and call the domain
modules (`desk`, `cv`, `gym`, `net`), so pipeline and heat rules are not
bypassable through a raw put.

## Leases and keys

- **Lease**: one channel lease per session; `lease {}` opens writes for
  the key's domains; an optional `applications` block inside it uses the
  buddy allocator. `since` on the row, operator revoke, no TTL, liveness
  is the carrier and PING/PONG.
- **Keys**: `read_mask`, `write_mask` (five domains: world, desk, mail,
  lanes, corpus), `may_delete`. Presets read-only, write-only, read/write,
  custom. HELLO carries the masks. Minting, widening and delete need
  step-up; narrowing does not; a change closes live sessions with
  `bye "grants"`. `citations` and `trusted_hosts` are in no write mask.
  A key never mints keys.

## Web

```
assets/js/
  main.ts        # transport, handshake, boot
  wire.ts        # carriers, framing, HELLO/OP/PING, tickets
  kernel.ts      # wasm facade: load, apply boot/patch, derive, predict
  state.ts       # one state, typed messages, update
  store.ts       # IndexedDB snapshot, restore, trap recovery
  early.ts       # inline <head>: connect and HELLO before the bundle
  views/board.ts
  views/focus.ts
  views/battleplan.ts
  views/atlas.ts
  views/gym.ts
  views/net.ts
  views/account.ts
  ui/html.ts     # escaping, keyed morph
  ui/dom.ts      # patch, focus preservation
  ui/form.ts     # the account/key forms
assets/css/
  tokens.css
  app.css
```

- No framework. `state.ts` is the only mutable state; views are pure
  functions of it; `kernel.ts` is the source of derived data.
- Keyed morphing preserves focus, the way the old `html.ts` did; that
  requirement does not change.
- The atlas draws from the resident `atlas` rows and calls the kernel fit;
  it has no second scoring implementation.
- Auth pages are server-rendered EEx with no JavaScript; the desk is the
  only SPA.

## Release and edge

The application owns its whole host half:

- `nix/package.nix` — OTP release (`bin/hireme`, `bin/hireme-gate`), the
  committed wasm kernel, digested assets, application sources only.
- `nix/module.nix` — user, one systemd unit, sandboxing, state,
  secrets file, migration at boot, backup, drain.
- `nix/edge.nix` — nginx, ACME/DNS-01, gate DNAT, certificates, agenix
  wiring, off by default.
- `flake.nix` — package, module, checks; host flakes point at it and own
  only addresses.
- One baseline migration; `Hireme.Release` runs it; backup via
  `VACUUM INTO`; SIGTERM drains with BYE `restart`.

The rebuild's cutover is a new database: the baseline creates it, the old
file is archived, and the app has no reader for it. Data rescue from the
old database is explicitly outside the application; if it is wanted, it
is a throwaway script that never lands in the tree.

## Security

Unchanged standards, new code: passwordless links, GitHub/X OAuth, TOTP,
WebAuthn, recovery codes, step-up, session revocation, CSRF, security
headers, per-peer and per-key throttles, audit trail, hashed session and
key secrets.

New in the rebuild:

- masks are enforced on BOOT, PATCH, `find`, `get`, `history` and ops;
- `citations` and `trusted_hosts` are server-only;
- `sources.host` is derived, never supplied;
- raw text is marked untrusted to the agent;
- every write names its key, lease, op and either the value or a digest;
- an operator revoke can kill a lease and a session;
- `SECURITY.md` is rewritten with the carrier timeout, the masks and the
  trusted-host model.

## Testing, oracle, parity, bench

- One suite per contract: schema/emitters (`--check`), identity, MFA,
  keys/masks, leases, ops (seven checks), wire (frames, boot, patch), RPC,
  world (citations, stale, source trust), desk (pipeline, heat, score),
  atlas (fit parity), mail, release (baseline, backup, drain), web (auth
  pages, account).
- `test/support/oracle.ex` dumps server decisions (deltas, refusals,
  `can_apply`, mix, atlas fit); `native/kernel/parity.mjs` requires the
  kernel to equal it.
- The schema emitters have a `--check` that fails on any diff, including
  the baseline migration and the wire catalog.
- `bench/` is rewritten for wire v2: BOOT bytes, PATCH bytes, ops/s,
  `find` p99 at 50k places, kernel derive cost, gate throughput.
- Bounds: BOOT ≤ 8 MiB deflated at 10k applications; 0 BOOT bytes at 50k
  places; `find` p99 ≤ 10 ms; 1 MiB per op text; 256 KiB per `get` chunk;
  500 rows per `find`; 600 ops/min per key; 64 ops per transaction.

## The nuke manifest

Everything below is deleted at cutover. No file is copied, adapted, or
left behind as a shim.

| Deleted | Replaced by |
| --- | --- |
| `lib/hireme/*.ex` (34 files) | the new context tree above |
| `lib/hireme/heat/`, `mfa/`, `lib/hireme_web/` | `heat` inside `desk`, `identity/mfa`, `hireme_web/pages` |
| `lib/mix/tasks/hireme.ex` | `mix hireme.schema`, `mix hireme.import`, `mix hireme.score` |
| `test/**/*.exs` (22 files) | new suites, one per contract |
| `native/wire`, `kernel`, `gate`, `mcp` sources (16 files) | the crates above, sharing the generated catalog |
| `native/*/Cargo.toml` | new workspace members |
| `assets/js/*.ts` (13 files) | the `main/wire/kernel/state/views/ui` tree |
| `assets/css/app.css` | `tokens.css` + `app.css` |
| `priv/wire/schema.txt` | generated `priv/wire/catalog.txt` |
| `priv/repo/migrations/*.exs` | generated `0001_baseline.exs` |
| `priv/static/assets/*`, `priv/wasm/kernel.wasm` | rebuilt artifacts |
| `config/*.exs`, `mix.exs`, `.formatter.exs`, `.credo.exs` | re-derived for the new tree |
| `bench/*`, `docs/checklist.md`, `docs/performance.md`, `README.md`, `SECURITY.md`, `alchemy/*` | re-authored for the rebuild |
| `flake.nix`, `nix/*` | re-derived, with the edge owned by hireme |
| `secrets/*` | unchanged ciphertext; the module's variable names may change |

Not deleted: `.git`, `LICENSE`, the operator's `seed/` input files, the
design docs (`docs/full-duplex*.md`), and this document. The old database
is archived, not read.

## Build order and cutover

The rebuild happens on a branch; the nuke is a cutover commit, not a
slow replacement.

1. **Declare.** `schema.ex`, the DSL, the emitters, the baseline, the
   generated catalog and the `--check` gate. No app runs yet.
2. **Core.** Repo, store, contexts, ops, lease, keys; the seven checks;
   citations; the command table.
3. **Wire.** Session state machine, Boot, adapters, put/drop/command,
   ACK/NACK, RPC.
4. **Kernel.** Tables, derive, atlas fit, predict, keywords; wasm and
   native; oracle and parity.
5. **Web.** State, views, morphing, account and auth pages.
6. **World and mail.** Places/corporations/offices/messages/contacts,
   MCP tools and resources.
7. **Edge.** Release, baseline boot, backup, drain, flake and module,
   bench.

Cutover acceptance, all green in the same commit:

- every in-scope v1 path is absent from `git ls-tree`;
- a fresh database boots from the baseline alone, and `mix test` passes;
- `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`;
- `mix hireme.schema --check` reproduces the baseline, catalog, JSON,
  Rust and TypeScript artifacts byte for byte;
- oracle parity for every kernel port;
- bench inside the bounds;
- `nix build .#hireme .#hireme-gate --rebuild` fails on no differing byte;
- the dev-profile VM check passes;
- `hireme-mcp` built from the new catalog connects and reads.

There is no flag, no dual reader, no "old mode". If a piece is not ready,
the cutover does not happen; the old tree stays archived on its branch.

## Refused

- A migration path for the old database, the old wire hash, or the old
  bundle. The cutover is a new app with a new database.
- Keeping `job_apps`, `listing`, `letterbox`, `packet`, or the 13-op
  vocabulary to spare a rename. The nuke makes names free.
- A second implementation of any derivation. One kernel, one atlas fit,
  one prediction, proven by parity.
- A policy language beyond masks and delete. Row filters, if ever, are a
  column and a check, not a DSL.
- A separate `WRITE` frame, blob frame, or `sequences` table.
- Parsed listing columns, an EAV fact table, a thread table, or
  per-entity statistics tables.

## Measurements, not decisions

- BOOT at 10k applications with listings resident. If it exceeds 8 MiB
  deflated, ship extracted keywords and defer `listing_raw`; otherwise
  leave it resident.
- `find` p99 at 50k places; add the `(account_id, country_id, name)` index
  if the planner wants it.
- Prose conflict rate; move CAS to the cell (`expect_citation`) if
  whole-row `expect_rev` causes more than a rare retry.
- The `:agent_write` cap (600/min) and the 64-op batch, measured against
  the bench.
- Whether the gate earns its keep against `wire.ws`; the bench answers,
  and dropping it is a deletion, not a deprecation.
