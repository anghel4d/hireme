//! CV masks: a small typed pattern language over one application's
//! facts, after ano's selection masks. A rule's text compiles once into
//! an [`Expr`] and matches applications by reading their [`Facts`].
//!
//! ```text
//! expr  := and ("|" and)*
//! and   := not ("&" not)*
//! not   := "!" not | atom
//! atom  := "(" expr ")" | "[" not ("," not)* "]" | test | MASKNAME
//! test  := field | field "_" | field op value
//! op    := "=" | "==" | "!=" | "<" | "<=" | ">" | ">=" | "in" | "~" | "^="
//! value := literal | "[" literal ("," literal)* "]" | field
//! literal := "text" | 12 | 1.5 | :symbol | DE | DE-BY | 2026-10-20 | true | false
//! ```
//!
//! `[a, b]` holds when every test does; `[!country]` is absence. A bare
//! bool field is true, any other bare field present. A comparison on an
//! absent field is false, so `country != DE` needs `country` present
//! while `!(country = DE)` does not. A bare lowercase name that is no
//! field names a mask. `~` is a word (or, on a list, an element) the
//! value contains; `^=` a prefix; text compares ignoring case. Enums
//! order by declaration, so `stage < :submitted` reads as it says.

use alloc::borrow::Cow;
use alloc::boxed::Box;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use std::sync::OnceLock;

use crate::{Day, text};

/// A field's type. Enum types name their value list ([`values`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ty {
    Bool,
    Text,
    Num,
    Day,
    Code,
    Enum(&'static str),
    Texts,
    Codes,
    Enums(&'static str),
}

impl Ty {
    fn elem(self) -> Option<Ty> {
        match self {
            Ty::Texts => Some(Ty::Text),
            Ty::Codes => Some(Ty::Code),
            Ty::Enums(e) => Some(Ty::Enum(e)),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Ty::Bool => "bool",
            Ty::Text => "text",
            Ty::Num => "num",
            Ty::Day => "day",
            Ty::Code => "code",
            Ty::Enum(_) => "enum",
            Ty::Texts | Ty::Codes | Ty::Enums(_) => "list",
        }
    }
}

/// One field a mask may read: its path and type, by index in [`fields`].
#[derive(Clone, Copy, Debug)]
pub struct Field {
    pub path: &'static str,
    pub ty: Ty,
}

const SIZES: &[&str] = &["mega", "large", "mid", "small"];
const TIERS: &[&str] = &["none", "frontier", "labs", "big_tech"];
const DEPARTMENTS: &[&str] = &["infra", "research", "security", "data", "product", "eng", "other"];
const FAMILIES: &[&str] = &["software_engineer", "research_engineer", "research_scientist", "sre", "data_engineer", "security_engineer", "other"];
const VENDORS: &[&str] = &[
    "greenhouse", "lever", "ashby", "workday", "icims", "smartrecruiters", "workable", "jobvite", "taleo", "successfactors", "bamboohr",
    "rippling", "eightfold", "gem", "unknown",
];

/// An enum type's values in order: the kernel's own, else the schema's.
pub fn values(name: &str) -> &'static [&'static str] {
    match name {
        "size" => SIZES,
        "tier" => TIERS,
        "department" => DEPARTMENTS,
        "family" => FAMILIES,
        "seniority" => crate::org::Seniority::NAMES,
        "vendor" => VENDORS,
        other => schema::enum_names(other).unwrap_or(&[]),
    }
}

