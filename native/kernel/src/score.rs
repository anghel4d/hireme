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

use crate::lexicon::{self, Hits};
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

/// The rung a company name anchors on, read once per name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    None,
    Frontier,
    Labs,
    BigTech,
}

impl Tier {
    /// The tier of a normalized company name.
    pub fn of(n: &str) -> Tier {
        Tier::of_hits(Hits::of(n))
    }

    /// The tier from a name's [`Hits`].
    pub fn of_hits(h: Hits) -> Tier {
        if h.has(lexicon::FRONTIER) {
            Tier::Frontier
        } else if h.has(lexicon::LABS) {
            Tier::Labs
        } else if h.has(lexicon::BIG_TECH) {
            Tier::BigTech
        } else {
            Tier::None
        }
    }

    fn anchor(self, high_comp: bool) -> Option<u8> {
        match self {
            Tier::None => None,
            Tier::Frontier => Some(100),
            Tier::Labs => Some(90),
            Tier::BigTech => Some(if high_comp { 85 } else { 80 }),
        }
    }
}

/// The anchor a company name sits on, if any.
pub fn anchor(company: &str, high_comp: bool) -> Option<u8> {
    Tier::of(&text::normalize(company)).anchor(high_comp)
}

/// What the score reads off one normalized text (a company name, a role
/// title or a location), as flags. A seat's company and role are read
/// separately and their facts joined, so each distinct name and title is
/// read once; a phrase straddling the two ("…body" + "shop…") is not one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Facts(u16);

impl Facts {
    const STAFFING: u16 = 1;
    const INTERN: u16 = 2;
    const THEATER: u16 = 4;
    const NOT_ENGINEERING: u16 = 8;
    const SYSTEMS: u16 = 16;
    const AGENTIC: u16 = 32;
    const LOW_LEVEL: u16 = 64;
    const MID_CURVE: u16 = 128;
    const REMOTE: u16 = 256;
    const ONSITE_ONLY: u16 = 512;

    /// The facts of an already normalized text.
    pub fn of(n: &str) -> Facts {
        Facts::of_hits(Hits::of(n))
    }

    /// The facts from a text's [`Hits`].
    pub fn of_hits(h: Hits) -> Facts {
        let mut f = 0;
        for (bit, g) in [
            (Facts::STAFFING, lexicon::STAFFING),
            (Facts::INTERN, lexicon::INTERN),
            (Facts::THEATER, lexicon::THEATER),
            (Facts::NOT_ENGINEERING, lexicon::NOT_ENGINEERING),
            (Facts::SYSTEMS, lexicon::SYSTEMS),
            (Facts::AGENTIC, lexicon::AGENTIC),
            (Facts::LOW_LEVEL, lexicon::LOW_LEVEL),
            (Facts::MID_CURVE, lexicon::MID_CURVE),
        ] {
            if h.has(g) {
                f |= bit;
            }
        }
        Facts(f | Facts::of_place_hits(h).0)
    }

    /// The facts of an already normalized location: only remote and
    /// onsite-only are read off a place.
    pub fn of_place(n: &str) -> Facts {
        Facts::of_place_hits(Hits::of(n))
    }

    fn of_place_hits(h: Hits) -> Facts {
        let no_remote = h.has(lexicon::NO_REMOTE);
        let mut f = 0;
        if h.has(lexicon::REMOTE) && !no_remote {
            f |= Facts::REMOTE;
        }
        if no_remote || h.has(lexicon::ONSITE_ONLY) {
            f |= Facts::ONSITE_ONLY;
        }
        Facts(f)
    }

    fn has(self, bit: u16) -> bool {
        self.0 & bit != 0
    }

    fn join(self, o: Facts) -> Facts {
        Facts(self.0 | o.0)
    }
}

/// A seat's text read once: its company's facts and tier, its role's and
/// its location's facts.
#[derive(Clone, Copy, Debug)]
pub struct Read {
    pub company: Facts,
    pub tier: Tier,
    pub role: Facts,
    pub location: Facts,
}

