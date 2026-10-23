//! The heat governor: the campaign must not snap onto one company or one
//! applicant tracking system. Heat gates the move into the queue and the
//! submission itself; FIRE HOLD still owns submit, and nothing here sends
//! anything.
//!
//! Only what went out carries heat: a submitted application, or one in
//! `reply`/`closed` after something was sent. A draft (`fire_ready`,
//! `open_fire`) carries none. Each sent application weighs what the
//! other side has seen of it: submitted and unanswered `application_load`,
//! in conversation `conversation_weight`, rejected `rejected_weight`,
//! ghosted `ghosted_weight`, withdrawn or declined `closed_weight`, each
//! decaying from its last contact (`weight · 0.5^(days / half_life)`; a
//! rejection at `rejected_half_life`), and counting for nothing under
//! `load_floor`.
//!
//! A company's load on one application is its peers' loads weighted by
//! how close each is to that role: the same family `similar_family`, the
//! same department (two roles the lexicon cannot place count as one)
//! `similar_department`, any other team `similar_other`. Its capacity is
//! `1 + log2(headcount / headcount_base)` in [`cap_min`, `cap_max`] when its
//! corporation's headcount is known, else its size tier's cap. An ATS
//! tenant or vendor sees volume, not teams: their loads are unweighted.
//!
//! A move into the queue (and the submission) is deferred when the
//! company would pass its capacity, the vendor or tenant theirs, its batch
//! already holds `ats_batch_cap` sent on that vendor, the company made an
//! offer, or it rejected the same role family under `reapply_days` ago. A
//! heat override with a written reason lets one application past. The
//! board's class is the load already there over the capacity: an
//! untouched company is cool.
//!
//! The defaults are the standing order (`docs/heat.md`); an account's
//! `settings.heat_config` overrides any of them by name.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use schema::enums;

use crate::ats::{self, Ats, Vendor};
use crate::org::{self, Department, Family, Size};
use crate::pipeline::Stage;
use crate::Day;

