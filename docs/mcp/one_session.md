# One MCP session, two hosts

The operator (2026-10-22), on the lever list: "Two MCP hosts (mcp.ex 1.7k
beside the Rust daemon's agent and upstream, 2k): one host, the Rust session
serving the node's /mcp too, would retire roughly 1.2k of Elixir. The biggest
structural duplication in the tree." Then, on the proposal below: "Authorized.
Proceed with it. Architecting yours. Code writing itself to be delegated to one
of the opus elements in herdr here. Final pass and simplification refinement
yours."

Architecture: fable-overwatch. Code: the opus lane named in the team log.
Final pass and simplification: fable-overwatch.

## Today

Two hosts speak MCP, each with its own session implementation over one
protocol crate:

```
  agents on the operator's box                    agents anywhere
       │ MCP over HTTP, loopback token                 │ MCP over HTTPS, Bearer API key
       ▼                                               ▼
 ┌─ hireme-mcp daemon (Rust, 2,920) ──────┐   ┌─ node: HiremeWeb.Mcp (Elixir, 1,723) ───────┐
 │ front.rs    doors: HTTP, stdio         │   │ plug: key auth, limits, SSE streams          │
 │ agent.rs    THE MCP SESSION            │   │ Session GenServer: THE MCP SESSION           │
 │ upstream.rs one wire session per key,  │   │ reads:  Sequencer.read → kernel (NIF)        │
 │             a pool of kernel replicas  │   │ writes: Sequencer.call (ops from the NIF)    │
 │ link.rs     the WebSocket              │   └────────────────┬──────────────────────────────┘
 └──────────────┬─────────────────────────┘                    │ NIF
                ▼                                              ▼
         the node's wire session ──────────────▶ ┌─ native/mcp, shared (Rust, 1,862) ─────┐
                                                 │ tools, schemas, shapes, op encoding,   │
                                                 │ refusal and mission texts              │
                                                 └────────────────────────────────────────┘
```

`native/mcp/src/agent.rs` (1,009) and `HiremeWeb.Mcp.Session` (about 1,200
of mcp.ex's 1,723) each implement what a session does with a message: the
two protocol eras, tool dispatch, reads, writes with verdict collection and
the local lease refusals, the lease and the bulk contract, resources and
their watches, `subscriptions/listen` and the legacy stream, cancellation,
`cv_upload`. Every tool added since the daemon landed was added to both.

## After

```
  local agents                                   agents anywhere
       │ loopback                                     │ HTTPS
       ▼                                              ▼
  daemon doors (front.rs, as now)            node: thin plug (auth, limits, SSE, blobs)
       │                                              │ NIF: step(session, kernel, facts, msg)
       ▼                                              ▼
 ┌───── native/mcp/src/session.rs: the one MCP session, a machine without I/O ────────┐
 │ reads run on the kernel it is handed (the daemon's replica, the node's sequencer   │
 │ kernel); a write, a claim, a release or a blob is an Effect it yields, and it is   │
 │ resumed with the Outcome; events (a PATCH's moved rows, a masks change, the end)   │
 │ become the notifications it hands back, addressed to sink ids the host owns        │
 └──────────────┬────────────────────────────────────────┬─────────────────────────────┘
                │ daemon: effects on its Upstream         │ node: effects on the Sequencer
                ▼ (replica reads, wire ops, claims)       ▼ (kernel reads, Sequencer.call, Lease)
```

The session logic exists once, in Rust, without an async runtime, so the
node's NIF links it as it links the tool list today. Each host keeps what
is its own: the daemon its replicas and shared wire session, the node its
per-account kernel and public door.

## The machine's contract

Everything below is a contract, not a line of code; the lane writing it
chooses names and shapes inside it.

`Session` holds a session's state: its era (the legacy version agreed at
`initialize`, if any), the label, the request ids in flight and those
cancelled, the watches (URI → table, id, subscriber set) and the listens
(request id → wants tool-list changes, sink id), the legacy sink ids, and the
continuations of requests waiting on an effect.

Three calls drive it:

- `request(kernel, facts, msg) -> Step`. Reads run synchronously on
  `kernel` (`Kernel::query_as` under the facts' grants, `application`,
  `overview_as`): `find`, `get`, `text`, `history`, `cv`, `unlinked`,
  `missions`, `mission`, `fire_keys`, `schema`, `hireme`, resources and
  subscribe all finish here. A write, `lease`, `release`, `request_fire_key`
  and `cv_upload` end in `Step::Pending(Effect)`; everything else in
  `Step::Answer(Option<Json>)` (`None` for a notification, a response or a
  cancelled request).
