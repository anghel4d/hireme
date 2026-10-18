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

/// Latin letters to their base letters: Latin-1 Supplement through
/// Latin Extended-B (U+00C0..U+024F) and Latin Extended Additional
/// (U+1E00..U+1EFF), generated from Unicode's decompositions; "" for a
/// symbol or a letter with no ASCII base.
const LATIN_1: [&str; 400] = [
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
    "b", "B", "B", "b", "", "", "", "C", "c", "", "D", "D", "d", "", "", "",
    "", "F", "f", "G", "", "hv", "", "I", "K", "k", "l", "", "", "N", "n", "O",
    "O", "o", "OI", "oi", "P", "p", "", "", "", "", "", "t", "T", "t", "T", "U",
    "u", "", "V", "Y", "y", "Z", "z", "", "", "", "", "", "", "", "", "",
    "", "", "", "", "DZ", "Dz", "dz", "LJ", "Lj", "lj", "NJ", "Nj", "nj", "A", "a", "I",
    "i", "O", "o", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u", "", "A", "a",
    "A", "a", "AE", "ae", "G", "g", "G", "g", "K", "k", "O", "o", "O", "o", "", "",
    "j", "DZ", "Dz", "dz", "G", "g", "", "", "N", "n", "A", "a", "AE", "ae", "O", "o",
    "A", "a", "A", "a", "E", "e", "E", "e", "I", "i", "I", "i", "O", "o", "O", "o",
    "R", "r", "R", "r", "U", "u", "U", "u", "S", "s", "T", "t", "", "", "H", "h",
    "N", "d", "OU", "ou", "Z", "z", "A", "a", "E", "e", "O", "o", "O", "o", "O", "o",
    "O", "o", "Y", "y", "l", "n", "t", "", "", "", "A", "C", "c", "L", "T", "s",
    "z", "", "", "B", "", "", "E", "e", "J", "j", "", "q", "R", "r", "Y", "y",
];
const LATIN_ADDITIONAL: [&str; 256] = [
    "A", "a", "B", "b", "B", "b", "B", "b", "C", "c", "D", "d", "D", "d", "D", "d",
    "D", "d", "D", "d", "E", "e", "E", "e", "E", "e", "E", "e", "E", "e", "F", "f",
    "G", "g", "H", "h", "H", "h", "H", "h", "H", "h", "H", "h", "I", "i", "I", "i",
    "K", "k", "K", "k", "K", "k", "L", "l", "L", "l", "L", "l", "L", "l", "M", "m",
    "M", "m", "M", "m", "N", "n", "N", "n", "N", "n", "N", "n", "O", "o", "O", "o",
    "O", "o", "O", "o", "P", "p", "P", "p", "R", "r", "R", "r", "R", "r", "R", "r",
    "S", "s", "S", "s", "S", "s", "S", "s", "S", "s", "T", "t", "T", "t", "T", "t",
    "T", "t", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u", "V", "v", "V", "v",
    "W", "w", "W", "w", "W", "w", "W", "w", "W", "w", "X", "x", "X", "x", "Y", "y",
    "Z", "z", "Z", "z", "Z", "z", "h", "t", "w", "y", "a", "s", "", "", "SS", "",
    "A", "a", "A", "a", "A", "a", "A", "a", "A", "a", "A", "a", "A", "a", "A", "a",
    "A", "a", "A", "a", "A", "a", "A", "a", "E", "e", "E", "e", "E", "e", "E", "e",
    "E", "e", "E", "e", "E", "e", "E", "e", "I", "i", "I", "i", "O", "o", "O", "o",
    "O", "o", "O", "o", "O", "o", "O", "o", "O", "o", "O", "o", "O", "o", "O", "o",
    "O", "o", "O", "o", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u", "U", "u",
    "U", "u", "Y", "y", "Y", "y", "Y", "y", "Y", "y", "", "", "", "", "Y", "y",
];

fn latin(cp: u32) -> Option<&'static str> {
    let b = match cp {
        0xC0..0x250 => LATIN_1[(cp - 0xC0) as usize],
        0x1E00..0x1F00 => LATIN_ADDITIONAL[(cp - 0x1E00) as usize],
        _ => return None,
    };
    (!b.is_empty()).then_some(b)
}

/// Lowercase with Latin letters folded to their base and combining marks
/// (a decomposed accent, the dot of "İ") dropped; everything else kept.
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let cp = c as u32;
        if (0x300..=0x36F).contains(&cp) {
            continue;
        }
        match latin(cp) {
            Some(b) => out.extend(b.chars().map(|c| c.to_ascii_lowercase())),
            None => out.extend(c.to_lowercase()),
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

/// Most codes a settings list is read for.
pub const MAX_CODES: usize = 64;

/// A U+001F-joined list of codes (ISO 3166 or 639), lowercased, deduped,
/// the first [`MAX_CODES`] kept: read once, then matched by lookup.
pub fn codes(joined: &str) -> alloc::vec::Vec<String> {
    let mut out: alloc::vec::Vec<String> = alloc::vec::Vec::new();
    for c in list(joined).map(str::to_ascii_lowercase) {
        if out.len() == MAX_CODES {
            break;
        }
        if !out.contains(&c) {
            out.push(c);
        }
    }
    out
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
        assert_eq!(normalize("Timi\u{219}oara"), normalize("Timis\u{326}oara"));
        assert_eq!(normalize("Hà Nội"), "ha noi");
        assert_eq!(normalize("Ha\u{300} No\u{323}\u{302}i"), "ha noi");
        assert_eq!(normalize("\u{1e9e}"), normalize(&normalize("\u{1e9e}")));
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
