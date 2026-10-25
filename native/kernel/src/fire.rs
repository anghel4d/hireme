//! Missions and fire keys: the unit of fire, the operator's authority over
//! it, and the commander who answers a shot.
//!
//! A mission is one route of an application. Write access stages it up to
//! fire_ready; only a shot under a live fire key moves it on. A key is made
//! by the operator's command alone, names its missions by ranges of ids and
//! freezes each one's SHA-256 (`hash`: everything the shot sends), so a
//! mission edited afterwards no longer fires under it. One shot per mission:
//! the shot burns when it lands (`landed`), and a failed one leaves the
//! mission covered. A key lives a week unused and 24 hours from its first
//! use. A shot that cannot go is answered, not errored: the `fire` refusal
//! carries the commander's answer (`answer`), what the key has burned, what
//! it still covers and the time it has left.
//!
//! The three writers, as the judge's context tells them apart: the operator
//! (`human`), an agent (a `key_id`), and the mail actor (neither: the
//! node's connector and the domain pipe, which record facts).

use alloc::borrow::Cow;
use alloc::string::String;
use alloc::vec::Vec;

use schema::col::{applications as A, fire_keys as K, fire_requests as R, fire_shots as S, mailboxes as MB, missions as M};
use schema::{enums, refusal, table};
use serde_json::{json, Value as Json};
use sha2::{Digest, Sha256};

use crate::judge::{no, Ctx, EVal, Refusal, Row};
use crate::pipeline::Stage;
use crate::rows::{Rows, Table, Val};

/// An unused key's life, and a used key's from its first use (seconds).
pub const UNUSED_LIFE: i64 = 7 * 86_400;
pub const USED_LIFE: i64 = 86_400;
/// A request's reason, in characters.
pub const REASON_MAX: usize = 280;
/// An email's recipients, To and Cc together: what the connector sends to.
pub const RECIPIENTS_MAX: usize = 10;

/// The states a put moves a mission among.
const STAGED: [u8; 4] = [enums::mission_state::DRAFT, enums::mission_state::DRAFT_READY, enums::mission_state::FIRE_READY, enums::mission_state::CANCELLED];

// ------------------------------------------------------------------ ranges

/// A set of ids as sorted, disjoint, non-adjacent inclusive runs: how a key
/// names its missions ("1-44,56-213,444,4413").
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Ranges(Vec<(u32, u32)>);

impl Ranges {
    /// Ranges from their text: ids and `a-b` runs (a ≤ b, ids from 1)
    /// separated by commas, spaces anywhere between tokens. One pass of a
    /// small automaton; the error is the byte offset it stopped at.
    pub fn parse(text: &str) -> Result<Ranges, usize> {
        #[derive(Clone, Copy, PartialEq)]
        enum St {
            Start,
            Lo,
            Dash,
            Hi,
            AfterNum,
        }
        let mut runs = Vec::new();
        let (mut st, mut lo, mut n): (St, u64, u64) = (St::Start, 0, 0);
        let b = text.as_bytes();
        let close = |lo: u64, hi: u64, at: usize, runs: &mut Vec<(u32, u32)>| -> Result<(), usize> {
            if lo == 0 || lo > hi || hi > u64::from(u32::MAX) {
                return Err(at);
            }
            runs.push((lo as u32, hi as u32));
            Ok(())
        };
        for (i, &c) in b.iter().enumerate() {
            st = match (st, c) {
                (_, b' ' | b'\t') if st != St::Lo && st != St::Hi => st,
                (St::Lo, b' ' | b'\t') => {
                    lo = n;
                    St::AfterNum
                }
                (St::Hi, b' ' | b'\t') => {
                    close(lo, n, i, &mut runs)?;
                    lo = 0;
                    St::AfterNum
                }
                (St::Start, b'0'..=b'9') | (St::Dash, b'0'..=b'9') => {
                    if st == St::Start {
                        lo = 0;
                    }
                    n = u64::from(c - b'0');
                    if st == St::Start { St::Lo } else { St::Hi }
                }
                (St::Lo | St::Hi, b'0'..=b'9') => {
                    n = n * 10 + u64::from(c - b'0');
                    if n > u64::from(u32::MAX) {
                        return Err(i);
                    }
                    st
                }
                (St::Lo, b'-') => {
                    lo = n;
                    St::Dash
                }
                (St::AfterNum, b'-') if lo > 0 => St::Dash,
                (St::Lo, b',') => {
                    close(n, n, i, &mut runs)?;
                    St::Start
                }
                (St::Hi, b',') => {
                    close(lo, n, i, &mut runs)?;
                    St::Start
                }
                (St::AfterNum, b',') => {
                    if lo > 0 {
                        close(lo, lo, i, &mut runs)?;
                    }
                    lo = 0;
                    St::Start
                }
                _ => return Err(i),
            };
        }
        if st == St::Start && text.trim_end().ends_with(',') {
            return Err(b.len());
        }
        match st {
            St::Lo => close(n, n, b.len(), &mut runs)?,
            St::Hi => close(lo, n, b.len(), &mut runs)?,
            St::AfterNum if lo > 0 => close(lo, lo, b.len(), &mut runs)?,
            St::Dash => return Err(b.len()),
            _ => {}
        }
        Ok(Ranges::normal(runs))
    }

    /// Ranges holding exactly `ids`.
    pub fn of(ids: impl IntoIterator<Item = u32>) -> Ranges {
        Ranges::normal(ids.into_iter().filter(|&i| i > 0).map(|i| (i, i)).collect())
    }

    fn normal(mut runs: Vec<(u32, u32)>) -> Ranges {
        runs.sort_unstable();
        let mut out: Vec<(u32, u32)> = Vec::with_capacity(runs.len());
        for (lo, hi) in runs {
            match out.last_mut() {
                Some(last) if u64::from(lo) <= u64::from(last.1) + 1 => last.1 = last.1.max(hi),
                _ => out.push((lo, hi)),
            }
        }
        Ranges(out)
    }

    pub fn contains(&self, id: u32) -> bool {
        let i = self.0.partition_point(|r| r.1 < id);
        self.0.get(i).is_some_and(|r| r.0 <= id)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// How many ids it holds.
    pub fn count(&self) -> u64 {
        self.0.iter().map(|r| u64::from(r.1 - r.0) + 1).sum()
    }

    /// The canonical text: runs joined by commas, a run of one as its id.
    pub fn text(&self) -> String {
        let run = |&(lo, hi): &(u32, u32)| if lo == hi { alloc::format!("{lo}") } else { alloc::format!("{lo}-{hi}") };
        self.0.iter().map(run).collect::<Vec<_>>().join(",")
    }
}

// ------------------------------------------------------------------ cells

fn now_u32(now: i64) -> Val {
    Val::U32(u32::try_from(now.max(0)).unwrap_or(u32::MAX))
}

fn opt(v: Option<u32>) -> Val {
    v.map_or(Val::None, Val::U32)
}

fn text<'t>(t: &'t Table, id: u32, c: u16) -> Cow<'t, str> {
    t.text(id, c).unwrap_or(Cow::Borrowed(""))
}

fn row(table: u16, id: u32) -> Row {
    Row { table, id, cells: Vec::new() }
}

fn state_name(s: u32) -> &'static str {
    enums::mission_state::NAMES.get(s as usize).copied().unwrap_or("draft")
}

fn missions(rows: &Rows) -> Option<&Table> {
    rows.table(table::MISSIONS)
}

/// Mission `id`'s table, or not found.
fn mission_of(rows: &Rows, id: u32) -> Result<&Table, Refusal> {
    missions(rows).filter(|t| t.has(id)).ok_or_else(|| no(refusal::NOT_FOUND, json!({"table": "missions", "id": id})))
}

/// Request `id`'s table while it is open: else not found, or not_open.
fn open_request(rows: &Rows, id: u32) -> Result<&Table, Refusal> {
    let t = rows.table(table::FIRE_REQUESTS).filter(|t| t.has(id)).ok_or_else(|| no(refusal::NOT_FOUND, json!({"table": "fire_requests", "id": id})))?;
    if t.u32(id, R::STATUS) != Some(u32::from(enums::request_status::OPEN)) {
        return Err(no(refusal::STAGE, json!({"table": "fire_requests", "id": id, "rule": "not_open"})));
    }
    Ok(t)
}

/// An open request, which only the key that asked for it (or the operator)
/// changes or drops.
fn own_request(rows: &Rows, ctx: &Ctx, id: u32) -> Result<(), Refusal> {
    let t = open_request(rows, id)?;
    if !ctx.human && t.u32(id, R::REQUESTED_BY) != ctx.key_id {
        return Err(no(refusal::SCOPE, json!({"need": "the key that asked", "table": "fire_requests", "id": id})));
    }
    Ok(())
}

