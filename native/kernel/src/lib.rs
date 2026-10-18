//! hireme's kernel: the one implementation of every desk rule.
//!
//! The same crate runs in three places, so a prediction and its verdict
//! are one function: the browser loads it as WebAssembly (`abi`),
//! `hireme-mcp` links it natively, and the sequencer calls it through
//! `native/nif`. It holds an account's resident rows, judges every domain
//! write, and derives what the lenses and the MCP read.
//!
//! Every computation is deterministic across targets: float math goes
//! through `libm`, never a platform library, and nothing reads a clock;
//! the caller passes `today`. The wasm build uses std as the target ships
//! it (its allocator, panics abort), so one source serves all three.

extern crate alloc;

pub mod abi;
pub mod atlas;
pub mod ats;
pub mod board;
pub mod compose;
pub mod cv;
pub mod heat;
pub mod judge;
pub mod keywords;
pub mod lanes;
pub mod lexicon;
pub mod org;
pub mod pipeline;
pub mod query;
pub mod rows;
pub mod score;
pub mod text;

/// Hash maps for lookups by integer id. Nothing iterates one
/// to produce a result, so the cheap multiply hash (no per-process seed)
/// costs no determinism.
pub(crate) mod fx {
    use core::hash::{BuildHasherDefault, Hasher};

    #[derive(Default)]
    pub struct Fx(u64);

    impl Hasher for Fx {
        fn finish(&self) -> u64 {
            self.0
        }

        fn write(&mut self, bytes: &[u8]) {
            for b in bytes {
                self.write_u64(*b as u64);
            }
        }

        fn write_u8(&mut self, n: u8) {
            self.write_u64(n as u64);
        }

        fn write_u32(&mut self, n: u32) {
            self.write_u64(n as u64);
        }

        fn write_u64(&mut self, n: u64) {
            self.0 = (self.0.rotate_left(5) ^ n).wrapping_mul(0x517c_c1b7_2722_0a95);
        }

        fn write_usize(&mut self, n: usize) {
            self.write_u64(n as u64);
        }
    }

    pub type Map<K, V> = std::collections::HashMap<K, V, BuildHasherDefault<Fx>>;
}

/// Hash maps keyed by text a writer controls (company names, ATS tenants,
/// the board's distinct texts). A folded-multiply hash under a seed drawn
/// once per kernel instance from the host's random source: far cheaper
/// than SipHash, above all under WebAssembly, and a text cannot aim
/// collisions at a seed it does not know. Nothing iterates one to produce
/// a result.
pub(crate) mod keyed {
    use core::hash::{BuildHasher, Hasher};
    use std::sync::OnceLock;

    const M: u64 = 0x9E37_79B9_7F4A_7C15;

    fn fold(a: u64, b: u64) -> u64 {
        let p = (a as u128) * (b as u128);
        (p as u64) ^ ((p >> 64) as u64)
    }

    /// The multiplier a seed keys: mixed and odd, so no seed makes it 0
    /// (every text alike) or 1 (the hash linear in the text).
    fn multiplier(seed: u64) -> u64 {
        fold(seed ^ M, 0xC2B2_AE3D_27D4_EB4F) | (1 << 63) | 1
    }

    #[derive(Clone, Copy)]
    pub struct Seed(u64);

    impl Default for Seed {
        fn default() -> Self {
            static SEED: OnceLock<u64> = OnceLock::new();
            Seed(*SEED.get_or_init(draw))
        }
    }

    /// Under WebAssembly std has no random source (its `RandomState` keys
    /// are one constant there), so the module imports `host.random_u32`,
    /// the host's crypto RNG, and cannot be instantiated without it.
    #[cfg(target_arch = "wasm32")]
    fn draw() -> u64 {
        #[link(wasm_import_module = "host")]
        unsafe extern "C" {
            fn random_u32() -> u32;
        }
        // SAFETY: the import takes nothing and returns a number.
        let (a, b) = unsafe { (random_u32(), random_u32()) };
        ((a as u64) << 32) | b as u64
    }

    /// Natively std's hash keys come from the OS's random source.
    #[cfg(not(target_arch = "wasm32"))]
    fn draw() -> u64 {
        std::hash::RandomState::new().hash_one(M)
    }

    impl BuildHasher for Seed {
        type Hasher = Keyed;

