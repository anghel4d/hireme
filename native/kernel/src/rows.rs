//! The resident rows: one columnar table per wire table, filled from
//! BOOT and moved by PATCH, with the client's pending writes laid over
//! them.
//!
//! The store is generic over the declaration: a column's storage comes
//! from the wire type its block carries, so nothing here names a table.
//! Each table keeps its ids in a dense vector with an id → slot map;
//! deleting a row moves the last row into its slot, so slot order means
//! nothing and the board orders rows itself.
//!
//! Nulls are the codec's sentinels: `u32::MAX`, `i64::MIN`, NaN, an empty
//! string (null and empty are one thing on the wire), an empty list.
//!
//! **Base ⊕ pending.** A client applies its own op before the server has
//! judged it. Every pending op's writes are recorded with what they
//! replaced. When a BOOT or PATCH arrives, the pending writes are undone,
//! the frame is applied to the base, and the pending writes are applied
//! again; an ACK drops its op from the pending list (its PATCH, sent
//! first in the same sequencer turn, already carried the write into the
//! base); a NACK undoes every pending write, drops that op, and reapplies
//! the rest. So the visible rows are always the base the server sent with
//! the still-unanswered writes on top, and the server's sequencer, which
//! has no pending ops, holds exactly the base.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use wire::{Blocks, Value};

/// The id column every stored table and `leases` carries.
pub const ID: u16 = 1;

/// Whether a table's rows are keyed by an `id` column. The other wire
/// tables (`clock`, `catalog`) number their own columns from 1, so their
/// rows are positional, numbered from 1.
fn keyed(table: u16) -> bool {
    schema::table_def(table).is_none_or(|t| t.cols.iter().any(|c| c.id == ID && c.name == "id"))
}

/// Whether a frame naming a table replaces it whole: every wire table
/// (`leases`, `clock`, `catalog`) is sent whole, so a row missing from it
/// is gone.
fn whole(table: u16) -> bool {
    schema::table_def(table).is_some_and(|t| t.residency == schema::Residency::Wire) || !keyed(table)
}
/// The row revision column.
pub const REV: u16 = 3;
/// Ids a client gives rows it inserts before the server answers. Server
/// ids stay far below.
pub const TEMP_BASE: u32 = 0xC000_0000;

/// One owned value, as a pending write records it.
#[derive(Clone, Debug, PartialEq)]
pub enum Val {
    None,
    U32(u32),
    I64(i64),
    F64(f64),
    Str(String),
    List(Vec<u32>),
    /// A text cell as the wire packs it (tag byte, then raw UTF-8 or a
    /// zstd frame): held as it came, read on touch.
    Packed(Box<[u8]>),
}

impl Val {
    pub fn from_wire(v: Value) -> Val {
        match v {
            Value::None => Val::None,
            Value::U32(wire::NONE) => Val::None,
            Value::U32(x) => Val::U32(x),
            Value::I64(wire::NONE64) => Val::None,
            Value::I64(x) => Val::I64(x),
            Value::F64(x) if x.is_nan() => Val::None,
            Value::F64(x) => Val::F64(x),
            Value::Str("") => Val::None,
            Value::Str(s) => Val::Str(String::from(s)),
            Value::ZStr([]) => Val::None,
            Value::ZStr(c) => Val::Packed(c.into()),
            Value::List(l) if l.is_empty() => Val::None,
            Value::List(l) => Val::List(l.iter().collect()),
            #[allow(unreachable_patterns)]
            _ => Val::None,
        }
    }

    pub fn is_none(&self) -> bool {
        *self == Val::None
    }
}

/// A column's storage.
#[derive(Clone, Debug, PartialEq)]
pub enum Data {
    U32(Vec<u32>),
    I64(Vec<i64>),
    F64(Vec<f64>),
    Str(Vec<String>),
    List(Vec<Vec<u32>>),
    /// Text cells packed at rest; an empty cell is null.
    Packed(Vec<Box<[u8]>>),
}

std::thread_local! {
    /// One reader of packed text, its dictionary decoded once.
    static TEXTS: core::cell::RefCell<wire::Texts> = core::cell::RefCell::new(wire::Texts::default());
}

