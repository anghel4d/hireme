//! A listing's target words, extracted once when `listing_raw` is
//! written, and their coverage by the text a composed CV shows.
//!
//! Extraction reads the raw listing and its format, nothing else. Markup
//! goes first: HTML tags, comments, entities and `<style>`/`<script>`
//! bodies, Markdown link targets, and bare URLs anywhere. Words are then runs of letters and digits (Unicode,
//! lowercased, Latin accents folded as `text::normalize` folds them) with
//! `+`, `#` and inner `.` kept, so "c++", "c#" and "node.js" are words
//! and a sentence's full stop is not part of one. A word counts when it
//! has a letter, is not a stop word, and is three characters or more (two
//! when it carries `#`: "c#", "f#"); a dotted word counts only when
//! every part has two characters or more, which keeps "node.js" and drops
//! "e.g". The [`TOP`] most frequent, ties by bytes, are the keywords.
//! They are stored in `applications.keywords` with [`VERSION`]; a change
//! to any rule here bumps the version, and the server re-extracts.
//!
//! The kernel only ever holds a listing's text in the op that writes it,
//! so a put that changes `listing_format` alone does not re-extract; the
//! next write of `listing_raw` (or a version bump's backfill) does.

use alloc::collections::{BTreeMap, BTreeSet};
use alloc::string::String;
use alloc::vec::Vec;

/// Bump on any change to what `extract` returns for some input.
pub const VERSION: u32 = 3;

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
        let skip = if html && rest.starts_with("<!--") {
            Some(rest.find("-->").map_or(rest.len(), |j| j + 3))
        } else if html && (tag(rest, "<style") || tag(rest, "<script")) {
            let close = if tag(rest, "<style") { "</style" } else { "</script" };
            Some(find_ci(rest, close).map_or(rest.len(), |j| j + close.len()))
        } else if html && c == '<' {
            Some(through('>'))
        } else if html && c == '&' && entity(rest).is_some() {
            entity(rest)
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

fn starts_ci(s: &str, p: &str) -> bool {
    s.len() >= p.len() && s.as_bytes()[..p.len()].eq_ignore_ascii_case(p.as_bytes())
}

/// `s` opens the tag `p` ("<style"), not a longer name ("<styles").
fn tag(s: &str, p: &str) -> bool {
    starts_ci(s, p) && s.as_bytes().get(p.len()).is_none_or(|b| b.is_ascii_whitespace() || *b == b'>' || *b == b'/')
}

/// The length of an HTML entity at the start of `s` ("&amp;", "&#38;",
/// "&#x26;"), looking at most a few bytes ahead; `None` for prose like
/// "R&D;".
fn entity(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let end = b.iter().take(12).position(|c| *c == b';')?;
    let body = &b[1..end];
    let ok = match body {
        [b'#', b'x' | b'X', hex @ ..] => !hex.is_empty() && hex.iter().all(u8::is_ascii_hexdigit),
        [b'#', dec @ ..] => !dec.is_empty() && dec.iter().all(u8::is_ascii_digit),
        name => ENTITIES.binary_search(&name).is_ok(),
    };
    ok.then_some(end + 1)
}

/// The HTML 4 named entities (sorted, for a binary search); anything
/// else between '&' and ';' is prose ("salary&bonus;").
const ENTITIES: &[&[u8]] = &[
    b"AElig", b"Aacute", b"Acirc", b"Agrave", b"Alpha", b"Aring", b"Atilde", b"Auml", b"Beta", b"Ccedil",
    b"Chi", b"Dagger", b"Delta", b"ETH", b"Eacute", b"Ecirc", b"Egrave", b"Epsilon", b"Eta", b"Euml",
    b"Gamma", b"Iacute", b"Icirc", b"Igrave", b"Iota", b"Iuml", b"Kappa", b"Lambda", b"Mu", b"Ntilde", b"Nu",
    b"OElig", b"Oacute", b"Ocirc", b"Ograve", b"Omega", b"Omicron", b"Oslash", b"Otilde", b"Ouml", b"Phi",
    b"Pi", b"Prime", b"Psi", b"Rho", b"Scaron", b"Sigma", b"THORN", b"Tau", b"Theta", b"Uacute", b"Ucirc",
    b"Ugrave", b"Upsilon", b"Uuml", b"Xi", b"Yacute", b"Yuml", b"Zeta", b"aacute", b"acirc", b"acute",
    b"aelig", b"agrave", b"alefsym", b"alpha", b"amp", b"and", b"ang", b"aring", b"asymp", b"atilde",
    b"auml", b"bdquo", b"beta", b"brvbar", b"bull", b"cap", b"ccedil", b"cedil", b"cent", b"chi", b"circ",
    b"clubs", b"cong", b"copy", b"crarr", b"cup", b"curren", b"dArr", b"dagger", b"darr", b"deg", b"delta",
    b"diams", b"divide", b"eacute", b"ecirc", b"egrave", b"empty", b"emsp", b"ensp", b"epsilon", b"equiv",
    b"eta", b"eth", b"euml", b"euro", b"exist", b"fnof", b"forall", b"frac12", b"frac14", b"frac34",
    b"frasl", b"gamma", b"ge", b"gt", b"hArr", b"harr", b"hearts", b"hellip", b"iacute", b"icirc", b"iexcl",
    b"igrave", b"image", b"infin", b"int", b"iota", b"iquest", b"isin", b"iuml", b"kappa", b"lArr",
    b"lambda", b"lang", b"laquo", b"larr", b"lceil", b"ldquo", b"le", b"lfloor", b"lowast", b"loz", b"lrm",
    b"lsaquo", b"lsquo", b"lt", b"macr", b"mdash", b"micro", b"middot", b"minus", b"mu", b"nabla", b"nbsp",
    b"ndash", b"ne", b"ni", b"not", b"notin", b"nsub", b"ntilde", b"nu", b"oacute", b"ocirc", b"oelig",
    b"ograve", b"oline", b"omega", b"omicron", b"oplus", b"or", b"ordf", b"ordm", b"oslash", b"otilde",
    b"otimes", b"ouml", b"para", b"part", b"permil", b"perp", b"phi", b"pi", b"piv", b"plusmn", b"pound",
    b"prime", b"prod", b"prop", b"psi", b"quot", b"rArr", b"radic", b"rang", b"raquo", b"rarr", b"rceil",
    b"rdquo", b"real", b"reg", b"rfloor", b"rho", b"rlm", b"rsaquo", b"rsquo", b"sbquo", b"scaron", b"sdot",
    b"sect", b"shy", b"sigma", b"sigmaf", b"sim", b"spades", b"sub", b"sube", b"sum", b"sup", b"sup1",
    b"sup2", b"sup3", b"supe", b"szlig", b"tau", b"there4", b"theta", b"thetasym", b"thinsp", b"thorn",
    b"tilde", b"times", b"trade", b"uArr", b"uacute", b"uarr", b"ucirc", b"ugrave", b"uml", b"upsih",
    b"upsilon", b"uuml", b"weierp", b"xi", b"yacute", b"yen", b"yuml", b"zeta", b"zwj", b"zwnj",
];

fn find_ci(s: &str, p: &str) -> Option<usize> {
    let (b, n) = (s.as_bytes(), p.as_bytes());
    (0..=b.len().checked_sub(n.len())?).find(|&i| b[i..i + n.len()].eq_ignore_ascii_case(n))
}

fn word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '+' || c == '#' || c == '.'
}

