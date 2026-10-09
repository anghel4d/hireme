//! The documents a reader opens, composed from the pending view of the raw
//! rows: a job's focus (its CV through the lineage's overlays, the rail,
//! the events, keyword coverage and heat) and the lanes (gym, net, the heat
//! chart), as JSON. The browser (through wasm) and hireme-mcp (natively)
//! both read them: this is the one client implementation. Plain columns
//! are written by the schema's own names and kinds; only what is composed
//! is written by hand.

use alloc::string::String;
use alloc::vec::Vec;

use wire::NONE;
use wire::schema::{self, col, table};

use crate::desk::Desk;
use crate::store::{sort_u32, sort_usize};
use crate::{heat, keywords, predict};

// ---- JSON out ----------------------------------------------------------

struct Json(Vec<u8>);

impl Json {
    fn raw(&mut self, s: &str) {
        self.0.extend_from_slice(s.as_bytes());
    }

    /// `"key":`, after a comma unless it opens the object.
    fn key(&mut self, k: &str) {
        self.item();
        self.0.push(b'"');
        self.raw(k);
        self.raw("\":");
    }

    /// A comma unless this opens an object or array, or follows a key.
    fn item(&mut self) {
        if !matches!(self.0.last(), Some(b'{') | Some(b'[') | Some(b':') | None) {
            self.0.push(b',');
        }
    }

    fn str(&mut self, s: &[u8]) {
        self.0.push(b'"');
        for &c in s {
            match c {
                b'"' => self.raw("\\\""),
                b'\\' => self.raw("\\\\"),
                b'\n' => self.raw("\\n"),
                b'\r' => self.raw("\\r"),
                b'\t' => self.raw("\\t"),
                c if c < 0x20 => {
                    self.raw("\\u00");
                    self.0.extend_from_slice(&[b"0123456789abcdef"[(c >> 4) as usize], b"0123456789abcdef"[(c & 15) as usize]]);
                }
                c => self.0.push(c),
            }
        }
        self.0.push(b'"');
    }

    /// A string, or null when it is empty (the wire's none for a string).
    fn opt(&mut self, s: &[u8]) {
        if s.is_empty() { self.raw("null") } else { self.str(s) }
    }

    fn u(&mut self, n: u64) {
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
        self.0.extend_from_slice(&buf[i..]);
    }

    /// A u32 column value, or null for the wire's none.
    fn optu(&mut self, n: u32) {
        if n == NONE { self.raw("null") } else { self.u(n as u64) }
    }

    fn bool(&mut self, b: bool) {
        self.raw(if b { "true" } else { "false" });
    }

    /// To six decimals: these are loads and caps a reader sees, not values it computes with.
    fn f64(&mut self, x: f64) {
        if !(x.abs() < 1e12) {
            return self.raw("null");
        }
        let m = (if x < 0.0 { -x } else { x } * 1e6 + 0.5) as u64;
        if x < 0.0 && m > 0 {
            self.raw("-");
        }
        self.u(m / 1_000_000);
        let (mut f, mut d) = (m % 1_000_000, [b'0'; 7]);
        d[0] = b'.';
        for i in (1..7).rev() {
            d[i] = b'0' + (f % 10) as u8;
            f /= 10;
        }
        let n = 7 - d.iter().rev().take_while(|&&c| c == b'0').count();
        if n > 1 {
            self.0.extend_from_slice(&d[..n]);
        }
    }

    /// Days since the epoch as 2026-10-09 (Howard Hinnant's civil_from_days), or null.
    fn day(&mut self, days: u32) {
        if days == NONE {
            return self.raw("null");
        }
        self.0.push(b'"');
        self.ymd(days);
        self.0.push(b'"');
    }

    /// Unix seconds as Jason writes a UTC DateTime, 2026-10-09T13:25:45Z, or null.
    fn time(&mut self, secs: u32) {
        if secs == NONE {
            return self.raw("null");
        }
        self.0.push(b'"');
        self.ymd(secs / 86_400);
        let s = secs % 86_400;
        for (sep, n) in [(b'T', s / 3600), (b':', s / 60 % 60), (b':', s % 60)] {
            self.0.extend_from_slice(&[sep, b'0' + (n / 10) as u8, b'0' + (n % 10) as u8]);
        }
        self.raw("Z\"");
    }

