//! The heat governor: the campaign must not snap onto one company or one
//! applicant tracking system. Heat gates the submit queue; FIRE HOLD
//! still owns submit, and nothing here sends anything.
//!
//! Every application in a hot stage (`fire_ready` onward) puts a load of
//! `application_load` on its company, its ATS vendor and its ATS tenant,
//! decaying from its `stage_on` day with each one's half-life:
//! `load · 0.5^(days / half_life)`. A company's cap scales with its size
//! tier. An application entering the queue adds its increment: the base
//! load, plus `same_department_penalty` if a hot peer at that company
//! shares its department, plus `clone_penalty` if one shares its role
//! family. The move is deferred when the company would pass its cap, the
//! vendor or tenant would pass theirs, or its batch already holds
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
    /// A key that is unknown, not a number, or not positive and finite is
    /// ignored, so a bad setting can loosen nothing by accident.
    pub fn from_json(json: Option<&str>) -> Config {
        let mut c = Config::default();
        let Some(Ok(serde_json::Value::Object(m))) = json.map(serde_json::from_str::<serde_json::Value>) else {
            return c;
        };
        for (k, v) in m.iter() {
            let Some(x) = v.as_f64().filter(|x| x.is_finite() && *x > 0.0) else { continue };
            if let Some(slot) = c.field(k) {
                *slot = x;
            }
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
    pub company: String,
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
    /// The day its load decays from: the submission once sent, else the
    /// day it entered its stage.
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
    /// Whether it was ever submitted (its rail's `submitted` rung reached).
    pub sent: bool,
    pub score: u8,
    pub batch_id: Option<u32>,
    pub heat_override: bool,
    pub heat_override_reason: &'a str,
}

impl Seat {
    pub fn new(f: &SeatIn) -> Seat {
        let sent = f.sent || f.applied_on.is_some() || f.stage == Stage::Submitted;
        Seat {
            id: f.id,
            company: String::from(f.company.trim()),
            key: f.corporation_id.map_or_else(|| org::company_key(f.company), |c| alloc::format!("#{c}")),
            size: org::size(f.company),
            department: org::department(f.role),
            family: org::family(f.role),
            ats: ats::parse(f.url),
            stage: f.stage,
            hot: f.stage.queued() || (f.stage.after_send() && sent),
            since: if f.stage.after_send() { f.applied_on.or(f.stage_on) } else { f.stage_on },
            score: f.score,
            batch_id: f.batch_id,
            overridden: f.heat_override && !f.heat_override_reason.trim().is_empty(),
        }
    }

    fn age(&self, today: Day) -> i64 {
        self.since.map_or(0, |d| today as i64 - d as i64)
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
    pub tenant: Option<String>,
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

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "allow": self.allow,
            "reason": self.reason.name(),
            "company_load": self.company_load,
            "company_cap": self.company_cap,
            "increment": self.increment,
            "size": self.size.name(),
            "ats_vendor": self.vendor.name(),
            "ats_tenant": self.tenant,
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

/// The hot seats of an account on one day, each seat's decayed loads
/// computed once, grouped by company, vendor, tenant and batch, so a
/// verdict reads only its groups. A group's load is always summed over
/// its members in ascending id order, the asking seat skipped, then any
/// `kept` seats; [`Index::update`] re-sums only the groups a seat leaves
/// or joins. So an index kept current seat by seat, a fresh one, the
/// board, `judge` and `mix` all get bit-identical numbers for the same rows.
pub struct Index {
    today: Day,
    cfg: Config,
    seats: BTreeMap<u32, Seat>,
    by_company: BTreeMap<String, Group>,
    by_vendor: BTreeMap<Vendor, Group>,
    by_tenant: BTreeMap<(Vendor, String), Group>,
    /// Queued members per (batch, vendor).
    by_batch_vendor: BTreeMap<(u32, Vendor), u32>,
}

#[derive(Default)]
struct Group {
    /// Member id → its load at this group's half-life today, 0 under the floor.
    members: BTreeMap<u32, f64>,
    /// The sum over every member, in id order.
    total: f64,
}

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

/// A seat's load at the company, vendor and tenant half-lives `age` days
/// on, 0 under the floor.
fn loads_at(age: i64, cfg: &Config) -> [f64; 3] {
    let at = |half: f64| {
        let l = decay(cfg.application_load, age, half);
        if l >= cfg.load_floor { l } else { 0.0 }
    };
    [at(cfg.company_half_life), at(cfg.ats_vendor_half_life), at(cfg.ats_tenant_half_life)]
}


impl Index {
    /// Indexes (a copy of) the hot seats; the rest carry no load.
    pub fn new<'s>(seats: impl IntoIterator<Item = &'s Seat>, today: Day, cfg: &Config) -> Index {
        let mut ix = Index {
            today,
            cfg: cfg.clone(),
            seats: BTreeMap::new(),
            by_company: BTreeMap::new(),
            by_vendor: BTreeMap::new(),
            by_tenant: BTreeMap::new(),
            by_batch_vendor: BTreeMap::new(),
        };
        for s in seats.into_iter().filter(|s| s.hot) {
            ix.join(s.clone());
        }
        let c: Vec<String> = ix.by_company.keys().cloned().collect();
        let v: Vec<Vendor> = ix.by_vendor.keys().copied().collect();
        let t: Vec<(Vendor, String)> = ix.by_tenant.keys().cloned().collect();
        c.iter().for_each(|k| resum(ix.by_company.get_mut(k)));
        v.iter().for_each(|k| resum(ix.by_vendor.get_mut(k)));
        t.iter().for_each(|k| resum(ix.by_tenant.get_mut(k)));
        ix
    }

    /// Replaces seat `id` with `seat` (or removes it with `None`); a seat
    /// that is not hot is removed. Only the groups it left or joined are
    /// re-summed.
    pub fn update(&mut self, id: u32, seat: Option<Seat>) {
        let old = self.leave(id);
        let new = seat.filter(|s| s.hot).map(|s| self.join(s));
        for (c, v, t, _) in [old, new].into_iter().flatten() {
            if let Some(c) = c {
                resum(self.by_company.get_mut(&c));
            }
            if let Some(v) = v {
                resum(self.by_vendor.get_mut(&v));
            }
            if let Some(t) = t {
                resum(self.by_tenant.get_mut(&t));
            }
        }
    }

    fn join(&mut self, s: Seat) -> Keys {
        let k = keys(&s);
        let l = loads_at(s.age(self.today), &self.cfg);
        let id = s.id;
        if let Some(c) = &k.0 {
            self.by_company.entry(c.clone()).or_default().members.insert(id, l[COMPANY]);
        }
        if let Some(v) = k.1 {
            self.by_vendor.entry(v).or_default().members.insert(id, l[VENDOR]);
        }
        if let Some(t) = &k.2 {
            self.by_tenant.entry(t.clone()).or_default().members.insert(id, l[TENANT]);
        }
        if let Some(bv) = k.3 {
            *self.by_batch_vendor.entry(bv).or_default() += 1;
        }
        self.seats.insert(id, s);
        k
    }

    fn leave(&mut self, id: u32) -> Option<Keys> {
        let s = self.seats.remove(&id)?;
        let k = keys(&s);
        if let Some(c) = &k.0 {
            self.by_company.get_mut(c).map(|g| g.members.remove(&id));
        }
        if let Some(v) = k.1 {
            self.by_vendor.get_mut(&v).map(|g| g.members.remove(&id));
        }
        if let Some(t) = &k.2 {
            self.by_tenant.get_mut(t).map(|g| g.members.remove(&id));
        }
        if let Some(n) = k.3.and_then(|bv| self.by_batch_vendor.get_mut(&bv)) {
            *n -= 1;
        }
        Some(k)
    }

    /// Whether a seat (by id) is one of the indexed hot seats.
    pub fn contains(&self, id: u32) -> bool {
        self.seats.contains_key(&id)
    }

    pub fn today(&self) -> Day {
        self.today
    }

    /// The members of `g` other than `skip`, with their load `dt` days on
    /// at half-life `k` (today's loads when `dt` is 0), in id order.
    fn members<'g>(&'g self, g: &'g Group, k: usize, skip: u32, dt: i64) -> impl Iterator<Item = (&'g Seat, f64)> + 'g {
        g.members.iter().filter(move |(m, _)| **m != skip).filter_map(move |(m, l)| {
            let s = self.seats.get(m)?;
            Some((s, if dt == 0 { *l } else { loads_at(s.age(self.today) + dt, &self.cfg)[k] }))
        })
    }

    /// A group's load for `seat` `dt` days on: the precomputed total when
    /// that is exact, else the members summed in id order; then `kept`.
    fn load(&self, g: Option<&Group>, k: usize, seat: &Seat, kept: &[(&Seat, f64)], dt: i64) -> f64 {
        let mut sum = match g {
            None => 0.0,
            Some(g) if dt == 0 && !g.members.contains_key(&seat.id) => g.total,
            Some(g) => {
                let mut s = 0.0;
                for (_, l) in self.members(g, k, seat.id, dt) {
                    s += l;
                }
                s
            }
        };
        for (_, l) in kept {
            sum += l;
        }
        sum
    }
}

