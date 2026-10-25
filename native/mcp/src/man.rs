//! Manual pages the Unix way (docs/mcp/campaigns.md): `man <page>`, `man -k <word>`, and every
//! tool's `-h`. Section 1 is the tools this key may call, 5 the tables it can see, 7 the campaigns,
//! the concepts and the refusal codes, 8 the operator's own commands. Tool and table pages are
//! built from the same catalog `tools/list` and `schema` answer, so a page never disagrees with
//! the tool; section 7 is written here, the refusal pages are `diag`'s texts.

use serde_json::Value as Json;

use crate::tools::{self, Masks};

/// What `hireme`, `initialize` and every `-h` open with.
pub const CAMPAIGNS: &str = "CAMPAIGNS  start here; every answer ends with the next call\n  apply      one application from listing to outcome   campaign {\"run\":\"apply\"}\n";

/// The footer every refusal ends with.
pub fn footer(code: &str) -> String {
    format!("help: man {code}\n")
}

/// Section 7, written by hand: (name, one line, body).
const CONCEPTS: &[(&str, &str, &str)] = &[
    (
        "campaigns",
        "golden routes: the next call, always",
        "A campaign walks one piece of work to its end, reading hireme's state on every call and naming the one next step. Nothing about a campaign is stored: the step is worked out from the rows, so it never drifts from them. Every surgical tool still works on its own; a campaign only says which to call next.\n\nCAMPAIGNS\n  apply   one application from listing to outcome (man apply)\n\nSEE ALSO\n  man apply, man hints, man refs",
    ),
    (
        "apply",
        "one application from listing to outcome",
        "SYNOPSIS\n  campaign {\"run\":\"apply\"}          pick the application closest to done and say its next step\n  campaign {\"app\":\"app:412\"}         the step of one application\n\nDESCRIPTION\n  Thirteen phases, each derived from the rows:\n   1 acquire    the listing is a row (canonical_url keys it; a second copy updates the first)\n   2 link       corporation_id, and place_id unless remote (man unlinked)\n   3 qualify    freshness, gate, heat, a prior send to settle\n   4 route      one primary route (careers page, email, referral, reply to a recruiter, cold email) and follow-ups\n   5 batch      today's day_pack: the stage rail needs a batch\n   6 documents  the CV pick, the letter when the route carries one, the battleplan\n   7 stage      one mission per route, typed by kind, to fire_ready\n   8 fire key   ask the user for the key: request_fire_key, then give the operator the review link and stop\n   9 fire       lease, fire under the key, report (an email reports itself)\n  10 confirm    a confirmation mail confirms a careers-page shot; a bounce routes again without that route\n  11 follow-up  linkedin note day 0-1, email nudges day 7 and 14, ghosted at day 30; a reply stops every timer\n  12 reply      read it; interview or question: reply; rejection: close; offer or assessment: the operator\n  13 close      an outcome: unsent (expired, skipped, withdrawn) or sent (offer, rejected, ghosted, withdrawn, declined)\n\n  Where the state leaves one way forward the campaign railroads; where it branches, the rows pick the branch.\n  Waits name their date; operator steps name what to ask the user.\n\nSEE ALSO\n  man campaigns, man hints, man fire-keys, man stage-rail",
    ),
    (
        "hints",
        "how an answer reads",
        "Every answer is its payload, then at most two lines:\n  green    a success, cargo style:           Landed mission:34 careers_page · ref GH-4410\n  cyan     next[phase]: the next call, or help: where to read more\n  yellow   warning[code]: something is off, the work can go on\n  red      error[code]: refused, then --> where, = notes, and help: man <code>\nColour is ANSI; NO_COLOR in the daemon's environment or hireme {\"color\":false} turns it off. The words are the same either way.",
    ),
    (
        "refs",
        "naming a row",
        "A row is named by its kind and key: app:412 (an application's no), mission:34, contact:9, corp:example.com, place:3, outreach:1291, batch:96, fire_key:51, fire_request:88. {\"ref\":\"app:412\"} names the row for get, put, drop and commands. A ref of the wrong kind is refused: a mission field takes mission:…, never app:….",
    ),
    (
        "fire-keys",
        "the operator's authority to send",
        "Nothing leaves without a fire key, and only the operator creates one, with a fresh second factor. Stage a mission to fire_ready (its hash freezes), ask with request_fire_key {\"missions\":\"34-35\",\"reason\":\"...\"}, then ask the user to grant it at the review link the answer gives. A key covers each named mission once, lives a week unused and 24 hours from its first shot, and refuses a mission whose target or draft changed since approval.\n\nSEE ALSO\n  man fire, man apply",
    ),
    (
        "stage-rail",
        "an application's stages",
        "discovered, freshness, gated, in_batch, draft_ready, fire_ready, open_fire, submitted, reply, closed. in_batch onward needs a batch. A landed mission moves its application to submitted; nothing returns to a stage before submitted once it went out. The stage command moves it; a refusal names the rule (needs_batch, sent, not_sent, fire_hold).",
    ),
];

