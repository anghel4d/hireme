//! The heat governor, ported from `lib/hireme/heat/*` for the browser.
//!
//! Everything here is a pure function of the account's job rows and the
//! server's `today`, written to give the same answers as the Elixir
//! reference bit for bit: the same float operations in the same order,
//! Elixir's own `Float.round/2` (which rounds the exact decimal expansion,
//! not `x * 10^n`), `:erlang.float_to_binary(x, decimals: 1)` for notes,
//! and `pow`/`log2` computed in double-double so they round as libm does.
//! The regexes of `Hireme.Heat.Org` and the `URI.parse` behind
//! `Hireme.Heat.Ats` are hand-written matchers over the same bytes.
//! The oracle dump from ops is the proof (native/kernel/test.mjs).

use alloc::collections::BTreeMap;

use crate::store::sort_usize;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

// ---- configuration (Hireme.Heat.Config.defaults/0) ------------------------

pub const COMPANY_HALF_LIFE: f64 = 35.0;
pub const ATS_VENDOR_HALF_LIFE: f64 = 14.0;
pub const ATS_TENANT_HALF_LIFE: f64 = 21.0;
pub const APPLICATION_LOAD: f64 = 1.0;
pub const SAME_DEPARTMENT_PENALTY: f64 = 0.6;
pub const CLONE_PENALTY: f64 = 0.6;
pub const ATS_VENDOR_CAP: f64 = 40.0;
pub const ATS_TENANT_CAP: f64 = 3.0;
pub const ATS_BATCH_CAP: u32 = 20;
pub const COOL_RATIO: f64 = 0.5;
pub const HOT_RATIO: f64 = 0.8;

const NONE: u32 = u32::MAX;

// ---- the pipeline (Hireme.Pipeline) --------------------------------------

pub const STAGES: [&str; 10] = [
    "discovered",
    "freshness",
    "gated",
    "in_batch",
    "draft_ready",
    "fire_ready",
    "open_fire",
    "submitted",
    "reply",
    "closed",
];

pub fn stage_ix(name: &str) -> Option<u8> {
    STAGES.iter().position(|s| *s == name).map(|i| i as u8)
}

/// fire_ready, open_fire, submitted, reply, closed.
pub fn hot_stage(ix: Option<u8>) -> bool {
    matches!(ix, Some(5..=9))
}

/// fire_ready, open_fire, submitted.
pub fn queue_stage(ix: u8) -> bool {
    matches!(ix, 5..=7)
}

/// open_fire, submitted.
pub fn fire_locked(ix: u8) -> bool {
    matches!(ix, 6 | 7)
}

/// Heat.entering?/2.
pub fn entering(from: Option<u8>, to: u8) -> bool {
    !hot_stage(from) && queue_stage(to)
}

// ---- numbers -------------------------------------------------------------

#[inline]
pub fn trunc(x: f64) -> f64 {
    if !(x.abs() < 4_503_599_627_370_496.0) {
        return x;
    }
    (x as i64) as f64
}

#[inline]
pub fn floor(x: f64) -> f64 {
    let t = trunc(x);
    if t > x { t - 1.0 } else { t }
}

#[inline]
pub fn ceil(x: f64) -> f64 {
    let t = trunc(x);
    if t < x { t + 1.0 } else { t }
}

/// Kernel.round/1 on a float: half away from zero.
pub fn round0(x: f64) -> i64 {
    let a = floor(x.abs() + 0.5);
    // floor(a + 0.5) is wrong exactly at 0.49999999999999994; Erlang's
    // round is C's round(), so correct for it.
    let a = if a - x.abs() > 0.5 { a - 1.0 } else { a };
    if x < 0.0 { -(a as i64) } else { a as i64 }
}

/// Elixir's `Float.round(x, precision)` for small precisions: the exact
/// decimal expansion truncated one digit past `precision`, rounded half
/// up on that digit (away from zero), then the nearest float to the
/// result.
pub fn round_to(x: f64, precision: u32) -> f64 {
    if x == 0.0 || !x.is_finite() {
        return x;
    }
    let bits = x.to_bits();
    let neg = bits >> 63 == 1;
    let exp = ((bits >> 52) & 0x7ff) as i32;
    if exp == 0 {
        // Subnormal: far below any precision asked for here.
        return if neg { -0.0 } else { 0.0 };
    }
    let m = (bits & ((1u64 << 52) - 1)) | (1u64 << 52);
    // x = m * 2^(exp - 1075). Fractional bits of x:
    let shift = 1075 - exp;
    if shift <= 0 {
        return x; // an integer
    }
    // `count` in Elixir: fractional binary digits after stripping zeros.
    let count = shift - m.trailing_zeros() as i32;
    if count <= precision as i32 {
        return x;
    }
    if count >= 104 {
        return if neg { -0.0 } else { 0.0 };
    }
    let p10 = 10u128.pow(precision + 1);
    let scaled = if shift >= 128 {
        0
    } else {
        ((m as u128) * p10) >> shift
    };
    let digit = scaled % 10;
    let mut n = scaled / 10;
    if digit >= 5 {
        n += 1;
    }
    if n == 0 {
        return if neg { -0.0 } else { 0.0 };
    }
    // n < 2^53 for every value this module rounds, so both operands are
    // exact and IEEE division gives the nearest float, ties to even, as
    // Elixir's decimal_to_float does.
    let r = n as f64 / 10u64.pow(precision) as f64;
    if neg { -r } else { r }
}

#[inline]
pub fn round4(x: f64) -> f64 {
    round_to(x, 4)
}

/// `:erlang.float_to_binary(x, decimals: 1)` for the non-negative values
/// a verdict note prints.
pub fn fmt1(x: f64, out: &mut String) {
    let neg = x < 0.0;
    let a = x.abs();
    let int = trunc(a);
    let n = floor((a - int) * 10.0 + 0.5);
    let (int, d) = if n >= 10.0 {
        (int + 1.0, 0)
    } else {
        (int, n as u32)
    };
    if neg && (int != 0.0 || d != 0) {
        out.push('-');
    }
    push_u64(out, int as u64);
    out.push('.');
    out.push((b'0' + d as u8) as char);
}

fn push_u64(out: &mut String, n: u64) {
    let mut buf = [0u8; 20];
    let mut i = buf.len();
    let mut n = n;
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    out.push_str(core::str::from_utf8(&buf[i..]).unwrap_or(""));
}

// Double-double arithmetic, enough to round exp2 and log2 the way libm does.

#[derive(Clone, Copy)]
struct Dd(f64, f64);

#[inline]
fn two_sum(a: f64, b: f64) -> Dd {
    let s = a + b;
    let bb = s - a;
    Dd(s, (a - (s - bb)) + (b - bb))
}

