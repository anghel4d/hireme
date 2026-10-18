//! hireme's wire v2 frame codec.
//!
//! `docs/rebuild.md` ("Wire v2") is the design; this comment is the byte
//! layout the design leaves to the codec, and the Elixir side
//! (`HiremeWeb.Wire.Codec`) and the browser's `wire.ts` mirror it exactly.
//!
//! Everything is little-endian. A frame is a 16-byte header and a body:
//!
//! ```text
//! u32 len | u8 kind | u8 flags | u16 wire_hash | u64 rev | body
//! ```
//!
//! `len` counts the whole frame and is a multiple of 8, so a stream of
//! frames is split by reading `len`. Flags: `DEFLATE 0x01` (the body is
//! `u32 raw_len | u32 deflated_len | raw DEFLATE bytes | pad`; inflated it
//! is the plain body), `END 0x02` (the last frame of a burst). `rev` is the
//! account's rev as of the frame, 0 where it means nothing (up frames).
//!
//! A *field* is `u32 len | bytes | zero pad to 8`. Fixed parts are
//! multiples of 8, so every field and every column starts 8-aligned from
//! the frame start (and from the body start: the header is 16 bytes).
//!
//! ```text
//! HELLO   1 up    u8 cred (1 ticket, 2 key) | 7×0 | u64 snapshot_rev | u64 schema_rev
//!                 | field credential | field client_label
//! WELCOME 2 down  u64 account_id | u64 session_id | u64 schema_rev | u16 read_mask
//!                 | u16 write_mask | u8 may_delete | u8 lease (0 none, 1 held) | u16 0
//!                 | field session_label
//! BOOT    3 down  table runs (below), replacing every table they name
//! PATCH   4 down  table runs: changed rows (id + moved columns) and gone blocks
//! OPS     8 up    u32 n | u32 0 | n ops (below), n ≤ 256
//! ACK     9 down  u32 n | u32 0 | n × (u64 op_id | u64 rev | u32 id | u32 0)
//! NACK   10 down  u32 n | u32 0 | n × (u64 op_id | u16 code | u16 0 | u32 0 | field data_json)
//! TICK   11 down  table runs (`clock`)
//! PING   13 both  u64 nonce
//! PONG   14 both  u64 nonce, echoed
//! BYE    16 down  u8 reason (the `bye` enum: 0 revoked, 1 grants, 2 restart, 3 schema, 4 suspended) | 7×0
//!                 | field message
//! RPC    33 up    u32 id | u32 0 | field method | field params_json
//! REPLY  34 down  u32 id | u8 ok (1, 0) | 3×0 | field result_or_error_json
//! ```
//!
//! ACK's `rev` is the op's target row's rev after the write and `id` its id
//! (the new id for an insert). NACK's `code` is the index of the refusal in
//! the schema's `refusal` enum.
//!
//! **Table runs.** A BOOT, PATCH or TICK body is a sequence of blocks:
//!
//! ```text
//! block := u16 table | u16 ncols | u32 nrows | col × ncols
//! col   := u16 col | u8 type | u8 0 | u32 byte_len | data | zero pad to 8
//! ```
//!
//! Column types and their data for `nrows` rows:
//!
//! | type | name | data | none |
//! | --- | --- | --- | --- |
//! | 1 | u32 | `u32 × nrows` (ids, refs, bools, u8, u32, days, times as unix seconds, enum codes) | `0xFFFF_FFFF` |
//! | 2 | str | `u32 offsets × (nrows + 1)` from 0, then UTF-8 (str, text, json) | empty |
//! | 3 | i64 | `i64 × nrows` | `i64::MIN` |
//! | 4 | f64 | `f64 × nrows` | NaN |
//! | 5 | deferred | `(u32 len, 8 bytes of SHA-256) × nrows`, 12 bytes each | len `0xFFFF_FFFF` |
//! | 6 | sym | `u32 nuniq`, `u32 offsets × (nuniq + 1)`, UTF-8, pad to 4, `u32 × nrows` naming one | empty |
//! | 7 | list | `u32 offsets × (nrows + 1)` into the u32 values that follow | empty |
//!
//! Codes 1–5 are the schema's wire types; 6 and 7 are encodings a writer
//! may pick for a column (a str of few distinct values; a list of ids).
//! A null and an empty string are the same thing: the sequencer stores a
//! put of `""` as NULL, so the database never holds an empty string.
//!
//! A *gone* block deletes rows of the table it names: its only column is
//! [`GONE`] (0xFFFE) of type u32, holding the deleted ids. A PATCH block
//! carries the table's `id` column and only the columns that moved. Table
//! ids start at 1, and a block with no columns has no rows.
//!
//! **Ops.** One op in OPS:
//!
//! ```text
//! u64 op_id | u8 verb (put 1, drop 2, command 3) | u8 flags (KEYED 1, CREATE_ONLY 2, EXPECT_REV 4)
//! | u16 table_or_command | u32 target (0 when keyed or new) | u16 ncols | u16 0 | u32 expect_rev
//! | cell × ncols
//! cell := u16 col | u8 type | u8 0 | u32 len | bytes | zero pad to 8
//! ```
//!
//! An op cell's type is null (0, len 0: clears the column), u32 (1, len
//! 4), str (2, UTF-8), i64 (3, len 8) or f64 (4, len 8); a cell holding its
//! type's null sentinel (or a non-finite f64, see [`Cell::is_sentinel`]) is refused
//! `type` by the sequencer, and an empty str
//! cell writes NULL; [`AS_OF`] and
//! [`SOURCE`] are reserved column ids. The server never casts a string
//! into another type.
//!
//! WELCOME's `session_label` and BYE's `message` go beyond the design's
//! list of their contents: the label is what `leases` shows for the
//! session, and the message says why in words.
//!
//! **Limits.** An up frame is at most [`MAX_UP`] (16 MiB), inflated as
//! well; a client with more to send splits it across frames
//! ([`OpsWriter::is_full`]). One OPS frame holds at most [`MAX_OPS`] (256)
//! ops, and one op at most [`MAX_OP_TEXT`] (1 MiB) of text, past which the
//! server refuses it `too_large`. A down body inflates to at most
//! [`MAX_INFLATED`]. [`LAYOUT`] numbers this layout; the schema's
//! `wire_hash` folds it in.
//!
//! The crate is `no_std` + `alloc`, `unsafe`-free, and validates every
//! length once at parse time with checked arithmetic, on 32-bit (wasm) as
//! on 64-bit targets; accessors after that are plain slices.

#![no_std]
#![forbid(unsafe_code)]

extern crate alloc;

use alloc::vec::Vec;
use core::str;

pub const HEADER: usize = 16;

/// Bumped whenever a byte layout below changes, so the schema's `wire_hash`
/// (which folds it in) refuses a client built against another layout.
pub const LAYOUT: u16 = 2;

