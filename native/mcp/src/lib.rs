//! hireme's MCP surface, which the node serves over HTTP (`HiremeWeb.Mcp`)
//! through the NIF: the tools a key's masks list, a table's description,
//! refusals as diagnostics, a call's writes encoded as OPS ops the
//! sequencer judges, resources by URI, and which rows a PATCH moved. The
//! node holds the session, the lease and the rows; this crate holds only
//! what the protocol says, so it is the one copy of it.

pub mod diag;
pub mod mission;
pub mod tools;

use std::collections::HashSet;

use schema::{CommandDef, TableDef, flag};
use serde_json::{Value as Json, json};
use tools::{Field, Masks};

/// What a blank call prints: the call's shape.
pub fn shape(tool: &str) -> Option<String> {
    Some(match tool {
        "find" => r#"{"table":"corporations","where":{"name":{"prefix":"Acme"}},"order":["headcount","desc"],"limit":20}  or  {"table":"applications","search":"berlin","min_score":60,"sort":["score","desc"],"group":"company","limit":20}"#.into(),
        "get" => r#"{"table":"corporations","key":{"domain":"example.com"}}  or  {"table":"applications","id":12}"#.into(),
        "text" => r#"{"table":"applications","id":12,"column":"listing_raw","offset":0,"length":65536}"#.into(),
        "history" => r#"{"table":"places","id":7,"column":"population"}"#.into(),
        "put" => r#"{"table":"corporations","key":{"domain":"example.com"},"set":{"name":"Example","headcount":1200},"as_of":"2026-10-01","source":"https://example.com/about"}  or  {"puts":[...]}"#.into(),
        "drop" => r#"{"table":"offices","id":31}"#.into(),
        "unlinked" => r#"{}  or  {"limit":20,"after":<the last application id shown>}"#.into(),
        "cv" => r#"{}  or  {"application":<no>}  or  {"check":"<pattern>","position":<n>}  or  {"fields":true}"#.into(),
        "missions" => r#"{}  or  {"application":<id>,"state":"fire_ready","kind":"email"}"#.into(),
        "mission" => r#"{"id":<mission id>}"#.into(),
        "fire_keys" => "{}".into(),
        "outreach" => r#"{}  or  {"where":{"application_id":120,"at":{"ge":"2026-10-01T00:00:00Z"}},"search":"interview","group":"kind","limit":50}"#.into(),
        "report" => r#"{"mission":34,"report":"<what you did, markdown>","link":"https://...","reference":"APP-4012","fields":{...}}  or  {"mission":34,"outcome":"failed","reason":"<why>"}"#.into(),
        "request_fire_key" => r#"{"missions":"33-34,56","reason":"<why these shots, at most 280 chars>"}"#.into(),
        "cv_upload" => r#"{"root_id":<cv_roots id>,"name":"cv.pdf","base64":"<the file>","note":"<what changed>"}"#.into(),
        other => return tools::command_named(other).map(command_shape),
    })
}

pub fn command_shape(c: &CommandDef) -> String {
    let params: Vec<String> = c.params.iter().map(|p| format!("\"{}\":<{}{}>", p.name, p.ty(), if p.required { "" } else { "?" })).collect();
    let table = tools::table_name(c.table);
    format!("{{\"id\":<{table} id>{}{}}}", if table == "applications" { " | \"no\":<number>" } else { "" }, if params.is_empty() { String::new() } else { format!(",{}", params.join(",")) })
}

/// A call whose arguments are wrong before anything is judged, with the tool's shape.
pub fn usage(tool: &str, problem: &str) -> String {
    diag::usage(tool, problem, &shape(tool).unwrap_or_default())
}

/// `schema` with no table: what this key can see and do.
pub fn overview(m: Masks) -> Json {
    json!({
        "schema_rev": schema::SCHEMA_REV,
        "tables": schema::TABLES.iter().filter(|t| t.residency.stored() && (m.reads(t) || m.writes(t))).map(|t| json!({
            "table": t.name, "domain": t.domain, "residency": t.residency.name(),
            "readable": m.reads(t), "writable": m.writes(t), "natural": tools::natural(t),
        })).collect::<Vec<_>>(),
        "commands": schema::COMMANDS.iter().filter(|c| !c.human_only).map(|c| json!({"command": c.name, "table": tools::table_name(c.table), "params": c.params.iter().map(|p| p.name).collect::<Vec<_>>()})).collect::<Vec<_>>(),
    })
}

