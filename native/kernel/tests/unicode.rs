//! Arbitrary text through every kernel entry point that reads it, seeded:
//! no panic, and a bounded run time. Agents write these fields, so any
//! string an op can carry must be survivable: multi-byte signs, combining
//! marks, emoji, right-to-left text, NUL, the edges of the scalar range,
//! and very long runs. native/kernel/fuzz.mjs drives arbitrary text
//! through the wasm exports.

use std::time::{Duration, Instant};

mod fixture;

use fixture::{Rng, TODAY, agent, cmd, put};
use kernel::abi::{self, Kernel};
use kernel::pipeline::{self, Stage};
use kernel::{ats, atlas, cv, keywords, org, score, text};
use serde_json::{Value as Json, json};

/// Pieces that have broken text code before, or could.
const PIECES: &[&str] = &[
    "0", "7", "250", "401", "1.2", "45.000", ",", ".", "k", "K", "m", "M", "$", "€", "£", "¥", "°", "%", "+", "#",
    "&", ";", "&amp;", "&#x26;", "<", ">", "<style>", "</script>", "<!--", "-->", "(", ")", "(k)", "[", "](", "http://",
    "www.", "://", "?", "=", "/", " ", "\u{a0}", "\t", "\n", "\u{1f}", "\0", "é", "e\u{301}", "\u{308}", "İ", "ß", "ẞ",
    "Ƕ", "ɓ", "Æ", "ø", "ł", "й", "한", "日本", "🙂", "👩‍💻", "\u{202e}", "مهندس", "מהנדס", "\u{feff}", "\u{fffd}",
    "\u{d7ff}", "\u{e000}", "\u{10ffff}", "usd", "eur", "rust", "c++", "c#", "node.js", "e.g.", "Engineer", "Senior",
    "Google", "Anthropic", "staffing", "intern", "onsite only", "remote", "greenhouse.io", "jobs.lever.co", "wd5.myworkdayjobs.com",
];

/// A string of up to `max` pieces; one in sixteen is a long run of one
/// piece instead.
fn any(r: &mut Rng, max: u64) -> String {
    if r.below(16) == 0 {
        return r.pick(PIECES).repeat(1 + r.below(20_000) as usize);
    }
    (0..r.below(max + 1)).map(|_| *r.pick(PIECES)).collect()
}

/// Runs `f`, failing past `limit` or on a panic; either way the message
/// names the seed, so a failure replays.
fn bounded<T>(what: &str, seed: u64, limit: Duration, f: impl FnOnce() -> T) -> T {
    let t = Instant::now();
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|e| {
        let why = e
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| e.downcast_ref::<&str>().copied())
            .unwrap_or("a panic");
        panic!("{what} panicked (seed {seed}): {why}")
    });
    assert!(t.elapsed() < limit, "{what} took {:?} (seed {seed})", t.elapsed());
    out
}

#[test]
fn every_text_reader_survives_any_text() {
    let limit = Duration::from_millis(if cfg!(debug_assertions) { 2_000 } else { 200 });
    // Every build runs it; the release run (CI's) covers more seeds.
    let seeds: u64 = if cfg!(debug_assertions) { 100 } else { 400 };
    for seed in 1..=seeds {
        let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15));
        let (a, b, c, d) = (any(&mut r, 30), any(&mut r, 30), any(&mut r, 30), any(&mut r, 30));
        bounded("text", seed, limit, || {
            let n = text::normalize(&a);
            assert_eq!(text::normalize(&n), n, "normalize is idempotent (seed {seed})");
            let _ = (text::fold(&a), text::codes(&b));
        });
        bounded("org/ats", seed, limit, || {
            let (company, role) = (text::normalize(&a), text::normalize(&b));
            let _ = (org::size(&company), org::department(&role), org::family(&role));
            let _ = (ats::parse(&c), ats::parse(&format!("https://{c}/{d}?for={a}")));
        });
        bounded("score", seed, limit, || {
            let _ = score::high_comp(&d);
            let _ = score::suggest(&score::Seat { company: &a, role: &b, location: &c, comp_raw: &d, onsite: true, home: Some(false) });
        });
        bounded("keywords", seed, limit, || {
            for f in [keywords::Format::Text, keywords::Format::Markdown, keywords::Format::Html] {
                let k = keywords::extract(&a, f);
                let joined = keywords::join(&k);
                let cvt = keywords::Text::new(&b);
                let _ = keywords::coverage(text::list(&joined).chain([c.as_str(), d.as_str()]), &cvt);
            }
        });
        bounded("cv theme", seed, limit, || {
            let json = serde_json::json!({"lead": a, "accent": b, "targets": [c, d]}).to_string();
            let _ = cv::Theme::parse(Some(&json)).over(cv::Theme::parse(Some(&d)));
        });
        bounded("atlas", seed, limit, || {
            let places = [atlas::Place { id: 1, iso2: Some(&a), name: &b, language: Some(&c), work_permit: Some(&d), figures: vec![Some(1.0)], ..Default::default() }];
            let me = atlas::Me { citizenships: &d, work_permits: &a, languages: c.as_str().into(), prefer: &b, avoid: &c, metrics: vec![1.0], route: 1.0, language: 1.0 };
            let _ = atlas::order(&places, &atlas::fit(&places, &me));
        });
    }
}

