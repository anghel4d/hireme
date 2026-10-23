//! Which CV root each application gets: one ordered match over the
//! `cv_rules` (by position, then id; the first enabled arm whose mask
//! matches wins), under a pin (`pick_cv`, by the operator or an agent),
//! over the `me` row's default root.
//!
//! A pick's state is `pinned`, `matched` or `default` with its root;
//! `stale` when a pin names a root that is gone; `empty` when the root
//! has no version yet and is not a composition (nothing to send); `none`
//! with no rule, pin or default. `also` lists the other arms that match,
//! so a pin is one click away from any of them.

use alloc::borrow::Cow;
use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use core::cell::OnceCell;

use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::{Value as Json, json};

use crate::mask::{self, Expr, Facts, Val};
use crate::org::{Department, Family, Seniority, Size};
use crate::rows::{Rows, Table};
use crate::score::{self, Tier};
use crate::{ats, lexicon, text};

/// One arm of the match: a rule row, compiled.
pub struct Arm {
    pub id: u32,
    pub root: u32,
    pub enabled: bool,
    /// None when the text does not compile against today's masks.
    pub expr: Option<Expr>,
}

/// The rules in match order, each compiled against the named masks.
pub fn arms(rows: &Rows) -> Vec<Arm> {
    let Some(t) = rows.table(table::CV_RULES) else { return Vec::new() };
    let masks = masks(rows);
    let lookup = |n: &str| masks.iter().find(|(k, _)| *k == n).map(|(_, v)| v.as_ref());
    let mut out: Vec<(u32, Arm)> = t
        .ids()
        .iter()
        .map(|&id| {
            let arm = Arm {
                id,
                root: t.u32(id, col::cv_rules::ROOT_ID).unwrap_or(0),
                enabled: t.u32(id, col::cv_rules::ENABLED) != Some(0),
                expr: mask::compile(&t.text(id, col::cv_rules::PATTERN).unwrap_or_default(), &lookup).ok(),
            };
            (t.u32(id, col::cv_rules::POSITION).unwrap_or(0), arm)
        })
        .collect();
    out.sort_by_key(|(p, a)| (*p, a.id));
    out.into_iter().map(|(_, a)| a).collect()
}

