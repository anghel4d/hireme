//! The OutreachItem through the facade: what each kind requires and
//! derives on a put, what is fixed once written, how an inbound item is
//! filed, the sent record, the commands, and the hub's query
//! (docs/mail/outreach_type.md).

mod fixture;

use fixture::{DAWN, HOUR, agent, body, cells, cmd, mail, operator, refused};
use kernel::abi::{self, Kernel};
use kernel::judge::{Ctx, Refusal, Row};
use kernel::outreach::{self, Body, Filing, Item, Kind, Shot, Status};
use kernel::query::Grants;
use schema::{enums, refusal, table};
use serde_json::{Value as Json, json};

const NOW: i64 = DAWN + HOUR;

/// Acme (corporation 1) with application 10 (Dana, contact 5) and mission
/// 20 (an email mission of application 10); Zed (2) with application 11.
fn kernel() -> Kernel {
    fixture::kernel(json!({
        "corporations": [{"id": 1, "domain": "acme.example", "name": "Acme"}, {"id": 2, "domain": "zed.example", "name": "Zed"}],
        "applications": [
            {"id": 10, "no": 10, "corporation_id": 1, "company": "Acme", "role": "Staff Engineer", "stage": "fire_ready", "heat_override": false},
            {"id": 11, "no": 11, "corporation_id": 2, "company": "Zed", "role": "Platform Engineer", "stage": "gated", "heat_override": false},
        ],
        "contacts": [{"id": 5, "corporation_id": 1, "name": "Dana Reyes", "email": "dana@acme.example"}],
        "missions": [{"id": 20, "application_id": 10, "kind": "email", "target": "jobs@acme.example", "state": "fire_ready"}],
    }))
}

fn put(target: u32, cells: Json) -> Vec<u8> {
    fixture::put("outreach", target, cells)
}

/// The outreach item's effects by column name.
fn item(rows: &[Row]) -> Json {
    cells(rows, "outreach")
}

/// Judges the op and, when it passes, lands its effects as the sequencer would: id `id` for an insert.
fn land(k: &mut Kernel, op: &[u8], ctx: &Ctx, id: u32) -> Result<Vec<Row>, Refusal> {
    let rows = k.judge(op, ctx)?;
    let mut patch = Vec::new();
    for r in abi::effects_json(&rows).as_array().unwrap() {
        let mut row = r["cells"].clone();
        row["id"] = if r["id"] == 0 { json!(id) } else { r["id"].clone() };
        patch.extend(body(&Json::Object([(r["table"].as_str().unwrap().to_string(), json!([row]))].into_iter().collect())));
    }
    k.patch(&patch, 2).unwrap();
    Ok(rows)
}

/// A mail from someone the filer cannot place: it goes to the tray.
fn inbound_mail(id: &str, in_reply_to: Option<&str>) -> Vec<u8> {
    let mut cells = json!({"kind": "email", "direction": "inbound", "from_addr": "Someone <someone@nowhere.example>", "to_addr": "matei3d@gmail.com", "subject": "Hello", "body": "Just saying hi.", "message_id": id, "pipe": "gmail"});
    if let Some(r) = in_reply_to {
        cells["in_reply_to"] = json!(r);
        cells["refs"] = json!(r);
    }
    put(0, cells)
}

