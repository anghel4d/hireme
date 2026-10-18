//! The resident store's laws, through its public API, over seeded random
//! histories: a base moved by PATCHes reads the same as a fresh BOOT of
//! the same rows; pending writes sit on top of any base and leave nothing
//! behind once rolled back; a snapshot restores the base.

use std::collections::BTreeMap;

use kernel::rows::{Rows, Val, Write};

const TABLES: [u16; 2] = [5, 9];
const U: u16 = 8;
const S: u16 = 9;
const F: u16 = 10;
const I: u16 = 11;

/// A seeded xorshift; the failing seed is in every assertion message.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn val(&mut self, col: u16) -> Val {
        if self.below(5) == 0 {
            return Val::None;
        }
        match col {
            U => Val::U32(self.below(1000) as u32),
            S => Val::Str(["a", "bb", "ünï", "x\u{1f}y", "long string here"][self.below(5) as usize].into()),
            F => Val::F64(self.below(1000) as f64 / 7.0),
            _ => Val::I64(self.below(1 << 40) as i64 - (1 << 39)),
        }
    }
}

/// The model: table → id → col → value (absent = null).
type Model = BTreeMap<u16, BTreeMap<u32, BTreeMap<u16, Val>>>;

fn block(w: &mut wire::BodyWriter, table: u16, rows: &[(u32, Vec<(u16, Val)>)], cols: &[u16]) {
    let mut b = w.block(table, rows.len());
    b.u32s(1, rows.iter().map(|r| r.0));
    let get = |r: &(u32, Vec<(u16, Val)>), c: u16| r.1.iter().find(|x| x.0 == c).map(|x| x.1.clone()).unwrap_or(Val::None);
    for &c in cols {
        match c {
            U => b.u32s(c, rows.iter().map(|r| if let Val::U32(x) = get(r, c) { x } else { wire::NONE })),
            F => b.f64s(c, rows.iter().map(|r| if let Val::F64(x) = get(r, c) { x } else { f64::NAN })),
            I => b.i64s(c, rows.iter().map(|r| if let Val::I64(x) = get(r, c) { x } else { wire::NONE64 })),
            _ => {
                let s: Vec<String> = rows.iter().map(|r| if let Val::Str(x) = get(r, c) { x } else { String::new() }).collect();
                b.strs(c, s.iter().map(String::as_str))
            }
        };
    }
    b.done();
}

fn boot_of(model: &Model) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    for t in TABLES {
        let rows: Vec<(u32, Vec<(u16, Val)>)> = model
            .get(&t)
            .map(|m| m.iter().map(|(id, cols)| (*id, cols.iter().map(|(c, v)| (*c, v.clone())).collect())).collect())
            .unwrap_or_default();
        block(&mut w, t, &rows, &[U, S, F, I]);
    }
    w.finish()
}

/// What a reader sees: per table, each id's non-null cells.
fn read(rows: &Rows) -> Model {
    let mut out = Model::new();
    for t in TABLES {
        let mut m = BTreeMap::new();
        if let Some(tab) = rows.table(t) {
            for &id in tab.ids() {
                let cells: BTreeMap<u16, Val> =
                    [U, S, F, I].into_iter().map(|c| (c, tab.get(id, c))).filter(|(_, v)| !v.is_none()).collect();
                m.insert(id, cells);
            }
        }
        out.insert(t, m);
    }
    out
}

/// A random PATCH body, applied to the model as well.
fn random_patch(rng: &mut Rng, model: &mut Model) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    for t in TABLES {
        if rng.below(3) == 0 {
            continue;
        }
        let m = model.entry(t).or_default();
        let cols: Vec<u16> = [U, S, F, I].into_iter().filter(|_| rng.below(2) == 0).collect();
        let n = rng.below(6) as usize;
        let mut rows = Vec::new();
        for _ in 0..n {
            let id = 1 + rng.below(20) as u32;
            if rows.iter().any(|r: &(u32, Vec<(u16, Val)>)| r.0 == id) {
                continue;
            }
            let cells: Vec<(u16, Val)> = cols.iter().map(|&c| (c, rng.val(c))).collect();
            let entry = m.entry(id).or_default();
            for (c, v) in &cells {
                if v.is_none() {
                    entry.remove(c);
                } else {
                    entry.insert(*c, v.clone());
                }
            }
            rows.push((id, cells));
        }
        block(&mut w, t, &rows, &cols);
        if rng.below(3) == 0 {
            let gone: Vec<u32> = (0..rng.below(4)).map(|_| 1 + rng.below(20) as u32).collect();
            for id in &gone {
                m.remove(id);
            }
            w.gone(t, &gone);
        }
    }
    w.finish()
}