    fn ymd(&mut self, days: u32) {
        let z = days as i64 + 719_468;
        let (era, doe) = (z.div_euclid(146_097), z.rem_euclid(146_097));
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let (d, m) = ((doy - (153 * mp + 2) / 5 + 1) as u32, if mp < 10 { mp + 3 } else { mp - 9 } as u32);
        let y = (yoe + era * 400 + i64::from(m <= 2)) as u32;
        for (i, n) in [y / 100, y % 100, m, d].into_iter().enumerate() {
            if i > 1 {
                self.0.push(b'-');
            }
            self.0.extend_from_slice(&[b'0' + (n / 10) as u8, b'0' + (n % 10) as u8]);
        }
    }
}

/// The string member `key` of a JSON object's text. A quote inside a string
/// is escaped, so `"key"` followed by a colon is only ever that member.
fn field(json: &[u8], key: &str) -> Option<String> {
    let s = core::str::from_utf8(json).ok()?;
    let mut pat = String::from("\"");
    pat.push_str(key);
    pat.push('"');
    s.match_indices(pat.as_str()).find_map(|(at, _)| {
        let rest = s[at + pat.len()..].trim_start().strip_prefix(':')?.trim_start();
        let mut i = s.len() - rest.len();
        predict::string(s, &mut i)
    })
}

/// Hireme.Theme.parse/1 over the stored JSON and its U+001F-joined targets.
struct Theme {
    lead: Option<String>,
    lead_reason: Option<String>,
    accent: &'static str,
    density: &'static str,
    targets: Vec<String>,
}

fn theme(json: &[u8], targets: &[u8]) -> Theme {
    let text = |k| field(json, k).map(|v| String::from(heat::trim(&v))).filter(|v| !v.is_empty());
    let choice = |k, allowed: &[&'static str]| field(json, k).and_then(|v| allowed.iter().find(|a| **a == v).copied());
    Theme {
        lead: text("lead"),
        lead_reason: text("lead_reason"),
        accent: choice("accent", &["ink", "signal", "paper"]).unwrap_or("ink"),
        density: choice("density", &["cv", "tight", "narrative"]).unwrap_or("cv"),
        targets: keywords::theme_targets(core::str::from_utf8(targets).unwrap_or("")),
    }
}

/// One canonical item after its overlay: Hireme.Mask.Line.
struct Line<'a> {
    id: u32,
    position: u32,
    kind: &'a [u8],
    title: &'a [u8],
    body: &'a [u8],
    org: &'a [u8],
    span: &'a [u8],
    mode: &'static str,
    reason: &'a [u8],
    canonical_body: &'a [u8],
}

impl Line<'_> {
    fn shown(&self) -> bool {
        self.mode != "hidden"
    }

    fn write(&self, j: &mut Json) {
        j.item();
        j.raw("{\"id\":");
        j.u(self.id as u64);
        for (k, v) in [("kind", self.kind), ("title", self.title), ("body", self.body), ("org", self.org), ("span", self.span), ("mode", self.mode.as_bytes()), ("canonical_body", self.canonical_body)] {
            j.key(k);
            j.str(v);
        }
        j.key("shown");
        j.bool(self.shown());
        j.key("reason");
        j.opt(self.reason);
        j.raw("}");
    }
}

const SECTIONS: &[(&str, &str)] = &[("experience", "Experience"), ("project", "Projects"), ("education", "Education"), ("skill", "Skills"), ("timeline", "Timeline")];

