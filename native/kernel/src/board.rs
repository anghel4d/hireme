//! The desk's board: every application as a card, ranked, filtered,
//! searched and walked with the keyboard, and the scoreboard over them.
//!
//! Order: `score_100` high to low (a stored number, else the Life-EV
//! suggestion), then heat cool to blocked, then the projected company
//! load, then `no`. A card's heat is the governor's verdict on it
//! entering the queue now, against the hot applications (its own load
//! excluded), so a card already in the queue shows how crowded its
//! company is without counting itself.
//!
//! What each card derives from its own row (its governor seat and its
//! suggestion) is kept between derives and recomputed only for the rows a
//! frame or a write moved; the me row or a place moving recomputes
//! all of them, since "home" is read from both.

use alloc::string::String;
use alloc::vec::Vec;

use schema::col::applications as A;
use schema::{col, enums, table};

use crate::heat::{self, Class, Seat, SeatIn};
use crate::lexicon::Hits;
use crate::org::{Department, Family, Size};
use crate::pipeline::Stage;
use crate::rows::{Moved, Row, Rows, Table};
use crate::score::{self, Band, Suggestion};
use crate::{text, Day};

/// One card's derived values.
#[derive(Clone, Debug, PartialEq)]
pub struct Card {
    pub id: u32,
    pub no: u32,
    pub stage: Stage,
    /// The score the card ranks by.
    pub score: u8,
    /// Whether `score` is a stored number rather than the suggestion.
    pub stored: bool,
    pub band: Band,
    pub suggestion: Suggestion,
    pub class: Class,
    pub verdict: heat::Verdict,
}

#[derive(Clone, Debug)]
struct Cached {
    seat: Seat,
    suggestion: Suggestion,
    no: u32,
    stored: Option<u8>,
    search: String,
}

/// What narrows the board. Empty masks and search mean everything.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Filter {
    /// Bit `Band as u8`.
    pub bands: u8,
    /// Bit `Stage as u8`.
    pub stages: u16,
    /// Bit `Class as u8`.
    pub classes: u8,
    pub min_score: u8,
    /// Words that must all occur in the company, role, location or `#no`.
    pub search: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    Next,
    Prev,
    Up,
    Down,
    First,
    Last,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Scoreboard {
    pub total: u32,
    pub by_stage: [u32; 10],
    pub by_band: [u32; 8],
    pub by_class: [u32; 4],
    /// Applications whose rail reached `submitted`, all time and today (an
    /// outreach answered without a submission is not one).
    pub submitted: u32,
    pub submitted_today: u32,
    pub goal_total: Option<u32>,
    pub goal_daily: Option<u32>,
    /// Days from today to `goal_on`; negative once past.
    pub goal_days_left: Option<i32>,
}

impl Scoreboard {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "total": self.total, "by_stage": self.by_stage, "by_band": self.by_band, "by_class": self.by_class,
            "submitted": self.submitted, "submitted_today": self.submitted_today,
            "goal_total": self.goal_total, "goal_daily": self.goal_daily, "goal_days_left": self.goal_days_left,
        })
    }
}

#[derive(Default)]
pub struct Board {
    cache: crate::fx::Map<u32, Cached>,
    cards: Vec<Card>,
    /// Card index by application id.
    at: crate::fx::Map<u32, usize>,
    /// Every card id in board order.
    order: Vec<u32>,
    config: heat::Config,
    /// The governor's index of hot seats, for the day and config it was
    /// built with, kept current as applications move.
    governor: Option<(Day, heat::Config, heat::Index)>,
    /// The settings' citizenships, parsed once per settings change.
    citizens: Option<Vec<String>>,
    lines: Option<Lines>,
    /// Each distinct company, title and location an application carries,
    /// normalized and read once (a desk repeats them); dropped with the
    /// applications on a BOOT.
    names: Memo<Name>,
    titles: Memo<Title>,
    places: Memo<score::Facts>,
}

