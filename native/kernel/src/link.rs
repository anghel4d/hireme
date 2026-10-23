//! Every application names a company in the world and, unless it is
//! remote, a place: the judge refuses one that does not (`unlinked`),
//! and never links on its own. What it gives back is what a compiler
//! gives: what was written, the rows it most likely meant ("did you
//! mean"), and the calls that confirm one and redo the write ("try").
//! `unlinked` lists the applications already on the desk without a
//! link, with the same suggestions: the agent's to-do list.

use alloc::string::String;
use alloc::vec::Vec;

use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::{Value as Json, json};

use crate::rows::{Rows, Table};
use crate::text;

/// A row the writer most likely meant.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub id: u32,
    pub name: String,
    /// The row's key: a corporation's domain, a place's ISO code (or its country's).
    pub key: String,
    pub score: f64,
    pub why: &'static str,
}

impl Candidate {
    fn to_json(&self, table: &str) -> Json {
        json!({"table": table, "id": self.id, "name": self.name, "key": self.key, "score": libm::round(self.score * 100.0) / 100.0, "why": self.why})
    }
}

const SHOWN: usize = 3;
const FLOOR: f64 = 0.45;

/// Words that say what kind of company, not which.
const FORMS: &[&str] = &["inc", "llc", "ltd", "limited", "gmbh", "ag", "sa", "sas", "bv", "nv", "plc", "corp", "corporation", "co", "company", "the", "group", "holdings"];

fn words(s: &str) -> Vec<String> {
    text::words(&text::normalize(s)).filter(|w| !FORMS.contains(w)).map(String::from).collect()
}

/// 1 for the same words, falling with the edit distance between them.
fn likeness(a: &[String], b: &[String]) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    let (x, y) = (a.join(" "), b.join(" "));
    if x == y {
        return 1.0;
    }
    let edit = 1.0 - distance(&x, &y) as f64 / x.chars().count().max(y.chars().count()) as f64;
    // Every word of the shorter name in the longer: "Stripe" and "Stripe Payments".
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    let within = if short.iter().all(|w| long.contains(w)) { 0.85 } else { 0.0 };
    edit.max(within)
}

/// Levenshtein over chars, two rows.
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut cur = alloc::vec![i + 1; b.len() + 1];
        for (j, cb) in b.iter().enumerate() {
            cur[j + 1] = (prev[j] + usize::from(ca != *cb)).min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        prev = cur;
    }
    prev[b.len()]
}

/// The corporations an application naming `company` at `url` most likely means, best first.
pub fn companies(rows: &Rows, company: &str, url: Option<&str>) -> Vec<Candidate> {
    let Some(t) = rows.table(table::CORPORATIONS) else { return Vec::new() };
    let mine = words(company);
    let host = url.and_then(crate::write::host);
    let ats = url.map(crate::ats::parse).filter(|a| a.vendor != crate::ats::Vendor::Unknown);
    let out: Vec<Candidate> = t
        .ids()
        .iter()
        .filter_map(|&id| {
            let s = |c: u16| t.str(id, c).unwrap_or("");
            let domain = s(col::corporations::DOMAIN);
            let careers = crate::write::host(s(col::corporations::CAREERS_URL));
            let tenant = s(col::corporations::ATS_TENANT);
            let (score, why) = if host.as_deref().is_some_and(|h| crate::ats::under(h, domain)) {
                (1.0, "the listing is on its domain")
            } else if ats.as_ref().is_some_and(|a| !tenant.is_empty() && a.tenant.as_deref() == Some(&tenant.to_ascii_lowercase())) {
                (0.95, "the listing is on its ATS board")
            } else if host.is_some() && host == careers {
                (0.9, "the listing is on its careers site")
            } else {
                (likeness(&mine, &words(s(col::corporations::NAME))), "its name is like the company named")
            };
            (score >= FLOOR).then(|| Candidate { id, name: s(col::corporations::NAME).into(), key: domain.into(), score, why })
        })
        .collect();
    best(out)
}

/// The best `SHOWN` candidates, by score then id.
fn best(mut out: Vec<Candidate>) -> Vec<Candidate> {
    out.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.id.cmp(&b.id)));
    out.truncate(SHOWN);
    out
}

/// The places a location like "Berlin, Germany" most likely means, best first.
pub fn places(rows: &Rows, location: &str) -> Vec<Candidate> {
    let Some(t) = rows.table(table::PLACES) else { return Vec::new() };
    let parts: Vec<Vec<String>> = location.split([',', '/', '·', '(', ')', '|']).map(words).filter(|w| !w.is_empty()).collect();
    let iso = |id: u32| -> String {
        let own = t.str(id, col::places::ISO2).unwrap_or("");
        if own.is_empty() { t.u32(id, col::places::COUNTRY_ID).and_then(|c| t.str(c, col::places::ISO2)).unwrap_or("").into() } else { own.into() }
    };
    let out: Vec<Candidate> = t
        .ids()
        .iter()
        .filter_map(|&id| {
            let name = words(t.str(id, col::places::NAME).unwrap_or(""));
            let code = t.str(id, col::places::ISO2).unwrap_or("").to_ascii_lowercase();
            let country = t.u32(id, col::places::KIND) == Some(enums::place_kind::COUNTRY as u32);
            let best = parts
                .iter()
                .map(|p| if country && p.len() == 1 && p[0] == code { 1.0 } else { likeness(p, &name) })
                .fold(0.0, f64::max);
            // A city names the place more exactly than its country does.
            let score = if country { best * 0.95 } else { best };
            (score >= FLOOR).then(|| Candidate { id, name: t.str(id, col::places::NAME).unwrap_or("").into(), key: iso(id), score, why: "its name is in the location" })
        })
        .collect();
    best(out)
}

