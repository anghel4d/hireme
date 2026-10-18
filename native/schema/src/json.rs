//! `priv/schema.json`: the resolved declaration, one table or command per
//! line, for `Hireme.Schema`, which loads it at compile time instead of
//! parsing the file a second time. Keys are the Elixir model's.

use crate::model::{Column, Index, Key, Param, Schema, Table, Type, Where};
use crate::ts::{json_str, opt_str};
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

pub fn emit(s: &Schema) -> String {
    let domains: Vec<String> = s
        .domains
        .iter()
        .map(|d| format!("{{\"name\":{},\"bit\":{}}}", json_str(&d.name), d.bit))
        .collect();
    let frames: Vec<String> = s
        .frames
        .iter()
        .map(|f| format!("{{\"name\":{},\"id\":{}}}", json_str(&f.name), f.id))
        .collect();
    let enums: Vec<String> = s
        .enums
        .iter()
        .map(|e| {
            format!(
                "{{\"id\":{},\"name\":{},\"values\":{}}}",
                e.id,
                json_str(&e.name),
                strs(&e.values)
            )
        })
        .collect();
    let tables: Vec<String> = s.tables.iter().map(table).collect();
    let commands: Vec<String> = s.commands.iter().map(command).collect();
    format!(
        "{{\"layout\":{},\"wire_hash\":{},\"schema_rev\":{},\"carry\":{},\n\"domains\":[{}],\n\"frames\":[{}],\n\"enums\":[\n{}],\n\"tables\":[\n{}],\n\"commands\":[\n{}]}}\n",
        s.layout,
        s.wire_hash,
        s.schema_rev,
        strs(&s.carry),
        domains.join(","),
        frames.join(","),
        enums.join(",\n"),
        tables.join(",\n"),
        commands.join(",\n")
    )
}

fn strs(v: &[String]) -> String {
    let items: Vec<String> = v.iter().map(|x| json_str(x)).collect();
    format!("[{}]", items.join(","))
}

fn opt_u32(v: Option<u32>) -> String {
    v.map_or(String::from("null"), |n| format!("{n}"))
}

fn term(t: Option<&Where>) -> String {
    match t {
        None => String::from("null"),
        Some(Where::Eq(c, v)) => format!("[\"eq\",{},{}]", json_str(c), json_str(v)),
        Some(Where::Null(c)) => format!("[\"null\",{}]", json_str(c)),
        Some(Where::NotNull(c)) => format!("[\"not_null\",{}]", json_str(c)),
    }
}

fn key(k: &Key) -> String {
    format!(
        "{{\"cols\":{},\"global\":{},\"where\":{},\"where_term\":{}}}",
        strs(&k.cols),
        k.global,
        opt_str(k.where_.as_deref()),
        term(k.term.as_ref())
    )
}

fn index(i: &Index) -> String {
    let cols: Vec<String> = i
        .cols
        .iter()
        .map(|(c, desc)| format!("[{},{}]", json_str(c), desc))
        .collect();
    format!(
        "{{\"cols\":[{}],\"global\":{},\"where\":{},\"where_term\":{}}}",
        cols.join(","),
        i.global,
        opt_str(i.where_.as_deref()),
        term(i.term.as_ref())
    )
}

/// The derived keys every reader wants on a column or param: its wire and
/// catalog type codes, and its target under the name of what it is.
fn typed(ty: Type, target: Option<&str>) -> String {
    format!(
        "\"type\":{},\"target\":{},\"wire\":{},\"type_code\":{},\"ref\":{},\"enum\":{}",
        json_str(ty.name()),
        opt_str(target),
        ty.wire(),
        ty.code(),
        opt_str(if ty == Type::Ref { target } else { None }),
        opt_str(if ty == Type::Enum { target } else { None })
    )
}

fn column(c: &Column) -> String {
    format!(
        "{{\"id\":{},\"name\":{},{},\"required\":{},\"default\":{},\"deferred\":{},\"private\":{},\"server_only\":{},\"human_only\":{},\"readonly\":{},\"unique\":{},\"cascade\":{},\"loose\":{},\"natural\":{},\"metric\":{},\"metric_of\":{},\"sha_of\":{},\"prose\":{},\"implied\":{},\"flags\":{}}}",
        c.id,
        json_str(&c.name),
        typed(c.ty, c.target.as_deref()),
        c.required,
        opt_str(c.default.as_deref()),
        c.deferred,
        c.private,
        c.server_only,
        c.human_only,
        c.readonly,
        c.unique,
        c.cascade,
        c.loose,
        c.natural,
        c.metric,
        opt_str(c.metric_of.as_deref()),
        opt_str(c.sha_of.as_deref()),
        c.prose,
        c.implied,
        c.flags()
    )
}

fn param(p: &Param) -> String {
    format!(
        "{{\"id\":{},\"name\":{},{},\"required\":{},\"column\":{}}}",
        p.id,
        json_str(&p.name),
        typed(p.ty, p.target.as_deref()),
        p.required,
        p.column
    )
}

fn table(t: &Table) -> String {
    let list = |v: Vec<String>| format!("[{}]", v.join(","));
    format!(
        "{{\"id\":{},\"name\":{},\"domain\":{},\"residency\":{},\"append_only\":{},\"soft_delete\":{},\"global\":{},\"account_optional\":{},\"singleton\":{},\"unmasked\":{},\"cap\":{},\"source\":{},\"source_where\":{},\"source_term\":{},\"naturals\":{},\"uniques\":{},\"indexes\":{},\"cols\":{}}}",
        t.id,
        json_str(&t.name),
        json_str(&t.domain),
        json_str(t.residency.name()),
        t.append_only,
        t.soft_delete,
        t.global,
        t.account_optional,
        t.singleton,
        t.unmasked,
        opt_u32(t.cap),
        opt_str(t.source.as_deref()),
        opt_str(t.source_where.as_deref()),
        term(t.source_term.as_ref()),
        list(t.naturals.iter().map(key).collect()),
        list(t.uniques.iter().map(key).collect()),
        list(t.indexes.iter().map(index).collect()),
        list(t.cols.iter().map(column).collect())
    )
}

fn command(c: &crate::model::Command) -> String {
    let params: Vec<String> = c.params.iter().map(param).collect();
    format!(
        "{{\"id\":{},\"name\":{},\"table\":{},\"human_only\":{},\"params\":[{}]}}",
        c.id,
        json_str(&c.name),
        json_str(&c.table),
        c.human_only,
        params.join(",")
    )
}