/// Every field, in a fixed order: a field's index is its id in [`Facts::read`].
pub const FIELDS: &[Field] = &[
    Field { path: "id", ty: Ty::Num },
    Field { path: "no", ty: Ty::Num },
    Field { path: "company", ty: Ty::Text },
    Field { path: "role", ty: Ty::Text },
    Field { path: "location", ty: Ty::Text },
    Field { path: "work_mode", ty: Ty::Enum("work_mode") },
    Field { path: "employment", ty: Ty::Enum("employment") },
    Field { path: "channel", ty: Ty::Enum("app_channel") },
    Field { path: "stage", ty: Ty::Enum("stage") },
    Field { path: "status", ty: Ty::Enum("app_status") },
    Field { path: "gate", ty: Ty::Enum("gate") },
    Field { path: "band", ty: Ty::Enum("band") },
    Field { path: "score", ty: Ty::Num },
    Field { path: "keywords", ty: Ty::Texts },
    Field { path: "listing_on", ty: Ty::Day },
    Field { path: "place", ty: Ty::Text },
    Field { path: "country", ty: Ty::Code },
    Field { path: "city", ty: Ty::Text },
    Field { path: "region", ty: Ty::Text },
    Field { path: "subregion", ty: Ty::Text },
    Field { path: "company.domain", ty: Ty::Text },
    Field { path: "company.name", ty: Ty::Text },
    Field { path: "company.parent", ty: Ty::Text },
    Field { path: "company.applications", ty: Ty::Num },
    Field { path: "company.parent.applications", ty: Ty::Num },
    Field { path: "country.applications", ty: Ty::Num },
    Field { path: "office", ty: Ty::Enum("office_kind") },
    Field { path: "company.industry", ty: Ty::Text },
    Field { path: "company.sector", ty: Ty::Text },
    Field { path: "company.size", ty: Ty::Enum("size") },
    Field { path: "company.tier", ty: Ty::Enum("tier") },
    Field { path: "company.ownership", ty: Ty::Enum("ownership") },
    Field { path: "company.remote_policy", ty: Ty::Enum("remote_policy") },
    Field { path: "company.ats", ty: Ty::Enum("vendor") },
    Field { path: "company.headcount", ty: Ty::Num },
    Field { path: "company.hq", ty: Ty::Code },
    Field { path: "field", ty: Ty::Enum("department") },
    Field { path: "subfield", ty: Ty::Enum("family") },
    Field { path: "seniority", ty: Ty::Enum("seniority") },
    Field { path: "me.citizenships", ty: Ty::Codes },
    Field { path: "me.field", ty: Ty::Text },
    Field { path: "me.subfields", ty: Ty::Texts },
    Field { path: "me.residence", ty: Ty::Code },
    Field { path: "me.regions", ty: Ty::Codes },
    Field { path: "me.relocate", ty: Ty::Bool },
    Field { path: "me.work_modes", ty: Ty::Enums("work_mode") },
    Field { path: "me.employments", ty: Ty::Enums("employment") },
    Field { path: "me.pay_floor", ty: Ty::Num },
    Field { path: "me.available_on", ty: Ty::Day },
    Field { path: "me.notice_days", ty: Ty::Num },
    Field { path: "me.languages", ty: Ty::Codes },
];

/// A field's id by path.
pub fn field(path: &str) -> Option<usize> {
    FIELDS.iter().position(|f| f.path == path)
}

