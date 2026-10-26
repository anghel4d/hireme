//! The apply campaign's route graph, walked whole (docs/mcp/campaigns.md).
//! A fresh application is driven from its first step to its close by a
//! model of what each answered call does in the kernel, across every route
//! shape (channel, what the listing names, the company's people) crossed
//! with the CV on file, the old ledger's word, how the key and the first
//! shot go, and what the company sends back; qualify's own variations,
//! which nothing after them reads, rotate through those walks. Every step
//! must say at most one ok and one warn line and name one next that the
//! kernel takes (a stage move the rail allows, a mission it stages, a close
//! in the outcome split), every next must move the state, none may come
//! back, and every walk must end closed.

mod fixture;

use std::collections::{BTreeMap, BTreeSet};

use kernel::campaign::{json, reads_as, step, Act, Ask, Channel, Contact, Cv, DayPack, Facts, Fresh, Gate, Level, MState, Mission, Next, Prior, Reads, Relation, Reply, Request, Role, To, Want};
use kernel::outreach::Kind;
use kernel::pipeline::{self, Stage};
use serde_json::Value as Json;

const D0: i32 = 739_528;
const DAY: i64 = 86_400;
const FORM: &str = "https://job-boards.greenhouse.io/acme/jobs/1";
const KEY: u32 = 51;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Listed {
    Form,
    Address,
    Nothing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum People {
    None,
    Recruiter,
    Referral,
    HiringManager,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cvs {
    /// The rules pick a PDF.
    File,
    /// The rules pick a text CV; another root is a file.
    Text,
    /// No CV at all until the operator uploads one.
    Missing,
    /// Roots, a PDF among them, that no rule picks.
    Unpicked,
}

/// The old ledger's word on a send before hireme.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Ledger {
    Silent,
    WentOut,
    DidNot,
}

/// What the company does once something lands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Script {
    Silence,
    Rejection,
    InterviewThenOffer,
    AutoReply,
    Assessment,
    /// The primary's mail bounces the next day, when an interview request
    /// comes from another address.
    Bounce,
    /// A rejection crosses the next shot that goes out after the first.
    Crossing,
}

/// Qualify's variations: each changes what qualify says and asks, and
/// nothing after it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Qual {
    Plain,
    Hot,
    Thin,
    Maybe,
    Unsettled,
}

#[derive(Clone, Copy, Debug)]
struct World {
    channel: Channel,
    listed: Listed,
    people: People,
    fresh: Fresh,
    gate: Gate,
    /// The operator's answer to a maybe.
    pursue: bool,
    ledger: Ledger,
    hot: bool,
    cv: Cvs,
    /// The operator declines the first key request.
    decline: bool,
    /// The operator revokes the first key before its shot goes.
    revoke: bool,
    /// The company runs hot once the shot is staged, until the key is in hand.
    hot_late: bool,
    /// The first shot fails (a form that walls, a mail the server defers).
    fail: bool,
    script: Script,
}

impl World {
    fn of(channel: Channel, listed: Listed, people: People) -> World {
        World { channel, listed, people, fresh: Fresh::Open, gate: Gate::Pursue, pursue: true, ledger: Ledger::Silent, hot: false, cv: Cvs::File, decline: false, revoke: false, hot_late: false, fail: false, script: Script::Silence }
    }

    fn qual(self, q: Qual) -> World {
        match q {
            Qual::Plain => self,
            Qual::Hot => World { hot: true, ..self },
            Qual::Thin => World { fresh: Fresh::Thin, ..self },
            Qual::Maybe => World { gate: Gate::Maybe, ..self },
            Qual::Unsettled if self.ledger == Ledger::Silent => World { ledger: Ledger::DidNot, ..self },
            Qual::Unsettled => self,
        }
    }
}

/// The model: the facts the step reads, and what the world does next.
struct Sim {
    w: World,
    f: Facts,
    ids: u32,
    declined: bool,
    revoked: bool,
    heated: bool,
    failed: bool,
    bounced: bool,
    /// Replies on their way, by the day they arrive.
    due: Vec<(i32, Reads)>,
    /// The primary's bounce: its day and mission.
    bounce: Option<(i32, u32)>,
    uploaded: bool,
}

fn posting(f: &mut Facts, listed: Listed) {
    f.listing = true;
    f.form = (listed == Listed::Form).then(|| FORM.to_string());
    f.listed = (listed == Listed::Address).then(|| "jobs@acme.example".to_string());
}

fn start(w: World) -> Sim {
    let person = |id: u32, relation, profile| Contact { id, relation: Some(relation), email: Some(format!("p{id}@acme.example")), profile };
    let contacts = match w.people {
        People::None => vec![],
        People::Recruiter => vec![person(9, Relation::Recruiter, true)],
        People::Referral => vec![person(7, Relation::Referral, false), person(8, Relation::HiringManager, false)],
        People::HiringManager => vec![person(8, Relation::HiringManager, true)],
    };
    let cv = match w.cv {
        Cvs::File => Cv { pinned: false, chosen: true, root: Some(1), file: true, file_root: Some(1), newest: Some(1) },
        Cvs::Text => Cv { pinned: false, chosen: true, root: Some(1), file: false, file_root: Some(2), newest: Some(2) },
        Cvs::Missing => Cv::default(),
        Cvs::Unpicked => Cv { pinned: false, chosen: false, root: None, file: false, file_root: Some(2), newest: Some(2) },
    };
    let mut f = Facts {
        app: 1,
        no: 412,
        company: "Acme".into(),
        role: "Staff Engineer".into(),
        score: 80,
        today: D0,
        now: i64::from(D0 - kernel::UNIX_EPOCH_DAY) * DAY + 43_200,
        stage: Stage::Discovered,
        status: "open",
        outcome: None,
        sent: false,
        channel: w.channel,
        listing: false,
        form: None,
        listed: None,
        letter_asked: false,
        link: Some(serde_json::json!({"tool": "find", "args": {"table": "corporations", "where": {"domain": "acme.example"}}})),
        freshness: None,
        gate: None,
        prior: if w.ledger == Ledger::Silent { Prior::Settled } else { Prior::Unsettled },
        heat: w.hot.then_some(D0 + 3),
        batch: false,
        day_pack: DayPack::Make { code: "D-0".into(), ordinal: 4 },
        cv,
        letter: false,
        contacts,
        missions: vec![],
        replies: vec![],
        requests: vec![],
        mailbox: true,
        domain_from: false,
        applied: None,
        corp: Some("acme.example".into()),
    };
    // A listing is captured by the agent; a person's lead comes with what it names.
    if !matches!(w.channel, Channel::Listing | Channel::Other) && w.listed != Listed::Nothing {
        posting(&mut f, w.listed);
    }
    if w.channel == Channel::Inbound {
        f.replies.push(Reply { id: 500, email: true, from: Some("talent@acme.example".into()), contact: None, subject: "Your profile".into(), reads: Reads::Question, seen: false, at: f.now - DAY });
    }
    Sim { w, f, ids: 30, declined: false, revoked: false, heated: false, failed: false, bounced: false, due: vec![], bounce: None, uploaded: false }
}