/// Whether an application is short of a link (`missing` is not empty), without building the list.
pub fn short(corporation: Option<u32>, place: Option<u32>, work_mode: Option<u32>) -> bool {
    corporation.is_none() || (place.is_none() && work_mode != Some(enums::work_mode::REMOTE as u32))
}

/// What an application must still link: `corporation_id`, then `place_id`
/// unless it is remote.
pub fn missing(corporation: Option<u32>, place: Option<u32>, work_mode: Option<u32>) -> Vec<&'static str> {
    let remote = work_mode == Some(enums::work_mode::REMOTE as u32);
    [("corporation_id", corporation.is_none()), ("place_id", place.is_none() && !remote)].into_iter().filter(|n| n.1).map(|n| n.0).collect()
}

/// The refusal's data for an application (`id`, 0 for a new one) naming
/// `company`, `location` and `url`, short of the links in `need`.
pub fn diagnosis(rows: &Rows, id: u32, need: &[&str], company: &str, location: &str, url: Option<&str>) -> Json {
    let corps = if need.contains(&"corporation_id") { companies(rows, company, url) } else { Vec::new() };
    let spots = if need.contains(&"place_id") { places(rows, location) } else { Vec::new() };
    let mut meant: Vec<Json> = corps.iter().map(|c| c.to_json("corporations")).collect();
    meant.extend(spots.iter().map(|c| c.to_json("places")));
    let mut tries: Vec<Json> = Vec::new();
    let look = |t: &str, col: &str, q: &str| json!({"tool": "find", "args": {"table": t, "where": {col: {"like": q}}, "limit": 10}});
    if need.contains(&"corporation_id") {
        let q = words(company).first().cloned().or_else(|| url.and_then(crate::write::host)).unwrap_or_default();
        tries.push(look("corporations", "name", &q));
        if corps.is_empty() {
            tries.push(json!({"tool": "put", "note": "only if the company truly is not in the world: add it there first, by its own domain",
                "args": {"table": "corporations", "key": {"domain": "<the company's own domain>"}, "set": {"name": company}}}));
        }
    }
    if need.contains(&"place_id") {
        let q = location.split(',').next().map(str::trim).unwrap_or("");
        tries.push(look("places", "name", q));
    }
    let set: serde_json::Map<String, Json> = [("corporation_id", &corps), ("place_id", &spots)]
        .into_iter()
        .filter(|(link, _)| need.contains(link))
        .map(|(link, found)| (link.into(), found.first().map_or_else(|| json!("<the id find answered>"), |c| json!(c.id))))
        .collect();
    let redo = if id == 0 {
        json!({"tool": "put", "note": "your put again, with these cells added", "args": {"table": "applications", "set": set}})
    } else {
        json!({"tool": "put", "args": {"table": "applications", "id": id, "set": set}})
    };
    tries.push(redo);
    json!({"need": need, "given": {"company": company, "location": location, "listing_url": url}, "did_you_mean": meant, "try": tries})
}

/// Every application without the links it needs, with what it most likely means.
pub fn unlinked(rows: &Rows) -> Json {
    let Some(t) = rows.table(table::APPLICATIONS) else { return json!({"applications": []}) };
    let list: Vec<Json> = t
        .ids()
        .iter()
        .filter_map(|&id| {
            let need = missing(t.u32(id, A::CORPORATION_ID), t.u32(id, A::PLACE_ID), t.u32(id, A::WORK_MODE));
            if need.is_empty() {
                return None;
            }
            let mut d = diagnosis(rows, id, &need, s(t, id, A::COMPANY), s(t, id, A::LOCATION), t.str(id, A::LISTING_URL));
            d["application"] = json!(id);
            d["no"] = json!(t.u32(id, A::NO));
            Some(d)
        })
        .collect();
    json!({"applications": list})
}

fn s(t: &Table, id: u32, c: u16) -> &str {
    t.str(id, c).unwrap_or("")
}

/// Why row `id` of `table` may not be dropped: the applications that name
/// it (a corporation, or a place a non-remote one is in), with the relink
/// that comes first. None when nothing names it.
pub fn named_by(rows: &Rows, table: u16, id: u32) -> Option<Json> {
    let (c, name, col) = match table {
        table::CORPORATIONS => (A::CORPORATION_ID, "corporations", "corporation_id"),
        table::PLACES => (A::PLACE_ID, "places", "place_id"),
        _ => return None,
    };
    let t = rows.table(table::APPLICATIONS)?;
    let remote = Some(enums::work_mode::REMOTE as u32);
    let nos: Vec<u32> = t
        .ids()
        .iter()
        .filter(|&&a| t.u32(a, c) == Some(id) && (table == table::CORPORATIONS || t.u32(a, A::WORK_MODE) != remote))
        .map(|&a| t.u32(a, A::NO).unwrap_or(a))
        .collect();
    if nos.is_empty() {
        return None;
    }
    Some(json!({
        "table": name, "id": id, "applications": nos,
        "try": [
            {"tool": "find", "args": {"table": "applications", "where": {col: {"eq": id}}}},
            {"tool": "put", "note": "each of them, to the row that replaces this one", "args": {"table": "applications", "id": "<each application>", "set": {col: "<the replacing id>"}}},
            {"tool": "drop", "args": {"table": name, "id": id}},
        ],
    }))
}
