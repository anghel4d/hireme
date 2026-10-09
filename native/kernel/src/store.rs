//! Resident tables.
//!
//! Every table a frame carries is kept here in the shape it travelled in:
//! one `Vec` per column, strings as `(offset, len)` into one shared arena.
//! The kernel's view layer and the ABI read these columns in place, so a
//! pointer handed to TypeScript is the column itself.
//!
//! Keyed tables (cards, batches, profiles, lines) upsert by their first
//! column; every other table is replaced whole when a frame carries it.
//! The arena only grows between compactions: a string that is replaced
//! becomes garbage, and `Store::compact` rewrites every live reference
//! once garbage outweighs what is live.

use alloc::collections::BTreeMap;
use alloc::vec;
use alloc::vec::Vec;

use wire::schema::{self, col, table};
use wire::{F64, NONE, STR, U32, U64, Writer};

/// Bytes of every string column, all tables. Never shrinks except by
/// [`Store::compact`].
#[derive(Default)]
pub struct Arena {
    pub bytes: Vec<u8>,
    /// Bytes that were live after the last compaction (or ever, if none).
    pub live_floor: usize,
    /// Bumped whenever existing references stop meaning what they meant
    /// (a clear or a compaction); within an epoch the arena only appends.
    pub epoch: u32,
}

impl Arena {
    #[inline]
    pub fn put(&mut self, s: &[u8]) -> [u32; 2] {
        if s.is_empty() {
            return [0, 0];
        }
        let at = self.bytes.len() as u32;
        self.bytes.extend_from_slice(s);
        [at, s.len() as u32]
    }

    #[inline]
    pub fn get(&self, r: [u32; 2]) -> &[u8] {
        &self.bytes[r[0] as usize..(r[0] + r[1]) as usize]
    }

    /// A string by reference. Everything put in the arena is valid UTF-8
    /// (`Column::write` empties a row that is not, the kernel's own strings
    /// are `str`s), and a reference covers whole strings.
    #[inline]
    pub fn text(&self, r: [u32; 2]) -> &str {
        let b = self.get(r);
        debug_assert!(core::str::from_utf8(b).is_ok());
        // SAFETY: see above.
        unsafe { core::str::from_utf8_unchecked(b) }
    }
}

pub enum Data {
    W32(Vec<u32>),
    /// u64 words, or f64 bits when the column's type is F64.
    W64(Vec<u64>),
    Str(Vec<[u32; 2]>),
}

pub struct Column {
    pub id: u16,
    pub ty: u8,
    pub data: Data,
}

impl Column {
    /// An `n`-row column holding the schema's "absent" value: none for
    /// days and times, NaN for f64, 0 and "" otherwise.
    pub fn blank(table: u16, id: u16, ty: u8, n: usize) -> Column {
        let data = match ty {
            STR => Data::Str(vec![[0, 0]; n]),
            U64 => Data::W64(vec![0; n]),
            F64 => Data::W64(vec![f64::NAN.to_bits(); n]),
            _ => Data::W32(vec![blank_u32(table, id); n]),
        };
        Column { id, ty, data }
    }

    pub fn ptr(&self) -> usize {
        match &self.data {
            Data::W32(v) => v.as_ptr() as usize,
            Data::W64(v) => v.as_ptr() as usize,
            Data::Str(v) => v.as_ptr() as usize,
        }
    }

    fn push_blank(&mut self, table: u16) {
        match &mut self.data {
            Data::W32(v) => v.push(blank_u32(table, self.id)),
            Data::W64(v) => v.push(if self.ty == F64 {
                f64::NAN.to_bits()
            } else {
                0
            }),
            Data::Str(v) => v.push([0, 0]),
        }
    }

    fn swap_remove(&mut self, row: usize) {
        match &mut self.data {
            Data::W32(v) => drop(v.swap_remove(row)),
            Data::W64(v) => drop(v.swap_remove(row)),
            Data::Str(v) => drop(v.swap_remove(row)),
        }
    }

    /// Copies row `r` of a wire column into row `row`.
    fn write(&mut self, row: usize, c: &wire::Col, r: usize, arena: &mut Arena) {
        match &mut self.data {
            Data::W32(v) => v[row] = c.u32(r),
            Data::W64(v) => v[row] = c.u64(r),
            // A row whose offsets split a character is read as empty, so
            // every string in the arena is valid UTF-8.
            Data::Str(v) => {
                let b = c.bytes(r);
                v[row] = if core::str::from_utf8(b).is_ok() {
                    arena.put(b)
                } else {
                    [0, 0]
                };
            }
        }
    }