/// Values by text. Each text is hashed once with the seeded hash a hostile
/// text cannot aim collisions at (`keyed`), and that hash indexes a cheap
/// map; a text whose hash another holds replaces it.
struct Memo<V> {
    keys: crate::keyed::Seed,
    by: crate::fx::Map<u64, (String, V)>,
}

impl<V> Default for Memo<V> {
    fn default() -> Self {
        Memo { keys: crate::keyed::Seed::default(), by: crate::fx::Map::default() }
    }
}

impl<V> Memo<V> {
    fn get_or(&mut self, text: &str, read: impl FnOnce() -> V) -> &V {
        use core::hash::BuildHasher;
        use std::collections::hash_map::Entry;
        let slot = match self.by.entry(self.keys.hash_one(text)) {
            Entry::Occupied(mut e) => {
                if e.get().0 != text {
                    *e.get_mut() = (String::from(text), read());
                }
                e.into_mut()
            }
            Entry::Vacant(e) => e.insert((String::from(text), read())),
        };
        &slot.1
    }

    fn clear(&mut self) {
        self.by.clear();
    }
}

/// A company name as read once: normalized, its size, its score facts and
/// anchor tier.
#[derive(Clone)]
struct Name {
    normalized: String,
    size: crate::org::Size,
    facts: score::Facts,
    tier: score::Tier,
}

/// A role title as read once.
#[derive(Clone, Copy)]
struct Title {
    department: crate::org::Department,
    family: crate::org::Family,
    facts: score::Facts,
}

/// Which lineage tells each corporation's story and which of its lines
/// have been told, kept current row by row, so judging an overlay reads
/// two lookups instead of every overlay.
#[derive(Default)]
pub struct Lines {
    lineage_of_corp: crate::fx::Map<u32, u32>,
    corp_of_lineage: crate::fx::Map<u32, u32>,
    line_of_overlay: crate::fx::Map<u32, (u32, u32)>,
    overlays_on_line: crate::fx::Map<(u32, u32), u32>,
    /// Overlay ids per lineage and per application, for composing a CV
    /// without a scan.
    overlays_of_lineage: crate::fx::Map<u32, alloc::collections::BTreeSet<u32>>,
    overlays_of_app: crate::fx::Map<u32, alloc::collections::BTreeSet<u32>>,
    app_of_overlay: crate::fx::Map<u32, u32>,
}

impl Lines {
    fn build(rows: &Rows) -> Lines {
        let mut l = Lines::default();
        for (t, id) in rows.each(table::CV_LINEAGES) {
            l.set_lineage(id, t.u32(id, col::cv_lineages::CORPORATION_ID));
        }
        for (t, id) in rows.each(table::CV_OVERLAYS) {
            l.set_overlay(id, line(t, id));
            l.set_owner(id, t.u32(id, col::cv_overlays::APPLICATION_ID));
        }
        l
    }

    fn set_lineage(&mut self, id: u32, corp: Option<u32>) {
        if let Some(old) = self.corp_of_lineage.remove(&id) {
            // The corporation falls back to its next lineage, if one is
            // still there (a predicted one beside the server's, for a while).
            if self.lineage_of_corp.get(&old) == Some(&id) {
                match self.corp_of_lineage.iter().filter(|(_, c)| **c == old).map(|(l, _)| *l).min() {
                    Some(next) => self.lineage_of_corp.insert(old, next),
                    None => self.lineage_of_corp.remove(&old),
                };
            }
        }
        if let Some(c) = corp {
            self.corp_of_lineage.insert(id, c);
            // One lineage per corporation; the lowest id holds when rows disagree.
            let held = self.lineage_of_corp.entry(c).or_insert(id);
            *held = (*held).min(id);
        }
    }

