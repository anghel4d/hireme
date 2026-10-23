# The OutreachItem type

The interface the mail lanes build against for everything said or done on
any channel (opus-turing's lane, by the operator's word). The brief is
[passthrough.md](passthrough.md); missions, fire keys, mailboxes and the
filer are [kernel.md](kernel.md) (opus-lovelace). Nothing here is a second
rule: the kernel's `outreach` module is the one reading of an outreach row,
and the node (NIF), the daemon and the page (wasm) decode it alike.

The operator, verbatim:

> the outreach tab is polymorphic **in the functional programming sense of
> the word**. Type OutreachItem as a base type, newtypes OutreachEmail
> OutreachLinkedIn OutreachTwitterDM etc as strong derivations of it, which
> outreach can display as collapsible rows and which can be grouped by the
> type or date range or any of these things. So outreach gets a nice
> functional programming kernel in Rust and good Elixir with pattern matching
> and all that beautiful algebraic-driven design we love.

> the machinery for lexical filing now becomes unified across the
> OutreachItem type, with the OutreachEmail specialization being extra
> patterns and rules that apply only to emails. Isnt FP glorious?

Changes to the type are asked for as `type-request:` lines in the team log.

## The algebra

An **OutreachItem** is a record of one communication: a mail received or
sent, a LinkedIn message, an X DM, a Discord message, a form submitted on a
careers page, or a note. It is a product of a **core** every item has and a
**body** that is one of the variants:

```
OutreachItem = Core × Body
Body         = Email | CareersPage | LinkedIn | XDm | Discord | Other | Note
```

A variant is a **strong derivation** of the base: `Item<Email>` (the
OutreachEmail) is a distinct type that carries the whole core and the
email's own fields. Widening to the base (`Item<Body>`) is free; narrowing
(`item.narrow::<Email>()`) is a guard that fails on any other kind. In Elixir
each variant is its own struct (`%Hireme.Outreach.Email{}`), with the core
fields and its own, so function heads pattern-match on it.

What an item is **not**: a draft. A mission (kernel.md) holds every draft
and is the unit of fire; the items are what happened. The outreach hub and
the desk card show missions for the drafts and items for the record, both
grouped as the page likes.

A mission of kind `k` produces outreach of kind `k`: `missions.kind` and
`outreach.kind` are one enum, `outreach_kind`, so the MCP tells an agent on
a fire mission its type and what it will produce from one place
(`Kind::brief`).

## The declaration

One fat row per item in table `outreach` (the `messages` table, renamed in
place: its number and its surviving column ids stay; migration
`0008_outreach`). Sparse by design: a column a variant does not own is null.

```
enum outreach_kind email careers_page linkedin x_dm discord other note
enum direction outbound inbound
enum filing filed unfiled ignored
enum filer matcher operator agent mail
enum mail_pipe gmail domain hireme

table outreach mail resident
  natural message_id where message_id is not null
  cap 200000
  index thread_key
  index application_id
  index contact_id
  index mission_id
  index at desc
  # core
  col kind enum outreach_kind !
  col direction enum direction ?
  col from_addr str ?
  col to_addr str ?
  col cc_addr str ?
  col subject str ?
  col body text ?
  col message_id str ?
  col thread_key str ? readonly
  col at time ?
  retired col 1
  col corporation_id ref corporations ?
  col application_id ref applications ?
  col contact_id ref contacts ?
  col mission_id ref missions ?
  col link str ?
  col report text ?
  col actor enum actor ! = system readonly
  col filing enum filing ! = unfiled readonly
  col filed_by enum filer ? readonly
  col evidence json ? readonly
  col seen bool ! = false
  # email
  col bounced_at time ? readonly
  col reply_to str ?
  col in_reply_to str ?
  col refs text ?
  col gmail_msgid i64 ?
  col gmail_thrid i64 ?
  col labels str ?
  col headers json ?
  col pipe enum mail_pipe ?
  # linkedin, x_dm, discord, other
  col handle str ?
  # careers_page
  col fields json ?
  col reference str ?
  # other
  col channel str ?
  command file application_id? mission_id? contact_id? corporation_id?
  command ignore
```

