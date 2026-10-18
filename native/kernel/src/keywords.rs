//! A listing's target words, extracted once when `listing_raw` is
//! written, and their coverage by the text a composed CV shows.
//!
//! Extraction reads the raw listing and nothing else: words are runs of
//! ASCII letters, digits, `+`, `#` and inner `.` (so "c++", "c#" and
//! "node.js" are words and a sentence's full stop is not part of one),
//! lowercased. A word of three or more bytes that is not a stop word and
//! not all digits counts; the [`TOP`] most frequent, ties broken by
//! bytes, are the keywords. The result is stored in
//! `applications.keywords` with [`VERSION`]; a change to any rule here
//! bumps the version, and the server re-extracts older rows.

use alloc::string::String;
use alloc::vec::Vec;

/// Bump on any change to what `extract` returns for some input.
pub const VERSION: u32 = 1;

/// How many keywords a listing keeps.
pub const TOP: usize = 12;

const STOP: &[&str] = &[
    "about", "across", "after", "all", "also", "and", "any", "are", "because", "been", "being", "both", "but",
    "can", "could", "each", "etc", "for", "from", "get", "has", "have", "here", "how", "into", "its", "just",
    "like", "may", "more", "most", "must", "new", "not", "of", "one", "only", "onto", "other", "our", "out",
    "over", "own", "per", "role", "such", "team", "than", "that", "the", "their", "them", "then", "there",
    "these", "they", "this", "those", "through", "use", "very", "was", "way", "well", "were", "what", "when",
    "where", "which", "while", "who", "why", "will", "with", "within", "work", "would", "you", "your",
];

fn word_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'+' || c == b'#' || c == b'.'
}

/// The words of `text`, lowercased, outer dots trimmed.
fn words(text: &str) -> impl Iterator<Item = String> + '_ {
    text.as_bytes()
        .split(|c| !word_byte(*c))
        .map(|w| {
            let a = w.iter().position(|c| *c != b'.').unwrap_or(w.len());
            let b = w.iter().rposition(|c| *c != b'.').map_or(a, |i| i + 1);
            &w[a..b]
        })
        .filter(|w| !w.is_empty())
        .map(|w| w.iter().map(u8::to_ascii_lowercase).map(char::from).collect())
}

fn counts(w: &str) -> bool {
    w.len() >= 3 && !STOP.contains(&w) && !w.bytes().all(|c| c.is_ascii_digit() || c == b'.')
}

/// The listing's keywords, most frequent first, ties by bytes.
pub fn extract(listing: &str) -> Vec<String> {
    let mut seen: alloc::collections::BTreeMap<String, u32> = alloc::collections::BTreeMap::new();
    for w in words(listing).filter(|w| counts(w)) {
        *seen.entry(w).or_insert(0) += 1;
    }
    let mut all: Vec<(String, u32)> = seen.into_iter().collect();
    // BTreeMap order is by bytes already; a stable sort by count keeps it.
    all.sort_by(|a, b| b.1.cmp(&a.1));
    all.truncate(TOP);
    all.into_iter().map(|(w, _)| w).collect()
}

/// The stored form: U+001F-joined.
pub fn join(words: &[String]) -> String {
    let mut out = String::new();
    for (i, w) in words.iter().enumerate() {
        if i > 0 {
            out.push('\u{1f}');
        }
        out.push_str(w);
    }
    out
}

/// A text's lowercase words split on everything but ASCII letters and
/// digits, for whole-term lookups.
pub struct Text {
    lower: String,
}

impl Text {
    pub fn new(text: &str) -> Text {
        Text { lower: text.to_ascii_lowercase() }
    }

    /// `term` occurs with no letter or digit on either side. A term with
    /// punctuation of its own ("c++", "node.js") matches literally.
    pub fn hit(&self, term: &str) -> bool {
        let term = term.trim().to_ascii_lowercase();
        if term.is_empty() {
            return false;
        }
        let (t, n) = (self.lower.as_bytes(), term.as_bytes());
        let alnum = |c: u8| c.is_ascii_alphanumeric();
        let mut from = 0;
        while let Some(p) = self.lower[from..].find(term.as_str()) {
            let at = from + p;
            let end = at + n.len();
            let left = at == 0 || !alnum(t[at - 1]) || !alnum(n[0]);
            let right = end == t.len() || !alnum(t[end]) || !alnum(n[n.len() - 1]);
            if left && right {
                return true;
            }
            from = at + self.lower[at..].chars().next().map_or(1, char::len_utf8);
        }
        false
    }
}

/// Which targets a CV's text covers, in target order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Coverage {
    pub terms: Vec<(String, bool)>,
}

impl Coverage {
    pub fn hits(&self) -> usize {
        self.terms.iter().filter(|t| t.1).count()
    }

    /// Covered over total, as a whole percent; 0 with no targets.
    pub fn percent(&self) -> u8 {
        let n = self.terms.len();
        if n == 0 { 0 } else { (self.hits() * 100 / n) as u8 }
    }

    pub fn to_json(&self) -> serde_json::Value {
        let terms: Vec<serde_json::Value> =
            self.terms.iter().map(|(t, h)| serde_json::json!({"term": t, "hit": h})).collect();
        serde_json::json!({"hits": self.hits(), "total": self.terms.len(), "percent": self.percent(), "terms": terms})
    }
}

/// The coverage of `targets` (duplicates and blanks dropped, first kept)
/// by `cv`.
pub fn coverage<'a>(targets: impl IntoIterator<Item = &'a str>, cv: &Text) -> Coverage {
    let mut terms: Vec<(String, bool)> = Vec::new();
    for t in targets {
        let t = t.trim();
        if t.is_empty() || terms.iter().any(|(s, _)| s.eq_ignore_ascii_case(t)) {
            continue;
        }
        terms.push((t.to_ascii_lowercase(), cv.hit(t)));
    }
    Coverage { terms }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_by_count_then_bytes() {
        let listing = "We build Rust systems. Rust, C++ and Node.js; rust again! GPU kernels for the GPU team. \
                       2026 and 3.14 are numbers. The the the.";
        let k = extract(listing);
        assert_eq!(k[0], "rust");
        assert_eq!(k[1], "gpu");
        assert!(k.contains(&String::from("c++")));
        assert!(k.contains(&String::from("node.js")));
        assert!(k.contains(&String::from("systems")));
        assert!(!k.iter().any(|w| w == "the" || w == "2026" || w == "3.14" || w.ends_with('.')));
        let tail: Vec<&String> = k.iter().skip(2).collect();
        let mut sorted = tail.clone();
        sorted.sort();
        assert_eq!(tail, sorted);
    }

    #[test]
    fn keeps_the_top_only_and_joins() {
        let many: String = (0..40).map(|i| alloc::format!("word{i:02} ")).collect();
        let k = extract(&many);
        assert_eq!(k.len(), TOP);
        assert_eq!(k[0], "word00");
        assert_eq!(join(&k[..2]), "word00\u{1f}word01");
        assert!(extract("").is_empty());
    }

    #[test]
    fn coverage_is_whole_term() {
        let cv = Text::new("Built a Rust runtime; C++ and Node.js tooling. Rustacean.");
        assert!(cv.hit("rust"));
        assert!(cv.hit("C++"));
        assert!(cv.hit("node.js"));
        assert!(!cv.hit("run"));
        assert!(!cv.hit("go"));
        let c = coverage(["rust", "Rust", "go", " ", "c++"], &cv);
        assert_eq!(c.terms.len(), 3);
        assert_eq!(c.hits(), 2);
        assert_eq!(c.percent(), 66);
    }
}
