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
    pub key: String,
    pub size: Size,
    pub department: Department,
    pub family: Family,
    pub ats: Ats,
    pub stage: Stage,
    pub stage_on: Option<Day>,
    pub score: u8,
    pub batch_id: Option<u32>,
    /// The override flag with a non-blank reason; either alone is nothing.
    pub overridden: bool,
}

/// The raw fields a [`Seat`] is read from.
pub struct SeatIn<'a> {
    pub id: u32,
    pub company: &'a str,
    pub role: &'a str,
    pub url: &'a str,
    pub stage: Stage,
    pub stage_on: Option<Day>,
    pub score: Option<u8>,
    pub batch_id: Option<u32>,
    pub heat_override: bool,
    pub heat_override_reason: &'a str,
}

impl Seat {
    pub fn new(f: &SeatIn) -> Seat {
        Seat {
            id: f.id,
            company: String::from(f.company.trim()),
            key: org::company_key(f.company),
            size: org::size(f.company),
            department: org::department(f.role),
            family: org::family(f.role),
            ats: ats::parse(f.url),
            stage: f.stage,
            stage_on: f.stage_on,
            score: f.score.unwrap_or(0),
            batch_id: f.batch_id,
            overridden: f.heat_override && !f.heat_override_reason.trim().is_empty(),
        }
    }

    fn age(&self, today: Day) -> i64 {
        self.stage_on.map_or(0, |d| today as i64 - d as i64)
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
    /// Days until the deferred move would fit, with nothing else changing;
    /// `None` when it never fits (the increment alone is over the cap).
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
    /// Per hot seat: the seat and its decayed load at the company, vendor
    /// and tenant half-lives, 0 under the floor.
    seats: BTreeMap<u32, (Seat, [f64; 3])>,
    by_company: BTreeMap<String, Group>,
    by_vendor: BTreeMap<Vendor, Group>,
    by_tenant: BTreeMap<(Vendor, String), Group>,
    by_batch_vendor: BTreeMap<(u32, Vendor), u32>,
}

#[derive(Default)]
struct Group {
    /// Member id → its load at this group's half-life.
    members: BTreeMap<u32, f64>,
    /// The sum over every member, in id order.
    total: f64,
}

const COMPANY: usize = 0;
const VENDOR: usize = 1;
const TENANT: usize = 2;

/// The group keys a seat belongs to.
fn keys(s: &Seat) -> (Option<String>, Option<Vendor>, Option<(Vendor, String)>, Option<(u32, Vendor)>) {
    let known = s.ats.vendor != Vendor::Unknown;
    (
        (!s.key.is_empty()).then(|| s.key.clone()),
        known.then_some(s.ats.vendor),
        s.ats.tenant.clone().filter(|_| known).map(|t| (s.ats.vendor, t)),
        s.batch_id.filter(|_| known).map(|b| (b, s.ats.vendor)),
    )
}

impl Index {
    /// Indexes (a copy of) the seats in hot stages; the rest carry no load.
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
        for s in seats.into_iter().filter(|s| s.stage.hot()) {
            ix.join(s.clone());
        }
        let (c, v, t) = (ix.by_company.keys().cloned().collect::<Vec<_>>(), ix.by_vendor.keys().copied().collect::<Vec<_>>(), ix.by_tenant.keys().cloned().collect::<Vec<_>>());
        for k in c {
            ix.resum_company(&k);
        }
        for k in v {
            ix.resum_vendor(k);
        }
        for k in t {
            ix.resum_tenant(&k);
        }
        ix
    }

    /// Replaces seat `id` with `seat` (or removes it with `None`); a seat
    /// that is not hot is removed. Only the groups it left or joined are
    /// re-summed.
    pub fn update(&mut self, id: u32, seat: Option<Seat>) {
        let old = self.leave(id);
        let new = seat.filter(|s| s.stage.hot()).map(|s| self.join(s));
        for (c, v, t, _) in [old, new].into_iter().flatten() {
            if let Some(c) = c {
                self.resum_company(&c);
            }
            if let Some(v) = v {
                self.resum_vendor(v);
            }
            if let Some(t) = t {
                self.resum_tenant(&t);
            }
        }
    }

    #[allow(clippy::type_complexity)]
    fn join(&mut self, s: Seat) -> (Option<String>, Option<Vendor>, Option<(Vendor, String)>, Option<(u32, Vendor)>) {
        let k = keys(&s);
        let id = s.id;
        let l = loads(&s, self.today, &self.cfg);
        self.seats.insert(id, (s, l));
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
        k
    }

    #[allow(clippy::type_complexity)]
    fn leave(&mut self, id: u32) -> Option<(Option<String>, Option<Vendor>, Option<(Vendor, String)>, Option<(u32, Vendor)>)> {
        let (s, _) = self.seats.remove(&id)?;
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
        if let Some(bv) = k.3 {
            if let Some(n) = self.by_batch_vendor.get_mut(&bv) {
                *n -= 1;
            }
        }
        Some(k)
    }

