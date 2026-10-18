//! `Hireme.Kernel.Nif`: the kernel inside the BEAM, one resource per
//! account sequencer. The contract is `Hireme.Kernel`'s (lib/hireme/kernel.ex):
//!
//! - `new()` → an empty resource; `load(res, boot_body)` → `:ok`, the
//!   rows of a BOOT body read from SQLite; `apply(res, patch_body)` →
//!   `:ok`, the PATCH body subscribers get, in the same sequencer turn.
//!   Both, and `board_ids`, run on a dirty CPU scheduler: their cost grows
//!   with the desk.
//! - `judge(res, op, ctx)` and `judge_dirty` (the same on a dirty CPU
//!   scheduler) → `{:ok, effects}` | `{:refused, code, data_json}` |
//!   `{:error, :panic}`. `op` is one op in the OPS layout; `ctx` is
//!   `%{actor: :human | :key, key_id: id | nil, now_day, now_s, held_ids,
//!   ...}`, every key present (`now_day` a day 0..=9999-12-31), else
//!   `badarg`.
//!   `effects` are `[{table_id, row_id, [{col_id, value}]}]` in write
//!   order, `row_id` 0 an insert; a value is an integer, float, binary or
//!   `nil` (bool 0/1, day = days since 0000-01-01 as
//!   `Date.to_gregorian_days/1` counts them, enum = its code), and
//!   a ref to a row inserted by the same effects is `{:new, k}` (the
//!   k-th insert).
//! - `board_ids(res, stage_code | nil)` → application ids in board order
//!   (none for a code that is no stage).
//! - `keywords_version()`.
//! - `unpack(frame, max)` → a ZSTD frame's plain body (at most `max`
//!   bytes) or `nil`: native/wire's reading, the one every client does.
//!
//! A panic in the kernel is caught here and answered `{:error, :panic}`;
//! the sequencer then rebuilds the resource from SQLite.

// `with` turns a kernel panic into `{:error, :panic}` and the sequencer
// rebuilds the resource; under panic=abort that would abort the BEAM.
#[cfg(panic = "abort")]
compile_error!("the NIF catches kernel panics: build it with panic=unwind");

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

use kernel::abi::Kernel;
use kernel::judge::{Ctx, EVal, Row};
use kernel::pipeline::Stage;
use kernel::rows::Val;
use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};

mod atoms {
    rustler::atoms! { ok, error, refused, panic, new, human, key, body, actor, key_id, now_day, now_s, held_ids }
}

pub struct Res(Mutex<Kernel>);

#[rustler::resource_impl]
impl rustler::Resource for Res {}

fn with<T>(res: &Res, f: impl FnOnce(&mut Kernel) -> T) -> Option<T> {
    let mut k = res.0.lock().ok()?;
    catch_unwind(AssertUnwindSafe(|| f(&mut k))).ok()
}

#[rustler::nif]
fn new() -> ResourceArc<Res> {
    ResourceArc::new(Res(Mutex::new(Kernel::new())))
}

