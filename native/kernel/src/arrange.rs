//! The desk's select-by-sort, kdb-shaped: every catalog field (`mask`) as
//! one typed column over the applications (struct of arrays, aligned with
//! the table's slots), and `arrange`, which takes the board's filtered
//! ids, sorts them on one column and buckets them on another, returning
//! the order and the groups' bounds. The page only renders.
//!
//! A column is numbers (NaN for absent) or symbols: each distinct value
//! interned once, its id per slot, and a rank per symbol in reading order
//! ("Company 2" before "Company 10"; an enum in its declared order), so a
//! sort compares u32 ranks and a group-by buckets symbol ids. A column is
//! built in one pass over the slots and kept until a table it reads moves
//! (`Kernel`'s cache).

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;
use core::cmp::Ordering;

use serde_json::{Value as Json, json};

use crate::mask::{self, Facts, Ty, Val};
use crate::pick::{AppFacts, Counts};
use crate::rows::Rows;

/// No symbol: the value is absent.
pub const NONE: u32 = u32::MAX;

/// One field over every application, aligned with the applications' slots.
pub enum Col {
    Num(Vec<f64>),
    Sym { ids: Vec<u32>, dict: Vec<String>, rank: Vec<u32> },
}

/// The archetype a field reads, by application: the company's fields
/// depend on the corporation alone, the place's on the place, the office on
/// both, the role's on its title, the person's on nothing. None: the row.
enum Archetype {
    Key(fn(&crate::rows::Table, u32) -> u64),
    Title,
    Row,
}

fn archetype(path: &str) -> Archetype {
    use schema::col::applications as A;
    let id = |c: u16| move |t: &crate::rows::Table, id: u32| u64::from(t.u32(id, c).unwrap_or(u32::MAX));
    if path.starts_with("company.") {
        Archetype::Key(|t, id| id_of(t, id, A::CORPORATION_ID))
    } else if matches!(path, "place" | "country" | "city" | "region" | "subregion" | "country.applications") {
        Archetype::Key(|t, id| id_of(t, id, A::PLACE_ID))
    } else if path == "office" {
        Archetype::Key(|t, id| (id_of(t, id, A::CORPORATION_ID) << 32) | id_of(t, id, A::PLACE_ID))
    } else if path.starts_with("me.") {
        Archetype::Key(|_, _| 0)
    } else if matches!(path, "field" | "subfield" | "seniority") {
        let _ = id;
        Archetype::Title
    } else {
        Archetype::Row
    }
}

fn id_of(t: &crate::rows::Table, id: u32, c: u16) -> u64 {
    u64::from(t.u32(id, c).unwrap_or(u32::MAX))
}

/// A value's symbol in `dict`, interned once per spelling up to case.
struct Interner {
    exact: crate::keyed::Map<String, u32>,
    folded: crate::keyed::Map<String, u32>,
    dict: Vec<String>,
}

impl Interner {
    fn new() -> Interner {
        Interner { exact: crate::keyed::Map::default(), folded: crate::keyed::Map::default(), dict: Vec::new() }
    }

    fn sym(&mut self, text: &str) -> u32 {
        if text.is_empty() {
            return NONE;
        }
        if let Some(&s) = self.exact.get(text) {
            return s;
        }
        // "Stripe" and "stripe" are one symbol.
        let fold = text.to_lowercase();
        let s = match self.folded.get(&fold) {
            Some(&s) => s,
            None => {
                self.dict.push(text.into());
                let s = self.dict.len() as u32 - 1;
                self.folded.insert(fold, s);
                s
            }
        };
        self.exact.insert(text.into(), s);
        s
    }
}