impl Desk {
    /// `{name: value, ...}` for each of `rows`, by the schema's names and
    /// kinds: a day or time as ISO text, the wire's none as null.
    fn rows_json(&self, j: &mut Json, t: u16, rows: impl Iterator<Item = usize>, names: &[&str]) {
        let cols: Vec<(&str, u16, &str)> = names
            .iter()
            .filter_map(|&n| schema::col_id(t, n).and_then(|c| schema::col_def(t, c)).map(|d| (n, d.col, d.kind)))
            .collect();
        for r in rows {
            j.item();
            j.raw("{");
            for &(name, c, kind) in &cols {
                j.key(name);
                match kind {
                    "str" => j.str(self.vstr(t, c, r)),
                    "day" => j.day(self.vu32(t, c, r)),
                    "time" => j.time(self.vu32(t, c, r)),
                    "f64" => j.f64(self.f64_at(t, c, r)),
                    _ => j.optu(self.vu32(t, c, r)),
                }
            }
            j.raw("}");
        }
    }

    /// One row as an object, or null.
    fn row_json(&self, j: &mut Json, t: u16, row: Option<usize>, names: &[&str]) {
        match row {
            None => j.raw("null"),
            Some(r) => self.rows_json(j, t, core::iter::once(r), names),
        }
    }

