//! The codec's contract: whatever an encoder writes, the decoder reads back
//! unchanged; a byte stream of frames splits into the same frames at any
//! chunking; and no input, however mangled, panics a decoder.

mod pack;

use proptest::prelude::*;
use wire::*;

const HASH: u16 = 0x5A17;

fn text() -> impl Strategy<Value = String> {
    prop_oneof![Just(String::new()), "[a-z]{1,12}", "\\PC{0,40}"]
}

#[derive(Clone, Debug)]
enum Column {
    U32(Vec<u32>),
    Str(Vec<String>),
    I64(Vec<i64>),
    F64(Vec<f64>),
    List(Vec<Vec<u32>>),
    Sym(Vec<String>),
}

fn column(n: usize) -> impl Strategy<Value = Column> {
    prop_oneof![
        prop::collection::vec(any::<u32>(), n).prop_map(Column::U32),
        prop::collection::vec(text(), n).prop_map(Column::Str),
        prop::collection::vec(any::<i64>(), n).prop_map(Column::I64),
        prop::collection::vec(prop_oneof![any::<f64>(), Just(f64::NAN)], n).prop_map(Column::F64),
        prop::collection::vec(prop::collection::vec(any::<u32>(), 0..4), n).prop_map(Column::List),
        prop::collection::vec(
            prop::sample::select(vec!["", "remote", "hybrid", "onsite"]).prop_map(String::from),
            n
        )
        .prop_map(Column::Sym),
    ]
}

fn block() -> impl Strategy<Value = (u16, usize, Vec<Column>)> {
    // A block with rows has at least one column; one without may have none.
    (1u16..200, 0usize..6).prop_flat_map(|(t, n)| {
        (
            Just(t),
            Just(n),
            prop::collection::vec(column(n), usize::from(n > 0)..5),
        )
    })
}

fn write_blocks(blocks: &[(u16, usize, Vec<Column>)]) -> Vec<u8> {
    let mut w = BodyWriter::new();
    for (t, n, cols) in blocks {
        let mut b = w.block(*t, *n);
        for (i, c) in cols.iter().enumerate() {
            let id = i as u16 + 1;
            match c {
                Column::U32(v) => b.u32s(id, v.iter().copied()),
                Column::Str(v) => b.strs(id, v.iter().map(|s| s.as_str())),
                Column::I64(v) => b.i64s(id, v.iter().copied()),
                Column::F64(v) => b.f64s(id, v.iter().copied()),
                Column::List(v) => b.lists(id, v.iter().map(|l| l.as_slice())),
                Column::Sym(v) => b.syms(id, v.iter().map(|s| s.as_str())),
            };
        }
    }
    w.finish()
}

