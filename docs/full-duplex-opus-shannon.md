# Full duplex: opus-shannon's design

A counter-design to `docs/full-duplex.md` (whalechan), to converge on one.
It keeps that design's spine (fat rows, natural keys, cell freshness,
account-scoped world, residency follows derivation, refusals as data) and
cuts what one sequencer per account already makes unnecessary.

## The operator's words this is held to

> "a connected AI agent should be given a full duplex (r/w) channel when it gets a "lease", and that it should be able to add new data"

> "Date of last update for each of those rows. Think of data-oriented programming designs and fat structs: this is a fat table with all those rows and more as needed. Not a soup of many different tables and schemas."

> "A col for the country it belongs to."

> "Fat table, many columns, nullables are ok (and this applies to every table btw, its a pricniple of modern data-oriented design to have sparse matrices)"

> "another row for its culture and what people have said its like from reputable sources only (like levels.fyi and stuff, not bottom of the barrel crap)"

> "We do not care about parsing job listings out into more database columns(at all!). Just throw the entire RAW unedited text a job listing came with into this text row, for any given listing. This job listing col is nullable, it can go completely blank, as a job app does not require a listing to exist, it can also be done through cold outreach etc."

> "the API key-provisioning improved so that perms can be a bit more granular (read only, write only, r/w, etc)"

> "The database schema itself is yours."

## Where `full-duplex.md` is wrong or under-specified

1. **It misses PR #8.** `geography_countries` (name, energy, energy_year)
   and `geography_places` (cost, qol, mobility, language, tech, ease,
   energy, energy_year, position, labeled) already exist, are
   account-scoped, and are **resident**: they are in `Ops.@tables`, ride in
   BOOT, and the atlas (`assets/js/atlas.ts`, `Hireme.Geography.route/2`,
   `language/2`) derives from them. New country/city tables that do not
   absorb them leave two country tables, the "soup" the operator rejected.
   It also contradicts "cities never boot": the atlas derives from cities.
   Fix: see *Residency*.

