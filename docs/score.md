# Score

Every application and corporation carries `score_100`, a Life-EV number
from 0 to 100: maximize life EV, not the number of applications. The desk
and the MCP rank by it first. FIRE HOLD stands: a score never submits.

The one implementation is `native/kernel/src/score.rs`. The kernel
**suggests** and never overwrites: a stored `score_100` is the operator's
or an agent's number and wins; a card with none ranks by the suggestion,
and the focus lens and the MCP show both.

## The ladder

| score | band | who |
| --- | --- | --- |
| 100 | `frontier` | OpenAI, Anthropic, SpaceX, Neuralink, xAI |
| 90–99 | `labs` | Google DeepMind, Meta FAIR, Thinking Machines, SSI, Starfish, Valve |
| 85–89 | `big_tech` | big tech with a pay signal over $200k |
| 70–84 | `systems` | real systems, agentic, Rust/C++ seats; big tech without the pay signal (80) |
| 55–69 | `craft` | strong craft, scaled product engineering that is not mid-curve |
| 40–54 | `mid` | decent engineering, mixed EV |
| 20–39 | `thin` | weak EV, unclear ownership, title inflation |
| 0–19 | `kill` | a hard filter |

The band is a pure function of the score; `band` filters on the board use
the score a card ranks by.

## Rules

1. **A hard kill wins over everything** and pins the suggestion under
   20: a staffing or body shop (8), AI theater or prompt-only (10), an
   internship-tier seat (12), a non-engineering role dressed as one
   (sales engineer, business analyst, project manager, support engineer:
   15), or an onsite-only seat away from home (15). Nothing raises a kill,
   not even a named anchor.
2. **Named anchors win over heuristics.** A big-tech name sits at 85 only
   with a pay figure over $200k in `comp_raw` ("$210,000", "250k",
   "180–240k", "250 000 €", a bare "220" or "$220" read as thousands);
   otherwise at 80. A figure with a currency sign after it is the amount
   itself ("250 €/h", "250$" are not $250k).
3. **Heuristics move an unanchored seat** from a base of 48: systems,
   runtime, kernel, infrastructure, distributed or compiler work +22;
   agentic work +10; Rust, C++ or low-level +8; home or remote +5; the pay
   signal +6; CRUD, full-stack, Rails-shop or WordPress work −16. The
   result is clamped to 0–84: heuristics never climb onto an anchor's rung.
4. **Never lower the bar to fill a quota.** Underfill.

## Home

"Home" is not a place written in source. A seat is home when its
`work_mode` is remote, or when its `place_id` is charted in the atlas
and that place (or a city's country) is one of `settings.citizenships`;
it is away when that place is charted and not one of them; otherwise it
is unknown. With no citizenships set, every place is unknown. An onsite
seat (by `work_mode`, or location text saying onsite only or no remote)
is killed as "onsite away" only when it is known to be away. Unknown is
never killed for location.

Anchors match a word of the company name, so an unrelated company that
shares a word with an anchor ("Apple Valley Bakery") is anchored too; a
stored `score_100` is the correction.