/// A value a field holds for one application.
#[derive(Clone, Debug, PartialEq)]
pub enum Val<'a> {
    Bool(bool),
    Text(Cow<'a, str>),
    Num(f64),
    Day(Day),
    Code(Cow<'a, str>),
    /// An enum value by its code (declaration order).
    Enum(u32),
    List(Vec<Val<'a>>),
}

/// What a mask reads: one application's value of each field, by id; none when absent.
pub trait Facts {
    fn read(&self, field: usize) -> Option<Val<'_>>;
}

/// A byte span in the text a rule was written in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub at: u32,
    pub len: u32,
}

/// Why a text does not compile, and where.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub span: Span,
    pub msg: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Op {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    In,
    Has,
    Prefix,
}

#[derive(Clone, Debug, PartialEq)]
enum Lit {
    Bool(bool),
    Text(String),
    Num(f64),
    Day(Day),
    Code(String),
    Enum(u32),
}

#[derive(Clone, Debug, PartialEq)]
enum Rhs {
    Lits(Vec<Lit>),
    Field(usize),
}

#[derive(Clone, Debug, PartialEq)]
enum Test {
    /// A bool field true, any other present.
    Bare(usize),
    Present(usize),
    Cmp(usize, Op, Rhs),
}

/// A compiled mask.
#[derive(Clone, Debug, PartialEq)]
pub struct Expr(Node);

#[derive(Clone, Debug, PartialEq)]
enum Node {
    All(Vec<Node>),
    Any(Vec<Node>),
    Not(Span, Box<Node>),
    Test(Span, Test),
    /// A named mask, inlined; the span is the name's in this text.
    Mask(Span, Box<Node>),
}

/// The first test that kept an expression from matching, the value it read
/// (`absent` when there was none), and its span in the rule's text.
#[derive(Clone, Debug, PartialEq)]
pub struct Fail {
    pub span: Span,
    pub read: String,
}

// ------------------------------------------------------------------ lexer

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Name(String),
    Code(String),
    Sym(String),
    Text(String),
    Num(f64),
    Day(Day),
    Punct(&'static str),
    End,
}

struct Lexer<'s> {
    src: &'s str,
    at: usize,
}

const PUNCT: &[&str] = &["==", "!=", "<=", ">=", "^=", "(", ")", "[", "]", ",", "&", "|", "!", "_", "=", "<", ">", "~"];

impl Lexer<'_> {
    fn next(&mut self) -> Result<(Tok, Span), Error> {
        let b = self.src.as_bytes();
        while self.at < b.len() && b[self.at].is_ascii_whitespace() {
            self.at += 1;
        }
        let start = self.at;
        let span = |end: usize| Span { at: start as u32, len: (end - start) as u32 };
        let Some(&c) = b.get(start) else { return Ok((Tok::End, span(start))) };
        let run = |from: usize, ok: fn(u8) -> bool| from + b[from..].iter().take_while(|&&x| ok(x)).count();
        let tok = if c == b'"' {
            let Some(len) = self.src[start + 1..].find('"') else {
                return Err(Error { span: span(b.len()), msg: "a text is not closed with \"".into() });
            };
            self.at = start + len + 2;
            Tok::Text(self.src[start + 1..start + 1 + len].to_string())
        } else if c == b':' {
            self.at = run(start + 1, |x| x.is_ascii_lowercase() || x.is_ascii_digit() || x == b'_');
            if self.at == start + 1 {
                return Err(Error { span: span(start + 1), msg: "a : names an enum value, like :remote".into() });
            }
            Tok::Sym(self.src[start + 1..self.at].to_string())
        } else if c.is_ascii_digit() || c == b'-' && b.get(start + 1).is_some_and(u8::is_ascii_digit) {
            self.at = run(start + 1, |x| x.is_ascii_digit() || x == b'.' || x == b'-');
            let s = &self.src[start..self.at];
            match crate::iso_day(s) {
                Some(d) => Tok::Day(d),
                None => match s.parse::<f64>() {
                    Ok(n) if n.is_finite() => Tok::Num(n),
                    _ => return Err(Error { span: span(self.at), msg: format!("{s} is neither a number nor a day (2026-10-20)") }),
                },
            }
        } else if c.is_ascii_uppercase() {
            self.at = run(start, |x| x.is_ascii_uppercase() || x.is_ascii_digit() || x == b'-');
            Tok::Code(self.src[start..self.at].to_string())
        } else if c.is_ascii_lowercase() || c == b'_' && b.get(start + 1).is_some_and(u8::is_ascii_lowercase) {
            self.at = run(start, |x| x.is_ascii_lowercase() || x.is_ascii_digit() || x == b'_' || x == b'.');
            Tok::Name(self.src[start..self.at].to_string())
        } else if let Some(p) = PUNCT.iter().find(|p| self.src[start..].starts_with(**p)) {
            self.at = start + p.len();
            Tok::Punct(p)
        } else {
            let ch = self.src[start..].chars().next().unwrap_or(' ');
            return Err(Error { span: span(start + ch.len_utf8()), msg: format!("{ch} has no meaning here") });
        };
        Ok((tok, span(self.at)))
    }
}

