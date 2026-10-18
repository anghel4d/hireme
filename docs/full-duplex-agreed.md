# Full duplex, agreed

Two designs, one spine, one document. Written by **whalechan** (pi, this
pane) and **opus-shannon** (claude, `wW:p3`), who fact-checked each
other's claims against the tree instead of trading preferences.

Inputs, both uncommitted:

- `docs/full-duplex.md` — whalechan's design.
- `docs/full-duplex-opus-shannon.md` — opus-shannon's counter-design.

Both were written while PR #8 (career geography) was briefly `main`.
The operator dropped it; this document is re-based on `2e01699`, where
`geography_*` and the atlas code do not exist. Where a database may still
carry them, the `places` migration drops them.

## The operator's words

The whole ask, verbatim:

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

Three later instructions, verbatim:

> I do not want to make any "rulings". Figure it out yourself. This isnt a subjective thing, it's science.

> I would reinvent the contents of PR8 altogether, rather than merge directly.

The PR #8 instruction, relayed verbatim by opus-shannon:

> (1) the atlas fit (route, language, parts, fit) becomes ONE kernel derivation over places plus the profile, used by the browser and the MCP; today it exists twice, in geography.ex and atlas.ts. (2) No personal data in source: delete @local_desk (citizenships, languages, field are hardcoded in a public repo) and the first-account heuristic; the profile is written by its holder. (3) The Catalog's hardcoded 28 cities are not seed data: city energy there is the country figure scaled by heating degree days, an estimate presented as a measurement, and cost/qol were read off a chart; places rows come from cited put writes instead. (4) geography_countries/places/profiles and the atlas_weights op are dropped in the same migration that creates places; the weights move to a profile row.

## What each design changed in the other

| Change | From | Because |
| --- | --- | --- |
| `places` absorbs countries and cities; `atlas` is a resident projection | opus-shannon | identical metric families; one table, one write path; the atlas derives from cities, so "cities never boot" was wrong |
| provenance is `citations` alone, not `x_src` + `citations` | opus-shannon | two authorities can disagree; a citation per cell is also history and undo |
| trust is `trusted_hosts`, not `sources.trust` | opus-shannon | a self-asserted trust column enforces nothing |
| no append/merge lease kinds, no spans, no `sequences`, no `id_taken` | opus-shannon | one sequencer already serialises; natural-key references replace span references |
| no TTL; the lease lives with the session | opus-shannon | a five-minute idle release guillotines an LLM mid-thought |
| `listing` stays resident | opus-shannon | `derive.rs` extracts keywords from it; a stub empties every fit |
| read/write masks instead of a `key_grant` policy table | opus-shannon | the ask says "read only, write only, r/w"; a policy language is not asked for |
| two ops, `put`/`drop`, instead of six | opus-shannon | they are upsert and tombstone; the rest are rows in edge or append-only tables |
| reuse the OP frame; no `WRITE` frame | opus-shannon | one decoder in four languages |
| keep `job_apps` and `listing` names; extend `events` | opus-shannon | renames cost four languages for no behaviour |
| world schema in `schema.ex` + RPC, not `schema.txt` | opus-shannon | a world metric must not force an MCP rebuild |
| `citations` server-only; `source_missing` only for declared metrics; `host` derived server-side | whalechan | otherwise a key forges provenance, and every desk field demands a source |
| partial unique indexes on `places` | whalechan | `iso2` and `geonames_id` are unique per kind, not across kinds |
| OP header: repurpose the `u16 0` slot as `nfields`, field `len` u16 → u32 | whalechan | the frame caps at 255 fields and 64 KiB per field, which contradicts 1 MiB and a full fat-row put |
| `leases.since` + operator revoke; `schema_rev` for the world catalog | whalechan | a hung-but-live agent otherwise holds a block forever; a metric no longer bumps the wire hash |

## The rule that settles residency

A table rides in BOOT **iff the kernel derives from it**. Otherwise it is
read server-side under `Repo`'s account predicate. This one rule settles
the argument both designs had:

- **Resident:** `job_apps` (with `listing`), profiles, items, narratives,
  batches, overlays, `cv_*`, `events`, `kv_pairs`, scoreboard snapshots,
  gym, net, `leases`, `clock`, `atlas_profile`, and **`atlas`** — a
  projection of `places` rows with `atlas_position` not null, carrying
  only the columns the fit reads. `atlas` is derived on the wire like
  `leases`, not stored.
- **Server-side:** `places`, `corporations`, `offices`, `contacts`,
  `messages`, `sources`, `citations`, `trusted_hosts`.

Fifty thousand places change zero BOOT bytes. Charting a city adds one
`atlas` row. `find`, `get`, `history` and `schema` answer for
server-side tables over RPC, one statement, keyset on `id`.

## Places, built fresh

Not a migration of PR #8. New tables, new semantics, and the legacy
tables dropped if they are there.

### `places` — countries and cities in one fat table

Identity: `kind` (`country`, `city`), `country_id` (self-reference, null
on a country row), `iso2`, `iso3`, `geonames_id`, `name`, `ascii_name`,
`admin1`, `admin2`, `lat`, `lon`, `timezone`, `currency`, `languages`,
`region` (sym), `work_permit` (sym).

| Group | Columns (each a declared metric, so each carries `_on`) |
| --- | --- |
| demography | `population`, `metro_population`, `population_growth_pct`, `density_per_km2`, `median_age_years`, `foreign_born_pct`, `tertiary_educated_pct`, `life_expectancy_years`, `hdi`, `gini`, `happiness_score` |
| economy | `gdp_usd`, `gdp_per_capita_usd`, `gdp_ppp_usd`, `gdp_ppp_per_capita_usd`, `gdp_growth_pct`, `inflation_pct`, `unemployment_pct`, `median_net_salary_usd`, `eng_salary_median_usd`, `income_tax_top_pct`, `corporate_tax_pct`, `vat_pct` |
| liveability | `qol_index`, `safety_index`, `healthcare_index`, `pollution_index`, `cost_of_living_index`, `rent_index`, `rent_1br_center_usd`, `purchasing_power_index`, `energy_comfort_index`, `english_proficiency_index`, `transit_score`, `walk_score` |
| energy | `energy_consumption_twh`, `energy_production_twh`, `energy_consumption_per_capita_kwh`, `energy_production_per_capita_kwh`, `electricity_consumption_twh`, `electricity_production_twh`, `renewable_share_pct`, `nuclear_share_pct`, `co2_mt`, `co2_per_capita_t`, `grid_carbon_g_per_kwh` |
| atlas | `mobility` (eu, eea, ch, uk, non), `language` (fr, en, de, ro, other), `tech` (1–3), `ease` (1–3), `atlas_position`, `labeled` |
| prose | `liveability`, `notes` (deferred only if BOOT says so; see Measurements) |

Every column in demography, economy, liveability and energy is a metric:
`value` + `value_on` (the day the source says it was true). No `_src`
column; the newest `citation` for `(table, row, column)` is the source.

Indexes: `(account_id, kind)`, `(account_id, country_id)`, and two
**partial** uniques — `iso2` where `kind = 'country'`, `geonames_id`
where `kind = 'city'`. A plain unique on either would collide across
kinds.

Country identity (`iso2`, `iso3`, `name`) may be seeded per account from
ISO 3166, which is a primary source. No metrics are seeded.

### `atlas_profile` — the holder, written by its holder

One row per account: `field`, `citizenships`, `languages`, and the seven
weights (`weight_qol`, `weight_afford`, `weight_lang`, `weight_route`,
`weight_tech`, `weight_ease`, `weight_energy`). Resident, because the fit
is derived client-side. Written through the Account page (or `put` by a
key whose mask includes `lanes`), never seeded, never hardcoded.

