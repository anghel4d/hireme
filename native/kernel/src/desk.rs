//! The desk: base ⊕ pending, board order, select and search.
//!
//! Base is what the server said, kept in [`Store`]. Pending is the ops
//! this client sent and has not heard back on. The view a reader sees is
//! base with every pending op replayed over it, and only the columns an op
//! touches get a copy (`overlay`). Base changes only when a frame arrives,
//! so settling is exact: an ACK compares what the op predicted with what
//! the PATCH before it wrote and drops the op; a NACK just drops it. Either
//! way the overlay is rebuilt from base and the remaining ops.
//!
//! The board is sorted here, by the same key as `Hireme.Desk.Card.order/1`
//! (score descending, company load ratio, batch ordinal, stage rank, heat
//! descending, company) with the id last so the order is total. The search
//! text the old packet carried is derived here too, lowercased once per
//! change rather than sent.

use wire::schema::{col, op, refusal, table};
use wire::{NONE, Op, U32};

use crate::store::{Column, Data, Store};

/// Counter slots readable through the ABI.
pub const PREDICTED: usize = 0;
pub const SETTLED: usize = 1;
pub const MISPREDICTED: usize = 2;
pub const NACKED: usize = 3;
pub const REFUSED: usize = 4;
pub const UNKNOWN_ACK: usize = 5;
pub const BAD_FRAMES: usize = 6;
pub const COMPACTIONS: usize = 7;
pub const COUNTERS: usize = 8;

#[derive(Clone, PartialEq, Eq, Debug)]
enum Val {
    U(u32),
    S(Vec<u8>),
}

struct Pending {
    id: u64,
    bytes: Vec<u8>,
    /// What the op said each field would become: (table, key, col, value).
    predicted: Vec<(u16, u32, u16, Val)>,
}

#[derive(Default)]
pub struct Desk {
    pub store: Store,
    overlay: Vec<(u16, Column)>,
    pending: Vec<Pending>,
    order: Vec<u32>,
    order_dirty: bool,
    /// Per card row: the string refs it was derived from, and the text.
    search: Vec<([u32; 13], Vec<u8>)>,
    search_epoch: u32,
    search_dirty: bool,
    pub sel: Vec<u32>,
    pub today: u32,
    pub counters: [u32; COUNTERS],
    pub events: Vec<[u32; 4]>,
    /// (job, item) → mode column, as pending overlay ops left it.
    modes: std::collections::HashMap<(u32, u32), Option<u16>>,
    pub event_msgs: Vec<Vec<u8>>,
}

impl Desk {
    pub fn new() -> Desk {
        Desk {
            today: NONE,
            order_dirty: true,
            search_dirty: true,
            ..Default::default()
        }
    }

    // ---- reading the view -------------------------------------------------

    /// The view's column: the overlay copy if a pending op touched it.
    pub fn vcol(&self, t: u16, c: u16) -> Option<&Column> {
        self.overlay
            .iter()
            .find(|(ot, oc)| *ot == t && oc.id == c)
            .map(|(_, oc)| oc)
            .or_else(|| self.store.table(t).and_then(|x| x.col(c)))
    }

    fn w32(&self, t: u16, c: u16) -> &[u32] {
        match self.vcol(t, c) {
            Some(Column {
                data: Data::W32(v), ..
            }) => v,
            _ => &[],
        }
    }

    fn strs(&self, t: u16, c: u16) -> &[[u32; 2]] {
        match self.vcol(t, c) {
            Some(Column {
                data: Data::Str(v), ..
            }) => v,
            _ => &[],
        }
    }

    fn vu32(&self, t: u16, c: u16, row: usize) -> u32 {
        self.w32(t, c).get(row).copied().unwrap_or(0)
    }

    fn vstr(&self, t: u16, c: u16, row: usize) -> &[u8] {
        let r = self.strs(t, c).get(row).copied().unwrap_or([0, 0]);
        self.store.arena.get(r)
    }