// ------------------------------------------------------------------ parser

/// The named masks a text may use: a name's text, if there is such a mask.
pub type Masks<'m> = &'m dyn Fn(&str) -> Option<&'m str>;

struct Parser<'s, 'm> {
    lex: Lexer<'s>,
    tok: Tok,
    span: Span,
    masks: Masks<'m>,
    /// The masks being compiled, outermost first: a name already here is a cycle.
    stack: Vec<String>,
}

/// Compile `text` against the fields and the named `masks`.
pub fn compile(text: &str, masks: Masks<'_>) -> Result<Expr, Error> {
    compile_in(text, masks, Vec::new()).map(Expr)
}

fn compile_in(text: &str, masks: Masks<'_>, stack: Vec<String>) -> Result<Node, Error> {
    let mut p = Parser { lex: Lexer { src: text, at: 0 }, tok: Tok::End, span: Span { at: 0, len: 0 }, masks, stack };
    p.bump()?;
    if p.tok == Tok::End {
        return Err(Error { span: p.span, msg: "a mask is empty: write a test, like country = DE".into() });
    }
    let e = p.or()?;
    if p.tok != Tok::End {
        return Err(p.err("expected & or | or the end here"));
    }
    Ok(e)
}

impl Parser<'_, '_> {
    fn bump(&mut self) -> Result<(), Error> {
        (self.tok, self.span) = self.lex.next()?;
        Ok(())
    }

    fn err(&self, msg: &str) -> Error {
        Error { span: self.span, msg: msg.into() }
    }