fn resum(g: Option<&mut Group>) {
    if let Some(g) = g {
        let mut t = 0.0;
        for l in g.members.values() {
            t += l;
        }
        g.total = t;
    }
}

/// The governor's check `dt` days after the index's day.
struct Check {
    reason: Reason,
    company_load: f64,
    increment: f64,
    vendor_load: f64,
    tenant_load: f64,
    batch_vendor: u32,
}

fn check(ix: &Index, seat: &Seat, kept: &[&Seat], cfg: &Config, dt: i64) -> Check {
    // Kept seats were admitted in this pass: fresh load, and never one
    // the index already counts.
    let kept: Vec<&Seat> = kept.iter().copied().filter(|p| p.id != seat.id && !ix.contains(p.id)).collect();
    let fresh = loads_at(dt, cfg);
    let in_group = |same: &dyn Fn(&Seat) -> bool, k: usize| -> Vec<(&Seat, f64)> {
        kept.iter().filter(|p| same(p)).map(|p| (*p, fresh[k])).collect()
    };
    let has_key = !seat.key.is_empty();
    let company_group = if has_key { ix.by_company.get(&seat.key) } else { None };
    let kept_company = if has_key { in_group(&|p| p.key == seat.key, COMPANY) } else { Vec::new() };
    let company_load = if has_key { ix.load(company_group, COMPANY, seat, &kept_company, dt) } else { 0.0 };
    // Penalties come from live peers only: a peer under the floor no
    // longer counts for anything.
    let live: Vec<&Seat> = company_group
        .map(|g| ix.members(g, COMPANY, seat.id, dt).filter(|(_, l)| *l > 0.0).map(|(s, _)| s).collect())
        .unwrap_or_default();
    let live = live.into_iter().chain(kept_company.iter().filter(|(_, l)| *l > 0.0).map(|(s, _)| *s));
    let (mut dept, mut fam) = (false, false);
    for p in live {
        dept |= p.department == seat.department;
        fam |= p.family == seat.family;
    }
    let increment = cfg.application_load
        + if dept { cfg.same_department_penalty } else { 0.0 }
        + if fam { cfg.clone_penalty } else { 0.0 };

    let vendor = seat.ats.vendor;
    let known = vendor != Vendor::Unknown;
    let vendor_load = if known {
        ix.load(ix.by_vendor.get(&vendor), VENDOR, seat, &in_group(&|p| p.ats.vendor == vendor, VENDOR), dt)
    } else {
        0.0
    };
    let tenant_load = match (&seat.ats.tenant, known) {
        (Some(t), true) => {
            let same = |p: &Seat| p.ats.vendor == vendor && p.ats.tenant.as_ref() == Some(t);
            ix.load(ix.by_tenant.get(&(vendor, t.clone())), TENANT, seat, &in_group(&same, TENANT), dt)
        }
        _ => 0.0,
    };
    let batch_vendor = match seat.batch_id {
        Some(b) if known => {
            let indexed = ix.by_batch_vendor.get(&(b, vendor)).copied().unwrap_or(0);
            let own = ix.seats.get(&seat.id).is_some_and(|e| keys(e).3 == Some((b, vendor))) as u32;
            let fresh = kept.iter().filter(|p| p.batch_id == Some(b) && p.ats.vendor == vendor).count() as u32;
            indexed - own + fresh
        }
        _ => 0,
    };
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
/// day, against the indexed hot seats plus `kept` (seats already admitted
/// in the same pass). The seat itself is never its own peer.
/// `cooldown_days` is left for [`cooldown`] to fill: `Some(0)` when
/// allowed, else `None`.
pub fn verdict(ix: &Index, seat: &Seat, kept: &[&Seat], cfg: &Config) -> Verdict {
    let c = check(ix, seat, kept, cfg, 0);
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
        tenant: seat.ats.tenant.clone(),
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
/// changing: 0 when it would now, `None` when a batch cap holds it (decay
/// does not move that) or it is still held [`HORIZON_DAYS`] on. Loads and
/// live peers only shrink with time, so the first allowed day is found by
/// bisection over every check at once.
pub fn cooldown(ix: &Index, seat: &Seat, kept: &[&Seat], cfg: &Config) -> Option<u32> {
    let ok = |dt: i64| check(ix, seat, kept, cfg, dt).reason == Reason::Ok;
    if seat.overridden || ok(0) {
        return Some(0);
    }
    if check(ix, seat, kept, cfg, 0).reason == Reason::BatchCap || !ok(HORIZON_DAYS) {
        return None;
    }
    let (mut lo, mut hi) = (0, HORIZON_DAYS);
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if ok(mid) { hi = mid } else { lo = mid }
    }
    Some(hi as u32)
}

/// A batch's mix: candidates in score order (then company, then id), each
/// admitted if the governor allows it against the hot seats and those
/// already admitted. Returns the admitted ids in order and the deferred
/// with their verdicts.
pub fn mix(candidates: &[Seat], ix: &Index, cfg: &Config) -> (Vec<u32>, Vec<(u32, Verdict)>) {
    let mut order: Vec<&Seat> = candidates.iter().collect();
    order.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.key.cmp(&b.key)).then(a.id.cmp(&b.id)));
    let mut kept: Vec<&Seat> = Vec::new();
    let mut deferred = Vec::new();
    for s in order {
        let mut v = verdict(ix, s, &kept, cfg);
        if v.allow {
            kept.push(s);
        } else {
            v.cooldown_days = cooldown(ix, s, &kept, cfg);
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
        let v = verdict(&ix, &next, &[], &cfg);
        assert!(!v.allow);
        assert_eq!(v.reason, Reason::CompanyCap);
        assert_eq!(v.increment, 1.0);
        // The increment fills the cap, so the wait is until the one peer
        // falls under the floor: 35 · log2(1 / 0.05) = 151.3 → 152 days.
        assert_eq!(cooldown(&ix, &next, &[], &cfg), Some(152));
        assert!(verdict(&Index::new(&hot, day + 152, &cfg), &next, &[], &cfg).allow);
        assert!(!verdict(&Index::new(&hot, day + 151, &cfg), &next, &[], &cfg).allow);
        let mega = [seat(1, "Google", "Software Engineer", "", Stage::Submitted, day)];
        let ix = Index::new(&mega, day, &cfg);
        let v = verdict(&ix, &seat(2, "Google", "Software Engineer", "", Stage::Gated, day), &[], &cfg);
        // 1.0 load + 1.0 + 0.6 dept + 0.6 clone = 3.2 ≤ 4.0
        assert!(v.allow);
        assert!((v.increment - 2.2).abs() < 1e-12);
        // Two more admitted in the same pass count fresh; the indexed seat
        // passed as kept is not counted twice.
        let fresh = [seat(3, "Google", "SRE", "", Stage::FireReady, day - 90), seat(4, "Google", "SRE", "", Stage::FireReady, day)];
        let next = seat(2, "Google", "Software Engineer", "", Stage::Gated, day);
        let v2 = verdict(&ix, &next, &[&mega[0], &fresh[0], &fresh[1]], &cfg);
        assert!(!v2.allow);
        assert_eq!(v2.reason, Reason::CompanyCap);
        assert_eq!(v2.company_load, 3.0);
        // load 3.0, room 4.0 − 2.2 = 1.8: 35 · log2(3 / 1.8) = 25.8 → 26 days.
        assert_eq!(cooldown(&ix, &next, &[&fresh[0], &fresh[1]], &cfg), Some(26));
    }

    #[test]
    fn override_needs_a_reason_and_is_reported() {
        let cfg = Config::default();
        let hot = [seat(1, "Acme", "Engineer", "", Stage::Submitted, 0)];
        let ix = Index::new(&hot, 0, &cfg);
        let mut s = seat(2, "Acme", "Engineer", "", Stage::Gated, 0);
        s.overridden = Seat::new(&SeatIn { heat_override: true, heat_override_reason: "  ", ..seat_in() }).overridden;
        assert!(!verdict(&ix, &s, &[], &cfg).allow);
        s.overridden = true;
        let v = verdict(&ix, &s, &[], &cfg);
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
        let v = verdict(&Index::new(&old, 3650, &cfg), &next, &[], &cfg);
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
            (1..=3).map(|i| seat(i, "Corp", "Engineer", url, Stage::Submitted, 0)).map(|mut s| { s.key = alloc::format!("c{}", s.id); s }).collect();
        let ix = Index::new(&hot, 0, &cfg);
        let v = verdict(&ix, &seat(10, "Other", "Engineer", url, Stage::Gated, 0), &[], &cfg);
        assert_eq!(v.reason, Reason::TenantCap);
        assert_eq!(v.tenant.as_deref(), Some("acme"));

        let cfg = Config { ats_batch_cap: 2.0, ..Config::default() };
        let mk = |id: u32, t: &str| {
            let u = alloc::format!("https://jobs.lever.co/{t}/1");
            Seat::new(&SeatIn { id, company: &alloc::format!("Co{id}"), role: "Engineer", url: &u, stage_on: Some(0), batch_id: Some(7), ..seat_in() })
        };
        let cands = [mk(1, "a"), mk(2, "b"), mk(3, "c")];
        let empty: [Seat; 0] = [];
        let (kept, deferred) = mix(&cands, &Index::new(&empty, 0, &cfg), &cfg);
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
                    assert_eq!(verdict(&ix, s, &[], &cfg), verdict(&fresh, s, &[], &cfg), "round {round} seat {}", s.id);
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
        assert_eq!(Config::from_json(None), Config::default());
    }
}
