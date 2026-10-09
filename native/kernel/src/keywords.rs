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

/// The stop words as a word's first chunk (each is under eight bytes),
/// and a 64-bit filter over them so most words skip the list.
const STOP_CHUNK: [u64; STOP.len()] = {
    let mut h = [0u64; STOP.len()];
    let mut i = 0;
    while i < STOP.len() {
        let b = STOP[i].as_bytes();
        let mut j = 0;
        while j < b.len() {
            h[i] |= (b[j] as u64) << (8 * j);
            j += 1;
        }
        i += 1;
    }
    h
};
const STOP_BLOOM: u64 = {
    let mut m = 0u64;
    let mut i = 0;
    while i < STOP.len() {
        m |= 1 << (STOP_CHUNK[i] % 64);
        i += 1;
    }
    m
};

const K: u64 = 0x9E37_79B9_7F4A_7C15;

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
    /// Each distinct word of four or more bytes.
    words: Vec<Word>,
}

/// A distinct word: its first sixteen bytes as two little-endian chunks
/// (zero past its end), which decide equality and order for any word of
/// sixteen bytes or fewer without touching the text.
struct Word {
    c: [u64; 2],
    start: u32,
    len: u32,
    count: u32,
    slot: u32,
}

impl Word {
    /// Byte order: the chunks as big-endian numbers, then the bytes.
    fn cmp(&self, o: &Word, text: &[u8]) -> core::cmp::Ordering {
        let key = |w: &Word| (w.c[0].swap_bytes(), w.c[1].swap_bytes());
        key(self).cmp(&key(o)).then_with(|| {
            let b = |w: &Word| &text[w.start as usize..(w.start + w.len) as usize];
            if self.len > 16 || o.len > 16 { b(self).cmp(b(o)) } else { core::cmp::Ordering::Equal }
        })
    }
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
        // The text's length; zeros pad it to whole blocks and one more.
        let end;
        // KELVIN SIGN lowercases to one byte from three; any other listing
        // maps byte for byte (U+0130 to "i" and a byte that ends the word).
        let ascii = src.is_ascii();
        // Where a byte pair or triple starts, by its first byte (rare, so
        // found by that byte, not compared at every position).
        let at = |lead: u8, rest: &'static [u8]| {
            src.iter().enumerate().filter(move |&(i, &c)| c == lead && src[i + 1..].starts_with(rest)).map(|(i, _)| i)
        };
        if ascii || at(0xE2, &[0x84, 0xAA]).next().is_none() {
            text.resize(src.len().next_multiple_of(16) + 16, 0);
            for (o, c) in text.chunks_exact_mut(16).zip(src.chunks(16)) {
                let mut b = [0u8; 16];
                b[..c.len()].copy_from_slice(c);
                o.copy_from_slice(&simd::words(b));
            }
            end = src.len();
            if !ascii {
                for i in at(0xC4, &[0xB0]) {
                    text[i] = b'i';
                }
            }
        } else {
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
            end = text.len();
            text.resize(end.next_multiple_of(16) + 16, 0);
        }
        // The words are the runs between zero bytes; the text ends in at
        // least sixteen zeros, so a word's chunks read past it into them.
        // A text of n bytes holds at most n / 5 words of four or more
        // bytes, so a table of twice that never fills past half.
        let need = (text.len() / 5 * 2 + 16).next_power_of_two();
        if self.slots.len() < need {
            self.slots.resize(need, 0);
        }
        let bits = need.trailing_zeros();
        let (slots, words) = (&mut self.slots, &mut self.words);
        words.clear();
        let load = |at: usize| u64::from_le_bytes(text[at..at + 8].try_into().unwrap_or([0; 8]));
        let mut start = 0;
        for block in (0..=end).step_by(16) {
            let mut zeros = simd::zeros(text[block..block + 16].try_into().unwrap_or([0; 16]));
            while zeros != 0 {
                let at = block + zeros.trailing_zeros() as usize;
                zeros &= zeros - 1;
                let len = at - start;
                if len >= 4 {
                    let keep = |n: usize| if n >= 8 { u64::MAX } else { (1u64 << (8 * n)) - 1 };
                    let c = [load(start) & keep(len), load(start + 8) & keep(len.saturating_sub(8))];
                    let h = (c[0] ^ c[1].rotate_left(29) ^ len as u64).wrapping_mul(K);
                    let mut k = (h >> (64 - bits)) as usize;
                    loop {
                        let Some(e) = slots[k].checked_sub(1).map(|w| &mut words[w as usize]) else {
                            slots[k] = words.len() as u32 + 1;
                            words.push(Word { c, start: start as u32, len: len as u32, count: 1, slot: k as u32 });
                            break;
                        };
                        if e.c == c && e.len as usize == len && (len <= 16 || text[e.start as usize..][..len] == text[start..at]) {
                            e.count += 1;
                            break;
                        }
                        k = (k + 1) & (need - 1);
                    }
                }
                start = at + 1;
            }
        }
        for e in words.iter() {
            slots[e.slot as usize] = 0;
        }
        // Stop words are seven bytes or fewer: their first chunk is the word.
        let stop = |e: &Word| e.len <= 7 && STOP_BLOOM & (1 << (e.c[0] % 64)) != 0 && STOP_CHUNK.contains(&e.c[0]);
        // The ten first by count then bytes: the tenth count bounds them,
        // every word above it is in, and the words at it fill the rest by
        // bytes.
        let mut top = [0u32; 10];
        for e in words.iter() {
            if e.count <= top[9] || stop(e) {
                continue;
            }
            let at = top.iter().position(|&t| e.count > t).unwrap_or(9);
            top.copy_within(at..9, at + 1);
            top[at] = e.count;
        }
        let floor = top[9];
        let mut out: Vec<&Word> = words.iter().filter(|e| e.count > floor && !stop(e)).collect();
        let mut tied: Vec<&Word> = Vec::new();
        for e in words.iter().filter(|e| e.count == floor && floor > 0) {
            let room = tied.len() + out.len() < 10;
            if (room || tied.last().is_some_and(|l| e.cmp(l, text).is_lt())) && !stop(e) {
                let at = tied.partition_point(|t| t.cmp(e, text).is_lt());
                tied.insert(at, e);
                tied.truncate(10 - out.len());
            }
        }
        out.sort_unstable_by(|a, b| b.count.cmp(&a.count).then_with(|| a.cmp(b, text)));
        out.iter()
            .chain(&tied)
            .filter_map(|e| core::str::from_utf8(&text[e.start as usize..(e.start + e.len) as usize]).ok())
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