    #[inline]
    pub fn u32(&self, row: usize) -> u32 {
        match &self.data {
            Data::W32(v) => v.get(row).copied().unwrap_or(0),
            _ => 0,
        }
    }

    #[inline]
    pub fn str_ref(&self, row: usize) -> [u32; 2] {
        match &self.data {
            Data::Str(v) => v.get(row).copied().unwrap_or([0, 0]),
            _ => [0, 0],
        }
    }

    pub fn clone_data(&self) -> Column {
        let data = match &self.data {
            Data::W32(v) => Data::W32(v.clone()),
            Data::W64(v) => Data::W64(v.clone()),
            Data::Str(v) => Data::Str(v.clone()),
        };
        Column {
            id: self.id,
            ty: self.ty,
            data,
        }
    }
}

fn blank_u32(table: u16, col: u16) -> u32 {
    match schema::col_def(table, col) {
        Some(d) if d.kind == "day" || d.kind == "time" => NONE,
        _ => 0,
    }
}

/// Tables that upsert by their first column instead of being replaced.
pub fn keyed(id: u16) -> bool {
    matches!(
        id,
        table::CARDS
            | table::BATCHES
            | table::PROFILES
            | table::LINES
            | table::NARRATIVES
            | table::ITEMS
            | table::KV_PAIRS
            | table::SCOREBOARD_SNAPSHOTS
            | table::JOB_APPS
            | table::EVENTS
            | table::CV_LINEAGES
            | table::CV_VARIANTS
            | table::OVERLAYS
            | table::GYM_PROBLEMS
            | table::GYM_REPS
            | table::NET_ENTRIES
    )
}

/// Tables that belong to one job's focus rather than to the desk.
pub fn focus_table(id: u16) -> bool {
    schema::table_name(id).is_some_and(|n| n.starts_with("focus"))
}

pub struct Table {
    pub id: u16,
    pub n: usize,
    pub cols: Vec<Column>,
    /// Key (first column) → row, for keyed tables.
    pub index: IdMap,
}

impl Table {
    pub fn new(id: u16) -> Table {
        Table {
            id,
            n: 0,
            cols: Vec::new(),
            index: IdMap::default(),
        }
    }

    #[inline]
    pub fn col(&self, id: u16) -> Option<&Column> {
        self.cols.iter().find(|c| c.id == id)
    }

    #[inline]
    pub fn col_mut(&mut self, id: u16) -> Option<&mut Column> {
        self.cols.iter_mut().find(|c| c.id == id)
    }

    #[inline]
    pub fn row_of(&self, key: u32) -> Option<usize> {
        self.index.get(key).map(|r| r as usize)
    }

    /// Replaces the whole table with a wire table.
    pub fn replace(&mut self, t: &wire::Table, arena: &mut Arena) {
        self.n = t.nrows as usize;
        self.cols.clear();
        self.index.clear();
        for c in t.cols() {
            if c.ty > F64 || self.col(c.id).is_some() {
                continue;
            }
            let mut col = Column::blank(self.id, c.id, c.ty, self.n);
            for r in 0..self.n {
                col.write(r, &c, r, arena);
            }
            self.cols.push(col);
        }
        if keyed(self.id) {
            self.reindex();
        }
    }

    /// Upserts a wire table by its first column. Rows the frame does not
    /// name are untouched; columns it does not carry are untouched on old
    /// rows and blank on new ones. Returns false when the table had no
    /// usable key column.
    pub fn upsert(&mut self, t: &wire::Table, arena: &mut Arena) -> bool {
        let Some(keys) = t.cols().find(|c| c.id == 1 && c.ty == U32) else {
            return false;
        };
        let mut rows = Vec::with_capacity(t.nrows as usize);
        for r in 0..t.nrows as usize {
            let k = keys.u32(r);
            let row = match self.index.get(k) {
                Some(row) => row as usize,
                None => {
                    if self.col(1).is_none() {
                        self.cols.insert(0, Column::blank(self.id, 1, U32, self.n));
                    }
                    let row = self.n;
                    for c in &mut self.cols {
                        c.push_blank(self.id);
                    }
                    self.n += 1;
                    self.index.insert(k, row as u32);
                    row
                }
            };
            rows.push(row);
        }
        for c in t.cols() {
            if c.ty > F64 {
                continue;
            }
            if self.col(c.id).is_none() {
                self.cols.push(Column::blank(self.id, c.id, c.ty, self.n));
            }
            let (id, n) = (self.id, self.n);
            let col = self.col_mut(c.id).unwrap();
            if col.ty != c.ty {
                *col = Column::blank(id, c.id, c.ty, n);
            }
            for (r, &row) in rows.iter().enumerate() {
                col.write(row, &c, r, arena);
            }
        }
        true
    }

