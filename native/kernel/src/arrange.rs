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
    if path.starts_with("company.") {
        Archetype::Key(|t, id| id_of(t, id, A::CORPORATION_ID))
    } else if matches!(path, "place" | "country" | "city" | "region" | "subregion" | "country.applications") {
        Archetype::Key(|t, id| id_of(t, id, A::PLACE_ID))
    } else if path == "office" {
        Archetype::Key(|t, id| (id_of(t, id, A::CORPORATION_ID) << 32) | id_of(t, id, A::PLACE_ID))
    } else if path.starts_with("me.") {
        Archetype::Key(|_, _| 0)
    } else if matches!(path, "field" | "subfield" | "seniority") {
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
    let key = |id: u32| -> Option<u64> { if let Archetype::Key(k) = &shape { Some(k(t, id)) } else { None } };
    match ty {
        Ty::Num | Ty::Day | Ty::Bool => {
            let num = |id: u32| number(read(id));
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
            symbols(ids, names.dict)
        }
    }
}

/// A number, day or flag as a number; anything else absent.
fn number(v: Option<Val<'_>>) -> f64 {
    match v {
        Some(Val::Num(n)) => n,
        Some(Val::Day(d)) => d as f64,
        Some(Val::Bool(b)) => f64::from(u8::from(b)),
        _ => f64::NAN,
    }
}

/// A symbol column: each symbol ranked in reading order (`collate`).
fn symbols(ids: Vec<u32>, dict: Vec<String>) -> Col {
    let rank = ranked(&dict);
    Col::Sym { ids, dict, rank }
}

fn ranked(dict: &[String]) -> Vec<u32> {
    let mut order: Vec<u32> = (0..dict.len() as u32).collect();
    order.sort_by(|a, b| collate(&dict[*a as usize], &dict[*b as usize]));
    let mut rank = alloc::vec![0; dict.len()];
    for (r, s) in order.into_iter().enumerate() {
        rank[s as usize] = r as u32;
    }
    rank
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

/// How a column's values fall into groups, and what a group is called.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Bucket {
    /// One group per symbol, labelled as written.
    Sym,
    /// 0-9, ..., 90-100 (a score).
    Tens,
    /// #1-99, #100-199, ... (a number or id).
    Hundreds,
    /// 0, 1, 2-9, 10-99, ...
    Magnitude,
    /// One group per value, its unit one and many: "1 application", "3 applications".
    Exact(&'static str, &'static str),
    Day,
    Month,
}

/// A column with how it groups: high first by default (`desc`), the
/// absent left out of a grouping (`drop_absent`, duplicates), and what the
/// absent group is called.
pub struct Column {
    pub col: Col,
    pub bucket: Bucket,
    pub desc: bool,
    pub drop_absent: bool,
    pub none: &'static str,
}

impl Column {
    pub fn of(col: Col, bucket: Bucket) -> Column {
        Column { col, bucket, desc: false, drop_absent: false, none: "(none)" }
    }

    /// A slot's sort key: absent is None (last either way).
    fn key(&self, slot: usize) -> Option<f64> {
        match &self.col {
            Col::Num(v) => Some(v[slot]).filter(|n| !n.is_nan()),
            Col::Sym { ids, rank, .. } => Some(ids[slot]).filter(|s| *s != NONE).map(|s| rank[s as usize] as f64),
        }
    }

    /// A slot's group: its bucket (None absent), ordered by the bucket's value.
    fn bucket(&self, slot: usize) -> Option<f64> {
        let n = match &self.col {
            Col::Sym { ids, .. } => return Some(ids[slot]).filter(|s| *s != NONE).map(f64::from),
            Col::Num(v) => Some(v[slot]).filter(|n| !n.is_nan())?,
        };
        Some(match self.bucket {
            Bucket::Tens => (libm::floor(n / 10.0) * 10.0).min(90.0),
            Bucket::Hundreds => libm::floor(n / 100.0) * 100.0,
            Bucket::Magnitude if n < 2.0 => n,
            Bucket::Magnitude => libm::pow(10.0, libm::floor(libm::log10(n))).max(2.0),
            Bucket::Month => {
                let iso = crate::day_iso(n as crate::Day);
                let (y, m) = (iso[..4].parse::<f64>().unwrap_or(0.0), iso[5..7].parse::<f64>().unwrap_or(0.0));
                y * 12.0 + m
            }
            _ => n,
        })
    }

