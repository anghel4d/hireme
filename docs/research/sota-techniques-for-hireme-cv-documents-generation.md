# CV and cover-letter generation, document understanding and structured extraction: state of the art (2024-2026) applied to hireme

Notes compiled 2026-10-20. Hireme facts below come from a read-only skim of the repository and are cited to local files. Today, hireme composes each application's CV from profile items through per-application `tailor` / `add` / `drop` overlays under a per-corporation lineage guard ([cv.rs](../../native/kernel/src/cv.rs)). It extracts the listing's 12 most frequent words once (`TOP = 12`, rules versioned `VERSION = 5`) and counts exact whole-term coverage by the CV text ([keywords.rs](../../native/kernel/src/keywords.rs)). It reads file CVs once at upload with hand-written readers: markdown as is, docx paragraphs, .doc pieces, and PDF strings through ToUnicode maps, in content-stream order with a line break on each vertical move, with no OCR and no column or hidden-text handling ([blobs.ex](../../lib/hireme/blobs.ex)). The `citations` table stores `table, row_id, column, source_id, value, as_of, actor, key_id, op_id` and no span or quote. `cv_overlays` stores `item_id, lineage_id, mode, title, body, reason, generation`, and `applications` carries `listing_raw, listing_format, keywords, keywords_version, work_mode, employment, comp_raw, notes, battleplan, letter_raw, outcome, replied_on` ([priv/schema.json](../../priv/schema.json)). Refusals reach agents as diagnostics that name the next step ([diag.rs](../../native/mcp/src/diag.rs)).

## 1. LLM-based CV tailoring and cover-letter generation: quality, faithfulness, hallucination, and grounding in the candidate's records

### Takeaway
Free LLM rewriting of a CV fabricates almost every time. In the one controlled study found, 96.7% of fully automated outputs carried at least one unsupported claim, and a newer model still did so 90.0% of the time. Prompt guardrails reduce how many claims are unsupported but not how often an output contains one. Human reviewers catch flagrant fabrications but miss about half of the subtle ones: dropped qualifiers, plausible new claims, and claims baited by the listing. What works is structural: select from the candidate's own records, keep edits bounded, attribute every claim to a record, and verify it mechanically. Exact token, entity and number support comes first; entailment or LLM checks come second and stay advisory, because factuality metrics are biased against paraphrase. AI-polished customization has also lost much of its value as a signal to employers, so letters should carry verifiable specifics rather than polish.

### Cited Findings
- **Fabrication in multi-stage hiring pipelines (most on-target study found).** Takano, "Mitigating Fabrication in Multi-Stage LLM Pipelines for Hiring: An Empirical Evaluation of Prompt Guardrails and Human-in-the-Loop Checkpoints" (single-author preprint, cs.CY; v1 22 Jul 2026, v2 16 Sep 2026; arXiv 2608.26171). The design was 180 runs: 10 synthetic resumes × 2 job descriptions × 3 repetitions × 3 conditions. Results:
  - Fully automated baseline: at least one unsupported claim in 96.7% of outputs, with a mean of 6.80 findings per output.
  - Prompt guardrails: finding density fell 86% (6.80 to 0.92), but 50.0% of outputs still contained a fabrication. Capture of trap requirements embedded in the job description fell to 5%, from 47% at baseline.
  - Human checkpoint after resume improvement: eliminated identity fabrications, cut density 59% (6.88 to 2.82), cut item-level fabrication from 96.7% to 75.0% (p = .022), and cut trap capture to 2%.
  - The reviewer caught all flagrant fabrications but removed only 54.5% of "subtle qualifier drops and plausible new claims".
  - Claim retention stayed above 99% under both mitigations.
  - Contamination rose monotonically with the domain distance between a resume's specialties, so career changers are most exposed.
  - A supplementary run with a newer-generation model had a 90.0% baseline fabrication rate.
  - The main experiment's models are not named on the abstract page. — [arXiv 2608.26171](https://arxiv.org/abs/2608.26171)
