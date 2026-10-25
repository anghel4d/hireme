//! Refs at the MCP's door (docs/mcp/refs.md). A ref names one row as every
//! page shows it: `app:412` (the application's number), `mission:34`,
//! `contact:9`, `corp:stripe.com`, `place:3`, `outreach:1291`, `batch:96`,
//! `fire_key:51`, `fire_request:88`. [`resolve`] rewrites a call's
//! arguments before dispatch: every ref becomes the table and id the tools
//! already take, a mission's kind-tagged keys become its row, and a key no
//! tool takes is refused with a did-you-mean. Nothing downstream changes.

use std::collections::HashMap;
use std::sync::OnceLock;

use kernel::abi::Kernel;
use kernel::query::Grants;
use schema::TableDef;
use serde_json::{Map, Value as Json, json};

use crate::tools::{self, Field, Masks};

/// A ref's kind: one table each.
pub use kernel::refs::{KINDS, Kind};

/// The kind's table by name, as the tools name it.
fn table_name(k: Kind) -> &'static str {
    schema::table_def(k.table()).map_or("", |t| t.name)
}

fn kind_of_table(name: &str) -> Option<Kind> {
    crate::tools::table_named(name).and_then(|t| Kind::of_table(t.id))
}

/// One ref, parsed: a row to insert, a row by its number or id, or a
/// corporation by its domain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ref {
    New(Kind),
    Key(Kind, u32),
    Domain(String),
}

impl Ref {
    pub fn kind(&self) -> Kind {
        match self {
            Ref::New(k) | Ref::Key(k, _) => *k,
            Ref::Domain(_) => Kind::Corp,
        }
    }
}

/// The kinds, for a refusal's words.
fn forms() -> String {
    KINDS.iter().map(|k| k.0.form()).collect::<Vec<_>>().join(", ")
}

/// `<kind>:<key>`, strictly; the error says what a ref is.
pub fn parse(text: &str) -> Result<Ref, String> {
    let t = text.trim();
    let Some((p, key)) = t.split_once(':') else {
        return Err(format!("{t:?} is no ref: a ref is <kind>:<key>, one of {}", forms()));
    };
    let Some(kind) = Kind::of_prefix(p.trim()) else {
        return Err(format!("{p:?} is no ref kind; the kinds are {}", KINDS.iter().map(|k| k.1).collect::<Vec<_>>().join(", ")));
    };
    let key = key.trim();
    if key == "new" {
        return Ok(Ref::New(kind));
    }
    match kind {
        Kind::Corp => {
            let d = key.to_ascii_lowercase();
            if d.is_empty() || !d.contains('.') || d.contains(char::is_whitespace) {
                return Err(format!("{t:?}: corp takes a domain, as corp:stripe.com"));
            }
            Ok(Ref::Domain(d))
        }
        _ => key.parse::<u32>().ok().filter(|n| *n > 0).map(|n| Ref::Key(kind, n)).ok_or_else(|| format!("{t:?}: {} takes a whole number from 1", kind.form())),
    }
}

/// Whether a string is meant as a ref: a known kind before the colon.
fn ref_like(s: &str) -> bool {
    s.split_once(':').is_some_and(|(p, _)| Kind::of_prefix(p.trim()).is_some())
}

// ------------------------------------------------------------ the replica

/// What resolution reads: the daemon's replica, under the key's grants.
pub trait Lookup {
    /// The application with this number.
    fn app_id(&mut self, no: u32) -> Option<u32>;
    /// The corporation with this domain.
    fn corp_id(&mut self, domain: &str) -> Option<u32>;
    /// An outreach item's Message-ID.
    fn message_id(&mut self, outreach: u32) -> Option<String>;
    /// A mission's kind, by name.
    fn mission_kind(&mut self, mission: u32) -> Option<String>;
}

/// [`Lookup`] over the kernel.
pub struct Replica<'a>(pub &'a mut Kernel, pub Grants);

impl Replica<'_> {
    fn row(&mut self, req: Json) -> Option<Json> {
        self.0.query_as(&self.1, &req).ok().and_then(|v| v.get("row").cloned()).filter(Json::is_object)
    }

    fn id_of(&mut self, req: Json) -> Option<u32> {
        self.row(req)?["id"].as_u64().and_then(|i| u32::try_from(i).ok())
    }
}

impl Lookup for Replica<'_> {
    fn app_id(&mut self, no: u32) -> Option<u32> {
        self.id_of(json!({"op": "get", "table": "applications", "key": {"no": no}}))
    }

    fn corp_id(&mut self, domain: &str) -> Option<u32> {
        self.id_of(json!({"op": "get", "table": "corporations", "key": {"domain": domain}}))
    }

    fn message_id(&mut self, outreach: u32) -> Option<String> {
        self.row(json!({"op": "get", "table": "outreach", "id": outreach}))?["message_id"].as_str().map(String::from)
    }

    fn mission_kind(&mut self, mission: u32) -> Option<String> {
        self.row(json!({"op": "get", "table": "missions", "id": mission}))?["kind"].as_str().map(String::from)
    }
}

// ------------------------------------------------------------ refusals

/// A refusal at the door: the code `diag::render` takes, and its data.
pub type Refused = (String, Json);

fn refuse(code: &str, data: Json) -> Refused {
    (code.into(), data)
}

