//! `judge` against its bound (docs/rebuild.md "Tests, bench, bounds":
//! ≤ 200 µs in the NIF) on a seeded 10k-application desk, the same shape
//! as bench/kernel.mjs. Times the ops a sequencer judges most: a stage
//! move into the queue (the heat governor runs), a plain stage move, a
//! put with a listing (keyword extraction), and a put of one cell.
//! Prints medians and p99s in µs; exits 1 past the bound.
//!
//!   cargo bench -p kernel --bench judge

use std::time::Instant;

use kernel::abi::Kernel;
use kernel::judge::Ctx;
use schema::col::applications as A;
use schema::{command, enums, param, table};

const N: u32 = 10_000;
const TODAY: i32 = 20_000;
const BOUND_US: f64 = 200.0;

struct Rng(u64);
impl Rng {
    fn below(&mut self, n: u64) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0 % n
    }
}

fn desk() -> Kernel {
    let mut r = Rng(0x9E37_79B9_7F4A_7C15);
    let roles = ["Software Engineer", "Senior Software Engineer", "Rust Systems Engineer", "Research Engineer", "SRE"];
    let (mut stage, mut company, mut role, mut url, mut on, mut batch) = (vec![], vec![], vec![], vec![], vec![], vec![]);
    for _ in 0..N {
        let c = r.below(2500);
        stage.push(if r.below(10) == 0 { 5 + r.below(5) as u32 } else { r.below(5) as u32 });
        company.push(format!("Company {c} Systems"));
        role.push(roles[r.below(5) as usize].to_string());
        url.push(match r.below(4) {
            0 => format!("https://boards.greenhouse.io/c{c}/jobs/1"),
            1 => format!("https://jobs.lever.co/c{c}/x"),
            2 => format!("https://c{c}.wd5.myworkdayjobs.com/x"),
            _ => format!("https://c{c}.example.com/careers"),
        });
        on.push((TODAY - r.below(120) as i32) as u32);
        batch.push(1 + r.below(50) as u32);
    }
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, N as usize);
    b.u32s(A::ID, 1..=N)
        .u32s(A::NO, 1..=N)
        .u32s(A::STAGE, stage.into_iter())
        .strs(A::COMPANY, company.iter().map(String::as_str))
        .strs(A::ROLE, role.iter().map(String::as_str))
        .strs(A::LISTING_URL, url.iter().map(String::as_str))
        .u32s(A::STAGE_ON, on.into_iter())
        .u32s(A::BATCH_ID, batch.into_iter())
        .u32s(A::HEAT_OVERRIDE, (0..N).map(|_| 0));
    b.done();
    let mut b = w.block(table::BATCHES, 50);
    b.u32s(schema::col::batches::ID, 1..=50).u32s(schema::col::batches::FIRE, (0..50).map(|_| 0));
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.boot(&w.finish(), 1).unwrap();
    k.derive();
    k
}

fn op(build: impl FnOnce(&mut wire::OpsWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    build(&mut w);
    w.finish()[8..].to_vec()
}

/// Times each op's judge; `before` runs first, untimed (a write landing).
fn time(k: &mut Kernel, ops: &[Vec<u8>], before: Option<&dyn Fn(&mut Kernel, usize)>) -> (f64, f64) {
    let ctx = Ctx { today: TODAY, now: 0, human: false, key_id: Some(1), held: &[] };
    let mut us: Vec<f64> = ops
        .iter()
        .enumerate()
        .map(|(i, o)| {
            if let Some(f) = before {
                f(k, i);
            }
            let t = Instant::now();
            let _ = std::hint::black_box(k.judge(o, &ctx));
            t.elapsed().as_secs_f64() * 1e6
        })
        .collect();
    us.sort_by(f64::total_cmp);
    (us[us.len() / 2], us[us.len() * 99 / 100])
}

fn main() {
    let mut k = desk();
    let cold: Vec<u32> = (1..=N).filter(|&id| k.rows().table(table::APPLICATIONS).unwrap().u32(id, A::STAGE) == Some(enums::stage::DRAFT_READY as u32)).take(500).collect();
    let into_queue: Vec<Vec<u8>> = cold
        .iter()
        .map(|&id| op(|w| { w.op(1, wire::COMMAND, 0, command::STAGE, id, None).u32(param::stage::STAGE, enums::stage::FIRE_READY as u32); }))
        .collect();
    let plain: Vec<Vec<u8>> = cold
        .iter()
        .map(|&id| op(|w| { w.op(1, wire::COMMAND, 0, command::STAGE, id, None).u32(param::stage::STAGE, enums::stage::CLOSED as u32); }))
        .collect();
    let listing = "We build Rust systems: kernels, schedulers, GPU runtimes, distributed storage. ".repeat(60);
    let puts: Vec<Vec<u8>> =
        cold.iter().map(|&id| op(|w| { w.op(1, wire::PUT, 0, table::APPLICATIONS, id, None).str(A::LISTING_RAW, &listing); })).collect();
    let cells: Vec<Vec<u8>> = cold.iter().map(|&id| op(|w| { w.op(1, wire::PUT, 0, table::APPLICATIONS, id, None).u32(A::SCORE_100, 70); })).collect();
    let hot: Vec<u32> = (1..=N)
        .filter(|&id| k.rows().table(table::APPLICATIONS).unwrap().u32(id, A::STAGE).is_some_and(|s| s >= enums::stage::FIRE_READY as u32))
        .collect();
    // A PATCH moving a hot application's day: the governor's index rebuilds.
    let touch = |k: &mut Kernel, i: usize| {
        let mut w = wire::BodyWriter::new();
        let mut b = w.block(table::APPLICATIONS, 1);
        b.u32s(A::ID, [hot[i % hot.len()]].into_iter()).u32s(A::STAGE_ON, [(TODAY - (i % 30) as i32) as u32].into_iter());
        b.done();
        k.patch(&w.finish(), 2).unwrap();
    };
    let mut worst: f64 = 0.0;
    let cases: [(&str, &Vec<Vec<u8>>, Option<&dyn Fn(&mut Kernel, usize)>); 5] = [
        ("stage into the queue", &into_queue, None),
        ("  … after a hot write", &into_queue, Some(&touch)),
        ("stage, no heat", &plain, None),
        ("put listing_raw (4.8 KB)", &puts, None),
        ("put one cell", &cells, None),
    ];
    for (name, ops, before) in cases {
        let (p50, p99) = time(&mut k, ops, before);
        worst = worst.max(p50);
        println!("{name:28} p50 {p50:8.1} µs   p99 {p99:8.1} µs");
    }
    println!("bound {BOUND_US} µs (median)");
    if worst > BOUND_US {
        std::process::exit(1);
    }
}