fn random_writes(rng: &mut Rng, rows: &mut Rows) -> Vec<Write> {
    let t = TABLES[rng.below(2) as usize];
    let ids: Vec<u32> = rows.table(t).map(|x| x.ids().to_vec()).unwrap_or_default();
    let mut ws = Vec::new();
    match rng.below(3) {
        0 if !ids.is_empty() => {
            let id = ids[rng.below(ids.len() as u64) as usize];
            ws.push(Write::Remove { table: t, id });
        }
        1 => {
            let id = rows.temp_id();
            ws.push(Write::Insert { table: t, id });
            ws.push(Write::Set { table: t, id, col: S, val: rng.val(S) });
        }
        _ if !ids.is_empty() => {
            let id = ids[rng.below(ids.len() as u64) as usize];
            let col = [U, S, F, I][rng.below(4) as usize];
            ws.push(Write::Set { table: t, id, col, val: rng.val(col) });
        }
        _ => {}
    }
    ws
}

#[test]
fn base_plus_deltas_reads_as_a_fresh_boot() {
    for seed in 1..=300u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        let mut model = Model::new();
        let mut rows = Rows::new();
        // Start from a random base.
        let first = random_patch(&mut rng, &mut model);
        rows.patch(&first, 1).unwrap();
        for step in 0..20 {
            let p = random_patch(&mut rng, &mut model);
            rows.patch(&p, 2 + step).unwrap();
            let mut fresh = Rows::new();
            fresh.boot(&boot_of(&model), 0).unwrap();
            assert_eq!(read(&rows), read(&fresh), "seed {seed} step {step}");
            assert_eq!(read(&rows), full(&model), "seed {seed} step {step}");
        }
    }
}

/// The model with every table present, as `read` reports it.
fn full(m: &Model) -> Model {
    TABLES.iter().map(|t| (*t, m.get(t).cloned().unwrap_or_default())).collect()
}

#[test]
fn pending_writes_ride_on_any_base_and_roll_back_clean() {
    for seed in 1..=300u64 {
        let mut rng = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03));
        let mut model = Model::new();
        let mut rows = Rows::new();
        rows.patch(&random_patch(&mut rng, &mut model), 1).unwrap();
        let mut ops = Vec::new();
        for op in 0..6u64 {
            let ws = random_writes(&mut rng, &mut rows);
            rows.apply_pending(op, ws);
            ops.push(op);
            // The base keeps moving under the pending writes.
            rows.patch(&random_patch(&mut rng, &mut model), 2 + op).unwrap();
        }
        // The snapshot is the base alone.
        let mut restored = Rows::new();
        restored.boot(&rows.snapshot(), 0).unwrap();
        assert_eq!(read(&restored), full(&model), "seed {seed}: snapshot");
        // Refusals in any order leave exactly the base.
        while !ops.is_empty() {
            let op = ops.remove(rng.below(ops.len() as u64) as usize);
            rows.resolve(op);
        }
        assert_eq!(read(&rows), full(&model), "seed {seed}: rollback");
    }
}

#[test]
fn a_settled_write_stays_through_its_patch() {
    let mut rows = Rows::new();
    let mut w = wire::BodyWriter::new();
    block(&mut w, 5, &[(7, vec![(U, Val::U32(1))])], &[U]);
    rows.boot(&w.finish(), 1).unwrap();

    rows.apply_pending(42, vec![Write::Set { table: 5, id: 7, col: U, val: Val::U32(2) }]);
    assert_eq!(rows.table(5).unwrap().u32(7, U), Some(2));
    // The server's PATCH for op 42, then its ACK.
    let mut w = wire::BodyWriter::new();
    block(&mut w, 5, &[(7, vec![(U, Val::U32(2))])], &[U]);
    let moved = rows.patch(&w.finish(), 2).unwrap();
    assert!(moved.touched(5));
    rows.resolve(42);
    assert_eq!(rows.table(5).unwrap().u32(7, U), Some(2));
    assert_eq!(rows.rev, 2);
}

#[test]
fn an_unreadable_table_arrives_as_an_empty_block_and_is_emptied() {
    let mut rows = Rows::new();
    let mut w = wire::BodyWriter::new();
    block(&mut w, 5, &[(7, vec![(U, Val::U32(1))])], &[U]);
    rows.boot(&w.finish(), 1).unwrap();
    // The BOOT of a key that cannot read table 5, then a table it can.
    let mut w = wire::BodyWriter::new();
    w.block(5, 0).done();
    block(&mut w, 9, &[(3, vec![(S, Val::Str("x".into()))])], &[S]);
    rows.boot(&w.finish(), 2).unwrap();
    assert_eq!(rows.table(5).map_or(0, |t| t.len()), 0);
    assert_eq!(rows.table(9).unwrap().str(3, S), Some("x"));
    // The server sends it as an id column with no rows.
    let mut w = wire::BodyWriter::new();
    block(&mut w, 5, &[(7, vec![(U, Val::U32(1))])], &[U]);
    rows.boot(&w.finish(), 3).unwrap();
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(5, 0);
    b.u32s(1, std::iter::empty());
    b.done();
    rows.boot(&w.finish(), 4).unwrap();
    assert_eq!(rows.table(5).map_or(0, |t| t.len()), 0);
}
