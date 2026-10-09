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
//! A derive is incremental. Writes mark the jobs they touch, split by
//! whether the change can move heat (company, role, URLs, department,
//! squad, fit, stage, stage_on, override) or only the job's own card. A
//! card-only change rewrites that one card row; a heat change rebuilds the
//! heat snapshot and re-judges only the jobs that share a company or an ATS
//! vendor with the job before or after the write, since nothing else reads
//! those loads. Anything that moves the joins (profiles, variants, leases,
//! batches, the day, rows added or removed) derives everything again.
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
use crate::heat::{self, Job, Snapshot, Traits, Verdict};
use crate::keywords;
use crate::store::{Arena, Column, Data, Table};

/// What a derive keeps for the next one, and what moved since.
pub struct Derived {
    /// Per job id: the string references its traits were read from, and
    /// the traits. Valid within one arena epoch.
    traits: BTreeMap<u32, ([u32; 14], Traits)>,
    epoch: u32,
    /// Constant strings put once per arena epoch.
    consts: Vec<(&'static str, [u32; 2])>,
    /// The last derive's verdict per job id.
    verdicts: BTreeMap<u32, Verdict>,
    /// The joins a card reads: job id → (variant label, lineage); profile
    /// ids; leased job ids. Rebuilt by a full derive.
    variant_of: BTreeMap<u32, VariantJoin>,
    /// Lineage id → its theme's targets (U+001F-joined) when the lineage
    /// carries a theme of its own, else None (the variant's theme applies).
    lineage_targets: BTreeMap<u32, Option<[u32; 2]>>,
    /// Per job id: the listing it was extracted from, and its targets.
    extracted: BTreeMap<u32, ([u32; 2], Vec<String>)>,
    /// Lineages whose overlays, and profiles whose items, moved.
    lineages_dirty: Vec<u32>,
    profiles_dirty: Vec<u32>,
    overlay_keys: Vec<u32>,
    item_keys: Vec<u32>,
    /// Bumped whenever any overlay or item moves; a job's glance is kept
    /// while this, its listing and its variant's joins stay the same.
    corpus_gen: u32,
    corpus: Option<(u32, Corpus)>,
    glances: BTreeMap<u32, ([u32; 6], [u32; 5])>,
    profiles: Vec<u32>,
    leased: Vec<u32>,
    /// Since the last derive: everything, or these jobs.
    all: bool,
    heat: Vec<u32>,
    card: Vec<u32>,
}

impl Derived {
    pub const fn new() -> Derived {
        Derived {
            traits: BTreeMap::new(),
            epoch: u32::MAX,
            consts: Vec::new(),
            verdicts: BTreeMap::new(),
            variant_of: BTreeMap::new(),
            lineage_targets: BTreeMap::new(),
            extracted: BTreeMap::new(),
            lineages_dirty: Vec::new(),
            profiles_dirty: Vec::new(),
            overlay_keys: Vec::new(),
            item_keys: Vec::new(),
            corpus_gen: 0,
            corpus: None,
            glances: BTreeMap::new(),
            profiles: Vec::new(),
            leased: Vec::new(),
            all: true,
            heat: Vec::new(),
            card: Vec::new(),
        }
    }

    fn konst(&mut self, arena: &mut Arena, s: &'static str) -> [u32; 2] {
        self.check_epoch(arena);
        if let Some((_, r)) = self.consts.iter().find(|(k, _)| *k == s) {
            return *r;
        }
        let r = arena.put(s.as_bytes());
        self.consts.push((s, r));
        r
    }

    fn check_epoch(&mut self, arena: &Arena) {
        if self.epoch != arena.epoch {
            self.consts.clear();
            self.traits.clear();
            self.extracted.clear();
            self.glances.clear();
            self.epoch = arena.epoch;
            // The cached joins hold string references of the old epoch.
            self.all = true;
        }
    }

    /// Notes that row `key` of table `t` moved (column `c`, when known).
    pub fn mark(&mut self, t: u16, key: u32, c: Option<u16>) {
        match t {
            table::JOB_APPS => match c {
                Some(c) if !heat_column(c) => self.card.push(key),
                _ => self.heat.push(key),
            },
            table::BATCHES
            | table::PROFILES
            | table::CV_VARIANTS
            | table::CV_LINEAGES
            | table::LEASES
            | table::SCOREBOARD_SNAPSHOTS => self.all = true,
            table::OVERLAYS => self.overlay_keys.push(key),
            table::ITEMS => self.item_keys.push(key),
            NONE_TABLE => self.all = true,
            _ => {}
        }
    }

    /// An overlay of `lineage` moved (for a deletion, read before it goes).
    pub fn mark_lineage(&mut self, lineage: u32) {
        self.lineages_dirty.push(lineage);
    }

