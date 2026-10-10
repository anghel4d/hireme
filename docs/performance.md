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

**All numbers in this section are local**: a scratch copy of the canonical 1,000-job fixture, loopback, Chromium 154, the same 5950X/WSL2 host. They are not production Internet latency; the release has not been deployed.

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

Not measured on the real network path yet: only the gate's handshake has been (`bench/gate.mjs`: QUIC RTT ~25–36 ms from the operator's workstation). The release builds byte-identically from any path (`nix build .#hireme .#hireme-gate --rebuild`), as does `kernel.wasm` (`native/kernel/build.sh --check`).

## Surgical lease-invalidation follow-up

The kernel now extends dirty-card IDs directly from the two lease-difference iterators instead of collecting two temporary vectors. The reproducible WASM shrank from 313,972 to 313,500 bytes. An isolated native allocator experiment preserved identical outputs across 40 cases: one-ID churn reduced allocation/reallocation calls from 3 to 1 and cumulative requested bytes from 48 to 16. This is not a universal byte reduction: replacing 16 leases with an already nonempty dirty list changed 8 to 5 calls but 428 to 496 requested bytes because of vector growth. No end-to-end latency gain is claimed for this edit. Verification: kernel rebuild reproduced, kernel fixtures and 40 seeded operation streams passed, a 200-operation Elixir oracle comparison had zero differences, and 184 ExUnit tests passed after integration with the concurrent wave changes.

## Session-revocation notification ordering

`Accounts.revoke_session/1` now persists `revoked_at` before publishing the account-change notification, matching the existing other-session revocation path. This prevents an observer from re-reading the still-active row on the only notification; command-time authentication checks are unchanged. The 10 account tests passed, and a disposable local PubSub smoke observed 20 revocations: the first change notification saw the revoked timestamp, no active-list row, and a rejected token. No latency gain or authorization-bypass claim is made.

## Wave 4: block leases and the group-commit sequencer — 2026-10-10 (main `e5d19a3`; the writers' lock at `efe6d1c`, the WAL fold at `f863959`; not deployed)

An agent leases a block of its account's entries on one session (`lease {"count": 16}`), and the sequencer seals writes in groups: a session keeps its ops in flight, the drainer commits a batch in one transaction and answers as it seals, the WAL is folded past a 4,096-frame trigger (a trigger, not a cap: transients reached ~10.6k frames), and nothing of the op ledger lives in memory (a resend is caught by the ledger's unique key and answered from the table). Measured locally on a copy of the canonical 1,000-job fixture with `bench/letterbox.mjs`: ten agents with sixteen entries each write `set_score` across their blocks for ten seconds, agent 0 is killed halfway and a spare asks for its block; hireme-mcp over the gate's WebTransport and over `/wire`; the testbed on CPUs 0–15, the agents on 16–31; one run per cell on a quiet box (1-minute load 0.5–2.2; the WS 4-in-flight cell was run three times and its median is shown, with the WS 1-in-flight control at 3,192–3,406 across runs). Before is `c65a37b` (block leases on the old sequencer), taken at a 1-minute load of ~3 in an earlier session; after is `e5d19a3`. The before → after pairs are not interleaved: sessions and load regimes apart.

| | WS, 1 in flight | WS, 4 in flight | WT, 1 in flight | WT, 4 in flight |
|---|---|---|---|---|
| writes/s, before → after | 1,881 → 3,406 | 1,637 → 3,477 (three runs: 3,030 / 3,477 / 3,628; the median) | 1,495 → 3,647 | 1,506 → 5,772 |
| write p50 ms | 4.79 → 2.59 | 21.73 → 10.25 | 5.66 → 2.37 | 24.30 → 5.87 |
| write p99 ms | 8.32 → 6.85 | 42.14 → 24.24 | 13.39 → 10.41 | 35.38 → 18.31 |
| refusals | 0 | 0 | 0 | 0 |
| dead agent's block back to the spare | 20 → 18 ms | 24 → 33 ms | 2.0 s | 2.0 s (the gate's dead-session detection) |
| ten leases asked at once, p50 / wall ms | 28 / 31 → 27 / 31 | 21 / 28 → 17 / 20 | 14 / 24 → 18 / 22 | 25 / 28 → 18 / 27 |