fn wrong_kind(field: &str, expected: Kind, got: &str) -> Refused {
    refuse("ref", json!({"field": field, "expected": expected.form(), "got": got, "reason": format!("expected {}, got {got}", expected.form())}))
}

fn not_a_ref(field: &str, why: String) -> Refused {
    refuse("ref", json!({"field": field, "reason": why}))
}

/// A row no ref names: `app:412` with no application 412.
fn missing(field: &str, r: &Ref, text: &str) -> Refused {
    refuse("not_found", json!({"field": field, "table": table_name(r.kind()), "ref": text, "reason": format!("no row {text}")}))
}

/// The nearest known key, by exact match, prefix or a small edit distance.
pub fn nearest<'a>(word: &str, known: impl IntoIterator<Item = &'a str>) -> Option<&'a str> {
    let w = word.to_ascii_lowercase();
    let bound = (1 + w.len() / 4).max(1);
    let mut best: Option<(usize, &str)> = None;
    for k in known {
        let kl = k.to_ascii_lowercase();
        let d = if kl == w {
            0
        } else if (kl.starts_with(&w) || w.starts_with(&kl)) && w.len() >= 2 {
            1
        } else {
            levenshtein(&w, &kl)
        };
        if d <= bound && best.is_none_or(|b| d < b.0) {
            best = Some((d, k));
        }
    }
    best.map(|b| b.1)
}

fn levenshtein(a: &str, b: &str) -> usize {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut cur = vec![i + 1];
        for (j, cb) in b.iter().enumerate() {
            let cost = usize::from(ca != cb);
            cur.push((prev[j] + cost).min(prev[j + 1] + 1).min(cur[j] + 1));
        }
        prev = cur;
    }
    prev[b.len()]
}

/// `key` is no key of `what`: refused `shape`, with the nearest known key.
fn unknown(what: &str, key: &str, known: &[&str]) -> Refused {
    let mut data = json!({"key": key, "of": what, "known": known, "reason": format!("{key:?} is not a key of {what}")});
    if let Some(near) = nearest(key, known.iter().copied()) {
        data["did_you_mean"] = json!(near);
    }
    refuse("shape", data)
}

// ------------------------------------------------------------ the tools' keys

const HELP_KEYS: [&str; 4] = ["help", "-h", "--help", "--version"];

/// Every tool's argument keys, from the tool list's schemas, plus the
/// resolver's own (`ref`; `refs` where ids are taken).
fn known_keys(tool: &str) -> Option<&'static [String]> {
    static KEYS: OnceLock<HashMap<String, Vec<String>>> = OnceLock::new();
    let all = KEYS.get_or_init(|| {
        let every = Masks { read: u16::MAX, write: u16::MAX, may_delete: true };
        let mut m = HashMap::new();
        for t in tools::list(every) {
            let name = t["name"].as_str().unwrap_or("").to_owned();
            let mut keys: Vec<String> = t["inputSchema"]["properties"].as_object().map(|p| p.keys().cloned().collect()).unwrap_or_default();
            keys.push("ref".into());
            if matches!(name.as_str(), "lease" | "release") {
                keys.push("refs".into());
            }
            m.insert(name, keys);
        }
        m
    });
    all.get(tool).map(Vec::as_slice)
}

/// Every key the tool's arguments may hold, else the first that may not.
fn check_keys(tool: &str, args: &Map<String, Json>) -> Result<(), Refused> {
    // A put's keys are its own and, for a mission, its kind's: `put_one` checks them once the kind is known.
    if tool == "put" {
        return Ok(());
    }
    let Some(known) = known_keys(tool) else { return Ok(()) };
    let names: Vec<&str> = known.iter().map(String::as_str).filter(|k| !HELP_KEYS.contains(k)).collect();
    for key in args.keys() {
        if HELP_KEYS.contains(&key.as_str()) || known.iter().any(|k| k == key) {
            continue;
        }
        return Err(unknown(tool, key, &names));
    }
    Ok(())
}

/// A put's own keys, beside `puts`.
fn put_keys(a: &Map<String, Json>) -> Result<(), Refused> {
    let known: Vec<&str> = ENVELOPE.iter().copied().chain(["puts"]).collect();
    match a.keys().find(|k| !known.contains(&k.as_str()) && !HELP_KEYS.contains(&k.as_str())) {
        Some(k) => Err(unknown("put", k, &known)),
        None => Ok(()),
    }
}

// ------------------------------------------------------------ resolution

