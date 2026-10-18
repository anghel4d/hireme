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
//! as SQLite's LIKE; texts are whole in the replica, so `find` and `get`
//! return them as any str and `text` chunks one; a soft-deleted row is
//! passed over by every read but `history`, whose citations still name it.

use alloc::borrow::Cow;
use alloc::string::String;
use alloc::vec::Vec;
use core::cmp::Ordering;
use schema::{flag, refusal, ColDef as Column, Cond, KeyDef, Residency, TableDef as TableModel, Type, TYPES};
use serde_json::{json, Map, Value as Json};

use crate::judge::Refusal;
use crate::rows::{Data, Moved, Rows, Table, Val};

const FIND_LIMIT: u64 = 50;
const FIND_MAX: u64 = 500;
const HISTORY_LIMIT: u64 = 50;
const HISTORY_MAX: u64 = 200;
const CHUNK: u64 = 256 * 1024;
const INT64: u64 = i64::MAX as u64;

pub(crate) fn has(c: &Column, f: u32) -> bool {
    c.flags & f != 0
}

pub(crate) fn ty(c: &Column) -> Type {
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
    /// Nothing, until the session's WELCOME says otherwise.
    fn default() -> Self {
        Grants { human: false, read_mask: 0, write_mask: 0, may_delete: false }
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

/// Ids of one table in one column's order: the non-null by value then id,
/// then the nulls by id. Built on a find's first use, kept as rows move.
#[derive(Default)]
pub struct Indexes {
    by: alloc::collections::BTreeMap<(u16, u16), (Vec<u32>, usize)>,
}

/// Past this many rows moved in one table its indexes are rebuilt, not mended.
const MEND_MAX: usize = 256;

impl Indexes {
    /// Mends or drops what the move touched.
    pub fn moved(&mut self, m: &Moved, rows: &Rows) {
        let stale: Vec<(u16, u16)> = self.by.keys().copied().filter(|(t, _)| m.touched(*t)).collect();
        for key in stale {
            let (tid, col) = key;
            let moved = m.tables.get(&tid);
            let mendable = !m.replaced.contains(&tid) && moved.is_some_and(|(w, g)| w.len() + g.len() <= MEND_MAX);
            let (Some(t), Some(c), true) = (rows.table(tid), schema::table_def(tid).and_then(|d| d.col(col)), mendable) else {
                self.by.remove(&key);
                continue;
            };
            let Some((wrote, gone)) = moved else { continue };
            let Some((ids, nn)) = self.by.get_mut(&key) else { continue };
            // A merged move (a PATCH, then a rollback) may name a row twice:
            // every entry of a touched row goes, and each live one returns once.
            let mut touched: Vec<u32> = wrote.iter().chain(gone).copied().collect();
            touched.sort_unstable();
            touched.dedup();
            let kept_nn = ids[..*nn].iter().filter(|x| touched.binary_search(x).is_err()).count();
            ids.retain(|x| touched.binary_search(x).is_err());
            *nn = kept_nn;
            let cells = Cells::new(t, c);
            for &id in &touched {
                let Some(slot) = t.slot(id) else { continue };
                let k = cells.key(slot);
                if k.is_null() {
                    let at = *nn + ids[*nn..].partition_point(|x| *x < id);
                    ids.insert(at, id);
                } else {
                    let at = ids[..*nn].partition_point(|x| t.slot(*x).is_some_and(|s| cells.key(s).cmp(&k).then(x.cmp(&id)) == Ordering::Less));
                    ids.insert(at, id);
                    *nn += 1;
                }
            }
        }
    }

    pub fn clear(&mut self) {
        self.by.clear();
    }

    fn get(&mut self, t: &Table, c: &'static Column) -> &(Vec<u32>, usize) {
        self.by.entry((t.id, c.id)).or_insert_with(|| {
            let cells = Cells::new(t, c);
            let (mut keyed, mut nulls): (Vec<(Key2, u32)>, Vec<u32>) = (Vec::new(), Vec::new());
            for (s, &id) in t.ids().iter().enumerate() {
                match cells.key(s) {
                    Key2::Null => nulls.push(id),
                    k => keyed.push((k, id)),
                }
            }
            keyed.sort_unstable_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
            nulls.sort_unstable();
            let nn = keyed.len();
            let mut ids: Vec<u32> = keyed.into_iter().map(|k| k.1).collect();
            ids.extend(nulls);
            (ids, nn)
        })
    }
}

/// One read: `{"op": "find" | "get" | "text" | "history", ...params}`.
pub fn query(rows: &Rows, g: &Grants, idx: &mut Indexes, req: &Json) -> Answer {
    let Some(p) = req.as_object() else { return refuse(refusal::TYPE, json!({"params": brief(req)})) };
    match p.get("op").and_then(Json::as_str) {
        Some("find") => find(rows, g, idx, p),
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
    // A replicated table reads whether or not any row arrived. The system
    // domain's views (acct_*) are the operator's alone; server tables (the
    // account's secrets) never replicate.
    match schema::TABLES.iter().find(|t| t.name == name) {
        Some(t) if t.residency != Residency::Server => {
            let bit = t.domain_bit;
            if bit == 0 && g.human && t.residency != Residency::Resident {
                Ok(t)
            } else if bit == 0 {
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
        // Past u64 a number reads as a float: still a too-large integer.
        Some(Json::Number(n)) if n.as_u64().is_some_and(|n| n > max) || n.as_f64().is_some_and(|f| f >= u64::MAX as f64) => {
            let mut d = json!({"limit": n, "max": max});
            if name != "limit" {
                d["param"] = name.into();
            }
            Err(Refusal { code: refusal::TOO_LARGE, data: d })
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

pub(crate) fn enum_values(c: &Column) -> &'static [&'static str] {
    c.target.and_then(schema::enum_names).unwrap_or(&[])
}

/// The value of a row's cell for comparing.
/// A column's storage, resolved once per read: its cells by slot, with no
/// lookup per row.
struct Cells<'a> {
    c: &'static Column,
    data: Option<&'a Data>,
}

impl<'a> Cells<'a> {
    fn new(t: &'a Table, c: &'static Column) -> Cells<'a> {
        Cells { c, data: t.column(c.id).map(|x| &x.data) }
    }

    fn key(&self, slot: usize) -> Key2<'a> {
        match (ty(self.c), self.data) {
            (Type::Enum, Some(Data::U32(v))) => match v[slot] {
                wire::NONE => Key2::Null,
                x => enum_values(self.c).get(x as usize).map_or(Key2::Null, |n| Key2::Str(Cow::Borrowed(n))),
            },
            (_, Some(Data::U32(v))) => if v[slot] == wire::NONE { Key2::Null } else { Key2::Int(v[slot] as i64) },
            (_, Some(Data::I64(v))) => if v[slot] == wire::NONE64 { Key2::Null } else { Key2::Int(v[slot]) },
            (_, Some(Data::F64(v))) => if v[slot].is_nan() { Key2::Null } else { Key2::Float(v[slot]) },
            (_, Some(Data::Str(v))) => if v[slot].is_empty() { Key2::Null } else { Key2::Str(Cow::Borrowed(v[slot].as_str())) },
            (_, Some(Data::Packed(v))) => crate::rows::unpack(&v[slot]).map_or(Key2::Null, Key2::Str),
            _ => Key2::Null,
        }
    }
}

fn key_of<'a>(t: &'a Table, id: u32, c: &'static Column) -> Key2<'a> {
    t.slot(id).map_or(Key2::Null, |s| Cells::new(t, c).key(s))
}

/// Whether row `id` is in `t` and not a tombstone (`deleted_at` set).
pub(crate) fn live(t: &Table, tm: &TableModel, id: u32) -> bool {
    t.has(id) && (!tm.soft_delete || tm.col_named("deleted_at").is_none_or(|c| t.u32(id, c.id).is_none()))
}

/// A cell as World's JSON shows it.
fn out(t: &Table, id: u32, c: &Column) -> Json {
    value_json(c, &t.get(id, c.id))
}

/// A value of a column as JSON: enums by name, bools, days and times ISO.
pub(crate) fn value_json(c: &Column, v: &Val) -> Json {
    match (ty(c), v) {
        (_, Val::None) => Json::Null,
        (Type::Enum, Val::U32(v)) => enum_values(c).get(*v as usize).map_or(Json::Null, |n| Json::String((*n).into())),
        (Type::Bool, Val::U32(b)) => Json::Bool(*b == 1),
        (Type::Day, Val::U32(d)) => crate::day_iso(*d as crate::Day).into(),
        (Type::Time, Val::U32(s)) => crate::time_iso(*s as i64).into(),
        (Type::Time, Val::I64(s)) => crate::time_iso(*s).into(),
        (Type::Json, Val::Str(s)) => serde_json::from_str(s).unwrap_or_else(|_| Json::String(s.clone())),
        _ => v.json(),
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
        Type::I64 => int(v).filter(|n| *n != i64::MIN).map(Key2::Int),
        Type::F64 => match v {
            Json::Number(n) => n.as_f64().map(Key2::Float),
            Json::String(s) if decimal(s) => s.parse::<f64>().ok().filter(|f| f.is_finite()).map(Key2::Float),
            _ => None,
        },
        Type::Bool => match v {
            Json::Bool(b) => Some(Key2::Int(*b as i64)),
            Json::String(s) if s == "true" || s == "1" => Some(Key2::Int(1)),
            Json::String(s) if s == "false" || s == "0" => Some(Key2::Int(0)),
            _ => None,
        },
        // As Ecto casts a date: an extended year's sign, or a datetime's date.
        Type::Day => v.as_str().map(|s| s.strip_prefix('+').unwrap_or(s)).and_then(|s| match s.len() {
            10 => crate::iso_day(s),
            _ => crate::iso_time(s).and_then(|_| crate::iso_day(s.get(..10)?)),
        }).map(|d| Key2::Int(d as i64)),
        Type::Time => v.as_str().and_then(crate::iso_time).map(Key2::Int),
        Type::Enum => v.as_str().filter(|s| enum_values(c).contains(s)).map(|s| Key2::Str(Cow::Owned(s.into()))),
        Type::Str | Type::Text => v.as_str().map(|s| Key2::Str(Cow::Owned(s.into()))),
        _ => None,
    }
}

/// A float as Elixir's Float.parse reads the whole of it: a sign, digits,
/// a fraction with digits, an exponent.
fn decimal(s: &str) -> bool {
    let b = s.strip_prefix(['+', '-']).unwrap_or(s).as_bytes();
    let digits = |b: &[u8]| b.iter().take_while(|c| c.is_ascii_digit()).count();
    let n = digits(b);
    let mut rest = &b[n..];
    if let [b'.', f @ ..] = rest {
        let m = digits(f);
        if m == 0 {
            return false;
        }
        rest = &f[m..];
    }
    if let [b'e' | b'E', e @ ..] = rest {
        let e = e.strip_prefix(b"+").or_else(|| e.strip_prefix(b"-")).unwrap_or(e);
        let m = digits(e);
        if m == 0 {
            return false;
        }
        rest = &e[m..];
    }
    n > 0 && rest.is_empty()
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
        if matches!(ty(c), Type::Json | Type::Bytes) {
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
        Json::Object(_) => return Err(Refusal { code: refusal::TYPE, data: json!({"column": c.name, "filter": brief(test)}) }),
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
        // A null in the list matches nothing, as SQL's IN reads it.
        ("in", Json::Array(vs)) if vs.len() as u64 <= FIND_MAX => Test::In(vs.iter().filter(|v| !v.is_null()).map(one).collect::<Result<_, _>>()?),
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

fn holds(t: &Table, id: u32, f: &Filter<'static>) -> bool {
    test(&key_of(t, id, f.col), &f.test)
}

fn test(k: &Key2, t: &Test) -> bool {
    let ord = |v: &Key2| (!k.is_null()).then(|| k.cmp(v));
    match t {
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

/// Whether a key's where holds on a row read through `value`.
pub(crate) fn cond_holds(td: &TableModel, value: &dyn Fn(&Column) -> Val, c: &Cond) -> bool {
    let (Cond::Eq(n, _) | Cond::Null(n) | Cond::NotNull(n)) = c;
    let Some(col) = td.col_named(n) else { return false };
    let v = value(col);
    match c {
        Cond::Null(_) => v.is_none(),
        Cond::NotNull(_) => !v.is_none(),
        Cond::Eq(_, want) => match (ty(col), &v) {
            (Type::Enum, Val::U32(x)) => enum_values(col).get(*x as usize) == Some(want),
            (_, Val::Str(s)) => s == want,
            (_, Val::U32(x)) => want.parse() == Ok(*x),
            _ => false,
        },
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
    if matches!(ty(c), Type::Json | Type::Bytes | Type::Text) {
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

fn find(rows: &Rows, g: &Grants, idx: &mut Indexes, p: &Map<String, Json>) -> Answer {
    let tm = readable(g, p.get("table"))?;
    let mut cols = columns(g, tm, p.get("cols"), false)?;
    // `sizes`: text columns answered as their byte length, never their text
    // (a grid shows a size; the reader asks get for the text).
    let sizes = match p.get("sizes") {
        None | Some(Json::Null) => Vec::new(),
        Some(Json::Array(names)) => names.iter().map(|n| column(g, tm, Some(n))).collect::<Result<Vec<_>, _>>()?,
        Some(other) => return refuse(refusal::TYPE, json!({"table": tm.name, "sizes": brief(other)})),
    };
    if let Some(c) = sizes.iter().find(|c| !matches!(ty(c), Type::Str | Type::Text | Type::Json)) {
        return refuse(refusal::COLUMN, json!({"table": tm.name, "column": c.name, "reason": "not text"}));
    }
    cols.retain(|x| !sizes.iter().any(|c| c.id == x.id));
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
    let past = |k: &(Key2, u32)| after.as_ref().is_none_or(|c| by(k, c) == Ordering::Greater);
    // Walk the column's index in the asked order from the cursor, testing
    // rows until the page is full: a page touches about as many rows as it
    // shows, unless a filter rejects most of them.
    let tests: Vec<(Cells, &Test)> = fs.iter().map(|f| (Cells::new(t, f.col), &f.test)).collect();
    let deleted = tm.col_named("deleted_at").filter(|_| tm.soft_delete).map(|c| Cells::new(t, c));
    let ord = Cells::new(t, order);
    let (ids, nn) = idx.get(t, order);
    let key = |id: u32| -> (Key2, u32) { (t.slot(id).map_or(Key2::Null, |s| ord.key(s)), id) };
    let mut keys: Vec<(Key2, u32)> = Vec::with_capacity(limit);
    for part in [&ids[..*nn], &ids[*nn..]] {
        let at = |j: usize| if desc { part[part.len() - 1 - j] } else { part[j] };
        let (mut lo, mut hi) = (0, part.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            if past(&key(at(mid))) { hi = mid } else { lo = mid + 1 }
        }
        for j in lo..part.len() {
            if keys.len() == limit {
                break;
            }
            let id = at(j);
            let Some(s) = t.slot(id) else { continue };
            if deleted.as_ref().is_none_or(|d| d.key(s).is_null()) && tests.iter().all(|(c, x)| test(&c.key(s), x)) {
                keys.push(key(id));
            }
        }
    }
    let next = (keys.len() == limit).then(|| keys.last().map(|k| cursor_of(t, k.1, order))).flatten();
    let rows: Vec<Json> = keys
        .iter()
        .map(|k| {
            let mut r = row_out(t, k.1, &cols, false);
            for c in &sizes {
                r[c.name] = t.text_len(k.1, c.id).map_or(Json::Null, Json::from);
            }
            r
        })
        .collect();
    Ok(json!({"rows": rows, "next": next}))
}

// ------------------------------------------------------------------ get

fn get(rows: &Rows, g: &Grants, p: &Map<String, Json>) -> Answer {
    let tm = readable(g, p.get("table"))?;
    let cols = columns(g, tm, p.get("cols"), true)?;
    let found = match (p.get("id"), p.get("key")) {
        (Some(id), _) => {
            let id = id_param(Some(id))?;
            rows.table(tm.id).filter(|t| live(t, tm, id)).map(|t| (t, id))
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
                    .find(|&id| live(t, tm, id) && fs.iter().all(|f| holds(t, id, f)) && k.1.is_none_or(|w| cond_holds(tm, &|c| t.get(id, c.id), w)))
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

pub(crate) fn key_doc(k: &KeyDef) -> Json {
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
    let Some(t) = rows.table(tm.id).filter(|t| live(t, tm, id)) else {
        return refuse(refusal::NOT_FOUND, json!({"table": tm.name, "id": id}));
    };
    let Some(whole) = t.text(id, c.id) else {
        return Ok(json!({"text": null, "offset": offset, "next": null, "total": 0, "untrusted": true}));
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
        "total": total, "untrusted": true,
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
    // The row id first, by slot: a scan of one u32 column, then the few rows it keeps.
    let row_ids = ct.u32s(c_row.id).unwrap_or(&[]);
    let mut ids: Vec<u32> = ct
        .ids()
        .iter()
        .zip(row_ids)
        .filter(|(_, r)| **r == id)
        .map(|(cid, _)| *cid)
        .filter(|&cid| {
            before.is_none_or(|b| cid < b)
                && ct.str(cid, c_table.id) == Some(tm.name)
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
                    "title": sf("title"), "kind": sf("kind"), "dropped": !live(s, sm, sid),
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