    /// The order a bucket stands in: a symbol by its rank, a number by itself.
    fn order(&self, b: f64) -> f64 {
        match &self.col {
            Col::Sym { rank, .. } => rank[b as usize] as f64,
            Col::Num(_) => b,
        }
    }

    fn label(&self, b: Option<f64>) -> String {
        let Some(b) = b else { return self.none.into() };
        match (&self.col, self.bucket) {
            (Col::Sym { dict, .. }, _) => dict[b as usize].replace('_', " "),
            (_, Bucket::Tens) => alloc::format!("{b}–{}", if b >= 90.0 { 100.0 } else { b + 9.0 }),
            (_, Bucket::Hundreds) => alloc::format!("#{}–{}", b.max(1.0), b + 99.0),
            (_, Bucket::Magnitude) if b < 2.0 => alloc::format!("{b}"),
            (_, Bucket::Magnitude) => alloc::format!("{b}–{}", if b == 2.0 { 9.0 } else { b * 10.0 - 1.0 }),
            (_, Bucket::Exact(one, many)) => alloc::format!("{b}{}", if b == 1.0 { one } else { many }),
            (_, Bucket::Day) => crate::day_iso(b as crate::Day),
            (_, Bucket::Month) => alloc::format!("{}-{:02}", libm::floor((b - 1.0) / 12.0), (b - 1.0) % 12.0 + 1.0),
            (_, Bucket::Sym) => alloc::format!("{b}"),
        }
    }
}

/// A catalog field as a column, grouped as its type reads.
pub fn field(rows: &Rows, f: usize) -> Column {
    let path = mask::FIELDS[f].path;
    let col = build(rows, f);
    let bucket = match (mask::FIELDS[f].ty, path) {
        (_, "id" | "no") => Bucket::Hundreds,
        (_, p) if p.ends_with(".applications") => Bucket::Exact(" application", " applications"),
        (Ty::Day, _) => Bucket::Month,
        (Ty::Num, _) => Bucket::Magnitude,
        _ => Bucket::Sym,
    };
    // A country code reads as its place: "Germany (DE)", ordered by the name.
    let col = if mask::FIELDS[f].ty == Ty::Code { named_codes(rows, col) } else { col };
    Column { desc: path.ends_with(".applications"), ..Column::of(col, bucket) }
}

/// Code symbols relabelled "<name> (<code>)" from the places, one name per
/// code, and ranked by the label.
fn named_codes(rows: &Rows, col: Col) -> Col {
    let Col::Sym { ids, dict, .. } = col else { return col };
    let mut names: crate::keyed::Map<String, &str> = crate::keyed::Map::default();
    for (pt, p) in rows.each(schema::table::PLACES) {
        if pt.u32(p, schema::col::places::KIND) == Some(schema::enums::place_kind::COUNTRY as u32)
            && let (Some(code), Some(name)) = (pt.str(p, schema::col::places::ISO2), pt.str(p, schema::col::places::NAME))
        {
            names.entry(code.to_ascii_uppercase()).or_insert(name);
        }
    }
    symbols(ids, dict.into_iter().map(|c| names.get(&c.to_ascii_uppercase()).map_or(c.clone(), |n| alloc::format!("{n} ({c})"))).collect())
}

/// How to arrange: a sort column and direction (1 rising, -1 falling; none
/// keeps the board's order), a group column, and groups by size rather than key.
pub struct Ask<'a> {
    pub sort: Option<(&'a str, i8)>,
    pub group: Option<&'a str>,
    pub largest: bool,
    /// The columns asked for, by key.
    pub cols: &'a BTreeMap<String, Column>,
}