impl Read {
    pub fn of(seat: &Seat) -> Read {
        let company = Hits::of(&text::normalize(seat.company));
        Read {
            company: Facts::of_hits(company),
            tier: Tier::of_hits(company),
            role: Facts::of(&text::normalize(seat.role)),
            location: Facts::of_place(&text::normalize(seat.location)),
        }
    }
}

/// The hard kill a seat falls under, if any.
pub fn kill(seat: &Seat) -> Option<Kill> {
    kill_read(seat, &Read::of(seat))
}

fn kill_read(seat: &Seat, r: &Read) -> Option<Kill> {
    let t = r.company.join(r.role);
    if t.has(Facts::STAFFING) {
        Some(Kill::Staffing)
    } else if t.has(Facts::INTERN) {
        Some(Kill::Intern)
    } else if t.has(Facts::THEATER) {
        Some(Kill::Theater)
    } else if t.has(Facts::NOT_ENGINEERING) {
        Some(Kill::NotEngineering)
    } else if onsite_away(seat, r.location) {
        Some(Kill::OnsiteAway)
    } else {
        None
    }
}

/// Onsite-only and known to be away: the place is outside home, not just
/// unknown, and nothing says remote.
fn onsite_away(seat: &Seat, loc: Facts) -> bool {
    seat.home == Some(false) && !loc.has(Facts::REMOTE) && (seat.onsite || loc.has(Facts::ONSITE_ONLY))
}

/// Space between a figure and what qualifies it: any Unicode whitespace
/// (tab, newline, NBSP, U+202F) and the invisible format characters
/// copy-paste leaves behind.
fn blank(c: char) -> bool {
    c.is_whitespace() || matches!(c, '\u{200b}'..='\u{200d}' | '\u{2060}' | '\u{feff}')
}

/// A sign next to a figure, glued or spaced: a currency, or a unit ('°').
fn sign(c: char) -> bool {
    matches!(c, '$' | '£' | '¥' | '¢' | '°' | '円' | '元' | '圆' | '원' | '﷼' | '＄' | '￠' | '￡' | '￥' | '￦')
        // The currency symbols block: € ₹ ₩ ₽ ₺ ₪ ₫ ₱ ₴ ₸ ₦ ₿ and the rest.
        || ('\u{20a0}'..='\u{20cf}').contains(&c)
        || c == '฿'
}

/// What separates thousands besides a comma: "250 000", "250\u{202f}000",
/// "250’000" (Swiss), "250'000".
fn grouping(c: char) -> bool {
    matches!(c, ' ' | '\u{a0}' | '\u{202f}' | '\u{2009}' | '\'' | '’')
}

/// Currency codes and names that make a figure money: after it, it is the
/// amount ("250 SEK", "250 euros"); before it, glued or spaced, it is a
/// sign ("USD250k").
const CURRENCIES: [&[u8]; 43] = [
    b"usd", b"eur", b"gbp", b"cad", b"chf", b"aud", b"nzd", b"sek", b"nok", b"dkk", b"isk", b"pln", b"czk", b"huf", b"ron",
    b"bgn", b"jpy", b"cny", b"rmb", b"krw", b"inr", b"sgd", b"hkd", b"brl", b"mxn", b"zar", b"ils", b"aed", b"sar",
    b"usdt", b"usdc", b"kr", b"z\xc5\x82", b"k\xc4\x8d", b"r$", b"lei", b"yen", b"euro", b"euros", b"dollar", b"dollars",
    b"pounds", b"rupees",
];

/// `w` starts `r` as a whole word, case-insensitively.
fn word_starts(r: &[u8], w: &[u8]) -> bool {
    r.len() >= w.len() && r[..w.len()].eq_ignore_ascii_case(w) && !r.get(w.len()).is_some_and(u8::is_ascii_alphanumeric)
}

