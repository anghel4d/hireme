//! One application's CV: the profile's items (plus the shared ones)
//! through the overlays of its corporation's lineage, read with a theme.
//!
//! An overlay is one line's change for one application: `tailor`
//! rewrites an item's title or body, `add` brings in an item the profile
//! would not show (another profile's), `drop` hides one. Every overlay
//! belongs to its corporation's lineage, so every application to one
//! company tells the same story.
//!
//! The lineage is the guard on that story. A generation is open for
//! [`COOLDOWN_DAYS`] from `opened_on`. While it is open and
//! `rewrites_allowed`, overlays may be written, rewritten and removed;
//! once rewrites are off (every generation after the first opens that
//! way) only an overlay on a line no application of the lineage has
//! overlaid yet may be added, so a later application cannot reword what
//! an earlier one already sent. When the window has passed,
//! overlay writes wait until `open_generation` opens the next one, which
//! is itself refused until the window has passed.

use alloc::borrow::Cow;
use alloc::string::String;
use alloc::vec::Vec;

use crate::Day;

pub const COOLDOWN_DAYS: Day = 90;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Mode {
    Tailor = 0,
    Add = 1,
    Drop = 2,
}

impl Mode {
    pub fn from_u8(v: u8) -> Option<Mode> {
        [Mode::Tailor, Mode::Add, Mode::Drop].get(v as usize).copied()
    }

    pub fn name(self) -> &'static str {
        match self {
            Mode::Tailor => "tailor",
            Mode::Add => "add",
            Mode::Drop => "drop",
        }
    }
}

/// Where a lineage stands on `today`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Overlays may be written, rewritten and removed.
    Tailor,
    /// Only new overlays may be added.
    Additive,
    /// The window has passed: writes wait for the next generation.
    Ready,
}

pub fn phase(opened_on: Day, rewrites_allowed: bool, today: Day) -> Phase {
    if today as i64 - opened_on as i64 >= COOLDOWN_DAYS as i64 {
        Phase::Ready
    } else if rewrites_allowed {
        Phase::Tailor
    } else {
        Phase::Additive
    }
}

/// Days until `open_generation` is allowed; 0 when it is.
pub fn days_to_open(opened_on: Day, today: Day) -> Day {
    (COOLDOWN_DAYS as i64 - (today as i64 - opened_on as i64)).clamp(0, COOLDOWN_DAYS as i64) as Day
}

/// Why an overlay write is refused by its lineage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The generation's window has passed (`cooldown`).
    Cooldown,
    /// Rewrites are off: only a new overlay may be added (`lineage_busy`).
    Additive,
}

/// Whether a lineage in `phase` takes an overlay write that `creates` an
/// overlay on a line the lineage has not overlaid yet (else it rewrites,
/// removes, or overlays a line again).
pub fn check(phase: Phase, creates: bool) -> Result<(), Refusal> {
    match phase {
        Phase::Ready => Err(Refusal::Cooldown),
        Phase::Additive if !creates => Err(Refusal::Additive),
        _ => Ok(()),
    }
}

/// How a CV reads. Stored as JSON on the lineage (`theme`) and the
/// application (`cv_theme`); the application's fields win field by field.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Theme {
    pub lead: Option<String>,
    pub lead_reason: Option<String>,
    pub accent: Option<&'static str>,
    pub density: Option<&'static str>,
    pub targets: Vec<String>,
}

const ACCENTS: [&str; 3] = ["ink", "signal", "paper"];
const DENSITIES: [&str; 3] = ["cv", "tight", "narrative"];