    fn set_overlay(&mut self, id: u32, line: Option<(u32, u32)>) {
        if let Some(old) = self.line_of_overlay.get(&id)
            && let Some(set) = self.overlays_of_lineage.get_mut(&old.0)
        {
            set.remove(&id);
        }
        if let Some(l) = line {
            self.overlays_of_lineage.entry(l.0).or_default().insert(id);
        }
        if let Some(old) = self.line_of_overlay.remove(&id)
            && let Some(n) = self.overlays_on_line.get_mut(&old)
        {
            *n -= 1;
            if *n == 0 {
                self.overlays_on_line.remove(&old);
            }
        }
        if let Some(l) = line {
            self.line_of_overlay.insert(id, l);
            *self.overlays_on_line.entry(l).or_insert(0) += 1;
        }
    }

    fn set_owner(&mut self, id: u32, app: Option<u32>) {
        if let Some(old) = self.app_of_overlay.remove(&id)
            && let Some(set) = self.overlays_of_app.get_mut(&old)
        {
            set.remove(&id);
        }
        if let Some(a) = app {
            self.app_of_overlay.insert(id, a);
            self.overlays_of_app.entry(a).or_default().insert(id);
        }
    }

    /// The overlay ids written for an application, ascending.
    pub fn overlays_of(&self, application: u32) -> impl Iterator<Item = u32> + '_ {
        self.overlays_of_app.get(&application).into_iter().flatten().copied()
    }

    pub fn lineage(&self, corporation: u32) -> Option<u32> {
        self.lineage_of_corp.get(&corporation).copied()
    }

    /// The overlay ids of a lineage, ascending.
    pub fn overlays(&self, lineage: u32) -> impl Iterator<Item = u32> + '_ {
        self.overlays_of_lineage.get(&lineage).into_iter().flatten().copied()
    }

    /// Whether an overlay other than `except` tells `item` in `lineage`.
    pub fn told(&self, lineage: u32, item: u32, except: u32) -> bool {
        let n = self.overlays_on_line.get(&(lineage, item)).copied().unwrap_or(0);
        let own = self.line_of_overlay.get(&except) == Some(&(lineage, item));
        n > own as u32
    }
}

fn line(t: &Table, id: u32) -> Option<(u32, u32)> {
    Some((t.u32(id, col::cv_overlays::LINEAGE_ID)?, t.u32(id, col::cv_overlays::ITEM_ID)?))
}

fn day(t: &Table, id: u32, c: u16) -> Option<Day> {
    t.u32(id, c).map(|d| d as Day)
}

/// The settings row (one per account), if any.
pub fn settings(rows: &Rows) -> Option<(&Table, u32)> {
    let t = rows.table(table::SETTINGS)?;
    t.ids().first().map(|id| (t, *id))
}

/// Whether a place is "home": in a country the operator is a citizen of
/// (a city through its country). With no citizenships set, or a place
/// whose country is not known, it is unknown: nothing is away.
fn home_place(rows: &Rows, citizenships: &[String], place: u32) -> Option<bool> {
    if citizenships.is_empty() {
        return None;
    }
    let pt = rows.table(table::PLACES)?;
    let iso2 = pt.str(place, col::places::ISO2).or_else(|| pt.str(pt.u32(place, col::places::COUNTRY_ID)?, col::places::ISO2))?;
    Some(citizenships.iter().any(|c| c.eq_ignore_ascii_case(iso2)))
}

/// The rail an application row shows: its stored pips when they parse and
/// agree with its stage, else the stage's fresh rail with a reply's or a
/// close's `submitted` and `reply` rungs read from the row's dates. `None`
/// when the row has no stage.
pub fn rail(t: &Table, id: u32) -> Option<crate::pipeline::Rail> {
    rail_of_row(t.row(id)?)
}

fn rail_of_row(r: Row<'_>) -> Option<crate::pipeline::Rail> {
    let stage = r.u32(A::STAGE).and_then(Stage::from_u32)?;
    let stored = r.str(A::PIPS).and_then(crate::pipeline::decode).filter(|p| crate::pipeline::current(p) == stage);
    Some(stored.unwrap_or_else(|| crate::pipeline::rail_by_dates(stage, r.u32(A::APPLIED_ON).is_some(), r.u32(A::REPLIED_ON).is_some())))
}

