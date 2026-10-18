//! Reads over the replica: `find`, `get`, `text` and `history`, the same
//! contract as the server's `Hireme.World` (lib/hireme/world.ex), answered
//! from the rows the kernel holds. The browser's lenses and `hireme-mcp`
//! read here; nothing it holds is fetched again.
//!
//! The replica holds what the session's grants let the server send, so a
//! read is checked against the same grants World checks (`Grants`): the
//! table's domain bit in the read mask, every column visible (never
//! `server_only`, `private` only to the operator).
//!
//! As World: an enum orders and compares by its value's name; `find`
//! orders by one column then `id`, nulls last both ways, and pages by an
//! opaque keyset cursor; `like` and `prefix` are ASCII-case-insensitive,
//! as SQLite's LIKE; a deferred text comes back as `{len, sha}` (its byte
//! length and the first 8 bytes of its SHA-256, hex) in `find` and `get`,
//! whole through `text`; a soft-deleted row is passed over by every read
//! but `history`, whose citations still name it.

use alloc::borrow::Cow;
use alloc::string::String;
use alloc::vec::Vec;
use core::cmp::Ordering;
use schema::{flag, refusal, ColDef as Column, Cond, KeyDef, Residency, TableDef as TableModel, Type, TYPES};
use serde_json::{json, Map, Value as Json};

use crate::judge::Refusal;
use crate::rows::{Rows, Table, Val};

const FIND_LIMIT: u64 = 50;
const FIND_MAX: u64 = 500;
const HISTORY_LIMIT: u64 = 50;
const HISTORY_MAX: u64 = 200;
const CHUNK: u64 = 256 * 1024;
const INT64: u64 = i64::MAX as u64;

fn has(c: &Column, f: u32) -> bool {
    c.flags & f != 0
}

fn ty(c: &Column) -> Type {
    TYPES.get((c.type_code as usize).wrapping_sub(1)).map_or(Type::U32, |t| t.1)
}

/// What the session reading the replica may read: the operator reads
/// every domain and every private column; a key its read mask.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Grants {
    pub human: bool,
    pub read_mask: u8,
    pub write_mask: u8,
    pub may_delete: bool,
}

impl Default for Grants {
    fn default() -> Self {
        Grants { human: true, read_mask: 0b1_1111, write_mask: 0b1_1111, may_delete: true }
    }
}

impl Grants {
    pub fn visible(&self, c: &Column) -> bool {
        !has(c, flag::SERVER_ONLY) && (!has(c, flag::PRIVATE) || self.human)
    }
}

type Answer = Result<Json, Refusal>;

fn refuse(code: u16, data: Json) -> Answer {
    Err(Refusal { code, data })
}

/// One read: `{"op": "find" | "get" | "text" | "history", ...params}`.
pub fn query(rows: &Rows, g: &Grants, req: &Json) -> Answer {
    let Some(p) = req.as_object() else { return refuse(refusal::TYPE, json!({"params": brief(req)})) };
    match p.get("op").and_then(Json::as_str) {
        Some("find") => find(rows, g, p),
        Some("get") => get(rows, g, p),
        Some("text") => text(rows, g, p),
        Some("history") => history(rows, g, p),
        other => refuse(refusal::NOT_FOUND, json!({"method": other.map(echo)})),
    }
}

// ------------------------------------------------------------------ checks

fn readable(g: &Grants, name: Option<&Json>) -> Result<&'static TableModel, Refusal> {
    let Some(name) = name.and_then(Json::as_str) else {
        return Err(Refusal { code: refusal::TYPE, data: json!({"param": "table", "got": got(name)}) });
    };
    match schema::TABLES.iter().find(|t| t.name == name) {
        Some(t) if matches!(t.residency, Residency::Resident | Residency::Server) => {
            let bit = if t.unmasked { 0 } else { t.domain_bit };
            if bit == 0 {
                Err(Refusal { code: refusal::NOT_FOUND, data: json!({"table": echo(name)}) })
            } else if g.read_mask & bit == 0 {
                Err(Refusal { code: refusal::SCOPE, data: json!({"table": echo(name)}) })
            } else {
                Ok(t)
            }
        }
        _ => Err(Refusal { code: refusal::NOT_FOUND, data: json!({"table": echo(name)}) }),
    }
}