#[inline]
fn split(a: f64) -> (f64, f64) {
    let t = 134_217_729.0 * a; // 2^27 + 1
    let hi = t - (t - a);
    (hi, a - hi)
}

#[inline]
fn two_prod(a: f64, b: f64) -> Dd {
    let p = a * b;
    let (ah, al) = split(a);
    let (bh, bl) = split(b);
    Dd(p, ((ah * bh - p) + ah * bl + al * bh) + al * bl)
}

impl Dd {
    #[inline]
    fn add(self, o: Dd) -> Dd {
        let s = two_sum(self.0, o.0);
        let t = two_sum(self.1, o.1);
        let s = two_sum(s.0, s.1 + t.0);
        two_sum(s.0, s.1 + t.1)
    }

    #[inline]
    fn mul(self, o: Dd) -> Dd {
        let p = two_prod(self.0, o.0);
        two_sum(p.0, p.1 + (self.0 * o.1 + self.1 * o.0))
    }

    #[inline]
    fn div(self, o: Dd) -> Dd {
        let q1 = self.0 / o.0;
        let r = self.add(o.mul(Dd(-q1, 0.0)));
        let q2 = r.0 / o.0;
        let r = r.add(o.mul(Dd(-q2, 0.0)));
        let q3 = r.0 / o.0;
        two_sum(q1, q2).add(Dd(q3, 0.0))
    }
}

const LN2: Dd = Dd(core::f64::consts::LN_2, 2.3190468138462996e-17);
const INV_LN2: Dd = Dd(core::f64::consts::LOG2_E, 2.0355273740931033e-17);

fn pow2i(k: i32) -> f64 {
    f64::from_bits(((k + 1023) as u64) << 52)
}

/// 2^t, correctly rounded but for cases no libm resolves differently.
pub fn exp2(t: f64) -> f64 {
    if t > 1023.0 {
        return f64::INFINITY;
    }
    if t < -1074.0 {
        return 0.0;
    }
    let k = floor(t + 0.5);
    let f = t - k; // exact, |f| <= 0.5
    let y = Dd(f, 0.0).mul(LN2);
    // exp(y) by Taylor series in double-double; |y| < 0.35.
    let mut sum = Dd(1.0, 0.0);
    let mut term = Dd(1.0, 0.0);
    for n in 1..28 {
        term = term.mul(y).div(Dd(n as f64, 0.0));
        sum = sum.add(term);
        if term.0.abs() < 1e-36 {
            break;
        }
    }
    let k = k as i32;
    let v = sum.0 + sum.1;
    if k < -1022 {
        // Scale in two steps so the subnormal result rounds once.
        v * pow2i(k + 600) * pow2i(-600)
    } else {
        v * pow2i(k)
    }
}

/// `:math.pow(0.5, y)`.
pub fn half_pow(y: f64) -> f64 {
    exp2(-y)
}

/// `:math.log2(z)` for z > 0.
pub fn log2(z: f64) -> f64 {
    if !(z > 0.0) || !z.is_finite() {
        return f64::NAN;
    }
    let bits = z.to_bits();
    let mut e = ((bits >> 52) & 0x7ff) as i32 - 1023;
    let mut m = f64::from_bits((bits & ((1u64 << 52) - 1)) | (1023u64 << 52));
    if (bits >> 52) & 0x7ff == 0 {
        // Subnormal: normalise first.
        let n = z * pow2i(54);
        return log2(n) - 54.0;
    }
    if m > core::f64::consts::SQRT_2 {
        m /= 2.0;
        e += 1;
    }
    // log(m) = 2 atanh(s), s = (m - 1) / (m + 1).
    let num = Dd(m - 1.0, 0.0);
    let den = two_sum(m, 1.0);
    let s = num.div(den);
    let s2 = s.mul(s);
    let mut sum = s;
    let mut pow = s;
    for k in 1..40 {
        pow = pow.mul(s2);
        let term = pow.div(Dd((2 * k + 1) as f64, 0.0));
        sum = sum.add(term);
        if term.0.abs() < 1e-36 {
            break;
        }
    }
    let ln = sum.add(sum);
    let r = ln.mul(INV_LN2).add(Dd(e as f64, 0.0));
    r.0 + r.1
}

/// Heat.decay/3.
pub fn decay(days: i64, half_life: f64) -> f64 {
    if days <= 0 {
        return APPLICATION_LOAD;
    }
    memo::decay(days, half_life)
}

fn decay_exact(days: i64, half_life: f64) -> f64 {
    round4(APPLICATION_LOAD * half_pow(days as f64 / half_life))
}

/// Decay is a pure function of (days, half-life), and a derive asks for
/// the same few hundred values thousands of times: they are kept once
/// computed, per thread (the WebAssembly build has one).
mod memo {
    use alloc::vec::Vec;

    pub fn decay(days: i64, half_life: f64) -> f64 {
        let slot = if half_life == super::COMPANY_HALF_LIFE {
            0
        } else if half_life == super::ATS_VENDOR_HALF_LIFE {
            1
        } else if half_life == super::ATS_TENANT_HALF_LIFE {
            2
        } else {
            return super::decay_exact(days, half_life);
        };
        if days >= 8192 {
            return super::decay_exact(days, half_life);
        }
        with(|m| {
            let (v, d) = (&mut m[slot], days as usize);
            if v.len() <= d {
                v.resize(d + 1, f64::NAN);
            }
            if v[d].is_nan() {
                v[d] = super::decay_exact(days, half_life);
            }
            v[d]
        })
    }

    #[cfg(target_arch = "wasm32")]
    fn with<R>(f: impl FnOnce(&mut [Vec<f64>; 3]) -> R) -> R {
        struct Memo(core::cell::UnsafeCell<[Vec<f64>; 3]>);
        // SAFETY: wasm32-unknown-unknown without atomics has one thread.
        unsafe impl Sync for Memo {}
        static MEMO: Memo = Memo(core::cell::UnsafeCell::new([Vec::new(), Vec::new(), Vec::new()]));
        // SAFETY: one thread, and no reference to the memo outlives this call.
        f(unsafe { &mut *MEMO.0.get() })
    }

    #[cfg(not(target_arch = "wasm32"))]
    fn with<R>(f: impl FnOnce(&mut [Vec<f64>; 3]) -> R) -> R {
        std::thread_local!(static MEMO: core::cell::RefCell<[Vec<f64>; 3]> = const { core::cell::RefCell::new([Vec::new(), Vec::new(), Vec::new()]) });
        MEMO.with(|m| f(&mut m.borrow_mut()))
    }
}

