# hireme

An agentic tool with a theoretical 7476% effectiveness at getting a qualified candidate hired.

The desk tracks DESERT STORM (Matei Anghel / Red cabal) the way [Broadside Observer](https://github.com/anghel4d/broadside-observer) tracks a paper: a card at a glance, a focus pane, and a fullscreen battleplan.

## Campaign

Target 10,000 apps by 2026-10-31. Cadence 8 batches × 55 apps = 440 a day, and every batch has to be a mix. The desk opens on **FIRE HOLD**: nothing is submitted until Matei names open fire on a named batch. Batches 001–008 are fire-ready and locked. 009–010 are draft prep.

The scoreboard reads leftover unique engineering URLs from a snapshot (2337 on 2026-10-06, after the Medium wave). Later imports replace that reading. It also shows batches queued today / 8, apps queued today / 440, submits today, the cumulative submit count, pace against 440, FIRE HOLD or OPEN FIRE, and variety flags per batch.

Fit: systems, agentic tooling, Rust and C++. Remote and relocation. CA + RO (EU) citizen. Framing: out of self-employment; the game years were tumultuous, so the hunt broadens; Anoptic is the systems depth.

The ATS mailbox is `matei3d@gmail.com`. This desk does not log in and does not store a password. If a password is needed elsewhere, it belongs in the environment, not in the repo.

## Narrative

The narrative is a private text blob on the candidate (the user), stored in SQLite with a version and `updated_at`. It is not the root CV and it is not a per-application mask. Its job is the vector: founder-versus-titan age, frontier labs by the end of 2030, the bridge through computational linear algebra and batches, and a hard filter against mid-curve shops.

It shows in the focus pane and the battleplan so drafting can see it. Application export omits it while it is private, which is the default. Save it from the narrative box. The sample seed writes Matei's current working note.

## Run the sample desk

Elixir 1.17+ and Erlang/OTP 27+.

```bash
mix setup
mix phx.server
```

Open http://localhost:4000. The scoreboard is FIRE HOLD. **Batch-001** in the lede filters the 55-card sample pack. Root CV is the thin stand-in for `red/CV.md`.

`mix ecto.reset` rebuilds the sample.

## Import

Imports are idempotent on the canonical job URL (lowercased host, tracking query dropped, trailing slash dropped).

```bash
mix hireme.import priv/desert_storm/sample/batch-001.json
mix hireme.import priv/desert_storm/sample/leftover-pursue.md
mix hireme.import priv/desert_storm/sample/universe-gaps-batch1-freshness.md
mix hireme.import priv/desert_storm/sample/scoreboard.json
```

The Matei profile must exist first (`mix ecto.setup`). A file that marks an app `submitted` while its batch is on HOLD is stored as `fire_ready` instead.

Expected paths when the Broadside `red/` tree is available:

| Path | Shape |
| --- | --- |
| `red/CV.md`, `red/CV.pdf` | Root CV. The sample root is a thin stand-in until that file is brought in by hand. |
| `red/batch-00N-55-mix.md` | Markdown table, or the JSON pack below |
| `red/drafts/batch00N/` | Draft files beside the pack |
| `red/ats-maps/batch00N.json` | `{batch, status, fire, queued_on, squad, apps: [...]}` |
| leftover pursue table | `Company \| Role \| Location \| Fit \| Source \| URL` |
| `red/universe-gaps-batchN-freshness.md` | `OPEN n` / `THIN n` / `CLOSED n` / `BLOCKED n`, then `## OPEN` URL lists |
| LinkedIn wave | JSON apps with `"source": "linkedin"`. No Easy Apply without a confirm. |
| claims | `{"claims": [{"squad", "slice", "note"}]}` |

Sample copies of those shapes live in `priv/desert_storm/sample/`.

## Battleplan

Discovered → freshness → gated → in batch → draft ready → fire ready → open fire → submitted → reply → closed.

Freshness (open, thin, closed, blocked) and the gate (pursue, maybe, skip) are fields on the card. That is a non-binding split so the rail stays one active stage. `open_fire` and `submitted` are refused while the batch fire is HOLD. **Name open fire** on the battleplan records the human decision. It does not send an application.

## Keys

`h` `j` `k` `l` or the arrows move the grid. The edge clamps. `Enter` opens the battleplan. `Esc` returns, then clears search. `/` focuses search. Click a card to focus it.

## Layout

| Path | Role |
| --- | --- |
| `lib/hireme/pipeline.ex` | Battleplan and the FIRE HOLD lock |
| `lib/hireme/import.ex` | JSON, markdown table, freshness note |
| `lib/hireme/campaign.ex` | Scoreboard |
| `lib/hireme/variety.ex` | Mix flags for a batch |
| `lib/hireme/narrative.ex` | Private candidate narrative |
| `lib/hireme/mask.ex` | Per-app CV overlay |
| `lib/hireme/desk.ex` | Cards, stages, naming open fire |
| `lib/hireme_web/live/board_live.ex` | The desk |