/// Frame kinds.
pub const HELLO: u8 = 1;
pub const WELCOME: u8 = 2;
pub const BOOT: u8 = 3;
pub const PATCH: u8 = 4;
pub const OPS: u8 = 8;
pub const ACK: u8 = 9;
pub const NACK: u8 = 10;
pub const TICK: u8 = 11;
pub const PING: u8 = 13;
pub const PONG: u8 = 14;
pub const BYE: u8 = 16;
pub const RPC: u8 = 33;
pub const REPLY: u8 = 34;

const KINDS: [u8; 13] = [
    HELLO, WELCOME, BOOT, PATCH, OPS, ACK, NACK, TICK, PING, PONG, BYE, RPC, REPLY,
];

/// Header flags.
pub const DEFLATE: u8 = 0x01;
pub const END: u8 = 0x02;

/// HELLO credential kinds.
pub const CRED_TICKET: u8 = 1;
pub const CRED_KEY: u8 = 2;

/// BYE reasons: the codes of the schema's `bye` enum (0-based, declaration order).
pub const BYE_REVOKED: u8 = 0;
pub const BYE_GRANTS: u8 = 1;
pub const BYE_RESTART: u8 = 2;
pub const BYE_SCHEMA: u8 = 3;
pub const BYE_SUSPENDED: u8 = 4;

/// Op verbs and flags.
pub const PUT: u8 = 1;
pub const DROP: u8 = 2;
pub const COMMAND: u8 = 3;
pub const KEYED: u8 = 0x01;
pub const CREATE_ONLY: u8 = 0x02;
pub const EXPECT_REV: u8 = 0x04;

/// Column and cell types.
pub const NULL: u8 = 0;
pub const U32: u8 = 1;
pub const STR: u8 = 2;
pub const I64: u8 = 3;
pub const F64: u8 = 4;
pub const DEFERRED: u8 = 5;
pub const SYM: u8 = 6;
pub const LIST: u8 = 7;

/// Reserved column ids.
pub const AS_OF: u16 = 0xFFF0;
pub const SOURCE: u16 = 0xFFF1;
pub const GONE: u16 = 0xFFFE;

/// "No value" in a u32 column, and in a deferred column's length.
pub const NONE: u32 = u32::MAX;
/// "No value" in an i64 column.
pub const NONE64: i64 = i64::MIN;

/// Ops per OPS frame.
pub const MAX_OPS: usize = 256;
/// Text one op may carry, summed over its cells (`too_large` past it).
pub const MAX_OP_TEXT: usize = 1 << 20;
/// The largest frame a peer may send up. 256 ops of 1 MiB each would be
/// 256 MiB; a client sending that much text splits it over frames.
pub const MAX_UP: usize = 16 << 20;
/// The largest body an inflate may produce.
pub const MAX_INFLATED: usize = 256 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// Fewer bytes than the header, a length or a count claims.
    Short,
    /// A frame length that is not a multiple of 8, below a header or over the limit.
    Len,
    /// The frame was encoded against another wire.
    Hash,
    /// A frame kind that is not this one, or unknown.
    Kind,
    /// A column or cell whose type or size does not fit.
    Column,
    /// Offsets that run backwards or past their bytes, or bad UTF-8.
    Str,
    /// A body that is not what its kind promises (nonzero pad, bad counts, trailing bytes).
    Body,
    /// A DEFLATE body that does not inflate to its stated length.
    Inflate,
}

pub type Result<T> = core::result::Result<T, Error>;

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let what = match self {
            Error::Short => "fewer bytes than a length claims",
            Error::Len => "a frame length that is not a multiple of 8, too small or over the limit",
            Error::Hash => "a frame of another wire",
            Error::Kind => "an unknown frame kind",
            Error::Column => "a column or cell that does not fit its type",
            Error::Str => "string offsets or UTF-8 that do not hold",
            Error::Body => "a body that is not what its kind promises",
            Error::Inflate => "a DEFLATE body that does not inflate to its stated length",
        };
        f.write_str(what)
    }
}

impl core::error::Error for Error {}

#[inline]
pub const fn pad8(n: usize) -> usize {
    (n + 7) & !7
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

/// Column ids seen so far in one block or op, as a bitmap over u16: a duplicate is O(1).
struct Seen([u64; 1024]);

impl Seen {
    fn new() -> Seen {
        Seen([0; 1024])
    }

    /// True when `id` had not been seen.
    fn add(&mut self, id: u16) -> bool {
        let (w, bit) = ((id >> 6) as usize, 1u64 << (id & 63));
        let fresh = self.0[w] & bit == 0;
        self.0[w] |= bit;
        fresh
    }
}

// ------------------------------------------------------------------ header

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub len: u32,
    pub kind: u8,
    pub flags: u8,
    pub hash: u16,
    pub rev: u64,
}

impl Header {
    /// Reads a header from the start of `b` without requiring the whole frame.
    pub fn peek(b: &[u8]) -> Result<Header> {
        if b.len() < HEADER {
            return Err(Error::Short);
        }
        let h = Header {
            len: u32_at(b, 0),
            kind: b[4],
            flags: b[5],
            hash: u16_at(b, 6),
            rev: u64_at(b, 8),
        };
        if (h.len as usize) < HEADER || h.len % 8 != 0 {
            return Err(Error::Len);
        }
        Ok(h)
    }

    fn write(&self, out: &mut [u8]) {
        out[0..4].copy_from_slice(&self.len.to_le_bytes());
        out[4] = self.kind;
        out[5] = self.flags;
        out[6..8].copy_from_slice(&self.hash.to_le_bytes());
        out[8..16].copy_from_slice(&self.rev.to_le_bytes());
    }
}

/// Splits the first whole frame off a byte stream: `Ok(None)` while more
/// bytes are needed, `Err` when the stream is not frames (or a frame is
/// over `max`).
pub fn split(buf: &[u8], max: usize) -> Result<Option<(Header, &[u8], &[u8])>> {
    if buf.len() < HEADER {
        return Ok(None);
    }
    let h = Header::peek(buf)?;
    let len = h.len as usize;
    if len > max {
        return Err(Error::Len);
    }
    if buf.len() < len {
        return Ok(None);
    }
    Ok(Some((h, &buf[..len], &buf[len..])))
}

/// One whole frame, checked against the wire hash.
#[derive(Clone, Copy, Debug)]
pub struct Frame<'a> {
    pub header: Header,
    raw: &'a [u8],
}