impl Sim {
    fn id(&mut self) -> u32 {
        self.ids += 1;
        self.ids
    }

    fn m(&mut self, id: u32) -> Result<&mut Mission, String> {
        self.f.missions.iter_mut().find(|m| m.id == id).ok_or_else(|| format!("no mission:{id}"))
    }

    fn rail(&self) -> pipeline::Facts {
        pipeline::Facts { has_batch: self.f.batch, sent: self.f.sent, outreach: self.f.channel != Channel::Listing }
    }

    fn is_file(&self, root: u32) -> bool {
        match root {
            1 => self.w.cv == Cvs::File,
            2 => matches!(self.w.cv, Cvs::Text | Cvs::Unpicked),
            _ => self.uploaded,
        }
    }

    /// What the company sends back, counted from day `a`.
    fn script(&mut self, a: i32) {
        self.due = match self.w.script {
            Script::Silence | Script::Crossing => vec![],
            Script::Bounce => vec![(a + 1, Reads::Interview)],
            Script::Rejection => vec![(a + 5, Reads::Rejection)],
            Script::InterviewThenOffer => vec![(a + 3, Reads::Interview), (a + 10, Reads::Offer)],
            Script::AutoReply => vec![(a, Reads::AutoReply), (a + 20, Reads::Rejection)],
            Script::Assessment => vec![(a + 4, Reads::Assessment), (a + 12, Reads::Rejection)],
        };
    }

    /// Whatever is due by today arrives: replies, filed to the application,
    /// and the primary's bounce, which sends it back to fire_ready (fire::bounced).
    fn arrive(&mut self) {
        let today = self.f.today;
        let (now, later): (Vec<_>, Vec<_>) = self.due.iter().partition(|(d, _)| *d <= today);
        self.due = later;
        for (d, reads) in now {
            let id = self.id();
            self.f.replies.push(Reply { id, email: true, from: Some("talent@acme.example".into()), contact: None, subject: "Re: Staff Engineer".into(), reads, seen: false, at: i64::from(d - kernel::UNIX_EPOCH_DAY) * DAY + 43_200 });
        }
        if let Some((_, id)) = self.bounce.filter(|(d, _)| *d <= today) {
            self.bounce = None;
            self.bounced = true;
            if let Ok(m) = self.m(id)
                && m.state == MState::Fired
            {
                m.state = MState::FireReady;
                m.last_error = Some("bounced".into());
            }
        }
    }

    fn pass(&mut self, day: i32) -> Result<(), String> {
        if day <= self.f.today {
            return Err(format!("a wait until day {day} on day {}", self.f.today));
        }
        self.f.now += i64::from(day - self.f.today) * DAY;
        self.f.today = day;
        self.f.day_pack = DayPack::Make { code: format!("D-{}", day - D0), ordinal: 5 };
        // Keys live a day from their first use.
        for m in &mut self.f.missions {
            m.covered = None;
        }
        self.arrive();
        Ok(())
    }

    /// A shot's outcome: the first fails if the world says so (fire::failed:
    /// back to fire_ready, still covered), else it lands.
    fn outcome(&mut self, id: u32) -> Result<(), String> {
        if self.w.fail && !self.failed {
            self.failed = true;
            let m = self.m(id)?;
            m.state = MState::FireReady;
            m.last_error = Some(if m.kind == Kind::Email { "421 try later".into() } else { "the form walled".into() });
            m.covered = Some(KEY);
            return Ok(());
        }
        let (now, today) = (self.f.now, self.f.today);
        let m = self.m(id)?;
        m.state = MState::Fired;
        m.fired = Some(now);
        m.provisional = m.kind != Kind::Email;
        if m.kind == Kind::Email {
            m.message_id = Some(format!("hm.{id}@hireme.example"));
        }
        let primary_mail = m.role == Role::Primary && m.kind == Kind::Email;
        // The first landing submits the application (judge's landed).
        if self.f.stage < Stage::Submitted {
            self.f.stage = Stage::Submitted;
            self.f.applied = Some(today);
        }
        if !self.f.sent {
            self.f.sent = true;
            self.script(today);
        }
        if primary_mail && self.w.script == Script::Bounce && !self.bounced {
            self.bounce = Some((today + 1, id));
        }
        Ok(())
    }

    fn close(&mut self, o: &'static str) -> Result<(), String> {
        // The split reads the rail: whether a submission or a reply is on it.
        let allowed: &[&str] = if self.f.sent { &["offer", "rejected", "ghosted", "withdrawn", "declined"] } else { &["expired", "skipped", "withdrawn"] };
        if !allowed.contains(&o) {
            return Err(format!("the outcome split refuses {o} (sent: {})", self.f.sent));
        }
        if self.f.missions.iter().any(|m| m.state == MState::InFlight) {
            return Err("closed with a shot in flight".into());
        }
        pipeline::check(self.f.stage, Stage::Closed, self.rail()).map_err(|e| format!("the rail refuses closed: {}", e.name()))?;
        self.f.stage = Stage::Closed;
        self.f.outcome = Some(o);
        Ok(())
    }

