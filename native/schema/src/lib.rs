//! The declaration, `schema/hireme.schema`, for every Rust crate.
//!
//! - Named constants, generated at build time: `table::APPLICATIONS`,
//!   `col::applications::STAGE`, `enums::stage::DRAFT_READY`,
//!   `refusal::HEAT`, `command::OPEN_FIRE`, `param::stage::NOTE`,
//!   `frame::BOOT`, `domain::DESK`, `WIRE_HASH`, `SCHEMA_REV`.
//! - `TABLES` and `COMMANDS`: the catalog as static slices, for generic
//!   BOOT/PATCH ingest and op encoding.
//! - `parse` and (with `std`) `model()`: the resolved declaration as a value.
//! - `sql` and `ts`: the emitters behind `mix hireme.schema`.
//!
//! The catalog numbers (wire type codes, flag bits, type codes, reserved
//! and free-param cell ids) are in `wire`, `flag`, `Type::code`, `AS_OF`,
//! `SOURCE_CELL` and `FREE_PARAM`.

#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

mod model;
pub mod sql;
pub mod ts;

pub use model::*;

/// The declaration's text, as compiled in.
pub const SOURCE: &str = include_str!("../../../schema/hireme.schema");

/// One table of the catalog.
#[derive(Debug)]
pub struct TableDef {
    pub id: u16,
    pub name: &'static str,
    pub domain: &'static str,
    /// The mask bit of its domain; 0 for `system`.
    pub domain_bit: u8,
    pub residency: Residency,
    pub cap: Option<u32>,
    pub append_only: bool,
    pub soft_delete: bool,
    pub unmasked: bool,
    pub singleton: bool,
    /// Its natural keys, then its declared uniques (a `unique` column flag
    /// is `flag::UNIQUE`).
    pub keys: &'static [KeyDef],
    pub cols: &'static [ColDef],
}

/// A natural key or a declared unique, with its where.
#[derive(Debug)]
pub struct KeyDef {
    pub cols: &'static [&'static str],
    pub natural: bool,
    pub global: bool,
    pub cond: Option<Cond>,
}

/// A key's where: `col = 'value'`, `col is null`, `col is not null`.
#[derive(Debug, PartialEq, Eq)]
pub enum Cond {
    Eq(&'static str, &'static str),
    Null(&'static str),
    NotNull(&'static str),
}

/// One column of the catalog.
#[derive(Debug)]
pub struct ColDef {
    pub id: u16,
    pub name: &'static str,
    /// `Type::code`.
    pub type_code: u8,
    /// `wire::*`.
    pub wire: u8,
    /// `flag::*`.
    pub flags: u32,
    /// The table a ref names or the enum an enum names.
    pub target: Option<&'static str>,
    /// The declared default, as written (`= <value>`).
    pub default: Option<&'static str>,
}

/// One command of the catalog.
#[derive(Debug)]
pub struct CommandDef {
    pub id: u16,
    pub name: &'static str,
    /// The table id it targets a row of.
    pub table: u16,
    pub human_only: bool,
    pub params: &'static [ParamDef],
}

/// One command param: a column of the table, or a free typed value.
#[derive(Debug)]
pub struct ParamDef {
    pub id: u16,
    pub name: &'static str,
    pub type_code: u8,
    pub wire: u8,
    pub required: bool,
    pub column: bool,
    pub target: Option<&'static str>,
}

impl TableDef {
    pub fn col(&self, id: u16) -> Option<&'static ColDef> {
        self.cols.iter().find(|c| c.id == id)
    }

    pub fn col_named(&self, name: &str) -> Option<&'static ColDef> {
        self.cols.iter().find(|c| c.name == name)
    }
}

/// A table of the catalog by id.
pub fn table_def(id: u16) -> Option<&'static TableDef> {
    TABLES.iter().find(|t| t.id == id)
}

/// An enum's values in code order, by the declaration's name.
pub fn enum_names(name: &str) -> Option<&'static [&'static str]> {
    ENUMS.iter().find(|(n, _)| *n == name).map(|(_, v)| *v)
}

/// A command of the catalog by id.
pub fn command_def(id: u16) -> Option<&'static CommandDef> {
    COMMANDS.iter().find(|c| c.id == id)
}

include!(concat!(env!("OUT_DIR"), "/consts.rs"));

/// The compiled-in declaration, parsed once.
#[cfg(feature = "std")]
pub fn model() -> &'static Schema {
    static MODEL: std::sync::OnceLock<Schema> = std::sync::OnceLock::new();
    MODEL.get_or_init(|| parse(SOURCE).expect("schema/hireme.schema was valid at build time"))
}
