// The parser and resolver of schema/hireme.schema. Shared by the library
// and by build.rs (included by path), so it needs only `alloc`.
//
// `lib/hireme/schema.ex` resolves the same file by the same rules; the two
// canonical dumps are compared by `mix hireme.schema --check`, so a change
// to any rule here is made there too, in the same commit.

use alloc::borrow::ToOwned;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;

/// A column's or param's declared type.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Type {
    Id,
    Ref,
    Enum,
    Bool,
    U8,
    U32,
    I64,
    F64,
    Day,
    Time,
    Str,
    Text,
    Json,
    Bytes,
}

pub const TYPES: [(&str, Type); 14] = [
    ("id", Type::Id),
    ("ref", Type::Ref),
    ("enum", Type::Enum),
    ("bool", Type::Bool),
    ("u8", Type::U8),
    ("u32", Type::U32),
    ("i64", Type::I64),
    ("f64", Type::F64),
    ("day", Type::Day),
    ("time", Type::Time),
    ("str", Type::Str),
    ("text", Type::Text),
    ("json", Type::Json),
    ("bytes", Type::Bytes),
];

impl Type {
    pub fn parse(name: &str) -> Option<Type> {
        TYPES.iter().find(|(n, _)| *n == name).map(|(_, t)| *t)
    }

    pub fn name(self) -> &'static str {
        TYPES.iter().find(|(_, t)| *t == self).map(|(n, _)| *n).unwrap()
    }

    /// The catalog's type code: position in `TYPES`, from 1.
    pub fn code(self) -> u8 {
        TYPES.iter().position(|(_, t)| *t == self).unwrap() as u8 + 1
    }

    /// The wire type a non-deferred value of this type travels as.
    pub fn wire(self) -> u8 {
        match self {
            Type::Id | Type::Ref | Type::Bool | Type::U8 | Type::U32 | Type::Day | Type::Time | Type::Enum => {
                wire::U32
            }
            Type::Str | Type::Text | Type::Json | Type::Bytes => wire::STR,
            Type::I64 => wire::I64,
            Type::F64 => wire::F64,
        }
    }
}

/// Wire type codes, the u8 in a cell and a column run.
pub mod wire {
    pub const NULL: u8 = 0;
    pub const U32: u8 = 1;
    pub const STR: u8 = 2;
    pub const I64: u8 = 3;
    pub const F64: u8 = 4;
    pub const DEFERRED: u8 = 5;
    /// Codec-only run encodings, never a declared type.
    pub const SYM: u8 = 6;
    pub const LIST: u8 = 7;
}

/// The catalog's flag bits.
pub mod flag {
    pub const REQUIRED: u32 = 1;
    pub const DEFERRED: u32 = 2;
    pub const PRIVATE: u32 = 4;
    pub const SERVER_ONLY: u32 = 8;
    pub const HUMAN_ONLY: u32 = 16;
    pub const READONLY: u32 = 32;
    pub const UNIQUE: u32 = 64;
    pub const METRIC: u32 = 128;
    pub const PROSE: u32 = 256;
    pub const IMPLIED: u32 = 512;
    pub const METRIC_ON: u32 = 1024;
    pub const NATURAL: u32 = 2048;
    pub const CASCADE: u32 = 4096;
}

/// Reserved cell ids in an op.
pub const AS_OF: u16 = 0xFFF0;
pub const SOURCE_CELL: u16 = 0xFFF1;
/// A free command param's cell id is this plus its position in the command.
pub const FREE_PARAM: u16 = 0xFE00;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Residency {
    Resident,
    Server,
    Wire,
    Projection,
}

impl Residency {
    pub fn name(self) -> &'static str {
        match self {
            Residency::Resident => "resident",
            Residency::Server => "server",
            Residency::Wire => "wire",
            Residency::Projection => "projection",
        }
    }

    pub fn stored(self) -> bool {
        matches!(self, Residency::Resident | Residency::Server)
    }
}

#[derive(Clone, Debug)]
pub struct Domain {
    pub name: String,
    /// The mask bit; `system` has none (0).
    pub bit: u8,
}

#[derive(Clone, Debug)]
pub struct Frame {
    pub name: String,
    pub id: u8,
}

#[derive(Clone, Debug)]
pub struct Enum {
    pub id: u16,
    pub name: String,
    /// Codes are positions, from 0.
    pub values: Vec<String>,
}

/// The where of a key, an index or a projection, in the only shapes a
/// reader of the declaration applies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Where {
    Eq(String, String),
    Null(String),
    NotNull(String),
}

