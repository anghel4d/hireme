# Sonnet researcher planset (revised 2026-10-20)

This replaces the first planset (commit 4fdcf48, still in git history). It was written after reading about 25 papers in full text, opening cards over the Observer MCP, and running three small experiments on 900 real job listings. The five candidates changed because of that reading; the section "Corrections from reading" lists what the first version got wrong or overstated.

## How this was gathered

- **Observer MCP** (https://observer.anoptic.io/mcp, one stream, one call about every 30 s after a Cloudflare 1015 early on): 63 `query_seeds` queries and 20 `get_seed` calls in the final stream (no rate-limit errors in it), plus about 35 early queries before the Cloudflare 1015. Its multi-word queries mostly return nothing, so most card reading was from the same catalog's `cards.json` (2,360 cards). `get_seed` returns the card's original markdown; `cards.json` is its parse.
- **Papers**: full text from arXiv HTML (or `pdftotext` for 2605.05257), then read by section or searched with grep; the list is at the end.
- **Code**: every "gap" below cites a file and line in the shared working tree on 2026-10-20 (HEAD 4fdcf48 plus other lanes' uncommitted edits, so line numbers drift).
- **Experiments** (listed under "What I measured"): the scripts live in the session scratchpad, not in the repo.

## Corrections from reading

1. **PlanFence matches centralized lineage on correctness; its edge is stall time.** Both completed 30/30 live tasks with no invalid action and one replan each; the freshness-only executor failed all 30. PlanFence's advantage is lower stall once owner updates outpace protected actions (it reports 1.5–7.1x below the better of synchronization and a central service). Its v2 title is "Derivation Currency for Distributed LLM-Agent Memory"; the Observer card still carries the v1 title ("Dependency-Scoped Validation"). In hireme the authoritative replica is local to the sequencer, so the stall argument does not apply; only the derivation-currency idea does.
2. **2610.03112's 95.79% is non-blinded, and seniority is the weak axis.** Recruiters saw the system's prediction before recording a value, only selected cases were recorded (927 values from 114 candidates), and the student agreed on 888 of 927. Seniority Alignment was 86 of 120 (71.7%) and carried 34 of the 39 disagreements. The same paper reports the student's fidelity to its LLM teacher at macro-F1 0.849 against 0.669 for the frozen encoder.
3. **Resume Tailor (2605.05257) has n=9, one candidate, and its own fit metric.** Its "hybrid" scores dense hits (0.6 x cosine + 0.4 x fuzzy `partial_ratio`) and the authors say it is not a true sparse-plus-dense retriever. Its provenance is internal tagging with no user-facing check and no evaluation. The +7.8 and -8.0 averages are over six and two postings.
4. **RBSR has not been peer-reviewed.** Meyer's arXiv draft (2212.13567) says so on its first page. It also needs a logarithmic number of rounds even when the difference is one item.
5. **My first plan said IDF would fix hireme's keywords. Tested, it does not.** See "What I measured".
6. **A search snippet misstated "The Bitter Lesson of Tool Calling" (2608.06370).** The abstract says programmatic tool calling matches or exceeds JSON tool calling in 11 of 14 models on BFCL v4 and matches or outperforms it in 13 of 14 under parallel fan-out. It does not say "half the wall-clock".
7. **The IBLT paper (2608.26537) is about periodic consistency verification between two databases**, with one O(N) scan per run. It is not live sync. I dropped it from the sync plan.
8. **S-Bus (2605.17076) can observe only 26.1% of single-step references over HTTP on its PH-2 workload (hidden-read probability 0.739; 0.074 on its PH-3 workload)**, and the authors bound genuine-causal coverage at 70% or less. Server-observed reads are a floor, not the read set.
9. **Observer card 2235 (Truth Maintenance System)** says itself it was written from the abstract plus secondary descriptions.
10. **Model2Vec numbers for retrieval are for English.** Its multilingual model is 0.1B parameters in F32 (roughly 0.4 to 0.5 GB) and cannot ride a browser cold load as is.

## What I measured

900 public engineering listings from 15 Greenhouse boards (fetched 2026-10-20; title filter for engineer, developer, scientist, researcher, architect, SRE, infrastructure; sales, support and management titles excluded). I re-implemented `keywords.rs` `extract` (fold, split on non-alphanumeric except `+ # .`, STOP list, 3-character minimum, dotted-word rule, top 12 by count, ties by bytes). The tech-term list is mine (about 150 terms); precision and recall against it are a proxy, not ground truth, and the sample is large tech companies only.

| Scheme | Share of the 12 words found in 30% or more of all listings | Tech-term precision@12 | Tech-term recall@12 |
| --- | --- | --- | --- |
| hireme (top 12 by count) | 0.73 | 0.04 | 0.08 |
| tf-idf | 0.04 | 0.04 | 0.08 |
| bm25 | 0.00 | 0.02 | 0.03 |
| tf-idf, df between 5 and 30%, tf 2 or more | 0.00 | 0.05 | 0.09 |

- A listing names a mean of **6.7 distinct tech terms** (881 of 900 name at least one), mostly once or twice each. No frequency or IDF top-12 selects them; a skill lexicon would.
- `counts()` drops every token under 3 characters except those with `#`. Over the 900: **"ai" appears in 847, "go" in 357, "ml" in 187, "ci" in 173, "c" in 69, "r" in 32.** Those never become keywords or targets.
- Structure is there to use: median 987 words, median **21 `<li>` bullets** (892 of 900 have 5 or more), 732 of 900 have a requirements-style heading, 759 of 900 a nice-to-have marker. Greenhouse HTML only; markdown and plain-text listings will be rougher.

- Labelling each bullet by the nearest preceding bold or heading text (a crude regex classifier of mine): across 18,977 bullets, bullets under a requirements-style heading carry 0.61 tech terms each, nice-to-have 0.49, responsibilities 0.34 and unclassified 0.38. Requirement bullets hold 30% of all tech-term mentions and unclassified ones 37%, so heading structure sharpens weighting but is not enough alone.

The result is stable: four random 900-listing samples gave a boilerplate share of 0.72 to 0.73 for hireme's method, 0.04 for tf-idf and 0.00 for bm25, and proxy recall of 0.08 for hireme and tf-idf (0.03 for bm25) in each.

The conclusion for fit: what the listing's keywords should be is a small, named set of skills and requirement lines, extracted by lexicon and structure. Statistical keywording of any kind is the wrong tool.

## Verified gaps in the code (used below)

- `sequencer.ex:436` resumes a session only when `snapshot_rev == state.rev` exactly and only for the operator's session; a key always gets a full BOOT. `resumed/3` (`:1706`) sends empty blocks. After every write `settled/2` (`:692`) sets `rows: nil, blocks: nil`, so the next joiner re-reads and re-encodes every resident table. The sequencer keeps no history of its deltas, and a node restart would empty any in-memory one, so a change log has to be persisted.
- `rev` advances by the number of acknowledged ops in a turn (`rev = state.rev + turn.acked`, `:671`). `op_ledger` (`schema/hireme.schema:291`) keeps `(subject, row_id, ack_rev)` for 24 hours: the start of a change log, but with no cascades and no server-side writes.
- MCP `put` and every command mint their own `op_id` from a per-session counter (`mcp.ex:954`, `next_op`) and the tool schemas take no client key (`tools.rs`). A retried call after a timeout is a new op, so the ledger's resend answer never engages. Natural-key puts and exact restatements are safe; an append-only `note` command or an insert into a table with no natural key is not (by schema inspection: `events.op_id` has no unique index; I did not run a retry).
- `find` is single-table over stored columns (`tools.rs:160`); the overview shows the top N cards with `band` and `class` (`compose.rs:212`), but an agent cannot filter or order by band, heat class, coverage or anything derived.
- `Board::derive` (`board.rs:541`) is a full O(N) pass per change; `heat.rs:500` is already incremental (group totals plus a department-by-family `joint` matrix). `Moved` (`rows.rs:565`) already reports per-table written and deleted ids per frame.
- Step-up is a generic 5-minute freshness window (`SECURITY.md:349`); the passkey challenge is random, not bound to the pending effect.

## The five, revised and ranked

Ranked by leverage on the product; the build order differs and is under Order.

### 1. Skill-aware fit in the kernel (lexicon first, models only if measured)

**What it replaces:** keywords-by-frequency and whole-term coverage (`keywords.rs`, `coverage` at `:309`). This is a deterministic kernel function, not agent RAG: no LLM sits on that path. Today coverage is read only by the focus lens (`focus.ts:91`) and the MCP document; `score.rs`, `heat.rs` and `board.rs` do not read keywords, so the gain is in CV tailoring and fit judgment, and whether fit should ever move the Life-EV score is the operator's call (the ladder is deliberately not a fit score).

**Evidence.**
- My measurements above: the frequency method is 73% boilerplate, IDF alone does not recover skills, 2-letter skills are discarded, listings have extractable structure.
- 2610.03112 (EMNLP 2026): eight named matching dimensions (title match, industry experience, certifications, hard-skill experience, skill proficiency, experience recency, seniority alignment, skill context), a CPU bi-encoder distilled from an LLM labeler. Non-blinded; weakest on seniority.
- PJB (2603.17386): a generic embedding (Qwen3-Embedding-0.6B) scored nDCG@10 0.0592 against 0.2070 for the in-house model; reranking was the only module that helped the in-house model (+0.0184) and query rewriting hurt. Domain differences dominate module differences.
- "Is Grep All You Need?" (2605.15184): on a 116-question LongMemEval sample grep generally beat vector retrieval for agents, though not uniformly (Chronos vector beat grep at the 5-session configuration, 87.9 to 94.0% against 83.2 to 89.7%). Agents can already substring-`find`; this plan is for the kernel's own matching.
- ConFit v3 (2605.09760): LLM rerankers trained with listwise RL beat GPT-5 and Claude Opus 4.5 on proprietary person-job datasets where under 0.05% of (resume, job) pairs are labeled. Hireme has no such data, so its reranker is the leased agent at inference, not a trained model.
- Skill normalization to a taxonomy follows embedding retrieval then LLM verification (ESCO papers 2601.09119, SkiLLink); HyST (2508.18048) pairs hard filters with embeddings. Static embeddings: potion-base-8M is 7.56M params, retrieval score 31.11; potion-multilingual-128M scores 37.86 but is about 0.1B params in F32; MiniLM is 42.92 (model cards).
- Observer: card 276 (floating-point determinism): keep the arithmetic integer or `libm`. `lib.rs:10` already does.

**Design.**
1. **L0, no model weight.** A skill lexicon with aliases and a short-token allowlist ("ai", "go", "ml", "ci", "c", "r" admitted when in the lexicon), seeded from the operator's own CV `items.keywords` and from a public taxonomy, plus df-banded discovery of terms not in the lexicon. Requirement lines are the `<li>` bullets under requirements-style headings, split must-have from nice-to-have by marker. Targets become about 7 named skills plus requirement lines, not 12 frequent words.
2. **L1, only if L0's recall on the eval set is short.** An int8 static embedding table with vocabulary pruned to the operator's languages (the English Model2Vec recipe goes 92 MB to 6 MB per the minish.ai size post, snippet only, not re-verified). Integer dot products keep wasm and the NIF identical. Derived at BOOT like the board, so no wire change.
3. **L2, named requirement-to-atom mapping.** For each requirement line, the best CV atom (an `item`) by lexical then semantic score, with the score shown and returned to agents. The CV composer picks atoms to cover requirements under the length budget (greedy; the standard (1 - 1/e) bound applies to monotone submodular coverage, which I did not find a resume-specific paper for). It must respect lineage: `cv.rs` forbids rewording what an earlier application of the same company sent.
4. **Gate by confidence.** Resume Tailor's boundary result (a gain when prior experience matches, a loss when the domain is absent) argues for abstaining: below a margin, return "uncertain" and let the agent judge, then store its cited verdict. Those become the labels for per-dimension heads later (the 2610.03112 recipe with the operator's own agents as labelers).
5. **MCP.** `find` gains a lexical `match` operator; a fielded `search` tool only if the eval shows agents need more than grep.

**Eval first.** 200 operator-judged (listing, CV atom) pairs plus the 900-listing set; metrics: requirement recall, nDCG@10, latency per application at 10k listings under 5 ms.

**Risks and LOC.** Multilingual listings (the atlas covers many countries) need per-language lexicons; nothing in my measurements covers non-English text. Net-positive LOC (a lexicon and mapping replace `extract`'s heuristics and `STOP`); needs an explicit waiver or a named payback under the LOC bound.

### 2. The agent write contract: idempotency key, derivation currency, completion receipts

**Gaps.** The retry duplicate path above; `expect_rev` guards only the target row (`write.rs:47`); nothing records what an agent's decision was derived from; a lease release does not check the agent's report against the ledger.

**Evidence.**
- Limbo, "Where Does Exactly-Once Live?" (2609.29095): 25,930 episodes; when a write is still in flight or delivered twice the contract explains 81% of the variance and frontier models duplicate in 56% and 74% of episodes; an idempotency key on every write lowered the duplicate rate from 28% to 4% because agents use keys when they exist.
- The Limbo discussion (read in full) argues for a standard idempotency-key argument on non-idempotent tools, a declared read-back with documented visibility, and one key pinned per intent so a model cannot defeat the key by regenerating it on a retry; a read-back that cannot see in-flight effects was worse than none. Hireme's reads answer from the sequencer's kernel at the new rev, so read-your-writes holds by construction.
- PlanFence (2609.03340, see correction 1), Table 1(a): session read tracking detected all 30 changes after same-session planning but missed all 30 inherited conflicts after a handoff to a session that had not read the old inputs; supplying the inherited versions fixed it (30/30). It does not ask the model what it depended on, and it notes that derivation currency does not imply semantic correctness (28 of 30 recorded decisions were correct on unchanged inputs).
- S-Bus (2605.17076): a server-side log of delivered reads reconstructs an approximate read set (26.1% of single-step references on one workload; correction 8). Taming Cognitive Transactions, TCT (2609.20261): typed dependency tokens separate content integrity from applicability; mean commit overhead 3.22 ms in the paper's prototype; a falsification suite prevented all injected anomalies. CoAgent (2606.15376): let the agent judge whether a conflicting write invalidates its plan and repair it; within 5% of serial correctness at 1.4x speedup on its ten workloads.
- Atomix (2602.14849), discussion section: adapter metadata (scopes, idempotency keys, compensation handlers) is safety-critical; a too-narrow declared scope let 66 of 200 invariant violations commit, and a wrong effect class leaked 17 of 200 irreversible actions. So the dependency frontier should be derived from what the judge actually reads for that command, never declared by the agent alone.
- MasuGate (2608.02764) names stale authorization; hireme's single sequencer already judges policy (heat, fire hold) against current state at commit, so that part is satisfied by construction. The remaining gap is the derivation of content writes.
- ECT (2608.23623): 0/288 unsafe completions against 252/288 for a termination critic, on 48 synthetic tasks, single author. Supporting only.

**Design.**
1. **Optional client key** on every write tool (no server-derived default, because two identical `note`s in one session can be intentional; the tool description tells the agent to pin one key per intent and reuse it on retry): `op_id = hash(key_id, key)` into the existing `(writer, op_id)` ledger so a retry across sessions is answered from it with `replayed: true`. This is the cheapest change in this planset and the best supported.
2. **Reads stamp, the server logs, and stored plans carry their inputs.** `find`, `get`, `text` return `(table, id, rev)` stamps and the MCP session keeps what it delivered. A write may carry `deps`; the judge also treats the session's delivered stamps as implicit deps for the cells that command's verdict reads (the action-specific frontier). Session-delivered stamps cover only the session that did the reading; a draft or plan another session picks up later needs its `basis` revs stored with it (item 3), which is the handoff case PlanFence measured. A moved dep is refused `stale_plan` with `{table, id, col, was, now, source}` so one repair turn suffices (CoAgent's advisory repair). The browser runs the same function on operator edits.
3. **Stale drafts.** Agent-written prose may carry a `basis` of `(table, id, col, rev)` references, the revs the agent read (a json cell, per the fat-table rule); a reverse index in the kernel marks the draft stale when a basis cell is superseded; the `hireme` overview lists stale drafts as the next step.
4. **Completion receipts.** `release {report}` checks each claim that names a row against `op_ledger` and the citations; unbacked claims are flagged in the audit trail.

**Gates.** Extend `agent_attack_test` and `session_test`: a retried `note` writes one event; a stale dep never lands; dep validation microseconds at 10k rows.

**Risks and LOC.** `EXPECT_REV` is one fixed `u32` in the op header (`wire/src/lib.rs:89`), so `deps` needs a variable field or a sibling block. Roughly neutral: it folds `EXPECT_REV` plumbing and the prose-`rev` refusal into one mechanism.

### 3. Delta-resume sync: BOOT is the delta from nothing

**Evidence.** Gaffer's State Synchronization (card 331): snapshots delta-compressed against an acknowledged baseline and prioritized. Quake III (Observer card 412, via `get_seed`): deltas against the last acknowledged snapshot, and a snapshot whose delta base is too old or missing is discarded rather than applied corrupt. Viewstamped Replication Revisited (card 862): recovery by log suffix or full state transfer. Electric and Replicache cursor-and-must-refetch practice (search snippets, secondary). The record from sync-engine practice: tombstones bound the window, and a timestamp delta misses joined-field changes (derived values here are client-derived, so only base rows need deltas).

**Design.**
1. A persisted change log, written in the sequencer's own transaction: `(account, rev_end, table, row_id, gone)`, bounded by the schema's `cap` rule. In memory is not enough: a deploy restarts the BEAM, which is the case this plan must cover. `op_ledger` is the seed but misses cascades and server-side writes (keywords backfill, purge).
2. HELLO already carries `snapshot_rev`. At or above the log floor, send one coalesced PATCH of current rows changed since, read from the kernel cache; else BOOT. BOOT becomes the same path with `snapshot_rev = 0`; delete `snapshot`/`resumed` duality.
3. Keys resume too, with a hash of effective grants in HELLO so a mask change forces a BOOT (`BYE grants` already does).
4. Stop invalidating the whole resident cache on each write (`settled/2`): patch the cached blocks by the turn's deltas.
5. **Not recommended:** RBSR or IBLT reconciliation. RBSR is a draft needing log-many rounds (about 4 round-trips at 50k rows for a branching factor of 16, my estimate; close to a 2 MiB BOOT on a good link), and IBLT is built for verification. The repo's own principle (a fat first load) is compatible with a BOOT fallback.
6. Stretch: with idempotent resend already in the ledger, QUIC 0-RTT (RFC 9001 warns about replay) could carry a resume HELLO. I found no authoritative source on WebTransport 0-RTT in browsers.

**Gates.** Property test: resume from any rev in the window equals a fresh read, with random disconnect points (extends the base-plus-deltas law). Metrics: bytes and time for a 60-second-offline return; sequencer stall during a mass reconnect after a deploy.

**LOC.** Targets net 0 or less: the log table and a read path (small) against `resumed/3`, the key-always-BOOT special case, the duplicate encode and the per-write cache reset.

### 4. A turn-thrifty, reactive agent surface

**Gap.** Agents poll `find`, cannot filter by derived state, and need one tool call per read.

**Evidence.** TurnCost (2610.15093; the paper stops short of showing turns can be removed with success fixed): across 600 coding-agent trajectories turn count explained 84% of log cost variance against 4% for mean observation size, and 98.6% of input tokens were cache hits. Percolator (card 858): observer notifications cut mean document age about 50%. Commit-window observation contracts (card 1853): inside one commit window observers see at most one net-effect delta per cell, which licenses coalescing; hireme's sequencer turn is that window. Programmatic tool calling: matches or exceeds JSON calls in 11 of 14 models (2608.06370; its benchmark returns echo stubs, so it measures argument serialization, not end-to-end correctness); code-execution MCP cuts tokens and latency but adds 16 attack classes (2602.15945); in the grep study, programmatic tool delivery collapsed one model-harness pair from 93.1% (inline grep) to 55.2% (2605.15184); a bash-only agent beat typed tools by 21.8 to 24.5 points on one enterprise benchmark while a fixed-catalog programmatic mode used fewer tokens than typed calls but scored below bash (2609.11999). The MCP Triggers and Events Working Group (charter 2026-03-24) is still ideating on server push, so hireme's existing `notifications/resources/updated` and listen stream are already ahead of the spec.

**Design, in order, stop when the measured turn count stops improving.**
1. **Derived columns in `find`:** band, heat class, coverage percent, stale, freshness verdict; filter and order by them. The kernel already derives them for the cards (`Board`); wiring them into `find` is the work; each is visible only to a key whose masks already cover the domains it reads (desk for band and class, corpus for coverage).
2. **`watch`:** a tool and a `hireme://watch/<hash>` URI over the `find` grammar. A new `watch.rs` consumes `Moved` and the heat-group peers `heat::Index` already knows, and emits enter and leave once per turn with `rev` (usable as a #2 dep). `lease {watch, count}` claims from the live frontier.
3. **`Board::derive` as a dirty set,** but only after measuring derive at 10k and 50k; `heat.rs` is already incremental, so the main gain is `watch`, not speed. Adapton (card 1466) suggests going one step further: refresh only the cards a lens or a watch actually reads, not every dirty one.
4. **A restricted program tool** (a hermetic interpreter over `find`/`get`/`put` with step and output limits, running in the NIF under the key's masks) only if 1 to 3 leave agent turn counts high. I did not verify a Rust interpreter's resource-limit API.

**Gates.** A property test that watch membership equals recompute; a turn-count comparison on a recorded agent session replayed in the harness described under Order, before and after.

### 5. A score that learns from the operator's overrides

**Gap.** `score.md` repeats that "a stored `score_100` is the correction", yet no override teaches the next suggestion. Weakest evidence of the five: I found no 2026 paper on learning from overrides.

**Evidence.** Observer cards 859 (Bao: steer an existing optimizer with learned hints chosen by Thompson sampling) and 860 (SkinnerDB: regret-bounded); Maystre and Grossglauser, "Just Sort It!" (ICML 2017): repeated sorting as active learning under Bradley-Terry; Li et al. NeurIPS 2018 information-gain pair selection. Application outcomes: no controlled audit study on tailoring or ATS keyword matching found; the vendor figures I met are self-reported.

**Design.** Keep the ladder as the prior. Fit a shrunk Bayesian linear residual on (override minus suggestion) over the ladder's named features; closed-form update per override. A `learn` command writes parameters with a citation into a json cell so wasm and the NIF agree. The lens shows them as editable adjustments with intervals. Hard kills stay untouchable; the kernel only suggests. An optional 5-card calibration deck asks the operator the highest-uncertainty comparison. Reply-rate modelling per ATS and size tier stays measure-first: n is small.

**Gates.** Leave-one-out error on overrides; Kendall tau against the final ranks; overrides needed to halve the error. First step: count the overrides that exist.

**LOC.** Net-positive; needs a waiver or payback.

## Order

First, a small replayable agent-session harness in the style of Limbo (2609.29095) and TurnCost's re-scoring (2610.15093): record one agent session against a bench node, inject a timeout and a duplicate delivery, and grade against `op_ledger` and `events`. Without it, #2 and #4 cannot be shown to help. `test/support/mcp_case.ex` and `agent_attack_test` are the starting point. The audit trail records writes only (`agent_ops`), and routine persistent diagnostic logging is not wanted in production, so the harness records reads and turns inside the test process.

Then #2 (cheapest, best supported; its stamps feed #4 and #5). #3 and #1 can run in parallel lanes (different files). Then #4, then #5.

## Considered, not top five

- **Columnar codecs:** ALP (SIGMOD 2024), FSST (VLDB 2020; OptFSST at ADMS 2026). The wire already shuffles and zstd-packs with dictionaries and columns are dense with null sentinels, so the win depends on BOOT composition, which I did not measure.
- **Deterministic simulation harness:** TigerBeetle's VOPR. No 2026 evidence found that it transfers to application servers; the kernel's purity and one sequencer per account fit it.
- **Effect-bound step-up** (2610.21063, Oct 2026 preprint, no human data): bind the passkey challenge to the key's masks instead of a 5-minute freshness window. The same paper found a second device added nothing measurable over an on-host confirmation.
- **Ghost-listing liveness** from posting age and repost patterns: Ng (2410.21771) estimates up to 21% of ads may be ghost jobs; the feature definitions are not in the abstract and the other figures I found are vendor-reported.
- **Merge instead of refuse for prose edits** (Eg-walker, EuroSys 2025, arXiv 2409.14252): a `put` of a long text refused `rev` could be three-way merged when the edits do not overlap. The paper reports about an order of magnitude less steady-state memory than existing CRDTs and orders-of-magnitude faster loading; I did not read it past the abstract, and hireme's compare-and-swap refusal is a deliberate rule today.
- **No research found for the heat governor's premise** (that mass applying degrades response): I found no peer-reviewed measurement; the figures I met were unsourced industry claims.
- **Proposals as a reviewable branch** (card 1581; Git4Data 2609.02106, search snippet only): FIRE HOLD already covers most of it.

## Convergence with the parallel SOTA research

After finishing the plans above I looked, and only looked, at the section headings of the parallel run's notes in this directory and at its idempotency passage, to keep the two plansets independent. It reached the same finding on idempotency from the other direction: its agent and MCP security note says `put` has no client-supplied idempotency field and proposes an optional client key mapped to `op_id` through the existing 24-hour ledger, and adds that under MCP 2026-07-28 broken streams are re-issued as new requests, so a retry is a new request (I did not verify that claim). Its headings also show sections on replacing exact-token coverage with skill and requirement extraction, on learning one person's preferences from small data, on ghost and duplicate listings, on incremental derivation, and on columnar encoding of the replica: the same questions as my #1, #5, the ghost-listing item, #4 and the codec item. Where the two disagree, trust whichever cites a primary source for the specific claim; I did not read their bodies.

## Feedback for the Observer catalog

My text search of the 2,360 cards found 2 mentioning BM25, 2 reranking, 0 learning-to-rank, 0 inverted-index and 1 dense retrieval. `radar/topics.yaml` is anchored on the Anoptic engine, `ano` and agents, which explains it. Retrieval and ranking, replication and sync, and columnar or string compression are the three topics that would have changed this research most.

## What I read, exactly

**Observer, opened with `get_seed` (the card's full markdown):** 1579, 2312, 1367, 1233, 092, 064, 1489, 412, 858, 1581, 859, 2287, 2314, 1853, 331, 1466, 053, 860, 1790, 042.
**Observer, sections from `cards.json` (takeaway, why, ideas, caveats; each cut at 900 to 1600 characters):** 2257, 1767, 1626, 1581 (also via `get_seed`), 2235, 171, 1606, 1826, 065, 1803, 1018, 1449, 1541, 862, 868, 265, 276, 210, 2314, 1366, 1853, 219, 1466, 331 (2314, 1853, 331 and 1466 were later opened with `get_seed` too).
**Observer, takeaway line only:** 197, 269.

**Papers, read past the abstract (arXiv HTML, or PDF text for 2605.05257), by section or grep rather than line by line:** 2609.03340, 2610.03112, 2605.05257, 2212.13567, 2405.19504, 2603.17386, 2609.29095 (discussion), 2605.15184 (results), 2608.06370 (limitations), 2606.15376 (setup), 2605.17076 (results table), 2602.14849 (discussion), 2609.20261 (definitions, overhead), 2610.15093, 2602.15945 (results sentences), 2605.09760 (tables), 2610.21063 (abstract), 2608.26537 (scope, limitations), 2608.23623, 2610.20927.
**Papers, abstract only (full text downloaded, not read):** 2608.13900, 2608.18092, 2608.02764, 2609.11999, 2603.19820.
**Not read, search snippet or fetched summary only:** 2508.18048 (HyST), 2603.09933, the potion and Model2Vec size figures, Zero, Electric and Replicache practice, the ESCO skill papers, Git4Data, FSST and ALP, TigerBeetle, MoQT, 2410.21771, Maystre 2017, Eg-walker.

My first report to opus-noether listed papers as "read as arXiv HTML full text, searched and sectioned"; for the "abstract only" group above that was an overstatement, and this section replaces it.

## Sources

[MUVERA](https://arxiv.org/abs/2405.19504) · [RBSR (Meyer)](https://arxiv.org/abs/2212.13567) · [RBSR order-statistics stores](https://arxiv.org/abs/2603.19820) · [Self-sizing IBLTs](https://arxiv.org/abs/2608.26537) · [PlanFence](https://arxiv.org/abs/2609.03340) · [S-Bus](https://arxiv.org/abs/2605.17076) · [CoAgent](https://arxiv.org/abs/2606.15376) · [Cognitive Serializability / TCT](https://arxiv.org/abs/2609.20261) · [MasuGate](https://arxiv.org/abs/2608.02764) · [Atomix](https://arxiv.org/abs/2602.14849) · [Limbo: Where Does Exactly-Once Live?](https://arxiv.org/abs/2609.29095) · [ECT](https://arxiv.org/abs/2608.23623) · [Interpretable resume-vacancy matching](https://arxiv.org/abs/2610.03112) · [Resume Tailor](https://arxiv.org/abs/2605.05257) · [PJB](https://arxiv.org/abs/2603.17386) · [HyST](https://arxiv.org/abs/2508.18048) · [Is Grep All You Need?](https://arxiv.org/abs/2605.15184) · [TurnCost](https://arxiv.org/abs/2610.15093) · [Bitter Lesson of Tool Calling](https://arxiv.org/abs/2608.06370) · [CE-MCP](https://arxiv.org/abs/2602.15945) · [Is Bash All You Need?](https://arxiv.org/abs/2609.11999) · [Approve What, Exactly?](https://arxiv.org/abs/2610.21063) · [Ghost jobs (Ng)](https://arxiv.org/abs/2410.21771) · [potion-multilingual-128M](https://huggingface.co/minishlab/potion-multilingual-128M) · [potion-base-8M](https://huggingface.co/minishlab/potion-base-8M) · [potion-retrieval-32M](https://huggingface.co/minishlab/potion-retrieval-32M) · [Model2Vec size post](https://minish.ai/blog/2025-10-05-size-blogpost/) · [Maystre and Grossglauser](https://proceedings.mlr.press/v70/maystre17a.html) · [ALP](https://duckdb.org/library/alp/) · [FSST](https://www.vldb.org/pvldb/vol13/p2649-boncz.pdf) · [TigerBeetle VOPR](https://docs.tigerbeetle.com/about/vopr) · [MCP 2026-07-28 changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog) · [MCP Triggers and Events charter](https://modelcontextprotocol.io/community/triggers-events/charter) · [Greenhouse job board API, as fetched](https://boards-api.greenhouse.io/v1/boards/anthropic/jobs?content=true)