/// Whether anything went out for an application row (submitted, or an
/// outreach answered), by its rail.
pub fn sent(t: &Table, id: u32) -> bool {
    rail(t, id).is_some_and(|r| crate::pipeline::sent(&r))
}

/// Whether an application row was submitted (not merely answered), by its rail.
pub fn submitted(t: &Table, id: u32) -> bool {
    rail(t, id).is_some_and(|r| crate::pipeline::submitted(&r))
}

/// The governor's seat for one application row. Its score is the stored
/// one; the board's cache sets the effective score.
pub fn seat(rows: &Rows, t: &Table, id: u32) -> Option<Seat> {
    seat_of_row(rows, t.row(id)?, id).map(|f| Seat::new(&f))
}

/// A corporation's cited headcount, when the application is linked to one.
fn headcount(rows: &Rows, corporation: Option<u32>) -> Option<u32> {
    rows.table(table::CORPORATIONS)?.u32(corporation?, col::corporations::HEADCOUNT)
}

fn seat_of_row<'r>(rows: &Rows, r: Row<'r>, id: u32) -> Option<SeatIn<'r>> {
    let stage = r.u32(A::STAGE).and_then(Stage::from_u32)?;
    let day = |c: u16| r.u32(c).map(|d| d as Day);
    Some(SeatIn {
        id,
        corporation_id: r.u32(A::CORPORATION_ID),
        headcount: headcount(rows, r.u32(A::CORPORATION_ID)),
        company: r.str(A::COMPANY).unwrap_or(""),
        role: r.str(A::ROLE).unwrap_or(""),
        url: r.str(A::LISTING_URL).or_else(|| r.str(A::CANONICAL_URL)).unwrap_or(""),
        stage,
        stage_on: day(A::STAGE_ON),
        applied_on: day(A::APPLIED_ON),
        replied_on: day(A::REPLIED_ON),
        outcome: r.u32(A::OUTCOME),
        sent: rail_of_row(r).is_some_and(|rail| crate::pipeline::sent(&rail)),
        score: r.u32(A::SCORE_100).map_or(0, |s| s.min(100) as u8),
        batch_id: r.u32(A::BATCH_ID),
        heat_override: r.u32(A::HEAT_OVERRIDE) == Some(1),
        heat_override_reason: r.str(A::HEAT_OVERRIDE_REASON).unwrap_or(""),
    })
}

/// The one `me` row: the person the desk is for.
pub fn me(rows: &Rows) -> Option<(&Table, u32)> {
    let t = rows.table(table::ME)?;
    t.ids().first().map(|id| (t, *id))
}

/// The operator's citizenships from the `me` row, read once.
pub fn citizenships(rows: &Rows) -> Vec<String> {
    text::codes(me(rows).and_then(|(m, id)| m.str(id, col::me::CITIZENSHIPS)).unwrap_or(""))
}

/// The languages the operator speaks, U+001F-joined ISO 639-1 codes.
pub fn languages(rows: &Rows) -> String {
    let codes: Vec<&str> = rows.each(table::LANGUAGES).filter_map(|(t, id)| t.str(id, col::languages::CODE)).collect();
    codes.join("\u{1f}")
}

/// The Life-EV suggestion for one application row, read without the
/// board's memos; `citizenships` is [`citizenships`].
pub fn suggestion(rows: &Rows, citizenships: &[String], t: &Table, id: u32) -> Suggestion {
    score::suggest(&score_seat(rows, citizenships, t, id))
}

fn score_seat<'t>(rows: &Rows, citizenships: &[String], t: &'t Table, id: u32) -> score::Seat<'t> {
    match t.row(id) {
        Some(r) => score_seat_of_row(rows, citizenships, r),
        None => score::Seat::default(),
    }
}