impl Where {
    pub fn col(&self) -> &str {
        match self {
            Where::Eq(c, _) | Where::Null(c) | Where::NotNull(c) => c,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Key {
    pub cols: Vec<String>,
    pub global: bool,
    pub where_: Option<String>,
    pub term: Option<Where>,
}

#[derive(Clone, Debug)]
pub struct Index {
    /// Column and descending.
    pub cols: Vec<(String, bool)>,
    pub global: bool,
    pub where_: Option<String>,
    pub term: Option<Where>,
}

#[derive(Clone, Debug)]
pub struct Column {
    pub id: u16,
    pub name: String,
    pub ty: Type,
    /// The table a ref names or the enum an enum names.
    pub target: Option<String>,
    pub required: bool,
    /// As written in the file.
    pub default: Option<String>,
    pub deferred: bool,
    pub private: bool,
    pub server_only: bool,
    pub human_only: bool,
    pub readonly: bool,
    pub unique: bool,
    /// A nullable ref whose row goes with the row it names.
    pub cascade: bool,
    pub natural: bool,
    pub metric: bool,
    /// On a metric's `_on` twin: the metric it dates.
    pub metric_of: Option<String>,
    pub prose: bool,
    pub implied: bool,
}

impl Column {
    fn blank(name: &str, ty: Type) -> Column {
        Column {
            id: 0,
            name: name.to_owned(),
            ty,
            target: None,
            required: false,
            default: None,
            deferred: false,
            private: false,
            server_only: false,
            human_only: false,
            readonly: false,
            unique: false,
            cascade: false,
            natural: false,
            metric: false,
            metric_of: None,
            prose: false,
            implied: false,
        }
    }

    pub fn wire(&self) -> u8 {
        if self.deferred { wire::DEFERRED } else { self.ty.wire() }
    }

    pub fn flags(&self) -> u32 {
        let mut f = 0;
        for (on, bit) in [
            (self.required, flag::REQUIRED),
            (self.deferred, flag::DEFERRED),
            (self.private, flag::PRIVATE),
            (self.server_only, flag::SERVER_ONLY),
            (self.human_only, flag::HUMAN_ONLY),
            (self.readonly, flag::READONLY),
            (self.unique, flag::UNIQUE),
            (self.metric, flag::METRIC),
            (self.prose, flag::PROSE),
            (self.implied, flag::IMPLIED),
            (self.metric_of.is_some(), flag::METRIC_ON),
            (self.natural, flag::NATURAL),
            (self.cascade, flag::CASCADE),
        ] {
            if on {
                f |= bit;
            }
        }
        f
    }

    pub fn type_name(&self) -> String {
        type_name(self.ty, self.target.as_deref())
    }
}

fn type_name(ty: Type, target: Option<&str>) -> String {
    match target {
        Some(t) => format!("{}:{}", ty.name(), t),
        None => ty.name().to_owned(),
    }
}

#[derive(Clone, Debug)]
pub struct Table {
    pub id: u16,
    pub name: String,
    pub domain: String,
    pub residency: Residency,
    pub append_only: bool,
    pub soft_delete: bool,
    pub global: bool,
    pub account_optional: bool,
    pub singleton: bool,
    /// In no key's mask whatever its domain (citations).
    pub unmasked: bool,
    pub naturals: Vec<Key>,
    pub uniques: Vec<Key>,
    pub indexes: Vec<Index>,
    pub cap: Option<u32>,
    pub cols: Vec<Column>,
    /// A projection's source table and filter.
    pub source: Option<String>,
    pub source_where: Option<String>,
    pub source_term: Option<Where>,
}

impl Table {
    pub fn col(&self, name: &str) -> Option<&Column> {
        self.cols.iter().find(|c| c.name == name)
    }
}

#[derive(Clone, Debug)]
pub struct Param {
    /// The column's id, or `FREE_PARAM` + position for a free param.
    pub id: u16,
    pub name: String,
    pub ty: Type,
    pub target: Option<String>,
    pub required: bool,
    /// Names a column of the command's table.
    pub column: bool,
}

impl Param {
    pub fn wire(&self) -> u8 {
        self.ty.wire()
    }
}

#[derive(Clone, Debug)]
pub struct Command {
    pub id: u16,
    pub name: String,
    pub table: String,
    pub params: Vec<Param>,
    pub human_only: bool,
}

#[derive(Clone, Debug)]
pub struct Schema {
    /// The byte layout native/wire implements.
    pub layout: u16,
    /// Enums the frames carry (NACK codes, BYE reasons, op verbs).
    pub carry: Vec<String>,
    pub domains: Vec<Domain>,
    pub frames: Vec<Frame>,
    pub enums: Vec<Enum>,
    pub tables: Vec<Table>,
    pub commands: Vec<Command>,
    pub wire_hash: u16,
    pub schema_rev: u32,
}

impl Schema {
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.tables.iter().find(|t| t.name == name)
    }

    pub fn enum_(&self, name: &str) -> Option<&Enum> {
        self.enums.iter().find(|e| e.name == name)
    }

    pub fn command(&self, name: &str) -> Option<&Command> {
        self.commands.iter().find(|c| c.name == name)
    }

    pub fn domain_bit(&self, name: &str) -> u8 {
        self.domains.iter().find(|d| d.name == name).map_or(0, |d| d.bit)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub line: usize,
    pub message: String,
}

impl core::fmt::Display for Error {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        // The caller names the file it read.
        if self.line == 0 { write!(f, "{}", self.message) } else { write!(f, "{}: {}", self.line, self.message) }
    }
}

fn fail<T>(line: usize, message: String) -> Result<T, Error> {
    Err(Error { line, message })
}

// ------------------------------------------------------------------ parse

const TABLE_MODS: [&str; 6] = ["append_only", "soft_delete", "global", "account_optional", "singleton", "unmasked"];

/// Names: lowercase words for everything but frames, which are uppercase.
fn is_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty() && b[0].is_ascii_lowercase() && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
}

fn is_frame_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty() && b[0].is_ascii_uppercase() && b.iter().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || *c == b'_')
}

