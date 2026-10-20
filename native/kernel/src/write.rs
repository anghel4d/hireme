//! The checks every put and drop on a replicated table passes, from the
//! replica: the one judge of a write, for the browser's and hireme-mcp's
//! prediction and the sequencer's verdict alike (the NIF). Elixir keeps
//! grants, the lease, the text budget and the database's own constraints.
//!
//! In order, with the sequencer's refusals: locate (by id, a KEYED op's
//! natural key, or a singleton's row), shape (each cell writable and of
//! its column's type, required columns on an insert, refs to live rows, a
//! source's identity fixed), then after the domain rules provenance (a
//! metric needs `as_of`, prose an `expect_rev` and a source, `culture` and
//! the ratings a trusted host) and limits (uniques and caps). A put that
//! restates its row exactly yields no effects; one that changes cited
//! cells cites only those.

use alloc::string::String;
use alloc::vec::Vec;

use schema::{flag, refusal, table, ColDef, Cond, TableDef, Type};
use serde_json::{json, Value as Json};
use wire::{Op, Value};

use crate::judge::{cell_val, no, Ctx, EVal, Refusal, Row};
use crate::query::{cond_holds, enum_values, has, key_doc, live, ty, value_json};
use crate::rows::{Rows, Table, Val};
use crate::Day;

/// Past this a source URL is refused before any parsing.
const URL_MAX: usize = 2048;
/// Columns whose source must be on a trusted host.
const TRUSTED_ONLY: [&str; 4] = ["culture", "rating", "rating_count", "wlb_rating"];
/// A source's identity, fixed once written.
const FIXED: [&str; 5] = ["url", "host", "publisher", "title", "kind"];

/// Where a put lands: its table, and the row (0 for an insert).
pub(crate) struct Plan {
    pub td: &'static TableDef,
    pub target: u32,
}

/// A table an op may put to or drop from: replicated, or the server's.
fn writable_table(id: u16) -> Result<&'static TableDef, Refusal> {
    schema::table_def(id)
        .filter(|t| matches!(t.residency, schema::Residency::Resident | schema::Residency::Server))
        .ok_or_else(|| no(refusal::NOT_FOUND, json!({"table": id})))
}

/// An op carrying EXPECT_REV names the row's rev.
fn expect_rev(op: &Op, td: &TableDef, rev: i64) -> Result<(), Refusal> {
    if op.flags & wire::EXPECT_REV != 0 && op.expect_rev as i64 != rev { Err(no(refusal::REV, json!({"table": td.name, "rev": rev}))) } else { Ok(()) }
}

/// A metric's `_on` twin, the day its figure is as of.
fn twin<'t>(td: &'t TableDef, c: &ColDef) -> Option<&'t ColDef> {
    td.cols.iter().find(|x| has(x, flag::METRIC_ON) && x.name.strip_suffix("_on") == Some(c.name))
}

// ------------------------------------------------------------------ locate

