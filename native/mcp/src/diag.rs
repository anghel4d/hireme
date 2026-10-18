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

/// What a refusal's `reason` (or `need`) says, when it says more than its code: (code, reason, one
/// line, what to do). Every reason the node sends today; a reason not listed here leads the
/// diagnostic in the node's own words, since the code's general line may contradict it.
const REASONS: &[(&str, &str, &str, &str)] = &[
    ("scope", "cited; provenance outlives it", "this row is cited, and provenance outlives it", "Citations name it, so no key may drop it; leave it in place. The operator's drop keeps it as a tombstone the citations still name."),
    ("scope", "a keyed op reads the table", "a keyed op reads the table, and this key cannot read it", "A put by natural key looks the row up first, which needs the table's read mask too. Put by id, or ask the operator for a key that reads this domain."),
    ("scope", "the delete reaches it", "the drop reaches a row this key cannot write", "Dropping this row removes or changes rows on another table (data: table), whose domain the key does not write. Ask the operator for that domain, or leave the row."),
    ("scope", "the lease is for writing", "the lease is for writing, and this key writes nothing", "A read-only key reads without a lease: call `find` and `get` directly."),
    ("lease_missing", "the operator revoked this session's lease; reconnect", "the operator revoked this session's lease", "The operator paused this key: it reads, but writes nothing until they resume it in the account lens. Then call `lease` again."),
    ("lease_missing", "paused by the operator", "the operator paused this key's writing", "Reads still work. Writes and claims wait until the operator resumes the key in the account lens; then call `lease` again."),
    ("column", "append_only", "this table is append-only", "Its rows are only ever inserted: put without id or key to add a row; an existing row is never updated or dropped."),
    ("column", "readonly", "this column is readonly", "The server or a command writes it; leave it out of `set`. `schema` with the table lists the writable columns."),
    ("column", "private", "this column is the operator's private data", "No key writes it; leave it out of `set`."),
    ("column", "required", "a required column is missing or null", "That column is required on a new row; set it to a value, not null."),
    ("column", "implied", "this column is implied by the row it belongs to", "Leave it out; the server fills it."),
    ("column", "a source's identity is fixed once written", "a source's identity is fixed once written", "Its url (and the host derived from it) never changes. To cite another page, put a new source; only retrieved_at and doc move."),
    ("column", "not filterable", "this column cannot be filtered on", "Deferred text, json and bytes columns are not compared in `where`. Filter on another column, or `get` the rows and read them."),
    ("column", "not orderable", "this column cannot order rows", "Deferred text, json, bytes and text columns do not order. Order by another column (id by default)."),
    ("column", "not text", "this column is not text", "`text` reads text columns (a deferred one comes as {len, sha} elsewhere); `get` returns every other column whole."),
    ("type", "an http(s) URL on a real hostname", "a source's url must be http(s) on a real hostname", "Give the page's full URL, e.g. https://example.com/page; the server derives the host from it. A host is ASCII letters, digits and hyphens: write an international one in its punycode form (bücher.example as xn--bcher-kva.example); the path may be any text."),
    ("type", "an http(s) URL or a source id", "source must be an http(s) URL or a source id", "Give `source` as \"https://...\" (the server finds or makes that source) or as an existing source's id."),
    ("type", "inside a character", "the offset falls inside a UTF-8 character", "Continue from the `next` offset the previous `text` answer gave, or from 0."),
    ("type", "compares with null", "only eq and ne compare with null", "Use {\"eq\": null} for an empty cell and {\"ne\": null} for a filled one; lt, gt, prefix and the rest take a value."),
    ("type", "params are a JSON object", "the call's params must be a JSON object", "Send the arguments as an object, e.g. {\"table\": \"places\"}."),
    ("type", "a value of the wrong type", "a value of the wrong type", "Match the column's type (`schema` with the table lists it); the server never casts strings."),
    ("type", "out of range", "the value is out of the column's range", "u8 is 0-255, u32 0-4294967295, i64 64-bit signed; a day is a real calendar day."),
    ("type", "not UTF-8", "the text is not UTF-8", "Send text as UTF-8."),
    ("freshness", "in the future", "as_of is in the future", "as_of is the day the figure was true: today or earlier, as 'YYYY-MM-DD'."),
    ("cap", "text", "the account's text budget is spent", "Long text counts against the account's budget (data: cap, in bytes); a rewrite that shortens a text always lands. Shorten or drop text that no longer matters, or ask the operator."),
    ("not_found", "a ref names no row", "a reference names no row", "A ref column (an ..._id) must name an existing row this key can see; `find` it first, or put the row it names."),
    ("natural_key", "a unique column already holds this value", "a unique column already holds this value", "Another row holds it; `find` that row and update it, or choose another value."),
    ("heat", "company_cap", "this company is at its heat cap", "Too many recent applications here (data: load and cap). Wait, or the operator can set heat_override with a reason."),
    ("heat", "ats_vendor_cap", "this ATS vendor is at its heat cap", "Too many recent applications through this ATS (data: load and cap). Wait, or the operator can set heat_override with a reason."),
    ("heat", "ats_tenant_cap", "this ATS tenant is at its heat cap", "Too many recent applications to this ATS tenant (data: load and cap). Wait, or the operator can set heat_override with a reason."),
    ("heat", "ats_batch_cap", "this ATS is at its cap for the batch", "Too many applications through this ATS in one batch (data: load and cap). Move one to another batch, or the operator can set heat_override with a reason."),
    ("internal", "kernel", "the kernel failed on this op", "Nothing was written. Retry once; if it repeats, tell the operator with the op_id."),
];