impl<'a> Frame<'a> {
    pub fn parse(b: &'a [u8], wire_hash: u16) -> Result<Frame<'a>> {
        let header = Header::peek(b)?;
        if header.len as usize != b.len() {
            return Err(if (header.len as usize) > b.len() {
                Error::Short
            } else {
                Error::Len
            });
        }
        if header.hash != wire_hash {
            return Err(Error::Hash);
        }
        if !KINDS.contains(&header.kind) {
            return Err(Error::Kind);
        }
        if header.flags & !(DEFLATE | END) != 0 {
            return Err(Error::Body);
        }
        Ok(Frame { header, raw: b })
    }

    pub fn kind(&self) -> u8 {
        self.header.kind
    }

    /// The body as sent; for a DEFLATE frame, the compressed form.
    pub fn raw_body(&self) -> &'a [u8] {
        &self.raw[HEADER..]
    }

    /// The plain body, inflated if needed, up to [`MAX_INFLATED`].
    pub fn body(&self) -> Result<Body<'a>> {
        self.body_max(MAX_INFLATED)
    }

    /// The plain body, refusing one that would inflate past `limit` bytes.
    /// A server reading a client's frame passes [`MAX_UP`]: compression must
    /// not let a small frame cost more than a large one.
    pub fn body_max(&self, limit: usize) -> Result<Body<'a>> {
        let b = self.raw_body();
        if self.header.flags & DEFLATE == 0 {
            return Ok(Body::Borrowed(b));
        }
        if b.len() < 8 {
            return Err(Error::Short);
        }
        let (raw_len, def_len) = (u32_at(b, 0) as usize, u32_at(b, 4) as usize);
        let end = 8usize.checked_add(def_len).ok_or(Error::Inflate)?;
        if raw_len > limit || raw_len % 8 != 0 || end > b.len() || pad8(end) != b.len() {
            return Err(Error::Inflate);
        }
        if b[end..].iter().any(|&z| z != 0) {
            return Err(Error::Body);
        }
        let out = miniz_oxide::inflate::decompress_to_vec_with_limit(&b[8..end], raw_len)
            .map_err(|_| Error::Inflate)?;
        if out.len() != raw_len {
            return Err(Error::Inflate);
        }
        Ok(Body::Owned(out))
    }
}

/// A frame body, borrowed from the frame or inflated into a buffer.
#[derive(Debug)]
pub enum Body<'a> {
    Borrowed(&'a [u8]),
    Owned(Vec<u8>),
}

impl core::ops::Deref for Body<'_> {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        match self {
            Body::Borrowed(b) => b,
            Body::Owned(v) => v,
        }
    }
}

// ------------------------------------------------------------------ writer

/// Builds one frame: header, then body writes, then [`Writer::finish`].
pub struct Writer {
    buf: Vec<u8>,
    kind: u8,
    flags: u8,
    hash: u16,
    rev: u64,
}

impl Writer {
    pub fn new(kind: u8, hash: u16, rev: u64) -> Writer {
        let mut buf = Vec::with_capacity(64);
        buf.resize(HEADER, 0);
        Writer {
            buf,
            kind,
            flags: 0,
            hash,
            rev,
        }
    }

    pub fn end(mut self) -> Writer {
        self.flags |= END;
        self
    }

    pub fn u8(&mut self, v: u8) -> &mut Self {
        self.buf.push(v);
        self
    }

    pub fn u16(&mut self, v: u16) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.buf.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub fn zeros(&mut self, n: usize) -> &mut Self {
        self.buf.resize(self.buf.len() + n, 0);
        self
    }

    pub fn pad(&mut self) -> &mut Self {
        self.buf.resize(pad8(self.buf.len()), 0);
        self
    }

    /// `u32 len | bytes | pad to 8`.
    pub fn field(&mut self, bytes: &[u8]) -> &mut Self {
        self.u32(bytes.len() as u32);
        self.buf.extend_from_slice(bytes);
        self.pad()
    }

    /// Appends an already-built body (table runs, ops); it must be a multiple of 8.
    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(b);
        self
    }

    pub fn finish(mut self) -> Vec<u8> {
        self.pad();
        let h = Header {
            len: self.buf.len() as u32,
            kind: self.kind,
            flags: self.flags,
            hash: self.hash,
            rev: self.rev,
        };
        h.write(&mut self.buf[..HEADER]);
        self.buf
    }

    /// Finishes with the body deflated when that is smaller.
    pub fn finish_deflated(mut self, level: u8) -> Vec<u8> {
        self.pad();
        let body = &self.buf[HEADER..];
        if body.len() < 256 {
            return self.finish();
        }
        let packed = miniz_oxide::deflate::compress_to_vec(body, level);
        if pad8(8 + packed.len()) >= body.len() {
            return self.finish();
        }
        let mut w = Writer::new(self.kind, self.hash, self.rev);
        w.flags = self.flags | DEFLATE;
        w.u32(body.len() as u32)
            .u32(packed.len() as u32)
            .bytes(&packed);
        w.finish()
    }
}

// ------------------------------------------------------------------ reader

/// Reads a body's fixed parts and fields, checking every length.
pub struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub fn new(b: &'a [u8]) -> Reader<'a> {
        Reader { b, at: 0 }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.at.checked_add(n).ok_or(Error::Short)?;
        let s = self.b.get(self.at..end).ok_or(Error::Short)?;
        self.at = end;
        Ok(s)
    }

    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }

    pub fn u16(&mut self) -> Result<u16> {
        Ok(u16_at(self.take(2)?, 0))
    }

    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32_at(self.take(4)?, 0))
    }

    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64_at(self.take(8)?, 0))
    }

    /// Skips `n` bytes that must be zero.
    pub fn zeros(&mut self, n: usize) -> Result<()> {
        if self.take(n)?.iter().all(|&z| z == 0) {
            Ok(())
        } else {
            Err(Error::Body)
        }
    }

    fn pad(&mut self) -> Result<()> {
        let n = pad8(self.at) - self.at;
        self.zeros(n)
    }

    pub fn field(&mut self) -> Result<&'a [u8]> {
        let n = self.u32()? as usize;
        let s = self.take(n)?;
        self.pad()?;
        Ok(s)
    }

    pub fn str_field(&mut self) -> Result<&'a str> {
        str::from_utf8(self.field()?).map_err(|_| Error::Str)
    }

    pub fn rest(&self) -> &'a [u8] {
        &self.b[self.at..]
    }

    pub fn done(&self) -> Result<()> {
        if self.at == self.b.len() {
            Ok(())
        } else {
            Err(Error::Body)
        }
    }
}

// ------------------------------------------------------------ small frames

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hello<'a> {
    pub cred: u8,
    pub snapshot_rev: u64,
    pub schema_rev: u64,
    pub credential: &'a [u8],
    pub label: &'a str,
}

impl<'a> Hello<'a> {
    pub fn encode(&self, hash: u16) -> Vec<u8> {
        let mut w = Writer::new(HELLO, hash, 0);
        w.u8(self.cred)
            .zeros(7)
            .u64(self.snapshot_rev)
            .u64(self.schema_rev);
        w.field(self.credential).field(self.label.as_bytes());
        w.finish()
    }