/// A packed cell's text; `None` for an empty cell or one that will not read.
pub fn unpack(cell: &[u8]) -> Option<alloc::borrow::Cow<'_, str>> {
    match cell {
        [] => None,
        [0, s @ ..] => core::str::from_utf8(s).ok().map(alloc::borrow::Cow::Borrowed),
        _ => TEXTS.with(|t| t.borrow_mut().cell(cell).ok().map(|c| alloc::borrow::Cow::Owned(c.into_owned()))),
    }
}

/// A packed cell's length in bytes, unread: a raw cell's, or the content
/// size its zstd frame states.
pub fn packed_len(cell: &[u8]) -> Option<usize> {
    match cell {
        [] => None,
        [0, s @ ..] => Some(s.len()),
        [1, 0x28, 0xB5, 0x2F, 0xFD, fhd, rest @ ..] => {
            let single = fhd & 0x20 != 0;
            let dict = [0, 1, 2, 4][(fhd & 3) as usize];
            let fcs = match fhd >> 6 {
                0 if single => 1,
                0 => return unpack(cell).map(|t| t.len()),
                1 => 2,
                2 => 4,
                _ => 8,
            };
            let at = usize::from(!single) + dict;
            let b = rest.get(at..at + fcs)?;
            let mut v = 0u64;
            for (i, x) in b.iter().enumerate() {
                v |= (*x as u64) << (8 * i);
            }
            Some(if fcs == 2 { v as usize + 256 } else { v as usize })
        }
        _ => unpack(cell).map(|t| t.len()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    U32,
    I64,
    F64,
    Str,
    List,
    Packed,
}

fn kind_of_wire(ty: u8) -> Option<Kind> {
    Some(match ty {
        wire::U32 => Kind::U32,
        wire::I64 => Kind::I64,
        wire::F64 => Kind::F64,
        wire::STR | wire::SYM => Kind::Str,
        wire::ZSTR => Kind::Packed,
        wire::LIST => Kind::List,
        _ => return None,
    })
}

fn kind_of_val(v: &Val) -> Option<Kind> {
    Some(match v {
        Val::None => return None,
        Val::U32(_) => Kind::U32,
        Val::I64(_) => Kind::I64,
        Val::F64(_) => Kind::F64,
        Val::Str(_) => Kind::Str,
        Val::List(_) => Kind::List,
        Val::Packed(_) => Kind::Packed,
    })
}

impl Data {
    fn new(kind: Kind, n: usize) -> Data {
        match kind {
            Kind::U32 => Data::U32(alloc::vec![wire::NONE; n]),
            Kind::I64 => Data::I64(alloc::vec![wire::NONE64; n]),
            Kind::F64 => Data::F64(alloc::vec![f64::NAN; n]),
            Kind::Str => Data::Str(alloc::vec![String::new(); n]),
            Kind::List => Data::List(alloc::vec![Vec::new(); n]),
            Kind::Packed => Data::Packed(alloc::vec![Box::default(); n]),
        }
    }

    fn kind(&self) -> Kind {
        match self {
            Data::U32(_) => Kind::U32,
            Data::I64(_) => Kind::I64,
            Data::F64(_) => Kind::F64,
            Data::Str(_) => Kind::Str,
            Data::List(_) => Kind::List,
            Data::Packed(_) => Kind::Packed,
        }
    }

    fn push_none(&mut self) {
        match self {
            Data::U32(v) => v.push(wire::NONE),
            Data::I64(v) => v.push(wire::NONE64),
            Data::F64(v) => v.push(f64::NAN),
            Data::Str(v) => v.push(String::new()),
            Data::List(v) => v.push(Vec::new()),
            Data::Packed(v) => v.push(Box::default()),
        }
    }

    fn swap_remove(&mut self, slot: usize) {
        match self {
            Data::U32(v) => drop(v.swap_remove(slot)),
            Data::I64(v) => drop(v.swap_remove(slot)),
            Data::F64(v) => drop(v.swap_remove(slot)),
            Data::Str(v) => drop(v.swap_remove(slot)),
            Data::List(v) => drop(v.swap_remove(slot)),
            Data::Packed(v) => drop(v.swap_remove(slot)),
        }
    }

    fn get(&self, slot: usize) -> Val {
        match self {
            Data::U32(v) => Val::from_wire(Value::U32(v[slot])),
            Data::I64(v) => Val::from_wire(Value::I64(v[slot])),
            Data::F64(v) => Val::from_wire(Value::F64(v[slot])),
            Data::Str(v) => if v[slot].is_empty() { Val::None } else { Val::Str(v[slot].clone()) },
            Data::List(v) => if v[slot].is_empty() { Val::None } else { Val::List(v[slot].clone()) },
            Data::Packed(v) => unpack(&v[slot]).map_or(Val::None, |t| Val::Str(t.into_owned())),
        }
    }

    /// The cell as stored: a packed one unread, for the undo log.
    fn raw(&self, slot: usize) -> Val {
        match self {
            Data::Packed(v) if v[slot].is_empty() => Val::None,
            Data::Packed(v) => Val::Packed(v[slot].clone()),
            _ => self.get(slot),
        }
    }

    /// Writes `v` at `slot`; a value of another kind than the column's is
    /// written as null.
    fn set(&mut self, slot: usize, v: &Val) {
        match (self, v) {
            (Data::U32(d), Val::U32(x)) => d[slot] = *x,
            (Data::I64(d), Val::I64(x)) => d[slot] = *x,
            (Data::F64(d), Val::F64(x)) => d[slot] = *x,
            (Data::Str(d), Val::Str(x)) => d[slot].clone_from(x),
            (Data::List(d), Val::List(x)) => d[slot].clone_from(x),
            (Data::Packed(d), Val::Packed(x)) => d[slot] = x.clone(),
            // A text written here (a prediction) is kept raw, tag 0.
            (Data::Packed(d), Val::Str(x)) => d[slot] = [&[0u8], x.as_bytes()].concat().into(),
            (Data::U32(d), _) => d[slot] = wire::NONE,
            (Data::I64(d), _) => d[slot] = wire::NONE64,
            (Data::F64(d), _) => d[slot] = f64::NAN,
            (Data::Str(d), _) => d[slot].clear(),
            (Data::List(d), _) => d[slot].clear(),
            (Data::Packed(d), _) => d[slot] = Box::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Column {
    pub id: u16,
    pub data: Data,
}

/// One resident table.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Table {
    pub id: u16,
    ids: Vec<u32>,
    slots: crate::fx::Map<u32, u32>,
    /// Sorted by column id.
    cols: Vec<Column>,
    /// Index into `cols` plus one by column id, 0 when absent: a cell
    /// read finds its column without a search.
    at: Vec<u16>,
}

impl Table {
    pub fn new(id: u16) -> Table {
        Table { id, ..Table::default() }
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    /// Row ids in slot order.
    pub fn ids(&self) -> &[u32] {
        &self.ids
    }

    pub fn slot(&self, id: u32) -> Option<usize> {
        self.slots.get(&id).map(|s| *s as usize)
    }

    pub fn has(&self, id: u32) -> bool {
        self.slots.contains_key(&id)
    }

    /// A u32 column's values in slot order (aligned with `ids`).
    pub fn u32s(&self, col: u16) -> Option<&[u32]> {
        match self.column(col).map(|c| &c.data) {
            Some(Data::U32(v)) => Some(v),
            _ => None,
        }
    }

    /// One row, its slot found once for every column read after.
    pub fn row(&self, id: u32) -> Option<Row<'_>> {
        self.slot(id).map(|slot| Row { t: self, slot })
    }

    pub fn column(&self, col: u16) -> Option<&Column> {
        match self.at.get(col as usize) {
            Some(&i) if i > 0 => self.cols.get(i as usize - 1),
            _ => None,
        }
    }

    pub fn columns(&self) -> &[Column] {
        &self.cols
    }

    /// The column, created when absent. A frame from the server may
    /// change a column's kind (`replace`); a local write of another kind
    /// gets `None` and changes nothing.
    fn column_mut(&mut self, col: u16, kind: Kind, replace: bool) -> Option<&mut Column> {
        let n = self.ids.len();
        let i = match self.cols.binary_search_by_key(&col, |c| c.id) {
            Ok(i) => {
                if self.cols[i].data.kind() != kind {
                    if !replace {
                        return None;
                    }
                    self.cols[i].data = Data::new(kind, n);
                }
                i
            }
            Err(i) => {
                self.cols.insert(i, Column { id: col, data: Data::new(kind, n) });
                self.at.clear();
                for (k, c) in self.cols.iter().enumerate() {
                    if self.at.len() <= c.id as usize {
                        self.at.resize(c.id as usize + 1, 0);
                    }
                    self.at[c.id as usize] = k as u16 + 1;
                }
                i
            }
        };
        Some(&mut self.cols[i])
    }

    /// The value at `(id, col)`, `Val::None` when either is absent.
    pub fn get(&self, id: u32, col: u16) -> Val {
        match (self.slot(id), self.column(col)) {
            (Some(s), Some(c)) => c.data.get(s),
            _ => Val::None,
        }
    }

    pub fn u32(&self, id: u32, col: u16) -> Option<u32> {
        match (self.slot(id), self.column(col).map(|c| &c.data)) {
            (Some(s), Some(Data::U32(v))) if v[s] != wire::NONE => Some(v[s]),
            _ => None,
        }
    }

    pub fn i64(&self, id: u32, col: u16) -> Option<i64> {
        match (self.slot(id), self.column(col).map(|c| &c.data)) {
            (Some(s), Some(Data::I64(v))) if v[s] != wire::NONE64 => Some(v[s]),
            _ => None,
        }
    }

    pub fn f64(&self, id: u32, col: u16) -> Option<f64> {
        match (self.slot(id), self.column(col).map(|c| &c.data)) {
            (Some(s), Some(Data::F64(v))) if !v[s].is_nan() => Some(v[s]),
            _ => None,
        }
    }

    /// A str cell, or a packed text cell sent raw; [`Table::text`] reads
    /// any text.
    pub fn str(&self, id: u32, col: u16) -> Option<&str> {
        match (self.slot(id), self.column(col).map(|c| &c.data)) {
            (Some(s), Some(Data::Str(v))) if !v[s].is_empty() => Some(v[s].as_str()),
            (Some(s), Some(Data::Packed(v))) => match &*v[s] {
                [0, t @ ..] => core::str::from_utf8(t).ok(),
                _ => None,
            },
            _ => None,
        }
    }

    /// A text cell, packed or not, read now.
    pub fn text(&self, id: u32, col: u16) -> Option<alloc::borrow::Cow<'_, str>> {
        match (self.slot(id), self.column(col).map(|c| &c.data)) {
            (Some(s), Some(Data::Str(v))) if !v[s].is_empty() => Some(alloc::borrow::Cow::Borrowed(v[s].as_str())),
            (Some(s), Some(Data::Packed(v))) => unpack(&v[s]),
            _ => None,
        }
    }

    /// A text cell's length in bytes, unread when it is packed.
    pub fn text_len(&self, id: u32, col: u16) -> Option<usize> {
        match (self.slot(id), self.column(col).map(|c| &c.data)) {
            (Some(s), Some(Data::Str(v))) if !v[s].is_empty() => Some(v[s].len()),
            (Some(s), Some(Data::Packed(v))) => packed_len(&v[s]),
            _ => None,
        }
    }

    /// Adds an empty row (every column null) and returns its slot; an
    /// existing id returns its slot unchanged.
    pub fn insert(&mut self, id: u32) -> usize {
        if let Some(s) = self.slot(id) {
            return s;
        }
        let s = self.ids.len();
        self.ids.push(id);
        self.slots.insert(id, s as u32);
        for c in &mut self.cols {
            c.data.push_none();
        }
        // A keyed table always carries its ids as a column, even when the
        // first row is one the client inserted itself, so every reader of
        // the row sees its id.
        if keyed(self.id)
            && let Some(c) = self.column_mut(ID, Kind::U32, false)
        {
            c.data.set(s, &Val::U32(id));
        }
        s
    }

    /// Removes a row, returning its values (by column) for an undo.
    pub fn remove(&mut self, id: u32) -> Option<Vec<(u16, Val)>> {
        let s = self.slot(id)?;
        let old = self.cols.iter().map(|c| (c.id, c.data.raw(s))).collect();
        self.slots.remove(&id);
        let last = self.ids.len() - 1;
        self.ids.swap_remove(s);
        for c in &mut self.cols {
            c.data.swap_remove(s);
        }
        if s != last {
            self.slots.insert(self.ids[s], s as u32);
        }
        Some(old)
    }

    /// Writes one cell of an existing row; returns the old value.
    pub fn set(&mut self, id: u32, col: u16, v: &Val) -> Option<Val> {
        let s = self.slot(id)?;
        let old = self.column(col).map_or(Val::None, |c| c.data.raw(s));
        // A text written to a packed column is packed raw, not refused.
        let packed = self.column(col).is_some_and(|c| c.data.kind() == Kind::Packed);
        match kind_of_val(v).map(|k| if packed && k == Kind::Str { Kind::Packed } else { k }) {
            Some(k) => {
                if let Some(c) = self.column_mut(col, k, false) {
                    c.data.set(s, v);
                }
            }
            None => {
                if let Some(i) = self.cols.iter().position(|c| c.id == col) {
                    self.cols[i].data.set(s, &Val::None);
                }
            }
        }
        Some(old)
    }

    fn clear(&mut self) {
        self.ids.clear();
        self.slots.clear();
        self.cols.clear();
        self.at.clear();
    }
}

/// A row of a table, by slot.
#[derive(Clone, Copy)]
pub struct Row<'t> {
    t: &'t Table,
    slot: usize,
}

impl<'t> Row<'t> {
    pub fn u32(&self, col: u16) -> Option<u32> {
        match self.t.column(col).map(|c| &c.data) {
            Some(Data::U32(v)) if v[self.slot] != wire::NONE => Some(v[self.slot]),
            _ => None,
        }
    }

    pub fn str(&self, col: u16) -> Option<&'t str> {
        match self.t.column(col).map(|c| &c.data) {
            Some(Data::Str(v)) if !v[self.slot].is_empty() => Some(v[self.slot].as_str()),
            _ => None,
        }
    }
}

/// What a frame moved, so a client re-renders only that.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Moved {
    /// Per table: rows written (ids) and rows deleted.
    pub tables: BTreeMap<u16, (Vec<u32>, Vec<u32>)>,
    /// Tables a BOOT replaced whole.
    pub replaced: Vec<u16>,
}

