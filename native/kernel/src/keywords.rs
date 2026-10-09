//! Hireme.Keywords: a listing's target words and their coverage by the
//! text a CV shows, byte for byte as the Elixir module reads them.

use alloc::string::String;
use alloc::vec::Vec;

use alloc::vec;

use crate::heat::downcase;

const STOP: &[&str] = &[
    "about", "after", "also", "and", "any", "are", "because", "been", "being", "both", "from",
    "have", "here", "into", "just", "more", "most", "only", "onto", "our", "over", "role", "such",
    "team", "that", "the", "their", "them", "then", "there", "these", "they", "this", "those",
    "very", "what", "when", "where", "which", "will", "with", "work", "would", "your", "you",
    "our", "for", "the", "and",
];

/// The stop words' hashes, so a word is only compared with them on a match.
const STOP_HASH: [u32; STOP.len()] = {
    let mut h = [0u32; STOP.len()];
    let mut i = 0;
    while i < STOP.len() {
        let b = STOP[i].as_bytes();
        let mut x = 0x811c_9dc5u32;
        let mut j = 0;
        while j < b.len() {
            x = (x ^ b[j] as u32).wrapping_mul(0x0100_0193);
            j += 1;
        }
        h[i] = x;
        i += 1;
    }
    h
};

/// A byte as a word byte of the downcased text (a-z 0-9 + # .), A-Z
/// folded down; 0 for every byte that ends a word.
const WORD: [u8; 256] = {
    let mut t = [0u8; 256];
    let mut c = 0;
    while c < 128 {
        let l = (c as u8).to_ascii_lowercase();
        if l.is_ascii_lowercase() || l.is_ascii_digit() || l == b'+' || l == b'#' || l == b'.' {
            t[c] = l;
        }
        c += 1;
    }
    t
};

/// Keywords.extract/1: the ten most frequent words of four or more
/// characters that are not stop words, by count then bytes. Words are
/// runs of a-z 0-9 + # . in the downcased text. One pass maps the bytes
/// through `WORD`, a second hashes and counts each word as it ends; stop
/// words are dropped from the counted words, not checked per occurrence.
pub fn extract(listing: &str) -> Vec<String> {
    Scratch::new().extract(listing)
}

/// What `extract` works in, kept between calls so a pass over many
/// listings allocates and clears nothing per listing.
pub struct Scratch {
    /// The listing's bytes through `WORD`.
    text: Vec<u8>,
    /// Open addressing: slot → 1 + its word's index in `words`, 0 empty.
    /// Kept all zero between calls.
    slots: Vec<u32>,
    /// Each distinct word of four or more bytes: hash, start, len, count,
    /// and its slot.
    words: Vec<[u32; 5]>,
}

impl Scratch {
    pub const fn new() -> Scratch {
        Scratch {
            text: Vec::new(),
            slots: Vec::new(),
            words: Vec::new(),
        }
    }

