//! The OutreachItem through the facade: what each kind requires and
//! derives on a put, what is fixed once written, how an inbound item is
//! filed, the sent record, the commands, and the hub's query
//! (docs/mail/outreach_type.md).

use kernel::abi::Kernel;
use kernel::judge::{Ctx, EVal, Refusal, Row};
use kernel::outreach::{self, Body, Direction, Email, Filing, Item, Kind, LinkedIn, Shot, Status};
use kernel::query::Grants;
use kernel::rows::Val;
use schema::col::outreach as O;
use schema::{col, command, enums, param, refusal, table};
use serde_json::{json, Value as Json};

const TODAY: i32 = 739_528;
const NOW: i64 = (TODAY - kernel::UNIX_EPOCH_DAY) as i64 * 86_400 + 3_600;
const OPERATOR: Grants = Grants { human: true, read_mask: 0b1111, write_mask: 0b1111, may_delete: true };

/// Acme (corporation 1) with application 10 (Dana, contact 5) and mission
/// 20 (an email mission of application 10); Zed (2) with application 11.
fn kernel() -> Kernel {
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::CORPORATIONS, 2);
    b.u32s(col::corporations::ID, [1, 2].into_iter()).strs(col::corporations::DOMAIN, ["acme.example", "zed.example"].into_iter()).strs(col::corporations::NAME, ["Acme", "Zed"].into_iter());
    b.done();
    let mut b = w.block(table::APPLICATIONS, 2);
    b.u32s(col::applications::ID, [10, 11].into_iter())
        .u32s(col::applications::NO, [10, 11].into_iter())
        .u32s(col::applications::CORPORATION_ID, [1, 2].into_iter())
        .strs(col::applications::COMPANY, ["Acme", "Zed"].into_iter())
        .strs(col::applications::ROLE, ["Staff Engineer", "Platform Engineer"].into_iter())
        .u32s(col::applications::STAGE, [enums::stage::FIRE_READY as u32, enums::stage::GATED as u32].into_iter())
        .u32s(col::applications::HEAT_OVERRIDE, [0, 0].into_iter());
    b.done();
    let mut b = w.block(table::CONTACTS, 1);
    b.u32s(col::contacts::ID, [5].into_iter()).u32s(col::contacts::CORPORATION_ID, [1].into_iter()).strs(col::contacts::NAME, ["Dana Reyes"].into_iter()).strs(col::contacts::EMAIL, ["dana@acme.example"].into_iter());
    b.done();
    let mut b = w.block(table::MISSIONS, 1);
    b.u32s(col::missions::ID, [20].into_iter())
        .u32s(col::missions::APPLICATION_ID, [10].into_iter())
        .u32s(col::missions::KIND, [enums::mission_kind::EMAIL as u32].into_iter())
        .strs(col::missions::TARGET, ["jobs@acme.example"].into_iter())
        .u32s(col::missions::STATE, [enums::mission_state::FIRE_READY as u32].into_iter());
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.set_grants(OPERATOR);
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn ctx(human: bool, key: Option<u32>) -> Ctx<'static> {
    Ctx { today: TODAY, now: NOW, human, key_id: key, held: &[] }
}

const OPERATOR_CTX: Ctx<'static> = Ctx { today: TODAY, now: NOW, human: true, key_id: None, held: &[] };
const AGENT: Ctx<'static> = Ctx { today: TODAY, now: NOW, human: false, key_id: Some(3), held: &[] };
const MAIL: Ctx<'static> = Ctx { today: TODAY, now: NOW, human: false, key_id: None, held: &[] };

fn op(verb: u8, flags: u8, table: u16, target: u32, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(77, verb, flags, table, target, None);
    cells(&mut o);
    o.done();
    w.finish()[8..].to_vec()
}

fn put(target: u32, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    op(wire::PUT, 0, table::OUTREACH, target, cells)
}

