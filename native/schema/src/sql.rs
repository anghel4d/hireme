//! The database: `priv/db/baseline.sql` from the declaration, and the
//! additive SQL that brings an older database's shape up to it.
//!
//! Tables are `STRICT`; ids are `AUTOINCREMENT`, so an id is never reused.
//! A required ref cascades on delete and a nullable one is set null. Keys
//! and indexes lead with `account_id` unless the table or the key is
//! `global`, and every account's table has `<table>__account (account_id)`. Enum values are stored by name, without a CHECK, so adding a
//! value is never a table rebuild.

use crate::model::{Column, Schema, Table, Type};
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

fn q(name: &str) -> String {
    format!("\"{name}\"")
}

fn sql_type(ty: Type) -> &'static str {
    match ty {
        Type::Id | Type::Ref | Type::Bool | Type::U8 | Type::U32 | Type::I64 => "INTEGER",
        Type::F64 => "REAL",
        Type::Day | Type::Time | Type::Str | Type::Text | Type::Json | Type::Enum => "TEXT",
        Type::Bytes => "BLOB",
    }
}

fn literal(col: &Column, value: &str) -> String {
    match col.ty {
        Type::Bool => (if value == "true" { "1" } else { "0" }).to_string(),
        Type::U8 | Type::U32 | Type::I64 | Type::F64 => value.to_string(),
        _ => {
            let inner = value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')).unwrap_or(value);
            format!("'{}'", inner.replace('\'', "''"))
        }
    }
}

/// One column as `CREATE TABLE` and `ADD COLUMN` spell it.
pub fn column(col: &Column) -> String {
    if col.ty == Type::Id {
        return format!("{} INTEGER PRIMARY KEY AUTOINCREMENT", q(&col.name));
    }
    let mut s = format!("{} {}", q(&col.name), sql_type(col.ty));
    if col.required {
        s.push_str(" NOT NULL");
    }
    if let Some(d) = &col.default {
        s.push_str(&format!(" DEFAULT {}", literal(col, d)));
    }
    if col.ty == Type::Ref {
        let on_delete = if col.required || col.cascade { "CASCADE" } else { "SET NULL" };
        s.push_str(&format!(
            " REFERENCES {}(\"id\") ON DELETE {on_delete}",
            q(col.target.as_deref().unwrap_or(""))
        ));
    }
    s
}

/// A named index of a table: its name and its `CREATE` statement.
pub struct IndexDef {
    pub name: String,
    pub sql: String,
}

/// Every index the declaration gives a table, uniques and naturals included.
pub fn indexes(t: &Table) -> Vec<IndexDef> {
    let mut out: Vec<IndexDef> = Vec::new();
    let scoped = !t.global;
    // Columns as (name, descending).
    let mut add = |kind: &str, unique: bool, global: bool, cols: Vec<(String, bool)>, where_: Option<&str>| {
        let lead = if scoped && !global { Some("\"account_id\"".to_string()) } else { None };
        let stem: Vec<String> =
            cols.iter().map(|(c, d)| if *d { format!("{c}_desc") } else { c.clone() }).collect();
        let stem = if stem.is_empty() { String::from("account_id") } else { stem.join("_") };
        let mut name = format!("{}__{kind}_{stem}", t.name);
        let mut n = 2;
        while out.iter().any(|i| i.name == name) {
            name = format!("{}__{kind}_{stem}_{n}", t.name);
            n += 1;
        }
        let cols: Vec<String> = lead
            .into_iter()
            .chain(cols.iter().map(|(c, d)| if *d { format!("{} DESC", q(c)) } else { q(c) }))
            .collect();
        let mut sql = format!(
            "CREATE {}INDEX {} ON {} ({})",
            if unique { "UNIQUE " } else { "" },
            q(&name),
            q(&t.name),
            cols.join(", ")
        );
        if let Some(w) = where_ {
            sql.push_str(&format!(" WHERE {w}"));
        }
        sql.push(';');
        out.push(IndexDef { name, sql });
    };

    // (account_id) alone gives every account's rows in rowid order, which
    // a keyset page by id walks without a sort; a singleton's unique key is
    // that index already.
    if t.singleton {
        add("single", true, false, Vec::new(), None);
    } else if scoped {
        add("account", false, false, Vec::new(), None);
    }
    let plain = |cols: &[String]| cols.iter().map(|c| (c.clone(), false)).collect::<Vec<_>>();
    for k in &t.naturals {
        add("natural", true, false, plain(&k.cols), k.where_.as_deref());
    }
    for k in &t.uniques {
        add("unique", true, k.global, plain(&k.cols), k.where_.as_deref());
    }
    for c in t.cols.iter().filter(|c| c.unique) {
        add("unique", true, false, alloc::vec![(c.name.clone(), false)], None);
    }
    for i in &t.indexes {
        add("index", false, i.global, i.cols.clone(), i.where_.as_deref());
    }
    out
}

