//! A kernel kept current must equal a fresh one: after any run of PATCHes
//! (applications, settings, atlas, lineages, gone rows), BOOTs, predicted
//! ops, their ACKs and NACKs, TICKs and day pins, a kernel booted from the
//! same rows derives the same board, documents and verdicts. The board's cache
//! and the governor's index are maintained incrementally; this is their law.

use kernel::abi::Kernel;
use kernel::judge::Ctx;
use kernel::pipeline::{self, Stage};
use kernel::rows::Data;
use schema::col::applications as A;
use schema::{col, command, enums, param, table};

const TODAY: i32 = 20_000;
const N: u32 = 24;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }

    fn pick<'a, T>(&mut self, v: &'a [T]) -> &'a T {
        &v[self.below(v.len() as u64) as usize]
    }

    fn day(&mut self, back: u64) -> u32 {
        (TODAY - self.below(back) as i32) as u32
    }
}

const TEXTS: &[&str] = &[
    "", "Rust engineer", "Senior Staff Software Engineer", "Google", "ACME Corp", "$250k", "250 000 €", "remote", "onsite only",
    "https://boards.greenhouse.io/acme/jobs/1", "https://jobs.lever.co/acme/2", "https://acme.wd5.myworkdayjobs.com/x/job/3",
];

fn pips(stage: u32, moved: bool) -> String {
    let s = Stage::from_u8(stage as u8).unwrap();
    let rail = if moved { pipeline::move_to(&pipeline::initial(Stage::Discovered), s) } else { pipeline::initial(s) };
    String::from_utf8(pipeline::encode(&rail).to_vec()).unwrap()
}

fn desk(r: &mut Rng) -> Vec<u8> {
    let n = N as usize;
    let stages: Vec<u32> = (0..n).map(|_| r.below(10) as u32).collect();
    let rails: Vec<String> = stages.iter().map(|&s| pips(s, r.below(2) == 0)).collect();
    let company: Vec<String> = (0..n).map(|i| format!("{}{}", ["Acme", "Google", "Stripe", "Zed"][i % 4], i / 8)).collect();
    let urls: Vec<String> = (0..n).map(|i| format!("https://boards.greenhouse.io/t{}/jobs/{i}", i % 3)).collect();
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::APPLICATIONS, n);
    b.u32s(A::ID, 1..=N)
        .u32s(A::NO, 1..=N)
        .u32s(A::CORPORATION_ID, (0..n).map(|i| 1 + (i % 4) as u32))
        .u32s(A::BATCH_ID, stages.iter().enumerate().map(|(i, &s)| if (3..=7).contains(&s) { 1 + (i % 3) as u32 } else { wire::NONE }))
        .u32s(A::CHANNEL, (0..n).map(|i| if i % 5 == 0 { enums::app_channel::REFERRAL } else { enums::app_channel::LISTING } as u32))
        .u32s(A::STAGE, stages.iter().copied())
        .strs(A::PIPS, rails.iter().map(String::as_str))
        .u32s(A::STAGE_ON, (0..n).map(|i| (TODAY - (i as i32 % 30)) as u32))
        .u32s(A::APPLIED_ON, stages.iter().enumerate().map(|(i, &s)| if s >= 7 { (TODAY - i as i32 * 3) as u32 } else { wire::NONE }))
        .u32s(A::REPLIED_ON, stages.iter().enumerate().map(|(i, &s)| if s == 8 { (TODAY - i as i32) as u32 } else { wire::NONE }))
        .strs(A::COMPANY, company.iter().map(String::as_str))
        .strs(A::ROLE, (0..n).map(|i| ["Software Engineer", "SRE", "Research Engineer"][i % 3]))
        .strs(A::LISTING_URL, urls.iter().map(String::as_str));
    b.done();
    let mut b = w.block(table::BATCHES, 3);
    b.u32s(col::batches::ID, 1..=3).strs(col::batches::CODE, ["A", "B", "C"].into_iter());
    b.done();
    let mut b = w.block(table::CV_LINEAGES, 2);
    b.u32s(col::cv_lineages::ID, 1..=2)
        .u32s(col::cv_lineages::CORPORATION_ID, [1, 2].into_iter())
        .u32s(col::cv_lineages::GENERATION, [1, 2].into_iter())
        .u32s(col::cv_lineages::OPENED_ON, [(TODAY - 10) as u32, (TODAY - 100) as u32].into_iter())
        .u32s(col::cv_lineages::REWRITES_ALLOWED, [1, 0].into_iter());
    b.done();
    let mut b = w.block(table::ITEMS, 6);
    b.u32s(col::items::ID, 1..=6).strs(col::items::TITLE, (0..6).map(|_| "Item")).strs(col::items::KEY, (0..6).map(|_| "k"));
    b.done();
    let mut b = w.block(table::SETTINGS, 1);
    b.u32s(col::settings::ID, [1].into_iter()).strs(col::settings::CITIZENSHIPS, ["pt"].into_iter());
    b.done();
    w.finish()
}

