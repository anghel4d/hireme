//! Every view the desk shows, derived in the browser from the raw tables.
//!
//! The server sends the account's rows (job_apps, profiles, cv_variants,
//! overlays, batches, scoreboard_snapshots, leases, clock...) and keeps
//! them current; this module turns the pending view of those rows into
//! the tables TypeScript reads, exactly as the Elixir code would:
//!
//! - `cards`: `Desk.list_cards` painted by `Heat.decorate_all`, one row
//!   per job that has a profile and a variant (the query's inner joins).
//! - `verdicts`: `Heat.verdict/4` for every job, what `can_apply` answers.
//! - `heat_rows`: `Heat.chart/2`, companies (group 0) then vendors (1).
//! - `score`, `varieties`, `chart_bands`, `chart_bins`:
//!   `Campaign.scoreboard/1` with `Desk.score_chart/0` (`LifeEv.chart`).
//!
//! String columns point at the raw rows' own bytes where the value is a raw
//! field, and reuse the previous derive's bytes where a derived string did
//! not change, so a re-derive allocates almost nothing in the arena and
//! the board's incremental sort and search see unchanged rows as unchanged.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use wire::schema::{col, table};
use wire::{F64, NONE, STR, U32};

use crate::desk::Desk;
use crate::heat::{self, Job, Snapshot, Traits};
use crate::store::{Arena, Column, Data, Table};

/// What a derive keeps for the next one.
pub struct Derived {
    /// Per job id: the string references its traits were read from, and
    /// the traits. Valid within one arena epoch.
    traits: BTreeMap<u32, ([u32; 14], Traits)>,
    epoch: u32,
    /// Constant strings put once per arena epoch.
    consts: Vec<(&'static str, [u32; 2])>,
}

const STATUSES: [&str; 4] = ["open", "paused", "hired", "closed"];
const FRESHNESS: [&str; 5] = ["unknown", "open", "thin", "closed", "blocked"];
const GATES: [&str; 4] = ["unset", "pursue", "maybe", "skip"];
const SENT: [u8; 2] = [7, 8]; // submitted, reply
const FLAGS: [&str; 5] = [
    "unfilled",
    "short",
    "few_companies",
    "few_locations",
    "few_fits",
];

/// LifeEv bands: key, label, min, max.
const BANDS: [(&str, &str, u32, u32); 8] = [
    ("frontier", "Frontier", 100, 100),
    ("labs", "Tier-2 labs", 90, 99),
    ("big_tech", "Big tech", 85, 89),
    ("systems", "Systems", 70, 84),
    ("craft", "Craft", 55, 69),
    ("mid", "Mid", 40, 54),
    ("thin", "Thin", 20, 39),
    ("kill", "Kill", 0, 19),
];

fn ix_of(list: &[&str], s: &str) -> u32 {
    list.iter().position(|x| *x == s).unwrap_or(0) as u32
}

fn text(arena: &Arena, r: [u32; 2]) -> &str {
    arena.text(r)
}

/// A table under construction.
struct Build {
    t: Table,
}

impl Build {
    fn new(id: u16, n: usize) -> Build {
        let mut t = Table::new(id);
        t.n = n;
        Build { t }
    }

    fn u32(&mut self, c: u16, v: Vec<u32>) {
        self.t.cols.push(Column {
            id: c,
            ty: U32,
            data: Data::W32(v),
        });
    }

    fn f64(&mut self, c: u16, v: Vec<f64>) {
        let v = v.into_iter().map(f64::to_bits).collect();
        self.t.cols.push(Column {
            id: c,
            ty: F64,
            data: Data::W64(v),
        });
    }

    fn str(&mut self, c: u16, v: Vec<[u32; 2]>) {
        self.t.cols.push(Column {
            id: c,
            ty: STR,
            data: Data::Str(v),
        });
    }
}

/// A string for a derived column: the previous derive's bytes when they
/// are the same, else new bytes in the arena.
fn reuse(arena: &mut Arena, prev: Option<[u32; 2]>, s: &[u8]) -> [u32; 2] {
    match prev {
        Some(p) if arena.get(p) == s => p,
        _ => arena.put(s),
    }
}

impl Derived {
    pub const fn new() -> Derived {
        Derived {
            traits: BTreeMap::new(),
            epoch: u32::MAX,
            consts: Vec::new(),
        }
    }