/// A rate's unit right at `j`: "/h", "/hr", "/day", "per hour", "an
/// hour", "hourly", "p.d.", "/tim", "/Std.".
fn per_unit(b: &[u8], j: usize) -> bool {
    const ALONE: [&[u8]; 10] = [b"hourly", b"daily", b"weekly", b"monthly", b"ph", b"pd", b"p.h.", b"p.d.", b"p/h", b"p/d"];
    const UNITS: [&[u8]; 23] = [
        b"h", b"hr", b"hrs", b"hour", b"hours", b"d", b"day", b"days", b"wk", b"week", b"mo", b"month", b"j", b"jour", b"tim",
        b"timme", b"std", b"stunde", b"stunden", b"tag", b"dag", b"dagen", b"dia",
    ];
    let r = b.get(j..).unwrap_or_default();
    if ALONE.iter().any(|u| word_starts(r, u)) {
        return true;
    }
    let r = match r {
        [b'/', rest @ ..] => rest,
        _ => match [&b"per"[..], b"an", b"a", b"pro", b"par"].iter().find(|w| word_starts(r, w)) {
            Some(w) if r.get(w.len()).is_some_and(u8::is_ascii_whitespace) => &r[w.len()..],
            _ => return false,
        },
    };
    let r = r.trim_ascii_start();
    UNITS.iter().any(|u| word_starts(r, u))
}

/// Only a range's joiner between two figures: "-", "–", "to", "bis",
/// "/", with spaces and the upper bound's own sign around it ("$200–$300").
fn joiner(gap: &str) -> bool {
    const JOINERS: [&str; 22] = [
        "-", "--", "\u{2013}", "\u{2014}", "\u{2212}", "~", "/", "...", "\u{2026}", "to", "bis", "\u{e0}", "a", "or", "and", "und",
        "oder", "et", "ou", "y", "o", "till",
    ];
    let g = gap.trim_matches(blank).trim_end_matches(|c| sign(c) || blank(c));
    JOINERS.iter().any(|j| g.eq_ignore_ascii_case(j))
}