    /// A profile's items through a lineage's overlays (none: the root CV),
    /// in (position, id) order: Mask.apply/2.
    fn resolve(&self, profile: u32, lineage: u32) -> Vec<Line<'_>> {
        let (it, ot) = (table::ITEMS, table::OVERLAYS);
        use col::items as i;
        use col::overlays as o;
        let mut lines: Vec<Line<'_>> = (0..self.rows(it))
            .filter(|&r| matches!(self.vu32(it, i::PROFILE_ID, r), p if p == NONE || p == 0 || p == profile))
            .map(|r| {
                let (id, title, body) = (self.vu32(it, i::ID, r), self.vstr(it, i::TITLE, r), self.vstr(it, i::BODY, r));
                let ov = (lineage != NONE && lineage != 0)
                    .then(|| (0..self.rows(ot)).find(|&x| self.vu32(ot, o::LINEAGE_ID, x) == lineage && self.vu32(ot, o::ITEM_ID, x) == id))
                    .flatten();
                let (mode, t, b, reason) = match ov.map(|x| (self.vstr(ot, o::MODE, x), x)) {
                    Some((b"hidden", x)) => ("hidden", title, body, self.vstr(ot, o::REASON, x)),
                    Some((b"emphasized", x)) => ("emphasized", title, body, self.vstr(ot, o::REASON, x)),
                    Some((b"altered", x)) => {
                        let (ot_, ob) = (self.vstr(ot, o::TITLE, x), self.vstr(ot, o::BODY, x));
                        ("altered", if ot_.is_empty() { title } else { ot_ }, if ob.is_empty() { body } else { ob }, self.vstr(ot, o::REASON, x))
                    }
                    _ => ("canonical", title, body, &b""[..]),
                };
                let s = |c| self.vstr(it, c, r);
                Line { id, position: self.vu32(it, i::POSITION, r), kind: s(i::KIND), title: t, body: b, org: s(i::ORG), span: s(i::SPAN), mode, reason, canonical_body: body }
            })
            .collect();
        let mut order: Vec<usize> = (0..lines.len()).collect();
        sort_usize(&mut order, &|a, b| (lines[a].position as i32).cmp(&(lines[b].position as i32)).then(lines[a].id.cmp(&lines[b].id)));
        let mut slots: Vec<Option<Line<'_>>> = lines.drain(..).map(Some).collect();
        order.into_iter().filter_map(|i| slots[i].take()).collect()
    }

    fn kv_get(&self, namespace: &[u8], key: &[u8]) -> &[u8] {
        let t = table::KV_PAIRS;
        use col::kv_pairs as k;
        (0..self.rows(t))
            .find(|&r| self.vstr(t, k::NAMESPACE, r) == namespace && self.vstr(t, k::KEY, r) == key)
            .map_or(b"", |r| self.vstr(t, k::VALUE, r))
    }

    /// Rows of `t` whose u32 column `c` is `v`, in `key` order (descending when `desc`).
    fn rows_where(&self, t: u16, c: u16, v: u32, key: u16, desc: bool) -> Vec<usize> {
        let mut rows: Vec<usize> = (0..self.rows(t)).filter(|&r| c == u16::MAX || self.vu32(t, c, r) == v).collect();
        sort_usize(&mut rows, &|a, b| {
            let o = self.vu32(t, key, a).cmp(&self.vu32(t, key, b));
            if desc { o.reverse() } else { o }
        });
        rows
    }

    /// HiremeWeb.JSON.focus/1 for one application, or "null" when it is unknown.
    pub fn focus_json(&mut self, job: u32) -> String {
        self.derive();
        let mut j = Json(Vec::new());
        let Some((profile, lineage, targets)) = self.focus(&mut j, job) else { return String::from("null") };
        // Coverage of the CV and of the root CV, over the kernel's memoized texts.
        for (name, l) in [("coverage", lineage), ("root_coverage", 0)] {
            let text = self.cv_text(profile, l);
            j.key(name);
            for (k, hit) in [("{\"hits\":[", true), ("],\"misses\":[", false)] {
                j.raw(k);
                for t in targets.iter().filter(|t| text.hit(t) == hit) {
                    j.item();
                    j.str(t.as_bytes());
                }
            }
            j.raw("]}");
        }
        j.raw("}");
        String::from_utf8(j.0).unwrap_or_default()
    }

    /// The focus up to its coverage: (profile, lineage, keyword targets).
    fn focus(&self, j: &mut Json, job: u32) -> Option<(u32, u32, Vec<String>)> {
        let (jt, vt, pt) = (table::JOB_APPS, table::CV_VARIANTS, table::PROFILES);
        use col::cv_variants as v;
        use col::job_apps as a;
        let jr = self.row_of(jt, job)?;
        let vr = (0..self.rows(vt)).find(|&r| self.vu32(vt, v::JOB_APP_ID, r) == job)?;
        let pr = self.row_of(pt, self.vu32(jt, a::PROFILE_ID, jr))?;
        let profile = self.vu32(pt, col::profiles::ID, pr);
        let lineage = self.vu32(vt, v::LINEAGE_ID, vr);
        let lt = table::CV_LINEAGES;
        let own = self.row_of(lt, lineage).filter(|&r| !matches!(heat::trim(core::str::from_utf8(self.vstr(lt, col::cv_lineages::THEME, r)).unwrap_or("")), "" | "{}" | "null"));
        let theme = match own {
            Some(r) => theme(self.vstr(lt, col::cv_lineages::THEME, r), self.vstr(lt, col::cv_lineages::THEME_TARGETS, r)),
            None => theme(self.vstr(vt, v::THEME, vr), self.vstr(vt, v::THEME_TARGETS, vr)),
        };
        let lines = self.resolve(profile, lineage);
        let s = |c| self.vstr(jt, c, jr);
        let (stage, pips, score) = (s(a::CURRENT_STAGE), s(a::PIPS), self.vu32(jt, a::SCORE_100, jr));
        let st = table::STAGES;
        let stages = self.rows_where(st, u16::MAX, 0, col::stages::IX, false);
        let srow = stages.iter().copied().find(|&r| self.vstr(st, col::stages::KEY, r) == stage);

        // The job as the row holds it, and its glance as the cards count it.
        j.raw("{\"job\":");
        self.row_json(j, jt, Some(jr), &["id", "company", "role", "location", "listing", "heat", "status", "pips", "score_100", "next_action", "next_due", "stage_on", "freshness", "gate", "fit"]);
        j.0.pop();
        j.key("code");
        j.raw("\"JobApp");
        j.u(job as u64);
        j.raw("\"");
        j.key("stage");
        j.str(stage);
        for (k, c) in [("stage_label", col::stages::LABEL), ("stage_hint", col::stages::HINT)] {
            j.key(k);
            j.str(srow.map_or(b"", |r| self.vstr(st, c, r)));
        }
        j.key("band");
        let bt = table::BANDS;
        let band = (0..self.rows(bt)).find(|&r| (self.vu32(bt, col::bands::MIN, r)..=self.vu32(bt, col::bands::MAX, r)).contains(&score));
        j.str(band.map_or(b"", |r| self.vstr(bt, col::bands::KEY, r)));
        let ct = table::CARDS;
        use col::cards as cd;
        let cr = self.row_of(ct, job);
        for (k, c) in [("keyword_hits", cd::HITS), ("keyword_total", cd::TOTAL), ("mask_hidden", cd::HIDDEN), ("mask_altered", cd::ALTERED), ("mask_emphasized", cd::EMPHASIZED)] {
            j.key(k);
            j.u(cr.map_or(0, |r| self.vu32(ct, c, r)) as u64);
        }
        j.key("batch");
        let bt = table::BATCHES;
        match self.row_of(bt, self.vu32(jt, a::BATCH_ID, jr)) {
            None => j.raw("null"),
            Some(r) => {
                j.raw("{\"code\":");
                j.str(self.vstr(bt, col::batches::CODE, r));
                j.raw(if self.vu32(bt, col::batches::FIRE, r) == 1 { ",\"fire\":\"open_fire\"}" } else { ",\"fire\":\"hold\"}" });
            }
        }
        j.raw("}");
        j.key("profile");
        self.row_json(j, pt, Some(pr), &["id", "slug", "name", "headline", "summary"]);
        j.key("variant");
        self.row_json(j, vt, Some(vr), &["id", "label", "lineage_id"]);

        // The rail: the pips decoded, else the stage's place; each rung's note.
        j.key("rail");
        j.raw("[");
        let decoded = pips.len() == stages.len() && pips.iter().all(|c| b"DAPSB".contains(c));
        let at = srow.and_then(|sr| stages.iter().position(|&r| r == sr));
        for (i, &r) in stages.iter().enumerate() {
            let state: &[u8] = match (decoded, pips.get(i), at) {
                (true, Some(b'D'), _) => b"done",
                (true, Some(b'A'), _) => b"active",
                (true, Some(b'S'), _) => b"skipped",
                (true, Some(b'B'), _) => b"blocked",
                (true, _, _) => b"pending",
                (false, _, Some(a)) if i < a => b"done",
                (false, _, Some(a)) if i == a => b"active",
                _ => b"pending",
            };
            let key = self.vstr(st, col::stages::KEY, r);
            j.item();
            j.raw("{");
            for (k, v) in [("key", key), ("label", self.vstr(st, col::stages::LABEL, r)), ("hint", self.vstr(st, col::stages::HINT, r)), ("state", state)] {
                j.key(k);
                j.str(v);
            }
            j.key("note");
            j.str(field(s(a::STAGE_NOTES), core::str::from_utf8(key).unwrap_or("")).unwrap_or_default().as_bytes());
            j.raw("}");
        }
        j.raw("]");

        // The twelve latest events; the time sits under "at".
        j.key("events");
        j.raw("[");
        let et = table::EVENTS;
        use col::events as e;
        for r in self.rows_where(et, e::JOB_APP_ID, job, e::ID, true).into_iter().take(12) {
            j.item();
            j.raw("{\"id\":");
            j.u(self.vu32(et, e::ID, r) as u64);
            for (k, c) in [("kind", e::KIND), ("body", e::BODY)] {
                j.key(k);
                j.str(self.vstr(et, c, r));
            }
            j.key("at");
            j.time(self.vu32(et, e::INSERTED_AT, r));
            j.raw("}");
        }
        j.raw("]");

        let mut ns = Json(Vec::from(&b"app:"[..]));
        ns.u(job as u64);
        self.cv_json(j, pr, &lines, &theme, self.vstr(vt, v::LABEL, vr), &ns.0);
        j.key("masks");
        j.raw("[");
        lines.iter().filter(|l| l.mode != "canonical").for_each(|l| l.write(j));
        j.raw("]");

        // The heat verdict the derive judged, and the job's override.
        let (ht, hr) = (table::VERDICTS, self.row_of(table::VERDICTS, job));
        use col::verdicts as h;
        let hs = |c| hr.map_or(&b""[..], |r| self.vstr(ht, c, r));
        j.key("heat");
        j.raw(if hs(h::DECISION) == b"defer" { "{\"decision\":\"defer\"" } else { "{\"decision\":\"allow\"" });
        for (k, c) in [("company_load", h::COMPANY_LOAD), ("company_cap", h::COMPANY_CAP)] {
            j.key(k);
            j.f64(hr.map_or(0.0, |r| self.f64_at(ht, c, r)));
        }
        j.key("ats_vendor");
        j.str(hs(h::ATS_VENDOR));
        j.key("size");
        j.opt(hs(h::SIZE));
        j.key("cooldown_days");
        j.optu(hr.map_or(NONE, |r| self.vu32(ht, h::COOLDOWN_DAYS, r)));
        j.key("override");
        j.bool(self.vu32(jt, a::HEAT_OVERRIDE, jr) == 1);
        j.key("override_reason");
        j.str(s(a::HEAT_OVERRIDE_REASON));
        j.raw("}");
        let targets = if theme.targets.is_empty() { keywords::extract(core::str::from_utf8(s(a::LISTING)).unwrap_or("")) } else { theme.targets };
        Some((profile, lineage, targets))
    }

    /// The CV (Cv.compose/4: masthead, sections in order, the hidden tray),
    /// the profile's narrative and a namespace's notes: what a focus and the
    /// root CV share.
    fn cv_json(&self, j: &mut Json, pr: usize, lines: &[Line<'_>], theme: &Theme, label: &[u8], ns: &[u8]) {
        let pt = table::PROFILES;
        let psummary = self.vstr(pt, col::profiles::SUMMARY, pr);
        let summary = theme.lead.as_deref().map_or(psummary, str::as_bytes);
        j.key("cv");
        j.raw("{");
        for (k, v) in [("label", label), ("headline", self.vstr(pt, col::profiles::HEADLINE, pr)), ("summary", summary), ("accent", theme.accent.as_bytes()), ("density", theme.density.as_bytes())] {
            j.key(k);
            j.str(v);
        }
        j.key("person");
        j.opt(self.kv_get(b"global", b"candidate"));
        j.key("summary_canonical");
        j.opt(if summary == psummary { b"" } else { psummary });
        j.key("summary_reason");
        j.opt(theme.lead_reason.as_deref().map_or(b"", str::as_bytes));
        j.key("facts");
        j.raw("[");
        lines.iter().filter(|l| l.shown() && l.kind == b"fact").for_each(|l| l.write(j));
        j.raw("],\"sections\":[");
        for (kind, name) in SECTIONS {
            if lines.iter().any(|l| l.shown() && l.kind == kind.as_bytes()) {
                j.item();
                j.raw("{\"kind\":");
                j.str(kind.as_bytes());
                j.key("label");
                j.str(name.as_bytes());
                j.raw(",\"lines\":[");
                lines.iter().filter(|l| l.shown() && l.kind == kind.as_bytes()).for_each(|l| l.write(j));
                j.raw("]}");
            }
        }
        j.raw("],\"hidden\":[");
        lines.iter().filter(|l| !l.shown()).for_each(|l| l.write(j));
        j.raw("]}");
        // Narrative.for_profile/1: the profile's user's narrative.
        let (nt, user) = (table::NARRATIVES, self.vu32(pt, col::profiles::USER_ID, pr));
        j.key("narrative");
        let nr = (user != NONE && user != 0).then(|| (0..self.rows(nt)).find(|&r| self.vu32(nt, col::narratives::USER_ID, r) == user)).flatten();
        self.row_json(j, nt, nr, &["id", "body", "version"]);

        // The namespace's notes (Kv.list/1), in key order.
        let kt = table::KV_PAIRS;
        use col::kv_pairs as k;
        let mut rows: Vec<usize> = (0..self.rows(kt)).filter(|&r| self.vstr(kt, k::NAMESPACE, r) == ns).collect();
        sort_usize(&mut rows, &|a, b| self.vstr(kt, k::KEY, a).cmp(self.vstr(kt, k::KEY, b)));
        j.key("kv");
        j.raw("[");
        self.rows_json(j, kt, rows.into_iter(), &["key", "value"]);
        j.raw("]");
    }

    /// HiremeWeb.JSON.root/1 for one profile, or "null" when it is unknown.
    pub fn root_json(&mut self, profile: u32) -> String {
        self.derive();
        let (pt, vt) = (table::PROFILES, table::CV_VARIANTS);
        use col::cv_variants as v;
        let Some(pr) = self.row_of(pt, profile) else { return String::from("null") };
        let vr = (0..self.rows(vt)).find(|&r| self.vu32(vt, v::PROFILE_ID, r) == profile && matches!(self.vu32(vt, v::JOB_APP_ID, r), 0 | NONE));
        let theme = vr.map_or_else(|| theme(b"", b""), |r| theme(self.vstr(vt, v::THEME, r), self.vstr(vt, v::THEME_TARGETS, r)));
        let mut j = Json(Vec::new());
        j.raw("{\"profile\":");
        self.row_json(&mut j, pt, Some(pr), &["id", "slug", "name", "headline", "summary"]);
        self.cv_json(&mut j, pr, &self.resolve(profile, 0), &theme, vr.map_or(b"Root", |r| self.vstr(vt, v::LABEL, r)), b"global");
        j.raw("}");
        String::from_utf8(j.0).unwrap_or_default()
    }

    /// HiremeWeb.JSON.lanes/0: gym and net progress for the server's day, and the heat chart.
    pub fn lanes_json(&mut self) -> String {
        self.derive();
        let today = if self.rows(table::CLOCK) > 0 { self.vu32(table::CLOCK, col::clock::TODAY, 0) } else { self.today };
        let week = today.wrapping_sub(6);
        let mut j = Json(Vec::new());

        // Gym.progress/1.
        let (rt, pt) = (table::GYM_REPS, table::GYM_PROBLEMS);
        use col::gym_problems as p;
        use col::gym_reps as r;
        let target = core::str::from_utf8(self.kv_get(b"gym", b"daily_target")).ok().and_then(|v| v.parse::<u32>().ok()).filter(|n| (1..=30).contains(n)).unwrap_or(3);
        let done = |x: usize| self.vu32(rt, r::DONE_ON, x);
        let solved: Vec<usize> = (0..self.rows(rt)).filter(|&x| self.vstr(rt, r::OUTCOME, x) == b"solved").collect();
        let solved_week = solved.iter().filter(|&&x| done(x) != NONE && done(x) >= week).count() as u32;
        let mut days: Vec<u32> = solved.iter().map(|&x| done(x)).collect();
        sort_u32(&mut days, &|a, b| a.cmp(&b));
        days.dedup();
        let mut day = if days.binary_search(&today).is_ok() { today } else { today.wrapping_sub(1) };
        let mut streak = 0;
        while days.binary_search(&day).is_ok() {
            streak += 1;
            day = day.wrapping_sub(1);
        }
        let problem = |x: usize| self.row_of(pt, self.vu32(rt, r::PROBLEM_ID, x));
        j.raw("{\"gym\":{");
        // Elixir's round/1 of solved_week / (target * 7) * 100, capped at 100.
        let score = ((solved_week * 200 + target * 7) / (target * 14)).min(100);
        let solved_today = solved.iter().filter(|&&x| done(x) == today).count() as u32;
        for (k, n) in [("target", target), ("streak", streak), ("solved_today", solved_today), ("solved_week", solved_week), ("score", score)] {
            j.key(k);
            j.u(n as u64);
        }
        j.key("topics");
        j.raw("[");
        for key in GYM_TOPICS {
            j.item();
            option(&mut j, key);
            j.0.pop();
            j.key("count");
            j.u(solved.iter().filter(|&&x| problem(x).is_some_and(|pr| self.vstr(pt, p::TOPIC, pr) == key.as_bytes())).count() as u64);
            j.raw("}");
        }
        j.raw("]");
        j.key("recent");
        j.raw("[");
        let mut reps: Vec<usize> = (0..self.rows(rt)).collect();
        // Newest first; a missing day (none) is the largest value, as nil is the largest term.
        sort_usize(&mut reps, &|x, y| done(y).cmp(&done(x)).then(self.vu32(rt, r::ID, y).cmp(&self.vu32(rt, r::ID, x))));
        for x in reps.into_iter().take(40) {
            self.rows_json(&mut j, rt, core::iter::once(x), &["id", "done_on", "outcome", "minutes", "note"]);
            j.0.pop();
            let pr = problem(x);
            for (k, c) in [("platform", p::PLATFORM), ("slug", p::SLUG), ("title", p::TITLE), ("topic", p::TOPIC), ("difficulty", p::DIFFICULTY), ("url", p::URL)] {
                j.key(k);
                j.str(pr.map_or(b"", |pr| self.vstr(pt, c, pr)));
            }
            j.raw("}");
        }
        j.raw("]");
        options(&mut j, "platforms", GYM_PLATFORMS);
        options(&mut j, "topics_all", GYM_TOPICS);
        options(&mut j, "difficulties", GYM_DIFFICULTIES);
        options(&mut j, "outcomes", GYM_OUTCOMES);

        // Net.progress/1.
        let nt = table::NET_ENTRIES;
        use col::net_entries as n;
        let kind = |x: usize| self.vstr(nt, n::KIND, x);
        let shipped = |x: usize| self.vu32(nt, n::SHIPPED_ON, x);
        j.raw("},\"net\":{\"lane\":");
        j.str(heat::trim(core::str::from_utf8(self.kv_get(b"net", b"broadside_lane")).unwrap_or("")).as_bytes());
        let count = |f: &dyn Fn(usize) -> bool| (0..self.rows(nt)).filter(|&x| f(x)).count() as u64;
        for (k, c) in [
            ("shipped_week", count(&|x| matches!(kind(x), b"artifact" | b"post") && shipped(x) != NONE && shipped(x) >= week)),
            ("drafts", count(&|x| kind(x) == b"draft")),
            ("observer_runs", count(&|x| kind(x) == b"observer")),
        ] {
            j.key(k);
            j.u(c);
        }
        j.key("recent");
        j.raw("[");
        let entries = self.rows_where(nt, u16::MAX, 0, n::ID, true);
        self.rows_json(&mut j, nt, entries.into_iter().take(40), &["id", "kind", "channel", "title", "url", "body", "shipped_on"]);
        j.raw("]");
        options(&mut j, "kinds", NET_KINDS);
        options(&mut j, "channels", NET_CHANNELS);

        // The heat chart, as the derive left it.
        let ht = table::HEAT_ROWS;
        j.raw("},\"heat\":{");
        for (name, group) in [("companies", 0), ("vendors", 1)] {
            j.key(name);
            j.raw("[");
            let rows = (0..self.rows(ht)).filter(|&x| self.vu32(ht, col::heat_rows::GROUP, x) == group);
            self.rows_json(&mut j, ht, rows, &["key", "label", "load", "cap", "ratio", "n", "cooldown_days"]);
            j.raw("]");
        }
        j.raw("}}");
        String::from_utf8(j.0).unwrap_or_default()
    }
}

