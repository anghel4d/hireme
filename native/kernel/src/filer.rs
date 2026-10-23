//! The filer: where an outreach item belongs, read by a simple, regular
//! machine (the operator's word: "Make sure the parsing itself is a simple
//! and regular machine").
//!
//! Two stages, neither of which backtracks or guesses:
//!
//! 1. **The lexer**, one left-to-right pass over the bytes of each text: a
//!    finite automaton cuts the text into chunks (runs of the characters an
//!    address, a URL, a domain or a word is made of), and each chunk is
//!    classified by a second automaton in one pass over it, into tokens:
//!    Message-IDs, addresses and their domains, URLs with their host and
//!    path, bare domains, numbers and words.
//! 2. **The correlator**, lookups of those tokens against the replica
//!    (sent Message-IDs, missions, corporations' domains and ATS tenants,
//!    applications' canonical URLs and roles, contacts), scored by one fixed
//!    evidence table. Same input, same filing, explainable token by token.

use alloc::string::String;
use alloc::vec::Vec;

/// What a token is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Class {
    /// `<local@domain>`, the brackets kept off.
    MsgId,
    /// `local@domain`, lowercased.
    Address,
    /// `http(s)://host/path`, as written but for trailing punctuation.
    Url,
    /// A dotted host name with a letter TLD (`acme.example`), lowercased.
    Domain,
    /// A run of ASCII digits.
    Number,
    /// A run of letters and digits, ASCII lowercased.
    Word,
}

/// One token: its class, its text (normalized as the class says) and where
/// it began in its text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Token {
    pub class: Class,
    pub text: String,
    pub at: usize,
}

/// The characters a chunk is made of: what an address, a URL, a domain, a
/// Message-ID or a word may contain. Anything else ends a chunk.
fn chunky(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c >= 0x80 || b"._%+-@:/?=&#~<>!$*'(),;[]".contains(&c)
}

/// Letters and digits of a word (UTF-8's continuation and lead bytes count
/// as letters, so `Zürich` is one word).
fn wordy(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c >= 0x80
}

/// A host name: dotted labels of letters, digits and hyphens (not at a
/// label's ends), the last one letters only, two labels at least.
fn host(s: &str) -> bool {
    if s.len() > 253 || s.is_empty() {
        return false;
    }
    let mut labels = 0;
    let mut last = "";
    for l in s.split('.') {
        if l.is_empty() || l.len() > 63 || l.starts_with('-') || l.ends_with('-') || !l.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') {
            return false;
        }
        labels += 1;
        last = l;
    }
    labels >= 2 && last.len() >= 2 && last.bytes().all(|c| c.is_ascii_alphabetic())
}

/// An address's local part: the characters mail allows unquoted.
fn local(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|c| c.is_ascii_alphanumeric() || b"._%+-!#$&'*/=?^`{|}~".contains(&c)) && !s.starts_with('.') && !s.ends_with('.')
}

/// The tokens of one text, in order. A chunk that is a Message-ID, a URL,
/// an address or a domain is that one token (an address adds its domain);
/// any other chunk is its words and numbers.
pub fn lex(text: &str) -> Vec<Token> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if !chunky(b[i]) {
            i += 1;
            continue;
        }
        let start = i;
        while i < b.len() && chunky(b[i]) {
            i += 1;
        }
        classify(text, start, i, &mut out);
    }
    out
}

