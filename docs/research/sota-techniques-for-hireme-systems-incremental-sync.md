# SOTA data-systems and PL techniques for hireme's client-resident architecture: incremental computation, local-first sync, columnar encoding, WebAssembly, rule analysis

## 1. Incremental view maintenance and incremental computation: what fits a single-tenant in-browser Wasm kernel of ~50k rows, and what would Z-set deltas or fine-grained dependency tracking cost and gain?

### Takeaway
None of the IVM engines should be imported. Feldera's `dbsp` runtime, differential dataflow/Materialize, Turso's IVM and Salsa are all either server runtimes or heavy `std` dependencies. The ideas are worth taking, though, and hireme already holds most of the prerequisites:
- per-row revisions;
- a `Moved` delta per write;
- fixed-point heat loads, whose group totals are exact in any order.

The best gain per line is in two places. First, keep CV picks per application instead of dropping all of them on any application write (Salsa-style durability and early cutoff, written by hand). Second, maintain the board as Z-set deltas with group-local updates and an order index, so a one-row write costs O(k log n) instead of O(n).

### Cited Findings
**Baseline read from hireme's code (read-only)**
- `Kernel::moved` invalidates by table, not by row:
  - it clears the per-application CV-part cache (`cvs`) when `items`, `cv_overlays`, `cv_lineages`, `cv_roots` or `me` move;
  - it drops every CV pick when any of `applications`, `places`, `corporations`, `cv_rules`, `cv_masks`, `cv_roots`, `me` or `languages` moves;
  - it then marks the board stale.
  — [native/kernel/src/abi.rs lines 154-170](../../native/kernel/src/abi.rs)
- `Picks::of` recomputes every application's pick against every rule. `pick()` evaluates all enabled arms per application, not first-match-only, because `also` lists every other matching arm. So one rebuild costs about (applications × arms) mask evaluations. Each time the cache is dropped, the next `pick(id)` or `cv_query` rebuilds it — [native/kernel/src/pick.rs lines 96-104, 312-321](../../native/kernel/src/pick.rs); [abi.rs `pick`, `application`](../../native/kernel/src/abi.rs)
- `Board::derive` keeps a per-row `Cached` seat and suggestion, recomputed only for moved rows. Each derive still does O(n) work:
  - it rebuilds every `Card`;
  - it rebuilds the heat governor index;
  - it computes `heat::verdict` for every card;
  - it re-keys every card with a u128 order key and re-sorts. The sort is adaptive, since the input is laid out in the last order.
  - The whole per-row cache is cleared when `settings`, `me`, `places` or `corporations` move.

  — [native/kernel/src/board.rs lines 423-453, 541-597](../../native/kernel/src/board.rs)
- Heat loads are already fixed point (2^-44 units) "so a group's total is an exact integer sum: the same in any order, and a member's own share comes out of it exactly". Decay is `weight · 0.5^(days / half_life)`, so loads change when the day changes — [native/kernel/src/heat.rs lines 1-30, 451-460](../../native/kernel/src/heat.rs)
- Every stored table carries a row revision column (`REV = 3`), and every frame or prediction returns `Moved`, the per-table written and deleted ids — [native/kernel/src/rows.rs lines 49-50, 565-588](../../native/kernel/src/rows.rs)
- The kernel benchmark's bounds at 10k applications: a derive after a change in ≤ 8 ms, the first derive after BOOT in ≤ 30 ms, and query p99 ≤ 1 ms over 50k places — [bench/kernel.mjs header](../../bench/kernel.mjs)

