# hireme

An agentic tool with a theoretical 7476% effectiveness at getting a qualified candidate hired.

The desk tracks a hiring campaign the way [Broadside Observer](https://github.com/anghel4d/broadside-observer) tracks a paper: a card you can read at a glance, a focus pane with the next layer, and a fullscreen battleplan for the application you are actually working.

Hundreds or thousands of applications stay in SQLite. The board paints a window of cards, so the DOM stays the size of the screen.

## The record and the mask

The root CV is the canonical record: experience, projects, education, skills, timeline, facts, plus a namespaced key-value table (`global`, `profile:<id>`, `app:<id>`).

Each application stores a **sparse overlay**. A line with no overlay is the root line. An overlay can hide it, emphasize it, or replace the wording. JobApp14413 reads CV14413: same Northwind work, retold with the listing's columnar ECS and deterministic replay, the cégep and the 2014 page masked out. The root CV is untouched. Kubernetes stays a miss, because the candidate does not have it.

Avery Quinn is sample data. `mix ecto.reset` replaces the desk.

## Run

Elixir 1.17+ and Erlang/OTP 27+.

```bash
mix setup
mix phx.server
```

Open http://localhost:4000. The lede links **JobApp14413**.

```bash
mix hireme.flood 5000
```

adds more applications above id 20000.

## Keys

Same grid rule as Observer: `h` `j` `k` `l` or the arrows. The edge clamps. `Enter` opens the battleplan. `Esc` returns to the desk, then clears search. `/` focuses search. Click a card to focus it. On a narrow window the focus pane is a sheet; `Esc` closes the sheet.

## Layout

| Path | Role |
| --- | --- |
| `lib/hireme/mask.ex` | Resolve one item through an overlay |
| `lib/hireme/cv.ex` | The document a reader sees |
| `lib/hireme/keywords.ex` | Listing targets against visible lines |
| `lib/hireme/grid_nav.ex` | Row-major movement and the painted window |
| `lib/hireme/pipeline.ex` | Recon → close |
| `lib/hireme/desk.ex` | Applications, glance numbers, stage moves |
| `lib/hireme/corpus.ex` | Profiles and root items |
| `lib/hireme/kv.ex` | Namespaced pairs |
| `lib/hireme_web/live/board_live.ex` | The desk |
