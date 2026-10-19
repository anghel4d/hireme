# Heat

The campaign must not snap onto one company or one applicant tracking
system. The heat governor gates the submit queue; FIRE HOLD still owns
submit, and nothing here sends an application.

The one implementation is `native/kernel/src/heat.rs` (with `ats.rs`,
`org.rs` and `lexicon.rs` for what it reads off a URL, a company and a
role). The sequencer
runs it through the NIF when the `stage` command moves an application
into the queue; the browser and the server run the same code to predict
the verdict and to colour the board.

## What carries heat

Only what went out: a `submitted` application, or one in `reply` or
`closed` after something was sent (its rail's `submitted` or `reply` rung
was reached, never jumped over; an answered outreach application counts
like a sent one). A draft at `fire_ready` or `open_fire` carries nothing,
and neither does a listing closed before anything went out.

Each sent application weighs what the other side has seen of it:

| What happened | Weight | Remembered for (half-life) |
| --- | --- | --- |
| submitted, no answer yet (`application_load`) | 1.0 | 30 days |
| in conversation: answered, still in `reply` (`conversation_weight`) | 2.0 | 30 days |
| rejected (`rejected_weight`) | 1.5 | 90 days (`rejected_half_life`) |
| ghosted (`ghosted_weight`) | 0.7 | 30 days |
| withdrawn, declined, or closed with no outcome (`closed_weight`) | 1.0 | 30 days |
| offer | blocks the company | as long as a rejection |

The load decays from the latest of `applied_on` and `replied_on` that
exists, else from the day it entered its stage: `weight · 0.5^(days /
half_life)`. Closing an answered application is no new contact, so it does
not re-warm the company. A load under `load_floor` counts for nothing,
because decay never reaches zero.

It is counted against three things:

- its **company**: its `corporation_id` when linked, else the normalized
  `applications.company`. A company's load on one role is each peer's load
  weighted by how close its role is: the same role family (seniority
  words stripped, so "Senior" and "Staff Software Engineer" are one
  family) `similar_family` 1.0, the same department (two roles the lexicon
  cannot place count as one department) `similar_department` 0.6, any
  other team `similar_other` 0.25. Five applications to five different
  teams are not five clones.