#[test]
fn an_inbound_mail_is_received_from_the_mail_actor_and_goes_to_the_tray_unfiled() {
    let mut k = kernel();
    let fx = land(&mut k, &inbound_mail("<a1@acme.example>", Some("<hm.1@gmail.com>")), &mail(NOW), 100).unwrap();
    assert_eq!(fx.len(), 1);
    let c = item(&fx);
    assert_eq!((&c["actor"], &c["filing"], &c["at"]), (&json!(enums::actor::MAIL), &json!(enums::filing::UNFILED), &json!(NOW)));
    // The sender stored bare; the thread by its own headers.
    assert_eq!((c["to_addr"].as_str(), c["thread_key"].as_str()), (Some("matei3d@gmail.com"), Some("<hm.1@gmail.com>")));
    let read = Item::read(k.rows().table(table::OUTREACH).unwrap(), 100).unwrap();
    assert_eq!((read.core.kind, read.status(), read.core.filing), (Kind::Email, Some(Status::Received), Filing::Unfiled));
    // The item as the hub reads it.
    let j = k.query(&json!({"op": "outreach"})).unwrap();
    assert_eq!((&j["total"], &j["counts"]), (&json!(1), &json!({"unfiled": 1, "unseen": 1})));
    let r = &j["rows"][0];
    assert_eq!((r["kind"].as_str(), r["status"].as_str(), r["body_format"].as_str()), (Some("email"), Some("received"), Some("text")));
    assert_eq!(r["email"]["from"], "someone@nowhere.example");
    assert!(r.get("linkedin").is_none());
    // A mail the filer can place (a contact at a company with one application
    // on the role) is filed by the matcher, with its evidence.
    let dana = json!({"kind": "email", "direction": "inbound", "from_addr": "Dana Reyes <dana@acme.example>", "to_addr": "matei3d@gmail.com", "subject": "Re: Staff Engineer", "body": "Thanks for applying for the Staff Engineer role, when can you talk?", "message_id": "<d1@acme.example>", "pipe": "gmail"});
    let c = item(&land(&mut k, &put(0, dana), &mail(NOW), 101).unwrap());
    assert_eq!((&c["filing"], &c["filed_by"]), (&json!(enums::filing::FILED), &json!(enums::filer::MATCHER)));
    assert_eq!((&c["application_id"], &c["contact_id"], &c["corporation_id"]), (&json!(10), &json!(5), &json!(1)));
    let ev: Json = serde_json::from_str(c["evidence"].as_str().expect("evidence")).unwrap();
    let kinds: Vec<&str> = ev["evidence"].as_array().unwrap().iter().filter_map(|e| e["kind"].as_str()).collect();
    assert!(kinds.contains(&"contact") && kinds.contains(&"sender_domain"), "{kinds:?}");
    let j = k.query(&json!({"op": "outreach", "where": {"application_id": 10}})).unwrap();
    assert_eq!((j["total"].as_u64(), j["rows"][0]["contact"].as_str(), j["rows"][0]["application"].as_str()), (Some(1), Some("Dana Reyes"), Some("Acme · Staff Engineer")));
    assert_eq!(outreach::summary(k.rows(), 10), json!({"count": 1, "unseen": 1, "last_inbound_at": kernel::time_iso(NOW)}));
}

#[test]
fn a_mail_the_writer_files_is_filed_by_its_actor_with_the_refs_a_mission_implies() {
    let mut k = kernel();
    let c = item(&k.judge(&put(0, json!({"kind": "email", "direction": "inbound", "from_addr": "dana@acme.example", "message_id": "<b@acme.example>", "mission_id": 20})), &agent(3, NOW)).unwrap());
    assert_eq!((&c["application_id"], &c["corporation_id"], &c["filing"], &c["filed_by"]), (&json!(10), &json!(1), &json!(enums::filing::FILED), &json!(enums::filer::AGENT)));
    // A contradiction is refused: the mission's application is 10.
    let (code, data) = refused(k.judge(&put(0, json!({"kind": "email", "direction": "inbound", "from_addr": "dana@acme.example", "mission_id": 20, "application_id": 11})), &agent(3, NOW)));
    assert_eq!((code, data["column"].as_str()), (refusal::TYPE, Some("application_id")));
}

#[test]
fn each_kind_has_its_invariants() {
    let mut k = kernel();
    let (op, ag) = (operator(NOW), agent(3, NOW));
    let mut refuses = |ctx: &Ctx, column: &str, cells: Json| {
        let (code, data) = refused(k.judge(&put(0, cells), ctx));
        assert_eq!((code, data["column"].as_str()), (refusal::TYPE, Some(column)), "{data}");
    };
    let dm = json!({"kind": "x_dm", "direction": "outbound", "handle": "@dana", "body": "Hi Dana", "mission_id": 20});
    for (ctx, column, cells) in [
        // A note has no direction and says something.
        (&op, "direction", json!({"kind": "note", "direction": "outbound", "body": "x"})),
        (&op, "body", json!({"kind": "note"})),
        // A message has one.
        (&op, "direction", json!({"kind": "linkedin", "handle": "dana"})),
        // A careers-page item is outbound and names its form.
        (&op, "direction", json!({"kind": "careers_page", "direction": "inbound", "link": "https://jobs.acme.example/4012"})),
        (&op, "link", json!({"kind": "careers_page"})),
        // A link is a URL.
        (&op, "link", json!({"kind": "note", "body": "x", "link": "not a url"})),
        // Another channel names itself.
        (&op, "channel", json!({"kind": "other", "direction": "outbound"})),
        // A mail's own columns are no one else's; an outbound mail names recipients, an inbound its sender.
        (&op, "from_addr", json!({"kind": "linkedin", "direction": "outbound", "from_addr": "a@b.co"})),
        (&op, "to_addr", json!({"kind": "email", "direction": "outbound", "subject": "hi"})),
        (&op, "from_addr", json!({"kind": "email", "direction": "inbound", "subject": "hi"})),
        (&op, "to_addr", json!({"kind": "email", "direction": "outbound", "to_addr": "nobody"})),
        // An agent's act on an untracked channel carries its report; the operator's need not.
        (&ag, "report", dm.clone()),
    ] {
        refuses(ctx, column, cells);
    }
    assert!(k.judge(&put(0, json!({"kind": "note", "body": "Saw the CTO post about hiring", "corporation_id": 1})), &op).is_ok());
    let c = item(&k.judge(&put(0, json!({"kind": "careers_page", "link": "https://jobs.acme.example/4012", "mission_id": 20})), &op).unwrap());
    assert_eq!(c["direction"], enums::direction::OUTBOUND);
    assert!(k.judge(&put(0, dm.clone()), &op).is_ok());
    let mut reported = dm;
    reported["report"] = json!("Sent at 10:42; she replied she will forward it.");
    let c = item(&k.judge(&put(0, reported), &ag).unwrap());
    // The handle without its @.
    assert_eq!((&c["handle"], &c["actor"]), (&json!("dana"), &json!(enums::actor::AGENT)));
}

