//! The OutreachItem: one row of `outreach` as a sum type, and the one
//! judge of its writes (docs/mail/outreach_type.md).
//!
//! An item is `Core × Body`: the core every item has, and a body that is
//! one of the kinds (`Kind`). `Item<Email>` is the OutreachEmail, a strong
//! derivation of the base `Item<Body>`: the whole core plus the mail's own
//! fields, widened for free and narrowed by a guard (`narrow`). Nothing
//! else in the kernel reads an outreach cell by column id: a row is decoded
//! here (`Item::read`), a put is judged here (`put`: what each kind
//! requires, what is fixed once written, what is derived, and the filing of
//! an inbound item by the filer, which reads the item as its `Input` and
//! the stored mail through `Stored`), and the hub's query (`query`) sorts
//! and groups the items on any key.
//!
//! An item is the record of what happened. A draft is its mission's, and a
//! mission of kind `k` produces outreach of kind `k`, so a mission's type,
//! the item it produces and the brief an agent gets (`Kind::brief`) are one
//! thing.

use alloc::string::{String, ToString};
use alloc::vec::Vec;

use schema::col::outreach as O;
use schema::{col, command, enums, param, refusal, table};
use serde_json::{json, Value as Json};
use wire::Op;

use crate::arrange::{self, Ask, Bucket, Col, Column};
use crate::judge::{cell_val, no, Ctx, EVal, Refusal, Row};
use crate::query::{self, Grants};
use crate::rows::{Rows, Table, Val};
use crate::Day;

/// The list separator every list column uses.
pub const SEP: char = '\u{1f}';
/// The most addresses a To or Cc holds.
pub const ADDRS_MAX: usize = 10;
const HANDLE_MAX: usize = 200;
/// Rows the hub's query answers, by default and at most.
const PAGE: u64 = 50;
const PAGE_MAX: u64 = 500;

// ------------------------------------------------------------------ enums

macro_rules! coded {
    ($name:ident, $names:expr, [$($v:ident),+]) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
        pub enum $name { $($v),+ }

        impl $name {
            pub const ALL: &[$name] = &[$($name::$v),+];

            /// The variant of a declared code; none past the enum.
            pub fn from_code(c: u32) -> Option<$name> {
                Self::ALL.get(c as usize).copied()
            }

            pub fn from_name(n: &str) -> Option<$name> {
                $names.iter().position(|x| *x == n).and_then(|i| Self::from_code(i as u32))
            }

            /// The declaration's code: the variant's position.
            pub fn code(self) -> u32 {
                Self::ALL.iter().position(|x| *x == self).unwrap_or(0) as u32
            }

            pub fn name(self) -> &'static str {
                $names[self.code() as usize]
            }
        }
    };
}

coded!(Kind, enums::outreach_kind::NAMES, [Email, CareersPage, LinkedIn, XDm, Discord, Other, Note]);
coded!(Direction, enums::direction::NAMES, [Outbound, Inbound]);
coded!(Filing, enums::filing::NAMES, [Filed, Unfiled, Ignored]);
coded!(FiledBy, enums::filer::NAMES, [Matcher, Operator, Agent, Mail]);
coded!(Actor, enums::actor::NAMES, [Operator, Agent, System, Mail]);
coded!(Pipe, enums::mail_pipe::NAMES, [Gmail, Domain, Hireme]);

/// What an item's record says of it, derived from its direction and, for
/// a mail, its bounce; never stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Sent,
    Received,
    Bounced,
}

impl Status {
    pub fn name(self) -> &'static str {
        match self {
            Status::Sent => "sent",
            Status::Received => "received",
            Status::Bounced => "bounced",
        }
    }
}

impl Kind {
    pub fn label(self) -> &'static str {
        match self {
            Kind::Email => "Email",
            Kind::CareersPage => "Careers page",
            Kind::LinkedIn => "LinkedIn",
            Kind::XDm => "X DM",
            Kind::Discord => "Discord",
            Kind::Other => "Other",
            Kind::Note => "Note",
        }
    }

    /// A mission may have this kind: every one but a note.
    pub fn fireable(self) -> bool {
        self != Kind::Note
    }

    /// hireme records what goes out and files the replies: a mail.
    pub fn tracked(self) -> bool {
        self == Kind::Email
    }

    /// An agent's outbound item on this kind carries its report.
    pub fn reports(self) -> bool {
        !matches!(self, Kind::Email | Kind::Note)
    }

    /// How a body reads: markdown for a note, plain text otherwise.
    pub fn body_format(self) -> &'static str {
        if self == Kind::Note { "markdown" } else { "text" }
    }

    /// The columns of a row this kind owns beyond the core; any other
    /// variant's column must be null on it.
    fn own(self) -> &'static [u16] {
        match self {
            Kind::Email => &[O::FROM_ADDR, O::TO_ADDR, O::CC_ADDR, O::MESSAGE_ID, O::THREAD_KEY, O::BOUNCED_AT, O::REPLY_TO, O::IN_REPLY_TO, O::REFS, O::GMAIL_MSGID, O::GMAIL_THRID, O::LABELS, O::HEADERS, O::PIPE],
            Kind::CareersPage => &[O::FIELDS, O::REFERENCE],
            Kind::LinkedIn | Kind::XDm | Kind::Discord => &[O::HANDLE],
            Kind::Other => &[O::HANDLE, O::CHANNEL],
            Kind::Note => &[],
        }
    }

    /// What a mission of this kind produces and what the agent on it must
    /// do and report: the MCP's brief, one text per kind.
    pub fn brief(self) -> &'static str {
        match self {
            Kind::Email => "An email mission. Its draft is the mission row itself: target is the To (up to 10 addresses), cc, subject, draft the body, in_reply_to and refs for a follow-up. Stage it to fire_ready and request a fire key. Firing sends it through the linked Gmail; hireme records the sent mail as an OutreachEmail (outbound) on the mission and files every reply to it by its headers, so there is nothing to report. Read the thread with the outreach query (where mission_id) and put seen: true on replies you have read.",
            Kind::CareersPage => "A careers-page mission. Scout the form (browser, computer use, visual inspection), put the form's URL in target and every field's text in draft as markdown; submit nothing while staging. Firing under a key is you filling and submitting the form once. Then put one OutreachCareersPage: kind careers_page, mission_id, link (the form), fields (what you submitted, as JSON), reference (the confirmation or application number the page showed), at (when), report (your write-up, markdown). The mission counts as submitted on that item, provisionally, until the board's confirmation mail is filed to it.",
            Kind::LinkedIn => "A LinkedIn message mission. target is the profile URL, draft the message. Firing under a key is you sending it once. Then put one OutreachLinkedIn: kind linkedin, direction outbound, mission_id, handle (the profile's vanity name), link (the conversation), body (the text you sent), at, report. A reply you see is another OutreachLinkedIn with direction inbound, the same handle and link, body the reply, contact_id when you know the person.",
            Kind::XDm => "An X DM mission. target is the handle, draft the message. Firing under a key is you sending it once. Then put one OutreachTwitterDm: kind x_dm, direction outbound, mission_id, handle (without the @), link (the conversation), body (the text you sent), at, report. A reply you see is another item with direction inbound, the same handle and link, body the reply.",
            Kind::Discord => "A Discord message mission. target is the user or server/#channel, draft the message. Firing under a key is you sending it once. Then put one OutreachDiscord: kind discord, direction outbound, mission_id, handle (user, or server/#channel), link (the message), body, at, report. A reply you see is another item with direction inbound.",
            Kind::Other => "A mission on a channel hireme does not model (a call, Slack, a meetup). target names the route, draft what you will say. Firing under a key is you doing it once. Then put one OutreachOther: kind other, direction outbound, mission_id, channel (the channel's name), handle, link, body, at, report. What came back is another item with direction inbound.",
            Kind::Note => "Not a mission: a note. Put an OutreachNote (kind note, no direction) with subject, body in markdown and the refs it is about (application_id, corporation_id, contact_id, mission_id) to record anything seen on any channel that is not itself a message.",
        }
    }
}

// ------------------------------------------------------------------ the type

/// Where an item belongs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Refs {
    pub corporation_id: Option<u32>,
    pub application_id: Option<u32>,
    pub contact_id: Option<u32>,
    pub mission_id: Option<u32>,
}

impl Refs {
    pub fn any(&self) -> bool {
        self.corporation_id.is_some() || self.application_id.is_some() || self.contact_id.is_some() || self.mission_id.is_some()
    }

