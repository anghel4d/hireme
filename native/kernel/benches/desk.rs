//! The kernel natively at a seeded 10k-application desk, the shape of
//! bench/kernel.mjs: the BOOT's ingest, the board's first derive and its
//! derive after a one-row PATCH (the bound is measured under wasm; this is
//! the profiling harness), then `judge` against its bound (docs/rebuild.md
//! "Tests, bench, bounds": ≤ 200 µs in the NIF) on the ops a sequencer
//! judges most: a stage move into the queue (the heat governor runs), a
//! plain stage move, a put with a listing (keyword extraction), and a put
//! of one cell. Prints medians and p99s; exits 1 past the judge bound.
//!
//!   cargo bench -p kernel --bench desk
//!   HOT=0.85 COMPANIES=150 cargo bench -p kernel --bench desk   (a mature, concentrated desk)
//!   DISTINCT=1: every company, role and location its own text, the desk
//!   on which reading each distinct text once saves nothing; PATCHES=0
//!   measures the first derive alone.

use std::time::Instant;

use kernel::abi::Kernel;
use kernel::judge::Ctx;
use schema::col::applications as A;
use schema::{command, enums, param, table};

const N: u32 = 10_000;
const TODAY: i32 = 739_528;
const BOUND_US: f64 = 200.0;

fn env<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn desk() -> Vec<u8> {
    let (hot, companies, distinct): (f64, u64, bool) = (env("HOT", 0.1), env("COMPANIES", 2500), env("DISTINCT", 0) == 1);
    let mut r = 0x9E37_79B9_7F4A_7C15u64;
    let mut below = |n: u64| {
        r ^= r << 13;
        r ^= r >> 7;
        r ^= r << 17;
        r % n
    };
    let roles = ["Software Engineer", "Senior Software Engineer", "Rust Systems Engineer", "Research Engineer", "SRE"];
    let (mut stage, mut company, mut role, mut place, mut url, mut on, mut batch) = (vec![], vec![], vec![], vec![], vec![], vec![], vec![]);
    for i in 0..N {
        let c = if distinct { i as u64 } else { below(companies) };
        stage.push(if (below(1000) as f64) < hot * 1000.0 { 5 + below(5) as u32 } else { below(5) as u32 });
        company.push(format!("Company {c} Systems"));
        let r = roles[below(5) as usize];
        role.push(if distinct { format!("{r} {i}") } else { r.to_string() });
        place.push(if distinct { format!("Office {i}, remote friendly") } else { ["Lisbon", "Remote", "Berlin, onsite only", ""][below(4) as usize].to_string() });
        url.push(match below(5) {
            0 => format!("https://boards.greenhouse.io/c{c}/jobs/1"),
            1 => format!("https://jobs.lever.co/c{c}/x"),
            2 => format!("https://jobs.ashbyhq.com/c{c}"),
            3 => format!("https://c{c}.wd5.myworkdayjobs.com/x"),
            _ => format!("https://c{c}.example.com/careers"),
        });
        on.push((TODAY - below(120) as i32) as u32);
        batch.push(1 + below(50) as u32);
    }
    let mut w = wire::BodyWriter::new();
    w.block(table::APPLICATIONS, N as usize)
        .u32s(A::ID, 1..=N)
        .u32s(A::NO, 1..=N)
        .u32s(A::STAGE, stage.into_iter())
        .strs(A::COMPANY, company.iter().map(String::as_str))
        .strs(A::ROLE, role.iter().map(String::as_str))
        .strs(A::LOCATION, place.iter().map(String::as_str))
        .strs(A::LISTING_URL, url.iter().map(String::as_str))
        .u32s(A::STAGE_ON, on.into_iter())
        .u32s(A::BATCH_ID, batch.into_iter())
        .u32s(A::HEAT_OVERRIDE, (0..N).map(|_| 0));
    w.block(table::BATCHES, 50).u32s(schema::col::batches::ID, 1..=50).u32s(schema::col::batches::FIRE, (0..50).map(|_| 0));
    w.finish()
}