    pub fn extract(&mut self, listing: &str) -> Vec<String> {
        let src = listing.as_bytes();
        let text = &mut self.text;
        text.clear();
        if src.is_ascii() {
            text.extend(src.iter().map(|&c| WORD[c as usize]));
        } else {
            // Only two characters lowercase to bytes that hold a word byte:
            // U+0130 is "i" and a combining dot, U+212A KELVIN SIGN is "k".
            // Every other non-ASCII byte ends a word.
            let mut i = 0;
            while i < src.len() {
                let (c, n) = match src[i] {
                    c if c < 0x80 => (WORD[c as usize], 1),
                    _ if src[i..].starts_with("\u{130}".as_bytes()) => (b'i', 2),
                    _ if src[i..].starts_with("\u{212A}".as_bytes()) => (b'k', 3),
                    _ => (0, 1),
                };
                text.push(c);
                if n == 2 {
                    text.push(0); // the combining dot ends the word
                }
                i += n;
            }
        }
        // A text of n bytes holds at most n / 5 words of four or more
        // bytes, so a table of twice that never fills past half.
        let need = (text.len() / 5 * 2 + 16).next_power_of_two();
        if self.slots.len() < need {
            self.slots.resize(need, 0);
        }
        let mask = need - 1;
        let (slots, words) = (&mut self.slots, &mut self.words);
        words.clear();
        let (mut h, mut start) = (0x811c_9dc5u32, 0);
        for i in 0..=text.len() {
            let c = text.get(i).copied().unwrap_or(0);
            if c != 0 {
                h = (h ^ c as u32).wrapping_mul(0x0100_0193);
                continue;
            }
            let len = i - start;
            if len >= 4 {
                let mut k = h as usize & mask;
                loop {
                    let Some(e) = slots[k].checked_sub(1).map(|w| &mut words[w as usize]) else {
                        slots[k] = words.len() as u32 + 1;
                        words.push([h, start as u32, len as u32, 1, k as u32]);
                        break;
                    };
                    if e[0] == h && e[2] as usize == len && text[e[1] as usize..][..len] == text[start..i] {
                        e[3] += 1;
                        break;
                    }
                    k = (k + 1) & mask;
                }
            }
            (h, start) = (0x811c_9dc5, i + 1);
        }
        for e in words.iter() {
            slots[e[4] as usize] = 0;
        }
        let word = |e: &[u32; 5]| &text[e[1] as usize..(e[1] + e[2]) as usize];
        let stop = |e: &[u32; 5]| e[2] <= 7 && STOP_HASH.contains(&e[0]) && STOP.iter().any(|s| s.as_bytes() == word(e));
        // The ten first by count then bytes: the tenth count bounds them,
        // every word above it is in, and the words at it fill the rest by
        // bytes.
        let mut top = [0u32; 10];
        for e in words.iter() {
            if e[3] <= top[9] || stop(e) {
                continue;
            }
            let at = top.iter().position(|&t| e[3] > t).unwrap_or(9);
            top.copy_within(at..9, at + 1);
            top[at] = e[3];
        }
        let floor = top[9];
        let mut out: Vec<&[u32; 5]> = words.iter().filter(|e| e[3] > floor && !stop(e)).collect();
        let mut tied: Vec<&[u8]> = Vec::new();
        for e in words.iter().filter(|e| e[3] == floor && floor > 0) {
            let w = word(e);
            if (tied.len() + out.len() < 10 || tied.last().is_some_and(|l| w < *l)) && !stop(e) {
                let at = tied.partition_point(|t| *t < w);
                tied.insert(at, w);
                tied.truncate(10 - out.len());
            }
        }
        out.sort_unstable_by(|a, b| b[3].cmp(&a[3]).then_with(|| word(a).cmp(word(b))));
        out.iter()
            .map(|e| word(e))
            .chain(tied)
            .filter_map(|w| core::str::from_utf8(w).ok())
            .map(String::from)
            .collect()
    }
}

fn fnv(b: &[u8]) -> usize {
    let mut h: u32 = 0x811c9dc5;
    for &c in b {
        h = (h ^ c as u32).wrapping_mul(0x0100_0193);
    }
    h as usize
}

/// A CV's visible text, downcased, with a hash set of its maximal a-z0-9
/// runs, so a target made only of a-z0-9 hits by one lookup (a whole-term
/// match is exactly a run equal to the term) and only other targets scan.
pub struct Text {
    pub text: String,
    /// Open addressing over (start, end) of distinct runs; end 0 is empty.
    runs: Vec<(u32, u32)>,
}

impl Text {
    pub fn new(text: String) -> Text {
        let b = text.as_bytes();
        let n = b.iter().filter(|c| !alnum(**c)).count() + 1;
        let mut runs = vec![(0u32, 0u32); (2 * n).next_power_of_two().max(16)];
        let mask = runs.len() - 1;
        let mut put = |from: usize, to: usize| {
            if to == from {
                return;
            }
            let w = &b[from..to];
            let mut k = fnv(w) & mask;
            loop {
                let e = runs[k];
                if e.1 == 0 {
                    runs[k] = (from as u32, to as u32);
                    return;
                }
                if &b[e.0 as usize..e.1 as usize] == w {
                    return;
                }
                k = (k + 1) & mask;
            }
        };
        let mut from = 0;
        for (i, &c) in b.iter().enumerate() {
            if !alnum(c) {
                put(from, i);
                from = i + 1;
            }
        }
        put(from, b.len());
        Text { text, runs }
    }

    pub fn hit(&self, term: &str) -> bool {
        let t = term.as_bytes();
        if t.is_empty() || !t.iter().all(|&c| alnum(c)) {
            return hit(&self.text, term);
        }
        let b = self.text.as_bytes();
        let mask = self.runs.len() - 1;
        let mut k = fnv(t) & mask;
        loop {
            let e = self.runs[k];
            if e.1 == 0 {
                return false;
            }
            if &b[e.0 as usize..e.1 as usize] == t {
                return true;
            }
            k = (k + 1) & mask;
        }
    }
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
