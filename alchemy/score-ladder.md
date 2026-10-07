# Life-EV score_100 ladder

Standing order: every job and every employer gets `score_100` (0–100). The desk, importer, and MCP directory rank by this first. FIRE HOLD — scoring does not submit.

Matei's thesis: maximize life EV, not apply count. Canadian + remote-OK. Prefer frontier labs, real systems seats, agentic, Rust–C++.

## Anchors

| score_100 | Band | Who |
| --- | --- | --- |
| **100** | `frontier` | OpenAI, Anthropic, SpaceX, Neuralink (also SpaceXAI / xAI as the same height) |
| **90** | `labs` | Starfish, Valve, GDM / DeepMind, Meta (FAIR / tier-2 labs), Thinking Machines, SSI |
| **85** | `big_tech` | Other big tech when total comp is **>$200k** (Google, Apple, Microsoft, Amazon, NVIDIA, Stripe, Databricks, …) |
| **70–84** | `systems` | Real systems / agentic / Rust–C++ seats, neoclouds, inference infra, European big-tech systems |
| **55–69** | `craft` | Strong craft, Canadian remote-OK, scaled product eng that is not mid-curve CRUD |
| **40–54** | `mid` | Decent engineering, mixed EV |
| **20–39** | `thin` | Weak EV, unclear ownership, onsite-heavy, title inflation |
| **0–19** | `kill` | Hard filters: staffing / body shop, internship-tier, PM/BA/support/sales-eng as eng, AI theater / prompt-only, onsite-only outside Canada with no remote |

## Rules

1. Named anchors win over heuristics.
2. Big-tech names without a **>$200k** signal sit at 80 (`systems`), not 85.
3. Role / fit / location can move an unanchored seat on the descending rungs. They cannot raise a hard-kill. They cannot raise an anchor except: big-tech + high-comp → 85.
4. Keepers for distillation still use the crème cut in `alchemy/distillation-method.md`. `score_100` is the standing Life-EV number on every card; the crème funnel is how a bank is cut.
5. Never lower the bar to fill a quota. Underfill.

## Fields

Job and employer both store `score_100`. Import may set it explicitly (`score_100` or `score`). Otherwise `Hireme.LifeEv.score/1` assigns it from company, role, fit, location, and comp.

Board default sort: **higher `score_100` first**, then batch, then battleplan rank, then heat. Filters: `band` and `min_score`.
