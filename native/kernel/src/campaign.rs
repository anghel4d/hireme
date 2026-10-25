//! The apply campaign: one application's road from its listing to an
//! outcome, read from what hireme stores (docs/mcp/campaigns.md). Nothing
//! about a campaign is stored: `Facts` are gathered from the rows each time
//! and `step`, a pure function of them, answers the phase the application
//! stands in, at most one ok and one warn line, and exactly one `Next`: an
//! action for the agent, a question for the operator, a wait, or done.
//!
//! Thirteen phases: acquire, link, qualify, route, batch, documents, stage,
//! fire key, fire, confirm, follow-up, reply, close. The first six walk
//! the rail up to draft_ready; then the route's shots (a referral's intro,
//! the primary route, the LinkedIn note) are all staged, one key is asked
//! over them, and they fire in that order, each once the one before it
//! landed. Once anything went out, no new primary is ever routed: a reply
//! filed to the application comes first and stops every timer, then the
//! follow-ups run (a nudge on day 7 and day 14 after the last exchange,
//! ghosted on day 30).
//!
//! `pick` answers the open application closest to done that the agent can
//! move now (its next is an action): the highest phase, then the higher
//! score, then the lower number.

use alloc::collections::BTreeMap;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use schema::col::{applications as A, batches as B, contacts as C, cv_roots, cv_versions, fire_requests as R, missions as M};
use schema::{enums, table};
use serde_json::{json, Value as Json};

use crate::fire::{self, Cvs, Ranges};
use crate::outreach::{Direction, Filing, Item, Kind};
use crate::pipeline::Stage;
use crate::rows::Rows;
use crate::Day;

/// A LinkedIn connection note's length: past it a warning, not a refusal
/// (a message to an existing connection may be longer).
pub const NOTE_MAX: usize = 300;
/// A provisional landing this old with no confirmation filed is a warning.
pub const CONFIRM_HOURS: i64 = 48;
/// The follow-up timers, in days after the last exchange.
pub const NUDGES: [i64; 2] = [7, 14];
pub const GHOSTED: i64 = 30;

// ------------------------------------------------------------------ the phases

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Phase {
    Acquire = 1,
    Link,
    Qualify,
    Route,
    Batch,
    Documents,
    Stage,
    FireKey,
    Fire,
    Confirm,
    FollowUp,
    Reply,
    Close,
}

impl Phase {
    pub const ALL: [Phase; 13] = [
        Phase::Acquire,
        Phase::Link,
        Phase::Qualify,
        Phase::Route,
        Phase::Batch,
        Phase::Documents,
        Phase::Stage,
        Phase::FireKey,
        Phase::Fire,
        Phase::Confirm,
        Phase::FollowUp,
        Phase::Reply,
        Phase::Close,
    ];

    pub fn n(self) -> u8 {
        self as u8
    }

    pub fn name(self) -> &'static str {
        ["acquire", "link", "qualify", "route", "batch", "documents", "stage", "fire-key", "fire", "confirm", "follow-up", "reply", "close"][self as usize - 1]
    }
}