fn column(g: &Grants, t: &TableModel, name: Option<&Json>) -> Result<&'static Column, Refusal> {
    let Some(name) = name.and_then(Json::as_str) else {
        return Err(Refusal { code: refusal::TYPE, data: json!({"table": t.name, "column": got(name)}) });
    };
    match t.col_named(name) {
        Some(c) if g.visible(c) => Ok(c),
        _ => Err(Refusal { code: refusal::COLUMN, data: json!({"table": t.name, "column": echo(name)}) }),
    }
}

fn columns(g: &Grants, t: &TableModel, names: Option<&Json>, default_metrics: bool) -> Result<Vec<&'static Column>, Refusal> {
    match names {
        None | Some(Json::Null) => {
            Ok(t.cols.iter().filter(|c| g.visible(c) && (default_metrics || !has(c, flag::METRIC | flag::METRIC_ON))).collect())
        }
        Some(Json::Array(list)) => {
            let mut out: Vec<&Column> = Vec::new();
            for n in list {
                let c = column(g, t, Some(n))?;
                if !out.iter().any(|o| o.id == c.id) {
                    out.push(c);
                }
            }
            if !out.iter().any(|c| c.name == "id")
                && let Some(id) = t.col_named("id")
            {
                out.insert(0, id);
            }
            Ok(out)
        }
        Some(other) => Err(Refusal { code: refusal::TYPE, data: json!({"table": t.name, "cols": brief(other)}) }),
    }
}

fn bound(v: Option<&Json>, default: u64, max: u64, name: &str) -> Result<u64, Refusal> {
    match v {
        None | Some(Json::Null) => Ok(default),
        Some(Json::Number(n)) if n.as_u64().is_some_and(|n| n > 0 && n <= max) => Ok(n.as_u64().unwrap_or(default)),
        Some(Json::Number(n)) if n.as_u64().is_some_and(|n| n > max) => {
            Err(Refusal { code: refusal::TOO_LARGE, data: json!({"limit": n, "max": max, "param": name}) })
        }
        Some(other) => Err(Refusal { code: refusal::TYPE, data: json!({"param": name, "got": brief(other)}) }),
    }
}

fn id_param(v: Option<&Json>) -> Result<u32, Refusal> {
    match v.and_then(Json::as_u64) {
        Some(n) if n > 0 && n <= INT64 => Ok(u32::try_from(n).unwrap_or(u32::MAX)),
        _ => Err(Refusal { code: refusal::TYPE, data: json!({"param": "id", "got": got(v)}) }),
    }
}

/// A name the caller sent, as a refusal repeats it: 64 bytes at most.
fn echo(s: &str) -> String {
    let mut end = s.len().min(64);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    String::from(&s[..end])
}

/// A value a refusal names, bounded.
fn brief(v: &Json) -> String {
    let s = v.to_string();
    if s.len() <= 64 { s } else { alloc::format!("{}…", echo(&s)) }
}

fn got(v: Option<&Json>) -> Json {
    match v {
        None | Some(Json::Null) => Json::Null,
        Some(v) => Json::String(brief(v)),
    }
}

// ------------------------------------------------------------------ cells

/// A cell as it compares: enums by name, bools as 0 and 1.
#[derive(Clone, Debug, PartialEq)]
enum Key2<'a> {
    Null,
    Int(i64),
    Float(f64),
    Str(Cow<'a, str>),
}

impl Key2<'_> {
    fn is_null(&self) -> bool {
        matches!(self, Key2::Null)
    }

    fn text(&self) -> Option<&str> {
        match self {
            Key2::Str(s) => Some(s),
            _ => None,
        }
    }

    /// Non-null values of one column, in SQLite's order.
    fn cmp(&self, o: &Key2<'_>) -> Ordering {
        match (self, o) {
            (Key2::Int(a), Key2::Int(b)) => a.cmp(b),
            (Key2::Float(a), Key2::Float(b)) => a.total_cmp(b),
            (Key2::Int(a), Key2::Float(b)) => (*a as f64).total_cmp(b),
            (Key2::Float(a), Key2::Int(b)) => a.total_cmp(&(*b as f64)),
            _ => match (self.text(), o.text()) {
                (Some(a), Some(b)) => a.as_bytes().cmp(b.as_bytes()),
                _ => Ordering::Equal,
            },
        }
    }
}

