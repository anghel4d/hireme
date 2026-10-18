//! A listing's target words, extracted once when `listing_raw` is
//! written, and their coverage by the text a composed CV shows.
//!
//! Extraction reads the raw listing and its format, nothing else. Markup
//! goes first: HTML tags, comments and `<style>`/`<script>` bodies,
//! Markdown link targets, and bare URLs anywhere; an HTML entity, in any
//! format, reads as the character it names. Words are then runs of letters and digits (Unicode,
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
pub const VERSION: u32 = 5;

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

/// The listing's prose: tags, link targets and URLs blanked, entities decoded.
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
        } else if c == '&' && entity(rest).is_some() {
            let n = entity(rest).unwrap_or(1);
            // An entity reads as the character it stands for in every format
            // (HTML and Markdown decode them; a plain listing that carries one
            // is escaped HTML), so "M&uuml;ller" is one word, as "Müller" is;
            // a symbol is a space.
            if let Some(ch) = decoded(&rest[1..n - 1]) {
                out.push(ch);
                prev = ch;
                i += n;
                continue;
            }
            Some(n)
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
        name => ENTITIES.binary_search_by_key(&name, |e| e.0).is_ok(),
    };
    ok.then_some(end + 1)
}

/// The letter or digit an entity's body names (`uuml`, `alpha`, `#252`,
/// `#xFC`), or `None` for a symbol or punctuation, which reads as a space.
fn decoded(body: &str) -> Option<char> {
    let cp = match body.as_bytes() {
        [b'#', b'x' | b'X', hex @ ..] => u32::from_str_radix(core::str::from_utf8(hex).ok()?, 16).ok()?,
        [b'#', dec @ ..] => core::str::from_utf8(dec).ok()?.parse::<u32>().ok()?,
        name => ENTITIES.binary_search_by_key(&name, |e| e.0).ok().map(|k| ENTITIES[k].1)?,
    };
    char::from_u32(cp).filter(|c| c.is_alphanumeric() || *c == '\'')
}