fn score_seat_of_row<'t>(rows: &Rows, citizenships: &[String], r: Row<'t>) -> score::Seat<'t> {
    let mode = r.u32(A::WORK_MODE);
    let remote = mode == Some(enums::work_mode::REMOTE as u32);
    let home = r.u32(A::PLACE_ID).and_then(|p| home_place(rows, citizenships, p));
    score::Seat {
        company: r.str(A::COMPANY).unwrap_or(""),
        role: r.str(A::ROLE).unwrap_or(""),
        location: r.str(A::LOCATION).unwrap_or(""),
        comp_raw: r.str(A::COMP_RAW).unwrap_or(""),
        onsite: mode == Some(enums::work_mode::ONSITE as u32),
        home: if remote { Some(true) } else { home },
    }
}

/// The heat config of the account: the defaults under `settings.heat_config`.
pub fn config(rows: &Rows) -> heat::Config {
    heat::Config::from_json(settings(rows).and_then(|(t, id)| t.str(id, col::settings::HEAT_CONFIG)))
}

impl Board {
    /// Forgets what a frame or a write moved, before the next derive;
    /// `rows` are the rows after it.
    pub fn forget(&mut self, moved: &Moved, rows: &Rows) {
        let cv = [table::CV_LINEAGES, table::CV_OVERLAYS];
        if cv.iter().any(|t| moved.replaced.contains(t)) {
            self.lines = None;
        } else if let Some(lines) = self.lines.as_mut() {
            if let Some((wrote, gone)) = moved.tables.get(&table::CV_LINEAGES) {
                let t = rows.table(table::CV_LINEAGES);
                for id in wrote.iter().chain(gone) {
                    lines.set_lineage(*id, t.filter(|t| t.has(*id)).and_then(|t| t.u32(*id, col::cv_lineages::CORPORATION_ID)));
                }
            }
            if let Some((wrote, gone)) = moved.tables.get(&table::CV_OVERLAYS) {
                let t = rows.table(table::CV_OVERLAYS);
                for id in wrote.iter().chain(gone) {
                    let live = t.filter(|t| t.has(*id));
                    lines.set_overlay(*id, live.and_then(|t| line(t, *id)));
                    lines.set_owner(*id, live.and_then(|t| t.u32(*id, col::cv_overlays::APPLICATION_ID)));
                }
            }
        }
        // A corporation's headcount is its applications' capacity.
        if moved.touched(table::SETTINGS)
            || moved.touched(table::ME)
            || moved.touched(table::PLACES)
            || moved.touched(table::CORPORATIONS)
            || moved.replaced.contains(&table::APPLICATIONS)
        {
            self.cache.clear();
            self.citizens = None;
            self.governor = None;
            return;
        }
        if let Some((wrote, gone)) = moved.tables.get(&table::APPLICATIONS) {
            let t = rows.table(table::APPLICATIONS);
            for id in wrote.iter().chain(gone) {
                self.cache.remove(id);
                if let Some((_, _, ix)) = self.governor.as_mut() {
                    let now = t.filter(|t| t.has(*id)).and_then(|t| seat(rows, t, *id));
                    if ix.contains(*id) || now.as_ref().is_some_and(|s| s.hot) {
                        ix.update(*id, now);
                    }
                }
            }
        }
    }

    /// The governor's index for `today`, built from the hot applications
    /// when missing or stale.
    pub fn governor(&mut self, rows: &Rows, today: Day) -> (&heat::Index, &heat::Config) {
        let cfg = config(rows);
        if !self.governor.as_ref().is_some_and(|g| g.0 == today && g.1 == cfg) {
            let mut hot: Vec<u32> = Vec::new();
            if let Some(t) = rows.table(table::APPLICATIONS) {
                let stages = t.u32s(A::STAGE).unwrap_or(&[]);
                for (i, &id) in t.ids().iter().enumerate() {
                    if stages.get(i).and_then(|v| Stage::from_u32(*v)).is_some_and(Stage::after_send)
                        && self.cached(rows, t, id).is_some()
                    {
                        hot.push(id);
                    }
                }
            }
            let ix = heat::Index::new(hot.iter().filter_map(|id| self.cache.get(id).map(|c| &c.seat)), today, &cfg);
            self.governor = Some((today, cfg, ix));
            self.forget_reads();
        }
        let g = self.governor.as_ref().map(|g| (&g.2, &g.1));
        g.unwrap_or_else(|| unreachable!())
    }