    fn want(&mut self, want: &Want) -> Result<(), String> {
        let Want { role, kind, to } = want.clone();
        let primary_id = self.f.missions.iter().find(|m| m.role == Role::Primary && m.state != MState::Cancelled).and_then(|m| m.message_id.clone());
        let (target, contact, reply) = match to {
            To::Form(u) => (u, None, None),
            To::Address { addr, contact, reply } => (addr, contact, reply),
            To::Profile(c) => {
                if !self.f.contacts.iter().any(|x| x.id == c && x.profile) {
                    return Err(format!("contact:{c} has no profile to send to"));
                }
                (String::new(), Some(c), None)
            }
        };
        if !target.is_empty() {
            kernel::fire::target(kind, &target).map_err(|e| format!("{} target {target}: {e}", kind.name()))?;
        }
        let lost = |m: &Mission| m.state == MState::Cancelled || m.last_error.as_deref() == Some("bounced");
        if self.f.missions.iter().any(|m| lost(m) && m.kind == kind && !target.is_empty() && m.target == target) {
            return Err(format!("a mission to {target}, which bounced"));
        }
        let answers = reply.or(match role {
            Role::Reply(r) => Some(r),
            _ => None,
        });
        let threaded = answers.is_some() || (role == Role::Nudge && primary_id.is_some());
        let id = self.id();
        self.f.missions.push(Mission { id, kind, state: MState::Draft, role, target, contact, draft_len: 200, domain: kind == Kind::Email && self.f.channel == Channel::Cold, hold: None, covered: None, revoked: false, last_error: None, provisional: false, fired: None, message_id: None, answers, threaded });
        Ok(())
    }

    fn act(&mut self, act: &Act) -> Result<(), String> {
        let w = self.w;
        match act {
            Act::Capture => posting(&mut self.f, w.listed),
            Act::Link => self.f.link = None,
            Act::Freshness => self.f.freshness = Some(w.fresh),
            Act::Gate => self.f.gate = Some(w.gate),
            Act::Stage(to) => {
                pipeline::check(self.f.stage, *to, self.rail()).map_err(|e| format!("the rail refuses {:?} -> {to:?}: {}", self.f.stage, e.name()))?;
                self.f.stage = *to;
            }
            Act::Close(o) => self.close(o)?,
            Act::MakeBatch => self.f.day_pack = DayPack::Today(96),
            Act::JoinBatch(b) => {
                if self.f.batch || self.f.day_pack != DayPack::Today(*b) {
                    return Err(format!("joins batch:{b} that is not today's, or a second batch"));
                }
                self.f.batch = true;
            }
            Act::Pin(root) => {
                self.f.cv = Cv { pinned: true, chosen: true, root: Some(*root), file: self.is_file(*root), ..self.f.cv };
                let file = self.f.cv.file;
                for m in self.f.missions.iter_mut().filter(|m| m.state == MState::FireReady) {
                    m.hold = (m.kind == Kind::Email && !m.threaded && !file).then_some("cv_file");
                }
            }
            Act::Letter => self.f.letter = true,
            Act::Research => self.f.contacts.push(Contact { id: 11, relation: Some(Relation::Recruiter), email: Some("p11@acme.example".into()), profile: false }),
            Act::Want(want) => self.want(want)?,
            Act::Ready(id) => {
                let file = self.f.cv.file;
                let m = self.m(*id)?;
                if m.kind == Kind::Email && !m.threaded && !file {
                    return Err(format!("the put refuses mission:{id} fire_ready: cv_file"));
                }
                m.state = MState::FireReady;
            }
            Act::Mend(id, hold) => return Err(format!("mission:{id} mended for {hold}, a hold the model never makes")),
            Act::Request(ids) => {
                if ids.is_empty() {
                    return Err("a request that names no mission".into());
                }
                for id in ids {
                    let m = self.m(*id)?;
                    if m.state != MState::FireReady || m.covered.is_some() || m.last_error.as_deref() == Some("bounced") {
                        return Err(format!("a request names mission:{id}, {:?}, covered {:?}, {:?}", m.state, m.covered, m.last_error));
                    }
                }
                let id = self.id();
                self.f.requests.push(Request { id, open: true, declined: false, covers: ids.clone() });
                if self.w.hot_late && !self.heated {
                    self.heated = true;
                    self.f.heat = Some(self.f.today + 2);
                }
            }
            Act::Fire { mission, key } => {
                if self.f.stage < Stage::FireReady {
                    return Err("fired below fire_ready (app_stage)".into());
                }
                let file = self.f.cv.file;
                let m = self.m(*mission)?;
                if m.kind == Kind::CareersPage && !file {
                    return Err(format!("mission:{mission}'s form goes without a CV file"));
                }
                if m.state != MState::FireReady || m.covered != Some(*key) || m.hold.is_some() {
                    return Err(format!("fire refuses mission:{mission}: {:?}, covered {:?}, held {:?}", m.state, m.covered, m.hold));
                }
                m.state = MState::InFlight;
                m.covered = None;
                m.last_error = None;
                if w.script == Script::Crossing && self.f.sent && !self.f.replies.iter().any(|r| r.reads == Reads::Rejection) {
                    let (id, at) = (self.id(), self.f.now);
                    self.f.replies.push(Reply { id, email: true, from: Some("talent@acme.example".into()), contact: None, subject: "Re: Staff Engineer".into(), reads: Reads::Rejection, seen: false, at });
                }
            }
            Act::Report(id) => {
                let m = self.m(*id)?;
                if m.state != MState::InFlight || m.kind == Kind::Email {
                    return Err(format!("report on mission:{id} {:?} {}", m.state, m.kind.name()));
                }
                self.outcome(*id)?;
            }
            Act::Cancel(id) => {
                let m = self.m(*id)?;
                if m.state != MState::FireReady {
                    return Err(format!("cancel on mission:{id} {:?}", m.state));
                }
                m.state = MState::Cancelled;
            }
            // Filed as ignored: no longer a reply to the application.
            Act::Ignore(r) => self.f.replies.retain(|x| x.id != *r),
            Act::Seen(r) => self.f.replies.iter_mut().filter(|x| x.id == *r).for_each(|x| x.seen = true),
        }
        Ok(())
    }

