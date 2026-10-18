//! The kernel as the outside calls it: [`Kernel`], the one facade the
//! NIF and `hireme-mcp` drive natively, and the WebAssembly exports the
//! browser drives, which are the same methods behind a C ABI.
//!
//! A `Kernel` holds an account's resident rows, the board derived from
//! them, and the day it judges by (the `clock` table's, else what the
//! caller set). Every write that reaches the rows (a frame, a prediction,
//! a settle or rollback) also tells the board what moved.
//!
//! **Wasm calling convention.** Memory is the module's own: `alloc(len)`
//! returns a buffer the caller fills, and the caller frees it with
//! `dealloc(ptr, len)` after the call that read it. A call that returns
//! bytes (a document, an id list, a refusal) leaves them in one result
//! buffer and returns its length (or `-1` for none / an error); read it
//! at `result_ptr()` before the next call. Column views (`ids_ptr`,
//! `col_ptr`) point straight into the table's storage and are valid until
//! the next call that writes rows. Strings are `(str_ptr, str_len)` per
//! cell. JSON documents are UTF-8.

use alloc::string::String;
use alloc::vec::Vec;

use schema::{col, table};
use serde_json::{json, Value as Json};

use crate::board::{Board, Dir, Filter};
use crate::judge::{self, Ctx, EVal, Refusal};
use crate::pipeline::Stage;
use crate::rows::{Moved, Rows, Val, Write};
use crate::{compose, query, Day};

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// The frame failed to parse, or names another schema.
    Frame,
    /// A table body failed to apply.
    Body,
    /// A snapshot from another schema or of another shape.
    Snapshot,
}

#[derive(Default)]
pub struct Kernel {
    rows: Rows,
    board: Board,
    /// The caller's day, used until the server's `clock` row arrives.
    today: Day,
    /// The server's own day (the sequencer pins its kernel), which wins
    /// over any `clock` row.
    pinned: Option<Day>,
    stale: bool,
    /// The session's grants, from its WELCOME: what `query` may read.
    grants: query::Grants,
    /// The order indexes `query`'s finds walk, mended as rows move.
    indexes: core::cell::RefCell<query::Indexes>,
}

impl Kernel {
    pub fn new() -> Kernel {
        Kernel { rows: Rows::new(), stale: true, ..Kernel::default() }
    }

    pub fn rows(&self) -> &Rows {
        &self.rows
    }

    /// The session's masks, from its WELCOME, before its BOOT is ingested.
    pub fn set_grants(&mut self, grants: query::Grants) {
        self.grants = grants;
    }

    /// A read of the replica: find, get, text or history (`query`).
    pub fn query(&self, req: &Json) -> Result<Json, Refusal> {
        query::query(&self.rows, &self.grants, &mut self.indexes.borrow_mut(), req)
    }

    pub fn set_today(&mut self, today: Day) {
        if self.today != today {
            self.today = today;
            self.stale = true;
        }
    }

    /// The server's day when this kernel is the server's; else the
    /// server's `clock`, so a client never predicts on a day the server
    /// has not reached; else the caller's.
    pub fn today(&self) -> Day {
        let clock = self.rows.table(table::CLOCK).and_then(|t| t.ids().first().and_then(|&id| t.u32(id, col::clock::TODAY)));
        self.pinned.or(clock.map(|d| d as Day)).unwrap_or(self.today)
    }

    /// The server's day for the sequencer's kernel: it wins over any
    /// `clock` row a BOOT carries.
    pub fn pin_today(&mut self, today: Day) {
        if self.pinned != Some(today) {
            self.pinned = Some(today);
            self.stale = true;
        }
    }

    fn moved(&mut self, m: &Moved, day_before: Day) {
        self.indexes.get_mut().moved(m, &self.rows);
        // A TICK that leaves the day as it was moves nothing derived.
        let only_clock = m.tables.keys().chain(&m.replaced).all(|t| *t == table::CLOCK);
        if m.is_empty() || (only_clock && self.today() == day_before) {
            return;
        }
        self.board.forget(m, &self.rows);
        self.stale = true;
    }