/// Field `f` for every application: each value read once per distinct
/// archetype (or title) and gathered to the applications' slots.
pub fn build(rows: &Rows, f: usize) -> Col {
    let Some(t) = rows.table(schema::table::APPLICATIONS) else { return Col::Num(Vec::new()) };
    let counts = Counts::of(rows);
    let ty = mask::FIELDS[f].ty;
    let shape = archetype(mask::FIELDS[f].path);
    let read = |id: u32| AppFacts::new(rows, t, id, &counts).read(f).map(Val::into_owned);
    // The slot's archetype key; None reads the row itself.
    let key = |id: u32| -> Option<u64> {
        match &shape {
            Archetype::Key(k) => Some(k(t, id)),
            Archetype::Title => None,
            Archetype::Row => None,
        }
    };
    match ty {
        Ty::Num | Ty::Day | Ty::Bool => {
            let num = |id: u32| match read(id) {
                Some(Val::Num(n)) => n,
                Some(Val::Day(d)) => d as f64,
                Some(Val::Bool(b)) => f64::from(u8::from(b)),
                _ => f64::NAN,
            };
            let mut memo: crate::fx::Map<u64, f64> = crate::fx::Map::default();
            Col::Num(t.ids().iter().map(|&id| key(id).map_or_else(|| num(id), |k| *memo.entry(k).or_insert_with(|| num(id)))).collect())
        }
        Ty::Enum(e) => {
            let names = mask::values(e);
            let code = |id: u32| if let Some(Val::Enum(i)) = read(id) { i } else { NONE };
            let mut memo: crate::fx::Map<u64, u32> = crate::fx::Map::default();
            let mut titles: crate::keyed::Map<&str, u32> = crate::keyed::Map::default();
            let ids = t
                .ids()
                .iter()
                .map(|&id| match (&shape, key(id)) {
                    (_, Some(k)) => *memo.entry(k).or_insert_with(|| code(id)),
                    (Archetype::Title, None) => *titles.entry(t.str(id, schema::col::applications::ROLE).unwrap_or("")).or_insert_with(|| code(id)),
                    _ => code(id),
                })
                .collect();
            Col::Sym { ids, dict: names.iter().map(|s| String::from(*s)).collect(), rank: (0..names.len() as u32).collect() }
        }
        _ => {
            let mut names = Interner::new();
            let mut memo: crate::fx::Map<u64, u32> = crate::fx::Map::default();
            // The application's own text columns read straight from the replica.
            let own = match mask::FIELDS[f].path {
                "company" => Some(schema::col::applications::COMPANY),
                "role" => Some(schema::col::applications::ROLE),
                "location" => Some(schema::col::applications::LOCATION),
                _ => None,
            };
            let text = |id: u32, names: &mut Interner| match own {
                Some(c) => names.sym(t.str(id, c).unwrap_or("")),
                None => match read(id) {
                    Some(Val::Text(s) | Val::Code(s)) => names.sym(&s),
                    Some(Val::List(xs)) => names.sym(&xs.iter().filter_map(|x| if let Val::Text(s) | Val::Code(s) = x { Some(s.as_ref()) } else { None }).collect::<Vec<_>>().join(", ")),
                    _ => NONE,
                },
            };
            let ids = t
                .ids()
                .iter()
                .map(|&id| match key(id) {
                    Some(k) => match memo.get(&k) {
                        Some(&s) => s,
                        None => {
                            let s = text(id, &mut names);
                            memo.insert(k, s);
                            s
                        }
                    },
                    None => text(id, &mut names),
                })
                .collect();
            let dict = names.dict;
            let mut order: Vec<u32> = (0..dict.len() as u32).collect();
            order.sort_by(|a, b| collate(&dict[*a as usize], &dict[*b as usize]));
            let mut rank = alloc::vec![0; dict.len()];
            for (r, s) in order.into_iter().enumerate() {
                rank[s as usize] = r as u32;
            }
            Col::Sym { ids, dict, rank }
        }
    }
}

/// Text as people order it: case aside, runs of digits by their value.
fn collate(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let take = |it: &mut core::iter::Peekable<core::str::Chars>| {
                    let mut n = String::new();
                    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
                        n.push(c);
                        it.next();
                    }
                    n
                };
                let (m, n) = (take(&mut x), take(&mut y));
                let (m, n) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                match m.len().cmp(&n.len()).then_with(|| m.cmp(n)) {
                    Ordering::Equal => {}
                    o => return o,
                }
            }
            (Some(p), Some(q)) => {
                match p.to_lowercase().cmp(q.to_lowercase()) {
                    Ordering::Equal => {}
                    o => return o,
                }
                x.next();
                y.next();
            }
        }
    }
}

impl Col {
    /// A slot's sort key: absent is None (last either way).
    fn key(&self, slot: usize) -> Option<f64> {
        match self {
            Col::Num(v) => Some(v[slot]).filter(|n| !n.is_nan()),
            Col::Sym { ids, rank, .. } => Some(ids[slot]).filter(|s| *s != NONE).map(|s| rank[s as usize] as f64),
        }
    }

    /// A slot's group: a key that orders the groups, and its label.
    fn group(&self, slot: usize, path: &str) -> (Option<f64>, String) {
        match self {
            Col::Sym { ids, dict, rank } => match ids[slot] {
                NONE => (None, String::from("(none)")),
                s => (Some(rank[s as usize] as f64), dict[s as usize].replace('_', " ")),
            },
            Col::Num(v) => {
                let n = v[slot];
                if n.is_nan() {
                    return (None, String::from("(none)"));
                }
                // A score reads in tens, a day as itself, a count or a number by its order of magnitude.
                if path == "score" {
                    let lo = libm::floor(n / 10.0) * 10.0;
                    let lo = lo.min(90.0);
                    return (Some(lo), alloc::format!("{lo}–{}", if lo >= 90.0 { 100.0 } else { lo + 9.0 }));
                }
                if mask::field(path).is_some_and(|f| mask::FIELDS[f].ty == Ty::Day) {
                    return (Some(n), crate::day_iso(n as crate::Day));
                }
                if n < 2.0 {
                    return (Some(n), alloc::format!("{n}"));
                }
                let lo = libm::pow(10.0, libm::floor(libm::log10(n)));
                let lo = if lo < 2.0 { 2.0 } else { lo };
                let hi = if lo == 2.0 { 9.0 } else { lo * 10.0 - 1.0 };
                (Some(lo), alloc::format!("{lo}–{hi}"))
            }
        }
    }
}

