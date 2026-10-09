//! Predicting a client op on the raw rows, as `Hireme.Ops` would write it.
//!
//! An op the client sends is parsed with Ops' own rules, judged with the
//! same refusals in the same order (argument, lease, fire hold, heat,
//! missing rows, the CV lineage's cooldown and additive phase), and, when
//! accepted, written into the pending view of the raw tables: job_apps
//! (stage, pips, stage_on, next action, notes, score, heat override),
//! overlays (rows added, changed or removed), batches and narratives. The
//! derived views follow from those rows, so a prediction is exact for
//! derived fields too. Rows the server adds that carry ids it chooses
//! (events, gym reps, net entries) are left for the PATCH.

use alloc::string::String;
use alloc::vec::Vec;

use wire::schema::{col, op, refusal, table};
use wire::{NONE, Op};

use crate::desk::{Desk, Val};
use crate::heat;
use crate::keywords;

/// Refusal names the schema has no code for travel as `internal`.
const INTERNAL: u8 = refusal::INTERNAL;

/// Elixir's `Integer.parse(s)` matching `{n, ""}`.
fn integer(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let (neg, digits) = match b.first() {
        Some(b'+') => (false, &s[1..]),
        Some(b'-') => (true, &s[1..]),
        _ => (false, s),
    };
    if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let mut n: i64 = 0;
    for c in digits.bytes() {
        n = n.checked_mul(10)?.checked_add((c - b'0') as i64)?;
    }
    Some(if neg { -n } else { n })
}

/// `Date.from_iso8601/1`: "YYYY-MM-DD" or "YYYYMMDD", a real calendar day.
pub fn iso_day(s: &str) -> Option<u32> {
    let b = s.as_bytes();
    let (y, m, d) = match b.len() {
        10 if b[4] == b'-' && b[7] == b'-' => (&s[0..4], &s[5..7], &s[8..10]),
        8 => (&s[0..4], &s[4..6], &s[6..8]),
        _ => return None,
    };
    let all = |t: &str| t.bytes().all(|c| c.is_ascii_digit());
    if !(all(y) && all(m) && all(d)) {
        return None;
    }
    let (y, m, d) = (integer(y)?, integer(m)?, integer(d)?);
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let dim = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=12).contains(&m) || d < 1 || d > dim[(m - 1) as usize] {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    u32::try_from(era * 146_097 + doe - 719_468).ok()
}

