//! The layout in the crate doc, checked byte by byte.
//!
//! Everything here is built by hand from the byte layout in the crate doc, never
//! through the crate's own writers, so a symmetric mistake in the writer and the
//! reader cannot hide. Each refusal vector breaks exactly one rule.

mod pack;

use wire::*;

const HASH: u16 = 0x5A17;

fn le16(v: u16) -> Vec<u8> {
    v.to_le_bytes().to_vec()
}
fn le32(v: u32) -> Vec<u8> {
    v.to_le_bytes().to_vec()
}
fn le64(v: u64) -> Vec<u8> {
    v.to_le_bytes().to_vec()
}
fn cat(parts: &[Vec<u8>]) -> Vec<u8> {
    parts.concat()
}
fn pad8(mut v: Vec<u8>) -> Vec<u8> {
    while !v.len().is_multiple_of(8) {
        v.push(0);
    }
    v
}
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A whole frame from the doc's header: `u32 len | u8 kind | u8 flags | u16 hash | u64 rev | body`.
fn frame(kind: u8, flags: u8, rev: u64, body: &[u8]) -> Vec<u8> {
    let body = pad8(body.to_vec());
    cat(&[
        le32(16 + body.len() as u32),
        vec![kind, flags],
        le16(HASH),
        le64(rev),
        body,
    ])
}

/// A field: `u32 len | bytes | zero pad to 8`.
fn field(b: &[u8]) -> Vec<u8> {
    pad8(cat(&[le32(b.len() as u32), b.to_vec()]))
}

/// A column: `u16 col | u8 type | u8 0 | u32 byte_len | data | zero pad to 8`.
fn col(id: u16, ty: u8, data: &[u8]) -> Vec<u8> {
    pad8(cat(&[
        le16(id),
        vec![ty, 0],
        le32(data.len() as u32),
        data.to_vec(),
    ]))
}

/// A block: `u16 table | u16 ncols | u32 nrows | col × ncols`.
fn block(table: u16, nrows: u32, cols: &[Vec<u8>]) -> Vec<u8> {
    cat(&[
        le16(table),
        le16(cols.len() as u16),
        le32(nrows),
        cols.concat(),
    ])
}