impl Moved {
    fn wrote(&mut self, t: u16, id: u32) {
        self.tables.entry(t).or_default().0.push(id);
    }

    fn gone(&mut self, t: u16, id: u32) {
        self.tables.entry(t).or_default().1.push(id);
    }

    pub fn touched(&self, t: u16) -> bool {
        self.tables.contains_key(&t) || self.replaced.contains(&t)
    }

    pub fn is_empty(&self) -> bool {
        self.tables.is_empty() && self.replaced.is_empty()
    }
}

/// One pending write's undo record.
#[derive(Clone, Debug, PartialEq)]
enum Undo {
    Set { table: u16, id: u32, col: u16, old: Val },
    Inserted { table: u16, id: u32 },
    Removed { table: u16, id: u32, row: Vec<(u16, Val)> },
}

/// A write the kernel applies: a cell, an insert or a delete.
#[derive(Clone, Debug, PartialEq)]
pub enum Write {
    Set { table: u16, id: u32, col: u16, val: Val },
    Insert { table: u16, id: u32 },
    Remove { table: u16, id: u32 },
}

#[derive(Clone, Debug, Default)]
struct Pending {
    op_id: u64,
    writes: Vec<Write>,
    undo: Vec<Undo>,
}

#[derive(Clone, Debug, Default)]
pub struct Rows {
    tables: BTreeMap<u16, Table>,
    /// The account rev of the newest frame applied.
    pub rev: u64,
    pending: Vec<Pending>,
    next_temp: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Wire(wire::Error),
    /// A block's column has a different row count than the block.
    Shape,
}