    fn eat(&mut self, p: &str) -> Result<bool, Error> {
        if self.tok == Tok::Punct(PUNCT.iter().find(|x| **x == p).copied().unwrap_or("")) {
            self.bump()?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn or(&mut self) -> Result<Node, Error> {
        let mut xs = alloc::vec![self.and()?];
        while self.eat("|")? {
            xs.push(self.and()?);
        }
        Ok(if xs.len() == 1 { xs.pop().unwrap_or(Node::All(Vec::new())) } else { Node::Any(xs) })
    }

    fn and(&mut self) -> Result<Node, Error> {
        let mut xs = alloc::vec![self.not()?];
        while self.eat("&")? {
            xs.push(self.not()?);
        }
        Ok(if xs.len() == 1 { xs.pop().unwrap_or(Node::All(Vec::new())) } else { Node::All(xs) })
    }

    fn not(&mut self) -> Result<Node, Error> {
        let at = self.span;
        if self.eat("!")? {
            let e = self.not()?;
            Ok(Node::Not(at, Box::new(e)))
        } else {
            self.atom()
        }
    }

    fn atom(&mut self) -> Result<Node, Error> {
        if self.eat("(")? {
            let e = self.or()?;
            if !self.eat(")")? {
                return Err(self.err("expected ) to close the ("));
            }
            return Ok(e);
        }
        if self.eat("[")? {
            let mut xs = Vec::new();
            loop {
                xs.push(self.not()?);
                if self.eat("]")? {
                    break;
                }
                if !self.eat(",")? {
                    return Err(self.err("expected , or ] in a [ ] pattern"));
                }
            }
            return Ok(if xs.len() == 1 { xs.pop().unwrap_or(Node::All(Vec::new())) } else { Node::All(xs) });
        }
        if let Tok::Name(name) = &self.tok
            && field(name).is_none()
        {
            let (name, span) = (name.clone(), self.span);
            return self.mask(&name, span);
        }
        self.test()
    }

    fn mask(&mut self, name: &str, span: Span) -> Result<Node, Error> {
        let Some(text) = (self.masks)(name) else {
            return Err(Error { span, msg: format!("{name} is neither a field nor a mask") });
        };
        if self.stack.iter().any(|n| n == name) {
            return Err(Error { span, msg: format!("mask {name} names itself through {}", self.stack.join(" -> ")) });
        }
        let mut stack = self.stack.clone();
        stack.push(name.into());
        let inner = compile_in(text, self.masks, stack).map_err(|e| Error { span, msg: format!("mask {name}: {}", e.msg) })?;
        self.bump()?;
        Ok(Node::Mask(span, Box::new(inner)))
    }

    fn field(&mut self) -> Result<(usize, Span), Error> {
        let Tok::Name(name) = &self.tok else { return Err(self.err("expected a field, like country or company.size")) };
        let Some(f) = field(name) else { return Err(self.err(&format!("{name} is not a field"))) };
        let span = self.span;
        self.bump()?;
        Ok((f, span))
    }

    fn test(&mut self) -> Result<Node, Error> {
        let (f, start) = self.field()?;
        let ty = FIELDS[f].ty;
        let whole = |end: Span| Span { at: start.at, len: end.at + end.len - start.at };
        if self.tok == Tok::Punct("_") {
            let end = self.span;
            self.bump()?;
            return Ok(Node::Test(whole(end), Test::Present(f)));
        }
        let op = match &self.tok {
            Tok::Punct("=" | "==") => Op::Eq,
            Tok::Punct("!=") => Op::Ne,
            Tok::Punct("<") => Op::Lt,
            Tok::Punct("<=") => Op::Le,
            Tok::Punct(">") => Op::Gt,
            Tok::Punct(">=") => Op::Ge,
            Tok::Punct("~") => Op::Has,
            Tok::Punct("^=") => Op::Prefix,
            Tok::Name(n) if n == "in" => Op::In,
            _ => return Ok(Node::Test(start, Test::Bare(f))),
        };
        let op_span = self.span;
        self.bump()?;
        let rhs_start = self.span;
        let rhs = self.rhs(ty, op)?;
        let end = Span { at: rhs_start.at, len: (self.lex_prev_end() - rhs_start.at as usize) as u32 };
        check(ty, op, &rhs).map_err(|msg| Error { span: Span { at: op_span.at, len: end.at + end.len - op_span.at }, msg })?;
        Ok(Node::Test(whole(end), Test::Cmp(f, op, rhs)))
    }

    /// Where the token before the current one ended.
    fn lex_prev_end(&self) -> usize {
        let src = self.lex.src.as_bytes();
        let mut end = self.span.at as usize;
        while end > 0 && src[end - 1].is_ascii_whitespace() {
            end -= 1;
        }
        end
    }

    fn rhs(&mut self, ty: Ty, op: Op) -> Result<Rhs, Error> {
        if let Tok::Name(name) = &self.tok
            && let Some(g) = field(name)
        {
            self.bump()?;
            return Ok(Rhs::Field(g));
        }
        let elem = ty.elem().unwrap_or(ty);
        if self.eat("[")? {
            let mut xs = Vec::new();
            loop {
                xs.push(self.lit(elem)?);
                if self.eat("]")? {
                    break;
                }
                if !self.eat(",")? {
                    return Err(self.err("expected , or ] in a list"));
                }
            }
            return Ok(Rhs::Lits(xs));
        }
        if op == Op::In {
            return Err(self.err("in takes a list on the right, like [DE, AT], or a list field"));
        }
        Ok(Rhs::Lits(alloc::vec![self.lit(elem)?]))
    }

    fn lit(&mut self, ty: Ty) -> Result<Lit, Error> {
        let lit = match (&self.tok, ty) {
            (Tok::Name(n), _) if n == "true" => Lit::Bool(true),
            (Tok::Name(n), _) if n == "false" => Lit::Bool(false),
            (Tok::Text(s), _) => Lit::Text(s.clone()),
            (Tok::Num(n), _) => Lit::Num(*n),
            (Tok::Day(d), _) => Lit::Day(*d),
            (Tok::Code(c), _) => {
                if !code(c) {
                    return Err(self.err(&format!("{c} is not an ISO code, like DE or DE-BY")));
                }
                Lit::Code(c.clone())
            }
            (Tok::Sym(s), Ty::Enum(e)) => match values(e).iter().position(|v| v == s) {
                Some(i) => Lit::Enum(i as u32),
                None => return Err(self.err(&format!(":{s} is not a {e}; one of :{}", values(e).join(" :")))),
            },
            (Tok::Sym(s), _) => return Err(self.err(&format!(":{s} is an enum value, but this field is not an enum"))),
            _ => return Err(self.err("expected a value")),
        };
        self.bump()?;
        Ok(lit)
    }
}

fn code(c: &str) -> bool {
    let (country, sub) = c.split_once('-').unwrap_or((c, ""));
    country.len() == 2 && country.bytes().all(|b| b.is_ascii_uppercase()) && (sub.is_empty() && !c.contains('-') || (1..=3).contains(&sub.len()))
}

fn lit_ty(l: &Lit) -> &'static str {
    match l {
        Lit::Bool(_) => "bool",
        Lit::Text(_) => "text",
        Lit::Num(_) => "num",
        Lit::Day(_) => "day",
        Lit::Code(_) => "code",
        Lit::Enum(_) => "enum",
    }
}

fn fits(ty: Ty, l: &Lit) -> bool {
    matches!(
        (ty, l),
        (Ty::Bool, Lit::Bool(_)) | (Ty::Text, Lit::Text(_)) | (Ty::Num, Lit::Num(_)) | (Ty::Day, Lit::Day(_)) | (Ty::Code, Lit::Code(_)) | (Ty::Enum(_), Lit::Enum(_))
    )
}

/// Whether `op` applies to a field of type `ty` with this value.
fn check(ty: Ty, op: Op, rhs: &Rhs) -> Result<(), String> {
    let list = ty.elem().is_some();
    match rhs {
        Rhs::Field(g) => {
            let other = FIELDS[*g].ty;
            let ok = match op {
                Op::In => other.elem() == Some(ty),
                Op::Has => ty.elem() == Some(other),
                Op::Eq | Op::Ne => other == ty && !list,
                Op::Lt | Op::Le | Op::Gt | Op::Ge => other == ty && matches!(ty, Ty::Num | Ty::Day | Ty::Enum(_)),
                Op::Prefix => false,
            };
            if ok { Ok(()) } else { Err(format!("a {} field cannot be compared to {} ({}) that way", ty.name(), FIELDS[*g].path, other.name())) }
        }
        Rhs::Lits(lits) => {
            let elem = ty.elem().unwrap_or(ty);
            if let Some(bad) = lits.iter().find(|l| !fits(elem, l)) {
                return Err(format!("this field holds {}, not {}", elem.name(), lit_ty(bad)));
            }
            let one = lits.len() == 1;
            let ok = match op {
                Op::In => !list,
                Op::Eq | Op::Ne => !list && one,
                Op::Lt | Op::Le | Op::Gt | Op::Ge => one && matches!(ty, Ty::Num | Ty::Day | Ty::Enum(_)),
                Op::Has => one && (list || ty == Ty::Text),
                Op::Prefix => one && matches!(ty, Ty::Text | Ty::Code),
            };
            if ok {
                Ok(())
            } else {
                Err(match op {
                    Op::In => "in takes a list on the right, and a single field on the left".into(),
                    Op::Has => "~ takes one value, on a text or list field".into(),
                    Op::Prefix => "^= takes one text, on a text or code field".into(),
                    _ if list => format!("a list field takes ~ (contains) or in, not {}", op_name(op)),
                    _ if !one => "use in to compare to a list".into(),
                    _ => format!("{} does not order {} values", op_name(op), ty.name()),
                })
            }
        }
    }
}

fn op_name(op: Op) -> &'static str {
    ["=", "!=", "<", "<=", ">", ">=", "in", "~", "^="][op as usize]
}