    pub fn mark_all(&mut self) {
        self.all = true;
    }
}

const NONE_TABLE: u16 = u16::MAX;

/// What a card reads from the job's variant.
#[derive(Clone, Copy)]
struct VariantJoin {
    label: [u32; 2],
    lineage: u32,
    profile: u32,
    /// The variant theme's targets, U+001F-joined.
    targets: [u32; 2],
}

/// The overlays and items a CV is composed from, indexed once, and the
/// visible texts built from them; kept until an overlay or item moves.
pub(crate) struct Corpus {
    /// Lineage → its overlays: (item, mode 0 hidden 1 altered 2
    /// emphasized, title, body).
    overlays: BTreeMap<u32, Vec<(u32, u8, [u32; 2], [u32; 2])>>,
    /// (id, profile, title, body) of every item.
    items: Vec<(u32, u32, [u32; 2], [u32; 2])>,
    /// (profile, lineage) → the downcased text that CV shows.
    texts: BTreeMap<(u32, u32), keywords::Text>,
}

/// The job_apps columns the heat governor reads.
fn heat_column(c: u16) -> bool {
    use col::job_apps as j;
    matches!(
        c,
        j::COMPANY
            | j::ROLE
            | j::LISTING_URL
            | j::CANONICAL_URL
            | j::DEPARTMENT
            | j::SQUAD
            | j::FIT
            | j::CURRENT_STAGE
            | j::STAGE_ON
            | j::HEAT_OVERRIDE
            | j::HEAT_OVERRIDE_REASON
    )
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

fn ix_of(list: &[&str], s: &[u8]) -> u32 {
    list.iter().position(|x| x.as_bytes() == s).unwrap_or(0) as u32
}

// ---- rows of the derived tables -------------------------------------------

use col::cards as c;
use col::verdicts as v;

const CARD_U32: [u16; 20] = [
    c::ID,
    c::SCORE,
    c::HEAT,
    c::STAGE,
    c::STATUS,
    c::FRESHNESS,
    c::GATE,
    c::BATCH,
    c::PROFILE,
    c::HITS,
    c::TOTAL,
    c::HIDDEN,
    c::ALTERED,
    c::EMPHASIZED,
    c::STAGE_ON,
    c::NEXT_DUE,
    c::HEAT_STATE,
    c::LOAD_PCT,
    c::COOLDOWN,
    c::LEASED,
];
const CARD_STR: [u16; 8] = [
    c::COMPANY,
    c::ROLE,
    c::LOCATION,
    c::NEXT_ACTION,
    c::CV_LABEL,
    c::FIT,
    c::PIPS,
    c::ATS_VENDOR,
];
const CARD_F64: [u16; 3] = [c::LOAD, c::CAP, c::RATIO];

const VERDICT_U32: [u16; 3] = [v::ID, v::HAS_TENANT, v::COOLDOWN_DAYS];
const VERDICT_STR: [u16; 7] = [
    v::DECISION,
    v::REASON,
    v::COMPANY,
    v::SIZE,
    v::ATS_VENDOR,
    v::ATS_TENANT,
    v::NOTE,
];
const VERDICT_F64: [u16; 7] = [
    v::COMPANY_LOAD,
    v::COMPANY_CAP,
    v::COMPANY_INCREMENT,
    v::VENDOR_LOAD,
    v::VENDOR_CAP,
    v::TENANT_LOAD,
    v::TENANT_CAP,
];

/// One row of a derived table, column values in the order of its id lists.
struct Row<const U: usize, const S: usize, const F: usize> {
    u: [u32; U],
    s: [[u32; 2]; S],
    f: [f64; F],
}

fn build<const U: usize, const S: usize, const F: usize>(
    id: u16,
    (cu, cs, cf): (&[u16; U], &[u16; S], &[u16; F]),
    rows: &[Row<U, S, F>],
) -> Table {
    let mut t = Table::new(id);
    t.n = rows.len();
    for (k, &cid) in cu.iter().enumerate() {
        t.cols.push(Column {
            id: cid,
            ty: U32,
            data: Data::W32(rows.iter().map(|r| r.u[k]).collect()),
        });
    }
    for (k, &cid) in cs.iter().enumerate() {
        t.cols.push(Column {
            id: cid,
            ty: STR,
            data: Data::Str(rows.iter().map(|r| r.s[k]).collect()),
        });
    }
    for (k, &cid) in cf.iter().enumerate() {
        t.cols.push(Column {
            id: cid,
            ty: F64,
            data: Data::W64(rows.iter().map(|r| r.f[k].to_bits()).collect()),
        });
    }
    t.reindex();
    t
}

/// Writes a row over row `at` of `t`. Returns whether anything moved.
fn patch<const U: usize, const S: usize, const F: usize>(
    t: &mut Table,
    at: usize,
    (cu, cs, cf): (&[u16; U], &[u16; S], &[u16; F]),
    r: &Row<U, S, F>,
    arena: &Arena,
) -> bool {
    let mut moved = false;
    for col in t.cols.iter_mut() {
        match &mut col.data {
            Data::W32(d) => {
                if let Some(k) = cu.iter().position(|&x| x == col.id) {
                    moved |= d[at] != r.u[k];
                    d[at] = r.u[k];
                }
            }
            Data::Str(d) => {
                if let Some(k) = cs.iter().position(|&x| x == col.id) {
                    moved |= d[at] != r.s[k] && arena.get(d[at]) != arena.get(r.s[k]);
                    d[at] = r.s[k];
                }
            }
            Data::W64(d) => {
                if let Some(k) = cf.iter().position(|&x| x == col.id) {
                    moved |= d[at] != r.f[k].to_bits();
                    d[at] = r.f[k].to_bits();
                }
            }
        }
    }
    moved
}

/// A string for a derived column: the previous bytes when they are the
/// same, else new bytes in the arena.
fn reuse(arena: &mut Arena, prev: Option<[u32; 2]>, s: &[u8]) -> [u32; 2] {
    match prev {
        Some(p) if arena.get(p) == s => p,
        _ => arena.put(s),
    }
}

/// The job_apps columns a card reads, as slices of the view.
struct JobCols<'a> {
    id: &'a [u32],
    score: &'a [u32],
    heat: &'a [u32],
    batch: &'a [u32],
    profile: &'a [u32],
    listing: &'a [[u32; 2]],
    stage_on: &'a [u32],
    next_due: &'a [u32],
    company: &'a [[u32; 2]],
    role: &'a [[u32; 2]],
    location: &'a [[u32; 2]],
    next_action: &'a [[u32; 2]],
    fit: &'a [[u32; 2]],
    pips: &'a [[u32; 2]],
    stage: &'a [[u32; 2]],
    status: &'a [[u32; 2]],
    freshness: &'a [[u32; 2]],
    gate: &'a [[u32; 2]],
}

impl Desk {
    fn job_cols(&self) -> JobCols<'_> {
        use col::job_apps as j;
        let t = table::JOB_APPS;
        JobCols {
            id: self.w32(t, j::ID),
            score: self.w32(t, j::SCORE_100),
            heat: self.w32(t, j::HEAT),
            batch: self.w32(t, j::BATCH_ID),
            profile: self.w32(t, j::PROFILE_ID),
            listing: self.strs(t, j::LISTING),
            stage_on: self.w32(t, j::STAGE_ON),
            next_due: self.w32(t, j::NEXT_DUE),
            company: self.strs(t, j::COMPANY),
            role: self.strs(t, j::ROLE),
            location: self.strs(t, j::LOCATION),
            next_action: self.strs(t, j::NEXT_ACTION),
            fit: self.strs(t, j::FIT),
            pips: self.strs(t, j::PIPS),
            stage: self.strs(t, j::CURRENT_STAGE),
            status: self.strs(t, j::STATUS),
            freshness: self.strs(t, j::FRESHNESS),
            gate: self.strs(t, j::GATE),
        }
    }