/// Heat's private cooldown/4; NONE for nil.
pub fn cooldown(load: f64, increment: f64, cap: f64, half_life: f64) -> u32 {
    if increment > cap {
        return NONE;
    }
    if load + increment <= cap || load <= 0.0 {
        return 0;
    }
    let room = cap - increment;
    if room <= 0.0 {
        return NONE;
    }
    let days = half_life * log2(load / room);
    let c = ceil(days);
    if c <= 0.0 { 0 } else { c as u32 }
}

/// Heat's private ratio/2.
pub fn ratio(load: f64, cap: f64) -> f64 {
    if cap <= 0.0 { 1.0 } else { round4(load / cap) }
}

// ---- text (Hireme.Text) --------------------------------------------------

/// String.downcase, then every run of bytes outside a-z0-9 folded to one
/// space, trimmed.
pub fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut gap = false;
    let mut push = |c: char, out: &mut String| {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            gap = false;
            out.push(c);
        } else {
            gap = true;
        }
    };
    if s.is_ascii() {
        for b in s.bytes() {
            push(b.to_ascii_lowercase() as char, &mut out);
        }
    } else {
        for c in downcase(s).chars() {
            // A non-ASCII char is one or more non a-z0-9 bytes: one gap.
            push(c, &mut out);
        }
    }
    out
}

/// String.downcase/1: per-character Unicode lowercasing (Elixir does not
/// apply the final-sigma rule).
pub fn downcase(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        out.extend(c.to_lowercase());
    }
    out
}

/// Elixir's String.trim/1: Unicode White_Space at both ends, which is
/// exactly what `str::trim` strips.
pub fn trim(s: &str) -> &str {
    s.trim()
}

// ---- org traits (Hireme.Heat.Org) ----------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Size {
    Mega,
    Large,
    Mid,
    Small,
}

impl Size {
    pub fn name(self) -> &'static str {
        match self {
            Size::Mega => "mega",
            Size::Large => "large",
            Size::Mid => "mid",
            Size::Small => "small",
        }
    }

    pub fn cap(self) -> f64 {
        match self {
            Size::Mega => 4.0,
            Size::Large => 2.5,
            Size::Mid => 1.5,
            Size::Small => 1.0,
        }
    }
}

const MEGA: [&str; 8] = [
    "google",
    "alphabet",
    "amazon",
    "aws",
    "meta",
    "facebook",
    "nvidia",
    "microsoft",
];
const LARGE: &[&str] = &[
    "apple",
    "netflix",
    "uber",
    "stripe",
    "databricks",
    "snowflake",
    "tesla",
    "adobe",
    "salesforce",
    "oracle",
    "linkedin",
    "snap",
    "pinterest",
    "shopify",
    "openai",
    "anthropic",
    "spacex",
    "neuralink",
    "xai",
    "starfish",
    "valve",
    "gdm",
    "deepmind",
    "ssi",
    "mira",
];

/// Org.size/1 over a company name.
pub fn size(company: &str) -> Size {
    let name = normalize(company);
    let compact: String = name.chars().filter(|c| *c != ' ').collect();
    let parts: Vec<&str> = name.split(' ').collect();
    let any = |set: &[&str]| set.iter().any(|a| *a == compact || parts.contains(a));
    if any(&MEGA) {
        Size::Mega
    } else if any(LARGE) {
        Size::Large
    } else if words(&name, &["systems", "runtime", "infra", "lab", "labs"]) {
        Size::Mid
    } else {
        Size::Small
    }
}

/// In a normalized text (words of a-z0-9 split by single spaces), is any
/// phrase present starting at a word start (`\bphrase`)? With `whole`,
/// it must also end at a word end (`\b(phrase)\b`). One pass over the
/// word starts.
fn at_word(n: &str, phrases: &[&str], whole: bool) -> bool {
    let b = n.as_bytes();
    let starts = core::iter::once(0).chain(b.iter().enumerate().filter(|x| *x.1 == b' ').map(|x| x.0 + 1));
    starts.into_iter().any(|at| {
        phrases.iter().any(|p| {
            let end = at + p.len();
            b.get(at) == p.as_bytes().first() && b[at..].starts_with(p.as_bytes()) && (!whole || end == b.len() || b[end] == b' ')
        })
    })
}

fn starts(n: &str, phrases: &[&str]) -> bool {
    at_word(n, phrases, false)
}