Not reintroduced, per the operator: `@local_desk`, the first-account
heuristic, the hardcoded 28-city Catalog, and the `atlas_weights` op.
Weights are ordinary `put`s on `atlas_profile`.

### One derivation, two consumers

`route/2`, `language/2`, `parts/3` and `fit/2` move into
`native/kernel/src/atlas.rs`, compiled to WebAssembly for the browser and
linked natively by `hireme-mcp`. Elixir keeps the `places` domain
(reads, writes, migrations) and no second implementation; the old
`geography.ex` / `atlas.ts` copies are not rebuilt. The parity suite
(`test/support/oracle.ex` + `native/kernel/parity.mjs`) owns the fit's
fixtures, so wasm and native cannot drift.

### The migration creates and drops

One migration creates `places`, `atlas_profile`, `corporations`,
`offices`, `contacts`, `messages`, `sources`, `citations`,
`trusted_hosts`, adds the new `job_apps` and `events` columns, and — for
databases that ran PR #8's migrations — executes
`DROP TABLE IF EXISTS geography_places`, `geography_countries`,
`geography_profiles`. Stale rows in `schema_migrations` for the dropped
files are left alone; Ecto only runs files that exist.

## Corporations, offices, applications, glue

### `corporations` (replaces `employers`)

Identity: `name`, `legal_name`, `domain` (natural key), `aliases`,
`ticker`, `exchange`, `lei`, `cik`, `status` (private, public, acquired,
defunct), `parent_id`, `hq_place_id`, `founded_year`, `industry`,
`sector`, `size_band`.

| Group | Columns |
| --- | --- |
| size | `headcount`, `eng_headcount`, `headcount_growth_pct` |
| private | `total_raised_usd`, `last_valuation_usd`, `last_round`, `last_round_on`, `est_revenue_usd`, `investors`, `runway_months` |
| public | `market_cap_usd`, `revenue_ttm_usd`, `net_income_ttm_usd`, `pe_ratio`, `eps_usd`, `gross_margin_pct` |
| comp & reputation | `swe_median_tc_usd`, `levels_fyi_rating`, `levels_fyi_reviews`, `glassdoor_rating`, `glassdoor_reviews` |
| hiring | `careers_url`, `eng_blog_url`, `ats`, `ats_tenant`, `remote_policy` |
| desk | `freshness`, `score_100`, `note` |
| prose | `about`, `about_on`, `culture`, `culture_on` |

`freshness_verdicts.employer_id`, `cv_lineages.employer_id` and
`job_apps.employer_id` become `corporation_id` in the same migration.
Rows migrate by `employers.name` (lowercased, trimmed) to
`corporations.domain` or `corporations.name`; a name that matches neither
creates a corporation with that name and no domain.

### `offices` — the one edge

`corporation_id`, `place_id`, `kind` (hq, office, rd, sales, remote_hub),
`headcount` (metric), `opened_on`, `source`. Unique
`(corporation_id, place_id, kind)`. Variable cardinality, so not a fat
row; reads project `office_places[]`.

### `job_apps` — kept, extended

The operator's item 4 is already this table: `listing` is the raw,
nullable, unparsed blob. Keep the name and the column. Add:
`corporation_id` (nullable, from `employer_id`), `place_id`,
`contact_id`, `channel` (listing, cold, referral, inbound, recruiter,
other), `listing_on` (day captured), `applied_on`, `replied_on`,
`closed_on`, `outcome` (offer, accepted, rejected, withdrawn, ghosted,
unknown), `listing_format` (text, markdown, html, json, pdf_text),
`listing_sha`, `letter_raw` (the cover letter or cold email as sent).

`company` stays until the kernel reads the corporation's name from the
resident rows; it is a card field typed by the human or agent, never
parsed from the listing.

### Glue

- **`contacts`**: `corporation_id`, `place_id`, `name`, `title`, `email`,
  `linkedin_url`, `x_handle`, `relation` (recruiter, hiring_manager,
  engineer, referrer, alum, friend), `last_touch_on`, `notes`.
