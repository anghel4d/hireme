Here are five candidates, ranked by leverage, each with a build plan. Where a claim comes from the code I give the file reference. Where it comes from research I give the source.

## How I searched

- **Observer MCP:** About 35 live `query_seeds` calls worked, then Cloudflare rate-limited me (error 1015), which I caused. I stopped hitting it. I pulled `cards.json` (2,360 cards) and searched that locally, which is the same data.
- **What the catalog covers:** It is strong on databases, netcode, agent memory and provenance. It is thin on retrieval and ranking. The retrieval, compression and matching evidence below comes from web search, and I note where a source is secondary.
- **Codebase:** I read `docs/rebuild.md`, `heat.md` and `score.md`, then the kernel, sequencer and MCP code those docs point at.
- **Constraints I planned around:**
  - Your client-resident rule: *"Authoritative server, optimistic client, rollup and rollback netcode like a fighting game. Round trips should be minimized to only when absolutely necessary, eg, when doing a rollback."*
  - The LOC bound: *"making sure every commit from here on is strictly bounded and ideally *reduces* LOC from now on."*
  - The nuke rule: one path per thing, no dual readers.

---

## 1. Fit: a hybrid retrieval kernel (RAG)

**Gap.**
- A listing's keywords are its 12 most frequent words after a stop list (`keywords.rs`: `TOP = 12`, `STOP`).
- Coverage is a whole-term hit in the composed CV (`keywords.rs:309`).
- Search is substring matching (`like`/`prefix` in `query.rs`, `contains` in `board.rs`).
- There is no IDF weighting, no skill aliasing ("k8s"/"kubernetes", "golang"/"go"), no semantic matching, and no relevance ranking. An agent can only substring-`find`.

**Research.**
- Observer cards:
  - 092 DPR: dense retrieval beats BM25 by 9–19 points of top-20 accuracy.
  - 064 TriMem: keep raw anchored text, atomic facts and profiles together.
  - 1233 Nexus: route with a cheap INT8 scan plus a calibrated margin gate, escalating about 20% to a heavier model.
  - 053 CodeGrep: lexical tools go far.