fn words(n: &str, phrases: &[&str]) -> bool {
    at_word(n, phrases, true)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Dept {
    Infra,
    Research,
    Security,
    Data,
    Product,
    Eng,
    Other,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Family {
    SoftwareEngineer,
    ResearchEngineer,
    ResearchScientist,
    Sre,
    DataEngineer,
    SecurityEngineer,
    Other,
}

fn infer_department(n: &str) -> Dept {
    // research: \b(research|scientist|machine learning|\bml\b|applied sci)
    if starts(
        n,
        &["research", "scientist", "machine learning", "applied sci"],
    ) || words(n, &["ml"])
    {
        Dept::Research
    } else if starts(
        n,
        &[
            "sre",
            "site reliability",
            "infra",
            "platform",
            "runtime",
            "kernel",
            "systems",
        ],
    ) {
        Dept::Infra
    } else if starts(n, &["security", "privacy"]) {
        Dept::Security
    } else if starts(n, &["data engineer", "analytics", "data platform"]) {
        Dept::Data
    } else if starts(
        n,
        &[
            "frontend",
            "front end",
            "ios",
            "android",
            "mobile",
            "product engineer",
        ],
    ) {
        Dept::Product
    } else if starts(n, &["engineer", "developer", "swe"]) {
        Dept::Eng
    } else {
        Dept::Other
    }
}

/// Org.department/1 from the job's department, role, squad and fit.
pub fn department(department: &str, role: &str, squad: &str, fit: &str) -> Dept {
    let explicit = trim(department);
    if !explicit.is_empty() {
        let n = normalize(explicit);
        let is = |set: &[&str]| set.iter().any(|s| *s == n);
        if is(&[
            "infra",
            "infrastructure",
            "sre",
            "platform",
            "runtime",
            "kernel",
            "systems",
        ]) {
            Dept::Infra
        } else if is(&["research", "ml", "science", "ai"]) {
            Dept::Research
        } else if is(&["security", "privacy"]) {
            Dept::Security
        } else if is(&["data", "analytics"]) {
            Dept::Data
        } else if is(&["product", "frontend", "mobile", "web"]) {
            Dept::Product
        } else if is(&["eng", "engineering"]) {
            Dept::Eng
        } else {
            infer_department(&n)
        }
    } else {
        let mut blob = String::with_capacity(role.len() + squad.len() + fit.len() + 2);
        for (i, part) in [role, squad, fit].iter().enumerate() {
            if i > 0 {
                blob.push(' ');
            }
            blob.push_str(trim(part));
        }
        infer_department(&normalize(&blob))
    }
}

const SENIORITY: [&str; 18] = [
    "staff",
    "senior",
    "sr",
    "principal",
    "distinguished",
    "fellow",
    "junior",
    "jr",
    "intern",
    "iii",
    "ii",
    "i",
    "l3",
    "l4",
    "l5",
    "l6",
    "l7",
    "l8",
];

/// Org.family/1 from the job's role.
pub fn family(role: &str) -> Family {
    // Seniority words go; the rest is rejoined with single spaces.
    let n = normalize(trim(role));
    let mut kept = String::with_capacity(n.len());
    for w in n
        .split(' ')
        .filter(|w| !w.is_empty() && !SENIORITY.contains(w))
    {
        if !kept.is_empty() {
            kept.push(' ');
        }
        kept.push_str(w);
    }
    let n = kept.as_str();
    if starts(n, &["research scientist"]) || n.contains("applied scientist") {
        Family::ResearchScientist
    } else if starts(n, &["research engineer"]) {
        Family::ResearchEngineer
    } else if words(n, &["site reliability", "sre"]) {
        Family::Sre
    } else if starts(n, &["data engineer"]) {
        Family::DataEngineer
    } else if starts(n, &["security engineer"]) {
        Family::SecurityEngineer
    } else if starts(n, &["software engineer", "swe", "engineer", "developer"]) {
        Family::SoftwareEngineer
    } else {
        Family::Other
    }
}

// ---- ATS (Hireme.Heat.Ats) -----------------------------------------------

pub const VENDORS: [&str; 15] = [
    "greenhouse",
    "lever",
    "ashby",
    "workday",
    "icims",
    "smartrecruiters",
    "workable",
    "jobvite",
    "taleo",
    "successfactors",
    "bamboohr",
    "rippling",
    "eightfold",
    "gem",
    "unknown",
];
pub const UNKNOWN: u8 = 14;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Ats {
    pub vendor: u8,
    pub tenant: Option<String>,
}

const ROOTS: [&[&str]; 14] = [
    &["greenhouse.io", ".greenhouse.net"],
    &["lever.co"],
    &["ashbyhq.com"],
    &[], // workday: special
    &["icims.com"],
    &["smartrecruiters.com"],
    &["workable.com"],
    &["jobvite.com"],
    &["taleo.net"],
    &[
        ".successfactors.com",
        ".successfactors.eu",
        ".sapsf.com",
        ".sapsf.eu",
    ],
    &["bamboohr.com"],
    &[".rippling.com"],
    &[".eightfold.ai"],
    &["gem.com"],
];

/// The host URI.parse finds in a (trimmed) URL, or None.
fn uri_host(s: &str) -> Option<&str> {
    let b = s.as_bytes();
    // Scheme: [a-z][a-z0-9+\-.]* ':' (case-insensitive), optional.
    let mut i = 0;
    if !b.is_empty() && b[0].is_ascii_alphabetic() {
        let mut j = 1;
        while j < b.len() && (b[j].is_ascii_alphanumeric() || matches!(b[j], b'+' | b'-' | b'.')) {
            j += 1;
        }
        if j < b.len() && b[j] == b':' {
            i = j + 1;
        }
    }
    if !s[i..].starts_with("//") {
        return None;
    }
    let start = i + 2;
    let end = s[start..]
        .find(['/', '?', '#'])
        .map_or(s.len(), |k| start + k);
    let auth = &s[start..end];
    if auth.is_empty() {
        // "//" alone: an empty host, which Ats still reads (as unknown).
        return Some("");
    }
    // (^(.*)@)?  greedy, and `.` stops at a newline.
    let line = auth.find('\n').map_or(auth, |k| &auth[..k]);
    let rest = match line.rfind('@') {
        Some(k) => &auth[k + 1..],
        None => auth,
    };
    // (\[[a-zA-Z0-9:.]*\]|[^:]*)
    let host = if rest.starts_with('[') {
        let close = rest[1..]
            .bytes()
            .position(|c| !(c.is_ascii_alphanumeric() || c == b':' || c == b'.'))
            .map(|k| k + 1);
        match close {
            Some(k) if rest.as_bytes()[k] == b']' => &rest[..=k],
            _ => &rest[..rest.find(':').unwrap_or(rest.len())],
        }
    } else {
        &rest[..rest.find(':').unwrap_or(rest.len())]
    };
    if host.is_empty() {
        return None;
    }
    Some(host.trim_start_matches('[').trim_end_matches(']'))
}

fn host_is(host: &str, root: &str) -> bool {
    if root.starts_with('.') {
        host.ends_with(root)
    } else {
        host == root || (host.ends_with(root) && host[..host.len() - root.len()].ends_with('.'))
    }
}

fn job_segment(seg: &str) -> bool {
    let d = downcase(seg);
    matches!(
        d.as_str(),
        "job" | "jobs" | "career" | "careers" | "apply" | "embed"
    )
}

fn first_segment(path: &str) -> Option<String> {
    path.split('/')
        .find(|s| !s.is_empty() && !job_segment(s))
        .map(downcase)
}

fn subdomain(host: &str, root: &str) -> Option<String> {
    let left = host.strip_suffix(root).and_then(|h| h.strip_suffix('.'))?;
    let name = left.rsplit('.').next().unwrap_or("");
    match name {
        "" | "www" | "jobs" | "boards" | "job-boards" | "apply" | "ats" => None,
        n => Some(String::from(n)),
    }
}

fn workday_host(host: &str) -> bool {
    host.contains("myworkdayjobs.com")
        || host.contains("myworkday.com")
        || host.ends_with(".wd1.myworkdaysite.com")
}

fn workday_tenant(host: &str, path: &str) -> Option<String> {
    let b = host.as_bytes();
    let lead = b
        .iter()
        .take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || **c == b'-')
        .count();
    if lead > 0 {
        let rest = &host[lead..];
        // \A([a-z0-9-]+)\.wd\d+\.
        if let Some(r) = rest.strip_prefix(".wd") {
            let digits = r.bytes().take_while(u8::is_ascii_digit).count();
            if digits > 0 && r[digits..].starts_with('.') {
                return Some(String::from(&host[..lead]));
            }
        }
        // \A([a-z0-9-]+)\.(?:myworkdayjobs|myworkday)\.com\z
        if rest == ".myworkdayjobs.com" || rest == ".myworkday.com" {
            return Some(String::from(&host[..lead]));
        }
    }
    first_segment(path)
}

/// Ats.parse/1.
#[inline(never)]
pub fn ats(url: &str) -> Ats {
    let unknown = Ats {
        vendor: UNKNOWN,
        tenant: None,
    };
    if url.is_empty() {
        return unknown;
    }
    let s = trim(url);
    let Some(host) = uri_host(s) else {
        return unknown;
    };
    let host = downcase(host);
    let path = path_of(s);
    let vendor = (0..14u8)
        .find(|&v| {
            if v == 3 {
                workday_host(&host)
            } else {
                ROOTS[v as usize].iter().any(|r| host_is(&host, r))
            }
        })
        .unwrap_or(UNKNOWN);
    let tenant = match vendor {
        0 => first_segment(path)
            .or_else(|| subdomain(&host, "greenhouse.io"))
            .or_else(|| subdomain(&host, "greenhouse.net")),
        1 => first_segment(path).or_else(|| subdomain(&host, "lever.co")),
        2 => first_segment(path).or_else(|| subdomain(&host, "ashbyhq.com")),
        6 => first_segment(path).or_else(|| subdomain(&host, "workable.com")),
        5 | 7 | 11 | 13 => first_segment(path),
        8 => subdomain(&host, "taleo.net"),
        10 => subdomain(&host, "bamboohr.com"),
        12 => subdomain(&host, "eightfold.ai"),
        3 => workday_tenant(&host, path),
        4 => {
            let t = host.strip_suffix(".icims.com").unwrap_or(&host);
            let t = t.strip_prefix("careers-").unwrap_or(t);
            match t {
                "" | "www" => None,
                t => Some(String::from(t)),
            }
        }
        9 => {
            let cut = [
                ".successfactors.com",
                ".successfactors.eu",
                ".sapsf.com",
                ".sapsf.eu",
            ]
            .iter()
            .find_map(|s| host.strip_suffix(s));
            cut.map(String::from)
        }
        _ => None,
    };
    Ats { vendor, tenant }
}

/// The path URI.parse finds: after scheme and authority, before ? or #.
fn path_of(s: &str) -> &str {
    let b = s.as_bytes();
    let mut i = 0;
    if !b.is_empty() && b[0].is_ascii_alphabetic() {
        let mut j = 1;
        while j < b.len() && (b[j].is_ascii_alphanumeric() || matches!(b[j], b'+' | b'-' | b'.')) {
            j += 1;
        }
        if j < b.len() && b[j] == b':' {
            i = j + 1;
        }
    }
    if s[i..].starts_with("//") {
        i += 2;
        i = s[i..].find(['/', '?', '#']).map_or(s.len(), |k| i + k);
    }
    let end = s[i..].find(['?', '#']).map_or(s.len(), |k| i + k);
    &s[i..end]
}

// ---- the governor --------------------------------------------------------

/// One job as the governor reads it.
#[derive(Clone, Copy)]
pub struct Job<'a> {
    pub id: u32,
    pub company: &'a str,
    pub role: &'a str,
    pub listing_url: &'a str,
    pub canonical_url: &'a str,
    pub department: &'a str,
    pub squad: &'a str,
    pub fit: &'a str,
    pub stage: Option<u8>,
    pub stage_on: u32,
    pub heat_override: bool,
    pub heat_override_reason: &'a str,
}

