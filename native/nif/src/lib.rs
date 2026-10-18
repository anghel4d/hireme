//! `Hireme.Kernel.Nif`: the kernel inside the BEAM, one resource per
//! account sequencer. The contract is `Hireme.Kernel`'s (lib/hireme/kernel.ex):
//!
//! - `new()` → an empty resource; `load(res, boot_body)` → `:ok`, the
//!   rows of a BOOT body read from SQLite; `apply(res, patch_body)` →
//!   `:ok`, the PATCH body subscribers get, in the same sequencer turn.
//! - `judge(res, op, ctx)` and `judge_dirty` (the same on a dirty CPU
//!   scheduler) → `{:ok, effects}` | `{:refused, code, data_json}` |
//!   `{:error, :panic}`. `op` is one op in the OPS layout; `ctx` is
//!   `%{actor: :human | :key, key_id, now_day, now_s, held_ids, ...}`.
//!   `effects` are `[{table_id, row_id, [{col_id, value}]}]` in write
//!   order, `row_id` 0 an insert; a value is an integer, float, binary or
//!   `nil` (bool 0/1, day = days since 1970-01-01, enum = its code), and
//!   a ref to a row inserted in the same effects is `0` (the op's own
//!   insert) or `{:new, k}` (the k-th insert).
//! - `board_ids(res, stage_code | nil)` → application ids in board order.
//! - `keywords_version()`.
//!
//! A panic in the kernel is caught here and answered `{:error, :panic}`;
//! the sequencer then rebuilds the resource from SQLite.

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
    // A poisoned lock means a panic mid-write; the caller rebuilds.
    let mut k = res.0.lock().ok()?;
    catch_unwind(AssertUnwindSafe(|| f(&mut k))).ok()
}

#[rustler::nif]
fn new() -> ResourceArc<Res> {
    ResourceArc::new(Res(Mutex::new(Kernel::new())))
}

#[rustler::nif]
fn load<'a>(env: Env<'a>, res: ResourceArc<Res>, boot: Binary<'a>) -> Term<'a> {
    body(env, &res, |k| k.boot(boot.as_slice(), 0).is_ok())
}

#[rustler::nif]
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

fn ctx_in(t: Term) -> NifResult<CtxIn> {
    let get = |k: Atom| t.map_get(k).ok();
    let actor: Atom = get(atoms::actor()).map(|v| v.decode()).transpose()?.unwrap_or(atoms::key());
    Ok(CtxIn {
        human: actor == atoms::human(),
        key_id: get(atoms::key_id()).and_then(|v| v.decode::<u32>().ok()),
        today: get(atoms::now_day()).map(|v| v.decode::<i64>()).transpose()?.unwrap_or(0) as i32,
        now: get(atoms::now_s()).map(|v| v.decode::<i64>()).transpose()?.unwrap_or(0),
        held: get(atoms::held_ids()).and_then(|v| v.decode::<Vec<u32>>().ok()).unwrap_or_default(),
    })
}

fn value<'a>(env: Env<'a>, v: &EVal) -> Term<'a> {
    match v {
        EVal::Own => 0u32.encode(env),
        EVal::New(k) => (atoms::new(), *k).encode(env),
        EVal::Val(v) => match v {
            Val::None => rustler::types::atom::nil().encode(env),
            Val::U32(x) => x.encode(env),
            Val::I64(x) => x.encode(env),
            Val::F64(x) => x.encode(env),
            Val::Str(s) => s.as_str().encode(env),
            Val::Deferred(n, _) => n.encode(env),
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
        k.set_today(c.today);
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

#[rustler::nif]
fn board_ids(res: ResourceArc<Res>, stage: Option<u8>) -> Vec<u32> {
    with(&res, |k| k.board_ids(stage.and_then(Stage::from_u8))).unwrap_or_default()
}

#[rustler::nif]
fn keywords_version() -> u32 {
    kernel::keywords::VERSION
}

rustler::init!("Elixir.Hireme.Kernel.Nif");
