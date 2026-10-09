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

use alloc::collections::BTreeMap;
use alloc::vec;
use alloc::vec::Vec;

use wire::schema::{col, op, refusal, table};
use wire::{NONE, Op, U32};

use crate::store::{self, Column, Data, Store, Table};

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
pub(crate) enum Val {
    U(u32),
    S(Vec<u8>),
}

pub(crate) struct Pending {
    id: u64,
    pub(crate) bytes: Vec<u8>,
    /// What the op said each field would become: (table, key, col, value).
    predicted: Vec<(u16, u32, u16, Val)>,
}

pub struct Desk {
    pub store: Store,
    pub(crate) overlay: Vec<(u16, Column)>,
    /// Whole-table copies for tables a pending op adds rows to or removes
    /// rows from (overlays); they take precedence over `overlay`.
    pub(crate) vtables: Vec<Table>,
    /// (table, key) pairs the last ingest or push wrote, for readers that
    /// memoize per row; [NONE, NONE] is "everything".
    pub touched: Vec<[u32; 2]>,
    provisional: u32,
    /// The raw tables or their pending view moved since the last derive.
    pub(crate) raw_dirty: bool,
    pub(crate) derived: crate::derive::Derived,
    /// Keyword hits and total TypeScript computed for a job's recomposed
    /// CV while an op on its lineage is pending.
    pub(crate) glance: BTreeMap<u32, [u32; 2]>,
    pub(crate) pending: Vec<Pending>,
    order: Vec<u32>,
    /// What each card row sorted by (see `basis_of`), and the arena epoch
    /// its string references belong to.
    basis: Vec<Basis>,
    basis_epoch: u32,
    /// The order needs a full sort.
    order_full: bool,
    /// Card rows a prediction moved since the last sort.
    moved: Vec<u32>,
    /// Per card row: the string refs it was derived from, and the text.
    search: Vec<([u32; 13], Vec<u8>)>,
    search_epoch: u32,
    search_dirty: bool,
    pub sel: Vec<u32>,
    pub today: u32,
    pub counters: [u32; COUNTERS],
    pub events: Vec<[u32; 4]>,
    /// (job, item) → mode column, as pending overlay ops left it.
    modes: BTreeMap<(u32, u32), Option<u16>>,
    pub event_msgs: Vec<Vec<u8>>,
}

impl Desk {
    pub const fn new() -> Desk {
        Desk {
            store: Store::new(),
            overlay: Vec::new(),
            vtables: Vec::new(),
            touched: Vec::new(),
            provisional: 0,
            raw_dirty: true,
            derived: crate::derive::Derived::new(),
            glance: BTreeMap::new(),
            pending: Vec::new(),
            order: Vec::new(),
            basis: Vec::new(),
            basis_epoch: 0,
            order_full: true,
            moved: Vec::new(),
            search: Vec::new(),
            search_epoch: 0,
            search_dirty: true,
            sel: Vec::new(),
            today: NONE,
            counters: [0; COUNTERS],
            events: Vec::new(),
            modes: BTreeMap::new(),
            event_msgs: Vec::new(),
        }
    }

    // ---- reading the view -------------------------------------------------

    /// The view's column: the overlay copy if a pending op touched it.
    pub fn vcol(&self, t: u16, c: u16) -> Option<&Column> {
        if let Some(vt) = self.vtables.iter().find(|x| x.id == t) {
            return vt.col(c);
        }
        self.overlay
            .iter()
            .find(|(ot, oc)| *ot == t && oc.id == c)
            .map(|(_, oc)| oc)
            .or_else(|| self.store.table(t).and_then(|x| x.col(c)))
    }

    pub(crate) fn w32(&self, t: u16, c: u16) -> &[u32] {
        match self.vcol(t, c) {
            Some(Column {
                data: Data::W32(v), ..
            }) => v,
            _ => &[],
        }
    }

    pub(crate) fn strs(&self, t: u16, c: u16) -> &[[u32; 2]] {
        match self.vcol(t, c) {
            Some(Column {
                data: Data::Str(v), ..
            }) => v,
            _ => &[],
        }
    }

    pub(crate) fn vu32(&self, t: u16, c: u16, row: usize) -> u32 {
        self.w32(t, c).get(row).copied().unwrap_or(0)
    }

