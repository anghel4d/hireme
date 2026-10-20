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
