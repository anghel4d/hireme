//! Missions under fire keys, through the kernel's facade: each op judged
//! and applied as the sequencer would (`predict`), so every shot is judged
//! against what the ones before it wrote. The rules are docs/mail/kernel.md
//! and the brief's agreed rules: a key fires exactly what was reviewed (by
//! hash), one shot per mission burned when it lands, a failed shot left
//! covered, a week unused and 24 hours from first use, every actor under a
//! key, the commander's answer instead of an error.

use kernel::abi::Kernel;
use kernel::judge::Ctx;
use schema::col::{applications as A, missions as M};
use schema::{col, command, enums, param, refusal, table};
use serde_json::{json, Value as Json};

const TODAY: i32 = 739_528;
const NOON: i64 = (TODAY - kernel::UNIX_EPOCH_DAY) as i64 * 86_400 + 43_200;
const HOUR: i64 = 3_600;

fn operator(now: i64) -> Ctx<'static> {
    Ctx { today: TODAY, now, human: true, key_id: None, held: &[] }
}

fn agent(key: u32, now: i64) -> Ctx<'static> {
    Ctx { today: TODAY, now, human: false, key_id: Some(key), held: &[] }
}

fn mail(now: i64) -> Ctx<'static> {
    Ctx { today: TODAY, now, human: false, key_id: None, held: &[] }
}

/// Applications 1 and 2 at fire_ready (2's prior send unsettled), linked;
/// missions 10 (careers page, app 1), 11 (email, app 1), 12 (careers page,
/// app 2), 13 (careers page, app 1, still a draft); a live mailbox with a
/// daily cap of `cap`; every pick sending CV version 5, a file when
/// `cv_blob` is not empty.
fn kernel(cap: u32) -> Kernel {
    kernel_with(cap, "5f1e9b")
}