    fn sum(g: &Group, skip: u32) -> f64 {
        let mut s = 0.0;
        for (m, l) in &g.members {
            if *m != skip {
                s += l;
            }
        }
        s
    }

    fn resum_company(&mut self, c: &str) {
        if let Some(g) = self.by_company.get(c) {
            let t = Index::sum(g, u32::MAX);
            self.by_company.get_mut(c).map(|g| g.total = t);
        }
    }

    fn resum_vendor(&mut self, v: Vendor) {
        if let Some(g) = self.by_vendor.get(&v) {
            let t = Index::sum(g, u32::MAX);
            self.by_vendor.get_mut(&v).map(|g| g.total = t);
        }
    }

    fn resum_tenant(&mut self, k: &(Vendor, String)) {
        if let Some(g) = self.by_tenant.get(k) {
            let t = Index::sum(g, u32::MAX);
            self.by_tenant.get_mut(k).map(|g| g.total = t);
        }
    }

    /// Whether a seat (by id) is one of the indexed hot seats.
    pub fn contains(&self, id: u32) -> bool {
        self.seats.contains_key(&id)
    }

    pub fn today(&self) -> Day {
        self.today
    }

    /// A group's load for `seat`: the total when the seat is not a
    /// member, else the members' sum without it; then `kept`.
    fn load(&self, g: Option<&Group>, k: usize, seat: &Seat, kept: &[(&Seat, [f64; 3])], same: impl Fn(&Seat) -> bool) -> f64 {
        let mut sum = match g {
            None => 0.0,
            Some(g) if !g.members.contains_key(&seat.id) => g.total,
            Some(g) => Index::sum(g, seat.id),
        };
        for (p, l) in kept {
            if p.id != seat.id && same(p) {
                sum += l[k];
            }
        }
        sum
    }
}

fn loads(s: &Seat, today: Day, cfg: &Config) -> [f64; 3] {
    let at = |half: f64| {
        let l = decay(cfg.application_load, s.age(today), half);
        if l >= cfg.load_floor { l } else { 0.0 }
    };
    [at(cfg.company_half_life), at(cfg.ats_vendor_half_life), at(cfg.ats_tenant_half_life)]
}

/// The governor's verdict on `seat` entering the queue on the index's
/// day, against the indexed hot seats plus `kept` (seats already admitted in the same
/// pass, which count as fresh peers). The seat itself is never its own
/// peer.
pub fn verdict(ix: &Index, seat: &Seat, kept: &[&Seat], cfg: &Config) -> Verdict {
    let kept: Vec<(&Seat, [f64; 3])> = kept.iter().map(|p| (*p, loads(p, ix.today, cfg))).collect();
    let others = |g: Option<&Group>| -> Vec<&Seat> {
        let mut v: Vec<&Seat> = g
            .map(|g| g.members.keys().filter(|&&m| m != seat.id).filter_map(|m| ix.seats.get(m).map(|e| &e.0)).collect())
            .unwrap_or_default();
        v.extend(kept.iter().map(|k| k.0).filter(|p| p.id != seat.id && p.key == seat.key));
        v
    };
    let company_group = if seat.key.is_empty() { None } else { ix.by_company.get(&seat.key) };
    let company_load =
        if seat.key.is_empty() { 0.0 } else { ix.load(company_group, COMPANY, seat, &kept, |p| p.key == seat.key) };
    let company_cap = cfg.cap(seat.size);
    // Department and family only matter among the company's peers, which
    // are few; the vendor's are not walked per seat.
    let company: Vec<&Seat> = if seat.key.is_empty() { Vec::new() } else { others(company_group) };
    let increment = cfg.application_load
        + if company.iter().any(|p| p.department == seat.department) { cfg.same_department_penalty } else { 0.0 }
        + if company.iter().any(|p| p.family == seat.family) { cfg.clone_penalty } else { 0.0 };

    let vendor = seat.ats.vendor;
    let known = vendor != Vendor::Unknown;
    let vendor_load = if known { ix.load(ix.by_vendor.get(&vendor), VENDOR, seat, &kept, |p| p.ats.vendor == vendor) } else { 0.0 };
    let tenant_load = match (&seat.ats.tenant, known) {
        (Some(t), true) => ix.load(ix.by_tenant.get(&(vendor, t.clone())), TENANT, seat, &kept, |p| {
            p.ats.vendor == vendor && p.ats.tenant.as_ref() == Some(t)
        }),
        _ => 0.0,
    };
    let batch_vendor = match seat.batch_id {
        Some(b) if known => {
            let indexed = ix.by_batch_vendor.get(&(b, vendor)).copied().unwrap_or(0);
            let own = ix.seats.get(&seat.id).is_some_and(|e| e.0.batch_id == Some(b) && e.0.ats.vendor == vendor) as u32;
            let fresh = kept.iter().filter(|k| k.0.id != seat.id && k.0.batch_id == Some(b) && k.0.ats.vendor == vendor).count() as u32;
            indexed - own + fresh
        }
        _ => 0,
    };

    let tenant = seat.ats.tenant.is_some();
    let (reason, cooldown) = if known && batch_vendor as f64 >= cfg.ats_batch_cap {
        (Reason::BatchCap, None)
    } else if known && vendor_load + cfg.application_load > cfg.ats_vendor_cap {
        (Reason::VendorCap, cooldown(vendor_load, cfg.application_load, cfg.ats_vendor_cap, cfg.ats_vendor_half_life, cfg.load_floor))
    } else if tenant && tenant_load + cfg.application_load > cfg.ats_tenant_cap {
        (Reason::TenantCap, cooldown(tenant_load, cfg.application_load, cfg.ats_tenant_cap, cfg.ats_tenant_half_life, cfg.load_floor))
    } else if company_load + increment > company_cap {
        (Reason::CompanyCap, cooldown(company_load, increment, company_cap, cfg.company_half_life, cfg.load_floor))
    } else {
        (Reason::Ok, Some(0))
    };
    let (allow, reason) = match reason {
        Reason::Ok => (true, Reason::Ok),
        _ if seat.overridden => (true, Reason::Override),
        r => (false, r),
    };
    Verdict {
        allow,
        reason,
        company_load,
        company_cap,
        increment,
        size: seat.size,
        vendor,
        tenant: seat.ats.tenant.clone(),
        vendor_load,
        vendor_cap: cfg.ats_vendor_cap,
        tenant_load,
        tenant_cap: cfg.ats_tenant_cap,
        batch_vendor,
        cooldown_days: if allow { Some(0) } else { cooldown },
    }
}