    /// Removes rows by key. Returns how many existed.
    pub fn delete(&mut self, keys: impl Iterator<Item = u32>) -> usize {
        let mut gone = 0;
        for k in keys {
            let Some(row) = self.index.remove(k) else {
                continue;
            };
            let row = row as usize;
            let last = self.n - 1;
            for c in &mut self.cols {
                c.swap_remove(row);
            }
            self.n -= 1;
            if row != last {
                let moved = self.col(1).map_or(0, |c| c.u32(row));
                self.index.insert(moved, row as u32);
            }
            gone += 1;
        }
        gone
    }

    pub fn reindex(&mut self) {
        self.index.clear();
        if let Some(Column {
            data: Data::W32(keys),
            ..
        }) = self.col(1)
        {
            let mut index = IdMap::default();
            for (r, &k) in keys.iter().enumerate() {
                index.insert(k, r as u32);
            }
            self.index = index;
        }
    }

    pub fn encode(&self, w: &mut Writer, arena: &Arena) {
        self.encode_rows(w, arena, None)
    }

    /// Encodes the rows `only` names (all rows when None), in row order.
    pub fn encode_rows(&self, w: &mut Writer, arena: &Arena, only: Option<&[usize]>) {
        let all: Vec<usize>;
        let rows = match only {
            Some(r) => r,
            None => {
                all = (0..self.n).collect();
                &all
            }
        };
        w.table(self.id, rows.len() as u32);
        for c in &self.cols {
            match &c.data {
                Data::W32(v) => w.col_u32(c.id, rows.iter().map(|&r| v[r])),
                Data::W64(v) => w.col_u64(c.id, c.ty, rows.iter().map(|&r| v[r])),
                Data::Str(v) => w.col_str(c.id, rows.iter().map(|&r| arena.get(v[r]))),
            }
        }
    }

    /// Every string reference in the table, for compaction.
    pub fn str_refs(&mut self) -> impl Iterator<Item = &mut [u32; 2]> {
        self.cols.iter_mut().flat_map(|c| match &mut c.data {
            Data::Str(v) => v.iter_mut(),
            _ => [].iter_mut(),
        })
    }
}

/// One job's focus: the focus* tables of its latest FOCUS frame.
pub struct Focus {
    pub rev: u64,
    pub tables: Vec<Table>,
}

/// Everything resident: desk tables, focuses by job, and the arena.
pub struct Store {
    pub arena: Arena,
    pub tables: Vec<Table>,
    pub focus: BTreeMap<u32, Focus>,
    pub rev: u64,
}

impl Store {
    pub const fn new() -> Store {
        Store {
            arena: Arena {
                bytes: Vec::new(),
                live_floor: 0,
                epoch: 0,
            },
            tables: Vec::new(),
            focus: BTreeMap::new(),
            rev: 0,
        }
    }

    /// Puts a derived table in place of the one with its id.
    pub fn put_table(&mut self, t: Table) {
        match self.tables.iter().position(|x| x.id == t.id) {
            Some(i) => self.tables[i] = t,
            None => self.tables.push(t),
        }
    }

    pub fn table(&self, id: u16) -> Option<&Table> {
        self.tables.iter().find(|t| t.id == id)
    }