    pub fn rows(&self, t: u16) -> usize {
        self.store.table(t).map_or(0, |x| x.n)
    }

    fn row_of(&self, t: u16, key: u32) -> Option<usize> {
        self.store.table(t).and_then(|x| x.row_of(key))
    }

    /// Row of the small, ix-keyed lookup table `t` whose `key` column
    /// equals `name`.
    fn find_str(&self, t: u16, c: u16, name: &[u8]) -> Option<usize> {
        (0..self.rows(t)).find(|&r| self.vstr(t, c, r) == name)
    }

    // ---- writing the view -------------------------------------------------

    fn overlay_mut(&mut self, t: u16, c: u16) -> Option<&mut Column> {
        if !self.overlay.iter().any(|(ot, oc)| *ot == t && oc.id == c) {
            let base = self.store.table(t)?;
            let copy = match base.col(c) {
                Some(col) => col.clone_data(),
                None => {
                    let ty = wire::schema::col_def(t, c).map_or(U32, |d| d.ty);
                    Column::blank(t, c, ty, base.n)
                }
            };
            self.overlay.push((t, copy));
        }
        self.overlay
            .iter_mut()
            .find(|(ot, oc)| *ot == t && oc.id == c)
            .map(|(_, oc)| oc)
    }

    fn set(&mut self, t: u16, key: u32, c: u16, v: Val, rec: &mut Vec<(u16, u32, u16, Val)>) {
        let Some(row) = self.row_of(t, key) else {
            return;
        };
        let put = match &v {
            Val::S(s) => Some(self.store.arena.put(s)),
            Val::U(_) => None,
        };
        let Some(col) = self.overlay_mut(t, c) else {
            return;
        };
        match (&mut col.data, &v) {
            (Data::W32(d), Val::U(x)) => d[row] = *x,
            (Data::Str(d), Val::S(_)) => d[row] = put.unwrap_or([0, 0]),
            _ => return,
        }
        // Search text is only strings (and the profile name, which no op
        // changes), so a number moving resorts without re-deriving it.
        self.search_dirty |= matches!(v, Val::S(_));
        rec.push((t, key, c, v));
        self.order_dirty = true;
    }

    /// Drops the overlay and replays every pending op over base.
    fn rebuild_view(&mut self) {
        self.overlay.clear();
        self.modes.clear();
        self.order_dirty = true;
        self.search_dirty = true;
        let pending = std::mem::take(&mut self.pending);
        for p in &pending {
            if let Ok(o) = Op::parse(&p.bytes) {
                let mut sink = Vec::new();
                let _ = self.apply(&o, false, &mut sink);
            }
        }
        self.pending = pending;
    }

    // ---- predictions ------------------------------------------------------