    /// A frame body into the rows. A body that fails part way may have
    /// applied some of its blocks, so everything derived is dropped and
    /// rebuilt from the rows on the next derive.
    fn frame(&mut self, body: &[u8], rev: u64, boot: bool) -> Result<Moved, Error> {
        let day = self.today();
        let r = if boot { self.rows.boot(body, rev) } else { self.rows.patch(body, rev) };
        match r {
            Ok(m) => {
                self.moved(&m, day);
                Ok(m)
            }
            Err(_) => {
                self.board = Board::new();
                self.indexes.get_mut().clear();
                self.stale = true;
                Err(Error::Body)
            }
        }
    }

    /// A BOOT body (the server's cache build and resync, a snapshot).
    pub fn boot(&mut self, body: &[u8], rev: u64) -> Result<Moved, Error> {
        self.frame(body, rev, true)
    }

    /// A PATCH body.
    pub fn patch(&mut self, body: &[u8], rev: u64) -> Result<Moved, Error> {
        self.frame(body, rev, false)
    }

    /// One whole frame from the server: BOOT, PATCH, TICK, ACK or NACK
    /// (deflated or not). Other kinds move nothing.
    pub fn ingest(&mut self, frame: &[u8]) -> Result<Moved, Error> {
        let f = wire::Frame::parse(frame, schema::WIRE_HASH).map_err(|_| Error::Frame)?;
        let rev = f.header.rev;
        let body = f.body().map_err(|_| Error::Frame)?;
        match f.kind() {
            wire::BOOT | wire::TICK => self.boot(&body, rev),
            wire::PATCH => self.patch(&body, rev),
            wire::ACK => {
                let mut all = Moved::default();
                for a in wire::decode_acks(&body).map_err(|_| Error::Frame)? {
                    merge(&mut all, self.rows.settle(a.op_id));
                }
                self.moved(&all, self.today());
                Ok(all)
            }
            wire::NACK => {
                let mut all = Moved::default();
                for n in wire::decode_nacks(&body).map_err(|_| Error::Frame)? {
                    merge(&mut all, self.rows.rollback(n.op_id));
                }
                self.moved(&all, self.today());
                Ok(all)
            }
            _ => Ok(Moved::default()),
        }
    }

    /// The domain verdict on one op, against the base and pending rows,
    /// on the kernel's day (the one the board is derived on), whatever
    /// day the caller's clock says.
    pub fn judge(&mut self, op: &[u8], ctx: &Ctx) -> judge::Verdict {
        let ctx = Ctx { today: self.today(), ..*ctx };
        judge::judge(&self.rows, &mut self.board, op, &ctx)
    }

    /// Judges one op and, if it passes, applies it as pending: the
    /// client's write in its own frame, settled or rolled back later.
    pub fn predict(&mut self, op: &[u8], ctx: &Ctx) -> Result<Moved, Refusal> {
        let effects = self.judge(op, ctx)?;
        let parsed = wire::Op::one(op).map_err(|_| Refusal { code: schema::refusal::TYPE, data: Json::Null })?;
        let writes = writes(&parsed, &effects, &mut || self.rows.temp_id());
        let m = self.rows.apply_pending(parsed.op_id, writes);
        self.moved(&m, self.today());
        Ok(m)
    }

    /// Recomputes the board if anything moved since the last derive.
    pub fn derive(&mut self) {
        if self.stale {
            let today = self.today();
            self.board.derive(&self.rows, today);
            self.stale = false;
        }
    }

    pub fn board(&mut self) -> &Board {
        self.derive();
        &self.board
    }

    pub fn view(&mut self, f: &Filter) -> Vec<u32> {
        self.board().view(f)
    }

