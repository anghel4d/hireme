//! Normalized text and word matching, the one reading of free text the
//! org, score and board rules share.
//!
//! A normalized text is lowercase, its words are runs of alphanumerics
//! (Unicode, so "Montréal" stays one word), and exactly one space sits
//! between words. Every matcher below takes an already normalized text
//! and an ASCII needle in the same form, so a match is a byte search with
//! a boundary check, never a regex.

use alloc::string::String;

/// Lowercase, every non-alphanumeric run folded to one space, trimmed.
/// `+` and `#` are kept as letters so "c++" and "c#" survive.
pub fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut gap = false;
    for c in s.chars() {
        if c.is_alphanumeric() || c == '+' || c == '#' {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            gap = false;
            for l in c.to_lowercase() {
                out.push(l);
            }
        } else {
            gap = true;
        }
    }
    out
}

fn boundary_before(t: &[u8], at: usize) -> bool {
    at == 0 || t[at - 1] == b' '
}

fn boundary_after(t: &[u8], end: usize) -> bool {
    end == t.len() || t[end] == b' '
}

/// `needle` (one word or a phrase of words) occurs as whole words.
pub fn word(text: &str, needle: &str) -> bool {
    find(text, needle, true)
}

/// `needle` occurs starting at a word start; its end may run into a word,
/// so "infra" finds "infrastructure".
pub fn starts(text: &str, needle: &str) -> bool {
    find(text, needle, false)
}

fn find(text: &str, needle: &str, whole: bool) -> bool {
    let (t, n) = (text.as_bytes(), needle.as_bytes());
    if n.is_empty() || n.len() > t.len() {
        return false;
    }
    let mut from = 0;
    while let Some(p) = memfind(&t[from..], n) {
        let at = from + p;
        if boundary_before(t, at) && (!whole || boundary_after(t, at + n.len())) {
            return true;
        }
        from = at + 1;
    }
    false
}

fn memfind(h: &[u8], n: &[u8]) -> Option<usize> {
    let first = n[0];
    let last = h.len().checked_sub(n.len())?;
    (0..=last).find(|&i| h[i] == first && &h[i..i + n.len()] == n)
}

/// Any of `needles` as whole words.
pub fn any_word(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| word(text, n))
}

/// Any of `needles` from a word start.
pub fn any_start(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| starts(text, n))
}

/// The words of a normalized text.
pub fn words(text: &str) -> impl Iterator<Item = &str> {
    text.split(' ').filter(|w| !w.is_empty())
}

/// A U+001F-joined list (the schema's list encoding in a `str` column),
/// trimmed, blanks dropped.
pub fn list(joined: &str) -> impl Iterator<Item = &str> {
    joined.split('\u{1f}').map(str::trim).filter(|w| !w.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_folds_punctuation_and_case() {
        assert_eq!(normalize("  Senior C++/Rust  Engineer, Montréal! "), "senior c++ rust engineer montréal");
        assert_eq!(normalize("---"), "");
    }

    #[test]
    fn word_needs_both_boundaries_and_starts_one() {
        let t = normalize("Infrastructure engineer at Meta FAIR");
        assert!(word(&t, "meta fair"));
        assert!(!word(&t, "infra"));
        assert!(starts(&t, "infra"));
        assert!(!starts(&t, "structure"));
        assert!(!word(&t, "fai"));
    }
}
