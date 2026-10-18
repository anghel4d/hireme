//! The board derive after a one-row PATCH on a seeded 10k desk, natively,
//! at the hot shares bench/kernel.mjs uses (`HOT=0.85 cargo bench -p
//! kernel --bench board`). The bound is measured under wasm; this is the
//! profiling harness.

use std::time::Instant;

use kernel::abi::Kernel;
use schema::col::applications as A;
use schema::table;

const N: u32 = 10_000;
const TODAY: i32 = 20_000;

fn main() {
    let hot: f64 = std::env::var("HOT").ok().and_then(|h| h.parse().ok()).unwrap_or(0.1);
    let mut r = 0x9E37_79B9_7F4A_7C15u64;
    let mut below = |n: u64| {
        r ^= r << 13;
        r ^= r >> 7;
        r ^= r << 17;
        r % n
    };
    let roles = ["Software Engineer", "Senior Software Engineer", "Rust Systems Engineer", "Research Engineer", "SRE"];
    let (mut stage, mut company, mut role, mut url, mut on) = (vec![], vec![], vec![], vec![], vec![]);
    for _ in 0..N {
        let c = below(2500);
        let is_hot = (below(1000) as f64) < hot * 1000.0;
        stage.push(if is_hot { 5 + below(5) as u32 } else { below(5) as u32 });
        company.push(format!("Company {c} Systems"));
        role.push(roles[below(5) as usize].to_string());
        url.push(match below(5) {
            0 => format!("https://boards.greenhouse.io/c{c}/jobs/1"),
            1 => format!("https://jobs.lever.co/c{c}/x"),
            2 => format!("https://jobs.ashbyhq.com/c{c}"),
            3 => format!("https://c{c}.wd5.myworkdayjobs.com/x"),
            _ => format!("https://c{c}.example.com/careers"),
        });
        on.push((TODAY - below(120) as i32) as u32);
    }
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, N as usize);
    b.u32s(A::ID, 1..=N)
        .u32s(A::NO, 1..=N)
        .u32s(A::STAGE, stage.iter().copied())
        .strs(A::COMPANY, company.iter().map(String::as_str))
        .strs(A::ROLE, role.iter().map(String::as_str))
        .strs(A::LISTING_URL, url.iter().map(String::as_str))
        .u32s(A::STAGE_ON, on.iter().copied())
        .u32s(A::HEAT_OVERRIDE, (0..N).map(|_| 0));
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    let body = w.finish();
    let t = Instant::now();
    k.boot(&body, 1).unwrap();
    let ingest = t.elapsed();
    let t = Instant::now();
    k.derive();
    let cold = t.elapsed();
    let mut times = Vec::new();
    // PATCHES=0 measures the first derive alone (for profiling).
    let patches: u32 = std::env::var("PATCHES").ok().and_then(|p| p.parse().ok()).unwrap_or(30);
    for i in 0..patches {
        let mut w = wire::BodyWriter::new();
        let mut b = w.block(table::APPLICATIONS, 1);
        b.u32s(A::ID, [1 + (i * 331) % N].into_iter()).u32s(A::STAGE_ON, [(TODAY - i as i32) as u32].into_iter());
        b.done();
        k.patch(&w.finish(), 2 + i as u64).unwrap();
        let t = Instant::now();
        k.derive();
        times.push(t.elapsed().as_secs_f64() * 1e3);
    }
    times.sort_by(f64::total_cmp);
    println!(
        "hot {hot}: BOOT ingest {:.2} ms, first derive {:.2} ms, after patch p50 {:.2} ms",
        ingest.as_secs_f64() * 1e3,
        cold.as_secs_f64() * 1e3,
        times.get(times.len() / 2).copied().unwrap_or(0.0)
    );
}