/// The call's arguments with every ref resolved and a mission's union keys
/// lowered to its row; or the refusal that stops it at the door.
pub fn resolve(tool: &str, args: &Json, look: &mut dyn Lookup) -> Result<Json, Refused> {
    let Some(obj) = args.as_object() else { return Ok(args.clone()) };
    let mut a = obj.clone();
    check_keys(tool, &a)?;
    match tool {
        "put" => {
            if let Some(Json::Array(puts)) = a.get("puts").cloned() {
                put_keys(&a)?;
                let mut done = Vec::with_capacity(puts.len());
                for (i, p) in puts.iter().enumerate() {
                    done.push(match p.as_object() {
                        Some(o) => Json::Object(put_one(o.clone(), look).map_err(|(c, mut d)| {
                            d["at"] = json!(format!("puts[{i}]"));
                            (c, d)
                        })?),
                        None => p.clone(),
                    });
                }
                a.insert("puts".into(), Json::Array(done));
            } else {
                a = put_one(a, look)?;
            }
        }
        "drop" | "get" | "text" | "history" => {
            a = row_ref(a, None, look, false)?;
            if let Some(t) = a.get("table").and_then(Json::as_str).and_then(tools::table_named) {
                resolve_fields(&mut a, "key", t, look)?;
            }
        }
        "find" | "outreach" => {
            let table = if tool == "outreach" { Some("outreach") } else { a.get("table").and_then(Json::as_str) };
            if let Some(t) = table.and_then(tools::table_named) {
                resolve_where(&mut a, t, look)?;
            }
        }
        "missions" | "campaign" => {
            for field in ["application", "app"] {
                if let Some(v) = a.get(field).cloned() {
                    a.insert(field.into(), resolve_one(&v, Kind::App, field, look)?);
                }
            }
        }
        // cv names an application by its number: the ref's key as it is.
        "cv" => {
            if let Some(Json::String(s)) = a.get("application").cloned() {
                match parse(&s).map_err(|w| not_a_ref("application", w))? {
                    Ref::Key(Kind::App, no) => a.insert("application".into(), json!(no)),
                    other => return Err(wrong_kind("application", Kind::App, &format!("{}:{}", other.kind().prefix(), key_text(&other)))),
                };
            }
        }
        "mission" => {
            a = row_ref(a, Some("missions"), look, false)?;
        }
        "report" => {
            if let Some(r) = a.remove("ref") {
                a.insert("mission".into(), r);
            }
            if let Some(v) = a.get("mission").cloned() {
                a.insert("mission".into(), resolve_one(&v, Kind::Mission, "mission", look)?);
            }
            if let Some(v) = a.get("contact_id").cloned() {
                a.insert("contact_id".into(), resolve_one(&v, Kind::Contact, "contact_id", look)?);
            }
        }
        "lease" | "release" => {
            if let Some(refs) = a.remove("refs") {
                let mut ids: Vec<Json> = a.get("ids").and_then(Json::as_array).cloned().unwrap_or_default();
                for r in refs.as_array().cloned().unwrap_or_else(|| vec![refs.clone()]) {
                    let id = resolve_one(&r, Kind::App, "refs", look)?;
                    if !ids.contains(&id) {
                        ids.push(id);
                    }
                }
                a.insert("ids".into(), Json::Array(ids));
            }
        }
        "request_fire_key" => {
            if let Some(v) = a.get("missions").cloned() {
                a.insert("missions".into(), json!(ranges(&v)?));
            }
        }
        name => {
            if let Some(c) = tools::command_named(name) {
                a = row_ref(a, Some(tools::table_name(c.table)), look, false)?;
                for p in c.params {
                    let Some(v) = a.get(p.name).cloned() else { continue };
                    if p.ty() == "ref"
                        && let Some(kind) = p.target.and_then(kind_of_table)
                    {
                        a.insert(p.name.into(), resolve_one(&v, kind, p.name, look)?);
                    } else if name == "fire" && p.name == "key" && v.is_string() {
                        a.insert("key".into(), resolve_one(&v, Kind::FireKey, "key", look)?);
                    }
                }
            }
        }
    }
    Ok(Json::Object(a))
}

fn key_text(r: &Ref) -> String {
    match r {
        Ref::New(_) => "new".into(),
        Ref::Key(_, n) => n.to_string(),
        Ref::Domain(d) => d.clone(),
    }
}

/// A ref's row id: the application's by its number, the corporation's by
/// its domain, every other kind's as given.
fn id_of(r: &Ref, field: &str, text: &str, look: &mut dyn Lookup) -> Result<u32, Refused> {
    match r {
        Ref::New(_) => Err(not_a_ref(field, format!("{text:?} names a row to insert, which only put takes"))),
        Ref::Key(Kind::App, no) => look.app_id(*no).ok_or_else(|| missing(field, r, text)),
        Ref::Domain(d) => look.corp_id(d).ok_or_else(|| missing(field, r, text)),
        Ref::Key(_, id) => Ok(*id),
    }
}

/// One value that names a row of `kind`: a ref as a string, resolved to its
/// id; a number as it is.
fn resolve_one(v: &Json, kind: Kind, field: &str, look: &mut dyn Lookup) -> Result<Json, Refused> {
    let Some(s) = v.as_str() else { return Ok(v.clone()) };
    let r = parse(s).map_err(|w| not_a_ref(field, w))?;
    if r.kind() != kind {
        return Err(wrong_kind(field, kind, s.trim()));
    }
    id_of(&r, field, s.trim(), look).map(|id| json!(id))
}

