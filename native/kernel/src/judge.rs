//! The domain check of every write (step 4 of the sequencer's checks)
//! and what the write becomes.
//!
//! `judge` takes one op in the OPS layout and the rows it lands on, and
//! answers either a refusal (a code from the schema's `refusal` enum and
//! its data) or the op's effects: the rows to write, in order, with every
//! derived cell, so the sequencer persists exactly what the kernel
//! decided and no rule lives anywhere else. The browser and `hireme-mcp`
//! call the same function on the same rows to predict the verdict.
//!
//! Grants, the lease, the op's shape, provenance and limits are the
//! sequencer's own checks (1–3, 5, 6) and are not repeated here; a put
//! on a table with no domain rule (the world and mail tables) comes back
//! as its own cells.
//!
//! Effects are rows in write order. The op's own row is the one on the
//! op's table (its target; id 0 is the op's insert), and no other effect
//! row touches that table; a drop has no own row, its deletion is the
//! sequencer's. Any other row with id 0 is a fresh insert. A ref cell to a
//! row inserted by the same effects holds [`EVal::New`]`(k)`, the id of
//! the k-th insert among the effect rows (0-based, the op's own insert
//! counted); a referenced row always comes before its referrer.
//!
//! Refusal data, by code:
//!
//! | code | data |
//! | --- | --- |
//! | `stage` | `{from, to, rule}`, rule one of `needs_batch`, `open_fire_by_command`, `sent`, `not_fire_ready` |
//! | `fire_hold` | `{from, to}` |
//! | `heat` | the governor's verdict plus `to`; or `{need: "reason"}` for a blank override |
//! | `lineage_busy` | `{lineage_id, generation}`: rewrites are off, only new overlays |
//! | `cooldown` | `{lineage_id, opened_on, days_left}` (open_generation too early), or `{lineage_id, opened_on, need: "open_generation"}` (the window has passed) |
//! | `not_found` | `{table, id}` or `{need}` |

use alloc::string::String;
use alloc::vec::Vec;

use schema::col::applications as A;
use schema::{col, command, enums, param, refusal, table};
use serde_json::{json, Value as Json};
use wire::Op;

use crate::board::{self, Board};
use crate::heat;
use crate::pipeline::{self, Stage};
use crate::rows::{Rows, Table, Val};
use crate::{cv, keywords, Day};

/// Who is writing and when.
#[derive(Clone, Copy, Debug)]
pub struct Ctx<'a> {
    pub today: Day,
    /// Unix seconds.
    pub now: i64,
    /// A browser session (the operator), not a key.
    pub human: bool,
    pub key_id: Option<u32>,
    /// Application ids the session's lease holds.
    pub held: &'a [u32],
}

/// A cell value in an effect.
#[derive(Clone, Debug, PartialEq)]
pub enum EVal {
    Val(Val),
    /// The id the k-th insert of this effect list gets.
    New(u32),
}

impl From<Val> for EVal {
    fn from(v: Val) -> EVal {
        EVal::Val(v)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub table: u16,
    /// 0 inserts.
    pub id: u32,
    pub cells: Vec<(u16, EVal)>,
}

impl Row {
    fn set(&mut self, col: u16, v: impl Into<EVal>) {
        let v = v.into();
        match self.cells.iter_mut().find(|c| c.0 == col) {
            Some(c) => c.1 = v,
            None => self.cells.push((col, v)),
        }
    }