- its **ATS vendor** (from `listing_url`, else `canonical_url`) and its
  **ATS tenant** (one company's board on that vendor). An ATS sees volume,
  not teams: these loads are unweighted, at their own half-lives.

## Capacity

A company's capacity comes from its corporation's cited headcount when
there is one: `1 + log2(headcount / headcount_base)`, between `cap_min`
and `cap_max`, so about 1 for 100 people, 4.3 for 1,000 and 7.6 for
10,000. Without a headcount it is its size tier's cap (below).

## The check

When the `stage` command moves an application into `fire_ready`,
`open_fire` or `submitted`, and again when it goes out to `submitted`
(drafts carry no heat, so two queued at one company are each judged as
they send), the governor checks, against every sent application except
this one, and defers the move, first match wins, when:

1. the company made an offer (`offer`);
2. the company rejected the same role family under `reapply_days` ago
   (`reapply`);
3. the application's batch already holds `ats_batch_cap` sent
   applications on the same vendor whose vendor load still lives
   (`ats_batch_cap`);
4. the vendor's load plus one application passes `ats_vendor_cap`;
5. the tenant's load plus one application passes `ats_tenant_cap`;
6. the company's load on this role plus `application_load` passes its
   capacity (`company_cap`).

An unknown vendor never trips 3–5. A deferred move is refused `heat` with
the verdict as data, including `cooldown_days`: the first day every check
passes with nothing else changing. Each check only loosens with time
(loads, live peers and live batch members only shrink, an offer and a
reapply window only lapse), so each failing
one is searched for its own first passing day and the latest of those is
the answer, exact. It is null when the move is still held ten years on.

The `stage` command also refuses, before heat: a batched stage without a
batch (`stage`, `needs_batch`), `open_fire` by anything but its human
command (`stage`), `submitted` from anywhere but `open_fire` (`fire_hold`),
a sent application moved back before `submitted` (`stage`, `sent`), and
`reply` for a listing application that was never sent (`stage`,
`not_sent`).

**Override.** The `heat_override` command with a non-blank reason sets
the application's flag and reason and writes a `heat` event; afterwards
the governor lets it past and reports `reason: "override"`. Either the
flag or the reason alone is nothing.

## Size tiers

Without a headcount, from the company name: a word of the name, or the
name with its spaces removed, naming a public company in the mega or large
list; else `mid` when the name has a systems, runtime, infra or lab word;
else `small`, which means the lexicon cannot place it, not that it is
tiny.

| Tier | Cap | Who |
| --- | --- | --- |
| mega | 4.0 | Google, Amazon, Meta, NVIDIA, Microsoft: a few roles across orgs |
| large | 2.5 | other big tech, the labs, the frontier |
| mid | 1.5 | named systems shops |
| small | 1.5 | everyone else: one seat, a second in another team or after decay |

## Defaults

Every number is overridable per account by name in
`settings.heat_config` (a JSON object); an unknown key, a non-number, or a
value out of range is ignored (the similarities may be 0 and are at most
1, `reapply_days` may be 0, a weight is at most 16, everything else must
be positive; a `cool_ratio` above `hot_ratio` or a `cap_min` above
`cap_max` drops both), so a bad setting cannot loosen anything by accident.

| Key | Default | Meaning |
| --- | --- | --- |
| `company_half_life` | 30 days | a company forgets an application in about a month |
| `rejected_half_life` | 90 days | a no is remembered longer |
| `ats_vendor_half_life` | 14 days | vendor-level profiling across companies |
| `ats_tenant_half_life` | 21 days | one tenant is usually one employer |
| `application_load` | 1.0 | a submission, and what a new one adds |
| `conversation_weight` | 2.0 | an active process competes with a new application |
| `rejected_weight` | 1.5 | reapplying soon after a no reads badly |
| `ghosted_weight` | 0.7 | nobody looked |
| `closed_weight` | 1.0 | withdrawn, declined, or closed |
| `similar_family` / `similar_department` / `similar_other` | 1.0 / 0.6 / 0.25 | a peer's weight by how close its role is |
| `reapply_days` | 90 | a rejection holds its role family this long |
| `mega_cap` / `large_cap` / `mid_cap` / `small_cap` | 4.0 / 2.5 / 1.5 / 1.5 | company caps by tier, without a headcount |
| `headcount_base` / `cap_min` / `cap_max` | 100 / 1.0 / 8.0 | capacity from headcount |
| `ats_vendor_cap` | 40.0 | so one vendor is never the whole campaign |
| `ats_tenant_cap` | 3.0 | per tenant |
| `ats_batch_cap` | 20 | one batch does not slam a single vendor |
| `cool_ratio` / `hot_ratio` | 0.5 / 0.8 | the board's cool / warm / hot bands |
| `load_floor` | 0.05 | a load under this no longer counts (130 days for a submission) |

## The board

Every card shows its company's load on its role already there over the
company's capacity, without the card itself: `cool` under `cool_ratio`,
`warm` under `hot_ratio`, `hot` above, and `blocked` when the governor
would defer the card's move now. An untouched company is cool however its
drafts stand. The board ranks by score, then heat, cool first.

## Vendors

Greenhouse, Lever, Ashby, Workday, iCIMS, SmartRecruiters, Workable,
Jobvite, Taleo, SuccessFactors, BambooHR, Rippling, Eightfold, Gem. The
tenant comes from the host (`acme.wd5.myworkdayjobs.com`,
`careers-acme.icims.com`) or the first non-generic path segment
(`jobs.lever.co/acme`), and from `?for=` on Greenhouse embeds.