    /// The job_apps rows of the view as the governor reads them, in row
    /// order, with their traits (cached per job while its text holds).
    fn heat_rows<'d>(&self, d: &'d mut Derived) -> (Vec<Job<'_>>, Vec<&'d Traits>) {
        let jt = table::JOB_APPS;
        let n = self.rows(jt);
        let arena = &self.store.arena;
        let s = |c: u16| self.strs(jt, c);
        let u = |c: u16| self.w32(jt, c);
        let at = |v: &[[u32; 2]], i: usize| v.get(i).copied().unwrap_or([0, 0]);
        let w = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0);
        use col::job_apps as j;
        let (ids, company, role, listing, canonical, department, squad, fit) = (
            u(j::ID),
            s(j::COMPANY),
            s(j::ROLE),
            s(j::LISTING_URL),
            s(j::CANONICAL_URL),
            s(j::DEPARTMENT),
            s(j::SQUAD),
            s(j::FIT),
        );
        let (stage, stage_on, score, ho, hor) = (
            s(j::CURRENT_STAGE),
            u(j::STAGE_ON),
            u(j::SCORE_100),
            u(j::HEAT_OVERRIDE),
            s(j::HEAT_OVERRIDE_REASON),
        );
        let jobs: Vec<Job> = (0..n)
            .map(|i| Job {
                id: w(ids, i),
                company: arena.text(at(company, i)),
                role: arena.text(at(role, i)),
                listing_url: arena.text(at(listing, i)),
                canonical_url: arena.text(at(canonical, i)),
                department: arena.text(at(department, i)),
                squad: arena.text(at(squad, i)),
                fit: arena.text(at(fit, i)),
                stage: heat::stage_ix(arena.text(at(stage, i))),
                stage_on: stage_on.get(i).copied().unwrap_or(NONE),
                score: match w(score, i) {
                    NONE => 0,
                    v => v,
                },
                heat_override: w(ho, i) == 1,
                heat_override_reason: arena.text(at(hor, i)),
            })
            .collect();
        d.check_epoch(arena);
        let keys: Vec<[u32; 14]> = (0..n)
            .map(|i| {
                let mut k = [0u32; 14];
                for (x, c) in [company, role, listing, canonical, department, squad, fit]
                    .iter()
                    .enumerate()
                {
                    k[2 * x..2 * x + 2].copy_from_slice(&at(c, i));
                }
                k
            })
            .collect();
        for i in 0..n {
            let fresh = !matches!(d.traits.get(&jobs[i].id), Some((k, _)) if *k == keys[i]);
            if fresh {
                d.traits
                    .insert(jobs[i].id, (keys[i], heat::traits(&jobs[i])));
            }
        }
        let d: &'d Derived = d;
        let tr = jobs.iter().map(|j| &d.traits[&j.id].1).collect();
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

    /// The card a job row shows, with its verdict painted on.
    fn card_row(
        &self,
        d: &Derived,
        j: &JobCols,
        i: usize,
        verdict: &Verdict,
        vnames: &[[u32; 2]],
        glance: [u32; 5],
    ) -> Row<20, 8, 3> {
        let w = |s: &[u32]| s.get(i).copied().unwrap_or(0);
        let r = |s: &[[u32; 2]]| s.get(i).copied().unwrap_or([0, 0]);
        let arena = &self.store.arena;
        let id = w(j.id);
        let none0 = |x: u32| if x == NONE { 0 } else { x };
        let load_pct = if verdict.company_cap <= 0.0 {
            100
        } else {
            heat::round0(verdict.company_load / verdict.company_cap * 100.0) as u32
        };
        Row {
            u: [
                id,
                none0(w(j.score)),
                w(j.heat),
                heat::stage_ix(arena.text(r(j.stage))).unwrap_or(0) as u32,
                ix_of(&STATUSES, arena.get(r(j.status))),
                ix_of(&FRESHNESS, arena.get(r(j.freshness))),
                ix_of(&GATES, arena.get(r(j.gate))),
                none0(w(j.batch)),
                w(j.profile),
                glance[0],
                glance[1],
                glance[2],
                glance[3],
                glance[4],
                j.stage_on.get(i).copied().unwrap_or(NONE),
                j.next_due.get(i).copied().unwrap_or(NONE),
                verdict.heat_state(),
                load_pct,
                verdict.cooldown,
                d.leased.binary_search(&id).is_ok() as u32,
            ],
            s: [
                r(j.company),
                r(j.role),
                r(j.location),
                r(j.next_action),
                d.variant_of.get(&id).map_or([0, 0], |v| v.label),
                r(j.fit),
                r(j.pips),
                vnames[verdict.vendor as usize],
            ],
            f: [
                verdict.company_load,
                verdict.company_cap,
                heat::ratio(verdict.company_load, verdict.company_cap),
            ],
        }
    }

    /// What a card counts of its CV: keyword hits and targets, and the
    /// hidden, altered and emphasized overlays on its lineage, as Desk's
    /// glance refresh counted them (Mask.apply, Theme lineage over variant,
    /// Keywords targets and coverage).
    fn glance(
        &self,
        d: &mut Derived,
        corpus: &mut Option<Corpus>,
        j: &JobCols,
        i: usize,
    ) -> [u32; 5] {
        let id = j.id.get(i).copied().unwrap_or(0);
        let Some(v) = d.variant_of.get(&id).copied() else {
            return [0; 5];
        };
        let listing = j.listing.get(i).copied().unwrap_or([0, 0]);
        let inputs = [
            d.corpus_gen,
            listing[0],
            listing[1],
            v.lineage,
            v.profile,
            v.targets[0],
        ];
        if let Some((k, out)) = d.glances.get(&id) {
            if *k == inputs {
                return *out;
            }
        }
        let arena = &self.store.arena;
        let c = corpus.get_or_insert_with(|| self.read_corpus());
        let mut counts = [0u32; 3];
        for o in c.overlays.get(&v.lineage).map_or(&[][..], |o| o.as_slice()) {
            counts[o.1 as usize] += 1;
        }
        let key = ensure_text(arena, c, v.profile, v.lineage);
        let text = &c.texts[&key];
        let theme = match d.lineage_targets.get(&v.lineage) {
            Some(Some(t)) => *t,
            _ => v.targets,
        };
        let themed = keywords::theme_targets(arena.text(theme));
        let (hits, total) = if !themed.is_empty() {
            let hits = themed
                .iter()
                .filter(|t| text.hit(&heat::downcase(t)))
                .count();
            (hits, themed.len())
        } else {
            // Extracted words are already lowercase.
            let fresh = !matches!(d.extracted.get(&id), Some((l, _)) if *l == listing);
            if fresh {
                d.extracted
                    .insert(id, (listing, keywords::extract(arena.text(listing))));
            }
            let words = &d.extracted[&id].1;
            (words.iter().filter(|t| text.hit(t)).count(), words.len())
        };
        let out = [hits as u32, total as u32, counts[0], counts[1], counts[2]];
        d.glances.insert(id, (inputs, out));
        out
    }

    fn read_corpus(&self) -> Corpus {
        let (ot, it) = (table::OVERLAYS, table::ITEMS);
        let mut overlays: BTreeMap<u32, Vec<(u32, u8, [u32; 2], [u32; 2])>> = BTreeMap::new();
        let s = |t: u16, c: u16, r: usize| self.strs(t, c).get(r).copied().unwrap_or([0, 0]);
        for r in 0..self.rows(ot) {
            let mode = match self.vstr(ot, col::overlays::MODE, r) {
                b"hidden" => 0,
                b"altered" => 1,
                b"emphasized" => 2,
                _ => continue,
            };
            overlays
                .entry(self.vu32(ot, col::overlays::LINEAGE_ID, r))
                .or_default()
                .push((
                    self.vu32(ot, col::overlays::ITEM_ID, r),
                    mode,
                    s(ot, col::overlays::TITLE, r),
                    s(ot, col::overlays::BODY, r),
                ));
        }
        let items = (0..self.rows(it))
            .map(|r| {
                (
                    self.vu32(it, col::items::ID, r),
                    self.vu32(it, col::items::PROFILE_ID, r),
                    s(it, col::items::TITLE, r),
                    s(it, col::items::BODY, r),
                )
            })
            .collect();
        Corpus {
            overlays,
            items,
            texts: BTreeMap::new(),
        }
    }

    /// Does the job get a card: a profile and a variant (the inner joins).
    fn has_card(&self, d: &Derived, j: &JobCols, i: usize) -> bool {
        let id = j.id.get(i).copied().unwrap_or(0);
        let p = j.profile.get(i).copied().unwrap_or(0);
        d.variant_of.contains_key(&id) && d.profiles.binary_search(&p).is_ok()
    }

    fn rebuild_joins(&self, d: &mut Derived) {
        let vt = table::CV_VARIANTS;
        use col::cv_variants as cv;
        let (vjob, vlabel, vlin, vprof, vtar) = (
            self.w32(vt, cv::JOB_APP_ID),
            self.strs(vt, cv::LABEL),
            self.w32(vt, cv::LINEAGE_ID),
            self.w32(vt, cv::PROFILE_ID),
            self.strs(vt, cv::THEME_TARGETS),
        );
        let s = |v: &[[u32; 2]], r: usize| v.get(r).copied().unwrap_or([0, 0]);
        let u = |v: &[u32], r: usize| v.get(r).copied().unwrap_or(0);
        d.variant_of.clear();
        for r in 0..self.rows(vt) {
            if let Some(&job) = vjob.get(r) {
                d.variant_of.entry(job).or_insert(VariantJoin {
                    label: s(vlabel, r),
                    lineage: u(vlin, r),
                    profile: u(vprof, r),
                    targets: s(vtar, r),
                });
            }
        }
        // A lineage's theme wins when it is a non-empty map (theme_of/1).
        let lt = table::CV_LINEAGES;
        let arena = &self.store.arena;
        let (lid, ltheme, ltar) = (
            self.w32(lt, col::cv_lineages::ID),
            self.strs(lt, col::cv_lineages::THEME),
            self.strs(lt, col::cv_lineages::THEME_TARGETS),
        );
        d.lineage_targets.clear();
        for r in 0..self.rows(lt) {
            let theme = arena.get(s(ltheme, r));
            let own = !(theme.is_empty() || theme == b"{}" || theme == b"null");
            d.lineage_targets.insert(u(lid, r), own.then(|| s(ltar, r)));
        }
        d.profiles = self.w32(table::PROFILES, col::profiles::ID).to_vec();
        d.profiles.sort_unstable();
        d.leased = self.w32(table::LEASES, col::leases::ID).to_vec();
        d.leased.sort_unstable();
    }

    /// Re-derives the views the dirty rows reach. Returns whether it ran.
    pub fn derive(&mut self) -> bool {
        if !self.raw_dirty || self.store.table(table::JOB_APPS).is_none() {
            return false;
        }
        self.raw_dirty = false;
        let mut d = core::mem::replace(&mut self.derived, Derived::new());
        d.check_epoch(&self.store.arena);
        let jt = table::JOB_APPS;
        // A job that is new, gone, or crosses the card joins re-derives all.
        let mut all = d.all
            || self.store.table(table::CARDS).is_none()
            || self.store.table(table::VERDICTS).is_none();
        if !all {
            let cards = self.store.table(table::CARDS);
            all = d
                .heat
                .iter()
                .chain(d.card.iter())
                .any(|&id| match self.row_of(jt, id) {
                    None => true,
                    Some(i) => {
                        let j = self.job_cols();
                        !d.verdicts.contains_key(&id)
                            || self.has_card(&d, &j, i)
                                != cards.is_some_and(|t| t.row_of(id).is_some())
                    }
                });
        }
        // Overlays and items that moved reach the cards on their lineage or
        // profile; one whose row is gone cannot say where it was.
        for k in core::mem::take(&mut d.overlay_keys) {
            let ot = table::OVERLAYS;
            match self.row_of(ot, k) {
                Some(r) => d
                    .lineages_dirty
                    .push(self.vu32(ot, col::overlays::LINEAGE_ID, r)),
                None => all = true,
            }
        }
        for k in core::mem::take(&mut d.item_keys) {
            let it = table::ITEMS;
            match self
                .row_of(it, k)
                .map(|r| self.vu32(it, col::items::PROFILE_ID, r))
            {
                Some(p) if p != NONE && p != 0 => d.profiles_dirty.push(p),
                _ => all = true,
            }
        }
        if all || !d.lineages_dirty.is_empty() || !d.profiles_dirty.is_empty() {
            d.corpus_gen = d.corpus_gen.wrapping_add(1);
        }
        if all {
            self.rebuild_joins(&mut d);
        } else if !d.lineages_dirty.is_empty() || !d.profiles_dirty.is_empty() {
            let reach: Vec<u32> = d
                .variant_of
                .iter()
                .filter(|(_, v)| {
                    d.lineages_dirty.contains(&v.lineage) || d.profiles_dirty.contains(&v.profile)
                })
                .map(|(job, _)| *job)
                .collect();
            d.card.extend(reach);
        }
        d.lineages_dirty.clear();
        d.profiles_dirty.clear();
        let today = if self.today == NONE { 0 } else { self.today };
        let mut heat_moved = all || !d.heat.is_empty();

        // ---- heat: judge the jobs a write can reach -------------------------
        // Old traits of heat-dirty jobs, before the cache refreshes.
        let mut reach_keys: Vec<String> = Vec::new();
        let mut reach_vendors: Vec<u8> = Vec::new();
        for id in &d.heat {
            if let Some((_, t)) = d.traits.get(id) {
                reach_keys.push(t.key.clone());
                reach_vendors.push(t.ats.vendor);
            }
        }
        let mut cache = core::mem::take(&mut d.verdicts);
        let card_dirty: Vec<u32> = core::mem::take(&mut d.card);
        let heat_dirty: Vec<u32> = core::mem::take(&mut d.heat);
        let (changed_jobs, chart): (
            Vec<usize>,
            Option<(Vec<heat::ChartRow>, Vec<heat::ChartRow>)>,
        ) = if !heat_moved {
            // A card-only write: its rows, painted with the verdicts they had.
            let mut targets: Vec<usize> = card_dirty
                .iter()
                .filter_map(|&id| self.row_of(jt, id))
                .collect();
            targets.sort_unstable();
            targets.dedup();
            (targets, None)
        } else {
            let (jobs, tr) = self.heat_rows(&mut d);
            let n = jobs.len();
            let mut targets: Vec<usize> = Vec::new();
            let mut chart = None;
            if heat_moved {
                let owned = &tr;
                let snap = Snapshot::build(&jobs, owned, today);
                let judge: Vec<usize> = if all {
                    (0..n).collect()
                } else {
                    for &id in &heat_dirty {
                        if let Some(i) = self.row_of(jt, id) {
                            reach_keys.push(owned[i].key.clone());
                            reach_vendors.push(owned[i].ats.vendor);
                        }
                    }
                    (0..n)
                        .filter(|&i| {
                            reach_keys.iter().any(|k| *k == owned[i].key)
                                || (owned[i].ats.vendor != heat::UNKNOWN
                                    && reach_vendors.contains(&owned[i].ats.vendor))
                                || heat_dirty.contains(&jobs[i].id)
                        })
                        .collect()
                };
                for &i in &judge {
                    cache.insert(jobs[i].id, snap.verdict(&jobs, owned, i, today));
                }
                targets = judge;
                chart = Some(snap.chart(&jobs));
            }
            for &id in &card_dirty {
                if let Some(i) = self.row_of(jt, id) {
                    targets.push(i);
                }
            }
            targets.sort_unstable();
            targets.dedup();
            (targets, chart)
        };
        if all {
            cache.retain(|id, _| self.row_of(jt, *id).is_some());
        }
        d.verdicts = cache;
        // Only rows that have an id and a verdict can be written (a frame
        // that dropped the id column leaves rows with neither).
        let changed_jobs: Vec<usize> = {
            let ids = self.w32(jt, col::job_apps::ID);
            changed_jobs
                .into_iter()
                .filter(|&i| ids.get(i).is_some_and(|id| d.verdicts.contains_key(id)))
                .collect()
        };

        // ---- write cards and verdicts ------------------------------------
        let arena_mut = &mut self.store.arena;
        let vnames: Vec<[u32; 2]> = heat::VENDORS
            .iter()
            .map(|x| d.konst(arena_mut, x))
            .collect();
        let allow = d.konst(arena_mut, "allow");
        let defer = d.konst(arena_mut, "defer");
        let reasons: Vec<[u32; 2]> = [
            heat::Reason::Ok,
            heat::Reason::Override,
            heat::Reason::CompanyCap,
            heat::Reason::AtsVendorCap,
            heat::Reason::AtsTenantCap,
            heat::Reason::AtsBatchCap,
        ]
        .iter()
        .map(|r| d.konst(arena_mut, r.name()))
        .collect();
        let sizes: Vec<[u32; 2]> = [
            heat::Size::Mega,
            heat::Size::Large,
            heat::Size::Mid,
            heat::Size::Small,
        ]
        .iter()
        .map(|s| d.konst(arena_mut, s.name()))
        .collect();
        // Strings each verdict row needs that are not constants: tenant and
        // note, reusing the previous row's bytes when they hold.
        let prev = self.store.table(table::VERDICTS);
        let prev_str = |id: u32, c: u16| prev.and_then(|t| Some(t.col(c)?.str_ref(t.row_of(id)?)));
        let mut texts: Vec<(u32, Option<[u32; 2]>, Option<[u32; 2]>)> =
            Vec::with_capacity(changed_jobs.len());
        {
            let ids = self.w32(jt, col::job_apps::ID);
            for &i in &changed_jobs {
                let id = ids[i];
                texts.push((id, prev_str(id, v::ATS_TENANT), prev_str(id, v::NOTE)));
            }
        }
        let mut tn: Vec<([u32; 2], [u32; 2])> = Vec::with_capacity(texts.len());
        for (id, pt, pn) in texts {
            let ver = &d.verdicts[&id];
            let arena = &mut self.store.arena;
            let t = reuse(arena, pt, ver.tenant.as_deref().unwrap_or("").as_bytes());
            let n = reuse(arena, pn, ver.note.as_bytes());
            tn.push((t, n));
        }
        let mut verdict_rows: Vec<Row<3, 7, 7>> = Vec::with_capacity(changed_jobs.len());
        let mut card_rows: Vec<(u32, Row<20, 8, 3>)> = Vec::new();
        let generation = d.corpus_gen;
        let mut corpus: Option<Corpus> = d
            .corpus
            .take()
            .filter(|(g, _)| *g == generation)
            .map(|(_, c)| c);
        {
            let j = self.job_cols();
            for (k, &i) in changed_jobs.iter().enumerate() {
                let id = j.id[i];
                let ver = &d.verdicts[&id];
                verdict_rows.push(Row {
                    u: [id, ver.tenant.is_some() as u32, ver.cooldown],
                    s: [
                        if ver.allow { allow } else { defer },
                        reasons[ver.reason as usize],
                        j.company.get(i).copied().unwrap_or([0, 0]),
                        sizes[ver.size as usize],
                        vnames[ver.vendor as usize],
                        tn[k].0,
                        tn[k].1,
                    ],
                    f: [
                        ver.company_load,
                        ver.company_cap,
                        ver.company_increment,
                        ver.vendor_load,
                        heat::ATS_VENDOR_CAP,
                        ver.tenant_load,
                        heat::ATS_TENANT_CAP,
                    ],
                });
                if self.has_card(&d, &j, i) {
                    let glance = self.glance(&mut d, &mut corpus, &j, i);
                    let ver = &d.verdicts[&id];
                    card_rows.push((id, self.card_row(&d, &j, i, ver, &vnames, glance)));
                }
            }
        }
        d.corpus = corpus.map(|c| (generation, c));
        let cards_cols = (&CARD_U32, &CARD_STR, &CARD_F64);
        let verdict_cols = (&VERDICT_U32, &VERDICT_STR, &VERDICT_F64);
        if all {
            let rows: Vec<Row<20, 8, 3>> = card_rows.into_iter().map(|(_, r)| r).collect();
            let cards = build(table::CARDS, cards_cols, &rows);
            let verdicts = build(table::VERDICTS, verdict_cols, &verdict_rows);
            for t in [cards, verdicts] {
                let keys = changed_rows(self.store.table(t.id), &t, &self.store.arena);
                self.touched
                    .extend(keys.into_iter().map(|k| [t.id as u32, k]));
                self.store.put_table(t);
            }
            self.mark_cards_derived();
        } else {
            for (id, row) in card_rows {
                let arena = core::mem::take(&mut self.store.arena);
                let t = self.store.table_mut(table::CARDS);
                let at = t.row_of(id).unwrap_or(0);
                if patch(t, at, cards_cols, &row, &arena) {
                    self.touched.push([table::CARDS as u32, id]);
                    self.card_moved(at as u32);
                }
                self.store.arena = arena;
            }
            for row in verdict_rows {
                let id = row.u[0];
                let arena = core::mem::take(&mut self.store.arena);
                let t = self.store.table_mut(table::VERDICTS);
                let at = t.row_of(id).unwrap_or(0);
                if patch(t, at, verdict_cols, &row, &arena) {
                    self.touched.push([table::VERDICTS as u32, id]);
                }
                self.store.arena = arena;
            }
        }

        // ---- the heat chart, scoreboard and score chart ---------------------
        let mut small: Vec<Table> = Vec::new();
        if let Some((companies, vendors)) = chart {
            small.push(self.chart_table(&mut d, &companies, &vendors));
        }
        heat_moved |= all;
        let _ = heat_moved;
        small.extend(self.score_tables(&mut d, today));
        for t in small {
            let same = self
                .store
                .table(t.id)
                .is_some_and(|o| same_table(o, &t, &self.store.arena));
            if !same {
                self.touched.push([t.id as u32, NONE]);
                self.store.put_table(t);
            }
        }
        d.all = false;
        self.derived = d;
        true
    }

    fn chart_table(
        &mut self,
        d: &mut Derived,
        companies: &[heat::ChartRow],
        vendors: &[heat::ChartRow],
    ) -> Table {
        let rows: Vec<(u32, &heat::ChartRow)> = companies
            .iter()
            .map(|r| (0, r))
            .chain(vendors.iter().map(|r| (1, r)))
            .collect();
        let prev = self.store.table(table::HEAT_ROWS);
        let prev_ref = |c: u16, i: usize| {
            prev.and_then(|t| (i < t.n).then(|| t.col(c).map(|x| x.str_ref(i))).flatten())
        };
        let prev: Vec<(Option<[u32; 2]>, Option<[u32; 2]>)> = (0..rows.len())
            .map(|i| {
                (
                    prev_ref(col::heat_rows::KEY, i),
                    prev_ref(col::heat_rows::LABEL, i),
                )
            })
            .collect();
        let arena = &mut self.store.arena;
        let mut t = Table::new(table::HEAT_ROWS);
        t.n = rows.len();
        let mut push = |cid: u16, ty: u8, data: Data| t.cols.push(Column { id: cid, ty, data });
        push(
            col::heat_rows::GROUP,
            U32,
            Data::W32(rows.iter().map(|r| r.0).collect()),
        );
        let keys = rows
            .iter()
            .enumerate()
            .map(|(i, r)| reuse(arena, prev[i].0, r.1.key.as_bytes()))
            .collect();
        push(col::heat_rows::KEY, STR, Data::Str(keys));
        let labels = rows
            .iter()
            .enumerate()
            .map(|(i, r)| reuse(arena, prev[i].1, r.1.label.as_bytes()))
            .collect();
        push(col::heat_rows::LABEL, STR, Data::Str(labels));
        push(
            col::heat_rows::LOAD,
            F64,
            Data::W64(rows.iter().map(|r| r.1.load.to_bits()).collect()),
        );
        push(
            col::heat_rows::CAP,
            F64,
            Data::W64(rows.iter().map(|r| r.1.cap.to_bits()).collect()),
        );
        push(
            col::heat_rows::RATIO,
            F64,
            Data::W64(rows.iter().map(|r| r.1.ratio.to_bits()).collect()),
        );
        push(
            col::heat_rows::N,
            U32,
            Data::W32(rows.iter().map(|r| r.1.n).collect()),
        );
        push(
            col::heat_rows::COOLDOWN_DAYS,
            U32,
            Data::W32(rows.iter().map(|r| r.1.cooldown).collect()),
        );
        let sizes = rows
            .iter()
            .map(|r| r.1.size.map_or([0, 0], |s| d.konst(arena, s.name())))
            .collect();
        push(col::heat_rows::SIZE, STR, Data::Str(sizes));
        t
    }

    /// Campaign.scoreboard/1 and LifeEv.chart over every job's score_100.
    fn score_tables(&mut self, d: &mut Derived, today: u32) -> Vec<Table> {
        let jt = table::JOB_APPS;
        let n = self.rows(jt);
        let w = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0);
        let (score, batch_id, stage_on) = (
            self.w32(jt, col::job_apps::SCORE_100),
            self.w32(jt, col::job_apps::BATCH_ID),
            self.w32(jt, col::job_apps::STAGE_ON),
        );
        let stages = self.strs(jt, col::job_apps::CURRENT_STAGE);
        let mut freq = [0u32; 101];
        for i in 0..n {
            let s = match w(score, i) {
                NONE => 0,
                v => v.min(100),
            };
            freq[s as usize] += 1;
        }
        let bt = table::BATCHES;
        let mut batches: Vec<usize> = (0..self.rows(bt)).collect();
        // By ordinal, ties in row order (as the database returns them).
        crate::store::sort_usize(&mut batches, &|a, b| {
            self.vu32(bt, col::batches::ORDINAL, a)
                .cmp(&self.vu32(bt, col::batches::ORDINAL, b))
                .then(a.cmp(&b))
        });
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
        let apps_today = (0..n).filter(|&i| queued.contains(&w(batch_id, i))).count() as u32;
        let arena = &self.store.arena;
        let sent = |i: usize| {
            heat::stage_ix(arena.text(stages.get(i).copied().unwrap_or([0, 0])))
                .is_some_and(|s| SENT.contains(&s))
        };
        let submitted_today = (0..n)
            .filter(|&i| sent(i) && stage_on.get(i).copied() == Some(today))
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
        let variety: Vec<([u32; 2], bool, [u32; 2], String)> = batches
            .iter()
            .map(|&r| {
                let flags = self.vstr(bt, col::batches::VARIETY_FLAGS, r);
                (
                    self.strs(bt, col::batches::CODE)
                        .get(r)
                        .copied()
                        .unwrap_or([0, 0]),
                    self.vu32(bt, col::batches::FIRE, r) == 1,
                    self.strs(bt, col::batches::STATUS)
                        .get(r)
                        .copied()
                        .unwrap_or([0, 0]),
                    variety_label(
                        self.vu32(bt, col::batches::VARIETY_APPS, r),
                        core::str::from_utf8(flags).unwrap_or(""),
                    ),
                )
            })
            .collect();
        let prev_labels: Vec<[u32; 2]> = self
            .store
            .table(table::VARIETIES)
            .and_then(|t| t.col(col::varieties::LABEL))
            .map_or(Vec::new(), |c| match &c.data {
                Data::Str(v) => v.clone(),
                _ => Vec::new(),
            });

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
        let arena = &mut self.store.arena;
        let mut out = Vec::new();

        let mut sb = Table::new(table::SCORE);
        sb.n = 1;
        let u = |cid: u16, x: u32| Column {
            id: cid,
            ty: U32,
            data: Data::W32(vec![x]),
        };
        let f = |cid: u16, x: f64| Column {
            id: cid,
            ty: F64,
            data: Data::W64(vec![x.to_bits()]),
        };
        use col::score as s;
        sb.cols = vec![
            u(s::FIRE, open_fire as u32),
            u(s::LEFTOVER_UNIQUE, snapv[0]),
            u(s::LEFTOVER_NOTED_ON, snapv[1]),
            u(s::BATCHES_TODAY, queued.len() as u32),
            u(s::BATCHES_TARGET, snapv[2]),
            u(s::APPS_TODAY, apps_today),
            u(s::APPS_TARGET, snapv[3]),
            u(s::SUBMITTED_TODAY, submitted_today),
            u(s::CUMULATIVE, cumulative),
            u(s::TARGET_TOTAL, snapv[4]),
            u(
                s::TARGET_ON,
                if snapv[5] == NONE { 20_757 } else { snapv[5] },
            ), // ~D[2026-10-31]
            u(s::CHART_N, total_n),
            f(s::CHART_MEAN, mean),
            f(s::CHART_MAX, max.map_or(f64::NAN, |m| m as f64)),
            f(s::CHART_MIN, min.map_or(f64::NAN, |m| m as f64)),
        ];
        out.push(sb);

        let mut bands = Table::new(table::CHART_BANDS);
        bands.n = BANDS.len();
        let counts: Vec<u32> = BANDS
            .iter()
            .map(|b| (b.2..=b.3).map(|s| freq[s as usize]).sum())
            .collect();
        let bk = BANDS.iter().map(|b| d.konst(arena, b.0)).collect();
        let bl = BANDS.iter().map(|b| d.konst(arena, b.1)).collect();
        bands.cols = vec![
            Column {
                id: col::chart_bands::KEY,
                ty: STR,
                data: Data::Str(bk),
            },
            Column {
                id: col::chart_bands::LABEL,
                ty: STR,
                data: Data::Str(bl),
            },
            Column {
                id: col::chart_bands::MIN,
                ty: U32,
                data: Data::W32(BANDS.iter().map(|b| b.2).collect()),
            },
            Column {
                id: col::chart_bands::MAX,
                ty: U32,
                data: Data::W32(BANDS.iter().map(|b| b.3).collect()),
            },
            Column {
                id: col::chart_bands::SHARE,
                ty: F64,
                data: Data::W64(
                    counts
                        .iter()
                        .map(|&c| {
                            if total_n == 0 {
                                0.0
                            } else {
                                heat::round_to(c as f64 / total_n as f64, 3)
                            }
                            .to_bits()
                        })
                        .collect(),
                ),
            },
            Column {
                id: col::chart_bands::COUNT,
                ty: U32,
                data: Data::W32(counts),
            },
        ];
        out.push(bands);

        let mut bins = Table::new(table::CHART_BINS);
        bins.n = 10;
        let hi = |i: u32| if i == 9 { 100 } else { i * 10 + 9 };
        bins.cols = vec![
            Column {
                id: col::chart_bins::LO,
                ty: U32,
                data: Data::W32((0..10).map(|i| i * 10).collect()),
            },
            Column {
                id: col::chart_bins::HI,
                ty: U32,
                data: Data::W32((0..10).map(hi).collect()),
            },
            Column {
                id: col::chart_bins::COUNT,
                ty: U32,
                data: Data::W32(
                    (0..10u32)
                        .map(|i| (i * 10..=hi(i)).map(|s| freq[s as usize]).sum())
                        .collect(),
                ),
            },
        ];
        out.push(bins);

        let mut vr = Table::new(table::VARIETIES);
        vr.n = variety.len();
        let fires = variety
            .iter()
            .map(|x| d.konst(arena, if x.1 { "open_fire" } else { "hold" }))
            .collect();
        let labels = variety
            .iter()
            .enumerate()
            .map(|(i, x)| reuse(arena, prev_labels.get(i).copied(), x.3.as_bytes()))
            .collect();
        vr.cols = vec![
            Column {
                id: col::varieties::CODE,
                ty: STR,
                data: Data::Str(variety.iter().map(|x| x.0).collect()),
            },
            Column {
                id: col::varieties::FIRE,
                ty: STR,
                data: Data::Str(fires),
            },
            Column {
                id: col::varieties::STATUS,
                ty: STR,
                data: Data::Str(variety.iter().map(|x| x.2).collect()),
            },
            Column {
                id: col::varieties::LABEL,
                ty: STR,
                data: Data::Str(labels),
            },
        ];
        out.push(vr);
        out
    }
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