impl<'a> Job<'a> {
    pub fn url(&self) -> &'a str {
        if !self.listing_url.is_empty() {
            self.listing_url
        } else {
            self.canonical_url
        }
    }

    pub fn age(&self, today: u32) -> i64 {
        if self.stage_on == NONE {
            0
        } else {
            today as i64 - self.stage_on as i64
        }
    }

    /// Heat.override?/1.
    pub fn overridden(&self) -> bool {
        self.heat_override && !trim(self.heat_override_reason).is_empty()
    }
}

/// What the governor derives from a job's own text, once.
#[derive(Clone, PartialEq, Debug)]
pub struct Traits {
    pub key: String,
    pub size: Size,
    pub ats: Ats,
    pub dept: Dept,
    pub family: Family,
}

#[inline(never)]
/// Org.key/1 and Org.size/1: what a job's traits take from its company.
pub fn company(company: &str) -> (String, Size) {
    (normalize(company), size(company))
}

/// A job's traits, given its company's.
pub fn traits(j: &Job, (key, size): (String, Size)) -> Traits {
    Traits {
        key,
        size,
        ats: ats(j.url()),
        dept: department(j.department, j.role, j.squad, j.fit),
        family: family(j.role),
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Reason {
    Ok,
    Override,
    CompanyCap,
    AtsVendorCap,
    AtsTenantCap,
    AtsBatchCap,
}

impl Reason {
    pub fn name(self) -> &'static str {
        match self {
            Reason::Ok => "ok",
            Reason::Override => "override",
            Reason::CompanyCap => "company_cap",
            Reason::AtsVendorCap => "ats_vendor_cap",
            Reason::AtsTenantCap => "ats_tenant_cap",
            Reason::AtsBatchCap => "ats_batch_cap",
        }
    }
}

#[derive(Clone, Debug)]
pub struct Verdict {
    pub allow: bool,
    pub reason: Reason,
    pub company_load: f64,
    pub company_cap: f64,
    pub company_increment: f64,
    pub size: Size,
    pub vendor: u8,
    pub tenant: Option<String>,
    pub vendor_load: f64,
    pub tenant_load: f64,
    pub cooldown: u32,
    pub note: String,
}

impl Verdict {
    /// Heat.decorate/4's heat state: 0 cool, 1 warm, 2 hot, 3 blocked.
    pub fn heat_state(&self) -> u32 {
        let r = ratio(self.company_load, self.company_cap);
        if !self.allow {
            3
        } else if r >= HOT_RATIO {
            2
        } else if r >= COOL_RATIO {
            1
        } else {
            0
        }
    }
}

/// One company group of the snapshot.
pub struct Company {
    pub key: String,
    /// Index (into `Snapshot::hot`) of its first job, whose company is the label.
    pub first: usize,
    pub size: Size,
    pub load: f64,
    pub members: Vec<usize>,
    /// How many members are in each department and role family.
    depts: [u32; 7],
    families: [u32; 7],
}

/// The hot jobs in id order, grouped by company and vendor, with the ATS
/// loads summed for today: what the server's governor reads per verdict.
pub struct Snapshot {
    /// Indexes of the hot jobs (into the caller's job list), by id.
    pub hot: Vec<usize>,
    /// Per job (caller's index): is it hot.
    pub is_hot: Vec<bool>,
    /// Company key → index into `companies`.
    by_key: BTreeMap<String, usize>,
    pub companies: Vec<Company>,
    /// Per vendor: load (vendor half-life), n, members (indexes into hot).
    pub vendors: Vec<(u8, f64, Vec<usize>)>,
    /// ATS loads: vendor → sum, (vendor, tenant) → sum.
    pub vendor_sums: [f64; 15],
    pub tenant_sums: BTreeMap<(u8, String), f64>,
}

fn sum_decay(members: impl Iterator<Item = i64>, half_life: f64) -> f64 {
    // `Enum.reduce(jobs, 0, &(&2 + decay(...)))`, then round4.
    let mut s = 0.0;
    for age in members {
        s += decay(age, half_life);
    }
    round4(s)
}

impl Snapshot {
    #[inline(never)]
    pub fn build(jobs: &[Job], tr: &[&Traits], today: u32) -> Snapshot {
        let mut hot: Vec<usize> = (0..jobs.len())
            .filter(|&i| hot_stage(jobs[i].stage))
            .collect();
        sort_usize(&mut hot, &|a, b| jobs[a].id.cmp(&jobs[b].id));
        let mut is_hot = vec![false; jobs.len()];
        let mut companies: Vec<Company> = Vec::new();
        let mut by_key: BTreeMap<String, usize> = BTreeMap::new();
        for (h, &i) in hot.iter().enumerate() {
            is_hot[i] = true;
            let c = match by_key.get(tr[i].key.as_str()) {
                Some(&c) => c,
                None => {
                    by_key.insert(tr[i].key.clone(), companies.len());
                    companies.push(Company {
                        key: tr[i].key.clone(),
                        first: h,
                        size: tr[i].size,
                        load: 0.0,
                        members: Vec::new(),
                        depts: [0; 7],
                        families: [0; 7],
                    });
                    companies.len() - 1
                }
            };
            let c = &mut companies[c];
            c.members.push(h);
            c.depts[tr[i].dept as usize] += 1;
            c.families[tr[i].family as usize] += 1;
        }
        for c in &mut companies {
            c.load = sum_decay(
                c.members.iter().map(|&h| jobs[hot[h]].age(today)),
                COMPANY_HALF_LIFE,
            );
        }
        let mut vendors: Vec<(u8, f64, Vec<usize>)> = Vec::new();
        let mut vendor_sums = [0.0; 15];
        let mut vendor_seen = [false; 15];
        let mut tenant_sums: BTreeMap<(u8, String), f64> = BTreeMap::new();
        for (h, &i) in hot.iter().enumerate() {
            let a = &tr[i].ats;
            if a.vendor == UNKNOWN {
                continue;
            }
            match vendors.iter_mut().find(|v| v.0 == a.vendor) {
                Some(v) => v.2.push(h),
                None => vendors.push((a.vendor, 0.0, vec![h])),
            }
            let age = jobs[i].age(today);
            let v = decay(age, ATS_VENDOR_HALF_LIFE);
            let slot = a.vendor as usize;
            vendor_sums[slot] = if vendor_seen[slot] {
                vendor_sums[slot] + v
            } else {
                v
            };
            vendor_seen[slot] = true;
            if let Some(t) = &a.tenant {
                let l = decay(age, ATS_TENANT_HALF_LIFE);
                match tenant_sums.get_mut(&(a.vendor, t.clone())) {
                    Some(x) => *x += l,
                    None => drop(tenant_sums.insert((a.vendor, t.clone()), l)),
                }
            }
        }
        for v in &mut vendors {
            v.1 = sum_decay(
                v.2.iter().map(|&h| jobs[hot[h]].age(today)),
                ATS_VENDOR_HALF_LIFE,
            );
        }
        Snapshot {
            hot,
            is_hot,
            by_key,
            companies,
            vendors,
            vendor_sums,
            tenant_sums,
        }
    }

    fn company(&self, key: &str) -> Option<&Company> {
        self.by_key.get(key).map(|&c| &self.companies[c])
    }

    /// Heat.verdict/4 (what can_apply answers), for job `i` of `jobs`.
    #[inline(never)]
    pub fn verdict(&self, jobs: &[Job], tr: &[&Traits], i: usize, today: u32) -> Verdict {
        let job = &jobs[i];
        let t = &tr[i];
        let own_hot = self.is_hot[i];
        let (company_load, increment) = match self.company(&t.key) {
            None => (0.0, round4(APPLICATION_LOAD)),
            Some(c) => {
                // A job that is not hot is not among the members, so its
                // peers are all of them: the group's own (same-order) sum.
                let load = if own_hot {
                    let ages = c
                        .members
                        .iter()
                        .map(|&h| self.hot[h])
                        .filter(|&p| p != i)
                        .map(|p| jobs[p].age(today));
                    sum_decay(ages, COMPANY_HALF_LIFE)
                } else {
                    c.load
                };
                let n = c.members.len() - own_hot as usize;
                let inc = if n == 0 {
                    round4(APPLICATION_LOAD)
                } else {
                    let same_dept = c.depts[t.dept as usize] > own_hot as u32;
                    let same_fam = c.families[t.family as usize] > own_hot as u32;
                    let extra = (if same_dept {
                        SAME_DEPARTMENT_PENALTY
                    } else {
                        0.0
                    }) + (if same_fam { CLONE_PENALTY } else { 0.0 });
                    round4(APPLICATION_LOAD + extra)
                };
                (load, inc)
            }
        };
        // ATS loads: the day's sums, less the job's own share when it is hot.
        let (vendor_load, tenant_load) = if t.ats.vendor == UNKNOWN {
            (0.0, 0.0)
        } else {
            let own = if own_hot { Some(i) } else { None };
            let (own_v, own_t) = match own {
                Some(p) => {
                    let prev = &tr[p].ats;
                    let same_vendor = prev.vendor == t.ats.vendor;
                    let age = jobs[p].age(today);
                    let v = if same_vendor {
                        decay(age, ATS_VENDOR_HALF_LIFE)
                    } else {
                        0.0
                    };
                    let tt = if same_vendor && t.ats.tenant.is_some() && prev.tenant == t.ats.tenant
                    {
                        decay(age, ATS_TENANT_HALF_LIFE)
                    } else {
                        0.0
                    };
                    (v, tt)
                }
                None => (0.0, 0.0),
            };
            let vs = self.vendor_sums[t.ats.vendor as usize];
            let ts = match &t.ats.tenant {
                Some(name) => self
                    .tenant_sums
                    .get(&(t.ats.vendor, name.clone()))
                    .copied()
                    .unwrap_or(0.0),
                None => 0.0,
            };
            (round4(vs - own_v), round4(ts - own_t))
        };
        finish(job, t, company_load, increment, vendor_load, tenant_load, 0)
    }

    /// Heat.chart/2: company rows then vendor rows, each by ratio
    /// descending, then label.
    #[inline(never)]
    pub fn chart(&self, jobs: &[Job]) -> (Vec<ChartRow>, Vec<ChartRow>) {
        let mut companies: Vec<ChartRow> = self
            .companies
            .iter()
            .map(|c| {
                let cap = c.size.cap();
                ChartRow {
                    key: c.key.clone(),
                    label: String::from(jobs[self.hot[c.first]].company),
                    load: c.load,
                    cap,
                    size: Some(c.size),
                    n: c.members.len() as u32,
                    ratio: ratio(c.load, cap),
                    cooldown: cooldown(c.load, APPLICATION_LOAD, cap, COMPANY_HALF_LIFE),
                }
            })
            .collect();
        let mut vendors: Vec<ChartRow> = self
            .vendors
            .iter()
            .map(|(v, load, members)| ChartRow {
                key: String::from(VENDORS[*v as usize]),
                label: String::from(VENDORS[*v as usize]),
                load: *load,
                cap: ATS_VENDOR_CAP,
                size: None,
                n: members.len() as u32,
                ratio: ratio(*load, ATS_VENDOR_CAP),
                cooldown: cooldown(
                    *load,
                    APPLICATION_LOAD,
                    ATS_VENDOR_CAP,
                    ATS_VENDOR_HALF_LIFE,
                ),
            })
            .collect();
        let by = |a: &ChartRow, b: &ChartRow| {
            b.ratio
                .partial_cmp(&a.ratio)
                .unwrap_or(core::cmp::Ordering::Equal)
                .then_with(|| a.label.as_bytes().cmp(b.label.as_bytes()))
        };
        // Labels are distinct (one per company key, one per vendor), so the
        // order is total and an unstable sort gives Elixir's.
        companies.sort_unstable_by(by);
        vendors.sort_unstable_by(by);
        (companies, vendors)
    }
}

pub struct ChartRow {
    pub key: String,
    pub label: String,
    pub load: f64,
    pub cap: f64,
    pub size: Option<Size>,
    pub n: u32,
    pub ratio: f64,
    pub cooldown: u32,
}

/// Heat's private increment/4.
fn increment<'t>(job: &Traits, mut peers: impl Iterator<Item = &'t Traits> + Clone) -> f64 {
    if peers.clone().next().is_none() {
        return round4(APPLICATION_LOAD);
    }
    let same_dept = peers.clone().any(|p| p.dept == job.dept);
    let same_fam = peers.any(|p| p.family == job.family);
    let extra = (if same_dept {
        SAME_DEPARTMENT_PENALTY
    } else {
        0.0
    }) + (if same_fam { CLONE_PENALTY } else { 0.0 });
    round4(APPLICATION_LOAD + extra)
}