fn cell(rows: &[Row], col: u16) -> Option<&EVal> {
    rows.iter().find(|r| r.table == table::OUTREACH && r.id == 0 || rows.len() == 1).and_then(|r| r.cells.iter().find(|c| c.0 == col).map(|c| &c.1))
}

fn u(v: u32) -> Option<&'static EVal> {
    // A tiny leak keeps the comparisons readable.
    Some(Box::leak(Box::new(EVal::Val(Val::U32(v)))))
}

fn refused(r: Result<Vec<Row>, Refusal>) -> (u16, Json) {
    let r = r.expect_err("expected a refusal");
    (r.code, r.data)
}

/// Judges the op and, when it passes, lands its effects as the sequencer would: id `id` for an insert.
fn land(k: &mut Kernel, op: &[u8], ctx: &Ctx, id: u32) -> Result<Vec<Row>, Refusal> {
    let rows = k.judge(op, ctx)?;
    let mut w = wire::BodyWriter::new();
    for r in &rows {
        let rid = if r.id == 0 { id } else { r.id };
        let mut b = w.block(r.table, 1);
        b.u32s(1, [rid].into_iter());
        for (c, v) in &r.cells {
            match v {
                EVal::Val(Val::U32(x)) => drop(b.u32s(*c, [*x].into_iter())),
                EVal::Val(Val::I64(x)) => drop(b.i64s(*c, [*x].into_iter())),
                EVal::Val(Val::Str(s)) => drop(b.strs(*c, [s.as_str()].into_iter())),
                EVal::Val(Val::None) => {}
                other => panic!("unexpected cell {other:?}"),
            }
        }
        b.done();
    }
    k.patch(&w.finish(), 2).unwrap();
    Ok(rows)
}

/// A mail from someone the filer cannot place: it goes to the tray.
fn inbound_mail(id: &str, in_reply_to: Option<&str>) -> Vec<u8> {
    let id = id.to_string();
    let irt = in_reply_to.map(String::from);
    put(0, move |o| {
        o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, Direction::Inbound.code()).str(O::FROM_ADDR, "Someone <someone@nowhere.example>").str(O::TO_ADDR, "matei3d@gmail.com").str(O::SUBJECT, "Hello").str(O::BODY, "Just saying hi.").str(O::MESSAGE_ID, &id).u32(O::PIPE, enums::mail_pipe::GMAIL as u32);
        if let Some(r) = &irt {
            o.str(O::IN_REPLY_TO, r).str(O::REFS, r);
        }
    })
}

/// A mail from Dana at Acme about the Staff Engineer role: the filer places it.
fn dana_mail(id: &str) -> Vec<u8> {
    let id = id.to_string();
    put(0, move |o| {
        o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, Direction::Inbound.code()).str(O::FROM_ADDR, "Dana Reyes <dana@acme.example>").str(O::TO_ADDR, "matei3d@gmail.com").str(O::SUBJECT, "Re: Staff Engineer").str(O::BODY, "Thanks for applying for the Staff Engineer role, when can you talk?").str(O::MESSAGE_ID, &id).u32(O::PIPE, enums::mail_pipe::GMAIL as u32);
    })
}

