//! A kernel kept current must equal a fresh one: after any run of PATCHes
//! (applications, settings, me, places, lineages, gone rows), BOOTs, predicted
//! ops, their ACKs and NACKs, TICKs and day pins, a kernel booted from the
//! same rows derives the same board, documents, CV picks, arranged desk and
//! verdicts. The board's cache, the governor's index, the picks and the
//! arranged columns are maintained incrementally; this is their law.

mod fixture;

use fixture::{OPERATOR, TODAY, body, gone, q};
use kernel::abi::Kernel;
use kernel::board;
use kernel::judge::Ctx;
use kernel::pipeline::{self, Stage};
use schema::col::applications as A;
use schema::{col, command, param, table};
use serde_json::{Value as Json, json};

const N: u32 = 24;
const COMPANIES: [&str; 4] = ["Acme", "Google", "Stripe", "Zed"];

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
    "no remote", "Remote, no remote", "Acme Body", "Shop Lead", "Sales", "Engineer", "Staffing Partners", "Systems Intern",
    "https://boards.greenhouse.io/acme/jobs/1", "https://jobs.lever.co/acme/2", "https://acme.wd5.myworkdayjobs.com/x/job/3",
];

fn pips(stage: u32, moved: bool) -> String {
    let s = Stage::from_u32(stage).unwrap();
    let rail = if moved { pipeline::move_to(&pipeline::initial(Stage::Discovered), s) } else { pipeline::initial(s) };
    String::from_utf8(pipeline::encode(&rail).to_vec()).unwrap()
}

/// A desk of N applications at four companies (one with an engineering
/// office) in three countries, in batches, on lineages, picking among two
/// CV roots by rule, pin and default.
fn desk(r: &mut Rng) -> Vec<u8> {
    let applications: Vec<Json> = (0..N)
        .map(|i| {
            let (stage, n) = (r.below(10) as u32, i as i32);
            json!({"id": i + 1, "no": i + 1, "corporation_id": 1 + i % 4, "batch_id": if (3..=7).contains(&stage) { json!(1 + i % 3) } else { Json::Null },
                "channel": if i % 5 == 0 { "referral" } else { "listing" }, "stage": stage, "pips": pips(stage, r.below(2) == 0), "stage_on": TODAY - n % 30,
                "applied_on": if stage >= 7 { json!(TODAY - n * 3) } else { Json::Null }, "replied_on": if stage == 8 { json!(TODAY - n) } else { Json::Null },
                "company": format!("{}{}", COMPANIES[i as usize % 4], i / 8), "role": (["Software Engineer", "SRE", "Research Engineer"][i as usize % 3]),
                "listing_url": format!("https://boards.greenhouse.io/t{}/jobs/{i}", i % 3), "place_id": if i % 3 == 2 { Json::Null } else { json!(1 + i % 3) },
                "cv_root_id": if i % 6 == 0 { json!(1 + i % 2) } else { Json::Null }})
        })
        .collect();
    body(&json!({
        "applications": applications,
        "corporations": (1..=4).map(|i| json!({"id": i, "domain": format!("c{i}.example"), "name": COMPANIES[i - 1]})).collect::<Json>(),
        "places": [{"id": 1, "kind": "country", "iso2": "PT"}, {"id": 2, "kind": "country", "iso2": "US"}, {"id": 3, "kind": "country", "iso2": "DE"}],
        "offices": [{"id": 1, "corporation_id": 2, "place_id": 1, "kind": "engineering"}],
        "batches": [{"id": 1, "code": "A"}, {"id": 2, "code": "B"}, {"id": 3, "code": "C"}],
        "cv_lineages": [{"id": 1, "corporation_id": 1, "generation": 1, "opened_on": TODAY - 10, "rewrites_allowed": true}, {"id": 2, "corporation_id": 2, "generation": 2, "opened_on": TODAY - 100, "rewrites_allowed": false}],
        "items": (1..=6).map(|i| json!({"id": i, "title": "Item", "key": "k"})).collect::<Json>(),
        "cv_roots": [{"id": 1, "slug": "composed", "name": "Composed", "format": "composed"}, {"id": 2, "slug": "rust", "name": "Rust", "format": "markdown", "version_id": 1}],
        "cv_versions": [{"id": 1, "root_id": 2, "n": 1, "text": "Rust"}],
        "cv_rules": [{"id": 1, "position": 0, "root_id": 2, "enabled": true, "pattern": "country = PT"}, {"id": 2, "position": 1, "root_id": 1, "enabled": true, "pattern": "company.domain = \"c3.example\""}],
        "me": [{"id": 1, "citizenships": "pt", "cv_default_root_id": 1}],
    }))
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

/// A server PATCH: application cells, or the settings, me, places or
/// lineages the derivations read, sometimes with gone rows.
fn patch(r: &mut Rng) -> Vec<u8> {
    let rows = match r.below(6) {
        0..=2 => {
            let (id, stage) = (1 + r.below(N as u64 + 2), r.below(10) as u32);
            let mut row = match r.below(6) {
                0 => json!({"stage": stage, "pips": pips(stage, r.below(2) == 0)}),
                1 => json!({"company": r.pick(TEXTS), "role": r.pick(TEXTS), "location": r.pick(TEXTS)}),
                2 => json!({"comp_raw": r.pick(TEXTS), "score_100": r.below(101)}),
                3 => json!({"applied_on": r.day(200), "stage_on": r.day(100)}),
                4 => json!({"place_id": 1 + r.below(3), "work_mode": r.below(3), "cv_root_id": ([json!(1), json!(2), json!(9), Json::Null][r.below(4) as usize])}),
                _ => json!({"corporation_id": 1 + r.below(4), "batch_id": 1 + r.below(3)}),
            };
            row["id"] = json!(id);
            if r.below(8) == 0 {
                return [body(&json!({"applications": [row]})), gone(table::APPLICATIONS, &[1 + r.below(N as u64) as u32])].concat();
            }
            json!({"applications": [row]})
        }
        3 if r.below(2) == 0 => json!({"settings": [{"id": 1, "heat_config": r.pick(&["", "{\"small_cap\": 2}", "{\"company_half_life\": 5}", "garbage"])}]}),
        3 => json!({"me": [{"id": 1, "citizenships": r.pick(&["", "pt", "us", "pt\u{1f}us"])}]}),
        4 => json!({"places": [{"id": 1 + r.below(3), "kind": "country", "iso2": r.pick(&["pt", "us", "de"])}]}),
        _ => json!({"cv_lineages": [{"id": 1 + r.below(3), "corporation_id": 1 + r.below(4), "opened_on": r.day(150), "rewrites_allowed": r.below(2) == 1}]}),
    };
    body(&rows)
}

/// A BOOT of the rows a kernel holds now, pending effects included.
fn boot_of(k: &Kernel) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    for t in k.rows().tables().filter(|t| schema::table_def(t.id).is_none_or(|d| d.residency != schema::Residency::Wire)) {
        t.block(&mut w);
    }
    w.finish()
}