- **`messages`**: `channel` (email, linkedin, x, call, meeting),
  `direction` (in, out), `from_addr`, `to_addrs`, `cc_addrs`, `subject`,
  `body`, `message_id` (natural key when present), `thread_key`,
  `sent_at`, `received_at`, `status` (draft, sent, delivered, bounced,
  received), `corporation_id`, `job_app_id`, `contact_id`, `source_id`.
  No tracking pixels.
- **`sources`**: `url` (natural key), `host` (derived server-side by the
  sequencer from `url`, never supplied), `publisher`, `title`,
  `retrieved_at`, `kind` (official, multilateral, statistic, filing, rating,
  press, community, document), `doc` (deferred; retention below). No `trust`
  column.
- **`citations`**: append-only, one row per metric or prose cell written.
  `table`, `row_id`, `column`, `source_id` (null for `actor: human`),
  `value` (the text written), `as_of`, `key_id`, `op_id`, `actor`,
  `inserted_at`. Index `(account_id, table, row_id, column, id desc)`.
  Newest citation is the authority; the older ones are history, the
  shape of a series over time, and an undo log.
- **`trusted_hosts`**: `host` (unique), `note`, `added_on`. Written only
  from a browser session behind step-up; in no key's mask.
- **`events`** (existing): gains `actor` (human, agent, system, mail) and
  `op_id`. No `application_event` table.

Not tables: EAV facts, parsed listing columns, a thread table, a
`sequences` table, a `key_grant` table, per-metric rows, per-entity
statistics tables.

## Provenance and freshness

A **metric** is declared once in `schema.ex`:

```elixir
metric :population, :integer   # => field :population + field :population_on, :date
```