2. **`x_src` beside `citations` is two provenance authorities.** A scalar
   gets `x_src`, prose gets `citations`, and the two can disagree. It also
   triples metric width (~100 metrics -> ~300 columns per table). Keep
   `x_on` per metric (the operator's ask) and make `citations` the only
   provenance: one append-only row per cell written. "Which source said
   the current value" is the newest citation for `(table, row_id, col)`,
   one index lookup.

3. **`sources.trust` is self-asserted.** The agent that writes the source
   row picks its trust, so `source_trust` enforces nothing. Trust is a
   property of the host, and the operator owns the list: `trusted_hosts`
   (kv namespace, written only from a browser session, never by a key).
   A culture/rating write whose sources' hosts are not on it is refused
   `source_trust`. Seed: `levels.fyi`; the operator adds the rest.

4. **Three lease kinds, id spans and `sequences` buy nothing behind one
   sequencer.** Every write already round-trips through `Hireme.Ops` for
   grant, `stale` and natural-key checks, so a reserved span saves no round
   trip. The one thing spans do (refer to a new row before its ACK, e.g. a
   corporation then its office in one batch) is better done by referring to
   rows by natural key (`"corporation":"stripe.com"`), which also works
   across sessions. Merge leases with column masks duplicate the key's
   ceiling and the `x_on` rule. Drop `append`/`merge` kinds, spans,
   `sequences`, `id_taken`. Ids are SQLite rowids assigned in the
   sequencer's transaction; the ACK carries the id.

5. **The 5-minute idle release will drop agents mid-thought.** An LLM turn
   (reading a 4 KB listing, searching, writing a culture summary) routinely
   runs past five minutes with no op sent. Liveness is the session's
   PING/PONG, not op traffic. A lease lives as long as the session, the
   key, and the account do. No TTL, no renewal call.

6. **Deferring `listing` breaks the kernel.** `native/kernel/src/derive.rs`
   reads `job_apps.listing` (`j::LISTING`) to extract keywords and targets
   for the composed CV. A `{sha, bytes}` stub there silently empties every
   fit. Either the server ships the extracted keywords, or the listing
   stays resident. Measure BOOT first (`bench/`), defer after; not a phase
   0-2 concern.

7. **`key_grant` is far past "a bit more granular".** Resource x action x
   column allow/deny x row filter x caps is a policy language with its own
   table, its own UI, and its own test matrix. The ask names read only,
   write only, r/w. Two masks over five domains on the `api_keys` row, plus
   a delete flag, express every preset in the draft except row filters,
   and private columns fall out of the domains (`corpus`, `mail`).

8. **Six op kinds are two.** `insert` and `merge` are one upsert by id or
   natural key; `null` is a put of null with its `x_on`; `link`/`unlink`
   are put/drop on the edge table; `append` is put on an append-only
   table. Collision answering `natural_key` and making the agent retry as
   a merge is a wasted round trip; `create_only: true` is the opt-in for
   that refusal.

9. **A `WRITE` frame (34) is not needed.** The OP body (`u64 op_id | u8
   kind | u8 nfields | u16 0 | u32 target | (u16 len, utf8)*`) already
   carries a generic put: target = row id or 0, fields = table, then
   column/value pairs. 255 fields is 120 columns per op. The sequencer
   already seals up to 64 waiting writes in one transaction, so pipelined
   OPs are the batch. Ecto casts the strings. One frame family, one
   decoder in four languages.

10. **Rename only what earns it.** `job_apps -> applications` and
    `listing -> listing_raw` change the kernel, TypeScript, oracle and
    parity suites for no behaviour. `employers -> corporations` earns it
    (the company must be one table). `application_event` duplicates the
    existing `events` table: extend `events` with `actor` and `op_id`.

11. **Countries and cities are one table.** Identical metric families,
    one catalog entry, one write path, one `find`. `places.kind` in
    (`country`, `city`) and `places.country_id` (self-reference) is the
    operator's "col for the country it belongs to". Country-only columns
    are null on cities and vice versa, which is the sparse matrix the
    operator asked for.

12. **The catalog for world tables should not live in `schema.txt`.**
    World tables are server-side reads (agreed), so they never cross the
    columnar wire and need no wire columns. If their columns are in
    `schema.txt`, every new metric changes the schema hash and every
    `hireme-mcp` is refused at HELLO until rebuilt. Their authority is
    `schema.ex` (`metric` declarations); `schema` and `find` serve them as
    JSON over RPC. Adding a metric is one line, one generated migration,
    and no client rebuild: "more as needed" made cheap.

## Residency

A table rides in BOOT if the kernel derives from it; otherwise it is read
server-side. Same rule as `full-duplex.md`, applied to what exists:

- **Resident:** job_apps (with `listing`), profiles, items, narratives,
  batches, overlays, cv_variants, cv_lineages, gym, net, snapshots,
  `leases`, `clock`, `geography_profiles`, and **`atlas`**: a projection of
  `places` rows with `atlas_position` not null, carrying only the columns
  the atlas scores (id, name, country code, region, cost, qol, mobility,
  language, tech, ease, energy, energy_on, atlas_position, labeled). This is
  the same shape as `leases`: a derived table on the wire, not stored.
- **Server-side:** places, corporations, offices, contacts, messages,
  sources, citations. 50k cities change zero BOOT bytes; charting a city
  adds one `atlas` row.

## Tables

Every table: `id`, `account_id`, `inserted_at`, `updated_at`, `rev`
(integer, +1 per write, the CAS token), `deleted_at` (null unless
tombstoned). Ids and `job_apps.no` are never reused (agreed).

A **metric** is declared once in `schema.ex`:

```elixir
metric :population, :integer      # => field :population + field :population_on, :date
```

`x_on` is the day the source says the value was true. `updated_at` is when
we wrote it. `mix hireme.metric places rent_index float` appends the
declaration and writes the migration.

### `places` (replaces `geography_countries`, `geography_places`)

| Group | Columns |
| --- | --- |
| identity | `kind` (country, city), `country_id`, `iso2` (unique for countries), `iso3`, `geonames_id` (unique for cities), `name`, `admin1`, `lat`, `lon`, `timezone`, `currency`, `languages`, `region` (Geography's south/west/central/nordic/east) |
| demography | `population`, `metro_population`, `population_growth_pct`, `density_per_km2`, `median_age_years`, `foreign_born_pct`, `tertiary_educated_pct`, `life_expectancy_years`, `hdi`, `gini` |
| economy | `gdp_usd`, `gdp_per_capita_usd`, `gdp_ppp_usd`, `gdp_ppp_per_capita_usd`, `gdp_growth_pct`, `inflation_pct`, `unemployment_pct`, `median_net_salary_usd`, `eng_salary_median_usd`, `income_tax_top_pct`, `corporate_tax_pct`, `vat_pct` |
| liveability | `qol_index`, `safety_index`, `healthcare_index`, `pollution_index`, `cost_of_living_index`, `rent_index`, `rent_1br_center_usd`, `purchasing_power_index`, `english_proficiency_index`, `transit_score` |
| energy | `energy_consumption_twh`, `energy_production_twh`, `energy_consumption_per_capita_kwh`, `energy_production_per_capita_kwh`, `electricity_consumption_twh`, `renewable_share_pct`, `nuclear_share_pct`, `co2_mt`, `co2_per_capita_t`, `grid_carbon_g_per_kwh` |
| career (from Geography) | `mobility` (eu, eea, ch, uk, non), `language` (fr, en, de, ro, other), `tech` (1-3), `ease` (1-3), `work_permit` (easy, moderate, hard, closed) |
| atlas | `atlas_position`, `labeled` |
| prose | `liveability`, `notes` |

Every column in demography, economy, liveability and energy is a metric
(carries `_on`). Geography's `cost` becomes `cost_of_living_index`, `qol`
becomes `qol_index`, `energy`/`energy_year` become
`energy_consumption_per_capita_kwh` / `_on` (year -> Jan 1 of that year).

### `corporations` (replaces `employers`)

| Group | Columns |
| --- | --- |
| identity | `name`, `legal_name`, `domain` (natural key), `aliases`, `ticker`, `exchange`, `lei`, `cik`, `status` (private, public, acquired, defunct), `parent_id`, `hq_place_id`, `founded_year`, `industry` |
| size | `headcount`, `eng_headcount`, `headcount_growth_pct` |
| private | `total_raised_usd`, `last_valuation_usd`, `last_round` (pre_seed .. series_f, growth), `last_round_on`, `est_revenue_usd` |
| public | `market_cap_usd`, `revenue_ttm_usd`, `net_income_ttm_usd`, `pe_ratio`, `gross_margin_pct` |
| comp & reputation | `swe_median_tc_usd`, `levels_fyi_rating`, `glassdoor_rating` |
| hiring | `careers_url`, `ats` (Heat's vendor set), `ats_tenant`, `remote_policy` (remote, hybrid, onsite) |
| desk (from `employers`) | `freshness`, `score_100`, `note` |
| prose | `about`, `about_on`, `culture`, `culture_on` |

`freshness_verdicts.employer_id`, `cv_lineages.employer_id` and
`job_apps.employer_id` become `corporation_id` in the same migration.

### `offices`

`corporation_id`, `place_id`, `kind` (hq, office, rd, sales), `headcount`
(metric), `opened_on`. Unique `(corporation_id, place_id, kind)`. The one
edge, for cardinality (agreed).

### `job_apps` (kept; gains columns)

`corporation_id` (nullable, from `employer_id`), `place_id`, `contact_id`,
`channel` (listing, cold, referral, inbound, recruiter, other),
`listing_on` (day captured), `applied_on`, `outcome` (offer, accepted,
rejected, withdrawn, ghosted). `listing` stays raw, nullable, never
parsed. `company` stays until the kernel reads the corporation's name,
then goes.

### Glue

- **`contacts`**: `corporation_id`, `place_id`, `name`, `title`, `email`,
  `linkedin_url`, `x_handle`, `relation` (recruiter, hiring_manager,
  engineer, referrer, alum, friend), `last_touch_on`, `notes`.
- **`messages`**: `channel` (email, linkedin, x, call, meeting),
  `direction` (in, out), `from_addr`, `to_addrs`, `cc_addrs`, `subject`,
  `body`, `message_id` (natural key when present), `thread_key`,
  `sent_at`, `status` (draft, sent, delivered, bounced, received),
  `corporation_id`, `job_app_id`, `contact_id`. No tracking pixels.
- **`sources`**: `url` (natural key), `host` (derived), `publisher`,
  `title`, `retrieved_at`, `kind` (official, statistic, filing, rating,
  press, community). No trust column: trust is `trusted_hosts`.
- **`citations`**: append-only. `table`, `row_id`, `column`, `source_id`,
  `value` (text of what was written), `as_of`, `key_id`, `op_id`,
  `inserted_at`. Index `(account_id, table, row_id, column, id desc)`.
  It is the provenance, the history (GDP by year), and the undo log
  ("revert every cell key X wrote since T").
- **`events`** (existing): gains `actor` (human, agent, system, mail) and
  `op_id`.

Not tables: EAV facts, parsed listing columns, a thread table,
`sequences`, `key_grant`, `application_event` (agreed or argued above).

## Writing

Two op kinds on the existing OP frame:

- **`put`** `{table, id | key, set: {col: value}, as_of, source, expect_rev?, create_only?}`
  Upsert. `key` is the natural key (`iso2`, `geonames_id`, `domain`,
  `message_id`, `url`, or an edge's pair); references may be natural keys
  (`"corporation":"stripe.com"`, `"place":"IE"`). New row -> ACK carries
  the id.
- **`drop`** `{table, id | key, reason}` tombstone. Needs the delete flag.

Rules, checked in this order in the sequencer, inside the op's savepoint:

1. **grant**: the key's write mask covers the table's domain, else `scope`.
2. **lease**: the session holds a lease, else `lease_missing`; a job_app
   outside the session's block held by another session -> `leased`
   (today's semantics, unchanged).
3. **columns**: every column is writable through `put`, else `column`.
   Pipeline columns (`current_stage`, `pips`, `stage_on`) are not: they
   stay behind `set_stage`, so the pipeline's rules cannot be bypassed.
4. **freshness**: a metric written without `as_of` -> `freshness`; with
   an `as_of` older than the stored `x_on` -> `stale` (carries the stored
   day and its citation). Equal day: last writer wins.
5. **prose CAS**: a put to a prose column (`about`, `culture`, `notes`,
   `liveability`) needs `expect_rev`; a mismatch -> `rev` (carries the
   current rev). Two agents rewriting one culture blob cannot clobber.
6. **source**: a metric or prose write without `source` -> `source_missing`
   (a browser write by hand is exempt and cited `actor: human`); a
   culture/rating write whose source host is not in `trusted_hosts` ->
   `source_trust`.
7. **limits**: text over 1 MiB -> `too_large`; more than
   `Security.limit(:agent_write, key_id)` = 600 ops/min -> `rate`; rows per
   table per account over the cap (places 100k, corporations 50k,
   contacts 50k, messages 200k, citations 5M) -> `cap`.

Then one UPDATE/INSERT, one citation row per metric/prose column written,
`rev + 1`, and the columnar delta as today (only moved columns).

## Lease

> "a connected AI agent should be given a full duplex (r/w) channel when it gets a "lease""

- **One lease per session. Taking it opens the write channel.** Without
  one, a session reads (as its key allows) and every write is
  `lease_missing`. `lease {}` takes it.
- **Optional application block inside it.** `lease {"count":16}` or
  `{"from":1,"to":16}` also claims a block, exactly as today (buddy
  allocator, all or nothing, `busy` with a free block). Applications the
  agent creates with `put` are claimed by its lease individually until
  release.
- **World rows need no claim.** `x_on` arbitrates metrics, `rev`
  arbitrates prose.
- **Lifetime**: the session. Ends on `release {}`, session exit, key
  revoked, grants changed, or account suspended; the drop is published on
  `leases`. No TTL, no idle timer.
- **Write-only keys** may lease; they receive no rows, only ACKs (with
  ids) and NACKs.

## Keys

Two bytes and a flag on `api_keys` (replacing the unused `scope`):
`read_mask`, `write_mask` (bit per domain), `may_delete`.

| Domain | Tables |
| --- | --- |
| `world` (1) | places, corporations, offices, sources, citations |
| `desk` (2) | job_apps, events, batches, overlays, cv_*, snapshots, claims |
| `mail` (4) | contacts, messages |
| `lanes` (8) | gym, net, geography_profiles |
| `corpus` (16) | profiles, items, narratives |

Presets on the Account page: **read only** (read all but corpus), **write
only** (write world + mail, read nothing), **read/write** (read all, write
world + desk + mail + lanes), **custom** (the 5x2 grid + delete).

- Enforced by the server: BOOT, PATCH and `find` are filtered by
  `read_mask` per table; ops by `write_mask`. The HELLO reply carries both
  masks; the MCP lists only the tools they allow.
- Minting, widening a mask, or setting `may_delete` needs step-up (the
  existing `@step_up` list). Narrowing does not. Any change closes the
  key's live sessions with `bye "grants"`.
- A key never mints keys, touches identities or factors, reads another
  account, or writes `trusted_hosts`.

## MCP surface

| Tool | Does |
| --- | --- |
| `hireme` | the overview, as today, plus this key's masks and lease |
| `schema` | `{table?}`: tables in the key's read or write domains, columns, types, units (in names), which are metrics, natural keys, writable through `put` |
| `find` | `{table, where, cols, order, limit, after}`: resident tables from the kernel, others by RPC (one statement, keyset on `id`, limit <= 500) |
| `get` | `{table, id | key, cols?, offset?, length?}`: one row, every non-null column with its `_on`; long text in 256 KiB chunks |
| `put`, `drop` | the two ops above |
| `lease`, `release` | the channel and the optional block |
| `history` | `{table, id | key, column?}`: citations, newest first |
| sugar | `set_stage`, `set_next_action`, `set_score`, `tailor_line`, `open_cv_generation`, `can_apply`, `list_applications`, `recommend_applications`, `heat_status`, gym/net tools: unchanged names, now one-op paths through the same checks |

- Rows are also MCP resources (`hireme://corporations/stripe.com`,
  `hireme://places/IE`), with `resources/subscribe` ->
  `notifications/resources/updated` on change. That is the duplex in
  MCP's own terms.
- Raw text (`listing`, `body`, `culture`, `about`) comes back marked as
  untrusted data, so a scraped page cannot steer the agent reading it.
- Refusals keep the rustc shape and `hireme {"explain":code}`. Codes:
  `scope`, `lease_missing`, `leased`, `busy`, `column`, `freshness`,
  `stale`, `rev`, `natural_key`, `source_missing`, `source_trust`,
  `too_large`, `rate`, `cap`, `type`, plus today's.

## Bounds

| Bound | Value |
| --- | --- |
| BOOT growth from 0 to 50k places rows | 0 bytes (+1 `atlas` row per charted city) |
| `find` p99, 50k places, by `iso2` / `country_id` | <= 10 ms |
| one op's text | 1 MiB |
| text chunk on `get` | 256 KiB |
| `find` page | <= 500 rows |
| agent writes | 600 ops/min per key |
| ops sealed per transaction | 64 (the sequencer's existing batch) |

## Tests owed

Through public surfaces only, one suite per contract:

- read-only key `put` -> `scope`, no row, no citation.
- write-only key: HELLO succeeds, BOOT carries no rows, `put` ACKs an id.
- two keys put `population` for one country: older `as_of` -> `stale`, the
  newer stays, both cited.
- two sessions put `culture` with the same `expect_rev`: second -> `rev`.
- culture cited to a host not in `trusted_hosts` -> `source_trust`.
- `put` with natural-key references creates a corporation and its office
  in two pipelined ops, no ids known in advance.
- account A's `put` of `iso2: "DE"` never touches account B's row.
- revoking a key or narrowing its mask mid-lease: next op refused, lease
  published as dropped.
- adding a metric with `mix hireme.metric` changes no BOOT byte and needs
  no `hireme-mcp` rebuild.
- `set_stage` and `put` on `current_stage`: the first passes the pipeline,
  the second is `column`.

## Phases

Each is a checkpoint: verified, committed, pushed.

1. **Keys**: masks + flag, Account grid, session filtering, step-up.
2. **Schema**: `places` absorbs Geography (atlas becomes the projection),
   `corporations` absorbs `employers`, offices, contacts, messages,
   sources, citations, `job_apps` columns, `events` columns; ISO 3166
   countries seeded per account.
3. **Write path**: `put`/`drop` in `Hireme.Ops`, the seven checks,
   citations, `trusted_hosts`.
4. **Wire + kernel**: `atlas` projection, ACK id, RPC `schema`/`find`/`get`/
   `history`, kernel `find` over resident tables, parity.
5. **MCP**: lease rework, generic tools, resources/subscribe, codes.
6. **Browser + docs**: corporation on the card, atlas from `places`,
   README, SECURITY.md.
7. Later, measured: deferred text for `listing` only if BOOT says so, with
   the kernel's keywords shipped instead.
