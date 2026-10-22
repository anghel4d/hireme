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
//!   bytes) or `nil`, and `text(cell)` → a zstr cell's string or `nil`:
//!   native/wire's reading, the one every client does.
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
    rustler::atoms! { ok, error, refused, panic, new, human, key, body, actor, key_id, now_day, now_s, held_ids, answer, pending, wait, submit, claim, release, blob, lost, none }
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

#[rustler::nif(schedule = "DirtyCpu")]
fn unpack<'a>(env: Env<'a>, frame: Binary<'a>, max: usize) -> Option<Binary<'a>> {
    let body = wire::Frame::parse(frame.as_slice(), schema::WIRE_HASH).ok()?.body_max(max).ok()?;
    let mut out = rustler::OwnedBinary::new(body.len())?;
    out.as_mut_slice().copy_from_slice(&body);
    Some(out.release(env))
}

/// A table-run body shuffled for packing (wire::shuffle); None when it does not walk.
#[rustler::nif]
fn shuffle<'a>(env: Env<'a>, body: Binary<'a>) -> Option<Binary<'a>> {
    let mut out = rustler::OwnedBinary::new(body.len())?;
    out.as_mut_slice().copy_from_slice(body.as_slice());
    wire::shuffle(out.as_mut_slice()).ok()?;
    Some(out.release(env))
}

#[rustler::nif]
fn text(cell: Binary) -> Option<String> {
    wire::text_cell(cell.as_slice()).ok().map(|s| s.into_owned())
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
    let bin = |bytes: &[u8]| -> NifResult<Term<'a>> {
        let mut b = rustler::OwnedBinary::new(bytes.len()).ok_or(rustler::Error::BadArg)?;
        b.as_mut_slice().copy_from_slice(bytes);
        Ok(b.release(env).encode(env))
    };
    Ok(match step {
        Step::Answer(a) => (atoms::answer(), a.map(|j| j.to_string())).encode(env),
        Step::Pending(t, effect) => {
            let e = match effect {
                Effect::Wait(_) => atoms::wait().encode(env),
                Effect::Submit { ops, atomic } => {
                    let ops = ops.iter().map(|(id, label, bytes)| Ok((*id, label.as_str(), bin(bytes)?).encode(env))).collect::<NifResult<Vec<Term>>>()?;
                    (atoms::submit(), ops, atomic).encode(env)
                }
                Effect::Claim { label, args } => (atoms::claim(), label, args.to_string()).encode(env),
                Effect::Release(ids) => (atoms::release(), ids).encode(env),
                Effect::Blob { ty, bytes } => (atoms::blob(), ty, bin(&bytes)?).encode(env),
            };
            (atoms::pending(), t, e).encode(env)
        }
    })
}

/// An effect's outcome as the Elixir session reports it (JSON): `{"waited": true}`,
/// `{"submitted": {"verdicts": [{"ack": [rev, id]} | {"nack": [code, data]} | null], "atomic": bool}}`,
/// `{"claimed" | "released": {"ok": reply} | {"error": error}}` or `{"blob": {"ok": sha} | {"error": why}}`.
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
    Ok(match (o.get("claimed"), o.get("released"), o.get("blob")) {
        (Some(c), _, _) => Outcome::Claimed(rpc(c)),
        (_, Some(r), _) => Outcome::Released(rpc(r)),
        (_, _, Some(b)) => Outcome::Blob(match (b["ok"].as_str(), b["error"].as_str()) {
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
