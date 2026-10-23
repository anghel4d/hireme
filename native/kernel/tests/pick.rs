//! Which CV root an application gets, through the kernel's facade: the
//! ordered match over the rules, pins, the default, the reads the lens
//! and the MCP draw from, and the judge's rules on CV writes.

mod fixture;

use fixture::{DAWN, agent, cells, cmd, del, gone, operator, packed, put, q, refused};
use kernel::abi::{self, Kernel};
use kernel::query::Grants;
use schema::{col, refusal, table};
use serde_json::{Value as Json, json};

/// Germany (1) with Berlin (2), France (3); Stripe (10) and Acme (11);
/// roots DACH (20, markdown, version 30), Stripe (21, pdf, version 31),
/// Default (22, composed, no version), France (23, markdown, none yet);
/// the dach mask; rules in order: a disabled catch-all, Stripe, dach,
/// France; the default root 22. Applications: Stripe in Berlin (1), Acme
/// in Berlin (2), Acme in France (3), Acme nowhere (4), Acme in Berlin
/// pinned to Stripe by an agent (5), all in an open batch and open_fire.
fn kernel() -> Kernel {
    let app = |id: u32, corporation: u32, place: Json| {
        json!({"id": id, "no": id, "stage": "open_fire", "batch_id": 1, "company": if corporation == 10 { "Stripe" } else { "Acme" }, "role": "Research Engineer", "corporation_id": corporation, "place_id": place, "heat_override": false})
    };
    let mut pinned = app(5, 11, json!(2));
    pinned["cv_root_id"] = json!(21);
    pinned["cv_pinned_by"] = json!("agent");
    let root = |id: u32, slug: &str, name: &str, format: &str, version: Json| json!({"id": id, "slug": slug, "name": name, "format": format, "version_id": version});
    let rule = |id: u32, position: u32, root: u32, enabled: bool, pattern: &str| json!({"id": id, "position": position, "root_id": root, "enabled": enabled, "pattern": pattern});
    fixture::kernel(json!({
        "places": fixture::europe(),
        "corporations": [{"id": 10, "domain": "stripe.com", "name": "Stripe"}, {"id": 11, "domain": "acme.com", "name": "Acme"}],
        "cv_roots": [root(20, "dach", "DACH", "markdown", json!(30)), root(21, "stripe", "Stripe", "pdf", json!(31)), root(22, "default", "Default", "composed", Json::Null), root(23, "france", "France", "markdown", Json::Null)],
        "cv_versions": [{"id": 30, "root_id": 20, "n": 1, "text": "# Ana\nRust, inference kernels."}, {"id": 31, "root_id": 21, "n": 1, "text": "Payments infrastructure."}],
        "cv_masks": [{"id": 50, "name": "dach", "pattern": "[country in [DE, AT, CH]]"}],
        "cv_rules": [rule(43, 0, 21, false, "[country _]"), rule(40, 1, 21, true, "[company.domain = \"stripe.com\"]"), rule(41, 2, 20, true, "dach"), rule(42, 3, 23, true, "country = FR")],
        "me": [{"id": 1, "cv_default_root_id": 22, "citizenships": "DE"}],
        "batches": [{"id": 1, "fire": "open_fire"}],
        "applications": [app(1, 10, json!(2)), app(2, 11, json!(2)), app(3, 11, json!(3)), app(4, 11, Json::Null), pinned],
    }))
}

fn picks(k: &mut Kernel) -> Vec<Json> {
    q(k, json!({"op": "cv_picks"}))["picks"].as_array().unwrap().clone()
}

fn pick_cv(app: u32, root: u32) -> Vec<u8> {
    cmd("pick_cv", app, json!({"cv_root_id": root}))
}

#[test]
fn the_first_enabled_arm_wins_a_pin_wins_over_it_and_the_default_takes_the_rest() {
    let mut k = kernel();
    let p = picks(&mut k);
    let row = |i: usize| (&p[i]["state"], &p[i]["root"], &p[i]["arm"], &p[i]["also"], &p[i]["version_id"], &p[i]["by"]);
    // Stripe in Berlin: the Stripe arm comes before dach, which also matches.
    assert_eq!(row(0), (&json!("matched"), &json!(21), &json!(40), &json!([41]), &json!(31), &json!(null)));
    assert_eq!(row(1), (&json!("matched"), &json!(20), &json!(41), &json!([]), &json!(30), &json!(null)));
    // France's root has nothing to send yet.
    assert_eq!(row(2), (&json!("empty"), &json!(23), &json!(42), &json!([]), &json!(null), &json!(null)));
    // No arm: the default, a composition, needs no version.
    assert_eq!(row(3), (&json!("default"), &json!(22), &json!(null), &json!([]), &json!(null), &json!(null)));
    assert_eq!(row(4), (&json!("pinned"), &json!(21), &json!(null), &json!([41]), &json!(31), &json!("agent")));

    assert_eq!(q(&mut k, json!({"op": "cv_picks", "where": {"state": "matched"}}))["picks"].as_array().unwrap().len(), 2);
    assert_eq!(q(&mut k, json!({"op": "cv_pick", "application": 2}))["root"], 20);
    assert_eq!(k.query(&json!({"op": "cv_pick", "application": 99})).unwrap_err().code, refusal::NOT_FOUND);
}

