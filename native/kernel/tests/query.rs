//! Reads of the replica answer World's contract: a page walk returns every
//! matching row once, in order; keys, text chunks, citations and grants
//! read as the server's.

use kernel::abi::Kernel;
use kernel::query::Grants;
use schema::col::{citations as C, places as P, sources as S};
use schema::{enums, table};
use serde_json::{json, Value as Json};

const N: u32 = 300;
const REGIONS: [&str; 4] = ["Europe", "Asia", "", "Americas"];
/// A browser session's grants: every domain both ways.
const OPERATOR: Grants = Grants { human: true, read_mask: 0b1_1111, write_mask: 0b1_1111, may_delete: true };

fn kernel() -> Kernel {
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::PLACES, N as usize);
    b.u32s(P::ID, 1..=N)
        .u32s(P::KIND, (1..=N).map(|i| if i.is_multiple_of(3) { enums::place_kind::COUNTRY } else { enums::place_kind::CITY } as u32))
        .strs(P::ISO2, (1..=N).map(|i| if i.is_multiple_of(3) { ["PT", "DE", "JP"][(i as usize / 3) % 3] } else { "" }))
        .strs(P::NAME, (1..=N).map(|i| ["Lisbon", "lisboa", "Porto", "Berlin", "Tōkyō"][i as usize % 5]))
        .strs(P::REGION, (1..=N).map(|i| REGIONS[i as usize % 4]))
        .u32s(P::POPULATION, (1..=N).map(|i| if i.is_multiple_of(7) { wire::NONE } else { (i * 7919) % 1000 }));
    b.done();
    let doc = "é".repeat(200_000);
    let mut b = w.block(table::SOURCES, 2);
    b.u32s(S::ID, [1, 2].into_iter())
        .strs(S::URL, ["https://a.example/1", "https://b.example/2"].into_iter())
        .strs(S::HOST, ["a.example", "b.example"].into_iter())
        .u32s(S::DELETED_AT, [wire::NONE, 1_700_000_000].into_iter())
        .strs(S::DOC, [doc.as_str(), ""].into_iter());
    b.done();
    let mut b = w.block(table::CITATIONS, 3);
    b.u32s(C::ID, 1..=3)
        .strs(C::TABLE, ["places"; 3].into_iter())
        .u32s(C::ROW_ID, [5, 5, 6].into_iter())
        .strs(C::COLUMN, ["population", "population", "population"].into_iter())
        .u32s(C::SOURCE_ID, [1, 2, 1].into_iter())
        .strs(C::VALUE, ["10", "20", "30"].into_iter())
        .u32s(C::AS_OF, [739_000, 739_100, 739_100].into_iter());
    b.done();
    let mut k = Kernel::new();
    k.set_grants(OPERATOR);
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn q(k: &Kernel, req: Json) -> Json {
    k.query(&req).unwrap_or_else(|r| panic!("{req}: refused {} {}", r.code, r.data))
}

fn refused(k: &Kernel, req: Json) -> u16 {
    k.query(&req).map(|j| panic!("{req}: answered {j}")).unwrap_err().code
}

/// Every page walk over every order and filter: each matching row once,
/// none other, ordered by the column (nulls last) then id.
#[test]
fn a_page_walk_returns_every_matching_row_in_order() {
    let k = kernel();
    let pop = |i: u32| (!i.is_multiple_of(7)).then_some((i * 7919) % 1000);
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
                let (mut got, mut after) = (Vec::new(), Json::Null);
                loop {
                    let page = q(&k, json!({"op": "find", "table": "places", "where": w, "order": order, "desc": desc, "limit": limit, "after": after, "cols": [order]}));
                    got.extend(page["rows"].as_array().unwrap().iter().map(|r| (r[order].clone(), r["id"].as_u64().unwrap() as u32)));
                    after = page["next"].clone();
                    if after.is_null() {
                        break;
                    }
                }
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
    let walk = |k: &Kernel| -> Vec<(Option<u64>, u32)> {
        let (mut got, mut after) = (Vec::new(), Json::Null);
        loop {
            let page = q(k, json!({"op": "find", "table": "places", "order": "population", "desc": true, "limit": 13, "after": after, "cols": ["population"]}));
            got.extend(page["rows"].as_array().unwrap().iter().map(|r| (r["population"].as_u64(), r["id"].as_u64().unwrap() as u32)));
            after = page["next"].clone();
            if after.is_null() {
                return got;
            }
        }
    };
    let _ = walk(&k);
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::PLACES, 4);
    b.u32s(P::ID, [5, 6, 301, 302].into_iter())
        .u32s(P::KIND, [enums::place_kind::CITY as u32; 4].into_iter())
        .strs(P::NAME, ["A", "B", "C", "D"].into_iter())
        .u32s(P::POPULATION, [999_999, wire::NONE, 1, 500].into_iter());
    b.done();
    w.gone(table::PLACES, &[8, 9]);
    k.patch(&w.finish(), 2).unwrap();
    let got = walk(&k);
    let pop = |i: u32| match i {
        5 => Some(999_999),
        6 => None,
        301 => Some(1),
        302 => Some(500),
        _ => (!i.is_multiple_of(7)).then_some(((i * 7919) % 1000) as u64),
    };
    let mut want: Vec<(Option<u64>, u32)> = (1..=N).chain([301, 302]).filter(|i| ![8, 9].contains(i)).map(|i| (pop(i), i)).collect();
    want.sort_by(|a, b| match (a.0, b.0) {
        (Some(x), Some(y)) => y.cmp(&x).then(b.1.cmp(&a.1)),
        (Some(_), None) => core::cmp::Ordering::Less,
        (None, Some(_)) => core::cmp::Ordering::Greater,
        (None, None) => b.1.cmp(&a.1),
    });
    assert_eq!(got, want);
}

