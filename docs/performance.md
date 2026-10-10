# Performance audit — 2026-10-09

## Scope and release

Baseline: `8104696`. Measured final application: `5531fef`.
Final immutable release: `/nix/store/hwi5r2gmijj68lmya1ndk5lhcn9s4wch-hireme-0.1.0-5531fef`.
The tables below compare those two releases. The subsequent outbox release changes notification behavior and is documented separately below; its controlled-provider measurements are not mixed into the original tables.

The dominant costs were repeated application work, not evidence of an intrinsically slow Elixir runtime: per-card heat/ATS calculations, loading rich cards for a score histogram, redundant reads after writes, and unnecessary DOM replacement. The packet format and WASM path were exercised end to end; packet construction now makes one binary per column, and startup fetches the kernel and packet concurrently. Public packet bytes remained identical in the parity workloads.

The latency tables are local production-release measurements, not measured live Internet latency. **Release `5531fef` was deployed to `hireme.anghel4d.com` on Hetzner fsn1-2 (`49.12.102.5`) at 2026-10-09 10:10:21 UTC**, after the operator opened the hardware-backed SSH master. The previous release was `8104696`; no alternative identity or hardware-policy bypass was used. **fsn1-1 / heijo.org was not touched.**

Initial performance-release deployment evidence:

- Online, WAL-aware backup: `/var/lib/hireme/backups/hireme-20261009T100927.db`, owned by `hireme`, mode `0600`; SQLite integrity check returned `ok` before the release switch.
- At that deployment, `/nix/var/nix/profiles/hireme` pointed to the exact measured release above. `hireme.service` and nginx were active; Hireme remained at PID 2342 with zero restarts during verification.
- The service's pre-start migration applied `20261009000000`; `gym_reps_account_id_done_on_index` exists on `(account_id, done_on)`. The live database integrity check returned `ok`, and the application listener remains restricted to `127.0.0.1:4000`.
- Public HTTPS checks: `/sign-in` returned 200; unauthenticated `/api/pack` returned 401; the final JavaScript bundle and WASM kernel returned 200 and their SHA-256 digests matched the local measured release byte-for-byte.
- Chromium rendered the live sign-in page and its email form. No synthetic production credentials were created. Signed-in production interactions and external mail delivery were not exercised during this rollout; their local testbed evidence must not be confused with a live authenticated smoke test.

### Security-notice outbox rollout

**Current production release: `94ac794`, deployed to fsn1-2 at 2026-10-09 12:23:10 UTC.** Immutable closure: `/nix/store/x6mla64irz9sfmc7zff145afhlridw8p-hireme-0.1.0-94ac794`. This supersedes `5531fef`.

The original testbed's test mail adapter omitted provider latency. Security notices previously waited for the provider inside account-change requests. This release's outbox persists notice intent before returning and delivers through one supervised worker with bounded retries. It does not guarantee delivery: the post-change/pre-enqueue gap remains, exhausted rows retain their error, and a crash after provider acceptance can cause a duplicate. Sign-in-link mail was still synchronous at `94ac794`; commit `0a87040` in the later realtime rework below changed it to a supervised asynchronous send. Request-return timing is not email-delivery timing. Neither change claims to accelerate mail-free TOTP verification or Account GET.

- Pre-switch online backup `/var/lib/hireme/backups/hireme-20261009T122227.db` passed integrity checking; mode `0600`, owned by `hireme`.
- The release profile was switched from `5531fef`; service pre-start migration applied `20261009010000` and created `mail_outbox`. The live database integrity check returned `ok`.
- Hireme and nginx were active; Hireme started as PID 2893 with zero restarts during verification. A read-only RPC against the running application confirmed `Hireme.Mailer.Outbox` was alive.
- Public HTTPS sign-in returned 200 and unauthenticated `/api/pack` returned 401. The served JavaScript and WASM matched this release byte-for-byte.
- The outbox was empty immediately after migration. No production security notices or synthetic credentials were created for this smoke check, so it does not establish live mail-delivery latency or authenticated account-operation timings. Whole-request journal durations must not be represented as isolated provider latency.


## Realtime rework — 2026-10-09

The desk no longer waits on HTTP. The browser holds the desk in a Rust WebAssembly kernel (`native/kernel`) and draws every interaction from it; a write is predicted in the same frame and settled by the server. Everything travels as columnar frames (`priv/wire/schema.txt`) over one session per tab: WebTransport through the gate sidecar (`native/gate`), or a WebSocket at `/wire` where UDP is blocked. `Hireme.Ops` serializes every write per account (op ledger, revisions, post-commit deltas of only the changed rows), and an agent holds one block lease on its session (`native/mcp`).

**All numbers in this section are local**: a scratch copy of the canonical 1,000-job fixture, loopback, Chromium 154, the same 5950X/WSL2 host. They are not production Internet latency and were not taken with the corrected harness above; the release has not been deployed.

**Deployed to fsn1-2 at 2026-10-09 15:03 UTC** as release `a9c4816`, with the WebTransport gate enabled; the WebSocket fallback stays. Pre-switch online backup `hireme-20261009T150255.db` passed `pragma integrity_check`. After the switch: `hireme`, `hireme-gate` and nginx active, no failed units; the gate's wildcard certificate was issued by Let's Encrypt through DNS-01; UDP 443 is bound on the gate's own address only and TCP 443 there is closed; the served `kernel.wasm` matches the release byte for byte; the CSP allows the gate origin; `/api/pack` answers 404. From the operator's workstation, the QUIC handshake to the gate takes 27.5 ms (one round trip) against 42–74 ms for a TCP connect to Cloudflare's edge and 113–145 ms for a full request through Cloudflare to the origin. No synthetic production credentials were created, so a signed-in desk session over the gate had not been exercised when this was written.


| What | Before (HTTP) | After (wire) | Source |
|---|---|---|---|
| hjkl to full focus painted | p50 60.6 / p99 75.5 ms at 47 ms emulated RTT; 1 fetch per move | p50 4.1 / p99 5.3 ms; same frame; 0 requests | shell lane, input timeStamp → paint |
| Stage click drawn | p50 59.5 / p99 84.1 ms at 47 ms RTT | p50 3.1 ms; same frame | shell lane |
| Cold load to 1,000 rows | 3–4 sequential requests | ~400 ms (WS) / ~470 ms (WT, includes browser start) | link lane |
| Reload | same as cold | snapshot painted at ~120 ms, live at ~130–150 ms; resume = 3 frames, 184 B | link lane |
| Board bytes | 249 KB raw / 36 KB gzip (HDP1) | 178 KB raw / 24 KB deflated BOOT | wire encoder |
| Whole-desk focus stream | 29 KB JSON per focus on demand | 0.9 MB deflated for all 1,000, 0.62 s of server reads cold; cached across sessions | lead |
| Kernel | `desk.wat` select | BOOT ingest 251 µs, select 26 µs, op push 2 µs, one-row PATCH + select 41 µs (node); 83 KB / 33 KB gzipped | kernel lane |
| Gate hop | — | stream round trip p50 0.32 ms (QUIC alone 0.21 ms) | gate lane |
| Sign-in link request | waited on the mail provider | answers before the provider; supervised send with retries, link never stored | ops lane |

Correctness evidence: a seeded property test (boot ⊕ deltas = fresh `list_cards`, consecutive revisions, no delta on refusal, fails if heat kin is disabled); kernel predictions checked against an independent model over 300 seeds; every op kind refused for foreign and missing targets without stalling the session; golden frames shared by the Elixir, Rust and TypeScript readers; `mix test` fails if `kernel.wasm` was built against another schema.

## Round two: views derived in the browser — 2026-10-09 (main, not deployed)

The browser now receives the account's raw rows instead of server-derived views, and the Rust kernel derives every view (cards, heat verdicts, heat chart, scoreboard, focus, root CV, lanes, account page); writes are predicted exactly, derived fields included. The server sends only the columns a write changed and replays missed revisions on reconnect. Measured locally on a copy of the canonical 1,000-job fixture with [`bench/desk.mjs`](../bench/desk.mjs) (Chromium 154, WebSocket, a fresh browser context per scenario, inputs fired in-page), p50 / p99 ms, every interaction drawn in the input's frame and 0 HTTP requests:

| Interaction | Round one release | Round two |
|---|---|---|
| Cold load, first card | — | 240 / 364 (357 at 47 ms emulated RTT) |
| hjkl to full focus | 4.5 | 4.6 / 6.2 |
| Card click | — | 4.9 / 6.7 |
| Search keystroke | 2.2 | 2.7 / 18.5 |
| Battleplan open / Escape | 6.2 / 22–35 | 6.8 / 5.6 |
| Stage write drawn, kin cards exact in that frame | 3.4 (derived fields settled later; kin exact 0/30) | 3.4 / 12.4 (kin exact 80/80) |
| CV line hide / restore / alter save | — | 8.3 / 7.8 / 6.5 |
| HEAT override | — | 15.0 (script 4.1) |
| Band filter / heat filter | — | 15.6 / 3.9 |
| Gym log / net log | not in frame (4/20) | 8.7 / 7.3 |
| Lenses: gym, net, root, account | account 5.5 + 1 HTTP | 6.1, 5.0, 3.8, 3.9 |
| Another tab's stage write, writer input to watcher paint | — | 23.4 / 38.3 |

Server and kernel, same fixture: a raw BOOT is 2.03 MB raw, ~90 KB deflated, read in ~32 ms outside the sequencer; a resume within the ring costs 66 µs; the kernel's push + derive + select is 0.08 ms (`next`) and 0.24 ms (stage move) in node, cold BOOT + derive 19 ms; `kernel.wasm` is 227 KB (88 KB gzipped). Agents and the sequencer's write path: see wave 4 below.

Not measured on the real network path yet: only the gate's handshake has been (`bench/gate.mjs`: QUIC RTT ~25–36 ms from the operator's workstation). The release builds byte-identically from any path (`nixos-server/scripts/hireme-repro.sh`), as does `kernel.wasm` (`native/kernel/build.sh --check`).

## Surgical lease-invalidation follow-up

The kernel now extends dirty-card IDs directly from the two lease-difference iterators instead of collecting two temporary vectors. The reproducible WASM shrank from 313,972 to 313,500 bytes. An isolated native allocator experiment preserved identical outputs across 40 cases: one-ID churn reduced allocation/reallocation calls from 3 to 1 and cumulative requested bytes from 48 to 16. This is not a universal byte reduction: replacing 16 leases with an already nonempty dirty list changed 8 to 5 calls but 428 to 496 requested bytes because of vector growth. No end-to-end latency gain is claimed for this edit. Verification: kernel rebuild reproduced, kernel fixtures and 40 seeded operation streams passed, a 200-operation Elixir oracle comparison had zero differences, and 184 ExUnit tests passed after integration with the concurrent wave changes.

## Session-revocation notification ordering

`Accounts.revoke_session/1` now persists `revoked_at` before publishing the account-change notification, matching the existing other-session revocation path. This prevents an observer from re-reading the still-active row on the only notification; command-time authentication checks are unchanged. The 10 account tests passed, and a disposable local PubSub smoke observed 20 revocations: the first change notification saw the revoked timestamp, no active-list row, and a rejected token. No latency gain or authorization-bypass claim is made.

## Wave 4: block leases and the group-commit sequencer — 2026-10-10 (main `e5d19a3`; the writers' lock at `efe6d1c`; not deployed)

An agent leases a block of its account's entries on one session (`lease {"count": 16}`), and the sequencer seals writes in groups: a session keeps its ops in flight, the drainer commits a batch in one transaction and answers as it seals, the WAL is checkpointed on a budget instead of growing without end, and nothing of the op ledger lives in memory (a resend is caught by the ledger's unique key and answered from the table). Measured locally on a copy of the canonical 1,000-job fixture with `bench/letterbox.mjs`: ten agents with sixteen entries each write `set_score` across their blocks for ten seconds, agent 0 is killed halfway and a spare asks for its block; hireme-mcp over the gate's WebTransport and over `/wire`; the testbed on CPUs 0–15, the agents on 16–31; one run per cell on a quiet box (1-minute load 0.5–2.2; the WS 4-in-flight cell was run three times and its median is shown, with the WS 1-in-flight control at 3,192–3,406 across runs). Before is `c65a37b` (block leases on the old sequencer), after is `e5d19a3`.

| | WS, 1 in flight | WS, 4 in flight | WT, 1 in flight | WT, 4 in flight |
|---|---|---|---|---|
| writes/s, before → after | 1,881 → 3,406 | 1,637 → 3,477 (three runs: 3,030 / 3,477 / 3,628; the median) | 1,495 → 3,647 | 1,506 → 5,772 |
| write p50 ms | 4.79 → 2.59 | 21.73 → 10.25 | 5.66 → 2.37 | 24.30 → 5.87 |
| write p99 ms | 8.32 → 6.85 | 42.14 → 24.24 | 13.39 → 10.41 | 35.38 → 18.31 |
| refusals | 0 | 0 | 0 | 0 |
| dead agent's block back to the spare | 20 → 18 ms | 24 → 33 ms | 2.0 s | 2.0 s (the gate's dead-session detection) |
| ten leases asked at once, p50 / wall ms | 28 / 31 → 27 / 31 | 21 / 28 → 17 / 20 | 14 / 24 → 18 / 22 | 25 / 28 → 18 / 27 |

Single-write guard, one agent on one application, `set_score` p50 / p99: WS 1.21 / 1.85 → 1.05 / 1.32 ms; WT 1.57 / 8.61 → 1.26 / 1.55 ms. In process, `Ops.run`: `next` 0.235 → 0.177 ms with an 80-byte delta, `score` 0.191 ms, a stage move flipping heat 0.595 ms (5.5 ms in the realtime rework). The WAL after a ten-second run is 58–67 MB and steady run over run; before the checkpoint budget it was 386 MB after one run and still growing.

Sequencer cold start against a retained op ledger (`Ops.stop`, then the first write; ten restarts per cell, fresh fixture copy): reading the ledger whole into memory on the first write cost 25 / 155 ms at 1,000 / 100,000 retained rows, and the warm write right after 0.5 / 41 ms. Now the first write is 22 / 22 / 21 ms at 1,000 / 100,000 / 1,000,000 rows, the writes after it 0.2 ms, one ledger row is read per client op, and the sequencer is 3.9 MB after GC at every size.

Writers after that (`3305bee`, `efe6d1c`): the hourly ledger sweep deletes a thousand rows per short commit with a 10 ms pause, so a million expired rows clear in 12 s quiet and 19–30 s under load instead of one statement of about a second; and every write in `lib/` takes one FIFO lock in `Hireme.Store` and begins IMMEDIATE, so two busy sequencers and a writer outside them take turns instead of busy-waiting on SQLite's one writer lock (strongly supported, inferred: the native sleeps are not instrumented). Direct writers from a third account while two accounts saturate the sequencer, p50 / p99 / max ms, before → after: `ApiKeys.create` 0.52 / 54.6 / 280.1 → 0.97 / 1.66 / 4.03; `Audit.record` 0.15 / 79.3 / 630.3 → 0.56 / 2.18 / 3.44; in perfchan's matched windows an innocent account's worst wait 430–882 → 8–32 ms and p99.9 33.8–79.1 → 1.75–2.09 ms, the medians roughly doubled (a turn is waited, not raced). The sequencer path is unchanged in the same session: the guard WS 1.05 / 1.92 against 1.15 / 2.25 and WT 1.20 / 2.51 against 1.21 / 2.50, in-process `next` 0.181 ms, cold start at a million rows 21 ms, the depth-4 cells 3,346 WS / 6,060 WT writes/s. A possible throughput trade to check, not proven: the two-account aggregate in perfchan's windows was 4,506–4,603 → 4,042–4,362 writes/s (−4 to −10%), from runs that were not same-session pairs. Scope: fairness holds among writers that take the lock, in this VM; a write that skips it (tests, migrations) or another VM on the same file contends at SQLite's lock as before. Open: with no sweep running the WAL grew to 2.2–2.7 GB over those windows before the quiescent reset, and the first write after quiescence costs about 250–300 ms.