/// One group: a stable key, its label, where it starts in the order, how
/// many, and (duplicates) the one to keep.
#[derive(Debug, PartialEq)]
pub struct Group {
    pub key: String,
    pub label: String,
    pub start: u32,
    pub count: u32,
    pub keep: Option<u32>,
}

/// `ids` (rows of `t`, in the caller's order) sorted and grouped as asked. A sort
/// is stable over the board's own order; groups keep the sort inside them
/// and stand in the key's order (high first for a desc column), or largest
/// first. `keep` names a duplicate group's keeper by `rank` (higher wins).
pub fn arrange(t: &crate::rows::Table, ids: &[u32], ask: &Ask, keep: &dyn Fn(u32) -> (u32, i64)) -> (Vec<u32>, Vec<Group>) {
    let mut order: Vec<(u32, usize)> = ids.iter().filter_map(|&id| t.slot(id).map(|s| (id, s))).collect();
    if let Some((k, dir)) = ask.sort {
        let col = &ask.cols[k];
        let mut keyed: Vec<(f64, u32, usize)> = order
            .iter()
            .map(|&(id, slot)| (col.key(slot).map_or(f64::INFINITY, |v| if dir < 0 { -v } else { v }), id, slot))
            .collect();
        keyed.sort_by(|a, b| a.0.total_cmp(&b.0));
        order = keyed.into_iter().map(|(_, id, slot)| (id, slot)).collect();
    }
    let Some(g) = ask.group else {
        let n = order.len() as u32;
        return (order.into_iter().map(|x| x.0).collect(), alloc::vec![Group { key: String::new(), label: String::new(), start: 0, count: n, keep: None }]);
    };
    let col = &ask.cols[g];
    // A counting sort: one bucket index per row, a count per bucket, then
    // the rows placed at their bucket's offset. No vector per group.
    let absent = u32::MAX;
    let mut index: Vec<u32> = Vec::with_capacity(order.len());
    let mut values: Vec<Option<f64>> = Vec::new();
    let mut by_sym: Vec<u32> = match &col.col {
        Col::Sym { dict, .. } => alloc::vec![absent; dict.len() + 1],
        Col::Num(_) => Vec::new(),
    };
    let mut by_num: crate::fx::Map<u64, u32> = crate::fx::Map::default();
    let mut counts: Vec<u32> = Vec::new();
    for &(_, slot) in &order {
        let b = col.bucket(slot);
        if b.is_none() && col.drop_absent {
            index.push(absent);
            continue;
        }
        let at = match (&col.col, b) {
            (Col::Sym { dict, .. }, b) => {
                let s = b.map_or(dict.len(), |b| b as usize);
                if by_sym[s] == absent {
                    by_sym[s] = values.len() as u32;
                    values.push(b);
                    counts.push(0);
                }
                by_sym[s]
            }
            (Col::Num(_), b) => *by_num.entry(b.map_or(u64::MAX, f64::to_bits)).or_insert_with(|| {
                values.push(b);
                counts.push(0);
                values.len() as u32 - 1
            }),
        };
        counts[at as usize] += 1;
        index.push(at);
    }
    let dir = match ask.sort {
        Some((k, d)) if k == g => d,
        _ if col.desc => -1,
        _ => 1,
    };
    // The groups in first-seen order, then sorted: by size, or by key with the absent last.
    let mut groups_at: Vec<u32> = (0..values.len() as u32).collect();
    groups_at.sort_by(|&a, &b| {
        if ask.largest {
            return counts[b as usize].cmp(&counts[a as usize]);
        }
        match (values[a as usize], values[b as usize]) {
            (Some(x), Some(y)) => {
                let o = col.order(x).total_cmp(&col.order(y));
                if dir < 0 { o.reverse() } else { o }
            }
            (None, None) => Ordering::Equal,
            (None, _) => Ordering::Greater,
            (_, None) => Ordering::Less,
        }
    });
    let mut start = alloc::vec![0u32; values.len()];
    let mut total = 0;
    for &gi in &groups_at {
        start[gi as usize] = total;
        total += counts[gi as usize];
    }
    let mut out = alloc::vec![0u32; total as usize];
    let mut cursor = start.clone();
    let mut keeper: Vec<Option<(u32, (u32, i64))>> = if col.drop_absent { alloc::vec![None; values.len()] } else { Vec::new() };
    for (&(id, _), &at) in order.iter().zip(&index) {
        if at == absent {
            continue;
        }
        out[cursor[at as usize] as usize] = id;
        cursor[at as usize] += 1;
        if col.drop_absent {
            let rank = keep(id);
            let k = &mut keeper[at as usize];
            if k.is_none_or(|(_, r)| rank > r) {
                *k = Some((id, rank));
            }
        }
    }
    let groups = groups_at
        .iter()
        .map(|&gi| {
            let b = values[gi as usize];
            let key = match (b, &col.col) {
                (None, _) => String::from("none"),
                // The value itself, case aside: the same group under any build of the column.
                (Some(b), Col::Sym { dict, .. }) => alloc::format!("s:{}", dict[b as usize].to_lowercase()),
                (Some(b), Col::Num(_)) => alloc::format!("n{b}"),
            };
            Group { key, label: col.label(b), start: start[gi as usize], count: counts[gi as usize], keep: keeper.get(gi as usize).copied().flatten().map(|k| k.0) }
        })
        .collect();
    (out, groups)
}