// ------------------------------------------------------------------ the facts

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Channel {
    Listing,
    Referral,
    Recruiter,
    Cold,
    Other,
    Inbound,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Fresh {
    Open,
    Thin,
    Closed,
    Blocked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Gate {
    Pursue,
    Maybe,
    Skip,
}

/// A send the crucible ledger recorded: unsettled until the operator says
/// whether it went out; applied on that day.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Prior {
    Settled,
    Unsettled,
    Applied(Day),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Relation {
    Recruiter,
    HiringManager,
    Engineer,
    Referral,
    Founder,
    Other,
}

/// What a reply reads as, by its words.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Reads {
    Interview,
    Question,
    Assessment,
    AutoReply,
    Rejection,
    Offer,
}

impl Reads {
    pub fn name(self) -> &'static str {
        ["interview", "question", "assessment", "auto-reply", "rejection", "offer"][self as usize]
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MState {
    Draft,
    DraftReady,
    FireReady,
    InFlight,
    Fired,
    Cancelled,
}

/// What a mission is for on the route.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// A referral's introduction, before the application itself.
    Intro,
    /// The application itself.
    Primary,
    /// The LinkedIn note to the recruiter or hiring manager.
    Note,
    /// A follow-up mail after the last exchange.
    Nudge,
    /// The answer to a reply (the outreach item's id).
    Reply(u32),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Contact {
    pub id: u32,
    pub relation: Option<Relation>,
    pub email: Option<String>,
    pub profile: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mission {
    pub id: u32,
    pub kind: Kind,
    pub state: MState,
    pub role: Role,
    pub target: String,
    pub contact: Option<u32>,
    pub draft_len: usize,
    /// Why it cannot fire whoever asks (fire::hold), for one fire_ready.
    pub hold: Option<&'static str>,
    /// The live key covering it.
    pub covered: Option<u32>,
    pub last_error: Option<String>,
    pub provisional: bool,
    /// Unix seconds.
    pub fired: Option<i64>,
    pub message_id: Option<String>,
    /// The inbound item it answers (its In-Reply-To), when it answers one.
    pub answers: Option<u32>,
    /// Its In-Reply-To names a mail the account holds: a reply inside a
    /// thread, which carries no CV (fire::answers).
    pub threaded: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reply {
    /// The outreach item's id.
    pub id: u32,
    pub email: bool,
    pub from: Option<String>,
    pub contact: Option<u32>,
    pub subject: String,
    pub reads: Reads,
    pub seen: bool,
    /// Unix seconds.
    pub at: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub id: u32,
    pub open: bool,
    pub declined: bool,
    /// The application's missions it names.
    pub covers: Vec<u32>,
}

/// Today's day pack: the batch to join, or the one to make.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DayPack {
    Today(u32),
    Make { code: String, ordinal: u32 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Cv {
    /// Pinned on the application (pick_cv), not only the rules' pick.
    pub pinned: bool,
    /// The root the pick names.
    pub root: Option<u32>,
    /// Whether that version is a file (a PDF or DOCX upload).
    pub file: bool,
    /// A root whose newest version is a file, for a first email.
    pub file_root: Option<u32>,
}

/// Everything the route reads about one application.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    pub app: u32,
    pub no: u32,
    pub company: String,
    pub role: String,
    pub score: u32,
    pub today: Day,
    /// Unix seconds.
    pub now: i64,
    pub stage: Stage,
    /// The app_status name; anything but `open` is the operator's hold.
    pub status: &'static str,
    pub outcome: Option<&'static str>,
    /// Whether anything went out (its rail).
    pub sent: bool,
    pub channel: Channel,
    pub listing: bool,
    /// The listing's careers form (an https URL).
    pub form: Option<String>,
    /// The address the listing names, when it names one.
    pub listed: Option<String>,
    /// Whether the listing asks for a cover letter.
    pub letter_asked: bool,
    /// The link diagnosis's first try, when the application is short of one.
    pub link: Option<Json>,
    pub freshness: Option<Fresh>,
    pub gate: Option<Gate>,
    pub prior: Prior,
    /// Over the heat cap until this day.
    pub heat: Option<Day>,
    pub batch: bool,
    pub day_pack: DayPack,
    pub cv: Cv,
    pub letter: bool,
    pub contacts: Vec<Contact>,
    pub missions: Vec<Mission>,
    pub replies: Vec<Reply>,
    pub requests: Vec<Request>,
    pub mailbox: bool,
    /// Today's email cap is used: it resets this day.
    pub cap_reset: Option<Day>,
    pub applied: Option<Day>,
    /// The corporation's domain, for a contact's put.
    pub corp: Option<String>,
}

// ------------------------------------------------------------------ the step

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Ok,
    Warn,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Said {
    pub level: Level,
    pub code: &'static str,
    pub text: String,
}

/// A mission the route wants: what for, of what kind, to whom.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Want {
    pub role: Role,
    pub kind: Kind,
    pub to: To,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum To {
    Form(String),
    Address { addr: String, contact: Option<u32>, reply: Option<u32> },
    Profile(u32),
}

/// What the agent does next: one tool call, typed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Act {
    Capture,
    Link,
    Freshness,
    Stage(Stage),
    Gate,
    Close(&'static str),
    JoinBatch(u32),
    MakeBatch,
    Pin(u32),
    Letter,
    Research,
    Want(Want),
    Ready(u32),
    Mend(u32, &'static str),
    Request(Vec<u32>),
    Fire { mission: u32, key: u32 },
    Report(u32),
    Cancel(u32),
    Ignore(u32),
    Seen(u32),
}

/// What only the operator can answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ask {
    Held,
    Gate,
    Prior,
    Route,
    Cv,
    Key(u32),
    Mailbox,
    /// A reply that names no address or contact to answer it through.
    Sender(u32),
    Assessment(u32),
    Offer(u32),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Next {
    Do(Act),
    Ask(Ask),
    Wait { until: Option<Day>, why: &'static str },
    Done(Option<&'static str>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub phase: Phase,
    pub said: Vec<Said>,
    pub next: Next,
}

/// The step, with at most one ok and one warn line.
struct Build {
    said: Vec<Said>,
}

impl Build {
    fn warn(&mut self, code: &'static str, text: String) {
        if !self.said.iter().any(|s| s.level == Level::Warn) {
            self.said.push(Said { level: Level::Warn, code, text });
        }
    }

    fn ok(&mut self, code: &'static str, text: String) {
        if !self.said.iter().any(|s| s.level == Level::Ok) {
            self.said.insert(0, Said { level: Level::Ok, code, text });
        }
    }

    fn at(self, phase: Phase, next: Next) -> Step {
        Step { phase, said: self.said, next }
    }
}

fn day_of(secs: i64) -> Day {
    (secs.div_euclid(86_400) + crate::UNIX_EPOCH_DAY as i64) as Day
}

/// The want a mission already put stands for.
fn want_of(m: &Mission) -> Want {
    let to = match (m.kind, m.contact) {
        (Kind::CareersPage, _) => To::Form(m.target.clone()),
        (Kind::LinkedIn, Some(c)) => To::Profile(c),
        _ => To::Address { addr: m.target.clone(), contact: m.contact, reply: m.answers },
    };
    Want { role: m.role, kind: m.kind, to }
}

impl Facts {
    /// Whether anything went out: on the rail, or before hireme by the old
    /// ledger's word, which the operator settled as applied.
    pub fn out(&self) -> bool {
        self.sent || matches!(self.prior, Prior::Applied(_))
    }

    fn live(&self) -> impl Iterator<Item = &Mission> {
        self.missions.iter().filter(|m| m.state != MState::Cancelled)
    }

    fn mission(&self, role: Role) -> Option<&Mission> {
        self.live().find(|m| m.role == role)
    }

    /// A target a mission of this kind went to and lost (cancelled).
    fn dead(&self, kind: Kind, target: &str) -> bool {
        self.missions.iter().any(|m| m.state == MState::Cancelled && m.kind == kind && m.target.eq_ignore_ascii_case(target))
    }

    /// It went out only by a primary whose mail bounced: routed again.
    fn bounced(&self) -> bool {
        self.mission(Role::Primary).is_none() && self.missions.iter().any(|m| m.role == Role::Primary && m.last_error.as_deref() == Some("bounced"))
    }

    /// The day it went out: the old ledger's, else its first shot that
    /// landed, else the rail's applied day.
    fn sent_on(&self) -> Option<Day> {
        self.ledger().or_else(|| self.live().filter_map(|m| m.fired.map(day_of)).min()).or(self.applied)
    }

    /// The day the old ledger says it went out, once the operator settled it.
    fn ledger(&self) -> Option<Day> {
        match self.prior {
            Prior::Applied(d) => Some(d),
            _ => None,
        }
    }

    /// Whether a mail the route wants opens a thread (a first contact,
    /// which carries the CV as a file) rather than answering one.
    fn opens_thread(&self, w: &Want) -> bool {
        w.kind == Kind::Email
            && match (&w.to, w.role) {
                (To::Address { reply: Some(_), .. }, _) | (_, Role::Reply(_)) => false,
                (_, Role::Nudge) => self.mission(Role::Primary).and_then(|m| m.message_id.as_ref()).is_none(),
                _ => true,
            }
    }

    /// The route's missions, in the order they go: a referral's intro, the
    /// primary route, the LinkedIn note. A mission already put stands for
    /// its role. Until anything goes out the rest come from the listing,
    /// the channel and the company's contacts; after, only the note, on
    /// the day of the send or the next, and a new primary for one that
    /// bounced.
    pub fn wants(&self) -> Vec<Want> {
        let out = self.out();
        let mut v = Vec::new();
        let has = |c: &Contact, rel: &[Relation]| c.relation.is_some_and(|r| rel.contains(&r));
        if self.channel == Channel::Referral {
            match self.mission(Role::Intro) {
                Some(m) => v.push(want_of(m)),
                None if !out => {
                    if let Some(c) = self.contacts.iter().find(|c| has(c, &[Relation::Referral])) {
                        match &c.email {
                            Some(e) if !self.dead(Kind::Email, e) => v.push(Want { role: Role::Intro, kind: Kind::Email, to: To::Address { addr: e.clone(), contact: Some(c.id), reply: None } }),
                            _ if c.profile => v.push(Want { role: Role::Intro, kind: Kind::LinkedIn, to: To::Profile(c.id) }),
                            _ => {}
                        }
                    }
                }
                None => {}
            }
        }
        let primary = match self.mission(Role::Primary) {
            Some(m) => Some(want_of(m)),
            None if !out || self.bounced() => self.primary_route(),
            None => None,
        };
        let Some(primary) = primary else { return v };
        let to = match &primary.to {
            To::Address { contact, .. } => *contact,
            To::Profile(c) => Some(*c),
            To::Form(_) => None,
        };
        let linkedin = primary.kind == Kind::LinkedIn;
        v.push(primary);
        if !linkedin {
            match self.mission(Role::Note) {
                Some(m) => v.push(want_of(m)),
                None if !out || self.sent_on().is_some_and(|d| self.today <= d + 1) => {
                    if let Some(c) = self.contacts.iter().find(|c| has(c, &[Relation::Recruiter, Relation::HiringManager]) && c.profile && Some(c.id) != to) {
                        v.push(Want { role: Role::Note, kind: Kind::LinkedIn, to: To::Profile(c.id) });
                    }
                }
                None => {}
            }
        }
        v
    }

    /// The primary route the stored state names, when no mission holds it.
    fn primary_route(&self) -> Option<Want> {
        let with = |rel: &[Relation]| {
            self.contacts.iter().find_map(|c| {
                let e = c.email.as_ref()?;
                (c.relation.is_some_and(|r| rel.contains(&r)) && !self.dead(Kind::Email, e)).then(|| Want {
                    role: Role::Primary,
                    kind: Kind::Email,
                    to: To::Address { addr: e.clone(), contact: Some(c.id), reply: None },
                })
            })
        };
        // Whatever the channel, then: the listing's form, the address it
        // names, a recruiter, a hiring manager or founder.
        let fallback = || {
            let form = self.form.as_ref().filter(|u| !self.dead(Kind::CareersPage, u)).map(|u| Want { role: Role::Primary, kind: Kind::CareersPage, to: To::Form(u.clone()) });
            let listed = || self.listed.as_ref().filter(|a| !self.dead(Kind::Email, a)).map(|a| Want { role: Role::Primary, kind: Kind::Email, to: To::Address { addr: a.clone(), contact: None, reply: None } });
            form.or_else(listed).or_else(|| with(&[Relation::Recruiter])).or_else(|| with(&[Relation::HiringManager, Relation::Founder]))
        };
        let first = match self.channel {
            Channel::Inbound => self.replies.iter().filter(|r| r.email).max_by_key(|r| (r.at, r.id)).and_then(|r| {
                let addr = r.from.clone()?;
                (!self.dead(Kind::Email, &addr)).then_some(Want { role: Role::Primary, kind: Kind::Email, to: To::Address { addr, contact: r.contact, reply: Some(r.id) } })
            }),
            Channel::Recruiter => with(&[Relation::Recruiter]),
            Channel::Cold => with(&[Relation::HiringManager, Relation::Founder]),
            Channel::Referral | Channel::Listing | Channel::Other => None,
        };
        first.or_else(fallback)
    }

    /// The address a follow-up goes to, and its contact: the primary
    /// mail's first address, else a recruiter's or hiring manager's.
    fn nudge_to(&self) -> Option<(String, Option<u32>)> {
        let primary = self.mission(Role::Primary).filter(|m| m.kind == Kind::Email).map(|m| (m.target.split(',').next().unwrap_or("").trim().to_string(), m.contact));
        let people = self.contacts.iter().filter(|c| c.relation.is_some_and(|r| matches!(r, Relation::Recruiter | Relation::HiringManager))).filter_map(|c| Some((c.email.clone()?, Some(c.id))));
        primary.into_iter().chain(people).find(|(a, _)| !a.is_empty() && !self.dead(Kind::Email, a))
    }
}

/// The step of one application: its phase, what is said, and the one next.
pub fn step(f: &Facts) -> Step {
    let mut b = Build { said: Vec::new() };
    // 13: closed, or held by the operator.
    if f.stage == Stage::Closed {
        b.ok("closed", alloc::format!("app:{} · {}({})", f.no, if f.out() { "sent" } else { "unsent" }, f.outcome.unwrap_or("closed")));
        return b.at(Phase::Close, Next::Done(f.outcome));
    }
    if f.status != "open" {
        return b.at(Phase::Qualify, Next::Ask(Ask::Held));
    }
    // 1: the listing captured.
    if !f.listing && matches!(f.channel, Channel::Listing | Channel::Other) {
        return b.at(Phase::Acquire, Next::Do(Act::Capture));
    }
    // 2: linked to its company and, unless remote, its place.
    if f.link.is_some() {
        return b.at(Phase::Link, Next::Do(Act::Link));
    }
    // 3: the old ledger's send settled, then qualified while nothing went out.
    if f.prior == Prior::Unsettled {
        return b.at(Phase::Qualify, Next::Ask(Ask::Prior));
    }
    // 9: a shot in flight is reported before anything else moves.
    if let Some(m) = f.live().find(|m| m.state == MState::InFlight) {
        let phase = match m.role {
            Role::Nudge => Phase::FollowUp,
            Role::Reply(_) => Phase::Reply,
            _ => Phase::Fire,
        };
        return b.at(phase, flying(m));
    }
    let out = f.out();
    if !out && let Some((phase, next)) = qualify(f, &mut b) {
        return b.at(phase, next);
    }
    // 12: once anything went out, a reply not yet answered comes first.
    if out && let Some((phase, next)) = reply(f, &mut b) {
        return b.at(phase, next);
    }
    // 4 to 9: the route, until each of its shots has landed; one the old
    // ledger sent has none.
    if !matches!(f.prior, Prior::Applied(_)) {
        let wants = f.wants();
        if !wants.iter().any(|w| w.role == Role::Primary) && (!out || f.bounced()) {
            return b.at(Phase::Route, if f.contacts.is_empty() { Next::Do(Act::Research) } else { Next::Ask(Ask::Route) });
        }
        let list: Vec<(Want, Option<&Mission>)> = wants.iter().map(|w| (w.clone(), f.mission(w.role))).collect();
        let rail = if out { None } else { rail(f, &wants) };
        if let Some((phase, next)) = rail.or_else(|| shots(f, &mut b, &list)) {
            b.ok("routed", route_line(f, &wants));
            return b.at(phase, next);
        }
    }
    // 10 and 11: confirmation and the follow-up timers.
    timers(f, b)
}

/// 3: whether the posting is still open, the fit, then the company's
/// heat; each judgement moved onto the rail as it is made.
fn qualify(f: &Facts, b: &mut Build) -> Option<(Phase, Next)> {
    let q = |next: Next| Some((Phase::Qualify, next));
    if f.listing {
        match f.freshness {
            None => return q(Next::Do(Act::Freshness)),
            Some(Fresh::Closed) => return Some((Phase::Close, Next::Do(Act::Close("expired")))),
            Some(Fresh::Thin) => b.warn("thin", alloc::format!("app:{} reads thin: check the posting is still open before anything goes out", f.no)),
            Some(Fresh::Blocked) => b.warn("blocked", alloc::format!("app:{}'s posting cannot be read: check it by hand before anything goes out", f.no)),
            Some(Fresh::Open) => {}
        }
        if f.stage < Stage::Freshness {
            return q(Next::Do(Act::Stage(Stage::Freshness)));
        }
    }
    match f.gate {
        None => return q(Next::Do(Act::Gate)),
        Some(Gate::Skip) => return Some((Phase::Close, Next::Do(Act::Close("skipped")))),
        Some(Gate::Maybe) => return q(Next::Ask(Ask::Gate)),
        Some(Gate::Pursue) => {}
    }
    if f.stage < Stage::Gated {
        return q(Next::Do(Act::Stage(Stage::Gated)));
    }
    f.heat.and_then(|until| q(Next::Wait { until: Some(until), why: "heat" }))
}

/// 5 and 6: the rail up to draft_ready while nothing went out: today's day
/// pack, in_batch, the CV (a file when a first mail goes), the letter.
fn rail(f: &Facts, wants: &[Want]) -> Option<(Phase, Next)> {
    if f.stage >= Stage::DraftReady {
        return None;
    }
    if !f.batch {
        return Some((Phase::Batch, day_pack(f)));
    }
    if f.stage < Stage::InBatch {
        return Some((Phase::Batch, Next::Do(Act::Stage(Stage::InBatch))));
    }
    if !f.cv.file && wants.iter().any(|w| f.opens_thread(w)) {
        return Some((Phase::Documents, cv_file(f)));
    }
    if !f.cv.pinned {
        return Some((Phase::Documents, f.cv.root.map_or(Next::Ask(Ask::Cv), |r| Next::Do(Act::Pin(r)))));
    }
    if !f.letter && (f.letter_asked || wants.iter().any(|w| w.role == Role::Primary && f.opens_thread(w))) {
        return Some((Phase::Documents, Next::Do(Act::Letter)));
    }
    Some((Phase::Documents, Next::Do(Act::Stage(Stage::DraftReady))))
}

fn day_pack(f: &Facts) -> Next {
    Next::Do(match &f.day_pack {
        DayPack::Today(id) => Act::JoinBatch(*id),
        DayPack::Make { .. } => Act::MakeBatch,
    })
}

/// A first mail carries the CV as a file: pin a root whose newest version
/// is one, or ask for one.
fn cv_file(f: &Facts) -> Next {
    f.cv.file_root.map_or(Next::Ask(Ask::Cv), |r| Next::Do(Act::Pin(r)))
}

/// 7, 8 and 9 for shots that go in order: each staged complete at
/// fire_ready, the application at fire_ready, one key asked over every
/// shot no key covers, then each fired once the one before it landed.
/// None once all have landed.
fn shots(f: &Facts, b: &mut Build, list: &[(Want, Option<&Mission>)]) -> Option<(Phase, Next)> {
    use Phase as P;
    for (w, m) in list {
        let Some(m) = m else { return Some((P::Stage, Next::Do(Act::Want(w.clone())))) };
        if m.kind == Kind::LinkedIn && m.draft_len > NOTE_MAX && matches!(m.state, MState::Draft | MState::DraftReady | MState::FireReady) {
            b.warn("length", alloc::format!("mission:{} is {}/{NOTE_MAX} chars; LinkedIn cuts a connection note at {NOTE_MAX}", m.id, m.draft_len));
        }
        let first_mail = m.kind == Kind::Email && !m.threaded;
        match m.state {
            MState::Draft | MState::DraftReady if first_mail && !f.cv.file => return Some((P::Documents, cv_file(f))),
            MState::Draft | MState::DraftReady => return Some((P::Stage, Next::Do(Act::Ready(m.id)))),
            MState::FireReady if m.last_error.as_deref() == Some("bounced") => return Some((P::Confirm, Next::Do(Act::Cancel(m.id)))),
            MState::FireReady => match m.hold {
                Some("cv_file") => return Some((P::Documents, cv_file(f))),
                Some(h) if !matches!(h, "app_stage" | "unsettled") => return Some((P::Stage, Next::Do(Act::Mend(m.id, h)))),
                _ => {}
            },
            MState::InFlight | MState::Fired | MState::Cancelled => {}
        }
    }
    let m = list.iter().filter_map(|(_, m)| *m).find(|m| matches!(m.state, MState::FireReady | MState::InFlight))?;
    if f.stage < Stage::FireReady {
        return Some(if f.batch { (P::Stage, Next::Do(Act::Stage(Stage::FireReady))) } else { (P::Batch, day_pack(f)) });
    }
    Some(if m.state == MState::InFlight { (P::Fire, flying(m)) } else { fire(f, b, m) })
}

/// A shot in flight: the node reports a mail itself; the agent reports the rest.
fn flying(m: &Mission) -> Next {
    if m.kind == Kind::Email { Next::Wait { until: None, why: "sending" } } else { Next::Do(Act::Report(m.id)) }
}

/// 8 and 9 for one staged shot: its key asked for, or used.
fn fire(f: &Facts, b: &mut Build, m: &Mission) -> (Phase, Next) {
    use Phase as P;
    let Some(key) = m.covered else {
        let asked = || f.requests.iter().filter(|r| r.covers.contains(&m.id));
        if let Some(r) = asked().filter(|r| r.open).max_by_key(|r| r.id) {
            return (P::FireKey, Next::Ask(Ask::Key(r.id)));
        }
        if let Some(r) = asked().max_by_key(|r| r.id).filter(|r| r.declined) {
            b.warn("declined", alloc::format!("fire_request:{} was declined: revise the drafts, then ask again", r.id));
        }
        return (P::FireKey, Next::Do(Act::Request(uncovered(f))));
    };
    if let Some(e) = &m.last_error {
        let then = if m.kind == Kind::Email { "fire it again" } else { "fire it again; a wall you cannot pass goes to the operator to send by hand, then report it landed" };
        b.warn("failed", alloc::format!("mission:{} failed last time ({e}); the key still covers it: {then}", m.id));
    }
    if m.kind == Kind::Email && !f.mailbox {
        (P::Fire, Next::Ask(Ask::Mailbox))
    } else if m.kind == Kind::Email && f.cap_reset.is_some() {
        (P::Fire, Next::Wait { until: f.cap_reset, why: "cap" })
    } else {
        (P::Fire, Next::Do(Act::Fire { mission: m.id, key }))
    }
}

/// The application's fire_ready missions no live key covers and no open
/// request names: what one request asks for.
fn uncovered(f: &Facts) -> Vec<u32> {
    let asked: Vec<u32> = f.requests.iter().filter(|r| r.open).flat_map(|r| r.covers.iter().copied()).collect();
    let mut ids: Vec<u32> = f.live().filter(|m| m.state == MState::FireReady && m.covered.is_none() && !asked.contains(&m.id) && m.hold.is_none_or(|h| matches!(h, "app_stage" | "unsettled"))).map(|m| m.id).collect();
    ids.sort_unstable();
    ids
}

/// A shot's phase inside a later one: its stage, key and fire are that phase's.
fn within(phase: Phase, of: Phase) -> Phase {
    if matches!(phase, Phase::Stage | Phase::FireKey | Phase::Fire) { of } else { phase }
}

/// 12: the newest reply neither seen nor answered by a shot that landed,
/// by what it reads as.
fn reply(f: &Facts, b: &mut Build) -> Option<(Phase, Next)> {
    let answered = |r: &Reply| f.missions.iter().any(|m| m.answers == Some(r.id) && m.state == MState::Fired);
    let r = f.replies.iter().filter(|r| !r.seen && !answered(r)).max_by_key(|r| (r.at, r.id))?;
    b.ok("filed", alloc::format!("outreach:{} → app:{} reads as: {}", r.id, f.no, r.reads.name()));
    if r.reads == Reads::AutoReply {
        return Some((Phase::Reply, Next::Do(Act::Ignore(r.id))));
    }
    if f.stage == Stage::Submitted {
        return Some((Phase::Reply, Next::Do(Act::Stage(Stage::Reply))));
    }
    Some(match r.reads {
        Reads::Rejection => (Phase::Close, Next::Do(Act::Close("rejected"))),
        Reads::Offer => (Phase::Reply, Next::Ask(Ask::Offer(r.id))),
        Reads::Assessment => (Phase::Reply, Next::Ask(Ask::Assessment(r.id))),
        Reads::AutoReply | Reads::Interview | Reads::Question => {
            let to = match (&r.from, r.contact) {
                (Some(a), _) if r.email && !f.dead(Kind::Email, a) => To::Address { addr: a.clone(), contact: r.contact, reply: Some(r.id) },
                (_, Some(c)) if f.contacts.iter().any(|x| x.id == c && x.profile) => To::Profile(c),
                _ => return Some((Phase::Reply, Next::Ask(Ask::Sender(r.id)))),
            };
            let w = Want { role: Role::Reply(r.id), kind: if matches!(to, To::Profile(_)) { Kind::LinkedIn } else { Kind::Email }, to };
            let m = f.mission(w.role);
            shots(f, b, &[(w, m)]).map_or((Phase::Reply, Next::Do(Act::Seen(r.id))), |(phase, next)| (within(phase, Phase::Reply), next))
        }
    })
}

/// 10 and 11: a self-reported landing left unconfirmed, a follow-up staged
/// and not yet landed, the follow-ups due after the last exchange, and
/// ghosted on day 30.
fn timers(f: &Facts, mut b: Build) -> Step {
    if let Some(m) = f.mission(Role::Primary).filter(|m| m.provisional && m.fired.is_some_and(|t| f.now - t > CONFIRM_HOURS * 3600)) {
        b.warn("unconfirmed", alloc::format!("mission:{} landed {} h ago and no confirmation mail is filed; check spam, or the page's reference stands", m.id, (f.now - m.fired.unwrap_or(f.now)) / 3600));
    }
    if let Some(m) = f.live().find(|m| m.role == Role::Nudge && m.state != MState::Fired)
        && let Some((phase, next)) = shots(f, &mut b, &[(want_of(m), Some(m))])
    {
        return b.at(within(phase, Phase::FollowUp), next);
    }
    let since = last_exchange(f);
    let days = i64::from(f.today - since);
    if days >= GHOSTED {
        return b.at(Phase::Close, Next::Do(Act::Close("ghosted")));
    }
    let nudged = f.missions.iter().filter(|m| m.role == Role::Nudge && m.fired.is_some_and(|t| day_of(t) >= since)).count();
    let next = match (f.nudge_to(), NUDGES.get(nudged)) {
        (Some((addr, contact)), Some(&d)) if days >= d => Next::Do(Act::Want(Want { role: Role::Nudge, kind: Kind::Email, to: To::Address { addr, contact, reply: None } })),
        (Some(_), Some(&d)) => Next::Wait { until: Some(since + d as Day), why: "follow-up" },
        _ => Next::Wait { until: Some(since + GHOSTED as Day), why: "follow-up" },
    };
    b.at(Phase::FollowUp, next)
}

/// The day of the last exchange: a shot that landed (a follow-up does not
/// count), a reply seen, or the send (the old ledger's day over the rail's,
/// which a follow-up's landing writes).
fn last_exchange(f: &Facts) -> Day {
    let landed = f.live().filter(|m| m.role != Role::Nudge).filter_map(|m| m.fired.map(day_of));
    let seen = f.replies.iter().filter(|r| r.seen).map(|r| day_of(r.at));
    landed.chain(seen).chain(f.ledger().or(f.applied)).max().unwrap_or(f.today)
}

/// The ok line once the route is known.
fn route_line(f: &Facts, wants: &[Want]) -> String {
    let mut parts: Vec<String> = Vec::new();
    for w in wants {
        let what = match (&w.role, &w.to) {
            (Role::Intro, _) => alloc::format!("{} intro first", w.kind.name()),
            (_, To::Form(u)) => alloc::format!("{} ({})", w.kind.name(), crate::ats::parse(u).vendor.name()),
            (Role::Note, To::Profile(c)) => alloc::format!("linkedin follow-up (contact:{c})"),
            (_, To::Address { addr, .. }) => alloc::format!("{} to {addr}", w.kind.name()),
            (_, To::Profile(c)) => alloc::format!("{} (contact:{c})", w.kind.name()),
        };
        parts.push(what);
    }
    alloc::format!("app:{} → {}", f.no, parts.join(" + "))
}

// ------------------------------------------------------------------ the answer

fn app_ref(f: &Facts) -> String {
    alloc::format!("app:{}", f.no)
}

fn iso(d: Day) -> String {
    crate::day_iso(d)
}

/// The tool call an act is, in the tools' own grammar: rows named by refs.
fn call(f: &Facts, act: &Act) -> (&'static str, Json, String) {
    let app = app_ref(f);
    match act {
        Act::Capture => ("put", json!({"ref": app, "set": {"listing_url": "<the posting's URL>", "listing_raw": "<the posting's full text>"}}), "capture the listing: its URL and its text as the page shows them".into()),
        Act::Link => {
            let t = f.link.clone().unwrap_or(Json::Null);
            let tool = match t["tool"].as_str() {
                Some("put") => "put",
                _ => "find",
            };
            (tool, t["args"].clone(), alloc::format!("confirm the company (and place) in the world, then put corporation_id and place_id on {app}; a link is never guessed"))
        }
        Act::Freshness => ("put", json!({"ref": app, "set": {"freshness": "<open|thin|closed|blocked>"}}), "open the listing: is the posting still open?".into()),
        Act::Stage(s) => ("stage", json!({"ref": app, "stage": s.name()}), alloc::format!("move {app} to {}", s.name())),
        Act::Gate => ("put", json!({"ref": app, "set": {"gate": "<pursue|maybe|skip>"}}), "judge the fit: pursue, maybe (the operator decides) or skip".into()),
        Act::Close(o) => ("stage", json!({"ref": app, "stage": "closed", "outcome": o}), alloc::format!("close {app} as {}({o})", if f.out() { "sent" } else { "unsent" })),
        Act::JoinBatch(b) => ("put", json!({"ref": app, "set": {"batch_id": alloc::format!("batch:{b}")}}), "join today's day pack: the rail needs a batch before in_batch".into()),
        Act::MakeBatch => {
            let (code, ordinal) = match &f.day_pack {
                DayPack::Make { code, ordinal } => (code.clone(), *ordinal),
                DayPack::Today(_) => (String::new(), 0),
            };
            ("put", json!({"table": "batches", "set": {"code": code, "ordinal": ordinal, "kind": "day_pack", "queued_on": iso(f.today)}}), "today's day pack does not exist yet: make it, then join it".into())
        }
        Act::Pin(root) => ("pick_cv", json!({"ref": app, "cv_root_id": root}), if f.cv.file { "confirm the CV the rules picked".into() } else { "a first email carries the CV as a file: pin a PDF or DOCX".into() }),
        Act::Letter => ("put", json!({"ref": app, "set": {"letter_raw": "<the letter: why this role, what you bring>"}}), "write the letter the route carries (an email's body, a form's letter field)".into()),
        Act::Research => (
            "put",
            json!({"table": "contacts", "set": {"name": "<a person at the company>", "corporation_id": f.corp.as_ref().map(|d| alloc::format!("corp:{d}")), "relation": "<recruiter|hiring_manager|founder>", "email": "<their address>", "linkedin_url": "<their profile>"}}),
            alloc::format!("no route to apply at {}: find its careers form or a person to write to", f.company),
        ),
        Act::Want(w) => ("put", mission_args(f, w), want_why(f, w)),
        Act::Ready(m) => ("put", json!({"ref": alloc::format!("mission:{m}"), "set": {"state": "fire_ready"}}), "fire_ready freezes what the key will fire".into()),
        Act::Mend(m, hold) => {
            let set = match *hold {
                "recipients" => json!({"cc": "<fewer addresses: 10 in To and Cc together>"}),
                _ => json!({"draft": "<the full draft>", "target": "<its route>"}),
            };
            ("put", json!({"ref": alloc::format!("mission:{m}"), "set": set}), alloc::format!("mission:{m} cannot fire yet ({hold}): complete it"))
        }
        Act::Request(ids) => {
            let range = Ranges::of(ids.iter().copied()).text();
            let kinds: Vec<&str> = f.live().filter(|m| ids.contains(&m.id)).map(|m| m.kind.name()).collect();
            (
                "request_fire_key",
                json!({"missions": range, "reason": alloc::format!("{} · {}: {}", f.company, f.role, kinds.join(", ")).chars().take(280).collect::<String>()}),
                "ask the operator for a fire key covering exactly these missions".into(),
            )
        }
        Act::Fire { mission, key } => {
            let kind = f.missions.iter().find(|m| m.id == *mission).map_or(Kind::Other, |m| m.kind);
            let how = match kind {
                Kind::Email => "the node sends it through Gmail",
                Kind::CareersPage => "fill and submit the form once, then report",
                _ => "send it once, then report",
            };
            ("fire", json!({"ref": alloc::format!("mission:{mission}"), "key": key}), alloc::format!("lease {app} first; {how}"))
        }
        Act::Report(m) => {
            let kind = f.missions.iter().find(|x| x.id == *m).map_or(Kind::Other, |x| x.kind);
            let args = match kind {
                Kind::CareersPage => json!({"mission": alloc::format!("mission:{m}"), "reference": "<the page's confirmation number>", "fields": {"<field>": "<what you entered>"}, "report": "<what happened, markdown>"}),
                _ => json!({"mission": alloc::format!("mission:{m}"), "body": "<the text you sent>", "link": "<the conversation>", "report": "<what happened, markdown>"}),
            };
            ("report", args, "the shot is in flight: report how it went (outcome failed with the reason if it did not go)".into())
        }
        Act::Cancel(m) => ("put", json!({"ref": alloc::format!("mission:{m}"), "set": {"state": "cancelled"}}), alloc::format!("mission:{m}'s address bounced: cancel it and route again without it")),
        Act::Ignore(r) => ("ignore", json!({"ref": alloc::format!("outreach:{r}")}), "an automatic reply: file it as ignored; the timers keep running".into()),
        Act::Seen(r) => ("put", json!({"ref": alloc::format!("outreach:{r}"), "set": {"seen": true}}), "the reply is answered: mark it seen".into()),
    }
}

/// A new mission, in the mission union's grammar.
fn mission_args(f: &Facts, w: &Want) -> Json {
    let mut a = json!({"ref": "mission:new", "kind": w.kind.name(), "app": app_ref(f)});
    match &w.to {
        To::Form(u) => {
            a["form"] = json!(u);
            a["draft"] = json!("<every field's text, markdown>");
        }
        To::Address { addr, contact, reply } => {
            a["to"] = json!(addr);
            if let Some(c) = contact {
                a["contact"] = json!(alloc::format!("contact:{c}"));
            }
            match (*reply, w.role) {
                (Some(r), _) | (_, Role::Reply(r)) => {
                    a["in_reply_to"] = json!(alloc::format!("outreach:{r}"));
                    a["subject"] = json!(f.replies.iter().find(|x| x.id == r).map_or_else(|| "Re: ".to_string(), |x| if x.subject.to_ascii_lowercase().starts_with("re:") { x.subject.clone() } else { alloc::format!("Re: {}", x.subject) }));
                }
                (None, Role::Nudge) => {
                    if let Some(id) = f.mission(Role::Primary).and_then(|m| m.message_id.clone()) {
                        a["in_reply_to"] = json!(id);
                    }
                    a["subject"] = json!(alloc::format!("Re: {}", f.role));
                }
                _ => a["subject"] = json!(alloc::format!("{} application", f.role)),
            }
            a["draft"] = json!(match w.role {
                Role::Nudge => "<a short follow-up: still keen, one new detail>",
                Role::Reply(_) => "<the answer: for an interview, two or three times>",
                _ => "<the letter>",
            });
        }
        To::Profile(c) => {
            a["contact"] = json!(alloc::format!("contact:{c}"));
            a["draft"] = json!(alloc::format!("<Hey {{first}}! I'm {{me}}, {{short intro}}, {{prior work}}. Just applied to {} at {}. (≤{NOTE_MAX} chars)>", f.role, f.company));
        }
    }
    a
}

fn want_why(f: &Facts, w: &Want) -> String {
    match w.role {
        Role::Intro => "a referral: the introduction to the referrer goes first".into(),
        Role::Primary => alloc::format!("stage the application itself: one {} mission", w.kind.name()),
        Role::Note => alloc::format!("a LinkedIn note to the recruiter, sent on day 0–1 after the application; from me and the corpus items that best match the listing (≤{NOTE_MAX} chars)"),
        Role::Nudge => alloc::format!("no reply since the last exchange: a short follow-up for {}", app_ref(f)),
        Role::Reply(r) => alloc::format!("answer outreach:{r}"),
    }
}

/// What the operator is asked.
fn ask_text(f: &Facts, a: &Ask) -> (String, String) {
    let app = app_ref(f);
    let (ask, why) = match a {
        Ask::Held => (alloc::format!("{app} is {}: resume it (status open) or close it", f.status), "the operator holds it"),
        Ask::Gate => (alloc::format!("{app} is gated maybe: pursue it or skip it? (gate pursue|skip)"), "the fit is the operator's call"),
        Ask::Prior => (alloc::format!("the old ledger says {app} was already applied to: did it go out? (prior_send applied or not_applied)"), "no double applications"),
        Ask::Route => (alloc::format!("no route to apply at {}: a careers form, an address or a person to write to?", f.company), "the company's contacts give none"),
        Ask::Cv => (alloc::format!("no CV to send with {app}: upload one (a PDF or DOCX for a first email)"), "a first email carries the CV as a file"),
        Ask::Key(r) => (alloc::format!("approve the fire key for {app}: /fire/{r}"), "only the operator makes a fire key; stop here until it is granted"),
        Ask::Mailbox => ("link Gmail (Account → Mail) so the mail can go".into(), "no live mailbox"),
        Ask::Sender(r) => (alloc::format!("outreach:{r} names no address or contact to answer through: link its sender's contact, or mark it seen once answered by hand"), "hireme cannot reach the sender"),
        Ask::Assessment(r) => (alloc::format!("outreach:{r} is an assessment for {app}: take it (then mark it seen) or decline (close {app} withdrawn)?"), "the operator's own work"),
        Ask::Offer(r) => (alloc::format!("outreach:{r} reads as an offer for {app}: accept (close it offer) or decline (close it declined)?"), "the operator's decision"),
    };
    (ask, why.into())
}

/// The step as the MCP renders it (docs/mcp/campaigns.md).
pub fn json(f: &Facts, s: &Step) -> Json {
    let said: Vec<Json> = s.said.iter().map(|x| json!({"level": if x.level == Level::Ok { "ok" } else { "warn" }, "code": x.code, "text": x.text})).collect();
    let next = match &s.next {
        Next::Do(act) => {
            let (tool, args, why) = call(f, act);
            json!({"kind": "do", "tool": tool, "args": args, "why": why})
        }
        Next::Ask(a) => {
            let (ask, why) = ask_text(f, a);
            json!({"kind": "ask", "ask": ask, "why": why})
        }
        Next::Wait { until, why } => {
            let text = match *why {
                "heat" => alloc::format!("the company's heat is over its cap; nothing on {} until then, or the operator overrides", app_ref(f)),
                "cap" => "today's 25 mails are out; the cap resets tomorrow".into(),
                "sending" => "the node is sending the mail; it reports the outcome itself".into(),
                _ => alloc::format!("nothing due on {} today", app_ref(f)),
            };
            json!({"kind": "wait", "until": until.map(iso), "why": text})
        }
        Next::Done(o) => json!({"kind": "done", "why": alloc::format!("closed {}", o.unwrap_or(""))}),
    };
    json!({
        "application": {"id": f.app, "no": f.no, "company": f.company, "role": f.role, "stage": f.stage.name()},
        "phase": {"n": s.phase.n(), "name": s.phase.name()},
        "said": said,
        "next": next,
    })
}

// ------------------------------------------------------------------ reading the rows

/// What a reply reads as, by its words, in this order: an automatic reply,
/// a rejection, an offer, an assessment, an interview; else a question.
pub fn reads_as(text: &str) -> Reads {
    let line = crate::filer::words(text);
    let has = |phrases: &[&str]| phrases.iter().any(|p| alloc::format!(" {line} ").contains(&alloc::format!(" {p} ")));
    if has(&["out of office", "automatic reply", "auto reply", "autoreply", "this is an automated", "do not reply", "thank you for applying", "thanks for applying", "we have received your application", "we received your application", "application received"]) {
        Reads::AutoReply
    } else if has(&["unfortunately", "not moving forward", "not be moving forward", "other candidates", "regret to inform", "position has been filled", "decided not to proceed", "not to proceed", "not a fit"]) {
        Reads::Rejection
    } else if has(&["offer letter", "pleased to offer", "happy to offer", "extend an offer", "job offer", "an offer"]) {
        Reads::Offer
    } else if has(&["assessment", "take home", "coding challenge", "hackerrank", "codility", "codesignal", "technical test", "online test", "test task"]) {
        Reads::Assessment
    } else if has(&["interview", "schedule a call", "your availability", "availability", "set up a call", "book a time", "calendly", "phone screen", "speak with you", "a quick call", "a call"]) {
        Reads::Interview
    } else {
        Reads::Question
    }
}

/// What a page of steps reads once: the missions, replies and contacts by
/// the row they belong to, the requests, today's day pack, the CV roots.
pub struct Index<'r> {
    rows: &'r Rows,
    cvs: Cvs,
    missions: BTreeMap<u32, Vec<u32>>,
    items: BTreeMap<u32, Vec<Item>>,
    contacts: BTreeMap<u32, Vec<u32>>,
    requests: Vec<(u32, u32, Ranges)>,
    day_pack: DayPack,
    file_root: Option<u32>,
    mailbox: bool,
    cap_reset: Option<Day>,
    today: Day,
    now: i64,
}

impl<'r> Index<'r> {
    pub fn of(rows: &'r Rows, today: Day, now: i64) -> Index<'r> {
        let mut missions: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
        for (t, id) in rows.each(table::MISSIONS) {
            if let Some(a) = t.u32(id, M::APPLICATION_ID) {
                missions.entry(a).or_default().push(id);
            }
        }
        let mut items: BTreeMap<u32, Vec<Item>> = BTreeMap::new();
        if let Some(t) = rows.table(table::OUTREACH) {
            for &id in t.ids() {
                if let Some(item) = Item::read(t, id)
                    && let Some(a) = item.core.refs.application_id
                {
                    items.entry(a).or_default().push(item);
                }
            }
        }
        let mut contacts: BTreeMap<u32, Vec<u32>> = BTreeMap::new();
        for (t, id) in rows.each(table::CONTACTS) {
            if let Some(c) = t.u32(id, C::CORPORATION_ID) {
                contacts.entry(c).or_default().push(id);
            }
        }
        let requests = rows.each(table::FIRE_REQUESTS).map(|(t, id)| (id, t.u32(id, R::STATUS).unwrap_or(0), Ranges::parse(t.str(id, R::MISSIONS).unwrap_or("")).unwrap_or_default())).collect();
        // Today's day pack, else the one to make.
        let mut ordinal = 0;
        let mut today_pack = None;
        let code = alloc::format!("D-{}", crate::day_iso(today));
        let mut taken: Vec<String> = Vec::new();
        for (t, id) in rows.each(table::BATCHES) {
            ordinal = ordinal.max(t.u32(id, B::ORDINAL).unwrap_or(0));
            taken.push(t.str(id, B::CODE).unwrap_or("").to_string());
            let pack = t.u32(id, B::KIND) == Some(u32::from(enums::batch_kind::DAY_PACK));
            let open = t.u32(id, B::STATUS).is_none_or(|s| s == u32::from(enums::batch_status::DRAFT_PREP));
            if pack && open && t.u32(id, B::QUEUED_ON) == Some(today as u32) {
                today_pack = today_pack.or(Some(id));
            }
        }
        let code = (1..).map(|n| if n == 1 { code.clone() } else { alloc::format!("{code}-{n}") }).find(|c| !taken.contains(c)).unwrap_or(code);
        let day_pack = today_pack.map_or(DayPack::Make { code, ordinal: ordinal + 1 }, DayPack::Today);
        let file_root = rows.each(table::CV_ROOTS).find_map(|(t, id)| {
            let v = t.u32(id, cv_roots::VERSION_ID)?;
            rows.table(table::CV_VERSIONS).and_then(|vt| vt.str(v, cv_versions::BLOB_SHA)).filter(|s| !s.is_empty()).map(|_| id)
        });
        let (cap, used, resets) = fire::quota(rows, now);
        Index {
            rows,
            cvs: Cvs::of(rows),
            missions,
            items,
            contacts,
            requests,
            day_pack,
            file_root,
            mailbox: fire::mailbox_live(rows),
            cap_reset: (used >= cap).then(|| day_of(resets)),
            today,
            now,
        }
    }

    /// One application's facts; `heat` is the day its company's heat lets
    /// it go, when it is over the cap now.
    pub fn facts(&self, app: u32, heat: Option<Day>) -> Option<Facts> {
        let rows = self.rows;
        let t = rows.table(table::APPLICATIONS).filter(|t| t.has(app))?;
        let s = |c: u16| t.str(app, c).unwrap_or("").to_string();
        let code = |c: u16| t.u32(app, c);
        let name = |c: u16, names: &'static [&'static str]| code(c).and_then(|v| names.get(v as usize).copied());
        let stage = code(A::STAGE).and_then(Stage::from_u32).unwrap_or(Stage::Discovered);
        let listing_raw = t.text(app, A::LISTING_RAW).unwrap_or_default();
        let listing_url = s(A::LISTING_URL);
        let channel = match name(A::CHANNEL, enums::app_channel::NAMES) {
            Some("referral") => Channel::Referral,
            Some("recruiter") => Channel::Recruiter,
            Some("cold") => Channel::Cold,
            Some("other") => Channel::Other,
            Some("inbound") => Channel::Inbound,
            _ => Channel::Listing,
        };
        let corp = code(A::CORPORATION_ID);
        let short = crate::link::missing(corp, code(A::PLACE_ID), code(A::WORK_MODE));
        let link = (!short.is_empty()).then(|| {
            let d = crate::link::diagnosis(rows, app, &short, &s(A::COMPANY), &s(A::LOCATION), Some(listing_url.as_str()).filter(|u| !u.is_empty()));
            d["try"].get(0).cloned().unwrap_or(Json::Null)
        });
        let prior = match name(A::PRIOR_SEND, enums::prior_send::NAMES) {
            Some("applied") => Prior::Applied(fire::ledger_day(t, app).unwrap_or(self.today)),
            _ if fire::unsettled(t, app) => Prior::Unsettled,
            _ => Prior::Settled,
        };
        let pick = self.cvs.pick(rows, app);
        let file_version = |v: Option<u32>| v.and_then(|v| rows.table(table::CV_VERSIONS).and_then(|vt| vt.str(v, cv_versions::BLOB_SHA))).is_some_and(|s| !s.is_empty());
        let cv = Cv { pinned: pick.state == crate::pick::State::Pinned, root: pick.root, file: file_version(pick.version), file_root: self.file_root };
        let listed = crate::filer::lex(&listing_raw).into_iter().find(|tk| tk.class == crate::filer::Class::Address).map(|tk| tk.text);
        let words = crate::filer::words(&listing_raw);
        let letter_asked = ["cover letter", "motivation letter", "anschreiben", "lettre de motivation"].iter().any(|p| alloc::format!(" {words} ").contains(&alloc::format!(" {p} ")));
        let form = Some(listing_url.clone()).filter(|u| fire::target(Kind::CareersPage, u).is_ok());
        let contacts: Vec<Contact> = corp
            .and_then(|c| self.contacts.get(&c))
            .map(|ids| {
                let ct = rows.table(table::CONTACTS);
                ids.iter()
                    .map(|&id| Contact {
                        id,
                        relation: ct.and_then(|ct| ct.u32(id, C::RELATION)).map(|r| match r as u8 {
                            enums::relation::RECRUITER => Relation::Recruiter,
                            enums::relation::HIRING_MANAGER => Relation::HiringManager,
                            enums::relation::ENGINEER => Relation::Engineer,
                            enums::relation::REFERRAL => Relation::Referral,
                            enums::relation::FOUNDER => Relation::Founder,
                            _ => Relation::Other,
                        }),
                        email: ct.and_then(|ct| ct.str(id, C::EMAIL)).and_then(crate::outreach::addr),
                        profile: ct.and_then(|ct| ct.str(id, C::LINKEDIN_URL)).and_then(fire::linkedin_profile).is_some(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        let replies = self.replies(app);
        let missions = self.missions(app, &contacts);
        let requests = self
            .requests
            .iter()
            .filter_map(|(id, status, r)| {
                let covers: Vec<u32> = missions.iter().map(|m| m.id).filter(|m| r.contains(*m)).collect();
                (!covers.is_empty()).then(|| Request { id: *id, open: *status == u32::from(enums::request_status::OPEN), declined: *status == u32::from(enums::request_status::DECLINED), covers })
            })
            .collect();
        Some(Facts {
            app,
            no: code(A::NO).unwrap_or(app),
            company: s(A::COMPANY),
            role: s(A::ROLE),
            score: code(A::SCORE_100).unwrap_or(0),
            today: self.today,
            now: self.now,
            stage,
            status: name(A::STATUS, enums::app_status::NAMES).unwrap_or("open"),
            outcome: name(A::OUTCOME, enums::outcome::NAMES),
            sent: crate::board::sent(t, app),
            channel,
            listing: !listing_raw.trim().is_empty() || !listing_url.is_empty(),
            form,
            listed,
            letter_asked,
            link,
            freshness: name(A::FRESHNESS, enums::freshness::NAMES).map(|f| match f {
                "thin" => Fresh::Thin,
                "closed" => Fresh::Closed,
                "blocked" => Fresh::Blocked,
                _ => Fresh::Open,
            }),
            gate: name(A::GATE, enums::gate::NAMES).map(|g| match g {
                "maybe" => Gate::Maybe,
                "skip" => Gate::Skip,
                _ => Gate::Pursue,
            }),
            prior,
            heat,
            batch: code(A::BATCH_ID).is_some(),
            day_pack: self.day_pack.clone(),
            cv,
            letter: t.text(app, A::LETTER_RAW).is_some_and(|l| !l.trim().is_empty()),
            contacts,
            missions,
            replies,
            requests,
            mailbox: self.mailbox,
            cap_reset: self.cap_reset,
            applied: code(A::APPLIED_ON).map(|d| d as Day),
            corp: corp.and_then(|c| rows.table(table::CORPORATIONS).and_then(|t| t.str(c, schema::col::corporations::DOMAIN))).map(String::from),
        })
    }

    /// The replies filed to an application: inbound items not ignored.
    fn replies(&self, app: u32) -> Vec<Reply> {
        self.items
            .get(&app)
            .map(|items| {
                items
                    .iter()
                    .filter(|i| i.core.direction == Some(Direction::Inbound) && i.core.filing == Filing::Filed && i.core.kind != Kind::Note)
                    .map(|i| {
                        let input = i.input();
                        let subject = i.core.subject.clone().unwrap_or_default();
                        Reply {
                            id: i.core.id,
                            email: i.core.kind == Kind::Email,
                            from: Some(input.from).filter(|f| !f.is_empty()).and_then(crate::outreach::addr),
                            contact: i.core.refs.contact_id,
                            reads: reads_as(&alloc::format!("{subject} {}", i.core.body.as_deref().unwrap_or(""))),
                            subject,
                            seen: i.core.seen,
                            at: i.core.at,
                        }
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// An application's missions with their roles: an answer to a reply,
    /// a referral's intro, the LinkedIn note, a follow-up mail after the
    /// primary landed, else the primary (the first by id).
    fn missions(&self, app: u32, contacts: &[Contact]) -> Vec<Mission> {
        let rows = self.rows;
        let Some(t) = rows.table(table::MISSIONS) else { return Vec::new() };
        let ids = self.missions.get(&app).cloned().unwrap_or_default();
        let mut reply_ids: BTreeMap<String, u32> = BTreeMap::new();
        for i in self.items.get(&app).into_iter().flatten().filter(|i| i.core.direction == Some(Direction::Inbound)) {
            let id = i.input().message_id;
            if !id.is_empty() {
                reply_ids.insert(crate::filer::canonical_id(id), i.core.id);
            }
        }
        let relation = |c: Option<u32>| c.and_then(|c| contacts.iter().find(|x| x.id == c)).and_then(|c| c.relation);
        let mut out: Vec<Mission> = ids
            .iter()
            .map(|&id| {
                let kind = t.u32(id, M::KIND).and_then(Kind::from_code).unwrap_or(Kind::Other);
                let state = match t.u32(id, M::STATE).unwrap_or(0) as u8 {
                    enums::mission_state::DRAFT_READY => MState::DraftReady,
                    enums::mission_state::FIRE_READY => MState::FireReady,
                    enums::mission_state::IN_FLIGHT => MState::InFlight,
                    enums::mission_state::FIRED => MState::Fired,
                    enums::mission_state::CANCELLED => MState::Cancelled,
                    _ => MState::Draft,
                };
                let contact = t.u32(id, M::CONTACT_ID);
                let answers = t.str(id, M::IN_REPLY_TO).map(crate::filer::canonical_id).and_then(|r| reply_ids.get(&r).copied());
                let role = match () {
                    _ if relation(contact) == Some(Relation::Referral) => Role::Intro,
                    _ if kind == Kind::LinkedIn && matches!(relation(contact), Some(Relation::Recruiter | Relation::HiringManager)) => Role::Note,
                    _ => Role::Primary,
                };
                Mission {
                    id,
                    kind,
                    state,
                    role,
                    target: t.str(id, M::TARGET).unwrap_or("").to_string(),
                    contact,
                    draft_len: t.text(id, M::DRAFT).map_or(0, |d| d.chars().count()),
                    hold: (state == MState::FireReady).then(|| fire::hold(rows, &self.cvs, id)).flatten(),
                    covered: (state == MState::FireReady).then(|| fire::covering(rows, &self.cvs, id, self.now)).flatten(),
                    last_error: t.text(id, M::LAST_ERROR).map(|e| e.into_owned()),
                    provisional: t.u32(id, M::CONFIRMATION) == Some(u32::from(enums::confirmation::PROVISIONAL)),
                    fired: t.u32(id, M::FIRED_AT).map(i64::from),
                    message_id: t.str(id, M::MESSAGE_ID).map(String::from),
                    answers,
                    threaded: t.str(id, M::IN_REPLY_TO).is_some_and(|v| fire::answers(rows, v)),
                }
            })
            .collect();
        out.sort_by_key(|m| m.id);
        // The first live mission that is no intro or note is the primary (an
        // inbound recruiter's first answer is one); a later one answering a
        // reply is that reply's, any other later one a follow-up.
        let mut primary = false;
        for m in out.iter_mut().filter(|m| m.role == Role::Primary) {
            if !primary && m.state != MState::Cancelled {
                primary = true;
            } else if let Some(item) = m.answers {
                m.role = Role::Reply(item);
            } else if m.state != MState::Cancelled || primary {
                m.role = Role::Nudge;
            }
        }
        out
    }
}

/// The `campaign` read: one application's step (`{"application": id}` or
/// `{"no": n}`), or the step of the one `pick` chooses (`{}`).
pub fn query(rows: &Rows, req: &Json, today: Day, now: i64, heat: &dyn Fn(u32) -> Option<Day>) -> Result<Json, crate::judge::Refusal> {
    let ix = Index::of(rows, today, now);
    let apps = rows.table(table::APPLICATIONS);
    let by_no = |n: u64| apps.and_then(|t| t.ids().iter().copied().find(|&id| t.u32(id, A::NO).map(u64::from) == Some(n)));
    let target = req
        .get("application")
        .and_then(Json::as_u64)
        .and_then(|v| u32::try_from(v).ok())
        .or_else(|| req.get("no").and_then(Json::as_u64).and_then(by_no));
    match target {
        Some(id) => {
            let f = ix.facts(id, heat(id)).ok_or_else(|| crate::judge::no(schema::refusal::NOT_FOUND, json!({"table": "applications", "id": id})))?;
            Ok(json(&f, &step(&f)))
        }
        None if req.get("application").is_some() || req.get("no").is_some() => Err(crate::judge::no(schema::refusal::NOT_FOUND, json!({"table": "applications"}))),
        None => {
            let open = apps.map(|t| t.ids().len()).unwrap_or(0);
            match pick(&ix, heat) {
                Some((f, s)) => {
                    let mut j = json(&f, &s);
                    j["picked"] = json!({"in_play": open});
                    Ok(j)
                }
                None => Ok(json!({"application": null, "phase": null, "said": [{"level": "ok", "code": "idle", "text": "no application can move now: every open one waits on the operator or a date"}], "next": {"kind": "wait", "until": null, "why": "nothing to do"}})),
            }
        }
    }
}

/// The open application closest to done that the agent can move now: the
/// highest phase whose next is an action, then the higher score, then the
/// lower number.
pub fn pick(ix: &Index, heat: &dyn Fn(u32) -> Option<Day>) -> Option<(Facts, Step)> {
    let t = ix.rows.table(table::APPLICATIONS)?;
    let mut best: Option<(Facts, Step)> = None;
    for &id in t.ids() {
        let open = t.u32(id, A::STATUS).is_none_or(|s| s == u32::from(enums::app_status::OPEN));
        if !open || t.u32(id, A::STAGE) == Some(u32::from(enums::stage::CLOSED)) {
            continue;
        }
        let Some(f) = ix.facts(id, heat(id)) else { continue };
        let s = step(&f);
        if !matches!(s.next, Next::Do(_)) {
            continue;
        }
        let key = |f: &Facts, s: &Step| (s.phase, f.score, core::cmp::Reverse(f.no));
        if best.as_ref().is_none_or(|(bf, bs)| key(&f, &s) > key(bf, bs)) {
            best = Some((f, s));
        }
    }
    best
}
