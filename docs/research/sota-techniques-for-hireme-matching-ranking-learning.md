# SOTA techniques for hireme: job matching, skill understanding, ranking, and learning from one seeker's outcomes (2024-2026)

Score scale used throughout (researcher's judgement, not from any source): **I** = expected impact on finding, judging and prioritising the right applications for one operator; **F** = feasibility under hireme's constraints (per-interaction work under about 10 ms in WebAssembly, deterministic kernel, small code, every surface usable over MCP); **N** = novelty of the technique in the field (5 = 2025-2026 frontier, 3 = established 2019-2024, 1 = textbook). hireme facts below were read from the repo at HEAD 223d228 (read-only).

## 1. Person-job fit and job recommendation in the LLM era: best methods and benchmarks, and which ones a single job seeker can use

### Takeaway
The 2024-2026 state of the art is hybrid and modular. Systems retrieve with dense and lexical methods, fuse the results, then rerank with an LLM, and platforms distil their LLM judges into small online models. One job seeker has no two-sided training pairs, so the trained platform models do not transfer. Two patterns do transfer: an LLM judges offline and a small deterministic scorer runs online, and an LLM reranks a short list listwise. hireme already has the right split for both: leased agents as judges, the kernel as the scorer. The largest gap in hireme is that it does not model the employer's side: how likely a reply is, learned from the operator's own outcomes.

### Cited Findings
**Platform-side and benchmark state of the art**
- ConFit (RecSys 2024, Yu et al., arXiv 2401.16349) represents resumes and jobs as dense embeddings and scores a pair by inner product. It paraphrases sections to augment the data, which roughly doubles the labelled pairs, and uses contrastive learning. It reports up to 19% (ranking jobs) and 31% (ranking resumes) absolute nDCG@10 over prior methods, including BM25 and OpenAI text-ada-002, on two datasets — [arXiv 2401.16349](https://arxiv.org/abs/2401.16349)
- ConFit v2 (arXiv 2502.12361) adds LLM-generated hypothetical reference resumes and hard-negative mining. It reports an average of +13.8% recall and +17.5% nDCG over ConFit and baselines — [arXiv 2502.12361](https://arxiv.org/abs/2502.12361v1)
- ConFit v3 (Yu et al., arXiv 2605.09760, May 2026) trains LLM rerankers for person-job fit (Qwen3-8B/32B). The abstract reports that multi-pass reranking, listwise RL objectives, removing noisy samples, and SFT distillation from a stronger LLM before RL all help. It claims "significant improvements" over the best person-job fit systems and over GPT-5 and Claude Opus-4.5, but the abstract page gives no numbers — [arXiv 2605.09760](https://arxiv.org/abs/2605.09760)
- TalentCLEF 2025 (Gasco et al., arXiv 2507.13275) covers job-title matching (Task A) and job-title-to-ESCO-skill prediction (Task B):
  - Task A: the best average MAP was 0.534 (AlexU-NLP) against a 0.360 baseline.
  - Task B: the best MAP was 0.360 (a 7B decoder embedding model fine-tuned with GIST loss on Qwen2.5-32B-augmented data) against a 0.196 baseline.
  - "the training strategies have a larger effect than the size of the model alone". The best Task A models were about 500M parameters, and LLM augmentation plus contrastive fine-tuning added up to 8 MAP points at similar sizes.
  - The test sets are small (for example, 116 English queries over 769 titles) — [TalentCLEF 2025 overview](https://arxiv.org/html/2507.13275v1)
- TalentCLEF 2025 participation counts conflict: the overview reports 76 registered teams and more than 280 submissions, while an organisers' CEUR brief says 15 participating teams — [overview](https://arxiv.org/abs/2507.13275); [CEUR brief](https://ceur-ws.org/Vol-4038/paper_362.pdf)
- TalentCLEF 2026 (arXiv 2606.31692) recast Task A as contextualised job-person matching: rank resumes for a vacancy, in English and Spanish, with 40 test queries over 476 resumes per language.
  - Task A: the baseline averaged 0.3828 MAP. The winner, "classum", reached 0.7140 by combining many dense embedders (ZEmbed1-4B, KaLM-12B, Octen-8B, Nemotron-8B, Harrier-27B) with LLM listwise scoring, rubric scoring, score fusion and reranking. QTPride reached 0.6632 by having an LLM parse the documents into structured JSON, then fusing retrieval views with reciprocal rank fusion. A third team reached 0.6532 with geometric-mean rank fusion followed by an LLM listwise tournament. BM25 appeared as a hybrid component in several submissions.
  - Task B (ESCO skills, core versus contextual): the best graded NDCG was 0.8068 against a 0.6204 baseline.
  - Conclusion: "the strongest systems... used hybrid, modular pipelines rather than single-model retrieval" — [TalentCLEF 2026 overview](https://arxiv.org/html/2606.31692v1)
- LinkedIn's LANTERN (arXiv 2510.05490, Oct 2025) distils a black-box teacher LLM into an encoder (fit classification) and a decoder (explanation), using data-level and logit-level distillation. Online it reports +0.24% apply rate and +0.28% qualified applications — [arXiv 2510.05490](https://arxiv.org/abs/2510.05490)
- "Semantic Search at LinkedIn" (arXiv 2602.07309, Feb 2026) combines an LLM relevance judge, embedding retrieval, and a small model distilled from several teachers. It reports over 75x ranking throughput under a fixed latency limit at "near-teacher-level NDCG" — [arXiv 2602.07309](https://arxiv.org/abs/2602.07309)
- LinkedIn also unified job-search query understanding into one LLM framework (CIKM '25) — [arXiv 2509.09690](https://ar5iv.labs.arxiv.org/html/2509.09690)
- 360Brew (LinkedIn, arXiv 2501.16450) is a 150B-parameter decoder trained on LinkedIn first-party data. It handles over 30 ranking tasks without task-specific fine-tuning — [arXiv 2501.16450](https://export.arxiv.org/pdf/2501.16450)
- MockLLM (KDD '25, arXiv 2405.18113) has an LLM role-play both interviewer and candidate in mock interviews, then evaluates both sides under a "handshake protocol". It was tested on Boss Zhipin data — [arXiv 2405.18113](https://arxiv.org/html/2405.18113v2)
- GIRL (arXiv 2307.02157) generates job descriptions from a CV (SFT, then a reward model, then PPO). It is seeker-centric, but it is a generator trained on platform data — [arXiv 2307.02157](https://arxiv.org/abs/2307.02157?context=cs)
- Reviews: "Natural Language Processing for Human Resources: A Survey" ([arXiv 2410.16498](https://arxiv.org/pdf/2410.16498)) and "From Matching Models to Recruiting Agents" (Sept 2026, [arXiv 2609.04286](https://arxiv.org/pdf/2609.04286)). I did not read their content.

**Seeker-side evidence**
- Galdin & Silbert, "Making Talk Cheap" (arXiv 2511.08785): on Freelancer.com, employers paid a premium for customised applications before LLMs and not after. Top-quintile workers are hired 19% less often and bottom-quintile workers 14% more often than in the pre-LLM equilibrium — [arXiv 2511.08785](https://arxiv.org/html/2511.08785v1)
- Referred candidates are more likely to be hired. This holds in a single US firm's data ([NY Fed SR568](https://www.newyorkfed.org/medialibrary/media/research/staff_reports/sr568.html)) and across nine large firms in call centres, trucking and high tech ([Columbia Business School](https://business.columbia.edu/faculty/research/value-hiring-through-employee-referrals)). Field experiments find that referrals carry information beyond observables ([Pallais & Sands, NBER w21357](https://www.nber.org/system/files/working_papers/w21357/w21357.pdf)).
- LLM judges are order-sensitive. In MT-Bench, GPT-4 gave the same verdict after the two answers were swapped only 65.0% of the time (Claude-v1 23.8%, GPT-3.5 46.2%) — [Zheng et al., arXiv 2306.05685](https://arxiv.org/pdf/2306.05685)
- Embedding-retrieval resume screening favoured White-associated names in 85.1% of cases and female-associated names in only 11.1% (nine occupations, more than 500 resumes, 500 job descriptions) — [Wilson & Caliskan, AIES 2024](https://ojs.aaai.org/index.php/AIES/article/view/31748); [arXiv 2407.20371](https://arxiv.org/abs/2407.20371v1)
- About 1% of roughly 200K real resumes on hireEZ contained hidden prompt injections, and the share grew over the prior one to two years. Over 90% of the injections used no explicit instructions — [arXiv 2605.28999](https://arxiv.org/pdf/2605.28999); defence benchmark: [ResumeShield, arXiv 2609.20188](https://arxiv.org/pdf/2609.20188)

**hireme baseline**
- Life-EV is a hand-built ladder: "Named anchors win over heuristics". Heuristics start "from a base of 48: systems... +22; agentic work +10; Rust, C++ or low-level +8; home or remote +5; the pay signal +6; CRUD... −16", and "The kernel **suggests** and never overwrites: a stored `score_100` is the operator's or an agent's number and wins" — [docs/score.md](../score.md)
- The board orders by "`score_100` high to low (a stored number, else the Life-EV suggestion), then heat cool to blocked, then the projected company load" — [native/kernel/src/board.rs](../../native/kernel/src/board.rs)

### Inferences
- **What does not transfer.** ConFit-style training, GIRL/LGIR-style generators, GNN recommenders and 360Brew all need large numbers of labelled two-sided interactions. One operator produces tens to hundreds of outcomes. These methods are platform tools.
- **What transfers.**
  - (a) LinkedIn's split, applied to hireme: an LLM judges offline (the leased agents writing structured, cited judgements through MCP `put`), and a small, cheap, deterministic scorer runs online (the kernel).
  - (b) TalentCLEF 2026's recipe: cheap hybrid retrieval and fusion produce a short list, and an LLM reranks it listwise.
  - (c) QTPride's step that has an LLM parse each document into structured JSON (0.6632 MAP) is exactly what agents could do once at ingest. The kernel would then read typed cells, not prose.
- **The missing half: the employer's side.** A seeker-side recommender is reciprocal: it must predict whether the employer will respond as well as what the operator wants. Today's Life-EV is utility-only. A principled decomposition is EV = U(seat) × P(reply | seat, channel, ATS, freshness) × P(offer | reply) − cost(heat, effort), with U and P as separate derived columns. Section 4 covers how to learn P with censoring. Whether the board ranks by EV or by U (the band staying a pure function of U) is an operator design decision. score.md's "maximize life EV, not the number of applications" argues for EV.
- **Volume is not the lever.** LLM-tailored applications lost their signal value (Galdin & Silbert), and referrals lift hire rates. So hireme's leverage is choosing where to apply, the channel, and timing, which supports FIRE HOLD and the heat caps. The `channel` enum (listing, referral, recruiter, cold, other, inbound) should be a first-class feature of P.
- **Shortlist reranking by agents.** In a daily batch (`day_pack`), an agent reranks the kernel's top 30-50 cards listwise:
  - Use several passes with swapped order, to counter the 65% order consistency seen in MT-Bench.
  - Write the result as cited data (an agent rank or a proposed `score_100` with actor=agent). The kernel uses it as one feature or label, never as truth.
  - This keeps LLM calls off the ≤10 ms path and keeps results reproducible, because the stored rows are what the board reads.
- **Benchmarks for a single seeker.** No public benchmark ranks jobs for one person's utility (see Gaps). TalentCLEF 2025/2026 corpora (Zenodo) can sanity-check hireme's title normalisation, skill normalisation and semantic matching choices offline. The real yardstick is a backtest on the operator's own labels, trained on older applications and tested on newer ones.

#### Scores (section 1)
- Offline LLM judge distilled into the kernel scorer (agents write cited structured judgements; kernel learns from them and from operator labels): I4 F4 N4
- Agent listwise multi-pass rerank of the top-k shortlist, stored as data: I3 F4 N3
- LLM-structured listing parse into typed, cited cells (QTPride pattern): I4 F4 N3
- EV = utility × reply probability decomposition: I5 F4 N2
- Platform PJF models (ConFit training, GIRL, LGIR, 360Brew, MockLLM): I1 F1 N4, anti-candidates (section 7)

### Gaps
- I found no public benchmark or dataset that evaluates ranking from a single job seeker's side with that seeker's own utility and outcome labels. TalentCLEF 2026 Task A is employer-side (rank resumes for a vacancy).
- The ConFit v3 abstract page gives no numbers, and TalentCLEF 2026's per-team model sizes and costs were only partly visible. I did not read the full PDFs.
- LANTERN's offline metrics and the LinkedIn semantic-search NDCG values are not on the abstract pages.
- I found no study that measures how much ranking by "reply probability × utility" improves a seeker's outcomes compared with utility alone.

## 2. Skill and requirement extraction from postings and CVs, normalisation to taxonomies, and what should replace hireme's exact-token coverage

### Takeaway
On exact span boundaries, supervised span taggers (SkillSpan, JobBERT, ESCOXLM-R) still beat in-context LLMs, but LLMs handle complex, implicit mentions better. Linking a mention to a taxonomy (ESCO) works best as bi-encoder retrieval followed by LLM reranking, trained on LLM-generated synthetic data. For hireme, the strongest replacement for the 12-most-frequent-words exact coverage is a requirement graph:
- agent-extracted, typed requirements (must or nice, years, seniority) whose text spans the kernel checks verbatim against the listing;
- normalisation to concept IDs (ESCO plus an operator alias table);
- concept-level coverage with partial credit for related skills.

The literal-token coverage stays as a secondary readout.

### Cited Findings
- Nguyen, Zhang, Montariol & Bosselut, "Rethinking Skill Extraction in the Job Market Domain using LLMs" (NLP4HR 2024, arXiv 2402.03832): across six standardised skill-extraction datasets, in-context LLMs trail supervised BIO taggers overall but handle syntactically complex skill mentions better — [ACL Anthology](https://aclanthology.org/2024.nlp4hr-1.3); [arXiv 2402.03832](https://arxiv.org/abs/2402.03832)
- ESCOXLM-R (Zhang, van der Goot & Plank, ACL 2023, arXiv 2305.12092) is XLM-R-large with further pre-training on the ESCO taxonomy (27 languages) plus a taxonomy-relation objective. It reached state of the art on 6 of 9 job-market datasets (6 sequence-labelling and 3 classification tasks, 4 languages) and is strongest on short spans — [ACL Anthology](https://aclanthology.org/2023.acl-long.662); [arXiv 2305.12092](https://arxiv.org/pdf/2305.12092)
- "Entity Linking in the Job Market Domain" (Zhang, van der Goot & Plank, EACL Findings 2024, arXiv 2401.17979) links span-level skill mentions, including implicit ones, to ESCO skills. A BLINK bi-encoder is best under strict evaluation and GENRE under loose evaluation (accuracy@k). Code is at mainlp/el_esco — [arXiv 2401.17979](https://arxiv.org/pdf/2401.17979)
- Decorte et al., "Extreme Multi-Label Skill Extraction Training using LLMs" (arXiv 2307.10778) trains with fully synthetic LLM-generated data and contrastive learning. It gains 15-25 points in R-Precision@5 over literal-match distant supervision on three benchmarks — [arXiv 2307.10778](https://arxiv.org/pdf/2307.10778)
- Clavié & Soulié, "LLMs as Batteries-Included Zero-Shot ESCO Skills Matchers" (RecSys-in-HR 2023, arXiv 2307.03539): synthetic training data gives +10 RP@10 over distant supervision, and GPT-4 reranking adds over 22 points — [arXiv 2307.03539](https://arxiv.org/pdf/2307.03539)
- SkiLLMo (Malandri et al., SAC '25, as attributed by the search summary) is an LLM pipeline for normalised ESCO extraction. Experts rated it 91% precise for extraction, 80% for standardisation and 79% combined. It reports precision only, no recall — [UNIMIB repository](https://boa.unimib.it/handle/10281/555064)
- JobSkape (NLP4HR 2024, arXiv 2402.03242) generates synthetic job postings for skill matching with GPT-3.5 — [arXiv 2402.03242](https://arxiv.org/pdf/2402.03242)
- Survey: Senger et al., "Deep Learning-based Computational Job Market Analysis: A Survey on Skill Extraction and Classification from Job Postings" — [arXiv 2402.05617](https://arxiv.org/pdf/2402.05617)
- SkillMatch (Decorte et al., AI4HR&PES @ ECML-PKDD 2024, arXiv 2410.05006) is a skill-relatedness benchmark mined from millions of job ads. It adapts Sentence-BERT self-supervised on skill co-occurrence and "greatly surpasses traditional models". alphaXiv's summary quotes AUC-PR 0.969 and MRR 0.357, which I did not verify in the paper — [arXiv 2410.05006](https://arxiv.org/abs/2410.05006); [alphaXiv summary](https://www.alphaxiv.org/overview/2410.05006)
- JobBERT naming collision: Decorte's JobBERT (arXiv 2109.09605) models job titles through skills, while Zhang's JobBERT is a domain-adapted BERT for span extraction (SkillSpan line) — [arXiv 2109.09605](https://arxiv.org/pdf/2109.09605)
- JobBERT-v2:
  - Its model card describes it as based on all-mpnet-base-v2, with 64 tokens maximum, and reports 0.6457 MAP "on the TalentCLEF benchmark". The split is unclear and the number is not comparable with the Task A leaderboard.
  - Sources disagree on its output size (768 versus a 1024 projection).
  - The JobBERT-V3 paper reports JobBERT-V2 at 0.2531 MAP on skill prediction against 0.1852 for the MPNet base.
  - Sources: [HF card](https://www.huggingface.co/TechWolf/JobBERT-v2); [arXiv 2507.21609](https://arxiv.org/pdf/2507.21609)
- JobBERT-v3 (Decorte, De Lange & Van Hautte, TalentCLEF 2025 workshop) is multilingual (en, es, de, zh). It is MIT-licensed, has 0.3B parameters, outputs 1024 dimensions, takes 64 tokens maximum, is fine-tuned from paraphrase-multilingual-mpnet-base-v2, and was trained on 21,123,868 title-skills pairs — [HF card](https://huggingface.co/TechWolf/JobBERT-v3); [arXiv 2507.21609](https://arxiv.org/abs/2507.21609)
- An ONNX export of JobBERT-v2 exists, which makes it runnable from Rust through ONNX Runtime — [onnx-community/JobBERT-v2-ONNX](https://huggingface.co/onnx-community/JobBERT-v2-ONNX)
- TalentCLEF 2026 Task B ranks ESCO skills for a job title and separates core from contextual skills (best graded NDCG 0.8068 against a 0.6204 baseline). The top systems fine-tuned encoders with GISTEmbedLoss and reranked with LLMs (Qwen3-Reranker-8B, Qwen3-235B) — [TalentCLEF 2026](https://arxiv.org/html/2606.31692v1)
- Saroglou et al. (arXiv 2512.03195, Dec 2025) compare sentence linking with entity linking to ESCO occupations and skills and to EQF qualifications, release two annotated datasets and an open-source tool. The abstract gives no numbers — [arXiv 2512.03195](https://arxiv.org/abs/2512.03195)
- ESCO v1.2 (May 2024) added 35 occupations, 42 skills, 196 knowledge concepts and 677 alternative labels, with translations in 28 languages — [ESCO v1.2 launch deck](https://esco.ec.europa.eu/system/files/2024-05/V1.2%20Launch%20-%20ESCO%20SEC%20combined%20-%20final%20clean.pdf)
- A third-party page gives ESCO totals of about 3,039 occupations and 13,890 skills. I did not find these totals in an official source — [Dublin Core MSI](https://msi.dublincore.org/standards/esco)
- Lightcast Open Skills:
  - It holds about 32,000-35,000 skills; Lightcast's own pages differ.
  - Free API access now covers only nonprofits and public-good initiatives, with up to 50 extraction requests a month; for-profit or production use needs a commercial license.
  - Sources: [Lightcast access options](https://docs.lightcast.io/lightcast-api/docs/api-access); [free API features](https://docs.lightcast.io/lightcast-api/docs/free-api-features); [Open Skills FAQ](https://lightcast.io/open-skills/faqs)
- GLiNER has a Rust inference engine, gline-rs 1.0.1 (ONNX, span and token modes), and separate Rust engines exist for GLiNER2. A production PII system reports about 180 ms p50 with GLiNER2 through ort — [gline-rs docs](https://docs.rs/crate/gline-rs/latest); [Rust forum](https://users.rust-lang.org/t/building-a-production-multilingual-pii-detection-system-in-rust-with-gliner2/139964)
- GLiNER paper: Zaratiana et al., NAACL 2024, a generalist zero-shot NER model. The identifier is from prior knowledge and was not re-fetched this session — [arXiv 2311.08526](https://arxiv.org/abs/2311.08526)
- hireme baseline:
  - Keywords are extracted once at write time from the listing's prose. "The [`TOP`] most frequent, ties by bytes, are the keywords" with `TOP = 12`, and "a change to any rule here bumps the version, and the server re-extracts".
  - Coverage is a whole-term hit on the CV's folded text (`Text::hit`), up to `MAX_TARGETS = 64`.
  - Source: [native/kernel/src/keywords.rs](../../native/kernel/src/keywords.rs)
  - Role family and seniority come from lexicon hits (org.rs `Seniority`, `Family`, `Department`) — [native/kernel/src/org.rs](../../native/kernel/src/org.rs)

### Inferences
- **What exact-token coverage misses today** (from reading keywords.rs):
  - synonyms and aliases ("k8s" and "kubernetes", "postgres" and "postgresql", "golang" and "go");
  - multiword skills ("distributed systems" and "machine learning" split into frequent single words);
  - requirement strength (must or nice), years and seniority;
  - negation and boilerplate (word frequency is not requirement: a company name or "benefits" can be among the top 12).
- **Proposed replacement, in three layers. Only layer 3 runs in the kernel per interaction.**
  1. **Extraction at ingest (agents, or server-side GLiNER).**
     - Requirements come back as rows: `{span_start, span_end, text, kind ∈ skill|tool|language|degree|years|seniority|clearance|visa|work_mode|location, strength ∈ must|nice, years_min?, concept_id?}` through MCP `put`, with the listing as the cited source.
     - The kernel checks that each span's text occurs verbatim in the listing's prose (it already computes `prose()`). It refuses rows that fail, which blocks hallucinated requirements and text planted by injections.
     - This plays to the evidence: LLMs handle complex mentions well but are weaker at exact BIO boundaries (Nguyen 2024), and a verbatim-substring check does not need BIO-exact boundaries.
  2. **Normalisation to concept IDs.**
     - A small `concepts` world table holds ESCO skill URIs with preferred and alternative labels (version and as-of day cited), plus operator aliases for tech tools.
     - Agents propose links: candidates from a bi-encoder or static embedding, then an LLM rerank. The rerank is the piece with the largest measured gain (+22 RP@10, Clavié & Soulié).
     - Only concepts that occur in the replica's listings and CVs need to be resident in the browser (probably hundreds, not 13,890). This is an estimate.
  3. **Kernel coverage.**
     - Map the CV and profile items (kinds experience, project, skill, timeline) to concepts by matching every alias with the existing `Text::hit` folding.
     - Derive years per concept from timeline items.
     - Score each requirement: an exact concept hit scores 1; a related concept scores partial credit (a precomputed neighbour list per concept from co-occurrence relatedness or embedding kNN, flagged "related"); years and seniority are checked as typed comparisons against `Seniority`.
     - Output must-coverage, nice-coverage and the missing-must list. The list feeds `compose.rs` tailor/add overlays ("which item covers Kubernetes?") and can become `mask.rs` facts for CV rules (for example, a `requires` fact).
     - All of this is hash lookups and small loops: microseconds per card in WebAssembly (estimate).
- **Keep literal coverage as a second readout.** Literal words still matter wherever a reader or a screening system matches strings. That ATS keyword filters are literal is an assumption; I found no source on how common they are.
- **Title normalisation (optional).** JobBERT-v3 (MIT, 0.3B, multilingual, 64-token inputs) could run on the server at ingest to map titles to ESCO occupations. This would improve heat's family and department similarity (`similar_family` 1.0, `similar_department` 0.6 in [docs/heat.md](../heat.md)) beyond the lexicon, and would cover German, Spanish and Chinese titles. Static-embedding nearest neighbours in the kernel are a cheaper alternative (section 3).
- **Cost and risk.**
  - New schema: a requirements table or JSON column, and a concepts table.
  - A span verifier and an alias matcher reusing `Text::hit`; coverage replaces `keywords::coverage`, and `extract` remains the fallback when no agent extraction exists.
  - Risks: LLM extraction cost and drift (record model and prompt version in the cited source; bump the version to re-extract), thin ESCO coverage of tech tools, multilingual listings, and injection (mitigated by the span check and by treating rows as data).

#### Scores (section 2)
- Agent-extracted typed requirements with verbatim span verification: I5 F4 N3
- Concept normalisation (ESCO plus alias table; bi-encoder candidates plus LLM rerank): I4 F4 N3
- Related-skill partial credit (co-occurrence or embedding neighbours): I3 F4 N3
- Typed years and seniority checks against profile timeline items: I4 F4 N2
- GLiNER (gline-rs) server-side extraction fallback: I3 F3 N3
- JobBERT-v3 title-to-occupation normalisation: I3 F3 N4
- Supervised span taggers (ESCOXLM-R or JobBERT fine-tuning): I2 F2 N2 (needs annotated data and a 560M-class model; not now)

### Gaps
- I found no 2025-2026 benchmark that reports GPT-4o or Claude-class F1 for end-to-end extraction plus ESCO linking from real postings; SkiLLMo reports precision only.
- I did not verify ESCO's coverage of modern tech tools (frameworks, cloud services) or ESCO's reuse licence in this session. O*NET's licence and size were not researched.
- I found no published accuracy for zero-shot GLiNER on skill spans.
- SkillMatch's exact numbers and dataset size are unverified (secondary summaries only).

## 3. Small embedding models within a millisecond budget in WebAssembly: quality, size, latency; hybrid lexical and semantic search

### Takeaway
Static (lookup-table) embeddings fit hireme's interactive path: Model2Vec "potion" models and Sentence Transformers' static-retrieval-mrl. Encoding is tokenise, look up, average, at roughly 100,000 sentences per second on a CPU. They keep about 87-93% of MiniLM/MPNet quality, and on retrieval they still beat BM25. For about 1,000 replica cards, brute-force int8 or binary similarity costs well under a millisecond, so no ANN index is needed. Fused with BM25 by reciprocal rank fusion, this gives hireme hybrid search and semantic similarity inside the deterministic kernel. Transformer encoders such as MiniLM, bge-small or EmbeddingGemma belong on the server for offline tasks; MiniLM takes about 400-500 ms per 512-token input in browser WASM.

### Cited Findings
- Model2Vec (MinishLab, MIT):
  - Model sizes: potion-base-8M has 7.5M parameters; potion-base-32M and potion-retrieval-32M have 32.3M (distilled from bge-base-en-v1.5); potion-multilingual-128M has 128M (distilled from bge-m3).
  - The project claims "up to 500 times faster on CPU" and models "~30 MB on disk... smallest model just ~8 MB".
  - Source: [GitHub MinishLab/model2vec](https://github.com/MinishLab/model2vec)
- Model2Vec MTEB results: the average is 55.93 for all-MiniLM-L6-v2, 52.13 for potion-base-32M and 51.08 for potion-base-8M. Retrieval is 42.92 for MiniLM, 35.06 for potion-retrieval-32M and 34.95 for static-retrieval-mrl-en-v1. A GitHub PR reports 36.35 for potion-retrieval-32M, a version discrepancy — [Model2Vec results](https://minish.ai/packages/model2vec/results/); [PR #187](https://github.com/MinishLab/model2vec/pull/187/files)
- potion-multilingual-128M is trained on 101 languages and scores 47.31 on MMTEB — [HF card](https://huggingface.co/minishlab/potion-multilingual-128m)
- Model2Vec's training table: model2vec + logistic regression trains at 17,925 samples/s, against 716 for SetFit on MiniLM and 118 for bge-base + logistic regression — [Model2Vec results](https://minish.ai/packages/model2vec/results/)
- model2vec-rs is the official Rust inference crate (0.2.1); a third party claims it is about 1.7x faster than Python. I found no official JS or WASM build — [docs.rs model2vec-rs](https://docs.rs/crate/model2vec-rs)
- Sentence Transformers static embeddings (blog, 15 Jan 2025), static-retrieval-mrl-en-v1 (1024 dimensions, Matryoshka 32-1024):
  - NanoBEIR NDCG@10 is 0.5032, against 0.5757 for all-mpnet-base-v2, 0.6376 for bge-base-en-v1.5, 0.5623 for all-MiniLM-L6-v2 and 0.4518 for BM25.
  - On CPU (i7-13700K) it encodes 107,419.51 sentences/s, against 1,739.31 for MiniLM and 270.40 for mpnet.
  - Halving the dimensions costs 1.47% (0.4957 against 0.5031).
  - Source: [HF blog](https://huggingface.co/blog/static-embeddings)
- The multilingual static model (static-similarity-mrl-multilingual-v1) is about 125x faster on CPU than multilingual-e5-small and keeps 92.3% of its STS score — [HF blog](https://huggingface.co/blog/static-embeddings)
- EmbeddingGemma (308M, arXiv 2509.20354, Sept 2025) is state of the art among models under 500M parameters. It ranks 8th overall on MTEB (Multilingual, v2), 17 places above the next model under 500M. It runs in under 200 MB of RAM when quantised and has Matryoshka outputs at 768, 512, 256 and 128 dimensions — [arXiv 2509.20354](https://arxiv.org/abs/2509.20354); [DeepMind page](https://deepmind.google/models/gemma/embeddinggemma/)
- Browser transformer latency (community benchmark): all-MiniLM-L6-v2 at batch 1 with 512 tokens, unquantised, took 451.00 ms in WASM against 10.10 ms in WebGPU (Linux Chrome 124), and 507.20 ms against 45.70 ms (Windows Chrome 122) — [Xenova WebGPU embedding benchmark](https://huggingface.co/spaces/Xenova/webgpu-embedding-benchmark/discussions/1)
- Embedding quantisation (mxbai-embed-large-v1):
  - Binary: 32x less memory, a mean 24.76x speedup, 92.53% retention without rescoring and 96.45% with rescoring.
  - Int8: 4x less memory, a 3.66x speedup, about 97% retention without rescoring and 99% with rescoring (rescore multiplier 4-5).
  - Source: [HF blog](https://huggingface.co/blog/embedding-quantization)
- Inference-free learned sparse retrieval:
  - The document side is expanded by a model offline; the query side is only tokenisation and a weight lookup.
  - Geng et al. (arXiv 2411.04403) beat SPLADE-v3-Doc by 3.3 NDCG@10 zero-shot on BEIR but trail siamese sparse retrievers by 4.7.
  - Li-LSR (arXiv 2505.01452) learns per-token query scores, which turns query encoding into a table lookup: about +1 MRR@10 on MS MARCO and +1.8 nDCG@10 on BEIR over SPLADE-v3-Doc.
  - Sources: [arXiv 2411.04403](https://arxiv.org/html/2411.04403v2); [arXiv 2505.01452](https://arxiv.org/pdf/2505.01452)
- Reciprocal rank fusion scores Σ 1/(k + rank) with k = 60. It "consistently yields better results than any individual system, and better results than the standard method Condorcet Fuse" — [Cormack, Clarke & Büttcher, SIGIR 2009](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf)
- TalentCLEF 2026 top systems used BM25 as a hybrid component and fused rankings with RRF or geometric-mean rank fusion — [TalentCLEF 2026](https://arxiv.org/html/2606.31692v1)
- hireme has no embedding, vector or near-duplicate code: a grep of lib/, native/ and assets/ for embedding, vector, bm25, minhash and simhash matched only build artefacts. The board caches per-row derivations: "recomputed only for the rows a frame or a write moved" — [board.rs](../../native/kernel/src/board.rs)

### Inferences
- **Budget arithmetic (estimates).**
  - 1,000 cards × 256-dimension int8 vectors take 256 KB. Brute-force scoring is 256k int8 multiply-adds, roughly 0.1-0.5 ms in WASM even without SIMD.
  - At the 50,000-row `applications` cap that grows to 12.8 MB and about 13 ms, over budget. There, 256-bit binary codes (32 B per card, 1.6 MB) searched by popcount, then int8 rescoring of the top 100, keep about 96% quality (HF quantisation blog).
  - A static query embedding (about 30 tokens × 256 dimensions) is microseconds.
- **Model size is the real cost: cold load, not latency.**
  - potion-base-8M is about 7.5M parameters, so about 7.5 MB in int8 and about 30 MB in fp32 (inferred from the parameter count).
  - Options: prune the vocabulary to tokens seen in the replica plus common query words, reduce dimensions (PCA or Matryoshka truncation), and ship the table in the columnar BOOT.
  - The operator has said a heavier cold load is acceptable if all other UX improves. Whether Model2Vec supports vocabulary pruning was not verified.
- **Determinism.** An int8 table with i32 accumulators and a fixed summation order gives bit-identical results in the WASM build and the NIF. That fits "deterministic kernel". Float mean-pooling would need a fixed order to be bit-stable.
- **Where it plugs in.**
  - (a) Board search box and MCP `find`: BM25 over the kernel's folded tokens plus static cosine, fused by RRF (k = 60). `find` could return the fused components so agents see why something matched.
  - (b) Semantic coverage in section 2: the maximum similarity between each requirement span and the CV's lines.
  - (c) "More like this": similarity to seats the operator pursued or that got a positive outcome, which is also a feature for section 4's models.
  - (d) A second stage for near-duplicates (section 5).
  - (e) Role clustering beyond the lexicon for heat similarity.
- **The server can embed with a stronger model** (EmbeddingGemma or bge-small through ONNX or candle) for dedup, concept linking and title normalisation. Those vectors are not in the same space as the browser's query embeddings, so the interactive path should use one static model end to end.
- **Inference-free learned sparse retrieval is an explainable alternative.** The server expands each listing into weighted terms. The browser scores a query with a lookup table over an inverted index of about 1,000 documents. Each term's contribution can be shown ("kubernetes 1.8, containers 0.6"), which suits the explanation goal in section 6. Its multilingual availability is unverified (see Gaps).

#### Scores (section 3)
- Static embeddings in the kernel (Model2Vec or static-retrieval-mrl class; int8 table): I4 F4 N4
- Hybrid BM25 + static cosine + RRF for board search and MCP `find`: I3 F5 N2
- Binary or int8 quantisation with rescoring (an enabler at the 50k scale): I2 F5 N3
- Inference-free learned sparse retrieval (document expansion on the server, lookup queries in WASM): I3 F3 N4
- Server-side small encoder (EmbeddingGemma-308M or bge-small) for offline tasks only: I3 F4 N3

### Gaps
- I found no published WASM latency numbers for Model2Vec or static-retrieval models specifically (the speed figures are CPU-native). I found no official JS or WASM Model2Vec package.
- I did not check the exact on-disk sizes and dimensions of potion-base-2M, 4M and 8M, or the size of static-retrieval-mrl-en-v1's token table.
- I did not verify multilingual inference-free sparse models or their licences, or EmbeddingGemma's licence terms.
- I found no job-domain evaluation of static embeddings against job-specific encoders such as JobBERT on, for example, TalentCLEF.

## 4. Learning one person's preferences and outcomes from small data: pairwise preference learning, active learning, bandits, Bayesian and empirical-Bayes response models, survival models, calibration and conformal prediction

### Takeaway
With tens to hundreds of labels, the methods that work are low-dimensional Bayesian models with informative priors. hireme's hand-built ladder is the natural prior mean, and LLM-elicited priors are a 2025 option. Add hierarchical or empirical-Bayes shrinkage, and treat "no reply yet" explicitly as censored rather than negative. Concretely:
- a Bayesian residual utility model on top of the ladder, fitted from gates, `score_100` overrides and active pairwise choices;
- a delayed-feedback or mixture-cure model of reply and ghosting, from `applied_on`, `replied_on`, `closed_on` and `outcome`;
- optionally, Thompson sampling under the heat caps to build batches;
- honest uncertainty shown as credible intervals with counts. Conformal bounds are secondary.

### Cited Findings
- Delayed feedback (Chapelle, KDD 2014): conversions arrive up to a month after the event. The Delayed Feedback Model trains a conversion model and an exponential delay model jointly (EM or gradient descent). A fixed waiting window mislabels late positives as negatives. Yoshikawa & Imai (2018) made the delay non-parametric — [ACM DOI 10.1145/2623330.2623634 via Unpaywall](https://unpaywall.org/10.1145%2F2623330.2623634); summaries in [arXiv 1710.08583](https://arxiv.org/pdf/1710.08583) and [arXiv 2011.11826](https://arxiv.org/pdf/2011.11826)
- Mixture cure models write population survival as a cured share (never experiences the event) plus a susceptible share; a plateau in the Kaplan-Meier curve signals the cured share. Fitting an ordinary Cox or Weibull model to such data reads the plateau as a slowly decaying hazard — [Maller et al., Statistics Surveys 2024](https://projecteuclid.org/journals/statistics-surveys/volume-18/issue-none/Mixture-cure-model-methodology-in-survival-analysis--Some-recent/10.1214/24-SS147.full); [Lambert, Stata Journal 2007](https://journals.sagepub.com/doi/reader/10.1177/1536867X0700700304); [MetricGate guide](https://metricgate.com/blogs/mixture-cure-model-survival-r/)
- Conformalized survival analysis (Candès, Lei & Ren, JRSSB 2023, arXiv 2103.09763) wraps any survival model to give calibrated lower predictive bounds on time-to-event. Coverage holds in finite samples under Type I censoring and is doubly robust under conditionally independent censoring — [arXiv 2103.09763](https://arxiv.org/abs/2103.09763v3)
- Conformal prediction tutorial: Angelopoulos & Bates, "A Gentle Introduction to Conformal Prediction". The identifier is from prior knowledge and was not re-fetched this session — [arXiv 2107.07511](https://arxiv.org/abs/2107.07511)
- Gaussian-process preference learning (Chu & Ghahramani, ICML 2005) gives a Bayesian likelihood for pairwise preferences that tolerates noisy labels and learns non-linear utilities from sparse data. Inference costs O(N³) — [paper](https://mlg.eng.cam.ac.uk/zoubin/papers/icml05chuwei-pl.pdf); [scaling note in arXiv 1806.02418](https://arxiv.org/pdf/1806.02418)
- OPEN (Handa, Gal, Pavlick, Goodman, Andreas, Tamkin & Li, arXiv 2403.05534, 2024) chooses informative questions by Bayesian optimal experimental design and uses an LM to extract features and phrase the questions. In user studies it beat LM-only and BOED-only elicitation — [arXiv 2403.05534](https://arxiv.org/pdf/2403.05534)
- AutoElicit (Capstick, Krishnan & Barnaghi, ICML 2025, arXiv 2411.17284) has LLMs elicit priors over the parameters of linear predictive models. Error fell against uninformative priors, especially with few labels, and the approach beat in-context learning. One case saved "over 6 months of labelling effort" — [arXiv 2411.17284](https://arxiv.org/pdf/2411.17284); [PMLR](https://proceedings.mlr.press/v267/capstick25a.html)
- TabPFN (Hollmann et al., Nature 2025) dominates on datasets of up to 10,000 samples and 500 features; in 2.8 s it beats an ensemble of baselines tuned for 4 h — [PubMed](https://pubmed.ncbi.nlm.nih.gov/39780007/)
- TabPFN licences: TabPFN-2.5 weights are non-commercial ("cannot be used for any commercial or production purpose"), as are TabPFN-3 and 3.5. TabPFN-2 is under the Prior Labs License (open, commercial use with attribution, per the docs) — [arXiv 2511.08667](https://arxiv.org/pdf/2511.08667); [Prior Labs models](https://docs.priorlabs.ai/models); [HF tabpfn_2_5](https://huggingface.co/Prior-Labs/tabpfn_2_5)
- Thompson sampling tutorial (Russo, Van Roy, Kazerouni, Osband & Wen, Foundations and Trends in ML 2018) covers Bernoulli bandits, assortment, recommendation and active learning — [arXiv 1707.02038](https://arxiv.org/pdf/1707.02038)
- Bandits with knapsacks, the formalism for exploration under budget constraints (Badanidiyuru, Kleinberg & Slivkins). The identifier is from prior knowledge and was not re-fetched — [arXiv 1305.2545](https://arxiv.org/abs/1305.2545)
- SetFit: with 8 labelled examples per class it is competitive with RoBERTa-large fine-tuned on the full 3k-example Customer Reviews set (blog claim) — [HF blog](https://huggingface.co/blog/setfit); [NeurIPS 2022 abstract](https://neurips.cc/virtual/2022/59465)
- Population priors on employer response:
  - Greenhouse's 2024 State of Job Hunting report: 61% of job seekers were ghosted after an interview (66% of historically underrepresented candidates against 59% of white candidates). More than 2,500 workers in the UK, US and Germany were surveyed. — [Greenhouse](https://www.greenhouse.com/blog/greenhouse-2024-state-of-job-hunting-report); [UNLEASH](https://www.unleash.ai/artificial-intelligence/greenhouse-61-of-job-seekers-have-been-ghosted-during-the-recruitment-process)
  - A secondary source puts the 2025 figure at 63% — [swipejobs](https://www.swipejobs.com/blog/why-employers-ghost-candidates-after-interviews)
  - The referral hire-rate lift is in section 1.
- hireme's data columns:
  - `enum gate pursue maybe skip` and `enum outcome offer rejected ghosted withdrawn declined`;
  - `enum app_channel listing referral recruiter cold other inbound`;
  - `applied_on`, `replied_on` and `closed_on` (day, set by the stage command), `score_100`, `notes`;
  - an append-only `events` table with `kind`, `body`, `actor` and `op_id`;
  - `enum batch_kind day_pack leftover universe_gaps linkedin`.
  - Source: [schema/hireme.schema](../../schema/hireme.schema)
- Heat already hand-sets outcome weights. Ghosted is 0.7 with a 30-day half-life, rejected 1.5 with 90 days, and in conversation 2.0 with 30 days. Load decays as "`weight · 0.5^(days / half_life)`" — [docs/heat.md](../heat.md)

### Inferences
**A. Utility model U: what the operator wants.**
- **Model.** u(x) = ladder(x) + wᵀφ(x), with a Gaussian prior on w.
  - With zero labels it reproduces today's ladder exactly: a safe cold start.
  - "Replace, don't add": move the hand-set heuristic increments (+22 systems, +10 agentic, +8 Rust, +5 home, +6 pay, −16 CRUD) into φ as prior means, with a modest prior standard deviation (for example about 5 points). The data can then move them, and nothing new is bolted on.
- **Likelihoods.** Gates are ordinal (cumulative logit, skip < maybe < pursue). Operator `score_100` overrides are Gaussian observations. Pairwise choices are Bradley-Terry (a logistic of u(a) − u(b)). Labels set by agents (event actor = agent) are excluded or down-weighted.
- **Fitting.** A Laplace approximation by IRLS or Newton with a fixed iteration count, run by the kernel when labels change. With 20-60 features this is about O(d³), roughly 10⁵ floating-point operations: trivial and deterministic.
- **Per-card cost.** Inference is a dot product plus a variance xᵀΣx, about 2.5M multiply-adds for 1,000 cards at d = 50. It runs only on refit or when a row moves, using board.rs's per-row cache. These are estimates.
- **Hard rules stay hard.** docs/score.md says: "A hard kill wins over everything... Nothing raises a kill, not even a named anchor." and "Never lower the bar to fill a quota. Underfill." So the learned residual should apply only to unanchored seats, or reorder only within a rung. It must never lift a kill. Which of the two is an operator design decision.
- **Active pairwise elicitation.**
  - The kernel picks the pair among plausible top-k seats that maximises the posterior variance of u(a) − u(b). This is cheap uncertainty sampling, a simple stand-in for OPEN's BOED.
  - The desk shows it as a one-click "which would you rather?" card.
  - The label should be a `human_only` command (like `open_fire`), because only the operator's choices are evidence of the operator's utility.
  - An LLM is optional here: it can phrase a follow-up "why" or propose new features.
- **LLM-elicited priors (AutoElicit).** An agent proposes prior means and standard deviations for each φ weight, with rationale, stored as cited configuration rows that the operator approves. This matters most in the first weeks, when labels are few.

**B. Response model P: what employers do, from the operator's own outcomes.**
- **Incidence × latency (mixture cure or delayed-feedback model).**
  - p(x) = P(ever replies | x), a logistic model with hierarchical or empirical-Bayes shrinkage across segments: ATS vendor (`ats.rs`), company size tier (`org.rs`), channel, country, seniority match, and coverage from section 2.
  - F(t) = P(reply by day t | replies), a pooled discrete weekly hazard or a Weibull.
  - For an application sent d days ago with no reply: P(eventual reply | silent so far) = p·S(d) / (1 − p + p·S(d)), where S = 1 − F.
- **What this gives.**
  - (a) A principled, steadily rising ghost probability in place of a fixed waiting window. Chapelle shows fixed windows mislabel late positives.
  - (b) An expected reply date.
  - (c) A suggestion to set `outcome = ghosted` once P(eventual reply) falls below a threshold. This is a suggestion only, in keeping with "The kernel **suggests** and never overwrites".
  - (d) Data-driven values for heat's `ghosted_weight` and half-life, eventually.
- **Small data.** Segment rates use Beta-Binomial empirical Bayes: each segment shrinks toward the global rate in proportion to its evidence. External figures such as Greenhouse's 61% post-interview ghosting rate can serve as weak priors.
- **Further funnel stages.** P(interview | reply) and P(offer | interview) are sparse. Show them only once the counts support it.

**C. What to pursue next: Thompson sampling under the heat caps.**
- When a `day_pack` batch is built, sample (w̃, p̃) from the posteriors, rank seats by sampled EV, and fill the batch greedily while respecting heat's company, ATS-vendor and tenant caps. This is a knapsack-like constraint (the bandits-with-knapsacks literature).
- Seed the random generator from (day, account), so the browser and the server produce the same order for a day and the kernel stays deterministic and auditable.
- Feedback is delayed by weeks and sends are perhaps tens per week, so learning is slow. Keep exploration bounded by a setting.
- The same sampling over segments (country × family × tier) can direct agents' discovery effort into `universe_gaps` batches.

**D. Honest uncertainty.**
- Show credible intervals with counts, for example "reply 14% [7–24%], n = 23 similar".
- Evaluate by time-split backtest: Brier score and log loss for P, NDCG of pursue against skip for U, and reliability diagrams once there are about 100 outcomes or more (a rule of thumb, not sourced).
- Conformalised survival bounds ("if a reply comes, it comes after day X with 90% coverage") are valid but wide at this sample size, so they are a low priority.

**E. TabPFN and few-shot text classifiers.**
- Use TabPFN only as an offline yardstick on the server. If it clearly beats the Bayesian logistic model in backtests, add richer features. Do not ship it: the 2.5+ weights are non-commercial, it needs PyTorch, and it is not explainable at the level of rules.
- SetFit, or Model2Vec plus logistic regression, can turn tens of labelled listings into a text feature, for example "would the operator gate this skip?". It can be computed at ingest, or in the kernel as 256 multiply-adds over a static embedding.

#### Scores (section 4)
- Censoring-aware response model (cure or delayed-feedback) with empirical-Bayes segment shrinkage: I5 F4 N3
- Bayesian residual utility model over the ladder (ordinal gates + overrides + Bradley-Terry pairs): I5 F5 N3
- Active pairwise elicitation (uncertainty-sampled "which would you rather?", human-only): I4 F4 N4
- LLM-elicited priors (AutoElicit) as cited, operator-approved configuration rows: I3 F4 N5
- Thompson sampling with a day seed under the heat caps for batches and discovery: I3 F4 N3
- Few-shot text classifier feature (SetFit, or Model2Vec + logistic regression): I3 F4 N3
- Conformalised survival bounds for time to reply: I2 F3 N4
- TabPFN as an offline benchmark only: I2 F3 N4

### Gaps
- I found no empirical study of reply-latency distributions or ghosting incidence for individual job seekers' applications; Greenhouse figures are survey self-reports.
- I found no source on how many pairwise comparisons are typically needed to calibrate a 20-60-feature linear utility. The "few dozen" intuition is unverified.
- I found no job-search study comparing Thompson sampling with greedy selection under delayed feedback.
- I did not verify TabPFN v2's exact licence text.

## 5. Detecting duplicate, reposted, ghost and scam listings

### Takeaway
Near-duplicate detection is a solved, cheap problem: 64-bit SimHash or MinHash with LSH, plus field blocking on normalised company, title and location within a time window. It matters more than it looks, because industry sources estimate that 50-80% of job ads are duplicates or reposts. Ghost jobs are common, with estimates from about 20% to 30% depending on definition, but they have no observable ground truth. Treat ghost risk as an evidence-based likelihood that feeds freshness and P(reply), never as a kill. Scams have shifted to "task" scams and texting, so rule-based red flags plus agent verification of the company domain beat supervised classifiers trained on the 2017-era EMSCAD dataset.

### Cited Findings
- Textkernel estimates that an average job ad is reposted 2-5 times depending on the country, which makes duplicates "as high as 50–80%". It uses shingling with min-wise permutations — [Textkernel](https://textkernel.com/newsroom/online-job-postings-have-many-duplicates-but-how-can-you-detect-them-if-they-are-not-exact-copies-of-each-other)
- Lightcast deduplicates in two steps: it avoids re-collecting ads already seen on a source, then compares normalised title, company and location across sources within 60 days — [Lightcast docs](https://docs.lightcast.io/data/docs/how-does-lightcast-handle-duplicate-postings)
- The Eurostat Web Intelligence Deduplication Challenge used 112,000 multilingual online job ads from about 400 EU websites, with full, semantic, temporal and partial duplicates. A third-place entry scored 0.82 F1 with a lightweight LLM plus semantic relations between ads — [Cedefop slides](https://www.cedefop.europa.eu/files/session4.2_-_oja_deduplication.pdf); [Statistics Poland presentation](https://win2025.stat.gov.pl/Content/Presentations/VI.2%20Jakub%20%c5%bberebecki.pdf)
- CareerBuilder's production near-duplicate system, Apollo (ICDMW 2017) — [IEEE CSDL](https://computer.org/csdl/proceedings-article/icdmw/2017/3800a177/12OmNC17hUn)
- SimHash at web scale (Manku, Jain & Das Sarma, WWW 2007): for 8 billion pages, 64-bit fingerprints with a Hamming distance of k = 3 are "a good choice"; the paper gives a fast method for the k-bit Hamming lookup — [WWW 2007 paper](https://www2007.cpsc.ucalgary.ca/papers/paper215.pdf)
- Rust implementations: gaoya provides MinHash (8-, 16-, 32- and 64-bit) with a banded LSH index, plus SimHash; txtfp provides MinHash + LSH, SimHash and ONNX embeddings — [gaoya](https://docs.rs/crate/gaoya/latest); [txtfp](https://docs.rs/crate/txtfp/latest)
- Ghost job estimates:
  - Hunter Ng (arXiv 2410.21771): using Glassdoor data and an "LLM-BERT technique", "up to 21% of job ads may be ghost jobs", most common in specialised industries and larger firms; ghost jobs can explain a Beveridge-curve disconnect — [arXiv 2410.21771](https://arxiv.org/abs/2410.21771)
  - Greenhouse 2024: three in five candidates suspect they have met a ghost job — [Greenhouse](https://www.greenhouse.com/blog/greenhouse-2024-state-of-job-hunting-report)
  - Coverage of a Greenhouse analysis: about 1 in 5 postings are not real — [Fox 9](https://www.fox9.com/news/ghost-jobs-greenhouse-analysis)
  - A MyPerfectResume-commissioned JOLTS analysis: 30% of openings in June 2025 (over 2.2M) never resulted in a hire — [CPA Practice Advisor](https://www.cpapracticeadvisor.com/2025/11/12/ghost-jobs-up-to-1-in-3-job-listings-dont-result-in-hires/173044/)
  - These definitions differ and the numbers are not comparable. A legal treatment exists — [Columbia Law Review](https://columbialawreview.org/?p=6312)
- Job scams (FTC, Dec 2024): reported losses tripled from 2020 to 2023 and exceeded $220M in the first half of 2024. Task scams rose from about 5,000 reports in 2023 to about 20,000 in the first half of 2024, nearly 40% of 2024 job-scam reports. Cryptocurrency is the payment of choice ($41M in the first half of 2024) — [FTC press release](https://ftc.gov/news-events/news/press-releases/2024/12/new-ftc-data-show-skyrocketing-consumer-reports-about-game-online-job-scams)
- A secondary summary of full-year 2024 figures ($501M; also ">$750M") is internally inconsistent — [Bitdefender](https://www.bitdefender.com/en-us/blog/hotforsecurity/job-scams-americans-millions-dollars-2024)
- Fraud classifiers:
  - EMSCAD has 17,880 postings, 866 of them fake, as commonly reported (Vidros et al., Future Internet 2017; the MDPI link is from prior knowledge, and the counts come from a search summary, not the paper itself) — [MDPI](https://www.mdpi.com/1999-5903/9/1/6)
  - Fraud-BERT (2025) reports F1 0.93 — [Springer](https://link.springer.com/article/10.1007/s10791-025-09502-8)
  - An LLM plus deception-theory framework (SMU, 2026) — [SMU](https://ink.library.smu.edu.sg/sis_research/11168)
- Hidden-text injection: most resume injections hide as white or low-contrast text — [arXiv 2605.28999](https://arxiv.org/pdf/2605.28999); [Duke Pratt](https://pratt.duke.edu/news/thwarting-prompt-injection/)
- hireme baseline:
  - `applications` deduplicates exactly, with the natural key `canonical_url`, and has `freshness` (open, thin, closed, blocked) and `listing_on` — [schema](../../schema/hireme.schema)
  - The listing parser already blanks tags, `<style>` and `<script>` bodies, link targets and URLs before extracting words — [keywords.rs](../../native/kernel/src/keywords.rs)
  - Hard kills exist for staffing (8), AI theatre (10), internship tier (12), non-engineering roles (15) and onsite away from home (15) — [docs/score.md](../score.md)

### Inferences
- **Near-duplicates at write time.**
  - In the same pass as `keywords::extract`, compute a 64-bit SimHash over word 3-gram shingles of `prose()`, plus a blocking key (normalised company, family, place).
  - Job ads are short and templated, so tune k on the operator's own data. Expect a looser threshold than k = 3 for web pages, or use MinHash with 64-128 hashes; this is an assumption.
  - Store the cluster (earliest member), cluster size, first seen (the minimum `listing_on`), repost count (distinct `listing_on` days) and clones across cities.
  - It is about 40 lines of Rust with no dependency (gaoya exists if LSH is needed at the 50k scale). Comparing 1,000 fingerprints by Hamming distance takes microseconds (estimate).
- **Uses.**
  - The board folds a cluster into one card with a "reposted 4× since …" chip, which prevents double applications and saves heat; heat counts a cluster as one role.
  - `freshness` turns "thin" when the cluster is old (for example over 60-90 days) or reposted at least 3 times. These thresholds should be learned in section 4's response model, not hand-set.
- **Ghost likelihood: an evidence list, not a verdict.** Inputs:
  - cluster age and repost count;
  - "evergreen" phrases in the lexicon ("talent pool", "always looking", "future opportunities");
  - missing pay where a pay-transparency law applies (needs a jurisdiction table in `places`);
  - layoff or hiring-freeze news, cited by agents in `sources`;
  - the company's own reply history (the empirical-Bayes rate from section 4);
  - how many near-identical postings are open at once.

  These are logistic features with priors that feed P(reply) and a freshness hint. Never kill on ghost risk alone, because the ground truth is unobservable.
- **Scam and injection red flags.** These are hard rules that can extend score.rs's kill list or set `freshness = blocked`:
  - contact through WhatsApp, Telegram or SMS;
  - any payment, equipment cheque or cryptocurrency;
  - "task", "rating" or "optimisation" gig wording;
  - an email or apply domain that differs from the company's verified domain (an agent checks it and cites the source);
  - an offer without an interview.

  Apply the same checks to inbound recruiter mail (`channel` inbound or recruiter, and the mail tables), since unsolicited outreach is where a senior engineer most likely meets scams (an inference). Flag hidden text in HTML listings (`display:none`, zero font size, same colour as the background) as an injection risk before agents read the listing.

#### Scores (section 5)
- SimHash or MinHash near-duplicate clustering with repost and age features: I4 F5 N2
- Evidence-based ghost likelihood feeding freshness and P(reply): I4 F4 N4
- Scam and hidden-text red-flag rules, with agent verification of the domain: I3 F5 N2
- Supervised fraud classifier trained on EMSCAD: I1 F3 N2, an anti-candidate

### Gaps
- No ground-truth dataset of ghost jobs exists. I found no peer-reviewed validation of any ghost-job detector, and Ng's "LLM-BERT" method is not described on the abstract page.
- I found no peer-reviewed comparison of deduplication methods on job-ad data beyond Apollo and the Eurostat challenge materials, and no tuned SimHash k or MinHash thresholds for job ads.
- I could not verify EMSCAD's provenance details in this session.

## 6. Explaining scores and rankings to the operator at tiny cost

### Takeaway
hireme's score is already additive rules with clamps, so exact attributions are free. A learned residual that is linear or additive in φ keeps them exact: for a linear model, w_i(φ_i − E[φ_i]) is the SHAP value. Counterfactuals have closed forms ("with a referral, reply 9% → 22%"). Generalised additive models (EBM) extend this to non-linear shapes as table lookups. User studies in job recommendation suggest presenting explanations as decision support with "healthy friction" (evidence and uncertainty), not persuasion. LLM-written rationales must not stand in for the explanation of a kernel number.

### Cited Findings
- InterpretML's Explainable Boosting Machine (Nori, Jenkins, Koch & Caruana, arXiv 1909.09223) is a generalised additive model (a fast derivative of GA2M) that "can be as accurate as many blackbox models" (the authors' claim). MIT licence — [arXiv 1909.09223](https://arxiv.org/pdf/1909.09223); [GitHub interpretml/interpret](https://github.com/interpretml/interpret/blob/b4a3181a9618c39b745081133863f1704b72eac8/README.md)
- Schellingerhout, Barile & Tintarev, "Creating Healthy Friction" (RecSys-in-HR 2024, arXiv 2409.15971): in a 30-participant mixed-design study, real explanations did not significantly improve decision speed or accuracy compared with random ones. There was a non-significant trend toward more trust, usefulness and transparency. Explanations work better "as decision support that adds healthy friction" than as persuasion — [arXiv 2409.15971](https://www.arxiv.org/abs/2409.15971); [CEUR](https://ceur-ws.org/Vol-3788/RecSysHR2024-paper_7.pdf); related co-design study [arXiv 2309.05507](https://arxiv.org/pdf/2309.05507) and multi-stakeholder explanations [arXiv 2410.00654](https://arxiv.org/html/2410.00654v1)
- LANTERN distils an LLM into a separate explanation decoder alongside the fit classifier — [arXiv 2510.05490](https://arxiv.org/abs/2510.05490)
- SHAP (Lundberg & Lee, NeurIPS 2017) includes the linear-model case, where the attribution is the weight times the feature's deviation from its mean. The identifier is from prior knowledge — [arXiv 1705.07874](https://arxiv.org/abs/1705.07874)
- Counterfactual explanations: Wachter, Mittelstadt & Russell 2017 ([arXiv 1711.00399](https://arxiv.org/abs/1711.00399)); DiCE, Mothilal, Sharma & Tan, FAT* 2020 ([arXiv 1905.07697](https://arxiv.org/abs/1905.07697)). Both identifiers are from prior knowledge.
- Chain-of-thought explanations can be unfaithful to the model's actual reasons (Turpin et al., NeurIPS 2023; identifier from prior knowledge) — [arXiv 2305.04388](https://arxiv.org/abs/2305.04388)
- hireme's score suggestion already carries the rules it read: score.rs has a "What a suggestion reads" struct with `to_json`, and "the focus lens and the MCP show both" (the stored and suggested scores) — [score.rs](../../native/kernel/src/score.rs); [docs/score.md](../score.md)
- Heat refusals already return "the verdict as data, including `cooldown_days`" — [docs/heat.md](../heat.md)

### Inferences
- **One explanation shape for every kernel number.** Use a list `why: [{factor, contribution, evidence}]`, where evidence is a span in the listing, a citation, or a count of similar outcomes:
  - the ladder's rule contributions;
  - the residual's w_i(φ_i − φ̄_i), with its posterior standard deviation;
  - the response model's segment rate with n;
  - heat's verdict.

  These are exact for additive models, cost O(d) per focused card, and are available to agents over MCP in the same JSON.
- **Pairwise "why A above B".** Show the difference of two cards' attribution lists ("A +22 systems; B −16 CRUD; B blocked by `ats_vendor_cap`"). This is the explanation the board order actually needs.
- **Closed-form counterfactuals.** For each actionable lever, recompute EV with the lever flipped:
  - a referral channel;
  - covering a missing must-have concept, by adding a CV item or overlay;
  - a pay figure being present;
  - remote work mode.

  That is d recomputations per focused card, microseconds each. Rule thresholds give exact counterfactuals for the ladder ("85 with a pay figure ≥ $200k in `comp_raw`, else 80").
- **Presentation with healthy friction.** Show evidence, uncertainty and counts ("n = 23 similar applications"), not persuasive prose. LLM commentary can sit beside the number as cited agent text, clearly marked, never as "the reason".
- **EBM only if non-linear shapes are needed.** Train it on the server with interpret (MIT) and export the bins and shape tables as rows; kernel inference is then table lookups. A binned logistic model fitted in the kernel already covers most of this with less code.

#### Scores (section 6)
- Exact additive attributions plus closed-form counterfactuals in the focus lens and MCP: I4 F5 N2
- Uncertainty-aware explanations (posterior standard deviation, n, evidence spans): I3 F5 N3
- EBM shape functions as lookup tables: I2 F3 N3
- Post-hoc SHAP, LIME or DiCE libraries over a black box: I1 F2 N2, an anti-candidate
- LLM-written rationales presented as the explanation of kernel scores: an anti-candidate

### Gaps
- I found no study of explanations aimed at a single expert job seeker who also configures the system (most HR explanation studies are multi-stakeholder or employer-side).
- I did not find a measured comparison of EBM against logistic regression on small (n < 500) preference data.

## 7. Per-technique scorecard, integration map and anti-candidates

### Takeaway
The best return for hireme comes from small Bayesian models over data hireme already records (gates, overrides, stages, outcomes, dates), from moving prose understanding to agents at ingest with verbatim-span checks, and from a static-embedding and SimHash layer in the kernel. Each of these replaces something: hand-tuned increments become priors, exact-token coverage becomes concept coverage, a fixed ghosting judgement becomes a censoring-aware probability. Anything that needs platform-scale data, per-interaction LLM calls, transformer inference in the browser, or non-commercial weights should be rejected.

### Cited Findings
- Per-interaction LLM judgement is unstable: GPT-4 kept its verdict after swapping order only 65.0% of the time — [arXiv 2306.05685](https://arxiv.org/pdf/2306.05685)
- Retrieval models carry demographic bias (85.1% White-associated preference) — [AIES 2024](https://ojs.aaai.org/index.php/AIES/article/view/31748)
- Untrusted documents carry prompt injections (about 1% of 200K resumes) — [arXiv 2605.28999](https://arxiv.org/pdf/2605.28999)
- Browser WASM transformer inference costs about 451-507 ms per 512-token input for MiniLM — [Xenova benchmark](https://huggingface.co/spaces/Xenova/webgpu-embedding-benchmark/discussions/1)
- TabPFN-2.5 and later weights are non-commercial — [arXiv 2511.08667](https://arxiv.org/pdf/2511.08667)
- Lightcast's free tier now covers only nonprofits and public-good use — [Lightcast](https://docs.lightcast.io/lightcast-api/docs/api-access)
- Platform foundation models are 150B parameters trained on first-party platform data — [360Brew](https://export.arxiv.org/pdf/2501.16450)
- Tailored applications lost their signal premium after LLMs — [arXiv 2511.08785](https://arxiv.org/html/2511.08785v1)
- Hybrid modular pipelines won TalentCLEF 2026 — [overview](https://arxiv.org/html/2606.31692v1)
- hireme's operating rules: "FIRE HOLD stands: a score never submits." and "maximize life EV, not the number of applications" — [docs/score.md](../score.md)
- Heat: "nothing here sends an application" — [docs/heat.md](../heat.md)

### Inferences
#### Scorecard (I / F / N; replaces → plug-in point; cost; risk)
1. **Censoring-aware reply and ghosting model** (mixture cure or delayed feedback, empirical-Bayes segment shrinkage). Chapelle KDD 2014; Maller et al. 2024; Candès et al. 2023 for optional bounds. **5 / 4 / 3.**
   - Replaces: the manual ghosting judgement and the fixed waiting windows.
   - Plugs into: a new kernel module beside `heat.rs` that reads `applied_on`, `replied_on`, `closed_on`, `outcome`, `channel`, ATS and size tier; the focus lens; an "EV" board sort; MCP `get` and `find` fields; suggested `outcome = ghosted`.
   - Cost: about 150-250 lines of Rust; no new data. Risk: little data in the first months, so show n and intervals.
2. **Bayesian residual utility over the ladder** (ordinal gates, overrides, Bradley-Terry pairs; Laplace fit in the kernel). Chu & Ghahramani 2005; Russo et al. 2018 for posterior sampling. **5 / 5 / 3.**
   - Replaces: hand-tuned heuristic increments, which become prior means.
   - Plugs into: `score.rs` (suggestion = ladder + residual; kills and anchors untouched), `board.rs` per-row cache, and a `human_only` `prefer` command.
   - Cost: about 200 lines. Risk: overfitting with few labels, held back by the priors; the operator decides where the residual may act.
3. **Active pairwise elicitation** (uncertainty-sampled pairs; optional LLM phrasing in the style of OPEN). Handa et al. 2024. **4 / 4 / 4.** Plugs into: a desk card plus a human-only command. Risk: annoying the operator, so cap it at a few a day.
4. **LLM-elicited priors** (AutoElicit, ICML 2025). **3 / 4 / 5.** Plugs into: cited configuration rows written by agents through MCP `put`, approved by the operator. Risk: miscalibrated priors, so keep the standard deviations wide.
5. **Agent-extracted typed requirements with verbatim span verification, plus ESCO concept coverage.** Nguyen 2024; Zhang 2024 entity linking; Clavié & Soulié 2023; Decorte 2023; TalentCLEF 2026 Task B. **5 / 4 / 3.**
   - Replaces: the 12-most-frequent-words exact coverage, kept as a literal readout.
   - Plugs into: an ingest step (agent `put` or server job), a kernel span verifier, a `concepts` world table, `keywords.rs` coverage, and `compose.rs` and `mask.rs` facts.
   - Cost: schema plus about 300 lines, plus agent prompts. Risks: drift (pin versions), ESCO tech coverage, injection (span check).
6. **Static embeddings in the kernel, hybrid with BM25 through RRF.** Model2Vec; the Sentence Transformers static blog; Cormack et al. 2009. **4 / 4 / 4.**
   - Replaces: purely lexical search and similarity.
   - Plugs into: `board.rs` search, MCP `find`, semantic coverage, "more like this", and near-duplicate stage 2.
   - Cost: a token table in BOOT (a few MB after pruning; estimate) and about 150 lines. Risk: cold-load size and multilingual quality.
7. **SimHash or MinHash near-duplicate clustering, plus repost and age features.** Manku et al. 2007; Textkernel; Lightcast; Eurostat. **4 / 5 / 2.**
   - Replaces: manual duplicate spotting; exact `canonical_url` only.
   - Plugs into: the listing write pass, the board fold, heat (one role per cluster), and `freshness`.
   - Cost: about 60-100 lines. Risk: templated ads from one company that are different roles, so block on title family.
8. **Evidence-based ghost likelihood.** Ng 2024; Greenhouse 2024. **4 / 4 / 4.** Plugs into: features for item 1, and freshness hints. Risk: no ground truth, so never a kill.
9. **Scam and hidden-text red-flag rules, with agent domain verification.** FTC 2024; arXiv 2605.28999. **3 / 5 / 2.** Plugs into: the `score.rs` kill list or `freshness = blocked`, and checks on inbound mail.
10. **Exact attributions and closed-form counterfactuals everywhere.** SHAP linear case; Wachter 2017; Schellingerhout 2024. **4 / 5 / 2.** Plugs into: suggestion and verdict JSON, the focus lens, and MCP.
11. **Offline LLM judges distilled into the kernel's features and labels, plus a daily agent listwise rerank of the shortlist.** LANTERN; LinkedIn semantic search; ConFit v3; TalentCLEF 2026. **3-4 / 4 / 4.** Plugs into: `day_pack` batches and agent-written cited rows. Risks: order bias (use multi-pass with swaps) and cost.
12. **JobBERT-v3 title normalisation on the server** (MIT, 0.3B). **3 / 3 / 4.** Plugs into: an occupation ID per application and `org.rs` family and department for heat similarity.
13. **Few-shot text classifier feature** (SetFit, or Model2Vec plus logistic regression). **3 / 4 / 3.** Plugs into: a φ_text feature for item 2.
14. **Thompson sampling under the heat caps** for batches and discovery. **3 / 4 / 3.** Plugs into: the `day_pack` and `universe_gaps` builders, with a day seed for determinism.
15. **Inference-free learned sparse retrieval.** Geng 2024; Li-LSR 2025. **3 / 3 / 4.** An explainable alternative to item 6 if English-only is acceptable.

Suggested order, from impact × feasibility and data already in hand (an inference): 1 → 2 (+3) → 7 → 5 → 6 → 10 throughout → 11, 8 and 9 → the rest.

#### Anti-candidates (do not adopt) and why
- **Platform recommenders and person-job fit training** (ConFit-style dual encoders trained from scratch, GIRL, LGIR, GNN recommenders, 360Brew-scale foundation models). They need large two-sided interaction data; hireme has one operator. 360Brew is 150B parameters on first-party platform data.
- **LLM scoring or reranking inside the interactive path** (in the browser, or a synchronous server call per interaction). It takes seconds, is non-deterministic and order-sensitive (65% swap consistency), costs money per call, and is exposed to injection from untrusted listing text. LLMs belong at ingest and in batches, writing cited data the kernel judges.
- **Transformer encoders run in browser WASM per keystroke** (MiniLM, bge-small, EmbeddingGemma). About 0.4-0.5 s per 512-token input in WASM; use static embeddings instead, and put transformers on the server.
- **Fine-tuning an LLM, or a deep model, on the operator's own outcomes.** Tens to hundreds of labels overfit, the result cannot run in the deterministic kernel, and it cannot be explained.
- **TabPFN or other black boxes as the shipped ranker.** The 2.5+ weights are non-commercial, it needs a PyTorch runtime, there is no WASM or NIF parity, and it cannot be explained at the level of rules. Use it only as an offline yardstick.
- **ANN indexes in the client** (HNSW, FAISS). Unnecessary at 1,000-50,000 items: brute-force int8 or binary search with rescoring is under a millisecond to a few milliseconds.
- **Lightcast's API as a dependency.** Its free tier is nonprofit and public-good only, with 50 extractions a month; for-profit use needs a licence. Prefer ESCO plus hireme's own alias table.
- **Supervised scam or ghost classifiers trained on EMSCAD or public "fake job" sets.** The data is dated, from a different domain, and does not cover task and texting scams. Ghost jobs have no ground truth. Use rules plus evidence-based likelihoods.
- **Volume-maximising automation** (auto-apply, mass-tailoring optimisation). It violates "FIRE HOLD stands: a score never submits." and "maximize life EV, not the number of applications", and tailored-text signals lost value after LLMs (Galdin & Silbert).
- **Full reinforcement learning (PPO and the like) over application strategy.** Far too little feedback, delayed by weeks. Bounded Thompson sampling on a posterior is the most exploration the data supports.
- **Dense-only retrieval with no lexical component.** Exact tool names ("c++", "rust", "node.js") need lexical matching. BM25 still scores 0.4518 against 0.5032 for the static model on NanoBEIR, the two are complementary, and TalentCLEF 2026's winners were hybrid.
- **Post-hoc SHAP, LIME or DiCE packages over opaque models, or LLM-written "reasons" for kernel numbers.** They are unnecessary when the model is additive, and LLM self-explanations can be unfaithful (Turpin 2023).

### Gaps
- The scores in this section are the researcher's judgement from the cited evidence and a read of hireme's code; none was measured on hireme's data.
- The line-count and latency estimates (for example "about 200 lines" and "under a millisecond") are estimates, not benchmarks. They should be confirmed with the repo's perf harness on the operator's node before any claim of done.
- I did not research whether any of these techniques changes the heat governor's best caps or half-lives; that needs the operator's outcome history.
