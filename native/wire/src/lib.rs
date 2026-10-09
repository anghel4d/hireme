//! hireme's frame codec.
//!
//! One frame is a 16-byte header and a body:
//!
//! ```text
//! u32 len | u8 kind | u8 flags | u16 schema_hash | u64 rev | body
//! ```
//!
//! `len` counts the whole frame and is a multiple of 8. BOOT, PATCH,
//! FOCUS and LINES bodies are a run of self-describing columnar tables
//! (`u16 table | u16 ncols | u32 nrows | col*`, each column
//! `u16 col | u8 type | u8 0 | u32 byte_len | data | pad to 8`), so every
//! column starts 8-aligned from the frame start and can be viewed in
//! place. Ids, kinds and the hash come from `priv/wire/schema.txt`
//! through the generated [`schema`] module; the Elixir encoder reads the
//! same file.
//!
//! The crate is `no_std` with `alloc` (the encoder builds a `Vec`); it
//! defines no allocator or panic handler, so std programs (the gate,
//! hireme-mcp) and the WASM kernel use it alike. Decoding validates every
//! length once and then reads with plain bounds-checked slices: no
//! `unsafe`, no copies.

#![no_std]
#![forbid(unsafe_code)]

extern crate alloc;

use alloc::vec::Vec;

/// Ids generated from `priv/wire/schema.txt`.
pub mod schema {
    /// One column the schema names. `ty` is the wire type; `kind` is the
    /// schema's own word for it (`u32`, `day`, `time`, `str`, `u64`, `f64`).
    #[derive(Clone, Copy, Debug)]
    pub struct ColDef {
        pub table: u16,
        pub col: u16,
        pub ty: u8,
        pub name: &'static str,
        pub kind: &'static str,
    }

    /// One op kind and the strings that follow its target, in order.
    #[derive(Clone, Copy, Debug)]
    pub struct OpDef {
        pub kind: u8,
        pub name: &'static str,
        pub target: &'static str,
        pub fields: &'static [&'static str],
    }

    include!(concat!(env!("OUT_DIR"), "/schema.rs"));

    pub fn table_name(id: u16) -> Option<&'static str> {
        TABLES.iter().find(|t| t.0 == id).map(|t| t.1)
    }

    pub fn table_id(name: &str) -> Option<u16> {
        TABLES.iter().find(|t| t.1 == name).map(|t| t.0)
    }

    pub fn col_def(table: u16, col: u16) -> Option<&'static ColDef> {
        COLS.iter().find(|c| c.table == table && c.col == col)
    }

    pub fn col_id(table: u16, name: &str) -> Option<u16> {
        COLS.iter()
            .find(|c| c.table == table && c.name == name)
            .map(|c| c.col)
    }

    pub fn op_def(kind: u8) -> Option<&'static OpDef> {
        OPS.iter().find(|o| o.kind == kind)
    }

    pub fn frame_name(kind: u8) -> Option<&'static str> {
        FRAMES.iter().find(|f| f.0 == kind).map(|f| f.1)
    }

    pub fn refusal_name(code: u8) -> Option<&'static str> {
        REFUSALS.iter().find(|r| r.0 == code).map(|r| r.1)
    }
}

pub const HEADER: usize = 16;

/// Wire types.
pub const U32: u8 = 1;
pub const STR: u8 = 2;
pub const U64: u8 = 3;
pub const F64: u8 = 4;

/// "No value" in a u32 column (a day, a time, a count that is absent).
pub const NONE: u32 = u32::MAX;

/// Header flags.
pub const DEFLATE: u8 = 0x01;
pub const END: u8 = 0x02;
pub const AGENT: u8 = 0x80;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// Fewer bytes than the header or the length claims.
    Short,
    /// A length that is not a multiple of 8 or smaller than a header.
    Len,
    /// The frame was encoded against a different schema.
    Hash,
    /// A column whose type or size does not fit its row count.
    Column,
    /// Offsets that run backwards or past their bytes, or bad UTF-8.
    Str,
    /// A body that is not what its frame kind promises.
    Body,
}