    fn cached(&mut self, rows: &Rows, t: &Table, id: u32) -> Option<&Cached> {
        if !self.cache.contains_key(&id) {
            let row = t.row(id)?;
            let f = seat_of_row(rows, row, id)?;
            let location = row.str(A::LOCATION).unwrap_or("");
            let name = self.names.get_or(f.company, || {
                let n = text::normalize(f.company);
                let h = Hits::of(&n);
                Name { size: Size::of_hits(h), facts: score::Facts::of_hits(h), tier: score::Tier::of_hits(h), normalized: n }
            });
            let title = *self.titles.get_or(f.role, || {
                let n = text::normalize(f.role);
                let (h, fam) = Hits::title(&n);
                Title { department: Department::of_hits(h), family: Family::of_hits(fam), facts: score::Facts::of_hits(h) }
            });
            let place = *self.places.get_or(location, || score::Facts::of_place(&text::normalize(location)));
            let seat = Seat::from_normalized(&f, &name.normalized, name.size, title.department, title.family);
            let read = score::Read { company: name.facts, tier: name.tier, role: title.facts, location: place };
            let mut search = String::with_capacity(f.company.len() + f.role.len() + location.len() + 16);
            for c in [A::COMPANY, A::ROLE, A::LOCATION] {
                if let Some(s) = row.str(c) {
                    search.push_str(&if s.is_ascii() { s.to_ascii_lowercase() } else { s.to_lowercase() });
                    search.push('\n');
                }
            }
            let no = row.u32(A::NO).unwrap_or(0);
            {
                use core::fmt::Write;
                let _ = write!(search, "#{no}");
            }
            let citizens = self.citizens.get_or_insert_with(|| citizenships(rows));
            let suggestion = score::suggest_read(&score_seat_of_row(rows, citizens, row), &read);
            let stored = row.u32(A::SCORE_100).map(|s| s.min(100) as u8);
            let mut seat = seat;
            seat.score = stored.unwrap_or(suggestion.score);
            let c = Cached {
                suggestion,
                stored,
                no,
                search,
                seat,
            };
            self.cache.insert(id, c);
        }
        self.cache.get(&id)
    }

    /// Recomputes every card and the board order.
    pub fn derive(&mut self, rows: &Rows, today: Day) {
        self.config = config(rows);
        self.cards.clear();
        self.at.clear();
        let Some(t) = rows.table(table::APPLICATIONS) else {
            self.order.clear();
            return;
        };
        let ids: Vec<u32> = t.ids().to_vec();
        for &id in &ids {
            self.cached(rows, t, id);
        }
        self.governor(rows, today);
        // Built here too, so the first overlay judged after a rebuild is
        // as fast as any.
        self.lines(rows);
        let Some((_, _, ix)) = self.governor.as_ref() else { return };
        let live: Vec<&Cached> = ids.iter().filter_map(|id| self.cache.get(id)).collect();
        for c in &live {
            let verdict = heat::verdict(ix, &c.seat, &[]);
            let class = Class::of(&verdict, &self.config);
            let score = c.stored.unwrap_or(c.suggestion.score);
            self.cards.push(Card {
                id: c.seat.id,
                no: c.no,
                stage: c.seat.stage,
                score,
                stored: c.stored.is_some(),
                band: Band::of(score),
                suggestion: c.suggestion,
                class,
                verdict,
            });
        }
        // One integer per card in board order (score high to low, class,
        // ratio, no), then the id: the same order as comparing the fields,
        // at the cost of one compare.
        for (i, c) in self.cards.iter().enumerate() {
            self.at.insert(c.id, i);
        }
        // Keys laid out in the last derive's order first: after a write
        // only a few cards move, the input is nearly sorted, and the stable
        // sort finishes in close to one pass. Keys are unique (the id is
        // in them), so the order is the same either way.
        let mut placed = alloc::vec![false; self.cards.len()];
        let mut keys: Vec<(u128, u32)> = Vec::with_capacity(self.cards.len());
        for id in core::mem::take(&mut self.order) {
            if let Some(&i) = self.at.get(&id) {
                placed[i] = true;
                keys.push((order_key(&self.cards[i]), id));
            }
        }
        keys.extend(self.cards.iter().enumerate().filter(|(i, _)| !placed[*i]).map(|(_, c)| (order_key(c), c.id)));
        keys.sort();
        self.order = keys.iter().map(|k| k.1).collect();
        self.forget_reads();
    }