fn name(s: &str, line: usize) -> Result<(), Error> {
    if is_name(s) { Ok(()) } else { fail(line, format!("name {s}")) }
}

// Only ASCII space and tab separate tokens, in both parsers.
fn sep(c: char) -> bool {
    c == ' ' || c == '\t'
}

fn trim(s: &str) -> &str {
    s.trim_matches(|c| c == ' ' || c == '\t' || c == '\r')
}

fn tokens(s: &str) -> Vec<&str> {
    s.split(sep).filter(|t| !t.is_empty()).collect()
}

fn where_term(where_: &Option<String>, line: usize) -> Result<Option<Where>, Error> {
    let Some(w) = where_ else { return Ok(None) };
    if let Some((col, rest)) = w.split_once(" = ")
        && is_name(col)
        && rest.len() >= 2
        && rest.starts_with('\'')
        && rest.ends_with('\'')
        && !rest[1..rest.len() - 1].contains('\'')
    {
        return Ok(Some(Where::Eq(col.to_owned(), rest[1..rest.len() - 1].to_owned())));
    }
    if let Some(col) = w.strip_suffix(" is not null")
        && is_name(col)
    {
        return Ok(Some(Where::NotNull(col.to_owned())));
    }
    if let Some(col) = w.strip_suffix(" is null")
        && is_name(col)
    {
        return Ok(Some(Where::Null(col.to_owned())));
    }
    fail(line, format!("where takes col = 'value', col is null or col is not null: {w}"))
}

fn int_in(text: &str, lo: i128, hi: i128) -> bool {
    text.parse::<i128>().is_ok_and(|v| v >= lo && v <= hi)
}

// A default must be a value of its column's type.
fn default_ok(col: &Column, line: usize) -> Result<(), Error> {
    let Some(d) = &col.default else { return Ok(()) };
    let ok = match col.ty {
        Type::Bool => d == "true" || d == "false",
        Type::U8 => int_in(d, 0, 255),
        Type::U32 => int_in(d, 0, 4_294_967_295),
        Type::I64 => int_in(d, i64::MIN as i128, i64::MAX as i128),
        Type::F64 => {
            let digits = d.strip_prefix('-').unwrap_or(d);
            let (whole, frac) = digits.split_once('.').map_or((digits, None), |(w, f)| (w, Some(f)));
            !whole.is_empty()
                && whole.bytes().all(|b| b.is_ascii_digit())
                && frac.is_none_or(|f| !f.is_empty() && f.bytes().all(|b| b.is_ascii_digit()))
        }
        Type::Str | Type::Text => d.len() >= 2 && d.starts_with('\'') && d.ends_with('\'') && !d[1..d.len() - 1].contains('\''),
        Type::Enum => true,
        _ => false,
    };
    if ok { Ok(()) } else { fail(line, format!("default {d} is not a {}", col.ty.name())) }
}

struct RawParam {
    name: String,
    ty: Option<Type>,
    required: bool,
}

struct RawCommand {
    name: String,
    params: Vec<RawParam>,
    human_only: bool,
    line: usize,
}

struct RawTable {
    name: String,
    domain: String,
    residency: Residency,
    mods: Vec<String>,
    naturals: Vec<Key>,
    uniques: Vec<Key>,
    indexes: Vec<Index>,
    cap: Option<u32>,
    cols: Vec<Column>,
    picks: Vec<String>,
    source: Option<String>,
    source_where: Option<String>,
    source_term: Option<Where>,
    commands: Vec<RawCommand>,
    line: usize,
}

fn strip_comment(line: &str) -> &str {
    match line.find('#') {
        Some(at) => &line[..at],
        None => line,
    }
}

// The text before the first whitespace-delimited `where`, as tokens, and the
// trimmed text after it.
fn split_where(text: &str) -> (Vec<&str>, Option<String>) {
    let bytes = text.as_bytes();
    let gap = |b: u8| b == b' ' || b == b'\t';
    let mut i = 0;
    while i + 7 <= bytes.len() {
        if gap(bytes[i]) && &bytes[i + 1..i + 6] == b"where" && gap(bytes[i + 6]) {
            return (tokens(&text[..i]), Some(trim(&text[i + 7..]).to_owned()));
        }
        i += 1;
    }
    (tokens(text), None)
}

fn int(text: &str, line: usize, lo: i128, hi: i128) -> Result<i128, Error> {
    match text.parse::<i128>() {
        Ok(v) if v >= lo && v <= hi => Ok(v),
        Ok(v) => fail(line, format!("{v} is out of {lo}..{hi}")),
        Err(_) => fail(line, format!("not a number: {text}")),
    }
}

fn global(cols: &[&str], line: usize) -> Result<(bool, Vec<String>), Error> {
    match cols.iter().filter(|c| **c == "global").count() {
        0 | 1 => Ok((cols.contains(&"global"), cols.iter().filter(|c| **c != "global").map(|c| c.to_string()).collect())),
        _ => fail(line, "global twice".into()),
    }
}