/// The governor's settings, each under its own name in `heat_config`,
/// with its default.
macro_rules! config {
    ($($(#[$doc:meta])* $name:ident: $default:expr,)+) => {
        #[derive(Clone, Debug, PartialEq)]
        pub struct Config {
            $($(#[$doc])* pub $name: f64,)+
        }

        impl Default for Config {
            fn default() -> Config {
                Config { $($name: $default),+ }
            }
        }

        impl Config {
            /// Every setting under its `heat_config` key.
            fn fields(&mut self) -> Vec<(&'static str, &mut f64)> {
                alloc::vec![$((stringify!($name), &mut self.$name)),+]
            }
        }
    };
}

config! {
    /// A company's memory of an application halves in a month.
    company_half_life: 30.0,
    /// A no is remembered longer: reapplying soon after one reads badly.
    rejected_half_life: 90.0,
    /// Vendor-level profiling across companies forgets faster.
    ats_vendor_half_life: 14.0,
    /// One tenant is usually one employer.
    ats_tenant_half_life: 21.0,
    /// Submitted, no answer yet: the ATS has it.
    application_load: 1.0,
    /// An active process: another application there now competes with it.
    conversation_weight: 2.0,
    rejected_weight: 1.5,
    /// Nobody looked.
    ghosted_weight: 0.7,
    /// Withdrawn or declined: they saw the candidate leave.
    closed_weight: 1.0,
    similar_family: 1.0,
    similar_department: 0.6,
    similar_other: 0.25,
    reapply_days: 90.0,
    /// A few roles across different orgs.
    mega_cap: 4.0,
    large_cap: 2.5,
    mid_cap: 1.5,
    /// Small is what the lexicon cannot place: unknown, not tiny.
    small_cap: 1.5,
    /// 1 + log2(headcount / 100): ~1 at 100 people, ~4 at 1,000, ~7.6 at 10,000.
    headcount_base: 100.0,
    cap_min: 1.0,
    cap_max: 8.0,
    /// So one vendor is never the whole campaign.
    ats_vendor_cap: 40.0,
    ats_tenant_cap: 3.0,
    /// One batch does not slam a single vendor.
    ats_batch_cap: 20.0,
    cool_ratio: 0.5,
    hot_ratio: 0.8,
    /// A peer whose decayed load is under this no longer counts. Decay
    /// never reaches zero, so without a floor a company whose cap equals
    /// one application's load would never take a second one. At a 30-day
    /// half-life a plain submission stops counting after 130 days.
    load_floor: 0.05,
}

impl Config {
    /// The defaults with every recognized key of a JSON object applied.
    /// A key that is unknown, not a finite number, or out of its range is
    /// ignored (the similarities may be 0 and are at most 1, `reapply_days`
    /// may be 0, a weight is at most 16, everything else must be
    /// positive), and a cool ratio above the hot ratio, or a `cap_min`
    /// above `cap_max`, drops both, so a bad setting can loosen nothing by accident.
    pub fn from_json(json: Option<&str>) -> Config {
        let mut c = Config::default();
        let Some(Ok(serde_json::Value::Object(m))) = json.map(serde_json::from_str::<serde_json::Value>) else {
            return c;
        };
        for (k, slot) in c.fields() {
            let similar = k.starts_with("similar_");
            let zero_ok = similar || k == "reapply_days";
            let weight = k == "application_load" || k.ends_with("_weight");
            let in_range = |x: f64| (x > 0.0 || (zero_ok && x == 0.0)) && (!weight || x <= 16.0) && (!similar || x <= 1.0);
            if let Some(x) = m.get(k).and_then(serde_json::Value::as_f64).filter(|x| x.is_finite() && in_range(*x)) {
                *slot = x;
            }
        }
        let d = Config::default();
        if c.cool_ratio > c.hot_ratio {
            (c.cool_ratio, c.hot_ratio) = (d.cool_ratio, d.hot_ratio);
        }
        if c.cap_min > c.cap_max {
            (c.cap_min, c.cap_max) = (d.cap_min, d.cap_max);
        }
        c
    }

    /// A company's capacity: from its headcount when known, else its tier.
    pub fn cap(&self, seat: &Seat) -> f64 {
        match (seat.headcount.filter(|h| *h > 0), seat.size) {
            (Some(h), _) => (1.0 + libm::log2(h as f64 / self.headcount_base)).clamp(self.cap_min, self.cap_max),
            (None, Size::Mega) => self.mega_cap,
            (None, Size::Large) => self.large_cap,
            (None, Size::Mid) => self.mid_cap,
            (None, Size::Small) => self.small_cap,
        }
    }

    /// How close a peer's role is to the role being judged.
    fn similarity(&self, dept: Department, fam: Family, to: &Seat) -> f64 {
        if fam == to.family && fam != Family::Other {
            self.similar_family
        } else if dept == to.department {
            self.similar_department
        } else {
            self.similar_other
        }
    }
}

/// `amount` after `days` of decay at `half_life`. Future days do not grow it.
pub fn decay(amount: f64, days: i64, half_life: f64) -> f64 {
    if days <= 0 { amount } else { amount * libm::pow(0.5, days as f64 / half_life) }
}

/// What the other side has seen of a sent application.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    /// Not sent: no heat.
    Unsent,
    Submitted,
    Conversation,
    Rejected,
    Ghosted,
    Closed,
    Offer,
}

/// What the governor reads of one application, parsed once.
#[derive(Clone, Debug)]
pub struct Seat {
    pub id: u32,
    /// The company the seat counts against: its corporation when linked,
    /// else its normalized name.
    pub key: String,
    pub size: Size,
    /// Its corporation's headcount, when cited.
    pub headcount: Option<u32>,
    pub department: Department,
    pub family: Family,
    pub ats: Ats,
    pub stage: Stage,
    pub status: Status,
    /// Carries load: something went out (submitted, or replied or closed
    /// after a submission). A draft costs nothing.
    pub hot: bool,
    /// The day its load decays from: the latest of its submission and its
    /// reply that exists, else the day it entered its stage.
    pub since: Option<Day>,
    /// The score it ranks by in a mix.
    pub score: u8,
    pub batch_id: Option<u32>,
    /// The override flag with a non-blank reason; either alone is nothing.
    pub overridden: bool,
}

/// The raw fields a [`Seat`] is read from.
pub struct SeatIn<'a> {
    pub id: u32,
    pub corporation_id: Option<u32>,
    pub headcount: Option<u32>,
    pub company: &'a str,
    pub role: &'a str,
    pub url: &'a str,
    pub stage: Stage,
    pub stage_on: Option<Day>,
    pub applied_on: Option<Day>,
    pub replied_on: Option<Day>,
    /// `applications.outcome`'s code, when set.
    pub outcome: Option<u32>,
    /// Whether anything went out (its rail's `submitted` or `reply` rung reached).
    pub sent: bool,
    pub score: u8,
    pub batch_id: Option<u32>,
    pub heat_override: bool,
    pub heat_override_reason: &'a str,
}

impl Seat {
    pub fn new(f: &SeatIn) -> Seat {
        let company = crate::text::normalize(f.company);
        let role = crate::text::normalize(f.role);
        Seat::from_normalized(f, &company, org::size(&company), org::department(&role), org::family(&role))
    }

    /// [`Seat::new`] from the company's normalized name and size and the
    /// role's department and family, already read (the board reads them
    /// once per distinct name and title).
    pub fn from_normalized(f: &SeatIn, company: &str, size: Size, department: Department, family: Family) -> Seat {
        let sent = (f.sent || f.stage == Stage::Submitted) && f.stage.after_send();
        // A control character no normalized name can contain.
        let key = f.corporation_id.map_or_else(|| String::from(company), |c| alloc::format!("\u{1}{c}"));
        let status = match f.outcome {
            _ if !sent => Status::Unsent,
            Some(o) if o == enums::outcome::OFFER as u32 => Status::Offer,
            Some(o) if o == enums::outcome::REJECTED as u32 => Status::Rejected,
            Some(o) if o == enums::outcome::GHOSTED as u32 => Status::Ghosted,
            Some(_) => Status::Closed,
            // Closing ends the process: it weighs as a withdrawal, whatever was said.
            None if f.stage == Stage::Closed => Status::Closed,
            None if f.replied_on.is_some() || f.stage == Stage::Reply => Status::Conversation,
            None => Status::Submitted,
        };
        Seat {
            id: f.id,
            key,
            size,
            headcount: f.headcount,
            department,
            family,
            ats: ats::parse(f.url),
            stage: f.stage,
            status,
            hot: sent,
            // The last contact with the company, else the stage's day: closing
            // an answered application is no new contact and must not re-warm it.
            since: f.applied_on.max(f.replied_on).or(f.stage_on),
            score: f.score,
            batch_id: f.batch_id,
            overridden: f.heat_override && !f.heat_override_reason.trim().is_empty(),
        }
    }

    /// Days since `since`. A seat with no date never ages: it sits so far
    /// in the future that no day ahead decays it, on any path.
    fn age(&self, today: Day) -> i64 {
        self.since.map_or(i64::MIN / 2, |d| today as i64 - d as i64)
    }

    /// Its weight before decay, and the half-life its company remembers it by.
    fn weight(&self, cfg: &Config) -> (f64, f64) {
        match self.status {
            Status::Unsent => (0.0, cfg.company_half_life),
            Status::Submitted | Status::Offer => (cfg.application_load, cfg.company_half_life),
            Status::Conversation => (cfg.conversation_weight, cfg.company_half_life),
            Status::Rejected => (cfg.rejected_weight, cfg.rejected_half_life),
            Status::Ghosted => (cfg.ghosted_weight, cfg.company_half_life),
            Status::Closed => (cfg.closed_weight, cfg.company_half_life),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    Ok,
    Override,
    CompanyCap,
    VendorCap,
    TenantCap,
    BatchCap,
    Offer,
    Reapply,
}

impl Reason {
    pub fn name(self) -> &'static str {
        ["ok", "override", "company_cap", "ats_vendor_cap", "ats_tenant_cap", "ats_batch_cap", "offer", "reapply"][self as usize]
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    pub allow: bool,
    pub reason: Reason,
    /// The company's load on this role: its sent peers, weighted by what
    /// happened to each and how close each role is, decayed.
    pub company_load: f64,
    pub company_cap: f64,
    pub increment: f64,
    pub size: Size,
    pub vendor: Vendor,
    pub vendor_load: f64,
    pub vendor_cap: f64,
    pub tenant_load: f64,
    pub tenant_cap: f64,
    pub batch_vendor: u32,
    /// Days until the deferred move would fit, with nothing else changing
    /// ([`cooldown`]); `None` when it would not within the horizon.
    pub cooldown_days: Option<u32>,
}

impl Verdict {
    /// The company's load already there over its capacity: how crowded
    /// the company is around this role, without the role itself.
    pub fn ratio(&self) -> f64 {
        if self.company_cap > 0.0 { self.company_load / self.company_cap } else { f64::INFINITY }
    }

    /// The verdict as JSON, with the seat's ATS tenant.
    pub fn to_json(&self, seat: &Seat) -> serde_json::Value {
        serde_json::json!({
            "ats_tenant": seat.ats.tenant,
            "allow": self.allow,
            "reason": self.reason.name(),
            "company_load": self.company_load,
            "company_cap": self.company_cap,
            "increment": self.increment,
            "size": self.size.name(),
            "headcount": seat.headcount,
            "ats_vendor": self.vendor.name(),
            "vendor_load": self.vendor_load,
            "vendor_cap": self.vendor_cap,
            "tenant_load": self.tenant_load,
            "tenant_cap": self.tenant_cap,
            "batch_vendor": self.batch_vendor,
            "cooldown_days": self.cooldown_days,
        })
    }
}

/// The board's four heat classes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Class {
    Cool = 0,
    Warm = 1,
    Hot = 2,
    Blocked = 3,
}

impl Class {
    pub fn name(self) -> &'static str {
        ["cool", "warm", "hot", "blocked"][self as usize]
    }

    pub fn parse(s: &str) -> Option<Class> {
        [Class::Cool, Class::Warm, Class::Hot, Class::Blocked].into_iter().find(|c| c.name() == s)
    }

    pub fn of(v: &Verdict, cfg: &Config) -> Class {
        let r = v.ratio();
        if !v.allow {
            Class::Blocked
        } else if r >= cfg.hot_ratio {
            Class::Hot
        } else if r >= cfg.cool_ratio {
            Class::Warm
        } else {
            Class::Cool
        }
    }
}

/// Loads are kept in fixed point, 2^-44 each, so a group's total is an
/// exact integer sum: the same in any order, and a member's own share
/// comes out of it exactly. 2^20 whole loads fit: 50k applications at the
/// largest weight (16).
const SCALE: f64 = 17_592_186_044_416.0;

fn real(x: u64) -> f64 {
    x as f64 / SCALE
}

/// One count per variant; `Other` is each enum's last.
const DEPARTMENTS: usize = Department::Other as usize + 1;
const FAMILIES: usize = Family::Other as usize + 1;

const COMPANY: usize = 0;
const VENDOR: usize = 1;
const TENANT: usize = 2;

/// A seat's load at group kind `k` (company, vendor, tenant) `age` days
/// on, 0 under the floor. A vendor and a tenant keep their own half-lives
/// whatever happened; a company remembers a rejection longer.
fn load_of(s: &Seat, age: i64, k: usize, cfg: &Config) -> u64 {
    let (w, company) = s.weight(cfg);
    let half = [company, cfg.ats_vendor_half_life, cfg.ats_tenant_half_life][k];
    let l = decay(w, age, half);
    if l >= cfg.load_floor { libm::round(l * SCALE) as u64 } else { 0 }
}

/// The hot seats of an account on one day, each seat's decayed loads
/// computed once and grouped by company, vendor, tenant and batch, so a
/// verdict reads only its groups. [`Index::update`] moves one seat between
/// groups; an index kept current that way answers exactly as a fresh one.
#[derive(Default)]
pub struct Index {
    today: Day,
    cfg: Config,
    seats: crate::fx::Map<u32, Seat>,
    // Keyed by the agent-written names themselves, in maps seeded from the
    // host's random source (`keyed`): exact, and a set of names crafted
    // without the seed cannot pile into one bucket.
    by_company: crate::keyed::Map<String, Group>,
    by_vendor: crate::fx::Map<Vendor, Group>,
    by_tenant: crate::fx::Map<Vendor, crate::keyed::Map<String, Group>>,
    /// Sent members per (batch, vendor), with their vendor load: a member
    /// counts toward the batch cap while that load is live.
    by_batch_vendor: crate::fx::Map<(u32, Vendor), Group>,
}

#[derive(Default)]
struct Group {
    /// Member id → its load at this group's half-life today, 0 under the floor.
    members: BTreeMap<u32, u64>,
    total: u64,
    /// A company group's loads by (department, family), so a role's
    /// similarity-weighted load reads one cell per pair, not the members.
    joint: Vec<u64>,
}

impl Group {
    fn put(&mut self, id: u32, l: u64) {
        self.total = self.total.saturating_add(l);
        if let Some(old) = self.members.insert(id, l) {
            self.total = self.total.saturating_sub(old);
        }
    }

    fn take(&mut self, id: u32) -> Option<u64> {
        let old = self.members.remove(&id)?;
        self.total = self.total.saturating_sub(old);
        Some(old)
    }
}

fn cell(d: Department, f: Family) -> usize {
    d as usize * FAMILIES + f as usize
}

#[allow(clippy::type_complexity)]
type Keys = (Option<String>, Option<Vendor>, Option<(Vendor, String)>, Option<(u32, Vendor)>);

/// The group keys a seat belongs to.
fn keys(s: &Seat) -> Keys {
    let known = s.ats.vendor != Vendor::Unknown;
    (
        (!s.key.is_empty()).then(|| s.key.clone()),
        known.then_some(s.ats.vendor),
        s.ats.tenant.clone().filter(|_| known).map(|t| (s.ats.vendor, t)),
        s.batch_id.filter(|_| known).map(|b| (b, s.ats.vendor)),
    )
}

impl Index {
    /// Indexes (a copy of) the hot seats; the rest carry no load.
    pub fn new<'s>(seats: impl IntoIterator<Item = &'s Seat>, today: Day, cfg: &Config) -> Index {
        let mut ix = Index { today, cfg: cfg.clone(), ..Index::default() };
        for s in seats.into_iter().filter(|s| s.hot) {
            ix.join(s.clone());
        }
        ix
    }

    /// Replaces seat `id` with `seat` (or removes it with `None`); a seat
    /// that is not hot is removed.
    pub fn update(&mut self, id: u32, seat: Option<Seat>) {
        self.leave(id);
        if let Some(s) = seat.filter(|s| s.hot) {
            self.join(s);
        }
    }

    fn join(&mut self, s: Seat) {
        let (c, v, t, bv) = keys(&s);
        let age = s.age(self.today);
        let l: [u64; 3] = core::array::from_fn(|k| load_of(&s, age, k, &self.cfg));
        let id = s.id;
        // A company keeps an offer or a rejection that still matters even
        // once its load is under the floor: the reapply window and the offer
        // read the members, not the load.
        if let Some(c) = c {
            let g = self.by_company.entry(c).or_default();
            if g.joint.is_empty() {
                g.joint = alloc::vec![0; DEPARTMENTS * FAMILIES];
            }
            g.put(id, l[COMPANY]);
            let j = &mut g.joint[cell(s.department, s.family)];
            *j = j.saturating_add(l[COMPANY]);
        }
        if let Some(v) = v.filter(|_| l[VENDOR] > 0) {
            self.by_vendor.entry(v).or_default().put(id, l[VENDOR]);
        }
        if let Some((v, t)) = t.filter(|_| l[TENANT] > 0) {
            self.by_tenant.entry(v).or_default().entry(t).or_default().put(id, l[TENANT]);
        }
        if let Some(bv) = bv.filter(|_| l[VENDOR] > 0) {
            self.by_batch_vendor.entry(bv).or_default().put(id, l[VENDOR]);
        }
        self.seats.insert(id, s);
    }

    fn leave(&mut self, id: u32) {
        let Some(s) = self.seats.remove(&id) else { return };
        let (c, v, t, bv) = keys(&s);
        if let Some(g) = c.and_then(|c| self.by_company.get_mut(&c))
            && let Some(old) = g.take(id)
        {
            let j = &mut g.joint[cell(s.department, s.family)];
            *j = j.saturating_sub(old);
        }
        if let Some(g) = v.and_then(|v| self.by_vendor.get_mut(&v)) {
            g.take(id);
        }
        if let Some(g) = t.and_then(|(v, t)| self.by_tenant.get_mut(&v)?.get_mut(&t)) {
            g.take(id);
        }
        if let Some(g) = bv.and_then(|bv| self.by_batch_vendor.get_mut(&bv)) {
            g.take(id);
        }
    }

    /// Whether a seat (by id) is one of the indexed hot seats.
    pub fn contains(&self, id: u32) -> bool {
        self.seats.contains_key(&id)
    }

    /// The members of `g` other than `seat`, with their seats.
    fn peers<'g>(&'g self, g: &'g Group, seat: &'g Seat) -> impl Iterator<Item = &'g Seat> + 'g {
        g.members.keys().filter(move |m| **m != seat.id).filter_map(|m| self.seats.get(m))
    }

    /// An unweighted group's load for `seat`: today its total less its own
    /// share, on a later day its other members' loads then.
    fn load(&self, g: Option<&Group>, k: usize, seat: &Seat, at: At) -> u64 {
        match (g, at) {
            (None, _) => 0,
            (Some(g), At::Today) => g.total.saturating_sub(g.members.get(&seat.id).copied().unwrap_or(0)),
            (Some(g), At::Day(dt)) => {
                self.peers(g, seat).fold(0u64, |a, p| a.saturating_add(load_of(p, p.age(self.today) + dt, k, &self.cfg)))
            }
        }
    }

    /// A company's load on `seat`'s role: each (department, family) cell
    /// at its similarity, its own share out.
    fn company_load(&self, g: &Group, seat: &Seat, at: At) -> f64 {
        let cfg = &self.cfg;
        let mut joint;
        let cells: &[u64] = match at {
            At::Today => &g.joint,
            At::Day(dt) => {
                joint = alloc::vec![0u64; DEPARTMENTS * FAMILIES];
                for p in self.peers(g, seat) {
                    let j = &mut joint[cell(p.department, p.family)];
                    *j = j.saturating_add(load_of(p, p.age(self.today) + dt, COMPANY, cfg));
                }
                &joint
            }
        };
        let own = match (at, g.members.get(&seat.id), self.seats.get(&seat.id)) {
            (At::Today, Some(l), Some(o)) => Some((cell(o.department, o.family), *l)),
            _ => None,
        };
        let mut load = 0.0;
        for (i, &x) in cells.iter().enumerate() {
            let x = match own {
                Some((c, l)) if c == i => x.saturating_sub(l),
                _ => x,
            };
            if x > 0 {
                let (d, f) = (i / FAMILIES, i % FAMILIES);
                load += real(x) * cfg.similarity(org::department_of(d), org::family_of(f), seat);
            }
        }
        load
    }

    /// How many members of `g` other than `seat` still carry vendor load on a day.
    fn live(&self, g: &Group, seat: &Seat, at: At) -> u32 {
        match at {
            At::Today => g.members.iter().filter(|(m, l)| **m != seat.id && **l > 0).count() as u32,
            At::Day(dt) => self.peers(g, seat).filter(|p| load_of(p, p.age(self.today) + dt, VENDOR, &self.cfg) > 0).count() as u32,
        }
    }
}