#[test]
fn an_inbound_mail_is_received_from_the_mail_actor_and_goes_to_the_tray_unfiled() {
    let mut k = kernel();
    let fx = land(&mut k, &inbound_mail("<a1@acme.example>", Some("<hm.1@gmail.com>")), &MAIL, 100).unwrap();
    assert_eq!(fx.len(), 1);
    assert_eq!(cell(&fx, O::ACTOR), u(enums::actor::MAIL as u32));
    assert_eq!(cell(&fx, O::FILING), u(enums::filing::UNFILED as u32));
    assert_eq!(cell(&fx, O::AT), u(NOW as u32));
    // The sender stored bare; the thread by its own headers.
    assert_eq!(cell(&fx, O::TO_ADDR), Some(&EVal::Val(Val::Str("matei3d@gmail.com".into()))));
    assert_eq!(cell(&fx, O::THREAD_KEY), Some(&EVal::Val(Val::Str("<hm.1@gmail.com>".into()))));
    let t = k.rows().table(table::OUTREACH).unwrap();
    let item = Item::read(t, 100).unwrap();
    assert_eq!((item.kind(), item.status(), item.core.filing), (Kind::Email, Some(Status::Received), Filing::Unfiled));
    let mail: Item<Email> = item.clone().narrow::<Email>().unwrap();
    assert_eq!(mail.body.from.as_deref(), Some("someone@nowhere.example"));
    assert!(item.narrow::<LinkedIn>().is_err());
    // The item as the hub reads it.
    let j = k.query(&json!({"op": "outreach"})).unwrap();
    assert_eq!(j["total"], 1);
    assert_eq!(j["counts"], json!({"unfiled": 1, "unseen": 1}));
    let r = &j["rows"][0];
    assert_eq!((r["kind"].as_str(), r["status"].as_str(), r["body_format"].as_str()), (Some("email"), Some("received"), Some("text")));
    assert_eq!(r["email"]["from"], "someone@nowhere.example");
    assert!(r.get("linkedin").is_none());
    // A mail the filer can place (a contact at a company with one application
    // on the role) is filed by the matcher, with its evidence.
    let fx = land(&mut k, &dana_mail("<d1@acme.example>"), &MAIL, 101).unwrap();
    assert_eq!(cell(&fx, O::FILING), u(enums::filing::FILED as u32));
    assert_eq!(cell(&fx, O::FILED_BY), u(enums::filer::MATCHER as u32));
    assert_eq!((cell(&fx, O::APPLICATION_ID), cell(&fx, O::CONTACT_ID), cell(&fx, O::CORPORATION_ID)), (u(10), u(5), u(1)));
    let Some(EVal::Val(Val::Str(ev))) = cell(&fx, O::EVIDENCE) else { panic!("no evidence") };
    let ev: Json = serde_json::from_str(ev).unwrap();
    let kinds: Vec<&str> = ev["evidence"].as_array().unwrap().iter().filter_map(|e| e["kind"].as_str()).collect();
    assert!(kinds.contains(&"contact") && kinds.contains(&"sender_domain"), "{kinds:?}");
    let j = k.query(&json!({"op": "outreach", "where": {"application_id": 10}})).unwrap();
    assert_eq!((j["total"].as_u64(), j["rows"][0]["contact"].as_str(), j["rows"][0]["application"].as_str()), (Some(1), Some("Dana Reyes"), Some("Acme · Staff Engineer")));
    assert_eq!(outreach::summary(k.rows(), 10), json!({"count": 1, "unseen": 1, "last_inbound_at": kernel::time_iso(NOW)}));
}

#[test]
fn a_mail_the_writer_files_is_filed_by_its_actor_with_the_refs_a_mission_implies() {
    let mut k = kernel();
    let fx = k.judge(&put(0, |o| {
        o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, Direction::Inbound.code()).str(O::FROM_ADDR, "dana@acme.example").str(O::MESSAGE_ID, "<b@acme.example>").u32(O::MISSION_ID, 20);
    }), &AGENT).unwrap();
    assert_eq!(cell(&fx, O::APPLICATION_ID), u(10));
    assert_eq!(cell(&fx, O::CORPORATION_ID), u(1));
    assert_eq!(cell(&fx, O::FILING), u(enums::filing::FILED as u32));
    assert_eq!(cell(&fx, O::FILED_BY), u(enums::filer::AGENT as u32));
    // A contradiction is refused: the mission's application is 10.
    let (code, data) = refused(k.judge(&put(0, |o| {
        o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, Direction::Inbound.code()).str(O::FROM_ADDR, "dana@acme.example").u32(O::MISSION_ID, 20).u32(O::APPLICATION_ID, 11);
    }), &AGENT));
    assert_eq!((code, data["column"].as_str()), (refusal::TYPE, Some("application_id")));
}

