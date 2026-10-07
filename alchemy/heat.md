# HEAT governor

Standing order: the pipeline does not snap onto a company or an ATS. Heat gates the queue. FIRE HOLD still owns submit. Nothing here sends an application.

Config lives in `lib/hireme/heat/config.ex`. `Hireme.Heat.Config.defaults/0` is the source of truth.

## Defaults

| Knob | Default | Meaning |
| --- | --- | --- |
| `company_half_life` | 35 days | Company load halves in ~a month (30–45 window) |
| `ats_vendor_half_life` | 14 days | Vendor-level ATS profiling across companies |
| `ats_tenant_half_life` | 21 days | One Greenhouse board / Workday tenant |
| `application_load` | 1.0 | One queued, submitted, or recently closed application |
| `same_department_penalty` | +0.6 | Same org/department is hotter than spreading |
| `clone_penalty` | +0.6 | Near-identical titles stack worse than distinct tracks |
| `mega_cap` | 4.0 | Google, Amazon, Meta, NVIDIA, Microsoft — a few roles if different orgs |
| `large_cap` | 2.5 | Other big tech, labs, frontier |
| `mid_cap` | 1.5 | Named systems shops |
| `small_cap` | 1.0 | Default. One seat, maybe two after decay |
| `ats_vendor_cap` | 40.0 | Decaying cap so one vendor is not the whole campaign |
| `ats_tenant_cap` | 3.0 | Per-tenant |
| `ats_batch_cap` | 20 | One day pack does not slam a single vendor |
| `cool_ratio` | 0.5 | Board: cool |
| `hot_ratio` | 0.8 | Board: hot |

Heat-producing stages: `fire_ready`, `open_fire`, `submitted`, `reply`, `closed`. Discovered/gated/draft do not count until they enter the queue.

Load at time `t`: `amount * 0.5^(days / half_life)`.

A new application’s increment is `1.0`, plus department penalty if another hot app at that company shares the inferred department, plus clone penalty if it shares the role family (seniority stripped).

## Enforcement

`Hireme.Heat.mix/2` keeps highest `score_100` first and defers the rest. `Desk.govern_batch/1` unassigns deferred apps (leftover) and drops queued ones to `gated`. `Desk.set_stage/2` refuses a move into the queue that would exceed a cap (`{:error, :heat}`) unless `heat_override` is set with a logged reason.

Overrides need both the flag and a non-empty reason.

## ATS

Vendor and tenant come from the apply URL host and path: Greenhouse, Lever, Ashby, Workday, iCIMS, SmartRecruiters, Workable, Jobvite, Taleo, SuccessFactors, BambooHR, Rippling, Eightfold, Gem. Unknown hosts do not trip vendor heat.

## Visibility

Desk heatmap under the Life-EV chart. Filters: cool / warm / hot / blocked. MCP: `heat_status`, `can_apply`. CLI: `mix hireme.heat`.
