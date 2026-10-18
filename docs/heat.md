# Heat

The campaign must not snap onto one company or one applicant tracking
system. The heat governor gates the submit queue; FIRE HOLD still owns
submit, and nothing here sends an application.

The one implementation is `native/kernel/src/heat.rs` (with `ats.rs` and
`org.rs` for what it reads off a URL, a company and a role). The sequencer
runs it through the NIF when the `stage` command moves an application
into the queue; the browser and `hireme-mcp` run the same code to predict
the verdict and to colour the board.

## What carries heat

An application in a hot stage (`fire_ready`, `open_fire`, `submitted`,
`reply`, `closed`) puts a load of `application_load` on three things:

- its **company** (the normalized `applications.company`),
- its **ATS vendor** (from `listing_url`, else `canonical_url`),
- its **ATS tenant** (one company's board on that vendor).

The load decays from the application's `stage_on` day:
`load · 0.5^(days / half_life)`. A peer whose decayed load is under
`load_floor` stops counting, because decay never reaches zero and a
company whose cap is one application's load would otherwise never take a
second one.

## The check

When the `stage` command moves an application from a cold stage into
`fire_ready`, `open_fire` or `submitted`, the governor computes, against
every hot application except this one:

- the company's load and the **increment**: `application_load`, plus
  `same_department_penalty` when a hot peer at the company shares the
  role's department, plus `clone_penalty` when one shares its role family
  (seniority words stripped, so "Senior" and "Staff Software Engineer"
  are clones);
- the vendor's and tenant's loads.

It defers the move, first match wins, when:

1. the application's batch already holds `ats_batch_cap` hot applications
   on the same vendor (`ats_batch_cap`);
2. the vendor's load plus one application passes `ats_vendor_cap`;
3. the tenant's load plus one application passes `ats_tenant_cap`;
4. the company's load plus the increment passes its size tier's cap.

An unknown vendor never trips 1–3. A deferred move is refused `heat` with
the verdict as data, including `cooldown_days`: how long until the load
has decayed enough for the move to fit, nothing else changing (when the
increment alone fills the cap, until the load falls under the floor; when
it exceeds the cap, never, and the field is null).

**Override.** The `heat_override` command with a non-blank reason sets
the application's flag and reason and writes a `heat` event; afterwards
the governor lets it past and reports `reason: "override"`. Either the
flag or the reason alone is nothing.

## Size tiers

From the company name: a word of the name, or the name with its spaces
removed, naming a public company in the mega or large list; else `mid`
when the name has a systems, runtime, infra or lab word; else `small`.

| Tier | Cap | Who |
| --- | --- | --- |
| mega | 4.0 | Google, Amazon, Meta, NVIDIA, Microsoft: a few roles across orgs |
| large | 2.5 | other big tech, the labs, the frontier |
| mid | 1.5 | named systems shops |
| small | 1.0 | everyone else: one seat, a second after decay |

## Defaults

Every number is overridable per account by name in
`settings.heat_config` (a JSON object); an unknown key, a non-number, or a
value that is not positive and finite is ignored, so a bad setting cannot
loosen anything by accident.

| Key | Default | Meaning |
| --- | --- | --- |
| `company_half_life` | 35 days | a company forgets in about a month |
| `ats_vendor_half_life` | 14 days | vendor-level profiling across companies |
| `ats_tenant_half_life` | 21 days | one tenant is usually one employer |
| `application_load` | 1.0 | one hot application |
| `same_department_penalty` | 0.6 | same department is hotter than spreading |
| `clone_penalty` | 0.6 | near-identical titles stack worse than distinct tracks |
| `mega_cap` / `large_cap` / `mid_cap` / `small_cap` | 4.0 / 2.5 / 1.5 / 1.0 | company caps by tier |
| `ats_vendor_cap` | 40.0 | so one vendor is never the whole campaign |
| `ats_tenant_cap` | 3.0 | per tenant |
| `ats_batch_cap` | 20 | one batch does not slam a single vendor |
| `cool_ratio` / `hot_ratio` | 0.5 / 0.8 | the board's cool / warm / hot bands |
| `load_floor` | 0.05 | a peer under this no longer counts (152 days at 35) |

## The board

Every card shows the governor's verdict on it entering the queue now:
`blocked` when it would be deferred, else `hot`, `warm` or `cool` by its
company's projected load over cap against `hot_ratio` and `cool_ratio`.
A card already in the queue is judged without its own load, so it shows
how crowded its company is around it. The board ranks by score, then
heat, cool first.

## Vendors

Greenhouse, Lever, Ashby, Workday, iCIMS, SmartRecruiters, Workable,
Jobvite, Taleo, SuccessFactors, BambooHR, Rippling, Eightfold, Gem. The
tenant comes from the host (`acme.wd5.myworkdayjobs.com`,
`careers-acme.icims.com`) or the first non-generic path segment
(`jobs.lever.co/acme`), and from `?for=` on Greenhouse embeds.
