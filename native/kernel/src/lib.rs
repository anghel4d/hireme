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
//! the caller passes `today`.

#![cfg_attr(target_arch = "wasm32", no_std)]

extern crate alloc;

pub mod atlas;
pub mod ats;
pub mod board;
pub mod cv;
pub mod heat;
pub mod keywords;
pub mod lanes;
pub mod org;
pub mod pipeline;
pub mod rows;
pub mod score;
pub mod text;

/// A calendar day as days since 1970-01-01, the schema's `day`.
pub type Day = i32;

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
