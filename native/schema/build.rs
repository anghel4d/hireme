// Named constants for every table, column, enum value, refusal, command,
// param and frame, generated from schema/hireme.schema into OUT_DIR and
// included by src/lib.rs, so no crate hand-writes an id.

extern crate alloc;

#[path = "src/model.rs"]
#[allow(dead_code)]
mod model;

use std::fmt::Write as _;
use std::path::PathBuf;

const SCHEMA: &str = "../../schema/hireme.schema";

fn upper(name: &str) -> String {
    name.to_ascii_uppercase()
}

fn opt(v: Option<&str>) -> String {
    match v {
        Some(v) => format!("Some({v:?})"),
        None => "None".into(),
    }
}

/// `pub mod <name> { pub const <k: T = v>; ... }`, `indent` deep.
fn module(o: &mut String, indent: &str, name: &str, consts: impl IntoIterator<Item = String>) {
    writeln!(o, "{indent}pub mod {name} {{").unwrap();
    for c in consts {
        writeln!(o, "{indent}    pub const {c};").unwrap();
    }
    writeln!(o, "{indent}}}").unwrap();
}

/// An enum's values as consts, then `NAMES`.
fn values(values: &[String], ty: &str) -> Vec<String> {
    values.iter().enumerate().map(|(i, v)| format!("{}: {ty} = {i}", upper(v))).chain([format!("NAMES: &[&str] = &{values:?}")]).collect()
}

fn key_def(k: &model::Key, natural: bool) -> String {
    let cond = match &k.term {
        None => "None".into(),
        Some(model::Where::Eq(c, v)) => format!("Some(Cond::Eq({c:?}, {v:?}))"),
        Some(model::Where::Null(c)) => format!("Some(Cond::Null({c:?}))"),
        Some(model::Where::NotNull(c)) => format!("Some(Cond::NotNull({c:?}))"),
    };
    format!("KeyDef {{ cols: &{:?}, natural: {natural}, global: {}, cond: {cond} }}", k.cols, k.global)
}