/// `ref` taken out of the arguments: the table it names (checked against
/// `fixed`, a command's own) and its row as `id`. A row named twice and
/// differently is refused; `<kind>:new` only where `allow_new`.
fn row_ref(mut a: Map<String, Json>, fixed: Option<&str>, look: &mut dyn Lookup, allow_new: bool) -> Result<Map<String, Json>, Refused> {
    let Some(v) = a.remove("ref") else { return Ok(a) };
    let text = v.as_str().map(str::trim).ok_or_else(|| not_a_ref("ref", format!("ref is a string, as {}", forms())))?.to_owned();
    let r = parse(&text).map_err(|w| not_a_ref("ref", w))?;
    let table = match fixed {
        Some(t) => {
            let want = kind_of_table(t).ok_or_else(|| not_a_ref("ref", format!("{t} rows have no ref; name the row by id")))?;
            if r.kind() != want {
                return Err(wrong_kind("ref", want, &text));
            }
            t
        }
        None => {
            if let Some(given) = a.get("table").and_then(Json::as_str)
                && given != table_name(r.kind())
            {
                return Err(refuse("ref", json!({"field": "ref", "ref": text, "table": given, "reason": format!("{text} is a {} row, not {given}", table_name(r.kind()))})));
            }
            table_name(r.kind())
        }
    };
    a.insert("table".into(), json!(table));
    // A command's `key` is its own param (fire's key); a row op's is the natural key.
    if fixed.is_none() && a.contains_key("key") {
        return Err(refuse("ref", json!({"field": "ref", "ref": text, "reason": "name the row once: by ref, or by key"})));
    }
    if let Ref::New(_) = r {
        if !allow_new {
            return Err(not_a_ref("ref", format!("{text} names a row to insert; this call needs a row that exists")));
        }
        if a.contains_key("id") || a.contains_key("no") {
            return Err(refuse("ref", json!({"field": "ref", "ref": text, "reason": "a row to insert has no id"})));
        }
        return Ok(a);
    }
    let id = id_of(&r, "ref", &text, look)?;
    if let Some(given) = a.get("id").and_then(Json::as_u64)
        && given != u64::from(id)
    {
        return Err(refuse("ref", json!({"field": "ref", "ref": text, "id": given, "reason": format!("{text} is row {id}, not {given}; name the row once")})));
    }
    if let (Ref::Key(Kind::App, no), Some(given)) = (&r, a.get("no").and_then(Json::as_u64))
        && given != u64::from(*no)
    {
        return Err(refuse("ref", json!({"field": "ref", "ref": text, "no": given, "reason": format!("{text} and no {given} name two rows")})));
    }
    a.remove("no");
    a.insert("id".into(), json!(id));
    Ok(a)
}

/// Ref columns inside the object under `under` (`set`, `key`): a string
/// ref becomes the id of the row it names, checked against the column's
/// target.
fn resolve_fields(a: &mut Map<String, Json>, under: &str, t: &TableDef, look: &mut dyn Lookup) -> Result<(), Refused> {
    let Some(Json::Object(mut fields)) = a.get(under).cloned() else { return Ok(()) };
    for (name, v) in fields.iter_mut() {
        if let Some(s) = v.as_str()
            && ref_like(s)
            && let Some(c) = t.col_named(name)
            && c.ty() == "ref"
            && let Some(kind) = c.target.and_then(kind_of_table)
        {
            *v = resolve_one(&Json::String(s.to_owned()), kind, name, look)?;
        }
    }
    a.insert(under.into(), Json::Object(fields));
    Ok(())
}

