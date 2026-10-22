//! The desk's select-by-sort through the facade: the board's filtered ids
//! narrowed, sorted on any key and grouped on another, the order, the
//! groups' bounds and the chips' counts coming back together.

use kernel::abi::Kernel;
use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::{Value as Json, json};

/// Applications 1-6 written "Company 10", "Company 2", "Company 1",
/// "company 2", "Company 30", "Company 3"; linked to Stripe (10), Helsing
/// (11), Stripe, none, Stripe, Helsing; in Berlin (2, Germany 1) but 4 and
/// 6; scores 50, 70, 60, -, 90, 40; 3 and 5 the same posting (5 further
/// along); 1 and 2 remote.
fn kernel() -> Kernel {
    let none = wire::NONE;
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::PLACES, 2);
    b.u32s(col::places::ID, [1, 2].into_iter())
        .u32s(col::places::KIND, [enums::place_kind::COUNTRY, enums::place_kind::CITY].map(u32::from).into_iter())
        .u32s(col::places::COUNTRY_ID, [none, 1].into_iter())
        .strs(col::places::ISO2, ["DE", ""].into_iter())
        .strs(col::places::NAME, ["Germany", "Berlin"].into_iter());
    b.done();
    let mut b = w.block(table::CORPORATIONS, 2);
    b.u32s(col::corporations::ID, [10, 11].into_iter())
        .strs(col::corporations::DOMAIN, ["stripe.com", "helsing.ai"].into_iter())
        .strs(col::corporations::NAME, ["Stripe", "Helsing"].into_iter());
    b.done();
    let remote = enums::work_mode::REMOTE as u32;
    let mut b = w.block(table::APPLICATIONS, 6);
    b.u32s(A::ID, 1..=6)
        .u32s(A::NO, 1..=6)
        .u32s(A::STAGE, [enums::stage::GATED, enums::stage::GATED, enums::stage::DISCOVERED, enums::stage::GATED, enums::stage::IN_BATCH, enums::stage::GATED].map(u32::from).into_iter())
        .strs(A::COMPANY, ["Company 10", "Company 2", "Company 1", "company 2", "Company 30", "Company 3"].into_iter())
        .strs(A::CANONICAL_URL, ["", "", "https://stripe.com/jobs/7", "", "https://stripe.com/jobs/7", ""].into_iter())
        .u32s(A::CORPORATION_ID, [10, 11, 10, none, 10, 11].into_iter())
        .u32s(A::PLACE_ID, [2, 2, 2, none, 2, none].into_iter())
        .u32s(A::WORK_MODE, [remote, remote, none, none, none, none].into_iter())
        .u32s(A::SCORE_100, [50, 70, 60, none, 90, 40].into_iter())
        .u32s(A::HEAT_OVERRIDE, (1..=6).map(|_| 0));
    b.done();
    let mut k = Kernel::new();
    k.set_today(739_528);
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn arrange(k: &mut Kernel, req: Json) -> (Vec<u32>, Json) {
    k.arrange(&req).unwrap()
}

fn labels(groups: &Json) -> Vec<String> {
    groups["groups"].as_array().unwrap().iter().map(|g| g["label"].as_str().unwrap().to_string()).collect()
}

#[test]
fn a_sort_reads_numbers_in_text_as_people_do_and_puts_the_absent_last() {
    let mut k = kernel();
    let (ids, _) = arrange(&mut k, json!({"sort": ["company.name", "asc"]}));
    // Helsing first, then Stripe, then the one with no company; ties in the board's order.
    let mut helsing = ids[..2].to_vec();
    helsing.sort_unstable();
    assert_eq!(helsing, [2, 6]);
    let mut stripe = ids[2..5].to_vec();
    stripe.sort_unstable();
    assert_eq!(stripe, [1, 3, 5]);
    assert_eq!(ids[5], 4);
    let (asc, _) = arrange(&mut k, json!({"sort": ["no", "asc"]}));
    let (desc, _) = arrange(&mut k, json!({"sort": ["no", "desc"]}));
    assert_eq!(asc, [1, 2, 3, 4, 5, 6]);
    assert_eq!(desc, [6, 5, 4, 3, 2, 1]);
    // Score reads high first by default; the score of an unscored card is its suggestion, never absent.
    let (by_score, _) = arrange(&mut k, json!({"sort": ["score"]}));
    assert_eq!(by_score[0], 5);
}