/// Loading builds the board and the governor's index too, so the first
/// judge after a (re)build is as fast as any.
#[rustler::nif(schedule = "DirtyCpu")]
fn load<'a>(env: Env<'a>, res: ResourceArc<Res>, boot: Binary<'a>) -> Term<'a> {
    body(env, &res, |k| {
        let ok = k.boot(boot.as_slice(), 0).is_ok();
        k.derive();
        ok
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn apply<'a>(env: Env<'a>, res: ResourceArc<Res>, patch: Binary<'a>) -> Term<'a> {
    body(env, &res, |k| k.patch(patch.as_slice(), 0).is_ok())
}

fn body<'a>(env: Env<'a>, res: &Res, f: impl FnOnce(&mut Kernel) -> bool) -> Term<'a> {
    match with(res, f) {
        Some(true) => atoms::ok().encode(env),
        Some(false) => (atoms::error(), atoms::body()).encode(env),
        None => (atoms::error(), atoms::panic()).encode(env),
    }
}

struct CtxIn {
    human: bool,
    key_id: Option<u32>,
    today: i32,
    now: i64,
    held: Vec<u32>,
}

/// A ctx that is not exactly the documented map is `badarg`: a missing or
/// out-of-range day must never judge as day 0 and persist as a date.
fn ctx_in(t: Term) -> NifResult<CtxIn> {
    let get = |k: Atom| t.map_get(k).map_err(|_| rustler::Error::BadArg);
    let actor: Atom = get(atoms::actor())?.decode()?;
    if actor != atoms::human() && actor != atoms::key() {
        return Err(rustler::Error::BadArg);
    }
    let today: i64 = get(atoms::now_day())?.decode()?;
    let today = i32::try_from(today).ok().filter(|d| (0..=kernel::LAST_DAY).contains(d)).ok_or(rustler::Error::BadArg)?;
    Ok(CtxIn {
        human: actor == atoms::human(),
        key_id: get(atoms::key_id())?.decode()?,
        today,
        now: get(atoms::now_s())?.decode()?,
        held: get(atoms::held_ids())?.decode()?,
    })
}

fn value<'a>(env: Env<'a>, v: &EVal) -> Term<'a> {
    match v {
        EVal::New(k) => (atoms::new(), *k).encode(env),
        EVal::Val(v) => match v {
            Val::None => rustler::types::atom::nil().encode(env),
            Val::U32(x) => x.encode(env),
            Val::I64(x) => x.encode(env),
            Val::F64(x) => x.encode(env),
            Val::Str(s) => s.as_str().encode(env),
            Val::List(l) => l.encode(env),
        },
    }
}

fn effects<'a>(env: Env<'a>, rows: &[Row]) -> Term<'a> {
    let list: Vec<Term> = rows
        .iter()
        .map(|r| {
            let cells: Vec<Term> = r.cells.iter().map(|(c, v)| (*c, value(env, v)).encode(env)).collect();
            (r.table, r.id, cells).encode(env)
        })
        .collect();
    list.encode(env)
}

fn judge_any<'a>(env: Env<'a>, res: &Res, op: Binary, ctx: Term<'a>) -> NifResult<Term<'a>> {
    let c = ctx_in(ctx)?;
    let verdict = with(res, |k| {
        k.pin_today(c.today);
        let ctx = Ctx { today: c.today, now: c.now, human: c.human, key_id: c.key_id, held: &c.held };
        k.judge(op.as_slice(), &ctx)
    });
    Ok(match verdict {
        Some(Ok(rows)) => (atoms::ok(), effects(env, &rows)).encode(env),
        Some(Err(r)) => (atoms::refused(), r.code, r.data.to_string()).encode(env),
        None => (atoms::error(), atoms::panic()).encode(env),
    })
}

#[rustler::nif]
fn judge<'a>(env: Env<'a>, res: ResourceArc<Res>, op: Binary, ctx: Term<'a>) -> NifResult<Term<'a>> {
    judge_any(env, &res, op, ctx)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn judge_dirty<'a>(env: Env<'a>, res: ResourceArc<Res>, op: Binary, ctx: Term<'a>) -> NifResult<Term<'a>> {
    judge_any(env, &res, op, ctx)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn board_ids(res: ResourceArc<Res>, stage: Option<u32>) -> Vec<u32> {
    with(&res, |k| match stage.map(|s| u8::try_from(s).ok().and_then(Stage::from_u8)) {
        Some(None) => Vec::new(),
        stage => k.board_ids(stage.flatten()),
    })
    .unwrap_or_default()
}

#[rustler::nif]
fn keywords_version() -> u32 {
    kernel::keywords::VERSION
}

#[rustler::nif(schedule = "DirtyCpu")]
fn unpack<'a>(env: Env<'a>, frame: Binary<'a>, max: usize) -> Option<Binary<'a>> {
    let body = wire::Frame::parse(frame.as_slice(), schema::WIRE_HASH).ok()?.body_max(max).ok()?;
    let mut out = rustler::OwnedBinary::new(body.len())?;
    out.as_mut_slice().copy_from_slice(&body);
    Some(out.release(env))
}

rustler::init!("Elixir.Hireme.Kernel.Nif");