impl Theme {
    /// A theme from JSON; unknown keys and ill-typed values are ignored,
    /// an unknown accent or density is absent.
    pub fn parse(json: Option<&str>) -> Theme {
        let Some(Ok(serde_json::Value::Object(m))) = json.map(serde_json::from_str::<serde_json::Value>) else {
            return Theme::default();
        };
        let text = |k: &str| m.get(k).and_then(|v| v.as_str()).map(str::trim).filter(|s| !s.is_empty()).map(String::from);
        let pick = |k: &str, set: [&'static str; 3]| m.get(k).and_then(|v| v.as_str()).and_then(|s| set.into_iter().find(|x| *x == s));
        let mut targets = Vec::new();
        for t in m.get("targets").and_then(|v| v.as_array()).into_iter().flatten().filter_map(|t| t.as_str()) {
            push_target(&mut targets, t);
        }
        Theme {
            lead: text("lead"),
            lead_reason: text("lead_reason"),
            accent: pick("accent", ACCENTS),
            density: pick("density", DENSITIES),
            targets,
        }
    }

    /// `self` over `base`: each field of `self` that is set wins; targets
    /// are the union, `self`'s first.
    pub fn over(self, base: Theme) -> Theme {
        let mut targets = self.targets;
        for t in &base.targets {
            push_target(&mut targets, t);
        }
        Theme {
            lead: self.lead.or(base.lead),
            lead_reason: self.lead_reason.or(base.lead_reason),
            accent: self.accent.or(base.accent),
            density: self.density.or(base.density),
            targets,
        }
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "lead": self.lead, "lead_reason": self.lead_reason,
            "accent": self.accent.unwrap_or("ink"), "density": self.density.unwrap_or("cv"),
            "targets": self.targets,
        })
    }
}

/// Adds a theme target: trimmed, at most [`keywords::MAX_TARGET_LEN`]
/// bytes, no case-folded duplicate, at most [`keywords::MAX_TARGETS`].
fn push_target(targets: &mut Vec<String>, t: &str) {
    use crate::keywords::{MAX_TARGETS, MAX_TARGET_LEN};
    let t = t.trim();
    if t.is_empty() || t.len() > MAX_TARGET_LEN || targets.len() >= MAX_TARGETS {
        return;
    }
    let folded = crate::text::fold(t);
    if !targets.iter().any(|x| crate::text::fold(x) == folded) {
        targets.push(String::from(t));
    }
}

/// A corpus item as the CV reads it.
#[derive(Clone, Debug, Default)]
pub struct Item<'a> {
    pub id: u32,
    pub profile_id: Option<u32>,
    pub kind: u8,
    pub key: &'a str,
    pub title: &'a str,
    /// A text column: packed at rest, so read into a Cow.
    pub body: Option<Cow<'a, str>>,
    pub org: Option<&'a str>,
    pub span: Option<&'a str>,
    pub position: u32,
}

/// One application's overlay on one item.
#[derive(Clone, Debug)]
pub struct Overlay<'a> {
    /// The overlay row's id; among overlays on one item the application's
    /// own wins, then the lowest id (the line as first told).
    pub id: u32,
    pub own: bool,
    pub item_id: u32,
    pub mode: Mode,
    pub title: Option<&'a str>,
    pub body: Option<Cow<'a, str>>,
    pub reason: Option<Cow<'a, str>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Line<'a> {
    pub item_id: u32,
    pub kind: u8,
    pub key: &'a str,
    pub title: &'a str,
    pub body: Option<Cow<'a, str>>,
    pub org: Option<&'a str>,
    pub span: Option<&'a str>,
    /// The overlay that shaped this line, if any (never `Drop`: dropped
    /// lines are not in the CV).
    pub mode: Option<Mode>,
    pub reason: Option<Cow<'a, str>>,
}