#[test]
fn each_kind_has_its_invariants() {
    let mut k = kernel();
    let refuses = |k: &mut Kernel, ctx: &Ctx, column: &str, cells: &dyn Fn(&mut wire::OpWriter)| {
        let (code, data) = refused(k.judge(&put(0, |o| cells(o)), ctx));
        assert_eq!((code, data["column"].as_str()), (refusal::TYPE, Some(column)), "{data}");
    };
    // A note has no direction and says something.
    refuses(&mut k, &OPERATOR_CTX, "direction", &|o| { o.u32(O::KIND, Kind::Note.code()).u32(O::DIRECTION, 0).str(O::BODY, "x"); });
    refuses(&mut k, &OPERATOR_CTX, "body", &|o| { o.u32(O::KIND, Kind::Note.code()); });
    assert!(k.judge(&put(0, |o| { o.u32(O::KIND, Kind::Note.code()).str(O::BODY, "Saw the CTO post about hiring").u32(O::CORPORATION_ID, 1); }), &OPERATOR_CTX).is_ok());
    // A message has one.
    refuses(&mut k, &OPERATOR_CTX, "direction", &|o| { o.u32(O::KIND, Kind::LinkedIn.code()).str(O::HANDLE, "dana"); });
    // A careers-page item is outbound and names its form.
    refuses(&mut k, &OPERATOR_CTX, "direction", &|o| { o.u32(O::KIND, Kind::CareersPage.code()).u32(O::DIRECTION, 1).str(O::LINK, "https://jobs.acme.example/4012"); });
    refuses(&mut k, &OPERATOR_CTX, "link", &|o| { o.u32(O::KIND, Kind::CareersPage.code()); });
    let fx = k.judge(&put(0, |o| { o.u32(O::KIND, Kind::CareersPage.code()).str(O::LINK, "https://jobs.acme.example/4012").u32(O::MISSION_ID, 20); }), &OPERATOR_CTX).unwrap();
    assert_eq!(cell(&fx, O::DIRECTION), u(Direction::Outbound.code()));
    // A link is a URL.
    refuses(&mut k, &OPERATOR_CTX, "link", &|o| { o.u32(O::KIND, Kind::Note.code()).str(O::BODY, "x").str(O::LINK, "not a url"); });
    // Another channel names itself.
    refuses(&mut k, &OPERATOR_CTX, "channel", &|o| { o.u32(O::KIND, Kind::Other.code()).u32(O::DIRECTION, 0); });
    // A mail's own columns are no one else's; an outbound mail names recipients, an inbound its sender.
    refuses(&mut k, &OPERATOR_CTX, "from_addr", &|o| { o.u32(O::KIND, Kind::LinkedIn.code()).u32(O::DIRECTION, 0).str(O::FROM_ADDR, "a@b.co"); });
    refuses(&mut k, &OPERATOR_CTX, "to_addr", &|o| { o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, 0).str(O::SUBJECT, "hi"); });
    refuses(&mut k, &OPERATOR_CTX, "from_addr", &|o| { o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, 1).str(O::SUBJECT, "hi"); });
    refuses(&mut k, &OPERATOR_CTX, "to_addr", &|o| { o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, 0).str(O::TO_ADDR, "nobody"); });
    // An agent's act on an untracked channel carries its report; the operator's need not.
    let dm = |o: &mut wire::OpWriter| { o.u32(O::KIND, Kind::XDm.code()).u32(O::DIRECTION, 0).str(O::HANDLE, "@dana").str(O::BODY, "Hi Dana").u32(O::MISSION_ID, 20); };
    refuses(&mut k, &AGENT, "report", &dm);
    assert!(k.judge(&put(0, dm), &OPERATOR_CTX).is_ok());
    let fx = k.judge(&put(0, |o| {
        dm(o);
        o.str(O::REPORT, "Sent at 10:42; she replied she will forward it.");
    }), &AGENT).unwrap();
    // The handle without its @.
    assert_eq!(cell(&fx, O::HANDLE), Some(&EVal::Val(Val::Str("dana".into()))));
    assert_eq!(cell(&fx, O::ACTOR), u(enums::actor::AGENT as u32));
}