fn counts(w: &str) -> bool {
    let len = w.chars().count();
    w.chars().any(char::is_alphabetic)
        && (len >= 3 || (w.contains('#') && len >= 2))
        && STOP.binary_search(&w).is_err()
        && (!w.contains('.') || w.split('.').all(|p| p.chars().count() >= 2))
}

/// The listing's keywords, most frequent first, ties by bytes.
pub fn extract(listing: &str, format: Format) -> Vec<String> {
    // Folded before splitting, so a decomposed accent stays in its word.
    // Plain text with no URL needs no markup pass.
    let plain = format == Format::Text && !listing.contains("http") && !listing.contains("www.");
    let text = if plain { crate::text::fold(listing) } else { crate::text::fold(&prose(listing, format)) };
    let mut seen: BTreeMap<&str, u32> = BTreeMap::new();
    for raw in text.split(|c: char| !word_char(c)) {
        let w = raw.trim_matches('.');
        if !w.is_empty() && counts(w) {
            *seen.entry(w).or_insert(0) += 1;
        }
    }
    let mut all: Vec<(&str, u32)> = seen.into_iter().collect();
    // BTreeMap order is by bytes already; a stable sort by count keeps it.
    all.sort_by_key(|w| core::cmp::Reverse(w.1));
    all.truncate(TOP);
    all.into_iter().map(|(w, _)| String::from(w)).collect()
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
        let k = extract("Zürich Zu\u{308}rich Müller développeur C# C# F# ### +++ A+ a+ e.g. e.g. i.e. u.s. go go ai ai", Format::Text);
        assert_eq!(k, ["c#", "zurich", "developpeur", "f#", "muller"]);
        let style = extract("<style>.a{color:red}</style><SCRIPT>var foo = bar;</script><!-- a > comment --><p>kernel kernel</p>", Format::Html);
        assert_eq!(style, ["kernel"]);
        let lookalike = extract("<styles>kernel kernel</styles> <scripting>gpu</scripting> R&D; salary&bonus; &amp; &#38; &#x26;", Format::Html);
        assert_eq!(lookalike, ["kernel", "bonus", "gpu", "salary"]);
        let html = extract("<div class=\"x\"><a href=\"https://acme.example/jobs\">Kernel</a>&nbsp;kernel&amp;GPU</div>", Format::Html);
        assert_eq!(html, ["kernel", "gpu"]);
        let md = extract("### Kernels\n[apply here](https://acme.example/apply) or see www.acme.example; kernels", Format::Markdown);
        assert_eq!(md, ["kernels", "apply", "see"]);
    }

    #[test]
    fn the_lookup_tables_are_sorted() {
        assert!(STOP.windows(2).all(|w| w[0] < w[1]));
        assert!(ENTITIES.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn ampersands_cost_a_bounded_look_ahead() {
        let t = std::time::Instant::now();
        assert!(extract(&"&".repeat(1 << 20), Format::Html).is_empty());
        assert!(extract(&("&a".repeat(1 << 18) + ";"), Format::Html).is_empty());
        assert!(t.elapsed().as_secs() < 5);
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