    /// Drops the per-distinct-text reads once a pass has used them: a
    /// rewritten name, title or place must not stay in memory until the
    /// next BOOT.
    fn forget_reads(&mut self) {
        self.names.clear();
        self.titles.clear();
        self.places.clear();
    }

    /// The lineage index, built on first use.
    pub fn lines(&mut self, rows: &Rows) -> &Lines {
        self.lines.get_or_insert_with(|| Lines::build(rows))
    }

    /// The lineage index as of the last derive, if built.
    pub fn lines_built(&self) -> Option<&Lines> {
        self.lines.as_ref()
    }

    /// Days until a blocked card's move would fit (`heat::cooldown`), as
    /// of the last derive; `Some(0)` when it fits now.
    pub fn cooldown(&self, id: u32) -> Option<u32> {
        let (_, _, ix) = self.governor.as_ref()?;
        heat::cooldown(ix, &self.cache.get(&id)?.seat, &[])
    }

    /// A card's governor seat, as of the last derive.
    pub fn seat(&self, id: u32) -> Option<&Seat> {
        self.cache.get(&id).map(|c| &c.seat)
    }

    pub fn card(&self, id: u32) -> Option<&Card> {
        self.at.get(&id).map(|&i| &self.cards[i])
    }

    /// Every card id in board order.
    pub fn order(&self) -> &[u32] {
        &self.order
    }

    /// The card ids a filter keeps, in board order.
    pub fn view(&self, f: &Filter) -> Vec<u32> {
        let words: Vec<String> = f.search.split_whitespace().map(|w| w.to_lowercase()).collect();
        self.order
            .iter()
            .copied()
            .filter(|id| {
                let Some(c) = self.card(*id) else { return false };
                (f.bands == 0 || f.bands & (1 << c.band as u8) != 0)
                    && (f.stages == 0 || f.stages & (1 << c.stage as u8) != 0)
                    && (f.classes == 0 || f.classes & (1 << c.class as u8) != 0)
                    && c.score >= f.min_score
                    && (words.is_empty()
                        || self.cache.get(id).is_some_and(|k| words.iter().all(|w| k.search.contains(w.as_str()))))
            })
            .collect()
    }

    /// Application ids in board order, optionally only one stage: what a
    /// lease claim by count takes from (the caller drops claimed ids).
    pub fn ids(&self, stage: Option<Stage>) -> Vec<u32> {
        self.order.iter().copied().filter(|id| stage.is_none_or(|s| self.card(*id).is_some_and(|c| c.stage == s))).collect()
    }

    pub fn scoreboard(&self, rows: &Rows, today: Day) -> Scoreboard {
        let mut s = Scoreboard { total: self.cards.len() as u32, ..Scoreboard::default() };
        let t = rows.table(table::APPLICATIONS);
        for c in &self.cards {
            s.by_stage[c.stage as usize] += 1;
            s.by_band[c.band as usize] += 1;
            s.by_class[c.class as usize] += 1;
            if t.is_some_and(|t| submitted(t, c.id)) {
                s.submitted += 1;
                if t.and_then(|t| day(t, c.id, A::APPLIED_ON)) == Some(today) {
                    s.submitted_today += 1;
                }
            }
        }
        if let Some((st, id)) = settings(rows) {
            s.goal_total = st.u32(id, col::settings::GOAL_TOTAL);
            s.goal_daily = st.u32(id, col::settings::GOAL_DAILY);
            s.goal_days_left = day(st, id, col::settings::GOAL_ON).map(|d| d.saturating_sub(today));
        }
        s
    }
}