    pub fn decode(body: &'a [u8]) -> Result<Hello<'a>> {
        let mut r = Reader::new(body);
        let cred = r.u8()?;
        r.zeros(7)?;
        if !(CRED_TICKET..=CRED_KEY).contains(&cred) {
            return Err(Error::Body);
        }
        let h = Hello {
            cred,
            snapshot_rev: r.u64()?,
            schema_rev: r.u64()?,
            credential: r.field()?,
            label: r.str_field()?,
        };
        r.done()?;
        Ok(h)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Welcome<'a> {
    pub account_id: u64,
    pub session_id: u64,
    pub schema_rev: u64,
    pub read_mask: u16,
    pub write_mask: u16,
    pub may_delete: bool,
    pub lease: bool,
    pub label: &'a str,
}

impl<'a> Welcome<'a> {
    pub fn encode(&self, hash: u16, rev: u64) -> Vec<u8> {
        let mut w = Writer::new(WELCOME, hash, rev);
        w.u64(self.account_id)
            .u64(self.session_id)
            .u64(self.schema_rev);
        w.u16(self.read_mask)
            .u16(self.write_mask)
            .u8(self.may_delete as u8)
            .u8(self.lease as u8)
            .u16(0);
        w.field(self.label.as_bytes());
        w.finish()
    }

    pub fn decode(body: &'a [u8]) -> Result<Welcome<'a>> {
        let mut r = Reader::new(body);
        let (account_id, session_id, schema_rev) = (r.u64()?, r.u64()?, r.u64()?);
        let (read_mask, write_mask) = (r.u16()?, r.u16()?);
        let (may_delete, lease) = (r.u8()?, r.u8()?);
        r.zeros(2)?;
        if may_delete > 1 || lease > 1 {
            return Err(Error::Body);
        }
        let label = r.str_field()?;
        r.done()?;
        Ok(Welcome {
            account_id,
            session_id,
            schema_rev,
            read_mask,
            write_mask,
            may_delete: may_delete == 1,
            lease: lease == 1,
            label,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ack {
    pub op_id: u64,
    pub rev: u64,
    pub id: u32,
}

pub fn encode_acks(hash: u16, rev: u64, acks: &[Ack]) -> Vec<u8> {
    let mut w = Writer::new(ACK, hash, rev);
    w.u32(acks.len() as u32).u32(0);
    for a in acks {
        w.u64(a.op_id).u64(a.rev).u32(a.id).u32(0);
    }
    w.finish()
}

pub fn decode_acks(body: &[u8]) -> Result<Vec<Ack>> {
    let mut r = Reader::new(body);
    let n = r.u32()? as usize;
    r.zeros(4)?;
    if n > MAX_OPS {
        return Err(Error::Body);
    }
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let a = Ack {
            op_id: r.u64()?,
            rev: r.u64()?,
            id: r.u32()?,
        };
        r.zeros(4)?;
        out.push(a);
    }
    r.done()?;
    Ok(out)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Nack<'a> {
    pub op_id: u64,
    pub code: u16,
    pub data: &'a [u8],
}

pub fn encode_nacks(hash: u16, rev: u64, nacks: &[Nack]) -> Vec<u8> {
    let mut w = Writer::new(NACK, hash, rev);
    w.u32(nacks.len() as u32).u32(0);
    for n in nacks {
        w.u64(n.op_id).u16(n.code).u16(0).u32(0).field(n.data);
    }
    w.finish()
}

pub fn decode_nacks(body: &[u8]) -> Result<Vec<Nack<'_>>> {
    let mut r = Reader::new(body);
    let n = r.u32()? as usize;
    r.zeros(4)?;
    if n > MAX_OPS {
        return Err(Error::Body);
    }
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let op_id = r.u64()?;
        let code = r.u16()?;
        r.zeros(6)?;
        out.push(Nack {
            op_id,
            code,
            data: r.field()?,
        });
    }
    r.done()?;
    Ok(out)
}

/// PING or PONG.
pub fn encode_ping(kind: u8, hash: u16, nonce: u64) -> Vec<u8> {
    let mut w = Writer::new(kind, hash, 0);
    w.u64(nonce);
    w.finish()
}

pub fn decode_ping(body: &[u8]) -> Result<u64> {
    let mut r = Reader::new(body);
    let n = r.u64()?;
    r.done()?;
    Ok(n)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bye<'a> {
    pub reason: u8,
    pub message: &'a str,
}

impl<'a> Bye<'a> {
    pub fn encode(&self, hash: u16, rev: u64) -> Vec<u8> {
        let mut w = Writer::new(BYE, hash, rev);
        w.u8(self.reason).zeros(7).field(self.message.as_bytes());
        w.finish()
    }

    pub fn decode(body: &'a [u8]) -> Result<Bye<'a>> {
        let mut r = Reader::new(body);
        let reason = r.u8()?;
        r.zeros(7)?;
        if reason > BYE_SUSPENDED {
            return Err(Error::Body);
        }
        let b = Bye {
            reason,
            message: r.str_field()?,
        };
        r.done()?;
        Ok(b)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rpc<'a> {
    pub id: u32,
    pub method: &'a str,
    pub params: &'a [u8],
}

impl<'a> Rpc<'a> {
    pub fn encode(&self, hash: u16) -> Vec<u8> {
        let mut w = Writer::new(RPC, hash, 0);
        w.u32(self.id)
            .u32(0)
            .field(self.method.as_bytes())
            .field(self.params);
        w.finish()
    }

    pub fn decode(body: &'a [u8]) -> Result<Rpc<'a>> {
        let mut r = Reader::new(body);
        let id = r.u32()?;
        r.zeros(4)?;
        let rpc = Rpc {
            id,
            method: r.str_field()?,
            params: r.field()?,
        };
        r.done()?;
        Ok(rpc)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Reply<'a> {
    pub id: u32,
    pub ok: bool,
    pub json: &'a [u8],
}

impl<'a> Reply<'a> {
    pub fn encode(&self, hash: u16, rev: u64) -> Vec<u8> {
        let mut w = Writer::new(REPLY, hash, rev);
        w.u32(self.id).u8(self.ok as u8).zeros(3).field(self.json);
        w.finish()
    }

    pub fn decode(body: &'a [u8]) -> Result<Reply<'a>> {
        let mut r = Reader::new(body);
        let id = r.u32()?;
        let ok = r.u8()?;
        r.zeros(3)?;
        if ok > 1 {
            return Err(Error::Body);
        }
        let reply = Reply {
            id,
            ok: ok == 1,
            json: r.field()?,
        };
        r.done()?;
        Ok(reply)
    }
}

// ------------------------------------------------------------- table runs

/// One value read from a column or an op cell.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Value<'a> {
    None,
    U32(u32),
    I64(i64),
    F64(f64),
    Str(&'a str),
    /// A deferred text: its byte length and the first 8 bytes of its SHA-256.
    Deferred(u32, [u8; 8]),
    List(U32s<'a>),
}

/// A run of little-endian u32s.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct U32s<'a>(&'a [u8]);

impl<'a> U32s<'a> {
    pub fn len(&self) -> usize {
        self.0.len() / 4
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn get(&self, i: usize) -> u32 {
        u32_at(self.0, i * 4)
    }

    pub fn iter(&self) -> impl Iterator<Item = u32> + use<'a> {
        self.0
            .chunks_exact(4)
            .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
    }
}

/// One validated column of a block.
#[derive(Clone, Copy, Debug)]
pub struct Col<'a> {
    pub id: u16,
    pub ty: u8,
    nrows: usize,
    data: &'a [u8],
}

/// Checks offsets `(n + 1) × u32` from 0, monotonic, ending at `bytes.len()`
/// on char boundaries of valid UTF-8.
fn check_strs(offsets: &[u8], n: usize, bytes: &[u8]) -> Result<()> {
    let s = str::from_utf8(bytes).map_err(|_| Error::Str)?;
    let mut prev = 0usize;
    for i in 0..=n {
        let o = u32_at(offsets, i * 4) as usize;
        if (i == 0 && o != 0) || o < prev || o > bytes.len() || !s.is_char_boundary(o) {
            return Err(Error::Str);
        }
        prev = o;
    }
    if prev != bytes.len() {
        Err(Error::Str)
    } else {
        Ok(())
    }
}

impl<'a> Col<'a> {
    fn parse(ty: u8, nrows: usize, data: &'a [u8]) -> Result<()> {
        let fixed = |w: usize| {
            if nrows.checked_mul(w) == Some(data.len()) {
                Ok(())
            } else {
                Err(Error::Column)
            }
        };
        match ty {
            U32 => fixed(4),
            I64 | F64 => fixed(8),
            DEFERRED => fixed(12),
            STR | LIST => {
                let head = nrows
                    .checked_add(1)
                    .and_then(|n| n.checked_mul(4))
                    .ok_or(Error::Column)?;
                if data.len() < head {
                    return Err(Error::Column);
                }
                let (offsets, rest) = data.split_at(head);
                if ty == STR {
                    return check_strs(offsets, nrows, rest);
                }
                if rest.len() % 4 != 0 {
                    return Err(Error::Column);
                }
                let vals = rest.len() / 4;
                let mut prev = 0;
                for i in 0..=nrows {
                    let o = u32_at(offsets, i * 4) as usize;
                    if (i == 0 && o != 0) || o < prev || o > vals {
                        return Err(Error::Column);
                    }
                    prev = o;
                }
                if prev != vals {
                    Err(Error::Column)
                } else {
                    Ok(())
                }
            }
            SYM => {
                if data.len() < 4 {
                    return Err(Error::Column);
                }
                let nuniq = u32_at(data, 0) as usize;
                let off_end = nuniq
                    .checked_add(1)
                    .and_then(|n| n.checked_mul(4))
                    .and_then(|n| n.checked_add(4))
                    .ok_or(Error::Column)?;
                if data.len() < off_end {
                    return Err(Error::Column);
                }
                let last = u32_at(data, off_end - 4) as usize;
                let bytes_end = off_end
                    .checked_add(last)
                    .filter(|&e| e <= data.len())
                    .ok_or(Error::Column)?;
                let ids_at = bytes_end.checked_add(3).ok_or(Error::Column)? & !3;
                let ids_len = nrows.checked_mul(4).ok_or(Error::Column)?;
                if ids_at.checked_add(ids_len) != Some(data.len()) {
                    return Err(Error::Column);
                }
                check_strs(&data[4..off_end], nuniq, &data[off_end..bytes_end])?;
                if data[bytes_end..ids_at].iter().any(|&z| z != 0) {
                    return Err(Error::Column);
                }
                if (0..nrows).any(|i| u32_at(data, ids_at + i * 4) as usize >= nuniq) {
                    return Err(Error::Column);
                }
                Ok(())
            }
            _ => Err(Error::Column),
        }
    }

    pub fn nrows(&self) -> usize {
        self.nrows
    }

    pub fn data(&self) -> &'a [u8] {
        self.data
    }

    fn str_at(offsets: &'a [u8], bytes: &'a [u8], i: usize) -> &'a str {
        let (a, b) = (
            u32_at(offsets, i * 4) as usize,
            u32_at(offsets, i * 4 + 4) as usize,
        );
        // Validated in parse: whole UTF-8, offsets on char boundaries.
        str::from_utf8(&bytes[a..b]).unwrap_or("")
    }

    /// The value in row `i` (`i < nrows`). An empty str or list is `None`.
    pub fn value(&self, i: usize) -> Value<'a> {
        let d = self.data;
        match self.ty {
            U32 => match u32_at(d, i * 4) {
                NONE => Value::None,
                v => Value::U32(v),
            },
            I64 => match u64_at(d, i * 8) as i64 {
                NONE64 => Value::None,
                v => Value::I64(v),
            },
            F64 => match f64::from_bits(u64_at(d, i * 8)) {
                v if v.is_nan() => Value::None,
                v => Value::F64(v),
            },
            DEFERRED => match u32_at(d, i * 12) {
                NONE => Value::None,
                len => {
                    let mut sha = [0u8; 8];
                    sha.copy_from_slice(&d[i * 12 + 4..i * 12 + 12]);
                    Value::Deferred(len, sha)
                }
            },
            STR => {
                let (offsets, bytes) = d.split_at((self.nrows + 1) * 4);
                match Self::str_at(offsets, bytes, i) {
                    "" => Value::None,
                    s => Value::Str(s),
                }
            }
            SYM => {
                let nuniq = u32_at(d, 0) as usize;
                let off_end = 4 + (nuniq + 1) * 4;
                let bytes_end = off_end + u32_at(d, off_end - 4) as usize;
                let ids_at = (bytes_end + 3) & !3;
                let k = u32_at(d, ids_at + i * 4) as usize;
                match Self::str_at(&d[4..off_end], &d[off_end..bytes_end], k) {
                    "" => Value::None,
                    s => Value::Str(s),
                }
            }
            LIST => {
                let (offsets, vals) = d.split_at((self.nrows + 1) * 4);
                let (a, b) = (
                    u32_at(offsets, i * 4) as usize,
                    u32_at(offsets, i * 4 + 4) as usize,
                );
                if a == b {
                    Value::None
                } else {
                    Value::List(U32s(&vals[a * 4..b * 4]))
                }
            }
            _ => Value::None,
        }
    }

    /// For a u32 column: row `i` raw, `NONE` included.
    pub fn u32(&self, i: usize) -> u32 {
        if self.ty == U32 {
            u32_at(self.data, i * 4)
        } else {
            NONE
        }
    }
}

/// One validated block.
#[derive(Clone, Copy, Debug)]
pub struct Block<'a> {
    pub table: u16,
    pub nrows: usize,
    ncols: usize,
    cols: &'a [u8],
}

impl<'a> Block<'a> {
    pub fn cols(&self) -> impl Iterator<Item = Col<'a>> + use<'a> {
        let (mut at, nrows, b) = (0usize, self.nrows, self.cols);
        (0..self.ncols).map(move |_| {
            let (id, ty, len) = (u16_at(b, at), b[at + 2], u32_at(b, at + 4) as usize);
            let data = &b[at + 8..at + 8 + len];
            at = pad8(at + 8 + len);
            Col {
                id,
                ty,
                nrows,
                data,
            }
        })
    }

    pub fn col(&self, id: u16) -> Option<Col<'a>> {
        self.cols().find(|c| c.id == id)
    }

    /// The deleted ids, when this is a gone block.
    pub fn gone(&self) -> Option<U32s<'a>> {
        let c = self.col(GONE)?;
        (self.ncols == 1).then_some(U32s(c.data))
    }
}

/// Walks a BOOT, PATCH or TICK body. The whole body is validated when the
/// walker is made, so iteration cannot fail.
#[derive(Clone, Copy, Debug)]
pub struct Blocks<'a> {
    b: &'a [u8],
}

impl<'a> Blocks<'a> {
    pub fn new(b: &'a [u8]) -> Result<Blocks<'a>> {
        let mut at = 0;
        while at < b.len() {
            if b.len() - at < 8 {
                return Err(Error::Short);
            }
            let (table, ncols, nrows) = (
                u16_at(b, at),
                u16_at(b, at + 2) as usize,
                u32_at(b, at + 4) as usize,
            );
            // Tables are numbered from 1; a block with no columns has no rows.
            if table == 0 || (ncols == 0 && nrows != 0) {
                return Err(Error::Body);
            }
            at += 8;
            let mut seen = Seen::new();
            for _ in 0..ncols {
                if b.len() - at < 8 {
                    return Err(Error::Short);
                }
                let (id, ty, zero, len) = (
                    u16_at(b, at),
                    b[at + 2],
                    b[at + 3],
                    u32_at(b, at + 4) as usize,
                );
                if zero != 0 || !seen.add(id) {
                    return Err(Error::Body);
                }
                let end = (at + 8).checked_add(len).ok_or(Error::Short)?;
                if end > b.len() || pad8(end) > b.len() {
                    return Err(Error::Short);
                }
                if id == GONE && (ty != U32 || ncols != 1) {
                    return Err(Error::Column);
                }
                Col::parse(ty, nrows, &b[at + 8..end])?;
                if b[end..pad8(end)].iter().any(|&z| z != 0) {
                    return Err(Error::Body);
                }
                at = pad8(end);
            }
        }
        Ok(Blocks { b })
    }

    pub fn iter(&self) -> impl Iterator<Item = Block<'a>> + use<'a> {
        let b = self.b;
        let mut at = 0;
        core::iter::from_fn(move || {
            if at >= b.len() {
                return None;
            }
            let (table, ncols, nrows) = (
                u16_at(b, at),
                u16_at(b, at + 2) as usize,
                u32_at(b, at + 4) as usize,
            );
            let start = at + 8;
            let mut end = start;
            for _ in 0..ncols {
                end = pad8(end + 8 + u32_at(b, end + 4) as usize);
            }
            at = end;
            Some(Block {
                table,
                nrows,
                ncols,
                cols: &b[start..end],
            })
        })
    }
}

/// Builds a table-run body.
#[derive(Default)]
pub struct BodyWriter {
    buf: Vec<u8>,
}

/// Builds one block's columns; dropping it without [`BlockWriter::done`] still leaves a valid block.
pub struct BlockWriter<'w> {
    buf: &'w mut Vec<u8>,
    head: usize,
    nrows: usize,
    ncols: u16,
}

impl BodyWriter {
    pub fn new() -> BodyWriter {
        BodyWriter::default()
    }

    pub fn block(&mut self, table: u16, nrows: usize) -> BlockWriter<'_> {
        let head = self.buf.len();
        self.buf.extend_from_slice(&table.to_le_bytes());
        self.buf.extend_from_slice(&0u16.to_le_bytes());
        self.buf.extend_from_slice(&(nrows as u32).to_le_bytes());
        BlockWriter {
            buf: &mut self.buf,
            head,
            nrows,
            ncols: 0,
        }
    }

    pub fn gone(&mut self, table: u16, ids: &[u32]) {
        let mut b = self.block(table, ids.len());
        b.u32s(GONE, ids.iter().copied());
    }

    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    pub fn finish(self) -> Vec<u8> {
        self.buf
    }
}

impl BlockWriter<'_> {
    fn col(&mut self, id: u16, ty: u8, data: impl FnOnce(&mut Vec<u8>)) -> &mut Self {
        let at = self.buf.len();
        self.buf.extend_from_slice(&id.to_le_bytes());
        self.buf.push(ty);
        self.buf.push(0);
        self.buf.extend_from_slice(&0u32.to_le_bytes());
        data(self.buf);
        let len = (self.buf.len() - at - 8) as u32;
        self.buf[at + 4..at + 8].copy_from_slice(&len.to_le_bytes());
        self.buf.resize(pad8(self.buf.len()), 0);
        self.ncols += 1;
        let n = self.ncols.to_le_bytes();
        self.buf[self.head + 2..self.head + 4].copy_from_slice(&n);
        self
    }