#[test]
fn kind_direction_and_message_id_are_fixed_once_written_and_a_touched_ref_refiles() {
    let mut k = kernel();
    land(&mut k, &inbound_mail("<c@acme.example>", None), &MAIL, 100).unwrap();
    let fixed = |k: &mut Kernel, cells: &dyn Fn(&mut wire::OpWriter)| {
        let (code, data) = refused(k.judge(&put(100, |o| cells(o)), &OPERATOR_CTX));
        assert_eq!((code, data["reason"].as_str()), (refusal::COLUMN, Some("fixed")));
    };
    fixed(&mut k, &|o| { o.u32(O::KIND, Kind::Note.code()); });
    fixed(&mut k, &|o| { o.u32(O::DIRECTION, Direction::Outbound.code()); });
    fixed(&mut k, &|o| { o.str(O::MESSAGE_ID, "<other@acme.example>"); });
    // The same values again are no change; a ref files it by the operator.
    let fx = k.judge(&put(100, |o| { o.u32(O::KIND, Kind::Email.code()).u32(O::CONTACT_ID, 5); }), &OPERATOR_CTX).unwrap();
    assert_eq!(cell(&fx, O::FILING), u(enums::filing::FILED as u32));
    assert_eq!(cell(&fx, O::FILED_BY), u(enums::filer::OPERATOR as u32));
    assert_eq!(cell(&fx, O::CORPORATION_ID), u(1));
    land(&mut k, &put(100, |o| { o.u32(O::CONTACT_ID, 5); }), &OPERATOR_CTX, 100).unwrap();
    // Ignored: no refs; filed again by the command.
    let fx = k.judge(&op(wire::COMMAND, 0, command::IGNORE, 100, |_| {}), &OPERATOR_CTX).unwrap();
    assert_eq!(cell(&fx, O::FILING), u(enums::filing::IGNORED as u32));
    assert_eq!(cell(&fx, O::CONTACT_ID), Some(&EVal::Val(Val::None)));
    let fx = k.judge(&op(wire::COMMAND, 0, command::FILE, 100, |o| { o.u32(param::file::MISSION_ID, 20); }), &AGENT).unwrap();
    assert_eq!(cell(&fx, O::APPLICATION_ID), u(10));
    assert_eq!(cell(&fx, O::FILED_BY), u(enums::filer::AGENT as u32));
    let (code, _) = refused(k.judge(&op(wire::COMMAND, 0, command::FILE, 100, |o| { o.u32(param::file::MISSION_ID, 99); }), &AGENT));
    assert_eq!(code, refusal::NOT_FOUND);
    let (code, _) = refused(k.judge(&op(wire::COMMAND, 0, command::FILE, 100, |_| {}), &AGENT));
    assert_eq!(code, refusal::COLUMN);
}