/// One chunk `text[start..end]`, classified in one pass.
fn classify(text: &str, start: usize, end: usize, out: &mut Vec<Token>) {
    let b = text.as_bytes();
    // A Message-ID: the whole chunk bracketed, one @ inside.
    if b[start] == b'<'
        && let Some(close) = b[start..end].iter().position(|&c| c == b'>')
    {
        let inner = &text[start + 1..start + close];
        if let Some((l, d)) = inner.split_once('@')
            && !l.is_empty()
            && !d.is_empty()
            && !d.contains('@')
            && inner.bytes().all(|c| c.is_ascii_graphic() && c != b'<' && c != b'>')
        {
            out.push(Token { class: Class::MsgId, text: inner.into(), at: start });
            // `Name <addr>` brackets an address the same way: it is one too.
            let lower = inner.to_ascii_lowercase();
            if let Some((l, d)) = lower.split_once('@')
                && local(l)
                && host(d)
            {
                out.push(Token { class: Class::Address, text: lower.clone(), at: start + 1 });
                out.push(Token { class: Class::Domain, text: d.into(), at: start + 2 + l.len() });
            }
            // What follows the bracket is a chunk of its own.
            if start + close + 1 < end {
                classify(text, start + close + 1, end, out);
            }
            return;
        }
    }
    // Brackets and trailing punctuation are not part of a URL, an address or
    // a domain: trim them off both ends.
    let mut s = start;
    let mut e = end;
    while s < e && b"<([".contains(&b[s]) {
        s += 1;
    }
    while e > s && b".,;:!?)]'>".contains(&b[e - 1]) {
        e -= 1;
    }
    if s == e {
        return;
    }
    let chunk = &text[s..e];
    let lower = chunk.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        let rest = &lower[lower.find("//").map_or(0, |p| p + 2)..];
        let h = rest.split(['/', '?', '#']).next().unwrap_or("");
        let h = h.rsplit('@').next().unwrap_or(h).split(':').next().unwrap_or("");
        if host(h) {
            out.push(Token { class: Class::Url, text: chunk.into(), at: s });
            out.push(Token { class: Class::Domain, text: h.into(), at: s });
            return;
        }
    }
    if let Some((l, d)) = lower.split_once('@')
        && local(l)
        && host(d)
    {
        out.push(Token { class: Class::Address, text: lower.clone(), at: s });
        out.push(Token { class: Class::Domain, text: d.into(), at: s + l.len() + 1 });
        return;
    }
    if lower.contains('.') && host(&lower) {
        out.push(Token { class: Class::Domain, text: lower, at: s });
        return;
    }
    // Words and numbers: the runs of letters and digits.
    let mut i = start;
    while i < end {
        if !wordy(b[i]) {
            i += 1;
            continue;
        }
        let w = i;
        while i < end && wordy(b[i]) {
            i += 1;
        }
        let word = &text[w..i];
        let class = if word.bytes().all(|c| c.is_ascii_digit()) { Class::Number } else { Class::Word };
        out.push(Token { class, text: word.to_ascii_lowercase(), at: w });
    }
}

/// A Message-ID as one canonical form, for comparing: no brackets or
/// spaces, ASCII lowercased. Stored ids keep their case (a reply must echo
/// one exactly); only comparisons fold it.
pub fn canonical_id(id: &str) -> String {
    id.trim().trim_start_matches('<').trim_end_matches('>').trim().to_ascii_lowercase()
}

/// The Message-IDs of a header (In-Reply-To, References): every bracketed
/// id in it, in order.
pub fn ids(header: &str) -> Vec<String> {
    lex(header).into_iter().filter(|t| t.class == Class::MsgId).map(|t| t.text).collect()
}

/// The words of a text as one lowercased line, joined by single spaces:
/// what the phrase rules (a confirmation's wording, a role's words) read.
pub fn words(text: &str) -> String {
    let mut s = String::with_capacity(text.len());
    for t in lex(text).into_iter().filter(|t| matches!(t.class, Class::Word | Class::Number)) {
        if !s.is_empty() {
            s.push(' ');
        }
        s.push_str(&t.text);
    }
    s
}

// ------------------------------------------------------------------ the correlator

use schema::col::{applications as A, contacts as C, corporations as CO, missions as M};
use schema::{enums, table};
use serde_json::{json, Value as Json};

use crate::ats::under;
use crate::pipeline::Stage;
use crate::rows::{Rows, Table};

/// The evidence table: every kind of evidence and its weight. Certain
/// evidence files an item by itself; the rest adds up per corporation.
pub const THREAD: u32 = 100;
pub const BOUNCE: u32 = 100;
pub const GMAIL_THREAD: u32 = 100;
pub const URL: u32 = 90;
pub const CONTACT: u32 = 60;
pub const ATS_TENANT: u32 = 50;
pub const SENDER_DOMAIN: u32 = 50;
pub const NAME: u32 = 20;
pub const ROLE: u32 = 20;
pub const ATS_SENDER: u32 = 10;
/// A corporation's evidence that, alone among the corporations, files.
pub const ENOUGH: u32 = 50;

/// One item as the filer reads it: its texts, and an email's headers.
#[derive(Clone, Copy, Debug, Default)]
pub struct Input<'a> {
    pub email: bool,
    pub inbound: bool,
    pub subject: &'a str,
    pub body: &'a str,
    pub report: &'a str,
    /// `Name <addr>` or `addr`.
    pub from: &'a str,
    pub to: &'a [String],
    pub cc: &'a [String],
    pub reply_to: &'a str,
    pub message_id: &'a str,
    pub in_reply_to: &'a str,
    pub refs: &'a [String],
    pub gmail_thrid: Option<i64>,
    /// list-id, auto-submitted, and a bounce's `report` object.
    pub headers: Option<&'a Json>,
    pub link: &'a str,
    pub handle: &'a str,
}

/// What the account already holds under a Message-ID or a Gmail thread:
/// the item's refs and thread (the outreach type answers it).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Known {
    pub row: Option<u32>,
    pub application_id: Option<u32>,
    pub corporation_id: Option<u32>,
    pub contact_id: Option<u32>,
    pub mission_id: Option<u32>,
    pub thread_key: Option<String>,
}