    /// Predicts one op over the current view. With `check`, refuses what
    /// the server would refuse for reasons the client can see; a refused
    /// op changes nothing.
    fn apply(
        &mut self,
        o: &Op,
        check: bool,
        rec: &mut Vec<(u16, u32, u16, Val)>,
    ) -> Result<(), u8> {
        let target_job = wire::schema::op_def(o.kind)
            .ok_or(refusal::ARGUMENT)?
            .target
            == "job";
        let row = if target_job {
            let row = self
                .row_of(table::CARDS, o.target)
                .ok_or(refusal::NOT_FOUND)?;
            if check && self.vu32(table::CARDS, col::cards::LEASED, row) != 0 {
                return Err(refusal::LEASED);
            }
            row
        } else {
            0
        };
        let job = o.target;
        match o.kind {
            op::STAGE => {
                let to = self.find_str(table::STAGES, col::stages::KEY, o.field(0).as_bytes());
                let to = to.ok_or(refusal::ARGUMENT)?;
                let st = table::STAGES;
                let to_ix = self.vu32(st, col::stages::IX, to);
                let from_ix = self.vu32(table::CARDS, col::cards::STAGE, row);
                let from =
                    (0..self.rows(st)).find(|&r| self.vu32(st, col::stages::IX, r) == from_ix);
                if check {
                    if self.vu32(st, col::stages::FIRE_LOCKED, to) != 0 && !self.batch_open(row) {
                        return Err(refusal::FIRE_HOLD);
                    }
                    let from_hot = from.is_some_and(|f| self.vu32(st, col::stages::HOT, f) != 0);
                    let to_queue = self.vu32(st, col::stages::QUEUE, to) != 0;
                    if !from_hot && to_queue && self.heat_blocked(row) {
                        return Err(refusal::HEAT);
                    }
                }
                if to_ix != from_ix {
                    self.set(table::CARDS, job, col::cards::STAGE, Val::U(to_ix), rec);
                    if self.today != NONE {
                        self.set(
                            table::CARDS,
                            job,
                            col::cards::STAGE_ON,
                            Val::U(self.today),
                            rec,
                        );
                    }
                }
            }
            op::NEXT => {
                let due = parse_day(o.field(1)).ok_or(refusal::ARGUMENT)?;
                let action = o.field(0).as_bytes().to_vec();
                self.set(
                    table::CARDS,
                    job,
                    col::cards::NEXT_ACTION,
                    Val::S(action),
                    rec,
                );
                self.set(table::CARDS, job, col::cards::NEXT_DUE, Val::U(due), rec);
            }
            op::SCORE => {
                let s: u32 = o.field(0).parse().map_err(|_| refusal::ARGUMENT)?;
                if s > 100 {
                    return Err(refusal::ARGUMENT);
                }
                self.set(table::CARDS, job, col::cards::SCORE, Val::U(s), rec);
            }
            op::OPEN_FIRE => {
                let b = table::BATCHES;
                let r = self
                    .find_str(b, col::batches::CODE, o.field(0).as_bytes())
                    .ok_or(refusal::BATCH)?;
                let id = self.vu32(b, col::batches::ID, r);
                self.set(b, id, col::batches::FIRE, Val::U(1), rec);
                self.set(
                    b,
                    id,
                    col::batches::STATUS,
                    Val::S(b"open_fire".to_vec()),
                    rec,
                );
            }
            op::OVERLAY => self.predict_overlay(o, job, rec)?,
            // Notes, heat overrides, narratives and the lanes change
            // nothing on the board; their effects settle from the server.
            _ => {}
        }
        Ok(())
    }

    fn batch_open(&self, row: usize) -> bool {
        let id = self.vu32(table::CARDS, col::cards::BATCH, row);
        id != 0
            && self
                .row_of(table::BATCHES, id)
                .is_some_and(|r| self.vu32(table::BATCHES, col::batches::FIRE, r) != 0)
    }

    fn heat_blocked(&self, row: usize) -> bool {
        let ix = self.vu32(table::CARDS, col::cards::HEAT_STATE, row);
        let h = table::HEAT_STATES;
        (0..self.rows(h))
            .find(|&r| self.vu32(h, col::heat_states::IX, r) == ix)
            .is_some_and(|r| self.vstr(h, col::heat_states::KEY, r) == b"blocked")
    }

    /// An overlay changes one item's mode. When the job's focus is
    /// resident the item's current mode is known, so the card's mask
    /// counts move by one; otherwise they settle from the server.
    fn predict_overlay(
        &mut self,
        o: &Op,
        job: u32,
        rec: &mut Vec<(u16, u32, u16, Val)>,
    ) -> Result<(), u8> {
        let item: u32 = o.field(0).parse().map_err(|_| refusal::ARGUMENT)?;
        let to = mode_col(o.field(1)).ok_or(refusal::ARGUMENT)?;
        let Some(from) = self.item_mode(job, item) else {
            return Ok(());
        };
        self.modes.insert((job, item), to);
        if from == to {
            return Ok(());
        }
        let row = self.row_of(table::CARDS, job).ok_or(refusal::NOT_FOUND)?;
        for (c, d) in [(from, -1i64), (to, 1)] {
            if let Some(c) = c {
                let v = (self.vu32(table::CARDS, c, row) as i64 + d).max(0) as u32;
                self.set(table::CARDS, job, c, Val::U(v), rec);
            }
        }
        Ok(())
    }

