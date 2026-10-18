//! The domain check through the kernel's facade: an op in the OPS layout
//! against resident rows, answered with a refusal or the effects the
//! sequencer persists. Rules from docs/rebuild.md "The sequencer's
//! checks", step 4: pipeline moves, fire hold, heat caps without an
//! override, lineage and cooldown; and "Keywords at write time".

use kernel::abi::Kernel;
use kernel::judge::{Ctx, EVal, Row};
use kernel::rows::Val;
use schema::col::applications as A;
use schema::{col, command, enums, param, refusal, table};

const TODAY: i32 = 20_000;

fn ctx() -> Ctx<'static> {
    Ctx { today: TODAY, now: TODAY as i64 * 86_400, human: false, key_id: Some(3), held: &[] }
}

struct App {
    id: u32,
    stage: u8,
    company: &'static str,
    role: &'static str,
    batch: Option<u32>,
    corp: Option<u32>,
    stage_on: i32,
}

fn app(id: u32, stage: u8, company: &'static str) -> App {
    App { id, stage, company, role: "Software Engineer", batch: None, corp: None, stage_on: TODAY }
}

/// A kernel booted with these applications, batches `(id, fire)` and
/// lineages `(id, corporation, opened_on, rewrites)`.
fn kernel(apps: &[App], batches: &[(u32, u8)], lineages: &[(u32, u32, i32, bool)]) -> Kernel {
    let mut w = wire::BodyWriter::new();
    let opt = |o: Option<u32>| o.unwrap_or(wire::NONE);
    let mut b = w.block(table::APPLICATIONS, apps.len());
    b.u32s(A::ID, apps.iter().map(|a| a.id))
        .u32s(A::NO, apps.iter().map(|a| a.id))
        .u32s(A::STAGE, apps.iter().map(|a| a.stage as u32))
        .strs(A::COMPANY, apps.iter().map(|a| a.company))
        .strs(A::ROLE, apps.iter().map(|a| a.role))
        .u32s(A::BATCH_ID, apps.iter().map(|a| opt(a.batch)))
        .u32s(A::CORPORATION_ID, apps.iter().map(|a| opt(a.corp)))
        .u32s(A::STAGE_ON, apps.iter().map(|a| a.stage_on as u32))
        .u32s(A::HEAT_OVERRIDE, apps.iter().map(|_| 0));
    b.done();
    let mut b = w.block(table::BATCHES, batches.len());
    b.u32s(col::batches::ID, batches.iter().map(|x| x.0)).u32s(col::batches::FIRE, batches.iter().map(|x| x.1 as u32));
    b.done();
    let mut b = w.block(table::CV_LINEAGES, lineages.len());
    b.u32s(col::cv_lineages::ID, lineages.iter().map(|x| x.0))
        .u32s(col::cv_lineages::CORPORATION_ID, lineages.iter().map(|x| x.1))
        .u32s(col::cv_lineages::OPENED_ON, lineages.iter().map(|x| x.2 as u32))
        .u32s(col::cv_lineages::GENERATION, lineages.iter().map(|_| 1))
        .u32s(col::cv_lineages::REWRITES_ALLOWED, lineages.iter().map(|x| x.3 as u32));
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.boot(&w.finish(), 1).unwrap();
    k
}

/// One op's bytes.
fn op(verb: u8, table: u16, target: u32, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(77, verb, 0, table, target, None);
    cells(&mut o);
    o.done();
    w.finish()[8..].to_vec()
}

fn stage_cmd(target: u32, to: u8) -> Vec<u8> {
    op(wire::COMMAND, command::STAGE, target, |o| {
        o.u32(param::stage::STAGE, to as u32);
    })
}

fn cell<'a>(rows: &'a [Row], table: u16, col: u16) -> Option<&'a EVal> {
    rows.iter().find(|r| r.table == table)?.cells.iter().find(|c| c.0 == col).map(|c| &c.1)
}

fn code(r: Result<Vec<Row>, kernel::judge::Refusal>) -> u16 {
    r.expect_err("expected a refusal").code
}

use enums::stage as S;