Correctness evidence: the sequencer's batch property (boot ⊕ deltas equals a fresh read across seeded op streams; a resend is answered from the ledger and writes nothing; two copies of one op id in a batch run once) and `native/kernel/parity.mjs` against the oracle (zero differences on three seeds after the server-side heat snapshot left) held throughout. Net change to the tree over the wave: hireme -39 lines (23 of them this section), nixos-server 0.

## How to read the measurements

- All latency columns are **milliseconds**. `beforems` and `afterms` are medians. The repeated current `p50` is deliberate: it matches the requested report columns.
- Quantiles use nearest rank, recomputed from retained raw samples. These are observed quantiles, **not statistical confidence intervals**. Original harness quantiles are retained separately where the convention differed.
- `n before / after` is the number of successful measured samples, not a confidence level. Small cohorts have very coarse tails: p99.9 for n=15, 40, 100, 150 or 200 is effectively a maximum; even n=1,000 has little tail resolution.
- Both versions use immutable production releases, separate SQLite copies and the same synthetic fixture. Baseline was not rebuilt from the changing working tree.
- Host: AMD Ryzen 9 5950X, 16 cores / 32 threads, Linux 6.18.40.1 WSL2. Backend work was pinned within CPUs 0–15; browser work within 16–31. Domain reads used four BEAM schedulers, durable-write harnesses two. This is shared-host evidence, not an isolated production hardware certification.
- Canonical fixture: 1,000 jobs, 100 employers, 100 hot jobs, 10 batches, three CV profiles with 90 total items, 2,000 Gym reps and 2,000 Net entries. Canonical URLs do not identify an ATS; separate Greenhouse cohorts prevent that blind spot from hiding ATS costs.
- Greenhouse rows use the same 1,000 jobs with 100 or 1,000 hot jobs, across 100 tenants. Those rows are separate workloads, not mixed with the canonical samples.
- Durable action timers cover real committed operations. Fixture preparation, correctness assertions and cleanup occur outside the timer; no encompassing transaction silently rolls back the measured work.
- Security action rows create fresh synthetic accounts, identities and sessions. Valid OTPs, recovery-code hashing and replay protection run normally. Hot authentication rows isolate successful authentication using distinct synthetic peers so the handshake throttle does not turn them into fast rejection benchmarks.
- HTTP rows include authenticated request handling and full response-body transfer over loopback, at closed-loop concurrency 1, 4 and 16. Achieved throughput is reported separately below. This is not an open-loop capacity limit or an Internet SLO.
- MCP rows use authenticated WebSockets and actual directory/leased tool calls. Lease acquisition has only 15 samples; the existing 20/minute peer handshake policy is not disabled. Persistent-socket tool throughput must not be confused with unlimited reconnection throughput.

## Browser interaction latency

Authoritative comparison: **base2 vs final2**, the same corrected harness, the same 20-scenario order, and a fresh canonical database copy per release. Earlier browser runs are superseded, not mixed into these tables. There are 39 paired interactions: **8,317 / 8,315 successful samples**, from **8,320 attempts per release**.

Playwright-core 1.63.0 drove Chromium 154.0.8037.97 headless at 1440×1000 with real input, signed-in synthetic sessions, and frame-throttling suppression flags. The timer starts at the input event and ends at the later of the last content paint and the first frame after the last associated request completes. A scenario-specific quiet window (20–250 ms) establishes completion but is not itself added to the measurement. This matters when a completed read changes nothing visible: the earlier probe could finish too early after the unchanged-title optimization, so **both releases were remeasured**.

- Autosave “from POST” rows exclude debounce; “from input” rows include it. Do not use the faster POST-only row as a claim about complete input-to-save latency.
- Feed rows start when the watching tab receives its first desk signal, not when the other tab begins its write.
- “Emulated 80 ms RTT” adds 80 ms to Chromium HTTP requests; cached resources and WebSocket frames are not delayed. It measures startup dependencies under that emulation, not the production network.
- WebAuthn is a **CDP virtual authenticator** (CTAP2, internal, resident key, user verification). The step-up row covers options, `navigator.credentials.get`, and confirmation, with n=10 because the factor throttle remains active. It is not physical-key or human response time.
- Account and passkey scenarios receive fresh legitimately minted sessions before execution. Refusals are never counted as successful timings.

### account

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| open account | 200 / 200 | 25.800 | 21.300 | 18.200 | 19.600 | 21.300 | 55.800 | 56.300 |
| create api key | 100 / 100 | 39.800 | 38.500 | 21.800 | 21.800 | 38.500 | 57.500 | 58.700 |
| rename api key | 100 / 100 | 38.200 | 36.300 | 20.700 | 20.700 | 36.300 | 51.900 | 52.100 |
| revoke api key | 100 / 100 | 39.700 | 40.500 | 18.400 | 18.400 | 40.500 | 56.400 | 56.500 |
| enroll passkey (virtual authenticator) | 30 / 30 | 68.500 | 65.800 | 63.800 | 63.800 | 65.800 | 71.800 | 71.800 |
| step-up passkey ceremony (virtual authenticator) | 10 / 10 | 9.800 | 8.300 | 7.700 | 7.700 | 8.300 | 13.300 | 13.300 |

### battleplan

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| open (enter) | 300 / 300 | 13.100 | 7.800 | 6.800 | 6.800 | 7.800 | 9.800 | 17.000 |
| back (esc) | 300 / 300 | 21.700 | 19.900 | 17.800 | 17.900 | 19.900 | 22.900 | 30.900 |
| set stage | 300 / 300 | 482.900 | 133.800 | 127.400 | 128.500 | 133.800 | 141.800 | 147.700 |
| mask hide | 150 / 150 | 491.200 | 131.400 | 123.800 | 124.400 | 131.400 | 458.000 | 490.900 |
| mask restore | 150 / 150 | 492.500 | 131.500 | 124.100 | 124.400 | 131.500 | 460.300 | 501.400 |
| mask emphasize | 150 / 150 | 492.000 | 131.400 | 125.600 | 125.600 | 131.400 | 158.500 | 455.100 |
| alter open | 150 / 150 | 22.300 | 20.700 | 19.100 | 19.500 | 20.700 | 22.000 | 22.500 |
| alter save | 150 / 150 | 489.000 | 130.400 | 122.900 | 123.300 | 130.400 | 139.200 | 140.300 |
| note autosave | 150 / 150 | 432.800 | 12.800 | 12.000 | 12.000 | 12.800 | 15.000 | 16.300 |
| note autosave (from input, incl. 500 ms debounce) | 100 / 100 | 932.800 | 516.000 | 514.800 | 514.800 | 516.000 | 520.100 | 520.300 |

### desk

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| page load | 150 / 150 | 536.500 | 214.200 | 199.300 | 199.300 | 214.200 | 374.600 | 512.700 |
| page load (emulated 80 ms RTT) | 50 / 50 | 730.900 | 322.100 | 308.300 | 308.300 | 322.100 | 339.200 | 339.200 |
| search keystroke | 1000 / 1000 | 12.200 | 3.900 | 3.400 | 3.500 | 3.900 | 18.500 | 20.100 |
| search clear | 140 / 140 | 20.800 | 19.700 | 6.200 | 6.200 | 19.700 | 23.400 | 26.300 |
| hjkl move | 1000 / 1000 | 25.900 | 16.800 | 15.100 | 15.800 | 16.800 | 21.200 | 25.400 |
| click card | 500 / 500 | 28.300 | 15.200 | 13.100 | 13.200 | 15.200 | 22.700 | 30.400 |
| scroll 400px | 500 / 495 | 18.000 | 17.000 | 9.700 | 9.700 | 17.000 | 20.000 | 20.700 |
| filter band | 300 / 300 | 16.800 | 16.600 | 6.700 | 6.800 | 16.600 | 20.000 | 21.600 |
| filter heat | 300 / 300 | 15.300 | 14.600 | 2.800 | 2.800 | 14.600 | 18.800 | 19.900 |
| next action autosave | 150 / 150 | 452.900 | 113.700 | 108.600 | 108.900 | 113.700 | 174.700 | 444.400 |
| next action autosave (from input, incl. 400 ms debounce) | 100 / 100 | 854.500 | 513.500 | 508.300 | 508.300 | 513.500 | 533.800 | 544.500 |
| heat override | 60 / 60 | 444.300 | 131.100 | 110.300 | 110.300 | 131.100 | 138.000 | 138.000 |
| back to board | 200 / 200 | 22.900 | 17.800 | 16.600 | 17.000 | 17.800 | 21.300 | 22.300 |