/// The named masks, name to text. A long text arrives packed, so it is
/// read with `text`, which unpacks; `str` would read it as empty.
pub fn masks(rows: &Rows) -> Vec<(&str, Cow<'_, str>)> {
    rows.each(table::CV_MASKS)
        .filter_map(|(t, id)| Some((t.str(id, col::cv_masks::NAME)?, t.text(id, col::cv_masks::PATTERN).unwrap_or_default())))
        .collect()
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum State {
    Pinned,
    Matched,
    Default,
    #[default]
    None,
    Stale,
    Empty,
}

impl State {
    pub fn name(self) -> &'static str {
        ["pinned", "matched", "default", "none", "stale", "empty"][self as usize]
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Pick {
    pub state: State,
    pub root: Option<u32>,
    pub arm: Option<u32>,
    /// The actor code of a pin.
    pub by: Option<u32>,
    pub also: Vec<u32>,
    pub version: Option<u32>,
}

impl Pick {
    pub fn to_json(&self, application: u32) -> Json {
        json!({
            "application": application, "state": self.state.name(), "root": self.root, "arm": self.arm,
            "by": self.by.and_then(|b| enums::actor::NAMES.get(b as usize)), "also": self.also, "version_id": self.version,
        })
    }
}

/// Application `id`'s pick.
pub fn pick(rows: &Rows, arms: &[Arm], counts: &Counts, id: u32) -> Pick {
    let Some(t) = rows.table(table::APPLICATIONS) else { return Pick::default() };
    let roots = rows.table(table::CV_ROOTS);
    let alive = |r: u32| roots.is_some_and(|rt| rt.has(r));
    let facts = AppFacts::new(rows, t, id, counts);
    let hits: Vec<&Arm> = arms.iter().filter(|a| a.enabled && alive(a.root) && a.expr.as_ref().is_some_and(|e| e.matches(&facts))).collect();
    let (state, root, arm, by) = if let Some(r) = t.u32(id, A::CV_ROOT_ID) {
        (if alive(r) { State::Pinned } else { State::Stale }, Some(r), None, t.u32(id, A::CV_PINNED_BY))
    } else if let Some(a) = hits.first() {
        (State::Matched, Some(a.root), Some(a.id), None)
    } else if let Some(r) = rows.first(table::ME).and_then(|(m, mid)| m.u32(mid, col::me::CV_DEFAULT_ROOT_ID)).filter(|r| alive(*r)) {
        (State::Default, Some(r), None, None)
    } else {
        (State::None, None, None, None)
    };
    let version = root.filter(|_| state != State::Stale).and_then(|r| roots.and_then(|rt| rt.u32(r, col::cv_roots::VERSION_ID)));
    let composed = root.and_then(|r| roots.and_then(|rt| rt.u32(r, col::cv_roots::FORMAT))) == Some(enums::cv_format::COMPOSED as u32);
    let state = if matches!(state, State::Pinned | State::Matched | State::Default) && version.is_none() && !composed { State::Empty } else { state };
    let also = hits.iter().map(|a| a.id).filter(|a| Some(*a) != arm).collect();
    Pick { state, root, arm, by, also, version }
}

/// Per arm, whether application `id` matches it, else the test that failed.
pub fn explain(rows: &Rows, arms: &[Arm], id: u32) -> Json {
    let counts = Counts::of(rows);
    let Some(t) = rows.table(table::APPLICATIONS).filter(|t| t.has(id)) else { return Json::Array(Vec::new()) };
    let facts = AppFacts::new(rows, t, id, &counts);
    arms.iter()
        .map(|a| match &a.expr {
            None => json!({"arm": a.id, "matched": false, "error": "the rule does not compile"}),
            Some(e) => match e.explain(&facts) {
                None => json!({"arm": a.id, "matched": true, "enabled": a.enabled}),
                Some(f) => json!({"arm": a.id, "matched": false, "failed": {"at": f.span.at, "len": f.span.len, "read": f.read}}),
            },
        })
        .collect()
}

/// A rule text at `position` (0-based in match order; the end for a new
/// rule) checked against the masks and today's applications: whether it
/// compiles, the earlier arms that take every application it matches,
/// and whether it matches any at all.
pub fn check(rows: &Rows, arms: &[Arm], text: &str, position: Option<usize>) -> Json {
    let masks = masks(rows);
    let lookup = |n: &str| masks.iter().find(|(k, _)| *k == n).map(|(_, v)| v.as_ref());
    let e = match mask::compile(text, &lookup) {
        Ok(e) => e,
        Err(err) => return json!({"ok": false, "error": {"pos": err.span.at, "len": err.span.len, "msg": err.msg}, "shadowed": []}),
    };
    let earlier = &arms[..position.unwrap_or(arms.len()).min(arms.len())];
    let mut matched = 0usize;
    let mut taken = 0usize;
    let mut by: Vec<u32> = Vec::new();
    if let Some(t) = rows.table(table::APPLICATIONS) {
        let counts = Counts::of(rows);
        for &id in t.ids() {
            let facts = AppFacts::new(rows, t, id, &counts);
            if !e.matches(&facts) {
                continue;
            }
            matched += 1;
            if let Some(a) = earlier.iter().find(|a| a.enabled && a.expr.as_ref().is_some_and(|x| x.matches(&facts))) {
                taken += 1;
                if !by.contains(&a.id) {
                    by.push(a.id);
                }
            }
        }
    }
    let shadowed = if matched > 0 && taken == matched { by } else { Vec::new() };
    json!({"ok": true, "error": null, "shadowed": shadowed, "never_matches": matched == 0})
}

/// The facts of one application, read on demand.
pub struct AppFacts<'r> {
    rows: &'r Rows,
    t: &'r Table,
    id: u32,
    counts: &'r Counts,
    name: OnceCell<lexicon::Hits>,
    title: OnceCell<(Department, Family, Seniority)>,
}

impl<'r> AppFacts<'r> {
    pub fn new(rows: &'r Rows, t: &'r Table, id: u32, counts: &'r Counts) -> AppFacts<'r> {
        AppFacts { rows, t, id, counts, name: OnceCell::new(), title: OnceCell::new() }
    }

    fn place(&self) -> Option<(&'r Table, u32)> {
        let p = self.t.u32(self.id, A::PLACE_ID)?;
        self.rows.table(table::PLACES).filter(|pt| pt.has(p)).map(|pt| (pt, p))
    }

    /// The application's country: its place, or the place's country.
    fn country(&self) -> Option<(&'r Table, u32)> {
        let (pt, p) = self.place()?;
        country_of(pt, p).map(|c| (pt, c))
    }

    fn corp(&self) -> Option<(&'r Table, u32)> {
        let c = self.t.u32(self.id, A::CORPORATION_ID)?;
        self.rows.table(table::CORPORATIONS).filter(|ct| ct.has(c)).map(|ct| (ct, c))
    }

    fn iso2(&self, place: Option<u32>) -> Option<Val<'r>> {
        let pt = self.rows.table(table::PLACES)?;
        pt.str(place?, col::places::ISO2).map(|c| Val::Code(Cow::Borrowed(c)))
    }

    fn name_hits(&self) -> lexicon::Hits {
        *self.name.get_or_init(|| {
            let name = self.corp().and_then(|(ct, c)| ct.str(c, col::corporations::NAME)).or(self.t.str(self.id, A::COMPANY)).unwrap_or("");
            lexicon::Hits::of(&text::normalize(name))
        })
    }

    fn role(&self) -> (Department, Family, Seniority) {
        *self.title.get_or_init(|| {
            let n = text::normalize(self.t.str(self.id, A::ROLE).unwrap_or(""));
            let (h, fam) = lexicon::Hits::title(&n);
            (Department::of_hits(h), Family::of_hits(fam), Seniority::of(&n))
        })
    }
}

fn texts(joined: &str) -> Val<'_> {
    Val::List(text::list(joined).map(|s| Val::Text(Cow::Borrowed(s))).collect())
}

