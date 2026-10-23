//! The one judge of a write on a replicated table, as the sequencer judges
//! it: provenance, natural keys, shape, uniques and drops from the replica.

mod fixture;

use fixture::{TODAY, agent, cells, cmd, del, keyed, operator, put, put_with, raw, refused};
use kernel::abi::Kernel;
use kernel::judge::{Refusal, Row};
use schema::col::{corporations as K, places as P};
use schema::{refusal, table};
use serde_json::{Value as Json, json};

const D0: u32 = 739_000;
const NOW: i64 = 1_792_000_000;

/// Acme (corporation 1 at rev 2, headcount 100 on D0 cited from source 1
/// on levels.fyi, a trusted host), a blog (source 2) and an application.
fn kernel() -> Kernel {
    fixture::kernel(json!({
        "corporations": [{"id": 1, "rev": 2, "domain": "acme.com", "name": "Acme", "headcount": 100, "headcount_on": D0}],
        "sources": [{"id": 1, "url": "https://www.levels.fyi/acme", "host": "www.levels.fyi"}, {"id": 2, "url": "https://blog.example/a", "host": "blog.example"}],
        "trusted": [{"id": 1, "host": "levels.fyi"}],
        "citations": [{"id": 1, "table": "corporations", "row_id": 1, "column": "headcount", "source_id": 1, "as_of": D0}],
        "applications": [{"id": 1, "no": 1, "stage": "draft_ready", "company": "Acme", "stage_on": TODAY}],
    }))
}

/// An agent's write.
fn judge(k: &mut Kernel, op: &[u8]) -> Result<Vec<Row>, Refusal> {
    k.judge(op, &agent(3, NOW))
}

#[test]
fn a_metric_needs_its_date_and_cites_what_changes() {
    let mut k = kernel();
    let headcount = |n: u32, on: u32, src: u32| put("corporations", 1, json!({"headcount": n, "as_of": on, "source": src}));
    assert_eq!(refused(judge(&mut k, &put("corporations", 1, json!({"headcount": 120, "source": 1})))).0, refusal::FRESHNESS);
    let (code, data) = refused(judge(&mut k, &headcount(120, D0 - 1, 1)));
    assert_eq!((code, data["on"].as_str()), (refusal::STALE, Some("2023-04-25")));
    assert_eq!(refused(judge(&mut k, &headcount(120, TODAY as u32 + 2, 1))).0, refusal::FRESHNESS);
    // The same value, date and source again writes nothing.
    assert_eq!(judge(&mut k, &headcount(100, D0, 1)).unwrap(), Vec::new());
    // The same value from another source corroborates: cited.
    assert_eq!(cells(&judge(&mut k, &headcount(100, D0, 2)).unwrap(), "citations")["source_id"], 2);
    // A new figure from a new URL: the source first, its host derived, then
    // the row with its date moved, then the citation naming both.
    let fx = judge(&mut k, &put("corporations", 1, json!({"headcount": 140, "as_of": D0 + 30, "source": "https://Careers.Acme.com./jobs"}))).unwrap();
    assert_eq!((fx[0].table, fx[0].id), (table::SOURCES, 0));
    assert_eq!((cells(&fx, "sources")["host"].as_str(), cells(&fx, "corporations")["headcount_on"].as_u64()), (Some("careers.acme.com"), Some(D0 as u64 + 30)));
    let cited = cells(&fx, "citations");
    assert_eq!((&cited["source_id"], &cited["row_id"]), (&json!({"new": 0}), &json!(1)));
}

#[test]
fn ratings_need_a_trusted_host_and_prose_its_rev_and_source() {
    let mut k = kernel();
    let rating = |src: u32| put("corporations", 1, json!({"rating": 4.2, "as_of": D0, "source": src}));
    assert_eq!(refused(judge(&mut k, &rating(2))).0, refusal::SOURCE_TRUST);
    // A subdomain of a trusted host is trusted.
    assert!(judge(&mut k, &rating(1)).is_ok());
    let culture = |rev: Option<u32>, src: Option<u32>| {
        let mut c = json!({"culture": "Writes everything down."});
        if let Some(s) = src {
            c["source"] = json!(s);
        }
        put_with(0, rev, "corporations", 1, c)
    };
    assert_eq!(refused(judge(&mut k, &culture(None, Some(1)))).0, refusal::REV);
    assert_eq!(refused(judge(&mut k, &culture(Some(1), Some(1)))).0, refusal::REV);
    assert_eq!(refused(judge(&mut k, &culture(Some(2), None))).0, refusal::SOURCE_MISSING);
    assert!(judge(&mut k, &culture(Some(2), Some(1))).is_ok());
}

