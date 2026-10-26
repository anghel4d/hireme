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
//! - The wire's bytes for `HiremeWeb.Wire.Codec`, which keeps only the
//!   node's packing (OTP's zstd) and the Elixir types of cells: frames,
//!   small frames, ops and table-run blocks are native/wire's, the one
//!   implementation every client reads. Each is a normal scheduler's
//!   microseconds; `unpack` and `block_dirty`, whose cost grows with a
//!   desk, run on a dirty CPU scheduler.
//!
//! A panic in the kernel is caught here and answered `{:error, :panic}`;
//! the sequencer then rebuilds the resource from SQLite.

// `with` turns a kernel panic into `{:error, :panic}` and the sequencer
// rebuilds the resource; under panic=abort that would abort the BEAM.
#[cfg(panic = "abort")]
compile_error!("the NIF catches kernel panics: build it with panic=unwind");

use std::cell::RefCell;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use kernel::abi::Kernel;
use kernel::judge::{Ctx, EVal, Row};
use kernel::pipeline::Stage;
use kernel::rows::Val;
use mcp::session::{Effect, Event, Host, Outcome, Session, Step, Submitted, Verdict};
use mcp::tools::Masks;
use rustler::{Atom, Binary, Encoder, Env, NifResult, ResourceArc, Term};
use serde_json::Value as Json;

mod atoms {
    rustler::atoms! { ok, error, refused, panic, new, human, key, body, actor, key_id, now_day, now_s, held_ids, answer, pending, wait, submit, claim, release, blob, check, lost, none,
    len, hash, kind, ticket, nan, put, drop, command }
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
            Val::Packed(p) => kernel::rows::unpack(p).map(|t| t.into_owned()).encode(env),
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
    with(&res, |k| match stage.map(Stage::from_u32) {
        Some(None) => Vec::new(),
        stage => k.board_ids(stage.flatten()),
    })
    .unwrap_or_default()
}

#[rustler::nif]
fn keywords_version() -> u32 {
    kernel::keywords::VERSION
}

/// One posting's URL however it was linked (kernel::ats::canonical); nil for no web URL.
#[rustler::nif]
fn canonical(url: &str) -> Option<String> {
    kernel::ats::canonical(url)
}

/// A mail's Message-ID as the outreach judge stores it (kernel::outreach::message_id_form); "" for none.
#[rustler::nif]
fn message_id(id: &str) -> String {
    kernel::outreach::message_id_form(id)
}

// ------------------------------------------------------------------ wire

fn bin<'a>(env: Env<'a>, bytes: &[u8]) -> NifResult<Binary<'a>> {
    let mut out = rustler::OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
    out.as_mut_slice().copy_from_slice(bytes);
    Ok(out.release(env))
}

/// `part`, a slice of `whole`, as a sub-binary of it: nothing copied.
fn sub<'a>(whole: &Binary<'a>, part: &[u8]) -> NifResult<Binary<'a>> {
    whole.make_subbinary(part.as_ptr() as usize - whole.as_slice().as_ptr() as usize, part.len())
}

/// A whole frame of `body`: the header with `flags`, the body, zero pad to 8. `packed`, the body as one zstd
/// frame, travels instead when it is the shorter, flagged ZSTD, after `u32 raw_len | u32 packed_len`.
#[rustler::nif]
fn frame<'a>(env: Env<'a>, kind: u8, flags: u8, rev: u64, body: Binary, packed: Option<Binary>) -> NifResult<Binary<'a>> {
    let mut w = wire::Writer::new(kind, schema::WIRE_HASH, rev);
    let packed = packed.filter(|z| wire::pad8(8 + z.len()) < body.len());
    match &packed {
        Some(z) => w.u32(body.len() as u32).u32(z.len() as u32).bytes(z.as_slice()),
        None => w.bytes(body.as_slice()),
    };
    let mut frame = w.finish();
    frame[5] = flags | if packed.is_some() { wire::ZSTD } else { 0 };
    bin(env, &frame)
}