    /// The mode column an item currently counts toward: as an earlier
    /// pending overlay left it, else as the resident focus shows it.
    /// Some(None) is inherit; None means it cannot be known.
    fn item_mode(&self, job: u32, item: u32) -> Option<Option<u16>> {
        if let Some(&m) = self.modes.get(&(job, item)) {
            return Some(m);
        }
        let f = self.store.focus.get(&job)?;
        let fl = f.tables.iter().find(|t| t.id == table::FOCUS_LINES)?;
        let lines = self.store.table(table::LINES)?;
        let line_col = fl.col(col::focus_lines::LINE)?;
        for r in 0..fl.n {
            let lr = lines.row_of(line_col.u32(r))?;
            if lines.col(col::lines::ITEM).map(|c| c.u32(lr)) == Some(item) {
                let m = lines
                    .col(col::lines::MODE)
                    .map_or([0, 0], |c| c.str_ref(lr));
                let m = std::str::from_utf8(self.store.arena.get(m)).unwrap_or("");
                return mode_col(m);
            }
        }
        None
    }

    // ---- the pending layer ------------------------------------------------

    /// Takes an op the client is about to send. Returns 0 and applies it to
    /// the view, or a refusal code and changes nothing.
    pub fn push(&mut self, bytes: &[u8]) -> u8 {
        let Ok(o) = Op::parse(bytes) else {
            return refusal::ARGUMENT;
        };
        if self.pending.iter().any(|p| p.id == o.id) {
            return 0;
        }
        let mut rec = Vec::new();
        match self.apply(&o, true, &mut rec) {
            Ok(()) => {
                self.counters[PREDICTED] += 1;
                self.pending.push(Pending {
                    id: o.id,
                    bytes: bytes.to_vec(),
                    predicted: rec,
                });
                0
            }
            Err(code) => {
                // A refused op may have written part of its prediction
                // before the refusal surfaced; rebuild to be exact.
                if !rec.is_empty() {
                    self.rebuild_view();
                }
                self.counters[REFUSED] += 1;
                code
            }
        }
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// An ACK: the PATCH it follows is already in base.
    fn settle(&mut self, id: u64) {
        let Some(i) = self.pending.iter().position(|p| p.id == id) else {
            self.counters[UNKNOWN_ACK] += 1;
            self.event(id, 0, 0, &[]);
            return;
        };
        let p = self.pending.remove(i);
        let exact = p.predicted.iter().all(|(t, key, c, v)| {
            let Some(tbl) = self.store.table(*t) else {
                return false;
            };
            let Some(row) = tbl.row_of(*key) else {
                return true;
            };
            match (tbl.col(*c), v) {
                (Some(col), Val::U(x)) => col.u32(row) == *x,
                (Some(col), Val::S(s)) => self.store.arena.get(col.str_ref(row)) == s.as_slice(),
                (None, _) => false,
            }
        });
        self.counters[if exact { SETTLED } else { MISPREDICTED }] += 1;
        self.event(id, 0, if exact { 0 } else { 1 }, &[]);
    }

    fn drop_op(&mut self, id: u64, code: u8, msg: &[u8]) {
        self.pending.retain(|p| p.id != id);
        self.counters[NACKED] += 1;
        self.event(id, code.max(1) as u32, 0, msg);
    }

    fn event(&mut self, id: u64, code: u32, flags: u32, msg: &[u8]) {
        self.events
            .push([id as u32, (id >> 32) as u32, code, flags]);
        self.event_msgs.push(msg.to_vec());
    }

    // ---- ingest -----------------------------------------------------------

    /// Takes a buffer of whole frames. Returns what changed (see lib.rs).
    pub fn ingest(&mut self, buf: &[u8]) -> u32 {
        use crate::changed::*;
        use wire::schema::frame;
        self.events.clear();
        self.event_msgs.clear();
        let mut bits = 0;
        let mut base_moved = false;
        let mut pending_moved = false;
        for f in wire::frames(buf) {
            let Ok(f) = f else {
                self.counters[BAD_FRAMES] += 1;
                bits |= ERROR;
                break;
            };
            if f.header.check().is_err() || f.header.flags & wire::DEFLATE != 0 {
                self.counters[BAD_FRAMES] += 1;
                bits |= ERROR;
                continue;
            }
            let kind = f.header.kind;
            let tables_ok = f.tables().all(|t| t.is_ok());
            match kind {
                frame::BOOT | frame::PATCH | frame::LINES if tables_ok => {
                    if kind == frame::BOOT {
                        self.store.clear();
                        bits |= CARDS | TABLES | LINES | FOCUS;
                    }
                    for t in f.tables().flatten() {
                        bits |= match t.id {
                            table::CARDS | table::CARDS_GONE => CARDS,
                            table::LINES => LINES,
                            _ => TABLES,
                        };
                        self.store.take(&t);
                    }
                    self.store.rev = self.store.rev.max(f.header.rev);
                    base_moved = true;
                }
                frame::FOCUS if tables_ok => {
                    self.store.take_focus(f.header.rev, &f);
                    bits |= FOCUS;
                }
                frame::ACK => match wire::ack(f.body) {
                    Ok(id) => {
                        self.settle(id);
                        pending_moved = true;
                        bits |= SETTLED_BIT;
                    }
                    Err(_) => bits |= ERROR,
                },
                frame::NACK => match wire::nack(f.body) {
                    Ok((id, code, msg)) => {
                        self.drop_op(id, code, msg.as_bytes());
                        pending_moved = true;
                        bits |= ROLLED_BACK | CARDS;
                    }
                    Err(_) => bits |= ERROR,
                },
                frame::TICK => {
                    if let Ok(day) = wire::tick(f.body) {
                        self.today = day;
                        bits |= TICK;
                    }
                }
                frame::BOOT | frame::PATCH | frame::LINES | frame::FOCUS => {
                    self.counters[BAD_FRAMES] += 1;
                    bits |= ERROR;
                }
                _ => bits |= OTHER,
            }
        }
        if base_moved || pending_moved {
            self.rebuild_view();
        }
        if base_moved {
            let overlay = self.overlay.iter_mut().map(|(_, c)| c);
            let before = self.store.arena.live_floor;
            self.store.compact(overlay, false);
            if self.store.arena.live_floor != before {
                self.counters[COMPACTIONS] += 1;
            }
        }
        bits
    }

    // ---- order, search, select ------------------------------------------

    fn sort(&mut self) {
        if !self.order_dirty {
            return;
        }
        self.order_dirty = false;
        let c = table::CARDS;
        let n = self.rows(c);
        let ordinal = |id: u32| -> u64 {
            if id == 0 {
                return 999;
            }
            self.row_of(table::BATCHES, id)
                .map_or(999, |r| {
                    self.vu32(table::BATCHES, col::batches::ORDINAL, r) as u64
                })
                .min(0xffff)
        };
        let st = table::STAGES;
        let mut rank = vec![0xffu64; 64];
        for r in 0..self.rows(st) {
            let ix = self.vu32(st, col::stages::IX, r) as usize;
            if ix < rank.len() {
                rank[ix] = (self.vu32(st, col::stages::RANK, r) as u64).min(0xff);
            }
        }
        let (score, load, batch, stage, heat) = (
            self.w32(c, col::cards::SCORE),
            self.w32(c, col::cards::LOAD_PCT),
            self.w32(c, col::cards::BATCH),
            self.w32(c, col::cards::STAGE),
            self.w32(c, col::cards::HEAT),
        );
        let at = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0) as u64;
        let mut keys: Vec<(u64, u32)> = (0..n)
            .map(|i| {
                let k = (255 - at(score, i).min(255)) << 56
                    | at(load, i).min(0xff_ffff) << 32
                    | ordinal(at(batch, i) as u32) << 16
                    | rank.get(at(stage, i) as usize).copied().unwrap_or(0xff) << 8
                    | (255 - at(heat, i).min(255));
                (k, i as u32)
            })
            .collect();
        let company = self.strs(c, col::cards::COMPANY);
        let ids = self.w32(c, col::cards::ID);
        let arena = &self.store.arena;
        let name = |i: u32| arena.get(company.get(i as usize).copied().unwrap_or([0, 0]));
        keys.sort_unstable_by(|a, b| {
            a.0.cmp(&b.0)
                .then_with(|| name(a.1).cmp(name(b.1)))
                .then_with(|| ids.get(a.1 as usize).cmp(&ids.get(b.1 as usize)))
        });
        self.order = keys.into_iter().map(|(_, i)| i).collect();
    }