fn u32s(v: &[u32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}

/// A str column's data: offsets then bytes.
fn str_data(offsets: &[u32], bytes: &[u8]) -> Vec<u8> {
    cat(&[u32s(offsets), bytes.to_vec()])
}

/// A cell: `u16 col | u8 type | u8 0 | u32 len | bytes | zero pad to 8`.
fn cell(c: u16, ty: u8, bytes: &[u8]) -> Vec<u8> {
    pad8(cat(&[
        le16(c),
        vec![ty, 0],
        le32(bytes.len() as u32),
        bytes.to_vec(),
    ]))
}

/// One op: `u64 op_id | u8 verb | u8 flags | u16 table | u32 target | u16 ncols | u16 0 | u32 expect_rev | cells`.
fn op(verb: u8, flags: u8, expect_rev: u32, cells: &[Vec<u8>]) -> Vec<u8> {
    cat(&[
        le64(7),
        vec![verb, flags],
        le16(3),
        le32(0),
        le16(cells.len() as u16),
        le16(0),
        le32(expect_rev),
        cells.concat(),
    ])
}

/// An OPS body: `u32 n | u32 0 | ops`.
fn ops_body(ops: &[Vec<u8>]) -> Vec<u8> {
    cat(&[le32(ops.len() as u32), le32(0), ops.concat()])
}

// ------------------------------------------------------------------ constants

#[test]
fn the_documented_numbers() {
    assert_eq!(HEADER, 16);
    assert_eq!((ZSTD, END, ZSTR, LAYOUT), (0x01, 0x02, 5, 4));
    assert_eq!(
        (NULL, U32, STR, I64, F64, SYM, LIST),
        (0, 1, 2, 3, 4, 6, 7)
    );
    assert_eq!((PUT, DROP, COMMAND), (1, 2, 3));
    assert_eq!((KEYED, CREATE_ONLY, EXPECT_REV), (0x01, 0x02, 0x04));
    assert_eq!((AS_OF, SOURCE, GONE), (0xFFF0, 0xFFF1, 0xFFFE));
    assert_eq!((CRED_TICKET, CRED_KEY), (1, 2));
    assert_eq!((NONE, NONE64), (u32::MAX, i64::MIN));
    assert_eq!(
        (MAX_OPS, MAX_OP_TEXT, MAX_UP, MAX_INFLATED),
        (256, 1 << 20, 16 << 20, 256 << 20)
    );
}

// --------------------------------------------------------------- golden bytes

#[test]
fn small_frames_are_the_documented_bytes() {
    // HELLO: u8 cred | 7x0 | u64 snapshot_rev | u64 schema_rev | field credential | field label
    let want = frame(
        HELLO,
        0,
        0,
        &cat(&[
            vec![2],
            vec![0; 7],
            le64(5),
            le64(6),
            field(b"key"),
            field(b"lab"),
        ]),
    );
    let got = Hello {
        cred: 2,
        snapshot_rev: 5,
        schema_rev: 6,
        credential: b"key",
        label: "lab",
    }
    .encode(HASH);
    assert_eq!(hex(&got), hex(&want));

    // WELCOME: u64 account | u64 session | u64 schema_rev | u16 read | u16 write | u8 may_delete | u8 lease | u16 0 | field label
    let body = cat(&[
        le64(1),
        le64(2),
        le64(3),
        le16(31),
        le16(3),
        vec![1, 0],
        le16(0),
        field(b"tab"),
    ]);
    let w = Welcome {
        account_id: 1,
        session_id: 2,
        schema_rev: 3,
        read_mask: 31,
        write_mask: 3,
        may_delete: true,
        lease: false,
        features: 0,
        label: "tab",
    };
    assert_eq!(hex(&w.encode(HASH, 9)), hex(&frame(WELCOME, 0, 9, &body)));

    // ACK: u32 n | u32 0 | n x (u64 op_id | u64 rev | u32 id | u32 0)
    let body = cat(&[
        le32(2),
        le32(0),
        le64(1),
        le64(2),
        le32(3),
        le32(0),
        le64(4),
        le64(5),
        le32(6),
        le32(0),
    ]);
    let acks = [
        Ack {
            op_id: 1,
            rev: 2,
            id: 3,
        },
        Ack {
            op_id: 4,
            rev: 5,
            id: 6,
        },
    ];
    assert_eq!(
        hex(&encode_acks(HASH, 8, &acks)),
        hex(&frame(ACK, 0, 8, &body))
    );

    // NACK: u32 n | u32 0 | n x (u64 op_id | u16 code | u16 0 | u32 0 | field data)
    let body = cat(&[
        le32(1),
        le32(0),
        le64(9),
        le16(4),
        le16(0),
        le32(0),
        field(b"{}"),
    ]);
    assert_eq!(
        hex(&encode_nacks(
            HASH,
            8,
            &[Nack {
                op_id: 9,
                code: 4,
                data: b"{}"
            }]
        )),
        hex(&frame(NACK, 0, 8, &body))
    );

    // PING / PONG: u64 nonce
    assert_eq!(
        hex(&encode_ping(PONG, HASH, 3)),
        hex(&frame(PONG, 0, 0, &le64(3)))
    );

    // BYE: u8 reason | 7x0 | field message
    let body = cat(&[vec![4], vec![0; 7], field(b"gone")]);
    assert_eq!(
        hex(&Bye {
            reason: BYE_SUSPENDED,
            message: "gone"
        }
        .encode(HASH, 2)),
        hex(&frame(BYE, 0, 2, &body))
    );

    // RPC: u32 id | u32 0 | field method | field params
    let body = cat(&[le32(7), le32(0), field(b"get"), field(b"{}")]);
    assert_eq!(
        hex(&Rpc {
            id: 7,
            method: "get",
            params: b"{}"
        }
        .encode(HASH)),
        hex(&frame(RPC, 0, 0, &body))
    );

    // REPLY: u32 id | u8 ok | 3x0 | field json
    let body = cat(&[le32(7), vec![1, 0, 0, 0], field(b"[]")]);
    assert_eq!(
        hex(&Reply {
            id: 7,
            ok: true,
            json: b"[]"
        }
        .encode(HASH, 5)),
        hex(&frame(REPLY, 0, 5, &body))
    );
}

#[test]
fn every_column_type_is_the_documented_bytes() {
    let want = block(
        5,
        2,
        &[
            col(1, U32, &u32s(&[7, NONE])),
            col(2, STR, &str_data(&[0, 2, 2], b"ab")),
            col(3, I64, &cat(&[le64(1), le64(i64::MIN as u64)])),
            col(
                4,
                F64,
                &cat(&[
                    1.5f64.to_bits().to_le_bytes().to_vec(),
                    f64::NAN.to_bits().to_le_bytes().to_vec(),
                ]),
            ),
            // sym: u32 nuniq | offsets x (nuniq + 1) | utf-8 | pad to 4 | u32 x nrows (dictionary in first-seen order)
            col(
                6,
                SYM,
                &cat(&[
                    le32(2),
                    u32s(&[0, 2, 3]),
                    b"bca".to_vec(),
                    vec![0],
                    u32s(&[0, 1]),
                ]),
            ),
            // list: offsets x (nrows + 1), counted in u32 values, then the values
            col(7, LIST, &cat(&[u32s(&[0, 2, 2]), u32s(&[10, 11])])),
        ],
    );
    let mut w = BodyWriter::new();
    {
        let mut b = w.block(5, 2);
        b.u32s(1, [7, NONE].into_iter());
        b.strs(2, ["ab", ""].into_iter());
        b.i64s(3, [1, i64::MIN].into_iter());
        b.f64s(4, [1.5, f64::NAN].into_iter());
        b.syms(6, ["bc", "a"].into_iter());
        b.lists(7, [&[10u32, 11][..], &[][..]].into_iter());
    }
    assert_eq!(hex(&w.finish()), hex(&want));
}

#[test]
fn an_op_is_the_documented_bytes() {
    let want = frame(
        OPS,
        0,
        0,
        &ops_body(&[op(
            PUT,
            KEYED | EXPECT_REV,
            4,
            &[
                cell(8, U32, &le32(1)),
                cell(9, STR, b"hi"),
                cell(10, I64, &le64(2)),
                cell(11, F64, &1.5f64.to_bits().to_le_bytes()),
                cell(12, NULL, b""),
            ],
        )]),
    );
    let mut w = OpsWriter::new();
    w.op(7, PUT, KEYED, 3, 0, Some(4))
        .u32(8, 1)
        .str(9, "hi")
        .i64(10, 2)
        .f64(11, 1.5)
        .null(12);
    assert_eq!(hex(&w.frame(HASH)), hex(&want));
}

#[test]
fn a_zstr_column_keeps_its_cells_packed_until_one_is_read() {
    let listing = "Senior Rust engineer. About the team: kernels, schedulers and GPU runtimes. ".repeat(12);
    let cells = [pack::text(&listing), [&[0u8][..], b"short"].concat(), vec![]];
    let mut w = BodyWriter::new();
    w.block(3, 3).zstrs(5, cells.iter().map(Vec::as_slice));
    let body = w.finish();
    let col = Blocks::new(&body).unwrap().iter().next().unwrap().col(5).unwrap();
    assert_eq!(col.ty, ZSTR);
    let mut texts = Texts::default();
    let got: Vec<_> = (0..3)
        .map(|i| match col.value(i) {
            Value::ZStr(c) => Some(texts.cell(c).unwrap().into_owned()),
            Value::None => None,
            v => panic!("{v:?}"),
        })
        .collect();
    assert_eq!(got, [Some(listing.clone()), Some("short".to_owned()), None]);
    assert!(cells[0].len() < listing.len() / 4, "the dictionary pays");
}

#[test]
fn text_cells_are_refused_unless_they_unpack_to_their_stated_text() {
    let s = "Rust, kernels, GPUs. ".repeat(30);
    let z = pack::text(&s);
    assert_eq!(text_cell(&z).unwrap(), s);
    // a frame of another dictionary, a cut frame, an unknown tag, raw bytes that are not UTF-8
    assert_eq!(text_cell(&pack::text_with(s.as_bytes(), FRAME_DICT)).unwrap_err(), Error::Inflate);
    assert!(text_cell(&z[..z.len() - 3]).is_err());
    assert_eq!(text_cell(&[2, b'a']).unwrap_err(), Error::Column);
    assert_eq!(text_cell(&[0, 0xFF]).unwrap_err(), Error::Str);
    assert_eq!(text_cell(&pack::text_with(&[0xC3; 300], TEXT_DICT)).unwrap_err(), Error::Str);
}

#[test]
fn a_sym_dictionary_holds_each_value_once() {
    let mut w = BodyWriter::new();
    w.block(1, 4).syms(1, ["x", "x", "y", "x"].into_iter());
    let want = block(
        1,
        4,
        &[col(
            1,
            SYM,
            &cat(&[
                le32(2),
                u32s(&[0, 1, 2]),
                b"xy".to_vec(),
                vec![0, 0],
                u32s(&[0, 0, 1, 0]),
            ]),
        )],
    );
    assert_eq!(hex(&w.finish()), hex(&want));
}

// ------------------------------------------------------------------- frames

#[test]
fn frame_length_must_match_the_buffer() {
    let ok = encode_ping(PING, HASH, 1);
    let mut longer = ok.clone();
    longer.extend_from_slice(&[0; 8]);
    assert!(Frame::parse(&longer, HASH).is_err());
    assert!(Frame::parse(&ok[..16], HASH).is_err());
    assert!(Header::peek(&ok[..15]).is_err());
    let mut tiny = ok.clone();
    tiny[0..4].copy_from_slice(&8u32.to_le_bytes());
    assert!(Header::peek(&tiny).is_err());
}

fn zstd_ping(raw_len: u32, packed: &[u8], tail: &[u8]) -> Vec<u8> {
    pack::raw(PING, ZSTD, HASH, 0, &pack::zbody(raw_len, packed, tail))
}

#[test]
fn zstd_lengths_and_frames_are_refused() {
    let raw: Vec<u8> = (0..64u8).collect();
    let z = pack::packed(&raw);
    let pad = (8 - (8 + z.len()) % 8) % 8;
    let good = |f: Vec<u8>| Frame::parse(&f, HASH).unwrap().body().map(|b| b.to_vec());
    assert_eq!(good(zstd_ping(64, &z, &vec![0; pad])), Ok(raw.clone()), "a PING body is not shuffled");
    // the frame unpacks to 64: a stated length of 56 or 72 is refused
    assert!(good(zstd_ping(56, &z, &vec![0; pad])).is_err());
    assert!(good(zstd_ping(72, &z, &vec![0; pad])).is_err());
    // a raw_len that is not a multiple of 8 is refused even when it is true
    let odd = pack::packed(&raw[..13]);
    assert!(good(zstd_ping(13, &odd, &vec![0; (8 - (8 + odd.len()) % 8) % 8])).is_err());
    // pad bytes must be zero, and as many as the 8-alignment needs
    assert!(pad > 0);
    assert!(good(zstd_ping(64, &z, &vec![0x55; pad])).is_err());
    assert!(good(zstd_ping(64, &z, &vec![0; pad + 8])).is_err());
    // a packed_len past the body
    let mut long = pack::zbody(64, &z, &vec![0; pad]);
    long[4..8].copy_from_slice(&10_000u32.to_le_bytes());
    assert!(good(pack::raw(PING, ZSTD, HASH, 0, &long)).is_err());
    // a frame of the text dictionary, or of none, is not a ZSTD body
    let other = &pack::text(&"x".repeat(64))[1..];
    let opad = (8 - (8 + other.len()) % 8) % 8;
    assert!(good(zstd_ping(64, other, &vec![0; opad])).is_err());
    // raw_len past the reader's limit
    let fr_bytes = zstd_ping(64, &z, &vec![0; pad]);
    let fr = Frame::parse(&fr_bytes, HASH).unwrap();
    assert_eq!(fr.body_max(64).unwrap().len(), 64);
    assert!(fr.body_max(63).is_err());
    // a plain frame is not unpacked, so no limit applies
    assert_eq!(Frame::parse(&encode_ping(PING, HASH, 1), HASH).unwrap().body_max(0).unwrap().len(), 8);
    // a body of fewer than 8 bytes cannot hold the two lengths
    assert!(good(pack::raw(PING, ZSTD, HASH, 0, &[])).is_err());
}

// ---------------------------------------------------------------- small frames

#[test]
fn small_frame_refusals() {
    let hello = |cred: u8, reserved: u8, tail: &[u8]| {
        cat(&[
            vec![cred],
            vec![reserved; 7],
            le64(1),
            le64(2),
            field(b"k"),
            field(b"l"),
            tail.to_vec(),
        ])
    };
    assert!(Hello::decode(&hello(1, 0, &[])).is_ok());
    assert!(Hello::decode(&hello(1, 1, &[])).is_err(), "reserved bytes");
    assert!(
        Hello::decode(&hello(1, 0, &[0; 8])).is_err(),
        "trailing bytes"
    );
    assert!(Hello::decode(&hello(0, 0, &[])).is_err());
    assert!(Hello::decode(&hello(3, 0, &[])).is_err());
    let bad_label = cat(&[
        vec![1],
        vec![0; 7],
        le64(1),
        le64(2),
        field(b"k"),
        field(&[0xFF]),
    ]);
    assert!(Hello::decode(&bad_label).is_err());

    let welcome = |md: u8, lease: u8, pad: u16, tail: &[u8]| {
        cat(&[
            le64(1),
            le64(2),
            le64(3),
            le16(1),
            le16(1),
            vec![md, lease],
            le16(pad),
            field(b"x"),
            tail.to_vec(),
        ])
    };
    assert!(Welcome::decode(&welcome(1, 0, 0, &[])).is_ok());
    assert!(Welcome::decode(&welcome(2, 0, 0, &[])).is_err());
    assert!(Welcome::decode(&welcome(0, 2, 0, &[])).is_err());
    // The u16 after lease is the node's feature bits, read as they are.
    assert_eq!(Welcome::decode(&welcome(0, 0, FEATURE_ATOMIC, &[])).map(|w| w.features), Ok(FEATURE_ATOMIC));
    assert!(Welcome::decode(&welcome(0, 0, 0, &[0; 8])).is_err());

    let reply = |ok: u8| cat(&[le32(1), vec![ok, 0, 0, 0], field(b"{}")]);
    assert!(Reply::decode(&reply(0)).is_ok());
    assert!(Reply::decode(&reply(2)).is_err());
    assert!(Reply::decode(&cat(&[le32(1), vec![1, 0, 0, 1], field(b"{}")])).is_err());

    assert_eq!(decode_ping(&le64(5)), Ok(5));
    assert!(decode_ping(&[0; 16]).is_err());
    assert!(decode_ping(&[0; 4]).is_err());

    let rpc = |method: &[u8]| cat(&[le32(1), le32(0), field(method), field(b"{}")]);
    assert!(Rpc::decode(&rpc(b"get")).is_ok());
    assert!(Rpc::decode(&rpc(&[0xC0, 0x80])).is_err());
    assert!(Rpc::decode(&cat(&[le32(1), le32(1), field(b"m"), field(b"{}")])).is_err());

    let bye = |reason: u8, reserved: u8| cat(&[vec![reason], vec![reserved; 7], field(b"m")]);
    assert!(Bye::decode(&bye(4, 0)).is_ok());
    assert!(Bye::decode(&bye(5, 0)).is_err());
    assert!(Bye::decode(&bye(0, 1)).is_err());

    let many = |n: u32| cat(&[le32(n), le32(0), vec![0; 24 * n as usize]]);
    assert!(decode_acks(&many(257)).is_err());
    assert!(decode_acks(&many(256)).is_ok());
    let nacks = |n: u32| {
        cat(&[
            le32(n),
            le32(0),
            (0..n)
                .flat_map(|_| cat(&[le64(1), le16(1), le16(0), le32(0), field(b"")]))
                .collect(),
        ])
    };
    assert!(decode_nacks(&nacks(257)).is_err());
    assert!(decode_nacks(&nacks(256)).is_ok());
    let two = cat(&[
        le32(2),
        le32(0),
        cat(&[le64(1), le16(1), le16(0), le32(0), field(b"")]),
    ]);
    assert!(decode_nacks(&two).is_err());
    assert!(decode_acks(&cat(&[le32(1), le32(1), vec![0; 24]])).is_err());
    // a nack whose reserved bytes are nonzero, and a field whose pad is nonzero
    let nz = cat(&[
        le32(1),
        le32(0),
        le64(1),
        le16(1),
        le16(1),
        le32(0),
        field(b""),
    ]);
    assert!(decode_nacks(&nz).is_err());
    let mut pad = cat(&[
        le32(1),
        le32(0),
        le64(1),
        le16(1),
        le16(0),
        le32(0),
        field(b"abc"),
    ]);
    let last = pad.len() - 1;
    pad[last] = 1;
    assert!(decode_nacks(&pad).is_err());

    assert!(!format!("{}", Error::Short).is_empty());
}

// ------------------------------------------------------------------ table runs

/// Whether a one-block body is refused.
fn refused(cols: &[Vec<u8>], nrows: u32) -> bool {
    Blocks::new(&block(3, nrows, cols)).is_err()
}

#[test]
fn table_run_refusals() {
    // reserved byte of a column, and a gone column in the wrong company or of the wrong type
    let mut bad_reserved = col(1, U32, &u32s(&[1]));
    bad_reserved[3] = 1;
    assert!(refused(&[bad_reserved], 1));
    assert!(refused(
        &[col(1, U32, &u32s(&[1])), col(GONE, U32, &u32s(&[1]))],
        1
    ));
    assert!(refused(&[col(GONE, STR, &str_data(&[0, 1], b"a"))], 1));
    assert!(Blocks::new(&block(3, 1, &[col(GONE, U32, &u32s(&[1]))])).is_ok());
    // an unknown column type, and a fixed column of the wrong size
    assert!(refused(&[col(1, 9, &u32s(&[1]))], 1));
    assert!(refused(&[col(1, U32, &u32s(&[1, 2]))], 1));
    assert!(refused(&[col(1, I64, &le32(1))], 1));
    // a body that stops inside a block header or a column
    assert!(Blocks::new(&[1, 0, 0, 0]).is_err());
    let whole = block(3, 1, &[col(1, U32, &u32s(&[1]))]);
    assert!(Blocks::new(&whole[..whole.len() - 8]).is_err());
}

#[test]
fn str_offsets_are_refused() {
    let s = |offsets: &[u32], bytes: &[u8], nrows: u32| {
        refused(&[col(1, STR, &str_data(offsets, bytes))], nrows)
    };
    assert!(Blocks::new(&block(3, 2, &[col(1, STR, &str_data(&[0, 1, 3], b"abc"))])).is_ok());
    // backwards in the middle, with the last offset still at the end
    assert!(s(&[0, 2, 1, 3], b"abc", 3));
    // inside a multi-byte character
    assert!(s(&[0, 1, 2], "é".as_bytes(), 2));
    // the first offset not 0
    assert!(s(&[1, 2, 3], b"abc", 2));
    // the last offset short of the bytes, and past them
    assert!(s(&[0, 1, 2], b"abc", 2));
    assert!(s(&[0, 1, 4], b"abc", 2));
    // bytes that are not UTF-8
    assert!(s(&[0, 1], &[0xFF], 1));
    // fewer offsets than rows + 1
    assert!(refused(&[col(1, STR, &u32s(&[0, 0]))], 2));
}

#[test]
fn list_offsets_are_refused() {
    let l = |offsets: &[u32], values: &[u32], nrows: u32| {
        refused(&[col(1, LIST, &cat(&[u32s(offsets), u32s(values)]))], nrows)
    };
    assert!(
        Blocks::new(&block(
            3,
            2,
            &[col(1, LIST, &cat(&[u32s(&[0, 1, 3]), u32s(&[1, 2, 3])]))]
        ))
        .is_ok()
    );
    assert!(l(&[1, 1], &[9], 1), "first offset not 0");
    assert!(l(&[0, 1], &[9, 9], 1), "last offset short of the values");
    assert!(l(&[0, 3], &[9, 9], 1), "offset past the values");
    assert!(l(&[0, 2, 1, 2], &[9, 9], 3), "offsets backwards");
    let odd = cat(&[u32s(&[0, 1]), u32s(&[9]), vec![7]]);
    assert!(
        refused(&[col(1, LIST, &odd)], 1),
        "values not a multiple of 4 bytes"
    );
}

#[test]
fn sym_layouts_are_refused() {
    let sym = |nuniq: u32,
               offsets: &[u32],
               bytes: &[u8],
               pad: &[u8],
               ids: &[u32],
               tail: &[u8],
               nrows: u32| {
        let data = cat(&[
            le32(nuniq),
            u32s(offsets),
            bytes.to_vec(),
            pad.to_vec(),
            u32s(ids),
            tail.to_vec(),
        ]);
        Blocks::new(&block(3, nrows, &[col(1, SYM, &data)])).map(|_| ())
    };
    assert_eq!(sym(1, &[0, 1], b"a", &[0, 0, 0], &[0], &[], 1), Ok(()));
    assert!(
        sym(1, &[0, 1], b"a", &[0, 0, 0], &[1], &[], 1).is_err(),
        "id past the dictionary"
    );
    assert!(
        sym(1, &[0, 1], b"a", &[0, 1, 0], &[0], &[], 1).is_err(),
        "nonzero pad"
    );
    assert!(
        sym(1, &[0, 1], b"a", &[0, 0, 0], &[0], &[0; 4], 1).is_err(),
        "bytes after the ids"
    );
    assert!(
        sym(1, &[0, 1], b"a", &[0, 0, 0], &[0], &[], 2).is_err(),
        "fewer ids than rows"
    );
    // a dictionary whose offsets run past its bytes (the layout adds up, the offsets do not)
    assert!(sym(2, &[0, 2, 1], b"a", &[0, 0, 0], &[0], &[], 1).is_err());
    // pad to 4, not to 8: five dictionary bytes take three pad bytes, not none
    assert_eq!(sym(1, &[0, 5], b"abcde", &[0, 0, 0], &[0], &[], 1), Ok(()));
    assert!(sym(1, &[0, 5], b"abcde", &[], &[0], &[], 1).is_err());
    // no room for the dictionary count
    assert!(Blocks::new(&block(3, 0, &[col(1, SYM, &[0, 0])])).is_err());
}

#[test]
fn nulls_read_as_none_in_every_column_type() {
    let body = block(
        5,
        3,
        &[
            col(1, U32, &u32s(&[NONE, 0, 5])),
            col(2, I64, &cat(&[le64(i64::MIN as u64), le64(0), le64(7)])),
            col(
                3,
                F64,
                &cat(&[
                    f64::NAN.to_bits().to_le_bytes().to_vec(),
                    0f64.to_bits().to_le_bytes().to_vec(),
                    (-1.5f64).to_bits().to_le_bytes().to_vec(),
                ]),
            ),
            col(4, STR, &str_data(&[0, 0, 1, 2], b"xy")),
            col(6, LIST, &cat(&[u32s(&[0, 0, 1, 3]), u32s(&[4, 5, 6])])),
            col(
                7,
                SYM,
                &cat(&[
                    le32(2),
                    u32s(&[0, 0, 1]),
                    b"z".to_vec(),
                    vec![0; 3],
                    u32s(&[0, 1, 1]),
                ]),
            ),
        ],
    );
    let blocks = Blocks::new(&body).unwrap();
    let b = blocks.iter().next().unwrap();
    let v = |id: u16, i: usize| b.col(id).unwrap().value(i);
    assert_eq!(
        [v(1, 0), v(1, 1), v(1, 2)],
        [Value::None, Value::U32(0), Value::U32(5)]
    );
    assert_eq!(
        [v(2, 0), v(2, 1), v(2, 2)],
        [Value::None, Value::I64(0), Value::I64(7)]
    );
    assert_eq!(
        [v(3, 0), v(3, 1), v(3, 2)],
        [Value::None, Value::F64(0.0), Value::F64(-1.5)]
    );
    assert_eq!(
        [v(4, 0), v(4, 1), v(4, 2)],
        [Value::None, Value::Str("x"), Value::Str("y")]
    );
    let list = |i| match v(6, i) {
        Value::List(l) => Some(l.iter().collect::<Vec<_>>()),
        Value::None => None,
        other => panic!("{other:?}"),
    };
    assert_eq!(
        [list(0), list(1), list(2)],
        [None, Some(vec![4]), Some(vec![5, 6])]
    );
    assert_eq!(
        [v(7, 0), v(7, 1), v(7, 2)],
        [Value::None, Value::Str("z"), Value::Str("z")]
    );
    // the raw u32 accessor keeps NONE, and says NONE for a column that is not u32
    assert_eq!(b.col(1).unwrap().u32(0), NONE);
    assert_eq!(b.col(2).unwrap().u32(0), NONE);
    assert_eq!(b.col(1).unwrap().u32(2), 5);
}

// ------------------------------------------------------------------------- ops

/// Whether an OPS body of these ops is refused.
fn ops_err(ops: &[Vec<u8>]) -> bool {
    Ops::new(&ops_body(ops)).is_err()
}

#[test]
fn op_refusals() {
    let ok = op(PUT, KEYED, 0, &[cell(8, U32, &le32(1))]);
    assert_eq!(
        Ops::new(&ops_body(std::slice::from_ref(&ok))).map(|o| o.len()),
        Ok(1)
    );
    assert!(ops_err(&[op(0, 0, 0, &[])]), "verb 0");
    assert!(ops_err(&[op(4, 0, 0, &[])]), "verb 4");
    assert!(ops_err(&[op(PUT, 0x08, 0, &[])]), "unknown flag bit");
    assert!(
        ops_err(&[op(PUT, 0, 5, &[])]),
        "expect_rev without its flag"
    );
    assert!(Ops::new(&ops_body(&[op(PUT, EXPECT_REV, 5, &[])])).is_ok());
    let mut reserved = ok.clone();
    reserved[18] = 1;
    assert!(ops_err(&[reserved]), "reserved u16");
    assert!(
        ops_err(&[op(
            PUT,
            0,
            0,
            &[cell(8, U32, &le32(1)), cell(8, U32, &le32(2))]
        )]),
        "duplicate cell"
    );
    let mut cell_reserved = cell(8, U32, &le32(1));
    cell_reserved[3] = 1;
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell_reserved])]),
        "cell reserved byte"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, NULL, &le32(1))])]),
        "null cell with bytes"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, U32, &le64(1))])]),
        "u32 cell of 8 bytes"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, U32, &[1, 0, 0])])]),
        "u32 cell of 3 bytes"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, I64, &le32(1))])]),
        "i64 cell of 4 bytes"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, F64, &le32(1))])]),
        "f64 cell of 4 bytes"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, STR, &[0xFF])])]),
        "str cell not UTF-8"
    );
    assert!(
        ops_err(&[op(PUT, 0, 0, &[cell(8, SYM, &[0; 4])])]),
        "sym cell"
    );
    let mut cell_pad = cell(8, U32, &le32(1));
    let last = cell_pad.len() - 1;
    cell_pad[last] = 1;
    assert!(ops_err(&[op(PUT, 0, 0, &[cell_pad])]), "nonzero cell pad");
    // counts: 257 ops, trailing bytes, a nonzero reserved word, a body that stops short
    let one = op(DROP, 0, 0, &[]);
    assert!(Ops::new(&ops_body(&vec![one.clone(); 257])).is_err());
    assert_eq!(
        Ops::new(&ops_body(&vec![one.clone(); 256])).map(|o| o.len()),
        Ok(256)
    );
    let mut trailing = ops_body(std::slice::from_ref(&one));
    trailing.extend_from_slice(&[0; 8]);
    assert!(Ops::new(&trailing).is_err());
    let mut word = ops_body(std::slice::from_ref(&one));
    word[4] = 1;
    assert!(Ops::new(&word).is_err());
    let whole = ops_body(std::slice::from_ref(&ok));
    assert!(Ops::new(&whole[..whole.len() - 8]).is_err());
    assert!(Ops::new(&cat(&[le32(2), le32(0), one.clone()])).is_err());
    // one op alone: nothing may follow it
    assert!(Op::one(&one).is_ok());
    assert!(Op::one(&cat(&[one.clone(), one])).is_err());
}