/// One page by its name, optionally prefixed by its section (`7 apply`, `5 missions`).
pub fn page(m: Masks, query: &str) -> Option<String> {
    let q = query.trim();
    let (section, name) = match q.split_once(' ') {
        Some((s, n)) if s.len() == 1 && s.chars().all(|c| c.is_ascii_digit()) => (s.parse::<u8>().ok(), n.trim()),
        _ => (None, q),
    };
    let want = |s: u8| section.is_none_or(|x| x == s);
    if want(7)
        && let Some((n, line, body)) = CONCEPTS.iter().find(|c| c.0 == name)
    {
        return Some(format!("{}(7)  {n} — {line}\n\n{body}\n", n.to_uppercase()));
    }
    if want(1)
        && let Some(t) = tools::list(m).into_iter().find(|t| t["name"] == name)
    {
        return Some(tool_page(&t));
    }
    if want(7)
        && let Some(text) = crate::diag::explain(name)
    {
        return Some(format!("{}(7)  {name} — a refusal\n\n{text}\n\nSEE ALSO\n  man campaigns\n", name.to_uppercase()));
    }
    if want(5)
        && let Some(t) = tools::table_named(name).filter(|t| t.residency.stored() && (m.reads(t) || m.writes(t)))
    {
        return Some(table_page(&tools::describe(t, m)));
    }
    if want(8)
        && let Some(c) = schema::COMMANDS.iter().find(|c| c.human_only && c.name == name)
    {
        return Some(format!("{}(8)  {} — the operator's command on {}\n\nOnly the operator runs it, from the browser. No key can; leave it to them, and ask the user when a campaign needs it.\n", c.name.to_uppercase(), c.name, tools::table_name(c.table)));
    }
    None
}

/// `-h`: the page's head, in a dozen lines.
pub fn short(m: Masks, tool: &str) -> String {
    let synopsis = crate::shape(tool).map(|s| format!("usage: {tool} {s}\n")).unwrap_or_default();
    let line = tools::list(m).into_iter().find(|t| t["name"] == tool).and_then(|t| t["description"].as_str().map(first_sentence)).unwrap_or_default();
    format!("{tool}: {line}\n{synopsis}see: man {tool} · campaign apply -h\n")
}

/// `man -k`: every page whose name or first line holds the word.
pub fn apropos(m: Masks, word: &str) -> String {
    let w = word.to_lowercase();
    let mut out = String::new();
    let mut hit = |section: u8, name: &str, line: &str| {
        if name.to_lowercase().contains(&w) || line.to_lowercase().contains(&w) {
            out.push_str(&format!("{name} ({section}) - {line}\n"));
        }
    };
    for (n, line, _) in CONCEPTS {
        hit(7, n, line);
    }
    for t in tools::list(m) {
        hit(1, t["name"].as_str().unwrap_or(""), &first_sentence(t["description"].as_str().unwrap_or("")));
    }
    for code in crate::diag::names() {
        hit(7, code, "a refusal");
    }
    for t in schema::TABLES.iter().filter(|t| t.residency.stored() && (m.reads(t) || m.writes(t))) {
        hit(5, t.name, "a table");
    }
    if out.is_empty() { format!("{word}: nothing appropriate\n") } else { out }
}

/// `man` alone: what there is to read.
pub fn index(m: Masks) -> String {
    let tools: Vec<String> = tools::list(m).iter().filter_map(|t| t["name"].as_str().map(str::to_owned)).collect();
    let tables: Vec<&str> = schema::TABLES.iter().filter(|t| t.residency.stored() && (m.reads(t) || m.writes(t))).map(|t| t.name).collect();
    format!(
        "{CAMPAIGNS}\nSECTIONS  man <page>, man {{\"page\":\"7 apply\"}}, man {{\"k\":\"word\"}}\n  1 tools     {}\n  5 tables    {}\n  7 concepts  {}, and every refusal code\n  8 operator  the commands only the operator runs\n",
        tools.join(" "),
        tables.join(" "),
        CONCEPTS.iter().map(|c| c.0).collect::<Vec<_>>().join(" "),
    )
}

