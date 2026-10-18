//! The heat governor: the campaign must not snap onto one company or one
//! applicant tracking system. Heat gates the submit queue; FIRE HOLD
//! still owns submit, and nothing here sends anything.
//!
//! Every hot application (queued, or replied or closed after being sent)
//! puts a load of `application_load` on its company, its ATS vendor and
//! its ATS tenant, decaying from the latest of its submission and its
//! reply that exists (else the day it entered its stage) with each one's
//! half-life: `load · 0.5^(days / half_life)`, and counting for nothing
//! once under `load_floor`. A company's cap scales with its size tier. An
//! application entering the queue adds its increment: the base load, plus
//! `same_department_penalty` if a hot peer at that company shares its
//! department, plus `clone_penalty` if one shares its role family (live
//! peers only). The move is deferred when the company would pass its cap,
//! the vendor or tenant would pass theirs, or its batch already holds
//! `ats_batch_cap` of that vendor. A heat override with a written reason
//! lets one application past, and the verdict says so.
//!
//! The defaults are the standing order (`docs/heat.md`); an account's
//! `settings.heat_config` overrides any of them by name.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::ats::{self, Ats, Vendor};
use crate::org::{self, Department, Family, Size};
use crate::pipeline::Stage;
use crate::Day;

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub company_half_life: f64,
    pub ats_vendor_half_life: f64,
    pub ats_tenant_half_life: f64,
    pub application_load: f64,
    pub same_department_penalty: f64,
    pub clone_penalty: f64,
    pub mega_cap: f64,
    pub large_cap: f64,
    pub mid_cap: f64,
    pub small_cap: f64,
    pub ats_vendor_cap: f64,
    pub ats_tenant_cap: f64,
    pub ats_batch_cap: f64,
    pub cool_ratio: f64,
    pub hot_ratio: f64,
    /// A peer whose decayed load is under this no longer counts. Decay
    /// never reaches zero, so without a floor a company whose cap equals
    /// one application's load would never take a second one.
    pub load_floor: f64,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            // A company's load halves in about a month (the 30–45 day window).
            company_half_life: 35.0,
            // Vendor-level profiling across companies forgets faster.
            ats_vendor_half_life: 14.0,
            // One tenant is usually one employer.
            ats_tenant_half_life: 21.0,
            application_load: 1.0,
            same_department_penalty: 0.6,
            clone_penalty: 0.6,
            // A few roles across different orgs.
            mega_cap: 4.0,
            large_cap: 2.5,
            mid_cap: 1.5,
            // One seat, maybe two after decay.
            small_cap: 1.0,
            // So one vendor is never the whole campaign.
            ats_vendor_cap: 40.0,
            ats_tenant_cap: 3.0,
            // One batch does not slam a single vendor.
            ats_batch_cap: 20.0,
            cool_ratio: 0.5,
            hot_ratio: 0.8,
            // At a 35-day half-life a seat stops counting after 152 days.
            load_floor: 0.05,
        }
    }
}

impl Config {
    /// The defaults with every recognized key of a JSON object applied.
    /// A key that is unknown, not a finite number, or out of its range is
    /// ignored (the two penalties may be 0, everything else must be
    /// positive, `application_load` at most 16), and a cool ratio above the hot ratio drops both, so a bad
    /// setting can loosen nothing by accident.
    pub fn from_json(json: Option<&str>) -> Config {
        let mut c = Config::default();
        let Some(Ok(serde_json::Value::Object(m))) = json.map(serde_json::from_str::<serde_json::Value>) else {
            return c;
        };
        for (k, v) in m.iter() {
            let zero_ok = matches!(k.as_str(), "same_department_penalty" | "clone_penalty");
            let in_range = |x: f64| (x > 0.0 || (zero_ok && x == 0.0)) && (k != "application_load" || x <= 16.0);
            let Some(x) = v.as_f64().filter(|x| x.is_finite() && in_range(*x)) else { continue };
            if let Some(slot) = c.field(k) {
                *slot = x;
            }
        }
        if c.cool_ratio > c.hot_ratio {
            let d = Config::default();
            (c.cool_ratio, c.hot_ratio) = (d.cool_ratio, d.hot_ratio);
        }
        c
    }