#[inline]
fn u16_at(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

#[inline]
fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

#[inline]
fn u64_at(b: &[u8], at: usize) -> u64 {
    let mut w = [0u8; 8];
    w.copy_from_slice(&b[at..at + 8]);
    u64::from_le_bytes(w)
}

#[inline]
pub const fn pad8(n: usize) -> usize {
    (n + 7) & !7
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub len: u32,
    pub kind: u8,
    pub flags: u8,
    pub hash: u16,
    pub rev: u64,
}

impl Header {
    /// Reads a header. Checks the length's shape, not the hash: a reader
    /// that wants to refuse foreign frames calls [`Header::check`].
    pub fn parse(b: &[u8]) -> Result<Header, Error> {
        if b.len() < HEADER {
            return Err(Error::Short);
        }
        let len = u32_at(b, 0);
        if (len as usize) < HEADER || !len.is_multiple_of(8) {
            return Err(Error::Len);
        }
        Ok(Header {
            len,
            kind: b[4],
            flags: b[5],
            hash: u16_at(b, 6),
            rev: u64_at(b, 8),
        })
    }

    pub fn check(&self) -> Result<(), Error> {
        if self.hash == schema::HASH {
            Ok(())
        } else {
            Err(Error::Hash)
        }
    }

    pub fn bytes(&self) -> [u8; HEADER] {
        let mut o = [0u8; HEADER];
        o[0..4].copy_from_slice(&self.len.to_le_bytes());
        o[4] = self.kind;
        o[5] = self.flags;
        o[6..8].copy_from_slice(&self.hash.to_le_bytes());
        o[8..16].copy_from_slice(&self.rev.to_le_bytes());
        o
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Frame<'a> {
    pub header: Header,
    /// The body without padding guarantees beyond the frame's own `len`.
    pub body: &'a [u8],
}

impl<'a> Frame<'a> {
    /// The first frame in `b`, which must hold all of it.
    pub fn parse(b: &'a [u8]) -> Result<Frame<'a>, Error> {
        let header = Header::parse(b)?;
        let len = header.len as usize;
        if b.len() < len {
            return Err(Error::Short);
        }
        Ok(Frame {
            header,
            body: &b[HEADER..len],
        })
    }

    /// The body's tables. Only meaningful for table-bodied kinds.
    pub fn tables(&self) -> Tables<'a> {
        Tables {
            b: self.body,
            at: 0,
        }
    }
}

/// Splits a buffer of whole frames.
pub fn frames(b: &[u8]) -> Frames<'_> {
    Frames { b, at: 0 }
}

pub struct Frames<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Iterator for Frames<'a> {
    type Item = Result<Frame<'a>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.at >= self.b.len() {
            return None;
        }
        match Frame::parse(&self.b[self.at..]) {
            Ok(f) => {
                self.at += f.header.len as usize;
                Some(Ok(f))
            }
            Err(e) => {
                self.at = self.b.len();
                Some(Err(e))
            }
        }
    }
}

pub struct Tables<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Iterator for Tables<'a> {
    type Item = Result<Table<'a>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.at + 8 > self.b.len() {
            return None;
        }
        match Table::parse(&self.b[self.at..]) {
            Ok((t, used)) => {
                self.at += used;
                Some(Ok(t))
            }
            Err(e) => {
                self.at = self.b.len();
                Some(Err(e))
            }
        }
    }
}

/// One table block: validated columns over borrowed bytes.
#[derive(Clone, Copy, Debug)]
pub struct Table<'a> {
    pub id: u16,
    pub ncols: u16,
    pub nrows: u32,
    cols: &'a [u8],
}

impl<'a> Table<'a> {
    /// Reads and validates one table block; returns it and its byte size.
    pub fn parse(b: &'a [u8]) -> Result<(Table<'a>, usize), Error> {
        if b.len() < 8 {
            return Err(Error::Short);
        }
        let id = u16_at(b, 0);
        let ncols = u16_at(b, 2);
        let nrows = u32_at(b, 4);
        let mut at = 8;
        for _ in 0..ncols {
            let (_, used) = Col::parse(&b[at..], nrows)?;
            at += used;
        }
        Ok((
            Table {
                id,
                ncols,
                nrows,
                cols: &b[8..at],
            },
            at,
        ))
    }

    pub fn cols(&self) -> Cols<'a> {
        Cols {
            b: self.cols,
            at: 0,
            nrows: self.nrows,
        }
    }

    pub fn col(&self, id: u16) -> Option<Col<'a>> {
        self.cols().find(|c| c.id == id)
    }
}

pub struct Cols<'a> {
    b: &'a [u8],
    at: usize,
    nrows: u32,
}

impl<'a> Iterator for Cols<'a> {
    type Item = Col<'a>;

    fn next(&mut self) -> Option<Col<'a>> {
        if self.at >= self.b.len() {
            return None;
        }
        // Validated when the table was parsed.
        let (c, used) = Col::parse(&self.b[self.at..], self.nrows).ok()?;
        self.at += used;
        Some(c)
    }
}