/// The reason the node gives a refusal whose site named none: its code's, in the server's words
/// (sequencer.ex `@reasons`). Such a reason says nothing the code does not, so the data's shape decides.
const DEFAULT_REASONS: &[(&str, &str)] = &[
    ("scope", "the key's masks do not allow this"),
    ("human_only", "only the operator's browser session may do this"),
    ("lease_missing", "this session holds no write lease"),
    ("leased", "another session holds this application"),
    ("column", "a column is unknown, not writable, or missing"),
    ("type", "a value does not fit its column"),
    ("not_found", "the row, or a row a ref names, does not exist"),
    ("natural_key", "a row with this natural key already exists"),
    ("stage", "the pipeline does not allow this move"),
    ("fire_hold", "submitted follows only the operator's open_fire"),
    ("heat", "the heat governor defers this move"),
    ("lineage_busy", "the lineage is mid-generation; only new overlays"),
    ("cooldown", "the lineage's cooldown has not passed"),
    ("freshness", "a metric needs as_of no later than today"),
    ("stale", "a newer value is already stored"),
    ("rev", "the row has moved past expect_rev"),
    ("source_missing", "this cell needs a source"),
    ("source_trust", "this source's host is not trusted for this cell"),
    ("too_large", "the op is over its size bound"),
    ("rate", "over the rate limit; retry later"),
    ("cap", "a table or the account is at its cap"),
    ("internal", "the server failed on this op; it wrote nothing"),
];

/// The refusal's own reason: what its site said, not its code's default (flagged, or recognised).
fn site_reason<'a>(code: &str, data: &'a Json) -> Option<&'a str> {
    let r = data.get("reason").and_then(Json::as_str)?;
    let defaulted = data.get("reason_default").and_then(Json::as_bool) == Some(true)
        || DEFAULT_REASONS.iter().any(|d| d.0 == code && d.1 == r)
        || r == code.replace('_', " ");
    (!defaulted).then_some(r)
}

/// What a refusal's `need` asks for: (code, need, one line, what to do).
const NEEDS: &[(&str, &str, &str, &str)] = &[
    ("heat", "reason", "a heat override needs a reason", "Set heat_override_reason to why the cap is lifted, with heat_override."),
    ("cooldown", "open_generation", "this lineage's window has passed: open a new generation", "Call `open_generation` for the lineage (data: lineage_id), then write to the new generation."),
    ("type", "id or key", "this needs the row's id or key", "Give `id`, or `key` with one of the table's keys (`schema` with the table lists them)."),
    ("not_found", "application_id", "this needs an application", "Give the application (its id, or `no` where the tool takes one)."),
    ("not_found", "corporation_id", "the application has no corporation", "Set the application's corporation_id first, then retry."),
];