fn desc(cols: &[&str]) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < cols.len() {
        if i + 1 < cols.len() && cols[i + 1] == "desc" {
            out.push((cols[i].to_owned(), true));
            i += 2;
        } else {
            out.push((cols[i].to_owned(), false));
            i += 1;
        }
    }
    out
}

fn walk(rest: &[&str], mut col: Column, line: usize) -> Result<Column, Error> {
    let mut i = 0;
    while i < rest.len() {
        match rest[i] {
            "!" => col.required = true,
            "?" => col.required = false,
            "=" => {
                let Some(v) = rest.get(i + 1) else {
                    return fail(line, "= needs a value".into());
                };
                col.default = Some((*v).to_owned());
                i += 1;
            }
            "deferred" => col.deferred = true,
            "private" => col.private = true,
            "server_only" => col.server_only = true,
            "human_only" => col.human_only = true,
            "readonly" => col.readonly = true,
            "unique" => col.unique = true,
            "cascade" => col.cascade = true,
            other => return fail(line, format!("flag {other}")),
        }
        i += 1;
    }
    if col.cascade && col.ty != Type::Ref {
        return fail(line, "cascade is a ref's".into());
    }
    default_ok(&col, line)?;
    Ok(col)
}

fn param(token: &str, line: usize) -> Result<RawParam, Error> {
    let (token, required) = match token.strip_suffix('?') {
        Some(t) => (t, false),
        None => (token, true),
    };
    if token.ends_with('?') {
        return fail(line, format!("param {token}?"));
    }
    match token.split_once(':') {
        Some((pname, ty)) => {
            name(pname, line)?;
            match Type::parse(ty) {
                Some(t) if !matches!(t, Type::Id | Type::Ref | Type::Enum) => {
                    Ok(RawParam { name: pname.to_owned(), ty: Some(t), required })
                }
                _ => fail(line, format!("param type {ty}")),
            }
        }
        None => {
            name(token, line)?;
            Ok(RawParam { name: token.to_owned(), ty: None, required })
        }
    }
}

fn table_line(t: &mut RawTable, tokens: &[&str], where_: Option<String>, line: usize) -> Result<(), Error> {
    match tokens {
        ["pick", cols @ ..] => {
            for c in cols {
                name(c, line)?;
            }
            t.picks.extend(cols.iter().map(|c| c.to_string()))
        }
        ["cap", n] => t.cap = Some(int(n, line, 1, 4_294_967_295)? as u32),
        ["natural", cols @ ..] => {
            if cols.is_empty() {
                return fail(line, "a key names its columns".into());
            }
            let term = where_term(&where_, line)?;
            t.naturals.push(Key { cols: cols.iter().map(|c| c.to_string()).collect(), global: false, where_, term })
        }
        ["unique", cols @ ..] => {
            let (global, cols) = global(cols, line)?;
            if cols.is_empty() {
                return fail(line, "a key names its columns".into());
            }
            let term = where_term(&where_, line)?;
            t.uniques.push(Key { cols, global, where_, term });
        }
        ["index", cols @ ..] => {
            let (global, cols) = global(cols, line)?;
            if cols.is_empty() {
                return fail(line, "an index names its columns".into());
            }
            let term = where_term(&where_, line)?;
            let cols: Vec<&str> = cols.iter().map(|s| s.as_str()).collect();
            t.indexes.push(Index { cols: desc(&cols), global, where_, term });
        }
        ["col", cname, ty, rest @ ..] => {
            name(cname, line)?;
            let Some(ty) = Type::parse(ty) else {
                return fail(line, format!("type {ty}"));
            };
            let (target, rest) = if matches!(ty, Type::Ref | Type::Enum) {
                match rest {
                    [target, rest @ ..] => {
                        name(target, line)?;
                        (Some((*target).to_owned()), rest)
                    }
                    [] => return fail(line, format!("{} needs a target", ty.name())),
                }
            } else {
                (None, rest)
            };
            let mut col = Column::blank(cname, ty);
            col.target = target;
            t.cols.push(walk(rest, col, line)?);
        }
        ["metric", mname, ty, rest @ ..] => {
            name(mname, line)?;
            let ty = match *ty {
                "u32" => Type::U32,
                "i64" => Type::I64,
                "f64" => Type::F64,
                other => return fail(line, format!("metric type {other}")),
            };
            let mut col = walk(rest, Column::blank(mname, ty), line)?;
            if col.required {
                return fail(line, "a metric is nullable".into());
            }
            col.metric = true;
            // The twin is the metric's own date: written with it, never
            // alone, and seen by whoever sees the metric.
            let mut twin = Column::blank(&format!("{mname}_on"), Type::Day);
            twin.metric_of = Some((*mname).to_owned());
            twin.readonly = true;
            twin.private = col.private;
            twin.server_only = col.server_only;
            twin.human_only = col.human_only;
            t.cols.push(col);
            t.cols.push(twin);
        }
        ["prose", pname, rest @ ..] => {
            name(pname, line)?;
            let rest = match rest {
                ["text", r @ ..] => r,
                r => r,
            };
            let rest = match rest {
                ["?", r @ ..] => r,
                r => r,
            };
            let mut col = walk(rest, Column::blank(pname, Type::Text), line)?;
            col.prose = true;
            col.deferred = true;
            t.cols.push(col);
        }
        ["command", cname, rest @ ..] => {
            name(cname, line)?;
            let human_only = match rest.iter().filter(|p| **p == "human_only").count() {
                0 => false,
                1 => true,
                _ => return fail(line, "human_only twice".into()),
            };
            let params = rest
                .iter()
                .filter(|p| **p != "human_only")
                .map(|p| param(p, line))
                .collect::<Result<Vec<_>, _>>()?;
            t.commands.push(RawCommand { name: (*cname).to_owned(), params, human_only, line });
        }
        _ => return fail(line, format!("unreadable: {}", tokens.join(" "))),
    }
    Ok(())
}