/// When a check is made: today, or `dt` days on.
#[derive(Clone, Copy, PartialEq, Eq)]
enum At {
    Today,
    Day(i64),
}

impl At {
    fn dt(self) -> i64 {
        match self {
            At::Today => 0,
            At::Day(d) => d,
        }
    }
}

/// One of the governor's conditions, each monotone in time (loads and
/// live peers only shrink, an offer and a reapply window only lapse), so
/// each has its own first passing day. Checked in this order.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Cond {
    Offer,
    Reapply,
    Batch,
    Vendor,
    Tenant,
    Company,
}

impl Cond {
    const ALL: [Cond; 6] = [Cond::Offer, Cond::Reapply, Cond::Batch, Cond::Vendor, Cond::Tenant, Cond::Company];

    fn reason(self) -> Reason {
        [Reason::Offer, Reason::Reapply, Reason::BatchCap, Reason::VendorCap, Reason::TenantCap, Reason::CompanyCap][self as usize]
    }
}

/// What the checks share: the index and the seat they judge.
struct Probe<'a> {
    ix: &'a Index,
    seat: &'a Seat,
}

impl<'a> Probe<'a> {
    fn company_group(&self) -> Option<&'a Group> {
        if self.seat.key.is_empty() { None } else { self.ix.by_company.get(self.seat.key.as_str()) }
    }

    /// The company's peers other than the seat, live or not (an offer and a
    /// rejection count by their dates, not their load).
    fn company_peers(&self) -> impl Iterator<Item = &'a Seat> + '_ {
        self.company_group().into_iter().flat_map(move |g| self.ix.peers(g, self.seat))
    }

    fn company(&self, at: At) -> (f64, f64) {
        (self.company_group().map_or(0.0, |g| self.ix.company_load(g, self.seat, at)), self.ix.cfg.application_load)
    }

    fn vendor(&self, at: At) -> f64 {
        let v = self.seat.ats.vendor;
        if v == Vendor::Unknown {
            return 0.0;
        }
        real(self.ix.load(self.ix.by_vendor.get(&v), VENDOR, self.seat, at))
    }

    fn tenant(&self, at: At) -> f64 {
        let v = self.seat.ats.vendor;
        let Some(t) = self.seat.ats.tenant.as_ref().filter(|_| v != Vendor::Unknown) else { return 0.0 };
        real(self.ix.load(self.ix.by_tenant.get(&v).and_then(|m| m.get(t.as_str())), TENANT, self.seat, at))
    }

    fn batch(&self, at: At) -> u32 {
        let (seat, v) = (self.seat, self.seat.ats.vendor);
        let Some(b) = seat.batch_id.filter(|_| v != Vendor::Unknown) else { return 0 };
        self.ix.by_batch_vendor.get(&(b, v)).map_or(0, |g| self.ix.live(g, seat, at))
    }

    /// Whether the company made an offer that still stands on a day: one
    /// is remembered as long as a rejection.
    fn offer(&self, at: At) -> bool {
        let cfg = &self.ix.cfg;
        self.company_peers().any(|p| p.status == Status::Offer && decay(1.0, p.age(self.ix.today) + at.dt(), cfg.rejected_half_life) >= cfg.load_floor)
    }

    /// Whether the company rejected the same role family under `reapply_days` before a day.
    fn reapply(&self, at: At) -> bool {
        let (seat, cfg) = (self.seat, &self.ix.cfg);
        seat.family != Family::Other
            && self.company_peers().any(|p| p.status == Status::Rejected && p.family == seat.family && ((p.age(self.ix.today) + at.dt()) as f64) < cfg.reapply_days)
    }

    /// A condition's measure on a day: a flag as 0 or 1, the batch's live
    /// members, a vendor's or tenant's load, or the company's load and increment.
    fn measure(&self, c: Cond, at: At) -> (f64, f64) {
        match c {
            Cond::Offer => (self.offer(at) as u8 as f64, 0.0),
            Cond::Reapply => (self.reapply(at) as u8 as f64, 0.0),
            Cond::Batch => (self.batch(at) as f64, 0.0),
            Cond::Vendor => (self.vendor(at), 0.0),
            Cond::Tenant => (self.tenant(at), 0.0),
            Cond::Company => self.company(at),
        }
    }

    /// Whether a condition holds at its measure.
    fn holds(&self, c: Cond, (load, inc): (f64, f64)) -> bool {
        let cfg = &self.ix.cfg;
        let known = self.seat.ats.vendor != Vendor::Unknown;
        match c {
            Cond::Offer | Cond::Reapply => load == 0.0,
            Cond::Batch => !known || load < cfg.ats_batch_cap,
            Cond::Vendor => !known || load + cfg.application_load <= cfg.ats_vendor_cap,
            Cond::Tenant => self.seat.ats.tenant.is_none() || !known || load + cfg.application_load <= cfg.ats_tenant_cap,
            Cond::Company => load + inc <= cfg.cap(self.seat),
        }
    }

    fn passes(&self, c: Cond, at: At) -> bool {
        self.holds(c, self.measure(c, at))
    }

    /// The first day `c` passes, by bisection over exact loads; `None`
    /// past the horizon.
    fn first_day(&self, c: Cond) -> Option<i64> {
        if self.passes(c, At::Today) {
            return Some(0);
        }
        if !self.passes(c, At::Day(HORIZON_DAYS)) {
            return None;
        }
        let (mut lo, mut hi) = (0, HORIZON_DAYS);
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2;
            if self.passes(c, At::Day(mid)) { hi = mid } else { lo = mid }
        }
        Some(hi)
    }
}

