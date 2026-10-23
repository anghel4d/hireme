//! The domain check through the kernel's facade: an op in the OPS layout
//! against resident rows, answered with a refusal or the effects the
//! sequencer persists. Rules from docs/rebuild.md "The sequencer's
//! checks", step 4: lineage and cooldown, the day a move writes, natural
//! keys and links. The moves, the fire hold, heat and keywords at write
//! time are tests/vectors.json's.

mod fixture;

use fixture::{DAWN, TODAY, agent, body, cells, cmd, del, gone, keyed, put, refused};
use kernel::abi::Kernel;
use kernel::judge::Ctx;
use schema::col::applications as A;
use schema::{col, refusal, table};
use serde_json::{Value as Json, json};

fn ctx() -> Ctx<'static> {
    agent(3, DAWN)
}

fn app(id: u32, stage: &str, company: &str, corporation: Json) -> Json {
    json!({"id": id, "no": id, "stage": stage, "company": company, "role": "Software Engineer", "corporation_id": corporation, "stage_on": TODAY, "heat_override": false})
}

/// A kernel with `rows` beside the company and place a new application
/// must name (corporation 1, place 1) and the items an overlay names (5, 6).
fn kernel(mut rows: Json) -> Kernel {
    rows["corporations"] = json!([{"id": 1, "domain": "acme.example", "name": "Acme"}]);
    rows["places"] = json!([{"id": 1, "kind": "country", "iso2": "DE", "name": "Germany"}]);
    rows["items"] = json!([{"id": 5, "key": "k", "title": "Kernel work"}, {"id": 6, "key": "j", "title": "Wire work"}]);
    fixture::kernel(rows)
}

fn overlay(app: u32, target: u32) -> Vec<u8> {
    put("cv_overlays", target, json!({"application_id": app, "item_id": 5, "mode": 0}))
}

/// The day a move is judged on, through the facade: a pinned day, else the
/// server's clock row, else `set_today`'s; never the ctx's own.
#[test]
fn the_day_a_move_writes_is_pinned_then_clock_then_set_today() {
    let mut k = kernel(json!({"applications": [app(1, "gated", "Acme", Json::Null)]}));
    let late = Ctx { today: TODAY + 50, ..ctx() };
    let stage_on = |k: &mut Kernel| cells(&k.judge(&cmd("stage", 1, json!({"stage": "closed"})), &late).unwrap(), "applications")["stage_on"].clone();
    assert_eq!(stage_on(&mut k), TODAY);
    k.patch(&body(&json!({"clock": [{"today": TODAY + 1}]})), 2).unwrap();
    assert_eq!(stage_on(&mut k), TODAY + 1);
    k.pin_today(TODAY + 2);
    assert_eq!(stage_on(&mut k), TODAY + 2);
}

/// A corporation's first overlay opens its lineage and a closed window waits
/// for the next generation (tests/vectors.json). No corporation, no lineage;
/// the prediction links the two rows. With rewrites off an overlay is added,
/// never rewritten or dropped, nor is the line taken again by another
/// application; the next generation waits out its cooldown, and past the
/// window a drop waits for it as a write does.
#[test]
fn a_lineage_is_one_story_per_corporation_and_waits_out_its_windows() {
    let lineage = |rewrites: bool| json!([{"id": 7, "corporation_id": 40, "opened_on": TODAY - 10, "generation": 1, "rewrites_allowed": rewrites}]);
    let mut k = kernel(json!({"applications": [app(1, "draft_ready", "Acme", json!(40)), app(2, "gated", "Nobody", Json::Null)]}));
    assert_eq!(refused(k.judge(&overlay(2, 0), &ctx())).0, refusal::NOT_FOUND);
    k.predict(&overlay(1, 0), &ctx()).unwrap();
    let (lineages, ov) = (k.rows().table(table::CV_LINEAGES).unwrap(), k.rows().table(table::CV_OVERLAYS).unwrap());
    assert_eq!((lineages.len(), ov.u32(ov.ids()[0], col::cv_overlays::LINEAGE_ID)), (1, Some(lineages.ids()[0])));

    let mut k = kernel(json!({"applications": [app(1, "draft_ready", "Acme", json!(40)), app(2, "draft_ready", "Acme", json!(40))], "cv_lineages": lineage(false)}));
    k.predict(&overlay(1, 0), &ctx()).unwrap();
    let existing = k.rows().table(table::CV_OVERLAYS).unwrap().ids()[0];
    for busy in [overlay(1, existing), del("cv_overlays", existing), overlay(2, 0)] {
        assert_eq!(refused(k.judge(&busy, &ctx())).0, refusal::LINEAGE_BUSY);
    }
    let (code, data) = refused(k.judge(&cmd("open_generation", 0, json!({"corporation_id": 40})), &ctx()));
    assert_eq!((code, data["days_left"].as_i64(), data["opened_on"].as_str()), (refusal::COOLDOWN, Some(80), Some("2024-09-24")));

    let mut aged = kernel(json!({"applications": [app(1, "draft_ready", "Acme", json!(40))], "cv_lineages": lineage(true)}));
    aged.predict(&overlay(1, 0), &ctx()).unwrap();
    let existing = aged.rows().table(table::CV_OVERLAYS).unwrap().ids()[0];
    aged.pin_today(TODAY + 80);
    let (code, data) = refused(aged.judge(&del("cv_overlays", existing), &ctx()));
    assert_eq!((code, data["opened_on"].as_str(), data["need"].as_str()), (refusal::COOLDOWN, Some("2024-09-24"), Some("open_generation")));
}