impl Desk {
    /// The raw-row prediction of one op. With `check`, the refusals the
    /// server would answer, in its order; a refused op writes nothing.
    pub(crate) fn apply_raw(&mut self, o: &Op, check: bool, rec: &mut Vec<(u16, u32, u16, Val)>) -> Result<(), u8> {
        let jt = table::JOB_APPS;
        let job = o.target;
        let leased = |d: &Desk| d.row_of(table::LEASES, job).is_some();
        match o.kind {
            op::STAGE => {
                let to = heat::stage_ix(o.field(0)).ok_or(refusal::ARGUMENT)?;
                if check && leased(self) {
                    return Err(refusal::LEASED);
                }
                let row = self.row_of(jt, job);
                if check && heat::fire_locked(to) && !row.is_some_and(|r| self.job_batch_open(r)) {
                    return Err(refusal::FIRE_HOLD);
                }
                let row = row.ok_or(refusal::NOT_FOUND)?;
                let from = heat::stage_ix(core::str::from_utf8(self.vstr(jt, col::job_apps::CURRENT_STAGE, row)).unwrap_or(""));
                if check && heat::entering(from, to) && !self.can_apply(row) {
                    return Err(refusal::HEAT);
                }
                let pips = core::str::from_utf8(self.vstr(jt, col::job_apps::PIPS, row)).unwrap_or("");
                let before = heat::rail(pips, from);
                let previous = heat::current(&before);
                let moved = heat::move_to(&before, to);
                let active = heat::current(&moved);
                let changed = previous != active;
                let name = heat::STAGES[active as usize].as_bytes().to_vec();
                self.set(jt, job, col::job_apps::CURRENT_STAGE, Val::S(name), rec);
                self.set(jt, job, col::job_apps::PIPS, Val::S(moved.to_vec()), rec);
                if changed && self.today != NONE {
                    self.set(jt, job, col::job_apps::STAGE_ON, Val::U(self.today), rec);
                }
            }
            op::NEXT => {
                let action = heat::trim(o.field(0)).as_bytes().to_vec();
                let due = iso_day(o.field(1)).unwrap_or(NONE);
                self.write_job(check, job)?;
                self.set(jt, job, col::job_apps::NEXT_ACTION, Val::S(action), rec);
                self.set(jt, job, col::job_apps::NEXT_DUE, Val::U(due), rec);
            }
            op::NOTE => {
                let stage = heat::stage_ix(o.field(0)).ok_or(refusal::ARGUMENT)?;
                let row = self.write_job(check, job)?;
                let notes = core::str::from_utf8(self.vstr(jt, col::job_apps::STAGE_NOTES, row)).unwrap_or("");
                if let Some(json) = put_note(notes, heat::STAGES[stage as usize], o.field(1)) {
                    self.set(jt, job, col::job_apps::STAGE_NOTES, Val::S(json.into_bytes()), rec);
                }
            }
            op::SCORE => {
                let s = integer(o.field(0)).filter(|n| (0..=100).contains(n)).ok_or(refusal::ARGUMENT)?;
                self.write_job(check, job)?;
                self.set(jt, job, col::job_apps::SCORE_100, Val::U(s as u32), rec);
            }
            op::HEAT_OVERRIDE => {
                let reason = heat::trim(o.field(0));
                if reason.is_empty() {
                    return Err(INTERNAL); // :reason
                }
                self.row_of(jt, job).ok_or(refusal::NOT_FOUND)?;
                self.set(jt, job, col::job_apps::HEAT_OVERRIDE, Val::U(1), rec);
                self.set(jt, job, col::job_apps::HEAT_OVERRIDE_REASON, Val::S(reason.as_bytes().to_vec()), rec);
            }
            op::OPEN_FIRE => {
                let b = table::BATCHES;
                let code = o.field(0).as_bytes();
                let r = (0..self.rows(b)).find(|&r| self.vstr(b, col::batches::CODE, r) == code).ok_or(refusal::BATCH)?;
                let id = self.vu32(b, col::batches::ID, r);
                self.set(b, id, col::batches::FIRE, Val::U(1), rec);
                self.set(b, id, col::batches::STATUS, Val::S(b"open_fire".to_vec()), rec);
            }
            op::NARRATIVE => {
                let n = table::NARRATIVES;
                let r = self.row_of(n, job).ok_or(refusal::NOT_FOUND)?;
                let version = self.vu32(n, col::narratives::VERSION, r);
                self.set(n, job, col::narratives::BODY, Val::S(o.field(0).as_bytes().to_vec()), rec);
                self.set(n, job, col::narratives::VERSION, Val::U(version.wrapping_add(1)), rec);
            }
            op::OVERLAY => self.overlay_raw(o, check, rec)?,
            // Gym and net appends carry rows the server numbers; they come
            // with the PATCH. What Gym and Net refuse is refused here.
            op::GYM_TARGET => {
                integer(o.field(0)).filter(|n| (1..=30).contains(n)).ok_or(INTERNAL)?; // :target
            }
            op::GYM_LOG => {
                let f = form(o);
                closed(&f, "platform", &["leetcode", "codeforces", "other"], true)?;
                closed(&f, "topic", &["arrays", "graphs", "strings", "dp", "trees", "systems", "other"], true)?;
                closed(&f, "difficulty", &["easy", "medium", "hard", "unknown"], true)?;
                closed(&f, "outcome", &["solved", "attempt", "skip"], true)?;
                day(&f, "done_on")?;
                let title = required(&f, "title")?;
                let given = heat::trim(get(&f, "slug").unwrap_or(""));
                if given.is_empty() && slug_empty(title) {
                    return Err(refusal::ARGUMENT);
                }
            }
            op::NET_LOG => {
                let f = form(o);
                closed(&f, "kind", &["observer", "artifact", "post", "draft"], false)?;
                closed(&f, "channel", &["broadside", "x", "other"], true)?;
                required(&f, "title")?;
                day(&f, "shipped_on")?;
            }
            _ => {}
        }
        Ok(())
    }