/// A PATCH moving application `id`'s day.
fn touch(k: &mut Kernel, id: u32, back: i32) {
    let mut w = wire::BodyWriter::new();
    w.block(table::APPLICATIONS, 1).u32s(A::ID, [id].into_iter()).u32s(A::STAGE_ON, [(TODAY - back) as u32].into_iter());
    k.patch(&w.finish(), 2).unwrap();
}

/// The median and p99 of `us`.
fn stats(mut us: Vec<f64>) -> (f64, f64) {
    us.sort_by(f64::total_cmp);
    (us[us.len() / 2], us[us.len() * 99 / 100])
}

/// `f`'s run time in µs.
fn timed(f: impl FnOnce()) -> f64 {
    let t = Instant::now();
    f();
    t.elapsed().as_secs_f64() * 1e6
}

fn op(build: impl FnOnce(&mut wire::OpsWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    build(&mut w);
    w.finish()[8..].to_vec()
}

fn main() {
    let (body, mut k) = (desk(), Kernel::new());
    k.set_today(TODAY);
    let ingest = timed(|| drop(k.boot(&body, 1).unwrap())) / 1e3;
    let cold = timed(|| k.derive()) / 1e3;
    let patches: u32 = env("PATCHES", 30);
    if patches == 0 {
        println!("BOOT ingest {ingest:.2} ms, first derive {cold:.2} ms");
        return;
    }
    let (derive, _) = stats((0..patches).map(|i| {
        touch(&mut k, 1 + (i * 331) % N, i as i32);
        timed(|| k.derive())
    }).collect());
    println!("BOOT ingest {ingest:.2} ms, first derive {cold:.2} ms, derive after a patch p50 {:.2} ms", derive / 1e3);
    let stage_of = |k: &Kernel, id: u32| k.rows().table(table::APPLICATIONS).unwrap().u32(id, A::STAGE);
    let cold: Vec<u32> = (1..=N).filter(|&id| stage_of(&k, id) == Some(enums::stage::DRAFT_READY as u32)).take(500).collect();
    let hot: Vec<u32> = (1..=N).filter(|&id| stage_of(&k, id).is_some_and(|s| s >= enums::stage::FIRE_READY as u32)).collect();
    let stage = |to: u8| -> Vec<Vec<u8>> { cold.iter().map(|&id| op(|w| { w.op(1, wire::COMMAND, 0, command::STAGE, id, None).u32(param::stage::STAGE, to as u32); })).collect() };
    let listing = "We build Rust systems: kernels, schedulers, GPU runtimes, distributed storage. ".repeat(60);
    let puts: Vec<Vec<u8>> = cold.iter().map(|&id| op(|w| { w.op(1, wire::PUT, 0, table::APPLICATIONS, id, None).str(A::LISTING_RAW, &listing); })).collect();
    let cells: Vec<Vec<u8>> = cold.iter().map(|&id| op(|w| { w.op(1, wire::PUT, 0, table::APPLICATIONS, id, None).u32(A::SCORE_100, 70); })).collect();
    let (into_queue, plain) = (stage(enums::stage::FIRE_READY), stage(enums::stage::CLOSED));
    let ctx = Ctx { today: TODAY, now: 0, human: false, key_id: Some(1), held: &[] };
    let mut worst: f64 = 0.0;
    // "… after a hot write": a PATCH moving a hot application's day first, untimed, so the governor's index rebuilds.
    for (name, ops, after_write) in [("stage into the queue", &into_queue, false), ("  … after a hot write", &into_queue, true), ("stage, no heat", &plain, false), ("put listing_raw (4.8 KB)", &puts, false), ("put one cell", &cells, false)] {
        let (p50, p99) = stats((0..ops.len()).map(|i| {
            if after_write {
                touch(&mut k, hot[i % hot.len()], (i % 30) as i32);
            }
            timed(|| {
                let _ = std::hint::black_box(k.judge(&ops[i], &ctx));
            })
        }).collect());
        worst = worst.max(p50);
        println!("{name:28} p50 {p50:8.1} µs   p99 {p99:8.1} µs");
    }
    println!("bound {BOUND_US} µs (median)");
    if worst > BOUND_US {
        std::process::exit(1);
    }
}