/// A whole frame's header, checked as `Frame::parse` checks one but by direction: a peer's (`up`) may
/// flag ATOMIC and never ZSTD, the node's never ATOMIC. `{kind, flags, rev, body as sent}` or `{:error, why}`.
#[rustler::nif]
fn open<'a>(env: Env<'a>, frame: Binary<'a>, up: bool) -> NifResult<Term<'a>> {
    let b = frame.as_slice();
    let allowed = if up { wire::END | wire::ATOMIC } else { wire::ZSTD | wire::END };
    let why = match wire::Header::peek(b) {
        Ok(h) if h.len as usize != b.len() => atoms::len(),
        Ok(h) if h.hash != schema::WIRE_HASH => atoms::hash(),
        Ok(h) if !wire::KINDS.contains(&h.kind) => atoms::kind(),
        Ok(h) if h.flags & !allowed != 0 => atoms::body(),
        Ok(h) => return Ok((h.kind, h.flags, h.rev, sub(&frame, &b[wire::HEADER..])?).encode(env)),
        Err(_) => atoms::len(),
    };
    Ok((atoms::error(), why).encode(env))
}

/// A ZSTD frame's plain body, at most `max` bytes, or nil.
#[rustler::nif(schedule = "DirtyCpu")]
fn unpack<'a>(env: Env<'a>, frame: Binary<'a>, max: usize) -> Option<Binary<'a>> {
    bin(env, &wire::Frame::parse(frame.as_slice(), schema::WIRE_HASH).ok()?.body_max(max).ok()?).ok()
}

#[derive(rustler::NifMap)]
struct HelloMap<'a> {
    cred: Atom,
    snapshot_rev: u64,
    schema_rev: u64,
    credential: Binary<'a>,
    label: &'a str,
}

/// HELLO's body: `{:ok, %{cred: :ticket | :key, snapshot_rev, schema_rev, credential, label}}` or `{:error, :body}`.
#[rustler::nif]
fn hello<'a>(env: Env<'a>, body: Binary<'a>) -> NifResult<Term<'a>> {
    let Ok(h) = wire::Hello::decode(body.as_slice()) else { return Ok((atoms::error(), atoms::body()).encode(env)) };
    let cred = if h.cred == wire::CRED_TICKET { atoms::ticket() } else { atoms::key() };
    let hello = HelloMap { cred, snapshot_rev: h.snapshot_rev, schema_rev: h.schema_rev, credential: sub(&body, h.credential)?, label: h.label };
    Ok((atoms::ok(), hello).encode(env))
}

/// RPC's body: `{:ok, id, method, params_json}` or `{:error, :body}`.
#[rustler::nif]
fn rpc<'a>(env: Env<'a>, body: Binary<'a>) -> NifResult<Term<'a>> {
    Ok(match wire::Rpc::decode(body.as_slice()) {
        Ok(r) => (atoms::ok(), r.id, r.method, sub(&body, r.params)?).encode(env),
        Err(_) => (atoms::error(), atoms::body()).encode(env),
    })
}

/// PING's or PONG's body: `{:ok, nonce}` or `{:error, :body}`.
#[rustler::nif]
fn nonce<'a>(env: Env<'a>, body: Binary) -> Term<'a> {
    wire::decode_ping(body.as_slice()).map_or_else(|_| (atoms::error(), atoms::body()).encode(env), |n| (atoms::ok(), n).encode(env))
}