fn enum_values(c: &Column) -> &'static [&'static str] {
    c.target.and_then(schema::enum_names).unwrap_or(&[])
}

/// The value of a row's cell for comparing.
fn key_of<'a>(t: &'a Table, id: u32, c: &Column) -> Key2<'a> {
    match ty(c) {
        Type::Enum => t.u32(id, c.id).and_then(|v| enum_values(c).get(v as usize)).map_or(Key2::Null, |n| Key2::Str(Cow::Borrowed(n))),
        Type::I64 => t.i64(id, c.id).map_or(Key2::Null, Key2::Int),
        Type::F64 => t.f64(id, c.id).filter(|f| !f.is_nan()).map_or(Key2::Null, Key2::Float),
        Type::Str | Type::Text | Type::Json => t.str(id, c.id).map_or(Key2::Null, |s| Key2::Str(Cow::Borrowed(s))),
        _ => t.u32(id, c.id).map_or(Key2::Null, |v| Key2::Int(v as i64)),
    }
}

fn is_live(t: &Table, tm: &TableModel, id: u32) -> bool {
    !tm.soft_delete || tm.col_named("deleted_at").is_none_or(|c| t.u32(id, c.id).is_none() && t.i64(id, c.id).is_none())
}

fn sha8(text: &str) -> String {
    use sha2::{Digest, Sha256};
    let d = Sha256::digest(text.as_bytes());
    d[..8].iter().map(|b| alloc::format!("{b:02x}")).collect()
}

/// A cell as World's JSON shows it.
fn out(t: &Table, id: u32, c: &Column) -> Json {
    if has(c, flag::DEFERRED) {
        return t.str(id, c.id).map_or(Json::Null, |s| json!({"len": s.len(), "sha": sha8(s)}));
    }
    match ty(c) {
        Type::Enum => t.u32(id, c.id).and_then(|v| enum_values(c).get(v as usize)).map_or(Json::Null, |n| Json::String((*n).into())),
        Type::Bool => t.u32(id, c.id).map_or(Json::Null, |b| Json::Bool(b == 1)),
        Type::Day => t.u32(id, c.id).map_or(Json::Null, |d| crate::day_iso(d as crate::Day).into()),
        Type::Time => match t.get(id, c.id) {
            Val::U32(s) => crate::time_iso(s as i64).into(),
            Val::I64(s) => crate::time_iso(s).into(),
            _ => Json::Null,
        },
        Type::I64 => t.i64(id, c.id).map_or(Json::Null, Json::from),
        Type::F64 => t.f64(id, c.id).and_then(serde_json::Number::from_f64).map_or(Json::Null, Json::Number),
        Type::Json => t.str(id, c.id).map_or(Json::Null, |s| serde_json::from_str(s).unwrap_or_else(|_| Json::String(s.into()))),
        Type::Str | Type::Text | Type::Bytes => t.str(id, c.id).map_or(Json::Null, |s| Json::String(s.into())),
        _ => t.u32(id, c.id).map_or(Json::Null, Json::from),
    }
}

pub(crate) fn row_out(t: &Table, id: u32, cols: &[&Column], drop_nulls: bool) -> Json {
    let mut m = Map::new();
    for c in cols {
        let v = out(t, id, c);
        if !(drop_nulls && v.is_null()) {
            m.insert(c.name.into(), v);
        }
    }
    Json::Object(m)
}

// ------------------------------------------------------------------ casts

