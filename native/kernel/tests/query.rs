//! Reads of the replica answer World's contract: a page walk returns every
//! matching row once, in order; keys, text chunks, citations and grants
//! read as the server's.

mod fixture;

use fixture::{OPERATOR, body, gone, operator, packed, put, q};
use kernel::abi::Kernel;
use kernel::query::Grants;
use schema::col::sources as S;
use schema::{refusal, table};
use serde_json::{Value as Json, json};

const N: u32 = 300;
const REGIONS: [&str; 4] = ["Europe", "Asia", "", "Americas"];

/// Places 1-300: every third a country (PT, DE, JP), the rest cities with a
/// GeoNames id; five names, four regions (one blank), a population but on
/// every seventh. Source 1 holds a 400 kB document, source 2 is dropped;
/// three citations of populations.
fn kernel() -> Kernel {
    let places: Vec<Json> = (1..=N)
        .map(|i| {
            let country = i.is_multiple_of(3);
            json!({"id": i, "kind": if country { "country" } else { "city" }, "iso2": if country { ["PT", "DE", "JP"][(i as usize / 3) % 3] } else { "" }, "geonames_id": if country { Json::Null } else { json!(1000 + i) },
                "name": (["Lisbon", "lisboa", "Porto", "Berlin", "Tōkyō"][i as usize % 5]), "region": (REGIONS[i as usize % 4]), "population": pop(i)})
        })
        .collect();
    let cite = |id: u32, row: u32, source: u32, value: &str, as_of: u32| json!({"id": id, "table": "places", "row_id": row, "column": "population", "source_id": source, "value": value, "as_of": as_of});
    fixture::kernel(json!({
        "places": places,
        "sources": [{"id": 1, "url": "https://a.example/1", "host": "a.example", "doc": "é".repeat(200_000)}, {"id": 2, "url": "https://b.example/2", "host": "b.example", "deleted_at": 1_700_000_000}],
        "citations": [cite(1, 5, 1, "10", 739_000), cite(2, 5, 2, "20", 739_100), cite(3, 6, 1, "30", 739_100)],
    }))
}

fn pop(i: u32) -> Json {
    if i.is_multiple_of(7) { Json::Null } else { json!((i * 7919) % 1000) }
}

fn refused(k: &mut Kernel, req: Json) -> u16 {
    k.query(&req).map(|j| panic!("{req}: answered {j}")).unwrap_err().code
}

/// A find walked page by page from the first: each row's `order` cell and id.
fn walk(k: &mut Kernel, w: &Json, order: &str, desc: bool, limit: u32) -> Vec<(Json, u32)> {
    let (mut got, mut after) = (Vec::new(), Json::Null);
    loop {
        let page = q(k, json!({"op": "find", "table": "places", "where": w, "order": order, "desc": desc, "limit": limit, "after": after, "cols": [order]}));
        got.extend(page["rows"].as_array().unwrap().iter().map(|r| (r[order].clone(), r["id"].as_u64().unwrap() as u32)));
        after = page["next"].clone();
        if after.is_null() {
            return got;
        }
    }
}

/// Every page walk over every order and filter: each matching row once,
/// none other, ordered by the column (nulls last) then id.
#[test]
fn a_page_walk_returns_every_matching_row_in_order() {
    let mut k = kernel();
    let pop = |i: u32| pop(i).as_u64();
    let filters: [(Json, &dyn Fn(u32) -> bool); 6] = [
        (json!({}), &|_| true),
        (json!({"population": {"gt": 500}}), &|i| pop(i).is_some_and(|p| p > 500)),
        (json!({"population": {"ne": 0}}), &|i| pop(i) != Some(0)),
        (json!({"name": {"like": "LIS"}}), &|i| i % 5 <= 1),
        (json!({"region": {"null": true}, "kind": "country"}), &|i| i % 4 == 2 && i.is_multiple_of(3)),
        (json!({"kind": {"in": ["city"]}, "population": {"le": 100}}), &|i| !i.is_multiple_of(3) && pop(i).is_some_and(|p| p <= 100)),
    ];
    for (w, keep) in &filters {
        for (order, desc) in [("id", false), ("population", false), ("population", true), ("name", true), ("kind", false)] {
            for limit in [1, 7, 500] {
                let got = walk(&mut k, w, order, desc, limit);
                let mut ids: Vec<u32> = got.iter().map(|g| g.1).collect();
                ids.sort_unstable();
                assert_eq!(ids, (1..=N).filter(|&i| keep(i)).collect::<Vec<_>>(), "{w} {order} {desc} {limit}");
                for p in got.windows(2) {
                    let (a, b) = (&p[0], &p[1]);
                    let o = match (a.0.is_null(), b.0.is_null()) {
                        (false, true) => core::cmp::Ordering::Less,
                        (true, false) => core::cmp::Ordering::Greater,
                        (true, true) => core::cmp::Ordering::Equal,
                        _ => a.0.as_f64().map_or_else(|| a.0.as_str().cmp(&b.0.as_str()), |x| x.total_cmp(&b.0.as_f64().unwrap())),
                    };
                    let o = if desc && !(a.0.is_null() || b.0.is_null()) { o.reverse() } else { o };
                    let o = o.then(if desc { b.1.cmp(&a.1) } else { a.1.cmp(&b.1) });
                    assert_eq!(o, core::cmp::Ordering::Less, "{w} {order} {desc}: {a:?} then {b:?}");
                }
            }
        }
    }
}