/// A desk whose every text column is arbitrary, then every document and
/// a write of arbitrary text, through the facade the browser, the MCP and
/// the NIF use.
#[test]
fn a_desk_of_any_text_derives_judges_and_composes() {
    let limit = Duration::from_millis(if cfg!(debug_assertions) { 20_000 } else { 2_000 });
    let seeds: u64 = if cfg!(debug_assertions) { 6 } else { 40 };
    for seed in 1..=seeds {
        let mut r = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03));
        let n = 40;
        let t: Vec<[String; 13]> = (0..n).map(|_| core::array::from_fn(|_| any(&mut r, 12))).collect();
        // Most rails are real ones, so the paths reading a rail run; the
        // rest are arbitrary text, which falls back to the stage.
        let rail = |i: usize| match i % 3 {
            0 => t[i][8].clone(),
            k => {
                let s = Stage::from_u32((i % 10) as u32).unwrap();
                let rail = if k == 1 { pipeline::initial(s) } else { pipeline::move_to(&pipeline::initial(Stage::Discovered), s) };
                String::from_utf8(pipeline::encode(&rail).to_vec()).unwrap()
            }
        };
        let rows = json!({
            "applications": (0..n).map(|i| json!({"id": i + 1, "no": i + 1, "stage": i % 10, "corporation_id": 1 + i % 3, "place_id": 1, "stage_on": TODAY, "company": t[i][0], "role": t[i][1],
                "location": t[i][2], "comp_raw": t[i][3], "listing_url": t[i][4], "keywords": t[i][5], "stage_notes": t[i][6], "cv_theme": t[i][7], "pips": rail(i), "canonical_url": t[i][9]})).collect::<Json>(),
            "cv_overlays": (0..n).map(|i| json!({"id": i + 1, "application_id": i + 1, "item_id": 1 + i % 7, "mode": i % 3, "lineage_id": if i % 4 == 0 { Json::Null } else { json!(1 + i % 2) },
                "title": t[i][10], "body": t[i][11], "reason": t[i][12]})).collect::<Json>(),
            "cv_lineages": [{"id": 1, "corporation_id": 1, "generation": 1, "opened_on": TODAY - 10, "rewrites_allowed": true}, {"id": 2, "corporation_id": 2, "generation": 2, "opened_on": TODAY - 100, "rewrites_allowed": false}],
            "events": (0..n).map(|i| json!({"id": i + 1, "application_id": 1 + i % 5, "kind": t[i][11], "body": t[i][12]})).collect::<Json>(),
            "items": (0..n).map(|i| json!({"id": i + 1, "title": t[i][1], "body": t[i][5], "key": t[i][0]})).collect::<Json>(),
            "settings": [{"id": 1, "heat_config": t[2][6]}],
            "me": [{"id": 1, "citizenships": t[0][2]}],
            "languages": [{"id": 1, "code": t[1][2]}],
            "places": [{"id": 1, "kind": "country", "iso2": t[3][0], "name": t[3][1], "language": t[3][2], "work_permit": t[3][3]}],
        });
        bounded("desk", seed, limit, || {
            let mut k = fixture::kernel(rows);
            let _ = k.view(&abi::filter(&json!({"search": any(&mut r, 4)}).to_string()));
            for id in 1..=n as u32 {
                let _ = k.application(id);
            }
            let _ = (k.overview(10), k.atlas(), k.board_ids(None));
            for id in 1..=4u32 {
                let op = put("applications", id, json!({"listing_raw": any(&mut r, 40), "comp_raw": any(&mut r, 6), "company": any(&mut r, 6)}));
                let _ = k.judge(&op, &agent(1, 0));
                let _ = k.predict(&op, &agent(1, 0));
                let _ = k.predict(&cmd("note", id, json!({"stage": 0, "body": any(&mut r, 8)})), &agent(1, 0));
            }
            let _ = (k.overview(10), k.application(1));
            let mut restored = Kernel::new();
            restored.restore(&k.snapshot()).unwrap();
        });
    }
}

/// `normalize` is idempotent on every scalar value, alone and after a
/// letter (so combining marks are exercised in place).
#[test]
fn normalize_is_idempotent_on_every_scalar() {
    for cp in 0..=0x10FFFFu32 {
        let Some(c) = char::from_u32(cp) else { continue };
        for s in [c.to_string(), format!("a{c}b")] {
            let n = text::normalize(&s);
            assert_eq!(text::normalize(&n), n, "U+{cp:04X}");
        }
    }
}