/// One column. `data` is exactly `byte_len` bytes.
#[derive(Clone, Copy, Debug)]
pub struct Col<'a> {
    pub id: u16,
    pub ty: u8,
    pub nrows: u32,
    pub data: &'a [u8],
}

impl<'a> Col<'a> {
    fn parse(b: &'a [u8], nrows: u32) -> Result<(Col<'a>, usize), Error> {
        if b.len() < 8 {
            return Err(Error::Short);
        }
        let id = u16_at(b, 0);
        let ty = b[2];
        let len = u32_at(b, 4) as usize;
        let used = 8 + pad8(len);
        if b.len() < 8 + len {
            return Err(Error::Short);
        }
        let data = &b[8..8 + len];
        let n = nrows as usize;
        match ty {
            U32 if len == n * 4 => {}
            U64 | F64 if len == n * 8 => {}
            STR => {
                let offs = (n + 1) * 4;
                if len < offs {
                    return Err(Error::Column);
                }
                let mut prev = 0;
                for i in 0..=n {
                    let o = u32_at(data, i * 4) as usize;
                    if o < prev || offs + o > len {
                        return Err(Error::Str);
                    }
                    prev = o;
                }
                if u32_at(data, 0) != 0 || core::str::from_utf8(&data[offs..]).is_err() {
                    return Err(Error::Str);
                }
            }
            // An unknown type is skipped whole, like an unknown column.
            t if t > F64 => {}
            _ => return Err(Error::Column),
        }
        Ok((
            Col {
                id,
                ty,
                nrows,
                data,
            },
            used.min(b.len()),
        ))
    }

    #[inline]
    pub fn u32(&self, i: usize) -> u32 {
        u32_at(self.data, i * 4)
    }

    #[inline]
    pub fn u64(&self, i: usize) -> u64 {
        u64_at(self.data, i * 8)
    }

    #[inline]
    pub fn f64(&self, i: usize) -> f64 {
        f64::from_bits(self.u64(i))
    }

    /// The UTF-8 bytes of row `i` of a str column.
    #[inline]
    pub fn bytes(&self, i: usize) -> &'a [u8] {
        let base = (self.nrows as usize + 1) * 4;
        let s = u32_at(self.data, i * 4) as usize;
        let e = u32_at(self.data, i * 4 + 4) as usize;
        &self.data[base + s..base + e]
    }

    /// Row `i` of a str column. The whole column was checked as UTF-8 and
    /// offsets land on whatever the encoder wrote; a split inside a
    /// character reads as empty rather than panicking.
    #[inline]
    pub fn str(&self, i: usize) -> &'a str {
        core::str::from_utf8(self.bytes(i)).unwrap_or("")
    }
}

/// An ACK body.
pub fn ack(body: &[u8]) -> Result<u64, Error> {
    if body.len() < 8 {
        Err(Error::Body)
    } else {
        Ok(u64_at(body, 0))
    }
}

/// A NACK body: op id, refusal code, message.
pub fn nack(body: &[u8]) -> Result<(u64, u8, &str), Error> {
    if body.len() < 12 {
        return Err(Error::Body);
    }
    let len = u16_at(body, 10) as usize;
    let msg = body.get(12..12 + len).ok_or(Error::Body)?;
    Ok((
        u64_at(body, 0),
        body[8],
        core::str::from_utf8(msg).map_err(|_| Error::Str)?,
    ))
}

/// A TICK body: the UTC day.
pub fn tick(body: &[u8]) -> Result<u32, Error> {
    if body.len() < 4 {
        Err(Error::Body)
    } else {
        Ok(u32_at(body, 0))
    }
}

/// An OP body: `u64 op_id | u8 kind | u8 nfields | u16 0 | u32 target |
/// (u16 len, utf8) * nfields | zero pad`. The count is explicit because
/// frame padding would otherwise read as empty fields.
#[derive(Clone, Copy, Debug)]
pub struct Op<'a> {
    pub id: u64,
    pub kind: u8,
    pub nfields: u8,
    pub target: u32,
    fields: &'a [u8],
}

impl<'a> Op<'a> {
    pub const FIXED: usize = 16;