    fn ask(&mut self, a: &Ask) -> Result<(), String> {
        match a {
            Ask::Held | Ask::Mailbox => return Err(format!("{a:?}: the model never holds or unlinks")),
            // The operator sets the domain address a cold email goes out as.
            Ask::DomainFrom => {
                if self.f.domain_from {
                    return Err("asked for the domain address while it is set".into());
                }
                self.f.domain_from = true;
            }
            Ask::Gate => self.f.gate = Some(if self.w.pursue { Gate::Pursue } else { Gate::Skip }),
            Ask::Prior => {
                if self.w.ledger == Ledger::WentOut {
                    // The word records the send: submitted on the ledger's day.
                    self.f.prior = Prior::Applied(D0 - 3);
                    self.f.stage = self.f.stage.max(Stage::Submitted);
                    self.f.applied = self.f.applied.or(Some(D0 - 3));
                    self.f.sent = true;
                    self.script(D0 - 3);
                    self.arrive();
                } else {
                    self.f.prior = Prior::Settled;
                }
            }
            Ask::Route => self.f.form = Some("https://acme.example/careers/staff".into()),
            Ask::Cv => {
                if self.f.cv.file_root.is_some() {
                    return Err("asked for a CV while a PDF root is there to pin".into());
                }
                self.uploaded = true;
                self.f.cv = Cv { pinned: false, chosen: true, root: Some(3), file: true, file_root: Some(3), newest: Some(3) };
            }
            Ask::Key(r) => {
                let decline = self.w.decline && !self.declined;
                let req = self.f.requests.iter_mut().find(|x| x.id == *r).ok_or("no such request")?;
                if !req.open {
                    return Err(format!("fire_request:{r} asked again once answered"));
                }
                req.open = false;
                req.declined = decline;
                if decline {
                    self.declined = true;
                } else {
                    let covers = req.covers.clone();
                    let revoke = self.w.revoke && !self.revoked;
                    self.revoked |= revoke;
                    for m in self.f.missions.iter_mut().filter(|m| covers.contains(&m.id)) {
                        // Granted, then revoked before the shot went: the key is dead, the shot's row remembers it.
                        if revoke { m.revoked = true } else { m.covered = Some(KEY) }
                    }
                }
            }
            // The operator's no, lifted by the operator: they have the agent ask again.
            Ask::Revoked(m) => {
                if self.f.missions.iter().any(|x| x.id == *m && x.covered.is_some()) || self.f.requests.iter().any(|r| r.open) {
                    return Err(format!("revoked asked for mission:{m} while a key covers it or a request is open"));
                }
                let id = self.id();
                self.f.requests.push(Request { id, open: true, declined: false, covers: vec![*m] });
            }
            Ask::Declined(r) => {
                let covers = self.f.requests.iter().find(|x| x.id == *r && x.declined).map(|x| x.covers.clone());
                let Some(covers) = covers.filter(|_| !self.f.requests.iter().any(|x| x.open)) else {
                    return Err(format!("declined asked for fire_request:{r} that is not the declined one, or while one is open"));
                };
                let id = self.id();
                self.f.requests.push(Request { id, open: true, declined: false, covers });
            }
            Ask::ByHand(id) => {
                // Sent by hand; the agent records it: fired under its key, reported landed.
                let m = self.m(*id)?;
                if m.state != MState::FireReady || m.covered.is_none() || m.kind == Kind::Email {
                    return Err(format!("by hand on mission:{id}: {:?}, covered {:?}, {}", m.state, m.covered, m.kind.name()));
                }
                m.state = MState::InFlight;
                m.covered = None;
                m.last_error = None;
                self.outcome(*id)?;
            }
            Ask::Sender(r) | Ask::Assessment(r) => self.f.replies.iter_mut().filter(|x| x.id == *r).for_each(|x| x.seen = true),
            Ask::Offer(_) => self.close("offer")?,
        }
        Ok(())
    }

    fn wait(&mut self, until: Option<i32>, why: &str) -> Result<(), String> {
        match why {
            "heat" => {
                self.f.heat = None;
                self.pass(until.ok_or("a heat wait names no day")?)
            }
            "sending" => {
                let id = self.f.missions.iter().find(|m| m.state == MState::InFlight && m.kind == Kind::Email).ok_or("waits on a mail that is not sending")?.id;
                self.outcome(id)
            }
            "nudge" | "ghosted" => {
                let day = until.ok_or("a follow-up wait names no day")?;
                // What arrives before the timer comes first.
                let first = self.due.iter().map(|r| r.0).chain(self.bounce.map(|b| b.0)).filter(|d| *d < day).min();
                self.pass(first.map_or(day, |d| d.max(self.f.today + 1)))
            }
            other => Err(format!("a wait the model has no world for: {other}")),
        }
    }
}

/// The answer's grammar: one next of one kind, with what that kind carries.
fn grammar(j: &Json) -> Result<(), String> {
    let n = j["phase"]["n"].as_u64().unwrap_or(0);
    let next = &j["next"];
    let ok = (1..=13).contains(&n)
        && match next["kind"].as_str() {
            Some("do") => next["tool"].is_string() && next["args"].is_object() && next["why"].is_string() && next["ask"].is_null(),
            Some("ask") => next["ask"].as_str().is_some_and(|a| !a.is_empty()) && next["tool"].is_null(),
            Some("wait") => next["why"].is_string() && next["tool"].is_null(),
            Some("done") => next["tool"].is_null(),
            _ => false,
        };
    if ok { Ok(()) } else { Err(format!("an answer out of grammar: {j}")) }
}

/// A next's kind and variant: "Do Want", "Ask Key", "Wait", "Done".
fn variant(next: &Next) -> String {
    match next {
        Next::Do(a) => format!("Do {}", format!("{a:?}").split(['(', ' ', '{']).next().unwrap_or("")),
        Next::Ask(a) => format!("Ask {}", format!("{a:?}").split(['(', ' ', '{']).next().unwrap_or("")),
        Next::Wait { .. } => "Wait".into(),
        Next::Done(_) => "Done".into(),
    }
}

/// One walk: the variants of next it took and how it closed, or where it broke.
fn walk(w: World) -> Result<(Vec<String>, Option<&'static str>), String> {
    let mut sim = start(w);
    let mut trail: Vec<String> = Vec::new();
    let mut taken = Vec::new();
    let mut seen: Vec<(Facts, bool, bool, bool, bool, bool, usize)> = Vec::new();
    let tail = |t: &[String]| t[t.len().saturating_sub(12)..].join("\n  ");
    for _ in 0..300 {
        let s = step(&sim.f);
        let said = |level| s.said.iter().filter(|x| x.level == level).count();
        if said(Level::Ok) > 1 || said(Level::Warn) > 1 {
            return Err(format!("{:?} says {:?}", s.next, s.said));
        }
        grammar(&json(&sim.f, &s))?;
        trail.push(format!("day {} {} {:?}", sim.f.today - D0, s.phase.name(), s.next));
        taken.push(variant(&s.next));
        let state = (sim.f.clone(), sim.declined, sim.revoked, sim.heated, sim.failed, sim.bounced, sim.due.len());
        if seen.contains(&state) {
            return Err(format!("a state came back:\n  {}", tail(&trail)));
        }
        seen.push(state);
        let before = sim.f.clone();
        let moved = match &s.next {
            Next::Done(o) => return Ok((taken, *o)),
            Next::Do(a) => sim.act(a),
            Next::Ask(a) => sim.ask(a),
            Next::Wait { until, why } => sim.wait(*until, why),
        };
        moved.map_err(|e| format!("{e}\n  {}", tail(&trail)))?;
        sim.arrive();
        if sim.f == before {
            return Err(format!("moved nothing:\n  {}", tail(&trail)));
        }
    }
    Err(format!("no close within 300 steps:\n  {}", tail(&trail)))
}