/// The order index a find builds is mended as rows move: after a PATCH
/// rewrites, removes and adds rows, a walk still returns each row once, in
/// order.
#[test]
fn a_find_after_a_patch_sees_the_rows_as_they_are() {
    let mut k = kernel();
    let _ = walk(&mut k, &json!({}), "population", true, 13);
    let city = |id: u32, name: &str, population: Json| json!({"id": id, "kind": "city", "name": name, "population": population});
    let moved = json!({"places": [city(5, "A", json!(999_999)), city(6, "B", Json::Null), city(301, "C", json!(1)), city(302, "D", json!(500))]});
    k.patch(&[body(&moved), gone(table::PLACES, &[8, 9])].concat(), 2).unwrap();
    let now = |i: u32| match i {
        5 => json!(999_999),
        6 => Json::Null,
        301 => json!(1),
        302 => json!(500),
        _ => pop(i),
    };
    let mut want: Vec<(Json, u32)> = (1..=N).chain([301, 302]).filter(|i| ![8, 9].contains(i)).map(|i| (now(i), i)).collect();
    want.sort_by_key(|(p, i)| (p.is_null(), std::cmp::Reverse((p.as_u64(), *i))));
    assert_eq!(walk(&mut k, &json!({}), "population", true, 13), want);
}

/// A row a PATCH rewrites while a predicted write to it is pending, then
/// rolled back by its NACK, is still one row (noether's Chromium repro).
#[test]
fn a_rollback_after_a_patch_leaves_each_row_once() {
    let mut k = kernel();
    let ids = |k: &mut Kernel| -> Vec<u64> {
        q(k, json!({"op": "find", "table": "places", "where": {"name": {"prefix": "Por"}}, "limit": 500}))["rows"].as_array().unwrap().iter().map(|r| r["id"].as_u64().unwrap()).collect()
    };
    let before = ids(&mut k);
    let mine = put("places", 2, json!({"region": "Mine"}));
    k.predict(&mine, &operator(0)).unwrap();
    k.patch(&body(&json!({"places": [{"id": 2, "name": "Porto", "region": "Theirs"}]})), 2).unwrap();
    k.ingest(&wire::encode_nacks(schema::WIRE_HASH, 3, &[wire::Nack { op_id: wire::Op::one(&mine).unwrap().op_id, code: 0, data: b"{}" }])).unwrap();
    assert_eq!(ids(&mut k), before);
}