/// A small frame (`kind`) of its fields, a tuple in the layout's order (ACK's and NACK's a list of them,
/// PING's and PONG's the nonce); WELCOME's features are this node's (it takes atomic bursts), BYE is flagged END.
#[rustler::nif]
fn small<'a>(env: Env<'a>, kind: u8, rev: u64, f: Term<'a>) -> NifResult<Binary<'a>> {
    let h = schema::WIRE_HASH;
    let mut frame = match kind {
        wire::HELLO => {
            let (cred, credential, label, snapshot_rev, schema_rev): (u8, Binary, &str, u64, u64) = f.decode()?;
            wire::Hello { cred, snapshot_rev, schema_rev, credential: credential.as_slice(), label }.encode(h)
        }
        wire::WELCOME => {
            let ((account_id, session_id, schema_rev), (read_mask, write_mask, may_delete, lease), label) = f.decode()?;
            wire::Welcome { account_id, session_id, schema_rev, read_mask, write_mask, may_delete, lease, features: wire::FEATURE_ATOMIC, label }.encode(h, rev)
        }
        wire::ACK => {
            let acks: Vec<(u64, u64, u32)> = f.decode()?;
            wire::encode_acks(h, rev, &acks.into_iter().map(|(op_id, rev, id)| wire::Ack { op_id, rev, id }).collect::<Vec<_>>())
        }
        wire::NACK => {
            let nacks: Vec<(u64, u16, Binary)> = f.decode()?;
            wire::encode_nacks(h, rev, &nacks.iter().map(|(op_id, code, data)| wire::Nack { op_id: *op_id, code: *code, data: data.as_slice() }).collect::<Vec<_>>())
        }
        wire::PING | wire::PONG => wire::encode_ping(kind, h, f.decode()?),
        wire::BYE => {
            let (reason, message) = f.decode()?;
            wire::Bye { reason, message }.encode(h, rev)
        }
        wire::RPC => {
            let (id, method, params): (u32, &str, Binary) = f.decode()?;
            wire::Rpc { id, method, params: params.as_slice() }.encode(h)
        }
        wire::REPLY => {
            let (id, ok, json): (u32, bool, Binary) = f.decode()?;
            wire::Reply { id, ok, json: json.as_slice() }.encode(h, rev)
        }
        _ => return Err(rustler::Error::BadArg),
    };
    if kind == wire::BYE {
        frame[5] = wire::END;
    }
    bin(env, &frame)
}

/// Op cells and table-run columns as Elixir gives and takes them: `[{col_id, type, value(s)}]`.
type Cells<'a> = Vec<(u16, u8, Term<'a>)>;

#[derive(rustler::NifMap)]
struct OpMap<'a> {
    op_id: u64,
    verb: Atom,
    keyed: bool,
    create_only: bool,
    expect_rev: Option<u32>,
    subject: u16,
    target: u32,
    cells: Cells<'a>,
    raw: Binary<'a>,
}

/// An op as the sequencer takes it, its `raw` bytes and str cells sub-binaries of `whole`; a cell's value
/// is an integer, a float (`:nan` for one not finite), its UTF-8 (`""` writes NULL), or nil for a null cell.
fn op_map<'a>(env: Env<'a>, whole: &Binary<'a>, op: &wire::Op) -> NifResult<OpMap<'a>> {
    let verb = match op.verb {
        wire::PUT => atoms::put(),
        wire::DROP => atoms::drop(),
        _ => atoms::command(),
    };
    let cells = op
        .cells()
        .map(|c| {
            let v = match c.value() {
                _ if c.ty == wire::STR => sub(whole, c.bytes)?.encode(env),
                wire::Value::U32(v) => v.encode(env),
                wire::Value::I64(v) => v.encode(env),
                wire::Value::F64(v) if v.is_finite() => v.encode(env),
                wire::Value::F64(_) => atoms::nan().encode(env),
                _ => rustler::types::atom::nil().encode(env),
            };
            Ok((c.col, c.ty, v))
        })
        .collect::<NifResult<_>>()?;
    let (op_id, subject, target, raw) = (op.op_id, op.table, op.target, sub(whole, op.raw)?);
    let (keyed, create_only, expect_rev) = (op.has(wire::KEYED), op.has(wire::CREATE_ONLY), op.has(wire::EXPECT_REV).then_some(op.expect_rev));
    Ok(OpMap { op_id, verb, keyed, create_only, expect_rev, subject, target, cells, raw })
}