/// The governor's verdict on `seat` entering the queue (or going out) on
/// the index's day, under the index's config, against the indexed hot
/// seats. The seat itself is never its own peer. `cooldown_days` is left
/// for [`cooldown`] to fill: `Some(0)` when allowed, else `None`.
pub fn verdict(ix: &Index, seat: &Seat) -> Verdict {
    let (cfg, p) = (&ix.cfg, Probe { ix, seat });
    let measures = Cond::ALL.map(|c| p.measure(c, At::Today));
    let held = Cond::ALL.into_iter().zip(measures).find(|(c, m)| !p.holds(*c, *m)).map(|(c, _)| c.reason());
    let (allow, reason) = match held {
        None => (true, Reason::Ok),
        Some(_) if seat.overridden => (true, Reason::Override),
        Some(r) => (false, r),
    };
    let [_, _, (batch_vendor, _), (vendor_load, _), (tenant_load, _), (company_load, increment)] = measures;
    Verdict {
        allow,
        reason,
        company_load,
        company_cap: cfg.cap(seat),
        increment,
        size: seat.size,
        vendor: seat.ats.vendor,
        vendor_load,
        vendor_cap: cfg.ats_vendor_cap,
        tenant_load,
        tenant_cap: cfg.ats_tenant_cap,
        batch_vendor: batch_vendor as u32,
        cooldown_days: allow.then_some(0),
    }
}