#[test]
fn get_by_key_text_history_and_grants_read_as_world() {
    let mut k = kernel();
    // A natural key holds only where its where does: iso2 is a country's.
    assert_eq!(q(&mut k, json!({"op": "get", "table": "places", "key": {"iso2": "DE"}}))["row"]["id"], 3);
    // Named as a put names it, the key's where column is one more filter.
    assert_eq!(q(&mut k, json!({"op": "get", "table": "places", "key": {"iso2": "DE", "kind": "country"}}))["row"]["id"], 3);
    assert_eq!(q(&mut k, json!({"op": "get", "table": "places", "key": {"geonames_id": 1001, "kind": "city"}}))["row"]["id"], 1);
    assert_eq!(refused(&mut k, json!({"op": "get", "table": "places", "key": {"iso2": "DE", "kind": "city"}})), refusal::NOT_FOUND);
    assert_eq!(refused(&mut k, json!({"op": "get", "table": "places", "key": {"name": "Porto"}})), refusal::NATURAL_KEY);
    assert_eq!(refused(&mut k, json!({"op": "get", "table": "places", "id": 9999})), refusal::NOT_FOUND);
    // A dropped source is passed over, and history still names it.
    assert_eq!(refused(&mut k, json!({"op": "get", "table": "sources", "id": 2})), refusal::NOT_FOUND);
    let h = q(&mut k, json!({"op": "history", "table": "places", "id": 5}));
    assert_eq!((h["citations"][0]["id"].clone(), h["citations"][0]["source"]["dropped"].clone(), h["citations"][1]["value"].clone()), (json!(2), json!(true), json!(10)));
    assert_eq!(h["citations"][0]["as_of"], "2023-08-03");
    // Text reads whole in chunks that end on a character boundary.
    let (mut whole, mut at) = (String::new(), json!(0));
    while !at.is_null() {
        let c = q(&mut k, json!({"op": "text", "table": "sources", "id": 1, "column": "doc", "offset": at, "length": 99_999}));
        whole.push_str(c["text"].as_str().unwrap());
        at = c["next"].clone();
    }
    assert_eq!(whole, "é".repeat(200_000));
    assert_eq!(refused(&mut k, json!({"op": "text", "table": "sources", "id": 1, "column": "doc", "offset": 1})), refusal::TYPE);
    // `sizes` answers a text column as its byte length, not its text.
    let r = q(&mut k, json!({"op": "find", "table": "sources", "cols": ["url"], "sizes": ["doc"]}));
    assert_eq!((r["rows"][0]["doc"].clone(), r["rows"][0]["url"].as_str()), (json!(400_000), Some("https://a.example/1")));
    assert_eq!(refused(&mut k, json!({"op": "find", "table": "sources", "sizes": ["id"]})), refusal::COLUMN);
    // The replica holds texts whole: find returns them as any str.
    assert_eq!(q(&mut k, json!({"op": "find", "table": "sources", "cols": ["doc"]}))["rows"][0]["doc"].as_str().map(str::len), Some(400_000));
    // A key reads its mask's domains only, never a private column.
    k.set_grants(Grants { human: false, read_mask: 0b10, write_mask: 0, may_delete: false });
    assert_eq!(refused(&mut k, json!({"op": "find", "table": "places"})), refusal::SCOPE);
    assert_eq!(refused(&mut k, json!({"op": "find", "table": "op_ledger"})), refusal::NOT_FOUND);
    // A declared table with no rows reads empty; the account's views are
    // the operator's, its secrets nobody's.
    let mut op = kernel();
    assert_eq!(q(&mut op, json!({"op": "find", "table": "trusted"}))["rows"], json!([]));
    assert_eq!(q(&mut op, json!({"op": "find", "table": "acct_keys"}))["rows"], json!([]));
    assert_eq!(refused(&mut k, json!({"op": "find", "table": "acct_keys"})), refusal::NOT_FOUND);
    assert_eq!(refused(&mut op, json!({"op": "find", "table": "accounts"})), refusal::NOT_FOUND);
    // Until its WELCOME, a kernel reads nothing.
    let mut blank = kernel();
    blank.set_grants(Grants::default());
    assert_eq!(refused(&mut blank, json!({"op": "find", "table": "places"})), refusal::SCOPE);
    // Hostile values refuse, never trap: an offset split inside a character.
    let mut k = kernel();
    for w in [json!({"retrieved_at": {"ge": "2023-11-14T22:13:20+0é:0"}}), json!({"id": [1, 2]}), json!({"url": {"in": [null]}})] {
        let _ = k.query(&json!({"op": "find", "table": "sources", "where": w}));
    }
}

/// Every row a find or get answers carries its last write, named or not,
/// and one over six months old by the kernel's day is flagged stale.
#[test]
fn every_row_carries_its_last_write_and_an_old_one_is_flagged_stale() {
    let at = |t: &str| kernel::iso_time(t).unwrap();
    let mut k = fixture::kernel(json!({"places": [{"id": 1, "kind": "city", "name": "Old", "updated_at": at("2026-04-01T12:00:00Z")}, {"id": 2, "kind": "city", "name": "Fresh", "updated_at": at("2026-10-01T12:00:00Z")}]}));
    k.set_today(kernel::iso_day("2026-10-22").unwrap());
    let rows = q(&mut k, json!({"op": "find", "table": "places", "cols": ["name"]}))["rows"].clone();
    assert_eq!(rows, json!([{"id": 1, "name": "Old", "updated_at": "2026-04-01T12:00:00Z", "stale": true}, {"id": 2, "name": "Fresh", "updated_at": "2026-10-01T12:00:00Z"}]));
    let one = q(&mut k, json!({"op": "get", "table": "places", "id": 1}))["row"].clone();
    assert_eq!((one["stale"].clone(), one["updated_at"].clone()), (json!(true), json!("2026-04-01T12:00:00Z")));
    // The day moves the line, never the row: on 2026-09-30 the old write is 182 days old and not yet stale.
    k.set_today(kernel::iso_day("2026-09-30").unwrap());
    assert!(q(&mut k, json!({"op": "get", "table": "places", "id": 1}))["row"]["stale"].is_null());
}

