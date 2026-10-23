//! Every phrase the score and org rules look for in a company name, a
//! role title or a location, read in one pass.
//!
//! A text is normalized first (`text::normalize`: lowercase ASCII words
//! joined by single spaces). One byte trie holds every needle; the reader
//! walks it from each word start, so a text costs about its length times
//! the depth of the longest match, whatever the number of needles. A
//! needle matches as a whole word or phrase, or at a word start with its
//! end running into a word ("infra" in "infrastructure"); a named set also
//! matches the whole name with its spaces removed ("deep mind").
//!
//! The rules that read these hits live with their kinds: `score::Facts`,
//! `score::Tier`, `org::Size`, `org::Department`, `org::Family`.

use alloc::vec::Vec;
use std::sync::OnceLock;

use crate::text;

/// Which rule a needle feeds: one bit of [`Hits`].
pub type Group = u8;

pub const STAFFING: Group = 0;
pub const INTERN: Group = 1;
pub const THEATER: Group = 2;
pub const NOT_ENGINEERING: Group = 3;
pub const SYSTEMS: Group = 4;
pub const AGENTIC: Group = 5;
pub const LOW_LEVEL: Group = 6;
pub const MID_CURVE: Group = 7;
pub const NO_REMOTE: Group = 8;
pub const REMOTE: Group = 9;
pub const ONSITE_ONLY: Group = 10;
pub const FRONTIER: Group = 11;
pub const LABS: Group = 12;
pub const BIG_TECH: Group = 13;
pub const MEGA: Group = 14;
pub const LARGE: Group = 15;
pub const MID: Group = 16;
pub const DEPT_RESEARCH: Group = 17;
pub const DEPT_INFRA: Group = 18;
pub const DEPT_SECURITY: Group = 19;
pub const DEPT_DATA: Group = 20;
pub const DEPT_PRODUCT: Group = 21;
pub const DEPT_ENG: Group = 22;
pub const FAM_RESEARCH_SCIENTIST: Group = 23;
pub const FAM_RESEARCH_ENGINEER: Group = 24;
pub const FAM_SRE: Group = 25;
pub const FAM_DATA_ENGINEER: Group = 26;
pub const FAM_SECURITY_ENGINEER: Group = 27;
pub const FAM_SOFTWARE_ENGINEER: Group = 28;

/// The family groups: read on a title with its seniority words removed.
const FAMILY: u64 = 0b11_1111 << FAM_RESEARCH_SCIENTIST;

/// How a needle matches.
#[derive(Clone, Copy)]
enum Mode {
    /// A whole word or phrase.
    Whole,
    /// At a word start; its end may run into a word.
    Start,
    /// A named set: a whole word, or the whole name without its spaces.
    Named,
}

use Mode::*;

pub(crate) const FRONTIER_NAMES: &[&str] = &["openai", "anthropic", "spacex", "neuralink", "xai", "spacexai"];
pub(crate) const LABS_NAMES: &[&str] = &["starfish", "valve", "gdm", "deepmind", "meta", "ssi", "mira"];
pub(crate) const LABS_PHRASES: &[&str] = &["google deepmind", "thinking machines", "safe superintelligence", "meta fair"];
pub(crate) const BIG_TECH_NAMES: &[&str] = &[
    "google", "alphabet", "apple", "microsoft", "amazon", "nvidia", "netflix", "uber", "stripe", "databricks",
    "snowflake", "tesla", "adobe", "salesforce", "oracle", "linkedin", "snap", "pinterest", "shopify",
];
pub(crate) const MEGA_NAMES: &[&str] = &["google", "alphabet", "amazon", "aws", "meta", "facebook", "nvidia", "microsoft"];
pub(crate) const LARGE_NAMES: &[&str] = &[
    "apple", "netflix", "uber", "stripe", "databricks", "snowflake", "tesla", "adobe", "salesforce", "oracle",
    "linkedin", "snap", "pinterest", "shopify", "openai", "anthropic", "spacex", "neuralink", "xai", "starfish",
    "valve", "gdm", "deepmind", "ssi", "mira",
];
pub(crate) const MID_WORDS: &[&str] = &["systems", "runtime", "infra", "lab", "labs"];

/// Seniority words, removed from a title before its family is read, so
/// "Senior Software Engineer" and "Staff Software Engineer" are clones.
pub(crate) const SENIORITY: &[&str] = &[
    "staff", "senior", "sr", "principal", "distinguished", "fellow", "junior", "jr", "intern", "iii", "ii", "i", "l3", "l4",
    "l5", "l6", "l7", "l8", "lead",
];