// ------------------------------------------------------------------ evaluation

impl Expr {
    /// Whether the application `facts` describes matches.
    pub fn matches(&self, facts: &dyn Facts) -> bool {
        self.0.explain(facts).is_none()
    }

    /// None when it matches; else the first test that kept it from matching.
    pub fn explain(&self, facts: &dyn Facts) -> Option<Fail> {
        self.0.explain(facts)
    }

    /// The fields the expression reads, by id.
    pub fn fields(&self) -> Vec<usize> {
        let mut out = Vec::new();
        self.0.fields(&mut out);
        out
    }
}

impl Node {
    fn explain(&self, facts: &dyn Facts) -> Option<Fail> {
        match self {
            Node::All(xs) => xs.iter().find_map(|x| x.explain(facts)),
            Node::Any(xs) => {
                let mut first = None;
                for x in xs {
                    let f = x.explain(facts)?;
                    first = first.or(Some(f));
                }
                first
            }
            Node::Not(span, x) => match x.explain(facts) {
                Some(_) => None,
                None => Some(Fail { span: *span, read: "matched".into() }),
            },
            Node::Mask(span, x) => x.explain(facts).map(|f| Fail { span: *span, read: f.read }),
            Node::Test(span, t) => {
                let (f, holds) = test(t, facts);
                (!holds).then(|| Fail { span: *span, read: facts.read(f).map_or_else(|| "absent".into(), |v| shown(&v, FIELDS[f].ty)) })
            }
        }
    }