#[test]
fn the_sent_record_is_inserted_or_lands_on_gmails_copy() {
    let mut k = kernel();
    let to = vec!["jobs@acme.example".to_string()];
    let shot = Shot { mission_id: 20, application_id: 10, contact_id: None, corporation_id: None, from: "matei3d@gmail.com", to: &to, cc: &[], subject: Some("Staff Engineer application"), body: Some("Hello"), in_reply_to: None, refs: &[], message_id: "<hm.7f3a@gmail.com>", gmail_msgid: None, gmail_thrid: None };
    let row = outreach::sent_record(k.rows(), &shot, NOW);
    assert_eq!(row.id, 0);
    let get = |r: &Row, c: u16| r.cells.iter().find(|x| x.0 == c).map(|x| x.1.clone());
    assert_eq!(get(&row, O::DIRECTION), Some(EVal::Val(Val::U32(Direction::Outbound.code()))));
    assert_eq!(get(&row, O::CORPORATION_ID), Some(EVal::Val(Val::U32(1))));
    assert_eq!(get(&row, O::FILED_BY), Some(EVal::Val(Val::U32(enums::filer::MAIL as u32))));
    assert_eq!(get(&row, O::THREAD_KEY), Some(EVal::Val(Val::Str("<hm.7f3a@gmail.com>".into()))));
    // Gmail's copy came first, under a differently written Message-ID: the record updates it.
    land(&mut k, &put(0, |o| { o.u32(O::KIND, Kind::Email.code()).u32(O::DIRECTION, Direction::Outbound.code()).str(O::TO_ADDR, "jobs@acme.example").str(O::MESSAGE_ID, " <HM.7F3A@gmail.com> ").i64(O::GMAIL_THRID, 77); }), &MAIL, 101).unwrap();
    assert_eq!(outreach::by_message_id(k.rows(), "<hm.7f3a@gmail.com>"), Some(101));
    let row = outreach::sent_record(k.rows(), &shot, NOW);
    assert_eq!(row.id, 101);
    assert_eq!(get(&row, O::KIND), None);
    assert_eq!(get(&row, O::MISSION_ID), Some(EVal::Val(Val::U32(20))));
    // The reply to it threads to the sent mail.
    let fx = land(&mut k, &inbound_mail("<r@acme.example>", Some("<hm.7f3a@gmail.com>")), &MAIL, 102).unwrap();
    assert_eq!(cell(&fx, O::THREAD_KEY), Some(&EVal::Val(Val::Str("<hm.7f3a@gmail.com>".into()))));
    let t = k.rows().table(table::OUTREACH).unwrap();
    let f = Item::read(t, 102).unwrap();
    let input = f.input();
    assert_eq!((input.email, input.inbound, input.in_reply_to, input.message_id), (true, true, "<hm.7f3a@gmail.com>", "<r@acme.example>"));
    assert_eq!(outreach::summary(k.rows(), 10)["count"], 0);
}