/// An OPS body, validated whole before any op is taken: `{:ok, [op]}` or `{:error, :body}`.
#[rustler::nif]
fn ops<'a>(env: Env<'a>, body: Binary<'a>) -> NifResult<Term<'a>> {
    let Ok(ops) = wire::Ops::new(body.as_slice()) else { return Ok((atoms::error(), atoms::body()).encode(env)) };
    Ok((atoms::ok(), ops.iter().map(|op| op_map(env, &body, &op)).collect::<NifResult<Vec<_>>>()?).encode(env))
}

/// One op from the start of `bin`: `{:ok, op, rest}`, or `:error` (for a `bin` that is no binary too).
#[rustler::nif]
fn op<'a>(env: Env<'a>, bin: Term<'a>) -> NifResult<Term<'a>> {
    Ok(match bin.decode::<Binary>().map(|b| (wire::Op::parse(b.as_slice()), b)) {
        Ok((Ok((op, rest)), b)) => (atoms::ok(), op_map(env, &b, &op)?, sub(&b, rest)?).encode(env),
        _ => atoms::error().encode(env),
    })
}

/// A float, an integer as one, or `:nan` (nil too: a column's no value).
fn float(t: Term) -> NifResult<f64> {
    match t.decode::<Atom>() {
        Ok(a) if a == atoms::nan() || a == rustler::types::atom::nil() => Ok(f64::NAN),
        _ => t.decode::<f64>().or_else(|_| t.decode::<i64>().map(|i| i as f64)),
    }
}

/// One op's bytes from `{op_id, verb, flags, subject, target, expect_rev | nil, [{col, type, value}]}`: a value
/// past its type is badarg, never wrapped, and a str cell that is not UTF-8 answers nil (which `op` refuses).
#[rustler::nif]
fn encode_op<'a>(env: Env<'a>, op: (u64, Atom, u8, u16, u32, Option<u32>, Cells<'a>)) -> NifResult<Term<'a>> {
    let (op_id, verb, flags, subject, target, expect_rev, cells) = op;
    let verbs = [(atoms::put(), wire::PUT), (atoms::drop(), wire::DROP), (atoms::command(), wire::COMMAND)];
    let verb = verbs.into_iter().find(|(a, _)| *a == verb).ok_or(rustler::Error::BadArg)?.1;
    let mut ops = wire::OpsWriter::new();
    let mut w = ops.op(op_id, verb, flags, subject, target, expect_rev);
    for (col, ty, v) in cells {
        match ty {
            wire::NULL => w.null(col),
            wire::U32 => w.u32(col, v.decode()?),
            wire::I64 => w.i64(col, v.decode()?),
            wire::F64 => w.f64(col, float(v)?),
            wire::STR => match std::str::from_utf8(v.decode::<Binary>()?.as_slice()) {
                Ok(s) => w.str(col, s),
                Err(_) => return Ok(rustler::types::atom::nil().encode(env)),
            },
            _ => return Err(rustler::Error::BadArg),
        };
    }
    w.done();
    Ok(bin(env, &ops.finish()[8..])?.encode(env))
}

/// One table-run block of `cols`, `[{col_id, type, values}]`, every `values` `nrows` long with nil for
/// none: a u32 value its low 32 bits, as a binary segment takes it; a zstr's are cells as they travel.
fn block_any<'a>(env: Env<'a>, table: u16, nrows: usize, cols: Cells<'a>) -> NifResult<Binary<'a>> {
    let mut body = wire::BodyWriter::new();
    let mut b = body.block(table, nrows);
    for (id, ty, vals) in cols {
        match ty {
            wire::U32 => b.u32s(id, vals.decode::<Vec<Option<i64>>>()?.into_iter().map(|v| v.map_or(wire::NONE, |v| v as u32))),
            wire::I64 => b.i64s(id, vals.decode::<Vec<Option<i64>>>()?.into_iter().map(|v| v.unwrap_or(wire::NONE64))),
            wire::F64 => b.f64s(id, vals.decode::<Vec<Term>>()?.into_iter().map(float).collect::<NifResult<Vec<_>>>()?.into_iter()),
            wire::STR => b.strs(id, vals.decode::<Vec<Option<&str>>>()?.into_iter().map(|s| s.unwrap_or(""))),
            wire::ZSTR => b.zstrs(id, vals.decode::<Vec<Binary>>()?.iter().map(|c| c.as_slice())),
            _ => return Err(rustler::Error::BadArg),
        };
    }
    b.done();
    bin(env, &body.finish())
}

#[rustler::nif]
fn block<'a>(env: Env<'a>, table: u16, nrows: usize, cols: Cells<'a>) -> NifResult<Binary<'a>> {
    block_any(env, table, nrows, cols)
}

/// `block` for a desk's table, on a dirty CPU scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn block_dirty<'a>(env: Env<'a>, table: u16, nrows: usize, cols: Cells<'a>) -> NifResult<Binary<'a>> {
    block_any(env, table, nrows, cols)
}