- **ResumeFlow.** Zinjad, Bhattacharjee, Bhilegaonkar, Liu (SIGIR 2024 demo; arXiv 2402.06221) tailor a resume in three steps: extract job-description details, extract role-specific resume details, then refine and generate. The models are off-the-shelf GPT-4 or Gemini with no fine-tuning. The authors propose metrics for alignment with the job description and for hallucination, meaning content unsupported by the original resume. The abstract page gives no numbers. — [arXiv 2402.06221](https://arxiv.org/abs/2402.06221)
- A 2026 systematized review of AI recruitment systems warns that resume-completion and enhancement approaches "risk converting plausible model knowledge into false biographical evidence". This is from a search snippet; the review was not read in full. — [arXiv 2609.04286](https://arxiv.org/pdf/2609.04286)
- A CLiC-it 2025 paper pairs an ATS-style score with LLM rewrites. Its prompt carries the resume, the job description and "the list of already matched keywords". The snippet shows no fabrication check. — [ACL Anthology 2025.clicit-1.51](https://aclanthology.org/2025.clicit-1.51.pdf)
- **FActScore (seminal).** Min et al. (EMNLP 2023; arXiv 2305.14251) split long-form text into atomic facts and score the fraction that a knowledge source supports. ChatGPT scored 58% on biographies. The automated estimator stays within 2% error of human FActScore. — [arXiv 2305.14251](https://arxiv.org/abs/2305.14251)
- **Entity-level factual consistency (seminal).** Nan et al. (EACL 2021; arXiv 2102.09130) propose entity-level consistency metrics. Summarizers trained on standard datasets hallucinate entities absent from the source, and filtering the training data alone reduces entity hallucination. — [arXiv 2102.09130](https://arxiv.org/abs/2102.09130)
- **MiniCheck.** Tang, Laban, Durrett (EMNLP 2024; arXiv 2404.10774) build small fact-checkers with "GPT-4-level performance but for 400x lower cost". MiniCheck-FT5 (770M parameters) "reaches GPT-4 accuracy" on their unified LLM-AggreFact benchmark. — [arXiv 2404.10774](https://arxiv.org/abs/2404.10774)
  - A third-party listing describes LLM-AggreFact as 11 datasets with 13,122 test instances. — [alphaXiv](https://www.alphaxiv.org/benchmarks/the-university-of-texas-at-austin/llm-aggrefact)
  - The Hugging Face repo lytang/MiniCheck-Flan-T5-Large is tagged MIT (search snippet; the LICENSE file itself was not checked). A third-party ONNX export exists under MIT. — [HF MiniCheck-Flan-T5-Large](https://huggingface.co/lytang/MiniCheck-Flan-T5-Large/commit/b0bab3363de0c09f2306608de75616ee1ccb4099), [HF ONNX export](https://huggingface.co/FamiliarTools/MiniCheck-Flan-T5-Large-onnx)
- **Bespoke-MiniCheck-7B.** The vendor claims 77.4% average balanced accuracy on LLM-AggreFact, against Vectara HHEM-2.1 at 71.8% on the same vendor page. It is built on internlm2.5-7b-chat with 32K context, and its license is non-commercial, CC BY-NC 4.0. — [Bespoke Labs](https://bespokelabs.ai/bespoke-minicheck), [PromptLayer](https://www.promptlayer.com/models/bespoke-minicheck-7b). An independent paper notes Bespoke-7B and gpt-4-turbo were the top leaderboard evaluators at release. — [arXiv 2501.14883](https://arxiv.org/pdf/2501.14883)
- **HHEM-2.1-Open.**
  - 110M parameters, per Vectara's own benchmark paper. — [arXiv 2505.04847](https://arxiv.org/pdf/2505.04847)
  - Under 1.5 s on an Intel Xeon w7-3445 for 2k tokens of premise plus hypothesis. — [Vectara blog](https://www.vectara.com/blog/hhem-2-1-a-better-hallucination-detection-model/)
  - Under 600 MB of memory at fp32 and Apache 2.0, per a third-party directory (not verified on the model card). — [PromptLayer](https://www.promptlayer.com/models/hallucinationevaluationmodel)
- **Pitfalls of factuality metrics.** Godbole and Jia (arXiv 2501.14883, Jan 2025) re-evaluated five state-of-the-art factuality metrics on 11 datasets. They found the metrics "inconsistent with each other" and that they "often misestimate system-level performance". The metrics are biased against highly paraphrased outputs and against outputs drawing on faraway parts of the source. The authors recommend manually validating the metrics. — [arXiv 2501.14883](https://arxiv.org/abs/2501.14883)
- **Quote-Tuning.** Zhang, Marone, Li, Van Durme, Khashabi (NAACL 2025; arXiv 2404.03862) align models to quote verbatim from trusted corpora. This raises verbatim quoting "up to 130% relative to base models" while maintaining response quality, and fast membership inference does the verification. — [arXiv 2404.03862](https://arxiv.org/abs/2404.03862)
- **Claude Citations (vendor feature agents can use).** With citations enabled on document blocks, each citation carries `cited_text`, `document_index`, and a location: `char_location` (start and end character index) for plain text, `page_location` (1-indexed) for PDF, or `content_block_location` for custom content. `cited_text` does not count toward output tokens. Citations cannot be combined with structured outputs: `output_config.format` returns a 400. — [Anthropic Citations docs](https://platform.claude.com/docs/en/build-with-claude/citations), [Structured outputs docs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
- **Bias in generated letters.** Wan et al., "Kelly is a Warm Person, Joseph is a Role Model" (Findings of EMNLP 2023; arXiv 2310.09219), report "significant gender biases" in reference letters generated by ChatGPT and Alpaca. The biases span lexical content and language style, plus a "hallucination bias" amplified in invented content. The authors warn against using such letters without careful review. — [arXiv 2310.09219](https://arxiv.org/abs/2310.09219)
- **AI-written applications lost signal value (Freelancer.com).** Galdin and Silbert, "Making Talk Cheap: Generative AI and Labor Market Signaling" (arXiv 2511.08785, Nov 2025). — [arXiv HTML](https://arxiv.org/html/2511.08785), [abstract](https://arxiv.org/abs/2511.08785)
  - Before LLMs, a one-SD higher customization signal was worth as much as a $25.67 lower bid (considered applications, Table 2). In post-LLM data it is worth $10.82. Our arithmetic from the reported values puts the drop near 58%; across all applications it falls from $25.44 to $6.39, about 75%.
  - The mean customization signal rose from 5.16 to 7.50 (0-18 scale). Applications written with the platform's AI tool averaged 11.88.
  - In a counterfactual where writing is uninformative, top-quintile workers are hired 19% less often, bottom-quintile workers 14% more often, and average wages fall 5%.
  - A secondary summary says employer responsiveness fell "over 60%". That is consistent in direction but differs in magnitude. — [Emergent Mind](https://www.emergentmind.com/papers/2511.08785)
- **Cover-letter tool on a large platform.** Cui, Dias, Ye, "Signaling in the Age of AI: Evidence from Cover Letters" (arXiv 2509.25054, v2 Nov 2025):
  - Access to the AI cover-letter tool raised the letters' alignment with job posts and raised callback rates.
  - Time spent editing AI drafts correlated positively with hiring success.
  - After the tool launched, the correlation between alignment and callbacks "fell by 51%", and employers shifted toward other signals such as prior work histories. — [arXiv 2509.25054](https://arxiv.org/abs/2509.25054)
- **Writing assistance on resumes.** Wiles, Munyikwa, Horton (NBER w30886; Management Science 2025) ran a field experiment with nearly half a million jobseekers. Algorithmic writing assistance, described as non-generative in the published version, led to 8% more hires, with no evidence that employers were less satisfied. — [NBER w30886](https://www.nber.org/papers/w30886), [arXiv 2301.08083](https://arxiv.org/pdf/2301.08083)

### Inferences
- **Hireme already has the strongest structure the literature points to.** It composes from records, with a corpus of items plus bounded overlays, rather than generating free text. The lineage guard ([cv.rs](../../native/kernel/src/cv.rs)) adds cross-application consistency. The remaining fabrication risk is concentrated in two free-text surfaces: `tailor` overlays, which rewrite an item's title or body, and `letter_raw`.
- **Takano's subtle failure classes map to deterministic checks with hireme's existing tokenizer.**
  - "Plausible new claims" and JD-baited claims show up as tokens present in the listing (`applications.keywords`) but absent from the source item.
  - "Qualifier drops" show up as hedges removed ("helped", "contributed to", "assisted", "co-", "part of") or ownership verbs escalated ("led", "owned", "architected").
  - Identity fabrications show up as new names, organizations, titles, dates and numbers.
  - None of these needs a model, so they fit a deterministic kernel that runs identically in WASM and the NIF.
- **T1. Claim-support gate on `tailor` and `add` overlays.** Impact 5, feasibility 5, novelty 4.
  - **What it checks.** On each `cv_overlays` write, compute the overlay's new material against its source item (the `items` title, body, org, span and keywords), with the rest of the profile corpus as a weaker support set:
    - (i) numbers and dates, reusing the number tokenizing in [score.rs](../../native/kernel/src/score.rs);
    - (ii) capitalized names, organizations and tools;
    - (iii) listing keywords absent from the source item, the "JD-baited" class;
    - (iv) scope escalation and qualifier drops, from a small needle set in [lexicon.rs](../../native/kernel/src/lexicon.rs).
  - **Where the result goes.**
    - [compose.rs](../../native/kernel/src/compose.rs) emits the support status, so the browser focus lens and the MCP render the same thing.
    - The MCP `put` returns a diagnostic in the [diag.rs](../../native/mcp/src/diag.rs) style under the provenance check.
    - The operator can accept unsupported tokens by writing a justification. The existing `cv_overlays.reason` column can hold it, mirroring `heat_override_reason`, so the change replaces rather than adds.
    - FIRE HOLD is unaffected because the human decides.
  - **Cost.** Roughly 150-250 lines of Rust reusing [keywords.rs](../../native/kernel/src/keywords.rs) and [text.rs](../../native/kernel/src/text.rs), with no model.
  - **Risks.** False positives on legitimate rewording are limited by checking only numbers, entities, listing keywords and scope words. Semantic inflation without new tokens is missed; T3 covers that. To avoid alarm fatigue, the gate should warn, not refuse.
- **T2. Cite-or-drop letters.** Impact 4, feasibility 4, novelty 4.
  - `letter_raw` sentences carry inline item references, for example `[[item-key]]`, that the kernel resolves against items shown in the composed CV or the corpus.
  - T1's token check then runs on each sentence against its cited items. Sentences with numbers, entities or listing keywords but no citation are flagged. References are stripped when the letter is rendered for sending.
  - Agents may use vendor citation features to produce the spans, but verification stays in the kernel and works with any leased model.
  - Supported by FActScore-style claim decomposition, Quote-Tuning's verifiability gains, and Wan et al.'s case for reviewing generated letters.
  - Risk: stilted prose if the rules are over-applied, so only factual sentences need citations.
- **T3. Entailment second pass, advisory only.** Impact 3, feasibility 3, novelty 2.
  - For paraphrased sentences that pass T1, check entailment against the cited items' text.
  - Server-side option: MiniCheck-Flan-T5-Large (MIT tag, ONNX export available) or HHEM-2.1-Open (110M, about 1.5 s per 2k tokens on CPU). This adds an ONNX runtime and a model of hundreds of MB, which conflicts with small code.
  - Agent-side option, preferred: a leased agent decomposes claims in the FActScore style, verifies them against the items with its own model, and writes the verdict as a metric with `as_of` and actor, using the existing provenance.
  - Per Godbole and Jia, these scores should never gate, because they penalize paraphrase.
- **The letter's value has moved toward verifiable, specific, cited claims and the operator's own edits** (Galdin and Silbert; Cui et al.). Hireme's per-cell provenance and FIRE HOLD human review already point that way. The editing-time result (Cui et al.) suggests measuring and encouraging operator edits of agent drafts rather than minimizing them.

### Gaps
- No peer-reviewed benchmark of fabrication rates in LLM resume tailoring was found. Takano is a single-author preprint on synthetic resumes, and its main models are unnamed on the abstract page.
- ResumeFlow's hallucination metric and values were not on the abstract page.
- No study measures the callback effects of truthful versus fabricated tailored content.
- No human evaluation of LLM-written job cover letters was found. A small randomized study of journal-submission cover letters surfaced but does not apply.
- License verification is incomplete: MiniCheck-Flan-T5-Large rests on a Hugging Face tag only, and HHEM-2.1-Open on a third-party listing.

## 2. How CVs are actually read now: ATS parsing, keyword filtering, LLM-based screening, biases, and LLM-written versus human-written CVs

### Takeaway
CVs now pass through two kinds of machine reader:
- Exact-criteria filters and keyword search: 88% of employers agree they screen out qualified people.
- LLM or semantic screeners, which have been shown to:
  - prefer resumes they generated themselves (67-82% in the abstract's figures);
  - flip 30-41% of pairwise decisions when competence-preserving presentation changes;
  - be susceptible to keyword manipulation, especially the least valid ones;
  - carry name, gender, disability and position biases;
  - be vulnerable to hidden-text prompt injection, which is now present in about 1% of real resumes and is being detected in production.

For tailoring, this means: keep the content truthful and specific, make the extracted text clean (presentation and extraction quality move LLM decisions), treat keyword coverage as a diagnostic of genuine coverage rather than a target, and never use hidden text.

### Cited Findings
- **Hidden Workers: Untapped Talent (Harvard Business School and Accenture, Sep 2021; seminal, older).**
  - 88% of employers agreed that qualified high-skill candidates are vetted out because they don't match the exact criteria in a job description, rising to 94% for middle-skill roles. Filters on gaps in full-time employment can override other qualifications. — [TechRadar](https://www.techradar.com/news/automated-hiring-software-is-rejecting-millions-of-suitable-job-candidates)
  - More than 90% of employers surveyed use such systems to filter or rank candidates. — [Next Avenue](https://www.nextavenue.org/hidden-workers-ai-getting-hired/)
  - The survey covered 8,720 hidden workers and 2,275 executives in the US, UK and Germany. — [HBS Working Knowledge](https://hbswk.hbs.edu/item/how-to-tap-the-talent-automated-hr-platforms-miss), [report PDF](https://accenture.com/content/dam/accenture/final/a-com-migration/r3-3/pdf/pdf-169/accenture-hidden-worker-report.pdf)
- **Domain model versus general LLMs.** Anzenberg, Samajpati, Chandrasekar, Kacholia (arXiv 2507.02087, Jul 2025) tested about 10,000 recent real candidate-job pairs.
  - Their proprietary domain-specific "Match Score" beat general LLMs from OpenAI, Anthropic, Google, Meta and DeepSeek on accuracy, ROC AUC 0.85 against 0.77.
  - It also did better on fairness: a minimum race-wise impact ratio of 0.957 against 0.809 or lower for the best LLMs, and 0.906 against 0.773 for intersectional groups.
  - Caveat: the authors evaluate their own product. — [arXiv 2507.02087](https://arxiv.org/abs/2507.02087)
- **Validity.** Castleman, Shen, Metevier, Springer, Korolova, "Measuring Validity in LLM-based Resume Screening" (arXiv 2602.18550, Feb 2026), built job-tailored resumes with known relative qualification. Many models "cannot consistently select the resume of the more qualified candidate" and do not reliably abstain on equally qualified pairs. They select demographic groups at different rates, sometimes favoring historically marginalized candidates. — [arXiv 2602.18550](https://arxiv.org/abs/2602.18550)
- **Presentation instability.** Chen and Xiao, "Competence-Preserving Resume Perturbations Expose Presentation Sensitivity in LLM Screening" (arXiv 2609.16517, Sep 2026, under review):
  - The perturbations vary wording, structure, stylistic polish and document extraction quality.
  - The most valid model (Llama-3.1-8B, validity 0.781) "reverses 29.6% of matched pairwise decisions". Mistral-7B (validity 0.644) reverses 41.4%.
  - Native chat formatting improves validity but does not remove the instability, and validity and stability are disconnected. — [arXiv 2609.16517](https://arxiv.org/abs/2609.16517)
- **Competence and the "illusion of neutrality".** Webster (arXiv 2507.11548, v3 Jul 2026) audited eight AI platforms. Some "appear demographically unbiased because they lack the ability to meaningfully differentiate among candidates". — [arXiv 2507.11548](https://arxiv.org/abs/2507.11548) Models that did poorly on the resume-role mismatch test "were also among the most susceptible to keyword manipulation", which the author attributes to reliance on surface-level lexical cues (PDF snippet). — [PDF](https://arxiv.org/pdf/2507.11548)
- **Self-preference for LLM-written resumes.** Xu, Li, Jiang, "AI Self-preferencing in Algorithmic Hiring: Empirical Evidence and Insights" (arXiv 2509.00462; non-archival at AIES 2025 and EAAMO 2025; v4 Jun 2026):
  - LLMs prefer resumes they generated over human-written ones: 67-82% across major commercial and open-source models.
  - In simulated pipelines across 24 occupations, candidates using the same LLM as the evaluator were 23-60% more likely to be shortlisted, with the largest gaps in business fields such as sales and accounting.
  - Interventions targeting self-recognition cut the bias by more than 50%. — [arXiv 2509.00462](https://arxiv.org/abs/2509.00462), [UMD Smith news](https://www.rhsmith.umd.edu/news/ai-hiring-tools-may-favor-their-own-work-smith-study-finds)
  - Conflict: one secondary write-up reports 68-92% for a later version, while the abstract page shows 67-82%. — [WebProNews](https://www.webpronews.com/llms-show-strong-self-bias-in-resume-screening-giving-ai-written-applications-a-big-edge-over-human-ones/)
- **Gender and position bias.** Rozado, "Gender and positional biases in LLM-based hiring decisions" (PeerJ Computer Science 2026; arXiv 2505.17049) ran 22 LLMs over 70 professions, 30,800 decisions in total, with name-swapped CV pairs.
  - All models favored female-named candidates: 56.9% against 43.1%, per the author's blog.
  - An explicit gender field increased the preference.
  - Most models showed "a substantial positional bias" toward the candidate listed first. — [PeerJ CS](https://peerj.com/articles/cs-3628), [arXiv 2505.17049](https://arxiv.org/pdf/2505.17049v1), [Rozado's blog](https://davidrozado.substack.com/p/the-strange-behavior-of-llms-in-hiring)
- **Retrieval-based screening bias.** Wilson and Caliskan (AIES 2024) used Massive Text Embedding retrieval over 500+ resumes and 500 job descriptions in nine occupations. White-associated names were favored in 85.1% of cases and female-associated names in only 11.1%. Black males were disadvantaged in up to 100% of cases. — [AIES 2024](https://ojs.aaai.org/index.php/AIES/article/view/31748)
- **Disability bias.** Glazko et al. (FAccT 2024; arXiv 2402.01732; DOI 10.1145/3630106.3658933) found GPT-4 "exhibits prejudice" toward CVs enhanced with disability-related items. A custom GPT instructed with DEI and disability-justice principles reduced it, by an amount the abstract page does not give. — [arXiv 2402.01732](https://arxiv.org/abs/2402.01732)
- **Cultural and racial bias.** "Invisible Filters" (AIES 2025) reports that LLM screening disadvantaged Black and female-associated names on otherwise identical resumes. This is from a search summary; the paper was not read in full. — [AIES 2025 PDF](https://ojs.aaai.org/index.php/AIES/article/download/36703/38841/40778)
- **Adversarial vulnerability (reported here only as a risk).** Mu et al. (arXiv 2512.20164, v2 Apr 2026) introduce a resume-screening benchmark where some attack types exceed 80% success. Defenses help only modestly:

  | Defense | Attack reduction | False rejection increase |
  |---|---|---|
  | Prompt-based | 10.1% | 12.5% |
  | FIDS, training-time (LoRA) | 15.4% | 10.4% |
  | Combined | 26.3% | not stated |

  — [arXiv 2512.20164](https://arxiv.org/abs/2512.20164)
- **Hidden prompt injection in the wild (risk).** Zhang, Jia, Tan, Jiang, Gong, Chen, Song, "Measuring Real-World Prompt Injection Attacks in LLM-based Resume Screening" (USENIX Security 2026; arXiv 2605.28999), studied about 200K real hireEZ resumes.
  - About 1% contain hidden prompt injections, and the share rose over the past one to two years.
  - "More than 90% of injected prompts do not use explicit instructions".
  - The study did not test whether injections changed hiring decisions. — [arXiv 2605.28999](https://arxiv.org/abs/2605.28999)
  - The 196,682 resumes break down as 83,277 from an applicant-matching product over 17 months and 113,405 from enterprise ATSs over 6.5 years. The detectors compare visual document content with machine-extracted text and are integrated into hireEZ production. — [Metaview](https://www.metaview.ai/resources/blog/resume-prompt-injection), [Duke Pratt](https://pratt.duke.edu/news/thwarting-prompt-injection/)
- Practitioner reporting says recruiters regard the white-text tactic as ineffective and grounds for rejection, and that "most ATS systems will remove the formatting from the resume, revealing any text the applicant might have hidden". — [Built In](https://builtin.com/articles/hidden-ai-prompts-in-resume)

### Inferences
- Hireme's exact-token coverage ([keywords.rs](../../native/kernel/src/keywords.rs)) models the first reader, exact criteria and keyword search, which the Hidden Workers data show is real.
- For the second reader, LLM screeners, the controllable levers are truthful, specific content and clean extracted text. Gaming levers (keyword density, the screener's preference for its own style) are unstable and susceptible mainly in low-validity screeners (Chen and Xiao; Webster). They are also ethically dubious.
- Self-preference means LLM-polished writing is not penalized by LLM screeners; if anything it helps with same-family screeners. Hireme should not chase a particular screener's style. The screener is unknown, the effect is halved by simple employer-side mitigations (Xu et al.), and human readers have shifted toward verifiable history (Cui et al.).
- Extraction quality is itself a presentation variable that flips LLM decisions (Chen and Xiao). This motivates the parse-health check, T9 in section 4: show the operator the text machines will see and flag degradation.
- Employer detectors now compare rendered pages with extracted text (Zhang et al.). Even accidental hidden text in the operator's own PDF, such as template boilerplate in white or text in invisible render mode, could look like an injection. Hireme should detect and warn (T9), never offer hidden-text tactics.
- The bias findings sit on the employer side and involve identity signals. Hireme should not advise identity masking or name changes; that is out of scope ethically. Pins and CV choice stay human decisions.

### Gaps
- No reliable independent figure was found for the share of employers using LLM-based screening in 2025-2026; only vendor surveys turned up, and they are not cited.
- No peer-reviewed measurement of commercial ATS parser accuracy on multi-column or design-template CVs was found.
- Chen and Xiao's per-perturbation effects (which formatting changes flip most) were not on the abstract page.
- Whether hidden injections change outcomes is unmeasured (Zhang et al.).
- The numbers for the NAACL Industry 2025 paper "Evaluating Bias in LLMs for Job-Resume Matching" (Iso et al.) were not retrieved, and its venue is reported inconsistently: FAccT '25 in one reference list, NAACL Industry in the ACL Anthology.

## 3. Choosing which CV items to include under a page or length budget: optimization formulations and evidence

### Takeaway
Choosing CV items under a length budget is formally the same problem as extractive summarization. Budgeted maximum coverage has a (1−1/e) approximation, which is the best possible. The concept-coverage ILP (Gillick and Favre) and monotone submodular selection (Lin and Bilmes) are the seminal and still-standard formulations. Industry tools use relevance thresholds and line budgets instead. No study was found that evaluates optimization-based CV selection against callbacks.

For hireme, the corpus is small: tens of items and roughly 50-120 lines. Exact, deterministic selection fits the kernel and can run in the browser. The most valuable output is gap triage: which listing requirements an excluded item covers, against which no record covers at all and must never be fabricated.

### Cited Findings
- **Concept-coverage ILP (seminal).** Gillick and Favre, "A Scalable Global Model for Summarization" (Workshop on Integer Linear Programming for NLP, Boulder, June 2009, pp. 10-18; Anthology W09-1802). The paper's formulation selects sentences to maximize the total weight of covered concepts under a length budget, solved exactly. The Anthology landing page has no abstract, so the formulation is summarized from the paper itself and was not re-read here. — [ACL Anthology W09-1802](https://aclanthology.org/W09-1802/)
- **Submodular selection (seminal).** Lin and Bilmes, "A Class of Submodular Functions for Document Summarization" (ACL-HLT 2011, pp. 510-520; P11-1052) use monotone submodular coverage-plus-diversity objectives under a budget, optimized greedily with approximation guarantees, and evaluated on DUC. The landing page shows no abstract, and this summary was not re-verified here. — [ACL Anthology P11-1052](https://aclanthology.org/P11-1052/)
- **Budgeted maximum coverage.** Khuller, Moss and Naor (Information Processing Letters 70(1):39-45, 1999) give a (1−1/e) approximation, described as best possible, using greedy selection with enumeration. — [UMIACS](https://sites.umiacs.umd.edu/node/15228)
  - The practical cost-benefit greedy picks the most weight gained per unit cost within the budget and returns the better of that set and the single best item. — [arXiv 2202.03093](https://arxiv.org/pdf/2202.03093)
  - Sviridenko's refinement guesses the 3 most profitable elements, and later work shows 2 suffice. — [Dagstuhl MFCS 2016](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.MFCS.2016.50)
- **Industry practice is thresholds and line budgets, not optimization.**
  - US 8,930,398 B1 scores profile elements against a job description and sets a relevancy threshold tuned by parameters such as the desired number of pages. — [Google Patents US8930398](https://patents.google.com/patent/US8930398)
  - The US 10,970,480 / 11,461,543 / 12,093,641 family manages per-section line budgets under spacing restrictions. — [USPTO 10970480](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10970480)
  - A commercial tool makes "a focused 1-2 page resume" in which less relevant base-resume content may not appear; the algorithm is undisclosed. — [Swooped help](https://help.swooped.co/en/articles/10423530-how-our-ai-selects-content-from-your-base-resume-for-job-optimized-resumes)
- A US federal two-page resume limit requires the resume to address the minimum qualifications in the job announcement (USDA Forest Service page, search snippet). — [fs.usda.gov](https://www.fs.usda.gov/media/260143)
- **Quality of the extracted requirements (the "concepts").** Nguyen, Zhang, Montariol, Bosselut, "Rethinking Skill Extraction in the Job Market Domain using Large Language Models" (NLP4HR @ EACL 2024; arXiv 2402.03832). — [arXiv 2402.03832](https://arxiv.org/abs/2402.03832), [results HTML](https://arxiv.org/html/2402.03832v1)
  - In-context LLMs trail supervised models on strict span F1: GPT-4 averages 36.8-37.7 (on ≤350 samples per dataset) against 64.4 for supervised ESCOXLM-R.
  - Relaxed F1 is much higher, up to 58.0 average for GPT-3.5 5-shot with kNN, so LLMs locate skills but miss span boundaries.
  - Errors: skill-definition misalignment (about 36%), non-skill spans (about 20%), conjoined skills (about 14%), extended spans (about 12%).
- **ESCO v1.2 (May 2024).** It added 677 alternative labels and 96 hidden terms, alongside 35 occupations, 42 skills and 196 knowledge concepts. It covers 28 languages and is downloadable as CSV, JSON-LD, ODS, RDF, TTL or XML. v1.2.1 (Dec 2025) brought quality fixes only, with no content added or removed. — [ESCO v1.2 launch](https://esco.ec.europa.eu/system/files/2024-05/V1.2%20Launch%20-%20ESCO%20SEC%20combined%20-%20final%20clean.pdf), [ESCO portal](https://esco.ec.europa.eu/et/node/563)

### Inferences
- **The formulation for hireme, computed in the kernel.** Variables: x_i ∈ {0,1} for each profile or shared item.
  - Cost c_i: the item's rendered lines at the application's `cv_theme` density (`DENSITIES = ["cv","tight","narrative"]` in [cv.rs](../../native/kernel/src/cv.rs)). Budget B: the lines for the target page count.
  - Concepts k: the listing's targets. Today these are `applications.keywords` (TOP = 12). Better are the agent-extracted requirements, verified by quote under T6 in section 5, split into required and preferred. Weight w_k: for example, required 3 and preferred 1, adjusted by frequency.
  - Coverage a_ik = 1 when item i covers k, exactly or through an alias (T5).
  - Objective: maximize Σ_k w_k · min(1, Σ_i a_ik x_i) + λ Σ_i r_i x_i, where r_i is recency or importance.
  - Constraints: Σ c_i x_i ≤ B; x_i = 1 for must-include items (current role, education); section quotas; and lineage consistency. An item already shown to the same corporation's lineage stays in, or its removal is flagged, so that "every application to one company tells the same story".
  - With n in the tens and B around 120, an exact dynamic program or branch-and-bound runs in milliseconds in WASM or the NIF. Ties break deterministically by position, then id, as [pick.rs](../../native/kernel/src/pick.rs) already does.
- **T4. Budgeted coverage selection as a derived suggestion.** Impact 4, feasibility 5, novelty 4.
  - [compose.rs](../../native/kernel/src/compose.rs) adds `suggest` to the application document: drops and adds to apply as overlays through the MCP `put`, plus gap triage.
  - Gap triage gives `coverable`, the targets an excluded item covers (include it), and `uncovered`, the targets no record covers (a genuine gap: never fabricate; address it honestly in the letter or leave it).
  - The browser and the MCP `cv` tool render the same document.
  - It replaces hand-curated `drop` overlays as the default path.
  - Risk: over-weighting keyword targets breeds stuffing pressure, so the objective counts each concept once (saturated coverage) and never rewards repetition.
- **T5. Alias-aware coverage beside exact coverage.** Impact 3, feasibility 4, novelty 3.
  - Compile alias groups (an operator-curated table, optionally seeded from ESCO alternative labels for the operator's domains) into the existing [lexicon.rs](../../native/kernel/src/lexicon.rs) trie.
  - Report two numbers: exact coverage (what keyword search and ATS filters see) and alias coverage (what semantic screeners and humans see).
  - Any rule change bumps `keywords::VERSION` and triggers the server's existing re-extraction backfill. It replaces the single exact-only coverage figure.
  - Risk: aliases can overstate coverage against exact Boolean search, hence both numbers are shown.
- Indirect evidence that targeting genuine requirements matters: exact-criteria filters exist (Hidden Workers), and customization had a large employer premium before LLMs (Galdin and Silbert, section 1). Its decline argues for coverage through real records, not more words.

### Gaps
- No empirical evidence was found that optimization-based CV item selection improves callbacks or recruiter ratings, and no CV-specific benchmark exists.
- No non-vendor evidence was found on one-page against two-page CVs.
- ESCO's license or terms of reuse were not verified.
- No sources covered weighting requirements by position or by "must/nice-to-have" phrasing in job ads.

## 4. Document understanding: extracting text and structure from PDF and DOCX CVs and from job listings

### Takeaway
The open-source state of the art is small vision-language parsers: PaddleOCR-VL at 0.9B (Apache-2.0) scores 96.34 on OmniDocBench v1.6, MinerU2.5-Pro at 1.2B scores 95.75, and GLM-OCR at 0.9B scores 95.22. All are well ahead of classic pipelines (Marker 78.44, MinerU pipeline 86.47), but they need GPUs or large RAM for throughput and Python stacks, and some carry licence conditions. Docling (MIT) and Kreuzberg are the permissive CPU-class toolkits, and Kreuzberg ships an Elixir NIF.

The operator's CVs are few and born-digital, so hireme's text-layer readers are the right default. The highest-value additions are deterministic: parse-health metrics and a hidden-text check in [blobs.ex](../../lib/hireme/blobs.ex). Heavy parsing, when needed, belongs to the leased agents, which can read PDFs visually and write the corrected text through hireme's existing "text corrected beside the file" flow.

### Cited Findings
- **OmniDocBench (CVPR 2025), end-to-end leaderboard v1.6_full (Overall, higher is better).** The benchmark README describes "1651 PDF pages, covering 10 document types", with resumes not listed among them, and announces a move to v1.7 on 2026-04-30. — [OmniDocBench GitHub](https://github.com/opendatalab/OmniDocBench)

  | Model | Params | Overall |
  |---|---|---|
  | PaddleOCR-VL-1.6 | 0.9B | 96.34 |
  | MinerU2.5-Pro | 1.2B | 95.75 |
  | GLM-OCR | 0.9B | 95.22 |
  | PaddleOCR-VL-1.5 | 0.9B | 94.93 |
  | PaddleOCR-VL | 0.9B | 94.18 |
  | Qianfan-OCR | 4B | 93.90 |
  | MinerU-2.5 | 1.2B | 93.04 |
  | Gemini 3 Pro | – | 92.91 |
  | dots.ocr | 3B | 90.77 |
  | DeepSeek-OCR 2 | 3B | 90.25 |
  | Qwen3-VL-235B | 235B | 89.78 |
  | Dolphin-v2 | 3B | 89.50 |
  | MonkeyOCR-pro-3B | 3B | 88.57 |
  | GPT-5.2 | – | 86.59 |
  | MinerU pipeline | – | 86.47 |
  | olmOCR | 7B | 85.74 |
  | Nanonets-OCR-s | 3B | 83.61 |
  | Marker | – | 78.44 |
  | Docling | – | indexed, no score |

- **marker (Datalab).** — [marker GitHub](https://github.com/datalab-to/marker)
  - License: code Apache-2.0. Weights under a modified AI Pubs Open RAIL-M license, "free for research, personal use, and startups under $5M funding/revenue".
  - Vendor-run olmOCR-bench scores:

    | Tool or mode | Score |
    |---|---|
    | marker balanced | 76.0% (83.5% on born-digital PDFs) |
    | marker fast | 66.6% |
    | marker fast, no OCR | 43.6% |
    | MinerU pipeline | 72.7% |
    | docling | 50.3% |
    | hosted Chandra 2 | 85.8% |

  - Throughput on one B200 host: 23.7 pages/s for fast with no OCR (CPU), 7.4 pages/s for fast (GPU), 2.9 pages/s for balanced (GPU).
  - Inputs: PDF, image, PPTX, DOCX, XLSX, HTML and EPUB.
- **MinerU (OpenDataLab).** — [MinerU GitHub](https://github.com/opendatalab/MinerU), [arXiv 2509.22186](https://arxiv.org/abs/2509.22186)
  - License: "MinerU Open Source License", based on Apache 2.0 with additional conditions that the README does not spell out.
  - Engine tiers:
    - `basic` with ONNX: about 0.8 GB of models and 2 GB RAM; runs on CPU.
    - `standard` / `advanced` with ONNX plus llama.cpp: about 2 GB, 8 GB RAM; CPU works.
    - GPU tiers: 8 GB+ of VRAM.
  - Inputs: PDF, images, DOC/DOCX, PPT/PPTX, XLS/XLSX, RTF, OpenDocument, EPUB and HTML; the current line is MinerU 4.0.
  - MinerU2.5 is a decoupled 1.2B vision-language model for high-resolution parsing.
- **Docling (IBM; AAAI 2025 workshop; arXiv 2501.17887; technical report arXiv 2408.09869).** MIT-licensed. Layout analysis uses DocLayNet and table structure uses TableFormer, and it "runs efficiently on commodity hardware". The abstract pages give no speed numbers. — [arXiv 2501.17887](https://arxiv.org/abs/2501.17887), [arXiv 2408.09869](https://arxiv.org/abs/2408.09869)
- **PaddleOCR-VL (0.9B).** The model card metadata says Apache-2.0, and the official script falls back to CPU. — [HF model card](https://huggingface.co/PaddlePaddle/PaddleOCR-VL/blob/refs%2Fpr%2F79/README.md) A third-party CPU port recommends 16 GB+ RAM. — [paddleocr-vl-cpu](https://github.com/Think-Core/paddleocr-vl-cpu)
- **olmOCR 2.** Poznanski, Soldaini, Lo (AI2; arXiv 2510.19817, Oct 2025) train a 7B vision-language model with RL from verifiable rewards (GRPO). The rewards are binary unit tests generated from synthetic documents with known ground-truth HTML, and the largest gains are in formulas, tables and multi-column layouts. The release is described as "permissive open licenses"; the exact license was not verified. — [arXiv 2510.19817](https://arxiv.org/abs/2510.19817)
- **Kreuzberg (Rust core) on Hex, version 4.10.x.**
  - Requires Elixir 1.12+ and OTP 24+; ONNX Runtime and Tesseract are optional; claims 91+ formats. — [Hex readme 4.10.3](https://readme.hex.pm/kreuzberg/4.10.3)
  - The binding uses "Rustler NIF integration, OTP supervision". — [Hex preview 4.0.0-rc.27](https://preview.hex.pm/preview/kreuzberg/4.0.0-rc.27)
  - The v4 line is LTS with critical fixes until the end of 2026. Development moved to Xberg 1.0, "the direct successor to Kreuzberg v4.9", under the MIT license. — [newreleases: xberg v1.0.0](https://newreleases.io/project/github/xberg-io/xberg/release/v1.0.0)
- **Resume-specific parsing.** Zhu et al. (Alibaba, Zhejiang Lab, Ant Group and others; arXiv 2510.09722, Oct 2025) combine a fine-tuned layout parser that normalizes diverse formats with an inference-efficient LLM extractor using parallel prompting. A fine-tuned 0.6B model "achieves top-tier accuracy while significantly reducing inference latency", and the system is deployed in Alibaba's HR platform. The abstract gives no numbers and says nothing about a release. — [arXiv 2510.09722](https://arxiv.org/abs/2510.09722)
- On layout-rich documents generally, optimally configured general-purpose LLMs with data cleaning gained 20% F1 over baseline and outperformed specialized fine-tuned models (arXiv 2502.18179; search snippet). — [arXiv 2502.18179](https://arxiv.org/abs/2502.18179v1)
- Production detectors for hidden injections compare visual document content with machine-extracted text. — [Duke Pratt](https://pratt.duke.edu/news/thwarting-prompt-injection/), [Metaview](https://www.metaview.ai/resources/blog/resume-prompt-injection)
- **Hireme's current PDF path** ([blobs.ex](../../lib/hireme/blobs.ex), local):
  - It inflates every FlateDecode stream and merges the ToUnicode maps of every font into one map; a font without one reads as Latin-1.
  - It reads the strings shown by `Tj`, `'`, `"` and `TJ` (a `TJ` gap below −250 becomes a space).
  - It breaks lines on a vertical `Td`/`TD`, on a `Tm` y-change above 1, and on `T*`.
  - It takes streams in byte order and keeps no x-order, column, render-mode, colour or font-size state, and it has no OCR.

### Inferences
- Fit with a single-server Elixir and Rust deployment:
  - Permissive and CPU-capable: Docling (MIT, Python), Kreuzberg / Xberg (MIT; an Elixir NIF exists), and MinerU's `basic` ONNX tier (custom conditions to review).
  - Accurate but GPU-hungry, from 0.9B to 7B: PaddleOCR-VL, GLM-OCR, MinerU2.5 and olmOCR 2.
  - Hireme parses a handful of the operator's own born-digital CVs at upload, so none of these belongs in the critical path.
- Specific failure risks in the current PDF reader:
  - Multi-column or design-tool templates whose stream order interleaves the columns.
  - Code collisions between fonts' ToUnicode maps after the merge.
  - Fonts without ToUnicode decoding to Latin-1 junk.
  - Invisible text being read: render mode 3, white fill, tiny `Tf`, or text off the page.
  - Scanned PDFs yielding empty text.
- **T9. Parse health and hidden-text hygiene at the one-time read.** Impact 4, feasibility 4, novelty 4.
  - Extend [blobs.ex](../../lib/hireme/blobs.ex) to compute, at upload:
    - the share of glyphs decoded through the Latin-1 fallback and the count of replacement or private-use characters;
    - the share of non-word tokens and average word length;
    - an x-jump interleave heuristic, by also tracking the `Tm`/`Td` x value;
    - invisible text: `Tr 3`, white `rg`/`g`/`k` fill, `Tf` size below 1, positions outside the MediaBox;
    - for DOCX, `w:vanish`, white `w:color` and tiny `w:sz` runs;
    - and the difference between keyword coverage of the file's text and of an operator-corrected body.
  - Store the result on `cv_versions`, show it on the CV strip, and return it from the MCP `cv` tool.
  - This gives the operator "what the ATS and LLM screener see" (Chen and Xiao: extraction quality flips decisions) and a pre-submission warning against hidden text, which employer detectors now flag (Zhang et al.).
  - Cost: about 80-150 lines of Elixir in the existing reader.
- **T10. Heavy-parse fallback.** Impact 2, feasibility 3, novelty 2.
  - Route (a), preferred, agent-side: when parse health is poor, the MCP exposes the blob, and a leased agent able to read PDFs visually proposes the corrected text as `cv_versions.body` beside the same `blob_sha`, the existing flow from commit 552e80c. This adds no server code.
  - Route (b), optional: a Kreuzberg / Xberg Rustler NIF (MIT) for broader formats and OCR. It adds a large native dependency, so take it only if (a) proves insufficient.
  - Avoid MinerU (extra license conditions, Python), marker (revenue-capped weights license), and 3-7B vision models (GPU) on the shared box.
- **Listings.** `listing_raw` is HTML or text and is already stripped of tags, comments, style and script for keyword extraction ([keywords.rs](../../native/kernel/src/keywords.rs)). Document AI adds little here; the risk is hidden-text injection aimed at the agents (T14 in section 5).

### Gaps
- No benchmark on CV and resume PDFs across open parsers was found; OmniDocBench has no resume category.
- Docling's OmniDocBench score and CPU seconds per page were not found in the sources read.
- The exact olmOCR 2 license and the Elixir binding status of the Xberg successor were not verified.
- Kreuzberg's PDF text quality has not been compared independently with pdfium or pdf.js in the sources found.

## 5. Structured extraction of listing fields with schema- or grammar-constrained decoding plus provenance, and how to evaluate it

### Takeaway
Constrained decoding is mature. In JSONSchemaBench, llguidance (Guidance) leads open engines on coverage and speed, vendor strict modes reach near-100% compliance on the schemas they accept, and constraints raised task accuracy by about 3 points. Strict JSON can hurt reasoning-heavy tasks, though, so reason or extract first and format last. Hireme does not decode tokens itself. Its leverage is the schema it publishes to agents and verification on write:
- Every field the agents extract carries a verbatim quote from `listing_raw`, which the kernel checks as an exact (normalized) substring and stores as an offset span. This is the model-agnostic version of LangExtract's character grounding and Claude Citations' `char_location`.
- Enums carry an explicit `unspecified` value.
- Deterministic extractors already in the kernel (pay, remote words) cross-check the agents.

### Cited Findings
- **JSONSchemaBench.** Geng, Cooper, Moskal, Jenkins, Berman, Ranchin, West, Horvitz, Nori (arXiv 2501.10868, v3 Feb 2025) cover 10K real-world JSON schemas across six frameworks. Open engines used Llama-3.2-1B and are not directly comparable to OpenAI and Gemini. — [arXiv 2501.10868 (HTML v3)](https://arxiv.org/html/2501.10868v3)
  - Guidance (llguidance) has the highest empirical coverage on 6 of 8 datasets. GitHub-Hard coverage and compliance:

    | Framework | Coverage | Compliance |
    |---|---|---|
    | Guidance | 0.41 | 0.69 |
    | Llamacpp | 0.39 | 0.63 |
    | XGrammar | 0.28 | 0.41 |
    | Outlines | 0.03 | 0.06 |
    | OpenAI | 0.09 | 1.00 |

  - Grammar compilation takes 0.00-0.01 s for Guidance against 3.48-8.05 s for Outlines. Time per output token is 6.37 ms for Guidance against 15.40 ms for the unconstrained model on llama.cpp.
  - Downstream accuracy for Llama-3.1-8B-Instruct:

    | Task | Unconstrained | Guidance | XGrammar |
    |---|---|---|---|
    | GSM8K | 80.1% | 83.8% | 83.7% |
    | Last Letters | 50.7% | 54.0% | 51.2% |
    | Shuffle Objects | 52.6% | 55.9% | 52.7% |

- **XGrammar (MLSys 2025; arXiv 2411.15100)** offers "up to 100x speedup over existing solutions" and "near-zero overhead" structured generation in end-to-end serving. — [arXiv 2411.15100](https://arxiv.org/abs/2411.15100)
- **"Let Me Speak Freely?"** Tam et al. (EMNLP 2024 Industry; arXiv 2408.02442) find that JSON-mode constraints "can hinder reasoning abilities while enhancing classification task accuracy". Looser formats and a natural-language-then-convert approach do better on reasoning. This conflicts in part with JSONSchemaBench's accuracy gains; the setups differ. — [arXiv 2408.02442](https://arxiv.org/pdf/2408.02442)
- **Claude structured outputs.** These come as `output_config.format` for JSON outputs and `strict: true` for tool parameters, with `additionalProperties: false` required on every object. — [Structured outputs docs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
  - Supported: basic types, `enum`, `const`, `anyOf`, `allOf`, `$ref`/`$def`, and string formats (date, date-time, email, uri, uuid and others).
  - Not supported: recursive schemas, `minimum`/`maximum`/`multipleOf`, `minLength`/`maxLength`, and complex array constraints.
  - A new schema pays a one-time compilation cost and is then cached for 24 hours.
  - Structured outputs cannot be combined with Citations (400).
- **LangExtract (Google; Apache-2.0; v1.6.0).** Every extraction is "grounded back to its exact character span in the source", and extractions that cannot be located get `char_interval = None`. The schema is enforced from few-shot examples, with controlled generation on supported models. It handles long documents with chunking, parallel processing and multiple passes, and runs on Gemini, OpenAI or local Ollama models. — [LangExtract GitHub](https://github.com/google/langextract)
- **GLiNER2.** Zaratiana, Pasternak, Boyd, Hurn-Maloney, Lewis (arXiv 2507.18546, Jul 2025) combine named entity recognition, text classification and hierarchical structured extraction in one compact encoder model with a schema-driven interface. They claim it "maintains CPU efficiency"; the abstract gives no numbers, and the repository license was not verified. — [arXiv 2507.18546](https://arxiv.org/abs/2507.18546)
- **Remote-work classification at scale.** Hansen, Lambert, Bloom, Davis, Sadun, Taska, "Remote Work across Jobs, Companies, and Space" (NBER w31007, updated abstract). A language model fine-tuned on 30,000 human classifications "achieves 99% classification accuracy", substantially outperforms dictionary-based approaches and "performs on par with frontier AI models". It was applied to more than 500 million postings in five English-speaking countries, where postings with remote days rose more than threefold in the US and at least fivefold in the others from 2019 to 2025. — [NBER w31007](https://www.nber.org/papers/w31007)
- **Fine-tuned DistilBERT on Gemini labels.** Thakrar and Young (arXiv 2501.07663, Jan 2025) worked with about 1.2M postings.

  | Field | F1 | MCC |
  |---|---|---|
  | Remote type | 0.78 | 0.60 |
  | Remuneration | 0.68 | 0.63 |
  | Experience | 0.59 | 0.53 |
  | Education | 0.66 | 0.59 |

  Inference took 1.1 s per posting. Regex and NLTK keyword parsing "overfit" with many false positives and negatives (qualitative). The labels were themselves LLM-generated and spot-checked on 50 samples. — [arXiv 2501.07663](https://arxiv.org/html/2501.07663v1)
- Skill-span extraction by in-context LLMs trails supervised models on strict F1, and boundary and definition mismatches dominate the errors (Nguyen et al. 2024, numbers in section 3). — [arXiv 2402.03832](https://arxiv.org/html/2402.03832v1)
- In Takano's hiring pipeline, requirements embedded in the job description leaked into outputs as claims (47% capture at baseline), the extraction-to-generation leakage that provenance checks target. — [arXiv 2608.26171](https://arxiv.org/abs/2608.26171)
- **Hireme today (local).**
  - Agents fill listing fields (`company, role, location, work_mode, employment, comp_raw`) with citations whose rows hold `source_id, value, as_of, actor` but no span ([schema.json](../../priv/schema.json)).
  - The server "never casts strings" and enums are named values ([diag.rs](../../native/mcp/src/diag.rs)).
  - Pay is parsed deterministically with currency and suffix handling ([score.rs](../../native/kernel/src/score.rs)).
  - Lexicon phrases are matched by trie ([lexicon.rs](../../native/kernel/src/lexicon.rs)).

### Inferences
- **T6. Quote-verified provenance spans.** Impact 5, feasibility 5, novelty 4.
  - Extend `citations` with a `quote` (and server-derived `[start,end)` offsets into `listing_raw` or `sources.doc`).
  - On write, the kernel checks that the normalized quote ([text.rs](../../native/kernel/src/text.rs) normalization) occurs in the source. If not, it refuses with a provenance-class diagnostic in [diag.rs](../../native/mcp/src/diag.rs).
  - [compose.rs](../../native/kernel/src/compose.rs) emits spans so the browser highlights the evidence, and the MCP `get` returns them.
  - It works with any leased model. Agents may use LangExtract or Claude Citations (`char_location`) to find spans, but the kernel never trusts their offsets, only the quote.
  - It replaces an unverifiable free-text `value` with a checkable one.
  - Risks: whitespace and entity normalization edge cases (reuse the [keywords.rs](../../native/kernel/src/keywords.rs) markup stripping), and fields with no verbatim basis, such as "remote inferred from 'work from anywhere'", which need a short quote plus an `inferred` flag.
- **T7. A strict-mode-friendly schema surface for agent writes.** Impact 3, feasibility 5, novelty 2.
  - Publish the MCP tool input schemas ([tools.rs](../../native/mcp/src/tools.rs), generated from [native/schema](../../native/schema)) within the common-denominator subset that vendor strict modes accept: no recursion, no numeric or length bounds, `additionalProperties: false`, required fields. That lets agents' clients turn on strict tool use.
  - Give enums for work mode, employment, visa sponsorship, seniority and pay period an explicit `unspecified` value, so a missing fact is said rather than guessed.
  - Advise agents to reason or extract first and format last (Tam et al.).
  - Constrained-decoding engines (XGrammar, llguidance) are relevant only if hireme ever self-hosts a model.
- **T8. Deterministic and agent extraction with an agreement check.** Impact 3, feasibility 4, novelty 3.
  - The kernel computes its own values for the fields it can read deterministically: pay from `comp_raw` and `listing_raw` via [score.rs](../../native/kernel/src/score.rs), and remote, hybrid, onsite and visa phrases via [lexicon.rs](../../native/kernel/src/lexicon.rs).
  - When the agent's value disagrees, the document shows a flag.
  - This follows the remote-work evidence: fine-tuned or frontier models beat dictionaries, but dictionaries make a cheap independent check.
- **T14. Sanitize hidden text in listings before agents read them.** Impact 3, feasibility 4, novelty 3.
  - Extend the existing markup stripper to drop CSS-hidden content (`display:none`, `visibility:hidden`, `font-size:0`, `aria-hidden`, inline white-on-white) before keyword extraction and before the MCP `text` export.
  - Record "hidden: N chars removed" so agents and the operator know.
  - This is the listing-side mirror of the resume injections documented by Zhang et al. and Mu et al. (an inference: no study of injection in job listings was found).
- **Evaluation plan.** Build a gold set of 50-100 of the operator's own listings, stratified by ATS vendor ([ats.rs](../../native/kernel/src/ats.rs) already identifies vendors). Measure:
  - exact match on enum fields;
  - numeric tolerance on pay (min, max, currency, period);
  - quote-validity rate, the share of quotes found verbatim (LangExtract's grounded fraction is the analogue);
  - abstention accuracy, whether `unspecified` is used exactly when the listing is silent;
  - cross-agent agreement, Cohen's kappa between two leased models.

  Re-run it whenever an agent's model or prompt changes. The MCP is uniform across agents, so one harness serves all.

### Gaps
- No benchmark was found for extracting visa sponsorship, remote policy restrictions (for example "remote, EU only"), or seniority from job ads with LLMs, beyond the WHAM-style remote classifier and Thakrar and Young.
- JSONSchemaBench's open-engine numbers use a 1B model, and vendor compliance of 1.00 says nothing about whether the values are correct.
- The GLiNER2 repository license and model size were not verified.

## 6. Evaluating generated documents: LLM-as-judge with rubrics, pairwise comparison, judge reliability, and personalization to the operator's voice

### Takeaway
LLM judges are useful but fragile:
- Pairwise preferences flip under distractors far more than absolute scores do (35% against 9%).
- Judges favor their own generations.
- Strong judges are near chance on hard pairs.
- Checklists raise agreement between evaluator models by 0.45 on average.
- A panel of diverse smaller models beats a single large judge at about a seventh of the cost.

For hireme this means agent-run, absolute, checklist rubrics tied to the listing's verified requirements, scored by more than one model family and never by the model that drafted. Results are stored as metrics with provenance. The ultimate check is outcome tracking.

On voice, LLMs imitate structured, email-like styles from a few samples better than informal ones. AI suggestions homogenize style, so the operator's own approved letters should anchor generation, and the operator's edits should be a tracked signal.

### Cited Findings
- **Pairwise against pointwise.** Tripathi, Wadhwa, Durrett, Niekum (COLM 2025; arXiv 2504.14716): "Pairwise preferences flip in about 35% of the cases, compared to only 9% for absolute scores", and "absolute scoring is more robust" to distractor features. — [arXiv 2504.14716](https://arxiv.org/abs/2504.14716)
- **Juries.** Verga et al., "Replacing Judges with Juries" (PoLL; arXiv 2404.18796, 2024): a panel of smaller models from disjoint families "outperforms a single large judge", "exhibits less intra-model bias", and is "over seven times less expensive", across three judge settings and six datasets. — [arXiv 2404.18796](https://arxiv.org/abs/2404.18796)
- **Self-preference in judges.** Panickssery, Bowman, Feng (arXiv 2404.13076, 2024) find that LLMs distinguish their own outputs from others' with "non-trivial accuracy", and that there is "a linear correlation between self-recognition capability and the strength of self-preference bias". — [arXiv 2404.13076](https://arxiv.org/abs/2404.13076) In hiring specifically, LLM screeners prefer their own resumes 67-82% of the time. — [arXiv 2509.00462](https://arxiv.org/abs/2509.00462)
- **JudgeBench.** Tan et al. (ICLR 2025; arXiv 2410.12784) find strong models such as GPT-4o "performing just slightly better than random guessing" on challenging response pairs. — [arXiv 2410.12784](https://arxiv.org/abs/2410.12784)
- **CheckEval.** Lee et al. (EMNLP 2025; arXiv 2403.18771) use checklists that "dramatically improve the average agreement across evaluator models by 0.45" over 12 evaluator models, reduce score variance, and correlate strongly with human judgments. — [arXiv 2403.18771](https://arxiv.org/abs/2403.18771)
- **Prometheus 2.** Kim et al. (EMNLP 2024; arXiv 2405.01535) present an open evaluator with the highest correlation and agreement with humans and proprietary judges among open evaluators, across four direct-assessment and four pairwise benchmarks. — [arXiv 2405.01535](https://arxiv.org/abs/2405.01535)
- **A validated rubric for tailoring.** Galdin and Silbert scored proposals with Llama 4 Maverick on nine ternary (0-2) questions: five "custom" criteria for tailoring to the job post and four "generic" ones (skills, experience, clarity, tone). Custom criteria are weighted twice and scaled to 0-18. Custom scores are zeroed when a proposal is within 4% normalized edit distance of the worker's other proposals, the copy-paste rule. On a subset, the LLM's scores were "no more different from a given human reader's score" than two humans differ from each other. — [arXiv 2511.08785 (HTML)](https://arxiv.org/html/2511.08785)
- Automated factuality metrics are inconsistent and biased against paraphrase, so validate them manually. — [arXiv 2501.14883](https://arxiv.org/abs/2501.14883)
- **Imitating a person's style.** Wang, Tripto, Park, Li, Zhou, "Catch Me If You Can? Not Yet" (Findings of EMNLP 2025; arXiv 2509.14543), ran over 40,000 generations per model across more than 400 real authors, measured by authorship attribution and verification, style matching and AI detection. LLMs "can approximate user styles in news and email" but struggle with informal blog and forum writing. — [arXiv 2509.14543](https://arxiv.org/pdf/2509.14543)
- **TinyStyler.** Horvitz, Patel, Singh, Callison-Burch, McKeown, Yu (Findings of EMNLP 2024; arXiv 2406.15586) use an 800M model with authorship embeddings for few-shot style transfer and outperform GPT-4 on authorship style transfer. The weights are on Hugging Face. — [arXiv 2406.15586](https://arxiv.org/pdf/2406.15586), [ACL Anthology](https://preview.aclanthology.org/watermark/2024.findings-emnlp.781)
- **Homogenization.** Agarwal, Naaman, Vashistha (CHI 2025; arXiv 2409.11360) studied 118 participants in India and the US: AI suggestions moved Indian participants toward Western writing styles and gave Americans greater efficiency gains. — [arXiv 2409.11360](https://arxiv.org/abs/2409.11360)
- Time spent editing AI drafts correlated positively with hiring success. — [arXiv 2509.25054](https://arxiv.org/abs/2509.25054)

### Inferences
- **T11. Checklist rubric judging by a cross-family jury, run by agents.** Impact 3, feasibility 4, novelty 3.
  - For each application, derive a binary checklist from the verified requirements (T6), with items such as:
    - each required item addressed with a cited record;
    - no unsupported claim (from T1 and T2);
    - one specific, verifiable achievement per paragraph;
    - length within budget;
    - no copy-paste across companies (Galdin and Silbert's edit-distance rule, computable in the kernel from `letter_raw` across applications).
  - Agents from two or more vendors score each item absolutely, never pairwise as the gate. The drafting agent's model never judges alone.
  - Store results as metrics with `as_of` and actor via `citations`; show agreement and disagreement to the operator.
  - Deterministic items (copy-paste distance, length, citation coverage) should live in the kernel; only the judgment items go to agents.
- **T12. Voice anchoring and edits as a signal.** Impact 3, feasibility 4, novelty 3.
  - Agents fetch the operator's own approved letters, the `letter_raw` of submitted applications, and their notes through MCP `find` and `text`, and use them as few-shot exemplars. Cover letters are email-like, the register where Wang et al. found imitation works.
  - The kernel records the edit distance from an agent's draft to the final letter as a metric, signalling how much a draft needed the operator's voice and making operator editing visible.
  - TinyStyler-class models and authorship embeddings are optional server-side add-ons, not a first step.
  - Homogenization risk (Agarwal et al.) argues for operator-written exemplars over generic "professional" prompts.
- **T13. Outcome-tracked variant reporting.** Impact 3, feasibility 4, novelty 2.
  - The desk overview in [compose.rs](../../native/kernel/src/compose.rs) shows reply rates from `replied_on` and `outcome` by CV root and rule arm ([pick.rs](../../native/kernel/src/pick.rs)), with or without a letter, and by checklist score band.
  - Each rate carries its n and an interval with an explicit small-sample warning.
  - It is descriptive only, with no automatic optimization (FIRE HOLD, one operator).
  - Given the signal erosion (Galdin and Silbert; Cui et al.), outcomes are the only ground truth for whether tailoring helps this operator.

### Gaps
- No validated rubric for the effectiveness of job cover letters was found, beyond Galdin and Silbert's customization measure.
- PoLL's correlation figures and JudgeBench's exact accuracies were not on the abstract pages.
- No study of voice personalization specific to cover letters was found. A UMAP 2026 cover-letter personalization system (DUPLet) turned up only with LLM-judge evaluation and no source URL, so it is not cited.

## 7. Technique scorecard (impact, feasibility, novelty, integration) and anti-candidates hireme should not adopt

### Takeaway
The best returns come from deterministic, kernel-side verification and selection that reuse what hireme already has: its tokenizer, lexicon trie, provenance rows, diagnostics and composed documents. In order:
1. Quote-verified provenance spans for listing fields (T6).
2. A claim-support gate on CV overlays (T1) and letters (T2).
3. Parse health and hidden-text hygiene (T9).
4. Budgeted coverage selection with gap triage (T4).

All are small, model-free, identical in WASM and the NIF, and exposed through the MCP. Model-based checks (entailment, judging, style) belong to the leased agents as advisory metrics. Heavy document AI and self-hosted constrained decoding are anti-candidates for this deployment, and so is any tactic that deceives screeners.

### Cited Findings
- Free generation fabricates (96.7%, and 90.0% with a newer model), and guardrails leave 50% of outputs with a fabrication. — [arXiv 2608.26171](https://arxiv.org/abs/2608.26171)
- Hidden prompt injection appears in about 1% of real resumes, and production detectors comparing rendered and extracted text are deployed. — [arXiv 2605.28999](https://arxiv.org/abs/2605.28999), [Duke Pratt](https://pratt.duke.edu/news/thwarting-prompt-injection/)
- Recruiters reject white-text tactics and ATSs strip formatting. — [Built In](https://builtin.com/articles/hidden-ai-prompts-in-resume)
- The screeners most susceptible to keyword manipulation are the least able to judge competence. — [arXiv 2507.11548](https://arxiv.org/pdf/2507.11548)
- Presentation changes flip 29.6-41.4% of LLM screening decisions. — [arXiv 2609.16517](https://arxiv.org/abs/2609.16517)
- Self-preference is real but cut by more than 50% with simple employer-side mitigations. — [arXiv 2509.00462](https://arxiv.org/abs/2509.00462)
- Pairwise judging flips 35% under distractors against 9% for absolute scores. — [arXiv 2504.14716](https://arxiv.org/abs/2504.14716)
- Strong judges are near chance on hard pairs. — [arXiv 2410.12784](https://arxiv.org/abs/2410.12784)
- Bespoke-MiniCheck-7B is licensed CC BY-NC 4.0. — [PromptLayer](https://www.promptlayer.com/models/bespoke-minicheck-7b)
- marker's weights are free only below $5M of funding or revenue, and MinerU's license is Apache 2.0 with additional conditions. — [marker](https://github.com/datalab-to/marker), [MinerU](https://github.com/opendatalab/MinerU)
- The value of customization as a signal fell after LLMs, and mass AI customization makes hiring less meritocratic in counterfactual. — [arXiv 2511.08785](https://arxiv.org/abs/2511.08785)

### Inferences

**Scorecard** (I = impact, F = feasibility, N = novelty, each 1-5; my judgment from the evidence above.)

| # | Technique | Where in hireme | I | F | N | Cost and complexity | Main risk |
|---|---|---|---|---|---|---|---|
| T6 | Quote-verified provenance spans for listing fields | `citations` (+quote, offsets); kernel write judge; [diag.rs](../../native/mcp/src/diag.rs) provenance refusal; [compose.rs](../../native/kernel/src/compose.rs) spans; MCP `put`/`get` | 5 | 5 | 4 | About 100-200 lines of Rust; no model | Normalization edge cases; inferred fields need an `inferred` flag |
| T1 | Claim-support gate on `tailor`/`add` overlays (numbers, entities, listing keywords, scope and qualifier words) | [cv.rs](../../native/kernel/src/cv.rs) overlay writes; [keywords.rs](../../native/kernel/src/keywords.rs) / [lexicon.rs](../../native/kernel/src/lexicon.rs); `cv_overlays.reason` as the override justification; MCP diagnostics | 5 | 5 | 4 | About 150-250 lines of Rust; no model | False positives; semantic inflation without new tokens |
| T9 | Parse health and hidden-text hygiene for CV files | [blobs.ex](../../lib/hireme/blobs.ex) one-time read; `cv_versions`; CV strip; MCP `cv` | 4 | 4 | 4 | About 80-150 lines of Elixir | Heuristic thresholds; DOCX and PDF variants |
| T4 | Budgeted coverage selection plus gap triage (exact DP or branch-and-bound) | [compose.rs](../../native/kernel/src/compose.rs) `suggest`; [cv.rs](../../native/kernel/src/cv.rs) densities and lineage; MCP `cv` | 4 | 5 | 4 | About 200-300 lines of Rust; deterministic | Keyword-stuffing pressure if unsaturated; no outcome evidence |
| T2 | Cite-or-drop letters (sentence-to-item references verified) | `applications.letter_raw` syntax; kernel check; [compose.rs](../../native/kernel/src/compose.rs) claim list; MCP `put` diagnostics | 4 | 4 | 4 | Small (reuses T1) | Stilted prose; references stripped on render |
| T5 | Alias-aware coverage beside exact coverage | [lexicon.rs](../../native/kernel/src/lexicon.rs) trie; [keywords.rs](../../native/kernel/src/keywords.rs) `VERSION` bump | 3 | 4 | 3 | Small, plus alias-table curation | Overstating coverage against exact search |
| T7 | Strict-mode-friendly MCP schemas and `unspecified` enums | [tools.rs](../../native/mcp/src/tools.rs) / [native/schema](../../native/schema) | 3 | 5 | 2 | Small | Vendor schema subsets drift |
| T8 | Deterministic and agent agreement check on fields | [score.rs](../../native/kernel/src/score.rs) pay, [lexicon.rs](../../native/kernel/src/lexicon.rs) remote and visa phrases; flags in compose | 3 | 4 | 3 | Small | Dictionary misses produce noise flags |
| T14 | Hidden-text sanitization of `listing_raw` before agents and keywords | [keywords.rs](../../native/kernel/src/keywords.rs) stripper; MCP `text` | 3 | 4 | 3 | Small | Over-stripping legitimate collapsed content |
| T11 | Checklist rubric judged by a cross-family jury (agents), stored as metrics | Agents via MCP; deterministic items in the kernel; `citations` metrics | 3 | 4 | 3 | No server code beyond the deterministic items | Judge noise; cost borne by leased agents |
| T12 | Voice anchoring from the operator's letters; draft-to-final edit distance metric | MCP `find`/`text`; kernel edit-distance metric | 3 | 4 | 3 | Small | Homogenization if exemplars are generic |
| T13 | Outcome-tracked variant reporting | Desk overview in [compose.rs](../../native/kernel/src/compose.rs); `replied_on`/`outcome` | 3 | 4 | 2 | Small | Small n; confounding |
| T3 | Entailment check, advisory (MiniCheck-Flan-T5-Large MIT / HHEM-2.1-Open), preferably agent-side | Agent-side metric; optional ONNX Port | 3 | 3 | 2 | Server-side means a new runtime and model | Paraphrase bias; dependency weight |
| T10 | Heavy-parse fallback: an agent transcribes into the existing corrected-text flow; optional Kreuzberg/Xberg NIF | MCP `cv` plus `cv_versions.body` beside `blob_sha` | 2 | 3 | 2 | Zero (agent) or large (NIF) | Native dependency and license review |

**Suggested order.**
1. T6, T1 and T9: deterministic, small, and each closes a documented failure mode.
2. T4 with T5: selection and gap triage.
3. T2 and T7.
4. Agent-side T11, T12 and T13.
5. T3 and T10 only if T1, T2 and T9 show residual problems.

"Replace, don't add" mapping:
- T6 replaces unverifiable citation values.
- T1 reuses `reason`.
- T4 replaces manual drop curation.
- T5 replaces exact-only coverage.
- T9 extends the single existing read rather than adding a pass.

**Anti-candidates, and why not.**
- **Hidden text, white-font keywords, or prompt injection in CVs.** Deceptive, now detected in production by comparing rendered and extracted text, and grounds for rejection. Hireme should instead detect any such text accidentally present (T9).
- **Free-form "rewrite my CV for this job" generation without a claim gate.** 96.7% and 90.0% fabrication; guardrails leave 50%; humans miss about half of the subtle fabrications.
- **Maximizing exact keyword coverage as an objective (keyword stuffing).** It works mainly on low-validity screeners, is unstable under presentation changes, and erodes signal. Keep coverage as a diagnostic of genuine records with saturated, once-per-concept counting.
- **Exploiting LLM self-preference** (drafting with the screener's assumed model family to win same-model bias). The screener is unknown, simple mitigations halve the effect, and it is ethically questionable.
- **Heavy vision-language parsers (MinerU2.5, PaddleOCR-VL, olmOCR 2, marker) as the default path on the single server.** GPU and RAM needs and Python stacks; MinerU's extra license conditions and marker's revenue-capped weights; born-digital CVs don't need them. At most they serve an offline fallback, preferably on the agent side.
- **Self-hosting constrained-decoding engines (XGrammar, llguidance, Outlines).** Hireme hosts no model, and vendor strict modes cover the agents. Revisit only if a local model is added.
- **A single pairwise LLM judge as the quality gate.** 35% flips under distractors, self-preference, and near-chance accuracy on hard pairs.
- **Bespoke-MiniCheck-7B in production checks.** Licensed CC BY-NC 4.0 and 7B on CPU; prefer the MIT-tagged MiniCheck-Flan-T5-Large or agent-side checks.
- **Auto-apply or auto-submit agents.** They violate FIRE HOLD, and mass AI customization erodes the very signal tailoring relies on.
- **Embedding or semantic models in the browser per interaction.** They break the "tiny per-interaction" constraint; alias tables in the kernel trie give deterministic semantic slack instead.
- **"Humanizer" or AI-detector-evasion rewriting of the operator's documents.** Deceptive, the same class as hidden text. This is an inference; no study on it was retrieved.

### Gaps
- The impact scores are judgments from indirect evidence. No source measures callback effects of claim gating, quote provenance or coverage selection.
- Line-of-code estimates are rough and were not checked against hireme's per-commit net line-count rule.
- Licenses still to verify before any adoption: ESCO's reuse terms, the GLiNER2 repository, the exact olmOCR 2 license, MinerU's "additional conditions", the MiniCheck-Flan-T5-Large LICENSE file, and HHEM-2.1-Open's model card.