impl Desk {
    /// Keywords.coverage of `targets` (U+001F-joined, as Theme.parse left
    /// them; empty for Keywords.extract of the job's listing) over the
    /// visible text of a CV. Writes the `coverage` table (word, hit in
    /// target order) and returns the hit count.
    pub fn coverage(&mut self, job: u32, text: &[u8], targets: &[u8]) -> u32 {
        let text = heat::downcase(core::str::from_utf8(text).unwrap_or(""));
        let targets = core::str::from_utf8(targets).unwrap_or("");
        let words = if targets.is_empty() {
            let jt = table::JOB_APPS;
            let listing = self
                .row_of(jt, job)
                .map_or(&b""[..], |r| self.vstr(jt, col::job_apps::LISTING, r));
            keywords::extract(core::str::from_utf8(listing).unwrap_or(""))
        } else {
            keywords::theme_targets(targets)
        };
        let hits: Vec<u32> = words
            .iter()
            .map(|w| keywords::hit(&text, w) as u32)
            .collect();
        let n = hits.iter().sum();
        self.put_words(&words, hits);
        n
    }

    /// Keywords.extract of the job's listing into the `coverage` table
    /// (every hit 0). Returns the word count.
    pub fn extract(&mut self, job: u32) -> u32 {
        let jt = table::JOB_APPS;
        let listing = self
            .row_of(jt, job)
            .map_or(&b""[..], |r| self.vstr(jt, col::job_apps::LISTING, r));
        let words = keywords::extract(core::str::from_utf8(listing).unwrap_or(""));
        let n = words.len() as u32;
        let zeros = vec![0; words.len()];
        self.put_words(&words, zeros);
        n
    }