    /// Application ids in board order, optionally of one stage.
    pub fn board_ids(&mut self, stage: Option<Stage>) -> Vec<u32> {
        self.board().ids(stage)
    }

    pub fn application(&mut self, id: u32) -> Option<Json> {
        self.derive();
        compose::application(&self.rows, &self.board, id, self.today())
    }

    pub fn overview(&mut self, top: usize) -> Json {
        self.derive();
        compose::overview(&self.rows, &self.board, self.today(), top)
    }

    pub fn atlas(&self, preset: Option<&str>) -> Json {
        compose::atlas_doc(&self.rows, preset)
    }

    pub fn lanes(&self) -> Json {
        compose::lanes_doc(&self.rows, self.today())
    }

    /// The base rows for a cold start: `u64 rev | u32 schema_rev | u16
    /// wire_hash | u16 0 | BOOT body`.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.rows.rev.to_le_bytes());
        out.extend_from_slice(&schema::SCHEMA_REV.to_le_bytes());
        out.extend_from_slice(&schema::WIRE_HASH.to_le_bytes());
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&self.rows.snapshot());
        out
    }

    /// A snapshot back into an empty kernel; the rev it was taken at.
    pub fn restore(&mut self, snap: &[u8]) -> Result<u64, Error> {
        if snap.len() < 16 {
            return Err(Error::Snapshot);
        }
        let rev = u64::from_le_bytes(snap[0..8].try_into().map_err(|_| Error::Snapshot)?);
        let srev = u32::from_le_bytes(snap[8..12].try_into().map_err(|_| Error::Snapshot)?);
        let hash = u16::from_le_bytes([snap[12], snap[13]]);
        if srev != schema::SCHEMA_REV || hash != schema::WIRE_HASH {
            return Err(Error::Snapshot);
        }
        let (today, pinned, grants) = (self.today, self.pinned, self.grants);
        *self = Kernel::new();
        (self.today, self.pinned, self.grants) = (today, pinned, grants);
        self.boot(&snap[16..], rev).map_err(|_| Error::Snapshot)?;
        Ok(rev)
    }
}

fn merge(into: &mut Moved, m: Moved) {
    for (t, (w, g)) in m.tables {
        let e = into.tables.entry(t).or_default();
        e.0.extend(w);
        e.1.extend(g);
    }
    into.replaced.extend(m.replaced);
}

/// An op's effects as row writes, inserts given ids by `fresh`.
pub fn writes(op: &wire::Op, effects: &[judge::Row], fresh: &mut dyn FnMut() -> u32) -> Vec<Write> {
    let mut out = Vec::new();
    if op.verb == wire::DROP {
        out.push(Write::Remove { table: op.table, id: op.target });
    }
    let mut inserted: Vec<u32> = Vec::new();
    // Ids first, so a ref resolves whatever its row's position.
    let ids: Vec<u32> = effects
        .iter()
        .map(|r| {
            if r.id != 0 {
                return r.id;
            }
            let id = fresh();
            inserted.push(id);
            id
        })
        .collect();
    for (r, &id) in effects.iter().zip(&ids) {
        if r.id == 0 {
            out.push(Write::Insert { table: r.table, id });
        }
        for (c, v) in &r.cells {
            let val = match v {
                EVal::Val(v) => v.clone(),
                EVal::New(k) => inserted.get(*k as usize).map_or(Val::None, |&i| Val::U32(i)),
            };
            out.push(Write::Set { table: r.table, id, col: *c, val });
        }
    }
    out
}