/// Parse and resolve a declaration.
pub fn parse(source: &str) -> Result<Schema, Error> {
    let mut domains: Vec<String> = Vec::new();
    let mut carry: Vec<String> = Vec::new();
    let mut layout: Option<u16> = None;
    let mut frames: Vec<Frame> = Vec::new();
    let mut enums: Vec<(String, Vec<String>)> = Vec::new();
    let mut tables: Vec<RawTable> = Vec::new();

    for (i, raw) in source.split('\n').enumerate() {
        let line = i + 1;
        let text = trim(strip_comment(raw));
        if text.is_empty() {
            continue;
        }
        let (tokens, where_) = split_where(text);
        match tokens.as_slice() {
            ["domain", names @ ..] => {
                for n in names {
                    name(n, line)?;
                }
                domains.extend(names.iter().map(|n| n.to_string()))
            }
            ["carry", names @ ..] => {
                for n in names {
                    name(n, line)?;
                }
                carry.extend(names.iter().map(|n| n.to_string()))
            }
            ["layout", n] => layout = Some(int(n, line, 0, 65_535)? as u16),
            ["frame", fname, id] => {
                if !is_frame_name(fname) {
                    return fail(line, format!("frame name {fname}"));
                }
                frames.push(Frame { name: (*fname).to_owned(), id: int(id, line, 1, 255)? as u8 })
            }
            ["enum", ename, values @ ..] if !values.is_empty() => {
                name(ename, line)?;
                for v in values {
                    name(v, line)?;
                }
                enums.push(((*ename).to_owned(), values.iter().map(|v| v.to_string()).collect()))
            }
            ["table", tname, domain, residency, mods @ ..] => {
                name(tname, line)?;
                let residency = match *residency {
                    "resident" => Residency::Resident,
                    "server" => Residency::Server,
                    "wire" => Residency::Wire,
                    other => return fail(line, format!("residency {other}")),
                };
                for (i, m) in mods.iter().enumerate() {
                    if !TABLE_MODS.contains(m) {
                        return fail(line, format!("table modifier {m}"));
                    }
                    if mods[..i].contains(m) {
                        return fail(line, "a table modifier twice".into());
                    }
                }
                if mods.contains(&"global") && mods.contains(&"singleton") {
                    return fail(line, "a global table has no account to be one row of".into());
                }
                tables.push(RawTable {
                    name: (*tname).to_owned(),
                    domain: (*domain).to_owned(),
                    residency,
                    mods: mods.iter().map(|m| m.to_string()).collect(),
                    naturals: vec![],
                    uniques: vec![],
                    indexes: vec![],
                    cap: None,
                    cols: vec![],
                    picks: vec![],
                    source: None,
                    source_where: None,
                    source_term: None,
                    commands: vec![],
                    line,
                });
            }
            ["projection", pname, domain, source] => {
                name(pname, line)?;
                if where_.is_none() {
                    return fail(line, "a projection needs a where".into());
                }
                let source_term = where_term(&where_, line)?;
                tables.push(RawTable {
                name: (*pname).to_owned(),
                domain: (*domain).to_owned(),
                residency: Residency::Projection,
                mods: vec![],
                naturals: vec![],
                uniques: vec![],
                indexes: vec![],
                cap: None,
                cols: vec![],
                picks: vec![],
                source: Some((*source).to_owned()),
                source_where: where_.clone(),
                source_term,
                commands: vec![],
                line,
            })
            }
            [kind, ..]
                if matches!(
                    *kind,
                    "col" | "metric" | "prose" | "natural" | "unique" | "index" | "cap" | "command" | "pick"
                ) =>
            {
                let Some(t) = tables.last_mut() else {
                    return fail(line, format!("{kind} outside a table"));
                };
                // A projection only picks its source's columns; a table never picks.
                if (t.residency == Residency::Projection) != (*kind == "pick") {
                    return fail(line, format!("{kind} in {} {}", if *kind == "pick" { "table" } else { "projection" }, t.name));
                }
                table_line(t, &tokens, where_, line)?;
            }
            _ => return fail(line, format!("unreadable line: {text}")),
        }
    }

    let Some(layout) = layout else { return fail(0, "no layout line".into()) };
    resolve(layout, carry, domains, frames, enums, tables)
}