    /// Reads an op whose kind the schema names, carrying exactly the
    /// schema's number of fields, each whole and UTF-8.
    pub fn parse(body: &'a [u8]) -> Result<Op<'a>, Error> {
        if body.len() < Self::FIXED {
            return Err(Error::Body);
        }
        let op = Op {
            id: u64_at(body, 0),
            kind: body[8],
            nfields: body[9],
            target: u32_at(body, 12),
            fields: &body[Self::FIXED..],
        };
        let want = schema::op_def(op.kind).ok_or(Error::Body)?.fields.len();
        if op.nfields as usize != want {
            return Err(Error::Body);
        }
        for f in op.fields() {
            f?;
        }
        Ok(op)
    }

    /// The strings after the target, in schema order.
    pub fn fields(&self) -> OpFields<'a> {
        OpFields {
            b: self.fields,
            at: 0,
            left: self.nfields,
        }
    }

    /// Field `i`, or "" if absent.
    pub fn field(&self, i: usize) -> &'a str {
        self.fields().nth(i).and_then(|f| f.ok()).unwrap_or("")
    }
}

pub struct OpFields<'a> {
    b: &'a [u8],
    at: usize,
    left: u8,
}

impl<'a> Iterator for OpFields<'a> {
    type Item = Result<&'a str, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.left == 0 {
            return None;
        }
        self.left -= 1;
        let s = (self.at + 2 <= self.b.len())
            .then(|| u16_at(self.b, self.at) as usize)
            .and_then(|len| {
                let s = self.b.get(self.at + 2..self.at + 2 + len);
                self.at += 2 + len;
                s
            });
        Some(match s {
            None => {
                self.left = 0;
                Err(Error::Body)
            }
            Some(s) => core::str::from_utf8(s).map_err(|_| Error::Str),
        })
    }
}

/// Builds frames. Tables are written column by column; the writer pads
/// every column and the frame to 8 and fills in the lengths.
pub struct Writer {
    pub buf: Vec<u8>,
    frame_at: usize,
    table_at: usize,
}

impl Default for Writer {
    fn default() -> Self {
        Self::new()
    }
}

impl Writer {
    pub fn new() -> Writer {
        Writer {
            buf: Vec::new(),
            frame_at: 0,
            table_at: usize::MAX,
        }
    }

    /// Starts a frame; the length is filled in by [`Writer::end`].
    pub fn begin(&mut self, kind: u8, flags: u8, rev: u64) {
        self.frame_at = self.buf.len();
        let h = Header {
            len: 0,
            kind,
            flags,
            hash: schema::HASH,
            rev,
        };
        self.buf.extend_from_slice(&h.bytes());
    }

    pub fn end(&mut self) {
        self.pad();
        let len = (self.buf.len() - self.frame_at) as u32;
        self.buf[self.frame_at..self.frame_at + 4].copy_from_slice(&len.to_le_bytes());
    }

    fn pad(&mut self) {
        let n = pad8(self.buf.len() - self.frame_at) - (self.buf.len() - self.frame_at);
        self.buf.extend(core::iter::repeat_n(0, n));
    }