/// Everything derived that a reader sees, and the verdicts on `probes`.
fn derived(k: &mut Kernel, probes: &[Vec<u8>], ctx: &Ctx) -> Vec<String> {
    let mut out = vec![format!("{:?}", k.board_ids(None)), k.overview(100).to_string(), k.atlas().to_string(), q(k, json!({"op": "cv_picks"})).to_string()];
    let asks = [
        json!({"sort": ["company.name", "asc"], "group": "field"}),
        json!({"sort": ["no", "desc"], "group": "company.name", "largest": true}),
        json!({"sort": ["role", "asc"], "group": "seniority"}),
        json!({"group": "work_mode"}),
        json!({"group": "office"}),
    ];
    out.extend(asks.iter().map(|a| format!("{a}: {:?}", k.arrange(a))));
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
        let mut a = fixture::kernel(json!({}));
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
                    let _ = a.patch(&body(&json!({"clock": [{"today": TODAY as u64 + r.below(60)}]})), 2 + step);
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
            b.set_grants(OPERATOR);
            b.pin_today(a.today());
            b.boot(&boot_of(&a), 1).unwrap();
            let mut pr = Rng(seed * 7919 + step);
            let probes: Vec<Vec<u8>> = (0..8).map(|i| op(&mut pr, 9000 + i)).collect();
            let (x, y) = (derived(&mut a, &probes, &agent), derived(&mut b, &probes, &agent));
            if let Some((i, (x, y))) = x.iter().zip(&y).enumerate().find(|(_, (x, y))| x != y) {
                panic!("seed {seed} step {step} after {log:?}: derived item {i}\n  kept current: {x}\n  fresh:        {y}");
            }
            // Each card's suggestion, read through the board's memos, is the
            // one the row reads to on its own.
            let ids = a.board_ids(None);
            let cards: Vec<_> = ids.iter().map(|id| a.board().card(*id).map(|c| c.suggestion)).collect();
            let rows = a.rows();
            let t = rows.table(table::APPLICATIONS).unwrap();
            let citizens = board::citizenships(rows);
            for (id, card) in ids.iter().zip(cards) {
                assert_eq!(card, Some(board::suggestion(rows, &citizens, t, *id)), "seed {seed} step {step} application {id}");
            }
        }
    }
}