#[test]
fn a_move_writes_stage_pips_day_and_an_event() {
    let mut k = kernel(&[app(1, S::GATED, "Acme")], &[], &[]);
    let fx = k.judge(&stage_cmd(1, S::CLOSED), &ctx()).unwrap();
    assert_eq!(cell(&fx, table::APPLICATIONS, A::STAGE), Some(&EVal::Val(Val::U32(S::CLOSED as u32))));
    assert_eq!(cell(&fx, table::APPLICATIONS, A::PIPS), Some(&EVal::Val(Val::Str("DDDSSSSSSA".into()))));
    assert_eq!(cell(&fx, table::APPLICATIONS, A::STAGE_ON), Some(&EVal::Val(Val::U32(TODAY as u32))));
    assert_eq!(cell(&fx, table::APPLICATIONS, A::CLOSED_ON), Some(&EVal::Val(Val::U32(TODAY as u32))));
    assert_eq!(cell(&fx, table::EVENTS, col::events::APPLICATION_ID), Some(&EVal::Val(Val::U32(1))));
    assert_eq!(cell(&fx, table::EVENTS, col::events::ACTOR), Some(&EVal::Val(Val::U32(enums::actor::AGENT as u32))));
    assert_eq!(cell(&fx, table::EVENTS, col::events::OP_ID), Some(&EVal::Val(Val::I64(77))));
}

#[test]
fn batches_and_fire_hold() {
    let mut a = app(2, S::FIRE_READY, "Acme");
    a.batch = Some(9);
    let mut k = kernel(&[app(1, S::GATED, "Acme"), a], &[(9, enums::fire::HOLD)], &[]);
    assert_eq!(code(k.judge(&stage_cmd(1, S::IN_BATCH), &ctx())), refusal::STAGE);
    assert_eq!(code(k.judge(&stage_cmd(2, S::SUBMITTED), &ctx())), refusal::FIRE_HOLD);
    // open_fire is named only by its own command.
    assert_eq!(code(k.judge(&stage_cmd(2, S::OPEN_FIRE), &ctx())), refusal::STAGE);
    let fire = op(wire::COMMAND, command::OPEN_FIRE, 2, |_| {});
    let fx = k.judge(&fire, &ctx()).unwrap();
    assert_eq!(cell(&fx, table::APPLICATIONS, A::STAGE), Some(&EVal::Val(Val::U32(S::OPEN_FIRE as u32))));
    assert_eq!(code(k.judge(&op(wire::COMMAND, command::OPEN_FIRE, 1, |_| {}), &ctx())), refusal::STAGE);

    let mut a = app(2, S::FIRE_READY, "Acme");
    a.batch = Some(9);
    let mut opened = kernel(&[a], &[(9, enums::fire::OPEN_FIRE)], &[]);
    assert!(opened.judge(&stage_cmd(2, S::SUBMITTED), &ctx()).is_ok());
}

#[test]
fn heat_defers_a_second_seat_until_overridden() {
    let mut hot = app(1, S::SUBMITTED, "Acme");
    hot.batch = Some(9);
    let mut next = app(2, S::DRAFT_READY, "ACME");
    next.batch = Some(9);
    let mut k = kernel(&[hot, next], &[(9, enums::fire::HOLD)], &[]);
    let r = k.judge(&stage_cmd(2, S::FIRE_READY), &ctx()).unwrap_err();
    assert_eq!(r.code, refusal::HEAT);
    assert_eq!(r.data["reason"], "company_cap");
    assert_eq!(r.data["to"], "fire_ready");

    let blank = op(wire::COMMAND, command::HEAT_OVERRIDE, 2, |o| {
        o.str(param::heat_override::REASON, "  ");
    });
    assert_eq!(code(k.judge(&blank, &ctx())), refusal::HEAT);
    // No reason at all is the sequencer's shape refusal, answered alike.
    let none = op(wire::COMMAND, command::HEAT_OVERRIDE, 2, |o| {
        o.str(param::heat_override::REASON, "");
    });
    let r = k.judge(&none, &ctx()).unwrap_err();
    assert_eq!((r.code, r.data["missing"][0].as_str()), (refusal::COLUMN, Some("reason")));
    let reason = op(wire::COMMAND, command::HEAT_OVERRIDE, 2, |o| {
        o.str(param::heat_override::REASON, "different org entirely");
    });
    let fx = k.judge(&reason, &ctx()).unwrap();
    assert_eq!(cell(&fx, table::APPLICATIONS, A::HEAT_OVERRIDE), Some(&EVal::Val(Val::U32(1))));
    // Applied (as the server would), the move passes.
    k.predict(&reason, &ctx()).unwrap();
    assert!(k.judge(&stage_cmd(2, S::FIRE_READY), &ctx()).is_ok());
    // A different, unloaded company is never held.
    let mut other = kernel(&[app(1, S::SUBMITTED, "Acme"), { let mut a = app(3, S::DRAFT_READY, "Other"); a.batch = Some(9); a }], &[(9, 0)], &[]);
    assert!(other.judge(&stage_cmd(3, S::FIRE_READY), &ctx()).is_ok());
}