/// The decision, note and cooldown of verdict_math/7, then the override.
fn finish(
    job: &Job,
    t: &Traits,
    company_load: f64,
    increment: f64,
    vendor_load: f64,
    tenant_load: f64,
    batch_vendor_n: u32,
) -> Verdict {
    let company_cap = t.size.cap();
    let projected = round4(company_load + increment);
    let known = t.ats.vendor != UNKNOWN;
    let vname = VENDORS[t.ats.vendor as usize];
    let mut note = String::new();
    let reason = if known && batch_vendor_n >= ATS_BATCH_CAP {
        note.push_str("ATS ");
        note.push_str(vname);
        note.push_str(" already ");
        push_u64(&mut note, batch_vendor_n as u64);
        note.push_str(" in this mix (cap ");
        push_u64(&mut note, ATS_BATCH_CAP as u64);
        note.push(')');
        Reason::AtsBatchCap
    } else if known && vendor_load + APPLICATION_LOAD > ATS_VENDOR_CAP {
        note.push_str("ATS vendor ");
        note.push_str(vname);
        note.push(' ');
        fmt1(vendor_load, &mut note);
        note.push('/');
        fmt1(ATS_VENDOR_CAP, &mut note);
        Reason::AtsVendorCap
    } else if t.ats.tenant.is_some() && tenant_load + APPLICATION_LOAD > ATS_TENANT_CAP {
        note.push_str("ATS tenant ");
        note.push_str(t.ats.tenant.as_deref().unwrap_or(""));
        note.push(' ');
        fmt1(tenant_load, &mut note);
        note.push('/');
        fmt1(ATS_TENANT_CAP, &mut note);
        Reason::AtsTenantCap
    } else if projected > company_cap {
        note.push_str(job.company);
        note.push(' ');
        fmt1(projected, &mut note);
        note.push('/');
        fmt1(company_cap, &mut note);
        note.push_str(" (");
        note.push_str(t.size.name());
        note.push_str(", +");
        fmt1(increment, &mut note);
        note.push(')');
        Reason::CompanyCap
    } else {
        note.push_str("ok");
        Reason::Ok
    };
    let cooldown_days = match reason {
        Reason::CompanyCap => cooldown(company_load, increment, company_cap, COMPANY_HALF_LIFE),
        Reason::AtsVendorCap => cooldown(
            vendor_load,
            APPLICATION_LOAD,
            ATS_VENDOR_CAP,
            ATS_VENDOR_HALF_LIFE,
        ),
        Reason::AtsTenantCap => cooldown(
            tenant_load,
            APPLICATION_LOAD,
            ATS_TENANT_CAP,
            ATS_TENANT_HALF_LIFE,
        ),
        _ => NONE,
    };
    let mut v = Verdict {
        allow: reason == Reason::Ok,
        reason,
        company_load,
        company_cap,
        company_increment: increment,
        size: t.size,
        vendor: t.ats.vendor,
        tenant: t.ats.tenant.clone(),
        vendor_load,
        tenant_load,
        cooldown: cooldown_days,
        note,
    };
    if job.overridden() {
        v.allow = true;
        v.reason = Reason::Override;
        v.note = String::from("override · ");
        v.note.push_str(job.heat_override_reason);
    }
    v
}


