//! Refusals as diagnostics an agent can act on.
//!
//! A NACK or an RPC error names a refusal from the schema's `refusal` enum
//! and carries its data. [`render`] prints it the way rustc prints an
//! error: what was refused, where, the data that decided it, and the next
//! step, ending with `hireme {"explain":"<code>"}`, which returns
//! [`explain`]'s longer text. The texts describe the sequencer's checks in
//! their order (grant, lease, shape, domain, provenance, limits); they say
//! what to do, never re-decide what the kernel decided.

use serde_json::Value as Json;

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
    // natural_key also covers a keyed put on a table that declares no natural key: other words, other advice.
    let nokey = code == "natural_key" && data.get("reason").and_then(Json::as_str).is_some_and(|r| r.contains("no natural key"));
    let (line, todo) = if nokey {
        ("this table declares no natural key", "Put by id, or without key to insert; `schema` with the table lists its keys.".to_owned())
    } else {
        (line, todo)
    };
    let mut out = format!("error[{code}]: {line}\n  --> {what}\n");
    if let Some(msg) = data.get("message").and_then(Json::as_str) {
        out.push_str(&format!("   = note: {msg}\n"));
    }
    if let Some(obj) = data.as_object() {
        for (k, v) in obj {
            if k == "message" {
                continue;
            }
            out.push_str(&format!("   = {k}: {}\n", compact(v)));
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
}
