//! The desk's select-by-sort through the facade: the board's filtered ids
//! sorted on any field and grouped on another, the order and the groups'
//! bounds coming back together.

use kernel::abi::Kernel;
use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::json;

/// Applications 1-6 at Stripe (10), Helsing (11), Stripe, none, Stripe,
/// Helsing; companies written "Company 10", "Company 2", ... so text sorts
/// by number; scores 50, 70, 60, -, 90, 40.
fn kernel() -> Kernel {
    let none = wire::NONE;
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::CORPORATIONS, 2);
    b.u32s(col::corporations::ID, [10, 11].into_iter())
        .strs(col::corporations::DOMAIN, ["stripe.com", "helsing.ai"].into_iter())
        .strs(col::corporations::NAME, ["Stripe", "Helsing"].into_iter());
    b.done();
    let mut b = w.block(table::APPLICATIONS, 6);
    b.u32s(A::ID, 1..=6)
        .u32s(A::NO, 1..=6)
        .u32s(A::STAGE, (1..=6).map(|_| enums::stage::GATED as u32))
        .strs(A::COMPANY, ["Company 10", "Company 2", "Company 1", "company 2", "Company 30", "Company 3"].into_iter())
        .u32s(A::CORPORATION_ID, [10, 11, 10, none, 10, 11].into_iter())
        .u32s(A::SCORE_100, [50, 70, 60, none, 90, 40].into_iter())
        .u32s(A::HEAT_OVERRIDE, (1..=6).map(|_| 0));
    b.done();
    let mut k = Kernel::new();
    k.set_today(739_528);
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn arrange(k: &mut Kernel, req: serde_json::Value) -> (Vec<u32>, serde_json::Value) {
    let (ids, groups) = k.arrange(&req).unwrap();
    (ids, kernel::arrange::groups_json(&groups))
}

#[test]
fn a_sort_reads_numbers_in_text_as_people_do_and_puts_the_absent_last() {
    let mut k = kernel();
    let (ids, _) = arrange(&mut k, json!({"sort": ["company", "asc"]}));
    assert_eq!(ids, [3, 2, 4, 6, 1, 5], "1, 2, 2, 3, 10, 30; case aside");
    let (ids, _) = arrange(&mut k, json!({"sort": ["company.name", "desc"]}));
    assert_eq!(&ids[..5].iter().map(|i| [1, 3, 5].contains(i)).collect::<Vec<_>>(), &[true, true, true, false, false]);
    assert_eq!(ids[5], 4, "no company: last, falling too");
    let (asc, _) = arrange(&mut k, json!({"sort": ["no", "asc"]}));
    let (desc, _) = arrange(&mut k, json!({"sort": ["no", "desc"]}));
    assert_eq!(asc, [1, 2, 3, 4, 5, 6]);
    assert_eq!(desc, [6, 5, 4, 3, 2, 1]);
}

#[test]
fn a_group_by_keeps_the_sort_inside_and_the_largest_group_can_lead() {
    let mut k = kernel();
    let (ids, groups) = arrange(&mut k, json!({"group": "company.name", "largest": true, "sort": ["no", "desc"]}));
    assert_eq!(
        groups,
        json!([{"label": "Stripe", "start": 0, "count": 3}, {"label": "Helsing", "start": 3, "count": 2}, {"label": "(none)", "start": 5, "count": 1}])
    );
    assert_eq!(ids, [5, 3, 1, 6, 2, 4]);
    // By key: alphabetical, the absent last.
    let (_, groups) = arrange(&mut k, json!({"group": "company.name"}));
    let labels: Vec<&str> = groups.as_array().unwrap().iter().map(|g| g["label"].as_str().unwrap()).collect();
    assert_eq!(labels, ["Helsing", "Stripe", "(none)"]);
    // A score groups by tens.
    let (_, groups) = arrange(&mut k, json!({"group": "score"}));
    let labels: Vec<&str> = groups.as_array().unwrap().iter().map(|g| g["label"].as_str().unwrap()).collect();
    assert_eq!(labels, ["40–49", "50–59", "60–69", "70–79", "90–100", "(none)"]);
    // The board's filter narrows first.
    let (ids, _) = arrange(&mut k, json!({"filter": {"search": "company 2"}, "sort": ["no", "asc"]}));
    assert_eq!(ids, [2, 4]);
    assert!(k.arrange(&json!({"sort": ["nope", "asc"]})).is_err());
}