    fn field(&mut self, name: &str) -> Option<&mut f64> {
        Some(match name {
            "company_half_life" => &mut self.company_half_life,
            "ats_vendor_half_life" => &mut self.ats_vendor_half_life,
            "ats_tenant_half_life" => &mut self.ats_tenant_half_life,
            "application_load" => &mut self.application_load,
            "same_department_penalty" => &mut self.same_department_penalty,
            "clone_penalty" => &mut self.clone_penalty,
            "mega_cap" => &mut self.mega_cap,
            "large_cap" => &mut self.large_cap,
            "mid_cap" => &mut self.mid_cap,
            "small_cap" => &mut self.small_cap,
            "ats_vendor_cap" => &mut self.ats_vendor_cap,
            "ats_tenant_cap" => &mut self.ats_tenant_cap,
            "ats_batch_cap" => &mut self.ats_batch_cap,
            "cool_ratio" => &mut self.cool_ratio,
            "hot_ratio" => &mut self.hot_ratio,
            "load_floor" => &mut self.load_floor,
            _ => return None,
        })
    }

    pub fn cap(&self, size: Size) -> f64 {
        match size {
            Size::Mega => self.mega_cap,
            Size::Large => self.large_cap,
            Size::Mid => self.mid_cap,
            Size::Small => self.small_cap,
        }
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "company_half_life": self.company_half_life,
            "ats_vendor_half_life": self.ats_vendor_half_life,
            "ats_tenant_half_life": self.ats_tenant_half_life,
            "application_load": self.application_load,
            "same_department_penalty": self.same_department_penalty,
            "clone_penalty": self.clone_penalty,
            "mega_cap": self.mega_cap,
            "large_cap": self.large_cap,
            "mid_cap": self.mid_cap,
            "small_cap": self.small_cap,
            "ats_vendor_cap": self.ats_vendor_cap,
            "ats_tenant_cap": self.ats_tenant_cap,
            "ats_batch_cap": self.ats_batch_cap,
            "cool_ratio": self.cool_ratio,
            "hot_ratio": self.hot_ratio,
            "load_floor": self.load_floor,
        })
    }
}

/// `amount` after `days` of decay at `half_life`. Future days do not grow it.
pub fn decay(amount: f64, days: i64, half_life: f64) -> f64 {
    if days <= 0 { amount } else { amount * libm::pow(0.5, days as f64 / half_life) }
}