    /// Re-derives the lowercased search text of rows whose inputs moved.
    /// Within one arena epoch the arena is append-only, so equal string
    /// references mean equal strings and a row whose references are all
    /// unchanged keeps its text; a new epoch (BOOT, compaction) derives all.
    fn derive_search(&mut self) {
        if !self.search_dirty {
            return;
        }
        self.search_dirty = false;
        let c = table::CARDS;
        let n = self.rows(c);
        let epoch = self.store.arena.epoch;
        if self.search_epoch != epoch {
            self.search.clear();
            self.search_epoch = epoch;
        }
        let mut search = std::mem::take(&mut self.search);
        search.resize_with(n, || ([u32::MAX; 13], Vec::new()));
        const FIELDS: [u16; 5] = [
            col::cards::COMPANY,
            col::cards::ROLE,
            col::cards::LOCATION,
            col::cards::NEXT_ACTION,
            col::cards::CV_LABEL,
        ];
        for (r, (key, text)) in search.iter_mut().enumerate() {
            let pid = self.vu32(c, col::cards::PROFILE, r);
            let pname = self.row_of(table::PROFILES, pid).map_or([0, 0], |pr| {
                self.strs(table::PROFILES, col::profiles::NAME)
                    .get(pr)
                    .copied()
                    .unwrap_or([0, 0])
            });
            let id = self.vu32(c, col::cards::ID, r);
            let mut k = [0u32; 13];
            for (i, f) in FIELDS.iter().enumerate() {
                let sr = self.strs(c, *f).get(r).copied().unwrap_or([0, 0]);
                k[2 * i..2 * i + 2].copy_from_slice(&sr);
            }
            k[10..12].copy_from_slice(&pname);
            k[12] = id;
            if *key == k {
                continue;
            }
            *key = k;
            text.clear();
            let arena = &self.store.arena;
            for (i, f) in FIELDS.iter().enumerate() {
                if *f == col::cards::CV_LABEL {
                    lower_into(text, arena.get(pname));
                    text.push(b'\n');
                }
                lower_into(text, arena.get([k[2 * i], k[2 * i + 1]]));
                if *f != col::cards::CV_LABEL {
                    text.push(b'\n');
                }
            }
            use std::io::Write;
            let _ = write!(text, "\njobapp{id}\ncv{id}\n{id}");
        }
        self.search = search;
    }