impl From<wire::Error> for Error {
    fn from(e: wire::Error) -> Error {
        Error::Wire(e)
    }
}

impl Rows {
    pub fn new() -> Rows {
        Rows { next_temp: TEMP_BASE, ..Rows::default() }
    }

    pub fn table(&self, id: u16) -> Option<&Table> {
        self.tables.get(&id)
    }

    pub fn tables(&self) -> impl Iterator<Item = &Table> {
        self.tables.values()
    }

    fn table_mut(&mut self, id: u16) -> &mut Table {
        self.tables.entry(id).or_insert_with(|| Table::new(id))
    }

    /// A BOOT or TICK body: every table it names is replaced.
    pub fn boot(&mut self, body: &[u8], rev: u64) -> Result<Moved, Error> {
        self.frame(body, rev, true)
    }

    /// A PATCH body: rows upserted by id with the columns that moved, and
    /// gone blocks deleted.
    pub fn patch(&mut self, body: &[u8], rev: u64) -> Result<Moved, Error> {
        self.frame(body, rev, false)
    }

    fn frame(&mut self, body: &[u8], rev: u64, replace: bool) -> Result<Moved, Error> {
        let blocks = Blocks::new(body)?;
        let pending = core::mem::take(&mut self.pending);
        self.unwind(&pending);
        let mut moved = Moved::default();
        let result = self.apply_blocks(&blocks, replace, &mut moved);
        self.pending = pending;
        self.rewind(&mut moved);
        result?;
        self.rev = self.rev.max(rev);
        Ok(moved)
    }

