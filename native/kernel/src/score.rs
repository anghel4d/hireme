//! Life-EV: the `score_100` the kernel suggests for an application or a
//! corporation, and the band ladder it falls on.
//!
//! The ladder (`docs/score.md`): named anchors win over heuristics; a big
//! tech name sits at 85 only with a pay signal over $200k, else 80; the
//! heuristics move an unanchored seat between 0 and 84 and never climb
//! onto an anchor's rung; a hard kill (staffing, internship tier, AI
//! theater, a non-engineering role dressed as one, onsite-only away from
//! home) pins the seat under 20 and nothing raises it.
//!
//! The kernel suggests and never overwrites: a stored `score_100` is the
//! operator's or an agent's number, and the board ranks by it. A seat
//! with none ranks by the suggestion.
//!
//! "Home" is not a place named in source: the caller says whether the
//! seat is remote or in a country the operator holds citizenship of
//! (`settings.citizenships` against the application's place).

use crate::text;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Band {
    Frontier = 0,
    Labs = 1,
    BigTech = 2,
    Systems = 3,
    Craft = 4,
    Mid = 5,
    Thin = 6,
    Kill = 7,
}

pub const BANDS: [Band; 8] =
    [Band::Frontier, Band::Labs, Band::BigTech, Band::Systems, Band::Craft, Band::Mid, Band::Thin, Band::Kill];

impl Band {
    pub fn from_u8(v: u8) -> Option<Band> {
        BANDS.get(v as usize).copied()
    }

    pub fn parse(s: &str) -> Option<Band> {
        BANDS.into_iter().find(|b| b.name() == s)
    }

    pub fn name(self) -> &'static str {
        match self {
            Band::Frontier => "frontier",
            Band::Labs => "labs",
            Band::BigTech => "big_tech",
            Band::Systems => "systems",
            Band::Craft => "craft",
            Band::Mid => "mid",
            Band::Thin => "thin",
            Band::Kill => "kill",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Band::Frontier => "Frontier",
            Band::Labs => "Tier-2 labs",
            Band::BigTech => "Big tech",
            Band::Systems => "Systems",
            Band::Craft => "Craft",
            Band::Mid => "Mid",
            Band::Thin => "Thin",
            Band::Kill => "Kill",
        }
    }

    /// The lowest and highest score on this rung.
    pub fn range(self) -> (u8, u8) {
        match self {
            Band::Frontier => (100, 100),
            Band::Labs => (90, 99),
            Band::BigTech => (85, 89),
            Band::Systems => (70, 84),
            Band::Craft => (55, 69),
            Band::Mid => (40, 54),
            Band::Thin => (20, 39),
            Band::Kill => (0, 19),
        }
    }

    pub fn of(score: u8) -> Band {
        BANDS.into_iter().find(|b| score >= b.range().0).unwrap_or(Band::Kill)
    }
}

/// Why a seat is a hard kill.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kill {
    Staffing,
    Intern,
    Theater,
    NotEngineering,
    OnsiteAway,
}

impl Kill {
    pub fn name(self) -> &'static str {
        match self {
            Kill::Staffing => "staffing",
            Kill::Intern => "intern",
            Kill::Theater => "theater",
            Kill::NotEngineering => "not_engineering",
            Kill::OnsiteAway => "onsite_away",
        }
    }

    fn score(self) -> u8 {
        match self {
            Kill::Staffing => 8,
            Kill::Theater => 10,
            Kill::Intern => 12,
            Kill::NotEngineering | Kill::OnsiteAway => 15,
        }
    }
}

/// What a suggestion reads.
#[derive(Clone, Copy, Debug, Default)]
pub struct Seat<'a> {
    pub company: &'a str,
    pub role: &'a str,
    pub location: &'a str,
    pub comp_raw: &'a str,
    /// The seat is onsite-only by its `work_mode`.
    pub onsite: bool,
    /// Whether the seat is home: remote, or in a country the operator is a
    /// citizen of; `None` when that is not known.
    pub home: Option<bool>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Suggestion {
    pub score: u8,
    pub band: Band,
    pub kill: Option<Kill>,
    /// Set by a named anchor rather than the heuristics.
    pub anchored: bool,
}

impl Suggestion {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "score_100": self.score,
            "band": self.band.name(),
            "kill": self.kill.map(Kill::name),
            "anchored": self.anchored,
        })
    }
}

const FRONTIER: &[&str] = &["openai", "anthropic", "spacex", "neuralink", "xai", "spacexai"];
const LABS: &[&str] = &["starfish", "valve", "gdm", "deepmind", "meta", "ssi", "mira"];
const LABS_PHRASES: &[&str] = &["google deepmind", "thinking machines", "safe superintelligence", "meta fair"];
const BIG_TECH: &[&str] = &[
    "google", "alphabet", "apple", "microsoft", "amazon", "nvidia", "netflix", "uber", "stripe", "databricks",
    "snowflake", "tesla", "adobe", "salesforce", "oracle", "linkedin", "snap", "pinterest", "shopify",
];