    /// Rows that pass every filter, in board order, into `sel`. Filter
    /// values as the old desk.wat: -1 is "all", batch -2 is "no batch";
    /// batch and profile are db ids, stage/status/heat are table ixs.
    #[allow(clippy::too_many_arguments)]
    pub fn select(
        &mut self,
        min: i32,
        lo: i32,
        hi: i32,
        stage: i32,
        status: i32,
        batch: i32,
        profile: i32,
        heat: i32,
        q: &[u8],
    ) -> usize {
        self.sort();
        let mut query = Vec::new();
        lower_into(&mut query, trim(q));
        if !query.is_empty() {
            self.derive_search();
        }
        let mut sel = std::mem::take(&mut self.sel);
        sel.clear();
        let c = table::CARDS;
        let (score, st, stat, bat, prof, hs) = (
            self.w32(c, col::cards::SCORE),
            self.w32(c, col::cards::STAGE),
            self.w32(c, col::cards::STATUS),
            self.w32(c, col::cards::BATCH),
            self.w32(c, col::cards::PROFILE),
            self.w32(c, col::cards::HEAT_STATE),
        );
        let at = |v: &[u32], i: usize| v.get(i).copied().unwrap_or(0) as i32;
        let eq = |want: i32, v: &[u32], i: usize| want == -1 || at(v, i) == want;
        for &r in &self.order {
            let i = r as usize;
            let s = at(score, i);
            if s < min || s < lo || s > hi {
                continue;
            }
            if !(eq(stage, st, i) && eq(status, stat, i) && eq(profile, prof, i) && eq(heat, hs, i))
            {
                continue;
            }
            let b = at(bat, i);
            if (batch == -2 && b != 0) || (batch >= 0 && b != batch) {
                continue;
            }
            if !query.is_empty() && !contains(&self.search[i].1, &query) {
                continue;
            }
            sel.push(r);
        }
        self.sel = sel;
        self.sel.len()
    }