/// How to arrange: a sort column and direction (1 rising, -1 falling), a
/// group column, and the groups by size rather than by key.
pub struct Ask<'a> {
    pub sort: Option<(usize, i8)>,
    pub group: Option<usize>,
    pub largest: bool,
    /// The columns asked for, built (`build`).
    pub cols: &'a BTreeMap<usize, Col>,
}

/// One group: its label, where it starts in the order, and how many.
#[derive(Debug, PartialEq)]
pub struct Group {
    pub label: String,
    pub start: u32,
    pub count: u32,
}

/// `ids` (the board's filtered order) sorted and grouped as asked. A sort
/// is stable over the board's own order; groups keep the sort inside them.
/// Columnar throughout: one key vector per pass, buckets by symbol or
/// bucket value, a label made once per group.
pub fn arrange(rows: &Rows, ids: &[u32], ask: &Ask) -> (Vec<u32>, Vec<Group>) {
    let Some(t) = rows.table(schema::table::APPLICATIONS) else { return (Vec::new(), Vec::new()) };
    let mut order: Vec<(u32, usize)> = ids.iter().filter_map(|&id| t.slot(id).map(|s| (id, s))).collect();
    if let Some((f, dir)) = ask.sort {
        let col = &ask.cols[&f];
        // Decorate once: absent sorts last whichever way.
        let mut keyed: Vec<(f64, u32, usize)> = order
            .iter()
            .map(|&(id, slot)| {
                let k = col.key(slot).map_or(f64::INFINITY, |k| if dir < 0 { -k } else { k });
                (k, id, slot)
            })
            .collect();
        keyed.sort_by(|a, b| a.0.total_cmp(&b.0));
        order = keyed.into_iter().map(|(_, id, slot)| (id, slot)).collect();
    }
    let Some(g) = ask.group else {
        let n = order.len() as u32;
        return (order.into_iter().map(|x| x.0).collect(), alloc::vec![Group { label: String::new(), start: 0, count: n }]);
    };
    let col = &ask.cols[&g];
    let path = mask::FIELDS[g].path;
    // A slot's bucket as bits: a symbol id, or a number's bucket value; absent its own.
    const ABSENT: u64 = u64::MAX;
    let bucket = |slot: usize| -> u64 {
        match col {
            Col::Sym { ids, .. } => match ids[slot] {
                NONE => ABSENT,
                s => u64::from(s),
            },
            Col::Num(_) => col.group(slot, path).0.map_or(ABSENT, f64::to_bits),
        }
    };
    let mut buckets: Vec<(u64, usize, Vec<u32>)> = Vec::new();
    // A symbol column buckets through an array by symbol id; numbers through a map.
    let mut by_sym: Vec<u32> = match col {
        Col::Sym { dict, .. } => alloc::vec![u32::MAX; dict.len() + 1],
        Col::Num(_) => Vec::new(),
    };
    let mut at: BTreeMap<u64, usize> = BTreeMap::new();
    for &(id, slot) in &order {
        let b = bucket(slot);
        let i = if by_sym.is_empty() {
            *at.entry(b).or_insert_with(|| {
                buckets.push((b, slot, Vec::new()));
                buckets.len() - 1
            })
        } else {
            let s = if b == ABSENT { by_sym.len() - 1 } else { b as usize };
            if by_sym[s] == u32::MAX {
                by_sym[s] = buckets.len() as u32;
                buckets.push((b, slot, Vec::new()));
            }
            by_sym[s] as usize
        };
        buckets[i].2.push(id);
    }
    let dir = match ask.sort {
        Some((f, d)) if f == g => d,
        _ => 1,
    };
    // Groups by size, else by key in the sort's direction when sorting the same field, absent last.
    let key = |b: &(u64, usize, Vec<u32>)| if b.0 == ABSENT { None } else { col.group(b.1, path).0 };
    buckets.sort_by(|a, b| {
        if ask.largest {
            return b.2.len().cmp(&a.2.len());
        }
        match (key(a), key(b)) {
            (Some(x), Some(y)) => {
                let o = x.total_cmp(&y);
                if dir < 0 { o.reverse() } else { o }
            }
            (None, None) => Ordering::Equal,
            (None, _) => Ordering::Greater,
            (_, None) => Ordering::Less,
        }
    });
    let mut out = Vec::with_capacity(order.len());
    let mut groups = Vec::with_capacity(buckets.len());
    for (_, slot, members) in buckets {
        groups.push(Group { label: col.group(slot, path).1, start: out.len() as u32, count: members.len() as u32 });
        out.extend(members);
    }
    (out, groups)
}

/// The groups as the page reads them.
pub fn groups_json(groups: &[Group]) -> Json {
    Json::Array(groups.iter().map(|g| json!({"label": g.label, "start": g.start, "count": g.count})).collect())
}