/// The HTML 4 named entities and `&apos;`, with the code point each names
/// (sorted by name, for a binary search); anything else between '&' and ';'
/// is prose ("salary&bonus;").
const ENTITIES: &[(&[u8], u32)] = &[
    (b"AElig", 198), (b"Aacute", 193), (b"Acirc", 194), (b"Agrave", 192), (b"Alpha", 913), (b"Aring", 197),
    (b"Atilde", 195), (b"Auml", 196), (b"Beta", 914), (b"Ccedil", 199), (b"Chi", 935), (b"Dagger", 8225),
    (b"Delta", 916), (b"ETH", 208), (b"Eacute", 201), (b"Ecirc", 202), (b"Egrave", 200), (b"Epsilon", 917),
    (b"Eta", 919), (b"Euml", 203), (b"Gamma", 915), (b"Iacute", 205), (b"Icirc", 206), (b"Igrave", 204),
    (b"Iota", 921), (b"Iuml", 207), (b"Kappa", 922), (b"Lambda", 923), (b"Mu", 924), (b"Ntilde", 209), (b"Nu", 925),
    (b"OElig", 338), (b"Oacute", 211), (b"Ocirc", 212), (b"Ograve", 210), (b"Omega", 937), (b"Omicron", 927),
    (b"Oslash", 216), (b"Otilde", 213), (b"Ouml", 214), (b"Phi", 934), (b"Pi", 928), (b"Prime", 8243), (b"Psi", 936),
    (b"Rho", 929), (b"Scaron", 352), (b"Sigma", 931), (b"THORN", 222), (b"Tau", 932), (b"Theta", 920),
    (b"Uacute", 218), (b"Ucirc", 219), (b"Ugrave", 217), (b"Upsilon", 933), (b"Uuml", 220), (b"Xi", 926),
    (b"Yacute", 221), (b"Yuml", 376), (b"Zeta", 918), (b"aacute", 225), (b"acirc", 226), (b"acute", 180),
    (b"aelig", 230), (b"agrave", 224), (b"alefsym", 8501), (b"alpha", 945), (b"amp", 38), (b"and", 8743),
    (b"ang", 8736), (b"apos", 39), (b"aring", 229), (b"asymp", 8776), (b"atilde", 227), (b"auml", 228),
    (b"bdquo", 8222), (b"beta", 946), (b"brvbar", 166), (b"bull", 8226), (b"cap", 8745), (b"ccedil", 231),
    (b"cedil", 184), (b"cent", 162), (b"chi", 967), (b"circ", 710), (b"clubs", 9827), (b"cong", 8773),
    (b"copy", 169), (b"crarr", 8629), (b"cup", 8746), (b"curren", 164), (b"dArr", 8659), (b"dagger", 8224),
    (b"darr", 8595), (b"deg", 176), (b"delta", 948), (b"diams", 9830), (b"divide", 247), (b"eacute", 233),
    (b"ecirc", 234), (b"egrave", 232), (b"empty", 8709), (b"emsp", 8195), (b"ensp", 8194), (b"epsilon", 949),
    (b"equiv", 8801), (b"eta", 951), (b"eth", 240), (b"euml", 235), (b"euro", 8364), (b"exist", 8707),
    (b"fnof", 402), (b"forall", 8704), (b"frac12", 189), (b"frac14", 188), (b"frac34", 190), (b"frasl", 8260),
    (b"gamma", 947), (b"ge", 8805), (b"gt", 62), (b"hArr", 8660), (b"harr", 8596), (b"hearts", 9829),
    (b"hellip", 8230), (b"iacute", 237), (b"icirc", 238), (b"iexcl", 161), (b"igrave", 236), (b"image", 8465),
    (b"infin", 8734), (b"int", 8747), (b"iota", 953), (b"iquest", 191), (b"isin", 8712), (b"iuml", 239),
    (b"kappa", 954), (b"lArr", 8656), (b"lambda", 955), (b"lang", 9001), (b"laquo", 171), (b"larr", 8592),
    (b"lceil", 8968), (b"ldquo", 8220), (b"le", 8804), (b"lfloor", 8970), (b"lowast", 8727), (b"loz", 9674),
    (b"lrm", 8206), (b"lsaquo", 8249), (b"lsquo", 8216), (b"lt", 60), (b"macr", 175), (b"mdash", 8212),
    (b"micro", 181), (b"middot", 183), (b"minus", 8722), (b"mu", 956), (b"nabla", 8711), (b"nbsp", 160),
    (b"ndash", 8211), (b"ne", 8800), (b"ni", 8715), (b"not", 172), (b"notin", 8713), (b"nsub", 8836),
    (b"ntilde", 241), (b"nu", 957), (b"oacute", 243), (b"ocirc", 244), (b"oelig", 339), (b"ograve", 242),
    (b"oline", 8254), (b"omega", 969), (b"omicron", 959), (b"oplus", 8853), (b"or", 8744), (b"ordf", 170),
    (b"ordm", 186), (b"oslash", 248), (b"otilde", 245), (b"otimes", 8855), (b"ouml", 246), (b"para", 182),
    (b"part", 8706), (b"permil", 8240), (b"perp", 8869), (b"phi", 966), (b"pi", 960), (b"piv", 982),
    (b"plusmn", 177), (b"pound", 163), (b"prime", 8242), (b"prod", 8719), (b"prop", 8733), (b"psi", 968),
    (b"quot", 34), (b"rArr", 8658), (b"radic", 8730), (b"rang", 9002), (b"raquo", 187), (b"rarr", 8594),
    (b"rceil", 8969), (b"rdquo", 8221), (b"real", 8476), (b"reg", 174), (b"rfloor", 8971), (b"rho", 961),
    (b"rlm", 8207), (b"rsaquo", 8250), (b"rsquo", 8217), (b"sbquo", 8218), (b"scaron", 353), (b"sdot", 8901),
    (b"sect", 167), (b"shy", 173), (b"sigma", 963), (b"sigmaf", 962), (b"sim", 8764), (b"spades", 9824),
    (b"sub", 8834), (b"sube", 8838), (b"sum", 8721), (b"sup", 8835), (b"sup1", 185), (b"sup2", 178), (b"sup3", 179),
    (b"supe", 8839), (b"szlig", 223), (b"tau", 964), (b"there4", 8756), (b"theta", 952), (b"thetasym", 977),
    (b"thinsp", 8201), (b"thorn", 254), (b"tilde", 732), (b"times", 215), (b"trade", 8482), (b"uArr", 8657),
    (b"uacute", 250), (b"uarr", 8593), (b"ucirc", 251), (b"ugrave", 249), (b"uml", 168), (b"upsih", 978),
    (b"upsilon", 965), (b"uuml", 252), (b"weierp", 8472), (b"xi", 958), (b"yacute", 253), (b"yen", 165),
    (b"yuml", 255), (b"zeta", 950), (b"zwj", 8205), (b"zwnj", 8204),
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
    let plain = format == Format::Text && !listing.contains("http") && !listing.contains("www.") && !listing.contains('&');
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
        (self.hits() * 100).checked_div(self.terms.len()).unwrap_or(0) as u8
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
    fn extracts_by_count_then_bytes_and_keeps_the_top() {
        let listing = "We build Rust systems. Rust, C++ and Node.js; rust again! GPU kernels for the GPU team. \
                       2026 and 3.14 are numbers. The the the.";
        let k = extract(listing, Format::Text);
        assert_eq!(&k[..2], ["rust", "gpu"]);
        for w in ["c++", "node.js", "systems"] {
            assert!(k.contains(&String::from(w)), "{w}");
        }
        assert!(!k.iter().any(|w| w == "the" || w == "2026" || w == "3.14" || w.ends_with('.')));
        assert!(k[2..].windows(2).all(|w| w[0] < w[1]), "ties by bytes: {k:?}");
        let many: String = (0..40).map(|i| alloc::format!("word{i:02} ")).collect();
        let k = extract(&many, Format::Text);
        assert_eq!((k.len(), k[0].as_str(), join(&k[..2]).as_str()), (TOP, "word00", "word00\u{1f}word01"));
        assert!(extract("", Format::Text).is_empty());
    }

    #[test]
    fn letters_markup_and_abbreviations() {
        // The binary searches below need their tables sorted.
        assert!(STOP.windows(2).all(|w| w[0] < w[1]));
        assert!(ENTITIES.windows(2).all(|w| w[0].0 < w[1].0));
        let k = extract("Zürich Zu\u{308}rich Müller développeur C# C# F# ### +++ A+ a+ e.g. e.g. i.e. u.s. go go ai ai", Format::Text);
        assert_eq!(k, ["c#", "zurich", "developpeur", "f#", "muller"]);
        let style = extract("<style>.a{color:red}</style><SCRIPT>var foo = bar;</script><!-- a > comment --><p>kernel kernel</p>", Format::Html);
        assert_eq!(style, ["kernel"]);
        let lookalike = extract("<styles>kernel kernel</styles> <scripting>gpu</scripting> R&D; salary&bonus; &amp; &#38; &#x26;", Format::Html);
        assert_eq!(lookalike, ["kernel", "bonus", "gpu", "salary"]);
        let html = extract("<div class=\"x\"><a href=\"https://acme.example/jobs\">Kernel</a>&nbsp;kernel&amp;GPU</div>", Format::Html);
        assert_eq!(html, ["kernel", "gpu"]);
        // An entity is the character it names: one word, folded like the
        // letter itself; an apostrophe splits as it does in plain text.
        // Every named entity reads as its own character: a letter or digit
        // joins the word around it, anything else splits it.
        for &(name, cp) in ENTITIES {
            let c = char::from_u32(cp).unwrap();
            let name = core::str::from_utf8(name).unwrap();
            let word = alloc::format!("zz&{name};zz");
            let joined = c.is_alphanumeric();
            assert_eq!(decoded(name), (joined || c == '\'').then_some(c), "{name}");
            let k = extract(&word, Format::Html);
            assert_eq!(k.len() == 1 && k[0].starts_with("zz") && k[0].len() > 4, joined, "{name}: {k:?}");
        }
        for format in [Format::Markdown, Format::Text] {
            assert_eq!(extract("M&uuml;ller M&uuml;ller &amp; R&D; &eacute;quipe", format), ["muller", "equipe"]);
        }
        let named = extract("M&uuml;ller M&#252;ller M&#xFC;ller d&eacute;veloppeur &#x6B;ernel don&apos;t &apos;quoted&apos;", Format::Html);
        assert_eq!(named, ["muller", "developpeur", "don", "kernel", "quoted"]);
        let md = extract("### Kernels\n[apply here](https://acme.example/apply) or see www.acme.example; kernels", Format::Markdown);
        assert_eq!(md, ["kernels", "apply", "see"]);
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