    fn put_words(&mut self, words: &[String], hits: Vec<u32>) {
        let mut t = Table::new(table::COVERAGE);
        t.n = words.len();
        let refs = words
            .iter()
            .map(|w| self.store.arena.put(w.as_bytes()))
            .collect();
        t.cols = vec![
            Column {
                id: col::coverage::WORD,
                ty: STR,
                data: Data::Str(refs),
            },
            Column {
                id: col::coverage::HIT,
                ty: U32,
                data: Data::W32(hits),
            },
        ];
        self.store.put_table(t);
    }

    /// Heat.mix_batch/2 for one batch, read-only: its members in mix order
    /// with each verdict, into the `mix` table. Returns the member count.
    pub fn mix(&mut self, batch: u32) -> u32 {
        let mut d = core::mem::replace(&mut self.derived, Derived::new());
        let today = if self.today == NONE { 0 } else { self.today };
        let jt = table::JOB_APPS;
        let out: Vec<(u32, bool, heat::Reason, String)> = {
            let (jobs, tr) = self.heat_rows(&mut d);
            let mut members: Vec<usize> = (0..jobs.len())
                .filter(|&i| self.vu32(jt, col::job_apps::BATCH_ID, i) == batch)
                .collect();
            // The database returns a batch's rows in id order.
            crate::store::sort_usize(&mut members, &|a, b| jobs[a].id.cmp(&jobs[b].id));
            heat::mix(&jobs, &tr, &members, today)
                .into_iter()
                .map(|(i, v)| (jobs[i].id, v.allow, v.reason, v.note))
                .collect()
        };
        self.derived = d;
        let n = out.len();
        let arena = &mut self.store.arena;
        let reasons = out
            .iter()
            .map(|o| arena.put(o.2.name().as_bytes()))
            .collect();
        let notes = out.iter().map(|o| arena.put(o.3.as_bytes())).collect();
        let mut t = Table::new(table::MIX);
        t.n = n;
        t.cols = vec![
            Column {
                id: col::mix::BATCH_ID,
                ty: U32,
                data: Data::W32(vec![batch; n]),
            },
            Column {
                id: col::mix::JOB,
                ty: U32,
                data: Data::W32(out.iter().map(|o| o.0).collect()),
            },
            Column {
                id: col::mix::KEPT,
                ty: U32,
                data: Data::W32(out.iter().map(|o| o.1 as u32).collect()),
            },
            Column {
                id: col::mix::REASON,
                ty: STR,
                data: Data::Str(reasons),
            },
            Column {
                id: col::mix::NOTE,
                ty: STR,
                data: Data::Str(notes),
            },
        ];
        self.store.put_table(t);
        n as u32
    }
}