    fn konst(&mut self, arena: &mut Arena, s: &'static str) -> [u32; 2] {
        if self.epoch != arena.epoch {
            self.consts.clear();
            self.traits.clear();
            self.epoch = arena.epoch;
        }
        if let Some((_, r)) = self.consts.iter().find(|(k, _)| *k == s) {
            return *r;
        }
        let r = arena.put(s.as_bytes());
        self.consts.push((s, r));
        r
    }
}

/// The job rows as the governor reads them.
struct Rows<'a> {
    jobs: Vec<Job<'a>>,
}

impl Desk {
    /// The job_apps rows of the view as the governor reads them, in row
    /// order, with their traits (cached per job while its text holds).
    fn heat_rows(&self, d: &mut Derived) -> (Vec<Job<'_>>, Vec<Traits>) {
        let jt = table::JOB_APPS;
        let n = self.rows(jt);
        let arena = &self.store.arena;
        let s = |c: u16| self.strs(jt, c);
        let u = |c: u16| self.w32(jt, c);
        let at = |v: &[[u32; 2]], i: usize| v.get(i).copied().unwrap_or([0, 0]);
        let w = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0);
        let (ids, company, role, listing, canonical, department, squad, fit) = (
            u(col::job_apps::ID),
            s(col::job_apps::COMPANY),
            s(col::job_apps::ROLE),
            s(col::job_apps::LISTING_URL),
            s(col::job_apps::CANONICAL_URL),
            s(col::job_apps::DEPARTMENT),
            s(col::job_apps::SQUAD),
            s(col::job_apps::FIT),
        );
        let (stage, stage_on, score, ho, hor) = (
            s(col::job_apps::CURRENT_STAGE),
            u(col::job_apps::STAGE_ON),
            u(col::job_apps::SCORE_100),
            u(col::job_apps::HEAT_OVERRIDE),
            s(col::job_apps::HEAT_OVERRIDE_REASON),
        );
        let jobs: Vec<Job> = (0..n)
            .map(|i| Job {
                id: w(ids, i),
                company: text(arena, at(company, i)),
                role: text(arena, at(role, i)),
                listing_url: text(arena, at(listing, i)),
                canonical_url: text(arena, at(canonical, i)),
                department: text(arena, at(department, i)),
                squad: text(arena, at(squad, i)),
                fit: text(arena, at(fit, i)),
                stage: heat::stage_ix(text(arena, at(stage, i))),
                stage_on: stage_on.get(i).copied().unwrap_or(NONE),
                score: match w(score, i) {
                    NONE => 0,
                    v => v,
                },
                heat_override: w(ho, i) == 1,
                heat_override_reason: text(arena, at(hor, i)),
            })
            .collect();
        if d.epoch != arena.epoch {
            d.consts.clear();
            d.traits.clear();
            d.epoch = arena.epoch;
        }
        let tr = (0..n)
            .map(|i| {
                let mut k = [0u32; 14];
                for (j, c) in [company, role, listing, canonical, department, squad, fit].iter().enumerate() {
                    k[2 * j..2 * j + 2].copy_from_slice(&at(c, i));
                }
                let id = jobs[i].id;
                match d.traits.get(&id) {
                    Some((key, t)) if *key == k => t.clone(),
                    _ => {
                        let t = heat::traits(&jobs[i]);
                        d.traits.insert(id, (k, t.clone()));
                        t
                    }
                }
            })
            .collect();
        (jobs, tr)
    }

    /// Heat.can_apply/2 for the job at `row` of job_apps, as the view
    /// stands: what a stage write into the queue is judged by.
    pub(crate) fn can_apply(&mut self, row: usize) -> bool {
        let mut d = core::mem::replace(&mut self.derived, Derived::new());
        let today = if self.today == NONE { 0 } else { self.today };
        let allow = {
            let (jobs, tr) = self.heat_rows(&mut d);
            heat::can_apply(&jobs, &tr, row, today).allow
        };
        self.derived = d;
        allow
    }

    /// Re-derives every view from the raw tables when they moved. Returns
    /// whether it ran.
    pub fn derive(&mut self) -> bool {
        if !self.raw_dirty || self.store.table(table::JOB_APPS).is_none() {
            return false;
        }
        self.raw_dirty = false;
        let mut d = core::mem::replace(&mut self.derived, Derived::new());
        if d.epoch != self.store.arena.epoch {
            d.consts.clear();
            d.traits.clear();
            d.epoch = self.store.arena.epoch;
        }
        let today = if self.today == NONE { 0 } else { self.today };

        // ---- read: everything computed while the arena is borrowed ----
        let jt = table::JOB_APPS;
        let n = self.rows(jt);
        let arena = &self.store.arena;
        let s = |c: u16| self.strs(jt, c);
        let u = |c: u16| self.w32(jt, c);
        let at = |v: &[[u32; 2]], i: usize| v.get(i).copied().unwrap_or([0, 0]);
        let w = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0);
        let (jobs, tr) = self.heat_rows(&mut d);
        let rows = Rows { jobs };
        let snap = Snapshot::build(&rows.jobs, &tr, today);
        let verdicts: Vec<heat::Verdict> = (0..n)
            .map(|i| snap.verdict(&rows.jobs, &tr, i, today))
            .collect();
        let (chart_companies, chart_vendors) = snap.chart(&rows.jobs);

        // Joins for the cards: profile, variant (label, lineage), leases,
        // overlay counts per lineage.
        let has_profile = |pid: u32| self.row_of(table::PROFILES, pid).is_some();
        let vt = table::CV_VARIANTS;
        let mut variant_of: BTreeMap<u32, ([u32; 2], u32)> = BTreeMap::new();
        {
            let (vjob, vlabel, vlin) = (
                self.w32(vt, col::cv_variants::JOB_APP_ID),
                self.strs(vt, col::cv_variants::LABEL),
                self.w32(vt, col::cv_variants::LINEAGE_ID),
            );
            for r in 0..self.rows(vt) {
                variant_of
                    .entry(w(vjob, r))
                    .or_insert((at(vlabel, r), w(vlin, r)));
            }
        }
        let mut masks: BTreeMap<u32, [u32; 3]> = BTreeMap::new();
        {
            let ot = table::OVERLAYS;
            let (olin, omode) = (
                self.w32(ot, col::overlays::LINEAGE_ID),
                self.strs(ot, col::overlays::MODE),
            );
            for r in 0..self.rows(ot) {
                let k = match arena.get(at(omode, r)) {
                    b"hidden" => 0,
                    b"altered" => 1,
                    b"emphasized" => 2,
                    _ => continue,
                };
                masks.entry(w(olin, r)).or_insert([0; 3])[k] += 1;
            }
        }
        let leased: Vec<u32> = {
            let mut v = self.w32(table::LEASES, col::leases::ID).to_vec();
            v.sort_unstable();
            v
        };
        // Mask counts: the server's glance on the job row, except on a
        // lineage a pending overlay op touches, where they are counted from
        // the predicted overlay rows as the server will recount them.
        let recount: Vec<u32> = self
            .pending
            .iter()
            .filter_map(|p| wire::Op::parse(&p.bytes).ok())
            .filter(|o| o.kind == wire::schema::op::OVERLAY)
            .filter_map(|o| variant_of.get(&o.target).map(|v| v.1))
            .collect();
        let card_rows: Vec<usize> = (0..n)
            .filter(|&i| {
                has_profile(w(u(col::job_apps::PROFILE_ID), i))
                    && variant_of.contains_key(&rows.jobs[i].id)
            })
            .collect();

        // Scoreboard inputs.
        let bt = table::BATCHES;
        let mut batches: Vec<usize> = (0..self.rows(bt)).collect();
        let bord = self.w32(bt, col::batches::ORDINAL);
        batches.sort_by_key(|&r| w(bord, r));
        let queued: Vec<u32> = batches
            .iter()
            .filter(|&&r| {
                let st = self.vstr(bt, col::batches::STATUS, r);
                self.vu32(bt, col::batches::QUEUED_ON, r) == today
                    && (st == b"fire_ready" || st == b"open_fire")
            })
            .map(|&r| self.vu32(bt, col::batches::ID, r))
            .collect();
        let open_fire = batches
            .iter()
            .any(|&r| self.vu32(bt, col::batches::FIRE, r) == 1);
        let batch_id = u(col::job_apps::BATCH_ID);
        let apps_today = (0..n).filter(|&i| queued.contains(&w(batch_id, i))).count() as u32;
        let sent = |i: usize| rows.jobs[i].stage.is_some_and(|s| SENT.contains(&s));
        let submitted_today = (0..n)
            .filter(|&i| sent(i) && rows.jobs[i].stage_on == today)
            .count() as u32;
        let cumulative = (0..n).filter(|&i| sent(i)).count() as u32;
        let snt = table::SCOREBOARD_SNAPSHOTS;
        // The latest snapshot by noted_on (none sorts first), then id.
        let snap_row = (0..self.rows(snt)).max_by_key(|&r| {
            let on = self.vu32(snt, col::scoreboard_snapshots::NOTED_ON, r);
            (
                on != NONE,
                on,
                self.vu32(snt, col::scoreboard_snapshots::ID, r),
            )
        });
        let sv = |c: u16, default: u32| snap_row.map_or(default, |r| self.vu32(snt, c, r));
        let snapv = [
            sv(col::scoreboard_snapshots::LEFTOVER_UNIQUE, 0),
            sv(col::scoreboard_snapshots::NOTED_ON, NONE),
            sv(col::scoreboard_snapshots::DAILY_BATCHES, 8),
            sv(col::scoreboard_snapshots::DAILY_APPS, 440),
            sv(col::scoreboard_snapshots::TARGET_TOTAL, 10_000),
            sv(col::scoreboard_snapshots::TARGET_ON, NONE),
        ];
        let mut freq = [0u32; 101];
        for j in &rows.jobs {
            freq[j.score.min(100) as usize] += 1;
        }
        drop(rows);

        // ---- write ----
        let prev_notes: BTreeMap<u32, [u32; 2]> = self
            .store
            .table(table::VERDICTS)
            .map(|t| {
                let (id, note) = (t.col(col::verdicts::ID), t.col(col::verdicts::NOTE));
                (0..t.n)
                    .map(|r| {
                        (
                            id.map_or(0, |c| c.u32(r)),
                            note.map_or([0, 0], |c| c.str_ref(r)),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        let ids = self.w32(jt, col::job_apps::ID).to_vec();
        let company_refs = self.strs(jt, col::job_apps::COMPANY).to_vec();
        let raw = |c: u16| self.strs(jt, c).to_vec();
        let raw32 = |c: u16| self.w32(jt, c).to_vec();
        let (role_r, loc_r, next_r, fit_r, pips_r, stage_r, status_r, fresh_r, gate_r) = (
            raw(col::job_apps::ROLE),
            raw(col::job_apps::LOCATION),
            raw(col::job_apps::NEXT_ACTION),
            raw(col::job_apps::FIT),
            raw(col::job_apps::PIPS),
            raw(col::job_apps::CURRENT_STAGE),
            raw(col::job_apps::STATUS),
            raw(col::job_apps::FRESHNESS),
            raw(col::job_apps::GATE),
        );
        let (hidden_c, altered_c, emph_c) = (
            raw32(col::job_apps::MASK_HIDDEN),
            raw32(col::job_apps::MASK_ALTERED),
            raw32(col::job_apps::MASK_EMPHASIZED),
        );
        let (heat_c, profile_c, hits_c, total_c, next_due_c, stage_on_c, batch_c, score_c) = (
            raw32(col::job_apps::HEAT),
            raw32(col::job_apps::PROFILE_ID),
            raw32(col::job_apps::KEYWORD_HITS),
            raw32(col::job_apps::KEYWORD_TOTAL),
            raw32(col::job_apps::NEXT_DUE),
            raw32(col::job_apps::STAGE_ON),
            raw32(col::job_apps::BATCH_ID),
            raw32(col::job_apps::SCORE_100),
        );
        let arena = &mut self.store.arena;
        let k = card_rows.len();
        let pick = |v: &Vec<u32>, i: usize| v.get(i).copied().unwrap_or(0);
        let pick_s = |v: &Vec<[u32; 2]>, i: usize| v.get(i).copied().unwrap_or([0, 0]);
        let st = |a: &Arena, v: &Vec<[u32; 2]>, i: usize| String::from(text(a, pick_s(v, i)));

        let mut cards = Build::new(table::CARDS, k);
        cards.u32(
            col::cards::ID,
            card_rows.iter().map(|&i| pick(&ids, i)).collect(),
        );
        cards.u32(
            col::cards::SCORE,
            card_rows
                .iter()
                .map(|&i| match pick(&score_c, i) {
                    NONE => 0,
                    v => v,
                })
                .collect(),
        );
        cards.u32(
            col::cards::HEAT,
            card_rows.iter().map(|&i| pick(&heat_c, i)).collect(),
        );
        cards.u32(
            col::cards::STAGE,
            card_rows
                .iter()
                .map(|&i| heat::stage_ix(&st(arena, &stage_r, i)).unwrap_or(0) as u32)
                .collect(),
        );
        cards.u32(
            col::cards::STATUS,
            card_rows
                .iter()
                .map(|&i| ix_of(&STATUSES, &st(arena, &status_r, i)))
                .collect(),
        );
        cards.u32(
            col::cards::FRESHNESS,
            card_rows
                .iter()
                .map(|&i| ix_of(&FRESHNESS, &st(arena, &fresh_r, i)))
                .collect(),
        );
        cards.u32(
            col::cards::GATE,
            card_rows
                .iter()
                .map(|&i| ix_of(&GATES, &st(arena, &gate_r, i)))
                .collect(),
        );
        cards.u32(
            col::cards::BATCH,
            card_rows
                .iter()
                .map(|&i| match pick(&batch_c, i) {
                    NONE => 0,
                    v => v,
                })
                .collect(),
        );
        cards.u32(
            col::cards::PROFILE,
            card_rows.iter().map(|&i| pick(&profile_c, i)).collect(),
        );
        // Keyword hits: the server's glance, unless TypeScript recomposed
        // the CV for a pending op and set them.
        let glance = |i: usize, which: usize, raw: &Vec<u32>| {
            self.glance
                .get(&pick(&ids, i))
                .map_or(pick(raw, i), |g| g[which])
        };
        cards.u32(
            col::cards::HITS,
            card_rows.iter().map(|&i| glance(i, 0, &hits_c)).collect(),
        );
        cards.u32(
            col::cards::TOTAL,
            card_rows.iter().map(|&i| glance(i, 1, &total_c)).collect(),
        );
        let mask = |i: usize, m: usize, raw: &Vec<u32>| {
            let lin = variant_of.get(&pick(&ids, i)).map_or(0, |v| v.1);
            if recount.contains(&lin) {
                masks.get(&lin).map_or(0, |c| c[m])
            } else {
                pick(raw, i)
            }
        };
        cards.u32(
            col::cards::HIDDEN,
            card_rows.iter().map(|&i| mask(i, 0, &hidden_c)).collect(),
        );
        cards.u32(
            col::cards::ALTERED,
            card_rows.iter().map(|&i| mask(i, 1, &altered_c)).collect(),
        );
        cards.u32(
            col::cards::EMPHASIZED,
            card_rows.iter().map(|&i| mask(i, 2, &emph_c)).collect(),
        );
        cards.u32(
            col::cards::STAGE_ON,
            card_rows
                .iter()
                .map(|&i| stage_on_c.get(i).copied().unwrap_or(NONE))
                .collect(),
        );
        cards.u32(
            col::cards::NEXT_DUE,
            card_rows
                .iter()
                .map(|&i| next_due_c.get(i).copied().unwrap_or(NONE))
                .collect(),
        );
        cards.u32(
            col::cards::HEAT_STATE,
            card_rows
                .iter()
                .map(|&i| verdicts[i].heat_state())
                .collect(),
        );
        cards.u32(
            col::cards::LOAD_PCT,
            card_rows
                .iter()
                .map(|&i| {
                    let v = &verdicts[i];
                    if v.company_cap <= 0.0 {
                        100
                    } else {
                        heat::round0(v.company_load / v.company_cap * 100.0) as u32
                    }
                })
                .collect(),
        );
        cards.u32(
            col::cards::COOLDOWN,
            card_rows.iter().map(|&i| verdicts[i].cooldown).collect(),
        );
        cards.u32(
            col::cards::LEASED,
            card_rows
                .iter()
                .map(|&i| leased.binary_search(&pick(&ids, i)).is_ok() as u32)
                .collect(),
        );
        cards.str(
            col::cards::COMPANY,
            card_rows
                .iter()
                .map(|&i| pick_s(&company_refs, i))
                .collect(),
        );
        cards.str(
            col::cards::ROLE,
            card_rows.iter().map(|&i| pick_s(&role_r, i)).collect(),
        );
        cards.str(
            col::cards::LOCATION,
            card_rows.iter().map(|&i| pick_s(&loc_r, i)).collect(),
        );
        cards.str(
            col::cards::NEXT_ACTION,
            card_rows.iter().map(|&i| pick_s(&next_r, i)).collect(),
        );
        cards.str(
            col::cards::CV_LABEL,
            card_rows
                .iter()
                .map(|&i| variant_of.get(&pick(&ids, i)).map_or([0, 0], |v| v.0))
                .collect(),
        );
        cards.str(
            col::cards::FIT,
            card_rows.iter().map(|&i| pick_s(&fit_r, i)).collect(),
        );
        cards.str(
            col::cards::PIPS,
            card_rows.iter().map(|&i| pick_s(&pips_r, i)).collect(),
        );
        cards.f64(
            col::cards::LOAD,
            card_rows
                .iter()
                .map(|&i| verdicts[i].company_load)
                .collect(),
        );
        cards.f64(
            col::cards::CAP,
            card_rows.iter().map(|&i| verdicts[i].company_cap).collect(),
        );
        let vnames: Vec<[u32; 2]> = heat::VENDORS.iter().map(|v| d.konst(arena, v)).collect();
        cards.str(
            col::cards::ATS_VENDOR,
            card_rows
                .iter()
                .map(|&i| vnames[verdicts[i].vendor as usize])
                .collect(),
        );
        cards.f64(
            col::cards::RATIO,
            card_rows
                .iter()
                .map(|&i| heat::ratio(verdicts[i].company_load, verdicts[i].company_cap))
                .collect(),
        );

        // Verdicts, every job.
        let mut vb = Build::new(table::VERDICTS, n);
        vb.u32(col::verdicts::ID, ids.clone());
        let allow = d.konst(arena, "allow");
        let defer = d.konst(arena, "defer");
        vb.str(
            col::verdicts::DECISION,
            verdicts
                .iter()
                .map(|v| if v.allow { allow } else { defer })
                .collect(),
        );
        let reason_names: Vec<[u32; 2]> = [
            heat::Reason::Ok,
            heat::Reason::Override,
            heat::Reason::CompanyCap,
            heat::Reason::AtsVendorCap,
            heat::Reason::AtsTenantCap,
            heat::Reason::AtsBatchCap,
        ]
        .iter()
        .map(|r| d.konst(arena, r.name()))
        .collect();
        let size_names: Vec<[u32; 2]> = [
            heat::Size::Mega,
            heat::Size::Large,
            heat::Size::Mid,
            heat::Size::Small,
        ]
        .iter()
        .map(|s| d.konst(arena, s.name()))
        .collect();
        let reasons: Vec<[u32; 2]> = verdicts
            .iter()
            .map(|v| reason_names[v.reason as usize])
            .collect();
        vb.str(col::verdicts::REASON, reasons);
        vb.str(
            col::verdicts::COMPANY,
            (0..n).map(|i| pick_s(&company_refs, i)).collect(),
        );
        vb.f64(
            col::verdicts::COMPANY_LOAD,
            verdicts.iter().map(|v| v.company_load).collect(),
        );
        vb.f64(
            col::verdicts::COMPANY_CAP,
            verdicts.iter().map(|v| v.company_cap).collect(),
        );
        vb.f64(
            col::verdicts::COMPANY_INCREMENT,
            verdicts.iter().map(|v| v.company_increment).collect(),
        );
        let sizes: Vec<[u32; 2]> = verdicts
            .iter()
            .map(|v| size_names[v.size as usize])
            .collect();
        vb.str(col::verdicts::SIZE, sizes);
        vb.str(
            col::verdicts::ATS_VENDOR,
            verdicts.iter().map(|v| vnames[v.vendor as usize]).collect(),
        );
        let tenants: Vec<[u32; 2]> = verdicts
            .iter()
            .map(|v| arena.put(v.tenant.as_deref().unwrap_or("").as_bytes()))
            .collect();
        vb.str(col::verdicts::ATS_TENANT, tenants);
        vb.u32(
            col::verdicts::HAS_TENANT,
            verdicts.iter().map(|v| v.tenant.is_some() as u32).collect(),
        );
        vb.f64(
            col::verdicts::VENDOR_LOAD,
            verdicts.iter().map(|v| v.vendor_load).collect(),
        );
        vb.f64(col::verdicts::VENDOR_CAP, vec![heat::ATS_VENDOR_CAP; n]);
        vb.f64(
            col::verdicts::TENANT_LOAD,
            verdicts.iter().map(|v| v.tenant_load).collect(),
        );
        vb.f64(col::verdicts::TENANT_CAP, vec![heat::ATS_TENANT_CAP; n]);
        vb.u32(
            col::verdicts::COOLDOWN_DAYS,
            verdicts.iter().map(|v| v.cooldown).collect(),
        );
        let notes: Vec<[u32; 2]> = (0..n)
            .map(|i| {
                reuse(
                    arena,
                    prev_notes.get(&pick(&ids, i)).copied(),
                    verdicts[i].note.as_bytes(),
                )
            })
            .collect();
        vb.str(col::verdicts::NOTE, notes);

        // The heat chart.
        let rows_all: Vec<(u32, &heat::ChartRow)> = chart_companies
            .iter()
            .map(|r| (0, r))
            .chain(chart_vendors.iter().map(|r| (1, r)))
            .collect();
        let mut hb = Build::new(table::HEAT_ROWS, rows_all.len());
        hb.u32(
            col::heat_rows::GROUP,
            rows_all.iter().map(|r| r.0).collect(),
        );
        let keys: Vec<[u32; 2]> = rows_all
            .iter()
            .map(|r| arena.put(r.1.key.as_bytes()))
            .collect();
        hb.str(col::heat_rows::KEY, keys);
        let labels: Vec<[u32; 2]> = rows_all
            .iter()
            .map(|r| arena.put(r.1.label.as_bytes()))
            .collect();
        hb.str(col::heat_rows::LABEL, labels);
        hb.f64(
            col::heat_rows::LOAD,
            rows_all.iter().map(|r| r.1.load).collect(),
        );
        hb.f64(
            col::heat_rows::CAP,
            rows_all.iter().map(|r| r.1.cap).collect(),
        );
        hb.f64(
            col::heat_rows::RATIO,
            rows_all.iter().map(|r| r.1.ratio).collect(),
        );
        hb.u32(col::heat_rows::N, rows_all.iter().map(|r| r.1.n).collect());
        hb.u32(
            col::heat_rows::COOLDOWN_DAYS,
            rows_all.iter().map(|r| r.1.cooldown).collect(),
        );
        let sizes: Vec<[u32; 2]> = rows_all
            .iter()
            .map(|r| r.1.size.map_or([0, 0], |s| d.konst(arena, s.name())))
            .collect();
        hb.str(col::heat_rows::SIZE, sizes);

        // The score chart (LifeEv.chart over every job's score_100).
        let total_n: u32 = freq.iter().sum();
        let sum: u64 = freq
            .iter()
            .enumerate()
            .map(|(s, c)| s as u64 * *c as u64)
            .sum();
        let mean = if total_n == 0 {
            f64::NAN
        } else {
            heat::round_to(sum as f64 / total_n as f64, 1)
        };
        let max = (0..=100).rev().find(|&s| freq[s] > 0);
        let min = (0..=100).find(|&s| freq[s] > 0);
        let mut bands = Build::new(table::CHART_BANDS, BANDS.len());
        let bk: Vec<[u32; 2]> = BANDS.iter().map(|b| d.konst(arena, b.0)).collect();
        let bl: Vec<[u32; 2]> = BANDS.iter().map(|b| d.konst(arena, b.1)).collect();
        bands.str(col::chart_bands::KEY, bk);
        bands.str(col::chart_bands::LABEL, bl);
        bands.u32(col::chart_bands::MIN, BANDS.iter().map(|b| b.2).collect());
        bands.u32(col::chart_bands::MAX, BANDS.iter().map(|b| b.3).collect());
        let counts: Vec<u32> = BANDS
            .iter()
            .map(|b| (b.2..=b.3).map(|s| freq[s as usize]).sum())
            .collect();
        bands.f64(
            col::chart_bands::SHARE,
            counts
                .iter()
                .map(|&c| {
                    if total_n == 0 {
                        0.0
                    } else {
                        heat::round_to(c as f64 / total_n as f64, 3)
                    }
                })
                .collect(),
        );
        bands.u32(col::chart_bands::COUNT, counts);
        let mut bins = Build::new(table::CHART_BINS, 10);
        bins.u32(col::chart_bins::LO, (0..10).map(|i| i * 10).collect());
        bins.u32(
            col::chart_bins::HI,
            (0..10)
                .map(|i| if i == 9 { 100 } else { i * 10 + 9 })
                .collect(),
        );
        bins.u32(
            col::chart_bins::COUNT,
            (0..10u32)
                .map(|i| {
                    (i * 10..=if i == 9 { 100 } else { i * 10 + 9 })
                        .map(|s| freq[s as usize])
                        .sum()
                })
                .collect(),
        );

        // The scoreboard.
        let mut sb = Build::new(table::SCORE, 1);
        sb.u32(col::score::FIRE, vec![open_fire as u32]);
        sb.u32(col::score::LEFTOVER_UNIQUE, vec![snapv[0]]);
        sb.u32(col::score::LEFTOVER_NOTED_ON, vec![snapv[1]]);
        sb.u32(col::score::BATCHES_TODAY, vec![queued.len() as u32]);
        sb.u32(col::score::BATCHES_TARGET, vec![snapv[2]]);
        sb.u32(col::score::APPS_TODAY, vec![apps_today]);
        sb.u32(col::score::APPS_TARGET, vec![snapv[3]]);
        sb.u32(col::score::SUBMITTED_TODAY, vec![submitted_today]);
        sb.u32(col::score::CUMULATIVE, vec![cumulative]);
        sb.u32(col::score::TARGET_TOTAL, vec![snapv[4]]);
        let target_on = match snapv[5] {
            NONE => 20_757, // ~D[2026-10-31]
            d => d,
        };
        sb.u32(col::score::TARGET_ON, vec![target_on]);
        sb.u32(col::score::CHART_N, vec![total_n]);
        sb.f64(col::score::CHART_MEAN, vec![mean]);
        sb.f64(
            col::score::CHART_MAX,
            vec![max.map_or(f64::NAN, |m| m as f64)],
        );
        sb.f64(
            col::score::CHART_MIN,
            vec![min.map_or(f64::NAN, |m| m as f64)],
        );

        // Varieties, by ordinal.
        let mut vr = Build::new(table::VARIETIES, batches.len());
        let codes: Vec<[u32; 2]> = batches
            .iter()
            .map(|&r| self_str_ref(&self.overlay, &self.store, bt, col::batches::CODE, r))
            .collect();
        let fires: Vec<&'static str> = batches
            .iter()
            .map(|&r| {
                if self_u32(&self.overlay, &self.store, bt, col::batches::FIRE, r) == 1 {
                    "open_fire"
                } else {
                    "hold"
                }
            })
            .collect();
        let statuses: Vec<[u32; 2]> = batches
            .iter()
            .map(|&r| self_str_ref(&self.overlay, &self.store, bt, col::batches::STATUS, r))
            .collect();
        let labels: Vec<String> = batches
            .iter()
            .map(|&r| {
                let apps = self_u32(
                    &self.overlay,
                    &self.store,
                    bt,
                    col::batches::VARIETY_APPS,
                    r,
                );
                let flags = self_str_ref(
                    &self.overlay,
                    &self.store,
                    bt,
                    col::batches::VARIETY_FLAGS,
                    r,
                );
                variety_label(apps, text(&self.store.arena, flags))
            })
            .collect();
        let arena = &mut self.store.arena;
        vr.str(col::varieties::CODE, codes);
        let fires = fires.into_iter().map(|f| d.konst(arena, f)).collect();
        vr.str(col::varieties::FIRE, fires);
        vr.str(col::varieties::STATUS, statuses);
        let labels = labels.iter().map(|l| arena.put(l.as_bytes())).collect();
        vr.str(col::varieties::LABEL, labels);

        let mut cards = cards.t;
        cards.reindex();
        let mut verdict_t = vb.t;
        verdict_t.reindex();
        for t in [cards, verdict_t, hb.t, bands.t, bins.t, sb.t, vr.t] {
            self.store.put_table(t);
        }
        self.derived = d;
        self.mark_cards_derived();
        true
    }
}

fn self_u32(
    overlay: &[(u16, Column)],
    store: &crate::store::Store,
    t: u16,
    c: u16,
    row: usize,
) -> u32 {
    overlay
        .iter()
        .find(|(ot, oc)| *ot == t && oc.id == c)
        .map(|(_, oc)| oc)
        .or_else(|| store.table(t).and_then(|x| x.col(c)))
        .map_or(0, |c| c.u32(row))
}

fn self_str_ref(
    overlay: &[(u16, Column)],
    store: &crate::store::Store,
    t: u16,
    c: u16,
    row: usize,
) -> [u32; 2] {
    overlay
        .iter()
        .find(|(ot, oc)| *ot == t && oc.id == c)
        .map(|(_, oc)| oc)
        .or_else(|| store.table(t).and_then(|x| x.col(c)))
        .map_or([0, 0], |c| c.str_ref(row))
}

/// Variety.label/1 over the counts and flags the batch row carries.
fn variety_label(apps: u32, flags: &str) -> String {
    if apps == 0 || apps == NONE {
        return String::from("unfilled");
    }
    let known: Vec<&str> = flags
        .split('\u{1f}')
        .filter(|f| FLAGS.contains(f))
        .collect();
    if known.is_empty() {
        String::from("varied")
    } else {
        known.join(", ")
    }
}
