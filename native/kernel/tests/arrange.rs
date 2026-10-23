//! The desk's select-by-sort through the facade: the board's filtered ids
//! narrowed, sorted on any key and grouped on another, the order, the
//! groups' bounds and the chips' counts coming back together.

mod fixture;

use kernel::abi::Kernel;
use serde_json::{Value as Json, json};

/// Applications 1-6 written "Company 10", "Company 2", "Company 1",
/// "company 2", "Company 30", "Company 3"; linked to Stripe (10), Helsing
/// (11), Stripe, none, Stripe, Helsing; in Berlin (2, Germany 1) but 4 and
/// 6; scores 50, 70, 60, -, 90, 40; 3 and 5 the same posting (5 further
/// along); 1 and 2 remote.
fn kernel() -> Kernel {
    let stripe7 = "https://stripe.com/jobs/7";
    fixture::kernel(json!({
        "places": fixture::europe(),
        "corporations": [{"id": 10, "domain": "stripe.com", "name": "Stripe"}, {"id": 11, "domain": "helsing.ai", "name": "Helsing"}],
        "applications": [
            {"id": 1, "no": 1, "stage": "gated", "company": "Company 10", "corporation_id": 10, "place_id": 2, "work_mode": "remote", "score_100": 50},
            {"id": 2, "no": 2, "stage": "gated", "company": "Company 2", "corporation_id": 11, "place_id": 2, "work_mode": "remote", "score_100": 70},
            {"id": 3, "no": 3, "stage": "discovered", "company": "Company 1", "canonical_url": stripe7, "corporation_id": 10, "place_id": 2, "score_100": 60},
            {"id": 4, "no": 4, "stage": "gated", "company": "company 2"},
            {"id": 5, "no": 5, "stage": "in_batch", "company": "Company 30", "canonical_url": stripe7, "corporation_id": 10, "place_id": 2, "score_100": 90},
            {"id": 6, "no": 6, "stage": "gated", "company": "Company 3", "corporation_id": 11, "score_100": 40},
        ],
    }))
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