/// A card's place in board order as one integer: `255 − score` (8 bits),
/// the class (8), the ratio as an order-preserving u64 (64), `no` (32).
fn order_key(c: &Card) -> u128 {
    key_of(c.score, c.class, c.verdict.ratio(), c.no)
}

fn key_of(score: u8, class: Class, ratio: f64, no: u32) -> u128 {
    let bits = ratio.to_bits();
    // f64::total_cmp's order as an unsigned integer.
    let ratio = if bits >> 63 == 1 { !bits } else { bits | 1 << 63 };
    ((255 - score as u128) << 104) | ((class as u128) << 96) | ((ratio as u128) << 32) | no as u128
}

/// The card after `selected` in direction `dir` over `view` laid out in
/// rows of `columns`. No selection starts at the first card; moves stop at
/// the edges rather than wrap.
pub fn step(view: &[u32], selected: Option<u32>, dir: Dir, columns: usize) -> Option<u32> {
    let n = view.len();
    if n == 0 {
        return None;
    }
    let cols = columns.max(1);
    let Some(at) = selected.and_then(|s| view.iter().position(|v| *v == s)) else {
        return Some(view[if dir == Dir::Last { n - 1 } else { 0 }]);
    };
    let to = match dir {
        Dir::Next => (at + 1).min(n - 1),
        Dir::Prev => at.saturating_sub(1),
        Dir::Down => if at + cols < n { at + cols } else { at },
        Dir::Up => at.checked_sub(cols).unwrap_or(at),
        Dir::First => 0,
        Dir::Last => n - 1,
    };
    Some(view[to])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_packed_key_orders_as_the_fields_do() {
        let ratios = [0.0, -0.0, 0.3, 0.5, 0.8, 1.0, 1.0000001, 2.5, f64::INFINITY, f64::MIN_POSITIVE, 1e300];
        let classes = [Class::Cool, Class::Warm, Class::Hot, Class::Blocked];
        let mut r = 0x9E37_79B9_7F4A_7C15u64;
        let mut next = |n: u64| {
            r ^= r << 13;
            r ^= r >> 7;
            r ^= r << 17;
            r % n
        };
        for _ in 0..20_000 {
            let mut pick = || (next(101) as u8, classes[next(4) as usize], ratios[next(ratios.len() as u64) as usize], next(5) as u32);
            let (a, b) = (pick(), pick());
            let fields = core::cmp::Reverse(a.0).cmp(&core::cmp::Reverse(b.0)).then(a.1.cmp(&b.1)).then(a.2.total_cmp(&b.2)).then(a.3.cmp(&b.3));
            assert_eq!(key_of(a.0, a.1, a.2, a.3).cmp(&key_of(b.0, b.1, b.2, b.3)), fields, "{a:?} {b:?}");
        }
    }

    #[test]
    fn keyboard_stops_at_edges() {
        let v = [10, 11, 12, 13, 14];
        assert_eq!(step(&v, None, Dir::Down, 2), Some(10));
        assert_eq!(step(&v, None, Dir::Last, 2), Some(14));
        assert_eq!(step(&v, Some(10), Dir::Down, 2), Some(12));
        assert_eq!(step(&v, Some(13), Dir::Down, 2), Some(13));
        assert_eq!(step(&v, Some(12), Dir::Up, 2), Some(10));
        assert_eq!(step(&v, Some(11), Dir::Up, 2), Some(11));
        assert_eq!(step(&v, Some(14), Dir::Next, 2), Some(14));
        assert_eq!(step(&v, Some(10), Dir::Prev, 0), Some(10));
        assert_eq!(step(&v, Some(99), Dir::Next, 2), Some(10));
        assert_eq!(step(&[], Some(1), Dir::Next, 2), None);
    }
}