#[test]
fn a_pin_by_the_operator_or_an_agent_moves_the_pick_and_unpinning_gives_it_back() {
    let mut k = kernel();
    k.predict(&pick_cv(2, 23), &operator(DAWN)).unwrap();
    let p = q(&mut k, json!({"op": "cv_pick", "application": 2}));
    assert_eq!((&p["state"], &p["root"], &p["by"]), (&json!("empty"), &json!(23), &json!("operator")));

    k.predict(&cmd("unpin_cv", 2, json!({})), &agent(3, DAWN)).unwrap();
    assert_eq!(q(&mut k, json!({"op": "cv_pick", "application": 2}))["state"], "matched");

    assert_eq!(refused(k.judge(&pick_cv(2, 99), &agent(3, DAWN))).0, refusal::NOT_FOUND);
    let fx = k.judge(&pick_cv(2, 21), &agent(3, DAWN)).unwrap();
    assert!(fx.iter().any(|r| r.table == table::EVENTS), "a pin is on the application's trail");
}

#[test]
fn a_dropped_root_turns_its_pin_stale() {
    let mut k = kernel();
    k.patch(&gone(table::CV_ROOTS, &[21]), 2).unwrap();
    let p = picks(&mut k);
    assert_eq!((&p[4]["state"], &p[4]["root"]), (&json!("stale"), &json!(21)));
    // Its arm is gone with it: Stripe falls through to dach.
    assert_eq!((&p[0]["arm"], &p[0]["root"]), (&json!(41), &json!(20)));
}

#[test]
fn going_out_freezes_the_version_the_pick_sends() {
    let mut k = kernel();
    let out = |k: &mut Kernel, app: u32| cells(&k.judge(&cmd("stage", app, json!({"stage": "submitted"})), &operator(DAWN)).unwrap(), "applications").get("cv_version_id").cloned();
    assert_eq!(out(&mut k, 1), Some(json!(31)));
    assert_eq!(out(&mut k, 4), Some(Json::Null));
}

#[test]
fn a_rule_or_mask_that_does_not_compile_is_refused_where_it_breaks() {
    let mut k = kernel();
    let mut judge = |op: Vec<u8>| refused(k.judge(&op, &operator(DAWN)));
    let (code, data) = judge(put("cv_rules", 40, json!({"pattern": "country = :de"})));
    assert_eq!((code, &data["at"], &data["rule"]), (refusal::RULE, &json!(10), &json!(40)));
    // Renaming dach breaks the rule that names it; dropping it too.
    for breaks in [put("cv_masks", 50, json!({"name": "dacha"})), del("cv_masks", 50)] {
        let (code, data) = judge(breaks);
        assert_eq!((code, &data["rule"]), (refusal::RULE, &json!(41)));
    }
    for bad in ["country", "Dach", "in"] {
        assert_eq!(judge(put("cv_masks", 0, json!({"name": bad, "pattern": "country = DE"}))).0, refusal::RULE, "{bad}");
    }
    // A mask naming itself through another is a cycle.
    assert!(judge(put("cv_masks", 50, json!({"pattern": "dach | country = FR"}))).1["error"].as_str().unwrap().contains("names itself"));
    assert!(k.judge(&put("cv_rules", 40, json!({"pattern": "dach & company.size = :mega"})), &operator(DAWN)).is_ok());
}

#[test]
fn a_version_carries_what_its_root_format_takes_and_becomes_the_root_head() {
    let mut k = kernel();
    let version = |cells: Json| put("cv_versions", 0, cells);
    assert_eq!(refused(k.judge(&version(json!({"root_id": 23, "blob_sha": "ab12"})), &operator(DAWN))).0, refusal::TYPE);
    assert_eq!(refused(k.judge(&version(json!({"root_id": 21, "body": "# CV"})), &operator(DAWN))).0, refusal::TYPE);
    // A file keeps its blob when the operator edits its text.
    assert!(k.judge(&version(json!({"root_id": 21, "body": "Payments infra, edited", "blob_sha": "ab12"})), &operator(DAWN)).is_ok());
    assert_eq!(refused(k.judge(&version(json!({"root_id": 99, "body": "# CV"})), &operator(DAWN))).0, refusal::NOT_FOUND);
    let fx = k.judge(&version(json!({"root_id": 23, "body": "# Ana\nRust, kernels"})), &operator(DAWN)).unwrap();
    assert!(abi::effects_json(&fx).as_array().unwrap().contains(&json!({"table": "cv_roots", "id": 23, "cells": {"version_id": {"new": 0}}})), "the root moves");

    k.predict(&version(json!({"root_id": 23, "body": "# Ana"})), &operator(DAWN)).unwrap();
    assert_eq!(q(&mut k, json!({"op": "cv_pick", "application": 3}))["state"], "matched");
}