/// A table-run body shuffled for packing (wire::shuffle); None when it does not walk.
fn shuffled<'a>(env: Env<'a>, body: Binary<'a>) -> Option<Binary<'a>> {
    let mut out = rustler::OwnedBinary::new(body.len())?;
    out.as_mut_slice().copy_from_slice(body.as_slice());
    wire::shuffle(out.as_mut_slice()).ok()?;
    Some(out.release(env))
}

#[rustler::nif]
fn shuffle<'a>(env: Env<'a>, body: Binary<'a>) -> Option<Binary<'a>> {
    shuffled(env, body)
}

/// `shuffle` for a desk's BOOT, on a dirty CPU scheduler (a 3 MB body is 2 ms of work).
#[rustler::nif(schedule = "DirtyCpu")]
fn shuffle_dirty<'a>(env: Env<'a>, body: Binary<'a>) -> Option<Binary<'a>> {
    shuffled(env, body)
}

/// A table-run body as a client reads it (the tests play one): `[{table, nrows, [{col, values}]}]` in body
/// order, a value an integer, a float, a string (a zstr's unpacked; nil when it does not unpack), a list of
/// ids, or nil for none; nil for a body that does not walk.
#[rustler::nif(schedule = "DirtyCpu")]
fn blocks<'a>(env: Env<'a>, body: Binary<'a>) -> Option<Term<'a>> {
    let mut texts = wire::Texts::default();
    let mut value = |v: wire::Value| match v {
        wire::Value::U32(x) => x.encode(env),
        wire::Value::I64(x) => x.encode(env),
        wire::Value::F64(x) => x.encode(env),
        wire::Value::Str(s) => s.encode(env),
        wire::Value::ZStr(z) => texts.cell(z).ok().map(|s| s.into_owned()).encode(env),
        wire::Value::List(l) => l.iter().collect::<Vec<u32>>().encode(env),
        wire::Value::None => rustler::types::atom::nil().encode(env),
    };
    let blocks = wire::Blocks::new(body.as_slice()).ok()?.iter();
    let out: Vec<_> = blocks.map(|b| (b.table, b.nrows, b.cols().map(|c| (c.id, (0..c.nrows()).map(|i| value(c.value(i))).collect::<Vec<_>>())).collect::<Vec<_>>())).collect();
    Some(out.encode(env))
}

rustler::init!("Elixir.Hireme.Kernel.Nif");

// ------------------------------------------------------------------ MCP

/// One MCP session (`mcp::session`, the daemon's too), held by `HiremeWeb.Mcp.Session`.
pub struct Mcp(Mutex<Session>);