/// The composed CV: the profile's items and the shared ones, ordered by
/// kind, position, id, with the lineage's tailored lines rewritten, added lines brought
/// in and dropped lines left out. An overlay naming an item that does not
/// exist is ignored.
pub fn compose<'a>(profile_id: Option<u32>, items: &[Item<'a>], overlays: &[Overlay<'a>]) -> Vec<Line<'a>> {
    let overlay = |id: u32| overlays.iter().filter(|o| o.item_id == id).min_by_key(|o| (!o.own, o.id));
    let mut out: Vec<(u8, u32, u32, Line<'a>)> = Vec::new();
    for it in items {
        let own = it.profile_id.is_none() || it.profile_id == profile_id;
        let o = overlay(it.id);
        let shown = match o.map(|o| o.mode) {
            Some(Mode::Drop) => false,
            Some(Mode::Add) => true,
            _ => own,
        };
        if !shown {
            continue;
        }
        let line = Line {
            item_id: it.id,
            kind: it.kind,
            key: it.key,
            title: o.and_then(|o| o.title).filter(|t| !t.trim().is_empty()).unwrap_or(it.title),
            body: o.and_then(|o| o.body.clone()).filter(|b| !b.trim().is_empty()).or_else(|| it.body.clone()),
            org: it.org,
            span: it.span,
            mode: o.map(|o| o.mode),
            reason: o.and_then(|o| o.reason.clone()),
        };
        out.push((it.kind, it.position, it.id, line));
    }
    out.sort_by_key(|a| (a.0, a.1, a.2));
    out.into_iter().map(|t| t.3).collect()
}

/// The text a reader sees: the lead and every line's title, org and body.
pub fn visible(lines: &[Line], theme: &Theme) -> String {
    let mut s = String::new();
    let mut put = |t: &str| {
        s.push_str(t);
        s.push('\n');
    };
    if let Some(l) = &theme.lead {
        put(l);
    }
    for l in lines {
        put(l.title);
        if let Some(o) = l.org {
            put(o);
        }
        if let Some(b) = &l.body {
            put(b);
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: u32, profile: Option<u32>, position: u32, title: &'static str) -> Item<'static> {
        Item { id, profile_id: profile, kind: 0, key: title, title, position, ..Item::default() }
    }

    #[test]
    fn overlays_shape_the_profile() {
        let items = [item(1, None, 2, "shared"), item(2, Some(7), 1, "mine"), item(3, Some(8), 0, "theirs"), item(4, Some(7), 3, "old")];
        let overlays = [
            Overlay { id: 1, own: true, item_id: 3, mode: Mode::Add, title: None, body: None, reason: Some("fits".into()) },
            Overlay { id: 2, own: true, item_id: 4, mode: Mode::Drop, title: None, body: None, reason: None },
            Overlay { id: 3, own: true, item_id: 2, mode: Mode::Tailor, title: Some("mine, tailored"), body: Some("b".into()), reason: None },
            Overlay { id: 4, own: true, item_id: 99, mode: Mode::Add, title: None, body: None, reason: None },
        ];
        let cv = compose(Some(7), &items, &overlays);
        let titles: Vec<&str> = cv.iter().map(|l| l.title).collect();
        assert_eq!(titles, ["theirs", "mine, tailored", "shared"]);
        assert_eq!(cv[1].body.as_deref(), Some("b"));
        assert_eq!(cv[0].mode, Some(Mode::Add));
        // Another application's earlier wording of a line is the story; the
        // application's own wording of it wins.
        let told = [
            Overlay { id: 9, own: false, item_id: 1, mode: Mode::Tailor, title: Some("told first"), body: None, reason: None },
            Overlay { id: 12, own: false, item_id: 1, mode: Mode::Drop, title: None, body: None, reason: None },
        ];
        assert_eq!(compose(Some(7), &items, &told).iter().find(|l| l.item_id == 1).map(|l| l.title), Some("told first"));
        let mine = [told[0].clone(), Overlay { id: 20, own: true, item_id: 1, mode: Mode::Tailor, title: Some("mine"), body: None, reason: None }];
        assert_eq!(compose(Some(7), &items, &mine).iter().find(|l| l.item_id == 1).map(|l| l.title), Some("mine"));
        let t = Theme { lead: Some("Lead".into()), ..Theme::default() };
        assert_eq!(visible(&cv, &t), "Lead\ntheirs\nmine, tailored\nb\nshared\n");
    }

    #[test]
    fn lineage_phases() {
        assert_eq!(phase(0, true, 89), Phase::Tailor);
        assert_eq!(phase(0, false, 89), Phase::Additive);
        assert_eq!(phase(0, true, 90), Phase::Ready);
        assert_eq!(check(Phase::Additive, true), Ok(()));
        assert_eq!(check(Phase::Additive, false), Err(Refusal::Additive));
        assert_eq!(check(Phase::Ready, true), Err(Refusal::Cooldown));
        assert_eq!(days_to_open(0, 30), 60);
        assert_eq!(days_to_open(0, 120), 0);
    }

    #[test]
    fn themes_layer() {
        let app = Theme::parse(Some(r#"{"lead":" Systems ","accent":"neon","targets":["Rust"," "]}"#));
        let lin = Theme::parse(Some(r#"{"lead":"x","accent":"signal","density":"tight","targets":["rust","go"]}"#));
        let t = app.over(lin);
        assert_eq!(t.lead.as_deref(), Some("Systems"));
        assert_eq!(t.accent, Some("signal"));
        assert_eq!(t.density, Some("tight"));
        assert_eq!(t.targets, ["Rust", "go"]);
        assert_eq!(Theme::parse(Some("nope")), Theme::default());
    }
}