/// An encoded op: its id, the label its verdict is reported under, and its bytes in the OPS op layout.
pub type Encoded = (u64, String, Vec<u8>);

/// A call's writes as ops numbered from `first`: `put` (one, or `puts`), `drop`, or a command on
/// `target` (the node resolves an application's `no` to its id first). The error is a usage text.
pub fn encode(tool: &str, args: &Json, first: u64, target: Option<u32>) -> Result<Vec<Encoded>, String> {
    match tool {
        "put" => {
            let one = [args.clone()];
            let puts: &[Json] = match args.get("puts").and_then(Json::as_array) {
                Some(list) => list,
                None => &one,
            };
            if puts.is_empty() {
                return Err(usage("put", "puts holds at least one op"));
            }
            puts.iter().enumerate().map(|(i, p)| encode_put(first + i as u64, p).map_err(|e| usage("put", &format!("puts[{i}]: {e}")))).collect()
        }
        "drop" => encode_drop(first, args).map(|e| vec![e]).map_err(|e| usage("drop", &e)),
        name => {
            let c = tools::command_named(name).filter(|c| !c.human_only).ok_or_else(|| usage(name, "no such tool"))?;
            encode_command(first, c, args, target).map(|e| vec![e]).map_err(|e| diag::usage(c.name, &e, &command_shape(c)))
        }
    }
}

fn encode_drop(op_id: u64, args: &Json) -> Result<Encoded, String> {
    let t = args.get("table").and_then(Json::as_str).and_then(tools::table_named).ok_or("table names nothing writable")?;
    let (target, keyed) = match (row_id(args)?, args.get("key")) {
        (Some(id), None) => (id, None),
        (None, Some(Json::Object(k))) => (0, Some(k)),
        _ => return Err("name the row by id (a whole number) or by key (an object), not both".into()),
    };
    let cells = keyed.map_or(Ok(Vec::new()), |k| key_cells(t, k))?;
    let bytes = op_bytes(op_id, wire::DROP, if keyed.is_some() { wire::KEYED } else { 0 }, t.id, target, None, &cells);
    let label = format!("drop {} {}", t.name, keyed.map_or_else(|| target.to_string(), |k| Json::Object(k.clone()).to_string()));
    Ok((op_id, label, bytes))
}

fn encode_command(op_id: u64, c: &CommandDef, args: &Json, target: Option<u32>) -> Result<Encoded, String> {
    let target = match (row_id(args)?, target) {
        (Some(id), _) | (None, Some(id)) => id,
        // A command whose params name its row (open_generation by corporation_id) carries no target.
        (None, None) => 0,
    };
    let mut cells = Vec::new();
    for p in c.params {
        match args.get(p.name) {
            Some(v) => cells.push((p.id, tools::cell(p, v)?)),
            None if p.required => return Err(format!("{} is required", p.name)),
            None => {}
        }
    }
    let label = format!("{} {} {target}", c.name, tools::table_name(c.table));
    Ok((op_id, label, op_bytes(op_id, wire::COMMAND, 0, c.id, target, None, &cells)))
}

