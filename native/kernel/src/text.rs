//! Normalized text and word matching, the one reading of free text the
//! org, score and board rules share.
//!
//! A normalized text is lowercase, Latin letters folded to their base
//! ("Zürich" and a decomposed "Zu\u{308}rich" both read "zurich"), its
//! words are runs of alphanumerics, and exactly one space sits between
//! words. Every matcher below takes an already normalized text
//! and an ASCII needle in the same form, so a match is a byte search with
//! a boundary check, never a regex.

use alloc::string::String;

/// Latin-1 Supplement and Latin Extended-A (U+00C0..U+017F) to their
/// base letters; "" for the two symbols in the range.
const LATIN: [&str; 192] = [
    "A", "A", "A", "A", "A", "A", "AE", "C", "E", "E", "E", "E", "I", "I", "I", "I",
    "D", "N", "O", "O", "O", "O", "O", "", "O", "U", "U", "U", "U", "Y", "TH", "ss",
    "a", "a", "a", "a", "a", "a", "ae", "c", "e", "e", "e", "e", "i", "i", "i", "i",
    "d", "n", "o", "o", "o", "o", "o", "", "o", "u", "u", "u", "u", "y", "th", "y",
    "A", "a", "A", "a", "A", "a", "C", "c", "C", "c", "C", "c", "C", "c", "D", "d",
    "D", "d", "E", "e", "E", "e", "E", "e", "E", "e", "E", "e", "G", "g", "G", "g",
    "G", "g", "G", "g", "H", "h", "H", "h", "I", "i", "I", "i", "I", "i", "I", "i",
    "I", "i", "IJ", "ij", "J", "j", "K", "k", "k", "L", "l", "L", "l", "L", "l", "L",
    "l", "L", "l", "N", "n", "N", "n", "N", "n", "n", "N", "n", "O", "o", "O", "o",
    "O", "o", "OE", "oe", "R", "r", "R", "r", "R", "r", "S", "s", "S", "s", "S", "s",
    "S", "s", "T", "t", "T", "t", "T", "t", "U", "u", "U", "u", "U", "u", "U", "u",
    "U", "u", "U", "u", "W", "w", "Y", "y", "Y", "Z", "z", "Z", "z", "Z", "z", "s",
];

/// Lowercase with Latin letters folded to their base and combining marks
/// (a decomposed accent, the dot of "İ") dropped; everything else kept.
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let cp = c as u32;
        if (0x300..=0x36F).contains(&cp) {
            continue;
        }
        match (0xC0..0x180).contains(&cp).then(|| LATIN[(cp - 0xC0) as usize]) {
            Some(b) if !b.is_empty() => out.extend(b.chars().map(|c| c.to_ascii_lowercase())),
            _ => out.extend(c.to_lowercase()),
        }
    }
    out
}

/// [`fold`], then every run of characters that are not alphanumeric, `+`
/// or `#` turned into one space, trimmed. `+` and `#` are kept as letters
/// so "c++" and "c#" survive.
pub fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut gap = false;
    for c in fold(s).chars() {
        if c.is_alphanumeric() || c == '+' || c == '#' {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            gap = false;
            out.push(c);
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

pub fn word(text: &str, needle: &str) -> bool {
    find(text, needle, true)
}

/// `needle` (one word or a phrase) at a word start; its end may run into a word,
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

pub fn any_word(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| word(text, n))
}

pub fn any_start(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| starts(text, n))
}

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
        assert_eq!(normalize("  Senior C++/Rust  Engineer, Zürich! "), "senior c++ rust engineer zurich");
        assert_eq!(normalize("Zu\u{308}rich"), "zurich");
        assert_eq!(normalize("Æsir × Łódź"), "aesir lodz");
        assert_eq!(normalize(&normalize("İstanbul")), normalize("İstanbul"));
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