fn implied(t: &RawTable) -> Vec<Column> {
    if !t.residency.stored() {
        return vec![];
    }
    let has = |m: &str| t.mods.iter().any(|x| x == m);
    let mut cols = Vec::new();
    let mut id = Column::blank("id", Type::Id);
    id.required = true;
    cols.push((1, id));
    if !has("global") {
        let mut a = Column::blank("account_id", Type::Ref);
        a.target = Some("accounts".into());
        a.required = !has("account_optional");
        cols.push((2, a));
    }
    let mut rev = Column::blank("rev", Type::I64);
    rev.required = true;
    rev.default = Some("1".into());
    cols.push((3, rev));
    let mut ins = Column::blank("inserted_at", Type::Time);
    ins.required = true;
    cols.push((4, ins));
    let mut upd = Column::blank("updated_at", Type::Time);
    upd.required = true;
    cols.push((5, upd));
    if has("soft_delete") {
        cols.push((6, Column::blank("deleted_at", Type::Time)));
    }
    cols.into_iter()
        .map(|(id, mut c)| {
            c.id = id;
            c.implied = true;
            c.readonly = true;
            c
        })
        .collect()
}

fn resolve_cols(t: &RawTable, all: &[RawTable]) -> Result<Vec<Column>, Error> {
    if t.residency == Residency::Projection {
        let src_name = t.source.as_deref().unwrap_or("");
        let Some(src) = all.iter().find(|s| s.name == src_name) else {
            return fail(t.line, format!("projection of {src_name}"));
        };
        if !src.residency.stored() {
            return fail(t.line, format!("a projection's source is a stored table, not {src_name}"));
        }
        let src_cols = resolve_cols(src, all)?;
        let mut out = Vec::new();
        for name in core::iter::once("id").chain(t.picks.iter().map(|s| s.as_str())) {
            match src_cols.iter().find(|c| c.name == name) {
                Some(c) => out.push(c.clone()),
                None => return fail(t.line, format!("{src_name} has no {name}")),
            }
        }
        return Ok(out);
    }
    let first: u16 = if t.residency == Residency::Wire { 1 } else { 8 };
    let mut cols = implied(t);
    for (i, c) in t.cols.iter().enumerate() {
        let mut c = c.clone();
        c.id = first + i as u16;
        cols.push(c);
    }
    Ok(cols)
}

fn resolve(
    layout: u16,
    carry: Vec<String>,
    domain_names: Vec<String>,
    frames: Vec<Frame>,
    raw_enums: Vec<(String, Vec<String>)>,
    raw: Vec<RawTable>,
) -> Result<Schema, Error> {
    dupes(domain_names.iter().map(String::as_str), "domain")?;
    for (i, n) in domain_names.iter().enumerate() {
        if n != "system" && i >= 8 {
            return fail(0, format!("domain {n}: a mask has eight bits"));
        }
    }
    for (n, values) in &raw_enums {
        dupes(values.iter().map(String::as_str), &format!("{n} value"))?;
    }
    let ids: Vec<String> = frames.iter().map(|f| f.id.to_string()).collect();
    dupes(ids.iter().map(String::as_str), "frame id")?;
    for c in &carry {
        if !raw_enums.iter().any(|(n, _)| n == c) {
            return fail(0, format!("carry names no enum {c}"));
        }
    }
    let domains = domain_names
        .iter()
        .enumerate()
        .map(|(i, n)| Domain { name: n.clone(), bit: if n == "system" { 0 } else { 1u8 << i } })
        .collect();

    let enums = raw_enums
        .into_iter()
        .enumerate()
        .map(|(i, (name, values))| Enum { id: i as u16 + 1, name, values })
        .collect();

    let mut tables = Vec::new();
    for (i, t) in raw.iter().enumerate() {
        let natural: Vec<&String> = t.naturals.iter().flat_map(|k| k.cols.iter()).collect();
        let mut cols = resolve_cols(t, &raw)?;
        for c in cols.iter_mut() {
            c.natural = natural.contains(&&c.name);
        }
        let has = |m: &str| t.mods.iter().any(|x| x == m);
        tables.push(Table {
            id: i as u16 + 1,
            name: t.name.clone(),
            domain: t.domain.clone(),
            residency: t.residency,
            append_only: has("append_only"),
            soft_delete: has("soft_delete"),
            global: has("global"),
            account_optional: has("account_optional"),
            singleton: has("singleton"),
            unmasked: has("unmasked"),
            naturals: t.naturals.clone(),
            uniques: t.uniques.clone(),
            indexes: t.indexes.clone(),
            cap: t.cap,
            cols,
            source: t.source.clone(),
            source_where: t.source_where.clone(),
            source_term: t.source_term.clone(),
        });
    }

    let mut commands = Vec::new();
    for t in &raw {
        let table = tables.iter().find(|x| x.name == t.name).unwrap();
        for c in &t.commands {
            let mut params = Vec::new();
            for (i, p) in c.params.iter().enumerate() {
                match p.ty {
                    None => {
                        let Some(col) = table.col(&p.name) else {
                            return fail(c.line, format!("command {}: no column {}", c.name, p.name));
                        };
                        params.push(Param {
                            id: col.id,
                            name: p.name.clone(),
                            ty: col.ty,
                            target: col.target.clone(),
                            required: p.required,
                            column: true,
                        });
                    }
                    Some(ty) => params.push(Param {
                        id: FREE_PARAM + i as u16,
                        name: p.name.clone(),
                        ty,
                        target: None,
                        required: p.required,
                        column: false,
                    }),
                }
            }
            commands.push(Command {
                id: commands.len() as u16 + 1,
                name: c.name.clone(),
                table: t.name.clone(),
                params,
                human_only: c.human_only,
            });
        }
    }

    let mut schema = Schema { layout, carry, domains, frames, enums, tables, commands, wire_hash: 0, schema_rev: 0 };
    validate(&schema)?;
    schema.wire_hash = fold(fnv(canonical(&schema, Scope::Wire).as_bytes()));
    schema.schema_rev = fnv(canonical(&schema, Scope::Full).as_bytes());
    Ok(schema)
}