    fn apply_blocks(&mut self, blocks: &Blocks, replace: bool, moved: &mut Moved) -> Result<(), Error> {
        let mut replaced: Vec<u16> = Vec::new();
        for b in blocks.iter() {
            let tid = b.table;
            if let Some(gone) = b.gone() {
                let t = self.table_mut(tid);
                for id in gone.iter() {
                    if t.remove(id).is_some() {
                        moved.gone(tid, id);
                    }
                }
                continue;
            }
            let n = b.nrows;
            let ids: Vec<u32> = match b.col(ID) {
                _ if !keyed(tid) => (1..=n as u32).collect(),
                Some(c) if c.ty == wire::U32 && c.nrows() == n => (0..n).map(|i| c.u32(i)).collect(),
                // A table the session may not read comes as an empty block
                // with no columns: it is emptied, nothing more.
                None if n == 0 => Vec::new(),
                _ => return Err(Error::Shape),
            };
            let t = self.table_mut(tid);
            if (replace || whole(tid)) && !replaced.contains(&tid) {
                t.clear();
                replaced.push(tid);
            }
            let slots: Vec<usize> = ids.iter().map(|&id| t.insert(id)).collect();
            for c in b.cols() {
                if c.nrows() != n {
                    return Err(Error::Shape);
                }
                let Some(kind) = kind_of_wire(c.ty) else { continue };
                let Some(col) = t.column_mut(c.id, kind, true) else { continue };
                for (i, &s) in slots.iter().enumerate() {
                    col.data.set(s, &Val::from_wire(c.value(i)));
                }
            }
            if !replace {
                for &id in &ids {
                    moved.wrote(tid, id);
                }
            }
        }
        moved.replaced = replaced;
        Ok(())
    }