#[test]
fn an_ops_text_is_its_str_cells() {
    let o = op(
        PUT,
        0,
        0,
        &[
            cell(8, STR, b"abc"),
            cell(9, U32, &le32(1)),
            cell(10, STR, b"de"),
            cell(11, NULL, b""),
            cell(12, I64, &le64(1)),
        ],
    );
    let parsed = Op::one(&o).unwrap();
    assert_eq!(parsed.text_len(), 5);
    assert_eq!(parsed.ncols, 5);
    assert_eq!(parsed.raw, &o[..]);
    assert!(!parsed.has(0) && !parsed.has(KEYED));
    assert_eq!(parsed.cell(10).unwrap().value(), Value::Str("de"));
    assert!(parsed.cell(99).is_none());
}

// --------------------------------------------------------------------- writers

#[test]
fn a_column_of_another_length_than_its_block_is_a_bug() {
    let writes: [(&str, fn()); 4] = [
        ("short u32s", || {
            BodyWriter::new().block(1, 3).u32s(1, [1u32, 2].into_iter());
        }),
        ("long strs", || {
            BodyWriter::new().block(1, 1).strs(1, ["a", "b"].into_iter());
        }),
        ("short syms", || {
            BodyWriter::new().block(1, 2).syms(1, ["a"].into_iter());
        }),
        ("long lists", || {
            BodyWriter::new().block(1, 0).lists(1, [&[1u32][..]].into_iter());
        }),
    ];
    for (what, write) in writes {
        let e = std::panic::catch_unwind(write).expect_err(what);
        let msg = e.downcast_ref::<String>().map(String::as_str).or_else(|| e.downcast_ref::<&str>().copied()).unwrap_or("");
        assert!(msg.contains("values in a block"), "{what}: {msg}");
    }
}

