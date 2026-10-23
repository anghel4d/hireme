//! What the kernel's test files share: rows and ops named as
//! tests/vectors.json names them (tables, columns, commands and params by
//! name, an enum value by name, an absent cell null), a kernel booted from
//! such rows, and the three actors.

#![allow(dead_code)]

use std::sync::atomic::{AtomicU64, Ordering};

use kernel::abi::{self, Kernel};
use kernel::judge::{Ctx, Refusal, Row};
use kernel::query::Grants;
use serde_json::Value as Json;

pub const TODAY: i32 = 739_528;
/// The start of TODAY in Unix seconds.
pub const DAWN: i64 = (TODAY - kernel::UNIX_EPOCH_DAY) as i64 * 86_400;
pub const NOON: i64 = DAWN + 43_200;
pub const HOUR: i64 = 3_600;
/// A browser session's grants: every domain both ways.
pub const OPERATOR: Grants = Grants { human: true, read_mask: 0b1111, write_mask: 0b1111, may_delete: true };

pub fn operator(now: i64) -> Ctx<'static> {
    Ctx { today: TODAY, now, human: true, key_id: None, held: &[] }
}

/// An agent under API key `key`.
pub fn agent(key: u32, now: i64) -> Ctx<'static> {
    Ctx { today: TODAY, now, human: false, key_id: Some(key), held: &[] }
}

/// The node's mail actor: no human, no key.
pub fn mail(now: i64) -> Ctx<'static> {
    Ctx { today: TODAY, now, human: false, key_id: None, held: &[] }
}

pub fn table(name: &str) -> &'static schema::TableDef {
    schema::TABLES.iter().find(|t| t.name == name).unwrap_or_else(|| panic!("no table {name}"))
}

/// `v` as the u32 a cell holds: null is NONE, a bool 0 or 1, a name the value of the enum `target`.
fn u32_of(v: &Json, target: Option<&str>) -> u32 {
    match v {
        Json::Null => wire::NONE,
        Json::Bool(b) => *b as u32,
        Json::String(s) => schema::enum_names(target.unwrap_or("")).and_then(|n| n.iter().position(|n| n == s)).unwrap_or_else(|| panic!("no {s} in enum {target:?}")) as u32,
        _ => v.as_u64().unwrap_or_else(|| panic!("{v} is not a u32")) as u32,
    }
}

/// A BOOT or PATCH body of `rows`, `{table: [{column: value}]}`: a block per table, a column for every name its rows use.
pub fn body(rows: &Json) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    for (name, list) in rows.as_object().unwrap() {
        let (t, list) = (table(name), list.as_array().unwrap());
        let mut cols: Vec<&schema::ColDef> = Vec::new();
        for k in list.iter().flat_map(|r| r.as_object().unwrap().keys()) {
            let c = t.col_named(k).unwrap_or_else(|| panic!("no column {name}.{k}"));
            if !cols.iter().any(|x| x.id == c.id) {
                cols.push(c);
            }
        }
        let mut b = w.block(t.id, list.len());
        for c in cols {
            let v = |r: &Json| r.get(c.name).cloned().unwrap_or(Json::Null);
            match c.wire {
                wire::U32 => b.u32s(c.id, list.iter().map(|r| u32_of(&v(r), c.target))),
                wire::I64 => b.i64s(c.id, list.iter().map(|r| v(r).as_i64().unwrap_or(wire::NONE64))),
                wire::F64 => b.f64s(c.id, list.iter().map(|r| v(r).as_f64().unwrap_or(f64::NAN))),
                _ => b.strs(c.id, list.iter().map(|r| v(r).as_str().unwrap_or("").to_string()).collect::<Vec<_>>().iter().map(String::as_str)),
            };
        }
    }
    w.finish()
}

/// Germany (1, DE) with Berlin (2), and France (3, FR), in Europe.
pub fn europe() -> Json {
    serde_json::json!([
        {"id": 1, "kind": "country", "iso2": "DE", "name": "Germany", "region": "Europe"},
        {"id": 2, "kind": "city", "country_id": 1, "name": "Berlin"},
        {"id": 3, "kind": "country", "iso2": "FR", "name": "France", "region": "Europe"},
    ])
}

/// A text cell as the node sends a long one: zstd against the text dictionary.
pub fn packed(text: &str) -> Vec<u8> {
    let mut z = zstd::bulk::Compressor::with_dictionary(19, wire::TEXT_DICT).unwrap();
    z.include_checksum(false).unwrap();
    z.include_contentsize(true).unwrap();
    [&[1u8][..], &z.compress(text.as_bytes()).unwrap()].concat()
}