### feed

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| other tab: stage | 100 / 100 | 472.400 | 121.800 | 108.800 | 108.800 | 121.800 | 133.700 | 142.500 |
| other tab: mask | 98 / 100 | 491.100 | 108.100 | 98.600 | 98.600 | 108.100 | 118.800 | 611.600 |
| other tab: 5 stages | 29 / 30 | 2186.800 | 242.500 | 232.400 | 232.400 | 242.500 | 254.700 | 254.700 |

### gym

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| open gym | 200 / 200 | 27.900 | 22.800 | 15.200 | 17.300 | 22.800 | 24.000 | 27.300 |
| log rep | 150 / 150 | 24.300 | 38.900 | 19.500 | 20.800 | 38.900 | 40.700 | 41.200 |
| set target | 150 / 150 | 22.200 | 37.100 | 19.200 | 19.300 | 37.100 | 39.100 | 39.500 |

### net

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| open net | 200 / 200 | 26.500 | 21.800 | 15.700 | 17.900 | 21.800 | 23.200 | 27.500 |
| log entry | 150 / 150 | 39.300 | 26.700 | 19.900 | 19.900 | 26.700 | 29.700 | 31.400 |
| set lane | 150 / 150 | 50.500 | 33.200 | 20.400 | 31.500 | 33.200 | 34.000 | 34.200 |

### root

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| open root cv | 200 / 200 | 25.200 | 21.000 | 16.700 | 18.800 | 21.000 | 56.400 | 57.100 |

### Browser attempts and request fanout

Counts are **before / after**. `failed` means a timeout; `no-op` means the input caused no observed change within two seconds; `refused` means a 4xx/5xx response. All remain visible even though they are excluded from successful latency quantiles. Baseline's two other-tab mask failures and one five-stage-burst failure were writer clicks on re-rendering nodes that produced no signal. The final scroll row contains five no-ops. Neither release had a refused sample.

| Page / interaction | Attempts | Refused | Failed | No-op | Requests per attempt |
|---|---:|---:|---:|---:|---:|
| desk / page load | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 6.00 / 6.00 |
| desk / page load (emulated 80 ms RTT) | 50 / 50 | 0 / 0 | 0 / 0 | 0 / 0 | 6.00 / 6.00 |
| desk / search keystroke | 1000 / 1000 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| desk / search clear | 140 / 140 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| desk / hjkl move | 1000 / 1000 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| desk / click card | 500 / 500 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| desk / scroll 400px | 500 / 500 | 0 / 0 | 0 / 0 | 0 / 5 | 0.00 / 0.00 |
| desk / filter band | 300 / 300 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| desk / filter heat | 300 / 300 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| battleplan / open (enter) | 300 / 300 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| battleplan / back (esc) | 300 / 300 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| battleplan / set stage | 300 / 300 | 0 / 0 | 0 / 0 | 0 / 0 | 7.99 / 4.99 |
| battleplan / mask hide | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 8.97 / 2.99 |
| battleplan / mask restore | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 9.00 / 2.99 |
| battleplan / mask emphasize | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 8.90 / 2.99 |
| battleplan / alter open | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| battleplan / alter save | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 9.00 / 2.99 |
| battleplan / note autosave | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 4.00 / 1.00 |
| desk / next action autosave | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 4.00 / 2.00 |
| battleplan / note autosave (from input, incl. 500 ms debounce) | 100 / 100 | 0 / 0 | 0 / 0 | 0 / 0 | 4.00 / 1.00 |
| desk / next action autosave (from input, incl. 400 ms debounce) | 100 / 100 | 0 / 0 | 0 / 0 | 0 / 0 | 4.00 / 2.00 |
| desk / heat override | 60 / 60 | 0 / 0 | 0 / 0 | 0 / 0 | 4.00 / 3.00 |
| root / open root cv | 200 / 200 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| desk / back to board | 200 / 200 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| gym / open gym | 200 / 200 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| net / open net | 200 / 200 | 0 / 0 | 0 / 0 | 0 / 0 | 0.00 / 0.00 |
| gym / log rep | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| gym / set target | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| net / log entry | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| net / set lane | 150 / 150 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| feed / other tab: stage | 100 / 100 | 0 / 0 | 0 / 0 | 0 / 0 | 4.00 / 4.00 |
| feed / other tab: mask | 100 / 100 | 0 / 0 | 2 / 0 | 0 / 0 | 4.90 / 2.00 |
| feed / other tab: 5 stages | 30 / 30 | 0 / 0 | 1 / 0 | 0 / 0 | 19.33 / 16.03 |
| account / open account | 200 / 200 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| account / create api key | 100 / 100 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| account / rename api key | 100 / 100 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| account / revoke api key | 100 / 100 | 0 / 0 | 0 / 0 | 0 / 0 | 1.00 / 1.00 |
| account / enroll passkey (virtual authenticator) | 30 / 30 | 0 / 0 | 0 / 0 | 0 / 0 | 2.00 / 2.00 |
| account / step-up passkey ceremony (virtual authenticator) | 10 / 10 | 0 / 0 | 0 / 0 | 0 / 0 | 2.00 / 2.00 |

### Flagged browser comparisons

- **Gym / Net frame pacing:** the primary table retains final Gym medians around 38.9/37.1 ms and baseline Net medians around 39.3/50.5 ms. These runs showed a roughly 16.7 ms frame step. Separate fresh-bed repeats showed the step can affect either release: one baseline repeat shifted all four interactions, while another baseline and both final repeats did not. This supports an environmental frame-pacing explanation; it is not a reason to silently subtract time or replace the primary observations. Unshifted diagnostic medians were Gym log 24.1→22.5, Gym target 22.2→20.6, Net log 23.5→21.7 and Net lane 33.2→33.2 ms. POST completion was approximately 15–16 ms in both releases. Raw diagnostic repeats are retained separately.
- **Five-stage burst:** five unwaited writer clicks make the exact result timing-sensitive. Observed medians across runs were approximately 1,743/2,187 ms before and 166/243 ms after. The direction is consistent; a precise universal percentage is not established.
- **Passkey enrollment:** account history matters. Fresh-bed enrollment was about 40 ms, versus 66–69 ms after 100 API-key cycles in either release. Only the main pair, in the same scenario position and state, is used here (68.5→65.8 ms).

Browser evidence: [`browser-before.jsonl.gz`](../bench/results/browser-before.jsonl.gz), [`browser-after.jsonl.gz`](../bench/results/browser-after.jsonl.gz), and separate [`browser-variance.jsonl.gz`](../bench/results/browser-variance.jsonl.gz). Rows retain samples, attempts, refusal/failure/no-op counts, per-operation request fanout and request traces for the first five samples. The committed portable harnesses were `browser.mjs` (replaced in round two by [`desk.mjs`](../bench/desk.mjs); in git history at `5e3574b`), [`mcp.mjs`](../bench/mcp.mjs), and [`mint.exs`](../bench/mint.exs); their headers document invocation and required environment. Credential minting is confined to a testbed directory and the mint VM cannot start an HTTP listener.

