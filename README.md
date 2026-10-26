# hireme

A job-campaign desk for one operator and the AI agents they lease.

The operator works in one web page. An agent works through MCP at the node's
`/mcp`, with an API key whose read and write masks bound everything it sees and
does. Both write the same rows, judged by the same rules, through the same
kernel, so an agent's prediction and the server's verdict are one function: a
write is either true for both or refused with a code that says why.

**FIRE HOLD stands: nothing here submits an application.** An agent can take an
application to the point where only the operator's fire key is missing, and
there it stops. Opening fire is a human act, on a page the agent cannot reach.

That loop is a harness, and it is built like one on purpose: the route, the
grants, the refusals and the gate all live in the kernel instead of in a prompt.
The harness is the cheap half though. What it runs against is the rest of this
README.

## The campaign

This is the job. Everything else here is machinery.

`campaign {"application":"app:412"}` answers with one next step, in the tools'
own grammar. `{"run":"apply"}` picks the open application closest to done and
answers for that one instead.

```json
{"application": {"id": 120, "no": 412, "company": "…", "role": "…", "stage": "gated"},
 "phase": {"n": 5, "name": "batch"},
 "said": [{"level": "ok", "code": "routed", "text": "app:412 → careers_page"}],
 "next": {"kind": "do", "tool": "put",
          "args": {"ref": "app:412", "set": {"batch_id": "batch:26"}},
          "why": "join today's day pack: the rail needs a batch before in_batch"}}
```

The agent makes that call, calls `campaign` again, and repeats until `next.kind`
is not `do`. Thirteen phases, derived from stored state on every call, and
nothing about a campaign is stored:

> acquire, link, qualify, route, batch, documents, stage, **fire key**, fire,
> confirm, follow-up, reply, close.

The route branches on what the rows say. An email-only listing routes to email. A
listing with a named contact gets a follow-up drafted in its thread. A posting
that died closes as `expired`, and the kernel's own rule says what a close may
say, depending on whether anything went out. Where the route needs a judgement it
does not make up, the argument arrives as a placeholder,
`{"freshness":"<open|thin|closed|blocked>"}`, and filling it is the agent's part
of the bargain. Where it needs the operator, it says so:

```
next[ask the user]: approve the fire key for app:412: https://<node>/fire/3
                   · stop here until it is granted
```

`request_fire_key` is the last call an agent makes on a row. The key names the
missions it covers, it is bound by hash to what the operator reviewed, and a
declined request or a revoked lease is never asked for again by the agent. The
route is written up in [`docs/mcp/campaigns.md`](docs/mcp/campaigns.md).

Missions are the same shape. A mission is a staged artifact: a careers page form,
a LinkedIn note, an email. Its `draft` is the full text. An email goes out as the
linked Gmail or as the account's own domain address, picked at draft time, locked
once sent, and covered by the same fire key.

## A harness, and the desk it holds

hireme is an agent harness, and the loop is runtime rather than prompt.
`campaign` is a step function: it reads stored rows and answers
`{kind, tool, args, why}`, so the route lives in the kernel and the model
contributes only the judgement the route asks for. The rest of what a harness
needs is here as a type, not a convention:

| Harness primitive | How it is here |
| --- | --- |
| step function | `campaign`: thirteen phases derived from the rows on every call; `next.kind` is `do`, `ask`, `wait` or `done`, never a suggestion |
| discovery | `man`, `schema`, and `-h`/`--help`/`help` on every tool; refusals end `help: man <code>` |
| capabilities, not permissions | an API key's read and write masks per domain (world, desk, mail, corpus) plus `may_delete`; a tool the masks forbid is not listed |
| leases with budgets | `lease {"bulk": n}` is a contract for n writes in one atomic burst, alive a few minutes; under the daemon, per-agent claims |
| errors that teach | a refusal carries its code, the data that decided it and the next step, judged in six checks: grant, lease, shape, domain, provenance, limits |
| optimistic concurrency | `expect_rev` on prose; a stale write loses and says so |
| action contracts | a mission is frozen by `kind`, its `target` is fixed by that kind, and the fire key is bound by hash to exactly what the operator reviewed |
| untrusted channels | listings, message bodies and prose come back marked untrusted, to be read as data and never as instructions |
| human in the loop | `open_fire` is not in the tool list; `request_fire_key` is where the agent stops |