fn dupes<'a>(names: impl Iterator<Item = &'a str>, what: &str) -> Result<(), Error> {
    let mut seen: Vec<&str> = Vec::new();
    for n in names {
        if seen.contains(&n) {
            return fail(0, format!("duplicate {what} {n}"));
        }
        seen.push(n);
    }
    Ok(())
}

fn validate(s: &Schema) -> Result<(), Error> {
    dupes(s.tables.iter().map(|t| t.name.as_str()), "table")?;
    dupes(s.enums.iter().map(|e| e.name.as_str()), "enum")?;
    dupes(s.commands.iter().map(|c| c.name.as_str()), "command")?;
    dupes(s.frames.iter().map(|f| f.name.as_str()), "frame")?;
    for t in &s.tables {
        if !s.domains.iter().any(|d| d.name == t.domain) {
            return fail(0, format!("{}: domain {}", t.name, t.domain));
        }
        dupes(t.cols.iter().map(|c| c.name.as_str()), &format!("{} column", t.name))?;
        for c in &t.cols {
            if c.id >= AS_OF {
                return fail(0, format!("{}.{}: id past 0xFFEF", t.name, c.name));
            }
            match c.ty {
                Type::Ref => {
                    let target = c.target.as_deref().unwrap_or("");
                    if s.table(target).is_none() {
                        return fail(0, format!("{}.{}: no table {target}", t.name, c.name));
                    }
                }
                Type::Enum => {
                    let target = c.target.as_deref().unwrap_or("");
                    let Some(e) = s.enum_(target) else {
                        return fail(0, format!("{}.{}: no enum {target}", t.name, c.name));
                    };
                    if let Some(d) = &c.default
                        && !e.values.contains(d)
                    {
                        return fail(0, format!("{}.{}: {d} not in {target}", t.name, c.name));
                    }
                }
                _ => {}
            }
        }
        if !t.global {
            let leads = t
                .naturals
                .iter()
                .chain(t.uniques.iter())
                .filter(|k| !k.global)
                .filter_map(|k| k.cols.first())
                .chain(t.indexes.iter().filter(|i| !i.global).filter_map(|i| i.cols.first().map(|(c, _)| c)));
            for c in leads {
                if c == "account_id" {
                    return fail(0, format!("{}: account_id already leads every per-account key and index", t.name));
                }
            }
        }
        let where_cols: Vec<String> = t
            .naturals
            .iter()
            .chain(t.uniques.iter())
            .filter_map(|k| k.term.as_ref())
            .chain(t.indexes.iter().filter_map(|i| i.term.as_ref()))
            .map(|w| w.col().to_owned())
            .collect();
        if let (Some(src), Some(term)) = (&t.source, &t.source_term) {
            let source = s.table(src).unwrap();
            if source.col(term.col()).is_none() {
                return fail(0, format!("{}: its where names no {src} column {}", t.name, term.col()));
            }
            term_fits(s, source, term)?;
        }
        for term in t.naturals.iter().chain(t.uniques.iter()).filter_map(|k| k.term.as_ref()).chain(t.indexes.iter().filter_map(|i| i.term.as_ref())) {
            term_fits(s, t, term)?;
        }
        let keys = t
            .naturals
            .iter()
            .chain(t.uniques.iter())
            .flat_map(|k| k.cols.iter())
            .chain(t.indexes.iter().flat_map(|i| i.cols.iter().map(|(c, _)| c)))
            .chain(where_cols.iter());
        for k in keys {
            if t.col(k).is_none() {
                return fail(0, format!("{}: key or index names no column {k}", t.name));
            }
        }
    }
    Ok(())
}

// A where's value must be one its column can hold, or the key never holds.
fn term_fits(s: &Schema, t: &Table, term: &Where) -> Result<(), Error> {
    let Where::Eq(col, v) = term else { return Ok(()) };
    let Some(c) = t.col(col) else { return Ok(()) };
    let digits = |x: &str| {
        let d = x.strip_prefix('-').unwrap_or(x);
        !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit())
    };
    let ok = match c.ty {
        Type::Enum => s.enum_(c.target.as_deref().unwrap_or("")).is_some_and(|e| e.values.contains(v)),
        Type::Bool => v == "true" || v == "false",
        Type::U8 | Type::U32 | Type::I64 | Type::Id | Type::Ref => digits(v),
        Type::F64 => {
            let (w, f) = v.split_once('.').map_or((v.as_str(), None), |(w, f)| (w, Some(f)));
            digits(w) && f.is_none_or(|f| !f.is_empty() && f.bytes().all(|b| b.is_ascii_digit()))
        }
        _ => true,
    };
    if ok { Ok(()) } else { fail(0, format!("{}: where {col} = '{v}' is no value of {col}", t.name)) }
}