/// A body that removes rows `ids` of `table`.
pub fn gone(table: u16, ids: &[u32]) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    w.gone(table, ids);
    w.finish()
}

/// A kernel on TODAY under the operator's grants, booted from `rows`.
pub fn kernel(rows: Json) -> Kernel {
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.set_grants(OPERATOR);
    k.boot(&body(&rows), 1).unwrap();
    k
}

/// A seeded xorshift; a failure names its seed, so it replays.
pub struct Rng(pub u64);

impl Rng {
    pub fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % n.max(1)
    }

    pub fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len() as u64) as usize]
    }
}

static OP_ID: AtomicU64 = AtomicU64::new(100);

/// One op as the judge takes it, under an op id of its own.
pub fn raw(verb: u8, flags: u8, table: u16, target: u32, rev: Option<u32>, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(OP_ID.fetch_add(1, Ordering::Relaxed), verb, flags, table, target, rev);
    cells(&mut o);
    o.done();
    w.finish()[8..].to_vec()
}

fn cell(o: &mut wire::OpWriter, id: u16, ty: u8, target: Option<&str>, v: &Json) {
    match (ty, v) {
        (_, Json::Null) => o.null(id),
        (wire::U32, _) => o.u32(id, u32_of(v, target)),
        (wire::I64, _) => o.i64(id, v.as_i64().unwrap()),
        (wire::F64, _) => o.f64(id, v.as_f64().unwrap()),
        _ => o.str(id, v.as_str().unwrap_or_else(|| panic!("{v} is not text"))),
    };
}

/// A put of `cells` on row `target` (0 inserts); `as_of` and `source` name the provenance cells.
pub fn put_with(flags: u8, rev: Option<u32>, name: &str, target: u32, cells: Json) -> Vec<u8> {
    let t = table(name);
    raw(wire::PUT, flags, t.id, target, rev, |o| {
        for (k, v) in cells.as_object().unwrap() {
            match (k.as_str(), v) {
                ("as_of", _) => cell(o, schema::AS_OF, wire::U32, None, v),
                ("source", Json::String(_)) => cell(o, schema::SOURCE_CELL, wire::STR, None, v),
                ("source", _) => cell(o, schema::SOURCE_CELL, wire::U32, None, v),
                _ => {
                    let c = t.col_named(k).unwrap_or_else(|| panic!("no column {name}.{k}"));
                    cell(o, c.id, c.cell_type(), c.target, v)
                }
            }
        }
    })
}

pub fn put(name: &str, target: u32, cells: Json) -> Vec<u8> {
    put_with(0, None, name, target, cells)
}

/// A put that names its row by a natural key.
pub fn keyed(name: &str, cells: Json) -> Vec<u8> {
    put_with(wire::KEYED, None, name, 0, cells)
}

/// Command `name` on row `target` with `params`.
pub fn cmd(name: &str, target: u32, params: Json) -> Vec<u8> {
    let c = schema::COMMANDS.iter().find(|c| c.name == name).unwrap_or_else(|| panic!("no command {name}"));
    raw(wire::COMMAND, 0, c.id, target, None, |o| {
        for (k, v) in params.as_object().unwrap() {
            let p = c.params.iter().find(|p| p.name == k).unwrap_or_else(|| panic!("no param {name}.{k}"));
            cell(o, p.id, p.wire, p.target, v);
        }
    })
}

/// A drop of row `id`.
pub fn del(name: &str, id: u32) -> Vec<u8> {
    raw(wire::DROP, 0, table(name).id, id, None, |_| {})
}

/// A read that must answer.
pub fn q(k: &mut Kernel, req: Json) -> Json {
    k.query(&req).unwrap_or_else(|r| panic!("{req}: refused {} {}", r.code, r.data))
}

/// The code and data of a refusal that must come.
pub fn refused<T: std::fmt::Debug>(r: Result<T, Refusal>) -> (u16, Json) {
    let r = r.expect_err("expected a refusal");
    (r.code, r.data)
}

/// The cells of the first effect on `table`, by column name (null when none touches it).
pub fn cells(rows: &[Row], table: &str) -> Json {
    abi::effects_json(rows).as_array().unwrap().iter().find(|r| r["table"] == table).map_or(Json::Null, |r| r["cells"].clone())
}