/// Sixteen bytes at a time: through `WORD`, and which are zero (simd128
/// in wasm, SSE2 on x86_64).
mod simd {
    #[allow(unused_imports)]
    use super::WORD;

    #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
    pub fn words(b: [u8; 16]) -> [u8; 16] {
        use core::arch::wasm32::*;
        let c = u8x16(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
        let within = |x: v128, lo: u8, n: u8| u8x16_lt(u8x16_sub(x, u8x16_splat(lo)), u8x16_splat(n));
        let low = v128_or(c, v128_and(within(c, b'A', 26), u8x16_splat(0x20)));
        let word = v128_or(
            v128_or(within(low, b'a', 26), within(low, b'0', 10)),
            v128_or(v128_or(u8x16_eq(low, u8x16_splat(b'+')), u8x16_eq(low, u8x16_splat(b'#'))), u8x16_eq(low, u8x16_splat(b'.'))),
        );
        let out = v128_and(low, word);
        let mut o = [0u8; 16];
        // SAFETY: o is 16 bytes.
        unsafe { v128_store(o.as_mut_ptr() as *mut v128, out) };
        o
    }

    #[cfg(all(target_arch = "wasm32", target_feature = "simd128"))]
    pub fn zeros(b: [u8; 16]) -> u32 {
        use core::arch::wasm32::*;
        // SAFETY: b is 16 bytes.
        let c = unsafe { v128_load(b.as_ptr() as *const v128) };
        u8x16_bitmask(u8x16_eq(c, u8x16_splat(0))) as u32
    }

    #[cfg(target_arch = "x86_64")]
    pub fn words(b: [u8; 16]) -> [u8; 16] {
        use core::arch::x86_64::*;
        // SAFETY: SSE2 is part of x86_64; b and o are 16 bytes.
        unsafe {
            let c = _mm_loadu_si128(b.as_ptr() as *const __m128i);
            let within = |x: __m128i, lo: u8, n: u8| {
                let d = _mm_sub_epi8(x, _mm_set1_epi8(lo as i8));
                _mm_cmpeq_epi8(_mm_min_epu8(d, _mm_set1_epi8(n as i8 - 1)), d)
            };
            let low = _mm_or_si128(c, _mm_and_si128(within(c, b'A', 26), _mm_set1_epi8(0x20)));
            let is = |x: u8| _mm_cmpeq_epi8(low, _mm_set1_epi8(x as i8));
            let word = _mm_or_si128(
                _mm_or_si128(within(low, b'a', 26), within(low, b'0', 10)),
                _mm_or_si128(_mm_or_si128(is(b'+'), is(b'#')), is(b'.')),
            );
            let mut o = [0u8; 16];
            _mm_storeu_si128(o.as_mut_ptr() as *mut __m128i, _mm_and_si128(low, word));
            o
        }
    }

    #[cfg(target_arch = "x86_64")]
    pub fn zeros(b: [u8; 16]) -> u32 {
        use core::arch::x86_64::*;
        // SAFETY: SSE2 is part of x86_64; b is 16 bytes.
        unsafe {
            let c = _mm_loadu_si128(b.as_ptr() as *const __m128i);
            _mm_movemask_epi8(_mm_cmpeq_epi8(c, _mm_setzero_si128())) as u32
        }
    }

    #[cfg(not(any(target_arch = "x86_64", all(target_arch = "wasm32", target_feature = "simd128"))))]
    pub fn words(b: [u8; 16]) -> [u8; 16] {
        b.map(|c| WORD[c as usize])
    }

    #[cfg(not(any(target_arch = "x86_64", all(target_arch = "wasm32", target_feature = "simd128"))))]
    pub fn zeros(b: [u8; 16]) -> u32 {
        b.iter().enumerate().fold(0, |m, (i, &c)| m | (((c == 0) as u32) << i))
    }
}