    fn apply_write(&mut self, w: &Write, undo: &mut Vec<Undo>) {
        match w {
            Write::Set { table, id, col, val } => {
                if let Some(old) = self.table_mut(*table).set(*id, *col, val) {
                    undo.push(Undo::Set { table: *table, id: *id, col: *col, old });
                }
            }
            Write::Insert { table, id } => {
                let t = self.table_mut(*table);
                if !t.has(*id) {
                    t.insert(*id);
                    undo.push(Undo::Inserted { table: *table, id: *id });
                }
            }
            Write::Remove { table, id } => {
                if let Some(row) = self.table_mut(*table).remove(*id) {
                    undo.push(Undo::Removed { table: *table, id: *id, row });
                }
            }
        }
    }

    fn undo(&mut self, u: &Undo) {
        match u {
            Undo::Set { table, id, col, old } => {
                self.table_mut(*table).set(*id, *col, old);
            }
            Undo::Inserted { table, id } => {
                self.table_mut(*table).remove(*id);
            }
            Undo::Removed { table, id, row } => {
                let t = self.table_mut(*table);
                t.insert(*id);
                for (c, v) in row {
                    t.set(*id, *c, v);
                }
            }
        }
    }

    /// Undoes every pending write, newest first.
    fn unwind(&mut self, pending: &[Pending]) {
        for p in pending.iter().rev() {
            for u in p.undo.iter().rev() {
                self.undo(u);
            }
        }
    }

