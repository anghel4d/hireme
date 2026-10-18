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
//! frame or a write moved; the settings row or the atlas moving
//! recomputes all of them, since "home" is read from both.

use alloc::string::String;
use alloc::vec::Vec;

use schema::col::applications as A;
use schema::{col, enums, table};

use crate::heat::{self, Class, Seat, SeatIn};
use crate::pipeline::Stage;
use crate::rows::{Moved, Rows, Table};
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
        if let Some(t) = rows.table(table::CV_LINEAGES) {
            t.ids().iter().for_each(|&id| l.set_lineage(id, t.u32(id, col::cv_lineages::CORPORATION_ID)));
        }
        if let Some(t) = rows.table(table::CV_OVERLAYS) {
            t.ids().iter().for_each(|&id| {
                l.set_overlay(id, line(t, id));
                l.set_owner(id, t.u32(id, col::cv_overlays::APPLICATION_ID));
            });
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

/// Whether a place is "home": in a country the operator is a citizen of,
/// read from the atlas projection (a city through its country). With no
/// citizenships set, every place is unknown: nothing is away.
fn home_place(rows: &Rows, citizenships: &[String], place: u32) -> Option<bool> {
    let at = rows.table(table::ATLAS)?;
    if citizenships.is_empty() || !at.has(place) {
        return None;
    }
    let iso2 = at.str(place, col::atlas::ISO2).or_else(|| {
        let country = at.u32(place, col::atlas::COUNTRY_ID)?;
        at.str(country, col::atlas::ISO2)
    })?;
    Some(citizenships.iter().any(|c| c.eq_ignore_ascii_case(iso2)))
}

/// The rail an application row shows: its stored pips when they parse and
/// agree with its stage, else the stage's fresh rail with a reply's or a
/// close's `submitted` and `reply` rungs read from the row's dates. `None`
/// when the row has no stage.
pub fn rail(t: &Table, id: u32) -> Option<crate::pipeline::Rail> {
    let stage = t.u32(id, A::STAGE).and_then(|v| u8::try_from(v).ok().and_then(Stage::from_u8))?;
    let stored = t.str(id, A::PIPS).and_then(crate::pipeline::decode).filter(|r| crate::pipeline::current(r) == stage);
    Some(stored.unwrap_or_else(|| {
        crate::pipeline::rail_by_dates(stage, day(t, id, A::APPLIED_ON).is_some(), day(t, id, A::REPLIED_ON).is_some())
    }))
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
pub fn seat(t: &Table, id: u32) -> Option<Seat> {
    let stage = u8::try_from(t.u32(id, A::STAGE)?).ok().and_then(Stage::from_u8)?;
    Some(Seat::new(&SeatIn {
        id,
        corporation_id: t.u32(id, A::CORPORATION_ID),
        company: t.str(id, A::COMPANY).unwrap_or(""),
        role: t.str(id, A::ROLE).unwrap_or(""),
        url: t.str(id, A::LISTING_URL).or_else(|| t.str(id, A::CANONICAL_URL)).unwrap_or(""),
        stage,
        stage_on: day(t, id, A::STAGE_ON),
        applied_on: day(t, id, A::APPLIED_ON),
        replied_on: day(t, id, A::REPLIED_ON),
        sent: sent(t, id),
        score: t.u32(id, A::SCORE_100).map_or(0, |s| s.min(100) as u8),
        batch_id: t.u32(id, A::BATCH_ID),
        heat_override: t.u32(id, A::HEAT_OVERRIDE) == Some(1),
        heat_override_reason: t.str(id, A::HEAT_OVERRIDE_REASON).unwrap_or(""),
    }))
}

/// The operator's citizenships from the settings row, read once.
pub fn citizenships(rows: &Rows) -> Vec<String> {
    text::codes(settings(rows).and_then(|(s, sid)| s.str(sid, col::settings::CITIZENSHIPS)).unwrap_or(""))
}

/// The Life-EV suggestion for one application row; `citizenships` is
/// [`citizenships`].
pub fn suggestion(rows: &Rows, citizenships: &[String], t: &Table, id: u32) -> Suggestion {
    let mode = t.u32(id, A::WORK_MODE);
    let remote = mode == Some(enums::work_mode::REMOTE as u32);
    let home = t.u32(id, A::PLACE_ID).and_then(|p| home_place(rows, citizenships, p));
    score::suggest(&score::Seat {
        company: t.str(id, A::COMPANY).unwrap_or(""),
        role: t.str(id, A::ROLE).unwrap_or(""),
        location: t.str(id, A::LOCATION).unwrap_or(""),
        comp_raw: t.str(id, A::COMP_RAW).unwrap_or(""),
        onsite: mode == Some(enums::work_mode::ONSITE as u32),
        home: if remote { Some(true) } else { home },
    })
}

/// The heat config of the account: the defaults under `settings.heat_config`.
pub fn config(rows: &Rows) -> heat::Config {
    heat::Config::from_json(settings(rows).and_then(|(t, id)| t.str(id, col::settings::HEAT_CONFIG)))
}

impl Board {
    pub fn new() -> Board {
        Board::default()
    }

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
        if moved.touched(table::SETTINGS) || moved.touched(table::ATLAS) || moved.replaced.contains(&table::APPLICATIONS) {
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
                    let now = t.filter(|t| t.has(*id)).and_then(|t| seat(t, *id));
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
            let mut hot: Vec<Seat> = Vec::new();
            if let Some(t) = rows.table(table::APPLICATIONS) {
                let stages = t.u32s(A::STAGE).unwrap_or(&[]);
                for (i, &id) in t.ids().iter().enumerate() {
                    if stages.get(i).and_then(|v| u8::try_from(*v).ok().and_then(Stage::from_u8)).is_some_and(|s| s.queued() || s.after_send())
                        && let Some(c) = self.cached(rows, t, id)
                    {
                        hot.push(c.seat.clone());
                    }
                }
            }
            let ix = heat::Index::new(hot.iter(), today, &cfg);
            self.governor = Some((today, cfg, ix));
        }
        let g = self.governor.as_ref().map(|g| (&g.2, &g.1));
        g.unwrap_or_else(|| unreachable!())
    }

    fn cached(&mut self, rows: &Rows, t: &Table, id: u32) -> Option<&Cached> {
        if !self.cache.contains_key(&id) {
            let seat = seat(t, id)?;
            let mut search = String::new();
            for c in [A::COMPANY, A::ROLE, A::LOCATION] {
                if let Some(s) = t.str(id, c) {
                    search.push_str(&s.to_lowercase());
                    search.push('\n');
                }
            }
            let no = t.u32(id, A::NO).unwrap_or(0);
            search.push_str(&alloc::format!("#{no}"));
            let citizens = self.citizens.get_or_insert_with(|| citizenships(rows));
            let suggestion = suggestion(rows, citizens, t, id);
            let stored = t.u32(id, A::SCORE_100).map(|s| s.min(100) as u8);
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
        let mut keys: Vec<(core::cmp::Reverse<u8>, Class, f64, u32, u32)> =
            self.cards.iter().map(|c| (core::cmp::Reverse(c.score), c.class, c.verdict.ratio(), c.no, c.id)).collect();
        keys.sort_unstable_by(|x, y| x.0.cmp(&y.0).then(x.1.cmp(&y.1)).then(x.2.total_cmp(&y.2)).then(x.3.cmp(&y.3)).then(x.4.cmp(&y.4)));
        self.order = keys.iter().map(|k| k.4).collect();
        for (i, c) in self.cards.iter().enumerate() {
            self.at.insert(c.id, i);
        }
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

    pub fn heat_config(&self) -> &heat::Config {
        &self.config
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