/// A filter's value as its column holds it, as Ecto casts it; `None`
/// when it will not cast or does not fit the column.
fn cast(c: &Column, v: &Json) -> Option<Key2<'static>> {
    let int = |v: &Json| -> Option<i64> {
        match v {
            Json::Number(n) => n.as_i64(),
            Json::String(s) => s.parse::<i64>().ok(),
            _ => None,
        }
    };
    match ty(c) {
        Type::Id | Type::Ref | Type::U32 => int(v).filter(|n| (0..=u32::MAX as i64).contains(n)).map(Key2::Int),
        Type::U8 => int(v).filter(|n| (0..=255).contains(n)).map(Key2::Int),
        Type::I64 => int(v).map(Key2::Int),
        Type::F64 => match v {
            Json::Number(n) => n.as_f64().map(Key2::Float),
            Json::String(s) => s.parse::<f64>().ok().filter(|f| f.is_finite()).map(Key2::Float),
            _ => None,
        },
        Type::Bool => match v {
            Json::Bool(b) => Some(Key2::Int(*b as i64)),
            Json::String(s) if s == "true" || s == "1" => Some(Key2::Int(1)),
            Json::String(s) if s == "false" || s == "0" => Some(Key2::Int(0)),
            _ => None,
        },
        Type::Day => v.as_str().and_then(crate::iso_day).map(|d| Key2::Int(d as i64)),
        Type::Time => v.as_str().and_then(crate::iso_time).map(Key2::Int),
        Type::Enum => v.as_str().filter(|s| enum_values(c).contains(s)).map(|s| Key2::Str(Cow::Owned(s.into()))),
        Type::Str | Type::Text => v.as_str().map(|s| Key2::Str(Cow::Owned(s.into()))),
        _ => None,
    }
}

// ------------------------------------------------------------------ filters