#[test]
fn listing_text_is_read_once_at_write_time() {
    let mut k = kernel(&[app(1, S::DISCOVERED, "Acme")], &[], &[]);
    let put = op(wire::PUT, table::APPLICATIONS, 1, |o| {
        o.str(A::LISTING_RAW, "Rust rust RUST kernels and GPU kernels");
    });
    let fx = k.judge(&put, &ctx()).unwrap();
    assert_eq!(cell(&fx, table::APPLICATIONS, A::KEYWORDS), Some(&EVal::Val(Val::Str("rust\u{1f}kernels\u{1f}gpu".into()))));
    assert_eq!(cell(&fx, table::APPLICATIONS, A::KEYWORDS_VERSION), Some(&EVal::Val(Val::U32(kernel::keywords::VERSION))));
    // The text's hash is the sequencer's, written for every deferred column.
    assert_eq!(cell(&fx, table::APPLICATIONS, A::LISTING_SHA), None);
    // A new application starts discovered, on today.
    let new = op(wire::PUT, table::APPLICATIONS, 0, |o| {
        o.str(A::COMPANY, "Acme");
    });
    let fx = k.judge(&new, &ctx()).unwrap();
    assert_eq!(fx[0].id, 0);
    assert_eq!(cell(&fx, table::APPLICATIONS, A::STAGE), Some(&EVal::Val(Val::U32(S::DISCOVERED as u32))));
    assert_eq!(cell(&fx, table::APPLICATIONS, A::PIPS), Some(&EVal::Val(Val::Str("APPPPPPPPP".into()))));
}

fn overlay(app: u32, target: u32) -> Vec<u8> {
    op(wire::PUT, table::CV_OVERLAYS, target, |o| {
        o.u32(col::cv_overlays::APPLICATION_ID, app).u32(col::cv_overlays::ITEM_ID, 5).u32(col::cv_overlays::MODE, 0);
    })
}

#[test]
fn a_first_overlay_opens_the_corporations_lineage() {
    let mut a = app(1, S::DRAFT_READY, "Acme");
    a.corp = Some(40);
    let mut k = kernel(&[a, app(2, S::GATED, "Nobody")], &[], &[]);
    let fx = k.judge(&overlay(1, 0), &ctx()).unwrap();
    assert_eq!(fx[0].table, table::CV_LINEAGES);
    assert_eq!(fx[0].id, 0);
    assert_eq!(cell(&fx, table::CV_OVERLAYS, col::cv_overlays::LINEAGE_ID), Some(&EVal::New(0)));
    // No corporation, no lineage to tell the story under.
    assert_eq!(code(k.judge(&overlay(2, 0), &ctx())), refusal::NOT_FOUND);
    // The prediction applies both rows and links them.
    k.predict(&overlay(1, 0), &ctx()).unwrap();
    let lineages = k.rows().table(table::CV_LINEAGES).unwrap();
    assert_eq!(lineages.len(), 1);
    let lid = lineages.ids()[0];
    let ov = k.rows().table(table::CV_OVERLAYS).unwrap();
    assert_eq!(ov.u32(ov.ids()[0], col::cv_overlays::LINEAGE_ID), Some(lid));
}

#[test]
fn lineage_windows() {
    let mut a = app(1, S::DRAFT_READY, "Acme");
    a.corp = Some(40);
    // Rewrites off: adding is fine, rewriting an existing overlay is not.
    let mut k = kernel(&[a], &[], &[(7, 40, TODAY - 10, false)]);
    assert!(k.judge(&overlay(1, 0), &ctx()).is_ok());
    k.predict(&overlay(1, 0), &ctx()).unwrap();
    let existing = k.rows().table(table::CV_OVERLAYS).unwrap().ids()[0];
    assert_eq!(code(k.judge(&overlay(1, existing), &ctx())), refusal::LINEAGE_BUSY);
    assert_eq!(code(k.judge(&op(wire::DROP, table::CV_OVERLAYS, existing, |_| {}), &ctx())), refusal::LINEAGE_BUSY);
    // Another application of the same company may not overlay that line again.
    let mut other = app(2, S::DRAFT_READY, "Acme");
    other.corp = Some(40);
    let mut k2 = kernel(&[{ let mut a = app(1, S::DRAFT_READY, "Acme"); a.corp = Some(40); a }, other], &[], &[(7, 40, TODAY - 10, false)]);
    k2.predict(&overlay(1, 0), &ctx()).unwrap();
    assert_eq!(code(k2.judge(&overlay(2, 0), &ctx())), refusal::LINEAGE_BUSY);
    // Too early for the next generation.
    let open = op(wire::COMMAND, command::OPEN_GENERATION, 0, |o| {
        o.u32(param::open_generation::CORPORATION_ID, 40);
    });
    let r = k.judge(&open, &ctx()).unwrap_err();
    assert_eq!((r.code, r.data["days_left"].as_i64()), (refusal::COOLDOWN, Some(80)));

    // Past the window: writes wait, the next generation opens additive.
    let mut a = app(1, S::DRAFT_READY, "Acme");
    a.corp = Some(40);
    let mut late = kernel(&[a], &[], &[(7, 40, TODAY - 90, true)]);
    assert_eq!(code(late.judge(&overlay(1, 0), &ctx())), refusal::COOLDOWN);
    let fx = late.judge(&open, &ctx()).unwrap();
    assert_eq!(cell(&fx, table::CV_LINEAGES, col::cv_lineages::GENERATION), Some(&EVal::Val(Val::U32(2))));
    assert_eq!(cell(&fx, table::CV_LINEAGES, col::cv_lineages::REWRITES_ALLOWED), Some(&EVal::Val(Val::U32(0))));
}

