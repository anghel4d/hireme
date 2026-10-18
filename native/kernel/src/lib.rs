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
pub mod heat;
pub mod keywords;
pub mod lanes;
pub mod org;
pub mod pipeline;
pub mod score;
pub mod text;

/// A calendar day as days since 1970-01-01, the schema's `day`.
pub type Day = i32;