/// A row a PATCH rewrites while a predicted write to it is pending, then
/// rolled back by its NACK, is still one row (noether's Chromium repro).
#[test]
fn a_rollback_after_a_patch_leaves_each_row_once() {
    let mut k = kernel();
    let ids = |k: &Kernel| -> Vec<u64> {
        q(k, json!({"op": "find", "table": "places", "where": {"name": {"prefix": "Por"}}, "limit": 500}))["rows"].as_array().unwrap().iter().map(|r| r["id"].as_u64().unwrap()).collect()
    };
    let before = ids(&k);
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(4242, wire::PUT, 0, table::PLACES, 2, None);
    o.str(P::REGION, "Mine");
    o.done();
    let ctx = kernel::judge::Ctx { today: 739_528, now: 0, human: true, key_id: None, held: &[] };
    k.predict(&w.finish()[8..], &ctx).unwrap();
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::PLACES, 1);
    b.u32s(P::ID, [2].into_iter()).strs(P::NAME, ["Porto"].into_iter()).strs(P::REGION, ["Theirs"].into_iter());
    b.done();
    k.patch(&w.finish(), 2).unwrap();
    k.ingest(&wire::encode_nacks(schema::WIRE_HASH, 3, &[wire::Nack { op_id: 4242, code: 0, data: b"{}" }])).unwrap();
    assert_eq!(ids(&k), before);
}

#[test]
fn get_by_key_text_history_and_grants_read_as_world() {
    let mut k = kernel();
    // A natural key holds only where its where does: iso2 is a country's.
    assert_eq!(q(&k, json!({"op": "get", "table": "places", "key": {"iso2": "DE"}}))["row"]["id"], 3);
    assert_eq!(refused(&k, json!({"op": "get", "table": "places", "key": {"name": "Porto"}})), schema::refusal::NATURAL_KEY);
    assert_eq!(refused(&k, json!({"op": "get", "table": "places", "id": 9999})), schema::refusal::NOT_FOUND);
    // A dropped source is passed over, and history still names it.
    assert_eq!(refused(&k, json!({"op": "get", "table": "sources", "id": 2})), schema::refusal::NOT_FOUND);
    let h = q(&k, json!({"op": "history", "table": "places", "id": 5}));
    assert_eq!((h["citations"][0]["id"].clone(), h["citations"][0]["source"]["dropped"].clone(), h["citations"][1]["value"].clone()), (json!(2), json!(true), json!(10)));
    assert_eq!(h["citations"][0]["as_of"], "2023-08-03");
    // Text reads whole in chunks that end on a character boundary.
    let (mut whole, mut at) = (String::new(), json!(0));
    while !at.is_null() {
        let c = q(&k, json!({"op": "text", "table": "sources", "id": 1, "column": "doc", "offset": at, "length": 99_999}));
        whole.push_str(c["text"].as_str().unwrap());
        at = c["next"].clone();
    }
    assert_eq!(whole, "é".repeat(200_000));
    assert_eq!(refused(&k, json!({"op": "text", "table": "sources", "id": 1, "column": "doc", "offset": 1})), schema::refusal::TYPE);
    // `sizes` answers a text column as its byte length, not its text.
    let r = q(&k, json!({"op": "find", "table": "sources", "cols": ["url"], "sizes": ["doc"]}));
    assert_eq!((r["rows"][0]["doc"].clone(), r["rows"][0]["url"].as_str()), (json!(400_000), Some("https://a.example/1")));
    assert_eq!(refused(&k, json!({"op": "find", "table": "sources", "sizes": ["id"]})), schema::refusal::COLUMN);
    // The replica holds texts whole: find returns them as any str.
    assert_eq!(q(&k, json!({"op": "find", "table": "sources", "cols": ["doc"]}))["rows"][0]["doc"].as_str().map(str::len), Some(400_000));
    // A key reads its mask's domains only, never a private column.
    k.set_grants(Grants { human: false, read_mask: 0b10, write_mask: 0, may_delete: false });
    assert_eq!(refused(&k, json!({"op": "find", "table": "places"})), schema::refusal::SCOPE);
    assert_eq!(refused(&k, json!({"op": "find", "table": "op_ledger"})), schema::refusal::NOT_FOUND);
    // A declared table with no rows reads empty; the account's views are
    // the operator's, its secrets nobody's.
    let op = kernel();
    assert_eq!(q(&op, json!({"op": "find", "table": "trusted"}))["rows"], json!([]));
    assert_eq!(q(&op, json!({"op": "find", "table": "acct_keys"}))["rows"], json!([]));
    assert_eq!(refused(&k, json!({"op": "find", "table": "acct_keys"})), schema::refusal::NOT_FOUND);
    assert_eq!(refused(&op, json!({"op": "find", "table": "accounts"})), schema::refusal::NOT_FOUND);
    // Until its WELCOME, a kernel reads nothing.
    assert_eq!(refused(&kernel_with(Grants::default()), json!({"op": "find", "table": "places"})), schema::refusal::SCOPE);
    // Hostile values refuse, never trap: an offset split inside a character.
    let k = kernel();
    for w in [json!({"retrieved_at": {"ge": "2023-11-14T22:13:20+0é:0"}}), json!({"id": [1, 2]}), json!({"url": {"in": [null]}})] {
        let _ = k.query(&json!({"op": "find", "table": "sources", "where": w}));
    }
}