        fn build_hasher(&self) -> Keyed {
            Keyed { h: self.0, k: multiplier(self.0) }
        }
    }

    pub struct Keyed {
        h: u64,
        k: u64,
    }

    impl Hasher for Keyed {
        fn finish(&self) -> u64 {
            fold(self.h, self.k.rotate_left(29))
        }

        fn write(&mut self, bytes: &[u8]) {
            self.write_u64(bytes.len() as u64);
            let (words, rest) = bytes.as_chunks::<8>();
            for w in words {
                self.write_u64(u64::from_le_bytes(*w));
            }
            if !rest.is_empty() {
                let mut a = [0u8; 8];
                a[..rest.len()].copy_from_slice(rest);
                self.write_u64(u64::from_le_bytes(a));
            }
        }

        fn write_u8(&mut self, n: u8) {
            self.write_u64(n as u64);
        }

        fn write_u32(&mut self, n: u32) {
            self.write_u64(n as u64);
        }

        fn write_u64(&mut self, n: u64) {
            self.h = fold(self.h ^ n, self.k);
        }

        fn write_usize(&mut self, n: usize) {
            self.write_u64(n as u64);
        }
    }

    pub type Map<K, V> = std::collections::HashMap<K, V, Seed>;

    #[cfg(test)]
    mod tests {
        use super::*;

        fn hash(seed: u64, bytes: &[u8]) -> u64 {
            let mut h = Seed(seed).build_hasher();
            h.write(bytes);
            h.finish()
        }

        /// Collisions take the seed. Knowing it, a writer can make any
        /// number of texts hash alike (the second word cancels the state
        /// the first left); under any other seed those texts spread.
        #[test]
        fn crafted_collisions_need_the_seed() {
            let known = 0x0123_4567_89AB_CDEF;
            let k = multiplier(known);
            let crafted: Vec<[u8; 16]> = (0..10_000u64)
                .map(|w1| {
                    let h0 = fold(known ^ 16, k);
                    let w2 = fold(h0 ^ w1, k);
                    let mut b = [0u8; 16];
                    b[..8].copy_from_slice(&w1.to_le_bytes());
                    b[8..].copy_from_slice(&w2.to_le_bytes());
                    b
                })
                .collect();
            let distinct = |seed: u64| crafted.iter().map(|b| hash(seed, b)).collect::<std::collections::BTreeSet<_>>().len();
            assert_eq!(distinct(known), 1, "the construction collides under its seed");
            // Any seed, the constant the multiplier is mixed from included.
            for other in [known ^ 1, Seed::default().0, M, 0, u64::MAX] {
                assert_eq!(distinct(other), crafted.len(), "seed {other:#x}");
            }
        }
    }
}

/// A calendar day as days since 0000-01-01 in the proleptic Gregorian
/// calendar, the schema's `day` (Elixir's `Date.to_gregorian_days/1`):
/// 0 is 0000-01-01, 719528 is 1970-01-01. The kernel only ever compares
/// and subtracts days, so it never converts one to a date.
pub type Day = i32;

/// 1970-01-01 as a [`Day`], where unix time begins.
pub const UNIX_EPOCH_DAY: Day = 719_528;

/// The last day a `day` column holds, 9999-12-31 (the schema's).
pub const LAST_DAY: Day = schema::DAY_MAX as Day;

/// A [`Day`] as its date, `YYYY-MM-DD`: how a document shows a day, and
/// what `put` takes back.
pub fn day_iso(d: Day) -> alloc::string::String {
    // Howard Hinnant's civil_from_days, from 0000-03-01 so a leap day
    // ends its year.
    let z = d as i64 - 60;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    alloc::format!("{year:04}-{month:02}-{day:02}")
}

/// A `YYYY-MM-DD` date as a [`Day`], if it is one in 0000-01-01..=9999-12-31.
pub fn iso_day(s: &str) -> Option<Day> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let num = |r: core::ops::Range<usize>| s.get(r).filter(|p| p.bytes().all(|c| c.is_ascii_digit()))?.parse::<i64>().ok();
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
    let len = *[31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].get((m as usize).wrapping_sub(1))?;
    if d < 1 || d > len {
        return None;
    }
    // Howard Hinnant's days_from_civil, counted from 0000-03-01.
    let (y, mp) = if m <= 2 { (y - 1, m + 9) } else { (y, m - 3) };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Day::try_from(era * 146_097 + doe + 60).ok().filter(|d| (0..=LAST_DAY).contains(d))
}