#[test]
fn an_ops_writer_knows_when_a_frame_is_full_and_a_full_one_is_a_valid_frame() {
    let mut w = OpsWriter::new();
    for i in 0..255u64 {
        w.op(i, DROP, 0, 1, 1, None);
    }
    assert!(!w.is_full(0), "255 ops leave room for one more");
    assert_eq!(w.len(), 255);
    w.op(255, DROP, 0, 1, 1, None);
    assert!(w.is_full(0), "256 ops is a full frame");
    let f = w.frame(HASH);
    let fr = Frame::parse(&f, HASH).unwrap();
    assert_eq!(fr.kind(), OPS);
    assert_eq!(Ops::new(&fr.body().unwrap()).map(|o| o.len()), Ok(256));

    let w = OpsWriter::new();
    let room = MAX_UP - HEADER - 8;
    assert!(!w.is_full(room), "exactly MAX_UP fits");
    assert!(w.is_full(room + 1), "one byte more does not");
}

// ------------------------------------------------------- mangled OPS and frames

/// A seeded xorshift, so a failure replays.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next() % n as u64) as usize
        }
    }
}

const EDGES: [u32; 14] = [
    0,
    1,
    7,
    8,
    9,
    0xFF,
    0x3FFF_FFFF,
    0x4000_0000,
    0x7FFF_FFFF,
    0x8000_0000,
    0xFFFF_FFF0,
    0xFFFF_FFF8,
    0xFFFF_FFFC,
    u32::MAX,
];

