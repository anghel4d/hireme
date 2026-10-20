//! Applications and the world rows they must name: what the kernel
//! suggests for an unlinked one, the list of those, and the desk's
//! columns of any field, joins included.

use kernel::abi::Kernel;
use kernel::query::Grants;
use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::{Value as Json, json};

/// Germany (1) with Berlin (2), France (3); Stripe (10, stripe.com, careers
/// on stripe.com, a Lever board "stripe") under Alphabet (12), Helsing (11)
/// with an engineering office in Berlin. Applications: Stripe in Berlin,
/// linked (1); "Stripe Inc" on Lever, unlinked (2); "Helsng GmbH" in
/// "Berlin, Germany", unlinked (3); a remote one with a company only (4).
fn kernel() -> Kernel {
    let none = wire::NONE;
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::PLACES, 3);
    b.u32s(col::places::ID, [1, 2, 3].into_iter())
        .u32s(col::places::KIND, [enums::place_kind::COUNTRY, enums::place_kind::CITY, enums::place_kind::COUNTRY].map(u32::from).into_iter())
        .u32s(col::places::COUNTRY_ID, [none, 1, none].into_iter())
        .strs(col::places::ISO2, ["DE", "", "FR"].into_iter())
        .strs(col::places::NAME, ["Germany", "Berlin", "France"].into_iter())
        .strs(col::places::REGION, ["Europe", "", "Europe"].into_iter());
    b.done();
    let mut b = w.block(table::CORPORATIONS, 3);
    b.u32s(col::corporations::ID, [10, 11, 12].into_iter())
        .strs(col::corporations::DOMAIN, ["stripe.com", "helsing.ai", "abc.xyz"].into_iter())
        .strs(col::corporations::NAME, ["Stripe", "Helsing", "Alphabet"].into_iter())
        .strs(col::corporations::ATS_TENANT, ["stripe", "", ""].into_iter())
        .u32s(col::corporations::PARENT_ID, [12, none, none].into_iter());
    b.done();
    let mut b = w.block(table::OFFICES, 1);
    b.u32s(col::offices::ID, [7].into_iter())
        .u32s(col::offices::CORPORATION_ID, [11].into_iter())
        .u32s(col::offices::PLACE_ID, [2].into_iter())
        .u32s(col::offices::KIND, [enums::office_kind::ENGINEERING as u32].into_iter());
    b.done();
    let mut b = w.block(table::APPLICATIONS, 4);
    b.u32s(A::ID, 1..=4)
        .u32s(A::NO, 1..=4)
        .u32s(A::STAGE, (1..=4).map(|_| enums::stage::GATED as u32))
        .strs(A::COMPANY, ["Stripe", "Stripe Inc", "Helsng GmbH", "Helsing"].into_iter())
        .strs(A::LOCATION, ["Berlin", "", "Berlin, Germany", "Remote"].into_iter())
        .strs(A::LISTING_URL, ["", "https://jobs.lever.co/stripe/123", "", ""].into_iter())
        .u32s(A::CORPORATION_ID, [10, none, none, 11].into_iter())
        .u32s(A::PLACE_ID, [2, none, none, none].into_iter())
        .u32s(A::WORK_MODE, [none, none, none, enums::work_mode::REMOTE as u32].into_iter())
        .u32s(A::HEAT_OVERRIDE, (1..=4).map(|_| 0));
    b.done();
    let mut k = Kernel::new();
    k.set_today(739_528);
    k.set_grants(Grants { human: true, read_mask: 0b1111, write_mask: 0b1111, may_delete: true });
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn q(k: &Kernel, req: Json) -> Json {
    k.query(&req).unwrap_or_else(|r| panic!("{req}: {r:?}"))
}

#[test]
fn an_unlinked_application_is_told_what_it_most_likely_means_and_how_to_link_it() {
    let k = kernel();
    let list = q(&k, json!({"op": "unlinked"}))["applications"].as_array().unwrap().clone();
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

#[test]
fn the_desk_reads_any_field_of_every_application_joins_included() {
    let k = kernel();
    let c = q(&k, json!({"op": "columns", "fields": ["company.name", "company.parent", "country", "region", "place", "office", "no", "field"]}));
    assert_eq!(c["ids"], json!([1, 2, 3, 4]));
    let col = |p: &str| c["cols"][p].clone();
    assert_eq!(col("company.name"), json!(["Stripe", null, null, "Helsing"]));
    assert_eq!(col("company.parent"), json!(["Alphabet", null, null, null]));
    assert_eq!(col("country"), json!(["DE", null, null, null]));
    assert_eq!(col("region"), json!(["Europe", null, null, null]));
    assert_eq!(col("place"), json!(["Berlin", null, null, null]));
    assert_eq!(col("office"), json!([null, null, null, null]));
    assert_eq!(col("no"), json!([1.0, 2.0, 3.0, 4.0]));
    // No role written: the department is "other".
    assert_eq!(col("field"), json!(["other", "other", "other", "other"]));
    assert_eq!(k.query(&json!({"op": "columns", "fields": ["nope"]})).unwrap_err().code, schema::refusal::TYPE);

    let fields: Vec<Json> = serde_json::from_value(q(&k, json!({"op": "mask_fields"}))["fields"].clone()).unwrap();
    let office = fields.iter().find(|f| f["path"] == "office").unwrap();
    assert_eq!((&office["label"], &office["type"]), (&json!("office"), &json!("enum")));
}

#[test]
fn a_column_follows_the_rows_it_reads() {
    let mut k = kernel();
    assert_eq!(q(&k, json!({"op": "columns", "fields": ["office"]}))["cols"]["office"], json!([null, null, null, null]));
    // Helsing's application 4 moves to Berlin, where Helsing has an engineering office.
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, 1);
    b.u32s(A::ID, [4].into_iter()).u32s(A::PLACE_ID, [2].into_iter());
    b.done();
    k.patch(&w.finish(), 2).unwrap();
    assert_eq!(q(&k, json!({"op": "columns", "fields": ["office"]}))["cols"]["office"], json!([null, null, null, "engineering"]));
}
