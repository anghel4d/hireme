//! Arbitrary text through every kernel entry point that reads it, seeded:
//! no panic, and a bounded run time. Agents write these fields, so any
//! string an op can carry must be survivable: multi-byte signs, combining
//! marks, emoji, right-to-left text, NUL, the edges of the scalar range,
//! and very long runs. native/kernel/fuzz.mjs drives the same shapes
//! through the wasm exports.

use std::time::{Duration, Instant};

use kernel::abi::{self, Kernel};
use kernel::judge::Ctx;
use kernel::{ats, atlas, cv, keywords, org, score, text};
use schema::{col, enums, table};

const TODAY: i32 = 20_000;

/// Pieces that have broken text code before, or could.
const PIECES: &[&str] = &[
    "0", "7", "250", "401", "1.2", "45.000", ",", ".", "k", "K", "m", "M", "$", "€", "£", "¥", "°", "%", "+", "#",
    "&", ";", "&amp;", "&#x26;", "<", ">", "<style>", "</script>", "<!--", "-->", "(", ")", "(k)", "[", "](", "http://",
    "www.", "://", "?", "=", "/", " ", "\u{a0}", "\t", "\n", "\u{1f}", "\0", "é", "e\u{301}", "\u{308}", "İ", "ß", "ẞ",
    "Ƕ", "ɓ", "Æ", "ø", "ł", "й", "한", "日本", "🙂", "👩‍💻", "\u{202e}", "مهندس", "מהנדס", "\u{feff}", "\u{fffd}",
    "\u{d7ff}", "\u{e000}", "\u{10ffff}", "usd", "eur", "rust", "c++", "c#", "node.js", "e.g.", "Engineer", "Senior",
    "Google", "Anthropic", "staffing", "intern", "onsite only", "remote", "greenhouse.io", "jobs.lever.co", "wd5.myworkdayjobs.com",
];

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    /// A string of up to `max` pieces; one in sixteen is a long run of one
    /// piece instead.
    fn text(&mut self, max: usize) -> String {
        if self.below(16) == 0 {
            return PIECES[self.below(PIECES.len())].repeat(1 + self.below(20_000));
        }
        (0..self.below(max + 1)).map(|_| PIECES[self.below(PIECES.len())]).collect()
    }
}

/// Runs `f`, failing past `limit`; the seed is in the message.
fn bounded<T>(what: &str, seed: u64, limit: Duration, f: impl FnOnce() -> T) -> T {
    let t = Instant::now();
    let out = f();
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
        let (a, b, c, d) = (r.text(30), r.text(30), r.text(30), r.text(30));
        bounded("text", seed, limit, || {
            let n = text::normalize(&a);
            assert_eq!(text::normalize(&n), n, "normalize is idempotent (seed {seed})");
            let _ = (text::fold(&a), text::codes(&b), text::word(&n, "rust"), text::starts(&n, "eng"));
        });
        bounded("org/ats", seed, limit, || {
            let _ = (org::size(&a), org::department(&b), org::family(&b), org::company_key(&a));
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
            let places = [atlas::Place { id: 1, iso2: Some(&a), name: &b, language: Some(&c), work_permit: Some(&d), ..Default::default() }];
            let me = atlas::Me { citizenships: &d, languages: &c, weights: atlas::Weights::default() };
            let _ = atlas::order(&atlas::fit(&places, &me));
        });
    }
}