fn expect(c: &Column, i: usize) -> Value<'_> {
    match c {
        Column::U32(v) if v[i] == NONE => Value::None,
        Column::U32(v) => Value::U32(v[i]),
        Column::Str(v) | Column::Sym(v) if v[i].is_empty() => Value::None,
        Column::Str(v) | Column::Sym(v) => Value::Str(&v[i]),
        Column::I64(v) if v[i] == NONE64 => Value::None,
        Column::I64(v) => Value::I64(v[i]),
        Column::F64(v) if v[i].is_nan() => Value::None,
        Column::F64(v) => Value::F64(v[i]),
        Column::List(_) => unreachable!(),
    }
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 256,
        rng_seed: proptest::test_runner::RngSeed::Fixed(0x5A17_0002),
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn table_runs_round_trip(blocks in prop::collection::vec(block(), 0..4)) {
        let body = write_blocks(&blocks);
        let parsed = Blocks::new(&body).unwrap();
        let read: Vec<_> = parsed.iter().collect();
        prop_assert_eq!(read.len(), blocks.len());
        for (b, (t, n, cols)) in read.iter().zip(&blocks) {
            prop_assert_eq!((b.table, b.nrows), (*t, *n));
            for (i, c) in cols.iter().enumerate() {
                let col = b.col(i as u16 + 1).unwrap();
                for r in 0..*n {
                    match (c, col.value(r)) {
                        (Column::List(v), Value::List(l)) => prop_assert_eq!(l.iter().collect::<Vec<_>>(), v[r].clone()),
                        (Column::List(v), Value::None) => prop_assert!(v[r].is_empty()),
                        (c, got) => prop_assert_eq!(got, expect(c, r)),
                    }
                }
            }
        }
    }

    #[test]
    fn frames_survive_zstd_and_any_chunking(
        blocks in prop::collection::vec(block(), 1..4),
        rev in any::<u64>(),
        cuts in prop::collection::vec(1usize..64, 0..20),
    ) {
        let body = write_blocks(&blocks);
        let packed = pack::frame(PONG, HASH, &body);
        let ping = encode_ping(PONG, HASH, rev);
        let stream: Vec<u8> = [packed.clone(), ping.clone()].concat();

        // Feed the stream in arbitrary chunks, splitting frames as they complete.
        let mut buf = Vec::new();
        let mut frames = Vec::new();
        let mut at = 0usize;
        for cut in cuts.iter().copied().chain(std::iter::once(usize::MAX)) {
            let end = at.saturating_add(cut).min(stream.len());
            buf.extend_from_slice(&stream[at..end]);
            at = end;
            while let Some((_, f, rest)) = split(&buf, MAX_INFLATED).unwrap() {
                let (f, rest) = (f.to_vec(), rest.to_vec());
                frames.push(f);
                buf = rest;
            }
        }
        prop_assert_eq!(frames.len(), 2);
        let packed = Frame::parse(&frames[0], HASH).unwrap();
        prop_assert_eq!((packed.kind(), packed.header.flags), (PONG, ZSTD));
        prop_assert_eq!(&*packed.body().unwrap(), &body[..]);
        prop_assert_eq!(&frames[1], &ping);
    }

    #[test]
    fn small_frames_round_trip(
        cred in 1u8..3, snap in any::<u64>(), srev in any::<u64>(),
        secret in prop::collection::vec(any::<u8>(), 0..80), label in text(),
        masks in (any::<u16>(), any::<u16>(), any::<bool>(), any::<bool>()),
        acks in prop::collection::vec((any::<u64>(), any::<u64>(), any::<u32>()), 0..10),
        nacks in prop::collection::vec((any::<u64>(), any::<u16>(), text()), 0..10),
        reason in 0u8..5, id in any::<u32>(), ok in any::<bool>(),
    ) {
        let body = |f: &[u8]| Frame::parse(f, HASH).unwrap().raw_body().to_vec();
        macro_rules! rt {
            ($dec:expr, $frame:expr, $want:expr) => {{
                let b = body(&$frame);
                prop_assert_eq!($dec(&b).unwrap(), $want);
            }};
        }

        let h = Hello { cred, snapshot_rev: snap, schema_rev: srev, credential: &secret, label: &label };
        rt!(Hello::decode, h.encode(HASH), h);

        let (read_mask, write_mask, may_delete, lease) = masks;
        let wl = Welcome { account_id: snap, session_id: srev, schema_rev: srev, read_mask, write_mask, may_delete, lease, features: 1, label: &label };
        rt!(Welcome::decode, wl.encode(HASH, 9), wl);

        let a: Vec<Ack> = acks.iter().map(|&(op_id, rev, id)| Ack { op_id, rev, id }).collect();
        rt!(decode_acks, encode_acks(HASH, 1, &a), a);

        let n: Vec<Nack> = nacks.iter().map(|(op_id, code, d)| Nack { op_id: *op_id, code: *code, data: d.as_bytes() }).collect();
        rt!(decode_nacks, encode_nacks(HASH, 1, &n), n);

        let b = Bye { reason, message: &label };
        rt!(Bye::decode, b.encode(HASH, 3), b);

        let r = Rpc { id, method: &label, params: &secret };
        rt!(Rpc::decode, r.encode(HASH), r);

        let rp = Reply { id, ok, json: &secret };
        rt!(Reply::decode, rp.encode(HASH, 4), rp);
    }

    #[test]
    fn ops_round_trip(ops in prop::collection::vec(
        (any::<u64>(), 1u8..4, 0u8..4, any::<u16>(), any::<u32>(), prop::option::of(any::<u32>()),
         prop::collection::vec((0u8..5, any::<u32>(), any::<i64>(), any::<f64>(), text()), 0..6)),
        0..12,
    )) {
        let mut w = OpsWriter::new();
        for (op_id, verb, flags, table, target, rev, cells) in &ops {
            let mut o = w.op(*op_id, *verb, *flags, *table, *target, *rev);
            for (i, (ty, u, l, f, s)) in cells.iter().enumerate() {
                let col = i as u16 + 8;
                match ty {
                    0 => o.null(col),
                    1 => o.u32(col, *u),
                    2 => o.str(col, s),
                    3 => o.i64(col, *l),
                    _ => o.f64(col, *f),
                };
            }
        }
        let frame = w.frame(HASH);
        let f = Frame::parse(&frame, HASH).unwrap();
        let body = f.body().unwrap();
        let parsed = Ops::new(&body).unwrap();
        prop_assert_eq!(parsed.len(), ops.len());
        for (op, (op_id, verb, flags, table, target, rev, cells)) in parsed.iter().zip(&ops) {
            prop_assert_eq!((op.op_id, op.verb, op.table, op.target), (*op_id, *verb, *table, *target));
            prop_assert_eq!(op.has(EXPECT_REV), rev.is_some());
            prop_assert_eq!(op.expect_rev, rev.unwrap_or(0));
            prop_assert_eq!(op.flags & !EXPECT_REV, flags & !EXPECT_REV);
            // An op alone, as the kernel's judge receives it, reads the same.
            prop_assert_eq!(Op::one(op.raw).unwrap().op_id, op.op_id);
            let got: Vec<_> = op.cells().collect();
            prop_assert_eq!(got.len(), cells.len());
            for (c, (ty, u, l, f, s)) in got.iter().zip(cells) {
                let want = match ty {
                    0 => Value::None,
                    1 => Value::U32(*u),
                    2 if s.is_empty() => Value::None,
                    2 => Value::Str(s),
                    3 => Value::I64(*l),
                    _ => Value::F64(*f),
                };
                match (c.value(), want) {
                    (Value::F64(a), Value::F64(b)) => prop_assert_eq!(a.to_bits(), b.to_bits()),
                    (a, b) => prop_assert_eq!(a, b),
                }
            }
        }
    }

}