#[test]
fn kind_direction_and_message_id_are_fixed_once_written_and_a_touched_ref_refiles() {
    let mut k = kernel();
    let (op, ag) = (operator(NOW), agent(3, NOW));
    land(&mut k, &inbound_mail("<c@acme.example>", None), &mail(NOW), 100).unwrap();
    for fixed in [json!({"kind": "note"}), json!({"direction": "outbound"}), json!({"message_id": "<other@acme.example>"})] {
        let (code, data) = refused(k.judge(&put(100, fixed), &op));
        assert_eq!((code, data["reason"].as_str()), (refusal::COLUMN, Some("fixed")));
    }
    // The same values again are no change; a ref files it by the operator.
    let c = item(&k.judge(&put(100, json!({"kind": "email", "contact_id": 5})), &op).unwrap());
    assert_eq!((&c["filing"], &c["filed_by"], &c["corporation_id"]), (&json!(enums::filing::FILED), &json!(enums::filer::OPERATOR), &json!(1)));
    land(&mut k, &put(100, json!({"contact_id": 5})), &op, 100).unwrap();
    // Ignored: no refs; filed again by the command.
    let fx = k.judge(&cmd("ignore", 100, json!({})), &op).unwrap();
    assert_eq!((&item(&fx)["filing"], item(&fx).get("contact_id")), (&json!(enums::filing::IGNORED), Some(&Json::Null)));
    let c = item(&k.judge(&cmd("file", 100, json!({"mission_id": 20})), &ag).unwrap());
    assert_eq!((&c["application_id"], &c["filed_by"]), (&json!(10), &json!(enums::filer::AGENT)));
    assert_eq!(refused(k.judge(&cmd("file", 100, json!({"mission_id": 99})), &ag)).0, refusal::NOT_FOUND);
    assert_eq!(refused(k.judge(&cmd("file", 100, json!({})), &ag)).0, refusal::COLUMN);
}

#[test]
fn the_sent_record_is_inserted_or_lands_on_gmails_copy() {
    let mut k = kernel();
    let to = vec!["jobs@acme.example".to_string()];
    let shot = Shot { mission_id: 20, application_id: 10, contact_id: None, corporation_id: None, from: "matei3d@gmail.com", to: &to, cc: &[], subject: Some("Staff Engineer application"), body: Some("Hello"), in_reply_to: None, refs: &[], message_id: "<hm.7f3a@gmail.com>", gmail_msgid: None, gmail_thrid: None };
    let row = outreach::sent_record(k.rows(), &shot, NOW);
    let c = item(std::slice::from_ref(&row));
    assert_eq!((row.id, &c["direction"], &c["corporation_id"]), (0, &json!(enums::direction::OUTBOUND), &json!(1)));
    assert_eq!((&c["filed_by"], &c["thread_key"]), (&json!(enums::filer::MAIL), &json!("<hm.7f3a@gmail.com>")));
    // Gmail's copy came first, under a differently written Message-ID: the record updates it.
    land(&mut k, &put(0, json!({"kind": "email", "direction": "outbound", "to_addr": "jobs@acme.example", "message_id": " <HM.7F3A@gmail.com> ", "gmail_thrid": 77})), &mail(NOW), 101).unwrap();
    assert_eq!(outreach::by_message_id(k.rows(), "<hm.7f3a@gmail.com>"), Some(101));
    let row = outreach::sent_record(k.rows(), &shot, NOW);
    let c = item(std::slice::from_ref(&row));
    assert_eq!((row.id, c.get("kind"), &c["mission_id"]), (101, None, &json!(20)));
    // The reply to it threads to the sent mail.
    let fx = land(&mut k, &inbound_mail("<r@acme.example>", Some("<hm.7f3a@gmail.com>")), &mail(NOW), 102).unwrap();
    assert_eq!(item(&fx)["thread_key"], "<hm.7f3a@gmail.com>");
    let f = Item::read(k.rows().table(table::OUTREACH).unwrap(), 102).unwrap();
    let input = f.input();
    assert_eq!((input.email, input.inbound, input.in_reply_to, input.message_id), (true, true, "<hm.7f3a@gmail.com>", "<r@acme.example>"));
    assert_eq!(outreach::summary(k.rows(), 10)["count"], 0);
}