    /// Desk's write/2 guard: the lease, then the row.
    fn write_job(&self, check: bool, job: u32) -> Result<usize, u8> {
        if check && self.row_of(table::LEASES, job).is_some() {
            return Err(refusal::LEASED);
        }
        self.row_of(table::JOB_APPS, job).ok_or(refusal::NOT_FOUND)
    }

    /// Is the job's batch named for open fire.
    fn job_batch_open(&self, row: usize) -> bool {
        let id = self.vu32(table::JOB_APPS, col::job_apps::BATCH_ID, row);
        id != 0
            && id != NONE
            && self.row_of(table::BATCHES, id).is_some_and(|r| self.vu32(table::BATCHES, col::batches::FIRE, r) == 1)
    }

    /// Desk.execute({:overlay, ...}): CvPair.bind, then tailor or drop_line.
    fn overlay_raw(&mut self, o: &Op, check: bool, rec: &mut Vec<(u16, u32, u16, Val)>) -> Result<(), u8> {
        let job = o.target;
        let item = integer(o.field(0)).filter(|n| *n > 0 && *n < u32::MAX as i64).ok_or(refusal::ARGUMENT)? as u32;
        let mode = o.field(1);
        let (mode, body, reason): (&str, Option<String>, Option<String>) = match mode {
            "inherit" => ("inherit", None, None),
            "altered" | "hidden" | "emphasized" => {
                let blank = |s: &str| {
                    let t = heat::trim(s);
                    if t.is_empty() { None } else { Some(String::from(t)) }
                };
                match mode {
                    "altered" => {
                        let body = blank(o.field(2)).ok_or(refusal::ARGUMENT)?;
                        ("altered", Some(body), blank(o.field(3)))
                    }
                    "hidden" => ("hidden", None, Some(blank(o.field(3)).unwrap_or_else(|| String::from("Hidden from this CV")))),
                    _ => ("emphasized", None, Some(blank(o.field(3)).unwrap_or_else(|| String::from("Emphasized for this CV")))),
                }
            }
            _ => return Err(refusal::ARGUMENT),
        };
        if check && self.row_of(table::LEASES, job).is_some() {
            return Err(refusal::LEASED);
        }
        // CvPair.bind: the job's variant, on a lineage of the job's employer.
        let jr = self.row_of(table::JOB_APPS, job).ok_or(INTERNAL)?;
        let employer = self.vu32(table::JOB_APPS, col::job_apps::EMPLOYER_ID, jr);
        let vt = table::CV_VARIANTS;
        let lt = table::CV_LINEAGES;
        let lineage = (0..self.rows(vt))
            .filter(|&r| self.vu32(vt, col::cv_variants::JOB_APP_ID, r) == job)
            .map(|r| self.vu32(vt, col::cv_variants::LINEAGE_ID, r))
            .find(|&l| self.row_of(lt, l).is_some_and(|lr| self.vu32(lt, col::cv_lineages::EMPLOYER_ID, lr) == employer))
            .ok_or(INTERNAL)?; // :unbound
        let lr = self.row_of(lt, lineage).ok_or(INTERNAL)?;
        if mode != "inherit" && self.row_of(table::ITEMS, item).is_none() {
            return Err(refusal::NOT_FOUND);
        }
        let opened = self.vu32(lt, col::cv_lineages::OPENED_ON, lr);
        if self.today != NONE && opened != NONE && self.today as i64 - opened as i64 >= 90 {
            return Err(refusal::COOLDOWN);
        }
        let rewrites = self.vu32(lt, col::cv_lineages::REWRITES_ALLOWED, lr) == 1;
        let ot = table::OVERLAYS;
        let existing: Vec<u32> = (0..self.rows(ot))
            .filter(|&r| {
                self.vu32(ot, col::overlays::LINEAGE_ID, r) == lineage && self.vu32(ot, col::overlays::ITEM_ID, r) == item
            })
            .map(|r| self.vu32(ot, col::overlays::ID, r))
            .collect();
        if mode == "inherit" {
            if !rewrites {
                return Err(refusal::NOT_ADDITIVE);
            }
            for id in existing {
                self.delete_row(ot, id);
            }
            self.refresh_lineage(lineage, rec);
            return Ok(());
        }
        let reason_b = reason.map(String::into_bytes).unwrap_or_default();
        match existing.first() {
            Some(_) if !rewrites => return Err(refusal::NOT_ADDITIVE),
            Some(&id) => {
                self.set(ot, id, col::overlays::MODE, Val::S(mode.as_bytes().to_vec()), rec);
                if let Some(b) = body {
                    self.set(ot, id, col::overlays::BODY, Val::S(b.into_bytes()), rec);
                }
                self.set(ot, id, col::overlays::REASON, Val::S(reason_b), rec);
            }
            None => {
                let generation = self.vu32(lt, col::cv_lineages::GENERATION, lr);
                let id = self.provisional_id();
                self.insert_row(
                    ot,
                    &[
                        (col::overlays::ID, Val::U(id)),
                        (col::overlays::JOB_APP_ID, Val::U(job)),
                        (col::overlays::ITEM_ID, Val::U(item)),
                        (col::overlays::LINEAGE_ID, Val::U(lineage)),
                        (col::overlays::MODE, Val::S(mode.as_bytes().to_vec())),
                        (col::overlays::BODY, Val::S(body.map(String::into_bytes).unwrap_or_default())),
                        (col::overlays::REASON, Val::S(reason_b)),
                        (col::overlays::GENERATION, Val::U(generation)),
                    ],
                );
            }
        }
        self.refresh_lineage(lineage, rec);
        Ok(())
    }
}

