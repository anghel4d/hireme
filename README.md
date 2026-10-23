# hireme

A personal job-campaign desk for one operator and the AI agents they lease
to. The operator works in one web page; an agent works through MCP at the
node's `/mcp`, with an API key whose read and write masks bound everything
it sees and does. Both write the same rows, judged by the same rules.

FIRE HOLD stands: nothing here submits an application. Opening fire is a
human act.

The design is [`docs/rebuild.md`](docs/rebuild.md). The heat governor and
the score ladder are explained in [`docs/heat.md`](docs/heat.md) and
[`docs/score.md`](docs/score.md); security practice is in
[`SECURITY.md`](SECURITY.md).

## How it fits together

- **One declaration.** `schema/hireme.schema` names every table, column,
  enum, command, frame and refusal. It emits the database baseline
  (`priv/db/baseline.sql`), the Ecto rows (at compile time), the Rust
  constants (`native/schema`) and the TypeScript types
  (`assets/js/gen/schema.ts`), all three generated at every build and never
  checked in; `mix hireme.schema --check` (and `mix test`) fails when the
  baseline left the frozen one without a migration or an id moved.
- **One kernel, three places.** `native/kernel` holds every desk rule
  (pipeline, heat, score, keywords, CV, board, atlas) and judges every
  domain write. The browser runs it as WebAssembly and the server's
  sequencer calls it as a NIF (which also answers MCP's reads), so a
  client's prediction and the server's verdict are one function.
- **One write path.** Every write is a `put`, `drop` or `command` op in an
  `OPS` frame, judged in six checks (grant, lease, shape, domain,
  provenance, limits) by one sequencer per account, and answered with
  `ACK` or `NACK`. A refusal names its code from the schema's `refusal`
  enum.
- **One wire.** Binary frames over a WebSocket at `/wire`. Tables the kernel derives from (applications, events, batches,
  the CV corpus, settings, the world and the mail) are resident:
  `BOOT` sends them whole, `PATCH` keeps them current, and every read is
  the client's own replica.
- **Provenance.** Every metric carries the day it is true as of, every prose
  cell its source; each such write makes a citation, and a cell's newest
  citation is its source.

## The page

One page, one wire session, the lens in the address:

| Lens | Address | What it is |
| --- | --- | --- |
| desk | `/desk`, `/desk/pro/<no>-<slug>`, `/desk/<no>-<slug>` | the board ranked by score, then heat; band, stage and heat filters; search; the scoreboard. pro puts the selected application beside the board; an application opened (`Enter`, a second click) is rail, score, coverage, the composed CV, the raw listing, events, messages, contact, corporation, and `Esc` backs out |
| world | `/world/<table>/<id>-<slug>`, `/world/atlas` | corporations, places, offices and sources as sparse grids, each cell with its as-of day and citations; the atlas orders every country and city for you (the `me` row) and shows the figures themselves |
| outreach | `/outreach/<id>-<slug>` | contacts and their threads; drafts only |
| account | `/account` | ways in, factors, sessions, API keys with masks, live leases, trusted hosts, audit |

An item's slug follows its title, and an old one is rewritten to the current
one. Keys: `1`–`5` switch lenses; `h`/`j`/`k`/`l` or the arrows move, `Enter`
opens, `/` searches, `Esc` backs out. Sign-in (email link, GitHub, X) and the
second-factor page are plain HTTP forms.

## Running it

Every tool comes from the flake's pinned nixpkgs: Elixir 1.20 on OTP 28,
Rust with the `wasm32-unknown-unknown` target, SQLite and Bun, which
bundles, type checks and runs the scripts. `nix develop` opens a shell
with exactly those; run everything
below inside it (an `elixir` or `mix` from elsewhere is not these versions).

```bash
nix develop
mix setup          # deps, kernel.wasm, the bundles
DATABASE_PATH=/tmp/hireme-dev/hireme.db HIREME_SERVER=true mix run --no-halt   # http://localhost:4000
```

`DATABASE_PATH` picks the SQLite file (its directory is created if
missing), and a new file gets the baseline schema on first boot (`schema:
applied 0000_baseline`). Without it, development writes `hireme_dev.db` at the repository root.
`PORT` moves the listener. A new database
starts empty; there is no older data to bring.

### Signing in locally

In development the sign-in page has a **Sign in locally (development)**
button. It signs you in as `dev@localhost`, and the first sign-in on a fresh
database creates that account (it is account 1, the id `mix hireme.import`
takes below).

The real ways in work locally too. An email link lands in the development
mailbox at <http://localhost:4000/dev/mailbox/> rather than being sent;
opening it shows "Sign in as …?", and you are signed in after you confirm.
GitHub and X need `GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` or
`X_CLIENT_ID`/`X_CLIENT_SECRET` in the environment.

Development logs every SQL query at debug level, so a command's own output
comes after the queries it ran.

Data comes in three ways: an agent through the MCP, the lenses, or a pack:

```bash
mix hireme.import --account 1 path/to/pack.json
```

A pack is JSON or markdown lowered to keyed puts through the sequencer
(`lib/hireme/import.ex` documents the format), so it meets every check a
wire write meets.

## Agents: MCP over HTTP

The node serves MCP at `https://your-node.example/mcp` (the Streamable HTTP
transport). There is nothing to install: an agent points at the URL with an
API key as its bearer token, and each MCP session is a wire session the node
holds for it.

1. In the account lens, **Mint a key**. Its **Access** choice is *Read
   only* (the default: it reads every domain and writes none, so an agent
   with it cannot `put`; an agent that adds or changes data needs *Read and
   write*), *Write only*, *Read and write*, or *Custom*, which
   shows a read and a write checkbox for each of world, desk, mail
   and corpus. *may delete rows* is a separate permission. Minting, widening
   a key and allowing deletes need a factor from the last few minutes: the
   lens asks for one (passkey, authenticator code or a recovery code) when
   it is due. The form states what the key will read, write and delete
   before you mint it. The secret is shown once; save it to a file.
2. Add the server to your MCP client. For Claude Code:

```bash
claude mcp add --transport http hireme https://your-node.example/mcp \
  --header "Authorization: Bearer $(cat /path/to/key)"
```

The key is the only credential, checked before a request's body is read. A
request without a valid one is answered 401 (429 past twenty wrong keys a
minute from one address); a valid key is never refused. Sessions survive
the node: a request naming one the node no longer holds (idle 30 minutes,
a restart) is served by a new one under the same id.

The server speaks both eras of MCP. A current client (MCP 2026-07-28, as
Claude Code is) sends the version in every request's `_meta` and never
calls `initialize`; `server/discover` lists the versions served. An older
client opens with `initialize`, the handshake of 2025-11-25 and earlier, and
gets the newest of those, so `initialize` never answers 2026-07-28: that
revision has no handshake to answer.

Tools: `hireme` (start here: masks, lease, the desk at a glance, the next
step; `{"explain": "<code>"}` explains any refusal), `schema`, `find`, `get`,
`text`, `history`, `put`, `drop` (only with the delete permission), `lease`,
`release`, and one tool per declared command (`stage`, `note`,
`heat_override`, `open_generation`; `open_fire` is never offered). A tool
the key's masks forbid is not listed. A `find` on `applications` without
`order` is the desk's own query, the one the page's toolbar runs:
`search`, `min_score`, `bands`, `stages`, `classes`, `modes`, `unlinked`
narrow it, `sort` orders on any desk key or catalog field, `group` buckets
on another (company unless told otherwise, `""` for none), and the answer
is the page: rows with their score, band and class, the groups, and a
listing under group headings. `hireme` opens with the board's first eight
the same way. Writes need a lease: `lease {}` opens
the channel, `lease {"count": 16}` also claims the 16 best-ranked unclaimed
applications, and `lease {"bulk": n}` grants a contract for n writes: a
`put` under it may carry the whole burst in one call, and lands atomically,
all of it or none. Writes are not paced; a key past 100,000 ops a minute is
stopped as abuse.

Stopping an agent, from the account lens: revoking its lease pauses that
key until you resume it (it still reads, but writes nothing, and a new
session does not lift the pause); revoking the key stops it for good.

Rows are resources (`hireme://applications/<no>`,
`hireme://corporations/<domain>`, `hireme://places/<iso2>`) and can be
subscribed to. A refusal comes back as a diagnostic naming its code, the
data that decided it, and what to do next. Text people or agents wrote (a
raw listing, a message body, prose) is returned marked untrusted: it is
data, never instructions.

### Many local agents: hireme-mcp

Optionally, one daemon on your machine serves every local agent: `nix build
.#hireme-mcp` (or `cargo build --release -p mcp --features client` in
`native/`). Every agent on a key shares one wire session to the node
(a WebSocket), one replica of the rows
(reads answer locally, several at once) and one lease, which the daemon
keeps apart per agent: an agent's claimed applications are its own, and a
`lease {"bulk": n}` is its own share of the session's contract. A hundred
agents are a hundred sessions in one process.

```bash
HIREME_KEY_FILE=/path/to/key hireme-mcp serve --node https://your-node.example
claude mcp add --transport http hireme http://127.0.0.1:7341/mcp \
  --header "Authorization: Bearer $(hireme-mcp token)"
```

An agent presents the daemon's local token (kept 0600 under
`$XDG_STATE_HOME/hireme-mcp/`; it stands for the daemon's key) or an API
key of its own, which gets a session of its own. The daemon answers on
loopback only and refuses a request with an `Origin`, so no web page can
reach a key through it. `hireme-mcp stdio` is the same for one agent on
stdin and stdout; `GET /health` reports each session (carrier, replicas,
rev, claims). A key is never read from argv.

## Tests

```bash
mix test                                  # every contract suite; a database per run
cargo test --manifest-path native/Cargo.toml --workspace
bun native/kernel/vectors.mjs priv/static/wasm/kernel.wasm   # the kernel's vectors under wasm
bun check -p assets                       # the client, strict
bun test ./assets/test/                   # the client's pure modules
nix flake check                           # all of it, plus the dev VM
```

## Layout

```
schema/hireme.schema   the declaration
lib/hireme/            the node: sequencer, kernel NIF, grants, lease, world, provenance, import, accounts, keys, mfa, mail, release
lib/hireme_web/        endpoint, router, sign-in, factor page, the wire session, MCP over HTTP, account RPC, codec
native/                one Cargo workspace: schema, wire, kernel, nif, mcp (the MCP surface the NIF serves, and the hireme-mcp daemon)
assets/js/             early (inline), app, wire, kernel bindings, state, morph, lenses/, auth/, gen/schema.ts
priv/db/               the baseline and additive migrations
nix/                   the package and the NixOS module
```

## License

See [`LICENSE`](LICENSE).
