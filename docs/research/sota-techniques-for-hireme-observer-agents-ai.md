# SOTA techniques for hireme from the Broadside Observer corpus: agents, LLM systems and game AI (2024-2026)

Score scale (researcher's judgement, not from any source): **I** = expected impact for the operator or the leased agents; **F** = feasibility under the constraints the brief states ("every UX interaction must be as fast or faster than before (sub-10 ms, measured)", "every control surface needs robust MCP integration", "commits aim to net zero or fewer lines (replace, don't add)", "deterministic, one kernel judges everything"); **N** = novelty of the technique in the field (5 = 2025-2026 frontier, 3 = established 2019-2024, 1 = textbook).

Conventions:
- **Card citations.** `[obs:NNNN](https://observer.anoptic.io/mcp)` is the Observer card whose MCP `get_seed` id starts with NNNN. Full ids are in the table in section 1.
- **Seen via.** "MCP" means fetched with `get_seed` from the hosted MCP on 2026-10-20: 87 cards, each byte-identical after trimming to the local mirror. "mirror" means seen only in the local mirror at `broadside-observer/seeds/cards` (a local clone) (same commit).
- **hireme facts.** Read at HEAD 4fdcf48, read-only. Links are relative to this file.
- **Overlap.** Candidate 3 of [sonnet-researcher-planset.md](sonnet-researcher-planset.md), "Dependency-scoped, evidence-carrying writes", already proposes shortlist item #7 below from the same cards. #7 is kept here with abstract-verified numbers; the other eight items are not in that planset.

## 1. Which Observer cards describe techniques that hireme's leased agents, MCP surface, provenance model or human-in-the-loop workflow could adopt?