fn named(name: &str, set: &[&str]) -> bool {
    let compact: alloc::string::String = name.chars().filter(|c| *c != ' ').collect();
    set.contains(&compact.as_str()) || text::words(name).any(|w| set.contains(&w))
}

/// The anchor a company name sits on, if any.
pub fn anchor(company: &str, high_comp: bool) -> Option<u8> {
    let n = text::normalize(company);
    if n.is_empty() {
        None
    } else if named(&n, FRONTIER) {
        Some(100)
    } else if text::any_word(&n, LABS_PHRASES) || named(&n, LABS) {
        Some(90)
    } else if named(&n, BIG_TECH) {
        Some(if high_comp { 85 } else { 80 })
    } else {
        None
    }
}

/// The hard kill a seat falls under, if any.
pub fn kill(seat: &Seat) -> Option<Kill> {
    let blob = text::normalize(&alloc::format!("{} {}", seat.company, seat.role));
    let loc = text::normalize(seat.location);
    if text::any_start(&blob, &["staffing", "body shop", "bodyshop", "recruit"]) {
        Some(Kill::Staffing)
    } else if text::any_word(&blob, &["intern", "internship", "new grad", "newgrad", "co op", "coop"]) {
        Some(Kill::Intern)
    } else if text::any_word(&blob, &["prompt only", "ai theater", "chatgpt wrapper"]) {
        Some(Kill::Theater)
    } else if text::any_word(
        &blob,
        &["sales engineer", "business analyst", "ba", "project manager", "pm", "support engineer"],
    ) {
        Some(Kill::NotEngineering)
    } else if onsite_away(seat, &loc) {
        Some(Kill::OnsiteAway)
    } else {
        None
    }
}

/// Onsite-only and known to be away: the place is outside home, not just
/// unknown, and nothing says remote.
fn onsite_away(seat: &Seat, loc: &str) -> bool {
    let says_onsite_only = text::any_word(loc, &["onsite only", "on site only", "no remote", "not remote"]);
    let remote_text = text::word(loc, "remote") && !text::any_word(loc, &["no remote", "not remote"]);
    seat.home == Some(false) && !remote_text && (seat.onsite || says_onsite_only)
}

