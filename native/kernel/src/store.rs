//! Resident tables.
//!
//! Every table a frame carries is kept here in the shape it travelled in:
//! one `Vec` per column, strings as `(offset, len)` into one shared arena.
//! The kernel's view layer and the ABI read these columns in place, so a
//! pointer handed to TypeScript is the column itself.
//!
//! Keyed tables (the raw rows and the derived cards) upsert by their first
//! column; every other table is replaced whole when a frame carries it.
//! The arena only grows between compactions: a string that is replaced
//! becomes garbage, and `Store::compact` rewrites every live reference
//! once garbage outweighs what is live.

use alloc::vec;
use alloc::vec::Vec;

use wire::schema::{self, col, table};
use wire::{F64, NONE, STR, SYM, U32, U64, Writer};

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
    /// The symbols: one reference per distinct string a sym column brought,
    /// by open addressing on its bytes ([0, 0] empty), so equal values
    /// share one reference. Emptied by a compaction.
    syms: Vec<[u32; 2]>,
    nsyms: usize,
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

    /// The one reference for `s` among the symbols, put on first sight.
    pub fn intern(&mut self, s: &[u8]) -> [u32; 2] {
        if s.is_empty() {
            return [0, 0];
        }
        if (self.nsyms + 1) * 2 > self.syms.len() {
            let size = (self.syms.len() * 2).max(256);
            let old = core::mem::replace(&mut self.syms, vec![[0, 0]; size]);
            for r in old.into_iter().filter(|r| r[1] > 0) {
                let k = self.slot(self.get(r));
                self.syms[k] = r;
            }
        }
        let k = self.slot(s);
        if self.syms[k][1] == 0 {
            self.syms[k] = self.put(s);
            self.nsyms += 1;
        }
        self.syms[k]
    }

    /// The slot holding `s`, or the empty one where it goes.
    fn slot(&self, s: &[u8]) -> usize {
        let mask = self.syms.len() - 1;
        let mut k = s.iter().fold(0x811c_9dc5u32, |h, &c| (h ^ c as u32).wrapping_mul(0x0100_0193)) as usize & mask;
        while self.syms[k][1] != 0 && self.get(self.syms[k]) != s {
            k = (k + 1) & mask;
        }
        k
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

#[derive(Clone)]
pub enum Data {
    W32(Vec<u32>),
    /// u64 words, or f64 bits when the column's type is F64.
    W64(Vec<u64>),
    Str(Vec<[u32; 2]>),
}

#[derive(Clone)]
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

    pub fn push_blank(&mut self, table: u16) {
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

    /// Copies row `r` of a wire column into row `row`; a sym column's
    /// rows take `syms`, its values' references.
    /// Returns whether the row's value changed; an equal string keeps its
    /// reference and puts nothing in the arena.
    fn write(&mut self, row: usize, c: &wire::Col, r: usize, arena: &mut Arena, syms: &[[u32; 2]]) -> bool {
        match &mut self.data {
            Data::W32(v) => core::mem::replace(&mut v[row], c.u32(r)) != c.u32(r),
            // f64 words by bits, so a NaN rewritten is unchanged.
            Data::W64(v) => core::mem::replace(&mut v[row], c.u64(r)) != c.u64(r),
            Data::Str(v) if c.ty == SYM => {
                let new = syms[c.id_of(r)];
                let moved = arena.get(v[row]) != arena.get(new);
                v[row] = new;
                moved
            }
            // The reader checked the column's bytes as UTF-8, so a row is
            // whole characters when it neither starts nor ends inside one;
            // one that splits a character is read as empty, so every string
            // in the arena is valid UTF-8.
            Data::Str(v) => {
                let b = c.bytes(r);
                let cont = |x: Option<u8>| x.is_some_and(|x| x & 0xC0 == 0x80);
                let b = if !cont(b.first().copied()) && !cont(c.after(r)) { b } else { &[][..] };
                if arena.get(v[row]) == b {
                    return false;
                }
                v[row] = arena.put(b);
                true
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

/// Tables the kernel derives itself; a frame that carries one is ignored.
pub fn derived(id: u16) -> bool {
    matches!(
        id,
        table::CARDS
            | table::VERDICTS
            | table::HEAT_ROWS
            | table::SCORE
            | table::VARIETIES
            | table::CHART_BANDS
            | table::CHART_BINS
    )
}

#[derive(Clone)]
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
            if c.ty > SYM || self.col(c.id).is_some() {
                continue;
            }
            let syms = symbols(&c, arena);
            let mut col = Column::blank(self.id, c.id, stored(c.ty), self.n);
            for r in 0..self.n {
                col.write(r, &c, r, arena, &syms);
            }
            self.cols.push(col);
        }
        if keyed(self.id) {
            self.reindex();
        }
    }

    /// Upserts a wire table by its first column. Rows the frame does not
    /// name are untouched; columns it does not carry are untouched on old
    /// rows and blank on new ones. Returns the key of each row that is new
    /// or changed with its changed columns (bit = column id, all for a new
    /// row), or None when the table had no usable key column.
    pub fn upsert(&mut self, t: &wire::Table, arena: &mut Arena) -> Option<Vec<(u32, u64)>> {
        let keys = t.cols().find(|c| c.id == 1 && c.ty == U32)?;
        let mut moved = Vec::with_capacity(t.nrows as usize);
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
                    moved.push(r);
                    row
                }
            };
            rows.push(row);
        }
        // Per row: the columns that changed (bit = column id), all for a new row.
        let mut changed = vec![0u64; rows.len()];
        for &r in &moved {
            changed[r] = u64::MAX;
        }
        for c in t.cols() {
            if c.ty > SYM {
                continue;
            }
            let ty = stored(c.ty);
            if self.col(c.id).is_none() {
                self.cols.push(Column::blank(self.id, c.id, ty, self.n));
            }
            let syms = symbols(&c, arena);
            let (id, n) = (self.id, self.n);
            let col = self.col_mut(c.id).unwrap();
            if col.ty != ty {
                *col = Column::blank(id, c.id, ty, n);
            }
            let bit = if c.id < 64 { 1u64 << c.id } else { u64::MAX };
            for (r, &row) in rows.iter().enumerate() {
                if col.write(row, &c, r, arena, &syms) {
                    changed[r] |= bit;
                }
            }
        }
        Some((0..rows.len()).filter(|&r| changed[r] != 0).map(|r| (keys.u32(r), changed[r])).collect())
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
        w.table(self.id, self.n as u32);
        for c in &self.cols {
            match &c.data {
                Data::W32(v) => w.col_u32(c.id, v.iter().copied()),
                Data::W64(v) => w.col_u64(c.id, c.ty, v.iter().copied()),
                Data::Str(v) => w.col_str(c.id, v.iter().map(|&r| arena.get(r))),
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

/// Everything resident: the raw tables, the derived ones, and the arena.
pub struct Store {
    /// (table, key) of every row a frame wrote or deleted since the
    /// owner last drained it; key NONE is "the whole table".
    pub touched: Vec<[u32; 2]>,
    /// Beside each `touched` entry: the columns that changed (bit = column
    /// id), all bits when not known.
    pub moved_cols: Vec<u64>,
    pub arena: Arena,
    pub tables: Vec<Table>,
    pub rev: u64,
}

impl Store {
    pub const fn new() -> Store {
        Store {
            touched: Vec::new(),
            moved_cols: Vec::new(),
            arena: Arena {
                bytes: Vec::new(),
                live_floor: 0,
                epoch: 0,
                syms: Vec::new(),
                nsyms: 0,
            },
            tables: Vec::new(),
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

    pub fn table_mut(&mut self, id: u16) -> &mut Table {
        match self.tables.iter().position(|x| x.id == id) {
            Some(i) => &mut self.tables[i],
            None => {
                self.tables.push(Table::new(id));
                self.tables.last_mut().unwrap()
            }
        }
    }

    pub fn table(&self, id: u16) -> Option<&Table> {
        self.tables.iter().find(|t| t.id == id)
    }

    /// Takes in one table block of a BOOT or PATCH frame.
    pub fn take(&mut self, t: &wire::Table) {
        let arena = &mut self.arena;
        if t.id == table::GONE {
            // Raw-row deletions: (table id, row id).
            if let (Some(ts), Some(ids)) = (t.col(col::gone::TABLE), t.col(col::gone::ID)) {
                for r in 0..t.nrows as usize {
                    let tid = ts.u32(r) as u16;
                    if let Some(x) = self.tables.iter_mut().find(|x| x.id == tid) {
                        x.delete(core::iter::once(ids.u32(r)));
                    }
                    self.touched.push([tid as u32, ids.u32(r)]);
                    self.moved_cols.push(u64::MAX);
                }
            }
            return;
        }
        let id = t.id;
        if derived(id) {
            return;
        }
        let tbl = match self.tables.iter().position(|x| x.id == id) {
            Some(i) => &mut self.tables[i],
            None => {
                self.tables.push(Table::new(id));
                self.tables.last_mut().unwrap()
            }
        };
        // A row the frame names as it already was moves nothing.
        if let Some(keys) = keyed(id).then(|| tbl.upsert(t, arena)).flatten() {
            for (k, cols) in keys {
                self.touched.push([id as u32, k]);
                self.moved_cols.push(cols);
            }
        } else {
            tbl.replace(t, arena);
            self.touched.push([id as u32, NONE]);
            self.moved_cols.push(u64::MAX);
        }
    }

    /// Clears what a BOOT with content replaces: every table.
    pub fn clear_desk(&mut self) {
        self.tables.clear();
        self.touched.push([NONE, NONE]);
        self.moved_cols.push(u64::MAX);
    }

    /// Rewrites the arena with only the strings something still points at,
    /// once at least half of it is garbage. `extra` are the view's own
    /// columns, which also point into the arena.
    pub fn compact<'a>(&'a mut self, extra: impl Iterator<Item = &'a mut Column>, force: bool) {
        let len = self.arena.bytes.len();
        if !force && len < 2 * self.arena.live_floor + (256 << 10) {
            return;
        }
        // Grown by what is still live (a frame of new rows) is not garbage:
        // moving every string then would only void what caches them.
        let live: usize = self.tables.iter_mut().flat_map(|t| t.str_refs()).map(|r| r[1] as usize).sum();
        if !force && 2 * live > len {
            self.arena.live_floor = live;
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
        for c in extra {
            if let Data::Str(v) = &mut c.data {
                v.iter_mut().for_each(&mut move_ref);
            }
        }
        self.arena.live_floor = new.len();
        self.arena.bytes = new;
        self.arena.epoch += 1;
        self.arena.syms.clear();
        self.arena.nsyms = 0;
    }

    /// The raw tables as one BOOT frame; ingesting it into an empty kernel
    /// restores them (and the views derive again).
    pub fn snapshot(&self, w: &mut Writer) {
        w.begin(schema::frame::BOOT, wire::END, self.rev);
        for t in self.tables.iter().filter(|t| !derived(t.id)) {
            t.encode(w, &self.arena);
        }
        w.end();
    }
}

/// u32 key → u32 row, open addressing with linear probing and
/// backward-shift deletion. Keys are ids and line ixs, so a multiplicative
/// hash spreads them; the table stays at most half full.
#[derive(Default, Clone)]
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

/// Sorts indexes by a comparator through one instantiation of the sort,
/// so each call site does not carry its own copy of it.
#[inline(never)]
pub fn sort_usize(v: &mut [usize], cmp: &dyn Fn(usize, usize) -> core::cmp::Ordering) {
    v.sort_unstable_by(|a, b| cmp(*a, *b));
}

/// The same for u32 rows.
#[inline(never)]
pub fn sort_u32(v: &mut [u32], cmp: &dyn Fn(u32, u32) -> core::cmp::Ordering) {
    v.sort_unstable_by(|a, b| cmp(*a, *b));
}

/// How a wire column is held: a sym column as a str one.
fn stored(ty: u8) -> u8 {
    if ty == SYM { STR } else { ty }
}

/// A sym column's values as interned references (a value whose offsets
/// split a character is empty); nothing for any other column.
fn symbols(c: &wire::Col, arena: &mut Arena) -> Vec<[u32; 2]> {
    if c.ty != SYM {
        return Vec::new();
    }
    (0..c.nsyms())
        .map(|k| {
            let b = c.sym(k);
            if core::str::from_utf8(b).is_ok() { arena.intern(b) } else { [0, 0] }
        })
        .collect()
}