## Server, domain, security and MCP latency

All 128 paired rows are included, including unchanged paths and regressions.

### Domain/ATS

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| parse | 10000 / 1000 | 0.007330 | 0.007310 | 0.007100 | 0.007140 | 0.007310 | 0.021290 | 0.042450 |

### Domain/Accounts

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| session_authenticate_hot | 100000 / 100000 | 0.100439 | 0.071859 | 0.053990 | 0.056899 | 0.071859 | 0.661722 | 1.412 |
| session_create | 1000 / 1000 | 0.368547 | 0.200168 | 0.169308 | 0.171289 | 0.200168 | 0.667724 | 3.930 |
| session_revoke | 1000 / 1000 | 0.382082 | 0.153949 | 0.128809 | 0.131768 | 0.153949 | 0.701992 | 3.399 |
| identity_link_synthetic_claim | 1000 / 1000 | 0.404316 | 0.424076 | 0.356217 | 0.369787 | 0.424076 | 1.227 | 1.370 |
| identity_unlink | 1000 / 1000 | 0.408786 | 0.448665 | 0.368346 | 0.374627 | 0.448665 | 0.884682 | 1.063 |
| magic_link_request_test_sink | 1000 / 1000 | 0.377346 | 0.249357 | 0.206268 | 0.210578 | 0.249357 | 0.710983 | 0.925531 |
| magic_link_redeem | 1000 / 1000 | 0.220447 | 0.235257 | 0.200598 | 0.206558 | 0.235257 | 3.466 | 4.059 |
| session_authenticate | 1000 / 1000 | 0.093079 | 0.078079 | 0.066200 | 0.067279 | 0.078079 | 0.395576 | 0.569285 |
| list_sessions | 1000 / 1000 | 0.061090 | 0.067359 | 0.055519 | 0.056369 | 0.067359 | 0.230448 | 0.270308 |

### Domain/ApiKeys

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| authenticate_hot | 100000 / 100000 | 0.112049 | 0.084929 | 0.066219 | 0.069040 | 0.084929 | 0.624394 | 1.324 |
| usable | 100000 / 100000 | 0.087559 | 0.063859 | 0.046770 | 0.049219 | 0.063859 | 0.610034 | 1.394 |
| api_key_create | 1000 / 1000 | 0.550924 | 0.823752 | 0.364097 | 0.375017 | 0.823752 | 1.301 | 1.468 |
| api_key_revoke | 1000 / 1000 | 0.438925 | 0.384996 | 0.314307 | 0.318747 | 0.384996 | 4.181 | 4.804 |
| list | 1000 / 1000 | 0.043099 | 0.043910 | 0.040230 | 0.040660 | 0.043910 | 0.210968 | 0.343977 |

### Domain/CV

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mask_hide_shared_2 | 1000 / 1000 | 2.529 | 1.969 | 1.672 | 1.727 | 1.969 | 2.648 | 3.074 |
| mask_alter_shared_2 | 1000 / 1000 | 2.637 | 1.955 | 1.623 | 1.691 | 1.955 | 2.381 | 2.693 |
| mask_emphasize_shared_2 | 1000 / 1000 | 2.622 | 1.986 | 1.723 | 1.790 | 1.986 | 2.437 | 3.520 |
| mask_restore_shared_2 | 1000 / 1000 | 2.406 | 1.798 | 1.540 | 1.583 | 1.798 | 4.553 | 5.208 |
| compose | 1000 / 1000 | 0.002139 | 0.002130 | 0.002070 | 0.002080 | 0.002130 | 0.005600 | 0.035589 |

### Domain/Campaign

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| batch_open_fire | 1000 / 1000 | 0.198188 | 0.136329 | 0.122858 | 0.124499 | 0.136329 | 0.404216 | 0.700253 |
| scoreboard | 1000 / 1000 | 0.887861 | 0.866631 | 0.781292 | 0.798123 | 0.866631 | 1.170 | 1.485 |

### Domain/Corpus

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| list_items | 1000 / 1000 | 0.250618 | 0.272048 | 0.226737 | 0.233328 | 0.272048 | 0.397716 | 0.458236 |

### Domain/Desk

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| job_add_new_employer | 1000 / 1000 | 3.677 | 2.803 | 1.551 | 1.656 | 2.803 | 5.870 | 6.891 |
| job_add_existing_employer_shared_overlay | 1000 / 1000 | 2.074 | 1.760 | 1.109 | 1.170 | 1.760 | 4.465 | 6.026 |
| score_change | 1000 / 1000 | 0.382457 | 0.201858 | 0.178518 | 0.181328 | 0.201858 | 1.133 | 3.065 |
| next_action | 1000 / 1000 | 0.370386 | 0.191639 | 0.168818 | 0.170369 | 0.191639 | 1.036 | 1.511 |
| note_save | 1000 / 1000 | 0.357396 | 0.179868 | 0.163249 | 0.165938 | 0.179868 | 0.650774 | 2.673 |
| stage_non_entering | 1000 / 1000 | 0.759252 | 0.406326 | 0.341307 | 0.347447 | 0.406326 | 1.052 | 3.019 |
| stage_entering_heat_gate | 1000 / 1000 | 4.066 | 2.366 | 2.123 | 2.178 | 2.366 | 3.094 | 5.283 |
| list_cards | 1000 / 1000 | 398.754 | 85.045 | 80.417 | 80.891 | 85.045 | 93.368 | 179.517 |
| focus | 1000 / 1000 | 2.080 | 1.536 | 1.248 | 1.294 | 1.536 | 2.120 | 2.584 |
| root | 1000 / 1000 | 0.461125 | 0.474606 | 0.357346 | 0.361386 | 0.474606 | 0.679314 | 1.033 |
| score_chart | 10000 / 1000 | 0.636484 | 0.527005 | 0.489765 | 0.498405 | 0.527005 | 0.667974 | 1.107 |
| score_distribution | 100 / 1000 | 398.632 | 0.860301 | 0.781702 | 0.795052 | 0.860301 | 1.122 | 1.389 |
| list_cards — greenhouse_1000_jobs_100_hot | 40 / 1000 | 545.197 | 86.065 | 81.386 | 82.017 | 86.065 | 95.593 | 110.797 |
| list_cards — greenhouse_1000_jobs_1000_hot | 40 / 1000 | 5634.756 | 163.036 | 153.571 | 155.212 | 163.036 | 177.035 | 183.335 |

### Domain/Gym

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| log_existing_problem | 1000 / 1000 | 0.364566 | 0.422436 | 0.345557 | 0.363496 | 0.422436 | 0.725334 | 3.116 |
| log_new_problem | 1000 / 1000 | 0.449485 | 0.568995 | 0.475345 | 0.494555 | 0.568995 | 1.039 | 1.212 |
| set_target | 1000 / 1000 | 0.133239 | 0.094649 | 0.081099 | 0.083739 | 0.094649 | 0.276877 | 0.741264 |
| progress | 1000 / 1000 | 4.321 | 3.250 | 2.986 | 3.027 | 3.250 | 3.964 | 4.520 |
| recent | 1000 / 1000 | 1.067 | 0.548695 | 0.491495 | 0.505375 | 0.548695 | 1.000 | 1.128 |

### Domain/Heat

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| override_with_reason | 1000 / 1000 | 0.548065 | 0.289467 | 0.259848 | 0.262667 | 0.289467 | 1.213 | 1.324 |
| snapshot | 1000 / 1000 | 5.569 | 2.714 | 2.597 | 2.624 | 2.714 | 3.962 | 4.409 |
| chart | 1000 / 1000 | 5.708 | 2.877 | 2.735 | 2.764 | 2.877 | 4.152 | 4.383 |
| can_apply | 1000 / 1000 | 3.041 | 1.962 | 1.823 | 1.838 | 1.962 | 3.140 | 3.228 |
| mix_batch_100 | 1000 / 1000 | 43.717 | 38.268 | 36.810 | 36.996 | 38.268 | 51.621 | 54.436 |