/// A pay figure of $200k or more anywhere in free text: "$210,000",
/// "250k", "180-240k", "220000", "$1.2M", "250 000 €", "250.000 €",
/// "CHF 250’000". A bare figure from 200 to 999, or one after its sign,
/// reads as thousands ("$220 base"); one with a sign or a currency code
/// after it, or a rate's unit ("$250/h", "600 € per day"), is the amount,
/// and so is a range's lower bound when the upper one is ("500-650 €").
pub fn high_comp(comp: &str) -> bool {
    let b = comp.as_bytes();
    let at = |j: usize| comp.get(j..).and_then(|t| t.chars().next());
    let before = |j: usize| comp.get(..j).and_then(|t| t.chars().next_back());
    let mut i = 0;
    let mut best = 0f64;
    // The last figure read as thousands and where it ended, held until the
    // next figure shows whether it is a range's lower bound.
    let mut held: Option<(f64, usize)> = None;
    // A range's upper bound is no smaller than its lower one: "$220 and 20
    // USD bonus" is two figures, not a range.
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
        // Digits since the last separator, and whether one was taken: the
        // first group has one to three digits, every later one three.
        let mut run = 0u32;
        let mut grouped = false;
        // Which mark groups thousands: the other one is the decimal point
        // ("250,000.00", "250.000,00").
        let mut mark = 0u8;
        loop {
            match b.get(i) {
                Some(&p @ (b',' | b'.')) if !in_frac => {
                    let digits = b[i + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
                    // Exactly three digits group, unless a suffix makes them a
                    // fraction ("1.250M"); one or two are a fraction ("1,2M",
                    // "3500,00 €").
                    let group = digits == 3 && (mark == 0 || mark == p) && !(p == b'.' && b.get(i + 4).is_some_and(u8::is_ascii_alphabetic));
                    if group && (p == b',' || ((1..=3).contains(&run) && (!grouped || run == 3))) {
                        mark = p;
                        run = 0;
                        grouped = true;
                    } else if digits > 0 && (p == b'.' || digits <= 2) {
                        in_frac = true;
                    } else {
                        break;
                    }
                }
                Some(&d) if d.is_ascii_digit() && in_frac => {
                    frac += (d - b'0') as f64 * scale;
                    scale /= 10.0;
                }
                Some(&d) if d.is_ascii_digit() => {
                    n = n * 10.0 + (d - b'0') as f64;
                    run += 1;
                }
                // A separator inside the integer part, between a digit and a
                // group of exactly three digits.
                Some(_) if !in_frac && b[i - 1].is_ascii_digit() && (1..=3).contains(&run) && (!grouped || run == 3) => match at(i) {
                    Some(c) if grouping(c) => {
                        let g = i + c.len_utf8();
                        let three = g + 3 <= b.len() && b[g..g + 3].iter().all(u8::is_ascii_digit);
                        if !three || b.get(g + 3).is_some_and(u8::is_ascii_digit) {
                            break;
                        }
                        i = g;
                        run = 0;
                        grouped = true;
                        continue;
                    }
                    _ => break,
                },
                _ => break,
            }
            i += 1;
        }
        let v = n + frac;
        // A suffix letter counts only when it ends the token: "250k", not
        // "300km"; "401k" is a retirement plan. Every look around the
        // number is a few characters: no copy.
        let ends = |j: usize| j >= b.len() || !b[j].is_ascii_alphanumeric();
        let suffix = if i < b.len() && b[i].is_ascii_alphabetic() && ends(i + 1) { b[i].to_ascii_lowercase() } else { 0 };
        let skip_spaces = |mut j: usize| {
            while let Some(c) = at(j).filter(|c| blank(*c)) {
                j += c.len_utf8();
            }
            j
        };
        let back_spaces = |mut j: usize| {
            while let Some(c) = before(j).filter(|c| blank(*c)) {
                j -= c.len_utf8();
            }
            j
        };
        // `w` is at `j` as a whole word, case-insensitively.
        let word_at = |j: usize, w: &[u8]| {
            j + w.len() <= b.len() && b[j..j + w.len()].eq_ignore_ascii_case(w) && ends(j + w.len())
        };
        let word_before = |k: usize, w: &[u8]| {
            k >= w.len() && b[k - w.len()..k].eq_ignore_ascii_case(w) && (k == w.len() || !b[k - w.len() - 1].is_ascii_alphanumeric())
        };
        // A currency code glued before the figure is its sign ("USD250k").
        let after_letter = start > 0 && b[start - 1].is_ascii_alphabetic() && !CURRENCIES.iter().any(|c| word_before(start, c));
        // Millions are pay only as money ("$1.2M", "USD 1.2M", "1.2M USD"),
        // not "5M users".
        let money_sign = |c: char| sign(c) && c != '°';
        let k = back_spaces(start);
        let sign_before = before(k).is_some_and(money_sign);
        // What follows the figure, past a suffix or the punctuation that
        // closes it ("250.–/h", "250,– €"), but not into the next figure.
        let end = if suffix != 0 {
            i + 1
        } else {
            let mut j = i;
            while let Some(c) = at(j).filter(|c| matches!(c, '.' | ',' | '-' | '\u{2013}' | '\u{2014}')) {
                j += c.len_utf8();
            }
            if at(j).is_some_and(|c| c.is_ascii_digit()) { i } else { j }
        };
        let after = skip_spaces(end);
        // A sign after the figure, not the next figure's own ("$250 $150").
        let unit_after = at(after).filter(|c| sign(*c) && !at(after + c.len_utf8()).is_some_and(|d| d.is_ascii_digit()));
        let code_after = CURRENCIES.iter().find(|c| word_at(after, c)).map(|c| c.len());
        let money = sign_before || unit_after.is_some_and(money_sign) || code_after.is_some() || CURRENCIES.iter().any(|c| word_before(k, c));
        // A rate: its unit after the figure, or after the figure's sign or
        // currency word ("$250/h", "250 EUR/h", "800 kr/tim").
        let rate = per_unit(b, after) || {
            let w = match (unit_after, code_after) {
                (Some(c), _) => c.len_utf8(),
                (None, Some(w)) => w,
                (None, None) => b[after..].iter().take_while(|c| c.is_ascii_alphabetic()).count(),
            };
            (1..=3).contains(&w) && per_unit(b, skip_spaces(after + w))
        };
        // Retirement plans: 401(k), 403(b), 457(b), in any spacing.
        let paren = |letter: u8| {
            let j = skip_spaces(i);
            if j >= b.len() || b[j] != b'(' {
                return false;
            }
            let j = skip_spaces(j + 1);
            if j >= b.len() || b[j].to_ascii_lowercase() != letter {
                return false;
            }
            let j = skip_spaces(j + 1);
            j < b.len() && b[j] == b')'
        };
        let plan = (v == 401.0 && (suffix == b'k' || paren(b'k'))) || ((v == 403.0 || v == 457.0) && paren(b'b'));
        let glued = at(i);
        let literal = unit_after.is_some() || code_after.is_some() || rate;
        let mut shorthand = false;
        let value = match suffix {
            _ if plan => 0.0,
            b'k' => v * 1e3,
            b'm' if money => v * 1e6,
            b'm' => 0.0,
            _ if i < b.len() && b[i].is_ascii_alphabetic() && code_after.is_none() => 0.0,
            // A sign, code or rate after the figure, glued or spaced ("250¥",
            // "250 €", "250 EUR", "30°", "$250/h"), makes it the amount
            // itself; the thousands shorthand is a bare figure or one after
            // its sign ("$220 base").
            _ if literal => v,
            // A glued letter is a word ("250é"); punctuation is not ("…").
            _ if glued.is_some_and(char::is_alphanumeric) => 0.0,
            _ if (200.0..1_000.0).contains(&v) => {
                shorthand = true;
                v * 1e3
            }
            _ => v,
        };
        if !after_letter {
            if let Some((h, end)) = held.take()
                && !(literal && value * 1e3 >= h && joiner(comp.get(end..start).unwrap_or("?")))
            {
                best = best.max(h);
            }
            if shorthand {
                held = Some((value, i));
            } else {
                best = best.max(value);
            }
        }
    }
    if let Some((h, _)) = held {
        best = best.max(h);
    }
    best >= 200_000.0
}