fn kernel_with(g: Grants) -> Kernel {
    let mut k = kernel();
    k.set_grants(g);
    k
}

/// Texts the server packs stay packed in the replica and its snapshot and
/// read on touch; a size reads without unpacking; a rolled-back write
/// leaves the packed cell exactly as it was.
#[test]
fn packed_texts_read_on_touch_and_survive_snapshot_and_rollback() {
    let doc = "Senior Rust engineer. About the team: kernels, schedulers and GPU runtimes. ".repeat(40);
    let mut z = zstd::bulk::Compressor::with_dictionary(19, wire::TEXT_DICT).unwrap();
    z.include_checksum(false).unwrap();
    z.include_contentsize(true).unwrap();
    let packed = [&[1u8][..], &z.compress(doc.as_bytes()).unwrap()].concat();
    let raw = [&[0u8][..], b"short note"].concat();
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::SOURCES, 2);
    b.u32s(S::ID, [1, 2].into_iter()).strs(S::URL, ["https://a.example/1", "https://b.example/2"].into_iter()).zstrs(S::DOC, [&packed[..], &raw[..]].into_iter());
    b.done();
    let mut k = Kernel::new();
    k.set_grants(OPERATOR);
    k.boot(&w.finish(), 1).unwrap();
    let docs = |k: &Kernel| q(k, json!({"op": "find", "table": "sources", "cols": ["doc"]}))["rows"].clone();
    assert_eq!(docs(&k), json!([{"id": 1, "doc": doc}, {"id": 2, "doc": "short note"}]));
    let sized = q(&k, json!({"op": "find", "table": "sources", "sizes": ["doc"]}))["rows"].clone();
    assert_eq!((sized[0]["doc"].clone(), sized[1]["doc"].clone()), (json!(doc.len()), json!(10)));
    // The snapshot holds the cell as packed, and restores it.
    let snap = k.snapshot();
    assert!(snap.len() < doc.len() / 4, "snapshot {} B for a {} B text", snap.len(), doc.len());
    let mut again = Kernel::new();
    again.set_grants(OPERATOR);
    again.restore(&snap).unwrap();
    assert_eq!(docs(&again), docs(&k));
    // A predicted write, then its NACK: the packed cell comes back as it was.
    let mut ops = wire::OpsWriter::new();
    let mut o = ops.op(5150, wire::PUT, 0, table::SOURCES, 1, None);
    o.str(S::DOC, "mine");
    o.done();
    let ctx = kernel::judge::Ctx { today: 739_528, now: 0, human: true, key_id: None, held: &[] };
    k.predict(&ops.finish()[8..], &ctx).unwrap();
    assert_eq!(docs(&k)[0]["doc"], "mine");
    k.ingest(&wire::encode_nacks(schema::WIRE_HASH, 2, &[wire::Nack { op_id: 5150, code: 0, data: b"{}" }])).unwrap();
    assert_eq!(k.snapshot(), snap);
}

/// A session table (the account's live views) arrives whole each time, so
/// a row the server no longer sends (a revoked key) goes; and the snapshot
/// at rest never holds one.
#[test]
fn session_tables_are_whole_and_never_at_rest() {
    use schema::col::acct_keys as AK;
    let mut k = kernel();
    let keys = |ids: &[u32]| {
        let mut w = wire::BodyWriter::new();
        let mut b = w.block(table::ACCT_KEYS, ids.len());
        b.u32s(AK::ID, ids.iter().copied()).strs(AK::NAME, ids.iter().map(|_| "k"));
        b.done();
        w.finish()
    };
    k.patch(&keys(&[1, 2]), 2).unwrap();
    k.patch(&keys(&[2]), 3).unwrap();
    let rows = q(&k, json!({"op": "find", "table": "acct_keys"}))["rows"].clone();
    assert_eq!(rows.as_array().map(|r| r.iter().map(|x| x["id"].clone()).collect::<Vec<_>>()), Some(vec![json!(2)]));
    let mut again = Kernel::new();
    again.set_grants(OPERATOR);
    again.restore(&k.snapshot()).unwrap();
    assert_eq!(q(&again, json!({"op": "find", "table": "acct_keys"}))["rows"], json!([]));
}