/// Every needle: what it is, how it matches, which group it feeds.
const NEEDLES: &[(&[&str], Mode, Group)] = &[
    (&["staffing", "body shop", "bodyshop", "recruit"], Start, STAFFING),
    (&["intern", "internship", "new grad", "newgrad", "co op", "coop"], Whole, INTERN),
    (&["prompt only", "ai theater", "chatgpt wrapper"], Whole, THEATER),
    (&["sales engineer", "business analyst", "ba", "project manager", "pm", "support engineer"], Whole, NOT_ENGINEERING),
    (&["systems", "runtime", "kernel", "infra", "infrastructure", "distributed", "compiler"], Whole, SYSTEMS),
    (&["agentic", "agent systems", "agents"], Whole, AGENTIC),
    (&["rust", "c++", "low level", "lowlevel", "systems c"], Whole, LOW_LEVEL),
    (&["crud", "full stack", "fullstack", "rails shop", "wordpress"], Whole, MID_CURVE),
    (&["no remote", "not remote"], Whole, NO_REMOTE),
    (&["remote"], Whole, REMOTE),
    (&["onsite only", "on site only"], Whole, ONSITE_ONLY),
    (FRONTIER_NAMES, Named, FRONTIER),
    (LABS_NAMES, Named, LABS),
    (LABS_PHRASES, Whole, LABS),
    (BIG_TECH_NAMES, Named, BIG_TECH),
    (MEGA_NAMES, Named, MEGA),
    (LARGE_NAMES, Named, LARGE),
    (MID_WORDS, Whole, MID),
    (&["research", "scientist", "machine learning", "applied sci"], Start, DEPT_RESEARCH),
    (&["ml"], Whole, DEPT_RESEARCH),
    (&["sre", "site reliability", "infra", "platform", "runtime", "kernel", "systems"], Start, DEPT_INFRA),
    (&["security", "privacy"], Start, DEPT_SECURITY),
    (&["data engineer", "analytics", "data platform"], Start, DEPT_DATA),
    (&["frontend", "front end", "ios", "android", "mobile", "product engineer"], Start, DEPT_PRODUCT),
    (&["engineer", "developer"], Start, DEPT_ENG),
    (&["swe"], Whole, DEPT_ENG),
    (&["research scientist", "applied scientist"], Start, FAM_RESEARCH_SCIENTIST),
    (&["research engineer"], Start, FAM_RESEARCH_ENGINEER),
    (&["site reliability"], Start, FAM_SRE),
    (&["sre"], Whole, FAM_SRE),
    (&["data engineer"], Start, FAM_DATA_ENGINEER),
    (&["security engineer"], Start, FAM_SECURITY_ENGINEER),
    (&["software engineer", "engineer", "developer"], Start, FAM_SOFTWARE_ENGINEER),
    (&["swe"], Whole, FAM_SOFTWARE_ENGINEER),
];

/// The bytes a needle is spelled in, each its own class; every other
/// byte is class 0, which no needle has, so a walk stops on it.
const CLASSES: usize = 40;

const fn class_of() -> [u8; 256] {
    let mut c = [0u8; 256];
    let mut i = 0;
    while i < 26 {
        c[b'a' as usize + i] = 1 + i as u8;
        i += 1;
    }
    let mut d = 0;
    while d < 10 {
        c[b'0' as usize + d] = 27 + d as u8;
        d += 1;
    }
    c[b'+' as usize] = 37;
    c[b'#' as usize] = 38;
    c[b' ' as usize] = 39;
    c
}

const CLASS: [u8; 256] = class_of();

/// Group bits of the needles ending at a node: at a word start, as a
/// whole word, as a whole name without spaces.
#[derive(Clone, Copy, Default)]
struct Ends {
    start: u64,
    whole: u64,
    compact: u64,
}

/// The needles as a dense trie: node `i`'s child on class `c` is
/// `next[i * CLASSES + c]`, 0 for none (the root is no one's child).
struct Trie {
    next: Vec<u16>,
    ends: Vec<Ends>,
}

impl Trie {
    fn build() -> Trie {
        let mut t = Trie { next: alloc::vec![0; CLASSES], ends: alloc::vec![Ends::default()] };
        for (words, mode, group) in NEEDLES {
            let bit = 1u64 << group;
            for w in *words {
                let mut at = 0usize;
                for &b in w.as_bytes() {
                    let c = CLASS[b as usize] as usize;
                    debug_assert!(c != 0, "a needle byte outside the classes: {w}");
                    if t.next[at * CLASSES + c] == 0 {
                        t.next[at * CLASSES + c] = t.ends.len() as u16;
                        t.ends.push(Ends::default());
                        t.next.extend([0u16; CLASSES]);
                    }
                    at = t.next[at * CLASSES + c] as usize;
                }
                let e = &mut t.ends[at];
                match mode {
                    Whole => e.whole |= bit,
                    Start => e.start |= bit,
                    Named => {
                        e.whole |= bit;
                        e.compact |= bit;
                    }
                }
            }
        }
        t
    }

    fn step(&self, at: usize, b: u8) -> usize {
        self.next[at * CLASSES + CLASS[b as usize] as usize] as usize
    }