/// The stored mail the correlator asks about; the outreach type is it.
pub trait Store {
    fn by_message_id(&self, id: &str) -> Option<Known>;
    fn by_thread(&self, gmail_thrid: i64) -> Option<Known>;
}

/// Holds nothing: the missions alone (a mail's first sight, or a replica
/// without the outreach table).
pub struct NoStore;

impl Store for NoStore {
    fn by_message_id(&self, _: &str) -> Option<Known> {
        None
    }

    fn by_thread(&self, _: i64) -> Option<Known> {
        None
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Evidence {
    pub kind: &'static str,
    pub token: String,
    pub weight: u32,
    pub table: &'static str,
    pub id: u32,
}

impl Evidence {
    pub fn json(&self) -> Json {
        json!({"kind": self.kind, "token": self.token, "weight": self.weight, "table": self.table, "id": self.id})
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub table: &'static str,
    pub id: u32,
    pub label: String,
    pub score: u32,
}

impl Candidate {
    pub fn json(&self) -> Json {
        json!({"table": self.table, "id": self.id, "label": self.label, "score": self.score})
    }
}

/// Where an item belongs, and why.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Filing {
    /// It reaches the desk at all: what the node reads and labels.
    pub relevant: bool,
    pub filed: bool,
    pub application_id: Option<u32>,
    pub corporation_id: Option<u32>,
    pub contact_id: Option<u32>,
    pub mission_id: Option<u32>,
    pub thread_key: Option<String>,
    pub evidence: Vec<Evidence>,
    pub candidates: Vec<Candidate>,
    /// A bounce of the mail this mission sent (the row the store names).
    pub bounce: Option<(u32, Option<u32>)>,
    /// A confirmation mail for this provisional mission.
    pub confirms: Option<u32>,
}

impl Filing {
    pub fn json(&self) -> Json {
        json!({
            "relevant": self.relevant, "filing": if self.filed { "filed" } else { "unfiled" },
            "application_id": self.application_id, "corporation_id": self.corporation_id,
            "contact_id": self.contact_id, "mission_id": self.mission_id, "thread_key": self.thread_key,
            "evidence": self.evidence.iter().map(Evidence::json).collect::<Vec<_>>(),
            "candidates": self.candidates.iter().map(Candidate::json).collect::<Vec<_>>(),
            "bounce_of": self.bounce.map(|b| b.0), "confirms": self.confirms,
        })
    }
}

/// Hosts anyone's mail comes from: a sender there names no corporation.
const FREEMAIL: [&str; 27] = [
    "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com", "icloud.com", "me.com",
    "mac.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.de", "gmx.net", "web.de", "mail.com", "yandex.com",
    "yandex.ru", "zoho.com", "fastmail.com", "hey.com", "qq.com", "163.com",
];

/// The applicant tracking systems' sending hosts, by the vendor names
/// `corporations.ats` holds (ats.rs's).
const ATS_SENDERS: [(&str, &[&str]); 14] = [
    ("greenhouse", &["greenhouse.io", "greenhouse-mail.io"]),
    ("lever", &["lever.co"]),
    ("ashby", &["ashbyhq.com"]),
    ("workday", &["myworkday.com", "myworkdayjobs.com", "workday.com"]),
    ("icims", &["icims.com"]),
    ("smartrecruiters", &["smartrecruiters.com"]),
    ("workable", &["workable.com", "workablemail.com"]),
    ("jobvite", &["jobvite.com"]),
    ("taleo", &["taleo.net"]),
    ("successfactors", &["successfactors.com", "successfactors.eu", "sapsf.com"]),
    ("bamboohr", &["bamboohr.com"]),
    ("rippling", &["rippling.com"]),
    ("eightfold", &["eightfold.ai"]),
    ("gem", &["gem.com"]),
];

/// A confirmation's wording (rule 3): a job board saying it has the
/// application. Matched as whole words in the lowercased text.
const CONFIRMATIONS: [&str; 9] = [
    "thank you for applying", "thanks for applying", "we have received your application", "we ve received your application",
    "we received your application", "your application has been received", "application received", "thank you for your application",
    "your application was submitted",
];

/// A delivery failure's wording, beside a mailer-daemon sender.
const BOUNCES: [&str; 6] = ["undeliverable", "delivery status notification", "mail delivery failed", "returned mail", "delivery failure", "failure notice"];

/// The bare address of `Name <addr>` or `addr`, lowercased.
pub fn address(from: &str) -> Option<String> {
    lex(from).into_iter().find(|t| t.class == Class::Address).map(|t| t.text)
}

fn domain_of(addr: &str) -> &str {
    addr.rsplit_once('@').map_or("", |(_, d)| d)
}

/// Whole-word containment: `phrase` (words joined by spaces) in `line`.
fn has_phrase(line: &str, phrase: &str) -> bool {
    !phrase.is_empty() && alloc::format!(" {line} ").contains(&alloc::format!(" {phrase} "))
}

/// A mission's refs: its application, that application's corporation, its contact.
fn mission_target(rows: &Rows, mission: u32) -> Known {
    let ms = rows.table(table::MISSIONS);
    let app = ms.and_then(|t| t.u32(mission, M::APPLICATION_ID));
    Known {
        row: None,
        application_id: app,
        corporation_id: app.and_then(|a| rows.table(table::APPLICATIONS).and_then(|t| t.u32(a, A::CORPORATION_ID))),
        contact_id: ms.and_then(|t| t.u32(mission, M::CONTACT_ID)),
        mission_id: Some(mission),
        thread_key: ms.and_then(|t| t.str(mission, M::MESSAGE_ID)).map(String::from),
    }
}

fn mission_by_message_id(rows: &Rows, id: &str) -> Option<u32> {
    let want = canonical_id(id);
    rows.each(table::MISSIONS).find(|(t, m)| t.str(*m, M::MESSAGE_ID).is_some_and(|x| canonical_id(x) == want)).map(|(_, m)| m)
}

/// An application in play: it went out, or one of its missions is in
/// flight or fired.
fn live(rows: &Rows, apps: &Table, app: u32) -> bool {
    let stage = apps.u32(app, A::STAGE).and_then(Stage::from_u32).unwrap_or(Stage::Discovered);
    if matches!(stage, Stage::Submitted | Stage::Reply) {
        return true;
    }
    rows.each(table::MISSIONS).any(|(t, m)| {
        t.u32(m, M::APPLICATION_ID) == Some(app)
            && [enums::mission_state::IN_FLIGHT, enums::mission_state::FIRED].contains(&(t.u32(m, M::STATE).unwrap_or(0) as u8))
    })
}

fn app_label(apps: &Table, app: u32) -> String {
    alloc::format!("{} · {}", apps.str(app, A::COMPANY).unwrap_or(""), apps.str(app, A::ROLE).unwrap_or(""))
}

/// Files one item: the lexer's tokens of every text, looked up against the
/// replica and `store`, scored by the evidence table.
pub fn file(rows: &Rows, store: &dyn Store, input: &Input) -> Filing {
    let mut f = Filing::default();
    let mut certain: Vec<Known> = Vec::new();
    let texts = [input.subject, input.body, input.report, input.link];
    let tokens: Vec<Token> = texts.iter().flat_map(|t| lex(t)).collect();
    let line = words(&alloc::format!("{} {}", input.subject, input.body));
    let subject_line = words(input.subject);

    // A sender whose domain's DMARC failed is not who it says it is: nothing
    // drawn from the sender counts, and nothing files on its own.
    let forged = input.email
        && input.inbound
        && input.headers.and_then(|h| h.get("authentication-results")).is_some_and(|v| {
            let text = match v {
                Json::Array(a) => a.iter().filter_map(Json::as_str).collect::<Vec<_>>().join(" "),
                _ => v.as_str().unwrap_or("").into(),
            };
            has_phrase(&words(&text), "dmarc fail")
        });
    if forged {
        f.evidence.push(Evidence { kind: "dmarc_fail", token: address(input.from).unwrap_or_default(), weight: 0, table: "", id: 0 });
    }
    // Gmail's copy of a mail hireme sent carries the id the mission stamped.
    if !input.message_id.trim().is_empty()
        && let Some(m) = mission_by_message_id(rows, input.message_id)
    {
        f.evidence.push(Evidence { kind: "sent", token: canonical_id(input.message_id), weight: THREAD, table: "missions", id: m });
        certain.push(mission_target(rows, m));
    }
    // The thread: a reply names the mail it answers.
    let mut thread: Vec<(&'static str, String)> = ids(input.in_reply_to).into_iter().map(|i| ("in_reply_to", i)).collect();
    if thread.is_empty() && !input.in_reply_to.trim().is_empty() {
        thread.push(("in_reply_to", canonical_id(input.in_reply_to)));
    }
    for r in input.refs {
        let found = ids(r);
        if found.is_empty() {
            thread.push(("refs", canonical_id(r)));
        }
        thread.extend(found.into_iter().map(|i| ("refs", i)));
    }
    for (kind, id) in &thread {
        if let Some(m) = mission_by_message_id(rows, id) {
            f.evidence.push(Evidence { kind, token: id.clone(), weight: THREAD, table: "missions", id: m });
            certain.push(mission_target(rows, m));
        } else if let Some(k) = store.by_message_id(id).filter(|k| k.application_id.is_some() || k.corporation_id.is_some() || k.contact_id.is_some() || k.mission_id.is_some()) {
            f.evidence.push(Evidence { kind, token: id.clone(), weight: THREAD, table: "outreach", id: k.row.unwrap_or(0) });
            certain.push(k);
        }
    }
    if let Some(thrid) = input.gmail_thrid {
        if let Some((_, m)) = rows.each(table::MISSIONS).find(|(t, m)| t.i64(*m, M::GMAIL_THRID) == Some(thrid)) {
            f.evidence.push(Evidence { kind: "gmail_thread", token: alloc::format!("{thrid}"), weight: GMAIL_THREAD, table: "missions", id: m });
            certain.push(mission_target(rows, m));
        } else if let Some(k) = store.by_thread(thrid).filter(|k| k.application_id.is_some() || k.corporation_id.is_some()) {
            f.evidence.push(Evidence { kind: "gmail_thread", token: alloc::format!("{thrid}"), weight: GMAIL_THREAD, table: "outreach", id: k.row.unwrap_or(0) });
            certain.push(k);
        }
    }

    // A bounce names the mail it returns: the report's original Message-ID,
    // else a mailer-daemon's text quoting one of the account's sent ids.
    let sender = address(input.from).unwrap_or_default();
    if input.email && input.inbound {
        let reported = input.headers.and_then(|h| h.get("report")).filter(|r| r.get("kind").and_then(Json::as_str) == Some("bounce"));
        let mut original: Vec<String> = reported.and_then(|r| r.get("original_message_id")).and_then(Json::as_str).map(|i| alloc::vec![canonical_id(i)]).unwrap_or_default();
        let daemon = sender.split('@').next().is_some_and(|l| ["mailer-daemon", "postmaster", "mail-daemon"].contains(&l));
        if original.is_empty() && daemon && BOUNCES.iter().any(|b| has_phrase(&subject_line, b) || has_phrase(&line, b)) {
            original = tokens.iter().filter(|t| t.class == Class::MsgId).map(|t| canonical_id(&t.text)).collect();
        }
        if let Some((id, m)) = original.iter().find_map(|i| mission_by_message_id(rows, i).map(|m| (i.clone(), m))) {
            f.evidence.push(Evidence { kind: "bounce", token: id.clone(), weight: BOUNCE, table: "missions", id: m });
            f.bounce = Some((m, store.by_message_id(&id).and_then(|k| k.row)));
            certain.push(mission_target(rows, m));
        }
    }

    // A link to a posting the desk holds.
    let apps = rows.table(table::APPLICATIONS);
    if let Some(at) = apps {
        for t in tokens.iter().filter(|t| t.class == Class::Url) {
            let Some(c) = crate::ats::canonical(&t.text) else { continue };
            if let Some(app) = at.ids().iter().copied().find(|&a| at.str(a, A::CANONICAL_URL) == Some(c.as_str())) {
                f.evidence.push(Evidence { kind: "url", token: c, weight: URL, table: "applications", id: app });
                certain.push(Known { application_id: Some(app), corporation_id: at.u32(app, A::CORPORATION_ID), ..Known::default() });
            }
        }
    }

    // The corporation's evidence, summed.
    let mut corp: Vec<(u32, u32)> = Vec::new();
    let add = |corp: &mut Vec<(u32, u32)>, c: u32, w: u32| match corp.iter_mut().find(|x| x.0 == c) {
        Some(x) => x.1 += w,
        None => corp.push((c, w)),
    };
    // The people on the other end: a mail's sender (or its recipients when
    // it went out), a message's handle.
    let parties: Vec<String> = if forged {
        Vec::new()
    } else if input.inbound {
        [input.from, input.reply_to].iter().filter_map(|a| address(a)).collect()
    } else {
        input.to.iter().chain(input.cc).filter_map(|a| address(a)).collect()
    };
    let contacts = rows.table(table::CONTACTS);
    let mut contact: Option<u32> = None;
    if let Some(ct) = contacts {
        for id in ct.ids().iter().copied() {
            let email = ct.str(id, C::EMAIL).map(str::to_ascii_lowercase);
            let by_mail = email.as_deref().is_some_and(|e| parties.iter().any(|p| p == e));
            let h = input.handle.trim().trim_start_matches('@').to_ascii_lowercase();
            let by_handle = !h.is_empty()
                && (ct.str(id, C::X_HANDLE).is_some_and(|x| x.trim_start_matches('@').eq_ignore_ascii_case(&h))
                    || ct.str(id, C::LINKEDIN_URL).is_some_and(|u| u.to_ascii_lowercase().trim_end_matches('/').ends_with(&alloc::format!("/in/{h}"))));
            if by_mail || by_handle {
                f.evidence.push(Evidence { kind: if by_mail { "contact" } else { "handle" }, token: if by_mail { email.unwrap_or_default() } else { h }, weight: CONTACT, table: "contacts", id });
                contact = contact.or(Some(id));
                if let Some(c) = ct.u32(id, C::CORPORATION_ID) {
                    add(&mut corp, c, CONTACT);
                }
            }
        }
    }
    // The tracking system it came through, and the tenant it names.
    let corps = rows.table(table::CORPORATIONS);
    let party_domains: Vec<&str> = parties.iter().map(|p| domain_of(p)).collect();
    let vendor = party_domains.iter().find_map(|d| ATS_SENDERS.iter().find(|(_, roots)| roots.iter().any(|r| under(d, r))).map(|v| v.0));
    let mut tenants: Vec<(&'static str, String)> = Vec::new();
    if vendor == Some("workday")
        && let Some(local) = parties.iter().find(|p| ATS_SENDERS[3].1.iter().any(|r| under(domain_of(p), r))).and_then(|p| p.split('@').next())
    {
        tenants.push(("workday", local.into()));
    }
    for t in tokens.iter().filter(|t| t.class == Class::Url) {
        let a = crate::ats::parse(&t.text);
        if let Some(tenant) = a.tenant
            && a.vendor != crate::ats::Vendor::Unknown
        {
            tenants.push((a.vendor.name(), tenant.to_ascii_lowercase()));
        }
    }
    let mut tenant_hit = false;
    if let Some(ct) = corps {
        for (v, tenant) in &tenants {
            for c in ct.ids().iter().copied() {
                if ct.str(c, CO::ATS) == Some(*v) && ct.str(c, CO::ATS_TENANT).is_some_and(|x| x.eq_ignore_ascii_case(tenant)) {
                    f.evidence.push(Evidence { kind: "ats_tenant", token: alloc::format!("{v}:{tenant}"), weight: ATS_TENANT, table: "corporations", id: c });
                    add(&mut corp, c, ATS_TENANT);
                    tenant_hit = true;
                }
            }
        }
        // A sender's own domain, unless anyone's or a tracking system's.
        for d in party_domains.iter().filter(|d| !d.is_empty() && !FREEMAIL.contains(d) && !ATS_SENDERS.iter().any(|(_, roots)| roots.iter().any(|r| under(d, r)))) {
            for c in ct.ids().iter().copied() {
                let Some(cd) = ct.str(c, CO::DOMAIN) else { continue };
                if !cd.contains(':') && !cd.contains('/') && under(d, &cd.to_ascii_lowercase()) {
                    f.evidence.push(Evidence { kind: "sender_domain", token: (*d).into(), weight: SENDER_DOMAIN, table: "corporations", id: c });
                    add(&mut corp, c, SENDER_DOMAIN);
                }
            }
        }
        // A name in the subject, of a corporation the desk works with.
        if let Some(at) = apps {
            let mut desk: Vec<u32> = at.ids().iter().filter_map(|&a| at.u32(a, A::CORPORATION_ID)).collect();
            desk.sort_unstable();
            desk.dedup();
            for c in desk {
                let n = words(ct.str(c, CO::NAME).unwrap_or(""));
                if n.len() > 2 && has_phrase(&subject_line, &n) {
                    f.evidence.push(Evidence { kind: "name", token: n, weight: NAME, table: "corporations", id: c });
                    add(&mut corp, c, NAME);
                }
            }
        }
    }
    if vendor.is_some() && !tenant_hit {
        f.evidence.push(Evidence { kind: "ats_sender", token: vendor.unwrap_or("").into(), weight: ATS_SENDER, table: "", id: 0 });
    }

    // The decision. Certain evidence that agrees files; certain evidence
    // that disagrees files nothing.
    // A forged sender files nothing: its evidence and what it named stay for
    // the operator's tray.
    if forged {
        let mut named: Vec<u32> = certain.iter().filter_map(|k| k.application_id).collect();
        named.sort_unstable();
        named.dedup();
        if let Some(at) = apps {
            f.candidates = named.iter().map(|&a| Candidate { table: "applications", id: a, label: app_label(at, a), score: THREAD }).collect();
        }
        f.bounce = None;
        f.relevant = true;
        return f;
    }
    let mut apps_named: Vec<u32> = certain.iter().filter_map(|k| k.application_id).collect();
    apps_named.sort_unstable();
    apps_named.dedup();
    if !certain.is_empty() && apps_named.len() <= 1 {
        let best = certain.iter().find(|k| k.mission_id.is_some()).or_else(|| certain.iter().find(|k| k.application_id.is_some())).unwrap_or(&certain[0]).clone();
        f.filed = true;
        f.application_id = best.application_id.or(apps_named.first().copied());
        f.corporation_id = best.corporation_id.or_else(|| f.application_id.and_then(|a| apps.and_then(|t| t.u32(a, A::CORPORATION_ID))));
        f.contact_id = best.contact_id.or(contact);
        f.mission_id = best.mission_id;
        f.thread_key = certain.iter().find_map(|k| k.thread_key.clone()).map(|k| canonical_id(&k));
    } else if apps_named.len() > 1 {
        if let Some(at) = apps {
            f.candidates = apps_named.iter().map(|&a| Candidate { table: "applications", id: a, label: app_label(at, a), score: THREAD }).collect();
        }
    } else {
        corp.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let top = corp.first().copied().filter(|t| t.1 >= ENOUGH && corp.get(1).is_none_or(|s| s.1 < t.1));
        if let (Some((c, _)), Some(at)) = (top, apps) {
            let mine: Vec<u32> = at.ids().iter().copied().filter(|&a| at.u32(a, A::CORPORATION_ID) == Some(c)).collect();
            let in_play: Vec<u32> = mine.iter().copied().filter(|&a| live(rows, at, a)).collect();
            // Each application by how many of its role words the item's words hold.
            let overlap = |a: u32| words(at.str(a, A::ROLE).unwrap_or("")).split(' ').filter(|w| w.len() > 2 && has_phrase(&line, w)).count() as u32;
            let mut ranked: Vec<(u32, u32)> = mine.iter().map(|&a| (a, overlap(a))).collect();
            ranked.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            let by_role = ranked.first().filter(|r| r.1 >= 2 && ranked.get(1).is_none_or(|s| s.1 < r.1)).map(|r| r.0);
            let chosen = if in_play.len() == 1 { Some(in_play[0]) } else { by_role.filter(|a| in_play.is_empty() || in_play.contains(a)) };
            if let Some(a) = chosen {
                if by_role == Some(a) {
                    f.evidence.push(Evidence { kind: "role", token: words(at.str(a, A::ROLE).unwrap_or("")), weight: ROLE, table: "applications", id: a });
                }
                f.filed = true;
                f.application_id = Some(a);
                f.corporation_id = Some(c);
                f.contact_id = contact;
            } else if contact.is_some() && mine.is_empty() {
                // A person the operator knows, at a company with no
                // application: the item is theirs.
                f.filed = true;
                f.contact_id = contact;
                f.corporation_id = Some(c);
            } else {
                f.candidates = ranked.iter().map(|&(a, w)| Candidate { table: "applications", id: a, label: app_label(at, a), score: corp[0].1 + w * ROLE }).collect();
                f.candidates.push(Candidate { table: "corporations", id: c, label: corps.and_then(|t| t.str(c, CO::NAME)).unwrap_or("").into(), score: corp[0].1 });
            }
        } else if let Some(at) = apps {
            for &(c, w) in corp.iter().take(3) {
                f.candidates.push(Candidate { table: "corporations", id: c, label: corps.and_then(|t| t.str(c, CO::NAME)).unwrap_or("").into(), score: w });
                for a in at.ids().iter().copied().filter(|&a| at.u32(a, A::CORPORATION_ID) == Some(c)) {
                    f.candidates.push(Candidate { table: "applications", id: a, label: app_label(at, a), score: w });
                }
            }
        }
    }
    f.candidates.sort_by(|a, b| b.score.cmp(&a.score).then(a.id.cmp(&b.id)));
    f.candidates.truncate(8);

    // A confirmation mail confirms the provisional shot it answers.
    if f.filed && input.email && input.inbound && f.bounce.is_none() && CONFIRMATIONS.iter().any(|p| has_phrase(&line, p))
        && let Some(app) = f.application_id
    {
        f.confirms = rows
            .each(table::MISSIONS)
            .filter(|(t, m)| t.u32(*m, M::APPLICATION_ID) == Some(app) && t.u32(*m, M::CONFIRMATION) == Some(u32::from(enums::confirmation::PROVISIONAL)))
            .max_by_key(|(t, m)| (t.u32(*m, M::FIRED_AT).unwrap_or(0), *m))
            .map(|(_, m)| m);
    }
    let desk_corp = corp.iter().any(|&(c, w)| w >= ENOUGH && apps.is_some_and(|at| at.ids().iter().any(|&a| at.u32(a, A::CORPORATION_ID) == Some(c))));
    f.relevant = f.filed || !certain.is_empty() || contact.is_some() || vendor.is_some() || desk_corp;
    f
}

/// The node's question before it stores a mail (`mail_match`): the
/// envelope as JSON, answered as the filing.
pub fn match_json(rows: &Rows, store: &dyn Store, req: &Json) -> Json {
    let s = |k: &str| req.get(k).and_then(Json::as_str).unwrap_or("");
    let list = |k: &str| -> Vec<String> {
        match req.get(k) {
            Some(Json::Array(a)) => a.iter().filter_map(Json::as_str).map(String::from).collect(),
            Some(Json::String(t)) => t.split([',', '\u{1f}', ' ']).map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect(),
            _ => Vec::new(),
        }
    };
    let (to, cc, refs) = (list("to"), list("cc"), list("refs"));
    let input = Input {
        email: true,
        inbound: req.get("direction").and_then(Json::as_str) != Some("outbound"),
        subject: s("subject"),
        body: if s("text").is_empty() { s("body") } else { s("text") },
        report: "",
        from: s("from"),
        to: &to,
        cc: &cc,
        reply_to: s("reply_to"),
        message_id: s("message_id"),
        in_reply_to: s("in_reply_to"),
        refs: &refs,
        gmail_thrid: req.get("gmail_thrid").and_then(Json::as_i64),
        headers: req.get("headers").filter(|h| h.is_object()),
        link: "",
        handle: "",
    };
    // The bounce report travels beside the headers in the node's envelope.
    let merged;
    let input = match req.get("report") {
        Some(r) if r.is_object() => {
            let mut h = req.get("headers").cloned().filter(Json::is_object).unwrap_or_else(|| json!({}));
            h["report"] = r.clone();
            merged = h;
            Input { headers: Some(&merged), ..input }
        }
        _ => input,
    };
    file(rows, store, &input).json()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(Class, String)> {
        lex(text).into_iter().map(|t| (t.class, t.text)).collect()
    }

    #[test]
    fn a_text_lexes_into_its_tokens() {
        use Class::*;
        let got = kinds("Re: Staff Engineer at Acme (req 4012). Apply at https://job-boards.greenhouse.io/acme/jobs/4012?gh_src=x, or write to Jobs@Acme.example.");
        let want: Vec<(Class, String)> = [
            (Word, "re"), (Word, "staff"), (Word, "engineer"), (Word, "at"), (Word, "acme"), (Word, "req"), (Number, "4012"),
            (Word, "apply"), (Word, "at"), (Url, "https://job-boards.greenhouse.io/acme/jobs/4012?gh_src=x"), (Domain, "job-boards.greenhouse.io"),
            (Word, "or"), (Word, "write"), (Word, "to"), (Address, "jobs@acme.example"), (Domain, "acme.example"),
        ]
        .into_iter()
        .map(|(c, t)| (c, t.to_string()))
        .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn message_ids_come_out_whole() {
        assert_eq!(ids("<hm.7f3a@gmail.com> <CAB+x=y@mail.gmail.com>"), ["hm.7f3a@gmail.com", "CAB+x=y@mail.gmail.com"]);
        assert_eq!(canonical_id(" <CAB+X=Y@Mail.Gmail.com> "), "cab+x=y@mail.gmail.com");
        // A bracketed address is id-shaped: it is both, and its domain.
        let classes: Vec<Class> = kinds("Dana <dana@acme.example>").into_iter().map(|t| t.0).collect();
        assert_eq!(classes, [Class::Word, Class::MsgId, Class::Address, Class::Domain]);
    }

    #[test]
    fn hosts_and_words_are_what_they_look_like() {
        use Class::*;
        assert_eq!(kinds("acme.example"), [(Domain, "acme.example".to_string())]);
        assert_eq!(kinds("v1.2"), [(Word, "v1".to_string()), (Number, "2".to_string())]);
        assert_eq!(kinds("Zürich, Schweiz"), [(Word, "zürich".to_string()), (Word, "schweiz".to_string())]);
        assert_eq!(words("Senior   Staff-Engineer, Platform!"), "senior staff engineer platform");
        assert_eq!(kinds("mailto:x"), [(Word, "mailto".to_string()), (Word, "x".to_string())]);
    }

    /// Arbitrary bytes as text: the lexer ends, every token lies inside its
    /// text at the offset it names, and no two tokens start out of order.
    #[test]
    fn any_text_lexes_in_one_pass() {
        let alphabet = "aZ09.@<>:/-_ ,\n\t?=&#é(https://)x.co";
        let chars: Vec<char> = alphabet.chars().collect();
        let mut seed = 0x2545_f491_u32;
        let mut next = |n: u32| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed % n
        };
        for case in 0..2000 {
            let len = next(60);
            let text: String = (0..len).map(|_| chars[next(chars.len() as u32) as usize]).collect();
            let toks = lex(&text);
            let mut last = 0;
            for t in &toks {
                assert!(t.at < text.len().max(1) && t.at >= last, "case {case}: {text:?} {toks:?}");
                last = t.at;
                assert!(!t.text.is_empty(), "case {case}: {text:?}");
            }
        }
    }
}