const GYM_PLATFORMS: &[&str] = &["leetcode", "codeforces", "other"];
const GYM_TOPICS: &[&str] = &["arrays", "graphs", "strings", "dp", "trees", "systems", "other"];
const GYM_DIFFICULTIES: &[&str] = &["easy", "medium", "hard", "unknown"];
const GYM_OUTCOMES: &[&str] = &["solved", "attempt", "skip"];
const NET_KINDS: &[&str] = &["observer", "artifact", "post", "draft"];
const NET_CHANNELS: &[&str] = &["broadside", "x", "other"];

/// String.capitalize/1 over the closed sets' ASCII keys, with their proper names.
fn label(k: &str) -> String {
    match k {
        "dp" => String::from("DP"),
        "leetcode" => String::from("LeetCode"),
        "x" => String::from("X"),
        k => {
            let mut s = String::from(k);
            s[..1].make_ascii_uppercase();
            s
        }
    }
}

fn option(j: &mut Json, key: &str) {
    j.raw("{\"key\":");
    j.str(key.as_bytes());
    j.key("label");
    j.str(label(key).as_bytes());
    j.raw("}");
}

fn options(j: &mut Json, name: &str, keys: &[&str]) {
    j.key(name);
    j.raw("[");
    for k in keys {
        j.item();
        option(j, k);
    }
    j.raw("]");
}