fn tool_page(t: &Json) -> String {
    let name = t["name"].as_str().unwrap_or("");
    let mut out = format!("{}(1)  {name} — {}\n\n", name.to_uppercase(), t["title"].as_str().unwrap_or(""));
    if let Some(s) = crate::shape(name) {
        out.push_str(&format!("SYNOPSIS\n  {name} {s}\n\n"));
    }
    out.push_str(&format!("DESCRIPTION\n  {}\n", t["description"].as_str().unwrap_or("")));
    if let Some(props) = t.pointer("/inputSchema/properties").and_then(Json::as_object).filter(|p| !p.is_empty()) {
        let required: Vec<&str> = t.pointer("/inputSchema/required").and_then(Json::as_array).map(|r| r.iter().filter_map(Json::as_str).collect()).unwrap_or_default();
        out.push_str("\nOPTIONS\n");
        for (k, v) in props {
            let ty = v.get("type").map(|t| t.as_str().map_or_else(|| t.to_string(), str::to_owned)).unwrap_or_default();
            let req = if required.contains(&k.as_str()) { " (required)" } else { "" };
            let desc = v.get("description").and_then(Json::as_str).unwrap_or("");
            out.push_str(&format!("  {k:<14} {ty}{req}  {desc}\n"));
        }
    }
    out.push_str("\nDIAGNOSTICS\n  A refusal prints error[code]; man <code> explains it.\n\nSEE ALSO\n  man campaigns, man hints\n");
    out
}

fn table_page(d: &Json) -> String {
    let name = d["table"].as_str().unwrap_or("");
    let mut out = format!("{}(5)  {name} — a {} table\n\nCOLUMNS\n", name.to_uppercase(), d["domain"].as_str().unwrap_or(""));
    for c in d["columns"].as_array().into_iter().flatten() {
        let flags: Vec<&str> = c["flags"].as_array().into_iter().flatten().filter_map(Json::as_str).collect();
        let values = c["values"].as_array().map(|v| format!("  {}", v.iter().filter_map(Json::as_str).collect::<Vec<_>>().join("|"))).unwrap_or_default();
        out.push_str(&format!("  {:<22} {:<5} {}{values}\n", c["name"].as_str().unwrap_or(""), c["type"].as_str().unwrap_or(""), flags.join(",")));
    }
    let commands: Vec<&str> = d["commands"].as_array().into_iter().flatten().filter_map(Json::as_str).collect();
    if !commands.is_empty() {
        out.push_str(&format!("\nCOMMANDS\n  {}\n", commands.join(" ")));
    }
    out.push_str(&format!("\nRULES\n  {}\n", d["rules"].as_str().unwrap_or("")));
    out
}

fn first_sentence(s: &str) -> String {
    s.split_once(". ").map_or(s, |(a, _)| a).trim_end_matches('.').to_owned()
}

/// Whether a call's arguments ask for its manual: `-h`, `--help`, `help` or `h` set, or the bare string.
pub fn wants_help(args: &Json) -> bool {
    match args {
        Json::String(s) => matches!(s.trim(), "-h" | "--help" | "help"),
        Json::Object(o) => ["-h", "--help", "help", "h"].iter().any(|k| o.get(*k).is_some_and(|v| v != &Json::Bool(false) && !v.is_null())),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: Masks = Masks { read: 0xffff, write: 0xffff, may_delete: true };

    /// Every tool a key sees, every refusal code and every concept has a page and a -h, and man -k finds them.
    #[test]
    fn every_listed_thing_has_its_page() {
        for m in [ALL, Masks { read: 0xffff, write: 0, may_delete: false }] {
            for t in tools::list(m) {
                let name = t["name"].as_str().unwrap();
                let p = page(m, name).unwrap_or_else(|| panic!("no page for tool {name}"));
                assert!(p.starts_with(&format!("{}(1)", name.to_uppercase())), "{p}");
                assert!(page(m, &format!("1 {name}")).is_some() && short(m, name).starts_with(&format!("{name}: ")));
                assert!(t.pointer("/inputSchema/properties/help").is_some(), "{name} takes help in its schema");
                assert!(apropos(m, name).contains(&format!("{name} (1)")));
            }
        }
        for code in crate::diag::names() {
            assert!(page(ALL, code).is_some_and(|p| p.contains("a refusal")) || tools::list(ALL).iter().any(|t| t["name"] == code), "{code}");
        }
        for (n, _, _) in CONCEPTS {
            assert!(page(ALL, &format!("7 {n}")).is_some() && page(ALL, &format!("1 {n}")).is_none_or(|p| p.contains("(1)")));
        }
        assert!(page(ALL, "5 missions").is_some_and(|p| p.contains("COLUMNS")));
        assert!(page(ALL, "nonesuch").is_none() && apropos(ALL, "nonesuch").contains("nothing appropriate"));
    }

    #[test]
    fn help_is_asked_every_usual_way() {
        for yes in [serde_json::json!("-h"), serde_json::json!("--help"), serde_json::json!({"-h":true}), serde_json::json!({"--help":1}), serde_json::json!({"help":true}), serde_json::json!({"h":"y"})] {
            assert!(wants_help(&yes), "{yes}");
        }
        for no in [serde_json::json!({}), serde_json::json!({"help":false}), serde_json::json!({"table":"help"}), serde_json::json!("help me")] {
            assert!(!wants_help(&no), "{no}");
        }
    }
}