    /// Reapplies every pending op's writes over the current base,
    /// recording fresh undo entries and what they touched.
    fn rewind(&mut self, moved: &mut Moved) {
        let mut pending = core::mem::take(&mut self.pending);
        for p in &mut pending {
            let mut undo = Vec::new();
            for w in &p.writes {
                self.apply_write(w, &mut undo);
                note(moved, w);
            }
            p.undo = undo;
        }
        self.pending = pending;
    }

    /// Applies `writes` now, as pending op `op_id`.
    pub fn apply_pending(&mut self, op_id: u64, writes: Vec<Write>) -> Moved {
        let mut moved = Moved::default();
        let mut undo = Vec::new();
        for w in &writes {
            self.apply_write(w, &mut undo);
            note(&mut moved, w);
        }
        self.pending.push(Pending { op_id, writes, undo });
        moved
    }

    /// Applies writes to the base directly (the sequencer's own cache,
    /// which has no pending ops).
    pub fn apply(&mut self, writes: &[Write]) -> Moved {
        let mut moved = Moved::default();
        let mut undo = Vec::new();
        for w in writes {
            self.apply_write(w, &mut undo);
            note(&mut moved, w);
        }
        moved
    }

    /// The server took op `op_id`: its PATCH already carried the write.
    pub fn settle(&mut self, op_id: u64) -> Moved {
        self.drop_pending(op_id)
    }

    /// The server refused op `op_id`: its writes are taken back.
    pub fn rollback(&mut self, op_id: u64) -> Moved {
        self.drop_pending(op_id)
    }

    fn drop_pending(&mut self, op_id: u64) -> Moved {
        let mut moved = Moved::default();
        let Some(i) = self.pending.iter().position(|p| p.op_id == op_id) else { return moved };
        let pending = core::mem::take(&mut self.pending);
        self.unwind(&pending);
        for w in &pending[i].writes {
            note(&mut moved, w);
        }
        self.pending = pending;
        self.pending.remove(i);
        self.rewind(&mut moved);
        moved
    }

    pub fn pending_ops(&self) -> impl Iterator<Item = u64> + '_ {
        self.pending.iter().map(|p| p.op_id)
    }

    /// A fresh id for a row inserted before the server names it.
    pub fn temp_id(&mut self) -> u32 {
        self.next_temp = self.next_temp.wrapping_add(1).max(TEMP_BASE + 1);
        self.next_temp
    }

    /// The account's base rows (pending writes and wire tables left out)
    /// as a BOOT body, for a client's cold-start snapshot. `boot` on it restores the same base.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut base = self.clone();
        let pending = core::mem::take(&mut base.pending);
        base.unwind(&pending);
        let mut w = wire::BodyWriter::new();
        // Wire tables (leases, clock, catalog) are the session's, not the
        // account's: the next BOOT brings them fresh.
        let session = |id: u16| schema::table_def(id).is_some_and(|t| t.residency == schema::Residency::Wire);
        for t in base.tables.values().filter(|t| !session(t.id)) {
            let n = t.len();
            let mut b = w.block(t.id, n);
            for c in &t.cols {
                match &c.data {
                    Data::U32(v) => b.u32s(c.id, v.iter().copied()),
                    Data::I64(v) => b.i64s(c.id, v.iter().copied()),
                    Data::F64(v) => b.f64s(c.id, v.iter().copied()),
                    Data::Str(v) => b.strs(c.id, v.iter().map(String::as_str)),
                    Data::List(v) => b.lists(c.id, v.iter().map(Vec::as_slice)),
                    Data::Packed(v) => b.zstrs(c.id, v.iter().map(|c| &c[..])),
                };
            }
            b.done();
        }
        w.finish()
    }
}

fn note(moved: &mut Moved, w: &Write) {
    match w {
        Write::Set { table, id, .. } | Write::Insert { table, id } => moved.wrote(*table, *id),
        Write::Remove { table, id } => moved.gone(*table, *id),
    }
}