/// An ISO-8601 time (`YYYY-MM-DDTHH:MM:SS`, optional fraction, `Z` or an
/// offset, or none for UTC) as unix seconds.
pub fn iso_time(s: &str) -> Option<i64> {
    let day = iso_day(s.get(..10)?)? as i64;
    let rest = s.get(10..)?.strip_prefix(['T', ' '])?;
    let num = |p: &str| p.bytes().all(|c| c.is_ascii_digit()).then(|| p.parse::<i64>().ok()).flatten();
    let (h, mi, sec) = (num(rest.get(0..2)?)?, num(rest.get(3..5)?)?, num(rest.get(6..8)?)?);
    if rest.as_bytes().get(2) != Some(&b':') || rest.as_bytes().get(5) != Some(&b':') || h > 23 || mi > 59 || sec > 59 {
        return None;
    }
    let mut tail = &rest[8..];
    if let Some(f) = tail.strip_prefix('.') {
        let n = f.bytes().take_while(u8::is_ascii_digit).count();
        tail = &f[n..];
    }
    let offset = match tail {
        "" | "Z" => 0,
        t if t.len() == 6 && (t.starts_with('+') || t.starts_with('-')) && &t[3..4] == ":" => {
            let o = num(&t[1..3])? * 3600 + num(&t[4..6])? * 60;
            if t.starts_with('-') { -o } else { o }
        }
        _ => return None,
    };
    Some((day - UNIX_EPOCH_DAY as i64) * 86_400 + h * 3600 + mi * 60 + sec - offset)
}

/// Unix seconds as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn time_iso(secs: i64) -> alloc::string::String {
    let (days, s) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    alloc::format!("{}T{:02}:{:02}:{:02}Z", day_iso((days + UNIX_EPOCH_DAY as i64) as Day), s / 3600, s / 60 % 60, s % 60)
}

#[cfg(test)]
mod tests {
    use alloc::vec::Vec;

    use super::{day_iso, time_iso, LAST_DAY, UNIX_EPOCH_DAY};

    /// Every day from 0000-01-01 to 9999-12-31 is the next date after
    /// the one before, counted by a plain calendar.
    #[test]
    fn days_read_as_dates() {
        let (mut y, mut m, mut d) = (0i64, 1u32, 1u32);
        for day in 0..=LAST_DAY {
            assert_eq!(day_iso(day), alloc::format!("{y:04}-{m:02}-{d:02}"), "day {day}");
            let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
            let len = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m as usize - 1];
            d += 1;
            if d > len {
                (d, m) = (1, m + 1);
                if m > 12 {
                    (m, y) = (1, y + 1);
                }
            }
        }
        for (day, iso) in [(0, "0000-01-01"), (692_866, "1897-01-01"), (UNIX_EPOCH_DAY, "1970-01-01"), (740_272, "2026-10-18"), (3_652_424, "9999-12-31")] {
            assert_eq!(day_iso(day), iso);
        }
        assert_eq!(time_iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(time_iso(1_792_281_600 + 13 * 3600 + 5 * 60 + 9), "2026-10-18T13:05:09Z");
        assert_eq!(time_iso(-1), "1969-12-31T23:59:59Z");
    }

    /// The kernel's enums are the declaration's, value for value.
    #[test]
    fn enums_match_the_schema() {
        use schema::enums;
        let stages: Vec<&str> = crate::pipeline::STAGES.iter().map(|s| s.name()).collect();
        assert_eq!(stages, enums::stage::NAMES);
        let bands: Vec<&str> = crate::score::BANDS.iter().map(|b| b.name()).collect();
        assert_eq!(bands, enums::band::NAMES);
        let modes: Vec<&str> = (0..3).map(|i| crate::cv::Mode::from_u8(i).unwrap().name()).collect();
        assert_eq!(modes, enums::overlay_mode::NAMES);
        let kinds: Vec<&str> = crate::lanes::NetKind::ALL.iter().map(|k| k.name()).collect();
        assert_eq!(kinds, enums::net_kind::NAMES);
        assert_eq!(enums::rep_outcome::SKIP, crate::lanes::RepOutcome::Skip as u8);
        assert_eq!(enums::rep_outcome::ATTEMPT, crate::lanes::RepOutcome::Attempt as u8);
    }
}