#[rustler::resource_impl]
impl rustler::Resource for Mcp {}

fn json_in(s: &str) -> NifResult<Json> {
    serde_json::from_str(s).map_err(|_| rustler::Error::BadArg)
}

/// What the Elixir session knows, as of this step (`facts`, JSON), and what the step changed of it.
struct Node {
    masks: Masks,
    account: u64,
    session: u64,
    leased: bool,
    held: Vec<u32>,
    paused: Option<String>,
    bulk: Option<(u64, u64)>,
    rev: u64,
    origin: String,
    server: (String, String),
    next_op: u64,
    ledger: RefCell<Ledger>,
}

/// What a step did to what the Elixir session owns: op ids taken, contract writes drawn, the lease lost.
#[derive(Default)]
struct Ledger {
    ops: u64,
    drawn: u64,
    lost: Option<Option<String>>,
}

fn node(facts: &str) -> NifResult<Node> {
    let f = json_in(facts)?;
    let n = |k: &str| f[k].as_u64().ok_or(rustler::Error::BadArg);
    let m = &f["masks"];
    Ok(Node {
        masks: Masks { read: m[0].as_u64().unwrap_or(0) as u16, write: m[1].as_u64().unwrap_or(0) as u16, may_delete: m[2] == true },
        account: n("account")?,
        session: n("session")?,
        leased: f["leased"] == true,
        held: f["held"].as_array().map(|a| a.iter().filter_map(|i| i.as_u64().map(|i| i as u32)).collect()).unwrap_or_default(),
        paused: f["paused"].as_str().map(str::to_owned),
        bulk: f["bulk"].as_array().and_then(|b| Some((b.first()?.as_u64()?, b.get(1)?.as_u64()?))),
        rev: n("rev")?,
        origin: f["origin"].as_str().unwrap_or("").to_owned(),
        server: (f["server"][0].as_str().unwrap_or("hireme").to_owned(), f["server"][1].as_str().unwrap_or("").to_owned()),
        next_op: n("next_op")?,
        ledger: RefCell::default(),
    })
}

// The node is always connected and trained, and a session is one agent: no co-agent holds anything here.
impl Host for Node {
    fn agent(&self) -> u64 {
        0
    }
    fn masks(&self) -> Option<Masks> {
        Some(self.masks)
    }
    fn welcome(&self) -> Option<(u64, u64)> {
        Some((self.account, self.session))
    }
    fn dead(&self) -> Option<String> {
        None
    }
    fn untrained(&self) -> Option<String> {
        None
    }
    fn held(&self) -> (bool, Vec<u32>) {
        (self.leased, self.held.clone())
    }
    fn paused(&self) -> Option<String> {
        self.paused.clone()
    }
    fn bulk(&self) -> Option<(u64, u64)> {
        self.bulk
    }
    fn rev(&self) -> u64 {
        self.rev
    }
    fn carrier(&self) -> Option<&'static str> {
        None
    }
    fn origin(&self) -> String {
        self.origin.clone()
    }
    fn server(&self) -> (String, String) {
        self.server.clone()
    }
    fn holder(&self, _application: u32) -> Option<(u64, String)> {
        None
    }
    fn draw(&self, n: u64) -> bool {
        let mut l = self.ledger.borrow_mut();
        match self.bulk {
            Some((left, _)) if left >= l.drawn + n => {
                l.drawn += n;
                true
            }
            _ => false,
        }
    }
    fn op_ids(&self, n: usize) -> u64 {
        let mut l = self.ledger.borrow_mut();
        let first = self.next_op + l.ops;
        l.ops += n as u64;
        first
    }
    fn adopt(&self, _application: u32) {}
    fn lost_lease(&self, paused: Option<String>) {
        self.ledger.borrow_mut().lost = Some(paused);
    }
}