// A gone block's bytes by hand (u16 table | u16 1 | u32 n | GONE u32 column), and read back.
#[test]
fn gone_blocks_are_the_documented_bytes_and_delete_ids() {
    let mut g = BodyWriter::new();
    g.gone(9, &[4, 5]);
    let body = g.finish();
    let hex: String = body.iter().map(|x| format!("{x:02x}")).collect();
    assert_eq!(hex, "0900010002000000feff0100080000000400000005000000");
    let b = Blocks::new(&body).unwrap().iter().next().unwrap();
    assert_eq!((b.table, b.gone().unwrap().iter().collect::<Vec<_>>()), (9, vec![4, 5]));
}

#[test]
fn sentinel_cells_are_named() {
    let mut w = OpsWriter::new();
    w.op(1, PUT, 0, 2, 0, None)
        .u32(8, NONE)
        .i64(9, NONE64)
        .f64(10, f64::INFINITY)
        .f64(11, 1.5)
        .u32(12, 3)
        .str(13, "");
    let body = w.finish();
    let ops = Ops::new(&body).unwrap();
    let op = ops.iter().next().unwrap();
    let flags: Vec<bool> = op.cells().map(|c| c.is_sentinel()).collect();
    assert_eq!(flags, [true, true, true, false, false, false]);
    assert_eq!(op.cell(13).unwrap().value(), Value::None);
}

// The refusals the hand-built vectors do not name: each by its error.
#[test]
fn refusals_are_named() {
    let ok = encode_ping(PING, HASH, 1);
    assert_eq!(Frame::parse(&ok, HASH ^ 1).unwrap_err(), Error::Hash);
    assert!(split(&ok[..15], MAX_UP).unwrap().is_none());
    let (mut odd, mut huge, mut kind, mut flag) = (ok.clone(), ok.clone(), ok.clone(), ok);
    odd[0] = 23;
    assert_eq!(split(&odd, MAX_UP).unwrap_err(), Error::Len);
    huge[0..4].copy_from_slice(&((MAX_UP as u32) + 8).to_le_bytes());
    assert_eq!(split(&huge, MAX_UP).unwrap_err(), Error::Len);
    kind[4] = 99;
    assert_eq!(Frame::parse(&kind, HASH).unwrap_err(), Error::Kind);
    flag[5] = 0x40;
    assert_eq!(Frame::parse(&flag, HASH).unwrap_err(), Error::Body);

    let block = |table: u16, ncols: u16, nrows: u32, cols: &[u8]| {
        [&table.to_le_bytes()[..], &ncols.to_le_bytes(), &nrows.to_le_bytes(), cols].concat()
    };
    let col = |id: u16, ty: u8, data: &[u8], pad: u8| {
        let mut c = [&id.to_le_bytes()[..], &[ty, 0], &(data.len() as u32).to_le_bytes(), data].concat();
        c.resize(8 + data.len().div_ceil(8) * 8, pad);
        c
    };
    let one = col(1, U32, &7u32.to_le_bytes(), 0);
    assert!(Blocks::new(&block(3, 1, 1, &one)).is_ok());
    assert_eq!(Blocks::new(&block(0, 1, 1, &one)).unwrap_err(), Error::Body, "table 0");
    assert_eq!(Blocks::new(&block(3, 0, u32::MAX, &[])).unwrap_err(), Error::Body, "rows without columns");
    assert_eq!(Blocks::new(&block(3, 2, 1, &[one.clone(), one].concat())).unwrap_err(), Error::Body, "duplicate column");
    assert_eq!(Blocks::new(&block(3, 1, 1, &col(1, U32, &7u32.to_le_bytes(), 1))).unwrap_err(), Error::Body, "nonzero pad");
    let backwards = [0u32, 3, 1].iter().flat_map(|o| o.to_le_bytes()).chain(*b"abc").collect::<Vec<u8>>();
    assert_eq!(Blocks::new(&block(3, 1, 2, &col(2, STR, &backwards, 0))).unwrap_err(), Error::Str, "offsets run backwards");
}