    fn fields(&self, out: &mut Vec<usize>) {
        let mut add = |f: usize| {
            if !out.contains(&f) {
                out.push(f);
            }
        };
        match self {
            Node::All(xs) | Node::Any(xs) => xs.iter().for_each(|x| x.fields(out)),
            Node::Not(_, x) | Node::Mask(_, x) => x.fields(out),
            Node::Test(_, Test::Bare(f) | Test::Present(f)) => add(*f),
            Node::Test(_, Test::Cmp(f, _, rhs)) => {
                add(*f);
                if let Rhs::Field(g) = rhs {
                    add(*g);
                }
            }
        }
    }
}

fn shown(v: &Val<'_>, ty: Ty) -> String {
    match v {
        Val::Bool(b) => b.to_string(),
        Val::Text(s) => format!("\"{s}\""),
        Val::Num(n) => format!("{n}"),
        Val::Day(d) => crate::day_iso(*d),
        Val::Code(c) => c.to_string(),
        Val::Enum(i) => {
            let e = match ty {
                Ty::Enum(e) | Ty::Enums(e) => e,
                _ => "",
            };
            values(e).get(*i as usize).map_or_else(|| format!("#{i}"), |s| format!(":{s}"))
        }
        Val::List(xs) => format!("[{}]", xs.iter().map(|x| shown(x, ty)).collect::<Vec<_>>().join(", ")),
    }
}

/// The field a test reads, and whether it holds.
fn test(t: &Test, facts: &dyn Facts) -> (usize, bool) {
    match t {
        Test::Bare(f) => (*f, facts.read(*f).is_some_and(|v| v != Val::Bool(false) && v != Val::List(Vec::new()))),
        Test::Present(f) => (*f, facts.read(*f).is_some_and(|v| v != Val::List(Vec::new()))),
        Test::Cmp(f, op, rhs) => {
            let Some(left) = facts.read(*f) else { return (*f, false) };
            let holds = match rhs {
                Rhs::Lits(lits) => {
                    let lits: Vec<Val<'_>> = lits.iter().map(lit_val).collect();
                    cmp(&left, *op, &lits)
                }
                Rhs::Field(g) => match facts.read(*g) {
                    None => false,
                    Some(Val::List(xs)) if *op == Op::In => cmp(&left, Op::In, &xs),
                    Some(right) => cmp(&left, *op, core::slice::from_ref(&right)),
                },
            };
            (*f, holds)
        }
    }
}