/// An application as a mission's review and brief show it.
fn app_json(a: &Table, app: u32) -> Json {
    json!({
        "id": app, "no": a.u32(app, A::NO), "company": a.str(app, A::COMPANY), "role": a.str(app, A::ROLE),
        "stage": a.u32(app, A::STAGE).and_then(Stage::from_u32).map(Stage::name), "corporation_id": a.u32(app, A::CORPORATION_ID),
    })
}

/// A mission's state, kind and application.
fn state(t: &Table, id: u32) -> u8 {
    t.u32(id, M::STATE).map_or(enums::mission_state::DRAFT, |v| v as u8)
}

fn is_email(t: &Table, id: u32) -> bool {
    t.u32(id, M::KIND) == Some(u32::from(enums::outreach_kind::EMAIL))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| alloc::format!("{b:02x}")).collect()
}

// ------------------------------------------------------------------ the hash

/// The CV version each application's pick sends, computed once per judgment.
pub struct Cvs {
    arms: Vec<crate::pick::Arm>,
    counts: crate::pick::Counts,
}

impl Cvs {
    pub fn of(rows: &Rows) -> Cvs {
        Cvs { arms: crate::pick::arms(rows), counts: crate::pick::Counts::of(rows) }
    }

    fn version(&self, rows: &Rows, app: u32) -> Option<u32> {
        crate::pick::pick(rows, &self.arms, &self.counts, app).version
    }

    /// Whether the version an application's pick sends is a file the mail
    /// can carry (a PDF or DOCX upload): a markdown or composed one is not.
    fn file(&self, rows: &Rows, app: u32) -> bool {
        let v = self.version(rows, app);
        v.is_some_and(|v| rows.table(table::CV_VERSIONS).and_then(|t| t.str(v, schema::col::cv_versions::BLOB_SHA)).is_some_and(|s| !s.is_empty()))
    }
}

/// A host name: dotted labels of letters, digits and hyphens, a letter TLD.
fn host_ok(h: &str) -> bool {
    let labels: Vec<&str> = h.split('.').collect();
    labels.len() >= 2
        && h.len() <= 253
        && labels.iter().all(|l| !l.is_empty() && l.len() <= 63 && l.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') && !l.starts_with('-') && !l.ends_with('-'))
        && labels.last().is_some_and(|t| t.len() >= 2 && t.bytes().all(|c| c.is_ascii_alphabetic()))
}

/// A LinkedIn profile URL as one form, `https://www.linkedin.com/in/<name>`.
pub fn linkedin_profile(text: &str) -> Option<String> {
    let t = text.trim();
    let lower = t.to_ascii_lowercase();
    let rest = lower.strip_prefix("https://").or_else(|| lower.strip_prefix("http://"))?;
    let (h, path) = rest.split_once('/')?;
    if !(h == "linkedin.com" || h.ends_with(".linkedin.com")) {
        return None;
    }
    let name = path.strip_prefix("in/")?.split(['/', '?', '#']).next()?;
    let ok = !name.is_empty() && name.len() <= 100 && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b'%');
    ok.then(|| alloc::format!("https://www.linkedin.com/in/{name}"))
}

/// A mission's target as its kind reads it, in the one form stored; the
/// one-line need when it is not one. The MCP's door and the missions put
/// call it alike: an email's To as `outreach::addrs` reads it, a form's
/// https URL, a LinkedIn profile, an X or Discord handle; `other` names
/// any route.
pub fn target(kind: crate::outreach::Kind, text: &str) -> Result<String, &'static str> {
    use crate::outreach::Kind;
    let t = text.trim();
    match kind {
        Kind::Email => crate::outreach::addrs(t).ok().filter(|a| !a.is_empty()).map(|a| a.join(", ")).ok_or("1 to 10 addresses, comma-separated"),
        Kind::CareersPage => {
            let lower = t.to_ascii_lowercase();
            let rest = lower.strip_prefix("https://").ok_or("the form's https URL")?;
            let h = rest.split(['/', '?', '#']).next().unwrap_or("");
            let h = h.rsplit('@').next().unwrap_or(h).split(':').next().unwrap_or("");
            if host_ok(h) && t.len() <= 2048 && !t.bytes().any(|c| c.is_ascii_whitespace()) { Ok(t.into()) } else { Err("the form's https URL") }
        }
        Kind::LinkedIn => linkedin_profile(t).ok_or("a linkedin.com/in/ profile URL (or no target, and a contact_id whose linkedin_url is one)"),
        Kind::XDm => {
            let lower = t.to_ascii_lowercase();
            let handle = ["https://x.com/", "https://twitter.com/", "https://www.x.com/", "https://www.twitter.com/"]
                .iter()
                .find_map(|p| lower.strip_prefix(p).map(|_| &t[p.len()..]))
                .map_or(t, |rest| rest.split(['/', '?', '#']).next().unwrap_or(""));
            let handle = handle.trim_start_matches('@');
            let ok = !handle.is_empty() && handle.len() <= 15 && handle.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_');
            if ok { Ok(handle.into()) } else { Err("an X handle: 1 to 15 letters, digits or _ (an @ or x.com/ link is read too)") }
        }
        Kind::Discord => {
            let user = |u: &str| (2..=32).contains(&u.len()) && u.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'.');
            let channel = |c: &str| !c.is_empty() && c.len() <= 100 && c.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-');
            let ok = match t.split_once("/#") {
                Some((server, ch)) => !server.trim().is_empty() && server.len() <= 100 && !server.contains('/') && channel(ch),
                None => user(&t.trim_start_matches('@').to_ascii_lowercase()),
            };
            if !ok {
                return Err("a Discord user (2 to 32 of a-z 0-9 _ .) or server/#channel");
            }
            Ok(if t.contains("/#") { t.into() } else { t.trim_start_matches('@').to_ascii_lowercase() })
        }
        Kind::Other => if t.is_empty() || t.len() > 500 { Err("the route, at most 500 bytes") } else { Ok(t.into()) },
        Kind::Note => Err("a note is no mission"),
    }
}

/// Whether a mission's route is one its kind can take: its target, or for
/// LinkedIn its contact's profile.
fn routed(rows: &Rows, t: &Table, id: u32) -> bool {
    let Some(kind) = t.u32(id, M::KIND).and_then(crate::outreach::Kind::from_code) else { return false };
    let given = text(t, id, M::TARGET);
    if !given.trim().is_empty() {
        return target(kind, &given).is_ok();
    }
    kind == crate::outreach::Kind::LinkedIn && contact_profile(rows, t.u32(id, M::CONTACT_ID)).is_some()
}

/// A contact's LinkedIn profile, when its row holds one.
fn contact_profile(rows: &Rows, contact: Option<u32>) -> Option<String> {
    let c = contact?;
    rows.table(table::CONTACTS).and_then(|t| t.str(c, schema::col::contacts::LINKEDIN_URL)).and_then(linkedin_profile)
}

/// Whether an In-Reply-To names a mail the account holds: an outreach row,
/// or the Message-ID a mission stamped. Any other value answers nothing.
fn answers(rows: &Rows, in_reply_to: &str) -> bool {
    let want = crate::filer::canonical_id(in_reply_to);
    !want.is_empty()
        && (crate::outreach::by_message_id(rows, in_reply_to).is_some()
            || missions(rows).is_some_and(|t| t.ids().iter().any(|&m| t.str(m, M::MESSAGE_ID).is_some_and(|x| crate::filer::canonical_id(x) == want))))
}

/// Whether an email mission is a reply inside a thread the account holds;
/// anything else it sends is a first contact.
fn replies(rows: &Rows, t: &Table, id: u32) -> bool {
    t.str(id, M::IN_REPLY_TO).is_some_and(|irt| answers(rows, irt))
}

/// The SHA-256 (hex) of everything mission `id` sends: its kind, target,
/// draft, cc, subject, in_reply_to and refs, its application, and the CV
/// version that application's pick sends. Each field is length-prefixed,
/// so no two missions encode alike.
pub fn hash(rows: &Rows, cvs: &Cvs, id: u32) -> Option<String> {
    let t = missions(rows).filter(|t| t.has(id))?;
    let app = t.u32(id, M::APPLICATION_ID).unwrap_or(0);
    let mut h = Sha256::new();
    h.update(b"hireme mission v1");
    let mut field = |tag: u8, bytes: &[u8]| {
        h.update([tag]);
        h.update((bytes.len() as u64).to_le_bytes());
        h.update(bytes);
    };
    field(1, &t.u32(id, M::KIND).unwrap_or(0).to_le_bytes());
    field(2, text(t, id, M::TARGET).as_bytes());
    field(3, text(t, id, M::DRAFT).as_bytes());
    field(4, text(t, id, M::CC).as_bytes());
    field(5, text(t, id, M::SUBJECT).as_bytes());
    field(6, text(t, id, M::IN_REPLY_TO).as_bytes());
    field(7, text(t, id, M::REFS).as_bytes());
    field(8, &app.to_le_bytes());
    field(9, &cvs.version(rows, app).unwrap_or(0).to_le_bytes());
    Some(hex(&h.finalize()))
}