    pub(crate) fn vstr(&self, t: u16, c: u16, row: usize) -> &[u8] {
        let r = self.strs(t, c).get(row).copied().unwrap_or([0, 0]);
        self.store.arena.get(r)
    }

    pub fn rows(&self, t: u16) -> usize {
        self.vtable(t).map_or(0, |x| x.n)
    }

    /// The table rows are read from: a pending whole-table copy, or base.
    fn vtable(&self, t: u16) -> Option<&Table> {
        self.vtables.iter().find(|x| x.id == t).or_else(|| self.store.table(t))
    }

    /// Row by key: the index of a keyed table, else a scan of the first
    /// column (narratives and other small whole-replaced tables).
    pub fn row_of(&self, t: u16, key: u32) -> Option<usize> {
        let x = self.vtable(t)?;
        if store::keyed(t) {
            return x.row_of(key);
        }
        let c = x.col(1)?;
        (0..x.n).find(|&r| c.u32(r) == key)
    }

    /// Row of the small, ix-keyed lookup table `t` whose `key` column
    /// equals `name`.
    fn find_str(&self, t: u16, c: u16, name: &[u8]) -> Option<usize> {
        (0..self.rows(t)).find(|&r| self.vstr(t, c, r) == name)
    }

    // ---- writing the view -------------------------------------------------