#[test]
fn keys_shape_uniques_and_drops_are_the_sequencers() {
    let mut k = kernel();
    // A keyed put lands on the row its natural key names, or inserts.
    let named = |flags: u8, domain: &str| put_with(wire::KEYED | flags, None, "corporations", 0, json!({"domain": domain, "name": "Acme Inc"}));
    assert_eq!(judge(&mut k, &named(0, "acme.com")).unwrap().last().map(|r| r.id), Some(1));
    assert_eq!(judge(&mut k, &named(0, "new.example")).unwrap().last().map(|r| r.id), Some(0));
    assert_eq!(refused(judge(&mut k, &named(wire::CREATE_ONLY, "acme.com"))).0, refusal::NATURAL_KEY);
    // The same domain unkeyed is a unique clash.
    assert_eq!(refused(judge(&mut k, &put("corporations", 0, json!({"domain": "acme.com", "name": "Dup"})))).0, refusal::NATURAL_KEY);
    // Shape: required columns and params (a blank one is missing), types, refs, readonly twins.
    for (op, missing) in [(put("corporations", 0, json!({"domain": "x.example"})), "name"), (cmd("heat_override", 1, json!({"reason": ""})), "reason")] {
        let (code, data) = refused(judge(&mut k, &op));
        assert_eq!((code, data["missing"][0].as_str()), (refusal::COLUMN, Some(missing)));
    }
    let many = raw(wire::PUT, 0, table::CORPORATIONS, 1, None, |o| {
        o.str(K::HEADCOUNT, "many");
    });
    assert_eq!(refused(judge(&mut k, &many)).0, refusal::TYPE);
    assert_eq!(refused(judge(&mut k, &put("corporations", 1, json!({"hq_place_id": 999})))).0, refusal::NOT_FOUND);
    assert_eq!(refused(judge(&mut k, &put("corporations", 1, json!({"headcount_on": D0})))).0, refusal::COLUMN);
    assert_eq!(refused(judge(&mut k, &put("corporations", 9, json!({"name": "Ghost"})))).0, refusal::NOT_FOUND);
    // A cited source outlives a key's drop, not the operator's; a stale rev
    // and an append-only table refuse a drop.
    assert_eq!(refused(judge(&mut k, &del("sources", 1))).0, refusal::SCOPE);
    assert!(k.judge(&del("sources", 1), &operator(NOW)).is_ok());
    assert_eq!(refused(judge(&mut k, &raw(wire::DROP, 0, table::CORPORATIONS, 1, Some(1), |_| {}))).0, refusal::REV);
    assert_eq!(refused(judge(&mut k, &del("citations", 1))).0, refusal::COLUMN);
    // Citations are the server's to write.
    let (code, data) = refused(judge(&mut k, &put("citations", 0, json!({}))));
    assert_eq!((code, data["reason"].as_str()), (refusal::COLUMN, Some("the server writes this table")));
}

/// The review's cases: a KEYED key honours its where on stored rows; an
/// empty str is a clear only in a str column; a projection is no op's to
/// drop; a JSON restatement compares values, not text.
#[test]
fn keys_hold_their_where_and_cells_their_type() {
    let mut k = fixture::kernel(json!({
        "places": [{"id": 1, "kind": "city", "iso2": "US", "name": "Springfield"}, {"id": 2, "kind": "country", "iso2": "US", "name": "United States"}],
        "settings": [{"id": 1, "heat_config": r#"{"a":1,"b":2}"#}],
    }));
    assert_eq!(judge(&mut k, &keyed("places", json!({"kind": "country", "iso2": "US", "name": "USA"}))).unwrap().last().map(|r| r.id), Some(2));
    let blank = raw(wire::PUT, 0, table::PLACES, 2, None, |o| {
        o.str(P::KIND, "");
    });
    assert_eq!(refused(judge(&mut k, &blank)).0, refusal::TYPE);
    assert_eq!(refused(judge(&mut k, &del("trusted", 1))).0, refusal::NOT_FOUND);
    assert_eq!(judge(&mut k, &put("settings", 1, json!({"heat_config": r#"{ "b": 2, "a": 1 }"#}))).unwrap(), Vec::new());
}

/// A table at its cap refuses an insert, never a restatement (which
/// writes nothing): the citations a write adds count the same way.
#[test]
fn a_cap_refuses_inserts_not_restatements() {
    let cap = schema::table_def(table::CORPORATIONS).and_then(|t| t.cap).unwrap();
    let mut k = fixture::kernel(json!({"corporations": (1..=cap).map(|i| json!({"id": i, "domain": format!("c{i}.example"), "name": "C"})).collect::<Json>()}));
    let (code, data) = refused(judge(&mut k, &put("corporations", 0, json!({"domain": "one-more.example", "name": "C"}))));
    assert_eq!((code, data["cap"].as_u64()), (refusal::CAP, Some(cap as u64)));
    assert_eq!(judge(&mut k, &put("corporations", 7, json!({"name": "C"}))).unwrap(), Vec::new());
}

#[test]
fn a_source_host_is_what_a_browser_opens() {
    use kernel::write::host;
    assert_eq!(host("https://WWW.Levels.FYI./x?y#z").as_deref(), Some("www.levels.fyi"));
    assert_eq!(host("http://a.example:080/").as_deref(), Some("a.example"));
    assert_eq!(host("HTTPS://ABC.com.:443/p").as_deref(), Some("abc.com"));
    assert_eq!(host("https://@a.example/x").as_deref(), Some("a.example"));
    for bad in ["https://evil.example\\@levels.fyi/", "https://u@levels.fyi/", "ftp://a.example/", "https://127.0.0.1/", "https://0x7f.1/", "https://a.example:99999/", "https://a b.example/", "https://localhost/", "https://-a.example/"] {
        assert_eq!(host(bad), None, "{bad}");
    }
}