### Takeaway
The corpus is rich here: 239 agents-pool cards, 136 of them from 2026 and 108 with Aug-Oct 2026 arXiv ids. Its consistent message is that agent reliability is decided by the harness and the server, not the model:
- an approval must bind the exact effect it approves ([obs:2314](https://observer.anoptic.io/mcp));
- the server must turn silent failures into loud ones ([obs:1144](https://observer.anoptic.io/mcp), [obs:2244](https://observer.anoptic.io/mcp));
- turn count, not output size, drives agent cost ([obs:2287](https://observer.anoptic.io/mcp));
- a plan must be fenced by the records it used ([obs:1579](https://observer.anoptic.io/mcp));
- humans should read ledger-derived reports, not agent prose ([obs:2313](https://observer.anoptic.io/mcp)).

hireme already does much of this: key masks as capabilities, FIRE HOLD as a deterministic human gate, rustc-style refusals, fenced untrusted text, and typed rows with citations. Four gaps are verified in the code:
- `open_fire` binds no content;
- write ACKs carry no derived state and no warnings;
- refusal telemetry records counts but no codes;
- an agent's read set is never validated.

### Cited Findings
#### Method and coverage
- **Live calls.** The hosted MCP answered five live `query_seeds` calls normally: "agent" 206 hits, "agent computer interface" 20, topic `rag` 45, "memgpt" 11, "zzzqqq" 0 — [Observer MCP](https://observer.anoptic.io/mcp)
- **Blocked sweep.** A scripted sweep through Python's urllib then got HTTP 403 on all 16 attempts, while curl kept getting HTTP 200. Following the coordinator's rule, the sweep moved to the local mirror and the MCP was used only for `get_seed` confirmations, at 0.5 requests per second — [Observer MCP](https://observer.anoptic.io/mcp)
- **Local emulation.** I emulated `query_seeds` locally: tokenized AND, substring match over title, authors, topics, one-sentence takeaway, lineage, venue and cited-work titles. It reproduces the live counts exactly for 3 of the 4 calibration queries and gives 205 against 206 for "agent". The tool's own description lists only title, authors, topics, takeaway and lineage, but the live counts show that cited-work titles are searched too — [Observer MCP tools/list](https://observer.anoptic.io/mcp)
- **Corpus.** 2,360 cards. The in-scope pools are agents 239, game-ai 102 and realtime 85. The rest are maths-foundations 630, graphics 385, languages 384, systems 336, engines 172, plus small pools — mirror (`broadside-observer/seeds/cards`)
- **Reach.** All 426 in-scope pool cards were returned by at least one of the 773 sweep queries.
- **Outside the three pools.** Only 17 cards touch LLMs, agents or tokenization, some only marginally: 1019, 1020, 1021, 1198, 1626, 2268, 2289, 2295, 2316, 2317, 2318, 2331, 2252, 2351, 860, 936 and 955. The 372 `ai-generated-math` cards are AI-produced mathematics, which is another researcher's lane.
- **No curiosity cards.** The `curiosity` topic (114 cards) is a daypart label on maths, graphics and languages curiosities, not curiosity-driven exploration. No card covers intrinsic-motivation exploration.
- **Agents pool skew.** Within the agents pool the largest topics are `agentic-llm-serving` 60, `rag` 45, `agent-failure-localization` 41, `retrieval` 36, `deepseek` 28 and `harness` 23. Smaller ones include `provenance` 22, `continual-agent-skills` 22, `provenance-first-agent-memory` 20 and `tool-use` 13. The coverage log below gives every count.

#### Coverage log (every query run, with its hit count)
**Live MCP calls on 2026-10-20 (UTC)**
- `tools/list`: 1, OK.
- `query_seeds`: "agent computer interface" (limit 5) 20; `topic=rag` 45; "agent" (limit 50) 206; "memgpt" 11; "zzzqqq" 0.
- 16 urllib `query_seeds` topic calls, all HTTP 403, then rerun locally: 3fs, action-selection, advice-taker, agent-architecture, agent-benchmarks, agent-control, agent-eval, agent-failure-localization, agent-memory, agent-safety, agent-security, agent-skills, agent-tokenization-and-caching, and agentic-llm-serving three times (the unsplit query and two of its year-split repeats).
- `get_seed` with a truncated id: 0 hits (my error).
- `get_seed`: 87 calls, all OK.

**Local-emulated sweep.** These hit counts are what the hosted search would return, within the calibration above.

Topic-slug sweep (361 queries: every topic carried by any agents/game-ai/realtime card plus 0 extra in-scope slugs; year-split for slugs over 50): `3fs` 1 · `action-selection` 1 · `advice-taker` 1 · `agent-architecture` 8 · `agent-benchmarks` 1 · `agent-control` 1 · `agent-eval` 6 · `agent-failure-localization` 42 · `agent-memory` 16 · `agent-safety` 1 · `agent-security` 4 · `agent-skills` 1 · `agent-tokenization-and-caching` 21 · `agentic-llm-serving` 62 · `agentic-llm-serving[..2024]` 0 · `agentic-llm-serving[2025..2025]` 0 · `agentic-llm-serving[2026..]` 62 · `agentic-serving` 2 · `agents` 2 · `agi` 1 · `ai` 5 · `ai-assisted-research` 1 · `ai-generated-math` 372 · `ai-generated-math[..2024]` 0 · `ai-generated-math[2025..2025]` 0 · `ai-generated-math[2026..]` 372 · `aiide-cog` 5 · `algorithm-discovery` 3 · `algorithmic-probability` 1 · `allreduce` 1 · `alphabeta` 1 · `ambisonics` 5 · `anthropometry` 8 · `any-angle` 2 · `api-release` 1 · `architecture` 1 · `ard` 3 · `async-io` 1 · `attended-state` 1 · `auralization` 13 · `automata` 11 · `autoresearch-experiment-selection` 4 · `autoresearch-rehearsal` 1 · `batched-interpreters-ffi` 21 · `beam-tracing` 6 · `behavior-arbitration` 1 · `behavior-trees` 4 · `belief-revision` 1 · `benchmarks` 1 · `binaural` 12 · `blackboard` 1 · `blackboard-facts` 1 · `blocks-world` 1 · `brain` 1 · `brir` 5 · `capability-scoped-harness` 1 · `causal-flow` 1 · `cellular-automata` 5 · `code-as-action` 1 · `code-llm` 2 · `coding-agents` 21 · `cognitive-architecture` 1 · `collision-avoidance` 2 · `combat-dialogue` 1 · `compression` 8 · `computational-linguistics-interfaces` 9 · `computer-use-agents` 3 · `conditional-memory` 1 · `constraint-solving` 1 · `context-compression` 1 · `continual-agent-skills` 22 · `continual-agents` 8 · `continual-skills` 11 · `control` 2 · `cpd` 1 · `crf` 2 · `crowds` 6 · `cryptanalysis` 1 · `csa` 1 · `curiosity` 114 · `curiosity[..2024]` 37 · `curiosity[2025..2025]` 4 · `curiosity[2026..]` 73 · `custom-allocators-runtime` 7 · `cybernetics` 4 · `d-star-lite` 1 · `data-oriented-design` 4 · `dataflow` 3 · `datalog` 3 · `ddgi` 2 · `deep-learning` 4 · `deepseek` 29 · `deictic-representation` 1 · `dependency-directed-backtracking` 1 · `determinism` 3 · `diffraction` 5 · `diffraction-utd` 1 · `distributed` 2 · `dsa` 1 · `dynamic-scenes` 11 · `ecs-data-oriented-simulation` 21 · `edf` 1 · `embedded-scripting` 5 · `embedded-scripting-dsls` 26 · `english` 1 · `engram` 1 · `entropy` 2 · `equivalent-source` 1 · `expert-specialization` 1 · `falling-sand` 1 · `feedback` 2 · `fields` 1 · `firing-points` 1 · `flowfields` 1 · `formations` 1 · `foundations` 8 · `fp8` 1 · `frame-pacing` 1 · `frustum-tracing` 2 · `fuzzing` 5 · `game-ai` 12 · `game-dialog` 1 · `game-networking-determinism` 3 · `game-sim` 1 · `game-theory` 2 · `game-tree-search` 2 · `gameai` 2 · `games` 8 · `geometric` 13 · `geometric-acoustics` 2 · `gi` 37 · `goal-regression` 1 · `goap` 1 · `gps` 1 · `grid-pathfinding` 1 · `grpo` 2 · `halo` 3 · `hardware` 1 · `harness` 23 · `harness-engineering` 15 · `harness-evolution` 1 · `hca` 1 · `headphone` 5 · `hebbian-learning` 1 · `heuristic` 1 · `hierarchical-state-machines` 1 · `hpa` 1 · `hpc` 2 · `hrtf` 27 · `htn` 1 · `htn-planning` 1 · `hybrid` 2 · `hyper-connections` 1 · `illuminance-caches` 1 · `imo` 5 · `incremental` 1 · `incremental-hashing` 1 · `incremental-search` 1 · `induction` 1 · `inference-systems` 16 · `infilling` 1 · `influence-maps` 1 · `information-theory` 5 · `intelligence` 1 · `interactive` 34 · `interpolation` 5 · `itd-ild` 8 · `japanese-morphology` 2 · `jps` 2 · `kernels` 2 · `knowledge-representation` 1 · `kv-cache` 4 · `kv-caching` 5 · `kv-serving` 16 · `lag-compensation` 1 · `language-models` 1 · `latency` 1 · `lean` 7 · `lean-verified` 3 · `learning` 2 · `linguistics` 3 · `llm` 2 · `llm-serving` 9 · `llm-systems` 1 · `load-balancing` 1 · `lockfree-game-parallelism` 23 · `logic` 8 · `logic-programming` 4 · `logic-theorist` 2 · `long-context` 2 · `looped-transformers` 1 · `low-precision-training` 1 · `magls` 3 · `manifold` 1 · `marl` 1 · `math-llm` 2 · `mathematical-reasoning` 13 · `mccarthy` 5 · `mcculloch-pitts` 2 · `mcts` 5 · `means-ends` 1 · `measurement` 23 · `memory-allocation` 40 · `memory-foundations` 3 · `mhc` 1 · `minimax` 1 · `ml` 6 · `ml-dnn` 3 · `mla` 4 · `model-vs-harness` 6 · `moe` 8 · `motion-planning` 1 · `multi-agent` 14 · `multi-agent-serving` 1 · `multimodal` 4 · `muon` 1 · `myth` 1 · `navmesh` 2 · `near-field` 4 · `netcode` 12 · `neural-nets` 3 · `neuroscience` 1 · `newell-simon` 5 · `nl-commands` 3 · `nl-game-commands` 6 · `ocr` 2 · `openai-math` 372 · `openai-math[..2024]` 0 · `openai-math[2025..2025]` 0 · `openai-math[2026..]` 372 · `opponent-modeling` 5 · `orca` 2 · `ordered-task-decomposition` 1 · `os` 1 · `outdoor` 1 · `paged-attention` 1 · `parallel` 2 · `parsing` 3 · `partial-observability` 5 · `partial-observability-multiagent` 1 · `path-guiding` 3 · `path-tracing` 7 · `pathfinding` 15 · `pcg` 9 · `perception` 2 · `personalization` 5 · `physical-symbol-system` 1 · `physics` 16 · `planning` 13 · `planning-under-uncertainty` 1 · `potential-fields` 2 · `precomputation` 3 · `precompute` 2 · `prediction` 2 · `prefix-caching` 2 · `priority` 1 · `probes` 5 · `problem-solving` 1 · `procedural-generation` 1 · `procedural-semantics` 1 · `product-sampling` 1 · `production-rules` 2 · `production-rules-triggers` 13 · `production-systems` 5 · `prolog` 3 · `provenance` 22 · `provenance-first-agent-memory` 20 · `provenance-first-memory` 5 · `purpose` 1 · `radiance-caching` 1 · `radiance-cascades` 14 · `radiance-transfer` 4 · `radiosity` 3 · `rag` 45 · `ray-tracing` 11 · `react` 11 · `reactive-agents` 1 · `reactive-game-ai` 2 · `reactive-systems` 1 · `realtime` 3 · `realtime-path-tracing` 1 · `reasoning` 8 · `rectified-flow` 1 · `rehearsal-autoresearch` 1 · `reliability` 5 · `replanning` 1 · `residual` 1 · `retrieval` 36 · `rir` 3 · `rl` 5 · `rm` 1 · `rollback` 3 · `rts` 5 · `rts-bots` 13 · `rule-matching` 1 · `runtime-harness-evolution` 3 · `rvo` 1 · `scaling-laws` 1 · `scheduling` 7 · `search` 4 · `self-verification` 1 · `serving` 1 · `shannon` 9 · `shrdlu` 1 · `simd` 7 · `simulation` 3 · `situated-agents` 1 · `situation-calculus` 1 · `skills` 8 · `smart-terrain` 1 · `society` 1 · `solomonoff` 1 · `sparse-attention` 2 · `spherical-harmonics` 7 · `squad-ai` 1 · `state-offload` 1 · `statecharts` 1 · `static-analysis` 3 · `steering` 1 · `strategy-rts-agents` 9 · `strips` 1 · `subsumption-architecture` 1 · `surface-based` 1 · `surfels` 3 · `symbolic-ai` 2 · `synthetic-data` 1 · `teleology` 1 · `text` 4 · `theorem-proving` 8 · `tile-maps` 1 · `timestep` 1 · `tokenization` 1 · `tokenization-prefix-caching` 2 · `tool-caching` 1 · `tool-use` 13 · `transformer` 5 · `transposition-tables` 1 · `tree-search` 1 · `truth-maintenance` 1 · `turing` 8 · `turing-test` 1 · `uct` 1 · `ui-modes` 1 · `unicode-text-shaping` 9 · `unified-model` 2 · `unorganized-machines` 1 · `utd` 2 · `utility` 1 · `utility-ai` 3 · `v4-pro` 1 · `verification` 3 · `virtual-acoustic` 1 · `vision-language` 2 · `von-neumann` 8 · `vr-ar` 5 · `wave` 16 · `wave-based` 8 · `wave-function-collapse` 1 · `wiener` 2 · `workload-characterization` 1 · `zobrist-hashing` 1

Lineage sweep (94 queries): `agent-harness-runtime` 10 · `agent-kv-cache` 4 · `agent-kv-serving` 2 · `agent-kv-virtualization` 1 · `agent-memory` 4 · `agent-memory-provenance` 4 · `agent-protocols` 1 · `agent-provenance` 1 · `agent-security` 1 · `agent-session-kv-scheduling` 1 · `agent-skills` 3 · `agent-supply-chain-security` 1 · `agent-tool-contracts` 5 · `agentic-kv-serving` 2 · `agentic-llm-serving` 1 · `agentic-serving` 4 · `ai-mathematical-reasoning` 386 · `ambisonics-binaural` 7 · `arena-agent-tools` 1 · `c11-memory-model` 1 · `capability-scoped-harness` 2 · `coding-agent-test-scaffold` 1 · `commit-gate-runtime-assurance` 1 · `continual-skills` 2 · `cpp-memory-model` 1 · `crowd-steering` 11 · `d-star-lite` 1 · `deepseek` 28 · `deepseek-sparse-attention` 1 · `environment-probing-memory-curation` 1 · `evolving-harness-benchmark` 1 · `execution-state-unlearning` 1 · `external-kv-prefix-cache-tiers` 1 · `falling-sand-sims` 1 · `flow-fields` 1 · `foundations-of-computing` 151 · `frontier-labs` 1 · `game-ai-planning` 21 · `game-networking` 13 · `geometric-acoustics` 12 · `harness` 2 · `harness-agnostic-reward-hacking` 1 · `harness-credit-assignment` 1 · `harness-evolution-search` 1 · `harness-model-coevolution` 1 · `hrtf-spatial-audio` 26 · `htn-planning` 1 · `interactive-sound-propagation` 30 · `kv-cache-agents` 2 · `kv-cache-compression` 1 · `kv-cache-serving` 1 · `kv-cache-systems` 1 · `kv-reuse-cross-context` 1 · `lock-free` 2 · `long-horizon-agents` 1 · `mcts` 2 · `memory-allocators` 31 · `memory-consistency` 1 · `memory-planning` 1 · `memory-portability-across-models` 1 · `memory-reclamation` 18 · `model-harness` 1 · `model-vs-harness` 4 · `nl-game-commands` 1 · `online-skill-evolution` 1 · `pathfinding` 19 · `prefix-cache-reproducibility` 1 · `prefix-paging` 1 · `procedural-generation` 14 · `production-rules-triggers` 4 · `production-systems` 3 · `prompt-injection-trajectory-localization` 1 · `provenance-first-memory` 1 · `radiance-cascades` 35 · `reactive-action-selection` 1 · `reactive-agent-architectures` 2 · `realtime-scheduling` 2 · `region-memory` 6 · `region-memory-capabilities` 1 · `reward-integrity-eval-infra` 1 · `rollback-consistency` 1 · `rsi-routing-harness` 1 · `runtime-harness-evolution` 12 · `self-improvement-evaluation` 1 · `serving-route-measurement` 1 · `shrdlu` 1 · `silent-tool-failure` 1 · `skill-graph-evolution` 1 · `skill-retrieval-forgetting` 1 · `strategy-rts-agents` 1 · `swebench-eval-hygiene` 1 · `trace-grounded-skill-orchestration` 1 · `wave-based-acoustics` 19 · `willmore` 1

Keyword sweep (318 queries, tokenized AND): "agent" 205 · "agents" 134 · "agentic" 78 · "LLM" 163 · "language model" 147 · "large language models" 31 · "tool" 80 · "tool use" 29 · "tool calling" 0 · "function calling" 0 · "MCP" 6 · "model context protocol" 0 · "protocol" 27 · "interface" 44 · "agent-computer interface" 20 · "API" 76 · "schema" 14 · "structured output" 4 · "JSON" 4 · "constrained decoding" 0 · "grammar" 18 · "retrieval" 53 · "RAG" 187 · "retrieval-augmented" 15 · "search" 124 · "BM25" 1 · "rerank" 0 · "embedding" 16 · "dense" 19 · "hybrid" 31 · "index" 57 · "memory" 293 · "agent memory" 82 · "episodic" 7 · "semantic memory" 9 · "procedural memory" 3 · "long-term memory" 12 · "forgetting" 2 · "memory portability" 2 · "provenance" 50 · "citation" 4 · "attribution" 0 · "source" 135 · "grounding" 3 · "hallucination" 1 · "faithful" 6 · "verification" 19 · "verifier" 5 · "self-verification" 2 · "critic" 35 · "judge" 5 · "LLM-as-a-judge" 0 · "reward model" 5 · "reward hacking" 3 · "failure" 59 · "failure localization" 42 · "blame" 5 · "root cause" 0 · "trajectory" 10 · "trace" 83 · "diagnosis" 0 · "debugging" 2 · "error" 48 · "silent" 13 · "tool failure" 17 · "credit assignment" 3 · "skill" 45 · "skills" 43 · "skill library" 7 · "continual" 42 · "continual learning" 9 · "lifelong" 11 · "curriculum" 3 · "self-improvement" 11 · "self-evolving" 7 · "evolution" 47 · "reflection" 42 · "reflexion" 7 · "self-refine" 0 · "feedback" 15 · "critique" 4 · "memory curation" 1 · "experience" 21 · "harness" 79 · "scaffold" 2 · "model vs harness" 9 · "sandbox" 6 · "permission" 2 · "capability" 17 · "security" 23 · "prompt injection" 3 · "injection" 3 · "untrusted" 4 · "jailbreak" 0 · "supply chain" 6 · "guardrail" 0 · "safety" 72 · "human" 54 · "human-in-the-loop" 0 · "approval" 5 · "oversight" 0 · "commit gate" 1 · "gate" 52 · "assurance" 1 · "planning" 66 · "planner" 14 · "plan" 168 · "HTN" 5 · "GOAP" 2 · "STRIPS" 8 · "hierarchical" 70 · "task decomposition" 1 · "scheduling" 32 · "constraint" 36 · "budget" 25 · "cost" 62 · "ranking" 2 · "recommendation" 0 · "preference" 1 · "utility" 8 · "utility AI" 7 · "bandit" 3 · "exploration" 7 · "curiosity" 114 · "experiment" 19 · "autoresearch" 6 · "experiment selection" 4 · "research agent" 16 · "scientific discovery" 1 · "multi-agent" 45 · "coordination" 8 · "communication" 83 · "debate" 1 · "negotiation" 0 · "orchestration" 4 · "delegation" 3 · "natural language" 16 · "natural-language commands" 0 · "command" 30 · "instruction" 25 · "semantic parsing" 1 · "text-to-SQL" 0 · "SQL" 13 · "query" 50 · "dialogue" 3 · "conversation" 5 · "computational linguistics" 9 · "morphology" 7 · "tokenization" 26 · "tokenizer" 1 · "cache" 106 · "caching" 70 · "prefix cache" 17 · "KV cache" 33 · "serving" 114 · "speculative decoding" 0 · "batching" 2 · "latency" 18 · "throughput" 19 · "long context" 15 · "context" 47 · "context management" 9 · "context compression" 7 · "summarization" 4 · "compaction" 6 · "knowledge graph" 6 · "graph" 445 · "entity" 34 · "extraction" 10 · "information extraction" 1 · "keyword" 2 · "classification" 14 · "document" 12 · "PDF" 4 · "OCR" 3 · "table" 176 · "spreadsheet" 0 · "email" 0 · "web agent" 9 · "browser" 7 · "computer use" 20 · "GUI" 88 · "form" 800 · "job" 16 · "resume" 2 · "hiring" 0 · "recruiting" 0 · "career" 0 · "labor" 6 · "code as action" 10 · "program synthesis" 6 · "code generation" 14 · "coding agent" 44 · "SWE-bench" 18 · "benchmark" 25 · "evaluation" 78 · "eval" 171 · "contamination" 1 · "reproducibility" 1 · "measurement" 43 · "rule" 72 · "production rules" 18 · "triggers" 16 · "blackboard" 3 · "truth maintenance" 1 · "belief revision" 1 · "state machine" 19 · "behavior tree" 10 · "squad" 2 · "director" 0 · "pacing" 1 · "difficulty" 1 · "governor" 0 · "rate limit" 36 · "backpressure" 0 · "audit" 7 · "log" 395 · "replay" 20 · "determinism" 11 · "rollback" 17 · "optimistic" 9 · "sequencer" 2 · "netcode" 15 · "lockstep" 10 · "lease" 13 · "transaction" 79 · "consistency" 33 · "partial observability" 7 · "fog of war" 5 · "opponent modeling" 7 · "theory of mind" 1 · "belief" 2 · "uncertainty" 6 · "calibration" 0 · "confidence" 1 · "explanation" 0 · "explainable" 0 · "interpretability" 0 · "simulation" 111 · "world model" 28 · "MCTS" 6 · "tree search" 29 · "reinforcement learning" 31 · "GRPO" 4 · "fine-tuning" 2 · "distillation" 1 · "small model" 26 · "router" 2 · "routing" 17 · "mixture of experts" 10 · "reasoning" 433 · "chain of thought" 5 · "test-time compute" 2 · "thinking" 12 · "math" 638 · "theorem proving" 23 · "Lean" 279 · "ReAct" 32 · "Voyager" 6 · "MemGPT" 11 · "generative agents" 4 · "SWE-agent" 21 · "OpenHands" 3 · "Claude" 16 · "GPT-4" 6 · "DeepSeek" 48 · "Qwen" 2 · "Gemini" 7 · "agent workflow" 9 · "workflow" 12 · "pipeline" 48 · "DAG" 18 · "long-horizon" 9 · "horizon" 29 · "persona" 13 · "personalization" 8 · "user modeling" 5 · "recommender" 0 · "deduplication" 1 · "entity resolution" 0 · "matching" 41 · "fuzzy" 3 · "data cleaning" 0 · "web scraping" 0 · "crawl" 1 · "freshness" 0 · "staleness" 0 · "temporal" 29 · "time" 482 · "versioning" 3 · "diff" 214 · "patch" 25 · "edit" 36 · "rewrite" 32 · "writing" 25 · "cover letter" 0 · "text generation" 9 · "style" 87 · "tone" 25 · "translation" 27 · "multilingual" 1 · "language" 417 · "CEFR" 0 · "ontology" 0 · "taxonomy" 10 · "knowledge base" 3 · "database" 104 · "SQLite" 1 · "local-first" 0 · "offline" 13 · "CRDT" 0 · "sync" 83 · "replica" 14 · "WebAssembly" 3 · "WASM" 3 · "Rust" 42 · "Elixir" 0 · "BEAM" 22

**Zero-hit keyword queries.** The corpus has nothing under these words:
- tool calling, function calling, model context protocol, constrained decoding, rerank, attribution, LLM-as-a-judge, root cause, diagnosis
- self-refine, jailbreak, guardrail, human-in-the-loop, oversight, recommendation, negotiation, natural-language commands, text-to-SQL, speculative decoding
- spreadsheet, email, hiring, recruiting, career, director, governor, backpressure, calibration
- explanation, explainable, interpretability, recommender, entity resolution, data cleaning, web scraping, freshness, staleness
- cover letter, CEFR, ontology, local-first, CRDT, Elixir

#### In-scope cards judged not relevant (ids only)
282 in-scope pool cards are not in the table. Each was read by title and takeaway, and none has a credible hireme application:
- realtime: acoustics, HRTF, auralization (61): 1667, 1668, 1669, 1670, 1672, 1675, 1680, 1681, 1682, 1684, 1687, 1688, 1690, 1691, 1692, 1693, 1696, 1697, 1699, 1700, 1702, 1703, 1704, 1705, 1706, 1707, 1709, 1710, 1711, 1712, 1713, 1716, 1719, 1720, 1721, 1722, 1724, 1731, 1733, 1736, 1737, 1738, 1739, 1740, 1741, 1742, 1743, 1744, 1746, 1747, 1748, 1753, 1756, 1757, 1758, 1759, 1760, 1762, 1763, 1764, 1766
- agents: carrying serving/KV/tokenization tags (serving internals, plus training-side harness and skill papers) (49): 054, 057, 061, 062, 073, 077, 078, 080, 082, 083, 089, 176, 185, 187, 188, 1014, 1016, 1017, 1022, 1077, 1078, 1080, 1081, 1118, 1143, 1232, 1448, 1537, 1540, 1574, 1576, 1578, 1580, 1605, 1609, 1612, 1613, 1636, 1639, 1640, 1772, 1773, 1798, 1800, 1804, 1825, 2246, 2247, 2341
- agents: historical foundations (1943-1976) (43): 013, 053, 055, 056, 059, 060, 070, 084, 086, 087, 088, 093, 104, 108, 109, 165, 166, 178, 183, 184, 189, 193, 519, 520, 548, 558, 561, 562, 564, 565, 566, 567, 576, 579, 580, 581, 582, 583, 584, 610, 1768, 1774, 2266
- game-ai: pathfinding, crowds, steering, MAPF (32): 196, 201, 205, 212, 234, 262, 266, 273, 279, 281, 282, 294, 302, 310, 332, 349, 355, 357, 399, 454, 457, 458, 464, 468, 469, 476, 480, 932, 1064, 1433, 2250, 2292
- agents: DeepSeek model and infrastructure internals (28): 974, 975, 976, 977, 978, 979, 980, 981, 982, 983, 984, 985, 986, 987, 988, 989, 990, 991, 992, 993, 994, 995, 996, 997, 998, 999, 1000, 2340
- game-ai: RTS bots, multi-agent RL, game-tree search (21): 009, 010, 014, 017, 023, 025, 098, 101, 113, 115, 190, 247, 289, 336, 348, 354, 379, 381, 550, 551, 2233
- game-ai: other (reactive agents, smart terrain, behavior trees, Datalog sim) (13): 116, 123, 204, 225, 239, 283, 309, 369, 411, 460, 1490, 2305, 2332
- agents: math reasoning and algorithm discovery (12): 1220, 1221, 1222, 1223, 1224, 1225, 1226, 1227, 1228, 1229, 1230, 1231
- realtime: scheduling, OS, physics, timestep, other netcode (12): 198, 265, 276, 300, 311, 361, 363, 371, 382, 384, 413, 475
- game-ai: procedural content (7): 012, 019, 095, 102, 119, 1807, 1860
- realtime: rendering and global illumination (4): 1784, 1812, 1813, 1852

#### Relevant cards
Tags:
- #1 to #9: shortlist rank (section 3).
- A: anti-candidate (section 4).
- D: already done, or aligned with hireme.
- B: background or low relevance.

| MCP id | Title | Year | Pool | Tag | Seen via | Relevance to hireme |
|---|---|---|---|---|---|---|
| `2314-approve-what-exactly-effect-binding-and-trusted-rendering-for-agent` | Approve What, Exactly? Effect Binding and Trusted Rendering for Agent Step-Up Authorization | 2026 | agents | #1 | MCP | Approval must be agent-unreachable and name the exact effect; post-approval argument changes found in 4 of 8 runtimes. Direct model for binding `open_fire` to the CV version/letter it approved. |
| `2284-names-are-not-objects-object-bound-confinement-for-compromised-ai` | Names Are Not Objects: Object-Bound Confinement for Compromised AI Coding Agents | 2026 | agents | #1 | MCP | Approve the object, not the name: bind to the CV blob SHA / version id, not the CV root name a later pick can repoint. |
| `1449-when-tool-outputs-become-commands-separating-action-ind` | When Tool Outputs Become Commands: Separating Action Induction from Runtime Authorization in Tool-Augmented LLM Agents | 2026 | agents | #1 | MCP | Tool output that induces an action is not authorization; authorize against the operator objective. hireme already does this with masks + human_only; supports keeping it. |
| `1803-engineering-reliable-commit-gates-for-agentic-ai-cost-aware` | Engineering Reliable Commit Gates for Agentic AI: Cost-Aware Verification Portfolios under Common-Mode Data Failures | 2026 | agents | #1,#3 | MCP | Commit gates: verifier-model diversity is not evidence-source diversity. For hireme: independent sources/hosts, not extra LLM checkers. |
| `2241-humanize-judgement-engineering-for-agentic-coding` | Humanize: Judgement Engineering for Agentic Coding | 2026 | agents | #1 | MCP | Human approves a plan contract; deterministic hooks (not a model) enforce 72 gates; stopping is the weak point. Same shape as FIRE HOLD + kernel judge. |
| `1366-when-can-agents-safely-checkpoint-fork-restore-and-merge-exa` | When Can Agents Safely Checkpoint, Fork, Restore, and Merge? Exact Checking for Execution Edits | 2026 | agents | #1 | MCP | An agent cannot unsend a request; runtime decides from the execution record. hireme keeps every agent effect a reversible row write; irreversible acts stay human. |
| `1144-outcome-monitors-recovery-affordances-for-silent-tool-failure` | Outcome Monitors: Recovery Affordances for Silent Tool Failures | 2026 | agents | #2 | MCP | Outcome Monitors: nonbinding receipts naming the violated property + recovery tools lift completion 10.9% to 28.1%. Template for warnings in hireme write ACKs. |
| `2244-loud-failures-quiet-failures-fault-detection-and-recovery-in-tool-using` | Loud Failures, Quiet Failures: Fault Detection and Recovery in Tool-Using Language Model Agents | 2026 | agents | #2 | MCP | Agents catch 91.3% of loud errors but 58.8% of plausible wrong values; prompting to check does not help. Detection must live in the server (hireme kernel). |
| `1368-feedback-that-backfires-why-small-language-model-agents-repe` | Feedback That Backfires: Why Small Language Model Agents Repeat the Call They Just Watched Fail | 2026 | agents | #2 | MCP | Echoing a failed call makes small models repeat it; describe the failure instead. hireme diagnostics already print a corrected call shape: keep that, avoid verbatim echo. |
| `2287-turncost-turns-not-observations-cache-aware-loop-engineering-for-coding` | TurnCost: Turns, Not Observations: Cache-Aware Loop Engineering for Coding Agents | 2026 | agents | #2 | MCP | Under prefix caching, turns drive cost (84% of log-cost variance) not observation size (4%). Return derived effects in the ACK instead of forcing a follow-up get. |
| `065-schema-first-tool-apis-for-llm-agents-a-controlled-study-of-` | Schema First Tool APIs for LLM Agents: A Controlled Study of Tool Misuse, Recovery, and Budgeted Performance | 2026 | agents | #2 | MCP | JSON-Schema tool contracts cut interface misuse but not semantic misuse (pilot). hireme is schema-first already; the remaining lever is semantic receipts. |
| `2286-lost-in-implicit-routing-how-llm-agents-fail-to-load-relevant-skills-at` | Lost in Implicit Routing: How LLM Agents Fail to Load Relevant Skills at Scale | 2026 | agents | #2,#9 | MCP | Implicit routing collapses as catalogues grow (recall 73.6% to 27.4% with 1,000 irrelevant skills); preselection keeps 73.9%. Keep hireme tool list small; preselect playbooks. |
| `1233-nexus-depth-adaptive-kv-cache-splicing-and-retrieval-decoupled` | Nexus: Depth-Adaptive KV-Cache Splicing and Retrieval-Decoupled Tool Routing for Agentic LLMs on Unified Memory | 2026 | agents | #2 | MCP | Do not re-prefill a large MCP tool registry every turn. hireme lists at most ~18 tools, filtered by masks: already small; keep ordering stable. |
| `1142-recache-efficient-kv-cache-reuse-and-compression-for-tool-aug` | ReCache: Efficient KV Cache Reuse and Compression for Tool-Augmented LLM Agents | 2026 | agents | #2 | MCP | Tool schemas recur in different orders, so prefix caches miss. hireme should keep tool order deterministic per key (it is built from schema order). |
| `118-build-order-optimization-in-starcraft` | Build Order Optimization in StarCraft | 2011 | game-ai | #3 | MCP | Build-order optimization: fast-forward simulator, every action at its earliest legal frame, branch-and-bound. Direct analogue for a heat-aware fire calendar. |
| `1629-shop-simple-hierarchical-ordered-planner` | SHOP: Simple Hierarchical Ordered Planner | 1999 | agents | #3 | MCP | SHOP: plan in execution order so full state is known at every step. Fire calendar should simulate sends in date order over the real governor. |
| `296-shop2-an-htn-planning-system` | SHOP2: An HTN Planning System | 2003 | game-ai | #3 | MCP | SHOP2 HTN: methods evaluated against current state; interleave planning and execution. Background for the calendar. |
| `1492-advanced-real-time-hierarchical-task-network-long-term-behavior` | Advanced Real-Time Hierarchical Task Network: Long-Term Behavior in Real-Time Games | 2021 | game-ai | #3 | MCP | ART-HTN: emit a branched plan from a cheap simulator instead of thrashing replans. Calendar branches on reply/reject outcomes. |
| `380-scheduling-algorithms-for-multiprogramming-in-a-hard-real-ti` | Scheduling Algorithms for Multiprogramming in a Hard-Real-Time Environment | 1973 | realtime | #3 | MCP | Rate-monotonic / EDF scheduling (seminal 1973). EDF-style ordering by earliest legal day is the calendar heuristic. |
| `1137-d-lite` | D* Lite | 2002 | game-ai | #3 | MCP | D* Lite incremental replanning (seminal). Recompute only the calendar suffix a heat change touches. |
| `299-influence-mapping` | Influence Mapping | 2001 | game-ai | D | mirror | Influence maps: decaying numeric fields. hireme heat is already a decaying company/vendor field. |
| `1575-where-reliability-lives-experimental-localisation-of-behavioural` | Where Reliability Lives: Experimental Localisation of Behavioural Properties in an Agent System | 2026 | agents | #4 | MCP | Reliability properties have a location (model vs machinery); separate ledger lets you intervene. hireme six-check sequencer gives free localization. |
| `1822-harness-or-model-isolating-the-harness-effect-in-agentic-coding-with` | Harness or Model? Isolating the Harness Effect in Agentic Coding with a Contamination-Controlled Private Suite | 2026 | agents | #4,#9 | MCP | Harness, not just model, moves solve rate; use paired same-model contrasts. For measuring MCP description/diagnostic changes. |
| `1013-quotebench-how-matched-scores-can-hide-command-path-failures` | QuoteBench: How Matched Scores Can Hide Command-Path Failures | 2026 | agents | #4,#9 | MCP | Matched success hides 55-73 point command-path collapse; exact final-state validators (exit codes miss 23-47%). Grade agents by kernel state, not by self-report. |
| `2313-what-coding-agents-leave-unsaid-measuring-task-state-gaps-between` | What Coding Agents Leave Unsaid: Measuring Task-State Gaps Between Execution and Reports | 2026 | agents | #4 | MCP | Report-only readers recover 52.0% of task state vs 92.7% with full context. Operator should see a ledger-derived session report, not agent prose. |
| `1367-when-may-an-agent-stop-evidence-carrying-termination-for-too` | When May an Agent Stop? Evidence-Carrying Termination for Tool-Using LLMs | 2026 | agents | #4 | MCP | Evidence-carrying termination: stop only with a certificate binding claims to trace evidence (0/288 unsafe completions vs 252/288). |
| `2312-prune-the-summary-not-the-history-source-judged-compaction-for-long` | Prune the Summary, Not the History: Source-Judged Compaction for Long-Horizon Agents | 2026 | agents | #4,A | MCP | 83% of failed runs trace to an unsupported summary entry. Agent-written battleplan/notes must stay untrusted prose, never kernel inputs. |
| `1826-novafabric-tamper-evident-replayable-evidence-for-autonomous-ai` | NovaFabric: Tamper-Evident, Replayable Evidence for Autonomous AI Agent Runs | 2026 | agents | #4 | MCP | Tamper-evident, replayable agent-run evidence. Optional: hash-chain hireme audit/citations. |
| `1611-dnative-twin-decision-graphs-and-digital-twins-for-reconstructable-age` | DNative-Twin: Decision Graphs and Digital Twins for Reconstructable Agentic Decisions | 2026 | agents | #4 | MCP | Decision graphs with counterfactual replay. hireme kernel is deterministic, so replaying a verdict from rows is already possible. |
| `1450-safety-does-not-compose-non-decaying-loop-state-for-aut` | Safety Does Not Compose: Non-Decaying Loop State for Autonomous LLM Agents | 2026 | agents | #4 | MCP | Trajectory-scoped monitors cannot see attacks fragmented across loops; keep cross-iteration state. Per-key (not per-session) refusal tallies. |
| `1579-fresh-memory-stale-plans-dependency-scoped-validation-for-distributed` | Fresh Memory, Stale Plans: Dependency-Scoped Validation for Distributed LLM-Agent Memory | 2026 | agents | #7 | MCP | PlanFence: plans cite exact records; validate only the dependency-scoped slice before acting. Freshness-only executor acted on stale plan 30/30; PlanFence correct 30/30. |
| `1120-position-multi-agent-systems-should-prioritize-concurrency-contr` | Position: Multi-Agent Systems Should Prioritize Concurrency Control | 2026 | agents | #7 | MCP | Position: MAS failures are lost updates/stale reads across long inference windows; needs concurrency control. hireme leases + expect_rev cover part; read-set is the gap. |
| `1018-correct-is-not-governed-provenance-integrity-in-agentic-workflows` | Correct Is Not Governed: Provenance Integrity in Agentic Workflows | 2026 | agents | #7,#1 | MCP | Matrix: decision / execution / change provenance; dependency-scoped invalidation reissued 3 tasks vs 18 for full rerun. |
| `2235-a-truth-maintenance-system` | A Truth Maintenance System | 1979 | agents | #7 | MCP | Truth Maintenance System (seminal 1979): beliefs keep justifications, retract when support goes. Model for flagging agent-derived cells stale. |
| `171-tepa-revoking-stale-memories-for-conflict-robust-language-ag` | TEPA: Revoking Stale Memories for Conflict-Robust Language Agents | 2026 | agents | #7 | MCP | TEPA: revoke superseded memories without deleting audit history (stays near 0.95 where append-only/LWW fall below no-memory). hireme citations + `stale` already do supersession. |
| `1606-memorylace-memory-lifecycle-aware-consolidation-and-evidence-retrieval` | MemoryLACE: Memory Lifecycle-Aware Consolidation and Evidence Retrieval | 2026 | agents | D | mirror | MemoryLACE: atomic memories with merge/supersession/contradiction edges and provenance. hireme citation history is this shape for cells. |
| `068-track-rank-crack-epistemic-working-memory-scales-multi-hop-r` | Track, Rank, Crack: Epistemic Working Memory Scales Multi-Hop Reasoning in Language Agents | 2026 | agents | #6 | MCP | SLEUTH epistemic working memory: Confirmed Facts / ranked Hypotheses / Open Questions drive next action (+5 to +11 on multi-hop). |
| `1802-grounding-agent-memory-environment-probing-curation-for-enterprise` | Grounding Agent Memory: Environment-Probing Curation for Enterprise Agents | 2026 | agents | #6 | MCP | Environment-probing curation: re-query the live environment rather than trusting old traces. Stale `_on` cells re-researched, not reused. |
| `2356-teleo-reactive-programs-for-agent-control` | Teleo-Reactive Programs for Agent Control | 1994 | game-ai | #6,D | MCP | Teleo-reactive programs: ordered condition-action rules, first true wins. hireme cv_rules already have these semantics; same shape gives a per-application next step. |
| `931-building-a-better-battle-halo-3-ai-objectives` | Building a Better Battle: HALO 3 AI Objectives | 2008 | game-ai | #6 | MCP | Halo 3 objectives: declarative prioritized tasks with capacities distribute squads. Lease by work type (gaps) instead of scripting agents. |
| `395-game-ai-pro-utility-based-decision-architectures` | Game AI Pro — Utility-Based Decision Architectures | 2013 | game-ai | #5 | MCP | Utility AI: considerations as response curves, product vetoes. Score explanation as a consideration ledger (deterministic; skip the weighted-random part). |
| `351-behavioral-mathematics-for-game-ai` | Behavioral Mathematics for Game AI | 2009 | game-ai | #5 | MCP | Behavioral Mathematics for Game AI (Mark 2009): designer-authored response curves. Background for score parts. |
| `275-building-a-better-battle-damn-and-utility-theory-for-games` | Building a Better Battle: DAMN and Utility Theory for Games | 2010 | game-ai | #5 | MCP | Mark & Dill GDC 2010 utility talk. Background for score parts. |
| `930-handling-complexity-in-the-halo-2-ai` | Handling Complexity in the Halo 2 AI | 2005 | game-ai | #5 | MCP | Halo 2 AI: complexity paid in designer-readable rules, not float soup. Supports showing rule-level reasons. |
| `360-managing-complexity-in-the-halo-2-ai-system` | Managing Complexity in the Halo 2 AI System | 2005 | game-ai | #5 | MCP | Halo 2 behavior DAG (Isla GDC 2005), same point as 930. |
| `929-the-illusion-of-intelligence-ai-and-level-design-in-halo` | The Illusion of Intelligence: The Integration of AI and Level Design in Halo | 2002 | game-ai | #5 | MCP | Halo 1: make the AI legible to the player. UX argument for visible reasons. |
| `169-open-source-reproduction-and-explainability-analysis-of-corr` | Open-Source Reproduction and Explainability Analysis of Corrective Retrieval Augmented Generation | 2026 | agents | #5 | MCP | CRAG reproduction: SHAP shows the evaluator mostly checks named-entity overlap. Explanations expose scorer shortcuts (cf. hireme anchor-word false matches). |
| `1842-ai-driven-dynamic-dialog-through-fuzzy-pattern-matching` | AI-driven Dynamic Dialog through Fuzzy Pattern Matching | 2012 | game-ai | #5,A | MCP | Valve rule database: most-specific rule wins, rules owned by non-programmers. Do not switch cv_rules to specificity; ordered first-match + shadow checks already explain better. |
| `1625-real-time-world-crafting-generating-structured-game-behaviors` | Real-Time World Crafting: Generating Structured Game Behaviors from Natural Language with Large Language Models | 2025 | game-ai | #9 | MCP | LLM translates NL into a constrained DSL that configures the runtime (Wordplay@EMNLP 2025). Pattern for NL desk commands over the mask DSL. |
| `2257-nomos-compiling-written-policies-into-statically-verified-tool-call-gates-for-ll` | NOMOS: Compiling Written Policies into Statically Verified Tool-Call Gates for LLM Agents | 2026 | agents | #9,#1 | MCP | NOMOS: written policy compiled into a deterministic, schema-checked tool-call gate; violations 66.3% to 2.6% (airline). Validate NL-derived filters statically. |
| `1076-understanding-natural-language` | Understanding Natural Language | 1972 | game-ai | #9 | MCP | SHRDLU (1972): NL commands grounded in a world model, can answer "why". Read-back of what was understood. |
| `076-large-language-models-play-starcraft-ii-benchmarks-and-a-cha` | Large Language Models Play StarCraft II: Benchmarks and A Chain of Summarization Approach | 2024 | game-ai | #9 | MCP | TextStarCraft: chain-of-summarization turns state into commands an LLM can issue. Compact desk summaries for NL translation. |
| `072-agent-workflow-memory` | Agent Workflow Memory | 2024 | agents | #8 | MCP | Agent Workflow Memory: induce reusable workflows from trajectories (+24.6% / +51.1% relative). Source of hireme playbooks. |
| `2285-cortex-measurement-gated-evolution-and-pruning-of-coding-agent-skills` | Cortex: Measurement-Gated Evolution and Pruning of Coding-Agent Skills and Rules | 2026 | agents | #8 | MCP | Cortex: keep a rule/skill change only if repeated with/without runs show net gain; rules did most of the work, skills rarely opened. |
| `1015-practice-makes-unsafe-skill-misevolution-in-self-improving-llm-agents` | Practice Makes Unsafe: Skill Misevolution in Self-Improving LLM Agents | 2026 | agents | #8,A | MCP | Skill misevolution: all 21 evolved configs author unsafe artifacts. Playbooks must be curated, not self-evolved. |
| `2242-the-winner-s-curse-in-llm-self-improvement-loops-selection-noise-lock` | The Winner's Curse in LLM Self-Improvement Loops: Selection Noise, Lock-in, and Acceptance Rules | 2026 | agents | #8,A | MCP | Winner's curse: keep-if-better loops inflate gains 13-20 points with 16 selection items. Any eval of hireme agents needs held-out items. |
| `1638-from-interaction-traces-to-persistent-skills-online-evolution-for-comp` | From Interaction Traces to Persistent Skills: Online Evolution for Computer-Use Agents | 2026 | agents | #8 | MCP | Online skill evolution: +5.7 to 18.6 pp over empty library after warm-up; benefits conditional. |
| `006-voyager-an-open-ended-embodied-agent-with-large-language-mod` | Voyager: An Open-Ended Embodied Agent with Large Language Models | 2023 | agents | #8 | MCP | Voyager skill library + self-verification (2023, seminal for skills). |
| `1119-harness-continual-learning-continual-adaptation-beyond-model-par` | Harness Continual Learning: Continual Adaptation Beyond Model Parameters | 2026 | agents | #8 | MCP | Harness continual learning: guarded commit of harness state with a regression evaluator. |
| `1542-towards-a-systems-foundation-for-agentic-skills-architecture-lifecycle` | Towards a Systems Foundation for Agentic Skills: Architecture, Lifecycle, and Security | 2026 | agents | #8 | MCP | Skills as modular procedural artifacts needing lifecycle and security. |
| `192-osworld-benchmarking-multimodal-agents-for-open-ended-tasks-` | OSWorld: Benchmarking Multimodal Agents for Open-Ended Tasks in Real Computer Environments | 2024 | agents | #8 | MCP | OSWorld: execution-graded tasks with setup configs and custom graders. Template for a hireme MCP task suite graded by kernel state. |
| `079-the-browsergym-ecosystem-for-web-agent-research` | The BrowserGym Ecosystem for Web Agent Research | 2024 | agents | #8 | MCP | BrowserGym/AgentLab: one gym-like observation/action space for agent eval. |
| `1801-benchshield-formal-model-backed-instrumentation-for-reward-integrity-in` | BenchShield: Formal Model-Backed Instrumentation for Reward Integrity in LLM-Agent Evaluation Infrastructure | 2026 | agents | #8 | MCP | BenchShield: instrument benchmarks so reward hacking cannot inflate scores. |
| `1776-swe-bench-pro-verified-a-reliable-benchmark-for-software-engineering` | SWE-Bench Pro Verified: A Reliable Benchmark for Software Engineering Agents | 2026 | agents | #8 | MCP | SWE-Bench Pro Verified: gold leakage and misleading tasks inflate scores. |
| `1021-a-contract-grade-verifier-for-llm-generated-gpu-kernels` | A Contract-Grade Verifier for LLM-Generated GPU Kernels, and a Native Blackwell Backward for the Gated-Linear-Recurrence Family | 2026 | engines | #8 | MCP | Contract-grade verifier: allclose accepts 1,487 broken LLM kernels. Use exact validators. |
| `052-change2task-from-repository-changes-to-executable-coding-age` | Change2Task: From Repository Changes to Executable Coding Agent Tasks and Environments | 2026 | agents | #8 | MCP | Change2Task: turn real history into verified agent tasks. hireme audit/ledger could seed eval tasks. |
| `2245-package-hallucination-attacks-on-coding-agents-through-prompt-injection` | Package Hallucination Attacks on Coding Agents through Prompt Injection in Rule Files | 2026 | agents | D | MCP | Rule files are an injection channel. hireme rules are a typed DSL judged by the kernel, not prose instructions: already safe. |
| `2256-pycache-trap-the-inspection-execution-gap-in-agent-skill-scanners` | PyCache Trap: The Inspection-Execution Gap in Agent Skill Scanners | 2026 | agents | A | mirror | Skill packages can ship substituted bytecode. If playbooks are served, serve text only, never code. |
| `1767-authority-is-not-a-string-a-capability-scoped-harness-for-prompt` | Authority Is Not a String: A Capability-Scoped Harness for Prompt-Injection-Resistant Coding Agents | 2026 | agents | D | mirror | CapScope: typed capabilities outside the model context checked on every call. hireme read/write masks + leases are this. |
| `2311-a-team-of-gemini-4-argon-agents-beats-minecraft` | A team of Gemini 4 Argon agents beats Minecraft | 2026 | agents | D | mirror | Four Gemini agents coordinated only via chat + shared memory to beat Minecraft. Shared-state coordination, which hireme replica + leases provide. |
| `378-blackboard-systems` | Blackboard Systems | 1986 | game-ai | D | mirror | Blackboard systems: knowledge sources on a shared blackboard, scheduled by a controller. hireme replica = blackboard, sequencer = controller. |
| `1050-deepseek-harness-everything-is-a-plugin` | DeepSeek Harness: Everything is a Plugin | 2026 | agents | D | MCP | DeepSeek harness: append-only session log is the only source of model-visible state. hireme ledger/audit is append-only. |
| `1446-a-contract-centered-architecture-for-scalable-and-manag` | A Contract-Centered Architecture for Scalable and Manageable Agentic Runtimes | 2026 | agents | D | mirror | Contract-centered agent architecture keeps the data substrate outside the agent stack. hireme MCP is that substrate. |
| `1543-runtime-independent-persistent-agents-preserving-identity-memory-and-c` | Runtime-Independent Persistent Agents: Preserving Identity, Memory, and Code Across Models, Harnesses, and Servers | 2026 | agents | D | mirror | Persistent agent identity across models/harnesses. hireme keys + DB hold identity and memory, not the agent. |
| `1642-does-your-agents-memory-survive-a-model-upgrade-a-controlled-study` | Does Your Agent's Memory Survive a Model Upgrade? A Controlled Study of Memory Portability | 2026 | agents | A,D | MCP | Fixed-schema stores survive a model upgrade (delta acc about 0); model-written notes do not. Argues for hireme typed rows over agent notes/embeddings. |
| `058-governing-evolving-memory-in-llm-agents-risks-mechanisms-and` | Governing Evolving Memory in LLM Agents: Risks, Mechanisms, and the Stability and Safety Governed Memory (SSGM) Framework | 2026 | agents | D | mirror | SSGM: consistency checks, temporal decay, access control before memory consolidation. hireme provenance checks (stale, freshness, source_trust) map onto it. |
| `064-rethinking-how-to-remember-beyond-atomic-facts-in-lifelong-l` | Rethinking How to Remember: Beyond Atomic Facts in Lifelong LLM Agent Memory | 2026 | agents | D | mirror | TriMem keeps raw source next to extracted facts. hireme keeps listing_raw beside derived keywords. |
| `063-retain-or-consolidate-budget-dependent-operator-selection-fo` | Retain or Consolidate? Budget-Dependent Operator Selection for Language Agent Memory | 2026 | agents | D | mirror | Retain vs consolidate is a budget call. hireme retains raw listings by design. |
| `1641-same-request-different-answer-quantization-amplifies-cache-induced-div` | Same Request, Different Answer: Quantization Amplifies Cache-Induced Divergence in LLM Serving | 2026 | agents | D | mirror | Prefix caching changes agent trajectories (36% at 16-bit, 75% at 4-bit). Agents are nondeterministic; the kernel must judge every write (it does). |
| `1637-evoharnessbench-can-your-agents-keep-pace-with-an-evolving-harness` | EVOHARNESSBENCH: Can Your Agents Keep Pace with an Evolving Harness? | 2026 | agents | B | mirror | Harness changes under agents (EvoHarnessBench). Keep MCP contracts stable; schema_rev bumps should be announced in `hireme`. |
| `1626-provenance-guided-rollback-suggestions` | Provenance Guided Rollback Suggestions | 2025 | languages | #4 | MCP | Provenance-guided rollback (Datalog): localize the input delta that produced bad derived tuples. Kernel derivations could name the writes behind a derived value. |
| `001-swe-agent-agent-computer-interfaces-enable-automated-softwar` | SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering | 2024 | agents | #2 | MCP | SWE-agent ACI: compact commands, bounded output, lint-gated edits, collapsed history. hireme find/text paging and refusal diagnostics follow this. |
| `182-agentless-demystifying-llm-based-software-engineering-agents` | Agentless: Demystifying LLM-based Software Engineering Agents | 2024 | agents | #8 | MCP | Agentless: fixed localize-repair-validate pipeline beat open agent loops at $0.70. Routine hireme agent jobs as fixed recipes. |
| `051-auto-configuring-scientific-simulators-with-lightweight-codi` | Auto-Configuring Scientific Simulators with Lightweight Coding-Agent Adapters | 2026 | agents | #8 | MCP | SIGA: wrap an agent with an executable contract (retrieval, procedural memory, validation-gated termination). |
| `2243-when-sub-agents-work-in-parallel-the-promises-and-pitfalls-of-dynamic` | When Sub-Agents Work in Parallel: The Promises and Pitfalls of Dynamic Concurrency in Long-Horizon Coding Tasks | 2026 | agents | A | MCP | Parallel sub-agents: -11.9 to +2.3 points while tokens rise 1.41-3.31x. Do not design for agent fan-out. |
| `2288-scaling-inference-time-compute-with-teams-of-coding-agents` | Scaling Inference-Time Compute with Teams of Coding Agents | 2026 | agents | A | MCP | Teams cost 3-7x; workers best as planners; plateau beyond four. Same caution. |
| `074-from-local-to-global-a-graph-rag-approach-to-query-focused-s` | From Local to Global: A Graph RAG Approach to Query-Focused Summarization | 2024 | agents | A | MCP | GraphRAG community summaries. Heavy; hireme rows are already structured. |
| `075-hipporag-neurobiologically-inspired-long-term-memory-for-lar` | HippoRAG: Neurobiologically Inspired Long-Term Memory for Large Language Models | 2024 | agents | A | MCP | HippoRAG KG + PPR. Overkill for one operator's records. |
| `069-a-mem-agentic-memory-for-llm-agents` | A-MEM: Agentic Memory for LLM Agents | 2025 | agents | A | MCP | A-MEM Zettelkasten notes that rewrite linked memories. Free-form, writer-coupled (see 1642). |
| `1541-agent-zero-memory-provenance-aware-long-term-memory-for-llm-agents` | Agent Zero Memory: Provenance-Aware Long-Term Memory for LLM Agents | 2026 | agents | A | mirror | Three parallel memory stores. Consistency cost; hireme has one typed store. |
| `092-dense-passage-retrieval-for-open-domain-question-answering` | Dense Passage Retrieval for Open-Domain Question Answering | 2020 | agents | A | mirror | Dense passage retrieval beats BM25 on open-domain QA; for a small personal corpus of exact tech terms, lexical search is the cheaper first step (inference). |
| `1799-driftnet-a-dual-head-trajectory-transformer-for-detecting-and-localizing` | DriftNet: A Dual-Head Trajectory Transformer for Detecting and Localizing Prompt Injection in LLM Agents | 2026 | agents | A | MCP | DriftNet learned injection localizer. Needs training data; deterministic masks/fencing are stronger for hireme. |
| `1644-harness-agnostic-detection-and-immunization-of-reward-hacking-in-self` | Harness-agnostic detection and immunization of reward hacking in self-evolving language models | 2026 | agents | A | mirror | HackProbe reward-hacking detector for self-evolving loops. No self-evolving loop in hireme. |
| `1610-the-natural-language-interaction-protocol-and-standard-for-ai-agents` | The Natural Language Interaction Protocol and Standard for AI Agents | 2026 | agents | A | MCP | NLIP (Ecma) NL interaction envelope. MCP already is the protocol. |
| `1581-speculative-macro-commit-for-faster-tool-using-agents` | Speculative Macro Commit for Faster Tool-Using Agents | 2026 | agents | A | MCP | Speculative macro commit for tool latency. hireme agents are not latency-bound; needs snapshot sandboxes. |
| `2315-the-world-won-t-wait-evaluating-and-teaching-agents-under-a-live-clock` | The World Won't Wait: Evaluating and Teaching Agents Under a Live Clock | 2026 | game-ai | A | MCP | Real-time play punishes slow models. Not hireme's regime. |
| `003-generative-agents-interactive-simulacra-of-human-behavior` | Generative Agents: Interactive Simulacra of Human Behavior | 2023 | agents | A | MCP | Generative Agents memory stream + reflection. Agent-side cognition; hireme should not host it. |
| `081-reflexion-language-agents-with-verbal-reinforcement-learning` | Reflexion: Language Agents with Verbal Reinforcement Learning | 2023 | agents | A | MCP | Reflexion verbal self-critique memory. Agent-side. |
| `004-memgpt-towards-llms-as-operating-systems` | MemGPT: Towards LLMs as Operating Systems | 2023 | agents | A | mirror | MemGPT paging. Agent-side; hireme is the archival store it would page from. |
| `1079-helix-model-harness-co-evolution-for-recursive-self-improvement` | HELIX: Model-Harness Co-evolution for Recursive Self-Improvement | 2026 | agents | A | mirror | HELIX model-harness co-evolution. Training-side. |
| `1447-jit-agent-scaling-harness-intelligence-via-just-in-time` | JIT-Agent: Scaling Harness Intelligence via Just-in-Time Harness Evolution | 2026 | agents | A | mirror | JIT-Agent harness synthesis. Training/search-side. |
| `1538-whale-a-simple-recipe-for-joint-harness-weight-optimization` | WHALE: A Simple Recipe for Joint Harness-Weight Optimization | 2026 | agents | A | mirror | WHALE joint harness/weight optimization. Training-side. |
| `1770-neohorse-1-towards-recursive-self-improvement-via-agentic-post` | NeoHorse-1: Towards Recursive Self-Improvement via Agentic Post-Training with Routing Harness | 2026 | agents | A | mirror | NeoHorse RSI routing loop. Training-side. |
| `1009-bandit-based-monte-carlo-planning` | Bandit Based Monte-Carlo Planning | 2006 | game-ai | A | MCP | UCT bandits (seminal). Auto-optimizing CV choice or targets by reply-rate bandits is an anti-candidate (tiny n, winner's curse). |
| `1539-adaptive-kv-retention-for-llm-agents-at-human-approval-timescales` | Adaptive KV Retention for LLM Agents at Human-Approval Timescales | 2026 | agents | A | mirror | KV retention while an agent waits for human approval. Serving-side; hireme does not serve models. |
| `002-efficient-memory-management-for-large-language-model-serving` | Efficient Memory Management for Large Language Model Serving with PagedAttention | 2023 | agents | A | MCP | PagedAttention/vLLM: representative of ~60 LLM-serving and KV-cache cards. hireme serves no model; skip the whole cluster. |
| `007-react-synergizing-reasoning-and-acting-in-language-models` | ReAct: Synergizing Reasoning and Acting in Language Models | 2023 | agents | B | mirror | ReAct thought/act loop (2023). The loop hireme MCP clients run; tool results must be compact observations. |
| `008-retrieval-augmented-generation-for-knowledge-intensive-nlp-t` | Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks | 2020 | agents | B | mirror | RAG (2020, seminal). Retrieval with document provenance; hireme `text`/`history` + citations are the retrieval surface. |
| `066-the-evolution-of-tool-use-in-llm-agents-from-single-tool-cal` | The Evolution of Tool Use in LLM Agents: From Single-Tool Call to Multi-Tool Orchestration | 2026 | agents | B | mirror | Tool-use survey: long-horizon multi-tool orchestration under state, feedback, safety/cost constraints. Checklist for MCP design. |
| `067-toolgate-token-efficient-pre-call-control-for-tool-augmented` | ToolGate: Token-Efficient Pre-Call Control for Tool-Augmented Vision-Language Agents | 2026 | agents | A | mirror | ToolGate: external execute/skip controller before tool output enters context. Agent-harness side; hireme cannot run it. |
| `071-meta-policy-reflexion-reusable-reflective-memory-and-rule-ad` | Meta-Policy Reflexion: Reusable Reflective Memory and Rule Admissibility for Resource-Efficient LLM Agent | 2025 | agents | D | mirror | Meta-Policy Reflexion: rule memory plus hard admissibility checks at inference. hireme kernel judge is the hard admissibility layer. |
| `085-self-rag-learning-to-retrieve-generate-and-critique-through-` | Self-RAG: Learning to Retrieve, Generate, and Critique through Self-Reflection | 2023 | agents | B | mirror | Self-RAG reflection tokens (is passage relevant / is output supported). The "supported?" question is what hireme provenance answers structurally. |
| `186-corrective-retrieval-augmented-generation` | Corrective Retrieval Augmented Generation | 2024 | agents | B | mirror | CRAG: grade retrieved set, then use/refine/fallback. Low relevance; see 169 for its evaluator shortcut. |
| `191-multihop-rag-benchmarking-retrieval-augmented-generation-for` | MultiHop-RAG: Benchmarking Retrieval-Augmented Generation for Multi-Hop Queries | 2024 | agents | B | mirror | MultiHop-RAG: retrievers fail beyond one hop. Agents researching corporations need structured joins (hireme `find`), not just text search. |
| `180-the-openhands-software-agent-sdk-a-composable-and-extensible` | The OpenHands Software Agent SDK: A Composable and Extensible Foundation for Production Agents | 2025 | agents | B | mirror | OpenHands SDK: small default interface, sandbox-portable execution, built-in security analysis. Reference agent harness. |
| `1116-skilleffect-checked-lowering-for-memory-bounded-agent-tools` | SkillEffect: Checked Lowering for Memory-Bounded Agent Tools | 2026 | agents | D | mirror | SkillEffect: checked lowering with atomic capacity leases and postconditions. hireme bulk lease contracts are the capacity-lease analogue. |
| `1824-lifefuse-mem-lifecycle-aware-state-fusion-against-temporary` | LifeFuse-Mem: Lifecycle-Aware State Fusion Against Temporary Overwriting for Long-Term Memory | 2026 | agents | B | mirror | LifeFuse-Mem: lifecycle labels keep temporary state from overwriting durable memory. hireme separates world facts (cited) from notes/battleplan (uncited prose). |
| `1536-harness-engineering-anatomy-architecture-and-evolution-of-coding-agent` | Harness Engineering: Anatomy, Architecture, and Evolution of Coding Agents -- A Source-Code Study of Eleven Systems | 2026 | agents | B | mirror | Harness engineering anatomy of eleven production coding harnesses. Background for MCP-as-harness design. |
| `1573-where-does-harness-optimization-value-live-localized-gains-and-the` | Where Does Harness-Optimization Value Live? Localized Gains and the Budget-Splitting Trap in Self-Evolving LLM Agents | 2026 | agents | B | mirror | Harness-evolution value concentrates in the reflection/control slot. Background: diagnostics and next-step text are hireme's control slot. |
| `1608-a-blind-trust-the-bloody-thrust-when-attacker-controlled-hook-updates` | A Blind Trust, the Bloody Thrust: When Attacker-Controlled Hook Updates Steer AI Agent Harnesses towards Malicious Behaviors | 2026 | agents | B | mirror | HookPry: attacker-controlled harness hooks run host-privileged shell. Agent-side supply chain; outside hireme. |
| `1643-forgetting-without-restarting-execution-state-unlearning-for-stateful` | Forgetting Without Restarting: Execution-State Unlearning for Stateful LLM Agents | 2026 | agents | B | mirror | Deleting a memory record is not forgetting (summaries, plans, KV keep it). hireme drop/tombstone does not reach agents' copies. |
| `1607-when-users-dont-ask-benchmarking-context-driven-memory-retrieval-in-co` | When Users Don't Ask: Benchmarking Context-Driven Memory Retrieval in Conversational Agents | 2026 | agents | B | mirror | LOCOMO-CONV: implicit/composed memory queries expose retrieval gaps. Background. |
| `1823-aim-a-privacy-aware-interoperable-memory-framework-for-multi-agent` | AIM: A Privacy-Aware Interoperable Memory Framework for Multi-Agent Multi-User LLM Systems | 2026 | agents | B | mirror | AIM: privacy-aware memory sharing across users without collapsing private scopes. hireme tenancy already isolates accounts. |
| `1771-se-gos-self-evolving-graph-of-skills-for-skill-library-at-scale` | SE-GoS: Self-Evolving Graph-of-Skills for Skill Library at Scale | 2026 | agents | B | mirror | SE-GoS: evolve a graph of skills from traces; fewer input tokens than dumping the library. Low. |
| `1577-skillglow-procedural-family-skill-consolidation-for-self-improving` | SkillGLoW: Procedural-Family Skill Consolidation for Self-Improving Agents on Long-Horizon Task Streams | 2026 | agents | B | mirror | SkillGLoW: consolidate skills into procedural families; commit priors only with live evidence. Low. |
| `1769-robustsgpo-search-space-control-for-agent-harness-evolution` | RobustSGPO: Search-Space Control for Agent Harness Evolution | 2026 | agents | A | mirror | RobustSGPO harness search under permission scheduling. Search-side; not for hireme. |
| `164-a-a-typed-lambda-calculus-for-llm-agent-composition` | $λ_A$: A Typed Lambda Calculus for LLM Agent Composition | 2026 | agents | A | mirror | Typed lambda calculus for agent composition (Coq). Theory; no hireme hook. |
| `177-learn-by-interact-a-data-centric-framework-for-self-adaptive` | Learn-by-interact: A Data-Centric Framework for Self-Adaptive Agents in Realistic Environments | 2025 | agents | B | mirror | Learn-by-interact: synthesize trajectories from documentation. Could seed eval tasks; low. |
| `114-inferring-strategies-from-limited-reconnaissance-in-real-tim` | Inferring Strategies from Limited Reconnaissance in Real-time Strategy Games | 2012 | game-ai | B | mirror | Beta-Binomial detection effort for unseen units. Could model ghosting/reply hazard; data too thin for one operator (inference). |
| `096-forward-modeling-for-partial-observation-strategy-games-a-st` | Forward Modeling for Partial Observation Strategy Games - A StarCraft Defogger | 2018 | game-ai | B | mirror | Defogging as state estimation. Same as 114. |
| `022-three-states-and-a-plan-the-ai-of-f-e-a-r` | Three States and a Plan: The AI of F.E.A.R. | 2006 | game-ai | B | mirror | F.E.A.R. GOAP with working-memory blackboard. Planning background. |
| `461-applying-goal-oriented-action-planning-to-games` | Applying Goal-Oriented Action Planning to Games | 2003 | game-ai | B | mirror | GOAP (Orkin 2003). Planning background. |
| `126-a-survey-of-planning-techniques-for-agents-in-games` | A Survey of Planning Techniques for Agents in Games | 2006 | game-ai | B | mirror | Orkin GDC 2006 planning survey. Background. |
| `2236-statecharts-a-visual-formalism-for-complex-systems` | Statecharts: A Visual Formalism for Complex Systems | 1987 | game-ai | D | mirror | Statecharts (seminal 1987). hireme pipeline rail is already a flat state machine with legal moves. |
| `2302-vec-qmdp-vectorized-pomdp-planning-on-cpus-for-real-time-autonomous-dr` | Vec-QMDP: Vectorized POMDP Planning on CPUs for Real-Time Autonomous Driving | 2026 | game-ai | B | mirror | Vectorized POMDP planning. Planning under uncertainty background. |
| `2293-spirebench-evaluating-long-horizon-strategic-play-of-agentic-models` | SpireBench: Evaluating Long-Horizon Strategic Play of Agentic Models with Slay the Spire | 2026 | game-ai | B | mirror | SpireBench: LLMs on long-horizon strategy; frontier below experts. |
| `2343-starskirmish-bench-v0-2-llms-write-starcraft-brood-war-bots` | StarSkirmish Bench v0.2: LLMs write StarCraft: Brood War bots in one hour | 2026 | game-ai | B | mirror | StarSkirmish: LLMs write bots in their own CLI harness. Eval background. |
| `1775-ibib-a-protocol-for-measuring-enterprise-ai-systems-by-serving-route` | IBIB: A Protocol for Measuring Enterprise AI Systems by Serving Route, Not Model Identifier | 2026 | agents | B | mirror | IBIB: score systems by serving route (weights x precision x contract x harness). Record model + harness when evaluating agents. |
| `2342-claude-reveals-ecdsa-curve-origins` | Claude reveals ECDSA curve origins | 2026 | agents | B | mirror | Claude research model found NIST curve-seed origins. Capability datapoint only. |
| `197-ggpo-rollback-networking` | GGPO Rollback Networking | 2006 | realtime | D | MCP | GGPO rollback netcode. hireme replica already predicts and rolls back on refusal. |
| `471-ggpo-overview-and-design-notes` | GGPO Overview and Design Notes | 2019 | realtime | D | mirror | GGPO design notes. Same. |
| `269-client-side-prediction-server-reconciliation` | Client-Side Prediction & Server Reconciliation | 2013 | realtime | D | MCP | Client-side prediction + server reconciliation. hireme optimistic writes + authoritative sequencer. |
| `412-quake-iii-arena-networking-source` | Quake III Arena Networking Source | 1999 | realtime | D | mirror | Quake III delta snapshots against acked frame. hireme BOOT + PATCH deltas. |
| `331-state-synchronization` | State Synchronization | 2015 | realtime | D | mirror | State synchronization over lockstep. hireme streams state, not inputs. |
| `465-virtual-time-time-warp-optimistic-distributed-simulation` | Virtual Time | 1985 | realtime | D | MCP | Time Warp optimistic simulation with antimessages. Rollback background. |
| `228-an-asynchronous-scheme-for-rollback-recovery-in-message-pass` | An Asynchronous Scheme for Rollback Recovery in Message-Passing Concurrent Programming Languages | 2023 | realtime | B | mirror | Asynchronous rollback recovery for message-passing languages (check/commit/rollback). BEAM-adjacent; systems researcher's lane. |

#### Findings on agent interfaces, approval, failures, cost and provenance
**Approval and authority**
- Approve What, Exactly? ([obs:2314](https://observer.anoptic.io/mcp), [arXiv 2610.21063](https://arxiv.org/abs/2610.21063), Kodathala, Pollishetty and Cargill, 15 Oct 2026):
  - An approval is a real second factor only if the agent cannot produce it and it names the exact effect that will run.
  - Twelve approval-path attacks break AP2, a Microsoft action-bound approval design and MCP elicitation.
  - An audit of agent runtimes found "post-approval argument changes in four of eight runtimes with measurable binding".
  - The proposed gateway renders the approval card from a canonical effect descriptor, and a passkey signs its digest. This cuts forged-narration success from 0.54 to 0.03 (27,108 scripted trials, 609 AgentDojo attack pairs).
  - With 15 LLMs as automated approvers, the catch rate rises from 0.30 to 0.98, but 16% of harmless near misses are refused. Flooding still succeeds 0.45-0.60 of the time.
  - Code, data and Tamarin proofs (53 lemmas) are released — [arXiv abstract](https://arxiv.org/abs/2610.21063); [obs:2314](https://observer.anoptic.io/mcp)
- Names Are Not Objects: most deployed-agent exploits approve a name (path, argv, repository) that later resolves to a different object. Confinement must decide on the concrete object and re-check it at use — [obs:2284](https://observer.anoptic.io/mcp) ([arXiv 2610.14488](https://arxiv.org/abs/2610.14488))
- SARA treats tool output that specifies an action as a command. It authorizes tool calls only against the user objective, so "the tool said to" is never sufficient. The card gives no benchmark numbers — [obs:1449](https://observer.anoptic.io/mcp) ([arXiv 2608.27146](https://arxiv.org/abs/2608.27146))
- VP-CONTROL commit gates (48 templates, 2,880 scenarios, six fault regimes): cross-model votes over shared evidence still approve a large fraction of unsafe proposals. Diversity of verifier models is not diversity of evidence sources — [obs:1803](https://observer.anoptic.io/mcp) ([arXiv 2609.10969](https://arxiv.org/abs/2609.10969))
- Humanize: a human approves a plan contract, and deterministic hooks, not a model, route work and enforce 72 mechanical gates. Stopping is the weak point: two thirds of rounds happened after implementation was already accepted. The evidence is observational — [obs:2241](https://observer.anoptic.io/mcp) ([arXiv 2610.08900](https://arxiv.org/abs/2610.08900))

**Silent failures and tool feedback**
- Outcome Monitors ([obs:1144](https://observer.anoptic.io/mcp), [arXiv 2608.19303](https://arxiv.org/abs/2608.19303), Panthi and Abdelfattah, 19 Aug 2026):
  - Mining outcome contracts and appending a nonbinding receipt (violations plus admissible recovery tools) raises ToolMaze completion from 10.9% to 28.1% across four models in two families, and it replicates in a third.
  - τ-bench retail completion rises by 14.0 and 12.0 points on two tiers.
  - Outside the mined vocabulary, detection falls to 46%.
  - The card adds a cost of +7% list price against +498% for a reviewer loop (not in the abstract), and notes that stripping the recovery-tool list removes the gain.
- Loud Failures, Quiet Failures ([obs:2244](https://observer.anoptic.io/mcp), [arXiv 2610.10062](https://arxiv.org/abs/2610.10062), 7 Oct 2026; 1,920 trials, 24 tasks, six models):
  - Agents notice an explicit error 91.3% of the time but a plausible wrong value only 58.8%, with a 26.8% false-alarm rate.
  - Reasoning variants notice less (−9.3 points).
  - Two fault-free runs end in the same state only 63.3% of the time.
  - After a fault, agents repeat the same tool three or more times in up to 22.2% of trials.
  - The card adds that a prompt line asking for a check after each call did not move detection.
- Feedback That Backfires (six checkpoints of 135M-1.7B): appending a failed call raises P(repeat that call) from 0.06 to 0.54, and surface form accounts for 83% of the damage. "Do not repeat" does not undo it. The remedy is a runtime-generated description of the failure instead of the verbatim call — [obs:1368](https://observer.anoptic.io/mcp) ([arXiv 2608.23651](https://arxiv.org/abs/2608.23651))

**Cost and tool catalogue**
- TurnCost ([obs:2287](https://observer.anoptic.io/mcp), [arXiv 2610.15093](https://arxiv.org/abs/2610.15093), Kumar and Pandey, 10 Oct 2026):
  - 600 trajectories; 98.6% of input tokens are served from a prefix cache.
  - Flat pricing overstates loop cost about 7×.
  - Turn count explains 84% of the variance in log cost; mean observation size explains 4%.
  - Median observations are 118-286 tokens.
  - Caveat from the card: the authors do not show that turns can be removed at fixed task success.
- Schema-first tool APIs: JSON Schema contracts cut interface misuse compared with free-form docs, but in this local-model pilot they do not raise task success, which stays zero in every condition — [obs:065](https://observer.anoptic.io/mcp) ([arXiv 2603.13404](https://arxiv.org/abs/2603.13404))
- Lost in Implicit Routing: adding 1,000 irrelevant skills drops loaded-skill recall from 73.6% to 27.4% and raises the zero-load rate from 9.3% to 51.6%. Explicit preselection keeps 73.9% — [obs:2286](https://observer.anoptic.io/mcp) ([arXiv 2610.18522](https://arxiv.org/abs/2610.18522))
- Nexus: routing accuracy is 92/90/89/89% at 10/50/100/250 MCP tools on one hardware setup. Concatenating every schema runs out of memory beyond 10 tools — [obs:1233](https://observer.anoptic.io/mcp) ([arXiv 2608.20397](https://arxiv.org/abs/2608.20397))
- SWE-agent (NeurIPS 2024): a purpose-built agent-computer interface lifts GPT-4 Turbo from 3.8% to 12.47% on SWE-bench. Removing the linter-gated editor drops Lite from 18.0% to 10.3% — [obs:001](https://observer.anoptic.io/mcp) ([arXiv 2405.15793](https://arxiv.org/abs/2405.15793))

**Plans, memory and provenance**
- PlanFence ([obs:1579](https://observer.anoptic.io/mcp)). The paper is now titled "Fresh Memory, Stale Plans: Derivation Currency for Distributed LLM-Agent Memory" (Chen, Wang and Brinton; v1 3 Sep, v2 27 Sep 2026; the card carries the older subtitle):
  - 30 live five-agent workflows, with a revision inserted after planning.
  - A freshness-only executor "acts on the stale plan every time"; PlanFence "completes all 30 correctly".
  - Stall cost is 143-237 ms per action. Per-update synchronization instead grows from 52 to 1196 ms.
  - Scoped validation traffic is 8.1 KiB per action, a tenth of all-key validation at 128 keys — [arXiv 2609.03340](https://arxiv.org/abs/2609.03340)
- Correct Is Not Governed: direct RAG took 15/15 expected actions but made 6/15 unsupported citations. Dependency-scoped invalidation reissued 3 tasks against 18 for a full rerun. A transfer study scored specificity 0.00 — [obs:1018](https://observer.anoptic.io/mcp) ([arXiv 2608.12761](https://arxiv.org/abs/2608.12761))
- The Truth Maintenance System (Doyle 1979, seminal and still the reference design) keeps a justification for every belief, retracts consequences when support goes, and traces contradictions back to assumptions — [obs:2235](https://observer.anoptic.io/mcp)
- TEPA: on full reversal, append-only and last-write-wins memories fall below a no-memory baseline. Keyed revocation that keeps the audit history stays near 0.95 — [obs:171](https://observer.anoptic.io/mcp) ([arXiv 2608.07429](https://arxiv.org/abs/2608.07429))
- Memory portability: after a writer-model swap, fixed-schema knowledge graphs change accuracy by +0.0004 ± 0.0020, while model-compressed notes are tightly coupled to the writer. The study used 48 synthetic histories and two models under 10B — [obs:1642](https://observer.anoptic.io/mcp) ([arXiv 2609.05339](https://arxiv.org/abs/2609.05339))
- Position paper: multi-agent failures blamed on coordination are often lost updates and stale reads across long inference windows, which calls for concurrency control. It gives no numbers — [obs:1120](https://observer.anoptic.io/mcp) ([arXiv 2608.18092](https://arxiv.org/abs/2608.18092))

**Reports and failure localization**
- What Coding Agents Leave Unsaid (37 tasks, 4,799 probes; [obs:2313](https://observer.anoptic.io/mcp), [arXiv 2610.20003](https://arxiv.org/abs/2610.20003)):
  - Readers of the agent's reports alone recover 52.0% of task-state answers, against 92.7% with full context. The 40.7-point gap stays at 34.8 points at the final checkpoints of 30 verified fixes.
  - Full terminal scrollback reaches 73.6%.
- Evidence-carrying termination: 0/288 unsafe completions, against 252/288 for an inspected termination critic — [obs:1367](https://observer.anoptic.io/mcp) ([arXiv 2608.23623](https://arxiv.org/abs/2608.23623))
- Source-Judged Compaction: 83% of failed runs trace to an action that carries out a specific summary entry. Dropping unsourced entries lifts cross-run reliability by 2.1-8.9% on AppWorld and OfficeBench, at no extra agent tokens — [obs:2312](https://observer.anoptic.io/mcp) ([arXiv 2610.20927](https://arxiv.org/abs/2610.20927))
- QuoteBench: matched success hides a 55-73 point collapse on a nested quoting path. Exit codes miss 23-47% of failures, so exact final-state validators are needed — [obs:1013](https://observer.anoptic.io/mcp) ([arXiv 2608.13547](https://arxiv.org/abs/2608.13547))
- Harness or Model?: on 256 private tasks, harness choice moves solve rate under a fixed LLM. The paper recommends paired same-model contrasts — [obs:1822](https://observer.anoptic.io/mcp) ([arXiv 2609.11987](https://arxiv.org/abs/2609.11987))
- Safety Does Not Compose: against attacks fragmented across loop iterations, trajectory-scoped monitors are no better than chance; a monitor that keeps cross-iteration state separates them — [obs:1450](https://observer.anoptic.io/mcp) ([arXiv 2608.27141](https://arxiv.org/abs/2608.27141))

**Teams and skills**
- Parallel sub-agents: across 2,124 matched executions the success effect ranged from −11.9 to +2.3 points, while token use rose 1.41-3.31× — [obs:2243](https://observer.anoptic.io/mcp) ([arXiv 2610.10263](https://arxiv.org/abs/2610.10263))
- Teams of coding agents cost 3-7×. Workers are worth most as planners, and gains plateau beyond four workers — [obs:2288](https://observer.anoptic.io/mcp) ([arXiv 2610.17471](https://arxiv.org/abs/2610.17471))
- Agent Workflow Memory: induced workflows lift relative success by 24.6% on Mind2Web and 51.1% on WebArena — [obs:072](https://observer.anoptic.io/mcp) ([arXiv 2409.07429](https://arxiv.org/abs/2409.07429))
- Cortex ([obs:2285](https://observer.anoptic.io/mcp), [arXiv 2610.14216](https://arxiv.org/abs/2610.14216), Giampieri):
  - A rule or skill change is kept only if repeated with/without runs show a net gain.
  - With Claude Haiku 4.5, rules "did most of the work"; skills offered on every turn "were rarely opened".
  - Under Claude Sonnet 5, a single run's harness "added little".
  - It "reached no verdict on the harmful rules".
- Skill misevolution: all 21 evolved configurations author unsafe artifacts. Raising malicious tasks from 0 to 3 lifts carryover attack success from 16.0% to 35.3% — [obs:1015](https://observer.anoptic.io/mcp) ([arXiv 2608.12851](https://arxiv.org/abs/2608.12851))
- Winner's curse: keep-if-better loops overstate held-out accuracy by 13-20 points with 16 selection items and 1-5 points with 256. Scoring on 64 held-out items "removes the average bias", but single estimates stay off by about 6 points — [obs:2242](https://observer.anoptic.io/mcp) ([arXiv 2610.09239](https://arxiv.org/abs/2610.09239))

#### hireme facts these findings meet
**`open_fire` and the CV version that goes out**
- The `open_fire` command only moves `fire_ready` to `open_fire`. It records nothing about the CV, letter or listing being approved — [native/kernel/src/judge.rs:496-505](../../native/kernel/src/judge.rs)
- The CV version is frozen only when the application goes out to `submitted`, as the pick's version at that moment ("Going out freezes the CV version that went: the pick's.") — [native/kernel/src/judge.rs:463-470](../../native/kernel/src/judge.rs)
- `pick_cv` and `unpin_cv` have no stage guard — [native/kernel/src/judge.rs:535-549](../../native/kernel/src/judge.rs)
- No fire-stage write guard exists in the sequencer or lease modules (searched [lib/hireme/sequencer.ex](../../lib/hireme/sequencer.ex), [lib/hireme/lease.ex](../../lib/hireme/lease.ex), [lib/hireme/grants.ex](../../lib/hireme/grants.ex)).
- The column `cv_version_id ref cv_versions ? readonly` exists — [schema/hireme.schema:402](../../schema/hireme.schema)
- The operator's rule, verbatim: "FIRE HOLD stands: nothing submits an application; naming open fire is a human act (`open_fire` is a `human_only` command)." — [docs/rebuild.md](../rebuild.md)

**What a write returns**
- A write ACK on the MCP is one line, `ok: <label> -> id N, rev R`. It carries no derived state — [lib/hireme_web/mcp.ex:1073](../../lib/hireme_web/mcp.ex)
- A `warning[...]` line channel already exists, for claims cut short — [lib/hireme_web/mcp.ex:927](../../lib/hireme_web/mcp.ex)
- Refusals are rustc-style diagnostics ending in `hireme {"explain":"<code>"}`. Checks run in the order grant, lease, shape, domain, provenance, limits — [native/mcp/src/diag.rs:49](../../native/mcp/src/diag.rs)

**Telemetry and next steps**
- The audit row for an agent's op batch records `count`, `acks` and `nacks`, but no refusal codes — [lib/hireme/sequencer.ex:592](../../lib/hireme/sequencer.ex)
- The `hireme` overview's `next` text is about the channel state: paused, read-only, no lease, unknown operator, or lease open. It says nothing about the work — [lib/hireme_web/mcp.ex:1150-1165](../../lib/hireme_web/mcp.ex)

**MCP surface**
- The tool list is 12 fixed tools plus one per declared command. Seven commands are declared, and `human_only` `open_fire` is never listed, so a key sees at most 18 tools, fewer under narrower masks — [native/mcp/src/tools.rs](../../native/mcp/src/tools.rs); [schema/hireme.schema:394-436](../../schema/hireme.schema)
- `cv {}` lists unsettled CV picks; `cv {"check": pattern, "position": n}` judges a mask pattern with byte-span errors; `cv {"fields": true}` lists testable fields — [native/mcp/src/tools.rs:213-226](../../native/mcp/src/tools.rs)
- The MCP lists no resources and declares no prompts capability — [lib/hireme_web/mcp.ex:801](../../lib/hireme_web/mcp.ex)
- Untrusted text is returned between random `UNTRUSTED-<fence>` lines — [lib/hireme_web/mcp.ex:1293-1304](../../lib/hireme_web/mcp.ex)

**Score, heat and tooling**
- The score suggestion carries `{score, band, kill, anchored}` and no breakdown — [native/kernel/src/score.rs:96](../../native/kernel/src/score.rs)
- The docs name known false anchors ("Apple Valley Bakery") and the limits of pay reading — [docs/score.md](../score.md)
- The heat governor finds an exact `cooldown_days`: each failing check "is searched for its own first passing day and the latest of those is the answer" — [docs/heat.md:84](../heat.md)
- `bench/` holds `kernel.mjs`, `netns.sh` and `wire.exs` (performance) and no agent-evaluation harness — [bench/](../../bench)

### Inferences
**Already aligned: do not rebuild**
- Masks and leases outside the model context are CapScope's typed capabilities ([obs:1767](https://observer.anoptic.io/mcp)).
- The kernel judge is a deterministic, schema-checked gate of the kind NOMOS compiles ([obs:2257](https://observer.anoptic.io/mcp)).
- FIRE HOLD is Humanize's human-approved boundary ([obs:2241](https://observer.anoptic.io/mcp)).
- The rustc-style refusals already describe the failure and print the corrected call shape instead of echoing the call ([obs:1368](https://observer.anoptic.io/mcp), [obs:065](https://observer.anoptic.io/mcp)).
- Fenced untrusted text matches SARA's rule that observations never authorize ([obs:1449](https://observer.anoptic.io/mcp)).
- The append-only audit and ledger match the DeepSeek harness's append-only session log ([obs:1050](https://observer.anoptic.io/mcp)).
- Citations with `stale` refusals implement TEPA- and MemoryLACE-style supersession ([obs:171](https://observer.anoptic.io/mcp), [obs:1606](https://observer.anoptic.io/mcp)).
- Typed fixed-schema rows are the memory shape that survives model upgrades ([obs:1642](https://observer.anoptic.io/mcp)).
- Explicit lease claims are concurrency control ([obs:1120](https://observer.anoptic.io/mcp)).
- A mask-filtered tool list of at most 18 is far from the routing-collapse regime ([obs:2286](https://observer.anoptic.io/mcp)).
- The optimistic replica with server rollback is GGPO and Quake-style netcode (realtime cards 197, 269, 412, 331).

**The highest-value moves, in order**
1. Bind the human approval to the exact effect. This is a verified gap and the corpus's most direct, freshest, best-measured finding for hireme.
2. Make writes loud: return derived state and conservative receipts in every ACK.
3. Localize failures with the six-check order hireme already has.
4. Validate read sets.

Section 3 ranks these with the operator-facing items.

**Evidence quality**
- Most agent cards are arXiv preprints from the past 1-10 weeks.
- Many are single-group or single-benchmark studies.
- The strongest numbers come from controlled but synthetic setups: ToolMaze, scripted approval trials, synthetic histories.

So use the corpus for mechanisms and failure taxonomies, and treat magnitudes as indicative.

### Gaps
- **Open implementations.** I could not confirm open code for obs 1144, 2244, 2287, 1579, 2313 or 2257. Each abstract page was read, but no code link was checked. Only obs 2314 states a release (GitHub, Sports-Vision-Inc organization).
- **Full papers not read.** I read only the arXiv abstract pages for the verified items. Claims that appear only on the card (for example obs 1144's +7% cost, and obs 1625's validator) are marked as card-only.
- **Live sweep.** Because of the 403s, the live MCP sweep stopped after 5 successful searches. Hit counts for the other 773 queries come from the calibrated local emulation, not from the hosted server.
- **Missing topics.** The corpus holds no cards on job search, hiring, recommender systems, explainability, calibration or email outreach; those keyword queries returned 0 hits.

## 2. Which cards suggest techniques for the operator-facing features: ranking and prioritizing applications, explaining scores, natural-language commands over the desk, and planning a campaign under constraints such as the heat governor?

### Takeaway
The game-AI pool, not the LLM cards, carries the operator-facing techniques:
- build-order optimization over a fast-forward simulator ([obs:118](https://observer.anoptic.io/mcp)), plus ordered HTN planning, gives a heat-aware fire calendar;
- utility-AI considerations and Halo's designer-readable rules give a score explanation ledger;
- teleo-reactive rules and Halo 3 objectives give a deterministic "what next" queue;
- an LLM that translates into a constrained DSL ([obs:1625](https://observer.anoptic.io/mcp), [obs:2257](https://observer.anoptic.io/mcp)) gives natural-language desk commands that the kernel still validates.

All except the NL translator are deterministic and can stay inside the kernel.

### Cited Findings
**Planning under constraints**
- Build Order Optimization in StarCraft (Churchill and Buro, AIIDE 2011, seminal):
  - Makespan-minimal build orders come from depth-first branch-and-bound over a fast-forward simulator.
  - The simulator issues every action at its earliest legal frame.
  - It uses landmark and resource-goal lower bounds, plus K-repeat macro actions, to stay online.
  - "Optimal" means optimal inside the paper's abstractions — [obs:118](https://observer.anoptic.io/mcp) ([DOI](https://doi.org/10.1609/aiide.v7i1.12435))
- SHOP (IJCAI 1999) plans HTN tasks in the order they will execute, so the full world state is known at every step. It beat Blackbox and TLplan by orders of magnitude on blocks-world and logistics — [obs:1629](https://observer.anoptic.io/mcp)
- SHOP2 (2003) evaluates method preconditions against the current state and interleaves planning with execution — [obs:296](https://observer.anoptic.io/mcp)
- ART-HTN (AIIDE 2021, Square Enix): a cheap simulator emits a branched Situation-Task Network, and a plan executor picks a live branch instead of replanning on every surprise — [obs:1492](https://observer.anoptic.io/mcp) ([DOI](https://doi.org/10.1609/aiide.v17i1.18910))
- Liu and Layland (1973): rate-monotonic scheduling is optimal among fixed-priority schedulers, with a utilization bound tending to 69%. Earliest-deadline-first is optimal among dynamic schedulers — [obs:380](https://observer.anoptic.io/mcp)
- D* Lite (2002) replans incrementally, reusing previous search values when the map changes — [obs:1137](https://observer.anoptic.io/mcp)

**Explaining scores**
- Game AI Pro utility architectures: a consideration is a normalized [0,1] response curve of one input. An action's score is usually the product of its considerations, so a single zero vetoes. Inertia stops flicker — [obs:395](https://observer.anoptic.io/mcp) ([Game AI Pro chapter](https://www.gameaipro.com/GameAIPro/GameAIPro_Chapter09_An_Introduction_to_Utility_Theory.pdf))
- Behavioral Mathematics for Game AI and Mark and Dill's GDC 2010 talk are the practitioner sources for considerations and response curves — [obs:351](https://observer.anoptic.io/mcp), [obs:275](https://observer.anoptic.io/mcp)
- Halo 2's AI paid for its complexity "in designer-readable rules, not in a soup of utility floats". Halo 1 framed AI as legible behaviour for the player — [obs:930](https://observer.anoptic.io/mcp), [obs:360](https://observer.anoptic.io/mcp), [obs:929](https://observer.anoptic.io/mcp)
- An open reproduction of Corrective RAG used SHAP to show that its T5 retrieval evaluator mostly checks named-entity overlap. Explanations exposed what the scorer actually keys on — [obs:169](https://observer.anoptic.io/mcp) ([arXiv 2603.16169](https://arxiv.org/abs/2603.16169))
- Valve's response rules (GDC 2012) let the rule with the most criteria win. Non-programmers own the rules — [obs:1842](https://observer.anoptic.io/mcp)

**Choosing the next action**
- Teleo-reactive programs (Nilsson, JAIR 1994) are ordered condition→action lists. The first true condition runs, and when each condition is the regression of a higher one, the program reaches the goal from anywhere — [obs:2356](https://observer.anoptic.io/mcp) ([arXiv cs/9401101](https://arxiv.org/abs/cs/9401101))
- Halo 3 objectives (GDC 2008) are a declarative tree of prioritized tasks with capacities that distribute squads, rather than scripting each actor — [obs:931](https://observer.anoptic.io/mcp)
- SLEUTH keeps Confirmed Facts, ranked Active Hypotheses and Open Questions, and the Open Questions drive the next action. It gains +5 on HotpotQA and +11 on 4-hop chains — [obs:068](https://observer.anoptic.io/mcp) ([arXiv 2607.12267](https://arxiv.org/abs/2607.12267))
- Environment-probing curation re-queries the live environment instead of trusting finished trajectories, which cuts stale and overgeneralized memories. The card gives no numbers — [obs:1802](https://observer.anoptic.io/mcp) ([arXiv 2609.11060](https://arxiv.org/abs/2609.11060))

**Natural-language commands**
- Real-Time World Crafting (Drake and Dong, Wordplay at EMNLP 2025):
  - An LLM translates commands into a constrained DSL that configures an entity-component system at runtime.
  - The abstract reports no quantitative results.
  - The abstract does not mention the validator and fizzle default that the card describes — [obs:1625](https://observer.anoptic.io/mcp) ([arXiv 2510.16952](https://arxiv.org/abs/2510.16952))
- NOMOS (Yu, Kim and Choi; v2 14 Oct 2026) compiles written policy into a deterministic tool-call gate:
  - Schema-level checks alone repair or reject 37% (airline) and 13% (retail) of candidate rules.
  - Violations drop from 66.3% to 2.6% (airline) and from 30.8% to 6.9% (retail).
  - AgentDojo attack success is 0 on banking and at most 3.6% elsewhere. Decisions take microseconds without an LLM call.
  - In a replay audit, a development binding refused 95.9% of task-passing calls — [obs:2257](https://observer.anoptic.io/mcp) ([arXiv 2610.11030](https://arxiv.org/abs/2610.11030))
- SHRDLU (1972) grounded English commands in a world model and could answer "why did you do that?" — [obs:1076](https://observer.anoptic.io/mcp)
- TextStarCraft's Chain of Summarization compresses game state into commands an LLM can issue — [obs:076](https://observer.anoptic.io/mcp)

**Partial observability**
- A dynamic Bayes net infers unseen units from failed searches, with Beta-Binomial detection effort (UAI 2012) — [obs:114](https://observer.anoptic.io/mcp) ([arXiv 1210.4880](https://arxiv.org/abs/1210.4880))

**hireme facts**
- Ranking: "maximize life EV, not the number of applications", and the kernel "**suggests** and never overwrites" — [docs/score.md](../score.md)
- The board ranks by score, then heat (cool first) — [docs/heat.md](../heat.md)
- The CV masks are a typed pattern DSL with ordered first-match rules and shadowing checks — [native/kernel/src/mask.rs](../../native/kernel/src/mask.rs); [native/kernel/src/pick.rs](../../native/kernel/src/pick.rs)
- Commit 93ad825 added an "Understood" read-back that shows what the "you" form parsed before saving — `git log` in the repo.

### Inferences
- **Fire calendar.** The heat governor is already the fast-forward simulator that build-order search needs, and its exact `cooldown_days` is the "earliest legal frame". A fire calendar is therefore mostly a loop over existing functions (shortlist #3).
- **Score explanation.** The score ladder is a rule ladder: anchors, kills, then heuristic deltas, clamped. Utility-AI practice says to show the considerations. The CRAG-SHAP result shows why: explanations expose shortcuts such as hireme's documented anchor-word false matches (shortlist #5).
- **Next-step queue.** hireme's `cv_rules` already have teleo-reactive semantics (ordered, first true wins). The same shape over pipeline facts gives each application a deterministic next step and gives agents a research-gap queue (shortlist #6).
- **NL commands.** The safe pattern for natural language is translation into hireme's existing typed DSLs, then kernel validation, then a read-back. The LLM never acts (shortlist #9). Its value is lower than the deterministic items because the operator can already type the DSL.
- **Reply hazard (not shortlisted).** Fog-of-war inference ([obs:114](https://observer.anoptic.io/mcp)) suggests a reply-hazard model to suggest "likely ghosted", but one operator's outcomes are too few to fit it.

### Gaps
- The corpus has no cards on recommenders, person-job fit, explainable ranking or calibration. The sibling note [sota-techniques-for-hireme-matching-ranking-learning.md](sota-techniques-for-hireme-matching-ranking-learning.md) covers matching and ranking from outside the corpus.
- I could not measure whether a greedy fire calendar over at most about 100 queued applications fits under 10 ms in WebAssembly. It is plausible, because each governor check is a scan over sent applications, but unmeasured.
- The build-order card gives no numeric results. Its "optimal within abstractions" caveat transfers: the calendar is exact only for the governor's own model.

## 3. Ranked shortlist: technique, evidence, recency, implementations, where it plugs into hireme, cost and risk

### Takeaway
Nine candidates, in order:
1. Effect-bound `open_fire` (I4 F5 N4)
2. Loud write ACKs with derived state and receipts (I4 F4 N4)
3. Heat-aware fire calendar (I4 F4 N2)
4. Failure localization by check, plus ledger-derived session reports (I3 F5 N3)
5. Score explanation ledger (I3 F5 N2)
6. Research-gap queue for agents (I3 F4 N3)
7. Read-set validation, which is planset candidate 3 (I3 F3 N4)
8. Measurement-gated playbooks with an execution-graded MCP task suite (I3 F3 N3)
9. Natural-language desk commands compiled to the mask DSL (I2 F3 N3)

Items 1, 2, 4 and 5 are small kernel or MCP edits; 3 and 6 are new deterministic derivations; 7 to 9 are larger.

### Cited Findings
Evidence and recency for each item, as verified this session:
- **#1** rests on [obs:2314](https://observer.anoptic.io/mcp) (arXiv 2610.21063, 15 Oct 2026; abstract verified; code, data and proofs released). [obs:2284](https://observer.anoptic.io/mcp) (Oct 2026), [obs:1018](https://observer.anoptic.io/mcp) (Aug 2026), [obs:2241](https://observer.anoptic.io/mcp) (Oct 2026) and [obs:1366](https://observer.anoptic.io/mcp) (Aug 2026) support it, all card-level — [arXiv 2610.21063](https://arxiv.org/abs/2610.21063)
- **#2** rests on [obs:1144](https://observer.anoptic.io/mcp) (Aug 2026, abstract verified), [obs:2244](https://observer.anoptic.io/mcp) (Oct 2026, verified), [obs:2287](https://observer.anoptic.io/mcp) (Oct 2026, verified) and [obs:1368](https://observer.anoptic.io/mcp) (Aug 2026, card) — [arXiv 2608.19303](https://arxiv.org/abs/2608.19303); [arXiv 2610.10062](https://arxiv.org/abs/2610.10062); [arXiv 2610.15093](https://arxiv.org/abs/2610.15093)
- **#3** rests on [obs:118](https://observer.anoptic.io/mcp) (AIIDE 2011, seminal, still the standard formulation in the card's lineage) and [obs:1629](https://observer.anoptic.io/mcp)/[obs:296](https://observer.anoptic.io/mcp) (1999/2003, seminal), with [obs:1492](https://observer.anoptic.io/mcp) (2021) and [obs:380](https://observer.anoptic.io/mcp) (1973) — [DOI 10.1609/aiide.v7i1.12435](https://doi.org/10.1609/aiide.v7i1.12435)
- **#4** rests on [obs:2313](https://observer.anoptic.io/mcp) (Oct 2026, verified), [obs:1575](https://observer.anoptic.io/mcp), [obs:1822](https://observer.anoptic.io/mcp), [obs:1013](https://observer.anoptic.io/mcp), [obs:1450](https://observer.anoptic.io/mcp) and [obs:1367](https://observer.anoptic.io/mcp) (Aug-Sep 2026, card-level) — [arXiv 2610.20003](https://arxiv.org/abs/2610.20003)
- **#5** rests on practitioner sources ([obs:395](https://observer.anoptic.io/mcp) 2013, [obs:351](https://observer.anoptic.io/mcp) 2009, [obs:930](https://observer.anoptic.io/mcp) 2005), with [obs:169](https://observer.anoptic.io/mcp) (2026) for shortcut exposure. There is no controlled study — [arXiv 2603.16169](https://arxiv.org/abs/2603.16169)
- **#6** rests on [obs:068](https://observer.anoptic.io/mcp) (Jul 2026, card: +5 to +11 on multi-hop), [obs:1802](https://observer.anoptic.io/mcp) (Sep 2026), [obs:2356](https://observer.anoptic.io/mcp) (1994, seminal) and [obs:931](https://observer.anoptic.io/mcp) (2008, practitioner).
- **#7** rests on [obs:1579](https://observer.anoptic.io/mcp) (v2 27 Sep 2026, abstract verified; 30/30 workflows correct, against stale-plan action every time for a freshness-only executor), [obs:2235](https://observer.anoptic.io/mcp) (1979, seminal) and [obs:171](https://observer.anoptic.io/mcp) (Aug 2026) — [arXiv 2609.03340](https://arxiv.org/abs/2609.03340)
- **#8** rests on [obs:072](https://observer.anoptic.io/mcp) (2024; +24.6%/+51.1% relative), [obs:2285](https://observer.anoptic.io/mcp) (Oct 2026, verified), [obs:2286](https://observer.anoptic.io/mcp) (Oct 2026, verified), [obs:1015](https://observer.anoptic.io/mcp), [obs:2242](https://observer.anoptic.io/mcp) (Oct 2026, verified) and [obs:192](https://observer.anoptic.io/mcp) (OSWorld: 369 execution-graded tasks; humans 72.36%, best model 12.24%; environment published at os-world.github.io) — [arXiv 2610.14216](https://arxiv.org/abs/2610.14216); [arXiv 2610.18522](https://arxiv.org/abs/2610.18522); [arXiv 2610.09239](https://arxiv.org/abs/2610.09239); [arXiv 2404.07972](https://arxiv.org/abs/2404.07972)
- **#9** rests on [obs:1625](https://observer.anoptic.io/mcp) (2025 workshop paper; abstract has no numbers) and [obs:2257](https://observer.anoptic.io/mcp) (Oct 2026, abstract verified) — [arXiv 2510.16952](https://arxiv.org/abs/2510.16952); [arXiv 2610.11030](https://arxiv.org/abs/2610.11030)

### Inferences
**#1. Effect-bound `open_fire`: approval names exactly what goes out.** I4 F5 N4.

- **Technique.** Make the human approval bind a canonical effect descriptor:
  - the application's `no`;
  - the CV version id and its blob SHA (or body hash);
  - a hash of `letter_raw`;
  - the listing's `canonical_url` and `listing_raw` hash.

  Render that descriptor in the operator's own client. Refuse or void any later change to a bound input. Bind objects (version id, SHA), not names (CV root name), as [obs:2284](https://observer.anoptic.io/mcp) says.
- **Why it matters for hireme.** Today `open_fire` binds nothing. The CV version is chosen only when `submitted` is recorded, and agents can still `pick_cv` or `unpin_cv`, upload a new head version to the picked root, or rewrite `letter_raw` after the operator's approval. That is the "post-approval argument change" class that [obs:2314](https://observer.anoptic.io/mcp) found in 4 of 8 runtimes. The application stays approved while what it would send has changed, and the CV recorded as sent may not be the one the operator looked at.
- **Where it plugs in.**
  1. In [judge.rs](../../native/kernel/src/judge.rs) `command::OPEN_FIRE`, freeze `cv_version_id` from `pick::pick` at approval, moving the existing freeze block out of the `submitted` path. `submitted` then records the bound version.
  2. While `stage = open_fire`, refuse agent ops that touch bound inputs (`pick_cv`, `unpin_cv`, `letter_raw`, `listing_raw`) with the existing `fire_hold` code and a new reason, for example "bound since open_fire", in [diag.rs](../../native/mcp/src/diag.rs) `REASONS`.
  3. The operator's own edits demote the application to `fire_ready` with an event, which voids the approval.
  4. The focus lens shows the bound descriptor next to the fire control.
- **Cost.** About 30-60 changed lines in the kernel, one diag reason and one test, with no wire or schema change if the letter and listing hashes go into the `open_fire` event body. A schema column is needed only if the hashes must be queryable. Part of the change replaces the current freeze-at-submit code, so net LOC is small.
- **Risks.**
  - Friction when the operator wants a late edit; re-approval is one click.
  - Agents that keep polishing letters after approval now get refusals with a clear diagnostic.
- **Not needed.** A phone passkey or second device: [obs:2314](https://observer.anoptic.io/mcp) found a second device "added nothing measurable over a trusted on-host confirmation". hireme's browser plus step-up session is the trusted surface.

**#2. Loud writes: derived-state digest and conservative receipts in every ACK.** I4 F4 N4.

- **Technique.**
  - (a) Return what the kernel derived from each acknowledged op in the same response, so the agent need not take another turn to `get` it ([obs:2287](https://observer.anoptic.io/mcp)).
  - (b) Attach nonbinding `warning[...]` receipts from deterministic, conservative checks. Each names the violated property and the recovery tool, and never echoes the call verbatim ([obs:1144](https://observer.anoptic.io/mcp), [obs:1368](https://observer.anoptic.io/mcp)).
- **Why it matters for hireme.** ACKs today carry only id and rev. Agents notice plausible wrong values only 58.8% of the time, and prompting them to check does not help ([obs:2244](https://observer.anoptic.io/mcp)), so the server must make quiet failures loud.
- **Where it plugs in.**
  - The judge's effects already contain the derived cells. For applications that means keyword count, CV coverage, score suggestion and band, heat state with `cooldown_days`, and pick state. [mcp.ex](../../lib/hireme_web/mcp.ex) `settled/2` can print one compact line per ACK and add `derived` and `warnings` to the structured content.
  - Candidate receipts, all deterministic:
    - `listing_raw` yielding fewer than a few keywords, or matching login-wall, captcha or not-found phrases;
    - a metric jump above 10× or below 0.1× of its latest cited value;
    - an `as_of` many years old;
    - a `cv_upload` whose extracted text is empty or very short, as from a scanned PDF;
    - a new corporation whose normalized name equals an existing one under a different domain.
  - Recovery tools to name: `text`, `history`, `get`, `cv {"application": no}`.
  - The browser can show the same receipts as toasts.
- **Cost.** A small kernel function and formatting, about +60-120 lines; it adds behaviour without replacing anything.
- **Risks.**
  - False alarms. Agents already raise false alarms on 26.8% of fault-free trials ([obs:2244](https://observer.anoptic.io/mcp)), so receipts must stay conservative.
  - Detection outside a mined vocabulary falls to 46% ([obs:1144](https://observer.anoptic.io/mcp)).
  - Digest size must stay a single line, keeping `put` batches of up to 256 readable.

**#3. Heat-aware fire calendar: earliest-legal-day scheduling over the governor.** I4 F4 N2.

- **Technique.** List scheduling with a fast-forward simulator, after build-order optimization ([obs:118](https://observer.anoptic.io/mcp)):
  1. Take queued applications (`draft_ready`, `fire_ready`, `open_fire`) in board order.
  2. Place each on the earliest day the governor would pass, given the virtual sends already placed. Each placed send adds `application_load` at its day and decays like a real one.
  3. Record which check bound it (`company_cap`, `ats_tenant_cap`, `reapply`, ...).

  Two optional refinements:
  - a small branch-and-bound to maximize Σ score × day-discount under `settings.goal_daily`, as in [obs:118](https://observer.anoptic.io/mcp);
  - outcome branches on reply or reject, as in [obs:1492](https://observer.anoptic.io/mcp).

  It plans in execution order with full state, as SHOP does ([obs:1629](https://observer.anoptic.io/mcp)).
- **Where it plugs in.**
  - A function beside the governor in [heat.rs](../../native/kernel/src/heat.rs), whose exact first-passing-day search already exists ([docs/heat.md](../heat.md)).
  - A derived "earliest day" on each card in [board.rs](../../native/kernel/src/board.rs).
  - The desk overview in [compose.rs](../../native/kernel/src/compose.rs), for the MCP and agents.
  - A calendar strip or column on the desk.
- **FIRE HOLD.** Unchanged: the calendar is advisory and never moves a stage.
- **Cost.** About +100-200 kernel lines plus UI, which needs a named LOC payback under the bound. The O(n²·checks) work for n queued is likely within 10 ms for n up to about 100, but must be measured.
- **Risks.**
  - The plan assumes every queued application goes out in order, so the UI must say "if sent in this order".
  - Fresh replies change the plan: recompute only the suffix, as D* Lite reuses search ([obs:1137](https://observer.anoptic.io/mcp)).

**#4. Failure localization by check, and session reports derived from the ledger.** I3 F5 N3.

- **Technique.**
  - (a) Tally refusals per key by refusal code. The code maps to the sequencer check: grant, lease, shape, domain, provenance or limits. Keep the tally across sessions, because per-session monitors miss fragmented patterns ([obs:1450](https://observer.anoptic.io/mcp)).
  - (b) At `release` or lease end, produce a deterministic session report from the ledger, audit and citations:
    - rows created or updated per table;
    - stage moves;
    - citations added, with hosts;
    - refusals by code.

    Show it to the operator instead of trusting agent prose. Report-only readers recover 52.0% of task state against 92.7% with full context ([obs:2313](https://observer.anoptic.io/mcp)).
- **Why it matters for hireme.** It separates interface failures from planning or research failures, which is the harness-versus-model cut ([obs:1575](https://observer.anoptic.io/mcp), [obs:1822](https://observer.anoptic.io/mcp), [obs:1013](https://observer.anoptic.io/mcp)). For example, a key with mostly `type`/`column` refusals is an interface problem; mostly `heat`/`stage` is planning; mostly `source_missing`/`stale` is research hygiene.
- **Where it plugs in.**
  - Add a `codes` map to the `agent_ops` audit data in [sequencer.ex:592](../../lib/hireme/sequencer.ex).
  - Show it per key in the account lens.
  - The `hireme` overview tells the key its own recent mix, with `explain` pointers.
  - `release` returns the report.
- **Cost.** About +30-60 lines.
- **Risks.**
  - Retention: `agent_ops` rows expire under the activity retention period, which is fine for telemetry.
  - A hash-chained audit ([obs:1826](https://observer.anoptic.io/mcp)) is optional and not needed for one operator.

**#5. Score explanation ledger.** I3 F5 N2.

- **Technique.** Utility-AI style considerations, without the weighted-random selection ([obs:395](https://observer.anoptic.io/mcp), [obs:930](https://observer.anoptic.io/mcp)). The suggestion carries `parts` (rule, delta, matched needle and its byte span), for example "48 base · +22 systems ('runtime') · +8 Rust · +5 remote · +6 pay ('$210,000') · clamped to 84". Kills and anchors show the phrase that triggered them.
- **Why it matters for hireme.** It exposes the documented false anchor ("Apple Valley Bakery") and the limits of pay reading at a glance, the way SHAP exposed CRAG's entity-overlap shortcut ([obs:169](https://observer.anoptic.io/mcp)).
- **Where it plugs in.**
  - `score::Suggestion` and `suggest` in [score.rs](../../native/kernel/src/score.rs); the lexicon's trie already finds the hits.
  - The suggestion JSON in [compose.rs](../../native/kernel/src/compose.rs).
  - The focus lens and the MCP `get` for applications and corporations.
- **Already exists elsewhere.** Heat verdicts already carry their data, and `cv {"application": no}` already explains CV picks, so this completes the set.
- **Cost.** About +40-80 lines.
- **Risk.** Card space in the UI.

**#6. A research-gap queue: open questions ranked by decision impact.** I3 F4 N3.

- **Technique.** A deterministic, kernel-derived list of open questions ([obs:068](https://observer.anoptic.io/mcp)). Each is ranked by whether answering it could change a derivation the operator acts on, in the style of teleo-reactive rules ([obs:2356](https://observer.anoptic.io/mcp)):
  - a corporation without headcount, where company capacity binds a queued application;
  - comp unread for an application whose suggestion is within a few points of a band edge, such as the 80/85 big-tech line;
  - unknown place or work mode, where the "onsite away" kill would flip;
  - cited figures older than N days on high-score corporations, to re-probe rather than reuse ([obs:1802](https://observer.anoptic.io/mcp));
  - a missing `listing_raw`;
  - unsettled CV picks, which `cv {}` already lists.
- **Where it plugs in.**
  - The `hireme` overview's `next` lists the top items ([mcp.ex:1150-1165](../../lib/hireme_web/mcp.ex)).
  - A `lease {"gaps": n}` claim mode hands agents that work, in the style of Halo 3's objectives distributing squads ([obs:931](https://observer.anoptic.io/mcp)).
  - The operator sees the same list on the desk.
- **Cost.** About +80-150 lines.
- **Risk.** The ordering rules are judgment calls, so keep them few and explainable, and attach #5-style reasons.

**#7. Read-set (dependency-scoped) validation for agent writes.** I3 F3 N4. This is the same proposal as planset candidate 3.

- **Technique.**
  - Agent writes carry the `(table, id, rev)` stamps of the rows they read.
  - The sequencer refuses the op if any stamp moved, and its data names what moved.
  - Agent-written prose keeps its basis, so a later change flags the prose stale. This is TMS-style: flag, never delete ([obs:2235](https://observer.anoptic.io/mcp), [obs:171](https://observer.anoptic.io/mcp)).
- **Evidence.** PlanFence: 30/30 correct against stale-plan action every time; 143-237 ms stall per action in its distributed setting; scoped traffic a tenth of all-key validation ([obs:1579](https://observer.anoptic.io/mcp)). In hireme the check is a local replica lookup, so its cost should be microseconds (planset's estimate; unmeasured here).
- **Where it plugs in.** As in [sonnet-researcher-planset.md](sonnet-researcher-planset.md) candidate 3: reads return stamps; `put`/`command` take `deps`; the judge compares them.
- **Cost.** The OPS layout or MCP schema changes, which bumps `wire_hash`.
- **Why it ranks below #1-#6 here.** Per-application leases already prevent same-row conflicts. The residual risk is cross-row bases, such as a letter drafted from `corporations.about`, which grows with the number of concurrent agents.

**#8. Measurement-gated playbooks for leased agents, and an execution-graded MCP task suite.** I3 F3 N3.

- **Technique.**
  - (a) Three to five human-curated procedures, for example:
    - research a corporation with citations;
    - triage a raw listing;
    - prepare drafts up to `fire_ready`;
    - fix a refusal mix.

    Serve them as MCP prompts, or in `hireme` text, preselected by the overview's `next` rather than dumped as a catalogue ([obs:2286](https://observer.anoptic.io/mcp), [obs:2285](https://observer.anoptic.io/mcp)). Workflows mined from good sessions are the source ([obs:072](https://observer.anoptic.io/mcp)).
  - (b) A small task suite on a bench node, graded by final kernel state as OSWorld grades by execution ([obs:192](https://observer.anoptic.io/mcp)) and QuoteBench by exact final state ([obs:1013](https://observer.anoptic.io/mcp)).
- **Measurement rules for the suite.**
  - Repeat runs, since 63.3% run-to-run agreement means one run proves nothing ([obs:2244](https://observer.anoptic.io/mcp)).
  - Keep held-out items ([obs:2242](https://observer.anoptic.io/mcp)).
  - Use paired same-model contrasts when changing tool descriptions or diagnostics ([obs:1822](https://observer.anoptic.io/mcp)).
- **Where it plugs in.** The MCP initialize capabilities (prompts), [mcp.ex](../../lib/hireme_web/mcp.ex) and a new `bench/` agent harness.
- **Cost.** LLM API spend plus harness upkeep.
- **Risks.**
  - Misevolution if playbooks are rewritten automatically ([obs:1015](https://observer.anoptic.io/mcp)), so keep them curated, text-only, never code ([obs:2256](https://observer.anoptic.io/mcp)).
  - Cortex found skills "rarely opened" when offered every turn, so preselect.

**#9. Natural-language desk commands compiled to the typed DSL, validated by the kernel, read back before applying.** I2 F3 N3.

- **Technique.**
  1. The operator types NL.
  2. An LLM emits a mask expression or `find` JSON. It sees only `cv {"fields": true}` and the NL text, never listing text, so injection has nothing to ride on.
  3. The kernel checks the output with byte-span errors through the existing `cv {"check": ...}` path, with at most two repair rounds.
  4. The board shows the DSL and an "Understood" list before applying, in the read-back pattern of commit 93ad825.
  5. The applied filter then runs deterministically in WebAssembly.

  Safety lives in the DSL and the validator ([obs:1625](https://observer.anoptic.io/mcp)). Static checks against schemas reject bad translations, as NOMOS does for rules ([obs:2257](https://observer.anoptic.io/mcp)).
- **Where it plugs in.** A desk command bar, plus either the operator's own agent over MCP or a server route using an operator-supplied provider key.
- **Cost.**
  - An LLM round trip of hundreds of milliseconds to seconds, which must stay off the sub-10 ms path.
  - A provider dependency.
  - New UI.
- **Value.** Discovery for the operator, and lower than #1-#8, because the DSL is already typeable.

### Gaps
- **Open code.** I did not confirm open code for Outcome Monitors, TurnCost, PlanFence, NOMOS, Cortex, SLEUTH or Real-Time World Crafting.
- **Unverified recollections.** I recall that an open-source build-order search (BOSS, in Churchill's UAlbertaBot) and AWM's code exist, but did not verify either this session.
- **Estimates.** All LOC and latency figures for hireme are my estimates from reading the code, not measurements.
- **#2 receipt thresholds** (keyword minimum, metric-jump ratio, age limit) need tuning on real listings; no card gives values for this domain.

## 4. Which seemingly relevant cards should hireme NOT adopt, and why?

### Takeaway
Most of the corpus's agent volume should not be adopted. Four large clusters are out:
- LLM serving and KV-cache internals: hireme runs no model;
- self-evolving harness loops: they misevolve, and their gains are inflated by the winner's curse;
- multi-agent fan-out: it costs more tokens for mixed results;
- graph, vector and free-form agent memory: writer-coupled and nondeterministic.

Learned injection detectors, LLM verifier stacks and reply-rate bandits are also out. Each conflicts with hireme's deterministic, single-kernel, human-gated design, or with its scale of one operator.

### Cited Findings
- **Serving and KV internals.** About 60 cards carry the `agentic-llm-serving`, KV-serving or tokenization tags, for example PagedAttention [obs:002](https://observer.anoptic.io/mcp), CacheScout 1077, KV retention while waiting for human approval [obs:1539](https://observer.anoptic.io/mcp), remote KV tiers 2318, and 28 DeepSeek model and infrastructure cards. They concern serving or training models — [obs:002](https://observer.anoptic.io/mcp); [obs:1539](https://observer.anoptic.io/mcp)
- **Fan-out.** Parallel sub-agents moved success by −11.9 to +2.3 points while tokens rose 1.41-3.31× ([obs:2243](https://observer.anoptic.io/mcp)). Teams cost 3-7× and plateau beyond four workers ([obs:2288](https://observer.anoptic.io/mcp)) — [arXiv 2610.10263](https://arxiv.org/abs/2610.10263); [arXiv 2610.17471](https://arxiv.org/abs/2610.17471)
- **Self-evolving loops.** In skill evolution, all 21 evolved configurations author unsafe artifacts ([obs:1015](https://observer.anoptic.io/mcp)). Keep-if-better selection overstates gains by 13-20 points with 16 selection items ([obs:2242](https://observer.anoptic.io/mcp)) — [arXiv 2610.09239](https://arxiv.org/abs/2610.09239)
- **Free-form memory.** Model-written notes do not survive a writer swap, while fixed-schema stores do ([obs:1642](https://observer.anoptic.io/mcp)). 83% of failed runs trace to an action that executes an unsupported summary entry ([obs:2312](https://observer.anoptic.io/mcp)) — [arXiv 2610.20927](https://arxiv.org/abs/2610.20927)
- **LLM verifier stacks.** Verifier-model diversity does not provide evidence diversity: cross-model votes over shared evidence approve unsafe proposals ([obs:1803](https://observer.anoptic.io/mcp)).
- **Learned detectors.** DriftNet (a learned trajectory transformer for injection) and HackProbe (a reward-hacking battery for self-evolving loops) assume training data or self-evolving loops — [obs:1799](https://observer.anoptic.io/mcp); [obs:1644](https://observer.anoptic.io/mcp)
- **Speculative execution.** Speculative macro commit needs isolated environment snapshots to pre-execute action chains — [obs:1581](https://observer.anoptic.io/mcp)
- **Another protocol.** NLIP is an Ecma-standardized natural-language interaction envelope — [obs:1610](https://observer.anoptic.io/mcp)
- **Weighted-random selection.** Utility AI's weighted-random choice and inertia are nondeterministic selection devices — [obs:395](https://observer.anoptic.io/mcp)
- **Specificity-based rules.** Valve's dialogue system resolves conflicts by most specific rule — [obs:1842](https://observer.anoptic.io/mcp)
- **Bandits.** UCT treats each tree node as a bandit (seminal 2006) — [obs:1009](https://observer.anoptic.io/mcp)
- **Parsing listings.** The operator's decision on listings, verbatim: "We do not care about parsing job listings out into more database columns(at all!). Just throw the entire RAW unedited text a job listing came with into this text row, for any given listing." — [docs/rebuild.md](../rebuild.md)

### Inferences
**Anti-candidates and why**
- **A1. Serving, KV-cache, tokenization and DeepSeek internals** (about 90 cards). hireme serves no model. The only transferable lessons are on the MCP side: cut turns (#2) and keep the tool order stable ([obs:1142](https://observer.anoptic.io/mcp), [obs:1233](https://observer.anoptic.io/mcp)).
- **A2. Self-evolving harnesses and RSI loops** (HELIX 1079, JIT-Agent 1447, WHALE 1538, NeoHorse 1770, RobustSGPO 1769, SafeEvolve 1574, Ecdysis 1798). They are training- or search-side, expensive, prone to misevolution and inflated by the winner's curse. Curated playbooks (#8) get most of the benefit.
- **A3. Reply-rate bandits or A/B auto-optimization of CV choice or targeting** ([obs:1009](https://observer.anoptic.io/mcp)).
  - One operator's few hundred outcomes cannot support it.
  - Selection noise and the winner's curse dominate.
  - It conflicts with "suggests and never overwrites" and with FIRE HOLD.
  - If planset candidate 5 (a score learning from overrides) proceeds, the held-out discipline of [obs:2242](https://observer.anoptic.io/mcp) applies to it.
- **A4. Designing for agent fan-out or teams** ([obs:2243](https://observer.anoptic.io/mcp), [obs:2288](https://observer.anoptic.io/mcp)). Do not add features that assume many concurrent writer agents; explicit lease claims suffice.
- **A5. Hosting graph, vector or free-form agent memory inside hireme** (GraphRAG [obs:074](https://observer.anoptic.io/mcp), HippoRAG [obs:075](https://observer.anoptic.io/mcp), A-MEM [obs:069](https://observer.anoptic.io/mcp), Agent Zero Memory [obs:1541](https://observer.anoptic.io/mcp), DPR [obs:092](https://observer.anoptic.io/mcp)).
  - Typed rows with citations are already the memory, and they port across model upgrades ([obs:1642](https://observer.anoptic.io/mcp)).
  - If text search over listings or messages is needed, start lexical: deterministic, no model dependency. The sibling planset proposes BM25F plus int8 static embeddings.
- **A6. Treating agent-written `battleplan`, `notes` or summaries as facts the kernel reads** ([obs:2312](https://observer.anoptic.io/mcp)). Keep them as fenced, untrusted prose.
- **A7. Learned injection or reward-hacking detectors** ([obs:1799](https://observer.anoptic.io/mcp), [obs:1644](https://observer.anoptic.io/mcp)). Masks, `human_only`, fencing and FIRE HOLD give structural guarantees a classifier cannot.
- **A8. A second LLM that "verifies" agent-written world data** ([obs:1803](https://observer.anoptic.io/mcp)). Require independent sources and trusted hosts, which hireme's `source_trust` already does for culture and ratings.
- **A9. Speculative macro commit or latency-optimized agent play** ([obs:1581](https://observer.anoptic.io/mcp), [obs:2315](https://observer.anoptic.io/mcp)). hireme's agents are not latency-bound.
- **A10. Another agent protocol** ([obs:1610](https://observer.anoptic.io/mcp)). MCP already is the protocol; this would add LOC for nothing.
- **A11. Weighted-random utility selection or inertia** ([obs:395](https://observer.anoptic.io/mcp)). It breaks deterministic ranking; adopt only the explanation half (#5).
- **A12. Switching `cv_rules` to most-specific-rule-wins** ([obs:1842](https://observer.anoptic.io/mcp)). Ordered first-match with shadowing diagnostics is shipped and easier to explain, and a switch would churn the operator's rules.
- **A13. Agent-side cognition hosted in hireme** (Generative Agents [obs:003](https://observer.anoptic.io/mcp), Reflexion [obs:081](https://observer.anoptic.io/mcp), MemGPT [obs:004](https://observer.anoptic.io/mcp), ToolGate [obs:067](https://observer.anoptic.io/mcp)). These belong in the agent's harness; hireme is the store and the judge.
- **A14. CRF or NER listing parsers** (1104, 1074). They conflict with the operator's verbatim decision quoted above.

### Gaps
- I did not test whether lexical search alone is enough for agents researching hireme's own records; that question belongs to the matching and ranking note and the planset.
- No corpus card measures bandits or learned scorers at a single person's sample size, so A3 rests on the general selection-noise result ([obs:2242](https://observer.anoptic.io/mcp)) and on hireme's stated design rules, not on a direct study.