fn main() {
    println!("cargo:rerun-if-changed={SCHEMA}");
    let source = std::fs::read_to_string(SCHEMA).expect("read schema/hireme.schema");
    let s = model::parse(&source).unwrap_or_else(|e| panic!("schema/hireme.schema:{e}"));
    let mut o = String::new();

    writeln!(o, "/// Frame layouts, enums, commands and the resident tables.").unwrap();
    writeln!(o, "pub const WIRE_HASH: u16 = {:#06x};", s.wire_hash).unwrap();
    writeln!(o, "/// The whole declaration.").unwrap();
    writeln!(o, "pub const SCHEMA_REV: u32 = {:#010x};", s.schema_rev).unwrap();

    writeln!(o, "/// The byte layout native/wire implements; native/wire asserts its own equals it.").unwrap();
    writeln!(o, "pub const LAYOUT: u16 = {};", s.layout).unwrap();
    for d in &s.dicts {
        writeln!(o, "/// The {} zstd dictionary's (id, fnv), priv/wire/{}.zdict.", d.name, d.name).unwrap();
        writeln!(o, "pub const {}_DICT: (u32, u32) = ({}, {:#010x});", d.name.to_uppercase(), d.id, d.fnv).unwrap();
    }
    writeln!(o, "/// A day is days since 0000-01-01 (proleptic Gregorian), 0 to this (9999-12-31).").unwrap();
    writeln!(o, "pub const DAY_MAX: u32 = {};", model::DAY_MAX).unwrap();
    module(&mut o, "", "domain", s.domains.iter().map(|d| format!("{}: u8 = {}", upper(&d.name), d.bit)));
    module(&mut o, "", "frame", s.frames.iter().map(|f| format!("{}: u8 = {}", f.name, f.id)));
    module(&mut o, "", "table", s.tables.iter().map(|t| format!("{}: u16 = {}", upper(&t.name), t.id)));
    writeln!(o, "pub mod col {{").unwrap();
    for t in &s.tables {
        module(&mut o, "    ", &t.name, t.cols.iter().map(|c| format!("{}: u16 = {}", upper(&c.name), c.id)));
    }
    writeln!(o, "}}").unwrap();
    writeln!(o, "pub mod enums {{").unwrap();
    for e in &s.enums {
        module(&mut o, "    ", &e.name, values(&e.values, "u8"));
    }
    writeln!(o, "}}").unwrap();

    writeln!(o, "/// Every enum's values by the declaration's name.").unwrap();
    writeln!(o, "pub static ENUMS: &[(&str, &[&str])] = &[").unwrap();
    for e in &s.enums {
        writeln!(o, "    ({:?}, enums::{}::NAMES),", e.name, e.name).unwrap();
    }
    writeln!(o, "];").unwrap();

    let refusal = s.enum_("refusal").expect("enum refusal");
    writeln!(o, "/// NACK codes: positions in `enum refusal`.").unwrap();
    module(&mut o, "", "refusal", values(&refusal.values, "u16"));
    module(&mut o, "", "command", s.commands.iter().map(|c| format!("{}: u16 = {}", upper(&c.name), c.id)));
    writeln!(o, "/// Each command's param cell ids.").unwrap();
    writeln!(o, "pub mod param {{").unwrap();
    for c in &s.commands {
        module(&mut o, "    ", &c.name, c.params.iter().map(|p| format!("{}: u16 = {:#06x}", upper(&p.name), p.id)));
    }
    writeln!(o, "}}").unwrap();

    writeln!(o, "pub static TABLES: &[TableDef] = &[").unwrap();
    for t in &s.tables {
        let session = t.residency == model::Residency::Wire
            || t.source.as_deref().and_then(|n| s.table(n)).is_some_and(|src| src.residency == model::Residency::Server);
        let keys = t.naturals.iter().map(|k| key_def(k, true)).chain(t.uniques.iter().map(|k| key_def(k, false))).collect::<Vec<_>>().join(", ");
        writeln!(
            o,
            "    TableDef {{ id: {}, name: {:?}, domain: {:?}, domain_bit: {}, residency: Residency::{:?}, cap: {:?}, append_only: {}, soft_delete: {}, unmasked: {}, singleton: {}, session: {session}, keys: &[{keys}], cols: &[",
            t.id, t.name, t.domain, s.domain_bit(&t.domain), t.residency, t.cap, t.append_only, t.soft_delete, t.unmasked, t.singleton
        )
        .unwrap();
        for c in &t.cols {
            writeln!(o, "        ColDef {{ id: {}, name: {:?}, type_code: {}, wire: {}, flags: {}, target: {}, default: {} }},", c.id, c.name, c.ty.code(), c.wire(), c.flags, opt(c.target.as_deref()), opt(c.default.as_deref())).unwrap();
        }
        writeln!(o, "    ] }},").unwrap();
    }
    writeln!(o, "];").unwrap();

    writeln!(o, "pub static COMMANDS: &[CommandDef] = &[").unwrap();
    for c in &s.commands {
        let table = s.table(&c.table).unwrap();
        writeln!(o, "    CommandDef {{ id: {}, name: {:?}, table: {}, human_only: {}, params: &[", c.id, c.name, table.id, c.human_only).unwrap();
        for p in &c.params {
            writeln!(o, "        ParamDef {{ id: {:#06x}, name: {:?}, type_code: {}, wire: {}, required: {}, column: {}, target: {} }},", p.id, p.name, p.ty.code(), p.wire(), p.required, p.column, opt(p.target.as_deref())).unwrap();
        }
        writeln!(o, "    ] }},").unwrap();
    }
    writeln!(o, "];").unwrap();

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("consts.rs");
    std::fs::write(out, o).unwrap();
}