    /// The start and whole-word groups found from each word start.
    fn scan(&self, t: &[u8]) -> u64 {
        let mut hits = 0;
        for s in 0..t.len() {
            if s > 0 && t[s - 1] != b' ' {
                continue;
            }
            let mut at = 0;
            for j in s..t.len() {
                at = self.step(at, t[j]);
                if at == 0 {
                    break;
                }
                let e = &self.ends[at];
                hits |= e.start;
                if j + 1 == t.len() || t[j + 1] == b' ' {
                    hits |= e.whole;
                }
            }
        }
        hits
    }

    /// The named groups the whole text spells with its spaces removed.
    fn compact(&self, t: &[u8]) -> u64 {
        let mut at = 0;
        for &b in t.iter().filter(|b| **b != b' ') {
            at = self.step(at, b);
            if at == 0 {
                return 0;
            }
        }
        self.ends[at].compact
    }
}

fn trie() -> &'static Trie {
    static TRIE: OnceLock<Trie> = OnceLock::new();
    TRIE.get_or_init(Trie::build)
}

/// The groups a normalized text hits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Hits(u64);

impl Hits {
    /// Every group but the families, in one pass over `n` (normalized).
    pub fn of(n: &str) -> Hits {
        let t = trie();
        Hits((t.scan(n.as_bytes()) | t.compact(n.as_bytes())) & !FAMILY)
    }

    /// The family groups of a normalized title, read with its seniority
    /// words removed.
    pub fn family(n: &str) -> Hits {
        Hits::title(n).1
    }

    /// [`Hits::of`] and [`Hits::family`] of a title, sharing the scan when
    /// it has no seniority word.
    pub fn title(n: &str) -> (Hits, Hits) {
        let t = trie();
        let all = t.scan(n.as_bytes());
        let rest = Hits((all | t.compact(n.as_bytes())) & !FAMILY);
        if text::words(n).any(|w| SENIORITY.contains(&w)) { (rest, Hits::family_core(n)) } else { (rest, Hits(all & FAMILY)) }
    }

    fn family_core(n: &str) -> Hits {
        let core: Vec<&str> = text::words(n).filter(|w| !SENIORITY.contains(w)).collect();
        Hits(trie().scan(core.join(" ").as_bytes()) & FAMILY)
    }

    pub fn has(self, g: Group) -> bool {
        self.0 & (1 << g) != 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A needle at a word start, by brute force; a `whole` one ends at a
    /// word end too.
    fn found(t: &str, n: &str, whole: bool) -> bool {
        let (t, n) = (t.as_bytes(), n.as_bytes());
        !n.is_empty()
            && (0..=t.len().saturating_sub(n.len())).any(|at| {
                t[at..].starts_with(n) && (at == 0 || t[at - 1] == b' ') && (!whole || t.get(at + n.len()).is_none_or(|b| *b == b' '))
            })
    }

    /// The rule as written, needle by needle: what one pass must equal.
    fn plain(n: &str) -> u64 {
        let compact: String = n.chars().filter(|c| *c != ' ').collect();
        let mut hits = 0;
        for (words, mode, group) in NEEDLES {
            let hit = match mode {
                Whole => words.iter().any(|w| found(n, w, true)),
                Start => words.iter().any(|w| found(n, w, false)),
                Named => words.contains(&compact.as_str()) || text::words(n).any(|w| words.contains(&w)),
            };
            if hit {
                hits |= 1 << group;
            }
        }
        hits
    }

    #[test]
    fn one_pass_reads_what_each_needle_does() {
        let t = text::normalize("Infrastructure engineer at Meta FAIR");
        assert!(found(&t, "meta fair", true) && !found(&t, "infra", true) && found(&t, "infra", false) && !found(&t, "structure", false));
        let mut pieces: Vec<&str> = NEEDLES.iter().flat_map(|(w, _, _)| w.iter().copied()).collect();
        pieces.extend(["", "a", "s", "ing", "er", "x", "senior", "deep", "mind", "open", "ai", "c", "+", "staffing", "ü", "日本"]);
        let mut r = 0x2545_F491_4F6C_DD1Du64;
        let mut next = |n: usize| {
            r ^= r << 13;
            r ^= r >> 7;
            r ^= r << 17;
            (r % n as u64) as usize
        };
        for _ in 0..50_000 {
            // Words and glued fragments, normalized as a real text is.
            let mut raw = String::new();
            for _ in 0..next(6) {
                raw.push_str(pieces[next(pieces.len())]);
                if next(3) != 0 {
                    raw.push(' ');
                }
            }
            let n = text::normalize(&raw);
            assert_eq!(Hits::of(&n).0, plain(&n) & !FAMILY, "{n:?}");
            let core: Vec<&str> = text::words(&n).filter(|w| !SENIORITY.contains(w)).collect();
            assert_eq!(Hits::family(&n).0, plain(&core.join(" ")) & FAMILY, "{n:?}");
            assert_eq!(Hits::title(&n), (Hits::of(&n), Hits::family(&n)), "{n:?}");
        }
    }
}