fn mangle(rng: &mut Rng, seed: &[u8]) -> Vec<u8> {
    let mut m = seed.to_vec();
    for _ in 0..1 + rng.below(3) {
        match rng.below(6) {
            0 if !m.is_empty() => {
                let i = rng.below(m.len());
                m[i] = rng.next() as u8;
            }
            1..=3 if m.len() >= 4 => {
                let i = if rng.below(2) == 0 {
                    rng.below(m.len() / 4) * 4
                } else {
                    rng.below(m.len() - 3)
                };
                m[i..i + 4].copy_from_slice(&EDGES[rng.below(EDGES.len())].to_le_bytes());
            }
            4 => {
                let n = rng.below(m.len() + 1);
                m.truncate(n);
            }
            _ => m.extend((0..rng.below(16)).map(|_| rng.next() as u8)),
        }
    }
    m
}

#[test]
fn mangled_ops_blocks_and_frames_never_panic() {
    let mut o = OpsWriter::new();
    o.op(1, PUT, KEYED, 5, 0, None)
        .u32(8, 1)
        .str(9, "héllo")
        .i64(10, -3)
        .f64(11, 2.5)
        .null(12);
    o.op(2, DROP, 0, 6, 77, Some(3)).u32(8, 0);
    o.op(3, COMMAND, CREATE_ONLY, 2, 0, Some(9));
    let ops = o.finish();

    let mut w = BodyWriter::new();
    {
        let mut b = w.block(3, 3);
        b.u32s(1, [1, 2, NONE].into_iter());
        b.strs(2, ["a", "", "héllo"].into_iter());
        b.syms(3, ["x", "y", "x"].into_iter());
        let (l1, l2): (&[u32], &[u32]) = (&[1, 2], &[]);
        b.lists(4, [l1, l2, l1].into_iter());
        let z = pack::text(&"a long enough text to pack. ".repeat(20));
        b.zstrs(5, [&z[..], &[], &[0, b'r']].into_iter());
    }
    w.gone(9, &[4, 5, 6]);
    let blocks = w.finish();

    let runs: Vec<u8> = blocks.iter().cycle().take(blocks.len() * 64).copied().collect();
    let packed = pack::frame(PING, HASH, &runs);

    let frames = [
        packed,
        encode_ping(PING, HASH, 5),
        Hello {
            cred: 2,
            snapshot_rev: 1,
            schema_rev: 2,
            credential: b"k",
            label: "l",
        }
        .encode(HASH),
        Bye {
            reason: 3,
            message: "m",
        }
        .encode(HASH, 1),
        encode_acks(
            HASH,
            1,
            &[Ack {
                op_id: 1,
                rev: 2,
                id: 3,
            }],
        ),
        encode_nacks(
            HASH,
            1,
            &[Nack {
                op_id: 1,
                code: 2,
                data: b"{}",
            }],
        ),
    ];

    let mut rng = Rng(0x5A17_0003_9E37_79B9);
    for round in 0..60_000u32 {
        let pick = rng.below(3 + frames.len());
        let seed: &[u8] = match pick {
            0 => &ops,
            1 => &blocks,
            2 => &runs,
            n => &frames[n - 3],
        };
        let m = mangle(&mut rng, seed);
        // as a body
        if let Ok(b) = Blocks::new(&m) {
            for blk in b.iter() {
                let _ = blk.gone().map(|g| g.iter().count());
                for c in blk.cols() {
                    for r in 0..c.nrows().min(64) {
                        if let Value::ZStr(z) = c.value(r) {
                            let _ = text_cell(z);
                        }
                    }
                }
            }
        }
        if let Ok(o) = Ops::new(&m) {
            for op in o.iter() {
                let _ = (op.text_len(), op.cell(8).map(|c| c.is_sentinel()));
                for c in op.cells() {
                    let _ = (c.value(), c.is_sentinel());
                }
            }
        }
        let _ = (
            Hello::decode(&m),
            Welcome::decode(&m),
            Bye::decode(&m),
            Rpc::decode(&m),
            Reply::decode(&m),
        );
        let _ = (
            decode_acks(&m),
            decode_nacks(&m),
            decode_ping(&m),
            Op::one(&m).map(|o| o.ncols),
        );
        // as a frame, at every limit
        let _ = (
            Header::peek(&m),
            split(&m, MAX_UP).map(|s| s.map(|(h, _, _)| h)),
        );
        if let Ok(fr) = Frame::parse(&m, HASH) {
            for limit in [MAX_UP, 4096, 8, 0] {
                if let Ok(b) = fr.body_max(limit) {
                    let _ = (
                        Blocks::new(&b).map(|x| x.iter().count()),
                        Ops::new(&b).map(|x| x.len()),
                    );
                }
            }
        }
        // and as the body of a frame that claims ZSTD
        let mut claimed = Writer::new(BOOT, HASH, 0);
        claimed.bytes(&m);
        let mut cf = claimed.finish();
        cf[5] = ZSTD;
        if let Ok(fr) = Frame::parse(&cf, HASH) {
            let _ = fr.body_max(MAX_UP);
        }
        assert!(round < u32::MAX);
    }
}