/// An op an agent or the operator might send, often refused.
fn op(r: &mut Rng, op_id: u64) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let target = 1 + r.below(N as u64 + 2) as u32;
    if r.below(2) == 0 {
        let cmd = *r.pick(&[command::STAGE, command::STAGE, command::NOTE, command::HEAT_OVERRIDE, command::OPEN_GENERATION]);
        let mut o = w.op(op_id, wire::COMMAND, 0, cmd, target, None);
        match cmd {
            command::STAGE => {
                o.u32(param::stage::STAGE, r.below(10) as u32);
            }
            command::NOTE => {
                o.u32(param::note::STAGE, r.below(10) as u32).str(param::note::BODY, r.pick(TEXTS));
            }
            command::HEAT_OVERRIDE => {
                o.str(param::heat_override::REASON, r.pick(TEXTS));
            }
            _ => {}
        }
        o.done();
    } else {
        let t = *r.pick(&[table::APPLICATIONS, table::APPLICATIONS, table::CV_OVERLAYS, table::EVENTS]);
        let target = if r.below(4) == 0 { 0 } else { target };
        let mut o = w.op(op_id, wire::PUT, 0, t, target, None);
        match t {
            table::APPLICATIONS => {
                o.str(A::COMPANY, r.pick(TEXTS)).str(A::COMP_RAW, r.pick(TEXTS)).u32(A::SCORE_100, r.below(101) as u32);
            }
            table::CV_OVERLAYS => {
                o.u32(col::cv_overlays::APPLICATION_ID, 1 + r.below(N as u64) as u32)
                    .u32(col::cv_overlays::ITEM_ID, 1 + r.below(6) as u32)
                    .u32(col::cv_overlays::MODE, r.below(3) as u32)
                    .str(col::cv_overlays::TITLE, r.pick(TEXTS));
            }
            _ => {
                o.u32(col::events::APPLICATION_ID, 1 + r.below(N as u64) as u32).str(col::events::KIND, "note");
            }
        }
        o.done();
    }
    w.finish()[8..].to_vec()
}

/// A server PATCH: application cells, or the settings, atlas or lineages
/// the derivations read, sometimes with gone rows.
fn patch(r: &mut Rng) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    match r.below(6) {
        0..=2 => {
            let id = 1 + r.below(N as u64 + 2) as u32;
            let stage = r.below(10) as u32;
            let mut b = w.block(table::APPLICATIONS, 1);
            b.u32s(A::ID, [id].into_iter());
            match r.below(6) {
                0 => b.u32s(A::STAGE, [stage].into_iter()).strs(A::PIPS, [pips(stage, r.below(2) == 0).as_str()].into_iter()),
                1 => b.strs(A::COMPANY, [*r.pick(TEXTS)].into_iter()).strs(A::ROLE, [*r.pick(TEXTS)].into_iter()),
                2 => b.strs(A::COMP_RAW, [*r.pick(TEXTS)].into_iter()).u32s(A::SCORE_100, [r.below(101) as u32].into_iter()),
                3 => b.u32s(A::APPLIED_ON, [r.day(200)].into_iter()).u32s(A::STAGE_ON, [r.day(100)].into_iter()),
                4 => b.u32s(A::PLACE_ID, [1 + r.below(3) as u32].into_iter()).u32s(A::WORK_MODE, [r.below(3) as u32].into_iter()),
                _ => b.u32s(A::CORPORATION_ID, [1 + r.below(4) as u32].into_iter()).u32s(A::BATCH_ID, [1 + r.below(3) as u32].into_iter()),
            };
            b.done();
            if r.below(8) == 0 {
                w.gone(table::APPLICATIONS, &[1 + r.below(N as u64) as u32]);
            }
        }
        3 => {
            let mut b = w.block(table::SETTINGS, 1);
            b.u32s(col::settings::ID, [1].into_iter());
            if r.below(2) == 0 {
                b.strs(col::settings::HEAT_CONFIG, [*r.pick(&["", "{\"small_cap\": 2}", "{\"company_half_life\": 5}", "garbage"])].into_iter());
            } else {
                b.strs(col::settings::CITIZENSHIPS, [*r.pick(&["", "pt", "us", "pt\u{1f}us"])].into_iter());
            }
            b.done();
        }
        4 => {
            let id = 1 + r.below(3) as u32;
            let mut b = w.block(table::ATLAS, 1);
            b.u32s(col::atlas::ID, [id].into_iter())
                .u32s(col::atlas::KIND, [enums::place_kind::COUNTRY as u32].into_iter())
                .u32s(col::atlas::ATLAS_POSITION, [id].into_iter())
                .strs(col::atlas::ISO2, [*r.pick(&["pt", "us", "de"])].into_iter());
            b.done();
        }
        _ => {
            let id = 1 + r.below(3) as u32;
            let mut b = w.block(table::CV_LINEAGES, 1);
            b.u32s(col::cv_lineages::ID, [id].into_iter())
                .u32s(col::cv_lineages::CORPORATION_ID, [1 + r.below(4) as u32].into_iter())
                .u32s(col::cv_lineages::OPENED_ON, [r.day(150)].into_iter())
                .u32s(col::cv_lineages::REWRITES_ALLOWED, [r.below(2) as u32].into_iter());
            b.done();
        }
    }
    w.finish()
}