/// What `create_fire_key` echoes from the review: the SHA-256 of the
/// eligible missions' ids and hashes, in id order.
pub fn digest(shots: &[(u32, String)]) -> String {
    let mut h = Sha256::new();
    h.update(b"hireme fire digest v1");
    for (id, hash) in shots {
        h.update(id.to_le_bytes());
        h.update(hash.as_bytes());
    }
    hex(&h.finalize())
}

// ------------------------------------------------------------------ eligibility

/// Whether an application's prior send (the crucible ledger's
/// `sync.applied_on`) is still unsettled: rule 5's block.
fn unsettled(apps: &Table, app: u32) -> bool {
    if apps.u32(app, A::PRIOR_SEND).is_some() {
        return false;
    }
    let notes = text(apps, app, A::STAGE_NOTES);
    serde_json::from_str::<Json>(&notes).ok().is_some_and(|j| j.pointer("/sync/applied_on").is_some_and(|v| !v.is_null()))
}

/// Why mission `id` cannot fire whoever asks, before any key: its own state,
/// an email's mail and CV file, its application's links, stage and prior send.
pub fn hold(rows: &Rows, cvs: &Cvs, id: u32) -> Option<&'static str> {
    let Some(t) = missions(rows).filter(|t| t.has(id)) else { return Some("not_found") };
    match state(t, id) {
        enums::mission_state::FIRE_READY => {}
        enums::mission_state::IN_FLIGHT => return Some("in_flight"),
        enums::mission_state::FIRED => return Some("fired"),
        _ => return Some("not_ready"),
    }
    if !is_email(t, id) && (!routed(rows, t, id) || text(t, id, M::DRAFT).trim().is_empty()) {
        return Some("incomplete");
    }
    if is_email(t, id) {
        let to = crate::outreach::addrs(&text(t, id, M::TARGET));
        let cc = crate::outreach::addrs(&text(t, id, M::CC));
        if to.as_ref().map_or(0, Vec::len) + cc.as_ref().map_or(0, Vec::len) > RECIPIENTS_MAX {
            return Some("recipients");
        }
        if !to.is_ok_and(|a| !a.is_empty()) || cc.is_err() || text(t, id, M::SUBJECT).trim().is_empty() || text(t, id, M::DRAFT).trim().is_empty() {
            return Some("incomplete");
        }
        // A first contact goes with the application's CV as a file; a reply
        // inside a thread the account holds needs none.
        if !replies(rows, t, id) && !t.u32(id, M::APPLICATION_ID).is_some_and(|a| cvs.file(rows, a)) {
            return Some("cv_file");
        }
    }
    let Some(apps) = rows.table(table::APPLICATIONS) else { return Some("unlinked") };
    let Some(app) = t.u32(id, M::APPLICATION_ID).filter(|a| apps.has(*a)) else { return Some("unlinked") };
    if crate::link::short(apps.u32(app, A::CORPORATION_ID), apps.u32(app, A::PLACE_ID), apps.u32(app, A::WORK_MODE)) {
        return Some("unlinked");
    }
    let stage = apps.u32(app, A::STAGE).and_then(Stage::from_u32).unwrap_or(Stage::Discovered);
    if stage < Stage::FireReady || stage == Stage::Closed {
        return Some("app_stage");
    }
    if unsettled(apps, app) {
        return Some("unsettled");
    }
    None
}

// ------------------------------------------------------------------ keys

/// A fire key's cells.
#[derive(Clone, Copy, Debug)]
pub struct Key<'r> {
    pub id: u32,
    pub scope: &'r str,
    pub usable_by: Option<u32>,
    pub request: Option<u32>,
    pub created: Option<u32>,
    pub first_used: Option<u32>,
    pub expires: u32,
    pub revoked: Option<u32>,
}

pub fn key(rows: &Rows, id: u32) -> Option<Key<'_>> {
    let t = rows.table(table::FIRE_KEYS).filter(|t| t.has(id))?;
    Some(Key {
        id,
        scope: t.str(id, K::SCOPE).unwrap_or(""),
        usable_by: t.u32(id, K::USABLE_BY),
        request: t.u32(id, K::REQUEST_ID),
        created: t.u32(id, K::INSERTED_AT),
        first_used: t.u32(id, K::FIRST_USED_AT),
        expires: t.u32(id, K::EXPIRES_AT).unwrap_or(0),
        revoked: t.u32(id, K::REVOKED_AT),
    })
}

impl Key<'_> {
    /// Why it grants nothing at `now`, if it does not.
    pub fn dead(&self, now: i64) -> Option<&'static str> {
        if self.revoked.is_some() {
            Some("revoked")
        } else if now >= i64::from(self.expires) {
            Some("expired")
        } else {
            None
        }
    }

    /// The operator's session may use any key; an agent one bound to its
    /// own API key or to none; the mail actor never fires.
    pub fn usable(&self, ctx: &Ctx) -> bool {
        ctx.human || (ctx.key_id.is_some() && self.usable_by.is_none_or(|k| Some(k) == ctx.key_id))
    }
}

/// One shot: a key's cover of one mission.
#[derive(Clone, Copy, Debug)]
pub struct Shot<'r> {
    pub id: u32,
    pub key: u32,
    pub mission: u32,
    pub hash: &'r str,
    pub burned: Option<u32>,
}

fn shot(t: &Table, id: u32) -> Shot<'_> {
    Shot {
        id,
        key: t.u32(id, S::FIRE_KEY_ID).unwrap_or(0),
        mission: t.u32(id, S::MISSION_ID).unwrap_or(0),
        hash: t.str(id, S::HASH).unwrap_or(""),
        burned: t.u32(id, S::BURNED_AT),
    }
}

/// Every shot, in id order.
pub fn shots(rows: &Rows) -> impl Iterator<Item = Shot<'_>> {
    rows.each(table::FIRE_SHOTS).map(|(t, id)| shot(t, id))
}

/// A key's shots split four ways: burned, in flight under it, changed since
/// it was made, and what it still covers.
#[derive(Clone, Debug, Default)]
pub struct Parts {
    pub burned: Vec<u32>,
    pub in_flight: Vec<u32>,
    pub changed: Vec<u32>,
    pub remaining: Vec<u32>,
}

pub fn parts(rows: &Rows, cvs: &Cvs, key: u32) -> Parts {
    let mut p = Parts::default();
    let ms = missions(rows);
    for s in shots(rows).filter(|s| s.key == key) {
        let Some(t) = ms.filter(|t| t.has(s.mission)) else { continue };
        if s.burned.is_some() {
            p.burned.push(s.mission);
        } else if state(t, s.mission) == enums::mission_state::IN_FLIGHT && t.u32(s.mission, M::FIRE_KEY_ID) == Some(key) {
            p.in_flight.push(s.mission);
        } else if hash(rows, cvs, s.mission).as_deref() != Some(s.hash) {
            p.changed.push(s.mission);
        } else {
            p.remaining.push(s.mission);
        }
    }
    p
}

/// Seconds as `HH:MM:SS` (hours past 99 kept whole).
pub fn hms(secs: i64) -> String {
    let s = secs.max(0);
    alloc::format!("{:02}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
}

fn key_json(rows: &Rows, cvs: &Cvs, k: &Key, now: i64) -> Json {
    let p = parts(rows, cvs, k.id);
    let live = k.dead(now).is_none();
    let left = i64::from(k.expires) - now;
    json!({
        "id": k.id, "scope": k.scope, "usable_by": k.usable_by, "request_id": k.request,
        "created_at": k.created.map(|c| crate::time_iso(i64::from(c))),
        "first_used_at": k.first_used.map(|c| crate::time_iso(i64::from(c))),
        "expires_at": crate::time_iso(i64::from(k.expires)),
        "expires_in_s": if live { Json::from(left) } else { Json::Null },
        "expires_in": if live { Json::from(hms(left)) } else { Json::Null },
        "revoked_at": k.revoked.map(|c| crate::time_iso(i64::from(c))),
        "burned": Ranges::of(p.burned).text(), "remaining": Ranges::of(p.remaining).text(),
        "in_flight": Ranges::of(p.in_flight).text(), "changed": Ranges::of(p.changed).text(),
    })
}

/// Every key, newest first, live ones only unless `all`.
fn key_list<'r>(rows: &'r Rows, now: i64, all: bool) -> Vec<Key<'r>> {
    let mut ks: Vec<Key> = rows.each(table::FIRE_KEYS).filter_map(|(_, id)| key(rows, id)).filter(|k| all || k.dead(now).is_none()).collect();
    ks.sort_by_key(|k| core::cmp::Reverse(k.id));
    ks
}

