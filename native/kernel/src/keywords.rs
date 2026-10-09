//! Hireme.Keywords: a listing's target words and their coverage by the
//! text a CV shows, byte for byte as the Elixir module reads them.

use alloc::string::String;
use alloc::vec::Vec;

use crate::heat::downcase;

const STOP: &[&str] = &[
    "about", "after", "also", "and", "any", "are", "because", "been", "being", "both", "from",
    "have", "here", "into", "just", "more", "most", "only", "onto", "our", "over", "role", "such",
    "team", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those",
    "very", "what", "when", "where", "which", "will", "with", "work", "would", "your", "you",
    "our", "for", "the", "and",
];

/// Keywords.extract/1: the ten most frequent words of four or more
/// characters that are not stop words, by count then bytes. Words are
/// runs of a-z 0-9 + # . in the downcased text.
pub fn extract(listing: &str) -> Vec<String> {
    let text = downcase(listing);
    let b = text.as_bytes();
    let word =
        |c: u8| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'+' | b'#' | b'.');
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut from = 0;
    for (i, &c) in b.iter().enumerate() {
        if !word(c) {
            runs.push((from, i));
            from = i + 1;
        }
    }
    runs.push((from, b.len()));
    let mut counts: Vec<(&str, u32)> = Vec::new();
    for (from, to) in runs {
        // Runs are ASCII (so String.length is the byte length), but an
        // empty one may sit inside a multibyte character: read bytes.
        let Ok(w) = core::str::from_utf8(&b[from..to]) else {
            continue;
        };
        if w.len() < 4 || STOP.contains(&w) {
            continue;
        }
        match counts.iter_mut().find(|(k, _)| *k == w) {
            Some(c) => c.1 += 1,
            None => counts.push((w, 1)),
        }
    }
    counts.sort_unstable_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| a.0.as_bytes().cmp(b.0.as_bytes()))
    });
    counts
        .into_iter()
        .take(10)
        .map(|(w, _)| String::from(w))
        .collect()
}

fn alnum(c: u8) -> bool {
    c.is_ascii_lowercase() || c.is_ascii_digit()
}

/// Keywords.hit?/2 over an already downcased text.
pub fn hit(text: &str, term: &str) -> bool {
    if term.is_empty() {
        // (^|[^a-z0-9])([^a-z0-9]|$), over codepoints.
        let cs: Vec<char> = text.chars().collect();
        let non = |c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit());
        if cs.is_empty() || non(cs[0]) {
            return true;
        }
        return (0..cs.len()).any(|i| non(cs[i]) && (i + 1 == cs.len() || non(cs[i + 1])));
    }
    let term = downcase(term);
    let t = text.as_bytes();
    let n = term.as_bytes();
    let mut start = 0;
    while let Some(p) = text[start..].find(term.as_str()).map(|p| p + start) {
        let left = p == 0 || !alnum(t[p - 1]);
        let end = p + n.len();
        let right = end == t.len() || !alnum(t[end]);
        if left && right {
            return true;
        }
        // An occurrence can overlap the next valid one.
        start = p + text[p..].chars().next().map_or(1, char::len_utf8);
        if start > text.len() {
            break;
        }
    }
    false
}

/// Theme.parse/1's targets over a U+001F-joined list: trimmed, blanks out.
pub fn theme_targets(joined: &str) -> Vec<String> {
    if joined.is_empty() {
        return Vec::new();
    }
    joined
        .split('\u{1f}')
        .map(str::trim)
        .filter(|w| !w.is_empty())
        .map(String::from)
        .collect()
}