/// Ref columns in a `where`: `{"application_id": "app:412"}`, or under
/// `eq`, `ne` and `in`.
fn resolve_where(a: &mut Map<String, Json>, t: &TableDef, look: &mut dyn Lookup) -> Result<(), Refused> {
    let Some(Json::Object(mut w)) = a.get("where").cloned() else { return Ok(()) };
    for (name, cond) in w.iter_mut() {
        let Some(kind) = t.col_named(name).filter(|c| c.ty() == "ref").and_then(|c| c.target).and_then(kind_of_table) else { continue };
        match cond {
            Json::String(_) => *cond = resolve_one(cond, kind, name, look)?,
            Json::Object(ops) => {
                for (op, v) in ops.iter_mut() {
                    match (op.as_str(), &*v) {
                        ("eq" | "ne", Json::String(_)) => *v = resolve_one(v, kind, name, look)?,
                        ("in", Json::Array(items)) => {
                            let mut out = Vec::with_capacity(items.len());
                            for i in items {
                                out.push(resolve_one(i, kind, name, look)?);
                            }
                            *v = Json::Array(out);
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    a.insert("where".into(), Json::Object(w));
    Ok(())
}

/// Mission ranges for `request_fire_key`: `mission:34-35,mission:40`, an
/// array of such, or the bare text the kernel's `Ranges` reads.
fn ranges(v: &Json) -> Result<String, Refused> {
    let items: Vec<String> = match v {
        Json::String(s) => s.split(',').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect(),
        Json::Array(a) => a.iter().map(|i| i.as_str().map(str::trim).map(String::from).ok_or_else(|| not_a_ref("missions", "missions is text or a list of mission refs and ranges".into()))).collect::<Result<_, _>>()?,
        _ => return Err(not_a_ref("missions", "missions is text (\"mission:34-35,mission:40\") or a list of refs and ranges".into())),
    };
    let mut out = Vec::with_capacity(items.len());
    for item in items {
        let bare = match item.split_once(':') {
            Some((p, rest)) => {
                let kind = Kind::of_prefix(p.trim()).ok_or_else(|| not_a_ref("missions", format!("{item:?}: {p:?} is no ref kind")))?;
                if kind != Kind::Mission {
                    return Err(wrong_kind("missions", Kind::Mission, &item));
                }
                rest.trim().to_owned()
            }
            None => item,
        };
        out.push(bare);
    }
    Ok(out.join(","))
}

// ------------------------------------------------------------ the mission union

/// The keys every kind takes.
const COMMON: [&str; 7] = ["app", "application", "application_id", "draft", "note", "state", "contact"];
/// Each kind's own keys.
const OWN: [(&str, &[&str]); 7] = [
    ("email", &["to", "cc", "subject", "in_reply_to", "refs"]),
    ("careers_page", &["form"]),
    ("linkedin", &["profile"]),
    ("x_dm", &["handle"]),
    ("discord", &["handle"]),
    ("other", &["target"]),
    ("note", &[]),
];
/// Every union key, for telling a mission's keys on another table's put.
const UNION_KEYS: [&str; 17] = ["app", "application", "application_id", "draft", "note", "state", "contact", "contact_id", "to", "cc", "subject", "in_reply_to", "refs", "form", "profile", "handle", "target"];
/// The put's own keys beside the union's.
const ENVELOPE: [&str; 9] = ["ref", "table", "id", "key", "set", "expect_rev", "create_only", "as_of", "source"];

/// The kinds a mission can be: enum outreach_kind without note.
fn kinds() -> Vec<&'static str> {
    schema::enum_names("outreach_kind").unwrap_or(&[]).iter().copied().filter(|k| *k != "note").collect()
}

fn kind_named(name: &str) -> Option<kernel::outreach::Kind> {
    schema::enum_names("outreach_kind")?.iter().position(|k| *k == name).and_then(|i| kernel::outreach::Kind::from_code(i as u32))
}

/// A list key as text: a string as given, an array joined with `sep`.
fn joined(v: &Json, sep: &str) -> Option<String> {
    match v {
        Json::String(s) => Some(s.clone()),
        Json::Array(a) => Some(a.iter().filter_map(Json::as_str).map(str::trim).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(sep)),
        _ => None,
    }
}

/// One put, its ref and ref columns resolved and, for a mission, its union
/// keys lowered to its row.
fn put_one(a: Map<String, Json>, look: &mut dyn Lookup) -> Result<Map<String, Json>, Refused> {
    let inserting = matches!(a.get("ref").and_then(Json::as_str).map(parse), Some(Ok(Ref::New(_)))) || !(a.contains_key("ref") || a.contains_key("id") || a.contains_key("key"));
    let mut a = row_ref(a, None, look, true)?;
    let table = a.get("table").and_then(Json::as_str).unwrap_or("").to_owned();
    if table == "missions" {
        mission_union(&mut a, inserting, look)?;
    } else {
        put_keys(&a)?;
    }
    let Some(t) = tools::table_named(&table) else { return Ok(a) };
    if let Some(Json::Object(set)) = a.get("set") {
        let writable: Vec<&str> = t.cols.iter().filter(|c| tools::writable(c)).map(|c| c.name).collect();
        if let Some(k) = set.keys().find(|k| t.col_named(k).is_none()) {
            return Err(unknown(&format!("{table}.set"), k, &writable));
        }
    }
    resolve_fields(&mut a, "set", t, look)?;
    resolve_fields(&mut a, "key", t, look)?;
    Ok(a)
}

/// The mission's kind-tagged keys (docs/mcp/refs.md) lowered into `set`.
fn mission_union(a: &mut Map<String, Json>, inserting: bool, look: &mut dyn Lookup) -> Result<(), Refused> {
    let mut set = match a.remove("set") {
        Some(Json::Object(s)) => s,
        Some(other) => return Err(refuse("shape", json!({"key": "set", "of": "put", "reason": format!("set is an object; got {other}")}))),
        None => Map::new(),
    };
    let kind = match a.remove("kind").or_else(|| set.get("kind").cloned()) {
        Some(Json::String(k)) => Some(k),
        Some(other) => return Err(refuse("shape", json!({"key": "kind", "of": "a mission", "reason": format!("kind is one of {}; got {other}", kinds().join(", "))}))),
        None => a.get("id").and_then(Json::as_u64).and_then(|id| look.mission_kind(id as u32)),
    };
    let union_present = a.keys().any(|k| UNION_KEYS.contains(&k.as_str()));
    let Some(kind) = kind else {
        if union_present || inserting {
            return Err(refuse("shape", json!({"key": "kind", "of": "a mission", "reason": "a mission put names its kind", "known": kinds()})));
        }
        a.insert("set".into(), Json::Object(set));
        return Ok(());
    };
    let Some(k) = kind_named(&kind).filter(|k| k.fireable()) else {
        let kinds = kinds();
        let (last, rest) = kinds.split_last().map_or(("", &kinds[..]), |(l, r)| (*l, r));
        return Err(refuse("shape", json!({"key": "kind", "of": "a mission", "got": kind, "reason": format!("a mission is {} or {last}", rest.join(", "))})));
    };
    let own: &[&str] = OWN.iter().find(|o| o.0 == kind).map_or(&[], |o| o.1);
    let takes: Vec<&str> = COMMON.iter().copied().chain(["contact_id", "target"]).chain(own.iter().copied()).collect();
    for key in a.keys() {
        if !ENVELOPE.contains(&key.as_str()) && !takes.contains(&key.as_str()) && !HELP_KEYS.contains(&key.as_str()) {
            return Err(unknown(&format!("a {kind} mission"), key, &takes));
        }
    }
    let target = |text: &str| kernel::fire::target(k, text).map_err(|why| refuse("type", json!({"table": "missions", "column": "target", "kind": kind, "got": text, "reason": why})));
    let mut lowered: Map<String, Json> = Map::new();
    lowered.insert("kind".into(), json!(kind));
    for (key, v) in a.clone() {
        if !takes.contains(&key.as_str()) {
            continue;
        }
        a.remove(&key);
        match key.as_str() {
            "app" | "application" | "application_id" => {
                lowered.insert("application_id".into(), resolve_one(&v, Kind::App, &key, look)?);
            }
            "contact" | "contact_id" => {
                lowered.insert("contact_id".into(), resolve_one(&v, Kind::Contact, &key, look)?);
            }
            "to" | "form" | "profile" | "handle" | "target" => {
                let text = joined(&v, ", ").ok_or_else(|| refuse("shape", json!({"key": key, "of": format!("a {kind} mission"), "reason": format!("{key} is text")})))?;
                lowered.insert("target".into(), if v.is_null() { Json::Null } else { json!(target(&text)?) });
            }
            "cc" => {
                lowered.insert("cc".into(), joined(&v, ", ").map_or(Json::Null, Json::String));
            }
            "refs" => {
                lowered.insert("refs".into(), joined(&v, " ").map_or(Json::Null, Json::String));
            }
            "in_reply_to" => {
                let id = match v.as_str() {
                    Some(s) if ref_like(s) => match parse(s).map_err(|w| not_a_ref("in_reply_to", w))? {
                        Ref::Key(Kind::Outreach, id) => Json::String(look.message_id(id).ok_or_else(|| missing("in_reply_to", &Ref::Key(Kind::Outreach, id), s))?),
                        other => return Err(wrong_kind("in_reply_to", Kind::Outreach, &format!("{}:{}", other.kind().prefix(), key_text(&other)))),
                    },
                    _ => v,
                };
                lowered.insert("in_reply_to".into(), id);
            }
            _ => {
                lowered.insert(key, v);
            }
        }
    }
    // The union's keys over set's, so one name written both ways is the union's.
    for (k, v) in lowered {
        set.insert(k, v);
    }
    if inserting && !set.get("application_id").is_some_and(|v| !v.is_null()) {
        return Err(refuse("shape", json!({"key": "app", "of": format!("a new {kind} mission"), "reason": "a new mission needs kind and app (app:<the application's number>)"})));
    }
    a.insert("table".into(), json!("missions"));
    a.insert("set".into(), Json::Object(set));
    Ok(())
}

/// The union as JSON Schema: a `oneOf` keyed by `kind`, for a new mission.
pub fn mission_schema() -> Json {
    let ref_of = |k: Kind, what: &str| json!({"type": "string", "pattern": format!("^{}:[1-9][0-9]*$", k.prefix()), "description": what});
    let common = json!({
        "ref": {"type": "string", "const": "mission:new"},
        "kind": {"type": "string"},
        "app": ref_of(Kind::App, "the application, app:<its number>"),
        "contact": ref_of(Kind::Contact, "the person it goes to, contact:<id>"),
        "draft": {"type": "string", "description": "what goes out; markdown for a form's fields"},
        "note": {"type": "string"},
        "state": {"type": "string", "enum": ["draft", "draft_ready", "fire_ready"]},
        "expect_rev": {"type": "integer"},
        "create_only": {"type": "boolean"}
    });
    let branch = |kind: &str, own: Json, required: &[&str]| {
        let mut props = common.as_object().cloned().unwrap_or_default();
        props.insert("kind".into(), json!({"const": kind}));
        for (k, v) in own.as_object().cloned().unwrap_or_default() {
            props.insert(k, v);
        }
        let required: Vec<&str> = ["kind", "app"].iter().copied().chain(required.iter().copied()).collect();
        json!({"type": "object", "properties": props, "required": required, "additionalProperties": false})
    };
    let addr = json!({"type": "string", "description": "name@host.tld"});
    json!({"oneOf": [
        branch("email", json!({
            "to": {"description": "1 to 10 addresses", "oneOf": [addr, {"type": "array", "minItems": 1, "maxItems": 10, "items": addr}]},
            "cc": {"oneOf": [addr, {"type": "array", "maxItems": 10, "items": addr}]},
            "subject": {"type": "string"},
            "in_reply_to": {"type": "string", "description": "a Message-ID, or outreach:<id> of the mail it answers"},
            "refs": {"type": "array", "items": {"type": "string"}, "description": "the References header's ids"}
        }), &["to"]),
        branch("careers_page", json!({"form": {"type": "string", "pattern": "^https://", "description": "the form's https URL"}}), &["form"]),
        branch("linkedin", json!({"profile": {"type": "string", "description": "a linkedin.com/in/ profile URL; or name a contact whose row has one"}}), &[]),
        branch("x_dm", json!({"handle": {"type": "string", "description": "the X handle, with or without @"}}), &["handle"]),
        branch("discord", json!({"handle": {"type": "string", "description": "a user, or server/#channel"}}), &["handle"]),
        branch("other", json!({"target": {"type": "string", "description": "the route, in words"}}), &["target"]),
    ]})
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A replica of two applications (no 412 is id 120, no 7 is id 3), Acme at acme.com (id 11),
    /// outreach 1291 with a Message-ID, mission 34 an email.
    struct Fake;

    impl Lookup for Fake {
        fn app_id(&mut self, no: u32) -> Option<u32> {
            match no {
                412 => Some(120),
                7 => Some(3),
                _ => None,
            }
        }

        fn corp_id(&mut self, domain: &str) -> Option<u32> {
            (domain == "acme.com").then_some(11)
        }

        fn message_id(&mut self, outreach: u32) -> Option<String> {
            (outreach == 1291).then(|| "<r1@acme.example>".to_owned())
        }

        fn mission_kind(&mut self, mission: u32) -> Option<String> {
            (mission == 34).then(|| "email".to_owned())
        }
    }

    fn ok(tool: &str, args: Json) -> Json {
        resolve(tool, &args, &mut Fake).unwrap_or_else(|e| panic!("{tool} {args}: refused {e:?}"))
    }

    fn no(tool: &str, args: Json) -> (String, Json) {
        resolve(tool, &args, &mut Fake).expect_err("expected a refusal")
    }

    #[test]
    fn a_ref_is_a_kind_and_a_key_strictly() {
        assert_eq!(parse("app:412"), Ok(Ref::Key(Kind::App, 412)));
        assert_eq!(parse(" mission:new "), Ok(Ref::New(Kind::Mission)));
        assert_eq!(parse("corp:Acme.COM"), Ok(Ref::Domain("acme.com".into())));
        for bad in ["412", "app:0", "app:12a", "application:412", "corp:acme", "mission:-1", "app"] {
            assert!(parse(bad).is_err(), "{bad}");
        }
        assert_eq!(nearest("frm", ["form", "to", "draft"]), Some("form"));
        assert_eq!(nearest("aplication", ["application", "app"]), Some("application"));
        assert_eq!(nearest("app", ["application", "ids"]), Some("application"));
        assert_eq!(nearest("zzzz", ["form", "to"]), None);
    }

    #[test]
    fn a_ref_names_the_row_a_call_is_about_and_the_wrong_kind_is_refused() {
        assert_eq!(ok("get", json!({"ref": "app:412"})), json!({"table": "applications", "id": 120}));
        assert_eq!(ok("get", json!({"ref": "corp:acme.com"})), json!({"table": "corporations", "id": 11}));
        assert_eq!(ok("drop", json!({"ref": "outreach:9"})), json!({"table": "outreach", "id": 9}));
        assert_eq!(ok("stage", json!({"ref": "app:412", "stage": "closed", "outcome": "expired"})), json!({"table": "applications", "id": 120, "stage": "closed", "outcome": "expired"}));
        assert_eq!(ok("stage", json!({"no": 412, "ref": "app:412", "stage": "gated"})), json!({"table": "applications", "id": 120, "stage": "gated"}));
        assert_eq!(ok("mission", json!({"ref": "mission:34"})), json!({"table": "missions", "id": 34}));
        assert_eq!(ok("fire", json!({"ref": "mission:34", "key": "fire_key:51"})), json!({"table": "missions", "id": 34, "key": 51}));
        assert_eq!(ok("report", json!({"ref": "mission:34", "report": "done", "contact_id": "contact:9"})), json!({"mission": 34, "report": "done", "contact_id": 9}));
        let (code, data) = no("stage", json!({"ref": "mission:34", "stage": "closed"}));
        assert_eq!((code.as_str(), data["expected"].as_str(), data["got"].as_str()), ("ref", Some("app:<the application's number>"), Some("mission:34")));
        assert_eq!(no("get", json!({"ref": "app:999"})).0, "not_found");
        assert_eq!(no("get", json!({"ref": "app:412", "id": 5})).0, "ref");
        assert_eq!(no("get", json!({"ref": "mission:new"})).0, "ref");
        assert_eq!(no("get", json!({"ref": "app:412", "table": "missions"})).0, "ref");
        assert_eq!(no("drop", json!({"ref": "app:412", "key": {"no": 412}})).0, "ref");
    }

    #[test]
    fn ref_columns_lists_and_ranges_resolve_in_place() {
        let p = ok("put", json!({"table": "contacts", "set": {"name": "Dana", "corporation_id": "corp:acme.com", "email": "d@acme.com"}}));
        assert_eq!(p["set"]["corporation_id"], 11);
        assert_eq!(no("put", json!({"table": "contacts", "set": {"name": "Dana", "corporation_id": "app:412"}})).0, "ref");
        let f = ok("find", json!({"table": "missions", "where": {"application_id": {"in": ["app:412", "app:7"]}, "state": "fire_ready"}}));
        assert_eq!(f["where"]["application_id"]["in"], json!([120, 3]));
        assert_eq!(ok("outreach", json!({"where": {"mission_id": "mission:34"}}))["where"]["mission_id"], 34);
        assert_eq!(ok("missions", json!({"application": "app:412"}))["application"], 120);
        assert_eq!(ok("campaign", json!({"app": "app:412"})), json!({"app": 120}));
        assert_eq!(ok("campaign", json!({"application": 120, "run": "apply"})), json!({"application": 120, "run": "apply"}));
        // What the campaign's next.args call, verbatim.
        assert_eq!(ok("put", json!({"ref": "app:412", "set": {"batch_id": "batch:96"}})), json!({"table": "applications", "id": 120, "set": {"batch_id": 96}}));
        assert_eq!(ok("put", json!({"table": "batches", "set": {"code": "B9", "ordinal": 1}})), json!({"table": "batches", "set": {"code": "B9", "ordinal": 1}}));
        assert_eq!(ok("pick_cv", json!({"ref": "app:412", "cv_root_id": 20})), json!({"table": "applications", "id": 120, "cv_root_id": 20}));
        assert_eq!(ok("ignore", json!({"ref": "outreach:1291"})), json!({"table": "outreach", "id": 1291}));
        assert_eq!(ok("report", json!({"mission": "mission:34", "report": "sent"})), json!({"mission": 34, "report": "sent"}));
        assert_eq!(ok("request_fire_key", json!({"missions": "34-35", "reason": "r"}))["missions"], "34-35");
        assert_eq!(ok("cv", json!({"application": "app:412"}))["application"], 412);
        assert_eq!(ok("lease", json!({"refs": ["app:412", "app:7"], "ids": [120]})), json!({"ids": [120, 3]}));
        assert_eq!(ok("request_fire_key", json!({"missions": "mission:34-35, mission:40", "reason": "r"}))["missions"], "34-35,40");
        assert_eq!(ok("request_fire_key", json!({"missions": ["mission:34-35", "40"], "reason": "r"}))["missions"], "34-35,40");
        assert_eq!(no("request_fire_key", json!({"missions": "app:412", "reason": "r"})).0, "ref");
    }

    #[test]
    fn a_mission_is_put_by_its_kind_and_lowered_to_its_row() {
        let m = ok("put", json!({"ref": "mission:new", "kind": "email", "app": "app:412", "to": ["Dana <dana@acme.com>", "jobs@acme.com"], "cc": "cto@acme.com", "subject": "Hi", "draft": "Hello", "in_reply_to": "outreach:1291", "refs": ["<a@x>", "<b@x>"]}));
        assert_eq!(m, json!({"table": "missions", "set": {"kind": "email", "application_id": 120, "target": "dana@acme.com, jobs@acme.com", "cc": "cto@acme.com", "subject": "Hi", "draft": "Hello", "in_reply_to": "<r1@acme.example>", "refs": "<a@x> <b@x>"}}));
        let c = ok("put", json!({"ref": "mission:new", "kind": "careers_page", "application": "app:7", "form": "https://boards.greenhouse.io/acme/jobs/1", "draft": "- name: Ana"}));
        assert_eq!(c["set"]["target"], "https://boards.greenhouse.io/acme/jobs/1");
        let x = ok("put", json!({"ref": "mission:new", "kind": "x_dm", "app": "app:7", "handle": "@dana", "draft": "hi"}));
        assert_eq!(x["set"]["target"], "dana");
        let l = ok("put", json!({"ref": "mission:new", "kind": "linkedin", "app": "app:7", "contact": "contact:9", "draft": "hi"}));
        assert_eq!((l["set"]["contact_id"].clone(), l["set"].get("target").cloned()), (json!(9), None));
        // An edit of mission 34 (an email) takes the email's keys; set and the union are one.
        let e = ok("put", json!({"ref": "mission:34", "to": "jobs@acme.com", "set": {"draft": "v2"}}));
        assert_eq!(e, json!({"table": "missions", "id": 34, "set": {"kind": "email", "draft": "v2", "target": "jobs@acme.com"}}));
        // Refused at the door: a key of another kind, an unknown key, a target the kind cannot read, a new mission with no app.
        let (code, data) = no("put", json!({"ref": "mission:new", "kind": "email", "app": "app:412", "form": "https://x.y"}));
        assert_eq!((code.as_str(), data["key"].as_str(), data["known"].as_array().is_some_and(|k| k.contains(&json!("to")))), ("shape", Some("form"), true));
        assert_eq!(no("put", json!({"ref": "mission:new", "kind": "careers_page", "app": "app:412", "frm": "https://x.y"})).1["did_you_mean"], "form");
        let (code, data) = no("put", json!({"ref": "mission:new", "kind": "careers_page", "app": "app:412", "form": "http://x.y"}));
        assert_eq!((code.as_str(), data["column"].as_str()), ("type", Some("target")));
        assert_eq!(no("put", json!({"ref": "mission:new", "kind": "email", "to": "a@b.co"})).1["key"], "app");
        assert_eq!(no("put", json!({"ref": "mission:new", "kind": "note", "app": "app:412"})).0, "shape");
        assert_eq!(no("put", json!({"table": "contacts", "set": {"name": "x"}, "to": "a@b.co"})).0, "shape");
        assert_eq!(no("put", json!({"table": "contacts", "set": {"nmae": "x"}})).1["did_you_mean"], "name");
        assert_eq!(no("stage", json!({"ref": "app:412", "stage": "closed", "outcom": "expired"})).1["did_you_mean"], "outcome");
        assert_eq!(mission_schema()["oneOf"].as_array().map(Vec::len), Some(6));
    }
}