fn codes(joined: &str) -> Val<'_> {
    Val::List(text::list(joined).map(|s| Val::Code(Cow::Borrowed(s))).collect())
}

fn bits(set: u32) -> Val<'static> {
    Val::List((0..32).filter(|b| set & (1 << b) != 0).map(Val::Enum).collect())
}

impl Facts for AppFacts<'_> {
    fn read(&self, field: usize) -> Option<Val<'_>> {
        let (t, id) = (self.t, self.id);
        let s = |c: u16| t.str(id, c).map(|v| Val::Text(Cow::Borrowed(v)));
        let e = |c: u16| t.u32(id, c).map(Val::Enum);
        let corp_s = |c: u16| self.corp().and_then(|(ct, x)| ct.str(x, c)).map(|v| Val::Text(Cow::Borrowed(v)));
        let me = self.rows.first(table::ME);
        let me_s = |c: u16| me.and_then(|(m, x)| m.str(x, c));
        let me_u = |c: u16| me.and_then(|(m, x)| m.u32(x, c));
        match mask::FIELDS.get(field)?.path {
            "id" => Some(Val::Num(id as f64)),
            "no" => t.u32(id, A::NO).map(|v| Val::Num(v as f64)),
            "place" => self.place().and_then(|(pt, p)| pt.str(p, col::places::NAME)).map(|v| Val::Text(Cow::Borrowed(v))),
            "company.parent" => {
                let (ct, c) = self.corp()?;
                let parent = ct.u32(c, col::corporations::PARENT_ID).filter(|p| ct.has(*p))?;
                ct.str(parent, col::corporations::NAME).map(|v| Val::Text(Cow::Borrowed(v)))
            }
            "office" => {
                let (corp, place) = (t.u32(id, A::CORPORATION_ID)?, t.u32(id, A::PLACE_ID)?);
                self.rows
                    .each(table::OFFICES)
                    .find(|(ot, o)| ot.u32(*o, col::offices::CORPORATION_ID) == Some(corp) && ot.u32(*o, col::offices::PLACE_ID) == Some(place))
                    .and_then(|(ot, o)| ot.u32(o, col::offices::KIND))
                    .map(Val::Enum)
            }
            "company.applications" => self.counts.corp.get(&t.u32(id, A::CORPORATION_ID)?).map(|n| Val::Num(*n as f64)),
            "company.parent.applications" => {
                let (ct, c) = self.corp()?;
                self.counts.group.get(&group_of(ct, c)).map(|n| Val::Num(*n as f64))
            }
            "country.applications" => self.counts.country.get(&self.country()?.1).map(|n| Val::Num(*n as f64)),
            "company" => s(A::COMPANY),
            "role" => s(A::ROLE),
            "location" => s(A::LOCATION),
            "work_mode" => e(A::WORK_MODE),
            "employment" => e(A::EMPLOYMENT),
            "channel" => e(A::CHANNEL),
            "stage" => e(A::STAGE),
            "status" => e(A::STATUS),
            "gate" => e(A::GATE),
            "score" => t.u32(id, A::SCORE_100).map(|v| Val::Num(v as f64)),
            "band" => t.u32(id, A::SCORE_100).map(|v| Val::Enum(score::Band::of(v.min(100) as u8) as u32)),
            "keywords" => t.str(id, A::KEYWORDS).map(texts),
            "listing_on" => t.u32(id, A::LISTING_ON).map(|d| Val::Day(d as crate::Day)),
            "country" => self.iso2(self.country().map(|c| c.1)),
            "city" => {
                let (pt, p) = self.place()?;
                (pt.u32(p, col::places::KIND) != Some(enums::place_kind::COUNTRY as u32)).then(|| pt.str(p, col::places::NAME)).flatten().map(|v| Val::Text(Cow::Borrowed(v)))
            }
            "region" => self.country().and_then(|(pt, c)| pt.str(c, col::places::REGION)).map(|v| Val::Text(Cow::Borrowed(v))),
            "subregion" => self.country().and_then(|(pt, c)| pt.str(c, col::places::SUBREGION)).map(|v| Val::Text(Cow::Borrowed(v))),
            "company.domain" => corp_s(col::corporations::DOMAIN),
            "company.name" => corp_s(col::corporations::NAME),
            "company.industry" => corp_s(col::corporations::INDUSTRY),
            "company.sector" => corp_s(col::corporations::SECTOR),
            "company.size" => Some(Val::Enum(Size::of_hits(self.name_hits()) as u32)),
            "company.tier" => Some(Val::Enum(Tier::of_hits(self.name_hits()) as u32)),
            "company.ownership" => self.corp().and_then(|(ct, x)| ct.u32(x, col::corporations::OWNERSHIP)).map(Val::Enum),
            "company.remote_policy" => self.corp().and_then(|(ct, x)| ct.u32(x, col::corporations::REMOTE_POLICY)).map(Val::Enum),
            "company.ats" => t.str(id, A::LISTING_URL).map(|u| Val::Enum(ats::parse(u).vendor as u32)),
            "company.headcount" => self.corp().and_then(|(ct, x)| ct.u32(x, col::corporations::HEADCOUNT)).map(|v| Val::Num(v as f64)),
            "company.hq" => self.iso2(self.corp().and_then(|(ct, x)| ct.u32(x, col::corporations::HQ_PLACE_ID))),
            "field" => Some(Val::Enum(self.role().0 as u32)),
            "subfield" => Some(Val::Enum(self.role().1 as u32)),
            "seniority" => Some(Val::Enum(self.role().2 as u32)),
            "me.citizenships" => me_s(col::me::CITIZENSHIPS).map(codes),
            "me.field" => me_s(col::me::FIELD).map(|v| Val::Text(Cow::Borrowed(v))),
            "me.subfields" => me_s(col::me::SUBFIELDS).map(texts),
            "me.residence" => self.iso2(me_u(col::me::RESIDENCE_ID)),
            "me.regions" => me_s(col::me::REGIONS).map(codes),
            "me.relocate" => me_u(col::me::RELOCATE).map(|v| Val::Bool(v != 0)),
            "me.work_modes" => me_u(col::me::WORK_MODES).map(bits),
            "me.employments" => me_u(col::me::EMPLOYMENTS).map(bits),
            "me.pay_floor" => me_u(col::me::PAY_FLOOR).map(|v| Val::Num(v as f64)),
            "me.available_on" => me_u(col::me::AVAILABLE_ON).map(|d| Val::Day(d as crate::Day)),
            "me.notice_days" => me_u(col::me::NOTICE_DAYS).map(|v| Val::Num(v as f64)),
            "me.languages" => {
                let langs: Vec<Val<'_>> =
                    self.rows.each(table::LANGUAGES).filter_map(|(lt, x)| lt.str(x, col::languages::CODE)).map(|c| Val::Code(Cow::Borrowed(c))).collect();
                (!langs.is_empty()).then_some(Val::List(langs))
            }
            _ => None,
        }
    }
}