/// Heat.can_apply/2: job `i` against every hot job, read afresh (no
/// prepared snapshot), as `Desk`'s stage write asks it.
pub fn can_apply(jobs: &[Job], tr: &[&Traits], i: usize, today: u32) -> Verdict {
    let mut existing: Vec<usize> = (0..jobs.len())
        .filter(|&p| hot_stage(jobs[p].stage))
        .collect();
    sort_usize(&mut existing, &|a, b| jobs[a].id.cmp(&jobs[b].id));
    evaluate(jobs, tr, &existing, &[], i, today)
}

/// Heat's private evaluate/7 without a snapshot: the peers are `existing`
/// then `kept`, less the job itself.
fn evaluate(
    jobs: &[Job],
    tr: &[&Traits],
    existing: &[usize],
    kept: &[usize],
    i: usize,
    today: u32,
) -> Verdict {
    let job = &jobs[i];
    let t = &tr[i];
    let others: Vec<usize> = existing
        .iter()
        .chain(kept.iter())
        .copied()
        .filter(|&p| jobs[p].id != job.id)
        .collect();
    let company: Vec<usize> = others
        .iter()
        .copied()
        .filter(|&p| tr[p].key == t.key)
        .collect();
    let company_load = sum_decay(
        company.iter().map(|&p| jobs[p].age(today)),
        COMPANY_HALF_LIFE,
    );
    let inc = increment(t, company.iter().map(|&p| tr[p]));
    let (vendor_load, tenant_load) = if t.ats.vendor == UNKNOWN {
        (0.0, 0.0)
    } else {
        let vp: Vec<usize> = others
            .iter()
            .copied()
            .filter(|&p| tr[p].ats.vendor == t.ats.vendor)
            .collect();
        let tp = vp
            .iter()
            .copied()
            .filter(|&p| t.ats.tenant.is_some() && tr[p].ats.tenant == t.ats.tenant);
        (
            sum_decay(vp.iter().map(|&p| jobs[p].age(today)), ATS_VENDOR_HALF_LIFE),
            sum_decay(tp.map(|p| jobs[p].age(today)), ATS_TENANT_HALF_LIFE),
        )
    };
    let batch_n = kept
        .iter()
        .filter(|&&k| t.ats.vendor != UNKNOWN && tr[k].ats.vendor == t.ats.vendor)
        .count() as u32;
    finish(job, t, company_load, inc, vendor_load, tenant_load, batch_n)
}