/// A pay figure over $200k anywhere in free text: "$210,000", "250k",
/// "180-240k", "220000", "$1.2M". Bare numbers from 200 to 999 read as
/// thousands ("$220 base").
pub fn high_comp(comp: &str) -> bool {
    let b = comp.as_bytes();
    let mut i = 0;
    let mut best = 0f64;
    while i < b.len() {
        if !b[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        let start = i;
        let mut n = 0f64;
        let mut frac = 0f64;
        let mut scale = 0.1;
        let mut in_frac = false;
        while i < b.len() && (b[i].is_ascii_digit() || b[i] == b',' || (b[i] == b'.' && !in_frac)) {
            match b[i] {
                b',' => {}
                b'.' => in_frac = true,
                d if in_frac => {
                    frac += (d - b'0') as f64 * scale;
                    scale /= 10.0;
                }
                d => n = n * 10.0 + (d - b'0') as f64,
            }
            i += 1;
        }
        let v = n + frac;
        // A suffix letter counts only when it ends the token: "250k", not
        // "300km"; "401k" is a retirement plan.
        let ends = |j: usize| j >= b.len() || !b[j].is_ascii_alphanumeric();
        let suffix = if i < b.len() && ends(i + 1) { b[i].to_ascii_lowercase() } else { 0 };
        let after_letter = start > 0 && b[start - 1].is_ascii_alphabetic();
        // Millions are pay only as money ("$1.2M"), not "5M users".
        let money = comp[..start].trim_end().ends_with(['$', '€', '£']);
        let plan = v == 401.0 && (suffix == b'k' || comp[i..].starts_with("(k)") || comp[i..].starts_with("(K)"));
        let value = match suffix {
            _ if plan => 0.0,
            b'k' => v * 1e3,
            b'm' if money => v * 1e6,
            b'm' => 0.0,
            _ if i < b.len() && b[i].is_ascii_alphabetic() => 0.0,
            _ if (200.0..1_000.0).contains(&v) => v * 1e3,
            _ => v,
        };
        if !after_letter {
            best = best.max(value);
        }
    }
    best >= 200_000.0
}

/// The Life-EV suggestion for a seat.
pub fn suggest(seat: &Seat) -> Suggestion {
    let high = high_comp(seat.comp_raw);
    if let Some(k) = kill(seat) {
        return Suggestion { score: k.score(), band: Band::Kill, kill: Some(k), anchored: false };
    }
    if let Some(a) = anchor(seat.company, high) {
        return Suggestion { score: a, band: Band::of(a), kill: None, anchored: true };
    }
    let t = text::normalize(&alloc::format!("{} {}", seat.company, seat.role));
    let mut s: i32 = 48;
    if text::any_word(&t, &["systems", "runtime", "kernel", "infra", "infrastructure", "distributed", "compiler"]) {
        s += 22;
    }
    if text::any_word(&t, &["agentic", "agent systems", "agents"]) {
        s += 10;
    }
    if text::any_word(&t, &["rust", "c++", "low level", "lowlevel", "systems c"]) {
        s += 8;
    }
    let loc = text::normalize(seat.location);
    if seat.home == Some(true) || text::word(&loc, "remote") {
        s += 5;
    }
    if high {
        s += 6;
    }
    if text::any_word(&t, &["crud", "full stack", "fullstack", "rails shop", "wordpress"]) {
        s -= 16;
    }
    // Heuristics never climb onto an anchor's rung.
    let score = s.clamp(0, 84) as u8;
    Suggestion { score, band: Band::of(score), kill: None, anchored: false }
}

/// The score a seat ranks by: its stored number, else the suggestion.
pub fn effective(stored: Option<u8>, seat: &Seat) -> u8 {
    stored.map_or_else(|| suggest(seat).score, |s| s.min(100))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s<'a>(company: &'a str, role: &'a str) -> Seat<'a> {
        Seat { company, role, ..Seat::default() }
    }

    #[test]
    fn bands_cover_0_to_100() {
        for n in 0..=100u8 {
            let b = Band::of(n);
            let (lo, hi) = b.range();
            assert!(lo <= n && n <= hi, "{n} {b:?}");
        }
        assert_eq!(Band::of(100), Band::Frontier);
        assert_eq!(Band::of(84), Band::Systems);
        assert_eq!(Band::of(19), Band::Kill);
    }

    #[test]
    fn anchors_win_and_big_tech_needs_pay() {
        assert_eq!(suggest(&s("Anthropic", "Software Engineer")).score, 100);
        assert_eq!(suggest(&s("Google DeepMind", "Research Engineer")).score, 90);
        assert_eq!(suggest(&s("Thinking Machines Lab", "Engineer")).score, 90);
        assert_eq!(suggest(&s("Stripe", "Engineer")).score, 80);
        assert_eq!(suggest(&s("Fair Oaks Capital", "Engineer")).anchored, false);
        let paid = Seat { comp_raw: "$180k – $240k", ..s("Stripe", "Engineer") };
        assert_eq!(suggest(&paid).score, 85);
        assert_eq!(suggest(&paid).band, Band::BigTech);
    }

    #[test]
    fn heuristics_stay_under_the_anchors() {
        let top = Seat { comp_raw: "300000", home: Some(true), ..s("Acme", "Senior Rust Distributed Systems Engineer, Agents") };
        let g = suggest(&top);
        assert_eq!(g.score, 84);
        assert!(!g.anchored);
        assert_eq!(suggest(&s("Acme", "Full Stack Engineer")).score, 32);
        assert_eq!(suggest(&s("Acme", "Engineer")).score, 48);
    }

    #[test]
    fn kills_cannot_be_raised() {
        assert_eq!(suggest(&s("Anthropic", "Software Engineering Intern")).kill, Some(Kill::Intern));
        assert_eq!(suggest(&s("Acme Staffing", "Rust Engineer")).score, 8);
        assert_eq!(suggest(&s("Acme", "Sales Engineer")).kill, Some(Kill::NotEngineering));
        let away = Seat { onsite: true, home: Some(false), ..s("Acme", "Engineer") };
        assert_eq!(suggest(&away).kill, Some(Kill::OnsiteAway));
        let home = Seat { home: Some(true), ..away };
        assert_eq!(suggest(&home).kill, None);
        // Saying onsite-only is not enough while home is unknown.
        let text_only = Seat { location: "Onsite only, no remote", ..s("Acme", "Engineer") };
        assert_eq!(suggest(&text_only).kill, None);
        assert_eq!(suggest(&Seat { home: Some(false), ..text_only }).kill, Some(Kill::OnsiteAway));
        assert_eq!(suggest(&Seat { onsite: true, ..s("Acme", "Engineer") }).kill, None);
        assert_eq!(suggest(&s("Acme", "Newgrad Engineer")).kill, Some(Kill::Intern));
    }

    #[test]
    fn pay_signals() {
        for yes in ["$210,000", "250k", "180-240K", "220000", "$220 base", "US$205.5k", "$1.2M"] {
            assert!(high_comp(yes), "{yes}");
        }
        for no in ["", "competitive", "$150,000", "199k", "120-180k", "2026", "401k match", "300km commute", "L6", "$150,000 + 401(k)", "100m radius", "5M users", "10M+ users"] {
            assert!(!high_comp(no), "{no}");
        }
    }
}