/// Texts the server packs stay packed in the replica and its snapshot and
/// read on touch; a size reads without unpacking; a rolled-back write
/// leaves the packed cell exactly as it was.
#[test]
fn packed_texts_read_on_touch_and_survive_snapshot_and_rollback() {
    let doc = "Senior Rust engineer. About the team: kernels, schedulers and GPU runtimes. ".repeat(40);
    let raw = [&[0u8][..], b"short note"].concat();
    let mut w = wire::BodyWriter::new();
    w.block(table::SOURCES, 2).u32s(S::ID, [1, 2].into_iter()).strs(S::URL, ["https://a.example/1", "https://b.example/2"].into_iter()).zstrs(S::DOC, [&packed(&doc)[..], &raw[..]].into_iter());
    let mut k = Kernel::new();
    k.set_grants(OPERATOR);
    k.boot(&w.finish(), 1).unwrap();
    let docs = |k: &mut Kernel| q(k, json!({"op": "find", "table": "sources", "cols": ["doc"]}))["rows"].clone();
    assert_eq!(docs(&mut k), json!([{"id": 1, "doc": doc}, {"id": 2, "doc": "short note"}]));
    let sized = q(&mut k, json!({"op": "find", "table": "sources", "sizes": ["doc"]}))["rows"].clone();
    assert_eq!((sized[0]["doc"].clone(), sized[1]["doc"].clone()), (json!(doc.len()), json!(10)));
    // The snapshot holds the cell as packed, and restores it.
    let snap = k.snapshot();
    assert!(snap.len() < doc.len() / 4, "snapshot {} B for a {} B text", snap.len(), doc.len());
    let mut again = Kernel::new();
    again.set_grants(OPERATOR);
    again.restore(&snap).unwrap();
    assert_eq!(docs(&mut again), docs(&mut k));
    // A predicted write, then its NACK: the packed cell comes back as it was.
    let mine = put("sources", 1, json!({"doc": "mine"}));
    k.predict(&mine, &operator(0)).unwrap();
    assert_eq!(docs(&mut k)[0]["doc"], "mine");
    k.ingest(&wire::encode_nacks(schema::WIRE_HASH, 2, &[wire::Nack { op_id: wire::Op::one(&mine).unwrap().op_id, code: 0, data: b"{}" }])).unwrap();
    assert_eq!(k.snapshot(), snap);
}

/// The account's live views take deltas: a PATCH naming one factor (a passkey added) keeps the rest
/// (the authenticator app). A resume sends each view empty, then whole, so a page that kept rows
/// from before (a factor removed elsewhere) drops them; and the snapshot at rest never holds one.
#[test]
fn live_views_take_deltas_and_a_resume_empties_them_first() {
    let mut k = kernel();
    let factors = |rows: Json| body(&json!({"acct_factors": rows}));
    let ids = |k: &mut Kernel| q(k, json!({"op": "find", "table": "acct_factors"}))["rows"].as_array().unwrap().iter().map(|r| r["id"].clone()).collect::<Vec<_>>();
    k.patch(&factors(json!([{"id": 1, "name": "Phone"}, {"id": 2, "name": "Laptop"}])), 2).unwrap();
    // A passkey added: the delta names it alone; both earlier factors stay.
    k.patch(&factors(json!([{"id": 3, "name": "Key A"}])), 3).unwrap();
    assert_eq!(ids(&mut k), vec![json!(1), json!(2), json!(3)]);
    // Gone by a gone block, like any table: the others stay.
    k.patch(&gone(table::ACCT_FACTORS, &[3]), 4).unwrap();
    assert_eq!(ids(&mut k), vec![json!(1), json!(2)]);
    // A resume: the view empty, then whole. Factor 2 was removed while this page was away.
    k.patch(&[factors(json!([])), factors(json!([{"id": 1, "name": "Phone"}]))].concat(), 5).unwrap();
    assert_eq!(ids(&mut k), vec![json!(1)]);
    let mut again = Kernel::new();
    again.set_grants(OPERATOR);
    again.restore(&k.snapshot()).unwrap();
    assert_eq!(q(&mut again, json!({"op": "find", "table": "acct_factors"}))["rows"], json!([]));
}