/// A refusal of `what` (e.g. `put corporations domain=example.com`) as a diagnostic.
pub fn render(code: &str, what: &str, data: &Json) -> String {
    let (line, todo) = advice(code, data);
    let mut out = format!("error[{code}]: {line}\n  --> {what}\n");
    if let Some(msg) = data.get("message").and_then(Json::as_str) {
        out.push_str(&format!("   = note: {msg}\n"));
    }
    if let Some(obj) = data.as_object() {
        for (k, v) in obj {
            // reason_default says only that the reason was the code's, which is already not printed.
            if k == "message" || k == "reason_default" || (k == "reason" && site_reason(code, data).is_none()) {
                continue;
            }
            let shown = match (code, k.as_str()) {
                ("natural_key", "keys" | "unmet") => keys_of(Some(v)).iter().map(key_text).collect::<Vec<_>>().join("; "),
                _ => compact(v),
            };
            // An empty list, map or string says nothing.
            if shown.is_empty() || shown == "[]" || shown == "{}" {
                continue;
            }
            out.push_str(&format!("   = {k}: {shown}\n"));
        }
    }
    if !todo.is_empty() {
        out.push_str(&format!("   = help: {todo}\n"));
    }
    out.push_str(&format!("   = explain: hireme {{\"explain\":\"{code}\"}}\n"));
    out
}

/// The headline and the next step: the most precise thing the data says, else the code's own.
fn advice(code: &str, data: &Json) -> (String, String) {
    let reason = site_reason(code, data);
    let need = data.get("need").and_then(Json::as_str);
    let (line, todo) = REFUSALS
        .iter()
        .find(|r| r.0 == code)
        .map(|r| (r.2.to_owned(), first_sentence(r.3)))
        .unwrap_or(("refused".to_owned(), String::new()));
    // natural_key also covers a keyed put whose cells name no natural key: the table declares none at
    // all, the cells hold none of the keys it declares, or they hold a conditioned key's columns but
    // not its condition (places: iso2 only where kind = 'country'). Other words, other advice.
    if code == "natural_key" && reason.is_some_and(|r| r.contains("no natural key")) {
        return unkeyed_advice(data);
    }
    // A lookup (get, history) by columns no declared key is made of: World names the table's keys.
    if code == "natural_key" && reason == Some("no declared key is made of exactly these columns") {
        let keys = keys_of(data.get("keys"));
        let list = keys.iter().map(key_text).collect::<Vec<_>>().join("; ");
        let help = if keys.is_empty() { "This table declares no key; name the row by id.".to_owned() } else { format!("Name the row by id, or by exactly one of the table's keys: {list}.") };
        return ("no declared key is made of exactly these columns".to_owned(), help);
    }
    if let Some(d) = shaped(code, data) {
        return d;
    }
    if let Some(r) = reason {
        return match REASONS.iter().find(|x| x.0 == code && x.1 == r) {
            Some(x) => (x.2.to_owned(), x.3.to_owned()),
            // The node said why in words this table does not know: lead with them, not a guess.
            None => (r.to_owned(), todo),
        };
    }
    if let Some(n) = need
        && let Some(x) = NEEDS.iter().find(|x| x.0 == code && x.1 == n)
    {
        return (x.2.to_owned(), x.3.to_owned());
    }
    (line, todo)
}

