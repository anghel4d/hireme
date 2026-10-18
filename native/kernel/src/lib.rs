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

#[cfg(test)]
mod tests {
    use alloc::vec::Vec;

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