    // Every column writer takes exactly `nrows` values; another count is a
    // caller's bug, and a frame the decoder would refuse, so it panics here.
    fn count(n: usize, got: usize) {
        assert!(got == n, "a column of {got} values in a block of {n} rows");
    }

    /// A u32 column; `NONE` marks an absent value.
    pub fn u32s(&mut self, id: u16, vals: impl Iterator<Item = u32>) -> &mut Self {
        let n = self.nrows;
        self.col(id, U32, |b| {
            Self::count(
                n,
                vals.map(|v| b.extend_from_slice(&v.to_le_bytes())).count(),
            )
        })
    }

    /// An i64 column; `NONE64` marks an absent value.
    pub fn i64s(&mut self, id: u16, vals: impl Iterator<Item = i64>) -> &mut Self {
        let n = self.nrows;
        self.col(id, I64, |b| {
            Self::count(
                n,
                vals.map(|v| b.extend_from_slice(&v.to_le_bytes())).count(),
            )
        })
    }

    /// An f64 column; NaN marks an absent value.
    pub fn f64s(&mut self, id: u16, vals: impl Iterator<Item = f64>) -> &mut Self {
        let n = self.nrows;
        self.col(id, F64, |b| {
            Self::count(
                n,
                vals.map(|v| b.extend_from_slice(&v.to_bits().to_le_bytes()))
                    .count(),
            )
        })
    }

