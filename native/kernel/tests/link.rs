//! Applications and the world rows they must name: what the kernel
//! suggests for an unlinked one, the list of those, and the desk's
//! columns of any field, joins included.

mod fixture;

use fixture::q;
use kernel::abi::Kernel;
use serde_json::{Value as Json, json};

/// Germany (1) with Berlin (2), France (3); Stripe (10, stripe.com, careers
/// on stripe.com, a Lever board "stripe") under Alphabet (12), Helsing (11)
/// with an engineering office in Berlin. Applications: Stripe in Berlin,
/// linked (1); "Stripe Inc" on Lever, unlinked (2); "Helsng GmbH" in
/// "Berlin, Germany", unlinked (3); a remote one with a company only (4).
fn kernel() -> Kernel {
    fixture::kernel(json!({
        "places": fixture::europe(),
        "corporations": [{"id": 10, "domain": "stripe.com", "name": "Stripe", "ats_tenant": "stripe", "parent_id": 12}, {"id": 11, "domain": "helsing.ai", "name": "Helsing"}, {"id": 12, "domain": "abc.xyz", "name": "Alphabet"}],
        "offices": [{"id": 7, "corporation_id": 11, "place_id": 2, "kind": "engineering"}],
        "applications": [
            {"id": 1, "no": 1, "stage": "gated", "company": "Stripe", "location": "Berlin", "corporation_id": 10, "place_id": 2},
            {"id": 2, "no": 2, "stage": "gated", "company": "Stripe Inc", "listing_url": "https://jobs.lever.co/stripe/123"},
            {"id": 3, "no": 3, "stage": "gated", "company": "Helsng GmbH", "location": "Berlin, Germany"},
            {"id": 4, "no": 4, "stage": "gated", "company": "Helsing", "location": "Remote", "corporation_id": 11, "work_mode": "remote"},
        ],
    }))
}

#[test]
fn an_unlinked_application_is_told_what_it_most_likely_means_and_how_to_link_it() {
    let mut k = kernel();
    let list = q(&mut k, json!({"op": "unlinked"}))["applications"].as_array().unwrap().clone();
    // The remote one needs no place, and the linked one is not listed.
    assert_eq!(list.iter().map(|a| a["application"].as_u64().unwrap()).collect::<Vec<_>>(), [2, 3]);

    let stripe = &list[0];
    assert_eq!(stripe["need"], json!(["corporation_id", "place_id"]));
    let first = &stripe["did_you_mean"][0];
    assert_eq!((&first["table"], &first["id"], &first["why"]), (&json!("corporations"), &json!(10), &json!("the listing is on its ATS board")));
    let redo = stripe["try"].as_array().unwrap().last().unwrap();
    assert_eq!((&redo["tool"], &redo["args"]["id"], &redo["args"]["set"]["corporation_id"]), (&json!("put"), &json!(2), &json!(10)));
    assert_eq!(stripe["try"][0]["args"]["table"], "corporations", "the first step finds the company");

    // A misspelt name still finds its company; "Berlin, Germany" finds the city before the country.
    let helsing = &list[1];
    let meant: Vec<(String, u64)> =
        helsing["did_you_mean"].as_array().unwrap().iter().map(|c| (c["table"].as_str().unwrap().into(), c["id"].as_u64().unwrap())).collect();
    assert_eq!(meant[0], ("corporations".into(), 11));
    let places: Vec<u64> = meant.iter().filter(|m| m.0 == "places").map(|m| m.1).collect();
    assert_eq!(places, [2, 1]);
}

#[test]
fn a_company_nothing_resembles_is_not_guessed() {
    let k = kernel();
    let d = kernel::link::diagnosis(k.rows(), 0, &["corporation_id"], "Zyxwv Labs", "", None);
    assert_eq!(d["did_you_mean"], json!([]));
    let tools: Vec<&str> = d["try"].as_array().unwrap().iter().map(|t| t["tool"].as_str().unwrap()).collect();
    assert_eq!(tools, ["find", "put", "put"], "find it, add it to the world only if it truly is not there, then redo");
    assert_eq!(d["try"][2]["args"]["set"]["corporation_id"], "<the id find answered>");
}

/// A catalog field over every application as the desk's columns read it (`arrange::build`): null where absent.
fn column(k: &Kernel, path: &str) -> Json {
    use kernel::arrange::{Col, NONE, build};
    Json::Array(match build(k.rows(), kernel::mask::field(path).unwrap_or_else(|| panic!("no field {path}"))) {
        Col::Num(v) => v.iter().map(|n| if n.is_nan() { Json::Null } else { json!(n) }).collect(),
        Col::Sym { ids, dict, .. } => ids.iter().map(|&s| if s == NONE { Json::Null } else { json!(dict[s as usize]) }).collect(),
    })
}

/// Every field reads over every application, joins included; a company,
/// country or group carries how many applications name it.
#[test]
fn the_desk_reads_any_field_of_every_application_joins_included() {
    let mut k = kernel();
    for (path, want) in [
        ("company.name", json!(["Stripe", null, null, "Helsing"])),
        ("company.parent", json!(["Alphabet", null, null, null])),
        ("country", json!(["DE", null, null, null])),
        ("region", json!(["Europe", null, null, null])),
        ("place", json!(["Berlin", null, null, null])),
        ("office", json!([null, null, null, null])),
        ("no", json!([1.0, 2.0, 3.0, 4.0])),
        // No role written: the department is "other".
        ("field", json!(["other", "other", "other", "other"])),
        // Stripe (under Alphabet) has one linked application, Helsing one; Germany one (Berlin).
        ("company.applications", json!([1.0, null, null, 1.0])),
        ("company.parent.applications", json!([1.0, null, null, 1.0])),
        ("country.applications", json!([1.0, null, null, null])),
    ] {
        assert_eq!(column(&k, path), want, "{path}");
    }
    assert!(kernel::mask::field("nope").is_none());
    let fields = q(&mut k, json!({"op": "mask_fields"}))["fields"].clone();
    let field = |p: &str| fields.as_array().unwrap().iter().find(|f| f["path"] == p).unwrap().clone();
    assert_eq!((field("office")["label"].clone(), field("office")["type"].clone(), field("company.applications")["desc"].clone()), (json!("office"), json!("enum"), json!(true)));
}
