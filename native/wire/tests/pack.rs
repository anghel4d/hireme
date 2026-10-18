//! Packing as the server does it, against the dictionaries. A table run's
//! shuffle is the Elixir encoder's, crossed with this decoder in
//! test/hireme_web/codec_test.exs; these frames are of other kinds.

#![allow(dead_code)]

use wire::*;

fn zstd(bytes: &[u8], dict: &[u8]) -> Vec<u8> {
    let mut c = zstd::bulk::Compressor::with_dictionary(9, dict).unwrap();
    c.include_checksum(false).unwrap();
    c.include_contentsize(true).unwrap();
    c.compress(bytes).unwrap()
}

/// A frame of exactly these body bytes.
pub fn raw(kind: u8, flags: u8, hash: u16, rev: u64, body: &[u8]) -> Vec<u8> {
    let len = (16 + body.len()) as u32;
    [&len.to_le_bytes()[..], &[kind, flags], &hash.to_le_bytes(), &rev.to_le_bytes(), body].concat()
}

/// `u32 raw_len | u32 packed_len | packed | pad`.
pub fn zbody(raw_len: u32, packed: &[u8], pad: &[u8]) -> Vec<u8> {
    [&raw_len.to_le_bytes()[..], &(packed.len() as u32).to_le_bytes(), packed, pad].concat()
}

/// A ZSTD frame of `body` (not a table-run kind: those are shuffled first).
pub fn frame(kind: u8, hash: u16, body: &[u8]) -> Vec<u8> {
    let p = packed(body);
    raw(kind, ZSTD, hash, 0, &zbody(body.len() as u32, &p, &vec![0; pad8(8 + p.len()) - 8 - p.len()]))
}

/// zstd against the frame dictionary.
pub fn packed(bytes: &[u8]) -> Vec<u8> {
    zstd(bytes, FRAME_DICT)
}

/// A packed zstr cell of any bytes: tag 1 and a zstd frame against `dict`.
pub fn text_with(b: &[u8], dict: &[u8]) -> Vec<u8> {
    [&[1u8][..], &zstd(b, dict)].concat()
}

pub fn text(s: &str) -> Vec<u8> {
    text_with(s.as_bytes(), TEXT_DICT)
}