/// The triggers that hold a ref to its own account: a row may name only a
/// row of an account-owned table that has the same account_id, so no
/// account reads another's ids through a ref or loses rows to another's
/// delete. The abort names `ref <table>.<col>`.
pub fn triggers(s: &Schema, t: &Table) -> Vec<IndexDef> {
    let mut out = Vec::new();
    if t.global {
        return out;
    }
    for c in t.cols.iter().filter(|c| c.ty == Type::Ref && !c.implied) {
        let target = c.target.as_deref().unwrap_or("");
        if s.table(target).is_none_or(|p| p.global) {
            continue;
        }
        // A row with no account yet (audit before sign-in) names nothing to hold.
        let unowned = if t.account_optional { " AND NEW.\"account_id\" IS NOT NULL" } else { "" };
        let check = format!(
            "WHEN NEW.{col} IS NOT NULL{unowned} AND NOT EXISTS (SELECT 1 FROM {p} WHERE \"id\" = NEW.{col} AND \"account_id\" IS NEW.\"account_id\") BEGIN SELECT RAISE(ABORT, 'ref {t}.{c}'); END;",
            col = q(&c.name),
            p = q(target),
            t = t.name,
            c = c.name
        );
        for (when, on) in [("insert", "INSERT".to_string()), ("update", format!("UPDATE OF {}, \"account_id\"", q(&c.name)))] {
            let name = format!("{}__ref_{}_{when}", t.name, c.name);
            let sql = format!("CREATE TRIGGER {} BEFORE {on} ON {} {check}", q(&name), q(&t.name));
            out.push(IndexDef { name, sql });
        }
    }
    out
}

fn create_table(t: &Table) -> String {
    let cols: Vec<String> = t.cols.iter().map(|c| format!("  {}", column(c))).collect();
    format!("CREATE TABLE {} (\n{}\n) STRICT;\n", q(&t.name), cols.join(",\n"))
}

fn stored(s: &Schema) -> impl Iterator<Item = &Table> {
    s.tables.iter().filter(|t| t.residency.stored())
}

/// `priv/db/baseline.sql`: the whole declaration on an empty database.
pub fn baseline(s: &Schema) -> String {
    // No hash in the header: the baseline changes only when its SQL does,
    // so a frozen one admits a cap, a flag or an enum value without a step.
    let mut out = String::from("-- Generated by `mix hireme.schema` from schema/hireme.schema; do not edit.\n");
    for t in stored(s) {
        out.push('\n');
        out.push_str(&create_table(t));
        for i in indexes(t).into_iter().chain(triggers(s, t)) {
            out.push_str(&i.sql);
            out.push('\n');
        }
    }
    out
}

/// A database's shape, as `mix hireme.schema` reads it from SQLite.
#[derive(Default)]
pub struct Shape {
    /// Table name and its columns.
    pub tables: Vec<(String, Vec<ShapeCol>)>,
    pub indexes: Vec<String>,
    pub triggers: Vec<String>,
    /// An index's or trigger's SQL as SQLite holds it, by name.
    pub sql: Vec<(String, String)>,
    /// A ref's ON DELETE action: table, column, action.
    pub fks: Vec<(String, String, String)>,
}

// SQL compared as text: single spaces, no trailing semicolon.
fn norm(sql: &str) -> String {
    sql.split_whitespace().collect::<Vec<_>>().join(" ").trim_end_matches(';').to_string()
}

/// A column as SQLite reports it (`pragma_table_info`).
pub struct ShapeCol {
    pub name: String,
    pub sql_type: String,
    pub not_null: bool,
    /// The default's SQL text, `-` for none.
    pub default: String,
}

impl Shape {
    /// Lines of `table <name>`, `col <table> <name> <type> <0|1> <default|->`,
    /// `index <name>` and `trigger <name>`.
    pub fn read(text: &str) -> Result<Shape, String> {
        let mut shape = Shape::default();
        for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            match parts.as_slice() {
                ["table", name] => shape.tables.push((name.to_string(), Vec::new())),
                ["col", table, name, ty, nn, default @ ..] => {
                    let col = ShapeCol {
                        name: name.to_string(),
                        sql_type: ty.to_string(),
                        not_null: *nn == "1",
                        default: default.join(" "),
                    };
                    match shape.tables.iter_mut().find(|(t, _)| t == table) {
                        Some((_, cols)) => cols.push(col),
                        None => shape.tables.push((table.to_string(), alloc::vec![col])),
                    }
                }
                ["index", name] => shape.indexes.push(name.to_string()),
                ["trigger", name] => shape.triggers.push(name.to_string()),
                ["sql", name, rest @ ..] => shape.sql.push((name.to_string(), norm(&rest.join(" ")))),
                ["fk", table, col, action @ ..] => {
                    shape.fks.push((table.to_string(), col.to_string(), action.join(" ")))
                }
                _ => return Err(format!("unreadable shape line: {line}")),
            }
        }
        Ok(shape)
    }
}