/// How far ahead [`cooldown`] looks.
pub const HORIZON_DAYS: i64 = 3650;

/// Days until the governor would let `seat` in with nothing else
/// changing: 0 when it would now, `None` when it is still held
/// [`HORIZON_DAYS`] on. Each condition is monotone in time, so the first
/// day they all pass is the latest of their own first days, and only the
/// conditions failing today are searched, each over its own group.
pub fn cooldown(ix: &Index, seat: &Seat) -> Option<u32> {
    if seat.overridden {
        return Some(0);
    }
    let p = Probe { ix, seat };
    let mut day = 0;
    for c in Cond::ALL {
        day = day.max(p.first_day(c)?);
    }
    Some(day as u32)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: Day = 20_000;

    fn seat_in() -> SeatIn<'static> {
        SeatIn {
            id: 9,
            corporation_id: None,
            headcount: None,
            company: "",
            role: "",
            url: "",
            stage: Stage::Gated,
            stage_on: None,
            applied_on: None,
            replied_on: None,
            outcome: None,
            sent: false,
            score: 50,
            batch_id: None,
            heat_override: false,
            heat_override_reason: "",
        }
    }

    fn seat(id: u32, company: &str, role: &str, url: &str, stage: Stage, on: Day) -> Seat {
        Seat::new(&SeatIn { id, company, role, url, stage, stage_on: Some(on), applied_on: (stage >= Stage::Submitted).then_some(on), sent: stage >= Stage::Submitted, ..seat_in() })
    }

    fn with(mut s: Seat, status: Status) -> Seat {
        s.status = status;
        s
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn only_what_went_out_carries_heat_and_an_untouched_company_is_cool() {
        let cfg = Config::default();
        let drafts = [seat(1, "Acme", "Software Engineer", "", Stage::FireReady, DAY), seat(2, "Acme", "Software Engineer", "", Stage::OpenFire, DAY)];
        assert!(drafts.iter().all(|s| !s.hot && s.status == Status::Unsent));
        let next = seat(3, "Acme", "Software Engineer", "", Stage::DraftReady, DAY);
        let v = verdict(&Index::new(&drafts, DAY, &cfg), &next);
        assert!(v.allow && v.company_load == 0.0);
        assert_eq!(Class::of(&v, &cfg), Class::Cool);
        // One submission at an unknown (small) company: 1.0 of 1.5, hot, and a
        // same-role second would pass the capacity.
        let sent = [seat(1, "Acme", "Software Engineer", "", Stage::Submitted, DAY)];
        let v = verdict(&Index::new(&sent, DAY, &cfg), &next);
        assert!(!v.allow && v.reason == Reason::CompanyCap && close(v.company_load, 1.0) && v.company_cap == 1.5);
        // Closed without sending costs nothing; closed after sending does.
        let dead: Vec<Seat> = (1..=12).map(|i| Seat::new(&SeatIn { id: i, company: "Google", stage: Stage::Closed, stage_on: Some(100), ..seat_in() })).collect();
        assert!(dead.iter().all(|s| !s.hot));
        let after = Seat::new(&SeatIn { id: 13, company: "Google", stage: Stage::Closed, stage_on: Some(100), applied_on: Some(40), sent: true, ..seat_in() });
        assert!(after.hot && after.since == Some(40));
        // A linked corporation is one company whatever its name.
        let a = Seat::new(&SeatIn { id: 14, corporation_id: Some(7), company: "Acme, Inc.", ..seat_in() });
        let b = Seat::new(&SeatIn { id: 15, corporation_id: Some(7), company: "ACME", ..seat_in() });
        assert_eq!(a.key, b.key);
    }

    #[test]
    fn what_happened_weighs_and_a_rejection_is_remembered_longer() {
        let cfg = Config::default();
        let base = seat(1, "Globex", "Data Scientist", "", Stage::Closed, DAY - 30);
        let out = |o: u32, replied: bool| {
            Seat::new(&SeatIn { id: 1, company: "Globex", role: "Data Scientist", stage: Stage::Closed, stage_on: Some(DAY - 30), applied_on: Some(DAY - 30), replied_on: replied.then_some(DAY - 30), outcome: Some(o), sent: true, ..seat_in() })
        };
        assert_eq!(out(enums::outcome::REJECTED as u32, true).status, Status::Rejected);
        assert_eq!(out(enums::outcome::GHOSTED as u32, false).status, Status::Ghosted);
        assert_eq!(out(enums::outcome::WITHDRAWN as u32, false).status, Status::Closed);
        assert_eq!(out(enums::outcome::OFFER as u32, true).status, Status::Offer);
        let talking = Seat::new(&SeatIn { id: 1, company: "Globex", role: "Data Scientist", stage: Stage::Reply, stage_on: Some(DAY - 30), applied_on: Some(DAY - 40), replied_on: Some(DAY - 30), sent: true, ..seat_in() });
        assert_eq!(talking.status, Status::Conversation);
        // Each weighs its own, a month on (one company half-life).
        let probe = seat(2, "Globex", "Analyst", "", Stage::Gated, DAY);
        let load = |s: Seat| verdict(&Index::new(&[s], DAY, &cfg), &probe).company_load;
        let other = cfg.similarity(base.department, base.family, &probe);
        assert!(close(load(with(base.clone(), Status::Submitted)), 0.5 * other));
        assert!(close(load(with(base.clone(), Status::Conversation)), 2.0 * 0.5 * other));
        assert!(close(load(with(base.clone(), Status::Ghosted)), 0.7 * 0.5 * other));
        assert!(close(load(with(base, Status::Rejected)), 1.5 * libm::pow(0.5, 30.0 / 90.0) * other));
    }

    #[test]
    fn a_company_weighs_its_peers_by_how_close_each_role_is() {
        let cfg = Config::default();
        let ix = Index::new(
            &[
                seat(1, "Google", "Software Engineer", "", Stage::Submitted, DAY),
                seat(2, "Google", "Senior Data Engineer", "", Stage::Submitted, DAY),
                seat(3, "Google", "Security Engineer", "", Stage::Submitted, DAY),
            ],
            DAY,
            &cfg,
        );
        let swe = seat(9, "Google", "Staff Software Engineer", "", Stage::Gated, DAY);
        let (d, f) = (swe.department, swe.family);
        let expect: f64 = [(1u32, 1.0)].iter().map(|x| x.1).sum::<f64>();
        let v = verdict(&ix, &swe);
        // The clone counts whole; each other team by its department's closeness.
        let others: f64 = [2u32, 3].iter().map(|id| ix.seats[id].clone()).map(|p| cfg.similarity(p.department, p.family, &swe)).sum();
        assert!(close(v.company_load, expect + others), "{} vs {}", v.company_load, expect + others);
        assert!(v.allow && v.company_cap == 4.0 && (d, f) == (swe.department, swe.family));
        // Its own share never counts against itself.
        assert!(close(verdict(&ix, &ix.seats[&1].clone()).company_load, others));
    }

    #[test]
    fn capacity_follows_headcount_when_known() {
        let cfg = Config::default();
        let at = |h: Option<u32>| cfg.cap(&Seat::new(&SeatIn { headcount: h, company: "Initech", ..seat_in() }));
        assert!(close(at(Some(1_000)), 1.0 + libm::log2(10.0)));
        assert_eq!((at(Some(40)), at(Some(10_000_000)), at(None), at(Some(0))), (1.0, 8.0, 1.5, 1.5));
    }

    #[test]
    fn an_offer_blocks_and_a_rejection_holds_its_family_for_the_reapply_window() {
        let cfg = Config::default();
        let rejected = with(seat(1, "Hooli", "Software Engineer", "", Stage::Closed, DAY - 30), Status::Rejected);
        let ix = Index::new(core::slice::from_ref(&rejected), DAY, &cfg);
        let same = seat(2, "Hooli", "Senior Software Engineer", "", Stage::Gated, DAY);
        let v = verdict(&ix, &same);
        assert_eq!((v.allow, v.reason), (false, Reason::Reapply));
        // The window closes in 60 days, but the rejection (1.5, remembered at 90 days)
        // still fills the capacity until 1.5 · 0.5^(age / 90) + 1 fits 1.5: age 143.
        assert_eq!(cooldown(&ix, &same), Some(113));
        // Another family is judged by load alone.
        let infra = seat(3, "Hooli", "Site Reliability Engineer", "", Stage::Gated, DAY);
        assert_ne!(verdict(&ix, &infra).reason, Reason::Reapply);
        let offer = Index::new(&[with(rejected, Status::Offer)], DAY, &cfg);
        assert_eq!(verdict(&offer, &infra).reason, Reason::Offer);
        // An override with a written reason lets one past, and says so.
        let mut o = infra.clone();
        o.overridden = Seat::new(&SeatIn { heat_override: true, heat_override_reason: "  ", ..seat_in() }).overridden;
        assert!(!verdict(&offer, &o).allow);
        o.overridden = true;
        let v = verdict(&offer, &o);
        assert!(v.allow && v.reason == Reason::Override);
    }

    #[test]
    fn a_full_company_waits_until_its_peers_decay() {
        let cfg = Config::default();
        let hot = [seat(1, "Acme", "Software Engineer", "", Stage::Submitted, DAY)];
        let next = seat(2, "Acme", "Software Engineer", "", Stage::Gated, DAY);
        // 1.0 + 1.0 > 1.5 until the peer is under 0.5: one half-life.
        assert_eq!(cooldown(&Index::new(&hot, DAY, &cfg), &next), Some(30));
        assert!(verdict(&Index::new(&hot, DAY + 30, &cfg), &next).allow);
        assert!(!verdict(&Index::new(&hot, DAY + 29, &cfg), &next).allow);
    }

    #[test]
    fn tenant_and_batch_caps() {
        let cfg = Config::default();
        let url = "https://boards.greenhouse.io/acme/jobs/1";
        let hot: Vec<Seat> = (1..=3).map(|i| seat(i, &alloc::format!("Corp{i}"), "Engineer", url, Stage::Submitted, 0)).collect();
        let ix = Index::new(&hot, 0, &cfg);
        let v = verdict(&ix, &seat(10, "Other", "Engineer", url, Stage::Gated, 0));
        assert_eq!(v.reason, Reason::TenantCap);
        assert_eq!(hot[0].ats.tenant.as_deref(), Some("acme"));

        // A batch holding its cap of sent applications on one vendor takes no more there.
        let cfg = Config { ats_batch_cap: 2.0, ..Config::default() };
        let mk = |id: u32, t: &str, stage: Stage| Seat { batch_id: Some(7), ..seat(id, &alloc::format!("Co{id}"), "Engineer", &alloc::format!("https://jobs.lever.co/{t}/1"), stage, 0) };
        let sent = [mk(1, "a", Stage::Submitted), mk(2, "b", Stage::Submitted)];
        assert_eq!(verdict(&Index::new(&sent, 0, &cfg), &mk(3, "c", Stage::Gated)).reason, Reason::BatchCap);
    }

    #[test]
    fn an_index_kept_current_answers_as_a_fresh_one() {
        let cfg = Config::default();
        let mut r = 0x2545_F491_4F6C_DD1Du64;
        let mut next = |n: u64| {
            r ^= r << 13;
            r ^= r >> 7;
            r ^= r << 17;
            r % n
        };
        let statuses = [Status::Submitted, Status::Conversation, Status::Rejected, Status::Ghosted, Status::Closed, Status::Offer];
        let mk = |id: u32, c: u64, stage: u64, on: u64, url: u64, batch: u64, st: u64| {
            let u = alloc::format!("https://jobs.lever.co/t{url}/1");
            let mut s = seat(id, &alloc::format!("Co{c}"), ["Software Engineer", "Research Engineer", "SRE", "Analyst"][(c % 4) as usize], &u, crate::pipeline::STAGES[stage as usize], 1000 - on as Day);
            s.batch_id = (batch > 0).then_some(batch as u32);
            if s.hot {
                s.status = statuses[st as usize];
            }
            s
        };
        for round in 0..40 {
            let mut seats: Vec<Seat> = (1..=60).map(|id| mk(id, next(6), next(10), next(200), next(4), next(3), next(6))).collect();
            let mut ix = Index::new(&seats, 1000, &cfg);
            for _ in 0..80 {
                let i = next(60) as usize;
                if next(5) == 0 {
                    ix.update(seats[i].id, None);
                    seats[i].hot = false;
                } else {
                    seats[i] = mk(seats[i].id, next(6), next(10), next(200), next(4), next(3), next(6));
                    ix.update(seats[i].id, Some(seats[i].clone()));
                }
                let fresh = Index::new(&seats, 1000, &cfg);
                let probe = mk(999, next(6), 3, 0, next(4), next(3), 0);
                for s in seats.iter().chain([&probe]) {
                    assert_eq!(verdict(&ix, s), verdict(&fresh, s), "round {round} seat {}", s.id);
                }
            }
        }
    }

    #[test]
    fn config_from_json_ignores_garbage() {
        let c = Config::from_json(Some(r#"{"small_cap": 2, "mega_cap": -1, "nope": 3, "mid_cap": "x"}"#));
        assert_eq!((c.small_cap, c.mega_cap, c.mid_cap), (2.0, 4.0, 1.5));
        assert_eq!(Config::from_json(Some("[")), Config::default());
        let z = Config::from_json(Some(r#"{"similar_other": 0, "similar_family": 2, "load_floor": 0, "cool_ratio": 0.9, "cap_min": 9, "rejected_weight": 20}"#));
        assert_eq!((z.similar_other, z.similar_family, z.load_floor, z.cool_ratio, z.hot_ratio, z.cap_min, z.rejected_weight), (0.0, 1.0, 0.05, 0.5, 0.8, 1.0, 1.5));
        assert_eq!(Config::from_json(None), Config::default());
    }
}