fn cell_eq(a: &Column, ra: usize, b: &Column, rb: usize, arena: &Arena) -> bool {
    match (&a.data, &b.data) {
        (Data::W32(x), Data::W32(y)) => x.get(ra) == y.get(rb),
        (Data::W64(x), Data::W64(y)) => x.get(ra) == y.get(rb),
        (Data::Str(x), Data::Str(y)) => {
            let (p, q) = (
                x.get(ra).copied().unwrap_or([0, 0]),
                y.get(rb).copied().unwrap_or([0, 0]),
            );
            p == q || arena.get(p) == arena.get(q)
        }
        _ => false,
    }
}

/// Keys (first column) of rows that are new, gone, or different.
fn changed_rows(old: Option<&Table>, new: &Table, arena: &Arena) -> Vec<u32> {
    let key = |t: &Table, r: usize| t.col(1).map_or(0, |c| c.u32(r));
    let Some(old) = old else {
        return (0..new.n).map(|r| key(new, r)).collect();
    };
    // Each new row's old row, then one pass per column pair.
    let at: Vec<Option<usize>> = (0..new.n).map(|r| old.row_of(key(new, r))).collect();
    let mut moved: Vec<bool> = at.iter().map(Option::is_none).collect();
    for c in &new.cols {
        let Some(o) = old.col(c.id) else {
            moved.iter_mut().for_each(|m| *m = true);
            break;
        };
        for (r, a) in at.iter().enumerate() {
            if let Some(a) = *a {
                if !moved[r] && !cell_eq(o, a, c, r, arena) {
                    moved[r] = true;
                }
            }
        }
    }
    let mut out: Vec<u32> = (0..new.n)
        .filter(|&r| moved[r])
        .map(|r| key(new, r))
        .collect();
    out.extend(
        (0..old.n)
            .map(|r| key(old, r))
            .filter(|&k| new.row_of(k).is_none()),
    );
    out
}