/// One put as an op (its id, label and bytes), or why it cannot be one.
pub fn encode_put(op_id: u64, p: &Json) -> Result<Encoded, String> {
    let tname = p.get("table").and_then(Json::as_str).ok_or("table is required")?;
    let t = tools::table_named(tname).filter(|t| t.residency.stored()).ok_or_else(|| format!("no writable table {tname}"))?;
    let set = p.get("set").and_then(Json::as_object).ok_or("set is required: {column: value}")?;
    let mut cells = Vec::new();
    let mut flags = 0u8;
    let mut target = 0u32;
    let mut label = format!("put {tname}");
    let key = match p.get("key") {
        None | Some(Json::Null) => None,
        Some(Json::Object(k)) => Some(k),
        Some(v) => return Err(format!("key is an object of natural-key columns, e.g. {{\"domain\":\"example.com\"}}; got {v}")),
    };
    match (row_id(p)?, key) {
        (Some(_), Some(_)) => return Err("name the row by id or by key, not both".into()),
        (Some(id), None) => {
            target = id;
            label.push_str(&format!(" id={id}"));
        }
        (None, Some(k)) => {
            flags |= wire::KEYED;
            cells = key_cells(t, k)?;
            for (name, v) in k {
                label.push_str(&format!(" {name}={}", v.as_str().map(str::to_owned).unwrap_or_else(|| v.to_string())));
            }
        }
        (None, None) => label.push_str(" (new)"),
    }
    let mut metric = false;
    let mut prose = false;
    for (name, v) in set {
        let c = t.col_named(name).ok_or_else(|| format!("{tname} has no column {name}; `schema` {{\"table\":\"{tname}\"}} lists them"))?;
        if !tools::writable(c) {
            let readonly = c.flags & (flag::READONLY | flag::IMPLIED) != 0;
            return Err(format!("{tname}.{name} is not writable by a put{}", if readonly { " (readonly: the server or a command writes it)" } else { "" }));
        }
        metric |= c.flags & flag::METRIC != 0;
        prose |= c.flags & flag::PROSE != 0;
        // A key column repeated in set is the same cell: equal values merge, different ones are a mistake.
        if let Some(k) = key.and_then(|k| k.get(name)) {
            if k != v {
                return Err(format!("{name} is in key as {k} and in set as {v}; a natural key is changed by id, not by key"));
            }
            continue;
        }
        cells.push((c.id, tools::cell(c, v)?));
    }
    if let Some(day) = p.get("as_of") {
        cells.push((wire::AS_OF, tools::Cell::U32(day.as_str().and_then(tools::parse_day).ok_or("as_of is 'YYYY-MM-DD'")?)));
    } else if metric {
        return Err("a metric needs as_of: the day the figures are true as of".into());
    }
    match p.get("source") {
        Some(Json::String(url)) => cells.push((wire::SOURCE, tools::Cell::Str(url.clone()))),
        Some(Json::Number(n)) => cells.push((wire::SOURCE, tools::Cell::U32(n.as_u64().and_then(|n| u32::try_from(n).ok()).ok_or("source id out of range")?))),
        Some(_) => return Err("source is a URL or a sources id".into()),
        None if prose => return Err("prose needs a source URL".into()),
        None => {}
    }
    let expect = match p.get("expect_rev") {
        Some(r) => {
            flags |= wire::EXPECT_REV;
            Some(r.as_u64().and_then(|r| u32::try_from(r).ok()).ok_or("expect_rev is the row's rev")?)
        }
        None if prose => return Err("prose needs expect_rev: the row's rev from `get`".into()),
        None => None,
    };
    if p.get("create_only").and_then(Json::as_bool) == Some(true) {
        flags |= wire::CREATE_ONLY;
    }
    let mut seen = HashSet::new();
    if let Some((col, _)) = cells.iter().find(|(col, _)| !seen.insert(*col)) {
        return Err(format!("column {col} appears twice in one op"));
    }
    Ok((op_id, label, op_bytes(op_id, wire::PUT, flags, t.id, target, expect, &cells)))
}

/// The cells of a natural key, typed by the table's columns.
fn key_cells(t: &TableDef, k: &serde_json::Map<String, Json>) -> Result<Vec<(u16, tools::Cell)>, String> {
    k.iter()
        .map(|(name, v)| {
            let c = t.col_named(name).ok_or_else(|| format!("{} has no column {name}", t.name))?;
            Ok((c.id, tools::cell(c, v)?))
        })
        .collect()
}

/// One op's bytes in the OPS op layout, which the kernel judges and an OPS body carries as they are.
fn op_bytes(op_id: u64, verb: u8, flags: u8, table: u16, target: u32, expect: Option<u32>, cells: &[(u16, tools::Cell)]) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let mut op = w.op(op_id, verb, flags, table, target, expect);
    for (col, cell) in cells {
        tools::write_cell(&mut op, *col, cell);
    }
    op.done();
    w.finish()[8..].to_vec()
}

/// An id argument: absent, or a whole number that fits a row id; anything else is a mistake, never "absent".
pub fn row_id(args: &Json) -> Result<Option<u32>, String> {
    match args.get("id") {
        None | Some(Json::Null) => Ok(None),
        Some(v) => v.as_u64().and_then(|n| u32::try_from(n).ok()).filter(|n| *n > 0).map(Some).ok_or_else(|| format!("id is a row id, a whole number from 1; got {v}")),
    }
}

// ------------------------------------------------------------ resources