#[test]
fn a_frame_that_fails_part_way_leaves_nothing_stale() {
    let mut k = kernel(json!({"applications": [app(1, "gated", "Acme", Json::Null), app(2, "gated", "Bolt", Json::Null)]}));
    // A keyed table's block with no id column: the body fails after the first block.
    assert!(k.patch(&body(&json!({"applications": [{"id": 1, "score_100": 99}], "events": [{"application_id": 1}]})), 2).is_err());
    assert_eq!(k.board_ids(None)[0], 1);
}

#[test]
fn a_sentinel_cell_is_refused_as_the_server_refuses_it() {
    let mut k = kernel(json!({"applications": [app(1, "gated", "Acme", Json::Null)]}));
    let none = fixture::raw(wire::PUT, 0, table::APPLICATIONS, 1, None, |o| {
        o.u32(A::SCORE_100, wire::NONE);
    });
    assert_eq!(refused(k.judge(&none, &ctx())).0, refusal::TYPE);
    assert!(k.judge(&put("applications", 1, json!({"score_100": null})), &ctx()).is_ok());
}

#[test]
fn a_predicted_row_carries_its_id_and_a_corporation_keeps_a_surviving_lineage() {
    let mut k = kernel(json!({"applications": [app(1, "draft_ready", "Acme", json!(40))]}));
    // A note's event is the events table's first row, inserted by the client.
    k.predict(&cmd("note", 1, json!({"stage": "gated", "body": "called"})), &ctx()).unwrap();
    let ev = k.rows().table(table::EVENTS).unwrap();
    assert_eq!(ev.u32(ev.ids()[0], col::events::ID), Some(ev.ids()[0]));
    // A predicted overlay opens a lineage for corporation 40; the server's
    // own arrives, then goes: the predicted one still tells the story.
    k.predict(&overlay(1, 0), &ctx()).unwrap();
    k.patch(&body(&json!({"cv_lineages": [{"id": 3, "corporation_id": 40, "opened_on": TODAY, "rewrites_allowed": true}]})), 2).unwrap();
    k.patch(&gone(table::CV_LINEAGES, &[3]), 3).unwrap();
    // Another item on the same line (the same item twice is a unique clash).
    let fx = k.judge(&put("cv_overlays", 0, json!({"application_id": 1, "item_id": 6, "mode": 0})), &ctx()).unwrap();
    assert!(fx.iter().all(|r| r.table != table::CV_LINEAGES), "no second lineage: {fx:?}");
}

/// The scoreboard counts submissions: an outreach answered without one
/// reached `reply` with `submitted` skipped, and is not counted. Without
/// pips that agree with its stage, a reply or close counts by `applied_on`.
#[test]
fn scoreboard_counts_only_submissions() {
    let row = |id: u32, stage: &str, pips: &str, applied: bool| json!({"id": id, "no": id, "stage": stage, "pips": pips, "company": "Co", "role": "R", "applied_on": if applied { json!(TODAY) } else { Json::Null }, "heat_override": false});
    let mut k = fixture::kernel(json!({"applications": [row(1, "submitted", "DDDDDDDAPP", true), row(2, "reply", "DDSSSSSSAP", false), row(3, "reply", "DDDDDDDDAP", true), row(4, "closed", "", false), row(5, "reply", "DDDDDDDAPP", true)]}));
    let board = k.overview(0);
    assert_eq!((board["scoreboard"]["submitted"].as_u64(), board["scoreboard"]["submitted_today"].as_u64()), (Some(3), Some(3)), "{board}");
}