// ------------------------------------------------------------------ the commander

/// The commander's answer to a shot that does not go: why, the mission,
/// the key it was judged under (its burned, in-flight, changed and
/// remaining sets and the time it has left), the live keys the caller may
/// use, and for `no_key` what a request for this mission would carry.
pub fn answer(rows: &Rows, ctx: &Ctx, why: &str, mission: u32, key_id: Option<u32>) -> Refusal {
    let cvs = Cvs::of(rows);
    let mut data = json!({
        "why": why, "mission": mission, "key": key_id,
        "burned": "", "remaining": "", "in_flight": "", "changed": "",
        "expires_at": null, "expires_in": null,
    });
    if let Some(k) = key_id.and_then(|k| key(rows, k)) {
        let kj = key_json(rows, &cvs, &k, ctx.now);
        for f in ["burned", "remaining", "in_flight", "changed", "expires_at", "expires_in", "expires_in_s", "revoked_at", "scope"] {
            data[f] = kj[f].clone();
        }
    }
    let live: Vec<Json> = key_list(rows, ctx.now, false)
        .iter()
        .filter(|k| k.usable(ctx))
        .map(|k| {
            let p = parts(rows, &cvs, k.id);
            json!({"id": k.id, "scope": k.scope, "remaining": Ranges::of(p.remaining).text(), "expires_in": hms(i64::from(k.expires) - ctx.now)})
        })
        .collect();
    data["live_keys"] = Json::Array(live);
    if why == "no_key" {
        data["ask"] = json!({"missions": Ranges::of([mission]).text()});
    }
    no(refusal::FIRE, data)
}