/// A rule and a mask long enough to arrive packed are the rule and mask
/// their text says: the rule explains, a put that only enables it lands and
/// it picks, and a mask written beside them still finds both compiling.
#[test]
fn a_long_rule_or_mask_arrives_packed_and_reads_as_its_text() {
    let pad = (0..40).map(|i| format!("location ~ \"Nowhere {i}\"")).collect::<Vec<_>>().join(" | ");
    let (mask, rule) = (packed(&format!("[country in [DE, AT, CH]] | {pad}")), packed(&format!("dach | {pad}")));
    let mut k = fixture::kernel(json!({
        "places": fixture::europe(),
        "cv_roots": [{"id": 20, "slug": "dach", "name": "DACH", "format": "composed"}],
        "applications": [{"id": 1, "no": 1, "company": "Acme", "role": "Engineer", "place_id": 2}, {"id": 2, "no": 2, "company": "Acme", "role": "Engineer"}],
    }));
    let mut w = wire::BodyWriter::new();
    w.block(table::CV_MASKS, 1).u32s(col::cv_masks::ID, [50].into_iter()).strs(col::cv_masks::NAME, ["dach"].into_iter()).zstrs(col::cv_masks::PATTERN, [&mask[..]].into_iter());
    let mut b = w.block(table::CV_RULES, 1);
    b.u32s(col::cv_rules::ID, [40].into_iter()).u32s(col::cv_rules::POSITION, [0].into_iter()).u32s(col::cv_rules::ROOT_ID, [20].into_iter()).u32s(col::cv_rules::ENABLED, [0].into_iter());
    b.zstrs(col::cv_rules::PATTERN, [&rule[..]].into_iter());
    k.patch(&w.finish(), 2).unwrap();

    let matched = |k: &mut Kernel, app: u32| q(k, json!({"op": "cv_explain", "application": app}))[0]["matched"].clone();
    assert_eq!((matched(&mut k, 1), matched(&mut k, 2)), (json!(true), json!(false)));
    k.predict(&put("cv_rules", 40, json!({"enabled": true})), &operator(DAWN)).unwrap();
    let p = q(&mut k, json!({"op": "cv_pick", "application": 1}));
    assert_eq!((&p["state"], &p["root"], &p["arm"]), (&json!("matched"), &json!(20), &json!(40)));
    assert!(k.judge(&put("cv_masks", 0, json!({"name": "nordics", "pattern": "country in [SE, NO]"})), &operator(DAWN)).is_ok());
}

#[test]
fn a_rule_text_is_checked_explained_and_its_fields_listed() {
    let mut k = kernel();
    let mut check = |text: &str, at: Option<usize>| q(&mut k, json!({"op": "mask_check", "text": text, "position": at}));
    // Every application in Germany is already taken by Stripe's arm or dach's.
    let c = check("country = DE", None);
    assert_eq!((&c["ok"], &c["shadowed"], &c["never_matches"]), (&json!(true), &json!([40, 41]), &json!(false)));
    assert_eq!(check("country = DE", Some(0))["shadowed"], json!([]));
    assert_eq!(check("country = JP", None)["never_matches"], true);
    // "Research Engineer" names no level: mid.
    assert_eq!(check("seniority = :mid", Some(0))["never_matches"], false);
    assert_eq!(check("seniority >= :senior", None)["never_matches"], true);
    let bad = check("country = ", None);
    assert_eq!((&bad["ok"], &bad["error"]["pos"]), (&json!(false), &json!(10)));

    let why = q(&mut k, json!({"op": "cv_explain", "application": 3}));
    let arm = |n: u32| why.as_array().unwrap().iter().find(|a| a["arm"] == n).unwrap().clone();
    assert_eq!((&arm(40)["matched"], &arm(40)["failed"]["read"], &arm(42)["matched"]), (&json!(false), &json!("\"acme.com\""), &json!(true)));

    assert_eq!(q(&mut k, json!({"op": "mask_fields"}))["fields"].as_array().unwrap().len(), kernel::mask::FIELDS.len());
    // A key without the CV tables in its mask reads no picks.
    k.set_grants(Grants { human: false, read_mask: 0, write_mask: 0, may_delete: false });
    assert_eq!(k.query(&json!({"op": "cv_picks"})).unwrap_err().code, refusal::SCOPE);
}

#[test]
fn the_application_shows_the_picked_file_version_and_reads_its_words() {
    let mut k = kernel();
    let doc = k.application(2).unwrap();
    let file = &doc["cv"]["file"];
    assert_eq!((&file["format"], &file["version_id"], &file["n"], &file["text"]), (&json!("markdown"), &json!(30), &json!(1), &json!("# Ana\nRust, inference kernels.")));
    assert_eq!(doc["cv_pick"]["root"], 20);
    // Pinned elsewhere, it shows that root's version instead.
    k.predict(&pick_cv(2, 21), &operator(DAWN)).unwrap();
    assert_eq!(k.application(2).unwrap()["cv"]["file"]["text"], "Payments infrastructure.");
    // The default, a composition, has no file.
    assert_eq!(k.application(4).unwrap()["cv"]["file"], Json::Null);
}