#[test]
fn every_route_ends_closed() {
    let channels = [Channel::Listing, Channel::Other, Channel::Referral, Channel::Recruiter, Channel::Cold, Channel::Inbound];
    let quals = [Qual::Plain, Qual::Hot, Qual::Thin, Qual::Maybe, Qual::Unsettled];
    let scripts = [Script::Silence, Script::Rejection, Script::InterviewThenOffer, Script::AutoReply, Script::Assessment, Script::Bounce, Script::Crossing];
    let mut walks = 0;
    let mut closes: BTreeMap<&str, usize> = BTreeMap::new();
    let mut nexts: BTreeSet<String> = BTreeSet::new();
    let mut run = |w: World, walks: &mut usize| {
        let (taken, outcome) = walk(w).unwrap_or_else(|e| panic!("{w:?}\n{e}"));
        *closes.entry(outcome.unwrap_or("none")).or_default() += 1;
        nexts.extend(taken);
        *walks += 1;
    };
    for channel in channels {
        for listed in [Listed::Form, Listed::Address, Listed::Nothing] {
            for people in [People::None, People::Recruiter, People::Referral, People::HiringManager] {
                let base = World::of(channel, listed, people);
                // The walks qualify ends.
                run(World { fresh: Fresh::Closed, ..base }, &mut walks);
                run(World { gate: Gate::Skip, ..base }, &mut walks);
                run(World { gate: Gate::Maybe, pursue: false, ..base }, &mut walks);
                for cv in [Cvs::File, Cvs::Text, Cvs::Missing, Cvs::Unpicked] {
                    for (decline, fail, revoke, hot_late) in [(false, false, false, false), (true, true, false, false), (false, false, true, true)] {
                        for script in scripts {
                            for ledger in [Ledger::Silent, Ledger::WentOut] {
                                let w = World { cv, decline, fail, revoke, hot_late, script, ledger, ..base }.qual(quals[walks % quals.len()]);
                                run(w, &mut walks);
                            }
                        }
                    }
                }
            }
        }
    }
    assert_eq!(walks, 6 * 3 * 4 * (3 + 4 * 3 * scripts.len() * 2));
    for outcome in ["expired", "skipped", "rejected", "ghosted", "offer"] {
        assert!(closes.contains_key(outcome), "no walk closed {outcome}: {closes:?}");
    }
    // Every branch the model has a world for was taken.
    for v in ["Capture", "Link", "Freshness", "Gate", "Stage", "Close", "MakeBatch", "JoinBatch", "Pin", "Letter", "Research", "Want", "Ready", "Request", "Fire", "Report", "Cancel", "Ignore"] {
        assert!(nexts.contains(&format!("Do {v}")), "no walk did {v}: {nexts:?}");
    }
    for v in ["Gate", "Prior", "Route", "Cv", "Key", "Revoked", "Declined", "ByHand", "Assessment", "Offer"] {
        assert!(nexts.contains(&format!("Ask {v}")), "no walk asked {v}: {nexts:?}");
    }
}

#[test]
fn an_answer_is_one_call_in_the_tools_grammar() {
    let w = World { script: Script::InterviewThenOffer, ..World::of(Channel::Listing, Listed::Form, People::Recruiter) };
    let mut sim = start(w);
    let mut tools = BTreeSet::new();
    for _ in 0..200 {
        let s = step(&sim.f);
        let j = json(&sim.f, &s);
        assert_eq!((j["application"]["no"].as_u64(), j["phase"]["name"].as_str()), (Some(412), Some(s.phase.name())));
        let next = &j["next"];
        if next["kind"] == "do" {
            let tool = next["tool"].as_str().unwrap().to_string();
            let args = &next["args"];
            // Rows are named by refs, never by raw ids.
            for k in ["id", "application_id", "mission_id", "to"] {
                assert!(args.get(k).is_none() || (tool == "put" && k == "to"), "{tool} {args}");
            }
            match tool.as_str() {
                "stage" => assert!(args["ref"] == "app:412" && args["stage"].is_string(), "{args}"),
                "request_fire_key" if !tools.contains("request_fire_key") => assert_eq!(args["missions"], "31-32", "one key over the application and its note"),
                "fire" => assert!(args["ref"].as_str().unwrap().starts_with("mission:") && args["key"] == KEY, "{args}"),
                "put" if args["ref"] == "mission:new" => assert_eq!(args["app"], "app:412"),
                _ => {}
            }
            tools.insert(tool);
        }
        if let Next::Ask(Ask::Key(r)) = s.next {
            assert!(next["ask"].as_str().unwrap().contains(&format!("/fire/{r}")), "{next}");
        }
        let moved = match &s.next {
            Next::Done(o) => {
                assert_eq!(*o, Some("offer"));
                break;
            }
            Next::Do(a) => sim.act(a),
            Next::Ask(a) => sim.ask(a),
            Next::Wait { until, why } => sim.wait(*until, why),
        };
        moved.unwrap();
        sim.arrive();
    }
    for tool in ["find", "put", "stage", "pick_cv", "request_fire_key", "fire", "report"] {
        assert!(tools.contains(tool), "{tool} never asked: {tools:?}");
    }
}