Single-write guard, one agent on one application, `set_score` p50 / p99: WS 1.21 / 1.85 → 1.05 / 1.32 ms; WT 1.57 / 8.61 → 1.26 / 1.55 ms. In process, `Ops.run`: `next` 0.235 → 0.177 ms with an 80-byte delta, `score` 0.191 ms, a stage move flipping heat 0.595 ms (5.5 ms in the realtime rework). The WAL after a ten-second run is 58–67 MB and steady run over run; before the trigger it was 386 MB after one run and still growing. That is the short-reader workload. A reader held open for 1 s / 3 s while two accounts keep committing pins the WAL to 130–137 / 354–411 MB; the writers kept committing during the hold (p99 ≤ 1.1 ms, zero errors, which is not proof of no effect) and pay worst writes of 14–24 / 43–96 ms within the second after its release: a background PASSIVE checkpoint catches up first (110–294 ms, writes continuing), then a lock-held PASSIVE (8–55 ms) and the commit that rewinds the log and resets the file to 64 MiB (34–40 ms) together make those worst writes (perfchan's held-reader probe on `f863959`, eight matched cases; observed decomposition, no syscall trace). No hard bound is claimed.

Sequencer cold start against a retained op ledger (`Ops.stop`, then the first write; ten restarts per cell, fresh fixture copy): reading the ledger whole into memory on the first write cost 25 / 155 ms at 1,000 / 100,000 retained rows, and the warm write right after 0.5 / 41 ms. Now the first write is 22 / 22 / 21 ms at 1,000 / 100,000 / 1,000,000 rows, the writes after it 0.2 ms, one ledger row is read per client op, and the sequencer is 3.9 MB after GC at every size.

Writers after that (`3305bee`, `efe6d1c`, `f863959`): the hourly ledger sweep deletes a thousand rows per short commit with a 10 ms pause, so a million expired rows clear in 12 s quiet and 19–30 s under load instead of one statement of about a second; and every write in `lib/` takes one FIFO lock in `Hireme.Store` and begins IMMEDIATE, so two busy sequencers and a writer outside them take turns instead of busy-waiting on SQLite's one writer lock (strongly supported, inferred: the native sleeps are not instrumented). Direct writers from a third account while two accounts saturate the sequencer, p50 / p99 / max ms, before → after: `ApiKeys.create` 0.52 / 54.6 / 280.1 → 0.97 / 1.66 / 4.03; `Audit.record` 0.15 / 79.3 / 630.3 → 0.56 / 2.18 / 3.44 (with the WAL fold below, 0.93 / 3.32 / 7.30 and 1.00 / 2.52 / 6.37: about twice the tail, still single-digit ms); in perfchan's matched windows an innocent account's worst wait 430–882 → 8–32 ms and p99.9 33.8–79.1 → 1.75–2.09 ms, the medians roughly doubled (a turn is waited, not raced). The sequencer path is unchanged in the same session: the guard WS 1.05 / 1.92 against 1.15 / 2.25 and WT 1.20 / 2.51 against 1.21 / 2.50, in-process `next` 0.181 ms, cold start at a million rows 21 ms. The saturation curve on `486fcf8` (depths 1, 4, 16 and 64 in one session, zero refusals, WAL 22 MB throughout): WT plateaus at ~6–7k writes/s by depth 4 (6,061 at 5.6 ms p50) and deeper only adds latency; WS sits at ~3.3k at depths 1–4 and reaches 5.4k only at depth 64 with a 112 ms p50, so at low depth the WS carrier, not the sequencer, is the bound; with Nagle off on the agent's socket (`ac40f42`) the depth-4 cell gained 7–16% rate and 10–12% p50 in every same-bed pairing against the old client (null at depth 1; the old client itself spread 3,264–3,763 between beds; no tail or packet-count claim). The two-account aggregate in perfchan's windows read 4,506–4,603 writes/s on `3305bee`, 4,042–4,362 on `efe6d1c` and 4,585–4,754 on `f863959`, from different sessions: the dip reads as session variance, and no rate claim is made either way. Scope: fairness holds among the writers that take the Store lock, in this VM (every writer in `lib/` since `efe6d1c`: sessions, keys, MFA, audit, mail, imports); raw Repo bypasses such as migrations and tests are excepted, and another VM on the same file contends at SQLite's lock with correctness kept but not order or fairness. The WAL is then folded by the lock's holder every 100 ms (`f863959`): in the same windows it reaches 29 MB before the quiescent reset instead of 2.2–2.7 GB, the first write after quiescence costs 1.4–1.8 ms instead of 250–300, the file after a guard run is 18 MB instead of 29, and the sequencer's guard does not move in the same session (WS 1.04 / 2.34 against 1.07 / 2.29, WT 1.21 / 2.55 against 1.20 / 2.42; in-process `next` 0.179 ms); the fold's visible cost in those windows is at p99.9, 1.75–2.09 → 3.78–3.92 ms, with p99 unchanged at ~1.3–1.45 (33.8–79.1 at p99.9 before the lock).

Correctness evidence: the sequencer's batch property (boot ⊕ deltas equals a fresh read across seeded op streams; a resend is answered from the ledger and writes nothing; two copies of one op id in a batch run once) and `native/kernel/parity.mjs` against the oracle (zero differences on three seeds after the server-side heat snapshot left) held throughout. Net change to the tree over the wave: hireme -50 lines (23 of them this section), nixos-server 0.

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

## Server, domain and security latency

Unchanged paths and regressions are included.

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

### Domain/Corpus

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| list_items | 1000 / 1000 | 0.250618 | 0.272048 | 0.226737 | 0.233328 | 0.272048 | 0.397716 | 0.458236 |

### Domain/Heat

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| can_apply | 1000 / 1000 | 3.041 | 1.962 | 1.823 | 1.838 | 1.962 | 3.140 | 3.228 |
| mix_batch_100 | 1000 / 1000 | 43.717 | 38.268 | 36.810 | 36.996 | 38.268 | 51.621 | 54.436 |

### Domain/Kv

| Interaction / cohort | n before / after | beforems | afterms | current p0.1 | p1 | p50 | p99 | p99.9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| list | 1000 / 1000 | 0.040240 | 0.039829 | 0.034720 | 0.036169 | 0.039829 | 0.196058 | 0.434616 |

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

## Regressions, variance and rejected changes

The table is not a selection of only winning rows.

- API-key creation's main median increased from 0.551 to 0.824 ms. A fresh-fixture A/B/B/A follow-up produced baseline/final/final/baseline medians 0.490 / 0.448 / 0.834 / 0.938 ms. This shows substantial host/time variance, not a reliable whole-operation win. The main result remains unchanged in the table.
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
- Browser verification passed 20 same-job two-tab stage races and a shared-lineage update across Company 0 jobs 100/200; board glances, focused masks and server state agreed. No ordinal feed signal is dropped: signals held during a write are unioned into the required panel refreshes, including a focus reload when necessary.
- Independent visual smoke on the final release exercised signed-in search (Company 42, ten cards), selection, battleplan, Gym target change/restoration and Account navigation without console errors.
- A CDP virtual CTAP2 resident-key authenticator with user verification completed enrollment on the local final release: options and confirmation returned HTTP 200 and the named factor appeared. An expired fresh-auth window correctly returned 403 before a new legitimate synthetic session was minted. This is **virtual**, not physical hardware evidence.
- External OAuth providers, physical authenticators and actual SMTP/network delivery are not latency-benchmarked here. The mail action harness uses a test mail sink; identity-link rows use a synthetic proven identity claim. They do not measure an external provider ceremony.

## Reproduction and retained evidence

See [README performance testbed](../README.md#performance-testbed) and the scripts in [`bench/`](../bench/). Use separate disposable SQLite copies and immutable baseline/final releases. Never run these mutation harnesses against production or commit `testbed.json`: it contains synthetic authentication credentials.

- [`server-before.jsonl.gz`](../bench/results/server-before.jsonl.gz), [`server-after.jsonl.gz`](../bench/results/server-after.jsonl.gz): 128 rows each, raw samples, source revisions and measurement metadata. Includes domain, security, durable actions, HTTP, MCP and ATS scaling.
- [`server-steps.jsonl.gz`](../bench/results/server-steps.jsonl.gz): isolated backend step experiments, including rejected lane/index/import alternatives. These exploratory rows are not substitutes for the final paired tables.
- [`variance-checks.jsonl.gz`](../bench/results/variance-checks.jsonl.gz): adverse-result A/B/B/A checks; deliberately separate from the primary run.

The canonical fixture, local secrets and database files are not part of the committed evidence. Raw timings preserve failures/refusals as separate accounting where applicable; a refused action must not be counted as a fast successful action.