// ---- the rail (Hireme.Pipeline) -------------------------------------------

/// Rung states, as the pip characters D A P S B.
const PIPS: [u8; 5] = [b'D', b'A', b'P', b'S', b'B'];

/// Pipeline.decode/1, else Pipeline.initial/1 of the current stage: one
/// pip per stage, in order.
pub fn rail(pips: &str, current: Option<u8>) -> [u8; 10] {
    let b = pips.as_bytes();
    if b.len() == 10 && b.iter().all(|c| PIPS.contains(c)) {
        let mut r = [0u8; 10];
        r.copy_from_slice(b);
        return r;
    }
    let idx = current.unwrap_or(0) as usize;
    let mut r = [b'P'; 10];
    for (i, p) in r.iter_mut().enumerate() {
        *p = if i < idx {
            b'D'
        } else if i == idx {
            b'A'
        } else {
            b'P'
        };
    }
    r
}

/// Pipeline.current/1: the active rung, else the first pending, else the last.
pub fn current(rail: &[u8; 10]) -> u8 {
    rail.iter()
        .position(|&c| c == b'A')
        .or_else(|| rail.iter().position(|&c| c == b'P'))
        .unwrap_or(9) as u8
}

/// Pipeline.move_to/2.
pub fn move_to(rail: &[u8; 10], to: u8) -> [u8; 10] {
    let mut r = *rail;
    for (i, p) in r.iter_mut().enumerate() {
        *p = if i == to as usize {
            b'A'
        } else if *p == b'S' || *p == b'B' {
            *p
        } else if i < to as usize {
            b'D'
        } else {
            b'P'
        };
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn libm_values_match_erlang() {
        // :math.pow(0.5, D / 35) and :math.log2(X) as OTP 28 prints them.
        let pows = [
            (1.0, 0.9803906099397734),
            (7.0, 0.8705505632961241),
            (13.0, 0.7730166686334901),
            (100.0, 0.13801118920922653),
            (399.0, 3.700479898707026e-4),
        ];
        for (d, want) in pows {
            assert_eq!(half_pow(d / 35.0), want, "pow(0.5, {d}/35)");
        }
        let logs = [
            (1.5, 0.5849625007211562),
            (3.0, 1.584962500721156),
            (2.2, 1.1375035237499351),
            (0.7, -0.5145731728297583),
        ];
        for (x, want) in logs {
            assert_eq!(log2(x), want, "log2({x})");
        }
    }

    #[test]
    fn float_round_and_format_match_elixir() {
        // Float.round/2 as Elixir 1.18 answers it.
        let r4 = [
            (0.12345, 0.1235),
            (1.00015, 1.0002),
            (0.30005, 0.3),
            (5.55555, 5.5556),
            (0.000049999, 0.0),
            (123.45675, 123.4567),
        ];
        for (x, want) in r4 {
            assert_eq!(round_to(x, 4), want, "round({x}, 4)");
        }
        assert_eq!(
            (round_to(0.15, 1), round_to(0.25, 1), round_to(0.35, 1)),
            (0.1, 0.3, 0.3)
        );
        assert_eq!((round_to(0.1235, 3), round_to(0.0005, 3)), (0.123, 0.001));
        assert_eq!(round_to(2.2000000000000002, 4), 2.2);
        assert_eq!(round_to(1.00005, 4), 1.0001);
        let cases = [
            (0.25, "0.3"),
            (0.35, "0.4"),
            (0.05, "0.1"),
            (2.45, "2.5"),
            (1.25, "1.3"),
            (0.15, "0.2"),
            (39.95, "40.0"),
            (2.0, "2.0"),
            (0.0, "0.0"),
            (1.4499999999999999, "1.5"),
            (0.9500000000000001, "1.0"),
            (2.05, "2.0"),
            (3.05, "3.0"),
            (1.15, "1.1"),
            (1.65, "1.6"),
            (1.95, "2.0"),
            (4.35, "4.3"),
            (8.15, "8.2"),
        ];
        for (x, want) in cases {
            let mut s = String::new();
            fmt1(x, &mut s);
            assert_eq!(s, want, "fmt1({x})");
        }
    }

    #[test]
    fn ats_reads_hosts_and_tenants() {
        let t = |u: &str| {
            let a = ats(u);
            (VENDORS[a.vendor as usize], a.tenant)
        };
        assert_eq!(
            t("https://boards.greenhouse.io/acme/jobs/1"),
            ("greenhouse", Some("acme".into()))
        );
        assert_eq!(
            t("https://acme.wd5.myworkdayjobs.com/en/x"),
            ("workday", Some("acme".into()))
        );
        assert_eq!(
            t("https://careers-acme.icims.com/jobs/1"),
            ("icims", Some("acme".into()))
        );
        assert_eq!(
            t("https://acme.successfactors.eu/x"),
            ("successfactors", Some("acme".into()))
        );
        assert_eq!(t("greenhouse.io/acme"), ("unknown", None));
        assert_eq!(
            t("https://jobs.lever.co/acme"),
            ("lever", Some("acme".into()))
        );
    }

    #[test]
    fn org_traits() {
        assert_eq!(size("Google DeepMind"), Size::Mega);
        assert_eq!(size("Open AI"), Size::Large);
        assert_eq!(size("Acme Labs"), Size::Mid);
        assert_eq!(
            family("Senior Staff Software Engineer, II"),
            Family::SoftwareEngineer
        );
        assert_eq!(family("Applied Scientist"), Family::ResearchScientist);
        assert_eq!(department("", "SRE", "", ""), Dept::Infra);
        assert_eq!(department("Platform", "", "", ""), Dept::Infra);
    }
}
