//! Missions under fire keys, through the kernel's facade: each op judged
//! and applied as the sequencer would (`predict`), so every shot is judged
//! against what the ones before it wrote. The rules are docs/mail/kernel.md
//! and the brief's agreed rules: a key fires exactly what was reviewed (by
//! hash), one shot per mission burned when it lands, a failed shot left
//! covered, a week unused and 24 hours from first use, every actor under a
//! key, the commander's answer instead of an error.

mod fixture;

use fixture::{HOUR, NOON, TODAY, agent, cmd, del, mail, operator, put, q};
use kernel::abi::Kernel;
use schema::refusal;
use serde_json::{Value as Json, json};

/// Applications 1 and 2 at fire_ready (2's prior send unsettled), linked;
/// missions 10 (careers page, app 1), 11 (email, app 1), 12 (careers page,
/// app 2), 13 (careers page, app 1, still a draft); a live mailbox with a
/// daily cap of `cap`; every pick sending CV version 5, a file when
/// `cv_blob` is not empty.
fn kernel_with(cap: u32, cv_blob: &str) -> Kernel {
    let app = |id: u32, role: &str, notes: &str| {
        json!({"id": id, "no": id, "stage": "fire_ready", "pips": "DDDDDAPPPP", "company": "Acme", "role": role, "corporation_id": 1, "place_id": 1, "stage_notes": notes, "stage_on": TODAY, "heat_override": false})
    };
    let page = |id: u32, app: u32, target: &str, draft: &str, state: &str| json!({"id": id, "application_id": app, "kind": "careers_page", "target": target, "draft": draft, "state": state});
    fixture::kernel(json!({
        "corporations": [{"id": 1, "domain": "acme.example", "name": "Acme"}],
        "places": [{"id": 1, "kind": "country", "iso2": "DE", "name": "Germany"}],
        "applications": [app(1, "Staff Engineer", ""), app(2, "Platform Engineer", r#"{"sync": {"applied_on": "2026-10-12"}}"#)],
        "missions": [
            page(10, 1, "https://job-boards.greenhouse.io/acme/jobs/1", "## Name\nAna", "fire_ready"),
            {"id": 11, "application_id": 1, "kind": "email", "target": "jobs@acme.example", "draft": "Hello Acme,\n...", "subject": "Staff Engineer", "state": "fire_ready"},
            page(12, 2, "https://job-boards.greenhouse.io/acme/jobs/2", "## Name\nAna", "fire_ready"),
            page(13, 1, "", "", "draft"),
        ],
        // The CV every application's pick sends: the default root, a PDF upload.
        "cv_roots": [{"id": 1, "slug": "main", "name": "Main", "format": "pdf", "version_id": 5}],
        "cv_versions": [{"id": 5, "root_id": 1, "n": 1, "blob_sha": cv_blob, "actor": "operator"}],
        "me": [{"id": 1, "cv_default_root_id": 1}],
        "mailboxes": [{"id": 1, "provider": "gmail", "address": "ana@example.com", "status": "live", "daily_cap": cap}],
    }))
}

fn kernel(cap: u32) -> Kernel {
    kernel_with(cap, "5f1e9b")
}

fn fire(mission: u32, key: Option<u32>) -> Vec<u8> {
    cmd("fire", mission, key.map_or(json!({}), |k| json!({"key": k})))
}

fn landed(mission: u32) -> Vec<u8> {
    cmd("landed", mission, json!({"gmail_msgid": 1_800_000_000_000_000_001_i64, "gmail_thrid": 1_800_000_000_000_000_000_i64}))
}

/// The operator's key over `missions`, as the page makes one: the review's
/// scope and digest echoed. Answers the new key's id.
fn create(k: &mut Kernel, missions: &str, usable_by: Option<u32>, now: i64) -> u32 {
    let r = q(k, json!({"op": "fire_review", "missions": missions}));
    let ids = |k: &mut Kernel| -> Vec<u64> { q(k, json!({"op": "live_keys", "now": now, "all": true}))["keys"].as_array().unwrap().iter().map(|k| k["id"].as_u64().unwrap()).collect() };
    let before = ids(k);
    let mut params = json!({"missions": r["scope"], "digest": r["digest"]});
    if let Some(u) = usable_by {
        params["usable_by"] = json!(u);
    }
    k.predict(&cmd("create_fire_key", 0, params), &operator(now)).unwrap();
    ids(k).into_iter().find(|id| !before.contains(id)).unwrap() as u32
}

/// The commander's answer a refused shot carries.
fn answer(r: Result<kernel::rows::Moved, kernel::judge::Refusal>) -> Json {
    let r = r.expect_err("expected the commander's answer");
    assert_eq!(r.code, refusal::FIRE, "{r:?}");
    r.data
}

fn row(k: &mut Kernel, table: &str, id: u32) -> Json {
    q(k, json!({"op": "get", "table": table, "id": id}))["row"].clone()
}

#[test]
fn a_shot_needs_a_key_goes_once_and_the_commander_answers_the_rest() {
    let mut k = kernel(25);
    // Without a key no one fires, the operator included: the answer says
    // what a request for it would carry.
    for ctx in [agent(3, NOON), operator(NOON)] {
        let a = answer(k.predict(&fire(10, None), &ctx));
        assert_eq!((a["why"].as_str(), a["ask"]["missions"].as_str()), (Some("no_key"), Some("10")));
    }
    // The review holds back what cannot fire (13 is a draft, 12's prior send
    // is unsettled); the key covers exactly the rest.
    let review = q(&mut k, json!({"op": "fire_review", "missions": "10-13"}));
    assert_eq!(review["scope"], "10-11");
    let why: Vec<(u64, Json)> = review["missions"].as_array().unwrap().iter().map(|m| (m["id"].as_u64().unwrap(), m["why"].clone())).collect();
    assert_eq!(why, [(10, Json::Null), (11, Json::Null), (12, json!("unsettled")), (13, json!("not_ready"))]);
    let key = create(&mut k, "10-11", None, NOON);
    // An agent fires 10: in flight, the key's 24 hours started.
    k.predict(&fire(10, None), &agent(3, NOON + HOUR)).unwrap();
    assert_eq!(row(&mut k, "missions", 10)["state"], "in_flight");
    let live = q(&mut k, json!({"op": "live_keys", "now": NOON + HOUR}));
    assert_eq!((live["keys"][0]["in_flight"].as_str(), live["keys"][0]["expires_in"].as_str()), (Some("10"), Some("24:00:00")));
    // A second shot while it is in flight is answered, not doubled.
    assert_eq!(answer(k.predict(&fire(10, Some(key)), &agent(3, NOON + HOUR)))["why"], "in_flight");
    // It lands: fired and provisional (a careers page reports itself), the
    // shot burned, the application submitted.
    k.predict(&landed(10), &agent(3, NOON + 2 * HOUR)).unwrap();
    let m = row(&mut k, "missions", 10);
    assert_eq!((m["state"].as_str(), m["confirmation"].as_str()), (Some("fired"), Some("provisional")));
    assert_eq!(row(&mut k, "applications", 1)["stage"], "submitted");
    // Its report is owed until an outreach item names the mission.
    let due = |k: &mut Kernel| q(k, json!({"op": "missions", "application": 1}))["missions"][0]["report_due"].as_bool();
    assert_eq!(due(&mut k), Some(true));
    let report = json!({"kind": "careers_page", "direction": "outbound", "mission_id": 10, "link": "https://job-boards.greenhouse.io/acme/jobs/1", "reference": "APP-4012", "report": "Submitted the form; the page showed APP-4012."});
    k.predict(&put("outreach", 0, report), &agent(3, NOON + 2 * HOUR)).unwrap();
    assert_eq!(due(&mut k), Some(false));
    // The card carries its missions as they stand.
    let card = k.application(1).unwrap();
    let on_card: Vec<(u64, &str)> = card["missions"].as_array().unwrap().iter().map(|m| (m["id"].as_u64().unwrap(), m["state"].as_str().unwrap())).collect();
    assert_eq!(on_card, [(10, "fired"), (11, "fire_ready"), (13, "draft")]);
    // Trying it again: already done, with what is burned, what the key still
    // covers and the time it has left.
    let a = answer(k.predict(&fire(10, Some(key)), &agent(3, NOON + 3 * HOUR)));
    assert_eq!((a["why"].as_str(), a["key"].as_u64(), a["burned"].as_str(), a["remaining"].as_str()), (Some("fired"), Some(key as u64), Some("10"), Some("11")));
    assert_eq!(a["expires_in"], "22:00:00");
    // A mission the key never named is out of its scope.
    assert_eq!(answer(k.predict(&fire(12, Some(key)), &agent(3, NOON + 3 * HOUR)))["why"], "unsettled");
    k.predict(&put("applications", 2, json!({"prior_send": "not_applied"})), &operator(NOON + 3 * HOUR)).unwrap();
    assert_eq!(answer(k.predict(&fire(12, Some(key)), &agent(3, NOON + 3 * HOUR)))["why"], "out_of_scope");
    // 24 hours after its first use the key is spent, whatever it still covers.
    assert_eq!(answer(k.predict(&fire(11, None), &agent(3, NOON + HOUR + 24 * HOUR)))["why"], "expired");
}

#[test]
fn a_key_fires_exactly_what_was_reviewed() {
    let mut k = kernel(25);
    let key = create(&mut k, "10", None, NOON);
    let edit = |cells: Json| put("missions", 10, cells);
    // An agent rewrites the draft after the key was made: the key no
    // longer covers it.
    k.predict(&edit(json!({"draft": "## Name\nSomeone else"})), &agent(3, NOON)).unwrap();
    let a = answer(k.predict(&fire(10, None), &agent(3, NOON)));
    assert_eq!((a["why"].as_str(), a["changed"].as_str()), (Some("changed"), Some("10")));
    // Retargeting is the same edit.
    k.predict(&edit(json!({"draft": "## Name\nAna"})), &agent(3, NOON)).unwrap();
    k.predict(&edit(json!({"target": "https://evil.example/apply"})), &agent(3, NOON)).unwrap();
    assert_eq!(answer(k.predict(&fire(10, None), &agent(3, NOON)))["why"], "changed");
    // Put back exactly as reviewed, it fires.
    k.predict(&edit(json!({"target": "https://job-boards.greenhouse.io/acme/jobs/1"})), &agent(3, NOON)).unwrap();
    k.predict(&fire(10, Some(key)), &agent(3, NOON)).unwrap();
    // Nor does its application change the CV it carries.
    assert_eq!(k.predict(&cmd("unpin_cv", 1, json!({})), &agent(3, NOON)).expect_err("in flight").code, refusal::STAGE);
    // In flight, the mission takes no edit at all, but its note.
    assert_eq!(k.predict(&edit(json!({"draft": "## Name\nLate"})), &agent(3, NOON)).expect_err("in flight").code, refusal::STAGE);
    k.predict(&edit(json!({"note": "submitting now"})), &agent(3, NOON)).unwrap();
    // The create itself refuses a digest that is not the review's.
    let bad = cmd("create_fire_key", 0, json!({"missions": "11", "digest": "0000"}));
    assert_eq!(answer(k.predict(&bad, &operator(NOON)))["why"], "changed");
    // And only the operator creates one.
    assert_eq!(k.predict(&bad, &agent(3, NOON)).expect_err("agents never create a key").code, refusal::HUMAN_ONLY);
}

#[test]
fn a_failed_shot_stays_covered_and_a_bound_key_serves_its_own() {
    let mut k = kernel(25);
    let key = create(&mut k, "10", Some(4), NOON);
    // Bound to API key 4: another agent's shot is not its own; the
    // operator's session may use any live key.
    assert_eq!(answer(k.predict(&fire(10, None), &agent(3, NOON)))["why"], "not_yours");
    k.predict(&fire(10, None), &agent(4, NOON)).unwrap();
    // Only the key that fired reports the outcome of a careers page.
    let failed = |reason: &str| cmd("failed", 10, json!({"reason": reason}));
    assert_eq!(k.predict(&failed("form refused"), &agent(3, NOON)).expect_err("not the firing key").code, refusal::SCOPE);
    k.predict(&failed("form refused: session expired"), &agent(4, NOON)).unwrap();
    let m = row(&mut k, "missions", 10);
    assert_eq!((m["state"].as_str(), m["last_error"].as_str()), (Some("fire_ready"), Some("form refused: session expired")));
    // Still covered: it fires again under the same key, and lands.
    k.predict(&fire(10, Some(key)), &operator(NOON + HOUR)).unwrap();
    k.predict(&landed(10), &operator(NOON + HOUR)).unwrap();
    assert_eq!(q(&mut k, json!({"op": "live_keys", "now": NOON + HOUR}))["keys"][0]["burned"], "10");
    // Revoked, a key grants nothing more.
    let key2 = create(&mut k, "11", None, NOON + HOUR);
    k.predict(&cmd("revoke_fire_key", key2, json!({})), &operator(NOON + HOUR)).unwrap();
    assert_eq!(answer(k.predict(&fire(11, Some(key2)), &operator(NOON + HOUR)))["why"], "revoked");
}

#[test]
fn an_unused_key_lives_a_week() {
    let mut k = kernel(25);
    create(&mut k, "10", None, NOON);
    assert_eq!(q(&mut k, json!({"op": "live_keys", "now": NOON}))["keys"][0]["expires_in"], "168:00:00");
    assert_eq!(answer(k.predict(&fire(10, None), &agent(3, NOON + 7 * 24 * HOUR)))["why"], "expired");
    assert_eq!(q(&mut k, json!({"op": "live_keys", "now": NOON + 7 * 24 * HOUR}))["keys"], json!([]));
    k.predict(&fire(10, None), &agent(3, NOON + 7 * 24 * HOUR - 1)).unwrap();
}

#[test]
fn an_email_shot_is_the_mail_actors_to_report_under_the_daily_cap() {
    let mut k = kernel(1);
    create(&mut k, "11", None, NOON);
    k.predict(&fire(11, None), &agent(3, NOON)).unwrap();
    // The node stamps its Message-ID once, before it sends; an agent never
    // reports an email's outcome.
    let stamp = |id: &str| cmd("stamp", 11, json!({"message_id": id}));
    assert_eq!(k.predict(&stamp("hm.x1@example.com"), &agent(3, NOON)).expect_err("mail only").code, refusal::SCOPE);
    k.predict(&stamp("hm.x1@example.com"), &mail(NOON)).unwrap();
    assert_eq!(k.predict(&stamp("hm.other@example.com"), &mail(NOON)).expect_err("stamped once").code, refusal::STAGE);
    assert_eq!(k.predict(&landed(11), &agent(3, NOON)).expect_err("mail only").code, refusal::SCOPE);
    // The shot carries the CV its key covered, recorded as it was fired.
    assert_eq!(row(&mut k, "missions", 11)["cv_version_id"], 5);
    k.predict(&landed(11), &mail(NOON)).unwrap();
    // The sent mail is on the record, filed to its mission.
    let sent = q(&mut k, json!({"op": "outreach", "where": {"mission_id": 11}}));
    let item = &sent["rows"][0];
    assert_eq!((item["kind"].as_str(), item["direction"].as_str(), item["filing"].as_str()), (Some("email"), Some("outbound"), Some("filed")));
    assert_eq!((item["application_id"].as_u64(), item["email"]["message_id"].as_str()), (Some(1), Some("<hm.x1@example.com>")));
    let m = row(&mut k, "missions", 11);
    assert_eq!((m["state"].as_str(), m["message_id"].as_str(), m["confirmation"].clone()), (Some("fired"), Some("hm.x1@example.com"), Json::Null));
    assert_eq!(m["gmail_thrid"], 1_800_000_000_000_000_000_i64);
    assert_eq!(row(&mut k, "applications", 1)["stage"], "submitted");
    // The cap counts the day's email shots: a second email waits for the
    // reset, which the answer names.
    let draft = json!({"application_id": 1, "kind": "email", "target": "cto@acme.example", "subject": "Following up", "draft": "Hello again", "state": "fire_ready"});
    k.predict(&put("missions", 0, draft), &agent(3, NOON)).unwrap();
    let id = q(&mut k, json!({"op": "missions", "kind": "email", "state": "fire_ready"}))["missions"][0]["id"].as_u64().unwrap() as u32;
    create(&mut k, &id.to_string(), None, NOON);
    let a = answer(k.predict(&fire(id, None), &agent(3, NOON)));
    assert_eq!((a["why"].as_str(), a["used"].as_u64(), a["resets_at"].as_str()), (Some("cap"), Some(1), Some(kernel::time_iso(NOON - 43_200 + 86_400).as_str())));
    assert_eq!(q(&mut k, json!({"op": "mail_quota", "now": NOON})), json!({"cap": 1, "used": 1, "left": 0, "resets_at": kernel::time_iso(NOON + 43_200)}));
    k.predict(&fire(id, None), &agent(3, NOON + 43_200)).unwrap();
    // The node lands a mail only once it has stamped its Message-ID.
    let r = k.predict(&landed(id), &mail(NOON + 43_200)).expect_err("unstamped");
    assert_eq!((r.code, r.data["rule"].as_str()), (refusal::STAGE, Some("unstamped")));
}

#[test]
fn requests_are_stamped_and_only_the_operator_answers_them() {
    let mut k = kernel(25);
    k.predict(&put("fire_requests", 0, json!({"missions": " 11, 10 ", "reason": "Acme: both routes drafted"})), &agent(7, NOON)).unwrap();
    let req = &q(&mut k, json!({"op": "find", "table": "fire_requests"}))["rows"][0];
    assert_eq!((req["missions"].as_str(), req["requested_by"].as_u64(), req["status"].as_str()), (Some("10-11"), Some(7), Some("open")));
    let id = req["id"].as_u64().unwrap() as u32;
    // Another agent cannot rewrite it; a reason past 280 characters is refused.
    assert_eq!(k.predict(&put("fire_requests", id, json!({"missions": "1-100"})), &agent(8, NOON)).expect_err("not its request").code, refusal::SCOPE);
    let long = put("fire_requests", 0, json!({"missions": "10", "reason": "x".repeat(281)}));
    assert_eq!(k.predict(&long, &agent(7, NOON)).expect_err("too long").code, refusal::TOO_LARGE);
    assert_eq!(k.predict(&cmd("decline", id, json!({})), &agent(7, NOON)).expect_err("operator only").code, refusal::HUMAN_ONLY);
    // Granted from the review, the key is bound to the key that asked.
    let review = q(&mut k, json!({"op": "fire_review", "request": id}));
    assert_eq!(review["request"]["reason"], "Acme: both routes drafted");
    k.predict(&cmd("create_fire_key", 0, json!({"missions": review["scope"], "digest": review["digest"], "request": id})), &operator(NOON)).unwrap();
    let keys = q(&mut k, json!({"op": "live_keys", "now": NOON}));
    assert_eq!((keys["keys"][0]["usable_by"].as_u64(), keys["keys"][0]["request_id"].as_u64()), (Some(7), Some(id as u64)));
    assert_eq!(row(&mut k, "fire_requests", id)["status"], "granted");
    assert_eq!(answer(k.predict(&fire(10, None), &agent(8, NOON)))["why"], "not_yours");
    k.predict(&fire(10, None), &agent(7, NOON)).unwrap();
}

#[test]
fn the_record_stays() {
    let mut k = kernel(25);
    let key = create(&mut k, "10", None, NOON);
    // No one drops a key or its shots: a key is revoked.
    for ctx in [agent(3, NOON), operator(NOON)] {
        assert_eq!(k.predict(&del("fire_keys", key), &ctx).expect_err("kept").code, refusal::SCOPE);
    }
    // A put cannot move a mission past fire_ready; a fired one is not dropped.
    assert_eq!(k.predict(&put("missions", 10, json!({"state": "fired"})), &operator(NOON)).expect_err("by command only").code, refusal::STAGE);
    k.predict(&fire(10, None), &agent(3, NOON)).unwrap();
    k.predict(&landed(10), &agent(3, NOON)).unwrap();
    assert_eq!(k.predict(&del("missions", 10), &operator(NOON)).expect_err("fired").code, refusal::STAGE);
    // An email mission's To is read as the outreach type reads it and kept
    // bare (what the hash covers is what goes out); a non-address is refused.
    k.predict(&put("missions", 11, json!({"target": "Acme Jobs <Jobs@ACME.example>, cto@acme.example"})), &agent(3, NOON)).unwrap();
    assert_eq!(row(&mut k, "missions", 11)["target"], "Jobs@acme.example, cto@acme.example");
    assert_eq!(k.predict(&put("missions", 11, json!({"target": "the hiring team"})), &agent(3, NOON)).expect_err("not an address list").code, refusal::TYPE);
    // A mission is any outreach kind but a note.
    assert_eq!(k.predict(&put("missions", 13, json!({"kind": "note"})), &agent(3, NOON)).expect_err("never a note").code, refusal::TYPE);
    // The mailbox is the mail actor's (its address) and the operator's (its cap).
    assert_eq!(k.predict(&put("mailboxes", 1, json!({"address": "other@example.com"})), &operator(NOON)).expect_err("mail only").code, refusal::SCOPE);
    assert_eq!(k.predict(&put("mailboxes", 1, json!({"daily_cap": 500})), &agent(3, NOON)).expect_err("operator only").code, refusal::SCOPE);
}

#[test]
fn a_first_email_goes_with_the_cv_as_a_file() {
    // The pick's version is markdown (no file): a first-contact email is held.
    let mut k = kernel_with(25, "");
    let review = q(&mut k, json!({"op": "fire_review", "missions": "11"}));
    assert_eq!((review["missions"][0]["why"].as_str(), review["scope"].as_str()), (Some("cv_file"), Some("")));
    assert_eq!(answer(k.predict(&fire(11, None), &operator(NOON)))["why"], "cv_file");
    // Staging another one is refused at fire_ready.
    let draft = |reply: Option<&str>| {
        let mut cells = json!({"application_id": 1, "kind": "email", "target": "cto@acme.example", "subject": "Re: Staff Engineer", "draft": "Thanks, Tuesday works.", "state": "fire_ready"});
        if let Some(r) = reply {
            cells["in_reply_to"] = json!(r);
        }
        put("missions", 0, cells)
    };
    let r = k.predict(&draft(None), &agent(3, NOON)).expect_err("no CV file");
    assert_eq!((r.code, r.data["rule"].as_str()), (refusal::STAGE, Some("cv_file")));
    // An In-Reply-To naming no mail the account holds makes no reply.
    let r = k.predict(&draft(Some("<abc.123@mail.acme.example>")), &agent(3, NOON)).expect_err("a junk reply is a first contact");
    assert_eq!(r.data["rule"], "cv_file");
    // A reply to a mail the account holds needs none, fires, and carries no CV.
    let inbound = json!({"kind": "email", "direction": "inbound", "from_addr": "cto@acme.example", "subject": "Staff Engineer", "message_id": "<abc.123@mail.acme.example>", "body": "Are you free Tuesday?"});
    k.predict(&put("outreach", 0, inbound), &mail(NOON)).unwrap();
    k.predict(&draft(Some("<abc.123@mail.acme.example>")), &agent(3, NOON)).unwrap();
    let id = q(&mut k, json!({"op": "missions", "kind": "email", "state": "fire_ready"}))["missions"].as_array().unwrap().iter().map(|m| m["id"].as_u64().unwrap()).find(|&id| id != 11).unwrap() as u32;
    create(&mut k, &id.to_string(), None, NOON);
    k.predict(&fire(id, None), &agent(3, NOON)).unwrap();
    assert_eq!(row(&mut k, "missions", id)["cv_version_id"], Json::Null);
    // And the application it fires for stays while the shot is in flight.
    let r = k.predict(&del("applications", 1), &operator(NOON)).expect_err("in flight");
    assert_eq!((r.code, r.data["rule"].as_str()), (refusal::STAGE, Some("record")));
}

#[test]
fn an_email_goes_to_ten_recipients_at_most() {
    let mut k = kernel(25);
    let list = |n: usize, at: &str| (0..n).map(|i| format!("p{i}@{at}")).collect::<Vec<_>>().join(", ");
    k.predict(&put("missions", 11, json!({"target": list(6, "acme.example")})), &agent(3, NOON)).unwrap();
    assert_eq!(k.predict(&put("missions", 11, json!({"cc": list(5, "initech.example")})), &agent(3, NOON)).expect_err("eleven recipients").code, refusal::TYPE);
    k.predict(&put("missions", 11, json!({"cc": list(4, "initech.example")})), &agent(3, NOON)).unwrap();
    assert_eq!(q(&mut k, json!({"op": "fire_review", "missions": "11"}))["missions"][0]["eligible"], true);
}

/// A session's word on the mailbox (live, an error, a sync) arrives late after the operator's
/// unlink: it must not revive the mailbox, whose erase waits on the unlinked status. Only a new link moves it.
#[test]
fn an_unlinked_mailbox_takes_no_state_but_linking() {
    let mut k = fixture::kernel(json!({"mailboxes": [{"id": 1, "provider": "gmail", "address": "ana@example.com", "status": "unlinked", "daily_cap": 20}]}));
    for status in ["live", "error", "auth_failed"] {
        assert_eq!(k.predict(&cmd("mailbox_state", 1, json!({"status": status})), &mail(NOON)).expect_err(status).code, refusal::UNLINKED);
    }
    k.predict(&cmd("mailbox_state", 1, json!({"status": "linking"})), &mail(NOON)).expect("a new link moves it");
}