    fn cells(&self) -> [(u16, Option<u32>); 4] {
        [(O::CORPORATION_ID, self.corporation_id), (O::APPLICATION_ID, self.application_id), (O::CONTACT_ID, self.contact_id), (O::MISSION_ID, self.mission_id)]
    }
}

/// What every item has.
#[derive(Clone, Debug, PartialEq)]
pub struct Core {
    pub id: u32,
    pub kind: Kind,
    pub direction: Option<Direction>,
    /// Unix seconds; 0 until the judge sets it.
    pub at: i64,
    pub subject: Option<String>,
    pub body: Option<String>,
    pub link: Option<String>,
    pub report: Option<String>,
    pub actor: Actor,
    pub filing: Filing,
    pub filed_by: Option<FiledBy>,
    pub evidence: Option<Json>,
    pub seen: bool,
    pub refs: Refs,
    pub rev: i64,
    pub inserted_at: i64,
    pub updated_at: i64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Email {
    pub from: Option<String>,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub reply_to: Option<String>,
    pub message_id: Option<String>,
    pub in_reply_to: Option<String>,
    pub refs: Vec<String>,
    pub thread_key: Option<String>,
    pub gmail_msgid: Option<i64>,
    pub gmail_thrid: Option<i64>,
    pub labels: Vec<String>,
    pub headers: Option<Json>,
    pub pipe: Option<Pipe>,
    pub bounced_at: Option<i64>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CareersPage {
    pub fields: Option<Json>,
    pub reference: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LinkedIn {
    pub handle: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct XDm {
    pub handle: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Discord {
    pub handle: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Other {
    pub channel: Option<String>,
    pub handle: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Note;

/// The variants, one per kind. A mail carries the most, so it is boxed:
/// the other kinds stay small in the hub's lists.
#[derive(Clone, Debug, PartialEq)]
pub enum Body {
    Email(Box<Email>),
    CareersPage(CareersPage),
    LinkedIn(LinkedIn),
    XDm(XDm),
    Discord(Discord),
    Other(Other),
    Note(Note),
}

/// An item: the core and a body. `Item<Body>` is any item; `Item<Email>`
/// and the other derivations are items whose kind the type states.
#[derive(Clone, Debug, PartialEq)]
pub struct Item<B = Body> {
    pub core: Core,
    pub body: B,
}

pub type OutreachItem = Item<Body>;
pub type OutreachEmail = Item<Email>;
pub type OutreachCareersPage = Item<CareersPage>;
pub type OutreachLinkedIn = Item<LinkedIn>;
pub type OutreachTwitterDm = Item<XDm>;
pub type OutreachDiscord = Item<Discord>;
pub type OutreachOther = Item<Other>;
pub type OutreachNote = Item<Note>;

/// A row as it stands: a table's row, or an op's cells laid over one.
#[derive(Clone, Copy)]
struct View<'a> {
    base: Option<(&'a Table, u32)>,
    over: &'a [(u16, EVal)],
}

impl View<'_> {
    fn given(&self, c: u16) -> bool {
        self.over.iter().any(|x| x.0 == c)
    }

    fn val(&self, c: u16) -> Val {
        if let Some((_, v)) = self.over.iter().find(|x| x.0 == c) {
            return match v {
                EVal::Val(v) => v.clone(),
                EVal::New(_) => Val::None,
            };
        }
        self.base.map_or(Val::None, |(t, id)| t.get(id, c))
    }

    fn str(&self, c: u16) -> Option<String> {
        match self.val(c) {
            Val::Str(s) => Some(s),
            _ => None,
        }
    }

    fn u32(&self, c: u16) -> Option<u32> {
        match self.val(c) {
            Val::U32(v) => Some(v),
            _ => None,
        }
    }

    fn i64(&self, c: u16) -> Option<i64> {
        match self.val(c) {
            Val::I64(v) => Some(v),
            Val::U32(v) => Some(i64::from(v)),
            _ => None,
        }
    }

    fn json(&self, c: u16) -> Option<Json> {
        self.str(c).and_then(|s| serde_json::from_str(&s).ok())
    }

    fn list(&self, c: u16) -> Vec<String> {
        self.str(c).map(|s| crate::text::list(&s).map(String::from).collect()).unwrap_or_default()
    }
}

/// Each variant: read from a row, written as cells, lexed as facets, shown as JSON.
pub trait Variant: Sized {
    const KIND: Kind;
    fn into_body(self) -> Body;
    /// The variant out of a body, or the body back untouched when it is another kind.
    #[allow(clippy::result_large_err)]
    fn from_body(b: Body) -> Result<Self, Body>;
}

macro_rules! variant {
    ($t:ident, $k:ident) => {
        impl Variant for $t {
            const KIND: Kind = Kind::$k;

            fn into_body(self) -> Body {
                Body::$k(self)
            }

            fn from_body(b: Body) -> Result<Self, Body> {
                match b {
                    Body::$k(v) => Ok(v),
                    b => Err(b),
                }
            }
        }
    };
}

impl Variant for Email {
    const KIND: Kind = Kind::Email;

    fn into_body(self) -> Body {
        Body::Email(Box::new(self))
    }

    fn from_body(b: Body) -> Result<Self, Body> {
        match b {
            Body::Email(v) => Ok(*v),
            b => Err(b),
        }
    }
}

variant!(CareersPage, CareersPage);
variant!(LinkedIn, LinkedIn);
variant!(XDm, XDm);
variant!(Discord, Discord);
variant!(Other, Other);
variant!(Note, Note);

impl Body {
    pub fn kind(&self) -> Kind {
        match self {
            Body::Email(_) => Kind::Email,
            Body::CareersPage(_) => Kind::CareersPage,
            Body::LinkedIn(_) => Kind::LinkedIn,
            Body::XDm(_) => Kind::XDm,
            Body::Discord(_) => Kind::Discord,
            Body::Other(_) => Kind::Other,
            Body::Note(_) => Kind::Note,
        }
    }

    fn read(kind: Kind, v: &View<'_>) -> Body {
        match kind {
            Kind::Email => Body::Email(Box::new(Email {
                from: v.str(O::FROM_ADDR),
                to: v.list(O::TO_ADDR),
                cc: v.list(O::CC_ADDR),
                reply_to: v.str(O::REPLY_TO),
                message_id: v.str(O::MESSAGE_ID),
                in_reply_to: v.str(O::IN_REPLY_TO),
                refs: v.str(O::REFS).map(|s| s.split_whitespace().map(String::from).collect()).unwrap_or_default(),
                thread_key: v.str(O::THREAD_KEY),
                gmail_msgid: v.i64(O::GMAIL_MSGID),
                gmail_thrid: v.i64(O::GMAIL_THRID),
                labels: v.list(O::LABELS),
                headers: v.json(O::HEADERS),
                pipe: v.u32(O::PIPE).and_then(Pipe::from_code),
                bounced_at: v.i64(O::BOUNCED_AT),
            })),
            Kind::CareersPage => Body::CareersPage(CareersPage { fields: v.json(O::FIELDS), reference: v.str(O::REFERENCE) }),
            Kind::LinkedIn => Body::LinkedIn(LinkedIn { handle: v.str(O::HANDLE) }),
            Kind::XDm => Body::XDm(XDm { handle: v.str(O::HANDLE) }),
            Kind::Discord => Body::Discord(Discord { handle: v.str(O::HANDLE) }),
            Kind::Other => Body::Other(Other { channel: v.str(O::CHANNEL), handle: v.str(O::HANDLE) }),
            Kind::Note => Body::Note(Note),
        }
    }

    /// The variant's own writable cells.
    fn write(&self, out: &mut Vec<(u16, Val)>) {
        match self {
            Body::Email(e) => {
                out.push((O::FROM_ADDR, s(e.from.clone())));
                out.push((O::TO_ADDR, s(join(&e.to))));
                out.push((O::CC_ADDR, s(join(&e.cc))));
                out.push((O::REPLY_TO, s(e.reply_to.clone())));
                out.push((O::MESSAGE_ID, s(e.message_id.clone())));
                out.push((O::IN_REPLY_TO, s(e.in_reply_to.clone())));
                out.push((O::REFS, s(Some(e.refs.join(" ")))));
                out.push((O::GMAIL_MSGID, e.gmail_msgid.map_or(Val::None, Val::I64)));
                out.push((O::GMAIL_THRID, e.gmail_thrid.map_or(Val::None, Val::I64)));
                out.push((O::LABELS, s(join(&e.labels))));
                out.push((O::HEADERS, s(e.headers.as_ref().map(Json::to_string))));
                out.push((O::PIPE, e.pipe.map_or(Val::None, |p| Val::U32(p.code()))));
            }
            Body::CareersPage(c) => {
                out.push((O::FIELDS, s(c.fields.as_ref().map(Json::to_string))));
                out.push((O::REFERENCE, s(c.reference.clone())));
            }
            Body::LinkedIn(LinkedIn { handle }) | Body::XDm(XDm { handle }) | Body::Discord(Discord { handle }) => out.push((O::HANDLE, s(handle.clone()))),
            Body::Other(o) => {
                out.push((O::CHANNEL, s(o.channel.clone())));
                out.push((O::HANDLE, s(o.handle.clone())));
            }
            Body::Note(_) => {}
        }
    }

    /// The variant's fields as the item's JSON shows them.
    fn json(&self) -> Json {
        match self {
            Body::Email(e) => json!({
                "from": e.from, "to": e.to, "cc": e.cc, "reply_to": e.reply_to, "message_id": e.message_id,
                "in_reply_to": e.in_reply_to, "refs": e.refs, "thread_key": e.thread_key, "gmail_msgid": e.gmail_msgid,
                "gmail_thrid": e.gmail_thrid, "labels": e.labels, "pipe": e.pipe.map(Pipe::name),
                "bounced_at": e.bounced_at.map(crate::time_iso),
            }),
            Body::CareersPage(c) => json!({"fields": c.fields, "reference": c.reference}),
            Body::LinkedIn(LinkedIn { handle }) | Body::XDm(XDm { handle }) | Body::Discord(Discord { handle }) => json!({"handle": handle}),
            Body::Other(o) => json!({"channel": o.channel, "handle": o.handle}),
            Body::Note(_) => json!({}),
        }
    }

    fn handle(&self) -> Option<&str> {
        match self {
            Body::LinkedIn(LinkedIn { handle }) | Body::XDm(XDm { handle }) | Body::Discord(Discord { handle }) | Body::Other(Other { handle, .. }) => handle.as_deref(),
            _ => None,
        }
    }
}

/// The name a ref points at.
fn named(rows: &Rows, t: u16, col: u16, id: Option<u32>) -> Option<String> {
    id.and_then(|id| rows.table(t).and_then(|t| t.str(id, col).map(String::from)))
}

/// An application as a label: its company and role.
fn application_label(rows: &Rows, id: u32) -> Option<String> {
    let t = rows.table(table::APPLICATIONS)?;
    let company = t.str(id, col::applications::COMPANY).filter(|x| !x.is_empty()).map(String::from).or_else(|| named(rows, table::CORPORATIONS, col::corporations::NAME, t.u32(id, col::applications::CORPORATION_ID)));
    let role = t.str(id, col::applications::ROLE).unwrap_or("");
    Some(match company {
        Some(co) if !role.is_empty() => alloc::format!("{co} · {role}"),
        Some(co) => co,
        None => role.into(),
    })
}

fn or_empty(o: &Option<String>) -> &str {
    o.as_deref().unwrap_or("")
}

fn s(v: Option<String>) -> Val {
    match v {
        Some(v) if !v.is_empty() => Val::Str(v),
        _ => Val::None,
    }
}

fn join(list: &[String]) -> Option<String> {
    (!list.is_empty()).then(|| list.join(&SEP.to_string()))
}

impl Core {
    fn read(kind: Kind, v: &View<'_>, id: u32) -> Core {
        Core {
            id,
            kind,
            direction: v.u32(O::DIRECTION).and_then(Direction::from_code),
            at: v.i64(O::AT).unwrap_or(0),
            subject: v.str(O::SUBJECT),
            body: v.str(O::BODY),
            link: v.str(O::LINK),
            report: v.str(O::REPORT),
            actor: v.u32(O::ACTOR).and_then(Actor::from_code).unwrap_or(Actor::System),
            filing: v.u32(O::FILING).and_then(Filing::from_code).unwrap_or(Filing::Unfiled),
            filed_by: v.u32(O::FILED_BY).and_then(FiledBy::from_code),
            evidence: v.json(O::EVIDENCE),
            seen: v.u32(O::SEEN) == Some(1),
            refs: Refs {
                corporation_id: v.u32(O::CORPORATION_ID),
                application_id: v.u32(O::APPLICATION_ID),
                contact_id: v.u32(O::CONTACT_ID),
                mission_id: v.u32(O::MISSION_ID),
            },
            rev: v.i64(O::REV).unwrap_or(0),
            inserted_at: v.i64(O::INSERTED_AT).unwrap_or(0),
            updated_at: v.i64(O::UPDATED_AT).unwrap_or(0),
        }
    }
}

impl Item<Body> {
    fn of(v: &View<'_>, id: u32) -> Option<Item<Body>> {
        let kind = v.u32(O::KIND).and_then(Kind::from_code)?;
        Some(Item { core: Core::read(kind, v, id), body: Body::read(kind, v) })
    }

    /// Row `id` of the outreach table decoded; none for no row or no kind.
    pub fn read(t: &Table, id: u32) -> Option<Item<Body>> {
        if !t.has(id) {
            return None;
        }
        Item::of(&View { base: Some((t, id)), over: &[] }, id)
    }

    pub fn kind(&self) -> Kind {
        self.body.kind()
    }

    /// The guard: this item as the derivation `B`, or itself, untouched,
    /// when it is another kind.
    #[allow(clippy::result_large_err)]
    pub fn narrow<B: Variant>(self) -> Result<Item<B>, Item<Body>> {
        let Item { core, body } = self;
        match B::from_body(body) {
            Ok(body) => Ok(Item { core, body }),
            Err(body) => Err(Item { core, body }),
        }
    }
}

impl<B: Variant> From<Item<B>> for Item<Body> {
    fn from(i: Item<B>) -> Item<Body> {
        Item { core: i.core, body: i.body.into_body() }
    }
}

impl<B: Variant + Clone> Item<B> {
    /// The whole item, for what reads any kind.
    pub fn widen(&self) -> Item<Body> {
        Item { core: self.core.clone(), body: self.body.clone().into_body() }
    }

    pub fn status(&self) -> Option<Status> {
        self.widen().status()
    }

    pub fn cells(&self) -> Vec<(u16, Val)> {
        self.widen().cells()
    }
}

impl Item<Body> {
    pub fn status(&self) -> Option<Status> {
        match (self.core.direction, &self.body) {
            (None, _) => None,
            (Some(Direction::Inbound), _) => Some(Status::Received),
            (Some(Direction::Outbound), Body::Email(e)) if e.bounced_at.is_some() => Some(Status::Bounced),
            (Some(Direction::Outbound), _) => Some(Status::Sent),
        }
    }

    /// The writable cells of this item, as a put carries them (nothing
    /// derived or readonly: no actor, filing, thread key, evidence or bounce).
    pub fn cells(&self) -> Vec<(u16, Val)> {
        let c = &self.core;
        let mut out = alloc::vec![
            (O::KIND, Val::U32(c.kind.code())),
            (O::DIRECTION, c.direction.map_or(Val::None, |d| Val::U32(d.code()))),
            (O::AT, if c.at > 0 { Val::U32(c.at as u32) } else { Val::None }),
            (O::SUBJECT, s(c.subject.clone())),
            (O::BODY, s(c.body.clone())),
            (O::LINK, s(c.link.clone())),
            (O::REPORT, s(c.report.clone())),
            (O::SEEN, Val::U32(u32::from(c.seen))),
        ];
        out.extend(c.refs.cells().into_iter().map(|(col, v)| (col, v.map_or(Val::None, Val::U32))));
        self.body.write(&mut out);
        out.retain(|(_, v)| !v.is_none());
        out
    }

    /// The item as the filer's lexer reads it (`filer::Input`): its texts
    /// and, for a mail, its headers; never the type.
    pub fn input(&self) -> crate::filer::Input<'_> {
        let c = &self.core;
        let mut i = crate::filer::Input {
            email: c.kind == Kind::Email,
            inbound: c.direction == Some(Direction::Inbound),
            subject: or_empty(&c.subject),
            body: or_empty(&c.body),
            report: or_empty(&c.report),
            link: or_empty(&c.link),
            handle: self.body.handle().unwrap_or(""),
            ..Default::default()
        };
        if let Body::Email(e) = &self.body {
            i.from = or_empty(&e.from);
            i.to = &e.to;
            i.cc = &e.cc;
            i.reply_to = or_empty(&e.reply_to);
            i.message_id = or_empty(&e.message_id);
            i.in_reply_to = or_empty(&e.in_reply_to);
            i.refs = &e.refs;
            i.gmail_thrid = e.gmail_thrid;
            i.headers = e.headers.as_ref();
        }
        i
    }

    /// The item as the hub, the desk card and the MCP read it: the core
    /// flat, the names of what its refs point at, its variant under its kind.
    pub fn json(&self, rows: &Rows) -> Json {
        let c = &self.core;
        let name = |t: u16, id: Option<u32>, col: u16| named(rows, t, col, id);
        let application = c.refs.application_id.and_then(|id| application_label(rows, id));
        let confirmation = c.refs.mission_id.and_then(|m| {
            let t = rows.table(table::MISSIONS)?;
            let v = t.u32(m, col::missions::CONFIRMATION)?;
            enums::confirmation::NAMES.get(v as usize).map(|n| Json::String((*n).into()))
        });
        let mut j = json!({
            "id": c.id, "kind": c.kind.name(), "direction": c.direction.map(Direction::name), "status": self.status().map(Status::name),
            "at": crate::time_iso(c.at), "subject": c.subject, "body": c.body, "body_format": c.kind.body_format(),
            "link": c.link, "report": c.report, "actor": c.actor.name(), "filing": c.filing.name(),
            "filed_by": c.filed_by.map(FiledBy::name), "seen": c.seen,
            "corporation_id": c.refs.corporation_id, "application_id": c.refs.application_id,
            "contact_id": c.refs.contact_id, "mission_id": c.refs.mission_id,
            "company": name(table::CORPORATIONS, c.refs.corporation_id, col::corporations::NAME),
            "contact": name(table::CONTACTS, c.refs.contact_id, col::contacts::NAME),
            "application": application, "confirmation": confirmation,
        });
        j[c.kind.name()] = self.body.json();
        j["evidence"] = c.evidence.clone().unwrap_or(Json::Null);
        j["rev"] = json!(c.rev);
        j["inserted_at"] = Json::String(crate::time_iso(c.inserted_at));
        j["updated_at"] = Json::String(crate::time_iso(c.updated_at));
        j
    }
}

// ------------------------------------------------------------------ addresses and threads

/// Why a value is no item of its kind: the column and the reason, as the
/// refusal `type` names them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invariant {
    pub column: &'static str,
    pub reason: String,
}

fn bad(column: &'static str, reason: impl Into<String>) -> Invariant {
    Invariant { column, reason: reason.into() }
}

impl Invariant {
    fn refusal(self) -> Refusal {
        no(refusal::TYPE, json!({"table": "outreach", "column": self.column, "reason": self.reason}))
    }
}

/// One address, bare: `Name <local@domain>` and `<local@domain>` read as
/// `local@domain`; none for anything that is not one.
pub fn addr(text: &str) -> Option<String> {
    let t = text.trim();
    let bare = match (t.rfind('<'), t.ends_with('>')) {
        (Some(i), true) => &t[i + 1..t.len() - 1],
        _ => t,
    };
    let bare = bare.trim();
    let (local, domain) = bare.rsplit_once('@')?;
    let ok = !local.is_empty()
        && local.len() <= 64
        && !local.chars().any(|c| c.is_whitespace() || c == '<' || c == '>' || c == ',')
        && domain.contains('.')
        && domain.len() <= 253
        && domain.split('.').all(|l| !l.is_empty() && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
    ok.then(|| alloc::format!("{local}@{}", domain.to_ascii_lowercase()))
}

/// A list of addresses, comma or U+001F separated, each bare: at most
/// `ADDRS_MAX`. What `to_addr`, `cc_addr` and an email mission's target hold.
pub fn addrs(text: &str) -> Result<Vec<String>, Invariant> {
    let mut out: Vec<String> = Vec::new();
    for part in text.split([',', SEP]).map(str::trim).filter(|p| !p.is_empty()) {
        let a = addr(part).ok_or_else(|| bad("to_addr", alloc::format!("not an address: {part}")))?;
        if !out.contains(&a) {
            out.push(a);
        }
    }
    if out.len() > ADDRS_MAX {
        return Err(bad("to_addr", alloc::format!("at most {ADDRS_MAX} addresses")));
    }
    Ok(out)
}

/// A Message-ID as it is stored: trimmed, in one pair of angle brackets,
/// its case kept. The natural key compares this form, so the two pipes'
/// copies of one mail land on one row.
pub fn message_id_form(id: &str) -> String {
    let inner: String = id.chars().filter(|c| !c.is_whitespace() && *c != '<' && *c != '>').collect();
    if inner.is_empty() { String::new() } else { alloc::format!("<{inner}>") }
}

/// A Message-ID as it compares: no brackets or spaces, lowercase.
pub fn canon(id: &str) -> String {
    id.chars().filter(|c| !c.is_whitespace() && *c != '<' && *c != '>').flat_map(char::to_lowercase).collect()
}

/// The thread a mail belongs to by its own headers: the first id of its
/// References, else its In-Reply-To, else its own Message-ID.
pub fn thread_root(refs: &[String], in_reply_to: Option<&str>, message_id: Option<&str>) -> Option<String> {
    refs.first().map(String::as_str).or(in_reply_to).or(message_id).map(|r| r.trim().to_string()).filter(|r| !r.is_empty())
}

/// The account's row holding this Message-ID (canonical comparison).
pub fn by_message_id(rows: &Rows, message_id: &str) -> Option<u32> {
    let want = canon(message_id);
    if want.is_empty() {
        return None;
    }
    let t = rows.table(table::OUTREACH)?;
    t.ids().iter().copied().find(|&id| t.str(id, O::MESSAGE_ID).is_some_and(|m| canon(m) == want))
}

// ------------------------------------------------------------------ the stored mail

/// What the account already holds under a Message-ID or a Gmail thread,
/// for the filer (`filer::Store`): the outreach table answers it.
pub struct Stored<'a>(pub &'a Rows);

impl Stored<'_> {
    fn known(&self, id: u32) -> Option<crate::filer::Known> {
        let t = self.0.table(table::OUTREACH)?;
        let item = Item::read(t, id)?;
        let thread_key = match &item.body {
            Body::Email(e) => e.thread_key.clone(),
            _ => None,
        };
        Some(crate::filer::Known {
            row: Some(id),
            application_id: item.core.refs.application_id,
            corporation_id: item.core.refs.corporation_id,
            contact_id: item.core.refs.contact_id,
            mission_id: item.core.refs.mission_id,
            thread_key,
        })
    }
}

impl crate::filer::Store for Stored<'_> {
    fn by_message_id(&self, id: &str) -> Option<crate::filer::Known> {
        by_message_id(self.0, id).and_then(|row| self.known(row))
    }

    fn by_thread(&self, gmail_thrid: i64) -> Option<crate::filer::Known> {
        let t = self.0.table(table::OUTREACH)?;
        let row = t.ids().iter().copied().find(|&id| t.i64(id, O::GMAIL_THRID) == Some(gmail_thrid))?;
        self.known(row)
    }
}

// ------------------------------------------------------------------ the judge

fn actor_of(ctx: &Ctx) -> Actor {
    if ctx.human {
        Actor::Operator
    } else if ctx.key_id.is_some() {
        Actor::Agent
    } else {
        Actor::Mail
    }
}

fn filer_of(a: Actor) -> FiledBy {
    match a {
        Actor::Operator | Actor::System => FiledBy::Operator,
        Actor::Agent => FiledBy::Agent,
        Actor::Mail => FiledBy::Mail,
    }
}

/// The refs with what they imply filled in: a mission's application, an
/// application's or a contact's company. A contradiction is refused.
fn resolve(rows: &Rows, given: Refs) -> Result<Refs, Invariant> {
    let mut r = given;
    if let Some(m) = r.mission_id {
        let app = rows.table(table::MISSIONS).and_then(|t| t.u32(m, col::missions::APPLICATION_ID));
        match (r.application_id, app) {
            (Some(a), Some(x)) if a != x => return Err(bad("application_id", alloc::format!("mission {m} names application {x}"))),
            (None, Some(x)) => r.application_id = Some(x),
            _ => {}
        }
    }
    if let Some(a) = r.application_id {
        let corp = rows.table(table::APPLICATIONS).and_then(|t| t.u32(a, col::applications::CORPORATION_ID));
        match (r.corporation_id, corp) {
            (Some(c), Some(x)) if c != x => return Err(bad("corporation_id", alloc::format!("application {a} names corporation {x}"))),
            (None, Some(x)) => r.corporation_id = Some(x),
            _ => {}
        }
    }
    if r.corporation_id.is_none()
        && let Some(c) = r.contact_id
    {
        r.corporation_id = rows.table(table::CONTACTS).and_then(|t| t.u32(c, col::contacts::CORPORATION_ID));
    }
    Ok(r)
}

fn write_refs(row: &mut Row, before: Refs, after: Refs) {
    for ((c, b), (_, a)) in before.cells().into_iter().zip(after.cells()) {
        if a != b {
            row.set(c, a.map_or(Val::None, Val::U32));
        }
    }
}

fn write_filing(row: &mut Row, filing: Filing, by: Option<FiledBy>) {
    row.set(O::FILING, Val::U32(filing.code()));
    row.set(O::FILED_BY, by.map_or(Val::None, |f| Val::U32(f.code())));
}

/// The outreach table's domain rule on a put: the item as the row would
/// stand after the op, its invariants, its derived cells, and the filing of
/// an inbound insert that names no ref (the filer over the replica and the
/// stored mail; a bounce fails the mission it returns, a confirmation mail
/// confirms a provisional one).
pub fn put(rows: &Rows, op: &Op, ctx: &Ctx, row: &mut Row, extra: &mut Vec<Row>) -> Result<(), Refusal> {
    let t = rows.table(table::OUTREACH);
    let insert = op.target == 0;
    let base = t.filter(|_| !insert).map(|t| (t, op.target));
    let before = base.and_then(|(t, id)| Item::read(t, id));
    let snapshot = row.cells.clone();
    let view = View { base, over: &snapshot };
    let Some(kind) = view.u32(O::KIND).and_then(Kind::from_code) else {
        return Err(bad("kind", "one of the outreach kinds").refusal());
    };
    if let Some((t, id)) = base {
        for (c, name) in [(O::KIND, "kind"), (O::DIRECTION, "direction"), (O::MESSAGE_ID, "message_id")] {
            let given = match view.val(c) {
                Val::Str(m) if c == O::MESSAGE_ID => s(Some(message_id_form(&m))),
                v => v,
            };
            if view.given(c) && given != t.get(id, c) {
                return Err(no(refusal::COLUMN, json!({"table": "outreach", "column": name, "reason": "fixed"})));
            }
        }
    }
    // A variant's column is null on every other kind.
    for (c, name) in FOREIGN.iter().filter(|(c, _)| !kind.own().contains(c)) {
        if !view.val(*c).is_none() {
            return Err(bad(name, alloc::format!("not a {}'s column", kind.name())).refusal());
        }
    }
    let mut derived: Vec<(u16, Val)> = Vec::new();
    let now = ctx.now;
    // The row's author stays; the op's writer files.
    let writer = actor_of(ctx);
    let actor = before.as_ref().map_or(writer, |b| b.core.actor);
    if insert {
        derived.push((O::ACTOR, Val::U32(actor.code())));
    }
    if view.val(O::AT).is_none() {
        derived.push((O::AT, Val::U32(now as u32)));
    }
    let direction = view.u32(O::DIRECTION).and_then(Direction::from_code);
    let direction = match (kind, direction) {
        (Kind::Note, Some(_)) => return Err(bad("direction", "a note has no direction").refusal()),
        (Kind::Note, None) => None,
        (Kind::CareersPage, Some(Direction::Inbound)) => return Err(bad("direction", "a careers-page submission is outbound").refusal()),
        (Kind::CareersPage, None) => {
            derived.push((O::DIRECTION, Val::U32(Direction::Outbound.code())));
            Some(Direction::Outbound)
        }
        (_, None) => return Err(bad("direction", "outbound or inbound").refusal()),
        (_, d) => d,
    };
    for (c, v) in derived {
        row.set(c, v);
    }
    // The item as it stands now, after what was set above.
    let snapshot = row.cells.clone();
    let view = View { base, over: &snapshot };
    let Some(mut item) = Item::of(&view, op.target) else { return Err(bad("kind", "one of the outreach kinds").refusal()) };
    check(&item, actor).map_err(Invariant::refusal)?;
    if let Body::Email(e) = &mut item.body {
        // The Message-ID in its one stored form.
        if view.given(O::MESSAGE_ID)
            && let Some(m) = e.message_id.as_deref()
        {
            let form = message_id_form(m);
            row.set(O::MESSAGE_ID, s(Some(form.clone())));
            e.message_id = Some(form);
        }
        // Addresses stored bare: `Name <a@b>` reads as `a@b`.
        for (c, one) in [(O::FROM_ADDR, &mut e.from), (O::REPLY_TO, &mut e.reply_to)] {
            if view.given(c)
                && let Some(given) = one.as_deref()
            {
                let bare = addr(given).ok_or_else(|| bad(if c == O::REPLY_TO { "reply_to" } else { "from_addr" }, "an address").refusal())?;
                row.set(c, s(Some(bare.clone())));
                *one = Some(bare);
            }
        }
        for (c, list) in [(O::TO_ADDR, &mut e.to), (O::CC_ADDR, &mut e.cc)] {
            if view.given(c) {
                *list = addrs(&view.str(c).unwrap_or_default()).map_err(|i| Invariant { column: if c == O::CC_ADDR { "cc_addr" } else { "to_addr" }, ..i }.refusal())?;
                row.set(c, s(join(list)));
            }
        }
        if direction == Some(Direction::Outbound) && e.to.is_empty() {
            return Err(bad("to_addr", "an outbound mail names its recipients").refusal());
        }
    }
    if let Body::XDm(x) = &mut item.body
        && let Some(h) = x.handle.as_deref().and_then(|h| h.strip_prefix('@'))
    {
        let h = h.to_string();
        row.set(O::HANDLE, s(Some(h.clone())));
        x.handle = Some(h);
    }
    // Where it belongs: what the writer gave, with what that implies.
    let given = item.core.refs;
    let touched = given.cells().iter().any(|(c, _)| view.given(*c));
    let was = before.as_ref().map_or(Refs::default(), |b| b.core.refs);
    let refs = resolve(rows, given).map_err(Invariant::refusal)?;
    let mut thread_key = match &item.body {
        Body::Email(e) => e.thread_key.clone().or_else(|| thread_root(&e.refs, e.in_reply_to.as_deref(), e.message_id.as_deref())),
        _ => None,
    };
    if insert {
        if refs.any() {
            write_filing(row, Filing::Filed, Some(filer_of(writer)));
        } else if direction == Some(Direction::Inbound) {
            item.core.refs = refs;
            let f = crate::filer::file(rows, &Stored(rows), &item.input());
            let found = resolve(rows, Refs { corporation_id: f.corporation_id, application_id: f.application_id, contact_id: f.contact_id, mission_id: f.mission_id }).map_err(Invariant::refusal)?;
            if f.filed && found.any() {
                write_refs(row, was, found);
                write_filing(row, Filing::Filed, Some(FiledBy::Matcher));
            } else {
                write_filing(row, Filing::Unfiled, None);
            }
            if !f.evidence.is_empty() || !f.candidates.is_empty() {
                let ev = json!({"evidence": f.evidence.iter().map(crate::filer::Evidence::json).collect::<Vec<_>>(), "candidates": f.candidates.iter().map(crate::filer::Candidate::json).collect::<Vec<_>>()});
                row.set(O::EVIDENCE, Val::Str(ev.to_string()));
            }
            if f.thread_key.is_some() {
                thread_key = f.thread_key;
            }
            // A bounce: the mail it returns is bounced, and its mission failed (rule 2).
            if let Some((mission, returned)) = f.bounce {
                if let Some(b) = returned.filter(|&b| t.is_some_and(|t| t.has(b))) {
                    extra.push(Row { table: table::OUTREACH, id: b, cells: alloc::vec![(O::BOUNCED_AT, EVal::Val(Val::U32(now as u32)))] });
                }
                extra.extend(crate::fire::failed(rows, mission, "bounced"));
            }
            // A confirmation mail: a provisional mission is confirmed (rule 3).
            if let Some(m) = f.confirms
                && rows.table(table::MISSIONS).and_then(|mt| mt.u32(m, col::missions::CONFIRMATION)) == Some(u32::from(enums::confirmation::PROVISIONAL))
            {
                extra.push(Row { table: table::MISSIONS, id: m, cells: alloc::vec![(col::missions::CONFIRMATION, EVal::Val(Val::U32(u32::from(enums::confirmation::CONFIRMED))))] });
            }
            return finish(row, kind, was, if f.filed { found } else { refs }, thread_key, true);
        } else {
            write_filing(row, Filing::Unfiled, None);
        }
    } else if touched {
        if refs.any() {
            write_filing(row, Filing::Filed, Some(filer_of(writer)));
        } else {
            write_filing(row, Filing::Unfiled, None);
        }
    }
    finish(row, kind, was, refs, thread_key, insert || before.as_ref().and_then(|b| if let Body::Email(e) = &b.body { e.thread_key.clone() } else { None }).is_none())
}

fn finish(row: &mut Row, kind: Kind, was: Refs, refs: Refs, thread_key: Option<String>, key_moves: bool) -> Result<(), Refusal> {
    write_refs(row, was, refs);
    if kind == Kind::Email && key_moves {
        row.set(O::THREAD_KEY, s(thread_key));
    }
    Ok(())
}

/// Every variant's own column with its name, for the foreign-column check.
const FOREIGN: [(u16, &str); 18] = [
    (O::FROM_ADDR, "from_addr"),
    (O::TO_ADDR, "to_addr"),
    (O::CC_ADDR, "cc_addr"),
    (O::MESSAGE_ID, "message_id"),
    (O::THREAD_KEY, "thread_key"),
    (O::BOUNCED_AT, "bounced_at"),
    (O::REPLY_TO, "reply_to"),
    (O::IN_REPLY_TO, "in_reply_to"),
    (O::REFS, "refs"),
    (O::GMAIL_MSGID, "gmail_msgid"),
    (O::GMAIL_THRID, "gmail_thrid"),
    (O::LABELS, "labels"),
    (O::HEADERS, "headers"),
    (O::PIPE, "pipe"),
    (O::HANDLE, "handle"),
    (O::FIELDS, "fields"),
    (O::REFERENCE, "reference"),
    (O::CHANNEL, "channel"),
];

/// The invariants of an item as it stands, by its kind and who wrote it.
fn check(item: &Item<Body>, actor: Actor) -> Result<(), Invariant> {
    let c = &item.core;
    if let Some(l) = c.link.as_deref()
        && crate::write::host(l).is_none()
    {
        return Err(bad("link", "an http(s) URL on a real host"));
    }
    if item.body.handle().is_some_and(|h| h.len() > HANDLE_MAX) {
        return Err(bad("handle", alloc::format!("at most {HANDLE_MAX} bytes")));
    }
    let empty = |v: &Option<String>| v.as_deref().is_none_or(|x| x.trim().is_empty());
    match &item.body {
        Body::Email(e) => {
            if c.direction == Some(Direction::Inbound) && empty(&e.from) {
                return Err(bad("from_addr", "an inbound mail names its sender"));
            }
            if e.message_id.as_deref().is_some_and(|m| m.len() > 998 || canon(m).is_empty()) {
                return Err(bad("message_id", "a Message-ID"));
            }
        }
        Body::CareersPage(_) => {
            if empty(&c.link) {
                return Err(bad("link", "the form's URL"));
            }
        }
        Body::Other(o) => {
            if empty(&o.channel) {
                return Err(bad("channel", "the channel's name"));
            }
        }
        Body::Note(_) => {
            if empty(&c.body) {
                return Err(bad("body", "a note says something"));
            }
        }
        Body::LinkedIn(_) | Body::XDm(_) | Body::Discord(_) => {}
    }
    if actor == Actor::Agent && c.direction == Some(Direction::Outbound) && c.kind.reports() && empty(&c.report) {
        return Err(bad("report", "an agent reports what it did on an untracked channel"));
    }
    Ok(())
}

/// The outreach commands: `file` (the refs set, with what they imply) and
/// `ignore` (the tray's dismissal: ignored, no refs).
pub fn command(rows: &Rows, op: &Op, ctx: &Ctx) -> Result<Vec<Row>, Refusal> {
    let Some(t) = rows.table(table::OUTREACH).filter(|t| t.has(op.target)) else {
        return Err(no(refusal::NOT_FOUND, json!({"table": "outreach", "id": op.target})));
    };
    let Some(item) = Item::read(t, op.target) else { return Err(no(refusal::NOT_FOUND, json!({"table": "outreach", "id": op.target}))) };
    let mut row = Row { table: table::OUTREACH, id: op.target, cells: Vec::new() };
    match op.table {
        command::FILE => {
            let p = |id: u16| match cell_val(op, id) {
                Some(Val::U32(v)) => Some(v),
                _ => None,
            };
            let named = Refs {
                application_id: p(param::file::APPLICATION_ID),
                mission_id: p(param::file::MISSION_ID),
                contact_id: p(param::file::CONTACT_ID),
                corporation_id: p(param::file::CORPORATION_ID),
            };
            if !named.any() {
                return Err(no(refusal::COLUMN, json!({"command": "file", "missing": ["application_id", "mission_id", "contact_id", "corporation_id"]})));
            }
            // The refs named, over the item's own.
            let given = Refs {
                application_id: named.application_id.or(item.core.refs.application_id),
                mission_id: named.mission_id.or(item.core.refs.mission_id),
                contact_id: named.contact_id.or(item.core.refs.contact_id),
                corporation_id: named.corporation_id.or(item.core.refs.corporation_id),
            };
            let tables = [
                (param::file::APPLICATION_ID, table::APPLICATIONS, "applications"),
                (param::file::MISSION_ID, table::MISSIONS, "missions"),
                (param::file::CONTACT_ID, table::CONTACTS, "contacts"),
                (param::file::CORPORATION_ID, table::CORPORATIONS, "corporations"),
            ];
            for (pid, tid, name) in tables {
                if let Some(id) = p(pid)
                    && !rows.table(tid).is_some_and(|t| t.has(id))
                {
                    return Err(no(refusal::NOT_FOUND, json!({"table": name, "id": id})));
                }
            }
            let refs = resolve(rows, given).map_err(Invariant::refusal)?;
            write_refs(&mut row, item.core.refs, refs);
            write_filing(&mut row, Filing::Filed, Some(filer_of(actor_of(ctx))));
        }
        command::IGNORE => {
            write_refs(&mut row, item.core.refs, Refs::default());
            write_filing(&mut row, Filing::Ignored, None);
        }
        other => return Err(no(refusal::NOT_FOUND, json!({"command": other}))),
    }
    Ok(alloc::vec![row])
}

// ------------------------------------------------------------------ the sent record

/// What `landed` records of an email mission's shot: the mail as it went.
#[derive(Clone, Copy, Debug)]
pub struct Shot<'a> {
    pub mission_id: u32,
    pub application_id: u32,
    pub contact_id: Option<u32>,
    pub corporation_id: Option<u32>,
    pub from: &'a str,
    pub to: &'a [String],
    pub cc: &'a [String],
    pub subject: Option<&'a str>,
    pub body: Option<&'a str>,
    pub in_reply_to: Option<&'a str>,
    pub refs: &'a [String],
    pub message_id: &'a str,
    pub gmail_msgid: Option<i64>,
    pub gmail_thrid: Option<i64>,
}

/// The sent mail's record as an effect row: inserted, or the row Gmail's
/// copy of the same Message-ID already made, updated with the mission it
/// went for. Filed to its mission by the mail actor.
pub fn sent_record(rows: &Rows, shot: &Shot<'_>, now: i64) -> Row {
    let existing = by_message_id(rows, shot.message_id);
    let refs = resolve(rows, Refs { corporation_id: shot.corporation_id, application_id: Some(shot.application_id), contact_id: shot.contact_id, mission_id: Some(shot.mission_id) }).unwrap_or(Refs {
        corporation_id: shot.corporation_id,
        application_id: Some(shot.application_id),
        contact_id: shot.contact_id,
        mission_id: Some(shot.mission_id),
    });
    let mut row = Row { table: table::OUTREACH, id: existing.unwrap_or(0), cells: Vec::new() };
    let before = existing.and_then(|id| rows.table(table::OUTREACH).and_then(|t| Item::read(t, id)));
    if before.is_none() {
        row.set(O::KIND, Val::U32(Kind::Email.code()));
        row.set(O::DIRECTION, Val::U32(Direction::Outbound.code()));
        row.set(O::AT, Val::U32(now as u32));
        row.set(O::ACTOR, Val::U32(Actor::Mail.code()));
        row.set(O::PIPE, Val::U32(Pipe::Hireme.code()));
        row.set(O::MESSAGE_ID, s(Some(message_id_form(shot.message_id))));
    }
    row.set(O::FROM_ADDR, s(Some(shot.from.into())));
    row.set(O::TO_ADDR, s(join(shot.to)));
    row.set(O::CC_ADDR, s(join(shot.cc)));
    row.set(O::SUBJECT, s(shot.subject.map(String::from)));
    row.set(O::BODY, s(shot.body.map(String::from)));
    row.set(O::IN_REPLY_TO, s(shot.in_reply_to.map(String::from)));
    row.set(O::REFS, s(Some(shot.refs.join(" "))));
    if let Some(m) = shot.gmail_msgid {
        row.set(O::GMAIL_MSGID, Val::I64(m));
    }
    if let Some(t) = shot.gmail_thrid {
        row.set(O::GMAIL_THRID, Val::I64(t));
    }
    row.set(O::THREAD_KEY, s(thread_root(shot.refs, shot.in_reply_to, Some(shot.message_id))));
    write_refs(&mut row, before.as_ref().map_or(Refs::default(), |b| b.core.refs), refs);
    write_filing(&mut row, Filing::Filed, Some(FiledBy::Mail));
    row
}

// ------------------------------------------------------------------ the query

/// The keys the hub sorts on.
pub const SORTS: [&str; 9] = ["at", "kind", "company", "contact", "application", "subject", "from", "handle", "seen"];
/// The keys the hub groups on.
pub const GROUPS: [&str; 15] = ["kind", "direction", "status", "filing", "actor", "day", "month", "company", "contact", "application", "mission", "thread", "handle", "from", "pipe"];

/// Text symbols per slot, from one reading of each item.
fn texts_of(items: &[Option<Item<Body>>], f: impl Fn(&Item<Body>) -> Option<String>) -> Col {
    arrange::texts(items.iter().map(|i| i.as_ref().and_then(&f)))
}

/// Symbols from a fixed list per slot, from one reading of each item.
fn codes_of(items: &[Option<Item<Body>>], names: &[&str], f: impl Fn(&Item<Body>) -> Option<usize>) -> Col {
    arrange::listed(names, items.iter().map(|i| i.as_ref().and_then(&f)))
}

/// One key as a typed column over the outreach table's slots.
fn column(rows: &Rows, t: &Table, items: &[Option<Item<Body>>], key: &str) -> Option<Column> {
    if t.len() != items.len() {
        return None;
    }
    let per = |f: &dyn Fn(&Item<Body>) -> Option<String>| texts_of(items, f);
    let code = |names: &[&str], f: &dyn Fn(&Item<Body>) -> Option<usize>| codes_of(items, names, f);
    let day = |i: &Item<Body>| (i.core.at.div_euclid(86_400) + i64::from(crate::UNIX_EPOCH_DAY)) as f64;
    Some(match key {
        "at" => Column { desc: true, ..Column::of(Col::Num(items.iter().map(|i| i.as_ref().map_or(f64::NAN, |i| i.core.at as f64)).collect()), Bucket::Day) },
        "day" => Column { desc: true, ..Column::of(Col::Num(items.iter().map(|i| i.as_ref().map_or(f64::NAN, day)).collect()), Bucket::Day) },
        "month" => Column { desc: true, ..Column::of(Col::Num(items.iter().map(|i| i.as_ref().map_or(f64::NAN, day)).collect()), Bucket::Month) },
        "seen" => Column::of(Col::Num(items.iter().map(|i| i.as_ref().map_or(f64::NAN, |i| f64::from(u8::from(i.core.seen)))).collect()), Bucket::Sym),
        "kind" => Column::of(code(enums::outreach_kind::NAMES, &|i| Some(i.core.kind.code() as usize)), Bucket::Sym),
        "direction" => Column::of(code(enums::direction::NAMES, &|i| i.core.direction.map(|d| d.code() as usize)), Bucket::Sym),
        "status" => {
            const NAMES: [&str; 3] = ["sent", "received", "bounced"];
            Column::of(code(&NAMES, &|i| i.status().map(|s| NAMES.iter().position(|n| *n == s.name()).unwrap_or(0))), Bucket::Sym)
        }
        "filing" => Column::of(code(enums::filing::NAMES, &|i| Some(i.core.filing.code() as usize)), Bucket::Sym),
        "actor" => Column::of(code(enums::actor::NAMES, &|i| Some(i.core.actor.code() as usize)), Bucket::Sym),
        "pipe" => Column::of(code(enums::mail_pipe::NAMES, &|i| if let Body::Email(e) = &i.body { e.pipe.map(|p| p.code() as usize) } else { None }), Bucket::Sym),
        "company" => Column::of(per(&|i| named(rows, table::CORPORATIONS, col::corporations::NAME, i.core.refs.corporation_id)), Bucket::Sym),
        "contact" => Column::of(per(&|i| named(rows, table::CONTACTS, col::contacts::NAME, i.core.refs.contact_id)), Bucket::Sym),
        "application" => Column::of(per(&|i| i.core.refs.application_id.and_then(|a| application_label(rows, a))), Bucket::Sym),
        "mission" => Column::of(
            per(&|i| {
                let m = i.core.refs.mission_id?;
                let mt = rows.table(table::MISSIONS)?;
                let kind = mt.u32(m, col::missions::KIND).and_then(|k| enums::mission_kind::NAMES.get(k as usize)).copied().unwrap_or("");
                Some(alloc::format!("#{m} {kind} · {}", mt.str(m, col::missions::TARGET).unwrap_or("")))
            }),
            Bucket::Sym,
        ),
        "thread" => Column::of(per(&|i| if let Body::Email(e) = &i.body { e.thread_key.clone() } else { None }), Bucket::Sym),
        "handle" => Column::of(per(&|i| i.body.handle().map(String::from)), Bucket::Sym),
        "from" => Column::of(per(&|i| if let Body::Email(e) = &i.body { e.from.clone() } else { None }), Bucket::Sym),
        "subject" => Column::of(per(&|i| i.core.subject.clone()), Bucket::Sym),
        _ => return None,
    })
}

fn contains_ci(hay: &str, needle: &str) -> bool {
    hay.as_bytes().windows(needle.len()).any(|w| w.eq_ignore_ascii_case(needle.as_bytes()))
}

fn searched(i: &Item<Body>, needle: &str) -> bool {
    if needle.is_empty() {
        return true;
    }
    let c = &i.core;
    let mut texts: Vec<&str> = alloc::vec![c.subject.as_deref().unwrap_or(""), c.body.as_deref().unwrap_or(""), c.report.as_deref().unwrap_or("")];
    match &i.body {
        Body::Email(e) => {
            texts.push(e.from.as_deref().unwrap_or(""));
            texts.extend(e.to.iter().map(String::as_str));
            texts.extend(e.cc.iter().map(String::as_str));
        }
        Body::CareersPage(p) => texts.push(p.reference.as_deref().unwrap_or("")),
        Body::Other(o) => {
            texts.push(o.channel.as_deref().unwrap_or(""));
            texts.push(o.handle.as_deref().unwrap_or(""));
        }
        b => texts.push(b.handle().unwrap_or("")),
    }
    texts.iter().any(|t| contains_ci(t, needle))
}

/// The hub's query: `where` (find's filters), `search`, `sort`, `group`,
/// `largest`, `after` and `limit`, answered as items under the page's
/// groups with the tray's and the reply marker's counts.
pub fn query(rows: &Rows, g: &Grants, req: &Json, _today: Day) -> Result<Json, Refusal> {
    let tm = query::readable(g, Some(&json!("outreach")))?;
    let pass = query::sieve(g, tm, req.get("where"))?;
    let limit = query::bound(req.get("limit"), PAGE, PAGE_MAX, "limit")? as usize;
    let after = match req.get("after") {
        None | Some(Json::Null) => 0,
        Some(v) => v.as_u64().ok_or_else(|| no(refusal::TYPE, json!({"param": "after", "need": "the row offset the previous page answered as next"})))? as usize,
    };
    let search = req.get("search").and_then(Json::as_str).unwrap_or("").trim();
    if search.len() > 1000 {
        return Err(no(refusal::TOO_LARGE, json!({"param": "search", "max": 1000})));
    }
    let (sort, dir): (&str, i8) = match req.get("sort") {
        None | Some(Json::Null) => ("at", -1),
        Some(Json::String(k)) => (k.as_str(), 0),
        Some(Json::Array(a)) => (a.first().and_then(Json::as_str).unwrap_or("at"), match a.get(1).and_then(Json::as_str) {
            Some("desc") => -1,
            Some("asc") => 1,
            _ => 0,
        }),
        Some(other) => return Err(no(refusal::TYPE, json!({"param": "sort", "got": other.to_string()}))),
    };
    let group = req.get("group").and_then(Json::as_str).unwrap_or("");
    for (k, what) in [(sort, "sort"), (group, "group")] {
        let known: &[&str] = if what == "sort" { &SORTS } else { &GROUPS };
        if !k.is_empty() && !known.contains(&k) {
            return Err(no(refusal::TYPE, json!({"param": what, "unknown": k, "known": known})));
        }
    }
    let empty = json!({"rows": [], "groups": [], "total": 0, "next": null, "counts": {"unfiled": 0, "unseen": 0}, "listing": "no outreach\n"});
    let Some(t) = rows.table(table::OUTREACH) else { return Ok(empty) };
    let items: Vec<Option<Item<Body>>> = t.ids().iter().map(|&id| Item::read(t, id)).collect();
    let (mut unfiled, mut unseen) = (0u32, 0u32);
    for i in items.iter().flatten() {
        unfiled += u32::from(i.core.filing == Filing::Unfiled);
        unseen += u32::from(i.core.direction == Some(Direction::Inbound) && !i.core.seen);
    }
    let ids: Vec<u32> = t.ids().iter().zip(&items).filter(|(id, i)| i.as_ref().is_some_and(|i| pass(t, **id) && searched(i, search))).map(|(id, _)| *id).collect();
    let mut cols = alloc::collections::BTreeMap::new();
    for k in [sort, group].into_iter().filter(|k| !k.is_empty()) {
        if !cols.contains_key(k)
            && let Some(c) = column(rows, t, &items, k)
        {
            cols.insert(k.to_string(), c);
        }
    }
    let dir = if dir == 0 { cols.get(sort).map_or(1, |c| if c.desc { -1 } else { 1 }) } else { dir };
    let ask = Ask { sort: (!sort.is_empty()).then_some((sort, dir)), group: (!group.is_empty()).then_some(group), largest: req["largest"] == true, cols: &cols };
    let (order, groups) = arrange::arrange(t, &ids, &ask, &|_| (0, 0));
    let end = (after + limit).min(order.len());
    let page = &order[after.min(end)..end];
    let groups: Vec<Json> = arrange::groups_json(&groups)
        .as_array()
        .into_iter()
        .flatten()
        .filter(|g| {
            let (st, n) = (g["start"].as_u64().unwrap_or(0) as usize, g["count"].as_u64().unwrap_or(0) as usize);
            !group.is_empty() && st < end && st + n > after
        })
        .cloned()
        .collect();
    let out: Vec<Json> = page.iter().filter_map(|&id| t.slot(id).and_then(|s| items[s].as_ref()).map(|i| i.json(rows))).collect();
    let listing = listing(&out, &groups, order.len(), after, sort, dir, group);
    let next = (end < order.len()).then_some(end);
    Ok(json!({"rows": out, "groups": groups, "total": order.len(), "next": next, "counts": {"unfiled": unfiled, "unseen": unseen}, "listing": listing}))
}

/// The hub page as an agent reads it (`arrange::listing`): how it stands, then each item's line.
fn listing(rows: &[Json], groups: &[Json], total: usize, after: usize, sort: &str, dir: i8, group: &str) -> String {
    let how = if sort.is_empty() { String::new() } else { alloc::format!(" sorted by {sort} {}", if dir < 0 { "desc" } else { "asc" }) };
    let by = if group.is_empty() { String::new() } else { alloc::format!(", grouped by {group}") };
    arrange::listing("outreach items", &alloc::format!("{how}{by}"), rows, groups, total, after, |_, r| {
        let text = |k: &str| r[k].as_str().unwrap_or("").to_string();
        let who = match r["kind"].as_str() {
            Some("email") => r["email"]["from"].as_str().map(String::from).or_else(|| r["email"]["to"].as_array().map(|a| a.iter().filter_map(Json::as_str).collect::<Vec<_>>().join(", "))).unwrap_or_default(),
            Some(k) => r[k]["handle"].as_str().unwrap_or("").to_string(),
            None => String::new(),
        };
        let parts: Vec<String> = [text("kind"), text("direction"), text("at"), who, text("subject"), text("company"), text("filing")].into_iter().filter(|p| !p.is_empty()).collect();
        alloc::format!("#{}  {}", r["id"].as_u64().unwrap_or(0), parts.join(" · "))
    })
}

/// What the desk card shows of an application's outreach at a glance.
pub fn summary(rows: &Rows, application_id: u32) -> Json {
    let (mut count, mut unseen, mut last_inbound) = (0u32, 0u32, None::<i64>);
    for (t, id) in rows.each(table::OUTREACH) {
        if t.u32(id, O::APPLICATION_ID) != Some(application_id) {
            continue;
        }
        count += 1;
        if t.u32(id, O::DIRECTION) == Some(Direction::Inbound.code()) {
            if t.u32(id, O::SEEN) != Some(1) {
                unseen += 1;
            }
            let at = t.i64(id, O::AT).or_else(|| t.u32(id, O::AT).map(i64::from)).unwrap_or(0);
            last_inbound = Some(last_inbound.map_or(at, |l: i64| l.max(at)));
        }
    }
    json!({"count": count, "unseen": unseen, "last_inbound_at": last_inbound.map(crate::time_iso)})
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Rust enums are the declaration's, variant for value, in order.
    #[test]
    fn kinds_are_the_declarations() {
        for k in Kind::ALL {
            assert_eq!(enums::outreach_kind::NAMES[k.code() as usize], k.name());
        }
        assert_eq!(Kind::ALL.len(), enums::outreach_kind::NAMES.len());
        assert_eq!(Kind::from_name("x_dm"), Some(Kind::XDm));
        for (n, k) in enums::mission_kind::NAMES.iter().zip(Kind::ALL) {
            assert_eq!(n, &k.name(), "a mission's kind is an outreach kind");
        }
        assert_eq!(Direction::ALL.len(), enums::direction::NAMES.len());
        assert_eq!(Filing::ALL.len(), enums::filing::NAMES.len());
        assert_eq!(FiledBy::ALL.len(), enums::filer::NAMES.len());
        assert_eq!(Actor::ALL.len(), enums::actor::NAMES.len());
        assert_eq!(Pipe::ALL.len(), enums::mail_pipe::NAMES.len());
        assert!(Actor::ALL.iter().all(|a| a.name() == enums::actor::NAMES[a.code() as usize]));
    }

    #[test]
    fn addresses_read_bare_and_bounded() {
        assert_eq!(addr("Dana Reyes <Dana@Acme.Example>"), Some("Dana@acme.example".into()));
        assert_eq!(addr("<a@b.co>"), Some("a@b.co".into()));
        assert_eq!(addr("nope"), None);
        assert_eq!(addr("a@b"), None);
        assert_eq!(addrs("a@x.io, B <b@y.io>\u{1f}a@x.io").unwrap(), alloc::vec!["a@x.io".to_string(), "b@y.io".into()]);
        let many = (0..11).map(|i| alloc::format!("u{i}@x.io")).collect::<Vec<_>>().join(",");
        assert_eq!(addrs(&many).unwrap_err().column, "to_addr");
        assert_eq!(canon(" <A@B.Co> "), "a@b.co");
        assert_eq!(message_id_form(" a@b.co "), "<a@b.co>");
        assert_eq!(message_id_form("<<x@y>>"), "<x@y>");
        assert_eq!(thread_root(&["<r@x>".into(), "<p@x>".into()], Some("<p@x>"), Some("<m@x>")), Some("<r@x>".into()));
        assert_eq!(thread_root(&[], None, Some("<m@x>")), Some("<m@x>".into()));
    }
}