- [MUVERA](https://arxiv.org/abs/2405.19504) (NeurIPS 2024) reduces late-interaction search to single-vector search. It reports about 10% better recall at 90% lower latency than PLAID, and 32× compression with product quantization.
- Static embeddings: [potion-retrieval-32M](https://huggingface.co/minishlab/potion-retrieval-32M) reaches 81.7% of MiniLM's MTEB retrieval score. It is a token-table lookup plus a mean, with no transformer.
- Resume matching:
  - [2610.03112](https://arxiv.org/abs/2610.03112) (EMNLP 2026): a CPU bi-encoder distilled from LLM labels over 8 named dimensions agreed with recruiters 95.79% of the time on a selected, non-blinded feedback subset.
  - [Resume Tailor](https://arxiv.org/abs/2605.05257): retrieval raised fit scores by 7.8 points when prior experience matched and lowered them by 8.0 when the domain was absent. That is an argument for confidence gating.

**Design.** The kernel is the index, and every layer is one deterministic function, so wasm and the NIF agree.
1. **L0 lexical.** BM25F over company, role, location and `listing_raw`, with IDF from the account's own resident listings, plus an alias table in `lexicon.rs`. IDF makes the stop list and the top-12 cutoff unnecessary.
2. **L1 semantic.** An int8 static embedding table. Integer arithmetic keeps the result bit-identical across wasm and native. Embeddings are derived at BOOT like the board, so there is no schema or wire change.
3. **L2 explainable fit.** CV `items` are already atomic. For each listing requirement line, compute the best-matching CV atom by MaxSim and show it with the score. The CV composer then picks atoms to maximise requirement coverage under the length budget.
4. **Agent loop.** Ambiguous cases (inside the margin gate) go to the agent, which judges them and writes the result back as a cited `put`. Those labels later train the per-dimension heads, as in 2610.03112, with your own agents as the labelers.
5. **MCP.** A new `search` tool: fielded, mask-respecting, returning scored snippets with row refs.

**Scale.** At 10k listings, brute-force MaxSim is microseconds. MUVERA is the scale path, not the first step.

**Risks.**
- Listings are multilingual, so the embedding model needs multilingual vocabulary, which is larger.
- The model adds weight to cold load, which fits your cold-load tradeoff note.
- No eval set exists yet. Build 200 agent-judged queries first.

**LOC.** This adds net lines. It deletes `STOP`, the top-N heuristic and the `like` fallbacks, but it needs a waiver or a named payback.

## 2. Delta-resume sync: "BOOT is the delta from nothing"

**Gap** (this is the known gap in your wire notes).
- `sequencer.ex:436`: a session resumes only if `snapshot_rev == state.rev` exactly, and only the operator's session.
- Any write in between, or any agent key, gets a full BOOT. `resumed/3` (`:1698`) sends empty blocks.
- There is no delta history in sequencer state.
- After a deploy, every client re-BOOTs at once. A reconnecting agent re-BOOTs too.

**Research.**
- Observer cards: 412 Quake III (deltas against a per-client acknowledged frame), 331 Gaffer, 197 GGPO, 269 prediction and reconciliation.
- [Range-based set reconciliation](https://arxiv.org/pdf/2212.13567) (Meyer), with [Amparore 2026](https://arxiv.org/abs/2603.19820): augmented B+-tree range summaries, which cut local reconciliation cost on reconciliation-heavy workloads.
- [Self-sizing IBLTs](https://arxiv.org/abs/2608.26537) (Wu et al., Sept 2026): at most two rounds, 1.29–1.47× an oracle's communication, and over 90% finishing in one round-trip with a single 16 KB sketch.
- [Zero's](https://zero.rocicorp.dev/llms.txt) client-view-record model. I only saw a third-party mirror of its design docs.

**Design.**
1. A per-account change log (rev, table, id, tombstone), written in the sequencer's own transaction and bounded by the schema's `cap` rule.
2. HELLO already carries `snapshot_rev`. If it is above the log floor, the server sends one coalesced PATCH of rows changed since then, read from the kernel cache. That costs O(changed rows).
3. BOOT becomes the same path with `snapshot_rev = 0`. Delete the separate `snapshot`/`resumed` duality.
4. Keys resume too, with a hash of their effective grants in HELLO so a mask change forces a BOOT, which `BYE grants` already does.
5. Phase 2, only if a bench shows the fallback is common (your own "Measurements, not decisions" stance). Rows already carry a per-row `rev`, so `(table, id, rev)` triples are ready-made fingerprints for RBSR, or for a 16 KB IBLT sketch when the client is below the floor.

**Gates.**
- A property test: resume from any rev in the window equals a fresh read, with random disconnect points. It extends your existing "base ⊕ deltas = fresh read" law.
- Metrics: bytes and time for a 60-second-offline return, and sequencer stall during a mass reconnect after a deploy.

**LOC.** Targets net ≤ 0. Deleted: `resumed/3`, the key-always-BOOT special case, and the duplicate encode path.

## 3. Dependency-scoped, evidence-carrying writes

**Gap.**
- `expect_rev` guards the target row only. An agent can act on a plan built from facts that have since changed. For example, it can stage an application using a headcount that a later citation superseded.
- A draft built on superseded figures stays unflagged.
- A `release` or lease close has no completion check against the ledger.

**Research.**
- Card 1579 PlanFence ([2609.03340](https://arxiv.org/abs/2609.03340)): plans cite the exact records they used and only that slice is validated before external action. A freshness-only executor acted on the obsolete plan every time. PlanFence completed all 30 workflows without an invalid action.
- Card 1367 Evidence-Carrying Termination: stop only when claims bind to in-scope evidence and a replay reconstructs them.
- Card 2312 Source-Judged Compaction: 83% of failed runs traced to an unsourced summary entry.
- Card 2235 Truth Maintenance System (Doyle 1979), cards 171 TEPA and 1606 MemoryLACE: retract consequences when a premise changes.
- Card 1826 NovaFabric: tamper-evident replayable evidence.

**Design.**
1. Reads return stamps of `(table, id, rev)`. `put` and `command` may carry `deps`. This generalises the `EXPECT_REV` op flag.
2. The judge compares each dep against the kernel's replica. That is O(deps) lookups, and the browser runs the same function. A stale dep is refused `stale_plan`, with `changed: [{table, id, col, was, now, source}]` in the diagnostic. The refusal belongs in the schema's `refusal` enum.
3. Agent-written prose (`battleplan`, `stage_notes`, message drafts) may carry a `basis` of cell refs. A reverse index in the kernel marks a draft *stale* when a basis cell is superseded. The focus lens shows it, and the MCP `hireme` overview lists stale drafts as the next step.
4. `release {report}` checks each claim that names a row against `op_ledger` and the citations. Unbacked claims are flagged in the audit trail.
5. Optional phase 3: a Merkle or hash chain over audit and citations, with a signed daily tree head.

**Gates.** Extend `agent_attack_test` with a stale-plan scenario (a stale dep never lands). Check that the dep validation costs microseconds.

**LOC.** Roughly neutral. It folds the separate prose-`rev` refusal and `EXPECT_REV` plumbing into one deps mechanism.

## 4. Reactive desk: standing queries as incremental views

**What already exists.**
- The kernel is partly incremental already. `heat.rs:500` keeps group totals plus a department × family `joint` matrix, so a role's similarity-weighted load reads a few cells, not the members.
- `Board::derive` (`board.rs:541`) is still a full O(N) pass: `cards.clear()`, a verdict for every card, then a nearly-sorted re-sort.
- MCP already has `resources/subscribe` on single rows and a listen stream (`mcp.ex:1225`, `:472`), but no query watches. Agents poll `find`.

**Research.**
- Card 1489 DBSP: Z-sets, with each query's incremental version defined as `Q^Δ = D∘Q∘I`.
- Card 858 Percolator: observer notifications.
- Cards 042 Rete and 1790 Nemo.
- Card 2287 TurnCost: turns drive agent cost.
- Card 1581 Speculative Macro Commit.
- Zero runs IVM on both client and server, per the third-party mirror I read.

**Design.**
1. A `watch` tool and URI (`hireme://watch/<hash>`), reusing the `find` condition grammar plus derived columns (score band, heat class, coverage, stale draft).
2. A new `watch.rs` keeps each watch's member set. Per delta it evaluates the touched ids plus the heat-group peers that `heat::Index` already knows. It emits enter and leave events through the existing listen stream, each carrying `rev` so the agent can use it as a #3 dep.
3. `lease {"watch": id, "count": n}` claims from the live frontier.
4. `Board::derive` moves to a dirty set. Delete the presort-keys trick and the full-clear scaffolding.
5. Gate: a property test that incremental equals recompute, matching your existing parity-by-construction style.

**Honest note.** The existing bounds (≤ 8 ms at 10k) may already hold. Measure derive at 10k and 50k before touching it. The main win is the `watch` feature, not speed.

## 5. A score that learns from your overrides

**Gap.** `docs/score.md` repeats that "a stored `score_100` is the correction". Every override is a free label, but nothing learns from it. The same mistake recurs on the next thousand listings, and `outcome` and `replied_on` never feed back.

**Research.**
- Card 859 Bao: keep the existing optimizer and learn which hint to apply, using Thompson sampling.
- Card 860 SkinnerDB: regret-bounded.
- Active ranking under Bradley–Terry: [Maystre & Grossglauser, ICML 2017](https://proceedings.mlr.press/v70/maystre17a.html) (repeatedly sort) and the information-gain pair selection of Li et al., NeurIPS 2018.
- The interpretable-feature approach of 2610.03112.
- I found nothing I could verify on conformal ranking, so I'm not citing it.

**Design.**
1. Keep the ladder as the prior. It already yields a score and named features (anchor, systems, remote, pay signal, CRUD, size tier, ATS vendor, coverage).
2. Fit a shrunk Bayesian linear residual on override minus suggestion. It updates in closed form per override, in microseconds with about 20 features. The learned weights live in a json cell like `settings.heat_config`.
3. A `learn` command writes the parameters with a citation, so wasm and the NIF agree. The UI shows them as editable adjustments with intervals ("your overrides taught: remote +4").
4. Hard kills stay untouchable and the kernel still only suggests.
5. A 5-card calibration deck picks the next card to ask about, using posterior variance near band boundaries.
6. Phase 3, measure first: a hierarchical reply-rate estimate per ATS × size tier. n is small, so show intervals and never auto-act.

**Gates.** Leave-one-out error on overrides, Kendall τ against your final ranks, and overrides needed to halve the error.

**LOC.** Net positive, so it needs a waiver or payback like #1.

---

## Considered, not top five
- **Columnar codecs:** [ALP](https://duckdb.org/library/alp/) (SIGMOD 2024) for the `f64` metrics, FSST for names and URLs. I didn't re-verify FSST, FastLanes or BtrBlocks this session. Measure BOOT composition first.
- **Deterministic simulation harness:** It would pair with #2. [TigerBeetle's VOPR](https://docs.tigerbeetle.com/about/vopr) runs production code under seeded faults. Your kernel is pure and each account has a single sequencer, so it fits, but I found no 2026 evidence of it being standard for app servers.
- **Row-scoped, expiring sub-keys** for sub-agents (card 1767 CapScope).
- **Agent proposals as a reviewable branch** (card 1581, [Git4Data](https://arxiv.org/abs/2609.02106) from search results). Your FIRE HOLD already covers much of this.
- **Code-mode query tool:** Savings are mostly vendor-reported.

## Order and dependencies
Build #3 first. It is cheap, near net-zero, and its dep stamps feed #4 and #5. Then #2, which deletes code and fixes agent reconnects. Then #1, the biggest product leap. #4 and #5 follow. The open decision is whether #1 and #5 get an LOC waiver or a named payback under your bound.

I haven't changed any files. For a team run, I'd follow your `AGENTS.md` rule and brief each worker with your words verbatim. That is up to 6 workers, no Fable. Say the word, or tell me which candidates to start with.

Sources: [RBSR (Meyer)](https://arxiv.org/pdf/2212.13567) · [RBSR order-statistics stores](https://arxiv.org/abs/2603.19820) · [Self-sizing IBLTs](https://arxiv.org/abs/2608.26537) · [Willow RBSR](https://willowprotocol.org/specs/rbsr/index.html) · [Zero docs mirror](https://zero.rocicorp.dev/llms.txt) · [MUVERA](https://arxiv.org/abs/2405.19504) · [potion-retrieval-32M](https://huggingface.co/minishlab/potion-retrieval-32M) · [Interpretable matching 2610.03112](https://arxiv.org/abs/2610.03112) · [Resume Tailor 2605.05257](https://arxiv.org/abs/2605.05257) · [ConFit v3](https://arxiv.org/abs/2605.09760) · [Active ranking (Maystre)](https://proceedings.mlr.press/v70/maystre17a.html) · [ALP](https://duckdb.org/library/alp/) · [TigerBeetle VOPR](https://docs.tigerbeetle.com/about/vopr) · [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog) · [Git4Data via search](https://databricks.com/blog/database-branching)