/// The key a shot of `mission` goes under, or the commander's answer: the
/// first live key (by id) the caller may use whose shot of it is unburned
/// and unchanged; `named` narrows to one key. Every actor needs one.
pub fn authority(rows: &Rows, ctx: &Ctx, mission: u32, named: Option<u32>) -> Result<(u32, u32), Refusal> {
    if !ctx.human && ctx.key_id.is_none() {
        return Err(no(refusal::SCOPE, json!({"need": "operator or agent", "command": "fire"})));
    }
    let cvs = Cvs::of(rows);
    let now_hash = hash(rows, &cvs, mission);
    let mut cands: Vec<Shot> = shots(rows).filter(|s| s.mission == mission && named.is_none_or(|k| k == s.key)).collect();
    cands.sort_by_key(|s| s.key);
    if cands.is_empty() {
        return Err(answer(rows, ctx, if named.is_some() { "out_of_scope" } else { "no_key" }, mission, named));
    }
    // The most telling reason among the shots that do not serve.
    let rank = |w: &str| ["revoked", "expired", "not_yours", "burned", "changed"].iter().position(|x| *x == w).unwrap_or(0);
    let mut best: Option<(&'static str, u32)> = None;
    for s in &cands {
        let Some(k) = key(rows, s.key) else { continue };
        let why = if let Some(d) = k.dead(ctx.now) {
            d
        } else if !k.usable(ctx) {
            "not_yours"
        } else if s.burned.is_some() {
            "burned"
        } else if now_hash.as_deref() != Some(s.hash) {
            "changed"
        } else {
            return Ok((s.key, s.id));
        };
        if best.is_none_or(|b| rank(why) > rank(b.0)) {
            best = Some((why, s.key));
        }
    }
    let (why, k) = best.unwrap_or(("no_key", 0));
    Err(answer(rows, ctx, why, mission, Some(k).filter(|k| *k > 0)))
}

// ------------------------------------------------------------------ the mailbox and the cap

/// The UTC day of unix seconds.
fn day_of(secs: i64) -> i64 {
    secs.div_euclid(86_400)
}

/// The day's send cap, how many email shots went or are going today (UTC),
/// and when the count resets.
pub fn quota(rows: &Rows, now: i64) -> (u32, u32, i64) {
    let cap = rows.first(table::MAILBOXES).and_then(|(t, id)| t.u32(id, MB::DAILY_CAP)).unwrap_or(25);
    let today = day_of(now);
    let used = missions(rows).map_or(0, |t| {
        t.ids()
            .iter()
            .filter(|&&id| is_email(t, id))
            .filter(|&&id| match state(t, id) {
                enums::mission_state::IN_FLIGHT => t.u32(id, M::IN_FLIGHT_AT).is_some_and(|s| day_of(i64::from(s)) == today),
                enums::mission_state::FIRED => t.u32(id, M::FIRED_AT).is_some_and(|s| day_of(i64::from(s)) == today),
                _ => false,
            })
            .count() as u32
    });
    (cap, used, (today + 1) * 86_400)
}

/// An email shot's own gates: a live mailbox and room under the cap.
pub fn mail_gate(rows: &Rows, ctx: &Ctx, mission: u32, key_id: u32) -> Result<(), Refusal> {
    let live = rows.first(table::MAILBOXES).is_some_and(|(t, id)| t.u32(id, MB::STATUS) == Some(u32::from(enums::mailbox_status::LIVE)));
    if !live {
        return Err(answer(rows, ctx, "mailbox", mission, Some(key_id)));
    }
    let (cap, used, resets) = quota(rows, ctx.now);
    if used >= cap {
        let mut r = answer(rows, ctx, "cap", mission, Some(key_id));
        r.data["cap"] = json!(cap);
        r.data["used"] = json!(used);
        r.data["resets_at"] = json!(crate::time_iso(resets));
        return Err(r);
    }
    Ok(())
}

// ------------------------------------------------------------------ the shot's rows

/// What a shot that goes writes on its mission and its key: in flight, by
/// whom, under which key; the key's 24 hours start at its first use.
pub fn going(rows: &Rows, ctx: &Ctx, mission: u32, key_id: u32) -> Vec<Row> {
    let mut m = row(table::MISSIONS, mission);
    // The CV the shot carries is the one the key's hash covered: the node
    // attaches this version, whatever the pick names later, and attaches
    // nothing when it is null (a reply inside a thread the account holds).
    let app = application(rows, mission).unwrap_or(0);
    let reply = missions(rows).is_some_and(|t| is_email(t, mission) && replies(rows, t, mission));
    m.set(M::CV_VERSION_ID, if reply { Val::None } else { opt(Cvs::of(rows).version(rows, app)) });
    m.set(M::STATE, Val::U32(u32::from(enums::mission_state::IN_FLIGHT)));
    m.set(M::IN_FLIGHT_AT, now_u32(ctx.now));
    m.set(M::FIRE_KEY_ID, Val::U32(key_id));
    m.set(M::FIRED_WITH, opt(ctx.key_id));
    let actor = if ctx.human { enums::actor::OPERATOR } else { enums::actor::AGENT };
    m.set(M::FIRED_BY, Val::U32(u32::from(actor)));
    m.set(M::LAST_ERROR, Val::None);
    let mut out = alloc::vec![m];
    if key(rows, key_id).is_some_and(|k| k.first_used.is_none()) {
        let mut k = row(table::FIRE_KEYS, key_id);
        k.set(K::FIRST_USED_AT, now_u32(ctx.now));
        k.set(K::EXPIRES_AT, now_u32(ctx.now + USED_LIFE));
        out.push(k);
    }
    out
}

/// Who may report a shot's outcome: an email's, the mail actor; another's,
/// the API key that fired it or the operator.
pub fn may_report(rows: &Rows, ctx: &Ctx, mission: u32) -> Result<(), Refusal> {
    let t = mission_of(rows, mission)?;
    let mail = !ctx.human && ctx.key_id.is_none();
    let ok = if is_email(t, mission) { mail } else { ctx.human || (ctx.key_id.is_some() && t.u32(mission, M::FIRED_WITH) == ctx.key_id) };
    if !ok {
        return Err(no(refusal::SCOPE, json!({"need": if is_email(t, mission) { "mail" } else { "the key that fired it, or the operator" }, "mission": mission})));
    }
    if state(t, mission) != enums::mission_state::IN_FLIGHT {
        return Err(no(refusal::STAGE, json!({"table": "missions", "id": mission, "from": state_name(u32::from(state(t, mission))), "rule": "not_in_flight"})));
    }
    Ok(())
}

/// A landed shot's rows on its mission and its key's shot: fired, burned,
/// provisional unless it is a mail the node watched go out, which also
/// leaves the sent mail's record (an outreach row filed to the mission). An
/// email lands only once the node has stamped its Message-ID.
pub fn landed(rows: &Rows, ctx: &Ctx, mission: u32, gmail: (Val, Val)) -> Result<Vec<Row>, Refusal> {
    let t = missions(rows).filter(|t| t.has(mission));
    let mut m = row(table::MISSIONS, mission);
    m.set(M::STATE, Val::U32(u32::from(enums::mission_state::FIRED)));
    m.set(M::FIRED_AT, now_u32(ctx.now));
    let mut record = None;
    if let Some(t) = t.filter(|t| is_email(t, mission)) {
        let Some(message_id) = t.str(mission, M::MESSAGE_ID).filter(|v| !v.is_empty()) else {
            return Err(no(refusal::STAGE, json!({"table": "missions", "id": mission, "rule": "unstamped", "need": "stamp {message_id} before the mail goes"})));
        };
        let num = |v: &Val| match v {
            Val::I64(n) => Some(*n),
            Val::U32(n) => Some(i64::from(*n)),
            _ => None,
        };
        let app = t.u32(mission, M::APPLICATION_ID).unwrap_or(0);
        let to = crate::outreach::addrs(&text(t, mission, M::TARGET)).unwrap_or_default();
        let cc = crate::outreach::addrs(&text(t, mission, M::CC)).unwrap_or_default();
        let refs: Vec<String> = text(t, mission, M::REFS).split_whitespace().map(String::from).collect();
        let body = text(t, mission, M::DRAFT).into_owned();
        let from = rows.first(table::MAILBOXES).and_then(|(mb, id)| mb.str(id, MB::ADDRESS)).unwrap_or("");
        let shot = crate::outreach::Shot {
            mission_id: mission,
            application_id: app,
            contact_id: t.u32(mission, M::CONTACT_ID),
            corporation_id: rows.table(table::APPLICATIONS).and_then(|a| a.u32(app, A::CORPORATION_ID)),
            from,
            to: &to,
            cc: &cc,
            subject: t.str(mission, M::SUBJECT),
            body: Some(body.as_str()).filter(|b| !b.is_empty()),
            in_reply_to: t.str(mission, M::IN_REPLY_TO),
            refs: &refs,
            message_id,
            gmail_msgid: num(&gmail.0),
            gmail_thrid: num(&gmail.1),
        };
        record = Some(crate::outreach::sent_record(rows, &shot, ctx.now));
        m.set(M::GMAIL_MSGID, gmail.0);
        m.set(M::GMAIL_THRID, gmail.1);
    } else {
        m.set(M::CONFIRMATION, Val::U32(u32::from(enums::confirmation::PROVISIONAL)));
    }
    let mut out = alloc::vec![m];
    let k = t.and_then(|t| t.u32(mission, M::FIRE_KEY_ID));
    if let Some(s) = shots(rows).find(|s| s.mission == mission && Some(s.key) == k) {
        let mut r = row(table::FIRE_SHOTS, s.id);
        r.set(S::BURNED_AT, now_u32(ctx.now));
        out.push(r);
    }
    out.extend(record);
    Ok(out)
}

/// A failed shot: the mission back to fire_ready with the reason, its shot
/// unburned (still covered).
pub fn failed(rows: &Rows, mission: u32, reason: &str) -> Vec<Row> {
    let mut m = row(table::MISSIONS, mission);
    m.set(M::STATE, Val::U32(u32::from(enums::mission_state::FIRE_READY)));
    m.set(M::LAST_ERROR, if reason.trim().is_empty() { Val::Str("failed".into()) } else { Val::Str(reason.trim().into()) });
    let mut out = alloc::vec![m];
    let k = missions(rows).and_then(|t| t.u32(mission, M::FIRE_KEY_ID));
    if let Some(s) = shots(rows).find(|s| s.mission == mission && Some(s.key) == k && s.burned.is_some()) {
        let mut r = row(table::FIRE_SHOTS, s.id);
        r.set(S::BURNED_AT, Val::None);
        out.push(r);
    }
    out
}

/// A bounce of the mail a mission sent: the shot failed after all, so the
/// mission goes back to fire_ready, still covered (rule 2). Only a fired
/// mission moves; one already firing again keeps its shot, whose outcome
/// the node reports.
pub fn bounced(rows: &Rows, mission: u32) -> Vec<Row> {
    let fired = missions(rows).is_some_and(|t| t.has(mission) && state(t, mission) == enums::mission_state::FIRED);
    if fired { failed(rows, mission, "bounced") } else { Vec::new() }
}

/// Whether any of an application's missions is in flight.
pub fn in_flight(rows: &Rows, app: u32) -> bool {
    missions(rows).is_some_and(|t| t.ids().iter().any(|&m| t.u32(m, M::APPLICATION_ID) == Some(app) && state(t, m) == enums::mission_state::IN_FLIGHT))
}

/// The application a mission belongs to.
pub fn application(rows: &Rows, mission: u32) -> Option<u32> {
    missions(rows).and_then(|t| t.u32(mission, M::APPLICATION_ID))
}

/// A line for the application's events.
pub fn describe(rows: &Rows, mission: u32) -> String {
    let Some(t) = missions(rows).filter(|t| t.has(mission)) else { return alloc::format!("mission #{mission}") };
    let kind = t.u32(mission, M::KIND).and_then(|k| enums::outreach_kind::NAMES.get(k as usize).copied()).unwrap_or("mission");
    let target = text(t, mission, M::TARGET);
    if target.is_empty() { alloc::format!("mission #{mission} ({kind})") } else { alloc::format!("mission #{mission} ({kind}) → {target}") }
}

// ------------------------------------------------------------------ the operator's commands

fn need_human(ctx: &Ctx, command: &str) -> Result<(), Refusal> {
    if ctx.human { Ok(()) } else { Err(no(refusal::HUMAN_ONLY, json!({"command": command}))) }
}

fn need_mail(ctx: &Ctx, command: &str) -> Result<(), Refusal> {
    if !ctx.human && ctx.key_id.is_none() { Ok(()) } else { Err(no(refusal::SCOPE, json!({"need": "mail", "command": command}))) }
}

/// The review of a set of missions (rule 4): each one's draft and target in
/// full, its application, CV version and hash, and why it would not fire;
/// the eligible ones' canonical scope and their digest.
pub fn review(rows: &Rows, scope: &Ranges) -> Json {
    let cvs = Cvs::of(rows);
    let apps = rows.table(table::APPLICATIONS);
    let mut out = Vec::new();
    let mut eligible: Vec<(u32, String)> = Vec::new();
    if let Some(t) = missions(rows) {
        for &id in t.ids().iter().filter(|&&id| scope.contains(id)) {
            let why = hold(rows, &cvs, id);
            let h = hash(rows, &cvs, id).unwrap_or_default();
            let app = t.u32(id, M::APPLICATION_ID).unwrap_or(0);
            let a = apps.filter(|a| a.has(app));
            let draft = if is_email(t, id) {
                json!({"to": t.str(id, M::TARGET), "cc": t.str(id, M::CC), "subject": t.str(id, M::SUBJECT), "body": t.text(id, M::DRAFT),
                       "in_reply_to": t.str(id, M::IN_REPLY_TO), "refs": t.text(id, M::REFS)})
            } else {
                json!({"markdown": t.text(id, M::DRAFT)})
            };
            out.push(json!({
                "id": id,
                "kind": t.u32(id, M::KIND).and_then(|k| enums::outreach_kind::NAMES.get(k as usize).copied()),
                "target": t.str(id, M::TARGET),
                "state": state_name(u32::from(state(t, id))),
                "application": a.map_or(Json::Null, |a| app_json(a, app)),
                "draft": draft,
                "cv_version_id": if is_email(t, id) && replies(rows, t, id) { None } else { cvs.version(rows, app) },
                "hash": h,
                "eligible": why.is_none(),
                "why": why,
            }));
            if why.is_none() {
                eligible.push((id, h));
            }
        }
    }
    let scope = Ranges::of(eligible.iter().map(|e| e.0));
    json!({"missions": out, "scope": scope.text(), "count": eligible.len(), "digest": digest(&eligible)})
}

/// `create_fire_key`: the operator's key over exactly the reviewed missions.
/// The eligible missions of `missions` must be all of them that exist, and
/// their digest the review's; a request it answers turns granted.
pub fn create(rows: &Rows, ctx: &Ctx, missions_text: &str, digest_given: &str, usable_by: Option<u32>, request: Option<u32>) -> Result<Vec<Row>, Refusal> {
    need_human(ctx, "create_fire_key")?;
    let scope = Ranges::parse(missions_text).map_err(|at| no(refusal::TYPE, json!({"param": "missions", "at": at})))?;
    let cvs = Cvs::of(rows);
    let mut eligible: Vec<(u32, String)> = Vec::new();
    let mut held: Vec<u32> = Vec::new();
    if let Some(t) = missions(rows) {
        for &id in t.ids().iter().filter(|&&id| scope.contains(id)) {
            match hold(rows, &cvs, id) {
                None => eligible.push((id, hash(rows, &cvs, id).unwrap_or_default())),
                Some(_) => held.push(id),
            }
        }
    }
    if eligible.is_empty() && held.is_empty() {
        return Err(no(refusal::FIRE, json!({"why": "empty", "missions": scope.text()})));
    }
    if !held.is_empty() {
        return Err(no(refusal::FIRE, json!({"why": "ineligible", "missions": Ranges::of(held).text(), "review": review(rows, &scope)})));
    }
    if digest(&eligible) != digest_given.trim() {
        return Err(no(refusal::FIRE, json!({"why": "changed", "review": review(rows, &scope)})));
    }
    let mut bound = usable_by;
    if let Some(r) = request {
        bound = bound.or(open_request(rows, r)?.u32(r, R::REQUESTED_BY));
    }
    let mut k = row(table::FIRE_KEYS, 0);
    k.set(K::SCOPE, Val::Str(Ranges::of(eligible.iter().map(|e| e.0)).text()));
    k.set(K::USABLE_BY, opt(bound));
    k.set(K::REQUEST_ID, opt(request));
    k.set(K::EXPIRES_AT, now_u32(ctx.now + UNUSED_LIFE));
    let mut out = alloc::vec![k];
    for (id, h) in eligible {
        let mut s = row(table::FIRE_SHOTS, 0);
        s.set(S::FIRE_KEY_ID, EVal::New(0));
        s.set(S::MISSION_ID, Val::U32(id));
        s.set(S::HASH, Val::Str(h));
        out.push(s);
    }
    if let Some(r) = request {
        let mut q = row(table::FIRE_REQUESTS, r);
        q.set(R::STATUS, Val::U32(u32::from(enums::request_status::GRANTED)));
        q.set(R::FIRE_KEY_ID, EVal::New(0));
        out.push(q);
    }
    Ok(out)
}

/// `revoke_fire_key`: the key grants nothing from now; a shot in flight
/// under it still reports its outcome.
pub fn revoke(rows: &Rows, ctx: &Ctx, id: u32) -> Result<Vec<Row>, Refusal> {
    need_human(ctx, "revoke_fire_key")?;
    let Some(k) = key(rows, id) else { return Err(no(refusal::NOT_FOUND, json!({"table": "fire_keys", "id": id}))) };
    if k.revoked.is_some() {
        return Ok(Vec::new());
    }
    let mut r = row(table::FIRE_KEYS, id);
    r.set(K::REVOKED_AT, now_u32(ctx.now));
    Ok(alloc::vec![r])
}

/// `decline`: an open request closed without a key.
pub fn decline(rows: &Rows, ctx: &Ctx, id: u32) -> Result<Vec<Row>, Refusal> {
    need_human(ctx, "decline")?;
    open_request(rows, id)?;
    let mut r = row(table::FIRE_REQUESTS, id);
    r.set(R::STATUS, Val::U32(u32::from(enums::request_status::DECLINED)));
    Ok(alloc::vec![r])
}

/// `stamp`: the Message-ID the node minted for an email shot, once.
pub fn stamp(rows: &Rows, ctx: &Ctx, mission: u32, message_id: &str) -> Result<Vec<Row>, Refusal> {
    need_mail(ctx, "stamp")?;
    may_report(rows, ctx, mission)?;
    let t = mission_of(rows, mission)?;
    let id = message_id.trim();
    if id.is_empty() || id.len() > 998 || id.bytes().any(|c| c.is_ascii_whitespace() || c.is_ascii_control()) {
        return Err(no(refusal::TYPE, json!({"param": "message_id"})));
    }
    match t.str(mission, M::MESSAGE_ID) {
        Some(had) if had == id => Ok(Vec::new()),
        Some(_) => Err(no(refusal::STAGE, json!({"table": "missions", "id": mission, "rule": "stamped"}))),
        None => {
            let mut r = row(table::MISSIONS, mission);
            r.set(M::MESSAGE_ID, Val::Str(id.into()));
            Ok(alloc::vec![r])
        }
    }
}

/// `mailbox_state`: what the connector saw of the mailbox.
pub fn mailbox_state(rows: &Rows, ctx: &Ctx, status: Val, error: Val, synced: Val) -> Result<Vec<Row>, Refusal> {
    need_mail(ctx, "mailbox_state")?;
    let Some((t, id)) = rows.first(table::MAILBOXES) else { return Err(no(refusal::NOT_FOUND, json!({"table": "mailboxes"}))) };
    // An unlinked mailbox moves only to linking (a new link): a session's word on it that lands after
    // the operator's unlink must not revive it, or the erase that waits on the status never runs.
    if t.u32(id, MB::STATUS) == Some(u32::from(enums::mailbox_status::UNLINKED)) && status != Val::U32(u32::from(enums::mailbox_status::LINKING)) {
        return Err(no(refusal::UNLINKED, json!({"table": "mailboxes"})));
    }
    let mut r = row(table::MAILBOXES, id);
    r.set(MB::STATUS, status);
    r.set(MB::LAST_ERROR, error);
    if !synced.is_none() {
        r.set(MB::LAST_SYNC_AT, synced);
    }
    Ok(alloc::vec![r])
}

/// `unlink_mail`: the operator unlinks the mailbox (the node clears the
/// secrets and the cursor when it reads the status).
pub fn unlink(rows: &Rows, ctx: &Ctx) -> Result<Vec<Row>, Refusal> {
    need_human(ctx, "unlink_mail")?;
    let Some((_, id)) = rows.first(table::MAILBOXES) else { return Err(no(refusal::NOT_FOUND, json!({"table": "mailboxes"}))) };
    let mut r = row(table::MAILBOXES, id);
    r.set(MB::STATUS, Val::U32(u32::from(enums::mailbox_status::UNLINKED)));
    Ok(alloc::vec![r])
}

// ------------------------------------------------------------------ puts and drops

/// The domain rules of a put on the mission, request and mailbox tables:
/// who writes what, the states a put may move a mission among, a mission in
/// flight or fired kept as it went, a request's ranges made canonical and
/// its requester stamped.
pub fn put(rows: &Rows, ctx: &Ctx, op_table: u16, target: u32, row: &mut Row) -> Result<(), Refusal> {
    let mail = !ctx.human && ctx.key_id.is_none();
    let given = |row: &Row, c: u16| row.get(c).cloned();
    match op_table {
        table::MISSIONS => {
            if mail {
                return Err(no(refusal::SCOPE, json!({"need": "operator or agent", "table": "missions"})));
            }
            let t = missions(rows).filter(|t| target > 0 && t.has(target));
            let from = t.map(|t| state(t, target));
            if t.is_none() && given(row, M::STATE).is_none() {
                row.set(M::STATE, Val::U32(u32::from(enums::mission_state::DRAFT)));
            }
            if let Some(f) = from.filter(|f| [enums::mission_state::IN_FLIGHT, enums::mission_state::FIRED].contains(f))
                && row.cells.iter().any(|c| c.0 != M::NOTE)
            {
                return Err(no(refusal::STAGE, json!({"table": "missions", "id": target, "from": state_name(u32::from(f)), "rule": "record"})));
            }
            if let Some(EVal::Val(Val::U32(to))) = given(row, M::STATE)
                && (!STAGED.contains(&(to as u8)) || from.is_some_and(|f| !STAGED.contains(&f)))
            {
                return Err(no(refusal::STAGE, json!({"table": "missions", "id": target, "from": from.map(|f| state_name(u32::from(f))), "to": state_name(to), "rule": "by_command"})));
            }
            let kind = row.number(M::KIND, t, target);
            // A first-contact email reaches fire_ready only with a CV file to
            // carry (the pick's version a PDF or DOCX upload).
            let to_ready = matches!(given(row, M::STATE), Some(EVal::Val(Val::U32(s))) if s == u32::from(enums::mission_state::FIRE_READY));
            if to_ready && kind == Some(u32::from(enums::outreach_kind::EMAIL)) {
                let reply = match given(row, M::IN_REPLY_TO) {
                    Some(EVal::Val(Val::Str(v))) => answers(rows, &v),
                    Some(_) => false,
                    None => t.and_then(|t| t.str(target, M::IN_REPLY_TO)).is_some_and(|v| answers(rows, v)),
                };
                if !reply && !row.number(M::APPLICATION_ID, t, target).is_some_and(|a| Cvs::of(rows).file(rows, a)) {
                    return Err(no(refusal::STAGE, json!({"table": "missions", "id": target, "to": "fire_ready", "rule": "cv_file", "need": "the application's CV as a PDF or DOCX version: pick one (pick_cv) or upload one"})));
                }
            }
            if kind.and_then(crate::outreach::Kind::from_code).is_some_and(|k| !k.fireable()) {
                return Err(no(refusal::TYPE, json!({"table": "missions", "column": "kind", "reason": "a mission is never a note"})));
            }
            if let Some(k) = kind.and_then(crate::outreach::Kind::from_code).filter(|k| *k != crate::outreach::Kind::Email) {
                // The target as its kind reads it, stored in one form: a form's
                // https URL, a LinkedIn profile, an X or Discord handle.
                let given_target = match given(row, M::TARGET) {
                    Some(EVal::Val(Val::Str(v))) => Some(v),
                    _ => None,
                };
                let text_now = given_target.clone().or_else(|| t.and_then(|t| t.str(target, M::TARGET)).map(String::from)).unwrap_or_default();
                if (given_target.is_some() || given(row, M::KIND).is_some()) && !text_now.trim().is_empty() {
                    let read = self::target(k, &text_now).map_err(|need| no(refusal::TYPE, json!({"table": "missions", "column": "target", "need": need})))?;
                    if given_target.is_some() {
                        row.set(M::TARGET, Val::Str(read));
                    }
                }
                if to_ready && text_now.trim().is_empty() {
                    let by_contact = k == crate::outreach::Kind::LinkedIn && contact_profile(rows, row.number(M::CONTACT_ID, t, target)).is_some();
                    if !by_contact {
                        let need = self::target(k, "").err().unwrap_or("a target");
                        return Err(no(refusal::TYPE, json!({"table": "missions", "column": "target", "need": need})));
                    }
                }
            }
            if kind == Some(u32::from(enums::outreach_kind::EMAIL)) {
                // An email's To and cc as the outreach type reads them, stored
                // bare: what the hash covers is what goes out.
                let mut count = 0;
                for (c, name) in [(M::TARGET, "target"), (M::CC, "cc")] {
                    let a = match given(row, c) {
                        Some(EVal::Val(Val::Str(list))) => {
                            let a = crate::outreach::addrs(&list)
                                .map_err(|_| no(refusal::TYPE, json!({"table": "missions", "column": name, "need": "up to 10 addresses, comma-separated"})))?;
                            row.set(c, if a.is_empty() { Val::None } else { Val::Str(a.join(", ")) });
                            a
                        }
                        Some(_) => Vec::new(),
                        None => t.map(|t| crate::outreach::addrs(&text(t, target, c)).unwrap_or_default()).unwrap_or_default(),
                    };
                    count += a.len();
                }
                if count > RECIPIENTS_MAX {
                    return Err(no(refusal::TYPE, json!({"table": "missions", "column": "cc", "need": alloc::format!("at most {RECIPIENTS_MAX} recipients in To and Cc together")})));
                }
            }
            Ok(())
        }
        table::FIRE_REQUESTS => {
            if mail {
                return Err(no(refusal::SCOPE, json!({"need": "operator or agent", "table": "fire_requests"})));
            }
            if rows.table(table::FIRE_REQUESTS).is_some_and(|t| target > 0 && t.has(target)) {
                own_request(rows, ctx, target)?;
            } else {
                row.set(R::REQUESTED_BY, opt(ctx.key_id));
                // The default, written as the database will, so a prediction
                // reads the row it will be.
                row.set(R::STATUS, Val::U32(u32::from(enums::request_status::OPEN)));
            }
            if let Some(EVal::Val(Val::Str(m))) = given(row, R::MISSIONS) {
                let r = Ranges::parse(&m).map_err(|at| no(refusal::TYPE, json!({"table": "fire_requests", "column": "missions", "at": at})))?;
                if r.is_empty() {
                    return Err(no(refusal::TYPE, json!({"table": "fire_requests", "column": "missions", "need": "ranges of mission ids"})));
                }
                row.set(R::MISSIONS, Val::Str(r.text()));
            }
            if let Some(EVal::Val(Val::Str(why))) = given(row, R::REASON)
                && why.chars().count() > REASON_MAX
            {
                return Err(no(refusal::TOO_LARGE, json!({"table": "fire_requests", "column": "reason", "max": REASON_MAX})));
            }
            Ok(())
        }
        table::MAILBOXES => {
            let only = |cols: &[u16]| row.cells.iter().all(|c| cols.contains(&c.0));
            let ok = if mail { only(&[MB::PROVIDER, MB::ADDRESS]) } else { ctx.human && only(&[MB::DAILY_CAP]) };
            if !ok {
                return Err(no(refusal::SCOPE, json!({"need": if ctx.human { "mail" } else { "operator or mail" }, "table": "mailboxes"})));
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

/// The domain rules of a drop: a key and its shots are the record (revoke
/// a key, never drop it); a mission in flight or fired stays; a request
/// once answered stays; the mailbox is the operator's to drop.
pub fn drop(rows: &Rows, ctx: &Ctx, op_table: u16, target: u32) -> Result<(), Refusal> {
    match op_table {
        table::FIRE_KEYS | table::FIRE_SHOTS => Err(no(refusal::SCOPE, json!({"table": if op_table == table::FIRE_KEYS { "fire_keys" } else { "fire_shots" }, "reason": "the record of what was authorized: revoke a key, never drop it"}))),
        table::MISSIONS => match missions(rows).map(|t| state(t, target)) {
            Some(s) if s == enums::mission_state::IN_FLIGHT || s == enums::mission_state::FIRED => {
                Err(no(refusal::STAGE, json!({"table": "missions", "id": target, "from": state_name(u32::from(s)), "rule": "record"})))
            }
            _ => Ok(()),
        },
        // write::drop_checks found the row.
        table::FIRE_REQUESTS => own_request(rows, ctx, target),
        table::MAILBOXES if !ctx.human => Err(no(refusal::SCOPE, json!({"need": "operator", "table": "mailboxes"}))),
        // Its missions would go with it: one in flight (a mail mid-SMTP) or
        // fired (the record of a send) keeps the application.
        table::APPLICATIONS => {
            let held = missions(rows).and_then(|t| {
                t.ids().iter().copied().find(|&m| t.u32(m, M::APPLICATION_ID) == Some(target) && [enums::mission_state::IN_FLIGHT, enums::mission_state::FIRED].contains(&state(t, m)))
            });
            match held {
                Some(m) => Err(no(refusal::STAGE, json!({"table": "applications", "id": target, "rule": "record", "mission": m, "need": "an application a mission has fired, or is firing, for stays"}))),
                None => Ok(()),
            }
        }
        _ => Ok(()),
    }
}

// ------------------------------------------------------------------ queries

/// What a page of missions reads once rather than per mission: the live
/// keys covering each (unburned shots) and the missions an outreach item
/// names.
struct Seen {
    covered: alloc::collections::BTreeMap<u32, Vec<u32>>,
    reported: alloc::collections::BTreeSet<u32>,
}

impl Seen {
    fn of(rows: &Rows, now: i64) -> Seen {
        let mut covered: alloc::collections::BTreeMap<u32, Vec<u32>> = alloc::collections::BTreeMap::new();
        for s in shots(rows).filter(|s| s.burned.is_none()) {
            if key(rows, s.key).is_some_and(|k| k.dead(now).is_none()) {
                covered.entry(s.mission).or_default().push(s.key);
            }
        }
        let reported = rows
            .table(table::OUTREACH)
            .map(|o| o.ids().iter().filter_map(|&i| crate::outreach::Item::read(o, i).and_then(|item| item.core.refs.mission_id)).collect())
            .unwrap_or_default();
        Seen { covered, reported }
    }
}

fn mission_json(rows: &Rows, cvs: &Cvs, seen: &Seen, t: &Table, id: u32) -> Json {
    let cols: Vec<&'static schema::ColDef> = schema::table_def(table::MISSIONS).map(|d| d.cols.iter().filter(|c| c.id >= 8).collect()).unwrap_or_default();
    let mut j = crate::query::row_out(t, id, &cols, false);
    j["id"] = json!(id);
    j["hash"] = json!(hash(rows, cvs, id));
    j["covered_by"] = json!(seen.covered.get(&id).cloned().unwrap_or_default());
    j["hold"] = json!(hold(rows, cvs, id));
    // A fired shot hireme could not watch (anything but an email) owes its
    // report until an outreach item names the mission.
    j["report_due"] = json!(!is_email(t, id) && state(t, id) == enums::mission_state::FIRED && !seen.reported.contains(&id));
    j
}

/// The mission and fire reads: `ranges`, `missions`, `mission_brief`,
/// `fire_review`, `live_keys`, `mail_quota`.
pub fn query(rows: &Rows, op: &str, req: &Json, today: crate::Day) -> Result<Json, Refusal> {
    // The clock: the server's `now` when the replica holds it, else the
    // caller's, else the start of the kernel's day.
    let clock = rows.first(table::CLOCK).and_then(|(t, id)| t.u32(id, schema::col::clock::NOW));
    let now = clock.map(i64::from).or_else(|| req.get("now").and_then(Json::as_i64)).unwrap_or((today as i64 - crate::UNIX_EPOCH_DAY as i64) * 86_400);
    match op {
        "ranges" => {
            let r = match (req.get("text").and_then(Json::as_str), req.get("ids").and_then(Json::as_array)) {
                (Some(t), _) => Ranges::parse(t).map_err(|at| no(refusal::TYPE, json!({"param": "text", "at": at})))?,
                (None, Some(ids)) => Ranges::of(ids.iter().filter_map(Json::as_u64).filter_map(|v| u32::try_from(v).ok())),
                _ => return Err(no(refusal::TYPE, json!({"param": "text or ids"}))),
            };
            Ok(json!({"text": r.text(), "count": r.count()}))
        }
        "missions" => {
            let cvs = Cvs::of(rows);
            let seen = Seen::of(rows, now);
            let app = req.get("application").and_then(Json::as_u64);
            let st = req.get("state").and_then(Json::as_str);
            let kind = req.get("kind").and_then(Json::as_str);
            let list: Vec<Json> = missions(rows).map_or_else(Vec::new, |t| {
                t.ids()
                    .iter()
                    .copied()
                    .filter(|&id| app.is_none_or(|a| t.u32(id, M::APPLICATION_ID).map(u64::from) == Some(a)))
                    .filter(|&id| st.is_none_or(|s| state_name(u32::from(state(t, id))) == s))
                    .filter(|&id| kind.is_none_or(|k| t.u32(id, M::KIND).and_then(|v| enums::outreach_kind::NAMES.get(v as usize).copied()) == Some(k)))
                    .map(|id| mission_json(rows, &cvs, &seen, t, id))
                    .collect()
            });
            Ok(json!({"missions": list}))
        }
        "mission_brief" => {
            let id = req["mission"].as_u64().and_then(|v| u32::try_from(v).ok()).filter(|v| *v > 0).ok_or_else(|| no(refusal::TYPE, json!({"param": "mission"})))?;
            let t = mission_of(rows, id)?;
            let cvs = Cvs::of(rows);
            let email = is_email(t, id);
            let app = t.u32(id, M::APPLICATION_ID).unwrap_or(0);
            let apps = rows.table(table::APPLICATIONS).filter(|a| a.has(app));
            let corp = apps.and_then(|a| a.u32(app, A::CORPORATION_ID));
            let corp_name = corp.and_then(|c| rows.table(table::CORPORATIONS).and_then(|t| t.str(c, schema::col::corporations::NAME)));
            let contact = t.u32(id, M::CONTACT_ID);
            Ok(json!({
                "mission": mission_json(rows, &cvs, &Seen::of(rows, now), t, id),
                "application": apps.map_or(Json::Null, |a| {
                    let mut j = app_json(a, app);
                    j["corporation"] = json!(corp_name);
                    j
                }),
                "contact_id": contact,
                "kind": t.u32(id, M::KIND).and_then(crate::outreach::Kind::from_code).map(crate::outreach::Kind::name),
                "brief": t.u32(id, M::KIND).and_then(crate::outreach::Kind::from_code).map(crate::outreach::Kind::brief),
                "produces": if email { "an email sent through the linked mailbox, and its replies, filed by the mail" } else { "nothing hireme can see: the shot is yours to perform" },
                "report": if email { "none: the node reports the send (landed or failed)" } else { "once done: landed on the mission (failed, with the reason, if it did not go), then the outreach item its brief describes, naming the mission" },
                "track": if email { "replies arrive on the mission's thread" } else { "a confirmation mail confirms the shot (it stays provisional until one is filed)" },
                "quota": if email { let (cap, used, resets) = quota(rows, now); json!({"cap": cap, "used": used, "resets_at": crate::time_iso(resets)}) } else { Json::Null },
            }))
        }
        "fire_review" => {
            let (scope, request) = match req.get("request").and_then(Json::as_u64) {
                Some(r) => {
                    let r = u32::try_from(r).unwrap_or(0);
                    let t = rows.table(table::FIRE_REQUESTS).filter(|t| t.has(r)).ok_or_else(|| no(refusal::NOT_FOUND, json!({"table": "fire_requests", "id": r})))?;
                    let scope = Ranges::parse(t.str(r, R::MISSIONS).unwrap_or("")).unwrap_or_default();
                    let status = t.u32(r, R::STATUS).and_then(|s| enums::request_status::NAMES.get(s as usize).copied());
                    (scope, json!({"id": r, "missions": t.str(r, R::MISSIONS), "reason": t.str(r, R::REASON), "requested_by": t.u32(r, R::REQUESTED_BY), "status": status}))
                }
                None => {
                    let m = req.get("missions").and_then(Json::as_str).ok_or_else(|| no(refusal::TYPE, json!({"param": "request or missions"})))?;
                    (Ranges::parse(m).map_err(|at| no(refusal::TYPE, json!({"param": "missions", "at": at})))?, Json::Null)
                }
            };
            let mut r = review(rows, &scope);
            r["request"] = request;
            Ok(r)
        }
        "live_keys" => {
            let cvs = Cvs::of(rows);
            let all = req.get("all").and_then(Json::as_bool).unwrap_or(false);
            let keys: Vec<Json> = key_list(rows, now, all).iter().map(|k| key_json(rows, &cvs, k, now)).collect();
            Ok(json!({"keys": keys}))
        }
        "mail_quota" => {
            let (cap, used, resets) = quota(rows, now);
            Ok(json!({"cap": cap, "used": used, "left": cap.saturating_sub(used), "resets_at": crate::time_iso(resets)}))
        }
        other => Err(no(refusal::NOT_FOUND, json!({"method": other}))),
    }
}

/// The tables each read needs.
pub fn reads(op: &str) -> &'static [&'static str] {
    match op {
        "ranges" => &[],
        "mail_quota" => &["missions", "mailboxes"],
        "mission_brief" | "fire_review" => &["missions", "applications"],
        "live_keys" => &["fire_keys", "missions"],
        _ => &["missions"],
    }
}

pub const OPS: [&str; 6] = ["ranges", "missions", "mission_brief", "fire_review", "live_keys", "mail_quota"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_read_canonically_and_refuse_what_they_are_not() {
        for (text, canon) in [
            ("1-44,56-213,444,4413", "1-44,56-213,444,4413"),
            (" 444 , 56-213,1 - 44,4413 ", "1-44,56-213,444,4413"),
            ("3,1,2", "1-3"),
            ("5-9,7-12,13", "5-13"),
            ("7", "7"),
            ("", ""),
        ] {
            assert_eq!(Ranges::parse(text).map(|r| r.text()), Ok(canon.into()), "{text:?}");
        }
        for bad in ["0", "5-3", "1,,2", "a", "1-", "-4", "1 2", "4294967296", "1-2-3", "1,", ","] {
            assert!(Ranges::parse(bad).is_err(), "{bad:?}");
        }
        let r = Ranges::parse("1-44,56-213,444,4413").unwrap();
        for (id, inside) in [(1, true), (44, true), (45, false), (55, false), (56, true), (213, true), (444, true), (445, false), (4413, true), (0, false)] {
            assert_eq!(r.contains(id), inside, "{id}");
        }
        assert_eq!(r.count(), 44 + 158 + 2);
        assert_eq!(Ranges::of([4413, 1, 2, 3, 444]).text(), "1-3,444,4413");
        // The largest id is a range of its own.
        assert_eq!(Ranges::parse("4294967295").unwrap().count(), 1);
    }

    /// Any set of ids: its ranges hold exactly it, and their text reads back
    /// as the same ranges (seeded; the seed and the set on a failure).
    #[test]
    fn ranges_hold_exactly_their_ids_and_round_trip() {
        let mut seed = 0x9e37_79b9_u32;
        let mut next = |n: u32| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed % n
        };
        for case in 0..500 {
            let span = 1 + next(300);
            let ids: Vec<u32> = (0..next(40)).map(|_| 1 + next(span)).collect();
            let r = Ranges::of(ids.iter().copied());
            for id in 0..=span + 1 {
                assert_eq!(r.contains(id), ids.contains(&id), "case {case}: {ids:?} at {id}");
            }
            let mut distinct = ids.clone();
            distinct.sort_unstable();
            distinct.dedup();
            assert_eq!(r.count(), distinct.len() as u64, "case {case}: {ids:?}");
            assert_eq!(Ranges::parse(&r.text()), Ok(r.clone()), "case {case}: {ids:?} as {}", r.text());
        }
    }

    #[test]
    fn times_left_read_as_hours_minutes_seconds() {
        assert_eq!(hms(85_267), "23:41:07");
        assert_eq!(hms(7 * 86_400), "168:00:00");
    }
}