/// A board filter from JSON: `{bands, stages, classes, min_score, search}`,
/// the masks as numbers or lists of names.
pub fn filter(json: &str) -> Filter {
    let v: Json = serde_json::from_str(json).unwrap_or(Json::Null);
    let mask = |key: &str, names: &dyn Fn(&str) -> Option<u8>| -> u32 {
        match &v[key] {
            Json::Number(n) => n.as_u64().unwrap_or(0) as u32,
            Json::Array(a) => a.iter().filter_map(|x| x.as_str()).filter_map(names).fold(0, |m, b| m | 1 << b),
            _ => 0,
        }
    };
    Filter {
        bands: mask("bands", &|s| crate::score::Band::parse(s).map(|b| b as u8)) as u8,
        stages: mask("stages", &|s| Stage::parse(s).map(|b| b as u8)) as u16,
        classes: mask("classes", &|s| crate::heat::Class::parse(s).map(|b| b as u8)) as u8,
        min_score: v["min_score"].as_u64().unwrap_or(0).min(100) as u8,
        search: v["search"].as_str().map(String::from).unwrap_or_default(),
    }
}

/// Effects as JSON: `[{table, id, cells: {column: value}}]` with names
/// from the catalog; a value is null, a number, a string or `{"new": k}`
/// (the id of the k-th insert).
pub fn effects_json(rows: &[judge::Row]) -> Json {
    let rows: Vec<Json> = rows
        .iter()
        .map(|r| {
            let def = schema::table_def(r.table);
            let cells: serde_json::Map<String, Json> = r
                .cells
                .iter()
                .map(|(c, v)| {
                    let name = def.and_then(|d| d.col(*c)).map_or_else(|| c.to_string(), |c| c.name.into());
                    let v = match v {
                        EVal::New(k) => json!({"new": k}),
                        EVal::Val(Val::None) => Json::Null,
                        EVal::Val(Val::U32(x)) => json!(x),
                        EVal::Val(Val::I64(x)) => json!(x),
                        EVal::Val(Val::F64(x)) => json!(x),
                        EVal::Val(Val::Str(x)) => json!(x),
                        EVal::Val(Val::List(l)) => json!(l),
                    };
                    (name, v)
                })
                .collect();
            json!({"table": def.map_or("", |d| d.name), "id": r.id, "cells": cells})
        })
        .collect();
    Json::Array(rows)
}

/// The catalog the kernel was built against: `{wire_hash, schema_rev,
/// tables: {name: {id, residency, cols: {name: {id, wire, type, target}}}},
/// enums: {name: [values]}, commands: {name: {id, table, params: {name: id}}}}`.
pub fn catalog_json() -> Json {
    let tables: serde_json::Map<String, Json> = schema::TABLES
        .iter()
        .map(|t| {
            let cols: serde_json::Map<String, Json> = t
                .cols
                .iter()
                .map(|c| (c.name.into(), json!({"id": c.id, "wire": c.wire, "type": c.type_code, "target": c.target})))
                .collect();
            (t.name.into(), json!({"id": t.id, "residency": alloc::format!("{:?}", t.residency).to_lowercase(), "cols": cols}))
        })
        .collect();
    let enums: serde_json::Map<String, Json> = schema::ENUMS.iter().map(|(n, v)| ((*n).into(), json!(v))).collect();
    let commands: serde_json::Map<String, Json> = schema::COMMANDS
        .iter()
        .map(|c| {
            let params: serde_json::Map<String, Json> =
                c.params.iter().map(|p| (p.name.into(), json!({"id": p.id, "wire": p.wire, "type": p.type_code, "target": p.target}))).collect();
            (c.name.into(), json!({"id": c.id, "table": c.table, "human_only": c.human_only, "params": params}))
        })
        .collect();
    json!({"wire_hash": schema::WIRE_HASH, "schema_rev": schema::SCHEMA_REV, "tables": tables, "enums": enums, "commands": commands})
}

pub fn refusal_json(r: &Refusal) -> Json {
    let name = schema::refusal::NAMES.get(r.code as usize).copied().unwrap_or("internal");
    json!({"code": r.code, "refusal": name, "data": r.data})
}