    /// Takes in one table block of a BOOT, PATCH or LINES frame.
    pub fn take(&mut self, t: &wire::Table) {
        let arena = &mut self.arena;
        if t.id == table::CARDS_GONE {
            if let Some(ids) = t.col(col::cards_gone::ID) {
                let cards = self.tables.iter_mut().find(|x| x.id == table::CARDS);
                if let Some(cards) = cards {
                    cards.delete((0..ids.nrows as usize).map(|r| ids.u32(r)));
                }
            }
            return;
        }
        if t.id == table::GONE {
            // Raw-row deletions: (table id, row id).
            if let (Some(ts), Some(ids)) = (t.col(col::gone::TABLE), t.col(col::gone::ID)) {
                for r in 0..t.nrows as usize {
                    let tid = ts.u32(r) as u16;
                    if let Some(x) = self.tables.iter_mut().find(|x| x.id == tid) {
                        x.delete(core::iter::once(ids.u32(r)));
                    }
                }
            }
            return;
        }
        if focus_table(t.id) {
            return;
        }
        let id = t.id;
        let tbl = match self.tables.iter().position(|x| x.id == id) {
            Some(i) => &mut self.tables[i],
            None => {
                self.tables.push(Table::new(id));
                self.tables.last_mut().unwrap()
            }
        };
        if !(keyed(id) && tbl.upsert(t, arena)) {
            tbl.replace(t, arena);
        }
    }

    /// Stores one FOCUS frame as its job's focus.
    pub fn take_focus(&mut self, rev: u64, f: &wire::Frame) -> Option<u32> {
        let mut tables = Vec::new();
        let mut job = None;
        for t in f.tables().flatten() {
            if !focus_table(t.id) {
                continue;
            }
            let mut tbl = Table::new(t.id);
            tbl.replace(&t, &mut self.arena);
            if t.id == table::FOCUS {
                job = tbl.col(col::focus::JOB).map(|c| c.u32(0));
            }
            tables.push(tbl);
        }
        let job = job?;
        self.focus.insert(job, Focus { rev, tables });
        Some(job)
    }

    /// Clears what a BOOT with content replaces: every desk table. Lines
    /// keep their content-derived ix across sessions, so they and the
    /// focuses that point at them stay. The session that sent a line
    /// counts on it staying, so lines are only ever left out of a snapshot,
    /// which a new session (that resends what it uses) restores from.
    pub fn clear_desk(&mut self) {
        self.tables.retain(|t| t.id == table::LINES);
    }

    /// After a BOOT: drops the focuses of jobs that are gone.
    pub fn drop_gone_focuses(&mut self) {
        let cards = self.tables.iter().find(|t| t.id == table::CARDS);
        self.focus
            .retain(|job, _| cards.is_some_and(|c| c.row_of(*job).is_some()));
    }

    /// Line ixs some focus or root still points at.
    fn referenced_lines(&self) -> Vec<u32> {
        let mut keep = Vec::new();
        let mut refs = |t: &Table, c: u16| {
            if let Some(col) = t.col(c) {
                keep.extend((0..t.n).map(|r| col.u32(r)));
            }
        };
        for f in self.focus.values() {
            for t in f.tables.iter().filter(|t| t.id == table::FOCUS_LINES) {
                refs(t, col::focus_lines::LINE);
            }
        }
        if let Some(t) = self.table(table::ROOT_LINES) {
            refs(t, col::root_lines::LINE);
        }
        keep.sort_unstable();
        keep.dedup();
        keep
    }

    /// Rewrites the arena with only the strings something still points at,
    /// once at least half of it is garbage. `extra` are the view's own
    /// columns, which also point into the arena.
    pub fn compact<'a>(&'a mut self, extra: impl Iterator<Item = &'a mut Column>, force: bool) {
        let len = self.arena.bytes.len();
        if !force && len < 2 * self.arena.live_floor + (256 << 10) {
            return;
        }
        let old = core::mem::take(&mut self.arena.bytes);
        let mut new = Vec::with_capacity(self.arena.live_floor + (64 << 10));
        let mut move_ref = |r: &mut [u32; 2]| {
            if r[1] == 0 {
                *r = [0, 0];
                return;
            }
            let s = &old[r[0] as usize..(r[0] + r[1]) as usize];
            r[0] = new.len() as u32;
            new.extend_from_slice(s);
        };
        for t in &mut self.tables {
            t.str_refs().for_each(&mut move_ref);
        }
        for f in self.focus.values_mut() {
            for t in &mut f.tables {
                t.str_refs().for_each(&mut move_ref);
            }
        }
        for c in extra {
            if let Data::Str(v) = &mut c.data {
                v.iter_mut().for_each(&mut move_ref);
            }
        }
        self.arena.live_floor = new.len();
        self.arena.bytes = new;
        self.arena.epoch += 1;
    }

    /// The resident state as frames: one BOOT (every desk table but
    /// lines), one LINES (only lines a focus or root points at), one FOCUS
    /// per job. Ingesting the result into an
    /// empty kernel restores it.
    pub fn snapshot(&self, w: &mut Writer) {
        w.begin(schema::frame::BOOT, wire::END, self.rev);
        for t in self.tables.iter().filter(|t| t.id != table::LINES) {
            t.encode(w, &self.arena);
        }
        w.end();
        if let Some(lines) = self.table(table::LINES) {
            let keep = self.referenced_lines();
            let key = lines.col(col::lines::IX);
            let rows: Vec<usize> = (0..lines.n)
                .filter(|&r| key.is_some_and(|k| keep.binary_search(&k.u32(r)).is_ok()))
                .collect();
            w.begin(schema::frame::LINES, 0, self.rev);
            lines.encode_rows(w, &self.arena, Some(&rows));
            w.end();
        }
        let mut jobs: Vec<_> = self.focus.keys().copied().collect();
        jobs.sort_unstable();
        for job in jobs {
            let f = &self.focus[&job];
            w.begin(schema::frame::FOCUS, 0, f.rev);
            for t in &f.tables {
                t.encode(w, &self.arena);
            }
            w.end();
        }
    }
}