fn lit_val(l: &Lit) -> Val<'_> {
    match l {
        Lit::Bool(b) => Val::Bool(*b),
        Lit::Text(s) => Val::Text(Cow::Borrowed(s)),
        Lit::Num(n) => Val::Num(*n),
        Lit::Day(d) => Val::Day(*d),
        Lit::Code(c) => Val::Code(Cow::Borrowed(c)),
        Lit::Enum(i) => Val::Enum(*i),
    }
}

fn same(a: &Val<'_>, b: &Val<'_>) -> bool {
    match (a, b) {
        (Val::Text(x), Val::Text(y)) => x.to_lowercase() == y.to_lowercase(),
        (Val::Code(x), Val::Code(y)) => x.eq_ignore_ascii_case(y),
        (Val::Num(x), Val::Num(y)) => x == y,
        _ => a == b,
    }
}

fn order(a: &Val<'_>, b: &Val<'_>) -> Option<core::cmp::Ordering> {
    match (a, b) {
        (Val::Num(x), Val::Num(y)) => x.partial_cmp(y),
        (Val::Day(x), Val::Day(y)) => Some(x.cmp(y)),
        (Val::Enum(x), Val::Enum(y)) => Some(x.cmp(y)),
        _ => None,
    }
}

fn cmp(left: &Val<'_>, op: Op, right: &[Val<'_>]) -> bool {
    use core::cmp::Ordering::{Equal, Greater, Less};
    let Some(r) = right.first() else { return false };
    match op {
        Op::Eq => same(left, r),
        Op::Ne => !same(left, r),
        Op::In => right.iter().any(|r| same(left, r)),
        Op::Lt => order(left, r) == Some(Less),
        Op::Le => matches!(order(left, r), Some(Less | Equal)),
        Op::Gt => order(left, r) == Some(Greater),
        Op::Ge => matches!(order(left, r), Some(Greater | Equal)),
        Op::Prefix => match (left, r) {
            (Val::Text(x) | Val::Code(x), Val::Text(y) | Val::Code(y)) => x.to_lowercase().starts_with(&y.to_lowercase()),
            _ => false,
        },
        Op::Has => match left {
            Val::List(xs) => xs.iter().any(|x| match (x, r) {
                (Val::Text(a), Val::Text(b)) => contains_words(a, b),
                _ => same(x, r),
            }),
            Val::Text(a) => matches!(r, Val::Text(b) if contains_words(a, b)),
            _ => false,
        },
    }
}

/// Whether `needle`'s words appear in `hay` in order, whole, ignoring case.
fn contains_words(hay: &str, needle: &str) -> bool {
    let (h, n) = (text::normalize(hay), text::normalize(needle));
    if n.is_empty() {
        return false;
    }
    let (h, n) = (format!(" {h} "), format!(" {n} "));
    h.contains(&n)
}

/// Every field as the builder lists it: path, type and enum values.
pub fn catalog() -> &'static str {
    static JSON: OnceLock<String> = OnceLock::new();
    JSON.get_or_init(|| {
        let fields: Vec<serde_json::Value> = FIELDS
            .iter()
            .map(|f| {
                let mut o = serde_json::json!({"path": f.path, "label": f.path.replace(['.', '_'], " "), "type": f.ty.name()});
                if let Some(e) = f.ty.elem() {
                    o["list_of"] = e.name().into();
                }
                // A count reads largest first.
                if f.path.ends_with(".applications") {
                    o["desc"] = true.into();
                }
                if let Ty::Enum(e) | Ty::Enums(e) = f.ty {
                    o["values"] = values(e).into();
                }
                o
            })
            .collect();
        serde_json::Value::from(fields).to_string()
    })
}