    /// A str column; the empty string is absent.
    pub fn strs<'s>(&mut self, id: u16, vals: impl Iterator<Item = &'s str>) -> &mut Self {
        let n = self.nrows;
        self.col(id, STR, |b| {
            let (offsets, bytes) = offsets_and_bytes(vals.map(str::as_bytes));
            Self::count(n, offsets.len() - 1);
            offsets
                .iter()
                .for_each(|o| b.extend_from_slice(&o.to_le_bytes()));
            b.extend_from_slice(&bytes);
        })
    }

    /// A str column as a dictionary of its distinct values, for a column of few.
    pub fn syms<'s>(&mut self, id: u16, vals: impl Iterator<Item = &'s str>) -> &mut Self {
        let n = self.nrows;
        self.col(id, SYM, |b| {
            let mut uniq: Vec<&str> = Vec::new();
            let ids: Vec<u32> = vals
                .map(|v| match uniq.iter().position(|u| *u == v) {
                    Some(i) => i as u32,
                    None => {
                        uniq.push(v);
                        uniq.len() as u32 - 1
                    }
                })
                .collect();
            Self::count(n, ids.len());
            let (offsets, bytes) = offsets_and_bytes(uniq.iter().map(|u| u.as_bytes()));
            b.extend_from_slice(&(uniq.len() as u32).to_le_bytes());
            offsets
                .iter()
                .for_each(|o| b.extend_from_slice(&o.to_le_bytes()));
            let start = b.len();
            b.extend_from_slice(&bytes);
            b.resize(b.len() + (4 - (b.len() - start) % 4) % 4, 0);
            ids.iter()
                .for_each(|i| b.extend_from_slice(&i.to_le_bytes()));
        })
    }

    /// A deferred text column: `(length, first 8 bytes of SHA-256)` or absent.
    pub fn deferred(
        &mut self,
        id: u16,
        vals: impl Iterator<Item = Option<(u32, [u8; 8])>>,
    ) -> &mut Self {
        let n = self.nrows;
        self.col(id, DEFERRED, |b| {
            let got = vals
                .map(|v| {
                    let (len, sha) = v.unwrap_or((NONE, [0; 8]));
                    b.extend_from_slice(&len.to_le_bytes());
                    b.extend_from_slice(&sha);
                })
                .count();
            Self::count(n, got);
        })
    }

    /// A column of u32 lists; the empty list is absent.
    pub fn lists<'s>(&mut self, id: u16, vals: impl Iterator<Item = &'s [u32]>) -> &mut Self {
        let n = self.nrows;
        self.col(id, LIST, |b| {
            let mut offsets = alloc::vec![0u32];
            let mut values = Vec::new();
            for l in vals {
                values.extend(l.iter().flat_map(|v| v.to_le_bytes()));
                offsets.push((values.len() / 4) as u32);
            }
            Self::count(n, offsets.len() - 1);
            offsets
                .iter()
                .for_each(|o| b.extend_from_slice(&o.to_le_bytes()));
            b.extend_from_slice(&values);
        })
    }

    pub fn done(self) {}
}

