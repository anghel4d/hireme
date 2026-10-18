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

fn kernel() -> Kernel {
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::PLACES, N as usize);
    b.u32s(P::ID, 1..=N)
        .u32s(P::KIND, (1..=N).map(|i| if i % 3 == 0 { enums::place_kind::COUNTRY } else { enums::place_kind::CITY } as u32))
        .strs(P::ISO2, (1..=N).map(|i| if i % 3 == 0 { ["PT", "DE", "JP"][(i as usize / 3) % 3] } else { "" }))
        .strs(P::NAME, (1..=N).map(|i| ["Lisbon", "lisboa", "Porto", "Berlin", "Tōkyō"][i as usize % 5]))
        .strs(P::REGION, (1..=N).map(|i| REGIONS[i as usize % 4]))
        .u32s(P::POPULATION, (1..=N).map(|i| if i % 7 == 0 { wire::NONE } else { (i * 7919) % 1000 }));
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
    let pop = |i: u32| (i % 7 != 0).then_some((i * 7919) % 1000);
    let filters: [(Json, &dyn Fn(u32) -> bool); 6] = [
        (json!({}), &|_| true),
        (json!({"population": {"gt": 500}}), &|i| pop(i).is_some_and(|p| p > 500)),
        (json!({"population": {"ne": 0}}), &|i| pop(i) != Some(0)),
        (json!({"name": {"like": "LIS"}}), &|i| i % 5 <= 1),
        (json!({"region": {"null": true}, "kind": "country"}), &|i| i % 4 == 2 && i % 3 == 0),
        (json!({"kind": {"in": ["city"]}, "population": {"le": 100}}), &|i| i % 3 != 0 && pop(i).is_some_and(|p| p <= 100)),
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
                let ids: Vec<u32> = got.iter().map(|g| g.1).collect();
                let mut want: Vec<u32> = (1..=N).filter(|&i| keep(i)).collect();
                want.sort_unstable();
                let mut sorted = ids.clone();
                sorted.sort_unstable();
                assert_eq!(sorted, want, "{w} {order} {desc} {limit}");
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
    let stub = &q(&k, json!({"op": "find", "table": "sources", "cols": ["doc"]}))["rows"][0]["doc"];
    assert_eq!(stub["len"], 400_000);
    assert_eq!(stub["sha"].as_str().unwrap().len(), 16);
    // A key reads its mask's domains only, never a private column.
    k.set_grants(Grants { human: false, read_mask: 0b10, write_mask: 0, may_delete: false });
    assert_eq!(refused(&k, json!({"op": "find", "table": "places"})), schema::refusal::SCOPE);
    assert_eq!(refused(&k, json!({"op": "find", "table": "op_ledger"})), schema::refusal::NOT_FOUND);
}