impl Desk {
    /// Desk's refresh_lineage!/1 after an overlay write: every job with a
    /// variant on the lineage gets the mask counts of the lineage's
    /// overlays and the keyword coverage of the CV its profile now shows.
    fn refresh_lineage(&mut self, lineage: u32, rec: &mut Vec<(u16, u32, u16, Val)>) {
        let ot = table::OVERLAYS;
        let it = table::ITEMS;
        let vt = table::CV_VARIANTS;
        let lt = table::CV_LINEAGES;
        let jt = table::JOB_APPS;
        // The lineage's overlays by item: mode, title, body.
        let mut counts = [0u32; 3];
        let mut by_item: Vec<(u32, u8, String, String)> = Vec::new();
        for r in 0..self.rows(ot) {
            if self.vu32(ot, col::overlays::LINEAGE_ID, r) != lineage {
                continue;
            }
            let m = match self.vstr(ot, col::overlays::MODE, r) {
                b"hidden" => 0,
                b"altered" => 1,
                b"emphasized" => 2,
                _ => continue,
            };
            counts[m as usize] += 1;
            let text = |c| String::from(core::str::from_utf8(self.vstr(ot, c, r)).unwrap_or(""));
            by_item.push((self.vu32(ot, col::overlays::ITEM_ID, r), m, text(col::overlays::TITLE), text(col::overlays::BODY)));
        }
        let lin_row = self.row_of(lt, lineage);
        let lin_theme = lin_row.map_or(&b""[..], |r| self.vstr(lt, col::cv_lineages::THEME, r));
        let lineage_targets = if lin_theme.is_empty() || lin_theme == b"{}" {
            None
        } else {
            let t = lin_row.map_or(&b""[..], |r| self.vstr(lt, col::cv_lineages::THEME_TARGETS, r));
            Some(keywords::theme_targets(core::str::from_utf8(t).unwrap_or("")))
        };
        let variants: Vec<usize> = (0..self.rows(vt)).filter(|&r| self.vu32(vt, col::cv_variants::LINEAGE_ID, r) == lineage).collect();
        let mut writes: Vec<(u32, [u32; 5])> = Vec::new();
        for v in variants {
            let job = self.vu32(vt, col::cv_variants::JOB_APP_ID, v);
            let profile = self.vu32(vt, col::cv_variants::PROFILE_ID, v);
            let Some(jr) = self.row_of(jt, job) else { continue };
            // The text a reader sees: every shown line's title and body.
            let mut text = String::new();
            let mut first = true;
            for r in 0..self.rows(it) {
                let p = self.vu32(it, col::items::PROFILE_ID, r);
                if !(p == NONE || p == 0 || p == profile) {
                    continue;
                }
                let id = self.vu32(it, col::items::ID, r);
                let ov = by_item.iter().find(|o| o.0 == id);
                if ov.is_some_and(|o| o.1 == 0) {
                    continue;
                }
                let raw = |c| core::str::from_utf8(self.vstr(it, c, r)).unwrap_or("");
                let (mut title, mut body) = (raw(col::items::TITLE), raw(col::items::BODY));
                if let Some(o) = ov.filter(|o| o.1 == 1) {
                    if !o.2.is_empty() {
                        title = &o.2;
                    }
                    if !o.3.is_empty() {
                        body = &o.3;
                    }
                }
                if !first {
                    text.push('\n');
                }
                first = false;
                text.push_str(title);
                text.push('\n');
                text.push_str(body);
            }
            let text = heat::downcase(&text);
            let targets = match &lineage_targets {
                Some(t) => t.clone(),
                None => keywords::theme_targets(core::str::from_utf8(self.vstr(vt, col::cv_variants::THEME_TARGETS, v)).unwrap_or("")),
            };
            let targets = if targets.is_empty() {
                keywords::extract(core::str::from_utf8(self.vstr(jt, col::job_apps::LISTING, jr)).unwrap_or(""))
            } else {
                targets
            };
            let hits = targets.iter().filter(|t| keywords::hit(&text, t)).count() as u32;
            writes.push((job, [hits, targets.len() as u32, counts[0], counts[1], counts[2]]));
        }
        for (job, w) in writes {
            for (c, v) in [
                col::job_apps::KEYWORD_HITS,
                col::job_apps::KEYWORD_TOTAL,
                col::job_apps::MASK_HIDDEN,
                col::job_apps::MASK_ALTERED,
                col::job_apps::MASK_EMPHASIZED,
            ]
            .into_iter()
            .zip(w)
            {
                self.set(jt, job, c, Val::U(v), rec);
            }
        }
    }
}