    fn get(&self, col: u16) -> Option<&EVal> {
        self.cells.iter().find(|c| c.0 == col).map(|c| &c.1)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Refusal {
    pub code: u16,
    pub data: Json,
}

pub type Verdict = Result<Vec<Row>, Refusal>;

fn refuse(code: u16, data: Json) -> Verdict {
    Err(Refusal { code, data })
}

fn not_found(t: u16, id: u32) -> Verdict {
    let name = schema::table_def(t).map_or("", |d| d.name);
    refuse(refusal::NOT_FOUND, json!({"table": name, "id": id}))
}

fn u(v: u32) -> Val {
    Val::U32(v)
}

fn s(v: impl Into<String>) -> Val {
    let v = v.into();
    if v.is_empty() { Val::None } else { Val::Str(v) }
}

fn day_val(d: Day) -> Val {
    Val::U32(d as u32)
}

/// The op's cells as values; the reserved provenance cells are left out
/// (they are the sequencer's).
fn cells(op: &Op) -> Vec<(u16, Val)> {
    op.cells().filter(|c| c.col < schema::FREE_PARAM).map(|c| (c.col, Val::from_wire(c.value()))).collect()
}

fn param_val(op: &Op, id: u16) -> Val {
    op.cell(id).map_or(Val::None, |c| Val::from_wire(c.value()))
}

fn param_str(op: &Op, id: u16) -> Option<String> {
    match param_val(op, id) {
        Val::Str(s) => Some(s),
        _ => None,
    }
}

/// Judges one op. `board` supplies the cached governor seats; it must
/// have been told (`Board::forget`) about every write since its last use.
pub fn judge(rows: &Rows, board: &mut Board, raw: &[u8], ctx: &Ctx) -> Verdict {
    let Ok(op) = Op::one(raw) else {
        return refuse(refusal::TYPE, json!({"op": "malformed"}));
    };
    // A cell holding its type's null sentinel is refused, not read as a
    // clear, exactly as the sequencer's shape check refuses it.
    if let Some(c) = op.cells().find(|c| c.is_sentinel()) {
        return refuse(refusal::TYPE, json!({"column": c.col, "sentinel": true}));
    }
    match op.verb {
        wire::PUT => put(rows, board, &op, ctx),
        wire::DROP => drop(rows, &op, ctx),
        wire::COMMAND => run(rows, board, &op, ctx),
        _ => refuse(refusal::TYPE, json!({"verb": op.verb})),
    }
}

fn own(op: &Op, cells: Vec<(u16, Val)>) -> Row {
    Row { table: op.table, id: op.target, cells: cells.into_iter().map(|(c, v)| (c, EVal::Val(v))).collect() }
}

fn event(application: EVal, kind: &str, body: String, op: &Op, ctx: &Ctx) -> Row {
    let actor = if ctx.human { enums::actor::OPERATOR } else { enums::actor::AGENT };
    Row {
        table: table::EVENTS,
        id: 0,
        cells: alloc::vec![
            (col::events::APPLICATION_ID, application),
            (col::events::KIND, s(kind).into()),
            (col::events::BODY, s(body).into()),
            (col::events::ACTOR, u(actor as u32).into()),
            (col::events::KEY_ID, ctx.key_id.map_or(Val::None, u).into()),
            (col::events::OP_ID, Val::I64(op.op_id as i64).into()),
        ],
    }
}

fn put(rows: &Rows, board: &mut Board, op: &Op, ctx: &Ctx) -> Verdict {
    let c = cells(op);
    let mut row = own(op, c);
    let mut extra = Vec::new();
    match op.table {
        table::APPLICATIONS => {
            let apps = rows.table(table::APPLICATIONS);
            if op.target != 0 && !apps.is_some_and(|t| t.has(op.target)) {
                return not_found(op.table, op.target);
            }
            if op.target == 0 {
                let stage = Stage::Discovered;
                row.set(A::STAGE, u(stage as u32));
                row.set(A::PIPS, s(core::str::from_utf8(&pipeline::encode(&pipeline::initial(stage))).unwrap_or("")));
                row.set(A::STAGE_ON, day_val(ctx.today));
            } else if let Some(t) = apps {
                // A batched stage keeps its batch.
                if row.get(A::BATCH_ID) == Some(&EVal::Val(Val::None)) {
                    let stage = t.u32(op.target, A::STAGE).and_then(|v| u8::try_from(v).ok().and_then(Stage::from_u8));
                    if let Some(st) = stage.filter(|s| s.batched()) {
                        return refuse(refusal::STAGE, json!({"from": st.name(), "to": st.name(), "rule": "needs_batch"}));
                    }
                }
            }
            if let Some(EVal::Val(v)) = row.get(A::LISTING_RAW).cloned() {
                match v {
                    Val::Str(text) => {
                        // The format the op sets, else the row's.
                        let format = match row.get(A::LISTING_FORMAT) {
                            Some(EVal::Val(Val::U32(f))) => Some(*f),
                            _ => apps.and_then(|t| t.u32(op.target, A::LISTING_FORMAT)),
                        };
                        let words = keywords::extract(&text, keywords::Format::from_code(format));
                        row.set(A::KEYWORDS, s(keywords::join(&words)));
                        row.set(A::KEYWORDS_VERSION, u(keywords::VERSION));
                    }
                    _ => {
                        row.set(A::KEYWORDS, Val::None);
                        row.set(A::KEYWORDS_VERSION, Val::None);
                    }
                }
            }
        }
        table::CV_OVERLAYS => overlay(rows, board, op, ctx, &mut row, &mut extra)?,
        table::CV_LINEAGES => {
            let t = rows.table(table::CV_LINEAGES);
            if op.target == 0 {
                row.set(col::cv_lineages::GENERATION, u(1));
                row.set(col::cv_lineages::OPENED_ON, day_val(ctx.today));
            } else if let Some(t) = t {
                if !t.has(op.target) {
                    return not_found(op.table, op.target);
                }
                // Turning rewrites back on would let a later application
                // reword what an earlier one sent.
                let was = t.u32(op.target, col::cv_lineages::REWRITES_ALLOWED) == Some(1);
                if !was && row.get(col::cv_lineages::REWRITES_ALLOWED) == Some(&EVal::Val(u(1))) {
                    return refuse(
                        refusal::LINEAGE_BUSY,
                        json!({"lineage_id": op.target, "generation": t.u32(op.target, col::cv_lineages::GENERATION)}),
                    );
                }
            }
        }
        _ => {}
    }
    // Rows the op's row refers to come first.
    let mut out = extra;
    out.push(row);
    Ok(out)
}

/// The lineage rule on an overlay write, and the overlay's lineage and
/// generation. A corporation's first overlay opens its lineage.
fn overlay(rows: &Rows, board: &mut Board, op: &Op, ctx: &Ctx, row: &mut Row, extra: &mut Vec<Row>) -> Result<(), Refusal> {
    use col::cv_overlays as O;
    let existing = rows.table(table::CV_OVERLAYS);
    let inserting = op.target == 0;
    if !inserting && !existing.is_some_and(|t| t.has(op.target)) {
        return Err(Refusal { code: refusal::NOT_FOUND, data: json!({"table": "cv_overlays", "id": op.target}) });
    }
    let app = match row.get(O::APPLICATION_ID) {
        Some(EVal::Val(Val::U32(a))) => Some(*a),
        _ => existing.and_then(|t| t.u32(op.target, O::APPLICATION_ID)),
    };
    let Some(app) = app else {
        return Err(Refusal { code: refusal::NOT_FOUND, data: json!({"need": "application_id"}) });
    };
    let Some(corp) = rows.table(table::APPLICATIONS).and_then(|t| t.u32(app, A::CORPORATION_ID)) else {
        return Err(Refusal { code: refusal::NOT_FOUND, data: json!({"need": "corporation_id", "application_id": app}) });
    };
    match lineage_of(rows, board, corp) {
        Some((t, lid)) => {
            let opened = t.u32(lid, col::cv_lineages::OPENED_ON).unwrap_or(0) as Day;
            let rewrites = t.u32(lid, col::cv_lineages::REWRITES_ALLOWED) == Some(1);
            let generation = t.u32(lid, col::cv_lineages::GENERATION).unwrap_or(1);
            // Creating means a line no application of the lineage has
            // overlaid yet; overlaying it again is a rewrite.
            let item = match row.get(O::ITEM_ID) {
                Some(EVal::Val(Val::U32(i))) => Some(*i),
                _ => existing.and_then(|t| t.u32(op.target, O::ITEM_ID)),
            };
            let told = item.is_some_and(|i| board.lines(rows).told(lid, i, op.target));
            let creates = inserting && !told;
            match cv::check(cv::phase(opened, rewrites, ctx.today), creates) {
                Ok(()) => {}
                Err(cv::Refusal::Cooldown) => {
                    return Err(Refusal {
                        code: refusal::COOLDOWN,
                        data: json!({"lineage_id": lid, "opened_on": opened, "need": "open_generation"}),
                    });
                }
                Err(cv::Refusal::Additive) => {
                    return Err(Refusal { code: refusal::LINEAGE_BUSY, data: json!({"lineage_id": lid, "generation": generation}) });
                }
            }
            row.set(O::LINEAGE_ID, u(lid));
            if inserting {
                row.set(O::GENERATION, u(generation));
            }
        }
        None => {
            extra.push(Row {
                table: table::CV_LINEAGES,
                id: 0,
                cells: alloc::vec![
                    (col::cv_lineages::CORPORATION_ID, u(corp).into()),
                    (col::cv_lineages::GENERATION, u(1).into()),
                    (col::cv_lineages::OPENED_ON, day_val(ctx.today).into()),
                    (col::cv_lineages::REWRITES_ALLOWED, u(1).into()),
                ],
            });
            // The lineage row is written first: insert 0.
            row.set(O::LINEAGE_ID, EVal::New(0));
            if inserting {
                row.set(O::GENERATION, u(1));
            }
        }
    }
    Ok(())
}

fn lineage_of<'r>(rows: &'r Rows, board: &mut Board, corporation: u32) -> Option<(&'r Table, u32)> {
    let id = board.lines(rows).lineage(corporation)?;
    rows.table(table::CV_LINEAGES).filter(|t| t.has(id)).map(|t| (t, id))
}

fn drop(rows: &Rows, op: &Op, ctx: &Ctx) -> Verdict {
    if op.table == table::CV_OVERLAYS {
        let Some(t) = rows.table(table::CV_OVERLAYS).filter(|t| t.has(op.target)) else {
            return not_found(op.table, op.target);
        };
        if let Some(lid) = t.u32(op.target, col::cv_overlays::LINEAGE_ID) {
            if let Some(l) = rows.table(table::CV_LINEAGES).filter(|l| l.has(lid)) {
                let opened = l.u32(lid, col::cv_lineages::OPENED_ON).unwrap_or(0) as Day;
                let rewrites = l.u32(lid, col::cv_lineages::REWRITES_ALLOWED) == Some(1);
                match cv::check(cv::phase(opened, rewrites, ctx.today), false) {
                    Ok(()) => {}
                    Err(cv::Refusal::Cooldown) => {
                        return refuse(refusal::COOLDOWN, json!({"lineage_id": lid, "opened_on": opened, "need": "open_generation"}));
                    }
                    Err(cv::Refusal::Additive) => {
                        let generation = l.u32(lid, col::cv_lineages::GENERATION);
                        return refuse(refusal::LINEAGE_BUSY, json!({"lineage_id": lid, "generation": generation}));
                    }
                }
            }
        }
    }
    Ok(Vec::new())
}

fn app_stage(t: &Table, id: u32) -> Stage {
    t.u32(id, A::STAGE).and_then(|v| u8::try_from(v).ok().and_then(Stage::from_u8)).unwrap_or(Stage::Discovered)
}

/// The cells a move to `to` writes on the application, and its event.
fn moved(t: &Table, id: u32, from: Stage, to: Stage, note: Option<String>, op: &Op, ctx: &Ctx) -> Vec<Row> {
    let rail = pipeline::move_to(&pipeline::rail_of(from, t.str(id, A::PIPS)), to);
    let mut row = Row { table: table::APPLICATIONS, id, cells: Vec::new() };
    if from != to {
        row.set(A::STAGE, u(to as u32));
        row.set(A::PIPS, s(core::str::from_utf8(&pipeline::encode(&rail)).unwrap_or("")));
        row.set(A::STAGE_ON, day_val(ctx.today));
        let first = |c: u16| t.u32(id, c).is_none();
        if to == Stage::Submitted && first(A::APPLIED_ON) {
            row.set(A::APPLIED_ON, day_val(ctx.today));
        }
        if to == Stage::Reply && first(A::REPLIED_ON) {
            row.set(A::REPLIED_ON, day_val(ctx.today));
        }
        if to == Stage::Closed && first(A::CLOSED_ON) {
            row.set(A::CLOSED_ON, day_val(ctx.today));
        }
        // Reopened: it is no longer closed. What was sent and replied to
        // stays recorded.
        if from == Stage::Closed {
            row.set(A::CLOSED_ON, Val::None);
        }
    }
    let note = note.as_deref().map(str::trim).filter(|n| !n.is_empty());
    // A move to where it stands, with nothing to say, is nothing.
    if from == to && note.is_none() {
        return Vec::new();
    }
    if let Some(n) = note {
        row.set(A::STAGE_NOTES, s(with_note(t.str(id, A::STAGE_NOTES), to, n)));
    }
    let mut body = alloc::format!("{} → {}", from.name(), to.name());
    if let Some(n) = note {
        body.push_str(" · ");
        body.push_str(n);
    }
    let mut out = alloc::vec![row];
    out.push(event(u(id).into(), "stage", body, op, ctx));
    out
}

/// `stage_notes` (a JSON object, stage name → note) with one note set.
fn with_note(json: Option<&str>, stage: Stage, note: &str) -> String {
    let mut m = match json.map(serde_json::from_str::<Json>) {
        Some(Ok(Json::Object(m))) => m,
        _ => serde_json::Map::new(),
    };
    m.insert(stage.name().into(), Json::String(note.into()));
    Json::Object(m).to_string()
}

fn run(rows: &Rows, board: &mut Board, op: &Op, ctx: &Ctx) -> Verdict {
    // A required param that is absent (an empty string is a null) is the
    // sequencer's shape refusal; answering it the same way keeps a
    // prediction and its verdict one thing.
    if let Some(def) = schema::command_def(op.table) {
        let missing: Vec<&str> = def
            .params
            .iter()
            .filter(|p| p.required && op.cell(p.id).is_none_or(|c| Val::from_wire(c.value()).is_none()))
            .map(|p| p.name)
            .collect();
        if !missing.is_empty() {
            return refuse(refusal::COLUMN, json!({"command": def.name, "missing": missing}));
        }
    }
    match op.table {
        command::STAGE => {
            let Some(t) = rows.table(table::APPLICATIONS).filter(|t| t.has(op.target)) else {
                return not_found(table::APPLICATIONS, op.target);
            };
            let Some(to) = (match param_val(op, param::stage::STAGE) {
                Val::U32(v) => u8::try_from(v).ok().and_then(Stage::from_u8),
                _ => None,
            }) else {
                return refuse(refusal::TYPE, json!({"param": "stage"}));
            };
            let id = op.target;
            let from = app_stage(t, id);
            let batch = t.u32(id, A::BATCH_ID);
            let fire = batch
                .and_then(|b| rows.table(table::BATCHES).and_then(|bt| bt.u32(b, col::batches::FIRE)))
                == Some(enums::fire::OPEN_FIRE as u32);
            let outreach = t.u32(id, A::CHANNEL).is_some_and(|c| c != enums::app_channel::LISTING as u32);
            if let Err(r) = pipeline::check(from, to, batch.is_some(), fire, board::sent(t, id), outreach) {
                let code = if r == pipeline::Refusal::FireHold { refusal::FIRE_HOLD } else { refusal::STAGE };
                return refuse(code, json!({"from": from.name(), "to": to.name(), "rule": r.name()}));
            }
            if !from.queued() && to.queued() {
                governor(rows, board, id, to, ctx)?;
            }
            Ok(moved(t, id, from, to, param_str(op, param::stage::NOTE), op, ctx))
        }
        command::NOTE => {
            let Some(t) = rows.table(table::APPLICATIONS).filter(|t| t.has(op.target)) else {
                return not_found(table::APPLICATIONS, op.target);
            };
            let Some(stage) = (match param_val(op, param::note::STAGE) {
                Val::U32(v) => u8::try_from(v).ok().and_then(Stage::from_u8),
                _ => None,
            }) else {
                return refuse(refusal::TYPE, json!({"param": "stage"}));
            };
            let body = param_str(op, param::note::BODY).unwrap_or_default();
            let mut row = Row { table: table::APPLICATIONS, id: op.target, cells: Vec::new() };
            row.set(A::STAGE_NOTES, s(with_note(t.str(op.target, A::STAGE_NOTES), stage, body.trim())));
            let ev = event(u(op.target).into(), "note", alloc::format!("{} · {}", stage.name(), body.trim()), op, ctx);
            Ok(alloc::vec![row, ev])
        }
        command::HEAT_OVERRIDE => {
            if !rows.table(table::APPLICATIONS).is_some_and(|t| t.has(op.target)) {
                return not_found(table::APPLICATIONS, op.target);
            }
            let reason = param_str(op, param::heat_override::REASON).unwrap_or_default();
            let reason = reason.trim();
            if reason.is_empty() {
                return refuse(refusal::HEAT, json!({"need": "reason"}));
            }
            let row = Row {
                table: table::APPLICATIONS,
                id: op.target,
                cells: alloc::vec![(A::HEAT_OVERRIDE, u(1).into()), (A::HEAT_OVERRIDE_REASON, s(reason).into())],
            };
            Ok(alloc::vec![row, event(u(op.target).into(), "heat", alloc::format!("HEAT OVERRIDE · {reason}"), op, ctx)])
        }
        command::OPEN_FIRE => {
            let Some(t) = rows.table(table::APPLICATIONS).filter(|t| t.has(op.target)) else {
                return not_found(table::APPLICATIONS, op.target);
            };
            let from = app_stage(t, op.target);
            if !pipeline::opens(from) {
                return refuse(
                    refusal::STAGE,
                    json!({"from": from.name(), "to": Stage::OpenFire.name(), "rule": "not_fire_ready"}),
                );
            }
            Ok(moved(t, op.target, from, Stage::OpenFire, None, op, ctx))
        }
        command::OPEN_GENERATION => {
            let corp = match param_val(op, param::open_generation::CORPORATION_ID) {
                Val::U32(c) => Some(c),
                _ => None,
            };
            let found = match corp {
                Some(c) => lineage_of(rows, board, c),
                None => rows.table(table::CV_LINEAGES).filter(|t| t.has(op.target)).map(|t| (t, op.target)),
            };
            let Some((t, lid)) = found else {
                return refuse(refusal::NOT_FOUND, json!({"table": "cv_lineages", "corporation_id": corp}));
            };
            let opened = t.u32(lid, col::cv_lineages::OPENED_ON).unwrap_or(0) as Day;
            let left = cv::days_to_open(opened, ctx.today);
            if left > 0 {
                return refuse(refusal::COOLDOWN, json!({"lineage_id": lid, "opened_on": opened, "days_left": left}));
            }
            let generation = t.u32(lid, col::cv_lineages::GENERATION).unwrap_or(1);
            Ok(alloc::vec![Row {
                table: table::CV_LINEAGES,
                id: lid,
                cells: alloc::vec![
                    (col::cv_lineages::GENERATION, u(generation + 1).into()),
                    (col::cv_lineages::OPENED_ON, day_val(ctx.today).into()),
                    (col::cv_lineages::REWRITES_ALLOWED, u(0).into()),
                ],
            }])
        }
        other => refuse(refusal::NOT_FOUND, json!({"command": other})),
    }
}

/// The heat governor on an application entering the queue.
fn governor(rows: &Rows, board: &mut Board, id: u32, to: Stage, ctx: &Ctx) -> Result<(), Refusal> {
    let Some(t) = rows.table(table::APPLICATIONS) else { return Ok(()) };
    let Some(seat) = board::seat(t, id) else { return Ok(()) };
    let (ix, _) = board.governor(rows, ctx.today);
    let mut v = heat::verdict(ix, &seat, &[]);
    if v.allow {
        return Ok(());
    }
    v.cooldown_days = heat::cooldown(ix, &seat, &[]);
    let mut data = v.to_json(&seat);
    data["to"] = Json::String(to.name().into());
    Err(Refusal { code: refusal::HEAT, data })
}