- `resume(kernel, facts, outcome) -> Step`. The host performed the effect;
  the machine renders the answer (the verdict lines, the pending ones past
  the deadline, the local lease refusals, the commander's answer that is no
  error) or yields the next effect (`cv_upload`: the blob, then the put).
- `event(e) -> Vec<(SinkId, Json)>`. `Moved(rows)`, `Booted`,
  `Masks{first}`, `Ended(why)`: the notifications to push, per sink, as
  both hosts push them today; `Ended` also drains the listens with their
  closing answers.

`Effect` is small: `Submit { ops: Vec<Encoded>, atomic: bool }`,
`Claim(args)`, `Release(ids)`, `Blob { type, bytes }`. `Outcome` mirrors it:
`Submitted { verdicts: Vec<Option<Verdict>>, atomic, lost }`,
`Claimed(reply | refusal)`, `Released(reply | refusal)`,
`Blob(sha | why)`.

`Facts` is what only the host knows, handed in on every call: the key's
masks, account and session ids, the label, whether the lease is held and
which applications, the paused note if any, the bulk contract's remaining
writes and seconds, the rev, the origin for blob URLs, and `dead`/not
connected (the daemon's; the node is always connected). The daemon's
`holder(app)`, `draw(n)`, `op_ids(n)` and `adopt(id)` are facts and effects
too: the node answers them from its lease (`Hireme.Lease`), the daemon from
its upstream's book.

Sinks: the machine never holds a channel or a pid. A host registers a sink
id when a stream opens (the SSE GET, a `subscriptions/listen`, stdio) and
drops it when the stream goes; `event` and the listen's acknowledgment name
sink ids, and the host delivers.

Both eras, exactly as today (`MODERN` with `_meta` version and client
capabilities, `LEGACY` by `initialize`; `server/discover`; batches not
answered; the request-id rules; `notifications/cancelled`).

## The hosts

**Daemon** (`agent.rs`, after): per agent one `Session`; `request` on a
replica (`up.read(|k| session.request(k, facts, msg))`); effects on the
upstream (`submit`, `claim`, `release`, `put_blob`); `resume` on a replica
again; the upstream's event broadcast into `session.event`, its
notifications sent to the sinks the front owns. `front.rs`, `upstream.rs`,
`link.rs`, `main.rs` unchanged in substance.

**Node** (`mcp.ex`, after): the plug as today (key auth, refusals, the
per-address and per-key limits, SSE, blobs). `HiremeWeb.Mcp.Session` keeps
the host plumbing it has today and nothing else: the wire session it hosts
(HELLO, pings, BYE), the registry with the key's cap, the idle timer, the
stream monitors, the verdict collection with its deadline (the `calls` map,
`{:sequencer, :verdicts}`), the bulk contract, and the effects: `Submit` →
`Sequencer.call` as the ops are submitted today; `Claim`/`Release` → the
lease as `lease`/`release` run today; `Blob` → `Hireme.Blobs.put`. The
session machine lives in a NIF resource (`Mutex<Session>`, the pattern of
the kernel's `Res`): `mcp_open(facts)`, `mcp_request(res, kernel_res, facts,
msg)` and `mcp_resume(res, kernel_res, facts, outcome)` run inside
`Sequencer.read`, where the kernel is at hand; `mcp_event(res, event)`
answers the notifications to push. The Elixir tool layer (`tool/6`,
`run/6`, `cv`, `mission` views, `write`, `submit`'s rendering, the
`hireme` text, `read_resource`, `subscribe`) goes: about 1,100 lines.

Byte-identical answers are the test: `test/hireme_web/mcp_test.exs` pins
the node's texts and structured content today and must pass unchanged
(the tenancy pin among them); `test/hireme_web/agent_attack_test.exs` the
wire; the daemon's own tests; and the daemon against a bench node (the
checks of 0e5443b) and read-only against production through the gate.

## Landings

1. (1a5afe0) `native/mcp/src/session.rs` extracted from `agent.rs`; the daemon drives
   it; no node change; net near zero. Gates: cargo test -p mcp (client),
   clippy over the workspace, the bench-node checks, a read-only run against
   production.
2. (3477b96) The node drives the same machine through the NIF; the Elixir tool layer
   deleted; mcp.ex at its plumbing. Gates: the two Elixir suites unchanged,
   mix test whole, the acceptance (test/e2e/run.sh), the daemon's checks
   again (the crate changed under it). Net about -1,000.
3. fable-overwatch's pass: simplification over both (one failure type for a
   read, one JSON-RPC error builder on the node, the dead ends), the ledger.

Rules as ever: explicit-path commits, no amend, push to main, each sha in
the team log; the lane names the files it is in before it writes them.