    fn overlay_mut(&mut self, t: u16, c: u16) -> Option<&mut Column> {
        if let Some(i) = self.vtables.iter().position(|x| x.id == t) {
            let vt = &mut self.vtables[i];
            if vt.col(c).is_none() {
                let ty = wire::schema::col_def(t, c).map_or(U32, |d| d.ty);
                vt.cols.push(Column::blank(t, c, ty, vt.n));
            }
            return vt.col_mut(c);
        }
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

    pub(crate) fn set(&mut self, t: u16, key: u32, c: u16, v: Val, rec: &mut Vec<(u16, u32, u16, Val)>) {
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
        if t != table::CARDS {
            self.raw_dirty = true;
        }
        self.touched.push([t as u32, key]);
        rec.push((t, key, c, v));
        match t {
            table::CARDS => self.moved.push(row as u32),
            table::BATCHES if c == col::batches::ORDINAL => self.order_full = true,
            table::STAGES => self.order_full = true,
            _ => {}
        }
    }

    /// A whole-table copy of `t` in the view, made on first use from base
    /// and the column copies pending ops already made.
    fn vtable_mut(&mut self, t: u16) -> &mut Table {
        if let Some(i) = self.vtables.iter().position(|x| x.id == t) {
            return &mut self.vtables[i];
        }
        let mut copy = self.store.table(t).cloned().unwrap_or_else(|| Table::new(t));
        let mut i = 0;
        while i < self.overlay.len() {
            if self.overlay[i].0 == t {
                let (_, c) = self.overlay.swap_remove(i);
                match copy.col_mut(c.id) {
                    Some(slot) => *slot = c,
                    None => copy.cols.push(c),
                }
            } else {
                i += 1;
            }
        }
        self.vtables.push(copy);
        self.vtables.last_mut().unwrap()
    }

    /// Adds a predicted row to `t` (keyed by its first column) with the
    /// given values; other columns are blank.
    pub(crate) fn insert_row(&mut self, t: u16, vals: &[(u16, Val)]) {
        let puts: Vec<(u16, Val, [u32; 2])> = vals
            .iter()
            .map(|(c, v)| {
                let r = match v {
                    Val::S(s) => self.store.arena.put(s),
                    Val::U(_) => [0, 0],
                };
                (*c, v.clone(), r)
            })
            .collect();
        let vt = self.vtable_mut(t);
        let row = vt.n;
        for (c, v, _) in &puts {
            if vt.col(*c).is_none() {
                let ty = match v {
                    Val::S(_) => wire::STR,
                    Val::U(_) => U32,
                };
                vt.cols.push(Column::blank(t, *c, ty, vt.n));
            }
        }
        for col in vt.cols.iter_mut() {
            col.push_blank(t);
        }
        vt.n += 1;
        for (c, v, r) in puts {
            let col = vt.col_mut(c).unwrap();
            match (&mut col.data, v) {
                (Data::W32(d), Val::U(x)) => d[row] = x,
                (Data::Str(d), Val::S(_)) => d[row] = r,
                _ => {}
            }
        }
        let key = vt.col(1).map_or(0, |c| c.u32(row));
        vt.index.insert(key, row as u32);
        self.touched.push([t as u32, key]);
        self.raw_dirty = true;
    }

    /// Removes a row from `t` in the view.
    pub(crate) fn delete_row(&mut self, t: u16, key: u32) {
        let vt = self.vtable_mut(t);
        vt.delete(core::iter::once(key));
        self.touched.push([t as u32, key]);
        self.raw_dirty = true;
    }

    /// An id for a row a prediction adds before the server numbers it:
    /// above every id a database row will have, distinct per row.
    pub(crate) fn provisional_id(&mut self) -> u32 {
        self.provisional = self.provisional.wrapping_add(1);
        0x8000_0000 | (self.provisional & 0x7fff_ffff)
    }

    /// `today` from a `clock` table: the server's day, which every
    /// derivation uses.
    fn take_clock(&mut self, t: &wire::Table) {
        if t.id == table::CLOCK && t.nrows > 0 {
            if let Some(c) = t.col(col::clock::TODAY) {
                if c.u32(0) != NONE && c.u32(0) != self.today {
                    self.today = c.u32(0);
                    self.raw_dirty = true;
                }
            }
        }
    }

    /// The derived cards were replaced: order and search re-check every
    /// row (and reuse what did not move).
    pub(crate) fn mark_cards_derived(&mut self) {
        self.order_full = true;
        self.search_dirty = true;
    }

    /// Drops the overlay and replays every pending op over base.
    fn rebuild_view(&mut self) {
        self.raw_dirty = true;
        self.overlay.clear();
        self.vtables.clear();
        self.modes.clear();
        self.order_full = true;
        self.search_dirty = true;
        let pending = core::mem::take(&mut self.pending);
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
        if self.store.table(table::JOB_APPS).is_some() {
            return self.apply_raw(o, check, rec);
        }
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
                // As the server: the action is trimmed, a due date that is
                // not an ISO date means none.
                let due = parse_day(o.field(1)).unwrap_or(NONE);
                let action = o.field(0).trim().as_bytes().to_vec();
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
            op::NARRATIVE => {
                let n = table::NARRATIVES;
                if self.row_of(n, o.target).is_none() {
                    return Err(refusal::NOT_FOUND);
                }
                let body = o.field(0).as_bytes().to_vec();
                self.set(n, o.target, col::narratives::BODY, Val::S(body), rec);
            }
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
        if item == 0 || (o.field(1) == "altered" && o.field(2).trim().is_empty()) {
            return Err(refusal::ARGUMENT);
        }
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
                let m = core::str::from_utf8(self.store.arena.get(m)).unwrap_or("");
                return mode_col(m);
            }
        }
        None
    }

    // ---- the pending layer ------------------------------------------------

    /// Takes an op the client is about to send. Returns 0 and applies it to
    /// the view, or a refusal code and changes nothing.
    pub fn push(&mut self, bytes: &[u8]) -> u8 {
        self.touched.clear();
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
        self.touched.extend(p.predicted.iter().map(|(t, key, _, _)| [*t as u32, *key]));
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
        for p in self.pending.iter().filter(|p| p.id == id) {
            self.touched.extend(p.predicted.iter().map(|(t, key, _, _)| [*t as u32, *key]));
        }
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
        self.touched.clear();
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
                // A BOOT with no tables says "what you restored is current".
                frame::BOOT if f.tables().next().is_none() => {
                    self.store.rev = self.store.rev.max(f.header.rev);
                }
                frame::BOOT | frame::PATCH | frame::LINES if tables_ok => {
                    let boot = kind == frame::BOOT;
                    if boot {
                        self.store.clear_desk();
                        bits |= CARDS | TABLES | LINES | FOCUS;
                    }
                    for t in f.tables().flatten() {
                        bits |= match t.id {
                            table::CARDS | table::CARDS_GONE => CARDS,
                            table::LINES => LINES,
                            _ => TABLES,
                        };
                        self.take_clock(&t);
                        self.store.take(&t);
                    }
                    if boot {
                        self.store.drop_gone_focuses();
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
                // TICK carries the `clock` table: the server's UTC day turned.
                frame::TICK if tables_ok => {
                    for t in f.tables().flatten() {
                        self.take_clock(&t);
                    }
                    self.raw_dirty = true;
                    bits |= TICK | CARDS;
                }
                frame::BOOT | frame::PATCH | frame::LINES | frame::FOCUS => {
                    self.counters[BAD_FRAMES] += 1;
                    bits |= ERROR;
                }
                _ => bits |= OTHER,
            }
        }
        let drained = core::mem::take(&mut self.store.touched);
        self.touched.extend(drained);
        if base_moved || pending_moved {
            self.rebuild_view();
        }
        if self.raw_dirty && self.derive() {
            bits |= CARDS | TABLES;
        }
        if base_moved {
            let overlay = self
                .overlay
                .iter_mut()
                .map(|(_, c)| c)
                .chain(self.vtables.iter_mut().flat_map(|t| t.cols.iter_mut()));
            let before = self.store.arena.live_floor;
            self.store.compact(overlay, false);
            if self.store.arena.live_floor != before {
                self.counters[COMPACTIONS] += 1;
            }
        }
        bits
    }

    // ---- order, search, select ------------------------------------------

    /// Stage ix → rank.
    fn ranks(&self) -> Vec<u64> {
        let st = table::STAGES;
        // Pipeline.rank/1 is the stage's position; a stages lookup the
        // server sent overrides it.
        let mut rank: Vec<u64> = (0..64).map(|i| if i < 10 { i } else { 0xff }).collect();
        for r in 0..self.rows(st) {
            let ix = self.vu32(st, col::stages::IX, r) as usize;
            if ix < rank.len() {
                rank[ix] = (self.vu32(st, col::stages::RANK, r) as u64).min(0xff);
            }
        }
        rank
    }

    /// What a card row sorts by: everything of Card.order but the company,
    /// packed so a smaller number sorts first; the company's string
    /// reference; the id.
    fn basis_of(&self, rank: &[u64], i: usize) -> Basis {
        let c = table::CARDS;
        let at = |col: u16| self.vu32(c, col, i) as u64;
        let key = pack(
            at(col::cards::SCORE),
            at(col::cards::LOAD_PCT),
            self.ordinal(at(col::cards::BATCH) as u32),
            rank.get(at(col::cards::STAGE) as usize)
                .copied()
                .unwrap_or(0xff),
            at(col::cards::HEAT),
        );
        let company = self
            .strs(c, col::cards::COMPANY)
            .get(i)
            .copied()
            .unwrap_or([0, 0]);
        (key, company, at(col::cards::ID) as u32)
    }

    /// `basis_of` for every row, reading each column once.
    fn basis_all(&self, rank: &[u64]) -> Vec<Basis> {
        let c = table::CARDS;
        let cols = [
            col::cards::SCORE,
            col::cards::LOAD_PCT,
            col::cards::BATCH,
            col::cards::STAGE,
            col::cards::HEAT,
            col::cards::ID,
        ]
        .map(|k| self.w32(c, k));
        let company = self.strs(c, col::cards::COMPANY);
        let at = |k: usize, i: usize| cols[k].get(i).copied().unwrap_or(0) as u64;
        (0..self.rows(c))
            .map(|i| {
                let key = pack(
                    at(0, i),
                    at(1, i),
                    self.ordinal(at(2, i) as u32),
                    rank.get(at(3, i) as usize).copied().unwrap_or(0xff),
                    at(4, i),
                );
                (
                    key,
                    company.get(i).copied().unwrap_or([0, 0]),
                    at(5, i) as u32,
                )
            })
            .collect()
    }

    fn ordinal(&self, batch: u32) -> u64 {
        if batch == 0 {
            return 999;
        }
        self.row_of(table::BATCHES, batch).map_or(999, |r| {
            (self.vu32(table::BATCHES, col::batches::ORDINAL, r) as u64).min(0xffff)
        })
    }

    /// Card.order over two card rows, given `basis` is current.
    fn order_by(&self) -> impl Fn(u32, u32) -> core::cmp::Ordering + '_ {
        let arena = &self.store.arena;
        let basis = &self.basis;
        move |a, b| {
            let (x, y) = (&basis[a as usize], &basis[b as usize]);
            x.0.cmp(&y.0)
                .then_with(|| arena.get(x.1).cmp(arena.get(y.1)))
                .then_with(|| x.2.cmp(&y.2))
        }
    }

    /// Brings the board order up to date. Rows whose basis moved are taken
    /// out and put back by binary search, so a prediction or a small PATCH
    /// resorts in microseconds; a new arena epoch, a changed row count or
    /// a large change sorts in full.
    fn sort(&mut self) {
        let rank = self.ranks();
        let n = self.rows(table::CARDS);
        let mut moved = core::mem::take(&mut self.moved);
        if self.order_full {
            self.order_full = false;
            moved.clear();
            let basis = self.basis_all(&rank);
            let epoch = self.store.arena.epoch;
            let reuse = self.order.len() == n && self.basis.len() == n && self.basis_epoch == epoch;
            if reuse {
                moved.extend(
                    (0..n)
                        .filter(|&i| basis[i] != self.basis[i])
                        .map(|i| i as u32),
                );
            }
            self.basis = basis;
            self.basis_epoch = epoch;
            if !reuse || moved.len() > n / 8 {
                let mut order: Vec<u32> = (0..n as u32).collect();
                {
                    let by = self.order_by();
                    order.sort_unstable_by(|&a, &b| by(a, b));
                }
                self.order = order;
                moved.clear();
                self.moved = moved;
                return;
            }
        } else {
            moved.sort_unstable();
            moved.dedup();
            for &r in &moved {
                self.basis[r as usize] = self.basis_of(&rank, r as usize);
            }
        }
        // Everything still in the order kept its basis, so it is sorted;
        // the moved rows go back in one at a time.
        let mut order = core::mem::take(&mut self.order);
        order.retain(|r| moved.binary_search(r).is_err());
        {
            let by = self.order_by();
            for &r in &moved {
                let at = order.partition_point(|&x| by(x, r).is_lt());
                order.insert(at, r);
            }
        }
        self.order = order;
        moved.clear();
        self.moved = moved;
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
        let mut search = core::mem::take(&mut self.search);
        search.resize_with(n, || ([u32::MAX; 13], Vec::new()));
        const FIELDS: [u16; 5] = [
            col::cards::COMPANY,
            col::cards::ROLE,
            col::cards::LOCATION,
            col::cards::NEXT_ACTION,
            col::cards::CV_LABEL,
        ];
        let cols = FIELDS.map(|f| self.strs(c, f));
        let (profiles, names) = (
            self.w32(c, col::cards::PROFILE),
            self.strs(table::PROFILES, col::profiles::NAME),
        );
        let ids = self.w32(c, col::cards::ID);
        let profile_table = self.store.table(table::PROFILES);
        for (r, (key, text)) in search.iter_mut().enumerate() {
            let pid = profiles.get(r).copied().unwrap_or(0);
            let pname = profile_table
                .and_then(|t| t.row_of(pid))
                .and_then(|pr| names.get(pr).copied())
                .unwrap_or([0, 0]);
            let id = ids.get(r).copied().unwrap_or(0);
            let mut k = [0u32; 13];
            for (i, col) in cols.iter().enumerate() {
                let sr = col.get(r).copied().unwrap_or([0, 0]);
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
            for (prefix, digits) in [(&b"\njobapp"[..], id), (b"\ncv", id), (b"\n", id)] {
                text.extend_from_slice(prefix);
                decimal(text, digits);
            }
        }
        self.search = search;
    }

    /// Rows that pass every filter, in board order, into `sel`. Filter
    /// values: -1 is "all", batch -2 is "no batch";
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
        self.derive();
        self.sort();
        let mut query = Vec::new();
        lower_into(&mut query, trim(q));
        if !query.is_empty() {
            self.derive_search();
        }
        let mut sel = core::mem::take(&mut self.sel);
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

type Basis = (u64, [u32; 2], u32);

fn pack(score: u64, load: u64, ordinal: u64, rank: u64, heat: u64) -> u64 {
    (255 - score.min(255)) << 56
        | load.min(0xff_ffff) << 32
        | ordinal.min(0xffff) << 16
        | rank.min(0xff) << 8
        | (255 - heat.min(255))
}

fn decimal(out: &mut Vec<u8>, mut n: u32) {
    let mut buf = [0u8; 10];
    let mut i = buf.len();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    out.extend_from_slice(&buf[i..]);
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
    let s = core::str::from_utf8(s).unwrap_or("");
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