#[test]
fn one_posting_is_one_application_however_it_was_linked() {
    let canon = kernel::ats::canonical;
    let posting = Some("https://jobs.lever.co/acme/1234?gh_jid=9".to_string());
    for link in [
        "https://jobs.lever.co/acme/1234?gh_jid=9",
        "http://www.Jobs.Lever.co:80/acme/1234/?utm_source=x&gh_jid=9#apply",
        "HTTPS://jobs.lever.co/acme/1234?lever-source=LinkedIn&gh_jid=9&ref=feed",
    ] {
        assert_eq!(canon(link), posting, "{link}");
        assert_eq!(canon(posting.as_deref().unwrap()), posting, "canonical of canonical");
    }
    assert_eq!(canon("https://jobs.lever.co/acme/1235"), Some("https://jobs.lever.co/acme/1235".into()));
    assert_eq!(canon("https://jobs.lever.co:8443/acme/1234?source=x"), Some("https://jobs.lever.co/acme/1234".into()));
    for not_one in ["mailto:jobs@acme.com", "acme careers page", "https://localhost/x", "https://127.0.0.1/x", ""] {
        assert_eq!(canon(not_one), None, "{not_one}");
    }

    // Posting 1234 is application 4's; 5678 is predicted here. A link to either is refused, another posting is not.
    let mut k = kernel(json!({"applications": [{"id": 4, "no": 4, "stage": "gated", "company": "Acme", "canonical_url": "https://jobs.lever.co/acme/1234"}]}));
    let new = |url: &str| put("applications", 0, json!({"company": "Acme", "listing_url": url, "corporation_id": 1, "place_id": 1}));
    let fx = k.judge(&new("https://jobs.lever.co/acme/5678?utm_medium=x"), &ctx()).unwrap();
    assert_eq!(cells(&fx, "applications")["canonical_url"], "https://jobs.lever.co/acme/5678");
    k.predict(&new("https://jobs.lever.co/acme/5678?utm_medium=x"), &ctx()).unwrap();
    for dup in ["http://www.jobs.lever.co/acme/1234/#top", "http://www.jobs.lever.co/acme/5678/#top"] {
        assert_eq!(refused(k.judge(&new(dup), &ctx())).0, refusal::NATURAL_KEY, "{dup}");
    }
    assert!(k.judge(&new("https://jobs.lever.co/acme/9999"), &ctx()).is_ok());
    // A keyed put names the posting any way it was linked and is predicted onto its row, as the server puts it.
    k.predict(&keyed("applications", json!({"canonical_url": "http://www.jobs.lever.co/acme/1234/?gh_src=feed", "score_100": 77})), &ctx()).unwrap();
    let t = k.rows().table(table::APPLICATIONS).unwrap();
    assert_eq!((t.len(), t.u32(4, A::SCORE_100)), (2, Some(77)));
}

#[test]
fn an_application_names_its_company_and_place_or_is_told_which_it_means() {
    let mut k = kernel(json!({"applications": [app(1, "gated", "Acme", json!(1))]}));
    let (code, data) = refused(k.judge(&put("applications", 0, json!({"company": "ACME Inc", "location": "Germany"})), &ctx()));
    assert_eq!((code, &data["need"]), (refusal::UNLINKED, &json!(["corporation_id", "place_id"])));
    let meant = &data["did_you_mean"];
    assert_eq!((&meant[0]["table"], &meant[0]["id"], &meant[1]["table"]), (&json!("corporations"), &json!(1), &json!("places")));
    // Remote work needs no place; a company it still needs.
    assert!(k.judge(&put("applications", 0, json!({"company": "Acme", "corporation_id": 1, "work_mode": "remote"})), &ctx()).is_ok());
    // An application already short of a link may still be worked on; clearing a link may not.
    assert!(k.judge(&put("applications", 1, json!({"role": "Kernel Engineer"})), &ctx()).is_ok());
    assert_eq!(refused(k.judge(&put("applications", 1, json!({"corporation_id": null})), &ctx())).0, refusal::UNLINKED);
    // The company an application names is not dropped from under it.
    let (code, data) = refused(k.judge(&del("corporations", 1), &ctx()));
    assert_eq!((code, &data["applications"]), (refusal::UNLINKED, &json!([1])));
}