A harness is the cheap half, and any wrapper can put a loop over HTTP calls. What
the loop is running against is what makes this a desk:

- **The state machine is the domain.** An email-only listing routes to email. A
  listing with a named contact drafts a follow-up. A dead posting closes
  `expired`. The heat governor decides when outreach may go out and the score
  ladder decides what the board shows first. None of that is the model's to
  invent, and none of it is generic.
- **Invalid states do not parse, rather than being rejected after the fact.** One
  declaration emits the Ecto rows, the Rust constants, the TypeScript types and
  the WebAssembly the browser runs. The same kernel judges in the browser, in the
  server's NIF and in the daemon, so a client's prediction and the server's
  verdict cannot disagree. Most harnesses approximate that with client-side
  validation.
- **The model cannot claim success.** A metric needs its `as_of`, prose needs its
  `source` and `expect_rev`, a mission lands only when the node sees it land, and
  each of those writes makes a citation. The desk does not take an agent's word
  for something it can check itself.
- **The gate is structural.** Nothing here submits an application, and the shape
  of the code is what enforces it, not a sentence in a prompt.
- **It holds a fleet.** Agents share one desk: each gets a session, its own
  claims, its own share of the lease and its own span of rows, and concurrency
  stays the desk's problem.

The harness makes it safe to point an agent at a few thousand applications. The
desk is what makes the answers worth having.

## How it fits together

- **One declaration.** `schema/hireme.schema` names every table, column, enum,
  command, frame and refusal. It emits the database baseline
  (`priv/db/baseline.sql`), the Ecto rows (at compile time), the Rust constants
  (`native/schema`) and the TypeScript types (`assets/js/gen/schema.ts`), all
  generated at every build and never checked in; `mix hireme.schema --check`
  (and `mix test`) fails when the baseline left the frozen one without a
  migration or an id moved.