#[test]
fn a_follow_up_wait_says_what_its_day_is() {
    // The first follow-up wait of a walk, as the answer words it.
    let first = |w: World| {
        let mut sim = start(w);
        for _ in 0..300 {
            let s = step(&sim.f);
            if let Next::Wait { until, why: "nudge" | "ghosted" } = s.next {
                return (json(&sim.f, &s)["next"]["why"].as_str().unwrap().to_string(), until.map(|u| u - sim.f.today));
            }
            match &s.next {
                Next::Do(a) => sim.act(a),
                Next::Ask(a) => sim.ask(a),
                Next::Wait { until, why } => sim.wait(*until, why),
                Next::Done(_) => panic!("closed before any follow-up"),
            }
            .unwrap();
            sim.arrive();
        }
        panic!("no follow-up wait");
    };
    let routed = World::of(Channel::Listing, Listed::Form, People::Recruiter);
    assert_eq!(first(routed), ("the day-7 nudge to p9@acme.example is due".into(), Some(7)));
    let nobody = World::of(Channel::Listing, Listed::Form, People::None);
    assert_eq!(first(nobody), ("no reply by then closes it as ghosted (no address on file to nudge)".into(), Some(30)));
}

#[test]
fn a_reply_reads_as_its_words() {
    for (text, want) in [
        ("Automatic reply: I am out of office until Monday", Reads::AutoReply),
        ("Thanks for applying to Acme! We have received your application.", Reads::AutoReply),
        ("After careful consideration we will not be moving forward; unfortunately", Reads::Rejection),
        ("We are pleased to offer you the role", Reads::Offer),
        ("Please complete the HackerRank coding challenge by Friday", Reads::Assessment),
        ("Could you share your availability for an interview next week?", Reads::Interview),
        ("What is your notice period?", Reads::Question),
    ] {
        assert_eq!(reads_as(text), want, "{text}");
    }
}

// ------------------------------------------------------------------ through the kernel

use fixture::{TODAY, cmd, put, q};
use kernel::abi::Kernel;
use kernel::judge::Ctx;

/// The API key the agent writes under.
const AGENT: u32 = 3;

/// Application 7 (app:412) at Acme: a listing with its careers form, linked
/// to Acme and Germany; Rita, Acme's recruiter, with an address and a
/// LinkedIn profile; a PDF CV, the default; a live mailbox. `apps` adds
/// applications.
fn desk(apps: Json) -> Kernel {
    desk_cv(apps, true, true)
}

/// The desk with one CV root: a PDF (`pdf`) or a text CV, the default or
/// picked by nothing (`default`).
fn desk_cv(apps: Json, pdf: bool, default: bool) -> Kernel {
    desk_rows(apps, serde_json::json!([]), pdf, default)
}

/// The desk with `missions` already staged on its applications.
fn desk_rows(apps: Json, missions: Json, pdf: bool, default: bool) -> Kernel {
    let mut all = vec![json_app(7, 412, "discovered", 80)];
    all.extend(apps.as_array().cloned().unwrap_or_default());
    fixture::kernel(serde_json::json!({
        "corporations": [{"id": 1, "domain": "acme.example", "name": "Acme"}],
        "places": [{"id": 1, "kind": "country", "iso2": "DE", "name": "Germany"}],
        "applications": all,
        "missions": missions,
        "contacts": [{"id": 9, "corporation_id": 1, "name": "Rita", "relation": "recruiter", "email": "rita@acme.example", "linkedin_url": "https://www.linkedin.com/in/rita-acme"}],
        "cv_roots": [{"id": 1, "slug": "main", "name": "Main", "format": if pdf { "pdf" } else { "markdown" }, "version_id": 5}],
        "cv_versions": [{"id": 5, "root_id": 1, "n": 1, "blob_sha": if pdf { "5f1e9b" } else { "" }, "actor": "operator"}],
        "me": [{"id": 1, "cv_default_root_id": if default { serde_json::json!(1) } else { Json::Null }}],
        "mailboxes": [{"id": 1, "provider": "gmail", "address": "ana@example.com", "status": "live"}],
    }))
}

fn json_app(id: u32, no: u32, stage: &str, score: u32) -> Json {
    serde_json::json!({"id": id, "no": no, "company": "Acme", "role": "Staff Engineer", "corporation_id": 1, "place_id": 1, "stage": stage, "stage_on": TODAY, "listing_url": FORM, "listing_raw": "Staff Engineer at Acme: apply through our careers page.", "score_100": score, "heat_override": false})
}

/// A ref's id; an application's ref is by its number.
fn id_of(r: &Json, app: (u32, u32)) -> u32 {
    let (kind, key) = r.as_str().and_then(|r| r.split_once(':')).unwrap_or_else(|| panic!("not a ref: {r}"));
    let n: u32 = key.parse().unwrap_or_else(|_| panic!("not a ref: {r}"));
    if kind == "app" {
        assert_eq!(n, app.1, "the answer names another application");
        app.0
    } else {
        n
    }
}

/// A set's cells as the put takes them: a ref column's ref its id, a day
/// its number, a placeholder the value an agent would write.
fn cells(set: &Json, app: (u32, u32)) -> Json {
    let mut out = serde_json::Map::new();
    for (key, v) in set.as_object().unwrap() {
        let v = match v.as_str() {
            Some(s) if s.starts_with('<') => match key.as_str() {
                "freshness" => serde_json::json!("open"),
                "gate" => serde_json::json!("pursue"),
                "letter_raw" => serde_json::json!("Dear Acme, I build training infrastructure."),
                "draft" => serde_json::json!("Hi Rita! I'm Ana, an infrastructure engineer. Just applied to Staff Engineer at Acme."),
                _ => panic!("no value for {key}: {s}"),
            },
            Some(s) if key == "queued_on" => serde_json::json!(kernel::iso_day(s).unwrap()),
            Some(_) if key.ends_with("_id") => serde_json::json!(id_of(v, app)),
            _ => v.clone(),
        };
        out.insert(key.clone(), v);
    }
    Json::Object(out)
}

/// A mission in the union's keys, lowered to its row as the door does.
fn mission(k: &mut Kernel, args: &Json, app: (u32, u32)) -> Json {
    let mut m = serde_json::json!({"application_id": id_of(&args["app"], app), "kind": args["kind"]});
    for (key, v) in args.as_object().unwrap() {
        match key.as_str() {
            "ref" | "kind" | "app" => {}
            "form" | "to" => m["target"] = v.clone(),
            "contact" => m["contact_id"] = serde_json::json!(id_of(v, app)),
            "subject" => m["subject"] = v.clone(),
            "draft" => m["draft"] = cells(&serde_json::json!({"draft": v}), app)["draft"].clone(),
            "in_reply_to" if v.as_str().is_some_and(|r| r.starts_with("outreach:")) => {
                let item = q(k, serde_json::json!({"op": "get", "table": "outreach", "id": id_of(v, app)}));
                m["in_reply_to"] = item["row"]["message_id"].clone();
            }
            "in_reply_to" => m["in_reply_to"] = v.clone(),
            _ => panic!("a key the mission union does not take: {key} in {args}"),
        }
    }
    m
}