    /// Position of a job id within the selection, or -1.
    pub fn find(&self, id: u32) -> i32 {
        let ids = self.w32(table::CARDS, col::cards::ID);
        self.sel
            .iter()
            .position(|&r| ids.get(r as usize) == Some(&id))
            .map_or(-1, |p| p as i32)
    }

    /// The view columns, for compaction and for a pointer to hand out.
    pub fn view_col(&self, t: u16, c: u16) -> Option<&Column> {
        self.vcol(t, c)
    }
}

fn mode_col(mode: &str) -> Option<Option<u16>> {
    match mode {
        "inherit" | "" => Some(None),
        "hidden" => Some(Some(col::cards::HIDDEN)),
        "altered" => Some(Some(col::cards::ALTERED)),
        "emphasized" => Some(Some(col::cards::EMPHASIZED)),
        _ => None,
    }
}

fn trim(q: &[u8]) -> &[u8] {
    let s = q
        .iter()
        .position(|b| !b.is_ascii_whitespace())
        .unwrap_or(q.len());
    let e = q
        .iter()
        .rposition(|b| !b.is_ascii_whitespace())
        .map_or(s, |e| e + 1);
    &q[s..e.max(s)]
}

/// Appends `s` lowercased: ASCII in place, anything else through Unicode
/// lowercasing (as Elixir's String.downcase).
pub fn lower_into(out: &mut Vec<u8>, s: &[u8]) {
    if s.is_ascii() {
        out.extend(s.iter().map(u8::to_ascii_lowercase));
        return;
    }
    let s = std::str::from_utf8(s).unwrap_or("");
    let mut buf = [0u8; 4];
    for ch in s.chars().flat_map(char::to_lowercase) {
        out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
    }
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    if needle.len() > hay.len() {
        return false;
    }
    let first = needle[0];
    let last = hay.len() - needle.len();
    let mut i = 0;
    while i <= last {
        match hay[i..=last].iter().position(|&b| b == first) {
            None => return false,
            Some(p) => {
                i += p;
                if &hay[i..i + needle.len()] == needle {
                    return true;
                }
                i += 1;
            }
        }
    }
    false
}

/// "YYYY-MM-DD" → days since 1970-01-01; "" → none.
pub fn parse_day(s: &str) -> Option<u32> {
    if s.is_empty() {
        return Some(NONE);
    }
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let y: i64 = s[0..4].parse().ok()?;
    let m: i64 = s[5..7].parse().ok()?;
    let d: i64 = s[8..10].parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u32::try_from(days).ok()
}
