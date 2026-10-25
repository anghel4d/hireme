//! Row names as every page shows them (docs/mcp/refs.md): `<kind>:<key>`,
//! one kind per table; an application's key is its number, a corporation's
//! its domain, the rest their id. This is the one table of them: the
//! campaign writes a ref by it, the MCP's resolver reads one by it.

use alloc::string::String;
use core::fmt::Display;
use schema::table;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    App,
    Mission,
    Contact,
    Corp,
    Place,
    Outreach,
    Batch,
    FireKey,
    FireRequest,
}

/// Each kind, its prefix, its table and what its key is.
pub const KINDS: [(Kind, &str, u16, &str); 9] = [
    (Kind::App, "app", table::APPLICATIONS, "the application's number"),
    (Kind::Mission, "mission", table::MISSIONS, "id"),
    (Kind::Contact, "contact", table::CONTACTS, "id"),
    (Kind::Corp, "corp", table::CORPORATIONS, "domain"),
    (Kind::Place, "place", table::PLACES, "id"),
    (Kind::Outreach, "outreach", table::OUTREACH, "id"),
    (Kind::Batch, "batch", table::BATCHES, "id"),
    (Kind::FireKey, "fire_key", table::FIRE_KEYS, "id"),
    (Kind::FireRequest, "fire_request", table::FIRE_REQUESTS, "id"),
];

impl Kind {
    pub fn prefix(self) -> &'static str {
        KINDS.iter().find(|k| k.0 == self).map_or("", |k| k.1)
    }

    pub fn table(self) -> u16 {
        KINDS.iter().find(|k| k.0 == self).map_or(0, |k| k.2)
    }

    /// What the key is: the application's number, a domain, or an id.
    pub fn key(self) -> &'static str {
        KINDS.iter().find(|k| k.0 == self).map_or("id", |k| k.3)
    }

    /// What a ref of this kind looks like.
    pub fn form(self) -> String {
        alloc::format!("{}:<{}>", self.prefix(), self.key())
    }

    pub fn of_prefix(p: &str) -> Option<Kind> {
        KINDS.iter().find(|k| k.1 == p).map(|k| k.0)
    }

    pub fn of_table(t: u16) -> Option<Kind> {
        KINDS.iter().find(|k| k.2 == t).map(|k| k.0)
    }
}

/// The ref of a row of `kind` by its key.
pub fn of(kind: Kind, key: impl Display) -> String {
    alloc::format!("{}:{key}", kind.prefix())
}

/// The refs the kernel writes, by kind.
pub fn app(no: impl Display) -> String {
    of(Kind::App, no)
}

pub fn mission(id: impl Display) -> String {
    of(Kind::Mission, id)
}

pub fn contact(id: impl Display) -> String {
    of(Kind::Contact, id)
}

pub fn outreach(id: impl Display) -> String {
    of(Kind::Outreach, id)
}

pub fn request(id: impl Display) -> String {
    of(Kind::FireRequest, id)
}

/// A corporation's ref is its domain, lowercased.
pub fn corp(domain: &str) -> String {
    of(Kind::Corp, domain.trim().to_ascii_lowercase())
}
