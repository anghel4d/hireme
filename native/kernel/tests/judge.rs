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
    let Some(EVal::Val(Val::Str(sha))) = cell(&fx, table::APPLICATIONS, A::LISTING_SHA) else { panic!("no sha") };
    assert_eq!(sha.len(), 64);
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