/// The compiled rules and every application's pick under them.
pub struct Picks {
    pub arms: Vec<Arm>,
    pub by: BTreeMap<u32, Pick>,
}

impl Picks {
    /// Brings the picks of the applications `ids` up to date after they were
    /// written in place. False when a rule reads a count (which every
    /// application moves): the caller computes them all again.
    pub fn mend(&mut self, rows: &Rows, ids: &[u32]) -> bool {
        let counted = self.arms.iter().filter_map(|a| a.expr.as_ref()).any(|e| e.fields().iter().any(|&f| mask::FIELDS[f].path.ends_with(".applications")));
        if counted {
            return false;
        }
        let counts = Counts::default();
        for &id in ids {
            // A written row may be gone (a rolled-back write that had brought it back).
            if rows.table(table::APPLICATIONS).is_some_and(|t| t.slot(id).is_some()) {
                self.by.insert(id, pick(rows, &self.arms, &counts, id));
            } else {
                self.by.remove(&id);
            }
        }
        true
    }

    pub fn of(rows: &Rows) -> Picks {
        let arms = arms(rows);
        let counts = Counts::of(rows);
        let by = rows.table(table::APPLICATIONS).map_or_else(BTreeMap::new, |t| t.ids().iter().map(|&id| (id, pick(rows, &arms, &counts, id))).collect());
        Picks { arms, by }
    }
}