/// What the governor reads of one application, parsed once.
#[derive(Clone, Debug)]
pub struct Seat {
    pub id: u32,
    /// The company the seat counts against: its corporation when linked,
    /// else its normalized name.
    pub key: String,
    pub size: Size,
    pub department: Department,
    pub family: Family,
    pub ats: Ats,
    pub stage: Stage,
    /// Carries load: queued (`fire_ready`, `open_fire`, `submitted`), or in
    /// `reply`/`closed` after having been sent. A listing closed before
    /// anything went out costs nothing.
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
    pub company: &'a str,
    pub role: &'a str,
    pub url: &'a str,
    pub stage: Stage,
    pub stage_on: Option<Day>,
    pub applied_on: Option<Day>,
    pub replied_on: Option<Day>,
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
        let size = org::size_normalized(&company);
        Seat::from_normalized(f, &company, size, org::department_normalized(&role), org::family_normalized(&role))
    }

    /// [`Seat::new`] from the company's normalized name and size and the
    /// role's department and family, already read (the board reads them
    /// once per distinct name and title).
    pub fn from_normalized(f: &SeatIn, company: &str, size: Size, department: Department, family: Family) -> Seat {
        let sent = f.sent || f.stage == Stage::Submitted;
        // A control character no normalized name can contain.
        let key = f.corporation_id.map_or_else(|| String::from(company), |c| alloc::format!("\u{1}{c}"));
        let ats = ats::parse(f.url);
        Seat {
            id: f.id,
            key,
            size,
            department,
            family,
            ats,
            stage: f.stage,
            hot: f.stage.queued() || (f.stage.after_send() && sent),
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
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    Ok,
    Override,
    CompanyCap,
    VendorCap,
    TenantCap,
    BatchCap,
}

impl Reason {
    pub fn name(self) -> &'static str {
        match self {
            Reason::Ok => "ok",
            Reason::Override => "override",
            Reason::CompanyCap => "company_cap",
            Reason::VendorCap => "ats_vendor_cap",
            Reason::TenantCap => "ats_tenant_cap",
            Reason::BatchCap => "ats_batch_cap",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    pub allow: bool,
    pub reason: Reason,
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
    /// The company's projected load over its cap.
    pub fn ratio(&self) -> f64 {
        if self.company_cap > 0.0 { (self.company_load + self.increment) / self.company_cap } else { f64::INFINITY }
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
        match self {
            Class::Cool => "cool",
            Class::Warm => "warm",
            Class::Hot => "hot",
            Class::Blocked => "blocked",
        }
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
/// largest `application_load` (16).
const SCALE: f64 = 17_592_186_044_416.0;

fn fp(x: f64) -> u64 {
    libm::round(x * SCALE) as u64
}

fn real(x: u64) -> f64 {
    x as f64 / SCALE
}

/// The hot seats of an account on one day, each seat's decayed loads
/// computed once and grouped by company, vendor, tenant and batch, so a
/// verdict reads only its groups and a group total is one lookup.
/// [`Index::update`] moves one seat between groups; an index kept current
/// that way answers exactly as a fresh one.
pub struct Index {
    today: Day,
    cfg: Config,
    seats: crate::fx::Map<u32, Seat>,
    // Keyed by the agent-written names themselves, in seeded maps: exact,
    // and no crafted set of names can pile into one bucket.
    by_company: std::collections::HashMap<String, Group>,
    by_vendor: crate::fx::Map<Vendor, Group>,
    by_tenant: crate::fx::Map<Vendor, std::collections::HashMap<String, Group>>,
    /// Queued members per (batch, vendor), with their vendor load: a
    /// member counts toward the batch cap while that load is live.
    by_batch_vendor: crate::fx::Map<(u32, Vendor), Group>,
}

#[derive(Default)]
struct Group {
    /// Member id → its load at this group's half-life today, 0 under the floor.
    members: BTreeMap<u32, u64>,
    total: u64,
    /// Members by department and by role family (a company's group only),
    /// so the penalties read two counts instead of the members.
    depts: [u32; DEPARTMENTS],
    fams: [u32; FAMILIES],
    /// Members by age in days at the index's day: a load on any later day
    /// is one decay per distinct age, never a walk of the members.
    ages: BTreeMap<i64, u32>,
}

impl Group {
    fn put(&mut self, id: u32, l: u64, age: i64) {
        self.total = self.total.saturating_add(l);
        if let Some(old) = self.members.insert(id, l) {
            self.total = self.total.saturating_sub(old);
        } else {
            *self.ages.entry(age).or_insert(0) += 1;
        }
    }

    fn take(&mut self, id: u32, age: i64) -> bool {
        match self.members.remove(&id) {
            Some(old) => {
                self.total = self.total.saturating_sub(old);
                if let Some(n) = self.ages.get_mut(&age) {
                    *n -= 1;
                    if *n == 0 {
                        self.ages.remove(&age);
                    }
                }
                true
            }
            None => false,
        }
    }
}

/// One count per variant; `Other` is each enum's last.
const DEPARTMENTS: usize = Department::Other as usize + 1;
const FAMILIES: usize = Family::Other as usize + 1;

const COMPANY: usize = 0;
const VENDOR: usize = 1;
const TENANT: usize = 2;

#[allow(clippy::type_complexity)]
type Keys = (Option<String>, Option<Vendor>, Option<(Vendor, String)>, Option<(u32, Vendor)>);

/// The group keys a seat belongs to; a batch counts only queued seats.
fn keys(s: &Seat) -> Keys {
    let known = s.ats.vendor != Vendor::Unknown;
    (
        (!s.key.is_empty()).then(|| s.key.clone()),
        known.then_some(s.ats.vendor),
        s.ats.tenant.clone().filter(|_| known).map(|t| (s.ats.vendor, t)),
        s.batch_id.filter(|_| known && s.stage.queued()).map(|b| (b, s.ats.vendor)),
    )
}

/// A seat's load at half-life `k` (company, vendor, tenant) `age` days
/// on, 0 under the floor.
fn load_at(age: i64, k: usize, cfg: &Config) -> u64 {
    let half = [cfg.company_half_life, cfg.ats_vendor_half_life, cfg.ats_tenant_half_life][k];
    let l = decay(cfg.application_load, age, half);
    if l >= cfg.load_floor { fp(l) } else { 0 }
}

fn loads_at(age: i64, cfg: &Config) -> [u64; 3] {
    [load_at(age, COMPANY, cfg), load_at(age, VENDOR, cfg), load_at(age, TENANT, cfg)]
}

impl Index {
    /// Indexes (a copy of) the hot seats; the rest carry no load.
    pub fn new<'s>(seats: impl IntoIterator<Item = &'s Seat>, today: Day, cfg: &Config) -> Index {
        let mut ix = Index {
            today,
            cfg: cfg.clone(),
            seats: Default::default(),
            by_company: Default::default(),
            by_vendor: Default::default(),
            by_tenant: Default::default(),
            by_batch_vendor: Default::default(),
        };
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
        let l = loads_at(age, &self.cfg);
        let id = s.id;
        // A member whose load is already under the floor today adds
        // nothing to any group on any later day, so it is left out.
        if let Some(c) = c.filter(|_| l[COMPANY] > 0) {
            let g = self.by_company.entry(c).or_default();
            g.put(id, l[COMPANY], age);
            g.depts[s.department as usize] += 1;
            g.fams[s.family as usize] += 1;
        }
        if let Some(v) = v.filter(|_| l[VENDOR] > 0) {
            self.by_vendor.entry(v).or_default().put(id, l[VENDOR], age);
        }
        if let Some((v, t)) = t.filter(|_| l[TENANT] > 0) {
            self.by_tenant.entry(v).or_default().entry(t).or_default().put(id, l[TENANT], age);
        }
        if let Some(bv) = bv.filter(|_| l[VENDOR] > 0) {
            self.by_batch_vendor.entry(bv).or_default().put(id, l[VENDOR], age);
        }
        self.seats.insert(id, s);
    }

    fn leave(&mut self, id: u32) {
        let Some(s) = self.seats.remove(&id) else { return };
        let (c, v, t, bv) = keys(&s);
        let age = s.age(self.today);
        if let Some(g) = c.and_then(|c| self.by_company.get_mut(&c))
            && g.take(id, age)
        {
            g.depts[s.department as usize] -= 1;
            g.fams[s.family as usize] -= 1;
        }
        if let Some(g) = v.and_then(|v| self.by_vendor.get_mut(&v)) {
            g.take(id, age);
        }
        if let Some(g) = t.and_then(|(v, t)| self.by_tenant.get_mut(&v)?.get_mut(&t)) {
            g.take(id, age);
        }
        if let Some(g) = bv.and_then(|bv| self.by_batch_vendor.get_mut(&bv)) {
            g.take(id, age);
        }
    }

    /// Whether a seat (by id) is one of the indexed hot seats.
    pub fn contains(&self, id: u32) -> bool {
        self.seats.contains_key(&id)
    }

    pub fn today(&self) -> Day {
        self.today
    }

    pub fn config(&self) -> &Config {
        &self.cfg
    }

    /// The age of `seat` if it is a member of `g` (and so its own share
    /// comes out of `g`'s load).
    fn own_age(&self, g: &Group, seat: &Seat) -> Option<i64> {
        g.members.contains_key(&seat.id).then(|| self.seats.get(&seat.id).map(|s| s.age(self.today))).flatten()
    }

    /// Members of `g` other than `seat`, by age, with their load `dt`
    /// days on at half-life `k`: one decay per distinct age.
    fn by_age<'g>(&'g self, g: &'g Group, k: usize, seat: &Seat, dt: i64) -> impl Iterator<Item = (u32, u64)> + 'g {
        let own = self.own_age(g, seat);
        g.ages.iter().map(move |(age, n)| (n - (own == Some(*age)) as u32, load_at(age + dt, k, &self.cfg)))
    }

    /// A group's load for `seat`: the total less its own share today, the
    /// members by age on a later day.
    fn load(&self, g: Option<&Group>, k: usize, seat: &Seat, at: At) -> u64 {
        match (g, at) {
            (None, _) => 0,
            (Some(g), At::Today) => g.total.saturating_sub(g.members.get(&seat.id).copied().unwrap_or(0)),
            (Some(g), At::Day(dt)) => self.by_age(g, k, seat, dt).fold(0u64, |a, (n, l)| a.saturating_add(l.saturating_mul(n as u64))),
        }
    }

    /// How many members of `g` other than `seat` still carry load at
    /// half-life `k` on a day.
    fn live(&self, g: &Group, k: usize, seat: &Seat, at: At) -> u32 {
        match at {
            At::Today => g.members.iter().filter(|(m, l)| **m != seat.id && **l > 0).count() as u32,
            At::Day(dt) => self.by_age(g, k, seat, dt).filter(|(_, l)| *l > 0).map(|(n, _)| n).sum(),
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

/// The governor's check on one day.
struct Check {
    reason: Reason,
    company_load: f64,
    increment: f64,
    vendor_load: f64,
    tenant_load: f64,
    batch_vendor: u32,
}

/// One of the governor's four conditions, each monotone in time (loads,
/// live peers and live batch members only shrink), so each has its own
/// first passing day.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Cond {
    Batch,
    Vendor,
    Tenant,
    Company,
}

/// What the checks share: the seat's kept peers, admitted in this pass
/// (fresh load, never one the index already counts).
struct Probe<'a> {
    ix: &'a Index,
    seat: &'a Seat,
    kept: Vec<&'a Seat>,
}

impl<'a> Probe<'a> {
    fn new(ix: &'a Index, seat: &'a Seat, kept: &[&'a Seat]) -> Probe<'a> {
        let kept = kept.iter().copied().filter(|p| p.id != seat.id && !ix.contains(p.id)).collect();
        Probe { ix, seat, kept }
    }

    fn fresh(&self, at: At, k: usize) -> u64 {
        if self.kept.is_empty() { 0 } else { load_at(at.dt(), k, &self.ix.cfg) }
    }

    fn kept_load(&self, at: At, k: usize, same: impl Fn(&Seat) -> bool) -> u64 {
        let f = self.fresh(at, k);
        self.kept.iter().filter(|p| same(p)).fold(0u64, |a, _| a.saturating_add(f))
    }

    fn company_group(&self) -> Option<&'a Group> {
        if self.seat.key.is_empty() { None } else { self.ix.by_company.get(self.seat.key.as_str()) }
    }

    fn company(&self, at: At) -> (f64, f64) {
        let (ix, seat, cfg) = (self.ix, self.seat, &self.ix.cfg);
        let g = self.company_group();
        let same = |p: &Seat| !seat.key.is_empty() && p.key == seat.key;
        let load = real(ix.load(g, COMPANY, seat, at).saturating_add(self.kept_load(at, COMPANY, same)));
        // Penalties come from live peers only: a peer under the floor no
        // longer counts for anything.
        let (mut dept, mut fam) = (false, false);
        if let Some(g) = g {
            match at {
                At::Today => {
                    let own = ix.seats.get(&seat.id).filter(|_| g.members.contains_key(&seat.id));
                    let less = |n: u32, mine: bool| n > mine as u32;
                    dept = less(g.depts[seat.department as usize], own.is_some_and(|o| o.department == seat.department));
                    fam = less(g.fams[seat.family as usize], own.is_some_and(|o| o.family == seat.family));
                }
                At::Day(dt) => {
                    for m in g.members.keys().filter(|m| **m != seat.id) {
                        if let Some(p) = ix.seats.get(m).filter(|p| load_at(p.age(ix.today) + dt, COMPANY, cfg) > 0) {
                            dept |= p.department == seat.department;
                            fam |= p.family == seat.family;
                        }
                    }
                }
            }
        }
        if self.fresh(at, COMPANY) > 0 {
            for p in self.kept.iter().filter(|p| same(p)) {
                dept |= p.department == seat.department;
                fam |= p.family == seat.family;
            }
        }
        let increment = cfg.application_load
            + if dept { cfg.same_department_penalty } else { 0.0 }
            + if fam { cfg.clone_penalty } else { 0.0 };
        (load, increment)
    }

    fn vendor(&self, at: At) -> f64 {
        let v = self.seat.ats.vendor;
        if v == Vendor::Unknown {
            return 0.0;
        }
        real(self.ix.load(self.ix.by_vendor.get(&v), VENDOR, self.seat, at).saturating_add(self.kept_load(at, VENDOR, |p| p.ats.vendor == v)))
    }

    fn tenant(&self, at: At) -> f64 {
        let v = self.seat.ats.vendor;
        let Some(t) = self.seat.ats.tenant.as_ref().filter(|_| v != Vendor::Unknown) else { return 0.0 };
        let g = self.ix.by_tenant.get(&v).and_then(|m| m.get(t.as_str()));
        let same = |p: &Seat| p.ats.vendor == v && p.ats.tenant.as_ref() == Some(t);
        real(self.ix.load(g, TENANT, self.seat, at).saturating_add(self.kept_load(at, TENANT, same)))
    }

    fn batch(&self, at: At) -> u32 {
        let (seat, v) = (self.seat, self.seat.ats.vendor);
        let Some(b) = seat.batch_id.filter(|_| v != Vendor::Unknown) else { return 0 };
        let live = self.ix.by_batch_vendor.get(&(b, v)).map_or(0, |g| self.ix.live(g, VENDOR, seat, at));
        let fresh = if self.fresh(at, VENDOR) > 0 { self.kept.iter().filter(|p| p.batch_id == Some(b) && p.ats.vendor == v).count() as u32 } else { 0 };
        live + fresh
    }

    fn passes(&self, c: Cond, at: At) -> bool {
        let cfg = &self.ix.cfg;
        let known = self.seat.ats.vendor != Vendor::Unknown;
        match c {
            Cond::Batch => !known || (self.batch(at) as f64) < cfg.ats_batch_cap,
            Cond::Vendor => !known || self.vendor(at) + cfg.application_load <= cfg.ats_vendor_cap,
            Cond::Tenant => self.seat.ats.tenant.is_none() || !known || self.tenant(at) + cfg.application_load <= cfg.ats_tenant_cap,
            Cond::Company => {
                let (load, inc) = self.company(at);
                load + inc <= cfg.cap(self.seat.size)
            }
        }
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

fn check(ix: &Index, seat: &Seat, kept: &[&Seat], at: At) -> Check {
    let p = Probe::new(ix, seat, kept);
    let cfg = &ix.cfg;
    let known = seat.ats.vendor != Vendor::Unknown;
    let (company_load, increment) = p.company(at);
    let vendor_load = p.vendor(at);
    let tenant_load = p.tenant(at);
    let batch_vendor = p.batch(at);
    let reason = if known && batch_vendor as f64 >= cfg.ats_batch_cap {
        Reason::BatchCap
    } else if known && vendor_load + cfg.application_load > cfg.ats_vendor_cap {
        Reason::VendorCap
    } else if seat.ats.tenant.is_some() && known && tenant_load + cfg.application_load > cfg.ats_tenant_cap {
        Reason::TenantCap
    } else if company_load + increment > cfg.cap(seat.size) {
        Reason::CompanyCap
    } else {
        Reason::Ok
    };
    Check { reason, company_load, increment, vendor_load, tenant_load, batch_vendor }
}

/// The governor's verdict on `seat` entering the queue on the index's
/// day, under the index's config, against the indexed hot seats plus
/// `kept` (seats already admitted in the same pass). The seat itself is
/// never its own peer. `cooldown_days` is left for [`cooldown`] to fill:
/// `Some(0)` when allowed, else `None`.
pub fn verdict(ix: &Index, seat: &Seat, kept: &[&Seat]) -> Verdict {
    let cfg = &ix.cfg;
    let c = check(ix, seat, kept, At::Today);
    let (allow, reason) = match c.reason {
        Reason::Ok => (true, Reason::Ok),
        _ if seat.overridden => (true, Reason::Override),
        r => (false, r),
    };
    Verdict {
        allow,
        reason,
        company_load: c.company_load,
        company_cap: cfg.cap(seat.size),
        increment: c.increment,
        size: seat.size,
        vendor: seat.ats.vendor,
        vendor_load: c.vendor_load,
        vendor_cap: cfg.ats_vendor_cap,
        tenant_load: c.tenant_load,
        tenant_cap: cfg.ats_tenant_cap,
        batch_vendor: c.batch_vendor,
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
pub fn cooldown(ix: &Index, seat: &Seat, kept: &[&Seat]) -> Option<u32> {
    if seat.overridden {
        return Some(0);
    }
    let p = Probe::new(ix, seat, kept);
    let mut day = 0;
    for c in [Cond::Batch, Cond::Vendor, Cond::Tenant, Cond::Company] {
        day = day.max(p.first_day(c)?);
    }
    Some(day as u32)
}

/// A batch's mix: candidates in score order (then company, then id), each
/// admitted if the governor allows it against the hot seats and those
/// already admitted. The caller builds `ix` without the candidates, so
/// they count only as they are admitted. Returns the admitted ids in
/// order and the deferred with their verdicts.
pub fn mix(candidates: &[Seat], ix: &Index) -> (Vec<u32>, Vec<(u32, Verdict)>) {
    let mut order: Vec<&Seat> = candidates.iter().collect();
    order.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.key.cmp(&b.key)).then(a.id.cmp(&b.id)));
    let mut kept: Vec<&Seat> = Vec::new();
    let mut deferred = Vec::new();
    for s in order {
        let mut v = verdict(ix, s, &kept);
        if v.allow {
            kept.push(s);
        } else {
            v.cooldown_days = cooldown(ix, s, &kept);
            deferred.push((s.id, v));
        }
    }
    (kept.iter().map(|s| s.id).collect(), deferred)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seat(id: u32, company: &str, role: &str, url: &str, stage: Stage, on: Day) -> Seat {
        Seat::new(&SeatIn { id, company, role, url, stage, stage_on: Some(on), ..seat_in() })
    }

    #[test]
    fn decay_halves_at_the_half_life() {
        assert_eq!(decay(1.0, 0, 35.0), 1.0);
        assert_eq!(decay(1.0, -3, 35.0), 1.0);
        assert!((decay(1.0, 35, 35.0) - 0.5).abs() < 1e-12);
        assert!((decay(2.0, 70, 35.0) - 0.5).abs() < 1e-12);
    }

    #[test]
    fn small_company_takes_one_then_cools() {
        let cfg = Config::default();
        let day = 20_000;
        let hot = [seat(1, "Acme", "Software Engineer", "", Stage::Submitted, day)];
        let ix = Index::new(&hot, day, &cfg);
        let next = seat(2, "ACME", "Data Engineer", "", Stage::Gated, day);
        let v = verdict(&ix, &next, &[]);
        assert!(!v.allow);
        assert_eq!(v.reason, Reason::CompanyCap);
        assert_eq!(v.increment, 1.0);
        // The increment fills the cap, so the wait is until the one peer
        // falls under the floor: 35 · log2(1 / 0.05) = 151.3 → 152 days.
        assert_eq!(cooldown(&ix, &next, &[]), Some(152));
        assert!(verdict(&Index::new(&hot, day + 152, &cfg), &next, &[]).allow);
        assert!(!verdict(&Index::new(&hot, day + 151, &cfg), &next, &[]).allow);
        let mega = [seat(1, "Google", "Software Engineer", "", Stage::Submitted, day)];
        let ix = Index::new(&mega, day, &cfg);
        let v = verdict(&ix, &seat(2, "Google", "Software Engineer", "", Stage::Gated, day), &[]);
        // 1.0 load + 1.0 + 0.6 dept + 0.6 clone = 3.2 ≤ 4.0
        assert!(v.allow);
        assert!((v.increment - 2.2).abs() < 1e-12);
        // Two more admitted in the same pass count fresh; the indexed seat
        // passed as kept is not counted twice.
        let fresh = [seat(3, "Google", "SRE", "", Stage::FireReady, day - 90), seat(4, "Google", "SRE", "", Stage::FireReady, day)];
        let next = seat(2, "Google", "Software Engineer", "", Stage::Gated, day);
        let v2 = verdict(&ix, &next, &[&mega[0], &fresh[0], &fresh[1]]);
        assert!(!v2.allow);
        assert_eq!(v2.reason, Reason::CompanyCap);
        assert_eq!(v2.company_load, 3.0);
        // load 3.0, room 4.0 − 2.2 = 1.8: 35 · log2(3 / 1.8) = 25.8 → 26 days.
        assert_eq!(cooldown(&ix, &next, &[&fresh[0], &fresh[1]]), Some(26));
    }

    #[test]
    fn override_needs_a_reason_and_is_reported() {
        let cfg = Config::default();
        let hot = [seat(1, "Acme", "Engineer", "", Stage::Submitted, 0)];
        let ix = Index::new(&hot, 0, &cfg);
        let mut s = seat(2, "Acme", "Engineer", "", Stage::Gated, 0);
        s.overridden = Seat::new(&SeatIn { heat_override: true, heat_override_reason: "  ", ..seat_in() }).overridden;
        assert!(!verdict(&ix, &s, &[]).allow);
        s.overridden = true;
        let v = verdict(&ix, &s, &[]);
        assert!(v.allow);
        assert_eq!(v.reason, Reason::Override);
    }

    fn seat_in() -> SeatIn<'static> {
        SeatIn {
            id: 9,
            corporation_id: None,
            company: "",
            role: "",
            url: "",
            stage: Stage::Gated,
            stage_on: None,
            applied_on: None,
            replied_on: None,
            sent: false,
            score: 50,
            batch_id: None,
            heat_override: false,
            heat_override_reason: "",
        }
    }

    #[test]
    fn expired_peers_cost_nothing_and_unsent_closes_carry_no_heat() {
        let cfg = Config::default();
        let old = [seat(1, "Acme", "Software Engineer", "", Stage::Submitted, 0)];
        let next = seat(2, "Acme", "Software Engineer", "", Stage::Gated, 3650);
        let v = verdict(&Index::new(&old, 3650, &cfg), &next, &[]);
        assert!(v.allow);
        assert_eq!(v.increment, 1.0);
        // Dead listings closed without sending do not load the company.
        let dead: Vec<Seat> = (1..=12).map(|i| seat(i, "Google", "Engineer", "", Stage::Closed, 100)).collect();
        assert!(dead.iter().all(|s| !s.hot));
        let sent = Seat::new(&SeatIn { id: 13, company: "Google", stage: Stage::Closed, stage_on: Some(100), applied_on: Some(40), sent: true, ..seat_in() });
        assert!(sent.hot);
        assert_eq!(sent.since, Some(40));
        // A linked corporation is one company whatever its name.
        let a = Seat::new(&SeatIn { id: 14, corporation_id: Some(7), company: "Acme, Inc.", ..seat_in() });
        let b = Seat::new(&SeatIn { id: 15, corporation_id: Some(7), company: "ACME", ..seat_in() });
        assert_eq!(a.key, b.key);
    }

    #[test]
    fn tenant_and_batch_caps() {
        let cfg = Config::default();
        let url = "https://boards.greenhouse.io/acme/jobs/1";
        let hot: Vec<Seat> =
            (1..=3).map(|i| seat(i, &alloc::format!("Corp{i}"), "Engineer", url, Stage::Submitted, 0)).collect();
        let ix = Index::new(&hot, 0, &cfg);
        let v = verdict(&ix, &seat(10, "Other", "Engineer", url, Stage::Gated, 0), &[]);
        assert_eq!(v.reason, Reason::TenantCap);
        assert_eq!(hot[0].ats.tenant.as_deref(), Some("acme"));

        let cfg = Config { ats_batch_cap: 2.0, ..Config::default() };
        let mk = |id: u32, t: &str| {
            let u = alloc::format!("https://jobs.lever.co/{t}/1");
            Seat::new(&SeatIn { id, company: &alloc::format!("Co{id}"), role: "Engineer", url: &u, stage_on: Some(0), batch_id: Some(7), ..seat_in() })
        };
        let cands = [mk(1, "a"), mk(2, "b"), mk(3, "c")];
        let empty: [Seat; 0] = [];
        let (kept, deferred) = mix(&cands, &Index::new(&empty, 0, &cfg));
        assert_eq!(kept, [1, 2]);
        assert_eq!(deferred[0].0, 3);
        assert_eq!(deferred[0].1.reason, Reason::BatchCap);
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
        let mk = |id: u32, c: u64, stage: u64, on: u64, url: u64, batch: u64| {
            let u = alloc::format!("https://jobs.lever.co/t{url}/1");
            let mut s = seat(id, &alloc::format!("Co{c}"), ["Engineer", "Research Engineer", "SRE"][(c % 3) as usize], &u, crate::pipeline::STAGES[stage as usize], 1000 - on as Day);
            s.batch_id = (batch > 0).then_some(batch as u32);
            s
        };
        for round in 0..40 {
            let mut seats: Vec<Seat> = (1..=60).map(|id| mk(id, next(6), next(10), next(200), next(4), next(3))).collect();
            let mut ix = Index::new(&seats, 1000, &cfg);
            for _ in 0..80 {
                let i = next(60) as usize;
                if next(5) == 0 {
                    ix.update(seats[i].id, None);
                    seats[i].hot = false;
                } else {
                    seats[i] = mk(seats[i].id, next(6), next(10), next(200), next(4), next(3));
                    ix.update(seats[i].id, Some(seats[i].clone()));
                }
                let fresh = Index::new(&seats, 1000, &cfg);
                let probe = mk(999, next(6), 3, 0, next(4), next(3));
                for s in seats.iter().chain([&probe]) {
                    assert_eq!(verdict(&ix, s, &[]), verdict(&fresh, s, &[]), "round {round} seat {}", s.id);
                }
            }
        }
    }

    #[test]
    fn config_from_json_ignores_garbage() {
        let c = Config::from_json(Some(r#"{"small_cap": 2, "mega_cap": -1, "nope": 3, "mid_cap": "x"}"#));
        assert_eq!(c.small_cap, 2.0);
        assert_eq!(c.mega_cap, 4.0);
        assert_eq!(c.mid_cap, 1.5);
        assert_eq!(Config::from_json(Some("[")), Config::default());
        let z = Config::from_json(Some(r#"{"clone_penalty": 0, "load_floor": 0, "cool_ratio": 0.9}"#));
        assert_eq!((z.clone_penalty, z.load_floor, z.cool_ratio, z.hot_ratio), (0.0, 0.05, 0.5, 0.8));
        assert_eq!(Config::from_json(None), Config::default());
    }
}
