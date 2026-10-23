//! Normalized text and word matching, the one reading of free text the
//! org, score and board rules share.
//!
//! A normalized text is lowercase, Latin letters (only: other scripts keep
//! their marks) folded to their base
//! ("Zürich" and a decomposed "Zu\u{308}rich" both read "zurich"), its
//! words are runs of alphanumerics, and exactly one space sits between
//! words, so `lexicon` matches its needles by bytes with a boundary
//! check, never a regex.

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
    // Below U+00C0 nothing folds and a letter only lowercases: the common
    // case (an all-ASCII listing, or the ASCII between accents) skips the
    // tables and the Unicode case mapping.
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c.to_ascii_lowercase());
            continue;
        }
        let cp = c as u32;
        if (0x300..=0x36F).contains(&cp) {
            continue;
        }
        match latin(cp) {
            Some(b) => out.extend(b.chars().map(|c| c.to_ascii_lowercase())),
            // A capital outside the tables can lowercase into them (Ƕ → ƕ),
            // and a small letter outside them can have its capital inside
            // (ɓ → Ɓ): either way the base letter is the table's.
            None => {
                for l in c.to_lowercase() {
                    let mut up = l.to_uppercase();
                    let capital = match (up.next(), up.next()) {
                        (Some(u), None) => latin(u as u32),
                        _ => None,
                    };
                    match latin(l as u32).or(capital) {
                        Some(b) => out.extend(b.chars().map(|c| c.to_ascii_lowercase())),
                        None => out.push(l),
                    }
                }
            }
        }
    }
    out
}

/// [`fold`], then every run of characters that are not alphanumeric, `+`
/// or `#` turned into one space, trimmed. `+` and `#` are kept as letters
/// so "c++" and "c#" survive.
pub fn normalize(s: &str) -> String {
    // ASCII folds by lowercasing: one pass, no folded copy.
    if s.is_ascii() {
        let mut out = alloc::vec::Vec::with_capacity(s.len());
        let mut gap = false;
        for &b in s.as_bytes() {
            if b.is_ascii_alphanumeric() || b == b'+' || b == b'#' {
                if gap && !out.is_empty() {
                    out.push(b' ');
                }
                gap = false;
                out.push(b.to_ascii_lowercase());
            } else {
                gap = true;
            }
        }
        return String::from_utf8(out).unwrap_or_default();
    }
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

pub fn words(text: &str) -> impl Iterator<Item = &str> {
    text.split(' ').filter(|w| !w.is_empty())
}

/// Most codes a settings list is read for.
pub const MAX_CODES: usize = 64;

/// A list of codes (ISO 3166 or 639), U+001F-joined as stored or written
/// with spaces, commas or semicolons as an agent types them, lowercased,
/// deduped, the first [`MAX_CODES`] kept: read once, then matched by lookup.
pub fn codes(joined: &str) -> alloc::vec::Vec<String> {
    let mut out: alloc::vec::Vec<String> = alloc::vec::Vec::new();
    let split = |s: &'_ str| s.split([',', ';', ' ', '\t']).filter(|c| !c.is_empty()).map(str::to_ascii_lowercase).collect::<alloc::vec::Vec<_>>();
    for c in list(joined).flat_map(split) {
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
        assert_eq!(fold("\u{181}\u{253}\u{23a}\u{2c65}"), "bbaa");
        assert_eq!(normalize("---"), "");
    }

    #[test]
    fn fold_meets_its_specification() {
        // Written out by hand, not derived from the tables: Latin-1's
        // letters fold to their base, lowercased; everything else lowercases.
        let spec = [
            ("ÀÁÂÃÄÅàáâãäå", "aaaaaaaaaaaa"),
            ("ÇçÈÉÊËèéêë", "cceeeeeeee"),
            ("ÌÍÎÏìíîïÑñ", "iiiiiiiinn"),
            ("ÒÓÔÕÖØòóôõöø", "oooooooooooo"),
            ("ÙÚÛÜùúûüÝýÿ", "uuuuuuuuyyy"),
            ("ÆæŒœßÐðÞþ", "aeaeoeoessddthth"),
            ("ŁłŚśŹźŻżĆćŃńĘęĄą", "llsszzzzccnneeaa"),
            ("ŞşŢţĞğİıŠšŽž", "ssttggiisszz"),
            ("Ωμλ ПРИВЕТ 東京", "ωμλ привет 東京"),
            ("ABC xyz 123 !?", "abc xyz 123 !?"),
            ("e\u{301}u\u{308}n\u{303}", "eun"),
        ];
        for (input, want) in spec {
            assert_eq!(fold(input), want, "{input}");
        }
    }

    #[test]
    fn fold_is_piecewise() {
        // Folding a concatenation is the concatenation of the folds, at any
        // split before a non-combining character: no character's fold
        // depends on what is around it, ASCII or not.
        let pieces = ["A", "z", " ", "9", "é", "Ü", "Ƕ", "İ", "ß", "🙂", "Ł", "Ω", "東", "Ǆ"];
        let mut r = 0x2545_F491_4F6C_DD1Du64;
        for _ in 0..20_000 {
            let mut a = alloc::string::String::new();
            let mut b = alloc::string::String::new();
            for k in 0..(r % 10) {
                r ^= r << 13;
                r ^= r >> 7;
                r ^= r << 17;
                let p = pieces[(r % pieces.len() as u64) as usize];
                if k % 2 == 0 { a.push_str(p) } else { b.push_str(p) }
            }
            assert_eq!(fold(&alloc::format!("{a}{b}")), alloc::format!("{}{}", fold(&a), fold(&b)), "{a:?} {b:?}");
        }
    }
}