#[test]
fn a_predicted_listing_keeps_every_other_rows_stub_and_rolls_back() {
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, 3);
    b.u32s(A::ID, 1..=3)
        .u32s(A::STAGE, (0..3).map(|_| S::DISCOVERED as u32))
        .deferred(A::LISTING_RAW, (0..3).map(|i| Some((100 + i, [i as u8; 8]))));
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.boot(&w.finish(), 1).unwrap();
    let put = op(wire::PUT, table::APPLICATIONS, 1, |o| {
        o.str(A::LISTING_RAW, "Rust kernels");
    });
    k.predict(&put, &ctx()).unwrap();
    let t = k.rows().table(table::APPLICATIONS).unwrap();
    let Val::Deferred(len, _) = t.get(1, A::LISTING_RAW) else { panic!("row 1 is not a stub") };
    assert_eq!(len, 12);
    assert_eq!(t.get(2, A::LISTING_RAW), Val::Deferred(101, [1; 8]));
    // A put of the wrong kind for a column changes nothing.
    k.predict(&op(wire::PUT, table::APPLICATIONS, 2, |o| { o.u32(A::COMPANY, 5); }), &ctx()).unwrap();
    assert_eq!(k.rows().table(table::APPLICATIONS).unwrap().get(3, A::LISTING_RAW), Val::Deferred(102, [2; 8]));
    // The server refuses the listing (op 77): its writes go, the stub returns.
    k.ingest(&wire::encode_nacks(schema::WIRE_HASH, 2, &[wire::Nack { op_id: 77, code: 0, data: b"{}" }])).unwrap();
    assert_eq!(k.rows().table(table::APPLICATIONS).unwrap().get(1, A::LISTING_RAW), Val::Deferred(100, [0; 8]));
}

#[test]
fn a_keyed_put_is_predicted_where_the_server_puts_it() {
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, 1);
    b.u32s(A::ID, [4].into_iter()).u32s(A::STAGE, [S::GATED as u32].into_iter()).strs(A::CANONICAL_URL, ["https://acme.example/1"].into_iter());
    b.done();
    let mut k = Kernel::new();
    k.boot(&w.finish(), 1).unwrap();
    let mut ow = wire::OpsWriter::new();
    ow.op(9, wire::PUT, wire::KEYED, table::APPLICATIONS, 0, None).str(A::CANONICAL_URL, "https://acme.example/1").u32(A::SCORE_100, 77);
    let raw = ow.finish()[8..].to_vec();
    k.predict(&raw, &ctx()).unwrap();
    let t = k.rows().table(table::APPLICATIONS).unwrap();
    assert_eq!(t.len(), 1);
    assert_eq!(t.u32(4, A::SCORE_100), Some(77));
}

#[test]
fn a_frame_that_fails_part_way_leaves_nothing_stale() {
    let mut k = kernel(&[app(1, S::GATED, "Acme"), app(2, S::GATED, "Bolt")], &[], &[]);
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, 1);
    b.u32s(A::ID, [1].into_iter()).u32s(A::SCORE_100, [99].into_iter());
    b.done();
    // A keyed table's block with no id column: the body fails after the first block.
    let mut b = w.block(table::EVENTS, 1);
    b.u32s(col::events::APPLICATION_ID, [1].into_iter());
    b.done();
    assert!(k.patch(&w.finish(), 2).is_err());
    assert_eq!(k.board_ids(None)[0], 1);
}

#[test]
fn a_sentinel_cell_is_refused_as_the_server_refuses_it() {
    let mut k = kernel(&[app(1, S::GATED, "Acme")], &[], &[]);
    let put = op(wire::PUT, table::APPLICATIONS, 1, |o| {
        o.u32(A::SCORE_100, wire::NONE);
    });
    assert_eq!(code(k.judge(&put, &ctx())), refusal::TYPE);
    let clear = op(wire::PUT, table::APPLICATIONS, 1, |o| {
        o.null(A::SCORE_100);
    });
    assert!(k.judge(&clear, &ctx()).is_ok());
}
