# hireme

An agentic tool with a theoretical 6767% effectiveness at getting a qualified candidate hired.

A local desk for a large set of job applications. Each application is a card. Focusing a card opens a side pane. Fullscreening that pane opens the application's battleplan. The interaction follows the same grid rule as a card browser: `h` `j` `k` `l` or the arrows, edge clamped. `Enter` opens the battleplan. `Esc` steps back, then clears search. `/` focuses search.

SQLite holds the corpus, a per-application mask over that corpus, batches, a scoreboard snapshot, and a private narrative. The narrative is one text blob per user, with a version and `updated_at`. It is not the root CV and it is not a mask. Application export omits it while it is private, which is the default.

## Run

Elixir 1.17+ and Erlang/OTP 27+.

```bash
mix setup
mix phx.server
```

Open http://localhost:4000.

`mix ecto.reset` rebuilds the database and loads `seed/` when that directory is present.

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

The scoreboard reads leftover URL counts from the latest snapshot, then counts batches and applications queued today, submits today, the cumulative submit count, and pace against the snapshot's daily target. Variety flags are computed per batch.

## Life-EV (`score_100`)

Every job and employer gets `score_100` (0–100). Standing order from the hunt: OpenAI / Anthropic / SpaceX / Neuralink = 100; Starfish / Valve / GDM / Meta / tier-2 labs = 90; other big tech >$200k = 85; then descending. Ladder: [`alchemy/score-ladder.md`](alchemy/score-ladder.md). The board default-sorts higher first and filters by band / min score. Directory MCP tools (`list_applications`, `recommend_applications`, `score_distribution`, `list_letterboxes`) rank on `score_100`. FIRE HOLD — scoring does not submit.

## Types

Every closed set is a set of atoms with a `parse/1` at the edge: `Hireme.Pipeline` for stages and pips, `Hireme.Desk.Overlay.parse_mode/1` for mask modes, `Hireme.Desk.Job.parse_status/1`, `Hireme.Desk.Filters.from_params/1` for the URL. A string from the wire, a pack, or a form becomes one of those atoms once or is refused there. Past the edge nothing is compared to a string.

Values that cross a module boundary are structs with enforced keys: `Pipeline.Rung`, `Mask.Line`, `Keywords.Coverage`, `Cv.Document`, `Theme`, `Variety`, `Campaign.Scoreboard`, `Desk.Card`, `Desk.Focus`, `Desk.Opening`, `Desk.Signal`, `CvPair`, `Letterbox.Handle`. Where a struct is stored as JSON (`Theme`, `Variety`) the module has a `to_map`/`from_map` pair, and where a rail is stored as a pip string `Pipeline.encode/1` and `Pipeline.decode/1` are inverse. Tests check those round trips.

## CV pairs

One application has one CV variant. One employer has one CV lineage. `Hireme.CvPair.bind/1` loads that pair with a join that requires the lineage to belong to the application's employer. `JobId`, `VariantId`, `EmployerId`, and `LineageId` are different structs. Writes take the pair and load it again; the two structs must be equal.

For 90 days after a generation opens, the lineage can be rewritten. After that, edits wait. `open_cv_generation` starts the next quarter and accepts new lines only. A database trigger aborts a variant or a line that points at another employer's lineage.

## Agent socket

Letterboxes are single-producer, single-consumer. Each application has one letterbox. An agent leases that id and the lease opens a full-duplex websocket. The connection process is the only producer. The letterbox process is the only consumer. The handle closes over that application's CV pair. Commands do not carry an application id.

`/mcp/websocket` lists letterboxes and batches. It cannot write.

`/mcp/letterbox/<id>/websocket` is the lease. A second connection to that id is refused. A second connection to another application on the same employer CV is refused while the lease is held. One connection cannot hold two leases.

Each text frame is one JSON object. `{"id": 1, "method": "tools/list"}` lists the tools. `tools/call` runs one. The server pushes `{"method": "notifications/desk", "params": {...}}` for this application only. A job id or variant id from a different application is rejected. Naming open fire stays on the desk. The socket does not submit an application.

## Layout

| Path | Role |
| --- | --- |
| `lib/hireme/pipeline.ex` | Stage and pip atoms, `Rung`, encode/decode, the hold lock |
| `lib/hireme/theme.ex` | One CV's lead, accent, density, targets |
| `lib/hireme/import.ex` | JSON, markdown table, freshness note |
| `lib/hireme/campaign.ex` | Scoreboard |
| `lib/hireme/variety.ex` | Mix flags for a batch |
| `lib/hireme/narrative.ex` | Private narrative |
| `lib/hireme/mask.ex` | Per-application CV overlay, `Mask.Line` |
| `lib/hireme/desk/opening.ex` | Parsed input for opening one application |
| `lib/hireme/desk/signal.ex` | Typed desk change broadcast on the `desk` topic |
| `lib/hireme/cv_pair.ex` | The typed CV pair and the quarterly cooldown |
| `lib/hireme/letterbox.ex` | SPSC lease, one application per handle |
| `lib/hireme/life_ev.ex` | `score_100` ladder, bands, histogram |
| `lib/hireme/mcp.ex` | Tool calls on a directory socket or a leased handle; directory ranks on `score_100` |
| `lib/hireme_web/mcp_socket.ex` | Directory socket and letterbox socket |
| `lib/hireme/desk.ex` | Cards, stages, naming open fire |
| `lib/hireme_web/live/board_live.ex` | The desk |
| `alchemy/distillation-method.md` | DESERT STORM job-alchemy operator method (wide → crème → keepers) |
| `alchemy/score-ladder.md` | Life-EV `score_100` anchors and descending rungs |
| `.cursor/skills/job-alchemy-distillation/SKILL.md` | Cursor skill for the same distillation funnel |

## License

Copyright (c) 2026 Matei Anghel. All rights reserved. See [LICENSE](LICENSE).