### Domain/Import

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| batch_new_1_apps | 1000 / 1000 | 7.590 | 6.387 | 5.761 | 5.869 | 6.387 | 7.736 | 8.406 |
| batch_update_1_apps | 1000 / 1000 | 5.154 | 3.500 | 3.227 | 3.254 | 3.500 | 4.152 | 4.733 |
| batch_idempotent_1_apps | 1000 / 1000 | 4.103 | 3.078 | 2.829 | 2.853 | 3.078 | 3.818 | 4.171 |
| batch_new_55_apps | 100 / 100 | 223.879 | 192.903 | 181.143 | 181.143 | 192.903 | 255.145 | 259.290 |
| batch_update_55_apps | 100 / 100 | 89.224 | 59.809 | 57.680 | 57.680 | 59.809 | 63.911 | 64.239 |
| batch_idempotent_55_apps | 100 / 100 | 52.527 | 49.687 | 47.761 | 47.761 | 49.687 | 54.790 | 55.347 |

### Domain/KV

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| put_existing | 1000 / 1000 | 0.137079 | 0.094279 | 0.079849 | 0.082939 | 0.094279 | 0.265717 | 0.685393 |

### Domain/Keywords

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| coverage | 1000 / 1000 | 0.166349 | 0.108359 | 0.102119 | 0.102419 | 0.108359 | 0.133278 | 0.221268 |

### Domain/Kv

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| list | 1000 / 1000 | 0.040240 | 0.039829 | 0.034720 | 0.036169 | 0.039829 | 0.196058 | 0.434616 |

### Domain/Letterbox

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| claim | 1000 / 1000 | 0.414387 | 0.414516 | 0.328867 | 0.348017 | 0.414516 | 0.585984 | 0.687483 |
| command_score_commit | 1000 / 1000 | 0.437856 | 0.428886 | 0.364717 | 0.376537 | 0.428886 | 0.607854 | 3.061 |
| release | 1000 / 1000 | 0.040940 | 0.041419 | 0.037460 | 0.038000 | 0.041419 | 0.063669 | 0.074349 |

### Domain/Mfa

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| enrolled_0_factors | 100000 / 100000 | 0.057950 | 0.027950 | 0.023049 | 0.023309 | 0.027950 | 0.088549 | 0.831532 |
| enrolled_1_factors | 100000 / 100000 | 0.068359 | 0.028680 | 0.023679 | 0.024000 | 0.028680 | 0.091059 | 0.772522 |
| enrolled_10_factors | 100000 / 100000 | 0.121318 | 0.028729 | 0.023900 | 0.024190 | 0.028729 | 0.098569 | 0.672554 |
| totp_begin_enrollment_qr | 1000 / 1000 | 26.883 | 26.408 | 25.607 | 25.767 | 26.408 | 29.685 | 31.061 |
| totp_confirm_first_factor | 1000 / 1000 | 2.159 | 1.401 | 1.133 | 1.179 | 1.401 | 2.755 | 3.149 |
| totp_step_up | 1000 / 1000 | 0.368456 | 0.386456 | 0.336046 | 0.341726 | 0.386456 | 0.650074 | 4.362 |
| recovery_verify | 1000 / 1000 | 0.681604 | 0.512095 | 0.442915 | 0.452746 | 0.512095 | 2.855 | 5.223 |
| recovery_reissue | 1000 / 1000 | 1.254 | 0.483895 | 0.406776 | 0.419045 | 0.483895 | 1.460 | 4.859 |
| remove_last_factor_and_recovery | 1000 / 1000 | 0.772052 | 0.515625 | 0.454015 | 0.461366 | 0.515625 | 1.101 | 1.339 |
| enrolled | 1000 / 1000 | 0.061299 | 0.028680 | 0.024709 | 0.025349 | 0.028680 | 0.073599 | 0.096449 |
| methods | 1000 / 1000 | 0.061249 | 0.061489 | 0.055220 | 0.056030 | 0.061489 | 0.308257 | 0.430435 |
| fresh | 1000 / 1000 | 0.064320 | 0.031370 | 0.027370 | 0.028009 | 0.031370 | 0.090099 | 0.211708 |

### Domain/Narrative

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| save_private | 1000 / 1000 | 0.142898 | 0.100599 | 0.089409 | 0.093309 | 0.100599 | 0.292527 | 0.547985 |

### Domain/Net

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| log_draft | 1000 / 1000 | 0.129618 | 0.093089 | 0.081969 | 0.083319 | 0.093089 | 0.399846 | 2.764 |
| log_shipped | 1000 / 1000 | 0.135509 | 0.095389 | 0.083799 | 0.084880 | 0.095389 | 0.419456 | 2.761 |
| set_lane | 1000 / 1000 | 0.131819 | 0.095579 | 0.081459 | 0.086129 | 0.095579 | 0.412496 | 0.671264 |
| progress | 1000 / 1000 | 0.704903 | 0.731743 | 0.638594 | 0.653944 | 0.731743 | 0.924111 | 1.205 |
| recent | 1000 / 1000 | 0.245058 | 0.264888 | 0.195668 | 0.220578 | 0.264888 | 0.373937 | 0.422906 |

### Domain/Org

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| size | 10000 / 1000 | 0.022500 | 0.005480 | 0.005280 | 0.005320 | 0.005480 | 0.023440 | 0.075859 |
| department | 10000 / 1000 | 0.018620 | 0.015849 | 0.015559 | 0.015620 | 0.015849 | 0.052350 | 0.054430 |
| family | 10000 / 1000 | 0.019859 | 0.019790 | 0.019390 | 0.019460 | 0.019790 | 0.038619 | 0.082779 |

### Domain/Security

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| base62_12 | 100000 / 100000 | 0.008590 | 0.001040 | 0.000980 | 0.000990 | 0.001040 | 0.002400 | 0.040370 |
| base62_43 | 100000 / 100000 | 0.028780 | 0.001820 | 0.001710 | 0.001730 | 0.001820 | 0.004330 | 0.203398 |

### HTTP/Account

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| overview (concurrency 1) | 1000 / 1000 | 1.468 | 1.631 | 1.252 | 1.310 | 1.631 | 2.855 | 4.841 |
| overview (concurrency 4) | 1000 / 1000 | 3.808 | 4.251 | 1.613 | 2.611 | 4.251 | 7.079 | 8.477 |
| overview (concurrency 16) | 1000 / 1000 | 18.364 | 19.652 | 11.228 | 13.169 | 19.652 | 26.300 | 27.513 |

### HTTP/Campaign

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| scoreboard (concurrency 1) | 1000 / 1000 | 2.154 | 2.593 | 1.871 | 1.942 | 2.593 | 3.912 | 4.968 |
| scoreboard (concurrency 4) | 1000 / 1000 | 5.293 | 4.413 | 2.113 | 2.605 | 4.413 | 7.180 | 7.778 |
| scoreboard (concurrency 16) | 1000 / 1000 | 25.092 | 18.675 | 6.256 | 11.459 | 18.675 | 28.418 | 35.400 |

### HTTP/Desk

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| shell (concurrency 1) | 1000 / 1000 | 1.409 | 1.187 | 0.909842 | 0.929300 | 1.187 | 2.464 | 4.012 |
| shell (concurrency 4) | 1000 / 1000 | 2.484 | 1.857 | 1.099 | 1.258 | 1.857 | 4.594 | 13.331 |
| shell (concurrency 16) | 1000 / 1000 | 8.409 | 5.122 | 2.371 | 2.983 | 5.122 | 10.410 | 11.279 |
| focus (concurrency 1) | 1000 / 1000 | 7.566 | 5.456 | 4.732 | 4.781 | 5.456 | 7.348 | 8.154 |
| focus (concurrency 4) | 1000 / 1000 | 12.663 | 10.178 | 6.438 | 7.108 | 10.178 | 14.321 | 15.631 |
| focus (concurrency 16) | 1000 / 1000 | 44.481 | 40.730 | 25.215 | 27.780 | 40.730 | 53.256 | 56.265 |
| root (concurrency 1) | 1000 / 1000 | 2.169 | 2.347 | 1.894 | 1.936 | 2.347 | 4.260 | 5.791 |
| root (concurrency 4) | 1000 / 1000 | 4.308 | 4.644 | 2.207 | 2.764 | 4.644 | 9.156 | 9.997 |
| root (concurrency 16) | 1000 / 1000 | 17.267 | 19.177 | 9.504 | 11.394 | 19.177 | 27.905 | 30.478 |