/// How many applications name each corporation, each corporation group (a
/// parent and its children) and each country: the `*.applications`
/// fields, tallied once per read of the rows.
#[derive(Default)]
pub struct Counts {
    corp: BTreeMap<u32, u32>,
    group: BTreeMap<u32, u32>,
    country: BTreeMap<u32, u32>,
}

impl Counts {
    pub fn of(rows: &Rows) -> Counts {
        let mut c = Counts::default();
        let Some(t) = rows.table(table::APPLICATIONS) else { return c };
        let corps = rows.table(table::CORPORATIONS);
        let places = rows.table(table::PLACES);
        for &id in t.ids() {
            if let Some(corp) = t.u32(id, A::CORPORATION_ID) {
                *c.corp.entry(corp).or_default() += 1;
                if let Some(ct) = corps.filter(|ct| ct.has(corp)) {
                    *c.group.entry(group_of(ct, corp)).or_default() += 1;
                }
            }
            if let (Some(pt), Some(p)) = (places, t.u32(id, A::PLACE_ID))
                && let Some(country) = country_of(pt, p)
            {
                *c.country.entry(country).or_default() += 1;
            }
        }
        c
    }
}

/// A corporation's group: its parent when it has a live one, else itself.
fn group_of(corps: &Table, c: u32) -> u32 {
    corps.u32(c, col::corporations::PARENT_ID).filter(|p| corps.has(*p)).unwrap_or(c)
}

/// A place's country: itself when it is one, else the country it is in.
fn country_of(places: &Table, p: u32) -> Option<u32> {
    if !places.has(p) {
        return None;
    }
    if places.u32(p, col::places::KIND) == Some(enums::place_kind::COUNTRY as u32) {
        return Some(p);
    }
    places.u32(p, col::places::COUNTRY_ID).filter(|c| places.has(*c))
}