/// Refusals whose meaning is in the shape of their data, not a reason: which fields it carries.
fn shaped(code: &str, data: &Json) -> Option<(String, String)> {
    let text = |k: &str| data.get(k).and_then(Json::as_str);
    let int = |k: &str| data.get(k).and_then(Json::as_u64);
    let list = |k: &str| data.get(k).and_then(Json::as_array).map(|a| a.iter().filter_map(Json::as_str).collect::<Vec<_>>().join(", "));
    match code {
        // A parameter the call left out, or sent as null (World echoes it as inspect(nil): "nil").
        // got is present and null (an older World said "nil"); a param refused without got was given.
        "type" if text("param").is_some() && site_reason(code, data).is_none() && data.get("got").is_some_and(|g| g.is_null() || g.as_str() == Some("nil")) => {
            let p = text("param")?;
            Some((format!("{p} is required here"), format!("Give {p}; the tool's input schema lists what it takes.")))
        }
        // A cursor handed back changed: `after` takes only what an answer's `next` gave.
        "type" if text("param") == Some("after") && site_reason(code, data).is_none() => Some((
            "after is not a cursor this answer gave".to_owned(),
            "Pass `after` back exactly as the previous answer's `next` gave it, or leave it out to start from the first row.".to_owned(),
        )),
        "too_large" => match (int("limit"), int("max"), text("filter"), text("param")) {
            // `text` reads by length from an offset; find pages rows.
            (Some(n), Some(max), _, Some("length")) => Some((format!("a length of {n} is over the cap of {max}"), format!("Read at most {max} at a time and continue from the answer's next offset."))),
            (Some(n), Some(max), _, _) => Some((format!("a limit of {n} is over the cap of {max}"), format!("Ask for at most {max} rows and page on with `after`."))),
            (_, Some(max), Some("in"), _) => Some((format!("an `in` list over {max} values"), format!("Split the list into calls of at most {max} values each."))),
            // like and prefix take a pattern, bounded in bytes.
            (_, Some(max), Some(f), _) => Some((format!("a `{f}` pattern over {max} bytes"), format!("Shorten the pattern to at most {max} bytes."))),
            (_, _, _, Some("offset")) => Some(("the offset is past any text".to_owned(), "Give an offset inside the text: below the `len` of its {len, sha} stub.".to_owned())),
            _ => None,
        },
        "column" => {
            let missing = list("missing")?;
            Some(match text("command") {
                Some(c) => (format!("{c} needs {missing}"), format!("Give {missing} in the command's params.")),
                None => (format!("a new row lacks its required columns: {missing}"), format!("Add {missing} to `set`, or name an existing row by id or key.")),
            })
        }
        // A ref cell naming a row that does not exist (the sequencer's {column, id}; a missing row of the
        // op's own table says {table, id}).
        "not_found" if text("column").is_some() && int("id").is_some() && data.get("table").is_none() => {
            let (c, id) = (text("column")?, int("id")?);
            Some((format!("{c} {id} names no row"), format!("{c} must name an existing row this key can see; `find` it first, or put that row and use its id.")))
        }
        // A source named by an id that is no live source (dropped: a tombstone is never cited again).
        "source_missing" if int("source").is_some() => {
            let id = int("source")?;
            Some((format!("no live source has id {id}"), "That source was dropped or never existed. Cite by URL (\"source\": \"https://...\"), which finds or makes a source, or by a live source's id from `find`.".to_owned()))
        }
        _ => None,
    }
}