### HTTP/Lanes

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| lanes (concurrency 1) | 1000 / 1000 | 12.827 | 10.102 | 8.543 | 8.799 | 10.102 | 12.223 | 14.521 |
| lanes (concurrency 4) | 1000 / 1000 | 20.151 | 23.825 | 11.663 | 13.965 | 23.825 | 34.042 | 37.173 |
| lanes (concurrency 16) | 1000 / 1000 | 78.381 | 112.720 | 67.320 | 76.229 | 112.720 | 165.072 | 176.203 |

### HTTP/MFA

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| summary (concurrency 1) | 1000 / 1000 | 1.271 | 1.191 | 0.916481 | 0.975241 | 1.191 | 1.885 | 4.577 |
| summary (concurrency 4) | 1000 / 1000 | 3.032 | 2.676 | 1.097 | 1.232 | 2.676 | 4.890 | 7.192 |
| summary (concurrency 16) | 1000 / 1000 | 12.523 | 11.671 | 3.344 | 7.152 | 11.671 | 16.673 | 17.946 |

### HTTP/Packet

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pack (concurrency 1) | 200 / 200 | 421.961 | 97.289 | 92.046 | 92.912 | 97.289 | 103.512 | 104.870 |
| pack (concurrency 4) | 200 / 200 | 472.142 | 107.223 | 98.113 | 98.364 | 107.223 | 141.544 | 143.626 |
| pack (concurrency 16) | 200 / 200 | 1800.036 | 403.581 | 181.643 | 207.534 | 403.581 | 636.891 | 679.265 |

### Transport/JSON

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| focus | 1000 / 1000 | 5.748 | 3.783 | 3.310 | 3.459 | 3.783 | 4.937 | 5.620 |
| lanes | 1000 / 1000 | 11.583 | 7.919 | 7.028 | 7.235 | 7.919 | 9.819 | 10.908 |

### Transport/Packet

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| build | 1000 / 1000 | 426.384 | 88.431 | 83.172 | 83.837 | 88.431 | 94.967 | 98.832 |

### mcp/directory

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| tools/list | 1000 / 1000 | 0.630000 | 0.602000 | 0.452000 | 0.468000 | 0.602000 | 0.851000 | 0.962000 |
| list_batches | 1000 / 1000 | 0.796000 | 0.653000 | 0.471000 | 0.522000 | 0.653000 | 0.859000 | 1.108 |
| list_letterboxes | 300 / 300 | 7.582 | 8.078 | 7.307 | 7.412 | 8.078 | 10.401 | 11.452 |
| list_applications | 200 / 200 | 402.767 | 90.083 | 88.008 | 88.165 | 90.083 | 94.776 | 104.199 |
| recommend_applications | 200 / 200 | 204.135 | 47.030 | 45.134 | 45.136 | 47.030 | 50.459 | 51.055 |
| score_distribution | 200 / 200 | 399.618 | 1.511 | 1.292 | 1.322 | 1.511 | 2.189 | 4.941 |
| heat_status | 1000 / 1000 | 6.317 | 3.975 | 3.653 | 3.695 | 3.975 | 4.610 | 4.849 |
| can_apply | 1000 / 1000 | 3.871 | 2.802 | 2.409 | 2.486 | 2.802 | 3.485 | 3.735 |
| gym_status | 1000 / 1000 | 4.820 | 4.218 | 3.801 | 3.898 | 4.218 | 4.802 | 5.279 |
| net_status | 1000 / 1000 | 1.406 | 1.390 | 1.240 | 1.267 | 1.390 | 1.697 | 2.070 |
| gym_log | 300 / 300 | 5.692 | 4.909 | 4.268 | 4.386 | 4.909 | 5.677 | 12.311 |
| gym_set_target | 300 / 300 | 5.649 | 4.858 | 4.415 | 4.444 | 4.858 | 6.242 | 10.860 |
| net_log | 300 / 300 | 1.720 | 1.753 | 1.596 | 1.606 | 1.753 | 3.281 | 5.823 |
| net_set_lane | 300 / 300 | 1.799 | 1.847 | 1.653 | 1.715 | 1.847 | 2.318 | 2.815 |

### mcp/letterbox

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| lease + tools/list | 15 / 15 | 4.212 | 4.102 | 3.677 | 3.677 | 4.102 | 15.662 | 15.662 |
| get_application | 500 / 500 | 3.071 | 2.550 | 2.214 | 2.263 | 2.550 | 3.099 | 9.608 |
| set_stage | 300 / 300 | 1.063 | 1.539 | 1.331 | 1.348 | 1.539 | 2.441 | 5.741 |
| set_next_action | 300 / 300 | 0.918000 | 1.085 | 0.874000 | 0.883000 | 1.085 | 1.550 | 1.776 |
| set_score | 300 / 300 | 0.946000 | 1.058 | 0.902000 | 0.921000 | 1.058 | 1.439 | 5.066 |

## Authenticated HTTP throughput

Successful requests per wall-clock second at the stated closed-loop concurrency. These are separate from reciprocal median latency.

| Route / interaction | Concurrency | Before req/s | After req/s |
|---|---:|---:|---:|
| HTTP/Desk / shell (concurrency 1) | 1 | 683.502 | 804.905 |
| HTTP/Desk / shell (concurrency 4) | 4 | 1538.602 | 2009.335 |
| HTTP/Desk / shell (concurrency 16) | 16 | 1835.152 | 3056.169 |
| HTTP/Packet / pack (concurrency 1) | 1 | 2.335 | 10.259 |
| HTTP/Packet / pack (concurrency 4) | 4 | 8.354 | 36.302 |
| HTTP/Packet / pack (concurrency 16) | 16 | 8.604 | 38.390 |
| HTTP/Desk / focus (concurrency 1) | 1 | 129.549 | 177.395 |
| HTTP/Desk / focus (concurrency 4) | 4 | 308.164 | 385.331 |
| HTTP/Desk / focus (concurrency 16) | 16 | 350.596 | 395.341 |
| HTTP/Desk / root (concurrency 1) | 1 | 440.826 | 401.302 |
| HTTP/Desk / root (concurrency 4) | 4 | 893.039 | 822.767 |
| HTTP/Desk / root (concurrency 16) | 16 | 916.633 | 828.484 |
| HTTP/Campaign / scoreboard (concurrency 1) | 1 | 417.562 | 374.761 |
| HTTP/Campaign / scoreboard (concurrency 4) | 4 | 747.644 | 875.828 |
| HTTP/Campaign / scoreboard (concurrency 16) | 16 | 630.805 | 854.642 |
| HTTP/Lanes / lanes (concurrency 1) | 1 | 76.658 | 96.783 |
| HTTP/Lanes / lanes (concurrency 4) | 4 | 194.916 | 166.530 |
| HTTP/Lanes / lanes (concurrency 16) | 16 | 203.007 | 139.961 |
| HTTP/Account / overview (concurrency 1) | 1 | 658.087 | 573.373 |
| HTTP/Account / overview (concurrency 4) | 4 | 1039.435 | 911.726 |
| HTTP/Account / overview (concurrency 16) | 16 | 857.997 | 813.025 |
| HTTP/MFA / summary (concurrency 1) | 1 | 767.875 | 799.948 |
| HTTP/MFA / summary (concurrency 4) | 4 | 1289.578 | 1461.955 |
| HTTP/MFA / summary (concurrency 16) | 16 | 1261.832 | 1363.444 |

## Regressions, variance and rejected changes