#[test]
fn the_desk_keys_group_by_link_mark_the_unlinked_and_keep_one_duplicate() {
    let mut k = kernel();
    let (ids, g) = arrange(&mut k, json!({"group": "company", "largest": true, "sort": ["no", "asc"]}));
    assert_eq!(labels(&g), ["Stripe", "Helsing", "company 2 · unlinked"]);
    assert_eq!(ids, [1, 3, 5, 2, 6, 4]);
    let (ids, g) = arrange(&mut k, json!({"group": "dupes"}));
    assert_eq!(ids.len(), 2, "only a duplicate set is shown when grouping by duplicates");
    assert_eq!(g["groups"][0]["keep"], 5, "the furthest along is kept");
    let (_, g) = arrange(&mut k, json!({"group": "country"}));
    assert_eq!(labels(&g), ["Germany (DE)", "(none)"]);
    let (_, g) = arrange(&mut k, json!({"group": "company.applications"}));
    assert_eq!(labels(&g), ["3 applications", "2 applications", "(none)"]);
    let (_, g) = arrange(&mut k, json!({"group": "country.applications"}));
    assert_eq!(labels(&g)[0], "4 applications");
    let (_, g) = arrange(&mut k, json!({"group": "score"}));
    assert_eq!(labels(&g)[0], "90–100", "the score groups by tens, high first");
}

#[test]
fn filters_narrow_and_the_chips_count_the_modes_and_the_unlinked() {
    let mut k = kernel();
    let (ids, g) = arrange(&mut k, json!({"unlinked": true, "sort": ["no", "asc"]}));
    // 4 has no company; 6 has no place and is not remote.
    assert_eq!(ids, [4, 6]);
    assert_eq!(g["unlinked"], 2);
    let (ids, g) = arrange(&mut k, json!({"modes": ["remote"], "sort": ["no", "asc"]}));
    assert_eq!(ids, [1, 2]);
    assert_eq!((&g["modes"]["remote"], &g["modes"]["none"]), (&json!(2), &json!(4)));
    let (ids, _) = arrange(&mut k, json!({"filter": {"search": "company 2"}, "sort": ["no", "asc"]}));
    assert_eq!(ids, [2, 4]);
    assert!(k.arrange(&json!({"sort": ["nope", "asc"]})).is_err());
}

#[test]
fn a_mended_column_arranges_as_one_built_from_the_rows() {
    // Seeded writes in place (company text, a link, a score, a role), each
    // arranged by the mended kernel and by a fresh one restored from its rows.
    let mut k = kernel();
    let asks = [
        json!({"sort": ["company.name", "asc"], "group": "field"}),
        json!({"sort": ["no", "desc"], "group": "company.name", "largest": true}),
        json!({"sort": ["role", "asc"], "group": "seniority"}),
        json!({"group": "work_mode"}),
    ];
    for a in &asks {
        arrange(&mut k, a.clone());
    }
    let mut seed = 0x2545_f491_u32;
    let mut next = |n: u32| {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        seed % n
    };
    let roles = ["Staff Engineer", "Research Scientist", "Intern, ML", "senior sre"];
    for step in 0..40 {
        let id = 1 + next(6);
        let mut w = wire::BodyWriter::new();
        let mut b = w.block(table::APPLICATIONS, 1);
        b.u32s(A::ID, [id].into_iter());
        match next(4) {
            0 => {
                b.strs(A::ROLE, [roles[next(4) as usize]].into_iter());
            }
            1 => {
                b.u32s(A::CORPORATION_ID, [[10, 11, wire::NONE][next(3) as usize]].into_iter());
            }
            2 => {
                b.u32s(A::SCORE_100, [next(101)].into_iter());
            }
            _ => {
                b.u32s(A::WORK_MODE, [[enums::work_mode::REMOTE as u32, enums::work_mode::ONSITE as u32, wire::NONE][next(3) as usize]].into_iter());
            }
        }
        b.done();
        k.patch(&w.finish(), 2 + step).unwrap();
        let mut fresh = Kernel::new();
        fresh.set_today(739_528);
        fresh.restore(&k.snapshot()).unwrap();
        for a in &asks {
            assert_eq!(arrange(&mut k, a.clone()), arrange(&mut fresh, a.clone()), "step {step}: {a}");
        }
    }
}