- **One kernel, three places.** `native/kernel` holds every desk rule (pipeline,
  heat, score, keywords, CV, board, atlas, campaign) and judges every domain
  write. The browser runs it as WebAssembly, the server's sequencer calls it as
  a NIF (which also answers MCP's reads), and the daemon runs the same crate.
- **One write path.** Every write is a `put`, `drop` or `command` op in an `OPS`
  frame, judged in six checks (grant, lease, shape, domain, provenance, limits)
  by one sequencer per account, and answered with `ACK` or `NACK`. A refusal
  names its code from the schema's `refusal` enum, the data that decided it, and
  what to do next; `man <code>` is the same page.
- **One wire.** Binary frames over a WebSocket at `/wire`. Tables the kernel
  derives from (applications, events, batches, the CV corpus, settings, the world
  and the mail) are resident: `BOOT` sends them whole, `PATCH` keeps them
  current, and every read is the client's own replica.
- **Provenance.** Every metric carries the day it is true as of, every prose cell
  its source; each such write makes a citation, and a cell's newest citation is
  its source.
- **Untrusted text stays data.** A raw listing, a message body, prose written by
  people or agents comes back marked untrusted, and is read as data.

## The page

One page, one wire session, the lens in the address:

| Lens | Address | What it is |
| --- | --- | --- |
| desk | `/desk`, `/desk/pro/<no>-<slug>`, `/desk/<no>-<slug>` | the board ranked by score, then heat; band, stage and heat filters; search; the scoreboard. pro puts the selected application beside the board; an application opened (`Enter`, a second click) is rail, score, coverage, the composed CV, the raw listing, events, messages, contact, corporation, and `Esc` backs out |
| world | `/world/<table>/<id>-<slug>`, `/world/atlas` | corporations, places, offices and sources as sparse grids, each cell with its as-of day and citations; the atlas orders every country and city for you (the `me` row) and shows the figures themselves |
| outreach | `/outreach/<id>-<slug>` | contacts and their threads; drafts only |
| me | `/me` | the operator's own row: what the desk may assume about them, and the default CV root |
| fire | `/fire/<request>` | the operator's gate: the request, its missions and their drafts, and beside them **Create fire key** and **Decline** |
| account | `/account` | ways in, factors, sessions, API keys with masks, live leases, the mail identity, trusted hosts, audit |

An item's slug follows its title, and an old one is rewritten to the current one.
Keys: `1`-`5` switch lenses; `h`/`j`/`k`/`l` or the arrows move, `Enter` opens,
`/` searches, `Esc` backs out. Sign-in (email link, GitHub, X) and the
second-factor page are plain HTTP forms.

## Running it

Every tool comes from the flake's pinned nixpkgs: Elixir 1.20 on OTP 28, Rust
with the `wasm32-unknown-unknown` target, SQLite and Bun, which bundles, type
checks and runs the scripts. `nix develop` opens a shell with exactly those; run
everything below inside it (an `elixir` or `mix` from elsewhere is not these
versions).

```bash
nix develop
mix setup          # deps, kernel.wasm, the bundles
DATABASE_PATH=/tmp/hireme-dev/hireme.db HIREME_SERVER=true mix run --no-halt   # http://localhost:4000
```

`DATABASE_PATH` picks the SQLite file (its directory is created if missing), and
a new file gets the baseline schema on first boot (`schema: applied
0000_baseline`). Without it, development writes `hireme_dev.db` at the repository
root. `PORT` moves the listener. A new database starts empty; there is no older
data to bring.

### Signing in locally

In development the sign-in page has a **Sign in locally (development)** button.
It signs you in as `dev@localhost`, and the first sign-in on a fresh database
creates that account (it is account 1, the id `mix hireme.import` takes below).

The real ways in work locally too. An email link lands in the development mailbox
at <http://localhost:4000/dev/mailbox/> rather than being sent; opening it shows
"Sign in as …?", and you are signed in after you confirm. GitHub and X need
`GITHUB_CLIENT_ID`/`GITHUB_CLIENT_SECRET` or `X_CLIENT_ID`/`X_CLIENT_SECRET` in
the environment.

Development logs every SQL query at debug level, so a command's own output comes
after the queries it ran.

Data comes in three ways: an agent through the MCP, the lenses, or a pack:

```bash
mix hireme.import --account 1 path/to/pack.json
```

A pack is JSON or markdown lowered to keyed puts through the sequencer
(`lib/hireme/import.ex` documents the format), so it meets every check a wire
write meets.

## Agents: MCP over HTTP

The node serves MCP at `https://your-node.example/mcp` (the Streamable HTTP
transport). There is nothing to install: an agent points at the URL with an API
key as its bearer token, and each MCP session is a wire session the node holds
for it.

1. In the account lens, **Mint a key**. Its **Access** choice is *Read only* (the
   default: it reads every domain and writes none, so an agent with it cannot
   `put`; an agent that adds or changes data needs *Read and write*), *Write
   only*, *Read and write*, or *Custom*, which shows a read and a write checkbox
   for each of world, desk, mail and corpus. *may delete rows* is a separate
   permission. Minting, widening a key and allowing deletes are covered by the
   session's own sign-in proof, and a session without one is asked for a factor.
   The form states what the key will read, write and delete before you mint it.
   The secret is shown once; save it to a file.
2. Add the server to your MCP client. For Claude Code:

```bash
claude mcp add --transport http hireme https://your-node.example/mcp \
  --header "Authorization: Bearer $(cat /path/to/key)"
```

The key is the only credential, checked before a request's body is read. A
request without a valid one is answered 401 (429 past twenty wrong keys a minute
from one address); a valid key is never refused. Sessions survive the node: a
request naming one the node no longer holds (idle 30 minutes, a restart) is
served by a new one under the same id.

The server speaks both eras of MCP. A current client (MCP 2026-07-28, as Claude
Code is) sends the version in every request's `_meta` and never calls
`initialize`; `server/discover` lists the versions served. An older client opens
with `initialize`, the handshake of 2025-11-25 and earlier, and gets the newest of
those, so `initialize` never answers 2026-07-28: that revision has no handshake to
answer.

**Start with `hireme` or `-h`.** Every tool takes `-h`, `--help` and `help`, and
`man` is the manual (`man <code>`, `man -k`, also as `man://` resources).

Tools: `hireme` (masks, lease, the desk at a glance, the next step;
`{"explain": "<code>"}` explains any refusal), `man`, `campaign`, `schema`,
`find`, `get`, `text`, `history`, `unlinked`, `missions`, `mission`, `cv`,
`cv_upload`, `outreach`, `report`, `mail_check`, `lease`, `release`, `put`,
`drop` (only with the delete permission), `request_fire_key`, `fire_keys`, and one
tool per declared command (`stage`, `note`, `heat_override`, `pick_cv`,
`unpin_cv`, `open_generation`, `file`, `ignore`, `mailbox_state`; `open_fire` is
never offered). A tool the key's masks forbid is not listed.

A `find` on `applications` without `order` is the desk's own query, the one the
page's toolbar runs: `search`, `min_score`, `bands`, `stages`, `classes`,
`modes`, `unlinked` narrow it, `sort` orders on any desk key or catalog field,
`group` buckets on another (company unless told otherwise, `""` for none), and
the answer is the page: rows with their score, band and class, the groups, and a
listing under group headings. `hireme` opens with the board's first eight the
same way.

Writes need a lease: `lease {}` opens the channel, `lease {"count": 16}` also
claims the 16 best-ranked unclaimed applications, and `lease {"bulk": n}` grants a
contract for n writes, so a `put` under it may carry the whole burst in one call
and lands atomically, all of it or none. A lease lives a few minutes, so a long
run re-leases instead of finding out at the write. Writes are not paced; a key
past 100,000 ops a minute is stopped as abuse.

Rows are resources (`hireme://applications/<no>`,
`hireme://corporations/<domain>`, `hireme://places/<iso2>`) and can be subscribed
to. A refusal comes back as a diagnostic naming its code, the data that decided
it, and what to do next.

Stopping an agent, from the account lens: revoking its lease pauses that key
until you resume it (it still reads, but writes nothing, and a new session does
not lift the pause); revoking the key stops it for good.

### Many local agents: hireme-mcp

Optionally, one daemon on your machine serves every local agent: `nix build
.#hireme-mcp` (or `cargo build --release -p mcp --features client` in `native/`).
Every agent on a key shares one wire session to the node (a WebSocket), one
replica of the rows (reads answer locally, several at once) and one lease, which
the daemon keeps apart per agent: an agent's claimed applications are its own,
and a `lease {"bulk": n}` is its own share of the session's contract. A hundred
agents are a hundred sessions in one process.

```bash
HIREME_KEY_FILE=/path/to/key hireme-mcp serve --node https://your-node.example
claude mcp add --transport http hireme http://127.0.0.1:7341/mcp \
  --header "Authorization: Bearer $(hireme-mcp token)"
```

An agent presents the daemon's local token (kept 0600 under
`$XDG_STATE_HOME/hireme-mcp/`; it stands for the daemon's key) or an API key of
its own, which gets a session of its own. The daemon answers on loopback only and
refuses a request with an `Origin`, so no web page can reach a key through it.
`hireme-mcp stdio` is the same for one agent on stdin and stdout; `GET /health`
reports each session (carrier, replicas, rev, claims). A key is never read from
argv.

## Mail

Two sending identities per account, both operator-set: the linked Gmail, over
SMTP with STARTTLS, and the account's domain address through Cloudflare Email
Sending (DKIM-aligned, `p=reject`). A mission's email picks one at draft time,
shows it, and can change it until it is sent. After that the sender is part of
what the key covered and the kernel refuses the change.

There is no send cap of hireme's own. Gmail's and Cloudflare's limits are
surfaced as the provider's refusal, and pacing is a hint after a send, never a
block. Inbound replies are filed by their headers onto the mission that caused
them, which is what stops a campaign's follow-up timers. See [`docs/mail/`](docs/mail/)
and [`SECURITY.md`](SECURITY.md) for the threat model, deliverability and the
step-up rules.

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
workers/mail/          the Cloudflare Email worker for the domain pipe
```

## Where the thinking is

| Doc | What it settles |
| --- | --- |
| [`docs/rebuild.md`](docs/rebuild.md) | the design: the desk, the wire, the judgement |
| [`docs/mcp/campaigns.md`](docs/mcp/campaigns.md) | the golden routes, the thirteen phases, the fire-key gate |
| [`docs/mcp/refs.md`](docs/mcp/refs.md) | `app:412`, `mission:34`, `corp:<domain>`, naming a row |
| [`docs/mcp/one_session.md`](docs/mcp/one_session.md) | why two MCP hosts became one session |
| [`docs/heat.md`](docs/heat.md), [`docs/score.md`](docs/score.md) | the governor and the ladder |
| [`docs/mail/`](docs/mail/) | sender, deliverability, the domain pipe, the threat model |
| [`SECURITY.md`](SECURITY.md) | the policy table, factor freshness, what a key can never do |

## License

See [`LICENSE`](LICENSE).