/// A desk whose every text column is arbitrary, then every document and
/// a write of arbitrary text, through the facade the browser, the MCP and
/// the NIF use.
#[test]
fn a_desk_of_any_text_derives_judges_and_composes() {
    use col::applications as A;
    let limit = Duration::from_millis(if cfg!(debug_assertions) { 20_000 } else { 2_000 });
    let seeds: u64 = if cfg!(debug_assertions) { 6 } else { 40 };
    for seed in 1..=seeds {
        let mut r = Rng(seed.wrapping_mul(0xD1B5_4A32_D192_ED03));
        let n = 40;
        let texts: Vec<[String; 8]> = (0..n).map(|_| core::array::from_fn(|_| r.text(12))).collect();
        let mut w = wire::BodyWriter::new();
        let mut b = w.block(table::APPLICATIONS, n);
        let col = |i: usize| texts.iter().map(move |t| t[i].as_str());
        b.u32s(A::ID, 1..=n as u32)
            .u32s(A::NO, 1..=n as u32)
            .u32s(A::STAGE, (0..n).map(|i| (i % 10) as u32))
            .u32s(A::CORPORATION_ID, (0..n).map(|i| 1 + (i % 3) as u32))
            .u32s(A::PLACE_ID, (0..n).map(|_| 1))
            .u32s(A::STAGE_ON, (0..n).map(|_| TODAY as u32))
            .strs(A::COMPANY, col(0))
            .strs(A::ROLE, col(1))
            .strs(A::LOCATION, col(2))
            .strs(A::COMP_RAW, col(3))
            .strs(A::LISTING_URL, col(4))
            .strs(A::KEYWORDS, col(5))
            .strs(A::STAGE_NOTES, col(6))
            .strs(A::CV_THEME, col(7));
        b.done();
        let mut b = w.block(table::ITEMS, n);
        b.u32s(col::items::ID, 1..=n as u32).strs(col::items::TITLE, col(1)).strs(col::items::BODY, col(5)).strs(col::items::KEY, col(0));
        b.done();
        let mut b = w.block(table::SETTINGS, 1);
        b.u32s(col::settings::ID, [1].into_iter())
            .strs(col::settings::CITIZENSHIPS, [texts[0][2].as_str()].into_iter())
            .strs(col::settings::LANGUAGES, [texts[1][2].as_str()].into_iter())
            .strs(col::settings::HEAT_CONFIG, [texts[2][6].as_str()].into_iter());
        b.done();
        let mut b = w.block(table::ATLAS, 1);
        b.u32s(col::atlas::ID, [1].into_iter())
            .u32s(col::atlas::KIND, [enums::place_kind::COUNTRY as u32].into_iter())
            .u32s(col::atlas::ATLAS_POSITION, [1].into_iter())
            .strs(col::atlas::ISO2, [texts[3][0].as_str()].into_iter())
            .strs(col::atlas::NAME, [texts[3][1].as_str()].into_iter())
            .strs(col::atlas::LANGUAGE, [texts[3][2].as_str()].into_iter())
            .strs(col::atlas::WORK_PERMIT, [texts[3][3].as_str()].into_iter());
        b.done();
        bounded("desk", seed, limit, || {
            let mut k = Kernel::new();
            k.set_today(TODAY);
            k.boot(&w.finish(), 1).unwrap();
            let search = r.text(4);
            let _ = k.view(&abi::filter(&serde_json::json!({"search": search}).to_string()));
            for id in 1..=n as u32 {
                let _ = k.application(id);
            }
            let _ = (k.overview(10), k.atlas(None), k.lanes(), k.board_ids(None));
            let ctx = Ctx { today: TODAY, now: 0, human: false, key_id: Some(1), held: &[] };
            for id in 1..=4u32 {
                let mut ow = wire::OpsWriter::new();
                ow.op(id as u64, wire::PUT, 0, table::APPLICATIONS, id, None)
                    .str(A::LISTING_RAW, &r.text(40))
                    .str(A::COMP_RAW, &r.text(6))
                    .str(A::COMPANY, &r.text(6));
                let op = ow.finish()[8..].to_vec();
                let _ = k.judge(&op, &ctx);
                let _ = k.predict(&op, &ctx);
                let mut ow = wire::OpsWriter::new();
                ow.op(100 + id as u64, wire::COMMAND, 0, schema::command::NOTE, id, None)
                    .u32(schema::param::note::STAGE, 0)
                    .str(schema::param::note::BODY, &r.text(8));
                let _ = k.predict(&ow.finish()[8..], &ctx);
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