fn same_table(a: &Table, b: &Table, arena: &Arena) -> bool {
    a.n == b.n
        && a.cols.len() == b.cols.len()
        && a.cols.iter().all(|c| {
            b.col(c.id)
                .is_some_and(|d| (0..a.n).all(|r| cell_eq(c, r, d, r, arena)))
        })
}

/// Builds (once) the downcased visible text of `profile`'s CV on `lineage`
/// (Mask.apply's shown lines, "title\nbody" joined by "\n", as
/// Keywords.visible_text) and returns its key in `c.texts`. A lineage
/// without overlays shows its profile's items as written, so every such CV
/// of a profile shares one text.
fn ensure_text(arena: &Arena, c: &mut Corpus, profile: u32, lineage: u32) -> (u32, u32) {
    let ovs: &[(u32, u8, [u32; 2], [u32; 2])] =
        c.overlays.get(&lineage).map_or(&[], |o| o.as_slice());
    let key = (profile, if ovs.is_empty() { 0 } else { lineage });
    if c.texts.contains_key(&key) {
        return key;
    }
    let mut text = String::new();
    let mut first = true;
    for &(item, p, title, body) in &c.items {
        if !(p == NONE || p == 0 || p == profile) {
            continue;
        }
        let ov = ovs.iter().find(|o| o.0 == item);
        if ov.is_some_and(|o| o.1 == 0) {
            continue;
        }
        let (mut t, mut b) = (arena.text(title), arena.text(body));
        if let Some(o) = ov.filter(|o| o.1 == 1) {
            if o.2[1] > 0 {
                t = arena.text(o.2);
            }
            if o.3[1] > 0 {
                b = arena.text(o.3);
            }
        }
        if !first {
            text.push('\n');
        }
        first = false;
        text.push_str(t);
        text.push('\n');
        text.push_str(b);
    }
    c.texts
        .insert(key, keywords::Text::new(heat::downcase(&text)));
    key
}

impl Desk {
    /// The downcased visible text of `profile`'s CV on `lineage`, through
    /// the pending view, memoized until an item or overlay moves (for a
    /// focus's coverage; the cards count theirs in `derive`).
    #[allow(dead_code)] // compose.rs reads it
    pub(crate) fn cv_text(&mut self, profile: u32, lineage: u32) -> &keywords::Text {
        self.derive();
        let mut d = core::mem::replace(&mut self.derived, Derived::new());
        let generation = d.corpus_gen;
        let mut c = d
            .corpus
            .take()
            .filter(|(g, _)| *g == generation)
            .map_or_else(|| self.read_corpus(), |(_, c)| c);
        let key = ensure_text(&self.store.arena, &mut c, profile, lineage);
        d.corpus = Some((generation, c));
        self.derived = d;
        &self.derived.corpus.as_ref().unwrap().1.texts[&key]
    }
}