/// `find` on applications is the desk's query: the board grouped by company
/// unless told otherwise, each row with its card's score, band and class,
/// the page's groups with absolute starts, a grouped listing; `where`,
/// the filters and `sort` narrow and order before the groups form and
/// `after` is the row offset; `order` names the plain keyset find; an
/// unknown key is refused with the known ones; a key that reads no desk
/// is refused, and the overview under it has no board.
#[test]
fn a_find_on_applications_is_the_desk_grouped_by_company() {
    use kernel::query::Grants;
    let mut k = kernel();
    k.set_grants(Grants { human: true, read_mask: 0b11111, write_mask: 0, may_delete: false });
    let find = |k: &mut Kernel, req: Json| k.query(&json!({"op": "find", "table": "applications"}).as_object().unwrap().iter().chain(req.as_object().unwrap()).map(|(a, b)| (a.clone(), b.clone())).collect::<Json>()).unwrap_or_else(|r| panic!("{req}: {r:?}"));
    let page = find(&mut k, json!({}));
    assert_eq!((page["total"].as_u64(), page["unlinked"].as_u64(), page["modes"]["remote"].as_u64()), (Some(6), Some(2), Some(2)));
    assert_eq!(page["next"], Json::Null);
    let labels: Vec<(&str, u64)> = page["groups"].as_array().unwrap().iter().map(|g| (g["label"].as_str().unwrap(), g["count"].as_u64().unwrap())).collect();
    assert_eq!(labels, [("company 2 · unlinked", 1), ("Helsing", 2), ("Stripe", 3)]);
    // Rows stand in their groups' order, each a find row with its card.
    let nos: Vec<u64> = page["rows"].as_array().unwrap().iter().map(|r| r["no"].as_u64().unwrap()).collect();
    assert_eq!(&nos[..1], [4]);
    assert_eq!(nos[1..3].iter().copied().collect::<std::collections::BTreeSet<_>>(), [2, 6].into());
    let stripe = &page["rows"][3];
    assert!(stripe["score"].is_number() && stripe["band"].is_string() && stripe["class"].is_string() && stripe["company"].is_string());
    let listing = page["listing"].as_str().unwrap();
    assert!(listing.starts_with("6 applications in board order (score, then heat), grouped by company; rows 1-6\n"), "{listing}");
    assert!(listing.contains("\nStripe (3)\n") && listing.contains("\nHelsing (2)\n") && listing.contains("  #4  company 2"), "{listing}");
    // where narrows before the groups form; sort and after page the order; "" groups nothing.
    let stripe = find(&mut k, json!({"where": {"corporation_id": 10}}));
    assert_eq!((stripe["total"].as_u64(), stripe["groups"].as_array().unwrap().len()), (Some(3), 1));
    let second = find(&mut k, json!({"sort": ["no", "desc"], "group": "", "after": 1, "limit": 1}));
    assert_eq!((second["rows"][0]["no"].as_u64(), second["next"].as_u64(), second["groups"].as_array().unwrap().len()), (Some(5), Some(2), 0));
    assert!(second["listing"].as_str().unwrap().ends_with("next: {\"after\": 2}\n"), "{}", second["listing"]);
    let remote = find(&mut k, json!({"modes": ["remote"], "search": "company"}));
    assert_eq!(remote["total"], 2);
    // The plain find is the keyset walk, ungrouped.
    let plain = k.query(&json!({"op": "find", "table": "applications", "order": ["id"], "limit": 2})).unwrap();
    assert!(plain.get("groups").is_none() && plain["next"].is_string() && plain["rows"][0]["band"].is_null(), "{plain}");
    let r = k.query(&json!({"op": "find", "table": "applications", "sort": "nope"})).unwrap_err();
    assert_eq!((r.code, r.data["unknown"].as_str()), (schema::refusal::TYPE, Some("nope")));
    assert!(r.data["known"].as_array().unwrap().iter().any(|x| x == "company.name"));
    // A key reading only the world sees no desk: the find is refused and the overview has no board.
    let world = Grants { human: false, read_mask: 0b1, write_mask: 0, may_delete: false };
    assert_eq!(k.query_as(&world, &json!({"op": "find", "table": "applications"})).unwrap_err().code, schema::refusal::SCOPE);
    assert!(k.overview_as(&world, 8).get("top").is_none());
    let top = k.overview(2);
    assert_eq!((top["top"]["total"].as_u64(), top["top"]["rows"].as_array().unwrap().len(), top["top"]["groups"][0]["label"].as_str()), (Some(6), 2, Some("company 2 · unlinked")));
    assert!(top["scoreboard"].is_object());
}