// ------------------------------------------------------------------ hashes

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// What a client is compiled against: domains, frames, enums, commands,
    /// and the resident, wire and projection tables.
    Wire,
    /// Everything.
    Full,
}

fn dash(v: Option<&str>) -> &str {
    match v {
        None | Some("") => "-",
        Some(v) => v,
    }
}

fn bit(b: bool) -> &'static str {
    if b { "1" } else { "0" }
}

/// The declaration as canonical lines, the bytes the hashes cover.
pub fn canonical(s: &Schema, scope: Scope) -> String {
    let mut out = String::new();
    let mut line = |l: String| {
        out.push_str(&l);
        out.push('\n');
    };
    for d in &s.domains {
        line(format!("domain {} {}", d.name, d.bit));
    }
    line(format!("layout {}", s.layout));
    for f in &s.frames {
        line(format!("frame {} {}", f.name, f.id));
    }
    // The wire's enums: those its tables' columns and its commands' params
    // name, and those the frames carry. An enum only server tables use is not.
    let wire_enum = |name: &str| {
        s.carry.iter().any(|c| c == name)
            || s.tables
                .iter()
                .filter(|t| t.residency != Residency::Server)
                .flat_map(|t| t.cols.iter())
                .any(|c| c.ty == Type::Enum && c.target.as_deref() == Some(name))
            || s.commands.iter().flat_map(|c| c.params.iter()).any(|p| p.ty == Type::Enum && p.target.as_deref() == Some(name))
    };
    for e in &s.enums {
        if scope == Scope::Full || wire_enum(&e.name) {
            line(format!("enum {} {}", e.name, e.values.join(" ")));
        }
    }
    for t in &s.tables {
        if scope == Scope::Wire && t.residency == Residency::Server {
            continue;
        }
        let mods: Vec<&str> = [
            (t.append_only, "append_only"),
            (t.soft_delete, "soft_delete"),
            (t.global, "global"),
            (t.account_optional, "account_optional"),
            (t.singleton, "singleton"),
            (t.unmasked, "unmasked"),
        ]
        .iter()
        .filter(|(on, _)| *on)
        .map(|(_, n)| *n)
        .collect();
        let mods = mods.join(",");
        let cap = t.cap.map(|c| c.to_string());
        let mut head = format!(
            "table {} {} {} {} {} {}",
            t.id,
            t.name,
            t.domain,
            t.residency.name(),
            dash(Some(&mods)),
            dash(cap.as_deref())
        );
        if t.residency == Residency::Projection {
            head.push_str(&format!(
                " {} {}",
                t.source.as_deref().unwrap_or(""),
                t.source_where.as_deref().unwrap_or("")
            ));
        }
        line(head);
        for c in &t.cols {
            line(format!(
                "col {} {} {} {} {} {}",
                t.id,
                c.id,
                c.name,
                c.type_name(),
                c.flags(),
                dash(c.default.as_deref())
            ));
        }
        if scope == Scope::Full {
            for k in &t.naturals {
                line(format!("natural {} {} {}", t.id, k.cols.join(","), dash(k.where_.as_deref())));
            }
            for k in &t.uniques {
                line(format!(
                    "unique {} {} {} {}",
                    t.id,
                    k.cols.join(","),
                    bit(k.global),
                    dash(k.where_.as_deref())
                ));
            }
            for i in &t.indexes {
                let cols: Vec<String> = i
                    .cols
                    .iter()
                    .map(|(c, d)| if *d { format!("{c}:desc") } else { c.clone() })
                    .collect();
                line(format!(
                    "index {} {} {} {}",
                    t.id,
                    cols.join(","),
                    bit(i.global),
                    dash(i.where_.as_deref())
                ));
            }
        }
    }
    for c in &s.commands {
        let params: Vec<String> = c
            .params
            .iter()
            .map(|p| {
                format!(
                    "{}:{}:{}:{}",
                    p.name,
                    type_name(p.ty, p.target.as_deref()),
                    bit(p.required),
                    bit(p.column)
                )
            })
            .collect();
        let params = params.join(",");
        line(format!(
            "command {} {} {} {} {}",
            c.id,
            c.name,
            c.table,
            bit(c.human_only),
            dash(Some(&params))
        ));
    }
    out
}

/// FNV-1a, 32 bits.
pub fn fnv(bytes: &[u8]) -> u32 {
    let mut h: u32 = 0x811C_9DC5;
    for b in bytes {
        h ^= *b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

/// A 32-bit hash folded to the header's 16 bits.
pub fn fold(h: u32) -> u16 {
    ((h >> 16) ^ (h & 0xFFFF)) as u16
}