/// The op an answer's `do` is, as the MCP makes it, and the mission it fires.
fn op_of(k: &mut Kernel, next: &Json, app: (u32, u32)) -> (Vec<u8>, Option<u32>) {
    let args = &next["args"];
    let table = |r: &str| match r.split_once(':').map(|x| x.0) {
        Some("app") => "applications",
        Some("mission") => "missions",
        Some("outreach") => "outreach",
        Some("batch") => "batches",
        Some("contact") => "contacts",
        other => panic!("a ref of no table: {other:?}"),
    };
    let op = match next["tool"].as_str().unwrap() {
        "put" => match args["ref"].as_str() {
            Some("mission:new") => put("missions", 0, mission(k, args, app)),
            Some(r) => put(table(r), id_of(&args["ref"], app), cells(&args["set"], app)),
            None => put(args["table"].as_str().unwrap(), 0, cells(&args["set"], app)),
        },
        "stage" => {
            let mut p = serde_json::json!({"stage": args["stage"]});
            if !args["outcome"].is_null() {
                p["outcome"] = args["outcome"].clone();
            }
            cmd("stage", id_of(&args["ref"], app), p)
        }
        "pick_cv" => cmd("pick_cv", id_of(&args["ref"], app), serde_json::json!({"cv_root_id": args["cv_root_id"]})),
        "request_fire_key" => put("fire_requests", 0, serde_json::json!({"missions": args["missions"], "reason": args["reason"]})),
        "fire" => return (cmd("fire", id_of(&args["ref"], app), serde_json::json!({"key": args["key"]})), Some(id_of(&args["ref"], app))),
        "report" => cmd("landed", id_of(&args["mission"], app), serde_json::json!({})),
        "ignore" => cmd("ignore", id_of(&args["ref"], app), serde_json::json!({})),
        tool => panic!("a tool the walk has no call for: {tool} {args}"),
    };
    (op, None)
}

fn noon(day: i32) -> i64 {
    i64::from(day - kernel::UNIX_EPOCH_DAY) * DAY + 43_200
}

/// Follows the campaign on application `app` (id, number) from day `today`:
/// each `do` made by the agent under its key, as the MCP makes it; the key
/// ask answered as the operator answers it on /fire/<id>, the ledger's ask
/// with `ledger`; a mail in flight sent as the node sends it (stamped, then
/// landed); a follow-up wait slept through. The judge must take every call.
/// Answers every answer, up to the close.
fn follow(k: &mut Kernel, app: (u32, u32), mut today: i32, ledger: &str) -> Vec<Json> {
    let mut now = noon(today);
    let mut answers = Vec::new();
    let mut fired = None;
    for _ in 0..120 {
        let a = q(k, serde_json::json!({"op": "campaign", "application": app.0, "now": now}));
        grammar(&a).unwrap();
        answers.push(a.clone());
        let next = &a["next"];
        let agent = Ctx { today, now, human: false, key_id: Some(AGENT), held: &[] };
        let operator = Ctx { today, now, human: true, key_id: None, held: &[] };
        let node = Ctx { today, now, human: false, key_id: None, held: &[] };
        let (op, ctx) = match next["kind"].as_str().unwrap() {
            "done" => return answers,
            "do" => {
                let (op, m) = op_of(k, next, app);
                fired = m.or(fired);
                (op, agent)
            }
            "ask" if next["ask"].as_str().unwrap().contains("/fire/") => {
                let r: u32 = next["ask"].as_str().unwrap().rsplit("/fire/").next().unwrap().parse().unwrap();
                let review = q(k, serde_json::json!({"op": "fire_review", "request": r, "now": now}));
                (cmd("create_fire_key", 0, serde_json::json!({"missions": review["scope"], "digest": review["digest"], "usable_by": AGENT, "request": r})), operator)
            }
            "ask" if next["ask"].as_str().unwrap().contains("old ledger") => (put("applications", app.0, serde_json::json!({"prior_send": ledger})), operator),
            "wait" if next["until"].is_null() => {
                let m = fired.expect("a mail in flight");
                k.predict(&cmd("stamp", m, serde_json::json!({"message_id": format!("<hm.{m}@ana.example>")})), &node).unwrap();
                (cmd("landed", m, serde_json::json!({"gmail_msgid": 1_800_000_000_000_000_000_i64 + i64::from(m), "gmail_thrid": 1_800_000_000_000_000_000_i64})), node)
            }
            "wait" => {
                today = kernel::iso_day(next["until"].as_str().unwrap()).unwrap();
                k.set_today(today);
                now = noon(today);
                continue;
            }
            _ => panic!("an ask the walk has no answer for: {next}"),
        };
        k.predict(&op, &ctx).unwrap_or_else(|e| panic!("the judge refuses {next}: {e:?}"));
        now += 60;
    }
    panic!("no close within 120 answers: {:?}", answers.last());
}

fn phases(answers: &[Json]) -> Vec<u64> {
    answers.iter().map(|a| a["phase"]["n"].as_u64().unwrap()).collect()
}

#[test]
fn a_listing_goes_from_its_posting_to_ghosted_through_the_judge() {
    let mut k = desk(serde_json::json!([]));
    let answers = follow(&mut k, (7, 412), TODAY, "applied");
    let last = answers.last().unwrap();
    assert_eq!((last["next"]["kind"].as_str(), last["said"][0]["code"].as_str()), (Some("done"), Some("closed")), "{last}");
    assert_eq!(q(&mut k, serde_json::json!({"op": "get", "table": "applications", "id": 7}))["row"]["outcome"], "ghosted");
    // Railroaded: the phases only go forward, through every one this route has.
    let n = phases(&answers);
    assert!(n.windows(2).all(|w| w[0] <= w[1]), "{n:?}");
    for phase in [3, 5, 6, 7, 8, 9, 11, 13] {
        assert!(n.contains(&phase), "never in phase {phase}: {n:?}");
    }
    // One key over the application and its LinkedIn note, then one per follow-up.
    let requests: Vec<&str> = answers.iter().filter(|a| a["next"]["tool"] == "request_fire_key").map(|a| a["next"]["args"]["missions"].as_str().unwrap()).collect();
    assert_eq!(requests.len(), 3, "{requests:?}");
    assert!(requests[0].contains('-'), "the first request covers both shots: {requests:?}");
    let nudges = answers.iter().filter(|a| a["next"]["args"]["ref"] == "mission:new" && a["next"]["args"]["kind"] == "email").count();
    assert_eq!(nudges, 2, "a follow-up on day 7 and day 14");
}