`mix hireme.metric places rent_index float` appends the declaration,
generates the field, the `_on` companion, the changeset cast, and the
migration. Adding a metric is one line and no client rebuild (see
[The wire](#the-wire)).

Rules, checked in the sequencer:

- A declared metric written without `as_of` → `freshness`.
- `as_of` older than the stored `_on` → `stale`, carrying the stored day
  and its citation. Equal day: last writer wins.
- A declared metric or world prose written without `source` →
  `source_missing`, unless `actor: human` (then the citation records the
  actor and no source).
- `culture`, `about`, `places.liveability`, `places.notes`, and every rating metric:
  every cited source's derived host must be in `trusted_hosts`, else
  `source_trust`. Seed: `levels.fyi`. The operator adds the rest.
- A prose write (`about`, `culture`, `places.liveability`, `places.notes`) requires
  `expect_rev`; a mismatch → `rev` with the current value. Two agents
  rewriting one culture blob cannot clobber.

Source-document retention follows mutability: keep `doc` for `kind in
{rating, press, community, document}` (unrecoverable history); drop it
for `{official, multilateral, statistic, filing}` where `url` +
`retrieved_at` is the evidence and the publisher versions the series.
Retained docs: ≤ 256 KiB, 400 days, deferred text, never booted.

## Writing: `put` and `drop`

Two op kinds, on the existing OP frame:

- **`put`** `{table, id | key, set: {col: value}, as_of, source,
  expect_rev?, create_only?}` — upsert. `key` is the natural key
  (`iso2`, `geonames_id`, `domain`, `message_id`, `url`, or an edge's
  pair). Fields may be natural-key references and `$ref` values:
  `{"corporation": "stripe.com"}` resolves to an id in the same
  transaction, so a corporation and its office go in one pipelined batch
  without knowing ids in advance. A new row answers its id in the ACK.
- **`drop`** `{table, id | key, reason}` — tombstone. Needs
  `may_delete`.

The seven checks, in this order, inside the op's savepoint:

1. **grant** — the key's write mask covers the table's domain, else
   `scope`.
2. **lease** — the session holds the channel lease, else
   `lease_missing`; a `job_apps` row outside the session's block held by
   another session → `leased`, with held ids and a free range.
3. **column** — writable through `put`, else `column`. Pipeline columns
   (`current_stage`, `pips`, `stage_on`, `stage`) stay behind
   `set_stage` so the pipeline's rules cannot be bypassed.
4. **freshness** — `freshness`, `stale` as above.
5. **prose CAS** — `rev` as above.
6. **source** — `source_missing`, `source_trust` as above.
7. **limits** — text over 1 MiB → `too_large`; over a new limiter bucket
   `Security.limit(:agent_write, key_id)` (1 minute, 600) → `rate`; over
   the table cap (places 100k, corporations 50k, contacts 50k, messages
   200k, citations 5M) → `cap`.

Then one `UPDATE`/`INSERT`, one citation per metric/prose column
written, `rev + 1`, and the columnar delta as today — only the columns
that moved. `create_only: true` turns a natural-key collision into
`natural_key` with the existing id; without it, `put` is a merge.

## Lease

> "a connected AI agent should be given a full duplex (r/w) channel when it gets a "lease""

One lease per session. Taking it opens the write channel for every table
the key's write mask covers; without it every write is `lease_missing`
and the session is read-only. `lease {}` takes it.

An optional application block sits inside it: `lease {"count":16}` or
`{"from":1,"to":16}` also claims applications with the existing buddy
allocator, all or nothing, `busy` carrying a free block. `job_apps` rows
the agent creates with `put` are claimed individually until release.
World rows need no claim: `_on` arbitrates metrics, `rev` arbitrates
prose.

Lifetime is the session. Ends on `release {}`, session exit, key
revoked, mask changed, account suspended, or an operator revoke. No TTL
and no idle timer: a session that is thinking is not a session that is
dead. Liveness is the carrier and PING/PONG, whose timeout is stated in
`SECURITY.md`; the wire `leases` row carries `table`, `kind`, `from`,
`to`, `owner`, and `since`, so a hung holder is visible and can be
revoked from the Account page (step-up).

Write-only keys may lease. They receive no rows, only ACKs with ids and
NACKs.

## Keys

Replace `api_keys.scope` (a string no authorization path reads) with two
bitfields and a flag: `read_mask`, `write_mask`, `may_delete`.

| Domain | Tables |
| --- | --- |
| `world` (1) | places, corporations, offices, sources |
| `desk` (2) | job_apps, events, batches, overlays, cv_*, snapshots, claims |
| `mail` (4) | contacts, messages |
| `lanes` (8) | gym, net, atlas_profile |
| `corpus` (16) | profiles, items, narratives |

`citations` is in no write domain: the sequencer writes it. `trusted_hosts`
is in no mask at all. Reading `citations` needs read on the cited table's
domain.

Presets on the Account page: **read only** (all but corpus), **write only**
(world + mail, no read), **read/write** (all read; write world, desk,
mail, lanes), **custom** (the 5 × 2 grid plus delete). The grid is the
whole policy language, by the operator's ask.

Enforced by the server: BOOT, PATCH, `find`, `get` and `history` are
filtered by `read_mask` per table; ops by `write_mask` and `may_delete`.
HELLO carries both masks, and the MCP lists only the tools they allow.
Minting needs step-up; widening a mask or setting `may_delete` does too;
narrowing does not. Any change closes that key's live sessions with
`bye "grants"`. A key never mints keys, touches identities or factors,
reads another account, or writes `trusted_hosts`.

## MCP surface

| Tool | Does |
| --- | --- |
| `hireme` | the overview, as today, plus this key's masks and lease |
| `schema` | `{table?}`: tables in the key's domains, columns, types, units (in names), metrics, natural keys, writable-through-put, `resident`, `schema_rev` |
| `find` | `{table, where, cols, order, limit, after}`: resident tables from the kernel, others by RPC; one statement, keyset on `id`, limit ≤ 500 |
| `get` | `{table, id | key, cols?, offset?, length?}`: one row, every non-null column with its `_on`; text in 256 KiB chunks |
| `put`, `drop` | the two ops |
| `lease`, `release` | the channel and the optional block |
| `history` | `{table, id | key, column?}`: citations, newest first |
| sugar | `set_stage`, `set_next_action`, `set_score`, `tailor_line`, `open_cv_generation`, `can_apply`, `list_applications`, `recommend_applications`, `heat_status`, gym, net: unchanged names, now one-op paths through the same checks |

Rows are also MCP resources (`hireme://corporations/stripe.com`,
`hireme://places/IE`) with `resources/subscribe` →
`notifications/resources/updated`. That is the duplex in MCP's own terms,
for clients that speak it.

Raw text (`listing`, `body`, `culture`, `about`, `liveability`) comes
back marked as untrusted data, so a scraped page cannot steer the agent
reading it. Refusals keep the rustc shape and `hireme
{"explain": code}`.

## The wire

- **No `WRITE` frame.** The OP body is reused:
  `u64 op_id | u8 kind | u8 0 | u16 nfields | u32 target | (u32 len, utf8) * nfields`.
  The header stays 16 bytes: the existing `u16 0` slot becomes
  `nfields` (65,535 fields), and the field length widens u16 → u32
  (policy still caps a write at 1 MiB). One op family, one decoder in
  four languages, one hash bump.
- **Residency** as above. `atlas` is a new resident table, derived on the
  wire like `leases`. `places`, `corporations`, `offices`, `contacts`,
  `messages`, `sources`, `citations`, `trusted_hosts` never boot.
- **World schema is not in `schema.txt`.** It is served as JSON by the
  `schema` RPC from the `schema.ex` declarations, with a `schema_rev`
  carried in HELLO and TICK. Adding a world metric changes `schema_rev`
  and no wire hash, so no `hireme-mcp` rebuild. The wire catalog keeps
  only resident tables.
- **`leases` grows** `table`, `kind`, `from`, `to`, `owner`, `since`.
- **`get` chunks text** with `offset`/`length` over RPC; no blob frame,
  because a chunk is a read and is re-authorised as one.
- **Hash discipline unchanged** for `schema.txt`: any change to it
  changes the hash, and an MCP built from another schema is refused at
  HELLO with the existing message.

## Bounds

| Bound | Value | Checked by |
| --- | --- | --- |
| BOOT growth from 0 to 50k places | 0 bytes (+1 `atlas` row per charted city) | bench byte count |
| `find` p99, 50k places, by `iso2` or `country_id` | ≤ 10 ms | bench |
| one op's text | 1 MiB | unit |
| text chunk on `get` | 256 KiB | unit |
| `find` page | ≤ 500 rows | unit |
| agent writes | 600 ops/min per key | limiter test |
| ops sealed per transaction | 64 | existing sequencer |
| retained source document | ≤ 256 KiB, 400 days | retention job |

## Tests owed

Through public surfaces only; one suite per contract.

- read-only key `put` → `scope`, no row, no citation.
- write-only key: HELLO succeeds, BOOT carries no rows, `put` ACKs an id.
- two keys put `population` for one country: older `as_of` → `stale`,
  newer stays, both cited.
- two sessions put `culture` with the same `expect_rev`: second → `rev`.
- culture cited to a host not in `trusted_hosts` → `source_trust`; a
  source `url` whose host disagrees with the supplied `host` → the
  supplied one is ignored (derived, not trusted).
- `set_score` or `next_action` with no source is accepted; `population`
  with no source is `source_missing`.
- `put` with natural-key references creates a corporation and its office
  in two pipelined ops, no ids known in advance.
- account A's `put` of `iso2: "DE"` never touches B's row; a natural key
  that exists in B answers A's own id, never B's.
- revoking a key or narrowing its mask mid-lease: next op refused, lease
  published as dropped.
- operator revoke of a lease held by a live session: next op
  `lease_missing`, the block's rows free for others.
- `set_stage` and `put` on `current_stage`: the first passes the
  pipeline, the second is `column`.
- adding a metric with `mix hireme.metric` changes no BOOT byte and no
  wire hash, only `schema_rev`.
- a database migrated at an old revision with `geography_*` present:
  the places migration drops all three and creates `places`.
- the atlas fit is byte-identical between the wasm build and the native
  MCP on one fixture, and the oracle agrees.
- BOOT bytes do not change when the account gains 50k places or 1k
  messages.
- a world `find` under account A returns no row of B's and no
  `trusted_hosts`; a keyset cursor over a concurrent insert neither
  repeats nor skips.
- OP fields over 255 and over 64 KiB round-trip (the widening is real,
  not just documented).

## Phases

Each phase is a checkpoint: verified, committed, pushed.

1. **Keys.** Masks + `may_delete`, Account grid, BOOT/PATCH/`find`/`get`
   filtering, HELLO masks, step-up for widen and delete, `bye "grants"`.
2. **Schema, fresh.** `places`, `atlas_profile`, `corporations`,
   `offices`, `contacts`, `messages`, `sources`, `citations`,
   `trusted_hosts`, new `job_apps` and `events` columns; the migration
   that drops `geography_*` if present; ISO identity seed, no metrics.
3. **Write path.** `put`/`drop`, the seven checks, citations,
   `trusted_hosts`, the `:agent_write` limiter bucket, the `metric` DSL
   and `mix hireme.metric`.
4. **Wire and kernel.** OP widening, `atlas` projection, ACK id,
   `schema`/`find`/`get`/`history` RPCs, the fit in
   `native/kernel/src/atlas.rs`, parity fixtures.
5. **MCP.** Lease rework, the generic tools, resources/subscribe,
   refusal codes and `explain`.
6. **Browser and docs.** The atlas rebuilt on `places` + the kernel fit,
   the corporation on the card, the holder's own profile form, README,
   `SECURITY.md` (carrier timeout, masks, trusted hosts).
7. **Measured, later.** Deferring `listing` only if BOOT says so, and
   only with the kernel's extracted keywords shipped; bench first.

## Rejected, and why

- **Append/merge lease kinds, id spans, `sequences`, `id_taken`** — one
  sequencer makes a span save no round trip; natural-key references
  cover the only real need.
- **A `key_grant` policy table with row filters and column masks** — more
  policy language than the ask; the 5 × 2 grid + delete expresses every
  preset, and a filter can be a column later.
- **A `WRITE` frame** — a second decoder in four languages for no
  capability.
- **Deferring `listing` now** — the kernel extracts keywords from it; do
  it only with the extracted keywords shipped.
- **Migrating PR #8 rows** — the operator's instruction; the rows were
  partly estimates presented as measurements.
- **`x_src` beside `citations`** — two authorities that can disagree.
- **`sources.trust` supplied by the writer** — circular; trust is the
  operator's `trusted_hosts`.
- **Renaming `job_apps`/`listing`, or adding `application_event`** —
  four-language churn for no behaviour; `events` already exists.
- **Separate country and city tables** — the same metric families, and
  the operator asked for fat rows, not a soup.
- **Any EAV/fact table, parsed listing columns, or a thread table** —
  scans where columnar reads should be, and the operator's explicit
  "at all".

## Measurements, not decisions

Nothing here is open for a ruling. Four numbers decide themselves when
they are measured:

- **BOOT with 10k applications and their listings.** If it exceeds 8 MiB
  deflated, ship the kernel's extracted keywords and defer `listing`;
  otherwise leave it resident. The phase 7 bench is the trigger.
- **`find` p99 at 50k places.** If it exceeds 10 ms, add the
  `(account_id, country_id, name)` index; the query planner already wants
  it. If it still exceeds, the table is too fat for one statement and
  `find` gets a covering projection, not a schema change.
- **Prose conflict rate.** If `expect_rev` on a whole row causes more
  than a rare retry, move CAS to the cell (`expect_citation`) — the
  citations table already has the shape.
- **Whether 600 ops/min is right.** It is a limiter constant, measured
  against the bench, not a decision anyone makes by feel.