/// Check 1 and 2: where the put lands and whether each cell may be written.
pub(crate) fn put_plan(rows: &Rows, op: &Op, ctx: &Ctx) -> Result<Plan, Refusal> {
    let td = writable_table(op.table)?;
    // A table no op writes a column of (citations) is the server's alone.
    if td.cols.iter().all(|c| has(c, flag::IMPLIED | flag::READONLY | flag::SERVER_ONLY)) {
        return Err(no(refusal::COLUMN, json!({"table": td.name, "reason": "the server writes this table"})));
    }
    let t = rows.table(op.table);
    let target = if op.flags & wire::KEYED != 0 {
        natural(t, td, op)?
    } else if op.target > 0 {
        if !t.is_some_and(|t| live(t, td, op.target)) {
            return Err(no(refusal::NOT_FOUND, json!({"table": td.name, "id": op.target})));
        }
        op.target
    } else if td.singleton {
        t.and_then(|t| t.ids().first().copied()).unwrap_or(0)
    } else {
        0
    };
    let insert = target == 0;
    if td.append_only && !insert {
        return Err(no(refusal::COLUMN, json!({"table": td.name, "reason": "append_only"})));
    }
    expect_rev(op, td, if insert { 0 } else { t.and_then(|t| t.i64(target, 3)).unwrap_or(0) })?;
    for cell in op.cells().filter(|c| c.col != schema::AS_OF && c.col != schema::SOURCE_CELL) {
        writable(td, td.col(cell.col), cell.col, &cell, ctx)?;
    }
    for cell in op.cells() {
        match cell.col {
            schema::AS_OF => {
                if !(cell.ty == wire::U32 && !cell.is_sentinel() && matches!(cell.value(), Value::U32(d) if d <= schema::DAY_MAX)) {
                    return Err(no(refusal::TYPE, json!({"column": "as_of", "want": "day"})));
                }
            }
            schema::SOURCE_CELL if cell.ty != wire::U32 && cell.ty != wire::STR => {
                return Err(no(refusal::TYPE, json!({"column": "source", "want": "source id or URL"})));
            }
            _ => {}
        }
    }
    if insert {
        let missing: Vec<&str> = td
            .cols
            .iter()
            .filter(|c| has(c, flag::REQUIRED) && !has(c, flag::IMPLIED | flag::READONLY) && c.default.is_none())
            .filter(|c| cell_val(op, c.id).is_none_or(|v| v.is_none()))
            .map(|c| c.name)
            .collect();
        if !missing.is_empty() {
            return Err(no(refusal::COLUMN, json!({"table": td.name, "missing": missing})));
        }
    }
    for c in td.cols.iter().filter(|c| ty(c) == Type::Ref && !has(c, flag::IMPLIED)) {
        if let Some(Val::U32(id)) = cell_val(op, c.id) {
            let target = c.target.and_then(|n| schema::TABLES.iter().find(|t| t.name == n));
            // A tombstone still exists for a ref, as the database's foreign key sees it.
            if !target.is_some_and(|tt| rows.table(tt.id).is_some_and(|r| r.has(id))) {
                return Err(no(refusal::NOT_FOUND, json!({"column": c.name, "id": id})));
            }
        }
    }
    if op.table == table::SOURCES {
        source_change(t.filter(|_| !insert).map(|t| (t, target)), td, op)?;
    }
    Ok(Plan { td, target })
}

fn writable(td: &TableDef, c: Option<&ColDef>, id: u16, cell: &wire::Cell, ctx: &Ctx) -> Result<(), Refusal> {
    let Some(c) = c else { return Err(no(refusal::COLUMN, json!({"table": td.name, "column": id}))) };
    if has(c, flag::IMPLIED | flag::READONLY | flag::SERVER_ONLY) {
        return Err(no(refusal::COLUMN, json!({"table": td.name, "column": c.name, "reason": "readonly"})));
    }
    if has(c, flag::PRIVATE) && !ctx.human {
        return Err(no(refusal::COLUMN, json!({"table": td.name, "column": c.name, "reason": "private"})));
    }
    typed(td, c, cell)
}

/// A cell of its column's type, as Codec.cell_to_value reads it; a null
/// (or an empty str in a str column) only where the column is nullable.
fn typed(td: &TableDef, c: &ColDef, cell: &wire::Cell) -> Result<(), Refusal> {
    let bad = || no(refusal::TYPE, json!({"in": td.name, "column": c.name, "want": ty(c).name()}));
    if cell.ty == wire::NULL || (cell.ty == wire::STR && cell.bytes.is_empty() && c.cell_type() == wire::STR) {
        return if has(c, flag::REQUIRED) {
            Err(no(refusal::COLUMN, json!({"in": td.name, "column": c.name, "reason": "required"})))
        } else {
            Ok(())
        };
    }
    if cell.ty != c.cell_type() || cell.is_sentinel() {
        return Err(bad());
    }
    let ok = match (ty(c), cell.value()) {
        (Type::U8, Value::U32(v)) => v <= 255,
        (Type::Bool, Value::U32(v)) => v <= 1,
        (Type::Day, Value::U32(v)) => v <= schema::DAY_MAX,
        (Type::Enum, Value::U32(v)) => (v as usize) < enum_values(c).len(),
        (Type::Json, Value::Str(s)) => serde_json::from_str::<Json>(s).is_ok() && !long_integer(s),
        _ => true,
    };
    if ok { Ok(()) } else { Err(bad()) }
}

