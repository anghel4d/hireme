# Full duplex

Fat world rows, leases that name rows, and keys with scopes. This is a
design, not a migration. It says what to build, in what order, and what
must be true when it is done.

## The ask, in the operator's words

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

## Why the MCP writes are narrow now

The channel is already full duplex: one session, HELLO with a key, BOOT
and PATCH down, ops up, ACK/NACK down, lease RPCs both ways. Nothing
about transport stops an agent writing.

The ceiling is the vocabulary, and the subject of the lease:

- 13 ops total (`stage`, `next`, `note`, `score`, `overlay`,
  `heat_override`, `open_fire`, `narrative`, `gym_log`, `gym_target`,
  `net_log`, `net_lane`, `generation`). Every one targets an existing
  application, a narrative, a singleton kv, or a gym/net entry. There is
  no `insert`.
- A lease is a contiguous block of application numbers, one per session,
  all or nothing. `permit/2` hard-codes the seven op kinds that need it
  and refuses everything else with `:leased`. There is no way to lease a
  row that is not an application, because there is no row that is not an
  application.
- The scheme has no world at all: no country, city, corporation, contact,
  or message row to write to. An agent that learns a corporation's
  headcount has nowhere to put it.
- 23 hand-written tools, 23 hand-written schemas, one Elixir schema per
  new field, one wire column, one kernel column. Adding a metric is a
  four-language change because the MCP cannot describe data it was not
  compiled against.

So the design does not add twenty more tools. It adds a write grammar, a
schema catalog, and a lease whose subject is a row (or a column, or an id
span) rather than a block of applications. The tool surface then grows
without the MCP growing.

## Tenets

1. **Fat rows, sparse cells.** One row per country, city, corporation,
   application. Many nullable columns. `NULL` is the normal state of a
   cell nobody has measured; it is not an error and not a missing join.
2. **A metric is a triple.** `value`, `_as_of` (the day the source says
   the value was true), `_src` (which source said it). A row also carries
   `updated_at` (when we touched it) and `rev` (for compare-and-set).
   Nothing about a number is ambiguous.
3. **Columns, not rows, are the unit of change.** PATCH already carries
   only the columns that moved. Two agents may update two different
   columns of the same country without meeting.
4. **A lease names rows, never a query.** Explicit ids, an id range, or a
   reserved span of new ids. No predicate leases: they cannot be revoked
   precisely and they scan.
5. **A key is a ceiling.** A lease can only narrow what the key allows.
   Every op is checked against key grant, then lease, then row/column.
6. **The schema is data.** Column names, types, units, `_as_of` pairs,
   natural keys, private columns, and required grants travel on the wire
   like `stages` does. The MCP reads it; it does not hard-code it.
7. **Every refusal is data.** A code, what was asked, what is held, what
   is free. Same rustc shape as today, same `explain` long form.

## One plane: every row names its account

`Hireme.Repo.prepare_query/3` adds `where account_id = ?` to every read
and raises when the process has no account; `Hireme.Schema.tenant/1`
refuses an insert without one; `docs/checklist.md` treats every
`skip_account: true` as a finding unless it precedes knowing the account.
A shared world plane cannot be added without either a fourth unaudited
read path or a leak of one account's notes, contacts and messages into
another's. So **the country, city, corporation, contact and message rows
are account-scoped like everything else.** That is forced by the existing
invariant, not chosen.

