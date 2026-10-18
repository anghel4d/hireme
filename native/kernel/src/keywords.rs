//! A listing's target words, extracted once when `listing_raw` is
//! written, and their coverage by the text a composed CV shows.
//!
//! Extraction reads the raw listing and its format, nothing else. Markup
//! goes first: HTML tags and entities, Markdown link targets, and bare
//! URLs anywhere. Words are then runs of letters and digits (Unicode,
//! lowercased, Latin accents folded as `text::normalize` folds them) with
//! `+`, `#` and inner `.` kept, so "c++", "c#" and "node.js" are words
//! and a sentence's full stop is not part of one. A word counts when it
//! has a letter, is not a stop word, and is three characters or more (two
//! when it carries `+` or `#`: "c#", "f#"); a dotted word counts only when
//! every part has two characters or more, which keeps "node.js" and drops
//! "e.g". The [`TOP`] most frequent, ties by bytes, are the keywords.
//! They are stored in `applications.keywords` with [`VERSION`]; a change
//! to any rule here bumps the version, and the server re-extracts.

use alloc::collections::{BTreeMap, BTreeSet};
use alloc::string::String;
use alloc::vec::Vec;

/// Bump on any change to what `extract` returns for some input.
pub const VERSION: u32 = 1;

/// How many keywords a listing keeps.
pub const TOP: usize = 12;

/// Most targets a coverage reads, and the longest one.
pub const MAX_TARGETS: usize = 64;
pub const MAX_TARGET_LEN: usize = 64;

const STOP: &[&str] = &[
    "about", "across", "after", "all", "also", "and", "any", "are", "because", "been", "being", "both", "but",
    "can", "com", "could", "each", "etc", "for", "from", "get", "has", "have", "here", "how", "http", "https",
    "into", "its", "just", "like", "may", "more", "most", "must", "nbsp", "new", "not", "one", "only", "onto",
    "other", "our", "out", "over", "own", "per", "role", "such", "team", "than", "that", "the", "their", "them",
    "then", "there", "these", "they", "this", "those", "through", "use", "very", "was", "way", "well", "were",
    "what", "when", "where", "which", "while", "who", "why", "will", "with", "within", "work", "would", "www",
    "you", "your",
];

/// How `listing_raw` is written (the schema's `listing_format`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Text,
    Markdown,
    Html,
}

impl Format {
    /// From the enum code; absent is plain text.
    pub fn from_code(code: Option<u32>) -> Format {
        use schema::enums::listing_format as F;
        match code {
            Some(c) if c == F::MARKDOWN as u32 => Format::Markdown,
            Some(c) if c == F::HTML as u32 => Format::Html,
            _ => Format::Text,
        }
    }
}

/// The listing's prose: tags, entities, link targets and URLs blanked.
fn prose(listing: &str, format: Format) -> String {
    let (html, md) = (format == Format::Html, format == Format::Markdown);
    let mut out = String::with_capacity(listing.len());
    let mut i = 0;
    let mut prev = ' ';
    while let Some(c) = listing[i..].chars().next() {
        let rest = &listing[i..];
        let through = |end: char| rest.find(end).map_or(rest.len(), |j| j + end.len_utf8());
        let url = !word_char(prev) && (rest.starts_with("http://") || rest.starts_with("https://") || rest.starts_with("www."));
        let skip = if html && c == '<' {
            Some(through('>'))
        } else if html && c == '&' && rest[1..].find(';').is_some_and(|j| j < 9) {
            Some(through(';'))
        } else if md && rest.starts_with("](") {
            Some(through(')'))
        } else if url {
            Some(rest.find(char::is_whitespace).unwrap_or(rest.len()))
        } else {
            None
        };
        match skip {
            Some(n) => {
                out.push(' ');
                prev = ' ';
                i += n;
            }
            None => {
                out.push(c);
                prev = c;
                i += c.len_utf8();
            }
        }
    }
    out
}

fn word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '+' || c == '#' || c == '.'
}

fn counts(w: &str) -> bool {
    let len = w.chars().count();
    let marked = w.contains(['+', '#']);
    w.chars().any(char::is_alphabetic)
        && (len >= 3 || (marked && len >= 2))
        && !STOP.contains(&w)
        && (!w.contains('.') || w.split('.').all(|p| p.chars().count() >= 2))
}