/// What an additive diff found.
pub struct Diff {
    /// The SQL that adds what the shape lacks; empty when nothing does.
    pub sql: String,
    /// What the shape has and the declaration does not: a destructive
    /// change, written by hand as `NNNN_drop_<what>.sql`.
    pub extra: Vec<String>,
}

/// The declaration minus `shape`: new tables, new columns, new indexes.
/// Refuses a new required column without a default, which no `ADD COLUMN`
/// can fill.
pub fn additive(s: &Schema, shape: &Shape) -> Result<Diff, String> {
    let mut sql = String::new();
    let mut extra = Vec::new();
    for t in stored(s) {
        match shape.tables.iter().find(|(n, _)| *n == t.name) {
            None => {
                sql.push_str(&create_table(t));
                for i in indexes(t).into_iter().chain(triggers(s, t)) {
                    sql.push_str(&i.sql);
                    sql.push('\n');
                }
            }
            Some((_, have)) => {
                for c in &t.cols {
                    if let Some(h) = have.iter().find(|h| h.name == c.name) {
                        // An existing column whose type, nullability or default
                        // moved: no ADD COLUMN reaches it, so it is the hand's.
                        let default = match &c.default {
                            Some(d) => literal(c, d),
                            None => String::from("-"),
                        };
                        let ty = if c.ty == Type::Id { "INTEGER" } else { sql_type(c.ty) };
                        let not_null = c.required && c.ty != Type::Id;
                        if h.sql_type != ty || h.not_null != not_null || h.default != default {
                            extra.push(format!(
                                "column {}.{} changed: {} {} {} -> {ty} {} {default}",
                                t.name,
                                c.name,
                                h.sql_type,
                                if h.not_null { "NOT NULL" } else { "NULL" },
                                h.default,
                                if not_null { "NOT NULL" } else { "NULL" }
                            ));
                        }
                        continue;
                    }
                    if c.required && c.default.is_none() {
                        return Err(format!(
                            "{}.{} is new, required and has no default; write that migration by hand",
                            t.name, c.name
                        ));
                    }
                    sql.push_str(&format!("ALTER TABLE {} ADD COLUMN {};\n", q(&t.name), column(c)));
                }
                for c in have {
                    if t.col(&c.name).is_none() {
                        extra.push(format!("column {}.{} is in the database, not the declaration", t.name, c.name));
                    }
                }
                for (i, have) in indexes(t).into_iter().map(|i| (i, &shape.indexes)).chain(triggers(s, t).into_iter().map(|i| (i, &shape.triggers))) {
                    if !have.contains(&i.name) {
                        sql.push_str(&i.sql);
                        sql.push('\n');
                    } else if let Some((_, held)) = shape.sql.iter().find(|(n, _)| *n == i.name)
                        && *held != norm(&i.sql)
                    {
                        extra.push(format!("{} changed: {held} -> {}", i.name, norm(&i.sql)));
                    }
                }
                for c in t.cols.iter().filter(|c| c.ty == Type::Ref) {
                    let want = if c.required || c.cascade { "CASCADE" } else { "SET NULL" };
                    if let Some((_, _, held)) = shape.fks.iter().find(|(tn, cn, _)| *tn == t.name && *cn == c.name)
                        && held != want
                    {
                        extra.push(format!("column {}.{} changed: ON DELETE {held} -> ON DELETE {want}", t.name, c.name));
                    }
                }
            }
        }
    }
    for (name, _) in &shape.tables {
        if !stored(s).any(|t| t.name == *name) {
            extra.push(format!("table {name} is in the database, not the declaration"));
        }
    }
    let declared: Vec<String> = stored(s).flat_map(|t| indexes(t).into_iter().map(|i| i.name)).collect();
    for i in &shape.indexes {
        if !declared.contains(i) {
            extra.push(format!("index {i} is in the database, not the declaration"));
        }
    }
    let declared: Vec<String> = stored(s).flat_map(|t| triggers(s, t).into_iter().map(|i| i.name)).collect();
    for i in &shape.triggers {
        if !declared.contains(i) {
            extra.push(format!("trigger {i} is in the database, not the declaration"));
        }
    }
    Ok(Diff { sql, extra })
}