The cost is disk, and only disk: world tables are not resident on the
wire (see [The wire](#the-wire)), so a second account's copy adds bytes
to SQLite and nothing to what a reconnecting client downloads. Sharing
facts between accounts, if it is ever wanted, is an export/import of
cited rows — a document — not a live cross-account join.

The consequence is stated once, plainly: "the world" here is *this
account's copy of the world*, cited and dated. It is a corpus, not a
mirror.

## Tables

Types are the wire's: `u32`, `u64`, `f64`, `day`, `time`, `str`, `sym`.
`str` may be flagged deferred (see [The wire](#the-wire)). Every table
carries `account_id`, `created_at`, `updated_at`, `rev` (u32) and
`deleted_at` (day, null unless tombstoned).

### `sources` — where a fact came from

The dimension every `_src` points at.

| Column | Type | Notes |
| --- | --- | --- |
| `kind` | sym | `official`, `multilateral`, `statistic`, `survey`, `rating`, `registry`, `press`, `community`, `document` |
| `publisher` | str | `World Bank`, `IMF`, `UN DESA`, `Eurostat`, `Numbeo`, `levels.fyi`, `SEC EDGAR`, the company's own filing |
| `title`, `url` | str | the page or document |
| `retrieved_at` | time | when we fetched it |
| `trust` | sym | `primary`, `reputable`, `community`, `unknown` |
| `value_kind` | sym | `measured`, `estimate`, `projection`, `anecdote` |
| `doc_sha` | str | digest of `doc` |
| `doc` | deferred str | the raw source document, when it is worth keeping |
| `licence`, `note` | str | terms, caveats |

`trust` is what makes "reputable sources only" enforceable rather than a
comment. A write of a culture or rating column whose `_src` is `unknown`
or `community` is refused `source_trust` at the sequencer; `levels.fyi`,
Glassdoor, Numbeo and filings are `reputable`, a random aggregator blog is
not.

### `countries` — one row, well over a hundred columns

Identity: `id`, `code` (ISO 3166-1 alpha-2, unique), `iso3`,
`numeric_code`, `name`, `official_name`, `slug`, `region` (sym),
`subregion`, `currency_code`, `currency_name`, `dial_code`, `languages`,
`timezones`, `work_permit` (sym: `easy`, `moderate`, `hard`, `closed` —
the job hunt cares), `notes` (deferred).

Every column in the groups below carries `_as_of` (day) and `_src`
(u32) companions. That is the operator's "date of last update for each of
those rows", made per column instead of per row.

| Group | Columns |
| --- | --- |
| demography | `population`, `population_growth_pct`, `median_age_years`, `urbanization_pct`, `foreign_born_pct`, `life_expectancy_years`, `hdi`, `gini`, `happiness_score` |
| economy | `gdp_usd`, `gdp_per_capita_usd`, `gdp_ppp_usd`, `gdp_ppp_per_capita_usd`, `gdp_growth_pct`, `inflation_pct`, `unemployment_pct`, `avg_net_salary_usd`, `income_tax_pct`, `social_security_pct`, `vat_pct` |
| liveability | `qol_index`, `safety_index`, `healthcare_index`, `pollution_index`, `commute_index`, `cost_of_living_index`, `rent_index`, `purchasing_power_index`, `english_proficiency_index` |
| energy | `energy_consumption_twh`, `energy_production_twh`, `energy_consumption_per_capita_kwh`, `energy_production_per_capita_kwh`, `electricity_consumption_twh`, `electricity_production_twh`, `renewable_share_pct`, `nuclear_share_pct`, `fossil_share_pct`, `co2_emissions_mt` |

Units live in the column name (`_usd`, `_twh`, `_kwh`, `_pct`, `_years`)
so a reader never guesses and a write never silently changes scale.

"Fat with more as needed" is a promise the wire keeps cheap: a new metric
is a new column line, a new `sym` value, and an appended column id.
Nothing is ever renamed or renumbered.

### `cities` — one row per city, `country_id` on it, well over a hundred columns

Identity: `id`, `country_id`, `geonames_id` (u64, unique when known),
`name`, `ascii_name`, `admin1`, `admin2`, `slug`, `lat`, `lon`,
`timezone`, `metro_name`, `urban_area`.

| Group | Columns |
| --- | --- |
| demography | `population`, `metro_population`, `population_growth_pct`, `density_per_km2`, `median_age_years`, `foreign_born_pct`, `median_household_income_usd` |
| economy | `gdp_usd`, `gdp_per_capita_usd`, `avg_net_salary_usd`, `eng_salary_median_usd`, `unemployment_pct`, `median_rent_1br_usd` |
| liveability | `qol_index`, `safety_index`, `healthcare_index`, `pollution_index`, `commute_index`, `cost_of_living_index`, `rent_index`, `purchasing_power_index`, `walk_score`, `transit_score`, `bike_score` |
| energy | `energy_consumption_gwh`, `energy_production_gwh`, `energy_per_capita_kwh`, `renewable_share_pct`, `grid_carbon_g_per_kwh` |
| prose | `liveability` (deferred), `notes` (deferred) |

City energy is the sparsest data in the set and that is fine: the columns
exist, most are `NULL`, and a cell with a value is a cell with a source.

### `corporations` — one row, well over a hundred columns

Identity: `id`, `name`, `legal_name`, `slug`, `aliases` (joined U+001F,
as `keywords` already travels), `domain`, `lei`, `cik`, `ticker`,
`exchange`, `is_public`, `founded_on`, `hq_city_id`, `hq_country_id`,
`status` (sym: `active`, `private`, `acquired`, `defunct`, `unknown`),
`industry`, `sector`, `size_band` (sym: `seed` … `mega`).

| Group | Columns |
| --- | --- |
| size | `employee_count`, `eng_headcount`, `employee_growth_pct` |
| public economics | `revenue_usd`, `revenue_ttm_usd`, `market_cap_usd`, `enterprise_value_usd`, `pe_ratio`, `eps_usd`, `gross_margin_pct`, `dividend_yield_pct` |
| private economics | `total_raised_usd`, `last_valuation_usd`, `last_round_stage` (sym), `last_round_on` (day), `investors`, `burn_rate_usd`, `runway_months` |
| reputation | `levels_fyi_rating`, `levels_fyi_reviews`, `glassdoor_rating`, `glassdoor_reviews` |
| hiring | `careers_url`, `eng_blog_url`, `ats_vendor` (sym), `ats_tenant` |
| prose | `description` (deferred; what it does), `culture` (deferred; what people say it is like), `culture_as_of`, `notes` (deferred) |

The scalar facts carry `_as_of`/`_src`. The prose blobs cite through the
`citations` edge, because a well-sourced culture section has more than
one source and a single `_src` column would lie. A corporation's culture
row is refused `source_trust` unless every citation attached to `culture`
is `primary` or `reputable`.

`score_100` moves here from `employers` (Life-EV already scores an
employer) and `applications.score_100` stays job-specific. `employers`
is superseded; its name-column rows migrate by natural key.

#### `corporation_office` — the one variable-length thing, an edge

The operator's "the cities it has offices in" cannot live in a fat row
without an array or a blob, and both lose the join. It is glue, so it is
an edge table:

`id`, `corporation_id`, `city_id`, `kind` (sym: `hq`, `office`, `rd`,
`sales`, `remote_hub`), `headcount`, `headcount_as_of`,
`headcount_src`, `opened_on`, `source_id`, `note`. Unique on
`(corporation_id, city_id, kind)`.

Reads project it as `office_cities[]`; writes are ordinary `link`/
`unlink` ops under the corporation's lease. This is the only place the
design declines the fat-row rule, and the reason is cardinality, not
normalisation taste.

### `applications` — the job app, with the listing folded in

Supersedes `job_apps`. One row per application; `no` is the account's
number, unique, from 1, never reused (the existing `next_no`).

Identity: `id`, `no`, `corporation_id` (nullable — cold outreach may
name no company), `city_id` (nullable), `contact_id` (nullable),
`batch_id`, `profile_id`, `channel` (sym: `listing`, `cold_outreach`,
`referral`, `inbound`, `recruiter`, `other`), `source_id`.

What the human or agent typed, never parsed from the listing: `company`,
`role`, `location`, `work_mode` (sym), `employment` (sym), `comp_raw`
(the salary line as text).

The listing, verbatim, and not one column more:

| Column | Type | Notes |
| --- | --- | --- |
| `listing_raw` | deferred str | the entire unedited text exactly as it arrived |
| `listing_raw_format` | sym | `text`, `markdown`, `html`, `json`, `pdf_text` |
| `listing_raw_sha` | str | idempotency and dedupe; two apps may share one posting |
| `listing_url`, `listing_canonical_url` | str | canonical form keeps the existing import idempotency rule |
| `listing_fetched_at` | time | when it was captured |
| `listing_src` | u32 | the `sources` row that delivered it |

The operator's constraint is taken literally: **no parsed listing
columns.** No `title_from_listing`, no `salary_min`, no `requirements`.
The posting is a document, not a schema. `role` and `company` are the
card's own fields; if an agent wants to know what the posting says, it
reads `listing_raw`.

Progress: `stage` (sym), `pips`, `stage_on` (day), `status` (sym),
`score_100`, `gate`, `freshness`, `heat`, `heat_override`,
`heat_override_reason`, `applied_on`, `replied_on`, `closed_on`,
`outcome` (sym: `offer`, `accepted`, `rejected`, `withdrawn`, `ghosted`,
`unknown`), `next_action`, `next_due`, `referral`, `cv_variant_id`,
`stage_notes`.

Prose: `notes`, `battleplan`, `letter_raw` (the cover letter or cold
email as sent), all deferred.

`listing_raw` nullable, as demanded: a cold-outreach application is a
complete row with no listing at all. Unique on
`(account_id, listing_canonical_url)` when that column is not null.

### Glue

**`contacts`** — `id`, `corporation_id`, `city_id`, `name`, `role`,
`email`, `phone`, `linkedin_url`, `source_id`, `notes`, `last_touch_on`,
`warmth` (sym: `cold`, `warm`, `referral`, `alum`, `recruiter`). A person,
not a CRM. No sequences, no cadences.

**`messages`** — email tracking. `id`, `thread_key` (str, the provider's
thread id; no thread table), `application_id`, `corporation_id`,
`contact_id`, `direction` (sym: `in`, `out`), `from_addr`, `to_addrs`
(joined U+001F), `cc_addrs`, `subject`, `body_raw` (deferred),
`body_format` (sym), `sent_at`, `received_at`, `provider` (sym:
`cloudflare`, `imap`, `manual`), `provider_message_id` (unique when
present), `status` (sym: `queued`, `sent`, `delivered`, `bounced`,
`failed`, `received`), `bounce_reason`, `source_id`. Every message that
concerns a company or an application ties to it by id; a message that
concerns neither still exists.

**`citations`** — `id`, `source_id`, `target_table` (sym), `target_id`,
`target_column` (sym), `quote` (deferred), `note`, `at`. Append-only.
Scalars get a fast `_src`; prose gets the net.

**`application_event`** — `id`, `application_id`, `at`, `kind` (sym),
`body`, `source_id`, `actor` (sym: `human`, `agent`, `system`, `mail`),
`op_id` (idempotency). Append-only; stage history is a read of this, not
a second copy of the stage.

**`sequences`** — `account_id`, `name`, `next`. One per table that hands
out ids and one for `applications.no`. This is what lets an append lease
reserve a span without a round trip per insert.

**`key_grant`** — see [Keys](#keys).

## What is deliberately not a table

- A `fact`/EAV table with one row per metric. It turns every panel read
  into a scan and every columnar frame into a join. Rejected.
- Parsed listing columns. The operator said not at all; the design does
  not even keep the title.
- A `thread` table. `thread_key` on the message is enough; a thread is a
  view, not a row.
- Office columns on `corporations`. Cardinality, above.
- Separate `country_statistics`, `city_statistics`,
  `corporation_financials` tables. That is the "soup of many different
  tables and schemas" the operator rejected; it also destroys the one
  property that makes the wire cheap, that a row's fields are one
  contiguous column set.
- A per-metric audit table. `_as_of`, `_src`, `rev`, the op ledger and
  `citations` already answer who said what, when, from where.

## Freshness algebra

- A metric column `x` has companions `x_as_of` (day) and `x_src` (u32).
  Writing `x` without `x_as_of` is refused `freshness`; `x_src` may be
  null only when the writer is the account owner by hand (`actor:
  human`), which is recorded.
- `x_as_of` is monotonic per cell: a write whose `x_as_of` is older than
  the stored one is refused `stale`, carrying the stored day and source.
  `force` is allowed only with a `reason`, and it is audited. This is how
  a 2019 census cannot overwrite a 2024 estimate, and how two agents
  writing the same column resolve without a lock.
- `rev` is monotonic per row. `expect_rev` makes a write
  compare-and-set; without it, a write is a merge of the columns it
  names.
- `updated_at` answers "when did we last touch this row"; `x_as_of`
  answers "when was this true". They are different questions and the
  design keeps both.
- `sources.trust` gates culture and rating columns (`source_trust`), and
  `sources.value_kind` tells a projection from a measurement without a
  second column per metric.

## Writing

One op vocabulary, one frame, every table:

| Op | Meaning |
| --- | --- |
| `insert` | a new row; by reserved id, or by natural key when the table has one |
| `merge` | set only the named columns of an existing row (by id or natural key) |
| `null` | clear a metric deliberately, with `_as_of`/`_src` and a reason |
| `link` / `unlink` | an edge row (`corporation_office`, `citations`) |
| `append` | an append-only row (`application_event`, `messages`) |
| `delete` | soft tombstone, `deleted_at`; needs `delete` in the grant |

Rules:

- **Columnar delta.** A `merge` names columns and values; PATCH sends
  exactly those columns back to every subscriber. A ninety-column country
  row costs two columns on the wire when one metric changes.
- **Ids.** `insert` either uses an id from the session's append span or
  gets one from `sequences` at the sequencer. Ids are never reused;
  gaps are legal (sparse applies to ids too).
- **Natural keys.** `countries.code`, `cities.geonames_id` (or
  `(country_id, admin1, name)`), `corporations.lei` / `cik` /
  `(ticker, exchange)` / `domain`, `applications.(account_id,
  listing_canonical_url)`. An `insert` that collides answers
  `natural_key` with the existing id, exactly as `busy` answers with the
  free block; the agent retries as a `merge`. Natural keys are unique
  per account, so account A's `WB` row can never merge into account B's.
- **Ordering.** `x_as_of` monotonic per cell; `rev` monotonic per row;
  `op_id` idempotent (a resent op returns its first outcome).
- **Blobs.** A `merge` may carry up to 1 MiB of text. Larger is
  `too_large`; the blob RPC exists for reading, not for writing.
- **Outcomes.** Each op answers `ok(rev)` or a refusal, in order, in one
  transaction per batch. `atomic: true` turns any refusal into a
  rollback of the batch; the default is per-op, as today.

## Leases

A lease is a capability. The check has three levels, and each level can
only narrow the one above it:

```
key grant  ⊇  lease  ⊇  op
 resource      table      row ∈ selection
 action        kind       columns ⊆ mask
 mask/filter   span/ttl   as_of/rev rules
 budget
```

### Kinds

| Kind | Claims | Used for |
| --- | --- | --- |
| `edit` | each row id, exclusively, in the registry | applications, CV lineage claims (today's semantics) |
| `append` | a reserved span of new ids from `sequences` | agents adding rows concurrently without meeting |
| `merge` | no rows; a column mask and the `as_of` rule | many writers on the same fat world row |

`edit` is today's lease, generalised from `job_apps` to any table.
`append` is what makes "it should be able to add new data" true under
concurrency: two agents ingest two hundred cities each, each gets its own
id span, neither can collide, and no one holds a lock for the duration.
`merge` is what makes the world graph writable by six agents at once: a
disjoint column set cannot conflict, and an overlapping column set is
arbitrated by `x_as_of`.

### Selection grammar

```json
{"table":"corporations","kind":"merge","columns":["employee_count",
  "employee_count_as_of","employee_count_src"],"ttl":1800}
{"table":"cities","kind":"append","count":200}
{"table":"applications","kind":"edit","from":17,"to":32}
```

- `ids` (explicit list), `range` (`from`..`to`), `count` (the aligned
  power of two that covers it, for edit; a plain contiguous span, for
  append), or `natural` (resolve the key to one id at grant time and
  claim that id). `count` on a live append lease extends its span; it
  does not create a second lease.
- No predicates. A lease that says "every corporation where
  country=US" cannot be revoked precisely and cannot be checked without
  scanning. An agent that wants a filtered set reads the ids first, then
  leases them.
- Exactly one lease per `(session, table)`, and it is enough. The claim
  registry is unique per `(table, row)`, so it never needs two entries
  for one lease. Two blocks of one table buy nothing the allocator
  cannot express: an edit request already receives the aligned
  power-of-two block that covers the range asked for, so 17..32 in one
  lease dominates 17..24 plus 25..32 in two. An append span extends
  contiguously on renewal, so bulk ingest never needs a second span. A
  session may hold an application, corporation and source lease at once,
  because those are three tables.
- `ttl` default 30 minutes, renewable; a session that goes idle for 5
  minutes releases automatically. Session end, key revocation, account
  suspension, or an operator kill releases immediately, and the drop is
  published so subscribers see the row change.

### Budgets and visibility

A lease carries `max_rows`, `max_ops`, `max_bytes`; exceeding any is
refused `budget`. The live registry is already on the wire as `leases`;
it grows `table`, `kind`, `from`, `to`, `owner` (session label),
`expires_at`, and the column mask as joined text. The browser and the
kernel therefore predict `leased` and `scope` locally, the same way they
predict `fire_hold` and `heat` today.

### Refusals

`leased` (someone else holds the row; carries held ids and a free range),
`lease_missing` (no lease covers this op), `scope` (the key does not
allow this resource/action), `column` (mask), `stale` (older `as_of`),
`natural_key` (the row exists; carries its id), `id_taken` (append span
misuse), `source_trust`, `freshness`, `budget`, `too_large`, plus today's
codes. Every one is a struct with fields, not prose, and every one has an
`explain` long form.

## Keys

The key format does not change: `hm_<id>_<secret><check>`, hashed,
shown once, revocable, expiring. What changes is that a key stops being
"this account, everything" and becomes a set of grants.

### `key_grant`

`id`, `key_id`, `resource` (sym), `actions` (closed set joined),
`allow_columns` (joined; empty means all), `deny_columns` (joined),
`filter` (map: `stage`, `batch`, `channel` — only where the field is on
the row), `requires_lease` (bool), `max_lease_rows`, `max_ops_per_min`,
`expires_at`, `note`.

Resource grammar:

```
desk | desk:applications | desk:cv | desk:gym | desk:net | desk:mail
world | world:countries | world:cities | world:corporations | world:sources
```

Actions: `read`, `append`, `update`, `delete`, `lease`. `write` is
shorthand for `append + update`; `read_write` adds `read`.
`write_only` is a real mode — a blind ingest key that may `append` and
`merge` but not read. Its refusals are server-only, because the MCP has
no rows to predict against; the tool descriptions say so rather than
pretending.

Presets, authored on the Account page:

| Preset | Grants |
| --- | --- |
| `reader` | `desk:*` read, `world:*` read |
| `writer` | `desk:*` read + append + update; denies `narrative.body`, `profiles.summary` |
| `jobs` | `desk:applications` r/w, `world:corporations` read, `desk:mail` read |
| `scraper` | `world:*` read + append + update, `world:sources` append; no `desk:*` at all |
| `ingester` | `world:*` append + update, `desk:mail` append; `write_only` |
| `observer` | `desk:*` read only, under a row filter (`batch`) |

Private columns (`narratives.body`, `profiles.summary`,
`messages.body_raw`, `api_keys.secret_hash`, `sessions.token_hash`) are
invisible to `read` and absent from `select *` unless the grant names
them in `allow_columns`; `secret_hash` and `token_hash` can never be
named by any grant.

A key can never: mint or revoke keys, change an identity or a factor,
step up, read another account, run SQL, press `delete` without the
action, or act outside its resource. `desk:keys` is not a resource; key
provisioning stays on the browser session, behind step-up. Revocation
drops every live lease held by that key before the next op is read.

Audit: every op records `key_id`, `lease_id`, table, row, columns,
`rev`, and either the after-value or a digest of it. The Account page
shows per key: effective capability line, last used, live leases, ops
this week, and denials by code. `hm_` secrets are still the only copy.

## The MCP surface

Eight tools, plus whatever the schema catalog generates.

| Tool | Answers |
| --- | --- |
| `capabilities` | the key's effective grants, its live leases, its private-column visibility, work budget |
| `schema` | tables, columns, types, units, `_as_of` pairs, natural keys, `resident`, private and deferred flags, required grant. Served from the wire catalog. |
| `read` | `{table, select, where, order, limit, cursor}`: resident tables locally, all others as one server-side keyset statement; refuses deferred columns with `deferred` and names the blob tool |
| `blob` | `{table, id, column, offset, length}` — chunked raw text for listings, messages, culture, descriptions |
| `write` | a batch of the six ops; per-op outcomes; local prediction first |
| `lease` / `release` / `leases` | the capability, its renewal, what is held now |
| `explain` | a refusal code's long form, as today |
| `audit` | this key's own writes, newest first |

Domain sugar (`set_stage`, `gym_log`, `can_apply`, `recommend_applications`,
…) stays, implemented as one-op `write` batches so it cannot bypass
grants or leases. Nothing is removed; the sugar is no longer the only
door.

Two things make this more than "more tools":

- **The catalog is generated from `priv/wire/schema.txt`.** Add a
  `country_columns` line and the MCP can read and write it immediately,
  because `read`/`write` are generic and the catalog told it the units,
  the companions, and the required grant. The MCP's compiled code stops
  being a second schema.
- **Prediction follows residency.** For resident tables the kernel holds
  the rows, the lease table and the catalog, and predicts `scope`,
  `column`, `leased`, `stale`, `natural_key` and `freshness` in the
  input's frame, keeping the op pending and settling on ACK/NACK —
  exactly today's model. For non-resident tables the lease and the
  catalog are still resident, so `scope`, `column` and `leased` are still
  predicted; `stale`, `natural_key` and `freshness` are the server's
  answer alone, and the NACK rolls the pending op back. `budget` is
  always server-only. `test/support/oracle.ex` and
  `native/kernel/parity.mjs` extend to both cases, so prediction is
  proven, not asserted.

## The wire

- **Residency is derived, not total.** A table rides in BOOT iff the
  kernel derives from it. That is `applications` (today `job_apps`),
  profiles, items, narratives, batches, overlays, `cv_*`, `gym_*`,
  `net_*`, scoreboard snapshots, `leases`, `clock`, and the `catalog`.
  Countries, cities, corporations, offices, sources, citations, contacts,
  messages, `application_event`, `key_grant` and `sequences` never boot;
  `read`, `blob` and `audit` query them server-side under the account
  predicate. BOOT therefore scales with the desk, not with the corpus:
  ingesting fifty thousand cities changes zero bytes that a reconnecting
  client downloads.
- **Catalog.** A `catalog` table (like `stages`) carries per table and
  column: id, name, type, flags (`deferred`, `private`, `natural`,
  `as_of_of`, `src_of`), unit, and the grant a write needs. It rides in
  BOOT. This is the schema-as-data tenet.
- **New tables** for `sources`, `countries`, `cities`, `corporations`,
  `corporation_office`, `applications`, `contacts`, `messages`,
  `citations`, `application_event`, `key_grant`. Column ids append;
  never reused.
- **Deferred text.** The column header's reserved `u8 0` becomes a flags
  byte (`0x01 DEFERRED`). A deferred column travels as `{sha, bytes}`
  only; the text itself is fetched by the blob RPC with an offset. This
  is the one wire change that pays for itself immediately: 5,000
  applications with a 4 KB listing each is 20 MB of BOOT today, and
  ~1.5 MB of rows once the listing is deferred.
- **`leases` grows** `table`, `kind`, `from`, `to`, `owner`,
  `expires_at`, `columns`.
- **A `WRITE` frame** (kind 34) carries a batch of generic ops in
  columnar blocks: `op_id`, table, kind, selection, column set, values,
  `as_of` per column, `_src` per column, `expect_rev`. `ACK`/`NACK`
  answer per op. The 13 existing `OP` kinds remain for the browser until
  the sugar is reimplemented as `WRITE`, then retire.
- **Blob reads are an `RPC` method, not a new frame.** The RPC carrier
  already exists for `lease`, and a blob read is a read: it is chunked,
  range-addressed, and re-checks the key's scope on every chunk, because
  a chunk is a read and must be authorised as one.
- **Hash discipline unchanged.** Any change to `schema.txt` changes the
  hash; an MCP built from another schema is refused at HELLO with the
  existing message. Rebuild on pull, as the README already says.

## Bounds

Numbers the design is held to. They are measured by the bench harness,
not asserted in prose.

| Bound | Value | How it is checked |
| --- | --- | --- |
| BOOT, deflated, 10k applications with listings deferred | ≤ 8 MiB | bench byte count |
| BOOT growth from 10k to 60k world rows | 0 bytes | catalog-only diff |
| PATCH per burst | ≤ 256 KiB | bench |
| `read` p99, 50k city rows, keyed or `country_id` | ≤ 10 ms | bench |
| blob chunk | 256 KiB | unit |
| one op's text | 1 MiB | unit |
| write batch | 256 ops | unit |
| lease claim memory | ≤ 200 B per row (5k applications ≈ 1 MiB) | Registry entry measure |
| retained source document | ≤ 256 KiB, 400 days | retention job |

## Consistency

One SQLite file, one sequencer per account (`Hireme.Ops`), so every
write for an account is already serialised. The design leans on that
instead of adding a second consensus:

- The sequencer checks grant → lease → row/column → `as_of`/`rev` →
  write, in that order, inside the op's savepoint.
- Id allocation is the only shared counter; `sequences` rows are bumped
  in the same transaction that reserves the span, so a crashed agent
  leaves a gap, never a duplicate.
- Tombstones are soft. A deleted row keeps its id, appears in `gone`,
  and can be resurrected by an `insert` with the same natural key and an
  audited reason; hard delete is an operator task, not a key's.
- Cross-table batches (an application, its corporation, its source) are
  one transaction because they are one file; `atomic: true` is the
  switch.
- `read` is one statement and one WAL snapshot. Pagination is keyset on
  `id`, never an offset or a long-lived cursor, so a concurrent insert
  can neither duplicate nor skip a row.

## What this design owes a test

- A key with `world:* read` that calls `write`: refused `scope`; no
  bytes written.
- A lease held by A's key on row 7; B's session writes row 7: `leased`
  with A's ids and a free range; after A's TTL, B succeeds.
- Two merge leases over disjoint columns of one country: both succeed,
  both deltas name only their columns.
- Two merge leases over the same column: the older `as_of` is `stale`,
  the newer wins, the loser is audited.
- Append spans from two sessions interleave without collision; an
  insert outside the span is `id_taken`; a vanished session's span leaves
  a gap, not a collision.
- A natural key that exists in account B, inserted by account A: A gets
  its own row, never B's; `natural_key` never leaks B's id across
  accounts.
- Revoking a key mid-lease refuses the next op and releases the lease to
  subscribers.
- A deferred blob read with a scope that denies the table: refused
  `scope` per chunk, including the tail chunk.
- A merge lease naming `employee_count` refuses a write to `revenue_usd`
  with `column`, even though the key allows it.
- BOOT bytes do not change when the account gains fifty thousand city
  rows or a thousand messages; adding a metric column to `countries`
  changes the catalog and no rows.
- A world `read` under account A returns no row of B's and no private
  column; a keyset cursor over a concurrent insert neither repeats nor
  skips.
- A culture write cited only to an `unknown`-trust source:
  `source_trust`.
- `read` never returns a private column, including through `select *`,
  a natural-key lookup, or a link projection.
- The kernel predicts `scope`/`column`/`leased` for every table and
  `stale`/`natural_key`/`freshness` for resident tables identically to
  the oracle on a fixture with two sessions and three leases; for
  non-resident tables the server's answer is the only answer and its
  NACK rolls the op back.

## Phases

| Phase | Ships | Breaks |
| --- | --- | --- |
| 0 | `sources`, `countries`, `cities`, `corporations`, `corporation_office`, `citations`, `key_grant` as Elixir schema + migrations; seeds for one country one city one corporation | nothing on the wire; tests only |
| 1 | catalog, world/glue tables read server-side, `leases` columns, MCP `schema`/`read`/`blob`; `reader`/`scraper` presets | schema hash; rebuild `hireme-mcp` and `kernel.wasm`; BOOT size unchanged |
| 2 | `WRITE` frame, all six ops, `edit`/`append`/`merge` leases, MCP `write`/`lease`/`capabilities`; grants UI | MCP rebuild; OP sugar still works; parity fixtures grow |
| 3 | `applications` supersedes `job_apps`; `employers` → `corporations`; deferred `listing_raw`; `messages`/`contacts` glue | import, export, kernel views, oracle; the largest change, done behind a rename migration |
| 4 | email ingestion key (`ingester`, write-only), citation enforcement, `audit` tool | mail tests; no user-visible break |
| 5 | retire the 13 `OP` kinds in favour of `WRITE`; bench BOOT/PATCH with 10k applications and 1 MiB blobs, and 50k city rows with zero byte BOOT growth | browser ops; keep the old path until bench clears |

Phases 0–2 are additive; phase 3 is where the desk's own tables move and
where the README, the oracle, and the parity suite must be edited in the
same commit as the schema.

## Decisions

Each of these follows from a constraint in the system, not from taste.

1. **The world is account-scoped.** Forced by `Repo.prepare_query/3`,
   `Schema.tenant/1`, and the checklist's rule about
   `skip_account: true`. A shared plane needs an unaudited read path or
   leaks notes, contacts and messages across accounts; sharing is
   export/import of cited rows, not a live join.
2. **One lease per `(session, table)`.** The claim registry is unique per
   `(table, row)`; the buddy allocator already grants the aligned block
   covering a request; append spans extend on renewal. A second lease
   over one table can express nothing the first cannot, and costs a
   second lane and a second holder to explain in every refusal.
3. **Natural-key inserts take `sequences`, not a span.** A span exists to
   make unkeyed bulk inserts collision-free with no round trip. A
   natural-key insert is already one round trip inside the sequencer, so
   it takes the next sequence id; burning a span id for it would leave
   gaps for nothing. Both paths allocate in the same transaction, so both
   are collision-free.
4. **`no` and every other id are never reused, tombstones included.**
   Reuse is aliasing: a CV, a logged op, a lease or an email thread that
   names application 17 would silently point at a different application.
   The buddy allocator's free-block merging also assumes stable
   numbering. A tombstone costs one u32 forever; an alias costs
   correctness.
5. **Keep a source document where the value cannot be re-fetched, drop it
   where the publisher versions the series.** `doc` is kept for `kind in
   {rating, press, community, document}`: ratings and culture pages
   change under you and their historical values are otherwise
   unrecoverable. For `kind in {official, multilateral, statistic,
   registry}` the citation's `url` + `retrieved_at` + `doc_sha` is the
   evidence and the provider publishes revisions, so the document is
   dropped. Retained docs are capped at 256 KiB and 400 days, compressed,
   and are deferred text: they never boot.

## What is still unknown

Nothing in the design. Three things are unknown in the world, and each
has a measurable trigger rather than a decision to make:

- **Whether real city rows stay under the `read` bound.** Measure at 50k;
  if p99 exceeds 10 ms, add the `(account_id, country_id, name)` index
  the query planner already wants. The design does not change.
- **Whether any account ever needs shared facts.** If two accounts hold
  the same LEI, that is a duplicate, not a bug; an export/import of
  cited rows is the answer when it becomes a problem. No schema change.
- **Whether a bulk importer outgrows one span.** Extension is contiguous
  and O(1); if it ever is not, the span arithmetic, not the lease model,
  is what changes.
