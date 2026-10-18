//! Refusals as diagnostics an agent can act on.
//!
//! A NACK or an RPC error names a refusal from the schema's `refusal` enum
//! and carries its data. [`render`] prints it the way rustc prints an
//! error: what was refused, where, the data that decided it, and the next
//! step, ending with `hireme {"explain":"<code>"}`, which returns
//! [`explain`]'s longer text. The texts describe the sequencer's checks in
//! their order (grant, lease, shape, domain, provenance, limits); they say
//! what to do, never re-decide what the kernel decided.

use serde_json::{Value as Json, json};

/// (name, which check, one line, what to do).
const REFUSALS: &[(&str, &str, &str, &str)] = &[
    ("scope", "grant", "the key's masks do not cover this", "A key's write mask names the domains it may write (world 1, desk 2, mail 4, lanes 8, corpus 16) and a drop needs may_delete. Ask the operator for a key with the domain; a key never widens itself."),
    ("human_only", "grant", "only the operator may do this", "Commands and columns marked human_only (open_fire, batches.fire) are refused to every key. Leave it for the operator; FIRE HOLD stands."),
    ("lease_missing", "lease", "this session holds no lease", "Writes need the channel open. Call `lease` ({} opens it without claims, {\"count\":16} claims the 16 best unclaimed applications), then retry."),
    ("leased", "lease", "another session holds this application", "The data names the holder's label and since. Work on another application, or ask the operator to revoke that lease."),
    ("column", "shape", "no such writable column", "The column does not exist on this table, is readonly (written by the server or a command), server_only, or private. Call `schema` with the table for its writable columns."),
    ("type", "shape", "the value does not fit the column's type", "Ints for u8/u32/i64, numbers for f64, true/false for bool, 'YYYY-MM-DD' for a day, ISO-8601 UTC for a time, an enum's value by name. The server never casts strings."),
    ("not_found", "shape", "no such row, table or command", "The id or natural key names nothing this key can see. `find` it first."),
    ("natural_key", "shape", "a row with this natural key exists", "create_only refuses an existing natural key. Drop create_only to update that row, or `get` it by key."),
    ("stage", "domain", "the pipeline does not allow this move", "Stages move along the rail (discovered, freshness, gated, in_batch, draft_ready, fire_ready, open_fire, submitted, reply, closed). The data names the move (from, to) and the rule that refused it."),
    ("fire_hold", "domain", "FIRE HOLD: nothing past fire_ready without the operator", "No agent opens fire or submits. Leave the application at fire_ready."),
    ("heat", "domain", "the company or vendor is over its heat cap", "Too many recent applications at this company, vendor or department. The data names the load and the cap. Wait, or the operator can set heat_override with a reason."),
    ("lineage_busy", "domain", "the CV lineage for this corporation is busy", "Another application holds the lineage's current generation. Use the same generation, or `open_generation` when rewrites are allowed."),
    ("cooldown", "domain", "too soon after the last attempt", "The data names when the cooldown ends."),
    ("freshness", "provenance", "a metric needs as_of", "Every metric write carries the day the figure is true as of: put {..., \"as_of\":\"YYYY-MM-DD\"}."),
    ("stale", "provenance", "older than the stored figure", "The cell already holds a figure as of a later day (data: stored _on). Only newer figures replace older ones; history keeps both."),
    ("rev", "provenance", "prose needs the row's current rev", "Prose (about, culture, liveability, notes) is compare-and-swap: put with \"expect_rev\" set to the row's rev from `get`. A changed rev means someone wrote first; re-read and merge."),
    ("source_missing", "provenance", "this write needs a source", "Prose and metrics cite where they came from: put {..., \"source\":\"https://...\"} (the server derives the host)."),
    ("source_trust", "provenance", "this source's host is not trusted for this", "Culture and ratings come only from hosts the operator trusts (levels.fyi and the like). Cite one of those, or leave the cell."),
    ("too_large", "limits", "more than 1 MiB of text in one op", "Split the text, or store the raw listing once and refer to it."),
    ("rate", "limits", "over the agent write rate", "600 ops a minute per key. Nothing of the refused op was written: wait the data's retry_ms, then call again."),
    ("cap", "limits", "the table is full for this account", "The table's row cap is reached (data: cap). Drop rows that no longer matter, or ask the operator."),
    ("internal", "limits", "the server failed", "Nothing was written. Retry once; if it repeats, tell the operator with the op_id."),
];

pub fn names() -> impl Iterator<Item = &'static str> {
    REFUSALS.iter().map(|r| r.0)
}

/// The long text for `hireme {"explain":code}`; None for an unknown code.
pub fn explain(code: &str) -> Option<String> {
    REFUSALS.iter().find(|r| r.0 == code).map(|(name, check, line, todo)| {
        format!("{name} ({check} check): {line}.\n\n{todo}\n\nThe sequencer checks every op in order: grant, lease, shape, domain, provenance, limits; the first that fails is the refusal, and nothing of the op is written.")
    })
}