/// The Life-EV suggestion for a seat.
pub fn suggest(seat: &Seat) -> Suggestion {
    suggest_read(seat, &Read::of(seat))
}

/// [`suggest`] with the seat's text already read (`r` must be
/// `Read::of(seat)`; the board reads each distinct name and title once).
pub fn suggest_read(seat: &Seat, r: &Read) -> Suggestion {
    let high = high_comp(seat.comp_raw);
    if let Some(k) = kill_read(seat, r) {
        return Suggestion { score: k.score(), band: Band::Kill, kill: Some(k), anchored: false };
    }
    if let Some(a) = r.tier.anchor(high) {
        return Suggestion { score: a, band: Band::of(a), kill: None, anchored: true };
    }
    let t = r.company.join(r.role);
    let mut s: i32 = 48;
    if t.has(Facts::SYSTEMS) {
        s += 22;
    }
    if t.has(Facts::AGENTIC) {
        s += 10;
    }
    if t.has(Facts::LOW_LEVEL) {
        s += 8;
    }
    if seat.home == Some(true) || r.location.has(Facts::REMOTE) {
        s += 5;
    }
    if high {
        s += 6;
    }
    if t.has(Facts::MID_CURVE) {
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
        assert!(!suggest(&s("Fair Oaks Capital", "Engineer")).anchored);
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
        // "no remote" is not remote (no +5); a company and a role are read
        // apart, so a phrase straddling them is no kill.
        assert_eq!(suggest(&Seat { location: "no remote", ..s("Acme", "Engineer") }).score, suggest(&s("Acme", "Engineer")).score);
        assert_eq!(suggest(&Seat { location: "remote", ..s("Acme", "Engineer") }).score, suggest(&s("Acme", "Engineer")).score + 5);
        assert_eq!(suggest(&s("Acme Body", "Shop Lead")).kill, None);
        assert_eq!(suggest(&s("Sales", "Engineer")).kill, None);
    }

    #[test]
    fn pay_reading_never_panics_and_stays_linear() {
        let pieces = ["1", "25", "0", "000", "k", "K", "m", "M", "$", "€", "£", "¥", "°", "\u{a0}", "\u{202f}", "\t", "\n", "’", "'", " ", "(", ")", "b", "usd", ".", ",", "é", "ü", "🙂", "401", "\u{308}", "\u{200b}"];
        let mut r = 0x2545_F491_4F6C_DD1Du64;
        for _ in 0..20_000 {
            let mut t = alloc::string::String::new();
            for _ in 0..(r % 12) {
                r ^= r << 13;
                r ^= r >> 7;
                r ^= r << 17;
                t.push_str(pieces[(r % pieces.len() as u64) as usize]);
            }
            let _ = high_comp(&t);
        }
        let long = "1 ".repeat(50_000);
        let t = std::time::Instant::now();
        assert!(!high_comp(&long));
        // Linear, not fast: a debug build under load gets ten times the room.
        assert!(t.elapsed().as_millis() < if cfg!(debug_assertions) { 2_000 } else { 200 });
    }

    #[test]
    fn pay_signals() {
        for yes in ["$210,000", "250k", "180-240K", "220000", "$220 base", "US$205.5k", "$1.2M", "USD 1.2M", "1.2M USD", "€250k", "250k€", "1.2M€", "250\u{a0}k", "$\t1.2M", "USD\u{202f}1.2M", "1.2M\u{a0}€", "€\u{200b}250k", "250\u{202f}000 €", "250 000 €", "CHF 250’000", "CHF 250'000", "15,000,000円", "120,000,000원", "300000₴", "3000000₸", "20,000,000₦", "1.2M₩", "1.2M¥", "250 000 $", "1 250 000", "250.000 €", "Gehalt: 210.000 € - 250.000 €", "ab 250.000 € brutto", "250.000,00 €", "250.000 $", "1.250.000 €", "€1,2M", "250,000.00", "CHF 250’000.–", "250’000.– CHF", "250.000,– €", "$250,000—depending on level", "Up to $250,000…", "$250 $150", "£250\n£150", "$200 - $250k", "220 - 260k £", "USD250k", "EUR250k", "USD250,000", "CHF250'000", "EUR250 - EUR300", "$250 OTE", "SEK 2 500 000", "$1,200,000USD", "250,000kr", "Base 220, try to negotiate", "$220, try for more", "$220 and 20 USD bonus", "220 or 3 euros", "220 et 30 euros"] {
            assert!(high_comp(yes), "{yes}");
        }
        for no in ["", "competitive", "$150,000", "199k", "120-180k", "2026", "401k match", "300km commute", "L6", "$150,000 + 401(k)", "100m radius", "5M users", "10M+ users", "401 (k)", "403(b)", "457(b) match", "1.2Mü", "2Mé", "457 ( b )", "fraud 5M", "applaud 5M users", "entrepreneur 5M", "50€/h", "45.000€", "250¥", "30°", "3000€ brut", "401\n(k)", "403\t(b)", "457\u{a0}(b)", "150\u{202f}000 €", "CHF 150’000", "5\u{a0}M users", "2 300 km", "250é", "2024 100", "150 0000", "199 000 €", "250$", "250$/h", "250 €", "250 €/h", "220 £", "250\u{a0}€", "250\u{202f}€", "250\t€", "250 °", "250 EUR", "TJM : 500-650 €", "Day rate: 600-700 €", "200-250 €/h", "220 - 260 £", "500–650 €", "300 to 350 €", "$250/h", "$250/hr", "€250/h", "£500/day", "$700 per day", "$200–$300/hr", "250 EUR/h", "250 USD / hour", "800 kr/tim", "3500,00 €", "45 000,00 €", "1.500k", "250 SEK", "500-650 SEK", "250 PLN", "250 JPY", "250 kr", "250 zł", "250 Kč", "250 R$", "250 euros", "250 dollars", "250 USDT", "250USD", "$250 hourly", "$250 an hour", "$500 a day", "$500 daily", "$250 ph", "£250 p.d.", "800 kr/timme", "$250/tag", "$250/dagen", "$250 per\thour", "CHF 250.–/h", "CHF 250.–/Std.", "600 / 700 €", "600 or 700 €", "600 und 700 €", "500 -- 650 €", "500...650 €", "220 y 260 €"] {
            assert!(!high_comp(no), "{no}");
        }
    }
}