/// `(n + 1)` offsets from 0 and the concatenated bytes of `n` values.
fn offsets_and_bytes<'s>(vals: impl Iterator<Item = &'s [u8]>) -> (Vec<u32>, Vec<u8>) {
    let mut offsets = alloc::vec![0u32];
    let mut bytes = Vec::new();
    for v in vals {
        bytes.extend_from_slice(v);
        offsets.push(bytes.len() as u32);
    }
    (offsets, bytes)
}

// -------------------------------------------------------------------- ops

/// One validated op cell.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cell<'a> {
    pub col: u16,
    pub ty: u8,
    pub bytes: &'a [u8],
}

impl<'a> Cell<'a> {
    /// The cell's value; an empty str is `None` (it writes NULL). A
    /// sentinel ([`Cell::is_sentinel`]) comes back as its raw value.
    pub fn value(&self) -> Value<'a> {
        match self.ty {
            U32 => Value::U32(u32_at(self.bytes, 0)),
            I64 => Value::I64(u64_at(self.bytes, 0) as i64),
            F64 => Value::F64(f64::from_bits(u64_at(self.bytes, 0))),
            STR if self.bytes.is_empty() => Value::None,
            // Validated UTF-8 at parse time.
            STR => Value::Str(str::from_utf8(self.bytes).unwrap_or("")),
            _ => Value::None,
        }
    }

    /// A cell holding its type's null sentinel or a non-finite float: the
    /// server refuses the op `type` (a clear is a NULL cell, never a sentinel).
    pub fn is_sentinel(&self) -> bool {
        match self.ty {
            U32 => u32_at(self.bytes, 0) == NONE,
            I64 => u64_at(self.bytes, 0) as i64 == NONE64,
            F64 => !f64::from_bits(u64_at(self.bytes, 0)).is_finite(),
            _ => false,
        }
    }
}

/// One validated op.
#[derive(Clone, Copy, Debug)]
pub struct Op<'a> {
    pub op_id: u64,
    pub verb: u8,
    pub flags: u8,
    pub table: u16,
    pub target: u32,
    pub expect_rev: u32,
    pub ncols: usize,
    /// The op's whole encoding, as the kernel's `judge` takes it.
    pub raw: &'a [u8],
}

const OP_HEAD: usize = 24;

impl<'a> Op<'a> {
    /// Reads one op from the start of `b`; returns it and the bytes after it.
    pub fn parse(b: &'a [u8]) -> Result<(Op<'a>, &'a [u8])> {
        if b.len() < OP_HEAD {
            return Err(Error::Short);
        }
        let op_id = u64_at(b, 0);
        let (verb, flags, table, target) = (b[8], b[9], u16_at(b, 10), u32_at(b, 12));
        let (ncols, zero, expect_rev) = (u16_at(b, 16) as usize, u16_at(b, 18), u32_at(b, 20));
        if !(PUT..=COMMAND).contains(&verb)
            || flags & !(KEYED | CREATE_ONLY | EXPECT_REV) != 0
            || zero != 0
        {
            return Err(Error::Body);
        }
        if flags & EXPECT_REV == 0 && expect_rev != 0 {
            return Err(Error::Body);
        }
        let mut at = OP_HEAD;
        let mut seen = Seen::new();
        for _ in 0..ncols {
            if b.len() - at < 8 {
                return Err(Error::Short);
            }
            let (col, ty, z, len) = (
                u16_at(b, at),
                b[at + 2],
                b[at + 3],
                u32_at(b, at + 4) as usize,
            );
            let end = (at + 8).checked_add(len).ok_or(Error::Short)?;
            if z != 0 || !seen.add(col) {
                return Err(Error::Body);
            }
            if end > b.len() || pad8(end) > b.len() {
                return Err(Error::Short);
            }
            let ok = match ty {
                NULL => len == 0,
                U32 => len == 4,
                I64 | F64 => len == 8,
                STR => str::from_utf8(&b[at + 8..end]).is_ok(),
                _ => false,
            };
            if !ok {
                return Err(Error::Column);
            }
            if b[end..pad8(end)].iter().any(|&z| z != 0) {
                return Err(Error::Body);
            }
            at = pad8(end);
        }
        let op = Op {
            op_id,
            verb,
            flags,
            table,
            target,
            expect_rev,
            ncols,
            raw: &b[..at],
        };
        Ok((op, &b[at..]))
    }