pub fn templates(m: Masks) -> Json {
    let mut out = Vec::new();
    for (table, key, title) in [
        ("applications", "no", "An application by its number"),
        ("corporations", "domain", "A corporation by its domain"),
        ("places", "iso2", "A country by its ISO 3166-1 alpha-2 code"),
        ("cv_roots", "slug", "A CV root by its slug"),
        ("cv_versions", "id", "A CV version: its text, and blob_url for a pdf or docx (GET it with this key)"),
    ] {
        if tools::table_named(table).is_some_and(|t| m.reads(t)) {
            out.push(json!({"uriTemplate": format!("hireme://{table}/{{{key}}}"), "name": table, "title": title, "mimeType": "application/json"}));
        }
    }
    json!({"resourceTemplates": out})
}

/// `hireme://<table>/<key>` → the `get` the URI names.
pub fn locate(uri: &str) -> Option<Json> {
    let rest = uri.strip_prefix("hireme://")?;
    let (table, key) = rest.split_once('/')?;
    let key = percent_decode(key);
    Some(match table {
        "applications" => json!({"table":"applications","key":{"no": key.parse::<u64>().ok()?}}),
        "corporations" => json!({"table":"corporations","key":{"domain": key}}),
        "places" => json!({"table":"places","key":{"iso2": key.to_uppercase()}}),
        "cv_roots" => json!({"table":"cv_roots","key":{"slug": key}}),
        "cv_versions" => json!({"table":"cv_versions","id": key.parse::<u32>().ok().filter(|n| *n > 0)?}),
        _ => return None,
    })
}

/// Decodes over bytes, so a `%` before a multibyte character is kept as written instead of splitting it.
pub fn percent_decode(s: &str) -> String {
    let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%'
            && let (Some(h), Some(l)) = (b.get(i + 1).copied().and_then(hex), b.get(i + 2).copied().and_then(hex))
        {
            out.push(h << 4 | l);
            i += 3;
            continue;
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The rows a PATCH body (table runs) wrote or deleted, as (table, id).
pub fn moved(body: &[u8]) -> Vec<(u16, u32)> {
    let Ok(blocks) = wire::Blocks::new(body) else { return Vec::new() };
    let mut out = Vec::new();
    for b in blocks.iter() {
        if let Some(gone) = b.gone() {
            out.extend(gone.iter().map(|id| (b.table, id)));
        } else if let Some(ids) = b.col(1) {
            out.extend((0..ids.nrows()).map(|i| (b.table, ids.u32(i))));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decoding_keeps_a_multibyte_character_after_a_lone_percent() {
        assert_eq!(percent_decode("%aé"), "%aé");
        assert_eq!(percent_decode("a%20b%C3%A9"), "a bé");
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn a_put_with_a_bad_id_or_key_is_a_usage_error_not_an_insert() {
        assert_eq!(row_id(&json!({})), Ok(None));
        assert_eq!(row_id(&json!({"id": 7})), Ok(Some(7)));
        for bad in [json!("12"), json!(1.5), json!(-1), json!(0), json!(4_294_967_297u64)] {
            assert!(row_id(&json!({"id": bad})).is_err(), "{bad}");
        }
        for p in [
            json!({"table": "corporations", "id": "12", "set": {"name": "X"}}),
            json!({"table": "corporations", "key": "x.com", "set": {"name": "X"}}),
            json!({"table": "corporations", "key": {"domain": "x.com"}, "set": {"domain": "y.com"}}),
        ] {
            assert!(encode_put(1, &p).is_err(), "{p}");
        }
        // The same key column in set is the same cell: merged, so the op names it once.
        let (_, _, bytes) = encode_put(1, &json!({"table": "corporations", "key": {"domain": "x.com"}, "set": {"domain": "x.com", "name": "X"}})).unwrap();
        let cols: Vec<u16> = wire::Op::one(&bytes).unwrap().cells().map(|c| c.col).collect();
        assert_eq!(cols, vec![schema::col::corporations::DOMAIN, schema::col::corporations::NAME]);
    }

    #[test]
    fn a_burst_is_numbered_in_order_and_one_bad_put_names_its_index() {
        let puts = json!({"puts": [
            {"table": "corporations", "key": {"domain": "a.com"}, "set": {"name": "A"}},
            {"table": "corporations", "key": {"domain": "b.com"}, "set": {"name": "B"}},
        ]});
        let ops = encode("put", &puts, 40, None).unwrap();
        assert_eq!(ops.iter().map(|o| o.0).collect::<Vec<_>>(), vec![40, 41]);
        let bad = json!({"puts": [{"table": "corporations", "set": {"name": "A"}}, {"table": "nope", "set": {}}]});
        assert!(encode("put", &bad, 1, None).unwrap_err().contains("puts[1]"));
    }
}