/// The groups as the page reads them.
pub fn groups_json(groups: &[Group]) -> Json {
    Json::Array(
        groups
            .iter()
            .map(|g| {
                let mut o = json!({"key": g.key, "label": g.label, "start": g.start, "count": g.count});
                if let Some(k) = g.keep {
                    o["keep"] = json!(k);
                }
                o
            })
            .collect(),
    )
}

/// Symbols from text per slot: interned, ranked in reading order.
pub(crate) fn texts(per_slot: impl Iterator<Item = Option<String>>) -> Col {
    let mut names = Interner::new();
    let ids = per_slot.map(|t| t.map_or(NONE, |t| names.sym(&t))).collect();
    symbols(ids, names.dict)
}

/// Symbols from a fixed list in its order (an enum read as the desk reads it).
pub(crate) fn listed(names: &[&str], per_slot: impl Iterator<Item = Option<usize>>) -> Col {
    Col::Sym {
        ids: per_slot.map(|i| i.map_or(NONE, |i| i as u32)).collect(),
        dict: names.iter().map(|s| String::from(*s)).collect(),
        rank: (0..names.len() as u32).collect(),
    }
}

/// The desk's own keys.
pub const DESK: &[&str] = &["score", "band", "heat", "why", "lease", "added", "dupes", "company", "place"];