    /// Parses exactly one op and nothing after it.
    pub fn one(b: &'a [u8]) -> Result<Op<'a>> {
        match Op::parse(b)? {
            (op, []) => Ok(op),
            _ => Err(Error::Body),
        }
    }

    pub fn cells(&self) -> impl Iterator<Item = Cell<'a>> + use<'a> {
        let b = self.raw;
        let mut at = OP_HEAD;
        (0..self.ncols).map(move |_| {
            let (col, ty, len) = (u16_at(b, at), b[at + 2], u32_at(b, at + 4) as usize);
            let bytes = &b[at + 8..at + 8 + len];
            at = pad8(at + 8 + len);
            Cell { col, ty, bytes }
        })
    }

    pub fn cell(&self, col: u16) -> Option<Cell<'a>> {
        self.cells().find(|c| c.col == col)
    }

    /// Text bytes the op carries, for the `too_large` limit.
    pub fn text_len(&self) -> usize {
        self.cells()
            .filter(|c| c.ty == STR)
            .map(|c| c.bytes.len())
            .sum()
    }

    pub fn has(&self, flag: u8) -> bool {
        self.flags & flag != 0
    }
}

/// Walks an OPS body. Like [`Blocks`], all of it is validated up front, so
/// a malformed frame is refused whole and a well-formed one yields every op.
#[derive(Clone, Copy, Debug)]
pub struct Ops<'a> {
    n: usize,
    b: &'a [u8],
}

impl<'a> Ops<'a> {
    pub fn new(body: &'a [u8]) -> Result<Ops<'a>> {
        let mut r = Reader::new(body);
        let n = r.u32()? as usize;
        r.zeros(4)?;
        if n > MAX_OPS {
            return Err(Error::Body);
        }
        let b = r.rest();
        let mut rest = b;
        for _ in 0..n {
            rest = Op::parse(rest)?.1;
        }
        if !rest.is_empty() {
            return Err(Error::Body);
        }
        Ok(Ops { n, b })
    }

    pub fn len(&self) -> usize {
        self.n
    }

    pub fn is_empty(&self) -> bool {
        self.n == 0
    }

    pub fn iter(&self) -> impl Iterator<Item = Op<'a>> + use<'a> {
        let mut rest = self.b;
        (0..self.n).map(move |_| {
            let (op, r) = Op::parse(rest).expect("validated in Ops::new");
            rest = r;
            op
        })
    }
}

/// Builds an OPS body; [`OpsWriter::frame`] wraps it.
#[derive(Default)]
pub struct OpsWriter {
    buf: Vec<u8>,
    n: u32,
}

/// Builds one op's cells.
pub struct OpWriter<'w> {
    buf: &'w mut Vec<u8>,
    head: usize,
    ncols: u16,
}

impl OpsWriter {
    pub fn new() -> OpsWriter {
        let mut buf = Vec::with_capacity(256);
        buf.resize(8, 0);
        OpsWriter { buf, n: 0 }
    }

    pub fn op(
        &mut self,
        op_id: u64,
        verb: u8,
        flags: u8,
        table: u16,
        target: u32,
        expect_rev: Option<u32>,
    ) -> OpWriter<'_> {
        self.n += 1;
        let n = self.n.to_le_bytes();
        self.buf[0..4].copy_from_slice(&n);
        let head = self.buf.len();
        let flags = if expect_rev.is_some() {
            flags | EXPECT_REV
        } else {
            flags & !EXPECT_REV
        };
        self.buf.extend_from_slice(&op_id.to_le_bytes());
        self.buf.push(verb);
        self.buf.push(flags);
        self.buf.extend_from_slice(&table.to_le_bytes());
        self.buf.extend_from_slice(&target.to_le_bytes());
        self.buf.extend_from_slice(&[0; 4]);
        self.buf
            .extend_from_slice(&expect_rev.unwrap_or(0).to_le_bytes());
        OpWriter {
            buf: &mut self.buf,
            head,
            ncols: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.n as usize
    }

    pub fn is_empty(&self) -> bool {
        self.n == 0
    }

    /// Whether the frame holds [`MAX_OPS`] ops, or `bytes` more would take
    /// it past [`MAX_UP`]: the caller sends it and starts another.
    pub fn is_full(&self, bytes: usize) -> bool {
        self.n as usize >= MAX_OPS || HEADER + self.buf.len() + bytes > MAX_UP
    }

    pub fn finish(self) -> Vec<u8> {
        self.buf
    }

    pub fn frame(self, hash: u16) -> Vec<u8> {
        let mut w = Writer::new(OPS, hash, 0);
        w.bytes(&self.buf);
        w.finish()
    }
}

impl OpWriter<'_> {
    fn cell(&mut self, col: u16, ty: u8, bytes: &[u8]) -> &mut Self {
        self.buf.extend_from_slice(&col.to_le_bytes());
        self.buf.push(ty);
        self.buf.push(0);
        self.buf
            .extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        self.buf.extend_from_slice(bytes);
        self.buf.resize(pad8(self.buf.len()), 0);
        self.ncols += 1;
        let n = self.ncols.to_le_bytes();
        self.buf[self.head + 16..self.head + 18].copy_from_slice(&n);
        self
    }

    pub fn null(&mut self, col: u16) -> &mut Self {
        self.cell(col, NULL, &[])
    }

    pub fn u32(&mut self, col: u16, v: u32) -> &mut Self {
        self.cell(col, U32, &v.to_le_bytes())
    }

    pub fn i64(&mut self, col: u16, v: i64) -> &mut Self {
        self.cell(col, I64, &v.to_le_bytes())
    }

    pub fn f64(&mut self, col: u16, v: f64) -> &mut Self {
        self.cell(col, F64, &v.to_bits().to_le_bytes())
    }

    pub fn str(&mut self, col: u16, v: &str) -> &mut Self {
        self.cell(col, STR, v.as_bytes())
    }

    pub fn done(self) {}
}