/// Every (code, reason) and (code, need) the diagnostics describe, for tests.
#[cfg(test)]
fn described() -> impl Iterator<Item = (&'static str, &'static str)> {
    let special = [("natural_key", "no declared key is made of exactly these columns")];
    REASONS.iter().map(|r| (r.0, r.1)).chain(NEEDS.iter().map(|r| (r.0, r.1))).chain(special)
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
        // One step per set of missing columns, naming each key's condition (its values), never twice.
        let mut steps: Vec<(Vec<String>, Vec<String>)> = Vec::new();
        for k in &unmet {
            let missing = listed(k, "missing");
            let cond = format!("{} for {}", k.get("where").and_then(Json::as_str).unwrap_or("its condition"), listed(k, "cols").join(" + "));
            let group = if missing.is_empty() { listed(k, "reads") } else { missing.clone() };
            let tag = if missing.is_empty() { "set" } else { "add" };
            let key = [vec![tag.to_owned()], group].concat();
            match steps.iter_mut().find(|s| s.0 == key) {
                Some(s) if !s.1.contains(&cond) => s.1.push(cond),
                Some(_) => {}
                None => steps.push((key, vec![cond])),
            }
        }
        let fix = steps
            .iter()
            .map(|(key, conds)| {
                let cols = key[1..].join(", ");
                let conds = conds.join("; ");
                if key[0] == "add" { format!("add {cols} to the cells ({conds})") } else { format!("set {cols} so that the condition holds ({conds})") }
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
        assert!(absent.contains("= help: Add kind to the cells (kind = 'country' for iso2), or put by id."), "{absent}");
        assert!(absent.contains("= keys: iso2 where kind = 'country'; geonames_id where kind = 'city'"), "{absent}");
        assert!(!absent.contains("geonames_id is a key"), "{absent}");
        let wrong = place(serde_json::json!({"unmet": [{"cols": ["iso2"], "where": "kind = 'country'", "reads": ["kind"], "missing": []}]}));
        assert!(wrong.contains("= help: Set kind so that the condition holds (kind = 'country' for iso2), or put by id."), "{wrong}");
        let bare = place(serde_json::json!({"missing": ["kind"]}));
        assert!(bare.contains("iso2 is a key only where kind = 'country'; geonames_id is a key only where kind = 'city'"), "{bare}");
        let neither = place(serde_json::json!({}));
        assert!(neither.contains("with its condition met: iso2 where kind = 'country'; geonames_id where kind = 'city'"), "{neither}");
        assert_eq!(natural_key(&serde_json::json!(["domain"])), Some(serde_json::json!({"cols": ["domain"], "where": null, "reads": []})));
        let taken = render("natural_key", "put t x=1", &serde_json::json!({"table": "t", "key": {"domain": "a.com"}}));
        assert!(taken.contains("a row with this natural key exists"), "{taken}");
    }

    #[test]
    fn a_reason_the_node_sends_is_described_and_never_contradicted() {
        // Every (code, reason) and (code, need) the node and the kernel send today (sequencer, world,
        // provenance, session, lease, judge and the heat governor).
        let sent = [
            ("scope", "cited; provenance outlives it"), ("scope", "a keyed op reads the table"), ("scope", "the delete reaches it"),
            ("scope", "the lease is for writing"), ("lease_missing", "the operator revoked this session's lease; reconnect"), ("lease_missing", "paused by the operator"),
            ("column", "append_only"), ("column", "readonly"), ("column", "private"), ("column", "required"), ("column", "implied"),
            ("column", "a source's identity is fixed once written"), ("column", "not filterable"), ("column", "not orderable"), ("column", "not text"),
            ("type", "an http(s) URL on a real hostname"), ("type", "an http(s) URL or a source id"), ("type", "inside a character"),
            ("type", "compares with null"), ("type", "params are a JSON object"), ("type", "a value of the wrong type"), ("type", "out of range"),
            ("type", "not UTF-8"), ("freshness", "in the future"), ("cap", "text"), ("not_found", "a ref names no row"),
            ("natural_key", "a unique column already holds this value"), ("heat", "company_cap"), ("heat", "ats_vendor_cap"),
            ("heat", "ats_tenant_cap"), ("heat", "ats_batch_cap"), ("internal", "kernel"),
            ("natural_key", "no declared key is made of exactly these columns"),
            ("heat", "reason"), ("cooldown", "open_generation"), ("not_found", "application_id"), ("not_found", "corporation_id"), ("type", "id or key"),
        ];
        let known: Vec<_> = described().collect();
        for (code, r) in sent {
            assert!(known.contains(&(code, r)), "{code} {r} is not described");
            let field = if NEEDS.iter().any(|x| x.0 == code && x.1 == r) { "need" } else { "reason" };
            let d = render(code, "put t", &serde_json::json!({ field: r }));
            let general = REFUSALS.iter().find(|x| x.0 == code).unwrap().2;
            assert!(!d.starts_with(&format!("error[{code}]: {general}\n")), "{d}");
        }
        let cited = render("scope", "drop sources id=3", &serde_json::json!({"table": "sources", "reason": "cited; provenance outlives it"}));
        assert!(cited.starts_with("error[scope]: this row is cited, and provenance outlives it\n") && !cited.contains("write mask"), "{cited}");
        let future = render("freshness", "put t", &serde_json::json!({"column": "as_of", "reason": "in the future"}));
        assert!(future.contains("today or earlier") && !future.contains("needs as_of"), "{future}");
        let budget = render("cap", "put t", &serde_json::json!({"table": "account", "reason": "text", "cap": 1}));
        assert!(budget.contains("text budget") && !budget.contains("the table is full"), "{budget}");
        // A reason this table does not know leads in the node's own words.
        for got in [serde_json::json!(null), serde_json::json!("nil")] {
            let left_out = render("type", "history places", &serde_json::json!({"param": "id", "got": got}));
            assert!(left_out.starts_with("error[type]: id is required here\n"), "{left_out}");
        }
        let mid = render("type", "text", &serde_json::json!({"param": "offset", "reason": "inside a character"}));
        assert!(mid.starts_with("error[type]: the offset falls inside a UTF-8 character\n"), "{mid}");
        let cursor = render("type", "find places", &serde_json::json!({"param": "after"}));
        assert!(!cursor.contains("required"), "{cursor}");
        assert!(cursor.starts_with("error[type]: after is not a cursor this answer gave\n"), "{cursor}");
        let wrong = render("type", "history places", &serde_json::json!({"param": "id", "got": "\"x\""}));
        assert!(wrong.starts_with("error[type]: the value does not fit"), "{wrong}");
        let shaped = [
            ("type", serde_json::json!({"table": "places", "need": "id or key"}), "this needs the row's id or key"),
            ("too_large", serde_json::json!({"limit": 900, "max": 500}), "a limit of 900 is over the cap of 500"),
            ("too_large", serde_json::json!({"column": "id", "filter": "in", "max": 1000}), "an `in` list over 1000 values"),
            ("too_large", serde_json::json!({"column": "name", "filter": "prefix", "max": 1000}), "a `prefix` pattern over 1000 bytes"),
            ("too_large", serde_json::json!({"param": "offset"}), "the offset is past any text"),
            ("too_large", serde_json::json!({"limit": 2000000, "max": 1048576, "param": "length"}), "a length of 2000000 is over the cap of 1048576"),
            ("too_large", serde_json::json!({"bytes": 2000000, "max": 1048576}), "more than 1 MiB of text in one op"),
            ("column", serde_json::json!({"table": "corporations", "missing": ["name"]}), "a new row lacks its required columns: name"),
            ("column", serde_json::json!({"command": "open_generation", "missing": ["lineage_id"]}), "open_generation needs lineage_id"),
            ("source_missing", serde_json::json!({"source": 7}), "no live source has id 7"),
            ("not_found", serde_json::json!({"column": "corporation_id", "id": 999999}), "corporation_id 999999 names no row"),
            ("not_found", serde_json::json!({"table": "corporations", "id": 4}), "no such row, table or command"),
            ("source_missing", serde_json::json!({"table": "corporations", "column": "headcount"}), "this write needs a source"),
        ];
        for (code, mut data, line) in shaped {
            let d = render(code, "op", &data);
            assert!(d.starts_with(&format!("error[{code}]: {line}\n")), "{d}");
            // The node fills in its code's default reason where the site gave none: it decides nothing.
            if data.get("reason").is_none() {
                let default = DEFAULT_REASONS.iter().find(|x| x.0 == code).unwrap().1;
                data["reason"] = serde_json::json!(default);
                let d = render(code, "op", &data);
                assert!(d.starts_with(&format!("error[{code}]: {line}\n")) && !d.contains("= reason:"), "{d}");
                data["reason_default"] = serde_json::json!(true);
                let d = render(code, "op", &data);
                assert!(d.starts_with(&format!("error[{code}]: {line}\n")) && !d.contains("reason"), "{d}");
            }
        }
        let left = render("type", "history places", &serde_json::json!({"param": "id", "got": null, "reason": "a value does not fit its column"}));
        assert!(left.starts_with("error[type]: id is required here\n"), "{left}");
        let taken = render("natural_key", "put", &serde_json::json!({"table": "t", "key": {"domain": "a"}, "reason": "a row with this natural key already exists"}));
        assert!(taken.contains("a row with this natural key exists"), "{taken}");
        let odd = render("column", "put t", &serde_json::json!({"reason": "something new"}));
        assert!(odd.starts_with("error[column]: something new\n"), "{odd}");
    }

    #[test]
    fn a_lookup_by_columns_no_key_is_made_of_says_so() {
        let keys = serde_json::json!([{"cols": ["iso2"], "where": "kind = 'country'", "reads": ["kind"]}, {"cols": ["geonames_id"], "where": "kind = 'city'", "reads": ["kind"]}]);
        let d = render("natural_key", "get places name=Berlin", &serde_json::json!({"table": "places", "key": ["name"], "reason": "no declared key is made of exactly these columns", "keys": keys}));
        assert!(d.starts_with("error[natural_key]: no declared key is made of exactly these columns\n"), "{d}");
        assert!(d.contains("exactly one of the table's keys: iso2 where kind = 'country'; geonames_id where kind = 'city'."), "{d}");
        assert!(!d.contains("exists") && !d.contains("create_only"), "{d}");
        let taken = render("natural_key", "put corporations domain=a.com", &serde_json::json!({"table": "corporations", "key": {"domain": "a.com"}}));
        assert!(taken.contains("a row with this natural key exists"), "{taken}");
    }

    #[test]
    fn both_conditioned_keys_without_their_condition_ask_once_and_name_the_values() {
        let k = |c: &str, v: &str| serde_json::json!({"cols": [c], "where": format!("kind = '{v}'"), "reads": ["kind"], "missing": ["kind"]});
        let d = render("natural_key", "put places iso2=DE geonames_id=1", &serde_json::json!({"table": "places", "reason": "no natural key among the cells", "keys": [], "unmet": [k("iso2", "country"), k("geonames_id", "city")]}));
        assert!(d.contains("= help: Add kind to the cells (kind = 'country' for iso2; kind = 'city' for geonames_id), or put by id."), "{d}");
        assert_eq!(d.matches("add kind").count() + d.matches("Add kind").count(), 1, "{d}");
        assert!(!d.contains("= keys: \n"), "{d}");
    }
}