pub fn dir(code: u32) -> Dir {
    match code {
        0 => Dir::Next,
        1 => Dir::Prev,
        2 => Dir::Up,
        3 => Dir::Down,
        4 => Dir::First,
        _ => Dir::Last,
    }
}

/// The browser's exports. One kernel per module instance.
#[cfg(target_arch = "wasm32")]
mod exports {
    use super::*;
    use crate::rows::Data;
    use core::cell::RefCell;

    std::thread_local! {
        static K: RefCell<Kernel> = RefCell::new(Kernel::new());
        static OUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    }

    fn put(bytes: Vec<u8>) -> i32 {
        let n = bytes.len() as i32;
        OUT.with(|o| *o.borrow_mut() = bytes);
        n
    }

    fn put_json(j: &Json) -> i32 {
        put(j.to_string().into_bytes())
    }

    fn put_ids(ids: &[u32]) -> i32 {
        put(ids.iter().flat_map(|i| i.to_le_bytes()).collect())
    }

    /// # Safety
    /// `ptr` and `len` name a buffer from `alloc`, alive for the call.
    unsafe fn input<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
        if len == 0 { &[] } else { unsafe { core::slice::from_raw_parts(ptr, len) } }
    }

    fn moved_json(m: &Moved) -> Json {
        let tables: serde_json::Map<String, Json> = m
            .tables
            .iter()
            .map(|(t, (w, g))| (t.to_string(), json!({"wrote": w, "gone": g})))
            .collect();
        json!({"tables": tables, "replaced": m.replaced})
    }

    fn ctx_json(json: &[u8]) -> (Day, i64, bool, Option<u32>, Vec<u32>) {
        let v: Json = serde_json::from_slice(json).unwrap_or(Json::Null);
        let held = v["held"].as_array().map(|a| a.iter().filter_map(|x| x.as_u64()).map(|x| x as u32).collect()).unwrap_or_default();
        (
            v["today"].as_i64().unwrap_or(0) as Day,
            v["now"].as_i64().unwrap_or(0),
            v["human"].as_bool().unwrap_or(true),
            v["key_id"].as_u64().map(|x| x as u32),
            held,
        )
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn alloc(len: usize) -> *mut u8 {
        let mut v = Vec::<u8>::with_capacity(len.max(1));
        let p = v.as_mut_ptr();
        core::mem::forget(v);
        p
    }

    /// # Safety
    /// `ptr`/`len` came from `alloc(len)` and are freed once.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn dealloc(ptr: *mut u8, len: usize) {
        drop(unsafe { Vec::from_raw_parts(ptr, 0, len.max(1)) });
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn result_ptr() -> *const u8 {
        OUT.with(|o| o.borrow().as_ptr())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn wire_hash() -> u32 {
        schema::WIRE_HASH as u32
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn schema_rev() -> u32 {
        schema::SCHEMA_REV
    }

    /// The catalog JSON (`catalog_json`).
    #[unsafe(no_mangle)]
    pub extern "C" fn catalog() -> i32 {
        put_json(&catalog_json())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn set_today(day: i32) {
        K.with(|k| k.borrow_mut().set_today(day));
    }

    /// One server frame. Result: `{tables: {id: {wrote, gone}}, replaced}`.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn ingest(ptr: *const u8, len: usize) -> i32 {
        let f = unsafe { input(ptr, len) };
        K.with(|k| match k.borrow_mut().ingest(f) {
            Ok(m) => put_json(&moved_json(&m)),
            Err(_) => -1,
        })
    }

    /// Judges one op (OPS op layout) under a JSON ctx `{today, now,
    /// human, key_id, held}` and applies it as pending. Result: the moved
    /// JSON (returns its length), or the refusal JSON (returns minus its
    /// length minus one).
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn predict(op: *const u8, op_len: usize, ctx: *const u8, ctx_len: usize) -> i32 {
        let (op, c) = unsafe { (input(op, op_len), input(ctx, ctx_len)) };
        let (today, now, human, key_id, held) = ctx_json(c);
        K.with(|k| {
            let ctx = Ctx { today, now, human, key_id, held: &held };
            match k.borrow_mut().predict(op, &ctx) {
                Ok(m) => put_json(&moved_json(&m)),
                Err(r) => -put_json(&refusal_json(&r)) - 1,
            }
        })
    }

    /// Only the verdict, nothing applied: the effects JSON (returns its
    /// length), or the refusal JSON (returns minus its length minus one).
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn judge(op: *const u8, op_len: usize, ctx: *const u8, ctx_len: usize) -> i32 {
        let (op, c) = unsafe { (input(op, op_len), input(ctx, ctx_len)) };
        let (today, now, human, key_id, held) = ctx_json(c);
        K.with(|k| {
            let ctx = Ctx { today, now, human, key_id, held: &held };
            match k.borrow_mut().judge(op, &ctx) {
                Ok(rows) => put_json(&effects_json(&rows)),
                Err(r) => -put_json(&refusal_json(&r)) - 1,
            }
        })
    }

    /// The session's grants from its WELCOME (masks over the five
    /// domains; `human` for the operator's browser session).
    #[unsafe(no_mangle)]
    pub extern "C" fn set_grants(read_mask: u32, write_mask: u32, may_delete: u32, human: u32) {
        let grants = query::Grants { human: human == 1, read_mask: read_mask as u8, write_mask: write_mask as u8, may_delete: may_delete == 1 };
        K.with(|k| k.borrow_mut().set_grants(grants));
    }

    /// A read of the replica (`query::query`): the answer JSON (returns its
    /// length), or the refusal JSON (returns minus its length minus one).
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn query(ptr: *const u8, len: usize) -> i32 {
        let req = serde_json::from_slice(unsafe { input(ptr, len) }).unwrap_or(Json::Null);
        K.with(|k| match k.borrow().query(&req) {
            Ok(j) => put_json(&j),
            Err(r) => -put_json(&refusal_json(&r)) - 1,
        })
    }

    /// Board ids (u32 LE) a JSON filter keeps, in order.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn view(ptr: *const u8, len: usize) -> i32 {
        let f = filter(core::str::from_utf8(unsafe { input(ptr, len) }).unwrap_or("{}"));
        K.with(|k| put_ids(&k.borrow_mut().view(&f)))
    }

    /// The card after `selected` (0 = none) in `dir` (0 next, 1 prev, 2
    /// up, 3 down, 4 first, 5 last) over the filtered view; 0 for none.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn step(ptr: *const u8, len: usize, selected: u32, d: u32, columns: u32) -> u32 {
        let f = filter(core::str::from_utf8(unsafe { input(ptr, len) }).unwrap_or("{}"));
        K.with(|k| {
            let v = k.borrow_mut().view(&f);
            crate::board::step(&v, (selected != 0).then_some(selected), dir(d), columns as usize).unwrap_or(0)
        })
    }

    /// One card as JSON `{score_100, stored, band, class, stage, ratio, reason}`.
    #[unsafe(no_mangle)]
    pub extern "C" fn card(id: u32) -> i32 {
        K.with(|k| {
            let mut k = k.borrow_mut();
            match k.board().card(id) {
                Some(c) => put_json(&json!({
                    "score_100": c.score, "stored": c.stored, "band": c.band.name(), "class": c.class.name(),
                    "stage": c.stage.name(), "ratio": c.verdict.ratio(), "reason": c.verdict.reason.name(),
                })),
                None => -1,
            }
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn scoreboard() -> i32 {
        K.with(|k| {
            let mut k = k.borrow_mut();
            let today = k.today();
            k.derive();
            let s = k.board.scoreboard(&k.rows, today);
            put_json(&s.to_json())
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn application(id: u32) -> i32 {
        K.with(|k| k.borrow_mut().application(id).map_or(-1, |j| put_json(&j)))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn overview(top: u32) -> i32 {
        K.with(|k| put_json(&k.borrow_mut().overview(top as usize)))
    }

    /// The atlas under the settings' weights, or a named preset.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn atlas(ptr: *const u8, len: usize) -> i32 {
        let preset = core::str::from_utf8(unsafe { input(ptr, len) }).ok().filter(|s| !s.is_empty());
        K.with(|k| put_json(&k.borrow().atlas(preset)))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn lanes() -> i32 {
        K.with(|k| put_json(&k.borrow().lanes()))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn snapshot() -> i32 {
        K.with(|k| put(k.borrow().snapshot()))
    }

    /// Restores a snapshot; returns 0, or -1 for one of another schema.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn restore(ptr: *const u8, len: usize) -> i64 {
        let s = unsafe { input(ptr, len) };
        K.with(|k| k.borrow_mut().restore(s).map_or(-1, |rev| rev as i64))
    }

    /// Row count of a table.
    #[unsafe(no_mangle)]
    pub extern "C" fn rows(t: u32) -> u32 {
        K.with(|k| k.borrow().rows.table(t as u16).map_or(0, |t| t.len() as u32))
    }

    /// The table's ids, `rows(t)` u32s in slot order.
    #[unsafe(no_mangle)]
    pub extern "C" fn ids_ptr(t: u32) -> *const u32 {
        K.with(|k| k.borrow().rows.table(t as u16).map_or(core::ptr::null(), |t| t.ids().as_ptr()))
    }

    /// A column's storage in slot order: u32 (kind 1), i64 (3) or f64
    /// (4) values, `rows(t)` of them; null for other kinds.
    #[unsafe(no_mangle)]
    pub extern "C" fn col_ptr(t: u32, c: u32) -> *const u8 {
        K.with(|k| {
            let k = k.borrow();
            match k.rows.table(t as u16).and_then(|t| t.column(c as u16)).map(|c| &c.data) {
                Some(Data::U32(v)) => v.as_ptr() as *const u8,
                Some(Data::I64(v)) => v.as_ptr() as *const u8,
                Some(Data::F64(v)) => v.as_ptr() as *const u8,
                _ => core::ptr::null(),
            }
        })
    }

    /// A column's storage kind: 1 u32, 2 str, 3 i64, 4 f64,
    /// 7 list; 0 when absent.
    #[unsafe(no_mangle)]
    pub extern "C" fn col_kind(t: u32, c: u32) -> u32 {
        K.with(|k| {
            let k = k.borrow();
            match k.rows.table(t as u16).and_then(|t| t.column(c as u16)).map(|c| &c.data) {
                Some(Data::U32(_)) => 1,
                Some(Data::Str(_)) => 2,
                Some(Data::I64(_)) => 3,
                Some(Data::F64(_)) => 4,
                Some(Data::List(_)) => 7,
                None => 0,
            }
        })
    }

    /// The string at `(table, col, row id)`: pointer, with its length from
    /// `str_len`. Empty (null) is length 0.
    #[unsafe(no_mangle)]
    pub extern "C" fn str_ptr(t: u32, c: u32, id: u32) -> *const u8 {
        K.with(|k| k.borrow().rows.table(t as u16).and_then(|t| t.str(id, c as u16)).map_or(core::ptr::null(), |s| s.as_ptr()))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn str_len(t: u32, c: u32, id: u32) -> u32 {
        K.with(|k| k.borrow().rows.table(t as u16).and_then(|t| t.str(id, c as u16)).map_or(0, |s| s.len() as u32))
    }

    /// The slot of a row id in its table's column views; `u32::MAX` if absent.
    #[unsafe(no_mangle)]
    pub extern "C" fn slot(t: u32, id: u32) -> u32 {
        K.with(|k| k.borrow().rows.table(t as u16).and_then(|t| t.slot(id)).map_or(u32::MAX, |s| s as u32))
    }
}