/// A step under the session's lock and the kernel's: `{step, ledger}` (`step` as `step_term` says), or `{:error, :panic}`.
fn mcp_step<'a>(env: Env<'a>, m: &Mcp, res: &Res, facts: &str, f: impl FnOnce(&mut Session, &mut Kernel, &Node) -> Step) -> NifResult<Term<'a>> {
    let host = node(facts)?;
    let Ok(mut session) = m.0.lock() else { return Ok((atoms::error(), atoms::panic()).encode(env)) };
    let Some(step) = with(res, |k| f(&mut session, k, &host)) else { return Ok((atoms::error(), atoms::panic()).encode(env)) };
    let l = host.ledger.into_inner();
    let lost = match l.lost {
        None => atoms::none().encode(env),
        Some(since) => (atoms::lost(), since).encode(env),
    };
    Ok((step_term(env, step)?, (l.ops, l.drawn, lost)).encode(env))
}

/// `{:answer, json | nil}`, or `{:pending, ticket, effect}` with the effect as `:wait`,
/// `{:submit, [{op_id, label, op_bytes}], atomic}`, `{:claim, label, args_json}`,
/// `{:release, ids | nil}` or `{:blob, type, bytes}`.
fn step_term<'a>(env: Env<'a>, step: Step) -> NifResult<Term<'a>> {
    Ok(match step {
        Step::Answer(a) => (atoms::answer(), a.map(|j| j.to_string())).encode(env),
        Step::Pending(t, effect) => {
            let e = match effect {
                Effect::Wait(_) => atoms::wait().encode(env),
                Effect::Submit { ops, atomic } => {
                    let ops = ops.iter().map(|(id, label, bytes)| Ok((*id, label.as_str(), bin(env, bytes)?).encode(env))).collect::<NifResult<Vec<Term>>>()?;
                    (atoms::submit(), ops, atomic).encode(env)
                }
                Effect::Claim { label, args } => (atoms::claim(), label, args.to_string()).encode(env),
                Effect::Release(ids) => (atoms::release(), ids).encode(env),
                Effect::Blob { ty, bytes } => (atoms::blob(), ty, bin(env, &bytes)?).encode(env),
                Effect::Check => atoms::check().encode(env),
            };
            (atoms::pending(), t, e).encode(env)
        }
    })
}

/// An effect's outcome as the Elixir session reports it (JSON): `{"waited": true}`,
/// `{"submitted": {"verdicts": [{"ack": [rev, id]} | {"nack": [code, data]} | null], "atomic": bool}}`,
/// `{"claimed" | "released" | "checked": {"ok": reply} | {"error": error}}` or
/// `{"blob": {"ok": sha} | {"error": why}}`.
fn outcome(o: &Json) -> NifResult<Outcome> {
    let rpc = |v: &Json| match (v.get("ok"), v.get("error")) {
        (Some(ok), _) => Ok(Ok(ok.clone())),
        (_, Some(e)) => Ok(Err(e.clone())),
        _ => Err(v["lost"].as_str().unwrap_or("no answer").to_owned()),
    };
    if let Some(s) = o.get("submitted") {
        let verdicts = s["verdicts"]
            .as_array()
            .ok_or(rustler::Error::BadArg)?
            .iter()
            .map(|v| match (v.get("ack"), v.get("nack")) {
                (Some(a), _) => Some(Verdict::Ack { rev: a[0].as_u64().unwrap_or(0), id: a[1].as_u64().unwrap_or(0) as u32 }),
                (_, Some(n)) => Some(Verdict::Nack { code: n[0].as_u64().unwrap_or(0) as u16, data: n[1].clone() }),
                _ => None,
            })
            .collect();
        return Ok(Outcome::Submitted(Submitted { verdicts, lost: None, atomic: s["atomic"] == true }));
    }
    Ok(match (o.get("claimed"), o.get("released"), o.get("blob"), o.get("checked")) {
        (Some(c), _, _, _) => Outcome::Claimed(rpc(c)),
        (_, Some(r), _, _) => Outcome::Released(rpc(r)),
        (_, _, _, Some(c)) => Outcome::Checked(rpc(c)),
        (_, _, Some(b), _) => Outcome::Blob(match (b["ok"].as_str(), b["error"].as_str()) {
            (Some(sha), _) => Ok(sha.to_owned()),
            (_, why) => Err(why.unwrap_or("the upload failed").to_owned()),
        }),
        _ => Outcome::Waited,
    })
}