/// Days until a decaying `load` leaves room for `increment` under `cap`.
/// Total load decays as a whole at one half-life, so the wait is
/// `half_life · log2(load / (cap − increment))`, rounded up. When the
/// increment fills the cap exactly, the wait is until the load falls
/// under the floor (exact for one peer, an upper bound for several).
fn cooldown(load: f64, increment: f64, cap: f64, half_life: f64, floor: f64) -> Option<u32> {
    if increment > cap {
        return None;
    }
    if load + increment <= cap || load <= 0.0 {
        return Some(0);
    }
    let room = cap - increment;
    let target = if room > 0.0 { room } else { floor };
    let days = half_life * libm::log2(load / target);
    Some(libm::ceil(days).max(0.0) as u32)
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
        let v = verdict(ix, s, &kept, cfg);
        if v.allow {
            kept.push(s);
        } else {
            deferred.push((s.id, v));
        }
    }
    (kept.iter().map(|s| s.id).collect(), deferred)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seat(id: u32, company: &str, role: &str, url: &str, stage: Stage, on: Day) -> Seat {
        Seat::new(&SeatIn {
            id,
            company,
            role,
            url,
            stage,
            stage_on: Some(on),
            score: Some(50),
            batch_id: None,
            heat_override: false,
            heat_override_reason: "",
        })
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
        assert_eq!(v.cooldown_days, Some(152));
        assert!(verdict(&Index::new(&hot, day + 152, &cfg), &next, &[], &cfg).allow);
        assert!(!verdict(&Index::new(&hot, day + 151, &cfg), &next, &[], &cfg).allow);
        let mega = [seat(1, "Google", "Software Engineer", "", Stage::Submitted, day)];
        let ix = Index::new(&mega, day, &cfg);
        let v = verdict(&ix, &seat(2, "Google", "Software Engineer", "", Stage::Gated, day), &[], &cfg);
        // 1.0 load + 1.0 + 0.6 dept + 0.6 clone = 3.2 ≤ 4.0
        assert!(v.allow);
        assert!((v.increment - 2.2).abs() < 1e-12);
        let v2 = verdict(&ix, &seat(2, "Google", "Software Engineer", "", Stage::Gated, day), &[&mega[0], &mega[0]], &cfg);
        assert!(!v2.allow);
        assert_eq!(v2.reason, Reason::CompanyCap);
        // load 3.0, room 4.0 − 2.2 = 1.8: 35 · log2(3 / 1.8) = 25.8 → 26 days.
        assert_eq!(v2.cooldown_days, Some(26));
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
            company: "",
            role: "",
            url: "",
            stage: Stage::Gated,
            stage_on: None,
            score: None,
            batch_id: None,
            heat_override: false,
            heat_override_reason: "",
        }
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
            let mut s = seat(id, &alloc::format!("Co{id}"), "Engineer", &u, Stage::Gated, 0);
            s.batch_id = Some(7);
            s
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
                    seats[i].stage = Stage::Discovered;
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