`missions.kind` is `enum outreach_kind` (the first six values are
`mission_kind`'s in its order; a mission is never a `note`:
`Kind::fireable`). Lists (`to_addr`, `cc_addr`, `labels`) are U+001F-joined,
as every list column in the declaration; a put may give them comma-separated
and the judge stores them joined. `refs` is the References header as
written, space-separated.

## The core

| field | who writes | meaning |
| --- | --- | --- |
| kind | the writer, once | the variant |
| direction | the writer, once | `outbound`, `inbound`; null for a note. A careers-page item is outbound; the judge sets it |
| at | the writer; the judge sets now when absent | the item's instant: sent, received, submitted, written |
| subject | the writer | a mail's subject; a one-line title for anything else |
| body | the writer | the text that was said: a mail's plain text, a message, a note. Plain text, except a note's, which is markdown (`Kind::body_format`) |
| link | the writer | the conversation or page: the thread, the profile's messages, the form; an http(s) URL |
| report | the writer | the agent's write-up of a self-reported act, markdown (passthrough.md point 3) |
| actor | the judge, once | who wrote the item: `operator` (a browser session), `agent` (a key), `mail` (the node's connector and the domain pipe: `human: false`, no key) |
| corporation_id, application_id, contact_id, mission_id | the writer, the filer or `file` | where it belongs. A mission implies its application; an application or a contact implies its corporation: the judge fills what is implied and refuses a contradiction |
| filing, filed_by, evidence | the judge | below |
| seen | anyone | the reply marker on an inbound item |

**Filing.** An item is `filed` when it names any of its four refs, `unfiled`
when it names none, `ignored` when the operator or an agent dismissed it
(`ignore`: the refs cleared). On an inbound insert that names no ref the
judge runs the filer (kernel.md's `filer::file`, reading the item as its
`Input` and the stored mail through the type's `Stored`): `filed` with
`filed_by: matcher`, or `unfiled`, either way with `evidence` holding
`{"evidence": [...], "candidates": [...]}`. A bounce the filer recognizes
marks the returned mail `bounced_at` and fails its mission if it is fired
(`fire::bounced`, rule 2); a confirmation mail confirms a provisional
mission (rule 3). A put
that sets a ref files the item by the op's writer (`filed_by: operator |
agent | mail`); the `file` command is the same write under a name and must
name at least one ref. A filed item stays filed until `ignore` or a put
that clears every ref.

**Status** is derived, never stored: `received` for an inbound item, `sent`
for an outbound one, `bounced` for an outbound email whose `bounced_at` is
set; a note has none. A careers-page or other self-reported item is
`sent`; whether it is provisional or confirmed is its mission's
`confirmation` (kernel.md, rule 3), which the item's JSON carries.

## The variants

| kind | own fields | invariants |
| --- | --- | --- |
| `email` (OutreachEmail) | from_addr, to_addr, cc_addr, reply_to, message_id, in_reply_to, refs, thread_key, gmail_msgid, gmail_thrid, labels, headers, pipe, bounced_at | inbound needs `from_addr`; outbound needs `to_addr`. `to_addr` and `cc_addr` hold 1 to 10 and 0 to 10 addresses (`local@domain`; `Name <local@domain>` accepted, stored bare; so are `from_addr` and `reply_to`). `message_id` is stored in one form (trimmed, one pair of angle brackets, case kept) and is the natural key, compared in that form on the node too (`Hireme.Kernel.message_id/1`), so a second pipe's copy of the same mail updates the row however it spells the id; it is fixed once written. `thread_key` is the filer's, else the root of `refs`, else `in_reply_to`, else `message_id` |
| `careers_page` (OutreachCareersPage) | fields (json: the fields as submitted), reference (the confirmation or application number the page showed) | outbound only; `link` (the form) required |
| `linkedin` (OutreachLinkedIn) | handle (the profile's vanity name) | direction required |
| `x_dm` (OutreachTwitterDm) | handle (`@name`, stored without `@`) | direction required |
| `discord` (OutreachDiscord) | handle (`user`, or `server/#channel`) | direction required |
| `other` (OutreachOther) | channel (the channel's name: `slack`, `phone`, `meetup`), handle | direction and `channel` required. A channel that earns rows of its own becomes a kind appended to `outreach_kind` |
| `note` (OutreachNote) | none | no direction; `body` required |

Shared by every variant: `kind`, `direction`, `message_id` and `actor` are
fixed once written (an update that changes one is refused `column` with
`reason: "fixed"`). An agent's outbound `linkedin`, `x_dm`, `discord`,
`careers_page` or `other` item needs a `report` (the obligation in
passthrough.md point 3); the operator's does not. `link`, when given, is an
http(s) URL on a real host (`sources` rule). `handle` is at most 200 bytes.
An invariant breaks as refusal `type` with `{table: "outreach", column,
reason}`.

## The item as JSON

What `outreach` (below), the desk card and the MCP answer per row: the
core flat, the variant's own fields under its kind, nothing of another
variant.

```json
{"id": 41, "kind": "email", "direction": "inbound", "status": "received",
 "at": "2026-10-22T09:40:12Z", "subject": "Re: Staff Engineer application",
 "body": "Thanks for applying ...", "body_format": "text", "link": null, "report": null,
 "actor": "mail", "filing": "filed", "filed_by": "matcher", "seen": false,
 "corporation_id": 3, "application_id": 120, "contact_id": 9, "mission_id": 33,
 "company": "Acme", "contact": "Dana Reyes", "application": "Acme · Staff Engineer",
 "confirmation": null,
 "email": {"from": "dana@acme.example", "to": ["matei3d@gmail.com"], "cc": [], "reply_to": null,
           "message_id": "<a1@acme.example>", "in_reply_to": "<hm.7f3a@gmail.com>", "refs": ["<hm.7f3a@gmail.com>"],
           "thread_key": "<hm.7f3a@gmail.com>", "gmail_msgid": 1234, "gmail_thrid": 1200, "labels": ["hireme"],
           "pipe": "gmail", "bounced_at": null},
 "evidence": {"evidence": [{"kind": "in_reply_to", "token": "hm.7f3a@gmail.com", "weight": 100, "table": "outreach", "id": 40}], "candidates": []},
 "rev": 2, "inserted_at": "2026-10-22T09:40:13Z", "updated_at": "2026-10-22T09:40:13Z"}
```

A linkedin item carries `"linkedin": {"handle": "danareyes"}`, a careers
page `"careers_page": {"fields": {...}, "reference": "APP-4012"}`, an other
`"other": {"channel": "slack", "handle": "dana"}`, a note `"note": {}`.
`company`, `contact` and `application` are the names of what the refs
point at (null when unlinked); `confirmation` is the mission's. `body` and
`report` are someone else's text: untrusted, as every text the MCP
returns. A plain `find` or `get` on `outreach` answers the row as any
table's (every column, nulls included); the item shape is the type's.

## The `outreach` query

One kernel op for the hub, the desk card and the MCP, on every host:

```json
{"op": "outreach",
 "where": {"application_id": 120, "at": {"ge": "2026-10-01T00:00:00Z"}},
 "search": "interview",
 "sort": ["at", "desc"], "group": "kind", "largest": false,
 "after": 0, "limit": 50}
```

- `where`: find's filters over the table's columns (`eq`, `ne`, `lt`, `le`,
  `gt`, `ge`, `in`, `null`, `like`, `prefix`); a date range is `at` with
  `ge`/`le`.
- `search`: ASCII-case-insensitive, over subject, body, report, from, to,
  cc, handle, reference, channel.
- `sort`: `at` (default, falling), `kind`, `company`, `contact`,
  `application`, `subject`, `from`, `handle`, `seen`; `[key, "asc"|"desc"]`
  or the key.
- `group`: `kind`, `direction`, `status`, `filing`, `actor`, `day`, `month`,
  `company`, `contact`, `application`, `mission`, `thread`, `handle`,
  `from`, `pipe`; `""` for none. `largest` puts the biggest group first.
- `after` is the row offset, `limit` 1 to 500 (50).

Answers `{"rows": [items], "groups": [{"key", "label", "start", "count"}],
"total", "next", "counts": {"unfiled": n, "unseen": n}}`: the page's groups
with absolute starts, the counts over the whole table (the tray's and the
reply marker's). An unknown key is refused `type` naming the known keys.
Reads need the mail bit, as any read of the table.

The application document (`application`, the desk card) carries
`"outreach": {"count", "unseen", "last_inbound_at"}`; the items come from
the query with `where: {application_id}`.

## The Rust API (`native/kernel/src/outreach.rs`)

```rust
pub enum Kind { Email, CareersPage, LinkedIn, XDm, Discord, Other, Note }
impl Kind {
    pub const NAMES: [&str; 7];
    pub fn from_code(u32) -> Option<Kind>; pub fn code(self) -> u32; pub fn name(self) -> &'static str;
    pub fn fireable(self) -> bool;               // every kind but Note: a mission may have it
    pub fn reports(self) -> bool;                // every kind but Email and Note: an agent's outbound item needs a report
    pub fn body_format(self) -> &'static str;    // "markdown" for Note, "text" otherwise
    pub fn brief(self) -> &'static str;          // the agent-facing text: what a mission of this kind produces and what to report
}
pub enum Direction { Outbound, Inbound }
pub enum Filing { Filed, Unfiled, Ignored }
pub enum FiledBy { Matcher, Operator, Agent, Mail }
pub enum Actor { Operator, Agent, System, Mail }
pub enum Pipe { Gmail, Domain, Hireme }
pub enum Status { Sent, Received, Bounced }

pub struct Refs { pub corporation_id: Option<u32>, pub application_id: Option<u32>, pub contact_id: Option<u32>, pub mission_id: Option<u32> }
pub struct Core { pub id: u32, pub kind: Kind, pub direction: Option<Direction>, pub at: i64, pub subject: Option<String>, pub body: Option<String>,
                  pub link: Option<String>, pub report: Option<String>, pub actor: Actor, pub filing: Filing, pub filed_by: Option<FiledBy>,
                  pub evidence: Option<Json>, pub seen: bool, pub refs: Refs, pub rev: i64, pub inserted_at: i64, pub updated_at: i64 }

pub struct Email { pub from: Option<String>, pub to: Vec<String>, pub cc: Vec<String>, pub reply_to: Option<String>, pub message_id: Option<String>,
                   pub in_reply_to: Option<String>, pub refs: Vec<String>, pub thread_key: Option<String>, pub gmail_msgid: Option<i64>,
                   pub gmail_thrid: Option<i64>, pub labels: Vec<String>, pub headers: Option<Json>, pub pipe: Option<Pipe>, pub bounced_at: Option<i64> }
pub struct CareersPage { pub fields: Option<Json>, pub reference: Option<String> }
pub struct LinkedIn { pub handle: Option<String> }
pub struct XDm { pub handle: Option<String> }
pub struct Discord { pub handle: Option<String> }
pub struct Other { pub channel: Option<String>, pub handle: Option<String> }
pub struct Note;
pub enum Body { Email(Box<Email>), CareersPage(CareersPage), LinkedIn(LinkedIn), XDm(XDm), Discord(Discord), Other(Other), Note(Note) }

pub struct Item<B = Body> { pub core: Core, pub body: B }
pub type OutreachItem = Item<Body>;
pub type OutreachEmail = Item<Email>;          // and OutreachCareersPage, OutreachLinkedIn, OutreachTwitterDm (= Item<XDm>), OutreachDiscord, OutreachOther, OutreachNote

pub trait Variant: Sized { fn into_body(self) -> Body; fn from_body(b: Body) -> Result<Self, Body>; }

impl Item<Body> {
    pub fn read(t: &Table, id: u32) -> Option<Item>;                 // decode a row of the replica
    pub fn narrow<B: Variant>(self) -> Result<Item<B>, Item<Body>>;  // the guard: OutreachEmail from an OutreachItem; the judge's way to a mail's own rules
    pub fn status(&self) -> Option<Status>;
    pub fn input(&self) -> filer::Input<'_>;                         // what the filer's lexer reads: texts and headers, never the type
    pub fn json(&self, rows: &Rows) -> Json;                         // the item as JSON above
}
impl<B: Variant> From<Item<B>> for Item<Body>;                       // widening, free

pub fn addr(text: &str) -> Option<String>;                           // one address, bare
pub fn addrs(text: &str) -> Result<Vec<String>, Invariant>;          // 1 to 10 addresses, comma or U+001F separated; what to_addr and a mission's target must hold
pub fn message_id_form(id: &str) -> String;                          // the stored form of a Message-ID
pub fn canon(id: &str) -> String;                                    // a Message-ID as it compares: no brackets or spaces, lowercase
pub fn thread_root(refs: &[String], in_reply_to: Option<&str>, message_id: Option<&str>) -> Option<String>;

// The stored mail the filer asks about (filer::Store): the outreach table answers it. mail_match reads it too.
pub struct Stored<'a>(pub &'a Rows);
impl filer::Store for Stored<'_> { fn by_message_id(&self, id: &str) -> Option<filer::Known>; fn by_thread(&self, gmail_thrid: i64) -> Option<filer::Known>; }

// The judge's hooks (one line each in judge.rs and abi.rs, the kernel's):
pub fn put(rows: &Rows, op: &Op, ctx: &Ctx, row: &mut judge::Row, extra: &mut Vec<judge::Row>) -> Result<(), Refusal>;
pub fn command(rows: &Rows, op: &Op, ctx: &Ctx) -> judge::Verdict;  // file, ignore
pub fn query(rows: &Rows, g: &Grants, req: &Json, today: Day) -> Result<Json, Refusal>;
pub fn summary(rows: &Rows, application_id: u32) -> Json;

// For the landed command (kernel.md): the sent mail's record, inserted, or the row Gmail's copy already made, updated.
pub struct Shot<'a> { pub mission_id: u32, pub application_id: u32, pub contact_id: Option<u32>, pub corporation_id: Option<u32>,
    pub from: &'a str, pub to: &'a [String], pub cc: &'a [String], pub subject: Option<&'a str>, pub body: Option<&'a str>,
    pub in_reply_to: Option<&'a str>, pub refs: &'a [String], pub message_id: &'a str, pub gmail_msgid: Option<i64>, pub gmail_thrid: Option<i64> }
pub fn sent_record(rows: &Rows, shot: &Shot<'_>, now: i64) -> judge::Row;
pub fn by_message_id(rows: &Rows, message_id: &str) -> Option<u32>; // canonical comparison: no brackets or spaces, lowercase
```

`put` builds the item as the row would stand after the op (the row's cells
under the op's), checks every invariant, fills what is derived (`at`,
`actor`, the implied refs, `thread_key`, `filing`, `filed_by`), and runs
the filer for an inbound insert that names no ref: its refs, thread and
evidence land on the row, a bounce marks the returned mail and fails its
mission, a confirmation confirms a provisional one. Nothing else in the
kernel reads an outreach cell by column id: every reader goes through
`Item` (the filer's `Stored` included).

## The Elixir API (`lib/hireme/outreach.ex`)

```elixir
Hireme.Outreach.kinds()                      # [:email, :careers_page, :linkedin, :x_dm, :discord, :other, :note], pinned to the declaration at compile time
Hireme.Outreach.module(:email)               # Hireme.Outreach.Email
Hireme.Outreach.from_row(row)                # %Hireme.Rows.Outreach{} or a find's map -> the variant struct
Hireme.Outreach.cells(item)                  # the writable columns as a put's cells (%{"kind" => "email", ...}), lists joined
Hireme.Outreach.op(item, opts)               # the decoded op Hireme.Sequencer.call/3 takes (keyed by message_id when it has one; target: for an update)
Hireme.Outreach.status(item)                 # :sent | :received | :bounced | nil
Hireme.Outreach.refs(item)                   # %{corporation_id: _, application_id: _, contact_id: _, mission_id: _}

import Hireme.Outreach, only: [is_item: 1, is_email: 1, is_inbound: 1, is_outbound: 1, is_kind: 2, is_email_mission: 1]
def send(%Hireme.Outreach.Email{direction: :outbound} = e), do: ...
def ingest(item) when is_inbound(item), do: ...
def hand_off(mission) when is_email_mission(mission), do: ...   # a mission row (or map) whose kind is :email

# Variants: %Hireme.Outreach.Email{}, CareersPage, LinkedIn, XDm, Discord, Other, Note: the core fields
# (:id, :kind, :direction, :at, :subject, :body, :link, :report, :actor, :filing, :filed_by, :evidence, :seen,
#  :corporation_id, :application_id, :contact_id, :mission_id, :rev, :inserted_at, :updated_at) plus their own.

Hireme.Outreach.Email.inbound(parsed)        # the node's parsed mail -> %Email{direction: :inbound}; keys: message_id, in_reply_to, refs (list or text),
                                             # from, to, cc, reply_to, subject, text, date (DateTime or unix), gmail_msgid, gmail_thrid, labels, pipe, headers, report
Hireme.Outreach.Email.shot(mission, from)    # a mission row in flight -> %Email{direction: :outbound}: what the sender reads
Hireme.Outreach.Email.recipients(email)      # to as a list (at most 10); Email.copies(email) the cc list
Hireme.Outreach.Email.addrs(text)            # comma or U+001F separated text -> list, bare addresses
```

The Elixir structs shape data and pattern-match; every rule is the kernel's
(the put is judged by `outreach::put` through the NIF), so a bad
construction is refused there, never checked twice.

## Per lane

**opus-lovelace (missions, the filer).** `missions.kind` becomes `enum
outreach_kind`; `Kind::fireable` says which values a mission may take. The
filer reads an item as its `Input` (`Item::input`) and the stored mail
through `outreach::Stored` (its `Store`), and never matches on the type;
the judge applies its `Filing` to the row, fails the fired mission a bounce
returns (`fire::bounced`) and confirms the mission a confirmation names.
`landed` on an email mission appends `outreach::sent_record(rows, &shot,
now)` to its effects (an insert, or an update of the row Gmail's Sent copy
made first). `outreach::addrs` is the one reading of a mission's `target`
for email. `by_message_id` finds the account's sent mail a bounce or a reply
names.

**opus-hopper (the node).** An inbound mail is `Email.inbound(parsed)`,
written as the mail actor (`%Hireme.Grants{actor: :key, key_id: nil}` with
the mail bit) by `Sequencer.call(account_id, actor, [Outreach.op(item)])`:
keyed by Message-ID, so the second pipe's copy updates the first's row; the
judge files it. The Gmail copy of a mail the node sent is ingested the same
way with `direction: :outbound` and lands on the row `landed` made (or
makes it; `landed` then updates). What the sender reads off a mission in
flight is `Email.shot(mission, from)`: `recipients/1` (1 to 10), `copies/1`,
`subject`, `body`, `in_reply_to`, `refs`, `message_id`. `is_email_mission/1`
is the hand-off guard.

**opus-eliza (the MCP).** The mission brief's "what outreach it will
produce, and what it needs to do to write its reports" is `Kind::brief`,
one text per kind; the kernel's `mission_brief` answer (kernel.md) carries
it as `brief`, so both hosts print the same words. A tool `outreach`
on both hosts runs the query op and prints the rows under their group
headings, as the desk's find does. `put` on `outreach` works as on any
table; the text tool's description names `outreach.body`.

**opus-noether (the page).** The hub and the desk card read the `outreach`
op (one call per draw, `where` per lens) and render each item by `kind`
with its own fields; the groups are the page's; `counts.unfiled` is the
tray's badge and `counts.unseen` the reply marker. Manual items are a put of
the item's cells; `file` and `ignore` are commands; `seen` is a put. The
`messages` table and its `channel`, `status` and `sent_at` columns are gone
with the migration.

## Not here

Drafts, fire, the key windows and the filer's rules: kernel.md. The Gmail
connector's parsing bounds: hopper's. The page's rendering of markdown: the
page's. A `delivered` status: nothing reports it.