**DBSP / Feldera**
- DBSP: Automatic Incremental View Maintenance for Rich Query Languages.
  - Authors: Budiu, Chajed, McSherry, Ryzhyk, Tannen. PVLDB 16(7):1601–1614, 2023; arXiv:2203.16684; one of two VLDB 2023 Best Research Papers.
  - It gives a general algorithm that incrementalizes any DBSP program, and SQL and Datalog both compile to DBSP.

  — [VLDB PDF](https://www.vldb.org/pvldb/vol16/p1601-budiu.pdf); [arXiv](https://arxiv.org/abs/2203.16684v1); [VMware Research award note](https://research.vmware.com/announcements/vrg-paper-wins-a-vldb-23-best-research-paper-award)
- Core algebra:
  - A Z-set is a finite-support map from rows to integer weights; negative weights are deletions.
  - The incremental version of an operator is Q^Δ = D ∘ Q ∘ I.
  - "For an LTI operator Q we have Q^Δ = Q": linear operators such as filter, map and projection are their own incremental versions.
  - Incremental join is (a×b)^Δ = a×b + z⁻¹(I(a))×b + a×z⁻¹(I(b)). It needs the integrated inputs as state, "an amount of data proportional to the size of the relations".
  - Distinct is non-linear and "does have an important cost in terms of memory".

  — [DBSP paper (ar5iv HTML)](https://ar5iv.labs.arxiv.org/html/2203.16684)
- Cost claim: "the work performed by each operator for each new input is proportional to the size of change". Optimized linear operators run in O(C[t]) for change size C[t], and the claim assumes C[t] ≪ R[t]. Without optimization, the time complexity equals the non-incremental operator's — [DBSP paper (ar5iv HTML)](https://ar5iv.labs.arxiv.org/html/2203.16684)
- The `dbsp` crate (Feldera's runtime) is 0.367.0 (2026-10-18), with 12.3 MB of source.
  - It depends on tokio, rkyv, crossbeam, libc, nix, core_affinity, tempfile, zip and the C-binding zstd crate, plus internal feldera-storage and feldera-types crates.
  - docs.rs builds it for x86_64-unknown-linux-gnu only, and nothing indicates wasm32 support.

  — [docs.rs dbsp](https://docs.rs/crate/dbsp/latest)
- Turso (the Rust SQLite rewrite) shipped experimental "Live Materialized Views" on DBSP (blog of 2025-10-09).
  - Operators: join, filter, aggregate (SUM, COUNT, AVG, MIN, MAX) and merge (UNION). No recursive CTEs or CTEs.
  - The post gives no benchmarks and calls the on-disk format unstable.

  — [Turso blog](https://turso.tech/blog/introducing-real-time-data-with-materialized-views-in-turso)

**Differential dataflow (seminal)**
- Differential dataflow (McSherry, Murray, Isaacs, Isard; CIDR 2013) generalizes incremental computation to nested iteration. It tells apart the reasons a collection changes so earlier results can be reused. It was built on Naiad — [Microsoft Research](https://www.microsoft.com/en-us/research/publication/differential-dataflow/)

**Demand-driven memoization: Salsa, Adapton, self-adjusting computation**
- Salsa (Rust):
  - A single revision counter increases on every input set. A tracked function stores its value plus its dependencies and the revisions at which they last changed; on a later call it re-executes only if a dependency changed.
  - "Backdating": if a re-executed function returns an equal value, "we can backdate the result, meaning that we say that, even though the inputs changed, the output didn't". This is early cutoff.
  - "Durability": each input gets a durability level. A function that depends only on high-durability inputs is validated without walking its edges when only low-durability inputs changed.

  — [Salsa book: algorithm](https://salsa-rs.github.io/salsa/reference/algorithm.html)
- Salsa is at 0.28.x. A Fedora advisory dated 2026-09-30 moved it to 0.28.5 to fix a use-after-free (GHSA-xc3w-55vh-cw3w) — [docs.rs salsa 0.28](https://docs.rs/salsa/=0.28.0/); [Fedora advisory](https://linuxsecurity.com/advisories/fedora/rust-salsa-fedora-44-2026-407b957a3b)
- Salsa powers rust-analyzer, ty (Astral's Python type checker) and Cairo (secondary listing) — [tessl skill registry summary](https://tessl.io/registry/skills/github/joshuadavidthomas/agent-skills/salsa)
- An older snapshot of Astral's playground README says Salsa's cycle handling relied on `catch_unwind`, which `wasm32-unknown-unknown` lacked at the time, so the Wasm playground crashed on cycles. The page carries strikethroughs and its current status is unclear — [ruff playground README snapshot](https://git.joshthomas.dev/language-servers/ruff/src/commit/f888e51a34602a411e645e6cb1569fa69eaead74/playground/README.md)
- Adapton: Composable, Demand-Driven Incremental Computation (Hammer, Phang, Hicks, Foster; PLDI 2014; DOI 10.1145/2594291.2594324).
  - A "demanded computation graph" recomputes only outputs an observer still demands.
  - Reported speedups often beat earlier incremental approaches.
  - A Rust implementation is "the latest and fastest".

  — [UMD record](https://drum.lib.umd.edu/handle/1903/14708); [PLDI PDF](https://people.mpi-sws.org/~hammer/adapton-pldi2014.pdf); [Adapton page](https://cs.umd.edu/~hammer/adapton); [docs.rs adapton 0.3](https://docs.rs/adapton/^0.3)
- Self-adjusting computation records a dynamic dependence graph and re-executes only affected parts. Memoization finds the unaffected parts (An experimental analysis of self-adjusting computation; Acar, Blelloch, Blume, Harper, Tangwongsan; DOI 10.1145/1596527.1596530) — [Google Research listing](https://research.google/pubs/an-experimental-analysis-of-self-adjusting-computation)

**Reactive relational state in local-first apps**
- Riffle: Reactive Relational State for Local-First Applications (Litt, Schiefer, Schickling, Jackson; UIST 2023; DOI 10.1145/3586183.3606801) keeps all app state, domain and UI, in a client-side relational database with reactive queries — [MIT DSpace](https://dspace.mit.edu/handle/1721.1/152980)
- The Riffle prototype re-ran affected queries from scratch, which "usually be fast enough". IVM was future work.
  - In-browser Wasm SQLite: "most queries with a few joins over a few tens of thousands of rows complete in less than a millisecond".
  - Data loaded in under 1 ms, but "the browser takes hundreds of milliseconds to compute the CSS styles and layout".
  - React needed several render passes per update, which added latency.

  — [Riffle essay](https://riffle.systems/essays/prelude/)

### Inferences
- **Fit.** The DBSP algebra fits hireme's derivations closely, but its runtime does not fit. The board is:
  - filter and map, which are linear and so already incremental;
  - group-by sums of heat loads per company, vendor, tenant and batch, which are linear;
  - a per-card verdict against its groups' totals, a keyed join;
  - an ordering, a top-k/sort.

  A one-application write moves at most four groups. Only the cards in those groups need a new verdict and a new place in the order. Pulling in the `dbsp` crate is out: its dependencies (tokio, nix, libc, core_affinity, tempfile, C zstd) are hostile to wasm32 and its source is huge. The pattern should be written by hand inside `board.rs`.
- **Determinism risk already solved.** The usual objection to incremental aggregates is that floating-point drift breaks bitwise parity between server and client. The two kernels see different delta sequences, because the client also predicts and rolls back. `heat.rs` already keeps loads as fixed-point u64 whose group totals are "the same in any order". So +delta/−delta maintenance of group totals is exact and order-independent. Decay still moves every load when the day changes, so a day-changing TICK should take the existing full derive (once a day).
- **Concrete design for the board.** All of this lives in `board.rs` and `heat.rs`.
  - Keep `group → (fixed-point total, member ids)`. On `Moved`, subtract each moved card's old contribution and add its new one.
  - Recompute verdicts only for members of touched groups.
  - Keep `BTreeSet<(u128 order_key, id)>` and remove and reinsert only the cards whose key changed.
  - `view(filter)` then walks the ordered set.

  Expected effect: the `derive_after_patch_ms` path goes from O(n) to O(k log n), with k the members of the touched groups, typically tens. That is an estimate; measure it with `bench/kernel.mjs`.

  Cost:
  - the from-scratch `derive` stays for BOOT, resync and day change;
  - a property test "incremental board = fresh derive" joins the existing "base ⊕ deltas = fresh read" style;
  - roughly +120/−60 lines.

  So it is not net-zero unless the old `cache.clear()` paths and their special cases are deleted.
- **Cheapest win: picks.** CV picks are rebuilt for all applications × all arms after any application write. This is probably on the focus lens's write path: `application(id)` calls `pick(id)`, which calls `Picks::of`. Salsa's ideas apply directly, without the crate:
  - **Durability.** Rules, masks, roots, `me` and languages are a "high-durability" epoch, and applications are low durability.
  - **Per-row memo.** Key each application's pick by the revs of the rows it reads (its own row, its corporation row, its place row) plus the rules epoch.
  - **Early cutoff.** If a recomputed pick equals the old one, downstream documents stay valid.

  Changes are in `abi.rs` `moved()` and `pick.rs`: about +15/−10 lines, near net-zero. Dropping the whole map on any application move becomes "drop only the moved ids".
- **Salsa as a dependency is not recommended.**
  - It needs `std`, generates code through macros (Wasm size unknown), and has unsafe internals (the 0.28.5 use-after-free).
  - Its wasm32 history (`catch_unwind`) is a risk.
  - Its value is the generic dependency graph, which hireme does not need: there are about five derived documents, and their dependencies are known statically.
- **Adapton and self-adjusting computation.** These are the theory behind "recompute only what is demanded". hireme's lazy `derive()`-on-read already gives the demand-driven half. Fine-grained DDG tracking at the memory-cell level would cost more bookkeeping than the 50k-row tables justify.
- **Measure before building IVM.** Riffle found that queries over tens of thousands of rows took well under 1 ms in Wasm, while style, layout and framework passes dominated. Before an incremental board, the 4–6 ms medians should be split into judge, predict, derive, template and morph shares. The CDP harness under the scratchpad `rt/` folder from the round-trip audit, plus `bench/kernel.mjs`, already measures most of this.

### Gaps
- No public benchmark measures DBSP-style IVM inside a WebAssembly kernel. Feldera publishes no wasm build. Turso's IVM post has no numbers, and I found no confirmation that its IVM runs in the browser.
- I did not measure how much of hireme's 4–6 ms stage-write median is `Board::derive` or `Picks::of`. That needs a profile on the operator's node.
- Salsa's per-query memory and time overhead, and its wasm32 size cost, are not documented in the sources found.
- Materialize was not researched beyond its lineage from differential dataflow. No source was fetched on its licensing or embeddability.

## 2. Fine-grained reactivity (signals, TC39 Signals, reactive-programming research) versus whole-view re-render plus DOM morphing: evidence on update cost

### Takeaway
Keep morph, add rev-keyed skipping. Whole-view morph has a cost floor that grows with view size even when nothing changed. hireme already avoids it on the hottest path: board cards are written value by value, and the morph is skipped when the markup string is unchanged.

Adopting a signals runtime is not justified:
- TC39 Signals is still at Stage 1;
- a runtime would add a second state model next to `state.ts`.

The cheap, proven middle ground is Elm-`Html.Lazy`-style skipping keyed by the kernel's row revisions. Unchanged subtrees are then neither re-templated nor re-walked.

### Cited Findings
**Baseline read from hireme's code**
- `render()` rebuilds the whole shell's markup string on every model change and skips `morph` when it equals the last drawn string — [assets/js/app.ts lines 125-160](../../assets/js/app.ts)
- `morph` matches `data-key` children across the parent. A subtree marked `data-morph="own"` is left alone after it first lands, and its owner writes it value by value. Focus, caret and selection are preserved — [assets/js/morph.ts header](../../assets/js/morph.ts)
- Every lens is "model in, HTML out, morphed keyed, except the board's cards, written value by value" — [docs/rebuild.md, Web](../rebuild.md)

**Signals**
- The TC39 Signals proposal lists "Stage 1". It describes a "push-pull" construction:
  - computed signals are lazy and memoized;
  - pull evaluation is glitch-free;
  - a Watcher's `notify` runs synchronously inside `.set()` and cannot read or write signals.

  A polyfill exists. Before Stage 2 the team wants several production-grade polyfills and framework integrations.

  — [tc39/proposal-signals](https://github.com/tc39/proposal-signals)
- alien-signals, a push-pull signal library, says it is noticeably faster than Vue 3.4's reactivity, which the same author also wrote. It points to js-reactivity-benchmark for comparisons. These are author claims — [npm alien-signals](https://npmjs.com/package/alien-signals)

**Morph cost**
- morphdom's own benchmark (Chrome 72, 2019 hardware), in ms per iteration:

  | test | morphdom | virtual-dom |
  |---|---|---|
  | "equal" (no change at all) | 0.50 | 0.02 |
  | "large" | 2.88 | 0.35 |
  | "data-table2" | 2.72 | 0.84 |
  | small tests | competitive or faster | |

  The README notes "the larger the diff needed to evaluate, the more vdom will perform better".

  — [morphdom README](https://github.com/patrick-steele-idem/morphdom)
- Elm's `Html.Lazy` skips building and diffing a subtree when its arguments are unchanged:
  - primitives compare structurally;
  - records and lists compare by reference.

  — [Elm guide: lazy](https://guide.elm-lang.org/optimization/lazy)
- Practitioners call `Html.Lazy` fragile in large codebases: new records or `Maybe.map` defeat the reference check — [Elm Discourse](https://discourse.elm-lang.org/t/can-the-compiler-skip-virtual-dom/6300/)
- Riffle saw style and layout computation take "hundreds of milliseconds" while data loaded in under 1 ms — [Riffle essay](https://riffle.systems/essays/prelude/)

### Inferences
- The kernel already knows exactly which rows moved (`Moved`) and each row's `rev`. That beats a generic signals graph, which would have to rediscover dependencies at run time.
- **Recommended design.**
  - Templates emit `data-rev="<row rev>"` (or a hash of the inputs) on keyed nodes.
  - `morph` skips a keyed child whose `data-key` and `data-rev` both match.
  - Lenses keep a small per-key cache of the last `Html` fragment, so unchanged rows are not re-templated.

  This avoids Elm's reference-equality fragility, because revs are integers the kernel guarantees. Expected cost: about +25–40 lines in `morph.ts` and a lens or two, with no new dependency. Expected effect: template and morph cost on the world, outreach and atlas grids scales with changed rows instead of shown rows. This is an inference; the morphdom numbers show the floor that would go away.
- Full fine-grained reactivity (Solid-style signals, or the TC39 polyfill) would reverse "No framework" and "state.ts holds the model, the one shared state". It would add code against a net-zero-lines rule. Its main benefit, skipping work on unchanged values, is mostly captured by rev-keyed skipping plus the board's existing value-by-value writer. Anti-candidate for now.
- As Riffle found, layout and style can dominate after a morph. A morph that rewrites many nodes, for example re-ranking without keys, triggers style recalculation. Keeping `data-key` on every row-shaped element matters more than the diff algorithm.

### Gaps
- I found no current js-framework-benchmark figures for morphdom or idiomorph next to Solid or vanilla, and no controlled study of signals versus morph on update cost. The morphdom numbers are from 2019 (Chrome 72).
- I did not profile how much of hireme's 4–6 ms medians is template string building plus morph, versus kernel work.

## 3. Local-first replication and CRDT advances, and the theory of optimistic replication with an authoritative server: is anything better than hireme's sequencer-plus-rollback for one operator plus agents, especially offline or multi-device?

### Takeaway
hireme's model is already the state of the art for a central server with business-rule validation. It is the same server reconciliation that Replicache, Zero and Weidner's taxonomy recommend. Two theoretical results back the sequencer:
- CRDTs and OT are "merely optimizations over server reconciliation" in centralized systems (Weidner);
- invariants such as heat caps, leases, FIRE HOLD and `human_only` are not invariant-confluent, so they need coordination (Bailis et al.).

The real gaps are offline durability and better merges:
- pending ops are not persisted;
- a few writes would merge better as intent-level commands;
- text edited by the operator and an agent at once could merge (Eg-walker style) instead of being refused with `rev`.

### Cited Findings
**Baseline read from hireme's code**
- Rows are "base ⊕ pending":
  - pending writes record what they replaced;
  - on BOOT or PATCH they are undone, the frame applied, and the writes reapplied;
  - ACK drops an op;
  - NACK undoes all pending writes, drops that op, and reapplies the rest.

  — [native/kernel/src/rows.rs header](../../native/kernel/src/rows.rs)
- Pending ops live in an in-memory `Map` in `kernel.ts`. The IndexedDB snapshot is not written while any op is pending (`pending.size > 0`), so unacknowledged writes do not survive a reload — [assets/js/kernel.ts lines 503-546](../../assets/js/kernel.ts)
- A refused stale write tells the operator: "Someone changed this before your edit landed, so your edit was undone." — [assets/js/kernel.ts `SAID.rev`](../../assets/js/kernel.ts)

**Architectures and theory**
- Weidner, "Architectures for Central Server Collaboration" (2024-06-04):
  - Server reconciliation means clients "undo pending operations, apply the remote update, then redo" them. It is "the most flexible way to implement optimistic local updates, since it works for arbitrary operations and business logic", used in multiplayer games "since the 1990s" and by Replicache.
  - In centralized systems CRDT and OT are "merely optimizations over server reconciliation".
  - OT needs transformation functions whose number of cases grows as O((# op types)²), and the server does "O(# active users) transformations per operation".
  - Downsides of reconciliation: undo/redo "does increase the cost of remote updates", and it needs undoable local state.
  - High-level "mutations" give "maximum control over the behavior of server-side rebasing"; low-level state changes hide intent.

  — [mattweidner.com](https://mattweidner.com/2024/06/04/server-architectures.html)
- Replicache:
  - pending mutations are "persisted in case the tab closes before it can be pushed";
  - each carries a per-client sequential id;
  - the server keeps a `lastMutationID` per client, and the client discards pending mutations at or below it;
  - on pull the client "rewinds the state of the Client View to the last version it got from the server", applies the patch and replays pending mutations;
  - mutators re-run on the server and may take a different path there.

  — [Replicache: how it works](https://doc.replicache.dev/concepts/how-it-works)
- Zero (Rocicorp) is "server-authoritative": the server mutator wins, the client result is speculative, and mutators may run more than once, so IDs must not be generated inside them — [Zero custom mutators](https://zero.rocicorp.dev/docs/custom-mutators)
- Coordination Avoidance in Database Systems (Bailis, Fekete, Franklin, Ghodsi, Hellerstein, Stoica; PVLDB 8(3):185–196, 2015; arXiv:1402.2237): "invariant confluence" is a necessary and sufficient condition for safe coordination-free execution. Their prototype showed a 25× TPC-C New-Order improvement on 200 servers — [arXiv](https://arxiv.org/abs/1402.2237v1)

**CRDT and text-merge advances**
- Collaborative Text Editing with Eg-walker: Better, Faster, Smaller (Gentle, Kleppmann; EuroSys 2025; arXiv:2409.14252; DOI 10.1145/3689031.3696076):
  - an order of magnitude less steady-state memory than existing CRDTs;
  - loading from disk "orders of magnitude faster";
  - merging long-running branches orders of magnitude faster than OT;
  - worst-case merges comparable to CRDTs.

  — [arXiv](https://arxiv.org/abs/2409.14252)
- diamond-types, the author's Rust implementation, is ISC-licensed and ships WASM npm builds. It describes itself as WIP, and its crates.io package is "quite out of date" — [GitHub](https://github.com/josephg/diamond-types)
- The Art of the Fugue: Minimizing Interleaving in Collaborative Text Editing (Weidner, Kleppmann; IEEE TPDS 36(11):2425–2437, 2025; arXiv:2305.00583) defines maximal non-interleaving. FugueMax is proven to satisfy it, and performance is comparable to state-of-the-art CRDT libraries — [arXiv](https://arxiv.org/pdf/2305.00583)
- A TU Darmstadt bachelor thesis reports interleaving with deletions (unverified) — [TUprints](https://tuprints.ulb.tu-darmstadt.de/27834/1/Bachelor_Thesis_Optimizing_Collaborative_Plain_Text_Editing_Algorithms.pdf)
- Automerge 3.0:
  - memory cut "by over 10x, sometimes dramatically more", by keeping the compressed columnar format in memory (100× in some cases) with faster loads;
  - the old Text class was removed.

  — [Automerge 3 blog](https://automerge.org/blog/automerge-3/); [Ink & Switch dispatch 011](https://inkandswitch.com/newsletter/dispatch-011); [migration guide](https://automerge.org/docs/guides/migrating-from-automerge-2-to-automerge-3/)
- Loro 1.0 (October 2024; npm now 1.5.4), vendor benchmarks:
  - a new storage format gives 10× faster loading;
  - a document with millions of ops loads in 1 ms instead of 16 ms, or 0.37 ms as a shallow snapshot;
  - text is Fugue-based, with a movable tree.

  — [Loro 1.0 blog](https://loro.dev/blog/v1.0); [npm loro-crdt](https://npmjs.com/package/loro-crdt)

**Bootstrapping strategies**
- Linear (secondary source) gives each model a load strategy:
  - `instant` at bootstrap;
  - `lazy` on first demand;
  - `partial` per query;
  - `local`, IndexedDB only.

  Comments and history are kept out of the instant bootstrap to shrink cold load.

  — [performance.dev on Linear](https://performance.dev/what-makes-linear-feel-instant); official talk: [Scaling the Linear Sync Engine](https://linear.app/now/scaling-the-linear-sync-engine)

### Inferences
- **Nothing beats the current core model.** hireme's design matches Weidner's preferred cell (mutations, server-side business logic, server reconciliation) and Replicache's rewind/apply/replay. Its deterministic shared kernel is stronger than Replicache's: the same Rust `judge` runs on both sides, so a prediction diverges only on server-only inputs (ids, time, other sessions' writes). No CRDT or OT replaces the sequencer for the judged domain. Heat caps, leases, FIRE HOLD and `human_only` are not invariant-confluent in Bailis's sense.
- **Upgrades for offline and multi-device, in priority order.**
  1. **Persist pending ops** (Replicache style).
     - What: write the `pending` map, each op's bytes and `op_id`, to IndexedDB with the snapshot. On restore, replay with `predict` on the restored base, then resend.
     - Requires: the sequencer must dedupe resent ops per session or client by `op_id` (Replicache's `lastMutationID`); whether it already does is unknown.
     - Snapshot gating changes: today `pending.size > 0` blocks the snapshot.
     - Cost: about +30–50 lines across `kernel.ts` and `sequencer.ex`.
  2. **Prefer intent-level commands for writes likely to be offline.** Stage advance and heat override are better as `command` ops than as `put` with `EXPECT_REV`, so the server-side judge re-decides on the current state. A replayed op then refuses only when the domain says no, not because a rev moved. Weidner's mutations-versus-state-changes argument supports this.
  3. **Merge long text columns server-side** (CV bodies, notes, `listing_raw` edits) instead of NACKing with `rev`. A diff3-style or Eg-walker-style merge stores only plain text plus an op/event log, building CRDT state transiently. Eg-walker's design point, no persistent CRDT state, fits an authoritative SQLite store. diamond-types (ISC, Rust, WASM) is the only Eg-walker implementation and is WIP. Concurrency on one text field is rare for a single operator, and CV versions are immutable rows. Low priority.
- **Echo suppression** is novel and cheap but risky. The kernel is deterministic and the client predicted the exact writes. For the originating session, the sequencer could send ACK plus an effect hash instead of PATCH plus ACK; the client keeps its pending effects as base when the hash matches and asks for a resync otherwise. This is deterministic lockstep applied to settlement. It saves one PATCH per own write (bytes, plus one undo/redo pass in `rows.rs`). Risk: any hidden nondeterminism, such as a server-assigned id or `as_of`, forces fallbacks; a NACK-free fast path needs the hash to cover them.
- **CRDT libraries are anti-candidates** for the relational core:
  - Automerge 3, Loro and Yjs would add a second replica format next to `rows.rs`;
  - they cannot enforce judged invariants;
  - they add Wasm weight (unmeasured).

  Their compressed columnar in-memory history (Automerge 3) and shallow snapshots (Loro) only matter if hireme ever needs full history in the client.

### Gaps
- I did not verify whether `lib/hireme/sequencer.ex` dedupes a resent `op_id` after reconnect. That determines how safe persisted pending ops are.
- No source gave Automerge or Loro Wasm bundle sizes, or measured server-reconciliation undo/redo costs at hireme's scale.
- I found no peer-reviewed paper on "server reconciliation" itself. The evidence is practitioner writing (Weidner, Replicache, Zero) plus the older optimistic-replication literature, which I did not fetch.

## 4. Columnar encoding and compression for shipping the replica: FSST, BtrBlocks, ALP, FastLanes, Vortex and similar; Wasm decode speed versus zstd; dictionary-trained zstd

### Takeaway
The biggest cold-load lever is likely what is shipped and decoded first, not the codec. Three things matter:
- the ordering and projection of BOOT, so the desk's tables arrive and derive first;
- avoiding ruzstd for hot numeric columns, since ruzstd runs about 1.4–3.5× slower than C zstd and Chrome and Safari have no native `DecompressionStream("zstd")`;
- possibly lightweight encodings (frame-of-reference with bit-packing, ALP for doubles, FSST for strings), which decode an order of magnitude faster than general-purpose codecs at similar or better ratios.

hireme's byte-plane shuffle plus dictionary zstd is a sound, compact baseline. Replace it only after measuring decode time on the operator's node.

### Cited Findings
**Baseline read from hireme's code**
- Wire v2 frames:
  - BOOT and PATCH bodies of 256 bytes or more are byte-plane shuffled and packed with zstd level 9 against a 32 KiB trained `frame.zdict`;
  - a shuffle turns u32 columns into 4 byte planes and i64/f64 into 8, and string offsets become wrapping deltas;
  - text cells of 256 bytes or more are individually zstd 19 against a 32 KiB `text.zdict` and "unpacked one by one" on touch;
  - both dictionaries are declared in the schema and move `wire_hash`.

  — [docs/rebuild.md, Wire v2](../rebuild.md); [native/wire/src/lib.rs](../../native/wire/src/lib.rs); [priv/wire/*.zdict, 32,768 bytes each](../../priv/wire)
- The browser decodes with ruzstd, a pure-Rust decoder inside `kernel.wasm` — [native/wire/src/lib.rs `use ruzstd`](../../native/wire/src/lib.rs)
- The IndexedDB snapshot is the uncompressed table blocks. `restore` re-runs `boot` (parse), then the first derive is cold — [rows.rs `snapshot`, abi.rs `restore`](../../native/kernel/src/abi.rs)
- Recorded decision: if "BOOT at 10k applications with keywords stored" exceeds 2 MiB, "the next lever is a projection, not a compat path"; "a dual wire" is refused — [docs/rebuild.md, Measurements / Refused](../rebuild.md)

**Decoding zstd in and out of Wasm**
- ruzstd README: about 3.5× slower than C zstd decoding enwik9 from ramfs, and about 1.4× slower on less compressible data. Sequence decoding and the bit reader take about 50% of the time — [docs.rs ruzstd](https://docs.rs/ruzstd)
- `DecompressionStream` format support in MDN's browser-compat-data:

  | format | Chrome | Firefox | Safari |
  |---|---|---|---|
  | `zstd` | not supported | 138, behind `dom.compression_streams.zstd.enabled` | not supported |
  | `brotli` | not supported | 147 | 18.4 |
  | `gzip`, `deflate` | 80 | 113 | 16.4 |

  — [MDN BCD JSON](https://raw.githubusercontent.com/mdn/browser-compat-data/main/api/DecompressionStream.json)
- RFC 9842 Compression Dictionary Transport (September 2025, Meenan and Weiss) standardizes HTTP responses used as dictionaries for later responses, with Brotli and Zstandard content codings — [RFC 9842](https://www.rfc-editor.org/rfc/rfc9842.html)
- Per Cloudflare's changelog, shared dictionaries work with browsers that advertise `dcb`/`dcz`, "Chrome 130 or later and Edge 130 or later" — [Cloudflare speed changelog](https://developers.cloudflare.com/changelog/product/speed/); origin trial background: [Chrome blog](https://developer.chrome.com/blog/shared-dictionary-compression)
- A July 2026 blog (secondary) says Safari 26.3 added zstd Content-Encoding, so all three engines decode zstd over HTTP — [youngju.dev](https://www.youngju.dev/blog/2026-07-17-content-encoding-zstd-dictionary-transport.en)

**Lightweight encodings**
- FSST: Fast Random Access String Compression (Boncz, Neumann, Leis; PVLDB 13, 2020; DOI 10.14778/3407790.3407851).
  - A static table maps 1–8-byte symbols to 1-byte codes.
  - It "achieves similar decompression speed and compression speed, and better compression ratio" than LZ4.
  - "It allows random-access to compressed data: it is not block-based." MIT license.

  — [VLDB PDF](https://www.vldb.org/pvldb/vol13/p2649-boncz.pdf); [cwida/fsst README](https://github.com/cwida/fsst); [CWI record](https://ir.cwi.nl/pub/29629)
- fsst-rs, from spiraldb and used by vortex-fsst:
  - "pure-Rust, zero-dependency";
  - "still in-progress and is not production ready";
  - little-endian only;
  - Apache-2.0 per a third-party index.

  — [lib.rs fsst-rs](https://lib.rs/crates/fsst-rs); [depscope](https://depscope.dev/pkg/cargo/fsst-rs)
- OptFSST (arXiv:2607.11271, 2026) reports 5.86 GB/s average decompression, 3.6× LZ4, for its variant (search summary, not verified) — [arXiv PDF](https://arxiv.org/pdf/2607.11271)
- BtrBlocks: Efficient Columnar Compression for Data Lakes (Kuschewski, Sauerwein, Alhomssi, Leis; SIGMOD 2023; DOI 10.1145/3589263) is an open columnar format of cascaded lightweight encodings built for fast decompression at high ratio — [TUM PDF](https://www.cs.cit.tum.de/fileadmin/w00cfj/dis/papers/btrblocks.pdf); [paper index](https://rmarcus.info/dbscholar/papers/h05812847d34ced30)
- Vortex, "inspired by BtrBlocks", reports on TPC-H SF10 files 38% smaller and 10–25× faster to decompress than Parquet with ZSTD, without general-purpose compression. This is a vendor claim — [Vortex blog](https://vortex.dev/blog/btrblocks-compressor)
- ALP: Adaptive Lossless Floating-Point Compression (Afroozeh, Kuffó, Boncz; SIGMOD 2024).
  - It encodes doubles of decimal origin as integers via enhanced PseudoDecimals; other doubles get vectorized compression of their front bits.
  - The abstract says earlier float schemes were no better than Zstd on ratio and much slower than Delta and FOR, and that ALP "significantly improves these previous schemes in both speed and compression ratio".

  — [DuckDB library page](https://duckdb.org/library/alp/); [CWI PDF](https://ir.cwi.nl/pub/33334/33334.pdf)
- A reproducibility report confirmed ALP's core claims (search summary) — [CWI 35864](https://ir.cwi.nl/pub/35864)
- A Rust `fastalp` crate exists; maturity was not checked — [docs.rs fastalp](https://docs.rs/crate/fastalp/0.1.37)
- The FastLanes File Format (Afroozeh, Boncz; PVLDB 18(11):4629–4643, 2025):
  - expression encodings chained across columns, including multi-column correlation;
  - no generic codecs;
  - "improves compression ratio over Parquet, while strongly accelerating decompression";
  - C++ implementation.

  — [DuckDB library page](https://duckdb.org/library/fastlanes/); [VLDB](https://vldb.org/pvldb/volumes/18/paper/The%20FastLanes%20File%20Format); [GitHub](https://github.com/cwida/FastLanes)
- Vortex is now in LF AI & Data (formerly spiraldb). Its README claims 100–200× faster random reads and 2–10× faster scans than Parquet at similar ratio. Figures changed between README versions, and I found no independent reproduction — [GitHub vortex-data/vortex](https://github.com/vortex-data/vortex); [docs.rs vortex 0.86.1](https://docs.rs/crate/vortex)
- F3: The Open-Source Data File Format for the Future (Zeng, Meng, Prammer, McKinney, Patel, Pavlo, Zhang; PACMMOD, September 2025; DOI 10.1145/3749163).
  - Each file embeds Wasm decoders, "adds only kilobytes".
  - The repository is an MIT research prototype that should "not use in production".

  — [Crossref](https://api.crossref.org/works/10.1145%2F3749163); [community summary](https://news.hada.io/topic?id=23411)
- OpenZL (Meta; Collet, Rotem et al.; arXiv:2510.03203, October 2025; revised as arXiv:2605.09928, May 2026) models compression as a DAG of modular codecs with one universal decoder. It reports better ratio and speed than general-purpose compressors on real data — [arXiv](https://arxiv.org/abs/2510.03203); [2605.09928](https://arxiv.org/pdf/2605.09928)

**Client storage**
- RxDB vendor guidance:
  - IndexedDB has "the fastest initial page load"; OPFS suits datasets of more than 10k documents;
  - OPFS synchronous access works only in workers;
  - its table is mixed: IndexedDB about 5.7 ms to first insert versus 27 ms for OPFS in a worker.

  — [RxDB IndexedDB storage](https://rxdb.info/rx-storage-indexeddb.html); [RxDB storage performance](https://rxdb.info/rx-storage-performance.html)

### Inferences
- **Where the cold-load time likely goes.** The ~64 ms to first card (per the brief) is wasm compile and instantiate, plus the IndexedDB snapshot read, plus `restore` (parse blocks), plus the cold derive (bound ≤ 30 ms at 10k), plus template and morph. Codec work is only on the BOOT path, when there is no snapshot or after a resync. With a warm snapshot it is mostly gone, because the snapshot is stored as unpacked blocks. So, in order:
  1. **Progressive BOOT (projection by need).**
     - Order BOOT blocks so `applications`, `me`, `settings`, `corporations` and the places the board reads come first, closed by `END`.
     - Derive and paint the first card, then stream `places` and the world tables, which can be about 50k rows.
     - The wire already supports multi-frame BOOT bodies (`END 0x02`).
     - This is Linear's instant versus lazy load strategy, and it matches the recorded "next lever is a projection".
  2. **Snapshot the derived board for the warm start.** Keep the order and per-card cache keyed by `(rows rev, day)`, so the first card paints before the cold derive; fall back when the day differs. This is an inference; it needs care with grants and the schema rev.
  3. **Only then, codecs.**
- **Codec recommendation**, if BOOT decode shows up in profiles:
  - For u32 id, enum and day columns, a FastLanes-style frame-of-reference plus bit-packing (or dictionary plus bit-packing for low-cardinality enums) decodes with simple shifts. It needs no ruzstd pass, which is the slow part in Wasm. Ratio before entropy coding is usually 4–8× for small-range integers. That is my estimate; zstd over byte planes already captures much of it.
  - For f64 figures (`places`, atlas weights), ALP is the state of the art and beats byte-plane plus zstd on decimal-origin data per the paper's framing.
  - For short strings (names, roles, cities), FSST gives LZ4-class speed with random access per string. That would extend "packed at rest, read on touch" to every string and cut wasm heap. For long texts, per-cell dictionary zstd 19 likely keeps the better ratio. That is an inference; FSST lacks cross-string context.
  - Integration is in `native/wire/src/lib.rs`, replacing `shuffle`/`unshuffle` per column type. It is one codec crate for node and browser. Expect about +200/−60 lines, and borrow `fsst-rs` or `fastalp` code only after review, since neither is production-ready.
- **A native zstd path conflicts with the refused "dual wire".** Chrome and Safari cannot decode zstd in `DecompressionStream`, so ruzstd must stay for WebTransport and WebSocket frames. Shipping the page's own BOOT over HTTP with `Content-Encoding: zstd`/`dcz` (RFC 9842) would let the browser's C decoder do the work. That creates a second encoding path, so treat it as a measured exception at most.
- **Retraining the 32 KiB dictionaries** on current data whenever the schema changes is cheap: a dictionary move already moves `wire_hash`. It is the standard lever for small PATCH bodies and short texts. No new source is needed; this is general zstd practice.
- **Anti-candidates**, as dependencies only; borrow their encoders where useful:
  - Vortex (large, async I/O, file-format machinery);
  - F3 (research prototype; embedded Wasm decoders solve a portability problem hireme does not have);
  - OpenZL (no Rust or Wasm decoder found);
  - DuckDB-Wasm or Parquet in the browser.

### Gaps
- I found no published measurement of ruzstd inside WebAssembly, only native numbers, and no Wasm benchmarks for FSST, ALP or FastLanes decoders.
- I did not measure hireme's current BOOT size, compressed and raw, per table, or the decode and ingest share of cold load. Both are prerequisites for choosing among these options.
- The BtrBlocks paper's own numbers versus Parquet+zstd were not retrievable; the PDF could not be text-extracted here.
- Support for zstd Content-Encoding and `dcz` in Safari and Firefox is confirmed only by secondary sources.

## 5. WebAssembly performance features now shipping (SIMD, relaxed SIMD, memory64, WasmGC, multi-memory, JS string builtins) and what they would buy the kernel

### Takeaway
Most of what helps is already on or cheap:
- Rust ≥ 1.87 enables bulk memory, non-trapping float-to-int and reference types by default, and hireme's toolchain is 1.96+;
- `compileStreaming` already gets V8's code cache.

Fixed-width SIMD (96.5% global support, Safari since 16.4) is a modest, deterministic win for search, text folding and unshuffle. A warm-up call after boot targets the measured first-write penalty.

Do not adopt these:
- relaxed SIMD: nondeterministic and not in Safari, which is fatal for a judge that must match the native NIF;
- memory64: 10% to more than 100% slower;
- WasmGC: for GC languages, not Rust.

JS string builtins and multi-memory buy little for a linear-memory Rust kernel.

### Cited Findings
**Baseline read from hireme's code**
- `kernel.wasm` is built with `opt-level = "s"`, LTO and `codegen-units = 1`, and without `wasm-opt`: "-O3's inlining made the first call of a write's judge ~3 ms slower in Chromium (a fresh page's heat override 7.1 -> 10.3 ms, A/B x2) for a fifth fewer bytes" — [nix/package.nix lines 88-108](../../nix/package.nix); [native/Cargo.toml](../../native/Cargo.toml)
- The local release artifact is 896,597 bytes (Oct 18 build in `native/target`). A team memory note records 777 KB against v1's 83 KB — [native/target/wasm32-unknown-unknown/release/kernel.wasm](../../native/target/wasm32-unknown-unknown/release/kernel.wasm)
- `early.ts` uses `WebAssembly.compileStreaming(fetch(...))` on the preloaded wasm URL — [assets/js/early.ts line 65](../../assets/js/early.ts)
- All transcendental math goes through `libm`, never a platform library, for parity between NIF and Wasm — [native/kernel/src/lib.rs line 10](../../native/kernel/src/lib.rs); [heat.rs](../../native/kernel/src/heat.rs)
- The local toolchain reports rustc 1.96.1 — local `rustc --version`

**Standards and browser support**
- Wasm 3.0 was completed on 2025-09-17. It includes:
  - memory64 ("on the web, a 64-bit memory is limited to 16 gigabytes");
  - multiple memories;
  - GC;
  - typed references, with `call_ref` "without any runtime type or bounds check";
  - tail calls;
  - exception handling;
  - relaxed SIMD ("implementation-dependent behavior in certain edge cases");
  - a deterministic profile for NaNs and relaxed SIMD;
  - custom annotations;
  - JS string builtins, which operate on JS strings passed as externrefs.

  — [webassembly.org Wasm 3.0](https://webassembly.org/news/2025-09-17-wasm-3.0/)
- `wasm32-unknown-unknown` enables by default: multivalue, mutable-globals, reference-types, sign-ext, and since Rust 1.87 / LLVM 20, nontrapping-fptoint and bulk-memory — [rustc book: wasm32-unknown-unknown](https://doc.rust-lang.org/rustc/platform-support/wasm32-unknown-unknown.html)
- Fixed-width SIMD128 first shipped in Chrome 91, Firefox 89 and Safari 16.4 (desktop and iOS); global support is 96.53% — [caniuse wasm-simd](https://caniuse.com/wasm-simd)
- In Rust, `simd128` is a compile-time target feature with no runtime detection: "either have SIMD … or it will not" — [core::arch::wasm32 docs](https://doc.rust-lang.org/nightly/core/arch/wasm32/)
- memchr enables a `simd128` path on wasm32 when the feature is on, "typically much faster than scalar routines" — [memchr wasm32 simd128 source](https://searchfox.org/firefox-main/source/third_party/rust/memchr/src/arch/wasm32/simd128)
- Relaxed SIMD: Chrome 114+ and Firefox 146+, Safari unsupported through 26.5 TP — [caniuse wf-wasm-simd-relaxed](https://caniuse.com/wf-wasm-simd-relaxed)
- Memory64's slowdown "can range from just 10% to over 100%" because 32-bit bounds-check elision is impossible. "The only reason to use Memory64 is if you actually need more than 4GB of memory." — [SpiderMonkey blog, 2025-01-15](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html)
- V8 code caching:
  - only for `compileStreaming` and `instantiateStreaming`;
  - keyed by the wasm URL, and changing it (query included) forces a recompile;
  - needs `Content-Type: application/wasm` and at least 128 kB;
  - a 304 keeps the cache and a 200 invalidates it;
  - written only after TurboFan finishes, which can take 30–60 s for large modules;
  - invalidated with each V8 update ("at least every 6 weeks").

  — [v8.dev wasm code caching](https://v8.dev/blog/wasm-code-caching)
- Under dynamic tiering, "Chrome only caches TurboFan code". Functions that never qualify for TurboFan are compiled by Liftoff at startup even when the module is cached — [v8.dev dynamic tiering](https://v8.dev/blog/wasm-dynamic-tiering)
- The compilation hints proposal is at Phase 2, not shipped. Branch hinting reached Phase 5 (standardized) — [WebAssembly proposals](https://github.com/webassembly/proposals); [Leaning Technologies on branch hinting](https://labs.leaningtech.com/blog/branch-hinting)

### Inferences
- **Already have.** Bulk memory and the other defaults are on: rustc 1.96 is above 1.87, which affects memcpy-heavy column copies and BOOT ingest. Code caching applies: `compileStreaming`, about 0.9 MB, digested URL after commit 0e502aa per team notes. The cache stores only TurboFan-tiered functions. So every cold page pays Liftoff for the first call of anything not yet hot, which is consistent with the measured first-call heat-override cost.
- **Warm-up after boot.**
  - What: during idle after the first paint, run one throwaway `judge` call per hot op kind (a no-op stage move refused by FIRE HOLD), plus a `view` with a search.
  - Why: Liftoff compilation and early tier-up happen before the operator's first real write. This targets the "fresh page" penalty (7.1 ms versus 4–6 ms steady).
  - Cost: about 5–10 lines in `kernel.ts`.
  - Risk: none, since `judge` without `predict` has no side effects. Verify that `judge` mutates no board state; it takes `&mut self.board`.
- **SIMD128.** Build with `-C target-feature=+simd128` and let memchr (board search), ASCII folding in `text.rs` and `unshuffle` (an 8-plane transpose) vectorize.
  - Integer SIMD is deterministic, so NIF/Wasm parity holds, but float SIMD must not reorder reductions. Keep float sums scalar or fixed point, as `heat.rs` already does.
  - Expected: modest at 1k applications (search is already sub-ms), more for BOOT unshuffle at 10k. Measure with `bench/kernel.mjs` and a decode microbenchmark.
  - Risk: a build without runtime detection breaks pre-2023 Safari (below 16.4), which is negligible for a single operator.
  - LOC: 0–1 (a Nix flag).
- **`wasm-opt -Os`/`-Oz` without -O3's inlining is untested** per the build comment. It could shrink the module about 10–20% without the first-call penalty. This is an A/B to run, not a recommendation; the size figure is my estimate.
- **Anti-candidates:**
  - relaxed SIMD, whose implementation-defined results could make a client prediction disagree with the server verdict;
  - memory64;
  - WasmGC, since Rust uses linear memory;
  - exception handling and tail calls, which buy nothing for Rust with panics caught at the NIF boundary;
  - multi-memory, whose isolation could separate result buffers but whose Rust toolchain support is unverified.
- **JS string builtins** would only help if the kernel handed many strings to JS as JS strings. The better lever, already partly used through `ids_ptr`/`col_ptr`/`str_ptr`, is to keep returning column views instead of JSON documents for hot reads.

### Gaps
- I found no source on V8's current wasm lazy-compilation default or exact tier-up thresholds, and no 2025–2026 measurement of code-cache hit latency.
- Multi-memory's Rust/LLVM toolchain support was not verified.
- I found no measured SIMD128 speedups for memchr, ruzstd or byte transposes in browsers.

## 6. Static analysis of ordered rule sets: usefulness and redundancy checking, SMT/BDD policy analysis, decision trees, Rete. Which can report "this rule can never win" or "this rule matches nothing" from the types alone, cheaply?

### Takeaway
A small hand-written checker, about 200–300 lines, gives exact answers for hireme's mask language. It uses space subtraction over per-field abstract domains, combining Maranget/Lower-Your-Guards-style usefulness with firewall-style atomic partitioning:
- bitsets for enums and bools;
- interval sets for numbers and days;
- literal sets for codes;
- word, prefix and equality literal partitions for text.

This answers "can never win" in microseconds per keystroke, independent of today's data. Field-to-field comparisons are the only case where it falls back to sound-but-incomplete. SMT (Zelkova, Cedar) is the gold standard but far too heavy in the browser. Rete is unnecessary for single-application patterns.

### Cited Findings
**Baseline read from hireme's code**
- The DSL grammar:
  - operators `|`, `&`, `!` and `[a, b]` (all hold);
  - tests: bare field (present, or true for bools), `field op value`, and field-to-field comparison, with ops `= == != < <= > >= in ~ ^=`;
  - literals: text, numbers, `:symbols`, country codes, days, booleans;
  - named masks inline by name.

  — [native/kernel/src/mask.rs header](../../native/kernel/src/mask.rs)
- Field types are `Bool, Text, Num, Day, Code, Enum(name), Texts, Codes, Enums(name)`, and enums order by declaration. A comparison on an absent field is false, so `country != DE` requires presence while `!(country = DE)` does not — [mask.rs](../../native/kernel/src/mask.rs)
- `pick::check` judges a rule text against today's data only:
  - it counts applications the rule matches, and which of those an earlier enabled arm takes;
  - `shadowed` means every match is taken;
  - `never_matches` means `matched == 0`.

  The cost is O(applications × earlier arms) per call, run as the operator types — [native/kernel/src/pick.rs lines 143-174](../../native/kernel/src/pick.rs)

**Pattern-match usefulness (PL)**
- Maranget, "Warnings for pattern matching" (JFP 2007):
  - defines useless clauses and non-exhaustive matches with a simple usefulness-matrix algorithm;
  - it is integrated into OCaml and applies to non-strict languages, or-patterns included;
  - it notes that decision trees "include no dead code", which eases diagnostics.

  — [Cambridge Core](https://resolve.cambridge.org/core/journals/journal-of-functional-programming/article/warnings-for-pattern-matching/3165B75113781E2431E3856972940347); [PDF](https://code.garrettmills.dev/Archives/papers-we-love_papers-we-love/raw/branch/main/pattern_matching/warnings-for-pattern-matching.pdf)
- Maranget, "Compiling Pattern Matching to Good Decision Trees" (ML Workshop 2008; DOI 10.1145/1411304.1411311) uses necessity-based heuristics and is competitive with optimizing match compilers — [PDF](https://www.cs.tufts.edu/~nr/cs257/archive/luc-maranget/good-trees08.pdf)
- "Lower Your Guards: A Compositional Pattern-Match Coverage Checker" (Graf, Peyton Jones, Scott; ICFP 2020):
  - reduces every pattern form to guard trees with three constructs;
  - beats GHC's previous checker on accuracy and performance in reported cases;
  - is the basis of GHC's checker, which reports uncovered patterns, redundant equations and inaccessible right-hand sides.

  — [Microsoft Research](https://www.microsoft.com/en-us/research/publication/lower-your-guards-a-compositional-pattern-match-coverage-checker/); [GHC Pmc docs](https://hackage-origin.haskell.org/package/ghc/docs/GHC-HsToCore-Pmc.html)
- Rust's `rustc_pattern_analysis`:
  - "a pattern q is said to be useful if there is a value that is matched by q and by none of the p_i";
  - it is adapted from Maranget;
  - exhaustiveness is NP-complete, since SAT encodes into it.

  — [rustc_pattern_analysis::usefulness](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_pattern_analysis/usefulness/index.html)

**Policy analysis (security)**
- Zelkova, "Semantic-based Automated Reasoning for AWS Access Policies using SMT" (Backes et al.; FMCAD 2018, pp. 206–214):
  - translates policies to SMT over strings, regexes, bit vectors and integers, using off-the-shelf solvers and Z3AUTOMATA;
  - "solves a PSPACE-complete problem and is invoked many millions of times daily";
  - powers IAM Access Analyzer for S3.

  — [Amazon Science](https://www.amazon.science/publications/semantic-based-automated-reasoning-for-aws-access-policies-using-smt); [PDF](https://cs.utexas.edu/~hunt/FMCAD/FMCAD18/papers/paper3.pdf); [AWS blog](https://aws.amazon.com/jp/blogs/security/protect-sensitive-data-in-the-cloud-with-automated-reasoning-zelkova/)
- Cedar ("Cedar: A New Language for Expressive, Fast, Safe, and Analyzable Authorization", OOPSLA 2024; arXiv:2403.04651) was designed so its SMT encoding is "sound, decidable, and complete". Equivalence is checked as an SMT query satisfiable iff some request is allowed by one policy set and not the other; UNSAT proves equivalence — [arXiv](https://arxiv.org/pdf/2403.04651); [How We Built Cedar, arXiv:2407.01688](https://arxiv.org/pdf/2407.01688)
- `cedar-policy-symcc` checks equivalence, subsumption, disjointness and always-allow/always-deny with cvc5 1.3.1. The symbolic compiler is modelled and verified in Lean — [docs.rs cedar-policy-symcc](https://docs.rs/cedar-policy-symcc)
- Firewall anomaly taxonomy (Al-Shaer and Hamed, INFOCOM 2004; JSAC 23(10), 2005):
  - **shadowing:** a rule is unreachable because earlier rules take all its packets with a different action;
  - **generalization:** a later broader rule covers an earlier specific one;
  - **correlation:** partial overlap with different actions;
  - **redundancy:** removable with no change.
  - Pairwise comparison scales poorly as rule counts grow.

  — [KFUPM record](https://pure.kfupm.edu.sa/en/publications/discovery-of-policy-anomalies-in-distributed-firewalls/); [JSAC PDF](https://rboutaba.cs.uwaterloo.ca/Papers/Journals/2005/Ehab05.pdf); [summary of definitions](https://arxiv.org/pdf/1102.1237)
- FIREMAN (Yuan et al., IEEE S&P 2006) encodes rules as BDDs and model-checks all packets and paths, sound and complete on a finite state space. It found real misconfigurations — [UC Davis PDF](https://www.cs.ucdavis.edu/~hchen/paper/ieeesp2006.pdf)
- Margrave (Fisler, Krishnamurthi, Meyerovich, Tschantz; ICSE 2005) uses multi-terminal BDDs to verify XACML policies and compute change-impact (semantic differences between versions) — [Brown page](https://cs.brown.edu/~sk/Publications/Papers/Published/fkmt-verif-change-impact-xacml/)
- Atomic predicates (Yang and Lam, ICNP 2013; ToN 2016):
  - the coarsest set of disjoint, covering predicates from which every rule predicate is a union;
  - each atom is labelled by an integer, so conjunction and disjunction become set operations on integers;
  - re-implemented by Google to verify its virtual private clouds.

  — [UT Austin NRL page](https://www.cs.utexas.edu/~lam/NRL/Atomic_Predicates_Verifiers.html)
- Z3 in the browser: `z3-solver` 5.3.1 ships `build/z3-built.wasm` of 34,580,492 bytes, plus a 358 KB JS loader, and needs SharedArrayBuffer and cross-origin isolation (threads) — [jsDelivr package listing](https://data.jsdelivr.com/v1/packages/npm/z3-solver@5.3.1); [npm z3-solver](https://npmjs.com/package/z3-solver)

**Incremental matching (Rete family)**
- Rete is "eager", doing partial-match work on every insert, update and delete. Phreak (Drools) is "lazy", goal-oriented and heuristic-scheduled. The vendor claims it is more scalable but publishes no benchmark figures — [Red Hat docs: Phreak](https://docs.redhat.com/en/documentation/red_hat_decision_manager/7.13/html/developing_decision_services_in_red_hat_decision_manager/phreak-algorithm-con_decision-engine)
- A Rust Phreak crate exists — [lib.rs phreak_engine](https://www.lib.rs/crates/phreak_engine)

### Inferences
- **Problem shape.** hireme's arms are first-match. Arm i "can never win" iff P_i ∧ ¬P_1 ∧ … ∧ ¬P_{i−1} is unsatisfiable over enabled earlier arms with live roots. Arm i "matches nothing" iff P_i is unsatisfiable. These are exactly Maranget usefulness (row i is useless) and the firewall shadowing check. The ingredients:
  - **Domain values.** Each field's domain is {absent} ∪ the values of its type.
  - **Negation.** A negated atom flips within that domain, including the absent case, which matters because comparisons on absent fields are false.
  - **Decomposition.** Without field-to-field comparisons, a conjunction is satisfiable iff each field's constraints are.
- **Per-field abstract domains** (exact unless noted):
  - **Bool:** a 3-element set (absent, true, false).
  - **Enum and Enums element:** a bitset over `values(name)` plus absent. `<` and `>` map exactly because enums order by declaration.
  - **Num and Day:** finite unions of intervals, with open and closed endpoints and integer days.
  - **Code:** a finite literal set or its co-finite complement, with region prefixes like `DE-BY` as a prefix lattice.
  - **Text** (case-folded with the same `text.rs` folding): equality, `~` word containment and `^=` prefix, decided over the finite set of literals the rule set mentions. This is an atomic-predicate partition: a value's class is which mentioned words it contains, which mentioned prefixes it has, and whether it equals a mentioned literal. Examples:
    - `x = "a b"` with `x ~ c` is unsatisfiable when "a b" lacks word c;
    - two incompatible prefixes are unsatisfiable;
    - containment constraints are otherwise jointly satisfiable.
  - **Lists:** sets of required and forbidden elements plus emptiness.
- **Algorithm.** Expand each arm into a union of "boxes", each a product of per-field sets. Rules are short, so DNF stays small; cap it and fall back to the data check past the cap. To test arm i, subtract each earlier arm's boxes from arm i's boxes. Box difference yields at most one box per constrained field, the standard hypercube subtraction in firewall analysis. Empty remainder means "can never win", and the arms that consumed it are the "taken by" list.
- **Cost and placement.** Microseconds for tens of rules, independent of application count. It replaces the O(applications × arms) scan in `pick::check` that runs per keystroke in the rule editor. It lives in `mask.rs` (domains, NNF and box ops) and `pick.rs` (`check`). Size: about +200–300 lines, about −25 for the old shadow logic.
- **Reporting.** Keep the data counts as a second line ("today: matches N, wins M"). Use the Al-Shaer taxonomy for useful messages:
  - shadowed by a different root: likely a mistake;
  - redundant, same root: harmless, can delete;
  - generalization: a later broader rule, intended as an exception;
  - correlation: partial overlap with a different root, so order matters.
- **Field-to-field comparisons** (`value := field`) break per-field independence. Two options keep them sound:
  - treat them as "unknown", which over-approximates satisfiability, so no false "never wins" claims;
  - for Num and Day, add difference constraints (x − y ≤ c), decidable by a shortest-path check.

  Cedar's lesson applies: keep the DSL inside a decidable fragment. Adding regexes or arithmetic across fields would push hireme toward SMT.
- **SMT and BDD.** Zelkova, Cedar's symcc and Margrave-style MTBDDs give exact equivalence and change-impact ("which applications change root if I move this rule"). In the browser they are anti-candidates: z3-built.wasm is 34.6 MB, about 38× the whole kernel, and needs cross-origin isolation. hireme can already compute change-impact exactly on data with two pick passes.
- **Decision-tree compilation** (Maranget 2008) would let each application evaluate each distinct test once, and dead leaves give shadowing for free. It pays only when arms number in the hundreds. Low priority next to the per-application pick memo in question 1.
- **Rete and Phreak** are anti-candidates. Every rule is a pattern over one application's facts, reading through its corporation and place rows, so there are no beta joins between facts. A per-application memo keyed by row revs gives Rete's incremental property in about 20 lines.

### Gaps
- I found no paper that does usefulness checking for a DSL with word-containment text predicates specifically. The text-domain design above is my synthesis from atomic predicates and string-constraint practice, and needs property tests: random rule sets, with static "never wins" checked against brute-force evaluation over generated facts.
- I did not check whether any rule actually uses field-to-field comparisons, or how many rules a heavy user writes.

## 7. Technique scorecard (papers, maturity and implementations, plug point, expected impact, cost, line-count impact, risks, scores 1–5) and anti-candidates

### Takeaway
Five changes are recommended, in this order:
1. per-application CV-pick memo (Salsa ideas, hand-rolled);
2. static rule-shadowing checker;
3. Z-set incremental board with group-local updates;
4. rev-keyed lazy morph;
5. persisted pending ops plus intent commands for offline.

Then, measured cold-load levers: progressive BOOT, a post-boot warm-up call, SIMD128, and lightweight encodings only if decode shows up in profiles. Every imported engine is an anti-candidate: dbsp/Feldera, differential dataflow, Materialize, Turso IVM, Salsa as a crate, CRDT libraries, SMT solvers, Rete engines, Vortex, F3, OpenZL, memory64, relaxed SIMD and WasmGC.

### Cited Findings
- Maturity facts used in the scorecard (each cited in sections 1–6):
  - `dbsp` 0.367.0 has a wasm-hostile dependency set — [docs.rs dbsp](https://docs.rs/crate/dbsp/latest)
  - Salsa 0.28.x had a recent use-after-free fix — [Fedora advisory](https://linuxsecurity.com/advisories/fedora/rust-salsa-fedora-44-2026-407b957a3b)
  - Turso IVM is experimental — [Turso blog](https://turso.tech/blog/introducing-real-time-data-with-materialized-views-in-turso)
  - TC39 Signals is at Stage 1 — [tc39/proposal-signals](https://github.com/tc39/proposal-signals)
  - diamond-types is WIP, ISC — [GitHub](https://github.com/josephg/diamond-types)
  - fsst-rs is not production-ready — [lib.rs](https://lib.rs/crates/fsst-rs)
  - F3 is a research prototype — [Crossref](https://api.crossref.org/works/10.1145%2F3749163)
  - Vortex is in LF AI & Data — [GitHub](https://github.com/vortex-data/vortex)
  - `z3-built.wasm` is 34.6 MB — [jsDelivr](https://data.jsdelivr.com/v1/packages/npm/z3-solver@5.3.1)
  - memory64 is 10% to over 100% slower — [SpiderMonkey](https://spidermonkey.dev/blog/2025/01/15/is-memory64-actually-worth-using.html)
  - relaxed SIMD is not in Safari — [caniuse](https://caniuse.com/wf-wasm-simd-relaxed)
  - SIMD128 has 96.53% support — [caniuse](https://caniuse.com/wasm-simd)
  - ruzstd is 1.4–3.5× slower than C zstd — [docs.rs ruzstd](https://docs.rs/ruzstd)
  - no `DecompressionStream("zstd")` in Chrome or Safari — [MDN BCD](https://raw.githubusercontent.com/mdn/browser-compat-data/main/api/DecompressionStream.json)

### Inferences

**Recommended candidates.** Scores are my judgments: I = impact on hireme's latencies or payload, F = feasibility for the team under net-zero-lines, N = novelty relative to hireme's current design.

| # | Technique (key source) | Plug point | Expected effect (estimate; measure first) | Cost / LOC | Risks | I | F | N |
|---|---|---|---|---|---|---|---|---|
| 1 | Per-application CV-pick memo with durability epoch and early cutoff (Salsa red-green, durability, backdating; Adapton demand) | `abi.rs` `moved()`, `pick.rs` `Picks` | Removes the (applications × arms) rebuild after every application write. Hot on focus-lens and MCP `cv_pick` paths. Likely ms-scale at 1k+ applications × tens of arms. | about +15/−10, near net-zero | Missing a read dependency (corporation or place rev) gives a stale pick. Property test: memo = fresh `Picks::of`. | 3 | 5 | 2 |
| 2 | Static "never wins / matches nothing" checker: space subtraction over per-field domains (Maranget JFP 2007; Lower Your Guards ICFP 2020; Al-Shaer and Hamed taxonomy; atomic predicates ICNP 2013) | `mask.rs` (domains, boxes), `pick.rs` `check` | Per-keystroke check from O(applications × arms) to microseconds. Correct regardless of data, plus correlation and generalization warnings. | about +200–300 / −25: net positive (new capability) | Text-domain subtleties (folding, word boundaries) need brute-force property tests. Field-to-field comparisons stay "unknown". | 3 | 4 | 4 |
| 3 | Incremental board via Z-set deltas: linear group sums (exact fixed point already in `heat.rs`), group-local verdicts, BTreeSet order index (DBSP, PVLDB 2023) | `board.rs` `derive`/`forget`, `heat.rs` index | `derive_after_patch` from O(n) to O(k log n), k = cards in touched company, vendor, tenant and batch groups. Could recover 1–3 ms of the 4–6 ms stage-write median if derive dominates (unmeasured). | about +120 / −60; keep from-scratch derive for BOOT and day change | Day-change decay touches everything (full path). Global terms in the governor, if any, defeat locality. Needs an "incremental = fresh" property test. | 4 | 3 | 4 |
| 4 | Rev-keyed lazy morph: skip keyed subtrees whose `data-rev` is unchanged and cache their HTML (Elm `Html.Lazy`; morphdom cost floor) | `morph.ts`, lenses (world, outreach, atlas, focus rail) | Template and morph cost proportional to changed rows, not shown rows. Small on the desk (cards already value-by-value), larger on big grids. | about +25–40 | Stale fragments if a rev misses a dependency, for example a joined row. Elm's fragility avoided by using integer revs. | 3 | 4 | 2 |
| 5 | Persisted pending ops plus intent-level commands (Replicache; Weidner 2024; Bailis I-confluence for which ops can merge) | `kernel.ts` pending map and snapshot gating, `sequencer.ex` dedupe by op id | Offline and reload safety. Fewer `rev` NACKs after reconnect. No latency change online. | about +30–50 | Double-apply if the server does not dedupe resent `op_id`s (unknown). Replay on a moved base may legitimately refuse. | 3 | 3 | 2 |
| 6 | Progressive or projected BOOT, desk tables first (Linear-style load strategies; rebuild.md's "projection" lever) | `native/wire` BOOT ordering, node BOOT writer, `early.ts` and `kernel.ts` first derive | First card after the desk tables, not after 50k `places` rows, on BOOT and resync paths. Warm snapshot path unchanged. | about +20–60 | The board reads places ("home") and corporations, so the projection must include referenced rows. Grant masks. | 4 | 3 | 2 |
| 7 | Post-boot warm-up call (V8 Liftoff and dynamic tiering behaviour) | `kernel.ts` after first paint (idle) | Targets the measured fresh-page first-write penalty (heat override 7.1 ms; 10.3 ms with -O3). | about +5–10 | Must use a side-effect-free `judge`; check that `&mut board` has no visible effect. | 2 | 5 | 1 |
| 8 | SIMD128 build (Wasm 2.0; memchr simd128) | `nix/package.nix` and `flake.nix` RUSTFLAGS | Faster search, text folding and unshuffle. Modest at 1k, more at 10k BOOT. | about 0–2 | No runtime detection (Safari < 16.4 fails). Keep float reductions scalar or fixed point for parity. | 2 | 4 | 2 |
| 9 | Lightweight column encodings: FOR plus bit-packing (FastLanes PVLDB 2025), ALP for f64 (SIGMOD 2024), FSST for short strings (PVLDB 2020) | `native/wire/src/lib.rs` shuffle stage | Less ruzstd work (1.4–3.5× slower than C) on BOOT. Smaller `places` figures. Per-string random access. | about +200 / −60 | Immature Rust ports (fsst-rs, fastalp). A wire change moves `wire_hash`. Gains unproven in Wasm. | 3 | 3 | 4 |
| 10 | Echo suppression by deterministic effect hash (lockstep idea on a deterministic kernel) | `sequencer.ex` ACK, `wire` ACK body, `rows.rs` resolve | One fewer PATCH and undo/redo per own write. Fewer bytes. | about +30 | Any hidden nondeterminism (ids, `as_of`) forces resync. Debugging divergence is harder. | 2 | 3 | 4 |
| 11 | Server-side text merge for concurrent edits of long text (Eg-walker EuroSys 2025; diamond-types ISC) | sequencer write path for text columns | Fewer "your edit was undone" refusals when operator and agent edit one text. | about +80, or a diff3 variant at about +40 | Rare scenario. WIP library. Merge semantics on CV versions are debatable. | 1 | 2 | 4 |

**Anti-candidates (do not adopt), with reasons:**
- **`dbsp` crate / Feldera runtime in the kernel:** tokio, nix, libc, core_affinity, tempfile and C zstd make it wasm-hostile; 12.3 MB of source; built for server pipelines. Take the algebra, not the crate.
- **Differential dataflow, timely dataflow, Materialize:** designed for data-parallel, iterative and distributed dataflow; far beyond 50k single-tenant rows.
- **Turso IVM:** experimental, unstable on-disk format, no benchmarks. hireme's derivations live in the kernel, not in SQL views.
- **Salsa as a dependency:** `std` and macros, unsafe internals (0.28.5 use-after-free), a wasm32 `catch_unwind` history, and a generic graph for about five statically known derivations. Hand-rolled durability, early cutoff and per-row revs give the benefit.
- **A signals runtime** (TC39 polyfill, Solid, alien-signals): TC39 is at Stage 1, it adds a second state model and framework code against "No framework" and net-zero lines, and rev-keyed morph plus value-by-value cards capture most of the gain.
- **CRDT document stores for the relational core** (Automerge 3, Loro, Yjs):
  - they cannot enforce judged invariants (Bailis);
  - in centralized systems they are only an optimization over server reconciliation (Weidner);
  - they would duplicate the replica in a second format.
- **OT:** O(op types²) transformation functions and O(active users) server transforms per op.
- **SMT solvers in the browser** (Z3, cvc5): a 34.6 MB Wasm with cross-origin isolation. A server-side SMT in the NIF and Nix closure is also heavy for tens of rules.
- **Rete or Phreak engines:** single-application patterns; a per-row memo achieves the incremental property.
- **memory64:** 10% to over 100% slower; hireme needs far less than 4 GB.
- **Relaxed SIMD:** implementation-defined results threaten client and NIF parity, and Safari lacks it.
- **WasmGC:** Rust uses linear memory.
- **Vortex, F3, OpenZL, DuckDB-Wasm, Parquet-in-browser as dependencies:**
  - size and machinery far beyond the wire codec;
  - F3 is a research prototype;
  - no OpenZL Wasm decoder was found.
- **OPFS migration for the snapshot:** RxDB finds IndexedDB fastest for initial load below about 10k documents, and OPFS sync access is worker-only.
- **A native-zstd HTTP side channel for BOOT** (`dcz`, Content-Encoding): it would be the "dual wire" the rebuild refuses. Only an exception if measurement shows ruzstd dominating cold BOOT.

**Sequencing advice:** measure first, then build. A CDP and Performance-panel split of one stage write and one cold load, plus `bench/kernel.mjs` with `derive_after_patch_ms` and the picks rebuild timed separately, decides whether items 3, 6 and 9 are worth their lines. Items 1, 2, 7 and 8 are cheap enough to try directly.

### Gaps
- All "expected effect" figures above are reasoned estimates from code structure and literature; none were measured on hireme for this report.
- Several maturity facts rest on vendor or self-reported sources: Vortex and Loro benchmarks, alien-signals claims, Phreak claims, RxDB tables.
- Wasm bundle sizes for Automerge, Loro and Salsa-based builds were not found.