fn kernel_with(cap: u32, cv_blob: &str) -> Kernel {
    let mut w = wire::BodyWriter::new();
    let none = wire::NONE;
    let mut b = w.block(table::CORPORATIONS, 1);
    b.u32s(col::corporations::ID, [1].into_iter()).strs(col::corporations::DOMAIN, ["acme.example"].into_iter()).strs(col::corporations::NAME, ["Acme"].into_iter());
    b.done();
    let mut b = w.block(table::PLACES, 1);
    b.u32s(col::places::ID, [1].into_iter())
        .u32s(col::places::KIND, [enums::place_kind::COUNTRY as u32].into_iter())
        .strs(col::places::ISO2, ["DE"].into_iter())
        .strs(col::places::NAME, ["Germany"].into_iter());
    b.done();
    let fire_ready = enums::stage::FIRE_READY as u32;
    let mut b = w.block(table::APPLICATIONS, 2);
    b.u32s(A::ID, [1, 2].into_iter())
        .u32s(A::NO, [1, 2].into_iter())
        .u32s(A::STAGE, [fire_ready, fire_ready].into_iter())
        .strs(A::PIPS, ["DDDDDAPPPP", "DDDDDAPPPP"].into_iter())
        .strs(A::COMPANY, ["Acme", "Acme"].into_iter())
        .strs(A::ROLE, ["Staff Engineer", "Platform Engineer"].into_iter())
        .u32s(A::BATCH_ID, [none, none].into_iter())
        .u32s(A::CORPORATION_ID, [1, 1].into_iter())
        .u32s(A::PLACE_ID, [1, 1].into_iter())
        .strs(A::STAGE_NOTES, ["", r#"{"sync": {"applied_on": "2026-10-12"}}"#].into_iter())
        .u32s(A::STAGE_ON, [TODAY as u32, TODAY as u32].into_iter())
        .u32s(A::HEAT_OVERRIDE, [0, 0].into_iter());
    b.done();
    let k = |k: u8| k as u32;
    let s = |s: u8| s as u32;
    use enums::{mission_kind as K, mission_state as St};
    let mut b = w.block(table::MISSIONS, 4);
    b.u32s(M::ID, [10, 11, 12, 13].into_iter())
        .u32s(M::APPLICATION_ID, [1, 1, 2, 1].into_iter())
        .u32s(M::KIND, [k(K::CAREERS_PAGE), k(K::EMAIL), k(K::CAREERS_PAGE), k(K::CAREERS_PAGE)].into_iter())
        .strs(M::TARGET, ["https://job-boards.greenhouse.io/acme/jobs/1", "jobs@acme.example", "https://job-boards.greenhouse.io/acme/jobs/2", ""].into_iter())
        .strs(M::DRAFT, ["## Name\nAna", "Hello Acme,\n...", "## Name\nAna", ""].into_iter())
        .strs(M::SUBJECT, ["", "Staff Engineer", "", ""].into_iter())
        .u32s(M::STATE, [s(St::FIRE_READY), s(St::FIRE_READY), s(St::FIRE_READY), s(St::DRAFT)].into_iter());
    b.done();
    // The CV every application's pick sends: the default root, a PDF upload.
    let mut b = w.block(table::CV_ROOTS, 1);
    b.u32s(col::cv_roots::ID, [1].into_iter())
        .strs(col::cv_roots::SLUG, ["main"].into_iter())
        .strs(col::cv_roots::NAME, ["Main"].into_iter())
        .u32s(col::cv_roots::FORMAT, [enums::cv_format::PDF as u32].into_iter())
        .u32s(col::cv_roots::VERSION_ID, [5].into_iter());
    b.done();
    let mut b = w.block(table::CV_VERSIONS, 1);
    b.u32s(col::cv_versions::ID, [5].into_iter())
        .u32s(col::cv_versions::ROOT_ID, [1].into_iter())
        .u32s(col::cv_versions::N, [1].into_iter())
        .strs(col::cv_versions::BLOB_SHA, [cv_blob].into_iter())
        .u32s(col::cv_versions::ACTOR, [enums::actor::OPERATOR as u32].into_iter());
    b.done();
    let mut b = w.block(table::ME, 1);
    b.u32s(col::me::ID, [1].into_iter()).u32s(col::me::CV_DEFAULT_ROOT_ID, [1].into_iter());
    b.done();
    let mut b = w.block(table::MAILBOXES, 1);
    b.u32s(col::mailboxes::ID, [1].into_iter())
        .u32s(col::mailboxes::PROVIDER, [enums::mail_provider::GMAIL as u32].into_iter())
        .strs(col::mailboxes::ADDRESS, ["ana@example.com"].into_iter())
        .u32s(col::mailboxes::STATUS, [enums::mailbox_status::LIVE as u32].into_iter())
        .u32s(col::mailboxes::DAILY_CAP, [cap].into_iter());
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.set_grants(kernel::query::Grants { human: true, read_mask: 0b1111, write_mask: 0b1111, may_delete: true });
    k.boot(&w.finish(), 1).unwrap();
    k
}

static OP: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(100);

fn op(verb: u8, table: u16, target: u32, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    let id = OP.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(id, verb, 0, table, target, None);
    cells(&mut o);
    o.done();
    w.finish()[8..].to_vec()
}

fn fire(mission: u32, key: Option<u32>) -> Vec<u8> {
    op(wire::COMMAND, command::FIRE, mission, |o| {
        if let Some(k) = key {
            o.u32(param::fire::KEY, k);
        }
    })
}

fn landed(mission: u32) -> Vec<u8> {
    op(wire::COMMAND, command::LANDED, mission, |o| {
        o.i64(param::landed::GMAIL_MSGID, 1_800_000_000_000_000_001).i64(param::landed::GMAIL_THRID, 1_800_000_000_000_000_000);
    })
}

fn failed(mission: u32, reason: &str) -> Vec<u8> {
    op(wire::COMMAND, command::FAILED, mission, |o| {
        o.str(param::failed::REASON, reason);
    })
}

fn q(k: &mut Kernel, req: Json) -> Json {
    k.query(&req).unwrap()
}

/// The operator's key over `missions`, as the page makes one: the review's
/// scope and digest echoed. Answers the new key's id.
fn create(k: &mut Kernel, missions: &str, usable_by: Option<u32>, now: i64) -> u32 {
    let r = q(k, json!({"op": "fire_review", "missions": missions}));
    let (scope, digest) = (r["scope"].as_str().unwrap().to_string(), r["digest"].as_str().unwrap().to_string());
    let before: Vec<u64> = q(k, json!({"op": "live_keys", "now": now, "all": true}))["keys"].as_array().unwrap().iter().map(|k| k["id"].as_u64().unwrap()).collect();
    let o = op(wire::COMMAND, command::CREATE_FIRE_KEY, 0, |o| {
        o.str(param::create_fire_key::MISSIONS, &scope).str(param::create_fire_key::DIGEST, &digest);
        if let Some(u) = usable_by {
            o.u32(param::create_fire_key::USABLE_BY, u);
        }
    });
    k.predict(&o, &operator(now)).unwrap();
    let keys = q(k, json!({"op": "live_keys", "now": now, "all": true}));
    keys["keys"].as_array().unwrap().iter().map(|k| k["id"].as_u64().unwrap()).find(|id| !before.contains(id)).unwrap() as u32
}

/// The commander's answer a refused shot carries.
fn answer(r: Result<kernel::rows::Moved, kernel::judge::Refusal>) -> Json {
    let r = r.expect_err("expected the commander's answer");
    assert_eq!(r.code, refusal::FIRE, "{r:?}");
    r.data
}

fn mission(k: &mut Kernel, id: u32) -> Json {
    q(k, json!({"op": "get", "table": "missions", "id": id}))["row"].clone()
}

fn stage(k: &mut Kernel, app: u32) -> Json {
    q(k, json!({"op": "get", "table": "applications", "id": app}))["row"]["stage"].clone()
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
    assert_eq!(mission(&mut k, 10)["state"], "in_flight");
    let live = q(&mut k, json!({"op": "live_keys", "now": NOON + HOUR}));
    assert_eq!(live["keys"][0]["in_flight"], "10");
    assert_eq!(live["keys"][0]["expires_in"], "24:00:00");
    // A second shot while it is in flight is answered, not doubled.
    assert_eq!(answer(k.predict(&fire(10, Some(key)), &agent(3, NOON + HOUR)))["why"], "in_flight");
    // It lands: fired and provisional (a careers page reports itself), the
    // shot burned, the application submitted.
    k.predict(&landed(10), &agent(3, NOON + 2 * HOUR)).unwrap();
    let m = mission(&mut k, 10);
    assert_eq!((m["state"].as_str(), m["confirmation"].as_str()), (Some("fired"), Some("provisional")));
    assert_eq!(stage(&mut k, 1), "submitted");
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
    let settle = op(wire::PUT, table::APPLICATIONS, 2, |o| {
        o.u32(A::PRIOR_SEND, enums::prior_send::NOT_APPLIED as u32);
    });
    k.predict(&settle, &operator(NOON + 3 * HOUR)).unwrap();
    assert_eq!(answer(k.predict(&fire(12, Some(key)), &agent(3, NOON + 3 * HOUR)))["why"], "out_of_scope");
    // 24 hours after its first use the key is spent, whatever it still covers.
    assert_eq!(answer(k.predict(&fire(11, None), &agent(3, NOON + HOUR + 24 * HOUR)))["why"], "expired");
}

#[test]
fn a_key_fires_exactly_what_was_reviewed() {
    let mut k = kernel(25);
    let key = create(&mut k, "10", None, NOON);
    // An agent rewrites the draft after the key was made: the key no
    // longer covers it.
    let edit = |text: &str| {
        let text = text.to_string();
        op(wire::PUT, table::MISSIONS, 10, move |o| {
            o.str(M::DRAFT, &text);
        })
    };
    k.predict(&edit("## Name\nSomeone else"), &agent(3, NOON)).unwrap();
    let a = answer(k.predict(&fire(10, None), &agent(3, NOON)));
    assert_eq!((a["why"].as_str(), a["changed"].as_str()), (Some("changed"), Some("10")));
    // Retargeting is the same edit.
    k.predict(&edit("## Name\nAna"), &agent(3, NOON)).unwrap();
    k.predict(&op(wire::PUT, table::MISSIONS, 10, |o| {
        o.str(M::TARGET, "https://evil.example/apply");
    }), &agent(3, NOON))
    .unwrap();
    assert_eq!(answer(k.predict(&fire(10, None), &agent(3, NOON)))["why"], "changed");
    // Put back exactly as reviewed, it fires.
    k.predict(&op(wire::PUT, table::MISSIONS, 10, |o| {
        o.str(M::TARGET, "https://job-boards.greenhouse.io/acme/jobs/1");
    }), &agent(3, NOON))
    .unwrap();
    k.predict(&fire(10, Some(key)), &agent(3, NOON)).unwrap();
    // In flight, the mission takes no edit at all, but its note.
    let r = k.predict(&edit("## Name\nLate"), &agent(3, NOON)).expect_err("in flight");
    assert_eq!(r.code, refusal::STAGE);
    k.predict(&op(wire::PUT, table::MISSIONS, 10, |o| {
        o.str(M::NOTE, "submitting now");
    }), &agent(3, NOON))
    .unwrap();
    // The create itself refuses a digest that is not the review's.
    let bad = op(wire::COMMAND, command::CREATE_FIRE_KEY, 0, |o| {
        o.str(param::create_fire_key::MISSIONS, "11").str(param::create_fire_key::DIGEST, "0000");
    });
    assert_eq!(answer(k.predict(&bad, &operator(NOON)))["why"], "changed");
    // And only the operator creates one.
    let r = k.predict(&bad, &agent(3, NOON)).expect_err("agents never create a key");
    assert_eq!(r.code, refusal::HUMAN_ONLY);
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
    assert_eq!(k.predict(&failed(10, "form refused"), &agent(3, NOON)).expect_err("not the firing key").code, refusal::SCOPE);
    k.predict(&failed(10, "form refused: session expired"), &agent(4, NOON)).unwrap();
    let m = mission(&mut k, 10);
    assert_eq!((m["state"].as_str(), m["last_error"].as_str()), (Some("fire_ready"), Some("form refused: session expired")));
    // Still covered: it fires again under the same key, and lands.
    k.predict(&fire(10, Some(key)), &operator(NOON + HOUR)).unwrap();
    k.predict(&landed(10), &operator(NOON + HOUR)).unwrap();
    assert_eq!(q(&mut k, json!({"op": "live_keys", "now": NOON + HOUR}))["keys"][0]["burned"], "10");
    // Revoked, a key grants nothing more.
    let key2 = create(&mut k, "11", None, NOON + HOUR);
    k.predict(&op(wire::COMMAND, command::REVOKE_FIRE_KEY, key2, |_| {}), &operator(NOON + HOUR)).unwrap();
    assert_eq!(answer(k.predict(&fire(11, Some(key2)), &operator(NOON + HOUR)))["why"], "revoked");
}

#[test]
fn an_unused_key_lives_a_week() {
    let mut k = kernel(25);
    create(&mut k, "10", None, NOON);
    let live = q(&mut k, json!({"op": "live_keys", "now": NOON}));
    assert_eq!(live["keys"][0]["expires_in"], "168:00:00");
    assert_eq!(answer(k.predict(&fire(10, None), &agent(3, NOON + 7 * 24 * HOUR)))["why"], "expired");
    assert!(q(&mut k, json!({"op": "live_keys", "now": NOON + 7 * 24 * HOUR}))["keys"].as_array().unwrap().is_empty());
    k.predict(&fire(10, None), &agent(3, NOON + 7 * 24 * HOUR - 1)).unwrap();
}

#[test]
fn an_email_shot_is_the_mail_actors_to_report_under_the_daily_cap() {
    let mut k = kernel(1);
    create(&mut k, "11", None, NOON);
    k.predict(&fire(11, None), &agent(3, NOON)).unwrap();
    // The node stamps its Message-ID once, before it sends; an agent never
    // reports an email's outcome.
    let stamp = |id: &str| {
        let id = id.to_string();
        op(wire::COMMAND, command::STAMP, 11, move |o| {
            o.str(param::stamp::MESSAGE_ID, &id);
        })
    };
    assert_eq!(k.predict(&stamp("hm.x1@example.com"), &agent(3, NOON)).expect_err("mail only").code, refusal::SCOPE);
    k.predict(&stamp("hm.x1@example.com"), &mail(NOON)).unwrap();
    assert_eq!(k.predict(&stamp("hm.other@example.com"), &mail(NOON)).expect_err("stamped once").code, refusal::STAGE);
    assert_eq!(k.predict(&landed(11), &agent(3, NOON)).expect_err("mail only").code, refusal::SCOPE);
    k.predict(&landed(11), &mail(NOON)).unwrap();
    let m = mission(&mut k, 11);
    assert_eq!((m["state"].as_str(), m["message_id"].as_str(), m["confirmation"].clone()), (Some("fired"), Some("hm.x1@example.com"), Json::Null));
    assert_eq!(m["gmail_thrid"], 1_800_000_000_000_000_000_i64);
    assert_eq!(stage(&mut k, 1), "submitted");
    // The cap counts the day's email shots: a second email waits for the
    // reset, which the answer names.
    let draft = op(wire::PUT, table::MISSIONS, 0, |o| {
        o.u32(M::APPLICATION_ID, 1)
            .u32(M::KIND, enums::mission_kind::EMAIL as u32)
            .str(M::TARGET, "cto@acme.example")
            .str(M::SUBJECT, "Following up")
            .str(M::DRAFT, "Hello again")
            .u32(M::STATE, enums::mission_state::FIRE_READY as u32);
    });
    k.predict(&draft, &agent(3, NOON)).unwrap();
    let id = q(&mut k, json!({"op": "missions", "kind": "email", "state": "fire_ready"}))["missions"][0]["id"].as_u64().unwrap() as u32;
    create(&mut k, &id.to_string(), None, NOON);
    let a = answer(k.predict(&fire(id, None), &agent(3, NOON)));
    assert_eq!((a["why"].as_str(), a["used"].as_u64(), a["resets_at"].as_str()), (Some("cap"), Some(1), Some(kernel::time_iso(NOON - 43_200 + 86_400).as_str())));
    assert_eq!(q(&mut k, json!({"op": "mail_quota", "now": NOON})), json!({"cap": 1, "used": 1, "left": 0, "resets_at": kernel::time_iso(NOON + 43_200)}));
    k.predict(&fire(id, None), &agent(3, NOON + 43_200)).unwrap();
}

#[test]
fn requests_are_stamped_and_only_the_operator_answers_them() {
    let mut k = kernel(25);
    let ask = op(wire::PUT, table::FIRE_REQUESTS, 0, |o| {
        o.str(col::fire_requests::MISSIONS, " 11, 10 ").str(col::fire_requests::REASON, "Acme: both routes drafted");
    });
    k.predict(&ask, &agent(7, NOON)).unwrap();
    let rows = q(&mut k, json!({"op": "find", "table": "fire_requests"}));
    let req = &rows["rows"][0];
    assert_eq!((req["missions"].as_str(), req["requested_by"].as_u64(), req["status"].as_str()), (Some("10-11"), Some(7), Some("open")));
    let id = req["id"].as_u64().unwrap() as u32;
    // Another agent cannot rewrite it; a reason past 280 characters is refused.
    let r = k.predict(&op(wire::PUT, table::FIRE_REQUESTS, id, |o| {
        o.str(col::fire_requests::MISSIONS, "1-100");
    }), &agent(8, NOON));
    assert_eq!(r.expect_err("not its request").code, refusal::SCOPE);
    let long = "x".repeat(281);
    let r = k.predict(&op(wire::PUT, table::FIRE_REQUESTS, 0, |o| {
        o.str(col::fire_requests::MISSIONS, "10").str(col::fire_requests::REASON, &long);
    }), &agent(7, NOON));
    assert_eq!(r.expect_err("too long").code, refusal::TOO_LARGE);
    assert_eq!(k.predict(&op(wire::COMMAND, command::DECLINE, id, |_| {}), &agent(7, NOON)).expect_err("operator only").code, refusal::HUMAN_ONLY);
    // Granted from the review, the key is bound to the key that asked.
    let review = q(&mut k, json!({"op": "fire_review", "request": id}));
    assert_eq!(review["request"]["reason"], "Acme: both routes drafted");
    let o = op(wire::COMMAND, command::CREATE_FIRE_KEY, 0, |o| {
        o.str(param::create_fire_key::MISSIONS, review["scope"].as_str().unwrap())
            .str(param::create_fire_key::DIGEST, review["digest"].as_str().unwrap())
            .u32(param::create_fire_key::REQUEST, id);
    });
    k.predict(&o, &operator(NOON)).unwrap();
    let keys = q(&mut k, json!({"op": "live_keys", "now": NOON}));
    assert_eq!((keys["keys"][0]["usable_by"].as_u64(), keys["keys"][0]["request_id"].as_u64()), (Some(7), Some(id as u64)));
    assert_eq!(q(&mut k, json!({"op": "get", "table": "fire_requests", "id": id}))["row"]["status"], "granted");
    assert_eq!(answer(k.predict(&fire(10, None), &agent(8, NOON)))["why"], "not_yours");
    k.predict(&fire(10, None), &agent(7, NOON)).unwrap();
}

#[test]
fn the_record_stays() {
    let mut k = kernel(25);
    let key = create(&mut k, "10", None, NOON);
    // No one drops a key or its shots: a key is revoked.
    for ctx in [agent(3, NOON), operator(NOON)] {
        let r = k.predict(&op(wire::DROP, table::FIRE_KEYS, key, |_| {}), &ctx).expect_err("kept");
        assert_eq!(r.code, refusal::SCOPE);
    }
    // A put cannot move a mission past fire_ready; a fired one is not dropped.
    let r = k.predict(&op(wire::PUT, table::MISSIONS, 10, |o| {
        o.u32(M::STATE, enums::mission_state::FIRED as u32);
    }), &operator(NOON));
    assert_eq!(r.expect_err("by command only").code, refusal::STAGE);
    k.predict(&fire(10, None), &agent(3, NOON)).unwrap();
    k.predict(&landed(10), &agent(3, NOON)).unwrap();
    assert_eq!(k.predict(&op(wire::DROP, table::MISSIONS, 10, |_| {}), &operator(NOON)).expect_err("fired").code, refusal::STAGE);
    // An email mission's To is bare addresses, ten at most.
    let r = k.predict(&op(wire::PUT, table::MISSIONS, 11, |o| {
        o.str(M::TARGET, "Acme Jobs <jobs@acme.example>");
    }), &agent(3, NOON));
    assert_eq!(r.expect_err("not an address list").code, refusal::TYPE);
    // The mailbox is the mail actor's (its address) and the operator's (its cap).
    let r = k.predict(&op(wire::PUT, table::MAILBOXES, 1, |o| {
        o.str(col::mailboxes::ADDRESS, "other@example.com");
    }), &operator(NOON));
    assert_eq!(r.expect_err("mail only").code, refusal::SCOPE);
    let r = k.predict(&op(wire::PUT, table::MAILBOXES, 1, |o| {
        o.u32(col::mailboxes::DAILY_CAP, 500);
    }), &agent(3, NOON));
    assert_eq!(r.expect_err("operator only").code, refusal::SCOPE);
}

#[test]
fn a_first_email_goes_with_the_cv_as_a_file() {
    // The pick's version is markdown (no file): a first-contact email is held.
    let mut k = kernel_with(25, "");
    let review = q(&mut k, json!({"op": "fire_review", "missions": "11"}));
    assert_eq!((review["missions"][0]["why"].as_str(), review["scope"].as_str()), (Some("cv_file"), Some("")));
    assert_eq!(answer(k.predict(&fire(11, None), &operator(NOON)))["why"], "cv_file");
    // Staging another one is refused at fire_ready.
    let draft = |reply: &str| {
        let reply = reply.to_string();
        op(wire::PUT, table::MISSIONS, 0, move |o| {
            o.u32(M::APPLICATION_ID, 1)
                .u32(M::KIND, enums::mission_kind::EMAIL as u32)
                .str(M::TARGET, "cto@acme.example")
                .str(M::SUBJECT, "Re: Staff Engineer")
                .str(M::DRAFT, "Thanks, Tuesday works.")
                .u32(M::STATE, enums::mission_state::FIRE_READY as u32);
            if !reply.is_empty() {
                o.str(M::IN_REPLY_TO, &reply);
            }
        })
    };
    let r = k.predict(&draft(""), &agent(3, NOON)).expect_err("no CV file");
    assert_eq!((r.code, r.data["rule"].as_str()), (refusal::STAGE, Some("cv_file")));
    // A reply inside a thread needs none, and fires.
    k.predict(&draft("abc.123@mail.acme.example"), &agent(3, NOON)).unwrap();
    let id = q(&mut k, json!({"op": "missions", "kind": "email", "state": "fire_ready"}))["missions"].as_array().unwrap().iter().map(|m| m["id"].as_u64().unwrap()).find(|&id| id != 11).unwrap();
    create(&mut k, &id.to_string(), None, NOON);
    k.predict(&fire(id as u32, None), &agent(3, NOON)).unwrap();
}