/// The listing's keywords, most frequent first, ties by bytes.
pub fn extract(listing: &str, format: Format) -> Vec<String> {
    let text = prose(listing, format);
    let mut seen: BTreeMap<String, u32> = BTreeMap::new();
    for raw in text.split(|c: char| !word_char(c)).filter(|w| !w.trim_matches('.').is_empty()) {
        let w = crate::text::fold(raw.trim_matches('.'));
        if counts(&w) {
            *seen.entry(w).or_insert(0) += 1;
        }
    }
    let mut all: Vec<(String, u32)> = seen.into_iter().collect();
    // BTreeMap order is by bytes already; a stable sort by count keeps it.
    all.sort_by_key(|w| core::cmp::Reverse(w.1));
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

/// A CV's visible text, folded as keywords are, for whole-term lookups.
pub struct Text {
    folded: String,
}

impl Text {
    pub fn new(text: &str) -> Text {
        Text { folded: crate::text::fold(text) }
    }

    /// `term` occurs with no letter or digit on either side. A term with
    /// punctuation of its own ("c++", "node.js") matches literally.
    pub fn hit(&self, term: &str) -> bool {
        let term = crate::text::fold(term.trim());
        let Some(first) = term.chars().next() else { return false };
        let last = term.chars().next_back().unwrap_or(first);
        let t = self.folded.as_str();
        let mut from = 0;
        while let Some(p) = t[from..].find(term.as_str()) {
            let at = from + p;
            let end = at + term.len();
            let left = !first.is_alphanumeric() || t[..at].chars().next_back().is_none_or(|c| !c.is_alphanumeric());
            let right = !last.is_alphanumeric() || t[end..].chars().next().is_none_or(|c| !c.is_alphanumeric());
            if left && right {
                return true;
            }
            from = at + t[at..].chars().next().map_or(1, char::len_utf8);
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

/// The coverage of `targets` by `cv`: blanks, duplicates (after folding)
/// and terms over [`MAX_TARGET_LEN`] bytes dropped, the first
/// [`MAX_TARGETS`] kept.
pub fn coverage<'a>(targets: impl IntoIterator<Item = &'a str>, cv: &Text) -> Coverage {
    let mut seen = BTreeSet::new();
    let mut terms: Vec<(String, bool)> = Vec::new();
    for t in targets {
        if terms.len() == MAX_TARGETS {
            break;
        }
        let t = crate::text::fold(t.trim());
        if t.is_empty() || t.len() > MAX_TARGET_LEN || !seen.insert(t.clone()) {
            continue;
        }
        let hit = cv.hit(&t);
        terms.push((t, hit));
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
        let k = extract(listing, Format::Text);
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
        let k = extract(&many, Format::Text);
        assert_eq!(k.len(), TOP);
        assert_eq!(k[0], "word00");
        assert_eq!(join(&k[..2]), "word00\u{1f}word01");
        assert!(extract("", Format::Text).is_empty());
    }

    #[test]
    fn letters_markup_and_abbreviations() {
        let k = extract("Zürich Zürich Müller développeur C# C# F# ### +++ e.g. e.g. i.e. u.s. go go ai ai", Format::Text);
        assert_eq!(k, ["c#", "zurich", "developpeur", "f#", "muller"]);
        let html = extract("<div class=\"x\"><a href=\"https://acme.example/jobs\">Kernel</a>&nbsp;kernel&amp;GPU</div>", Format::Html);
        assert_eq!(html, ["kernel", "gpu"]);
        let md = extract("### Kernels\n[apply here](https://acme.example/apply) or see www.acme.example; kernels", Format::Markdown);
        assert_eq!(md, ["kernels", "apply", "see"]);
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
        let zurich = Text::new("Platform team in Zu\u{308}rich");
        assert!(zurich.hit("Zürich") && zurich.hit("zurich") && !zurich.hit("rich"));
        let many: Vec<String> = (0..200).map(|i| alloc::format!("t{i}")).collect();
        assert_eq!(coverage(many.iter().map(String::as_str), &cv).terms.len(), MAX_TARGETS);
    }
}