The table is not a selection of only winning rows.

- Durable Gym logging increased from approximately 0.365 to 0.422 ms for an existing problem and 0.449 to 0.569 ms for a new one. The retained `(account_id, done_on)` history index has a real write cost. Historical reads benefit; full MCP Gym log improved from approximately 5.7 to 4.9 ms. Do not describe the underlying insert as faster.
- API-key creation's main median increased from 0.551 to 0.824 ms. A fresh-fixture A/B/B/A follow-up produced baseline/final/final/baseline medians 0.490 / 0.448 / 0.834 / 0.938 ms. This shows substantial host/time variance, not a reliable whole-operation win. The main result remains unchanged in the table.
- HTTP lanes at concurrency 16 regressed in the main run (78.381 to 112.720 ms median). A/B/B/A follow-up medians were 105.338 / 85.846 / 104.667 / 97.588 ms: mixed at concurrency 16, while concurrency 1 and 4 improved in both orderings. There is no claim of universal concurrency/tail improvement.
- MCP leased writes and some unchanged root/account/security operations were slightly slower. Their raw rows remain in the report rather than being replaced by a favorable rerun.
- Rejected: consolidating Gym/Net/Campaign queries into conditional aggregates (fewer queries, slower execution); extra indexes without stable read gains; an employer upsert that reduced queries but worsened idempotent import mean latency by about 83%; a joined import pre-read that was about 5% slower; and a keyed per-card DOM morph that improved scroll but worsened movement/click medians by about 1.3 ms.
- A proposed stage index also changed the order of an otherwise unordered heat snapshot and failed parity; it was not retained.
- No durable-write guarantees, authentication revocation checks, MFA requirements, randomness quality or mail delivery semantics were weakened to obtain timing gains. No persistent authorization cache was introduced.
- Selection was based on removed work plus measurements and correctness checks, not an invented numerical posterior probability. Small wins and noisy unchanged paths should not be read as statistically established speedups.

## Correctness and compatibility evidence

- Production release built successfully. Compilation with warnings as errors and formatting checks passed.
- Strict Credo: 75 files, 67 checks, no issues. Full suite: **169 tests, zero failures**.
- ElixirLS was ready; the checked domain, security, web and task modules reported no diagnostics.
- Strict client type-check passed with TypeScript 7.0.2: `tsc --noEmit -p assets/tsconfig.json`.
- Literal keyword matching was compared with the previous regex behavior over **18,660 equivalence cases**.
- Public parity matched all seven fingerprints in each of three cohorts: canonical, Greenhouse/100 hot and Greenhouse/1,000 hot. Fingerprints cover packet bytes, representative focus/root JSON, scoreboard, lanes, score charts and batch decisions. This is equality on these fixtures, not a claim of exhaustive equivalence for all possible inputs.
- Query counts include asynchronous preload queries from all Repo processes. The legacy calling-process-only counter was corrected; the old undercounts were not silently presented as real reductions. Focus fell from 11 to 7 queries, JSON focus from 12 to 8, session authentication from 2 to 1, and score distribution from 2 to 1.
- Browser verification passed 20 same-job two-tab stage races and a shared-lineage update across Company 0 jobs 100/200; board glances, focused masks and server state agreed. No ordinal feed signal is dropped: signals held during a write are unioned into the required panel refreshes, including a focus reload when necessary.
- Independent visual smoke on the final release exercised signed-in search (Company 42, ten cards), selection, battleplan, Gym target change/restoration and Account navigation without console errors.
- A CDP virtual CTAP2 resident-key authenticator with user verification completed enrollment on the local final release: options and confirmation returned HTTP 200 and the named factor appeared. An expired fresh-auth window correctly returned 403 before a new legitimate synthetic session was minted. This is **virtual**, not physical hardware evidence.
- External OAuth providers, physical authenticators and actual SMTP/network delivery are not latency-benchmarked here. The mail action harness uses a test mail sink; identity-link rows use a synthetic proven identity claim. They do not measure an external provider ceremony.

## Reproduction and retained evidence

See [README performance testbed](../README.md#performance-testbed) and the scripts in [`bench/`](../bench/). Use separate disposable SQLite copies and immutable baseline/final releases. Never run these mutation harnesses against production or commit `testbed.json`: it contains synthetic authentication credentials.

- [`server-before.jsonl.gz`](../bench/results/server-before.jsonl.gz), [`server-after.jsonl.gz`](../bench/results/server-after.jsonl.gz): 128 rows each, raw samples, source revisions and measurement metadata. Includes domain, security, durable actions, HTTP, MCP and ATS scaling.
- [`server-steps.jsonl.gz`](../bench/results/server-steps.jsonl.gz): isolated backend step experiments, including rejected lane/index/import alternatives. These exploratory rows are not substitutes for the final paired tables.
- [`variance-checks.jsonl.gz`](../bench/results/variance-checks.jsonl.gz): adverse-result A/B/B/A checks; deliberately separate from the primary run.
- [`public-parity.jsonl`](../bench/results/public-parity.jsonl): public-output fingerprints for both releases across all three cohorts.
- [`query-counts.jsonl`](../bench/results/query-counts.jsonl): paired, all-process SQL query census, measured separately from latency.

The canonical fixture, local secrets and database files are not part of the committed evidence. Raw timings preserve failures/refusals as separate accounting where applicable; a refused action must not be counted as a fast successful action.

## Surgical application commits

Each entry is a separate commit; benchmark and documentation commits are omitted here. The two race fixes are correctness changes, not claimed independent speedups.

| Commit | Change / removed work |
|---|---|
| `79139b3` | Reuse company and ATS peer groups while decorating cards. |
| `30661e1` | Fetch the column kernel and first packet concurrently. |
| `366fa9b` | Classify employer sizes with precomputed word sets. |
| `bc7163d` | Load only heat inputs for hot-job snapshots. |
| `d07c874` | Reuse hot-peer role traits across board cards. |
| `dc08b44` | Join session and account authentication into one query. |
| `78952fe` | Join account validity into API-key lookup. |
| `3b6ff4a` | Check factor existence without loading MFA secrets. |
| `be471f7` | Batch unbiased cryptographic base62 sampling. |
| `c64ea4b` | Reuse the loaded problem after logging a Gym rep. |
| `4a15908` | Project only the scoreboard's required batch fields. |
| `a538d2c` | Match literal CV keywords without per-term regex compilation. |
| `1ff90fc` | Join focus associations and reuse the fetched job. |
| `1e6a3a7` | Index tenant Gym history in recent-read order; write-cost tradeoff disclosed above. |
| `de390af` | Aggregate score frequencies before loading chart data. |
| `4c762f4` | Query filtered score distributions without preparing cards. |
| `84d7641` | Use the score-count query in the MCP tool. |
| `95f538d` | Insert recovery-code hashes in one batch. |
| `bbd7e73` | Normalize department text once. |
| `361b1f1` | Encode each packet column as one binary; isolated encoder median 5.49 → 4.78 ms. |
| `9ea24b8` | Reuse inserted rows when opening applications, retaining returned database defaults. |
| `1d13608` | Match the canonical-URL partial-index predicate during import. |
| `cdd4661` | Union signals held during a write into its refresh, without discarding signals. |
| `82ce892` | Read only the panels a change can alter. |
| `8612fb7` | Allow one board read per kind in flight, with a trailing rerun; five-write burst packet reads 5 → 2. |
| `6faaa07` | Reload the root CV only while its lens is open. |
| `433624b` | Start scoreboard and lanes with the packet; removes a request dependency, not an isolated loopback win. |
| `34ebc5e` | Correctness: apply a write response only to its own card and supersede older focus reads. |
| `02ddac2` | Correctness: reload focused cards affected by their batch's open-fire change. |
| `8f95b48` | Skip DOM morphing when a slot's HTML has not changed. |
| `a2d7996` | Avoid setting an unchanged page title; no standalone latency claim. |
| `03cc17b` | Aggregate ATS decay loads once per board, with unknown-ATS fast path. |
