//! hireme's desk kernel: one client implementation of every desk view.
//!
//! It keeps the account's raw tables resident, predicts the writes the
//! client sends (with the refusals the server would answer), derives the
//! board, the heat verdicts and chart, the scoreboard and keyword
//! coverage from them, and orders and selects the board. The browser runs
//! it as `priv/static/wasm/kernel.wasm` through the export ABI in `abi`;
//! hireme-mcp links this crate natively and drives the same [`Desk`]:
//!
//! ```ignore
//! let mut desk = kernel::Desk::new();
//! desk.ingest(&frames);            // BOOT, PATCH, TICK, ACK, NACK...
//! desk.derive();                   // cards, verdicts, heat_rows, score...
//! let n = desk.rows(schema::table::CARDS);
//! let company = desk.str_at(schema::table::CARDS, schema::col::cards::COMPANY, 0);
//! ```
//!
//! `store` holds the tables, `desk` the pending view, order and selection,
//! `predict` the ops, `derive` the views, `heat` and `keywords` the Elixir
//! ports they run.

#![cfg_attr(target_arch = "wasm32", no_std)]

extern crate alloc;

#[cfg(target_arch = "wasm32")]
mod abi;
mod derive;
mod desk;
mod heat;
mod keywords;
mod predict;
mod store;

pub use desk::Desk;
pub use wire::schema;

/// Bits `ingest_commit` returns. (4 and 8 named LINES and FOCUS, which the
/// wire no longer carries; the other values stay where readers know them.)
pub mod changed {
    pub const CARDS: u32 = 1;
    pub const TABLES: u32 = 2;
    pub const SETTLED_BIT: u32 = 16;
    pub const ROLLED_BACK: u32 = 32;
    pub const TICK: u32 = 64;
    pub const OTHER: u32 = 128;
    pub const ERROR: u32 = 1 << 30;
}