#[test]
fn the_hub_query_filters_searches_sorts_and_groups_on_any_key() {
    let mut k = kernel();
    let op = operator(NOW);
    land(&mut k, &inbound_mail("<q1@acme.example>", None), &mail(NOW), 100).unwrap();
    land(&mut k, &put(0, json!({"kind": "linkedin", "direction": "outbound", "handle": "danareyes", "body": "Hi Dana, about the Staff role", "contact_id": 5, "at": NOW - 86_400 * 40})), &op, 101).unwrap();
    land(&mut k, &put(0, json!({"kind": "note", "body": "Zed is hiring in Berlin", "application_id": 11, "at": NOW - 86_400 * 2})), &op, 102).unwrap();
    land(&mut k, &put(0, json!({"kind": "careers_page", "link": "https://jobs.acme.example/4012", "reference": "APP-4012", "mission_id": 20, "report": "Submitted."})), &op, 103).unwrap();
    let q = |k: &mut Kernel, req: Json| k.query(&req).unwrap();
    let labels = |j: &Json| j["groups"].as_array().unwrap().iter().map(|g| g["label"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    // Newest first by default.
    let j = q(&mut k, json!({"op": "outreach"}));
    let ids: Vec<u64> = j["rows"].as_array().unwrap().iter().map(|r| r["id"].as_u64().unwrap()).collect();
    assert_eq!((ids, &j["counts"]), (vec![100, 103, 102, 101], &json!({"unfiled": 1, "unseen": 1})));
    assert_eq!((&j["rows"][1]["application"], &j["rows"][1]["careers_page"]["reference"], &j["rows"][2]["body_format"]), (&json!("Acme · Staff Engineer"), &json!("APP-4012"), &json!("markdown")));
    // Grouped by kind, the groups in the enum's order; by company, with the names.
    assert_eq!(labels(&q(&mut k, json!({"op": "outreach", "group": "kind"}))), ["email", "careers page", "linkedin", "note"]);
    assert_eq!(labels(&q(&mut k, json!({"op": "outreach", "group": "company", "sort": ["at", "asc"]}))), ["Acme", "Zed", "(none)"]);
    // Grouped by month, the absent at never (every item has one); searched; narrowed by where.
    assert_eq!(labels(&q(&mut k, json!({"op": "outreach", "group": "month"}))).len(), 2);
    assert_eq!(q(&mut k, json!({"op": "outreach", "search": "staff"}))["total"], 1);
    let j = q(&mut k, json!({"op": "outreach", "where": {"application_id": 10}, "group": "direction"}));
    assert_eq!((&j["total"], &j["rows"][0]["kind"]), (&json!(1), &json!("careers_page")));
    assert_eq!(q(&mut k, json!({"op": "outreach", "where": {"at": {"ge": kernel::time_iso(NOW - 86_400 * 3)}}}))["total"], 3);
    // Paged, with the listing an agent reads.
    let j = q(&mut k, json!({"op": "outreach", "limit": 2, "group": "kind"}));
    assert_eq!((j["next"].as_u64(), j["rows"].as_array().unwrap().len()), (Some(2), 2));
    assert!(j["listing"].as_str().unwrap().starts_with("4 outreach items sorted by at desc, grouped by kind; rows 1-2\n"));
    // An unknown key is refused with the known ones.
    let r = k.query(&json!({"op": "outreach", "group": "colour"})).unwrap_err();
    assert_eq!((r.code, r.data["known"][0].as_str()), (refusal::TYPE, Some("kind")));
    // A key without the mail bit reads nothing.
    let r = k.query_as(&Grants { human: false, read_mask: 0b0011, write_mask: 0, may_delete: false }, &json!({"op": "outreach"})).unwrap_err();
    assert_eq!(r.code, refusal::SCOPE);
    // The desk card's summary.
    assert_eq!(outreach::summary(k.rows(), 11), json!({"count": 1, "unseen": 0, "last_inbound_at": null}));
    assert!(matches!(Item::read(k.rows().table(table::OUTREACH).unwrap(), 101).unwrap().body, Body::LinkedIn(_)));
}