/// A BOOT of the rows a kernel holds now, pending effects included.
fn boot_of(k: &Kernel) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    for t in k.rows().tables() {
        if schema::table_def(t.id).is_some_and(|d| d.residency == schema::Residency::Wire) {
            continue;
        }
        let mut b = w.block(t.id, t.len());
        b.u32s(1, t.ids().iter().copied());
        for c in t.columns().iter().filter(|c| c.id != 1) {
            match &c.data {
                Data::U32(v) => b.u32s(c.id, v.iter().copied()),
                Data::I64(v) => b.i64s(c.id, v.iter().copied()),
                Data::F64(v) => b.f64s(c.id, v.iter().copied()),
                Data::Str(v) => b.strs(c.id, v.iter().map(String::as_str)),
                Data::Deferred(v) => b.deferred(c.id, v.iter().map(|d| (d.0 != wire::NONE).then_some(*d))),
                Data::List(v) => b.lists(c.id, v.iter().map(Vec::as_slice)),
            };
        }
        b.done();
    }
    w.finish()
}

/// Everything derived that a reader sees, and the verdicts on `probes`.
fn derived(k: &mut Kernel, probes: &[Vec<u8>], ctx: &Ctx) -> Vec<String> {
    let mut out = vec![format!("{:?}", k.board_ids(None)), k.overview(100).to_string(), k.atlas(None).to_string()];
    out.extend((1..=N + 2).map(|id| format!("{id}: {:?}", k.application(id))));
    out.extend(probes.iter().map(|p| format!("{:?}", k.judge(p, ctx))));
    out
}

#[test]
fn a_kernel_kept_current_derives_what_a_fresh_one_does() {
    let (seeds, steps): (u64, u64) = if cfg!(debug_assertions) { (12, 30) } else { (60, 60) };
    let agent = Ctx { today: TODAY, now: 0, human: false, key_id: Some(1), held: &[1, 2, 3] };
    let human = Ctx { today: TODAY, now: 0, human: true, key_id: None, held: &[] };
    for seed in 1..=seeds {
        let mut r = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03) | 1);
        let mut a = Kernel::new();
        a.set_today(TODAY);
        a.boot(&desk(&mut r), 1).unwrap();
        let (mut pending, mut op_id, mut log) = (Vec::new(), 5000u64, Vec::new());
        for step in 0..steps {
            match r.below(10) {
                0..=3 => {
                    let _ = a.patch(&patch(&mut r), 2 + step);
                    log.push("PATCH");
                }
                4..=6 => {
                    op_id += 1;
                    let ctx = if r.below(3) == 0 { &human } else { &agent };
                    if a.predict(&op(&mut r, op_id), ctx).is_ok() {
                        pending.push(op_id);
                        log.push("predict");
                    }
                }
                7 if !pending.is_empty() => {
                    let id = pending.remove(r.below(pending.len() as u64) as usize);
                    let frame = if r.below(2) == 0 {
                        wire::encode_acks(schema::WIRE_HASH, 9, &[wire::Ack { op_id: id, rev: 9, id: 0 }])
                    } else {
                        wire::encode_nacks(schema::WIRE_HASH, 9, &[wire::Nack { op_id: id, code: 0, data: b"" }])
                    };
                    let _ = a.ingest(&frame);
                    log.push("settle");
                }
                8 => {
                    a.pin_today(TODAY + r.below(130) as i32 - 5);
                    log.push("day");
                }
                // The server's TICK moving the day (unless a day is pinned),
                // or a BOOT replacing the desk whole.
                _ if r.below(2) == 0 => {
                    let mut w = wire::BodyWriter::new();
                    let mut b = w.block(table::CLOCK, 1);
                    b.u32s(col::clock::TODAY, [TODAY as u32 + r.below(60) as u32].into_iter());
                    b.done();
                    let _ = a.patch(&w.finish(), 2 + step);
                    log.push("tick");
                }
                _ if pending.is_empty() => {
                    let _ = a.boot(&desk(&mut r), 2 + step);
                    log.push("boot");
                }
                _ => {}
            }
            let mut b = Kernel::new();
            b.set_today(TODAY);
            b.pin_today(a.today());
            b.boot(&boot_of(&a), 1).unwrap();
            let mut pr = Rng(seed * 7919 + step);
            let probes: Vec<Vec<u8>> = (0..8).map(|i| op(&mut pr, 9000 + i)).collect();
            let (x, y) = (derived(&mut a, &probes, &agent), derived(&mut b, &probes, &agent));
            if let Some((i, (x, y))) = x.iter().zip(&y).enumerate().find(|(_, (x, y))| x != y) {
                panic!("seed {seed} step {step} after {log:?}: derived item {i}\n  kept current: {x}\n  fresh:        {y}");
            }
        }
    }
}