#[test]
fn the_old_ledgers_send_is_settled_then_followed_to_its_close() {
    let ledger = kernel::day_iso(TODAY - 3);
    let mut sent = json_app(8, 413, "gated", 70);
    sent["stage_notes"] = serde_json::json!(format!(r#"{{"sync": {{"applied_on": "{ledger}"}}}}"#));
    let mut k = desk(serde_json::json!([sent]));
    let answers = follow(&mut k, (8, 413), TODAY, "applied");
    // Asked first; then no shot goes again, only the follow-ups, and it
    // closes as an application that went out.
    assert!(answers[0]["next"]["ask"].as_str().unwrap().contains("old ledger"), "{}", answers[0]);
    assert!(!answers.iter().any(|a| a["next"]["args"]["kind"] == "careers_page"), "applied twice");
    let row = q(&mut k, serde_json::json!({"op": "get", "table": "applications", "id": 8}))["row"].clone();
    assert_eq!((row["applied_on"].as_str(), row["outcome"].as_str()), (Some(ledger.as_str()), Some("ghosted")));
    // Settled as not sent, it walks the whole route like any listing.
    let mut sent = json_app(8, 413, "gated", 70);
    sent["stage_notes"] = serde_json::json!(format!(r#"{{"sync": {{"applied_on": "{ledger}"}}}}"#));
    let mut k = desk(serde_json::json!([sent]));
    let answers = follow(&mut k, (8, 413), TODAY, "not_applied");
    assert!(answers.iter().any(|a| a["next"]["args"]["kind"] == "careers_page"));
}

/// An application imported or staged by hand past its listing (no listing text, freshness and
/// gate unset, its form already at fire_ready) picks its route up where its stage is: the rest
/// of the route (here the recruiter's LinkedIn note), never capture or qualify again
/// (opus-shannon's finding on the self-reported shot).
#[test]
fn an_application_staged_past_its_listing_picks_up_where_its_stage_is() {
    let mut app = json_app(8, 413, "fire_ready", 70);
    for col in ["listing_url", "listing_raw"] {
        app.as_object_mut().unwrap().remove(col);
    }
    let form = serde_json::json!([{"id": 20, "application_id": 8, "kind": "careers_page", "target": FORM, "draft": "Name: Ana", "state": "fire_ready"}]);
    let mut k = desk_rows(serde_json::json!([app]), form, true, true);
    let a = q(&mut k, serde_json::json!({"op": "campaign", "application": 8}));
    assert_eq!((a["phase"]["name"].as_str(), a["next"]["args"]["ref"].as_str(), a["next"]["args"]["kind"].as_str()), (Some("stage"), Some("mission:new"), Some("linkedin")), "{a}");
}

#[test]
fn the_pick_is_the_open_application_closest_to_done() {
    let held = {
        let mut a = json_app(9, 414, "draft_ready", 99);
        a["status"] = serde_json::json!("paused");
        a
    };
    let gated = |id: u32, no: u32, score: u32| {
        let mut a = json_app(id, no, "gated", score);
        a["freshness"] = serde_json::json!("open");
        a["gate"] = serde_json::json!("pursue");
        a
    };
    let mut k = desk(serde_json::json!([gated(8, 413, 70), gated(10, 415, 75), held]));
    // 413 and 415 stand at the batch, ahead of 412's qualify; the higher score wins; a held one is never picked.
    let a = q(&mut k, serde_json::json!({"op": "campaign"}));
    assert_eq!((a["application"]["no"].as_u64(), a["phase"]["name"].as_str(), a["picked"]["in_play"].as_u64()), (Some(415), Some("batch"), Some(4)), "{a}");
    // One by its number; one that is not there is not found.
    assert_eq!(q(&mut k, serde_json::json!({"op": "campaign", "no": 412}))["phase"]["name"], "qualify");
    let r = k.query(&serde_json::json!({"op": "campaign", "application": 999}));
    assert_eq!(r.expect_err("no application 999").code, schema::refusal::NOT_FOUND);
}

#[test]
fn a_cv_no_rule_picks_is_pinned_and_a_missing_file_asked_for_by_its_route() {
    // A PDF no rule picks: the agent pins it (the form takes the CV as a
    // file), and the route goes to its close without asking for one.
    let mut k = desk_cv(serde_json::json!([]), true, false);
    let answers = follow(&mut k, (7, 412), TODAY, "applied");
    let pin = answers.iter().find(|a| a["next"]["tool"] == "pick_cv").expect("a pin");
    // The pin names the file the route needs AND that nothing chose that root: a
    // default that reads like a match is how a house-sitting job ended up wearing
    // the Software Engineer CV.
    assert_eq!(
        (pin["next"]["args"]["cv_root_id"].as_u64(), pin["next"]["why"].as_str()),
        (Some(1), Some("the form takes the CV as a file: pin a PDF or DOCX; no rule picks a CV for app:412: this is me.cv_default_root_id, not a match — pin the right root, or fix cv_rules")),
        "{pin}"
    );
    assert!(!answers.iter().any(|a| a["next"]["kind"] == "ask" && a["next"]["ask"].as_str().is_some_and(|t| t.contains("CV"))));
    // Only a text CV: the operator is asked for a file, in the route's words.
    let mut k = desk_cv(serde_json::json!([]), false, true);
    let mut ask = Json::Null;
    for _ in 0..20 {
        let a = q(&mut k, serde_json::json!({"op": "campaign", "application": 7, "now": noon(TODAY)}));
        if a["next"]["kind"] != "do" {
            ask = a;
            break;
        }
        let (op, _) = op_of(&mut k, &a["next"], (7, 412));
        k.predict(&op, &Ctx { today: TODAY, now: noon(TODAY), human: false, key_id: Some(AGENT), held: &[] }).unwrap();
    }
    assert_eq!((ask["phase"]["name"].as_str(), ask["next"]["why"].as_str()), (Some("documents"), Some("the form takes the CV as a file")), "{ask}");
}