#[rustler::nif]
fn mcp_open(label: String) -> ResourceArc<Mcp> {
    ResourceArc::new(Mcp(Mutex::new(Session::new(label))))
}

/// One JSON-RPC message (`msg`, JSON) on the account's kernel.
#[rustler::nif(schedule = "DirtyCpu")]
fn mcp_request<'a>(env: Env<'a>, m: ResourceArc<Mcp>, res: ResourceArc<Res>, facts: String, msg: String) -> NifResult<Term<'a>> {
    let msg = json_in(&msg)?;
    mcp_step(env, &m, &res, &facts, |s, k, h| s.request(k, h, msg))
}

/// `subscriptions/listen` on the stream `sink`.
#[rustler::nif(schedule = "DirtyCpu")]
fn mcp_listen<'a>(env: Env<'a>, m: ResourceArc<Mcp>, res: ResourceArc<Res>, facts: String, msg: String, sink: u64) -> NifResult<Term<'a>> {
    let msg = json_in(&msg)?;
    mcp_step(env, &m, &res, &facts, |s, k, h| s.listen(k, h, msg, sink))
}

/// The effect request `ticket` stopped on is done (`outcome`, JSON).
#[rustler::nif(schedule = "DirtyCpu")]
fn mcp_resume<'a>(env: Env<'a>, m: ResourceArc<Mcp>, res: ResourceArc<Res>, facts: String, ticket: u64, outcome_json: String) -> NifResult<Term<'a>> {
    let o = outcome(&json_in(&outcome_json)?)?;
    mcp_step(env, &m, &res, &facts, |s, k, h| s.resume(k, h, ticket, o))
}

/// The notifications a PATCH body makes, as `[{sink, json}]`; nothing to decode while no row is watched.
#[rustler::nif(schedule = "DirtyCpu")]
fn mcp_patch(m: ResourceArc<Mcp>, body: Binary) -> Vec<(u64, String)> {
    let Ok(mut s) = m.0.lock() else { return Vec::new() };
    if !s.watching() {
        return Vec::new();
    }
    let moved = Event::Moved(Arc::new(mcp::moved(body.as_slice()).into_iter().collect()));
    s.event(&moved).into_iter().map(|(sink, j)| (sink, j.to_string())).collect()
}

/// A legacy event stream opened (`true`), or a stream went (`false`).
#[rustler::nif]
fn mcp_stream(m: ResourceArc<Mcp>, sink: u64, open: bool) -> Atom {
    if let Ok(mut s) = m.0.lock() {
        if open { s.attach(sink) } else { s.detach(sink) }
    }
    atoms::ok()
}

/// A read (find, get, text, history) under a key's grants: `{:ok, json}` or `{:refused, code, data_json}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn query<'a>(env: Env<'a>, res: ResourceArc<Res>, req: String, read: u8, write: u8, may_delete: bool) -> NifResult<Term<'a>> {
    let req = json_in(&req)?;
    let g = kernel::query::Grants { human: false, read_mask: read, write_mask: write, may_delete };
    Ok(match with(&res, |k| k.query_as(&g, &req)) {
        Some(Ok(v)) => (atoms::ok(), v.to_string()).encode(env),
        Some(Err(r)) => (atoms::refused(), mcp::tools::refusal(r.code), r.data.to_string()).encode(env),
        None => (atoms::error(), atoms::panic()).encode(env),
    })
}