#[test]
fn the_hub_query_filters_searches_sorts_and_groups_on_any_key() {
    let mut k = kernel();
    land(&mut k, &inbound_mail("<q1@acme.example>", None), &MAIL, 100).unwrap();
    land(&mut k, &put(0, |o| { o.u32(O::KIND, Kind::LinkedIn.code()).u32(O::DIRECTION, 0).str(O::HANDLE, "danareyes").str(O::BODY, "Hi Dana, about the Staff role").u32(O::CONTACT_ID, 5).u32(O::AT, (NOW - 86_400 * 40) as u32); }), &OPERATOR_CTX, 101).unwrap();
    land(&mut k, &put(0, |o| { o.u32(O::KIND, Kind::Note.code()).str(O::BODY, "Zed is hiring in Berlin").u32(O::APPLICATION_ID, 11).u32(O::AT, (NOW - 86_400 * 2) as u32); }), &OPERATOR_CTX, 102).unwrap();
    land(&mut k, &put(0, |o| { o.u32(O::KIND, Kind::CareersPage.code()).str(O::LINK, "https://jobs.acme.example/4012").str(O::REFERENCE, "APP-4012").u32(O::MISSION_ID, 20).str(O::REPORT, "Submitted."); }), &OPERATOR_CTX, 103).unwrap();
    let q = |k: &mut Kernel, req: Json| k.query(&req).unwrap();
    // Newest first by default.
    let j = q(&mut k, json!({"op": "outreach"}));
    let ids: Vec<u64> = j["rows"].as_array().unwrap().iter().map(|r| r["id"].as_u64().unwrap()).collect();
    assert_eq!(ids, vec![100, 103, 102, 101]);
    assert_eq!(j["counts"], json!({"unfiled": 1, "unseen": 1}));
    assert_eq!(j["rows"][1]["application"], "Acme · Staff Engineer");
    assert_eq!(j["rows"][1]["careers_page"]["reference"], "APP-4012");
    assert_eq!(j["rows"][2]["body_format"], "markdown");
    // Grouped by kind, the groups in the enum's order; by company, with the names.
    let j = q(&mut k, json!({"op": "outreach", "group": "kind"}));
    let labels: Vec<&str> = j["groups"].as_array().unwrap().iter().map(|g| g["label"].as_str().unwrap()).collect();
    assert_eq!(labels, vec!["email", "careers page", "linkedin", "note"]);
    let j = q(&mut k, json!({"op": "outreach", "group": "company", "sort": ["at", "asc"]}));
    let labels: Vec<&str> = j["groups"].as_array().unwrap().iter().map(|g| g["label"].as_str().unwrap()).collect();
    assert_eq!(labels, vec!["Acme", "Zed", "(none)"]);
    // Grouped by month, the absent at never (every item has one); searched; narrowed by where.
    let j = q(&mut k, json!({"op": "outreach", "group": "month"}));
    assert_eq!(j["groups"].as_array().unwrap().len(), 2);
    let j = q(&mut k, json!({"op": "outreach", "search": "staff"}));
    assert_eq!(j["total"], 1);
    let j = q(&mut k, json!({"op": "outreach", "where": {"application_id": 10}, "group": "direction"}));
    assert_eq!(j["total"], 1);
    assert_eq!(j["rows"][0]["kind"], "careers_page");
    let j = q(&mut k, json!({"op": "outreach", "where": {"at": {"ge": kernel::time_iso(NOW - 86_400 * 3)}}}));
    assert_eq!(j["total"], 3);
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
    let t = k.rows().table(table::OUTREACH).unwrap();
    assert!(matches!(Item::read(t, 101).unwrap().body, Body::LinkedIn(_)));
}

#[test]
fn the_items_cells_round_trip_through_a_put() {
    let mut k = kernel();
    let mut item: Item<Body> = Item { core: kernel_core(Kind::LinkedIn, Some(Direction::Inbound)), body: Body::LinkedIn(LinkedIn { handle: Some("danareyes".into()) }) };
    item.core.subject = Some("Reply".into());
    item.core.refs.contact_id = Some(5);
    let cells = item.cells();
    let fx = land(&mut k, &put(0, |o| {
        for (c, v) in &cells {
            match v {
                Val::U32(x) => { o.u32(*c, *x); },
                Val::Str(s) => { o.str(*c, s); },
                Val::I64(x) => { o.i64(*c, *x); },
                _ => {}
            }
        }
    }), &ctx(true, None), 100).unwrap();
    assert_eq!(cell(&fx, O::CORPORATION_ID), u(1));
    let back = Item::read(k.rows().table(table::OUTREACH).unwrap(), 100).unwrap();
    assert_eq!((back.kind(), back.core.subject.as_deref(), back.core.refs.contact_id), (Kind::LinkedIn, Some("Reply"), Some(5)));
    assert_eq!(back.body, item.body);
}

fn kernel_core(kind: Kind, direction: Option<Direction>) -> kernel::outreach::Core {
    kernel::outreach::Core {
        id: 0,
        kind,
        direction,
        at: NOW,
        subject: None,
        body: None,
        link: None,
        report: None,
        actor: kernel::outreach::Actor::Operator,
        filing: Filing::Unfiled,
        filed_by: None,
        evidence: None,
        seen: false,
        refs: kernel::outreach::Refs::default(),
        rev: 0,
        inserted_at: 0,
        updated_at: 0,
    }
}