/// The desk's own keys, which read the board's cards or several columns
/// at once; None for a key that is a catalog field.
pub fn desk(rows: &Rows, board: &crate::board::Board, key: &str) -> Option<Column> {
    use schema::col::applications as A;
    let t = rows.table(schema::table::APPLICATIONS)?;
    let ids = t.ids();
    let card = |id: u32| board.card(id);
    let linked = |c: u16, table: u16, name: u16, written: u16| {
        let rt = rows.table(table);
        texts(ids.iter().map(|&id| {
            match t.u32(id, c).and_then(|r| rt.filter(|rt| rt.has(r)).and_then(|rt| rt.str(r, name))) {
                Some(n) => Some(n.into()),
                None => {
                    let own = t.str(id, written).unwrap_or("");
                    let need = crate::link::missing(t.u32(id, A::CORPORATION_ID), t.u32(id, A::PLACE_ID), t.u32(id, A::WORK_MODE));
                    let short = need.contains(&if table == schema::table::CORPORATIONS { "corporation_id" } else { "place_id" });
                    (!own.is_empty()).then(|| if short { alloc::format!("{own} · unlinked") } else { own.into() })
                }
            }
        }))
    };
    Some(match key {
        "score" => Column { desc: true, ..Column::of(Col::Num(ids.iter().map(|&id| card(id).map_or(f64::NAN, |c| f64::from(c.score))).collect()), Bucket::Tens) },
        "band" => {
            let names: Vec<&str> = crate::score::BANDS.iter().map(|b| b.name()).collect();
            Column::of(listed(&names, ids.iter().map(|&id| card(id).map(|c| c.band as usize))), Bucket::Sym)
        }
        "heat" => {
            const ORDER: [&str; 4] = ["hot", "warm", "cool", "blocked"];
            Column::of(listed(&ORDER, ids.iter().map(|&id| card(id).and_then(|c| ORDER.iter().position(|n| *n == c.class.name())))), Bucket::Sym)
        }
        "why" => Column::of(
            texts(ids.iter().map(|&id| card(id).map(|c| c.verdict.reason.name()).filter(|r| *r != "ok").map(String::from))),
            Bucket::Sym,
        ),
        "lease" => {
            let mut by: crate::fx::Map<u32, String> = crate::fx::Map::default();
            for (lt, l) in rows.each(schema::table::LEASES) {
                let label = lt.str(l, schema::col::leases::LABEL).unwrap_or("");
                for held in crate::text::list(lt.str(l, schema::col::leases::HELD).unwrap_or("")) {
                    if let Ok(a) = held.parse::<u32>() {
                        by.insert(a, alloc::format!("leased by {}", if label.is_empty() { "an agent" } else { label }));
                    }
                }
            }
            Column { none: "not leased", ..Column::of(texts(ids.iter().map(|id| by.get(id).cloned())), Bucket::Sym) }
        }
        "added" => Column::of(
            Col::Num(ids.iter().map(|&id| match t.get(id, A::INSERTED_AT) {
                crate::rows::Val::I64(s) => (crate::UNIX_EPOCH_DAY as i64 + s.div_euclid(86_400)) as f64,
                crate::rows::Val::U32(s) => (crate::UNIX_EPOCH_DAY as i64 + i64::from(s) / 86_400) as f64,
                _ => f64::NAN,
            }).collect()),
            Bucket::Day,
        ),
        "dupes" => {
            // The same posting (its canonical URL), else the same company, role and place by link or by text.
            let norm = |s: &str| crate::text::normalize(s);
            let key = |id: u32| -> String {
                if let Some(u) = t.str(id, A::CANONICAL_URL).filter(|u| !u.is_empty()) {
                    return alloc::format!("u{u}");
                }
                let corp = t.u32(id, A::CORPORATION_ID).map_or_else(|| norm(t.str(id, A::COMPANY).unwrap_or("")), |c| alloc::format!("#{c}"));
                let place = t.u32(id, A::PLACE_ID).map_or_else(|| norm(t.str(id, A::LOCATION).unwrap_or("")), |p| alloc::format!("#{p}"));
                alloc::format!("{corp}|{}|{place}", norm(t.str(id, A::ROLE).unwrap_or("")))
            };
            let keys: Vec<String> = ids.iter().map(|&id| key(id)).collect();
            let mut seen: crate::keyed::Map<&str, u32> = crate::keyed::Map::default();
            for k in &keys {
                *seen.entry(k.as_str()).or_default() += 1;
            }
            let label = |id: u32| alloc::format!("{} · {}", t.str(id, A::COMPANY).filter(|c| !c.is_empty()).unwrap_or("(no company)"), t.str(id, A::ROLE).unwrap_or(""));
            // One symbol per duplicate set, labelled by its first member.
            let mut set: crate::keyed::Map<&str, String> = crate::keyed::Map::default();
            let per = ids.iter().zip(&keys).map(|(&id, k)| (seen[k.as_str()] > 1).then(|| set.entry(k.as_str()).or_insert_with(|| label(id)).clone()));
            let per: Vec<Option<String>> = per.collect();
            Column { drop_absent: true, ..Column::of(texts(per.into_iter()), Bucket::Sym) }
        }
        "company" => Column::of(linked(A::CORPORATION_ID, schema::table::CORPORATIONS, schema::col::corporations::NAME, A::COMPANY), Bucket::Sym),
        "place" => Column::of(linked(A::PLACE_ID, schema::table::PLACES, schema::col::places::NAME, A::LOCATION), Bucket::Sym),
        _ => return None,
    })
}