#[derive(Clone, Debug)]
enum Test {
    Eq(Key2<'static>),
    IsNull,
    NotNull,
    Ne(Key2<'static>),
    Lt(Key2<'static>),
    Le(Key2<'static>),
    Gt(Key2<'static>),
    Ge(Key2<'static>),
    In(Vec<Key2<'static>>),
    Like(String),
    Prefix(String),
}

struct Filter<'t> {
    col: &'t Column,
    test: Test,
}

fn filters(g: &Grants, t: &TableModel, w: Option<&Json>) -> Result<Vec<Filter<'static>>, Refusal> {
    let w = match w {
        None | Some(Json::Null) => return Ok(Vec::new()),
        Some(Json::Object(w)) => w,
        Some(other) => return Err(Refusal { code: refusal::TYPE, data: json!({"table": t.name, "where": brief(other)}) }),
    };
    let mut out = Vec::new();
    for (name, test) in w {
        let c = column(g, t, Some(&Json::String(name.clone())))?;
        if has(c, flag::DEFERRED) || matches!(ty(c), Type::Json | Type::Bytes) {
            return Err(Refusal { code: refusal::COLUMN, data: json!({"table": t.name, "column": c.name, "reason": "not filterable"}) });
        }
        out.push(Filter { col: c, test: filter(c, test)? });
    }
    Ok(out)
}

fn filter(c: &Column, test: &Json) -> Result<Test, Refusal> {
    let bad = |v: &Json| Refusal { code: refusal::TYPE, data: json!({"column": c.name, "value": brief(v)}) };
    let one = |v: &Json| cast(c, v).ok_or_else(|| bad(v));
    let (op, v) = match test {
        Json::Object(m) if m.len() == 1 => {
            let (op, v) = m.iter().next().unwrap_or_else(|| unreachable!());
            (op.as_str(), v)
        }
        Json::Object(_) | Json::Array(_) => return Err(Refusal { code: refusal::TYPE, data: json!({"column": c.name, "filter": brief(test)}) }),
        v => ("eq", v),
    };
    let text = matches!(ty(c), Type::Str | Type::Text);
    Ok(match (op, v) {
        ("eq", Json::Null) => Test::IsNull,
        ("eq", v) => Test::Eq(one(v)?),
        ("ne", Json::Null) => Test::NotNull,
        ("ne", v) => Test::Ne(one(v)?),
        ("lt" | "le" | "gt" | "ge", Json::Null) => {
            return Err(Refusal { code: refusal::TYPE, data: json!({"column": c.name, "filter": op, "reason": "compares with null"}) });
        }
        ("lt", v) => Test::Lt(one(v)?),
        ("le", v) => Test::Le(one(v)?),
        ("gt", v) => Test::Gt(one(v)?),
        ("ge", v) => Test::Ge(one(v)?),
        ("null", Json::Bool(true)) => Test::IsNull,
        ("null", Json::Bool(false)) => Test::NotNull,
        ("in", Json::Array(vs)) if vs.len() as u64 <= FIND_MAX => Test::In(vs.iter().map(one).collect::<Result<_, _>>()?),
        ("in", Json::Array(_)) => {
            return Err(Refusal { code: refusal::TOO_LARGE, data: json!({"column": c.name, "filter": "in", "max": FIND_MAX}) });
        }
        ("like" | "prefix", Json::String(s)) if s.len() > 1000 => {
            return Err(Refusal { code: refusal::TOO_LARGE, data: json!({"column": c.name, "filter": op, "max": 1000}) });
        }
        ("like", Json::String(s)) if text => Test::Like(s.to_ascii_lowercase()),
        ("prefix", Json::String(s)) if text => Test::Prefix(s.to_ascii_lowercase()),
        _ => return Err(Refusal { code: refusal::TYPE, data: json!({"column": c.name, "filter": brief(test)}) }),
    })
}

/// SQLite's LIKE: case folds ASCII only.
fn contains_ci(hay: &str, needle: &str) -> bool {
    needle.is_empty() || hay.as_bytes().windows(needle.len()).any(|w| w.eq_ignore_ascii_case(needle.as_bytes()))
}

fn holds(t: &Table, id: u32, f: &Filter) -> bool {
    let k = key_of(t, id, f.col);
    let ord = |v: &Key2| (!k.is_null()).then(|| k.cmp(v));
    match &f.test {
        Test::IsNull => k.is_null(),
        Test::NotNull => !k.is_null(),
        Test::Eq(v) => ord(v) == Some(Ordering::Equal),
        Test::Ne(v) => ord(v) != Some(Ordering::Equal),
        Test::Lt(v) => ord(v) == Some(Ordering::Less),
        Test::Le(v) => ord(v).is_some_and(|o| o != Ordering::Greater),
        Test::Gt(v) => ord(v) == Some(Ordering::Greater),
        Test::Ge(v) => ord(v).is_some_and(|o| o != Ordering::Less),
        Test::In(vs) => vs.iter().any(|v| ord(v) == Some(Ordering::Equal)),
        Test::Like(s) => k.text().is_some_and(|h| contains_ci(h, s)),
        Test::Prefix(s) => k.text().is_some_and(|h| h.len() >= s.len() && h.as_bytes()[..s.len()].eq_ignore_ascii_case(s.as_bytes())),
    }
}

fn cond_holds(tm: &TableModel, t: &Table, id: u32, w: &Cond) -> bool {
    let (Cond::Eq(c, _) | Cond::Null(c) | Cond::NotNull(c)) = w;
    let Some(c) = tm.col_named(c) else { return false };
    let k = key_of(t, id, c);
    match w {
        Cond::Null(_) => k.is_null(),
        Cond::NotNull(_) => !k.is_null(),
        Cond::Eq(_, v) => cast(c, &Json::String((*v).into())).is_some_and(|v| !k.is_null() && k.cmp(&v) == Ordering::Equal),
    }
}

// ------------------------------------------------------------------ find

fn order_param(g: &Grants, t: &TableModel, p: &Map<String, Json>) -> Result<(&'static Column, bool), Refusal> {
    let desc_flag = p.get("desc") == Some(&Json::Bool(true));
    let (name, desc) = match p.get("order") {
        Some(Json::Array(a)) if a.len() == 2 && a[1] == "desc" => (a.first().cloned(), true),
        Some(Json::Array(a)) if a.len() == 2 && a[1] == "asc" => (a.first().cloned(), false),
        Some(Json::Array(a)) if a.len() == 1 => (a.first().cloned(), desc_flag),
        None | Some(Json::Null) => (Some(Json::String("id".into())), desc_flag),
        Some(other) => (Some(other.clone()), desc_flag),
    };
    let c = column(g, t, name.as_ref())?;
    if has(c, flag::DEFERRED) || matches!(ty(c), Type::Json | Type::Bytes | Type::Text) {
        return Err(Refusal { code: refusal::COLUMN, data: json!({"table": t.name, "column": c.name, "reason": "not orderable"}) });
    }
    Ok((c, desc))
}

/// `[null?, value, id]` as JSON text: opaque to the caller.
fn cursor_of(t: &Table, id: u32, c: &Column) -> String {
    let v = if c.name == "id" { Json::from(id) } else { out(t, id, c) };
    json!([v.is_null(), v, id]).to_string()
}

fn decode_cursor(c: &Column, v: Option<&Json>) -> Result<Option<(Key2<'static>, u32)>, Refusal> {
    let bad = || Refusal { code: refusal::TYPE, data: json!({"param": "after"}) };
    let s = match v {
        None | Some(Json::Null) => return Ok(None),
        Some(Json::String(s)) => s,
        Some(_) => return Err(bad()),
    };
    let j: Json = serde_json::from_str(s).map_err(|_| bad())?;
    let a = j.as_array().filter(|a| a.len() == 3).ok_or_else(bad)?;
    let null = a[0].as_bool().ok_or_else(bad)?;
    let id = a[2].as_u64().filter(|n| *n <= INT64).ok_or_else(bad)?;
    if null != a[1].is_null() {
        return Err(bad());
    }
    let id = u32::try_from(id).unwrap_or(u32::MAX);
    if null {
        return Ok(Some((Key2::Null, id)));
    }
    let k = if c.name == "id" { Some(Key2::Int(id as i64)) } else { cast(c, &a[1]) };
    k.map(|k| Some((k, id))).ok_or_else(bad)
}

fn find(rows: &Rows, g: &Grants, p: &Map<String, Json>) -> Answer {
    let tm = readable(g, p.get("table"))?;
    let cols = columns(g, tm, p.get("cols"), false)?;
    let (order, desc) = order_param(g, tm, p)?;
    let limit = bound(p.get("limit"), FIND_LIMIT, FIND_MAX, "limit")? as usize;
    let fs = filters(g, tm, p.get("where"))?;
    let after = decode_cursor(order, p.get("after"))?;
    let Some(t) = rows.table(tm.id) else { return Ok(json!({"rows": [], "next": null})) };

    // Order by the column, nulls last both ways, then id the same way.
    let by = |a: &(Key2, u32), b: &(Key2, u32)| -> Ordering {
        let o = match (a.0.is_null(), b.0.is_null()) {
            (true, true) => Ordering::Equal,
            (true, false) => return Ordering::Greater,
            (false, true) => return Ordering::Less,
            _ => a.0.cmp(&b.0),
        };
        let o = if desc { o.reverse() } else { o };
        o.then_with(|| if desc { b.1.cmp(&a.1) } else { a.1.cmp(&b.1) })
    };
    let past = |k: &(Key2, u32)| -> bool {
        match &after {
            None => true,
            Some(c) => by(k, &(c.0.clone(), c.1)) == Ordering::Greater,
        }
    };
    let mut keys: Vec<(Key2, u32)> = t
        .ids()
        .iter()
        .copied()
        .filter(|&id| is_live(t, tm, id) && fs.iter().all(|f| holds(t, id, f)))
        .map(|id| (if order.name == "id" { Key2::Int(id as i64) } else { key_of(t, id, order) }, id))
        .filter(past)
        .collect();
    let page = keys.len().min(limit);
    if page > 0 && page < keys.len() {
        keys.select_nth_unstable_by(page - 1, by);
        keys.truncate(page);
    }
    keys.sort_by(by);
    let next = (keys.len() == limit).then(|| keys.last().map(|k| cursor_of(t, k.1, order))).flatten();
    let rows: Vec<Json> = keys.iter().map(|k| row_out(t, k.1, &cols, false)).collect();
    Ok(json!({"rows": rows, "next": next}))
}

// ------------------------------------------------------------------ get

fn get(rows: &Rows, g: &Grants, p: &Map<String, Json>) -> Answer {
    let tm = readable(g, p.get("table"))?;
    let cols = columns(g, tm, p.get("cols"), true)?;
    let found = match (p.get("id"), p.get("key")) {
        (Some(id), _) => {
            let id = id_param(Some(id))?;
            rows.table(tm.id).filter(|t| t.has(id) && is_live(t, tm, id)).map(|t| (t, id))
        }
        (None, Some(Json::Object(key))) if !key.is_empty() => {
            if key.values().any(|v| v.is_object() || v.is_array()) {
                return refuse(refusal::TYPE, json!({"table": tm.name, "key": "values, not filters"}));
            }
            let k = key_of_names(tm, key.keys())?;
            let fs = filters(g, tm, Some(&Json::Object(key.clone())))?;
            rows.table(tm.id).and_then(|t| {
                t.ids()
                    .iter()
                    .copied()
                    .find(|&id| is_live(t, tm, id) && fs.iter().all(|f| holds(t, id, f)) && k.1.is_none_or(|w| cond_holds(tm, t, id, w)))
                    .map(|id| (t, id))
            })
        }
        _ => return refuse(refusal::TYPE, json!({"table": tm.name, "need": "id or key"})),
    };
    match found {
        Some((t, id)) => Ok(json!({"row": row_out(t, id, &cols, true)})),
        None => refuse(refusal::NOT_FOUND, json!({"table": tm.name})),
    }
}

fn key_doc(k: &KeyDef) -> Json {
    let (w, reads) = match k.cond {
        Some(Cond::Eq(c, v)) => (Some(alloc::format!("{c} = '{v}'")), alloc::vec![c]),
        Some(Cond::Null(c)) => (Some(alloc::format!("{c} is null")), alloc::vec![c]),
        Some(Cond::NotNull(c)) => (Some(alloc::format!("{c} is not null")), alloc::vec![c]),
        None => (None, alloc::vec![]),
    };
    json!({"cols": k.cols, "where": w, "reads": reads})
}

/// The declared key made of exactly these columns, and its where: a
/// natural key, a unique, or a unique column.
fn key_of_names<'a>(tm: &TableModel, names: impl Iterator<Item = &'a String>) -> Result<(Vec<&'static str>, Option<&'static Cond>), Refusal> {
    let mut wanted: Vec<&str> = names.map(String::as_str).collect();
    wanted.sort_unstable();
    let declared = tm.keys.iter().map(|k| (k.cols.to_vec(), k.cond.as_ref()));
    let singles = tm.cols.iter().filter(|c| has(c, flag::UNIQUE)).map(|c| (alloc::vec![c.name], None));
    let all: Vec<(Vec<&'static str>, Option<&'static Cond>)> = declared.chain(singles).collect();
    all.iter()
        .find(|k| {
            let mut c = k.0.clone();
            c.sort_unstable();
            c == wanted
        })
        .cloned()
        .ok_or_else(|| Refusal {
            code: refusal::NATURAL_KEY,
            data: json!({
                "table": tm.name,
                "key": brief(&json!(wanted)),
                "reason": "no declared key is made of exactly these columns",
                "keys": tm.keys.iter().map(key_doc).collect::<Vec<_>>(),
            }),
        })
}

// ------------------------------------------------------------------ text

fn text(rows: &Rows, g: &Grants, p: &Map<String, Json>) -> Answer {
    let tm = readable(g, p.get("table"))?;
    let id = id_param(p.get("id"))?;
    let c = column(g, tm, p.get("column"))?;
    if !matches!(ty(c), Type::Text | Type::Str | Type::Json) {
        return refuse(refusal::COLUMN, json!({"table": tm.name, "column": c.name, "reason": "not text"}));
    }
    let offset = match p.get("offset") {
        None | Some(Json::Null) => 0,
        Some(v) => v.as_u64().filter(|n| *n <= INT64).ok_or_else(|| Refusal { code: refusal::TYPE, data: json!({"param": "offset", "got": brief(v)}) })?,
    };
    let length = bound(p.get("length"), CHUNK, CHUNK, "length")?;
    if offset + length + 4 > INT64 {
        return refuse(refusal::TOO_LARGE, json!({"param": "offset"}));
    }
    let Some(t) = rows.table(tm.id).filter(|t| t.has(id) && is_live(t, tm, id)) else {
        return refuse(refusal::NOT_FOUND, json!({"table": tm.name, "id": id}));
    };
    let Some(whole) = t.str(id, c.id) else {
        return Ok(json!({"text": null, "offset": offset, "next": null, "total": 0, "sha": null, "untrusted": true}));
    };
    let b = whole.as_bytes();
    let total = b.len() as u64;
    let start = offset.min(total) as usize;
    if offset > 0 && offset < total && (b[start] & 0xC0) == 0x80 {
        return refuse(refusal::TYPE, json!({"param": "offset", "reason": "inside a character"}));
    }
    // The chunk ends on a character boundary: at most three bytes past
    // `length` finish a character the limit would split.
    let want = (start + length as usize).min(b.len());
    let mut end = want;
    while end < b.len() && end < want + 3 && !whole.is_char_boundary(end) {
        end += 1;
    }
    while !whole.is_char_boundary(end) {
        end -= 1;
    }
    let chunk = &whole[start..end];
    let stop = (start + chunk.len()) as u64;
    Ok(json!({
        "text": chunk, "offset": offset, "next": (stop < total).then_some(stop),
        "total": total, "sha": sha8(whole), "untrusted": true,
    }))
}

// ------------------------------------------------------------------ history

fn history(rows: &Rows, g: &Grants, p: &Map<String, Json>) -> Answer {
    let tm = readable(g, p.get("table"))?;
    let id = id_param(p.get("id"))?;
    let only = match p.get("column") {
        None | Some(Json::Null) => None,
        name => Some(column(g, tm, name)?),
    };
    let limit = bound(p.get("limit"), HISTORY_LIMIT, HISTORY_MAX, "limit")? as usize;
    let before = match p.get("after") {
        None | Some(Json::Null) => None,
        v => Some(id_param(v)?),
    };
    let (Some(cm), Some(sm)) = (schema::table_def(schema::table::CITATIONS), schema::table_def(schema::table::SOURCES)) else {
        return Ok(json!({"citations": [], "next": null}));
    };
    let Some(ct) = rows.table(cm.id) else { return Ok(json!({"citations": [], "next": null})) };
    let cc = |n: &str| cm.col_named(n).unwrap_or_else(|| unreachable!("citations.{n}"));
    let (c_table, c_row, c_col) = (cc("table"), cc("row_id"), cc("column"));
    let visible: Vec<&str> = tm.cols.iter().filter(|c| g.visible(c)).map(|c| c.name).collect();
    let mut ids: Vec<u32> = ct
        .ids()
        .iter()
        .copied()
        .filter(|&cid| {
            before.is_none_or(|b| cid < b)
                && ct.str(cid, c_table.id) == Some(tm.name)
                && ct.u32(cid, c_row.id) == Some(id)
                && ct.str(cid, c_col.id).is_some_and(|n| visible.contains(&n) && only.is_none_or(|o| o.name == n))
        })
        .collect();
    ids.sort_unstable_by(|a, b| b.cmp(a));
    ids.truncate(limit);
    let st = rows.table(sm.id);
    let citations: Vec<Json> = ids
        .iter()
        .map(|&cid| {
            let f = |n: &str| out(ct, cid, cc(n));
            let source = cm.col_named("source_id").and_then(|c| ct.u32(cid, c.id)).and_then(|sid| {
                let s = st.filter(|s| s.has(sid))?;
                let sf = |n: &str| sm.col_named(n).map_or(Json::Null, |c| out(s, sid, c));
                Some(json!({
                    "id": sid, "url": sf("url"), "host": sf("host"), "publisher": sf("publisher"),
                    "title": sf("title"), "kind": sf("kind"), "dropped": !is_live(s, sm, sid),
                }))
            });
            json!({
                "id": cid, "column": f("column"), "value": f("value"), "as_of": f("as_of"), "actor": f("actor"),
                "key_id": f("key_id"), "op_id": f("op_id"), "at": f("inserted_at"), "source": source,
            })
        })
        .collect();
    let next = (citations.len() == limit).then(|| ids.last().copied()).flatten();
    Ok(json!({"citations": citations, "next": next}))
}