/// A refusal of `what` (e.g. `put corporations domain=example.com`) as a diagnostic.
pub fn render(code: &str, what: &str, data: &Json) -> String {
    let (line, todo) = REFUSALS
        .iter()
        .find(|r| r.0 == code)
        .map(|r| (r.2, first_sentence(r.3)))
        .unwrap_or(("refused", String::new()));
    // natural_key also covers a keyed put whose cells name no natural key: the table declares none at
    // all, the cells hold none of the keys it declares, or they hold a conditioned key's columns but
    // not its condition (places: iso2 only where kind = 'country'). Other words, other advice.
    let unkeyed = code == "natural_key" && data.get("reason").and_then(Json::as_str).is_some_and(|r| r.contains("no natural key"));
    let (line, todo): (String, String) = if unkeyed { unkeyed_advice(data) } else { (line.to_owned(), todo) };
    let mut out = format!("error[{code}]: {line}\n  --> {what}\n");
    if let Some(msg) = data.get("message").and_then(Json::as_str) {
        out.push_str(&format!("   = note: {msg}\n"));
    }
    if let Some(obj) = data.as_object() {
        for (k, v) in obj {
            if k == "message" {
                continue;
            }
            let shown = match (code, k.as_str()) {
                ("natural_key", "keys" | "unmet") => keys_of(Some(v)).iter().map(key_text).collect::<Vec<_>>().join("; "),
                _ => compact(v),
            };
            out.push_str(&format!("   = {k}: {shown}\n"));
        }
    }
    // A refusal's data can say more precisely what to do than its code's general advice.
    let todo = match (code, data.get("missing").and_then(Json::as_array)) {
        ("column", Some(cols)) => format!(
            "A new row needs its required columns: {}. Add them to `set`, or name an existing row by id or key.",
            cols.iter().filter_map(Json::as_str).collect::<Vec<_>>().join(", ")
        ),
        _ if code == "column" && data.get("reason").and_then(Json::as_str) == Some("required") => {
            "That column is required on a new row; set it to a value, not null.".to_owned()
        }
        _ => todo,
    };
    if !todo.is_empty() {
        out.push_str(&format!("   = help: {todo}\n"));
    }
    out.push_str(&format!("   = explain: hireme {{\"explain\":\"{code}\"}}\n"));
    out
}

/// A natural key as the node reports it, in either shape: a bare column list (an older node) or
/// `{cols, where, reads}` (and, in a refusal's `unmet`, `missing`). Normalised to the object.
pub fn natural_key(v: &Json) -> Option<Json> {
    let strs = |v: Option<&Json>| -> Vec<String> { v.and_then(Json::as_array).map(|a| a.iter().filter_map(Json::as_str).map(str::to_owned).collect()).unwrap_or_default() };
    if v.is_array() {
        return Some(json!({"cols": strs(Some(v)), "where": null, "reads": []}));
    }
    let o = v.as_object()?;
    let mut k = json!({"cols": strs(o.get("cols")), "where": o.get("where").and_then(Json::as_str), "reads": strs(o.get("reads"))});
    if let Some(m) = o.get("missing") {
        k["missing"] = json!(strs(Some(m)));
    }
    Some(k)
}

fn keys_of(v: Option<&Json>) -> Vec<Json> {
    v.and_then(Json::as_array).map(|a| a.iter().filter_map(natural_key).collect()).unwrap_or_default()
}

fn listed(k: &Json, field: &str) -> Vec<String> {
    k.get(field).and_then(Json::as_array).map(|a| a.iter().filter_map(Json::as_str).map(str::to_owned).collect()).unwrap_or_default()
}

/// `iso2 where kind = 'country'`, or `domain`.
fn key_text(k: &Json) -> String {
    let cols = listed(k, "cols").join(" + ");
    match k.get("where").and_then(Json::as_str) {
        Some(w) => format!("{cols} where {w}"),
        None => cols,
    }
}