/// Brings a catalog field's column up to date after the applications `ids`
/// were written in place (no row added or gone): each written slot read
/// again, a new text interned and the ranks redone. False when it cannot
/// (a count, which reads every row; a country code, which reads names;
/// rows added or gone): the caller rebuilds it then.
pub fn mend(rows: &Rows, key: &str, column: &mut Column, ids: &[u32]) -> bool {
    let Some(f) = mask::field(key) else { return false };
    let Some(t) = rows.table(schema::table::APPLICATIONS) else { return false };
    let path = mask::FIELDS[f].path;
    let len = match &column.col {
        Col::Num(v) => v.len(),
        Col::Sym { ids, .. } => ids.len(),
    };
    if DESK.contains(&key) || path.ends_with(".applications") || mask::FIELDS[f].ty == Ty::Code || len != t.len() {
        return false;
    }
    let counts = Counts::default();
    let mut grew = false;
    for &id in ids {
        let Some(slot) = t.slot(id) else { return false };
        let v = AppFacts::new(rows, t, id, &counts).read(f).map(Val::into_owned);
        match &mut column.col {
            Col::Num(nums) => nums[slot] = number(v),
            Col::Sym { ids: syms, dict, .. } => {
                syms[slot] = match v {
                    Some(Val::Enum(i)) => i,
                    Some(Val::Text(s)) if !s.is_empty() => {
                        let fold = s.to_lowercase();
                        match dict.iter().position(|d| d.to_lowercase() == fold) {
                            Some(i) => i as u32,
                            None => {
                                dict.push(s.into_owned());
                                grew = true;
                                dict.len() as u32 - 1
                            }
                        }
                    }
                    _ => NONE,
                }
            }
        }
    }
    if grew && let Col::Sym { dict, rank, .. } = &mut column.col {
        *rank = ranked(dict);
    }
    true
}

/// A page as an agent reads it: `total` `noun` and `how` they stand, a
/// heading per group the page crosses, `line` per row, and the offset of
/// the page after it.
pub fn listing(noun: &str, how: &str, rows: &[Json], groups: &[Json], total: usize, after: usize, line: impl Fn(usize, &Json) -> String) -> String {
    use core::fmt::Write;
    let mut s = String::new();
    let shown = if rows.is_empty() { "none".into() } else { alloc::format!("{}-{}", after + 1, after + rows.len()) };
    let _ = writeln!(s, "{total} {noun}{how}; rows {shown}");
    let mut heading: Option<&Json> = None;
    for (i, r) in rows.iter().enumerate() {
        let at = (after + i) as u64;
        let g = groups.iter().find(|g| g["start"].as_u64().is_some_and(|st| st <= at && at < st + g["count"].as_u64().unwrap_or(0)));
        if g.is_some() && g.map(|g| &g["key"]) != heading.map(|g| &g["key"]) {
            heading = g;
            let _ = writeln!(s, "\n{} ({})", g.map_or("", |g| g["label"].as_str().unwrap_or("")), g.map_or(0, |g| g["count"].as_u64().unwrap_or(0)));
        }
        let _ = writeln!(s, "  {}", line(i, r));
    }
    if after + rows.len() < total {
        let _ = writeln!(s, "\nnext: {{\"after\": {}}}", after + rows.len());
    }
    s
}