/// `Map.put(notes, stage, note)` on the job's stage_notes, re-encoded as
/// Jason encodes a small map: keys sorted, strings escaped minimally.
/// None when the stored text is not an object of strings this can read.
fn put_note(json: &str, stage: &str, note: &str) -> Option<String> {
    let mut pairs = parse_object(if json.is_empty() { "{}" } else { json })?;
    match pairs.iter_mut().find(|(k, _)| k == stage) {
        Some(p) => p.1 = String::from(note),
        None => pairs.push((String::from(stage), String::from(note))),
    }
    pairs.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let mut out = String::from("{");
    for (i, (k, v)) in pairs.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        escape(k, &mut out);
        out.push(':');
        escape(v, &mut out);
    }
    out.push('}');
    Some(out)
}

fn escape(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                const HEX: &[u8; 16] = b"0123456789ABCDEF";
                out.push_str("\\u00");
                out.push(HEX[(c as usize) >> 4] as char);
                out.push(HEX[(c as usize) & 15] as char);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A JSON object whose values are all strings, as (key, value) pairs.
fn parse_object(s: &str) -> Option<Vec<(String, String)>> {
    let b = s.as_bytes();
    let mut i = 0;
    let ws = |i: &mut usize| {
        while *i < b.len() && matches!(b[*i], b' ' | b'\n' | b'\r' | b'\t') {
            *i += 1;
        }
    };
    ws(&mut i);
    if b.get(i) != Some(&b'{') {
        return None;
    }
    i += 1;
    let mut out = Vec::new();
    ws(&mut i);
    if b.get(i) == Some(&b'}') {
        return Some(out);
    }
    loop {
        ws(&mut i);
        let k = string(s, &mut i)?;
        ws(&mut i);
        if b.get(i) != Some(&b':') {
            return None;
        }
        i += 1;
        ws(&mut i);
        let v = string(s, &mut i)?;
        out.push((k, v));
        ws(&mut i);
        match b.get(i) {
            Some(b',') => i += 1,
            Some(b'}') => return Some(out),
            _ => return None,
        }
    }
}

fn string(s: &str, i: &mut usize) -> Option<String> {
    let b = s.as_bytes();
    if b.get(*i) != Some(&b'"') {
        return None;
    }
    *i += 1;
    let mut out = String::new();
    loop {
        let c = *b.get(*i)?;
        match c {
            b'"' => {
                *i += 1;
                return Some(out);
            }
            b'\\' => {
                let e = *b.get(*i + 1)?;
                *i += 2;
                match e {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{8}'),
                    b'f' => out.push('\u{c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let hex = |at: usize| u32::from_str_radix(s.get(at..at + 4)?, 16).ok();
                        let mut cp = hex(*i)?;
                        *i += 4;
                        if (0xD800..0xDC00).contains(&cp) && s.get(*i..*i + 2) == Some("\\u") {
                            let lo = hex(*i + 2)?;
                            if (0xDC00..0xE000).contains(&lo) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                *i += 6;
                            }
                        }
                        out.push(char::from_u32(cp)?);
                    }
                    _ => return None,
                }
            }
            _ => {
                // One whole UTF-8 character.
                let ch = s[*i..].chars().next()?;
                out.push(ch);
                *i += ch.len_utf8();
            }
        }
    }
}