/// The headline and advice for a keyed put whose cells name no natural key.
fn unkeyed_advice(data: &Json) -> (String, String) {
    let table = data.get("table").and_then(Json::as_str).unwrap_or("this table");
    let keys = keys_of(data.get("keys"));
    let mut unmet = keys_of(data.get("unmet"));
    // A node that says only which condition columns were missing: the conditioned keys reading them.
    if unmet.is_empty() {
        let missing = listed(data, "missing");
        if !missing.is_empty() {
            unmet = keys
                .iter()
                .filter(|k| k.get("where").is_some_and(Json::is_string) && listed(k, "reads").iter().any(|r| missing.contains(r)))
                .map(|k| {
                    let mut k = k.clone();
                    k["missing"] = json!(listed(&k, "reads").into_iter().filter(|r| missing.contains(r)).collect::<Vec<_>>());
                    k
                })
                .collect();
        }
    }
    if !unmet.is_empty() {
        let line = unmet
            .iter()
            .map(|k| format!("{} is a key only where {}", listed(k, "cols").join(" + "), k.get("where").and_then(Json::as_str).unwrap_or("its condition holds")))
            .collect::<Vec<_>>()
            .join("; ");
        let fix = unmet
            .iter()
            .map(|k| match listed(k, "missing") {
                m if !m.is_empty() => format!("add {} to the cells", m.join(", ")),
                _ => format!("set {} so that {} holds", listed(k, "reads").join(", "), k.get("where").and_then(Json::as_str).unwrap_or("its condition")),
            })
            .collect::<Vec<_>>()
            .join("; or ");
        let mut fix = fix;
        if let Some(f) = fix.get_mut(..1) {
            f.make_ascii_uppercase();
        }
        return (format!("{table}: {line}"), format!("{fix}, or put by id."));
    }
    if keys.is_empty() {
        return ("this table declares no natural key".to_owned(), "Put by id, or without key to insert; `schema` with the table lists its keys.".to_owned());
    }
    if keys.iter().any(|k| k.get("where").is_some_and(Json::is_string)) {
        let list = keys.iter().map(key_text).collect::<Vec<_>>().join("; ");
        return ("the cells hold none of this table's natural keys".to_owned(), format!("Give every column of one key, with its condition met: {list}. Or put by id."));
    }
    ("the cells hold none of this table's natural keys".to_owned(), "Give every column of one of the listed keys, or put by id.".to_owned())
}

/// A call whose arguments are wrong before anything is sent.
pub fn usage(tool: &str, problem: &str, shape: &str) -> String {
    format!("error[usage]: {problem}\n  --> {tool}\n   = shape: {tool} {shape}\n")
}

fn first_sentence(s: &str) -> String {
    match s.find(". ") {
        Some(i) => s[..=i].to_owned(),
        None => s.to_owned(),
    }
}

fn compact(v: &Json) -> String {
    match v {
        Json::String(s) => s.clone(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_refusal_renders_with_its_explain_pointer() {
        for name in names() {
            let d = render(name, "put corporations domain=example.com", &serde_json::json!({"cap": 50000}));
            assert!(d.starts_with(&format!("error[{name}]")), "{d}");
            assert!(d.contains(&format!("hireme {{\"explain\":\"{name}\"}}")), "{d}");
            assert!(explain(name).is_some());
        }
        assert!(explain("nope").is_none());
    }

    #[test]
    fn every_refusal_the_schema_declares_is_explained_and_no_other() {
        assert_eq!(names().collect::<Vec<_>>(), schema::refusal::NAMES.to_vec());
    }

    #[test]
    fn a_keyed_put_naming_no_key_says_whether_the_table_declares_any() {
        let refused = |keys: Json| render("natural_key", "put t x=1", &serde_json::json!({"table": "t", "reason": "no natural key among the cells", "keys": keys}));
        let none = refused(serde_json::json!([]));
        assert!(none.contains("this table declares no natural key"), "{none}");
        let some = refused(serde_json::json!([["domain"]]));
        assert!(some.contains("the cells hold none of this table's natural keys"), "{some}");
        assert!(!some.contains("declares no natural key"), "{some}");
        let conditioned = serde_json::json!([{"cols": ["iso2"], "where": "kind = 'country'", "reads": ["kind"]}, {"cols": ["geonames_id"], "where": "kind = 'city'", "reads": ["kind"]}]);
        let place = |extra: Json| {
            let mut d = serde_json::json!({"table": "places", "reason": "no natural key among the cells", "keys": conditioned});
            d.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            render("natural_key", "put places iso2=DE", &d)
        };
        let absent = place(serde_json::json!({"unmet": [{"cols": ["iso2"], "where": "kind = 'country'", "reads": ["kind"], "missing": ["kind"]}]}));
        assert!(absent.starts_with("error[natural_key]: places: iso2 is a key only where kind = 'country'\n"), "{absent}");
        assert!(absent.contains("= help: Add kind to the cells, or put by id."), "{absent}");
        assert!(absent.contains("= keys: iso2 where kind = 'country'; geonames_id where kind = 'city'"), "{absent}");
        assert!(!absent.contains("geonames_id is a key"), "{absent}");
        let wrong = place(serde_json::json!({"unmet": [{"cols": ["iso2"], "where": "kind = 'country'", "reads": ["kind"], "missing": []}]}));
        assert!(wrong.contains("= help: Set kind so that kind = 'country' holds, or put by id."), "{wrong}");
        let bare = place(serde_json::json!({"missing": ["kind"]}));
        assert!(bare.contains("iso2 is a key only where kind = 'country'; geonames_id is a key only where kind = 'city'"), "{bare}");
        let neither = place(serde_json::json!({}));
        assert!(neither.contains("with its condition met: iso2 where kind = 'country'; geonames_id where kind = 'city'"), "{neither}");
        assert_eq!(natural_key(&serde_json::json!(["domain"])), Some(serde_json::json!({"cols": ["domain"], "where": null, "reads": []})));
        let taken = render("natural_key", "put t x=1", &serde_json::json!({"table": "t", "key": {"domain": "a.com"}}));
        assert!(taken.contains("a row with this natural key exists"), "{taken}");
    }
}