    pub fn raw(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    pub fn table(&mut self, id: u16, nrows: u32) {
        self.table_at = self.buf.len();
        self.buf.extend_from_slice(&id.to_le_bytes());
        self.buf.extend_from_slice(&0u16.to_le_bytes());
        self.buf.extend_from_slice(&nrows.to_le_bytes());
    }

    fn col_head(&mut self, id: u16, ty: u8, len: usize) {
        let n = u16_at(&self.buf, self.table_at + 2) + 1;
        self.buf[self.table_at + 2..self.table_at + 4].copy_from_slice(&n.to_le_bytes());
        self.buf.extend_from_slice(&id.to_le_bytes());
        self.buf.push(ty);
        self.buf.push(0);
        self.buf.extend_from_slice(&(len as u32).to_le_bytes());
    }

    pub fn col_u32(&mut self, id: u16, vals: impl ExactSizeIterator<Item = u32>) {
        self.col_head(id, U32, vals.len() * 4);
        for v in vals {
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
        self.pad();
    }

    pub fn col_u64(&mut self, id: u16, ty: u8, vals: impl ExactSizeIterator<Item = u64>) {
        self.col_head(id, ty, vals.len() * 8);
        for v in vals {
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
        self.pad();
    }

    pub fn col_str<'s>(&mut self, id: u16, vals: impl ExactSizeIterator<Item = &'s [u8]> + Clone) {
        let n = vals.len();
        let total: usize = vals.clone().map(|s| s.len()).sum();
        self.col_head(id, STR, (n + 1) * 4 + total);
        let mut at = 0u32;
        self.buf.extend_from_slice(&0u32.to_le_bytes());
        for s in vals.clone() {
            at += s.len() as u32;
            self.buf.extend_from_slice(&at.to_le_bytes());
        }
        for s in vals {
            self.buf.extend_from_slice(s);
        }
        self.pad();
    }

    /// An OP frame body; `fields` in schema order.
    pub fn op(&mut self, id: u64, kind: u8, target: u32, fields: &[&str]) {
        self.raw(&id.to_le_bytes());
        self.buf.push(kind);
        self.buf.push(fields.len() as u8);
        self.raw(&[0, 0]);
        self.raw(&target.to_le_bytes());
        for f in fields {
            self.raw(&(f.len() as u16).to_le_bytes());
            self.raw(f.as_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec;

    #[test]
    fn a_table_frame_round_trips() {
        let mut w = Writer::new();
        w.begin(schema::frame::BOOT, END, 7);
        w.table(schema::table::CARDS, 3);
        w.col_u32(schema::col::cards::ID, [3u32, 1, 2].into_iter());
        let names: [&[u8]; 3] = [b"Acme", b"", b"Zo\xc3\xab"];
        w.col_str(schema::col::cards::COMPANY, names.into_iter());
        w.col_u64(
            99,
            F64,
            [1.5f64.to_bits(), 0, f64::NAN.to_bits()].into_iter(),
        );
        w.end();
        w.begin(schema::frame::ACK, 0, 8);
        w.raw(&42u64.to_le_bytes());
        w.end();

        let fs: Vec<_> = frames(&w.buf).collect::<Result<_, _>>().unwrap();
        assert_eq!(fs.len(), 2);
        assert_eq!(fs[0].header.rev, 7);
        fs[0].header.check().unwrap();
        assert_eq!(fs[0].header.len % 8, 0);
        let t = fs[0].tables().next().unwrap().unwrap();
        assert_eq!((t.id, t.ncols, t.nrows), (schema::table::CARDS, 3, 3));
        let ids = t.col(schema::col::cards::ID).unwrap();
        assert_eq!(vec![ids.u32(0), ids.u32(1), ids.u32(2)], vec![3, 1, 2]);
        let c = t.col(schema::col::cards::COMPANY).unwrap();
        assert_eq!((c.str(0), c.str(1), c.str(2)), ("Acme", "", "Zoë"));
        assert_eq!(t.col(99).unwrap().f64(0), 1.5);
        assert_eq!(ack(fs[1].body).unwrap(), 42);
    }

    #[test]
    fn broken_frames_are_refused_not_panicked_on() {
        let mut w = Writer::new();
        w.begin(schema::frame::PATCH, 0, 1);
        w.table(schema::table::CARDS, 2);
        w.col_str(
            schema::col::cards::ROLE,
            [b"ab".as_slice(), b"cd"].into_iter(),
        );
        w.end();
        // Every truncation and every single-byte corruption must decode to
        // an error or to something, never panic.
        for cut in 0..w.buf.len() {
            for f in frames(&w.buf[..cut]).flatten() {
                let _ = f.tables().count();
            }
        }
        for i in 0..w.buf.len() {
            for v in [0u8, 1, 0x7f, 0xff] {
                let mut b = w.buf.clone();
                b[i] = v;
                for f in frames(&b).flatten() {
                    for t in f.tables().flatten() {
                        for c in t.cols() {
                            for r in 0..t.nrows as usize {
                                match c.ty {
                                    STR => drop(c.str(r)),
                                    U32 => drop(c.u32(r)),
                                    U64 | F64 => drop(c.u64(r)),
                                    _ => {}
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn ops_read_their_fields_in_schema_order() {
        let mut w = Writer::new();
        w.op(9, schema::op::NEXT, 12, &["call back", "2026-10-10"]);
        let op = Op::parse(&w.buf).unwrap();
        assert_eq!((op.id, op.kind, op.target), (9, schema::op::NEXT, 12));
        assert_eq!(op.field(0), "call back");
        assert_eq!(op.field(1), "2026-10-10");
        assert!(Op::parse(&w.buf[..w.buf.len() - 1]).is_err());
        // Padding after the last field is not another field.
        let mut padded = w.buf.clone();
        padded.extend_from_slice(&[0; 7]);
        assert_eq!(Op::parse(&padded).unwrap().fields().count(), 2);
    }

    #[test]
    fn nack_carries_a_message() {
        let mut b = vec![];
        b.extend_from_slice(&5u64.to_le_bytes());
        b.extend_from_slice(&[schema::refusal::LEASED, 0]);
        b.extend_from_slice(&4u16.to_le_bytes());
        b.extend_from_slice(b"held");
        assert_eq!(nack(&b).unwrap(), (5, schema::refusal::LEASED, "held"));
    }
}