/// u32 key → u32 row, open addressing with linear probing and
/// backward-shift deletion. Keys are ids and line ixs, so a multiplicative
/// hash spreads them; the table stays at most half full.
#[derive(Default)]
pub struct IdMap {
    slots: Vec<(u32, u32)>,
    len: usize,
    /// The one key the empty marker cannot hold.
    max: Option<u32>,
}

const EMPTY: u32 = u32::MAX;

impl IdMap {
    #[inline]
    fn slot(&self, k: u32) -> usize {
        let bits = self.slots.len().trailing_zeros();
        (k.wrapping_mul(0x9E37_79B1) >> (32 - bits)) as usize
    }

    pub fn get(&self, k: u32) -> Option<u32> {
        if k == EMPTY {
            return self.max;
        }
        if self.slots.is_empty() {
            return None;
        }
        let mask = self.slots.len() - 1;
        let mut i = self.slot(k);
        loop {
            match self.slots[i] {
                (EMPTY, _) => return None,
                (key, v) if key == k => return Some(v),
                _ => i = (i + 1) & mask,
            }
        }
    }

    pub fn insert(&mut self, k: u32, v: u32) {
        if k == EMPTY {
            self.max = Some(v);
            return;
        }
        if (self.len + 1) * 2 > self.slots.len() {
            self.grow();
        }
        let mask = self.slots.len() - 1;
        let mut i = self.slot(k);
        loop {
            match self.slots[i] {
                (EMPTY, _) => {
                    self.slots[i] = (k, v);
                    self.len += 1;
                    return;
                }
                (key, _) if key == k => {
                    self.slots[i].1 = v;
                    return;
                }
                _ => i = (i + 1) & mask,
            }
        }
    }

    pub fn remove(&mut self, k: u32) -> Option<u32> {
        if k == EMPTY {
            return self.max.take();
        }
        if self.slots.is_empty() {
            return None;
        }
        let mask = self.slots.len() - 1;
        let mut i = self.slot(k);
        let v = loop {
            match self.slots[i] {
                (EMPTY, _) => return None,
                (key, v) if key == k => break v,
                _ => i = (i + 1) & mask,
            }
        };
        // Shift later members of the run back so no probe stops early.
        let mut hole = i;
        let mut j = (i + 1) & mask;
        while self.slots[j].0 != EMPTY {
            let home = self.slot(self.slots[j].0);
            if (j.wrapping_sub(home) & mask) >= (j.wrapping_sub(hole) & mask) {
                self.slots[hole] = self.slots[j];
                hole = j;
            }
            j = (j + 1) & mask;
        }
        self.slots[hole] = (EMPTY, 0);
        self.len -= 1;
        Some(v)
    }

    pub fn clear(&mut self) {
        self.slots.clear();
        self.len = 0;
        self.max = None;
    }

    fn grow(&mut self) {
        let cap = (self.slots.len() * 2).max(16);
        let old = core::mem::replace(&mut self.slots, vec![(EMPTY, 0); cap]);
        self.len = 0;
        for (k, v) in old {
            if k != EMPTY {
                self.insert(k, v);
            }
        }
    }
}