/// A JSON integer past i64, as the server's decoder refuses it.
fn long_integer(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'"' {
            i += 1;
            while i < b.len() && b[i] != b'"' {
                i += if b[i] == b'\\' { 2 } else { 1 };
            }
        } else if b[i].is_ascii_digit() {
            let start = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            let float = matches!(b.get(i), Some(b'.' | b'e' | b'E'));
            let neg = start > 0 && b[start - 1] == b'-';
            let text = &s[start..i];
            if !float && (if neg { alloc::format!("-{text}").parse::<i64>().is_err() } else { text.parse::<i64>().is_err() }) {
                return true;
            }
            while i < b.len() && (b[i].is_ascii_digit() || matches!(b[i], b'.' | b'e' | b'E' | b'+' | b'-')) {
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    false
}

/// A KEYED op's row: the first natural key whose columns it gives all of
/// and whose where holds; 0 for a new row. CREATE_ONLY refuses one found.
fn natural(t: Option<&Table>, td: &TableDef, op: &Op) -> Result<u32, Refusal> {
    // As the sequencer: every cell typed first.
    for cell in op.cells() {
        if let Some(c) = td.col(cell.col)
            && typed(td, c, &cell).is_err()
        {
            return Err(no(refusal::TYPE, json!({"table": td.name, "column": c.name})));
        }
    }
    // A posting's URL keys as the judge stores it, however it was linked.
    let given = |c: &ColDef| match cell_val(op, c.id) {
        Some(Val::Str(u)) if td.id == schema::table::APPLICATIONS && c.name == "canonical_url" => Val::Str(crate::ats::canonical(&u).unwrap_or(u)),
        v => v.unwrap_or(Val::None),
    };
    let naturals = || td.keys.iter().filter(|k| k.natural);
    let key = naturals().find(|k| {
        k.cols.iter().all(|n| td.col_named(n).is_some_and(|c| !given(c).is_none())) && k.cond.as_ref().is_none_or(|w| cond_holds(td, &given, w))
    });
    let Some(key) = key else {
        let unmet: Vec<Json> = naturals()
            .filter(|k| k.cols.iter().all(|n| td.col_named(n).is_some_and(|c| !given(c).is_none())))
            .map(|k| {
                let mut d = key_doc(k);
                let reads: Vec<Json> = d["reads"].as_array().cloned().unwrap_or_default();
                let missing: Vec<Json> = reads.into_iter().filter(|r| r.as_str().and_then(|n| td.col_named(n)).is_none_or(|c| op.cell(c.id).is_none())).collect();
                d["missing"] = Json::Array(missing);
                d
            })
            .collect();
        return Err(no(
            refusal::NATURAL_KEY,
            json!({"table": td.name, "reason": "no natural key among the cells", "keys": naturals().map(key_doc).collect::<Vec<_>>(), "unmet": unmet}),
        ));
    };
    let found = t.and_then(|t| {
        t.ids().iter().copied().find(|&id| {
            live(t, td, id)
                && key.cols.iter().all(|n| td.col_named(n).is_some_and(|c| t.get(id, c.id) == given(c)))
                && key.cond.as_ref().is_none_or(|w| cond_holds(td, &|c| t.get(id, c.id), w))
        })
    });
    match found {
        Some(_) if op.flags & wire::CREATE_ONLY != 0 => {
            let k: serde_json::Map<String, Json> =
                key.cols.iter().filter_map(|n| td.col_named(n)).map(|c| (String::from(c.name), value_json(c, &given(c)))).collect();
            Err(no(refusal::NATURAL_KEY, json!({"table": td.name, "key": k})))
        }
        f => Ok(f.unwrap_or(0)),
    }
}

/// A source's URL is an http(s) link on a real hostname; its identity
/// (url, host, publisher, title, kind) is fixed once written.
fn source_change(row: Option<(&Table, u32)>, td: &TableDef, op: &Op) -> Result<(), Refusal> {
    let url = td.col_named("url").and_then(|c| cell_val(op, c.id));
    match row {
        None => match url {
            Some(Val::Str(u)) if u.len() > URL_MAX => Err(no(
                refusal::TYPE,
                json!({"table": "sources", "column": "url", "reason": "a source URL is at most 2048 bytes", "max": URL_MAX}),
            )),
            Some(Val::Str(u)) if host(&u).is_none() => {
                Err(no(refusal::TYPE, json!({"table": "sources", "column": "url", "reason": "an http(s) URL on a real hostname"})))
            }
            _ => Ok(()),
        },
        Some((t, id)) => match FIXED.iter().filter_map(|n| td.col_named(n)).find(|c| cell_val(op, c.id).is_some_and(|v| v != t.get(id, c.id))) {
            Some(c) => Err(no(refusal::COLUMN, json!({"table": "sources", "column": c.name, "reason": "a source's identity is fixed once written"}))),
            None => Ok(()),
        },
    }
}

/// The host of a URL as sources store it: lowercase, no port, no trailing
/// dot; `None` for anything a browser would open somewhere else.
pub fn host(url: &str) -> Option<String> {
    if url.len() > URL_MAX || url.chars().any(|c| c == '\\' || c.is_whitespace() || c.is_control()) {
        return None;
    }
    let (scheme, rest) = url.split_once("://")?;
    if !scheme.eq_ignore_ascii_case("http") && !scheme.eq_ignore_ascii_case("https") {
        return None;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // An empty userinfo is none (URI.parse); any other has no place here.
    let authority = match authority.split_once('@') {
        Some(("", host)) if !host.contains('@') => host,
        Some(_) => return None,
        None => authority,
    };
    let (h, port) = authority.split_once(':').map_or((authority, None), |(h, p)| (h, Some(p)));
    if let Some(p) = port.filter(|p| !p.is_empty()) {
        let digits = p.trim_start_matches('0');
        if !p.bytes().all(|b| b.is_ascii_digit()) || digits.len() > 5 || digits.parse::<u32>().unwrap_or(0) > 65_535 {
            return None;
        }
    }
    let h = h.to_lowercase();
    let h = h.trim_end_matches('.');
    let labels: Vec<&str> = h.split('.').collect();
    let ldh = |l: &&str| {
        let b = l.as_bytes();
        (1..=63).contains(&b.len())
            && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
            && b[0] != b'-'
            && b[b.len() - 1] != b'-'
    };
    let tld = labels.last()?;
    (h.len() <= 253 && labels.len() >= 2 && labels.iter().all(ldh) && tld.bytes().any(|b| b.is_ascii_lowercase()) && !tld.starts_with("0x"))
        .then(|| String::from(h))
}

// ------------------------------------------------------------------ provenance

/// The op's source: an existing live source's id, or a URL found by its
/// natural key or to be created (`Err(url, host)` until then).
type Source = Option<Result<u32, (String, String)>>;

fn source(rows: &Rows, op: &Op) -> Result<Source, Refusal> {
    let sd = schema::table_def(table::SOURCES).unwrap_or_else(|| unreachable!());
    let st = rows.table(table::SOURCES);
    match cell_val(op, schema::SOURCE_CELL) {
        None | Some(Val::None) => Ok(None),
        Some(Val::U32(id)) if st.is_some_and(|t| live(t, sd, id)) => Ok(Some(Ok(id))),
        Some(Val::U32(id)) => Err(no(refusal::SOURCE_MISSING, json!({"source": id}))),
        Some(Val::Str(u)) if u.len() > URL_MAX => {
            Err(no(refusal::TYPE, json!({"column": "source", "reason": "a source URL is at most 2048 bytes", "max": URL_MAX})))
        }
        Some(Val::Str(u)) => {
            let h = host(&u).ok_or_else(|| no(refusal::TYPE, json!({"column": "source", "reason": "an http(s) URL or a source id"})))?;
            let url_col = sd.col_named("url").map_or(0, |c| c.id);
            let found = st.and_then(|t| t.ids().iter().copied().find(|&id| live(t, sd, id) && t.str(id, url_col) == Some(u.as_str())));
            Ok(Some(found.ok_or((u, h))))
        }
        Some(_) => Err(no(refusal::TYPE, json!({"column": "source", "want": "source id or URL"}))),
    }
}

/// A host trusted directly or through a parent: trusting levels.fyi trusts
/// www.levels.fyi.
fn trusted(rows: &Rows, host: &str) -> bool {
    let Some(td) = schema::TABLES.iter().find(|t| t.name == "trusted") else { return false };
    let (Some(t), Some(c)) = (rows.table(td.id), td.col_named("host")) else { return false };
    let labels: Vec<&str> = host.split('.').collect();
    (0..labels.len().saturating_sub(1).max(1)).any(|i| {
        let h = labels[i..].join(".");
        t.ids().iter().any(|&id| t.str(id, c.id) == Some(h.as_str()))
    })
}

/// Check 5, provenance, on the cells the effects put on the op's own row
/// (the last effect row): `<metric>_on` moved to `as_of`, the citations
/// added, a new source inserted first; a restatement clears the effects.
pub(crate) fn provenance(rows: &Rows, op: &Op, ctx: &Ctx, plan: &Plan, effects: &mut Vec<Row>) -> Result<(), Refusal> {
    let td = plan.td;
    let Some(own) = effects.iter().rposition(|r| r.table == td.id && r.id == plan.target) else { return Ok(()) };
    let cited: Vec<&ColDef> = effects[own].cells.iter().filter_map(|(c, _)| td.col(*c)).filter(|c| has(c, flag::METRIC | flag::PROSE)).collect();
    let t = rows.table(td.id).filter(|_| plan.target != 0);
    let stored = |c: &ColDef| t.map_or(Val::None, |t| t.get(plan.target, c.id));
    let restated = |c: u16, v: &EVal, src: &Source, as_of: Option<Day>| -> bool {
        let Some(col) = td.col(c) else { return false };
        let same = |v: &Val| match (ty(col), v, stored(col)) {
            (Type::Json, Val::Str(a), Val::Str(b)) => serde_json::from_str::<Json>(a).ok().is_some_and(|a| serde_json::from_str::<Json>(&b).ok() == Some(a)),
            (_, v, s) => *v == s,
        };
        matches!(v, EVal::Val(v) if t.is_some() && same(v)) && (!has(col, flag::METRIC | flag::PROSE) || same_citation(rows, td, plan.target, col, src, as_of))
    };
    if cited.is_empty() {
        if op.verb == wire::PUT && t.is_some() && effects.len() == 1 && effects[own].cells.iter().all(|(c, v)| restated(*c, v, &None, None)) {
            effects.clear();
        }
        return Ok(());
    }
    let as_of = match cell_val(op, schema::AS_OF) {
        Some(Val::U32(d)) => Some(d as Day),
        _ => None,
    };
    if as_of.is_some_and(|d| d > ctx.today + 1) {
        return Err(no(refusal::FRESHNESS, json!({"column": "as_of", "reason": "in the future"})));
    }
    let src = source(rows, op)?;
    let src_host = match &src {
        Some(Ok(id)) => schema::table_def(table::SOURCES)
            .and_then(|sd| sd.col_named("host"))
            .and_then(|c| rows.table(table::SOURCES)?.str(*id, c.id).map(String::from)),
        Some(Err((_, h))) => Some(h.clone()),
        None => None,
    };
    let rev = t.and_then(|t| t.i64(plan.target, 3)).unwrap_or(0);
    for c in &cited {
        if has(c, flag::METRIC) {
            let Some(on) = as_of else { return Err(no(refusal::FRESHNESS, json!({"table": td.name, "column": c.name}))) };
            if let Some(Val::U32(was)) = twin(td, c).map(&stored)
                && on < was as Day
            {
                return Err(no(refusal::STALE, json!({"table": td.name, "column": c.name, "on": crate::day_iso(was as Day)})));
            }
        } else if op.flags & wire::EXPECT_REV == 0 || op.expect_rev as i64 != rev {
            return Err(no(refusal::REV, json!({"table": td.name, "column": c.name, "rev": rev})));
        } else if src.is_none() {
            return Err(no(refusal::SOURCE_MISSING, json!({"table": td.name, "column": c.name})));
        }
        if TRUSTED_ONLY.contains(&c.name) {
            match &src_host {
                None => return Err(no(refusal::SOURCE_MISSING, json!({"table": td.name, "column": c.name}))),
                Some(h) if !trusted(rows, h) => return Err(no(refusal::SOURCE_TRUST, json!({"table": td.name, "column": c.name, "host": h}))),
                _ => {}
            }
        }
    }
    // A restatement writes nothing; a changed write cites only its changes.
    let fresh: Vec<(u16, EVal)> = effects[own].cells.iter().filter(|(c, v)| !restated(*c, v, &src, as_of)).cloned().collect();
    if op.verb == wire::PUT && t.is_some() && effects.len() == 1 && fresh.is_empty() {
        effects.clear();
        return Ok(());
    }
    for c in cited.iter().filter(|c| has(c, flag::METRIC)) {
        if let (Some(on), Some(twin)) = (as_of, twin(td, c)) {
            effects[own].cells.push((twin.id, EVal::Val(Val::U32(on as u32))));
        }
    }
    if let Some(Err((url, h))) = &src {
        // A new source's id is the first insert's: every New(k) before
        // moves up one.
        for r in effects.iter_mut() {
            for (_, v) in r.cells.iter_mut() {
                if let EVal::New(k) = v {
                    *k += 1;
                }
            }
        }
        let sd = schema::table_def(table::SOURCES).unwrap_or_else(|| unreachable!());
        let set = |n: &str, v: Val| sd.col_named(n).map(|c| (c.id, EVal::Val(v)));
        let cells = [set("url", Val::Str(url.clone())), set("host", Val::Str(h.clone())), set("mutable", Val::U32(1))].into_iter().flatten().collect();
        effects.insert(0, Row { table: table::SOURCES, id: 0, cells });
    }
    let own = effects.iter().rposition(|r| r.table == td.id && r.id == plan.target).unwrap_or(0);
    let row_ref = if plan.target != 0 {
        EVal::Val(Val::U32(plan.target))
    } else {
        EVal::New(effects[..own].iter().filter(|r| r.id == 0).count() as u32)
    };
    let source_ref = match src {
        Some(Ok(id)) => EVal::Val(Val::U32(id)),
        Some(Err(_)) => EVal::New(0),
        None => EVal::Val(Val::None),
    };
    let cd = schema::table_def(table::CITATIONS).unwrap_or_else(|| unreachable!());
    let actor = schema::enums::actor::NAMES.iter().position(|n| *n == if ctx.human { "operator" } else { "agent" }).unwrap_or(0) as u32;
    let mut citations = Vec::new();
    for (c, v) in fresh.iter().filter(|(c, _)| td.col(*c).is_some_and(|c| has(c, flag::METRIC | flag::PROSE))) {
        let Some(col) = td.col(*c) else { continue };
        let value = match v {
            EVal::Val(v) => value_json(col, v),
            EVal::New(_) => Json::Null,
        };
        let on = if has(col, flag::METRIC) { as_of } else { as_of.or(Some(ctx.today)) };
        let set = |n: &str, v: EVal| cd.col_named(n).map(|c| (c.id, v));
        let cells = [
            set("table", EVal::Val(Val::Str(td.name.into()))),
            set("row_id", row_ref.clone()),
            set("column", EVal::Val(Val::Str(col.name.into()))),
            set("source_id", source_ref.clone()),
            set("value", EVal::Val(Val::Str(json!({"v": value}).to_string()))),
            set("as_of", EVal::Val(on.map_or(Val::None, |d| Val::U32(d as u32)))),
            set("actor", EVal::Val(Val::U32(actor))),
            set("key_id", EVal::Val(ctx.key_id.map_or(Val::None, Val::U32))),
            set("op_id", EVal::Val(Val::I64(op.op_id as i64))),
        ];
        citations.push(Row { table: table::CITATIONS, id: 0, cells: cells.into_iter().flatten().collect() });
    }
    effects.extend(citations);
    Ok(())
}

/// The same citation again: the cell's last citation names the same
/// source, and the same date (a metric's `_on`; prose only an explicit one).
fn same_citation(rows: &Rows, td: &TableDef, id: u32, col: &ColDef, src: &Source, as_of: Option<Day>) -> bool {
    let source = match src {
        Some(Ok(s)) => Some(*s),
        Some(Err(_)) => return false,
        None => None,
    };
    let Some(cd) = schema::table_def(table::CITATIONS) else { return false };
    let Some(ct) = rows.table(cd.id) else { return false };
    let c = |n: &str| cd.col_named(n).map_or(0, |c| c.id);
    let (tc, cc) = (c("table"), c("column"));
    let last = ct
        .ids()
        .iter()
        .zip(ct.u32s(c("row_id")).unwrap_or(&[]))
        .filter(|(_, r)| **r == id)
        .map(|(x, _)| *x)
        .filter(|&x| ct.str(x, tc) == Some(td.name) && ct.str(x, cc) == Some(col.name))
        .max();
    let Some(last) = last else { return false };
    let dated = if has(col, flag::METRIC) {
        twin(td, col).and_then(|tw| rows.table(td.id)?.u32(id, tw.id)).map(|d| d as Day) == as_of
    } else {
        as_of.is_none_or(|d| ct.u32(last, c("as_of")) == Some(d as u32))
    };
    dated && ct.u32(last, c("source_id")) == source
}

// ------------------------------------------------------------------ limits

/// Check 6: no table passes its cap, and no live row of the table already
/// holds a unique key the write makes.
pub(crate) fn limits(rows: &Rows, effects: &[Row]) -> Result<(), Refusal> {
    // The cap first, then the keys, as the sequencer met them; tables in
    // write order.
    let mut inserts: Vec<(u16, usize)> = Vec::new();
    for r in effects.iter().filter(|r| r.id == 0) {
        match inserts.iter_mut().find(|x| x.0 == r.table) {
            Some(x) => x.1 += 1,
            None => inserts.push((r.table, 1)),
        }
    }
    for (tid, n) in inserts {
        let Some(td) = schema::table_def(tid) else { continue };
        if let Some(cap) = td.cap {
            let have = rows.table(tid).map_or(0, |t| if td.soft_delete { t.ids().iter().filter(|&&id| live(t, td, id)).count() } else { t.len() });
            if have + n > cap as usize {
                return Err(no(refusal::CAP, json!({"table": td.name, "cap": cap})));
            }
        }
    }
    for r in effects {
        let Some(td) = schema::table_def(r.table) else { continue };
        let t = rows.table(r.table);
        let after = |c: &ColDef| -> Val {
            match r.cells.iter().find(|x| x.0 == c.id) {
                Some((_, EVal::Val(v))) => v.clone(),
                Some((_, EVal::New(_))) => Val::None,
                None if r.id != 0 => t.map_or(Val::None, |t| t.get(r.id, c.id)),
                None => Val::None,
            }
        };
        let singles: Vec<[&str; 1]> = td.cols.iter().filter(|c| has(c, flag::UNIQUE)).map(|c| [c.name]).collect();
        let keys = td.keys.iter().filter(|k| !k.global).map(|k| (k.cols, k.cond.as_ref())).chain(singles.iter().map(|s| (&s[..], None)));
        for (cols, cond) in keys {
            let cs: Vec<&ColDef> = cols.iter().filter_map(|n| td.col_named(n)).collect();
            let cond_col = cond.and_then(|(Cond::Eq(n, _) | Cond::Null(n) | Cond::NotNull(n))| td.col_named(n));
            let touched = cs.iter().chain(cond_col.iter()).any(|c| r.cells.iter().any(|x| x.0 == c.id));
            if !touched || cs.iter().any(|c| after(c).is_none()) || cond.is_some_and(|w| !cond_holds(td, &after, w)) {
                continue;
            }
            let clash = t.is_some_and(|t| {
                t.ids().iter().any(|&id| {
                    id != r.id
                        && live(t, td, id)
                        && cs.iter().all(|c| t.get(id, c.id) == after(c))
                        && cond.is_none_or(|w| cond_holds(td, &|c| t.get(id, c.id), w))
                })
            });
            if clash {
                return Err(no(refusal::NATURAL_KEY, json!({"reason": "a unique column already holds this value"})));
            }
        }
    }
    Ok(())
}

// ------------------------------------------------------------------ drops

/// A drop's checks, as the sequencer's: the row lives, its rev is the one
/// expected, its table is not append-only, and a key never drops a row a
/// loose ref names (a cited source: provenance outlives it). The server
/// sends any drop as gone, a tombstone too, so the replica removes it.
pub(crate) fn drop_checks(rows: &Rows, op: &Op, ctx: &Ctx) -> Result<(), Refusal> {
    let td = writable_table(op.table)?;
    let Some(t) = rows.table(op.table).filter(|t| live(t, td, op.target)) else {
        return Err(no(refusal::NOT_FOUND, json!({"table": td.name, "id": op.target})));
    };
    expect_rev(op, td, t.i64(op.target, 3).unwrap_or(0))?;
    if td.append_only {
        return Err(no(refusal::COLUMN, json!({"table": td.name, "reason": "append_only"})));
    }
    let named = schema::TABLES.iter().any(|o| {
        o.cols.iter().filter(|c| has(c, flag::LOOSE) && c.target == Some(td.name)).any(|c| {
            rows.table(o.id).is_some_and(|t| t.ids().iter().any(|&id| t.u32(id, c.id) == Some(op.target)))
        })
    });
    if named && !ctx.human {
        return Err(no(refusal::SCOPE, json!({"table": td.name, "reason": "cited; provenance outlives it"})));
    }
    Ok(())
}