// ---- Hireme.Form over an op's key, value pairs ----------------------------

/// The pairs as a map: a later key wins, as `Map.new/2` keeps the last.
fn form<'a>(o: &Op<'a>) -> Vec<(&'a str, &'a str)> {
    let f: Vec<&str> = o.fields().map(|x| x.unwrap_or("")).collect();
    let mut out: Vec<(&str, &str)> = Vec::new();
    for kv in f.chunks(2) {
        if let [k, v] = kv {
            match out.iter_mut().find(|(ok, _)| ok == k) {
                Some(slot) => slot.1 = v,
                None => out.push((k, v)),
            }
        }
    }
    out
}

fn get<'a>(f: &[(&str, &'a str)], name: &str) -> Option<&'a str> {
    f.iter().find(|(k, _)| *k == name).map(|(_, v)| *v)
}

/// Form.closed/4: blank takes the default (or is refused without one),
/// anything else must name a member exactly.
fn closed(f: &[(&str, &str)], name: &str, set: &[&str], has_default: bool) -> Result<(), u8> {
    match get(f, name) {
        None | Some("") => {
            if has_default { Ok(()) } else { Err(refusal::ARGUMENT) }
        }
        Some(v) if set.contains(&v) => Ok(()),
        Some(_) => Err(refusal::ARGUMENT),
    }
}

/// Form.day/3: blank is the default, else an ISO date.
fn day(f: &[(&str, &str)], name: &str) -> Result<(), u8> {
    match get(f, name) {
        None | Some("") => Ok(()),
        Some(v) => iso_day(v).map(|_| ()).ok_or(refusal::ARGUMENT),
    }
}

/// Form.required/2: trimmed, not empty.
fn required<'a>(f: &[(&str, &'a str)], name: &str) -> Result<&'a str, u8> {
    let v = heat::trim(get(f, name).unwrap_or(""));
    if v.is_empty() { Err(refusal::ARGUMENT) } else { Ok(v) }
}

/// Would Text.slug/1 make nothing of `title`: no a-z0-9 after downcasing.
fn slug_empty(title: &str) -> bool {
    !heat::downcase(title).bytes().any(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
}
