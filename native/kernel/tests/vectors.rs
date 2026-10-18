//! Runs tests/vectors.json natively, through the same facade calls the
//! wasm exports make; native/kernel/vectors.mjs runs the same file under
//! WebAssembly.

use kernel::abi::{self, Kernel};
use kernel::judge::Ctx;
use serde_json::Value as J;

const OP_ID: u64 = 7;
const KEY_ID: u32 = 3;

fn table(name: &str) -> &'static schema::TableDef {
    schema::TABLES.iter().find(|t| t.name == name).unwrap_or_else(|| panic!("no table {name}"))
}

/// A JSON value as the u32 a column or param of `type_code`/`target` holds.
fn as_u32(v: &J, type_code: u8, target: Option<&str>) -> u32 {
    match v {
        J::Null => wire::NONE,
        J::Bool(b) => *b as u32,
        J::String(s) if type_code == schema::Type::Enum.code() => {
            let names = schema::enum_names(target.unwrap_or("")).unwrap_or(&[]);
            names.iter().position(|n| n == s).unwrap_or_else(|| panic!("no {s} in enum {target:?}")) as u32
        }
        J::Number(n) => n.as_u64().unwrap_or_else(|| panic!("{n} is not a u32")) as u32,
        _ => panic!("{v} is not a u32"),
    }
}

/// An expected cell in the form effects come back in: enums as codes,
/// bools as 0/1.
fn expected_cell(v: &J, def: Option<&schema::ColDef>) -> J {
    match (v, def) {
        (J::String(_) | J::Bool(_), Some(c)) if c.wire == wire::U32 => J::from(as_u32(v, c.type_code, c.target)),
        _ => v.clone(),
    }
}

fn boot(rows: &J) -> Vec<u8> {
    let mut w = wire::BodyWriter::new();
    for (name, list) in rows.as_object().unwrap() {
        let t = table(name);
        let list = list.as_array().unwrap();
        let mut cols: Vec<&schema::ColDef> = Vec::new();
        for r in list {
            for k in r.as_object().unwrap().keys() {
                let c = t.col_named(k).unwrap_or_else(|| panic!("no column {name}.{k}"));
                if !cols.iter().any(|x| x.id == c.id) {
                    cols.push(c);
                }
            }
        }
        let mut b = w.block(t.id, list.len());
        let get = |r: &J, c: &schema::ColDef| r.get(c.name).cloned().unwrap_or(J::Null);
        for c in cols {
            match c.wire {
                wire::U32 => b.u32s(c.id, list.iter().map(|r| as_u32(&get(r, c), c.type_code, c.target))),
                wire::STR => {
                    let s: Vec<String> = list.iter().map(|r| get(r, c).as_str().unwrap_or("").to_string()).collect();
                    b.strs(c.id, s.iter().map(String::as_str))
                }
                wire::I64 => b.i64s(c.id, list.iter().map(|r| get(r, c).as_i64().unwrap_or(wire::NONE64))),
                wire::F64 => b.f64s(c.id, list.iter().map(|r| get(r, c).as_f64().unwrap_or(f64::NAN))),
                other => panic!("wire type {other} in a vector"),
            };
        }
        b.done();
    }
    w.finish()
}

fn cell(o: &mut wire::OpWriter, id: u16, wire_ty: u8, type_code: u8, target: Option<&str>, v: &J) {
    match (wire_ty, v) {
        (_, J::Null) => o.null(id),
        (wire::U32, _) => o.u32(id, as_u32(v, type_code, target)),
        // Deferred text is written in full; only BOOT and PATCH defer it.
        (wire::STR | wire::DEFERRED, J::String(s)) => o.str(id, s),
        (wire::I64, _) => o.i64(id, v.as_i64().unwrap()),
        (wire::F64, _) => o.f64(id, v.as_f64().unwrap()),
        _ => panic!("cell {id} = {v}"),
    };
}

fn op(step: &J) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let target = step["target"].as_u64().unwrap_or(0) as u32;
    if let Some(name) = step["put"].as_str() {
        let t = table(name);
        let mut o = w.op(OP_ID, wire::PUT, 0, t.id, target, None);
        for (k, v) in step["cells"].as_object().unwrap() {
            let c = t.col_named(k).unwrap();
            cell(&mut o, c.id, c.wire, c.type_code, c.target, v);
        }
        o.done();
    } else if let Some(name) = step["command"].as_str() {
        let c = schema::COMMANDS.iter().find(|c| c.name == name).unwrap();
        let mut o = w.op(OP_ID, wire::COMMAND, 0, c.id, target, None);
        if let Some(params) = step["params"].as_object() {
            for (k, v) in params {
                let p = c.params.iter().find(|p| p.name == k).unwrap_or_else(|| panic!("no param {name}.{k}"));
                cell(&mut o, p.id, p.wire, p.type_code, p.target, v);
            }
        }
        o.done();
    }
    w.finish()[8..].to_vec()
}

/// `expected` holds within `actual`: objects by the keys listed, arrays
/// element by element at equal length, numbers to 1e-12 relative.
fn holds(expected: &J, actual: &J, at: &str) -> Result<(), String> {
    match (expected, actual) {
        (J::Object(e), J::Object(a)) => {
            for (k, v) in e {
                holds(v, a.get(k).unwrap_or(&J::Null), &format!("{at}.{k}"))?;
            }
            Ok(())
        }
        (J::Array(e), J::Array(a)) => {
            if e.len() != a.len() {
                return Err(format!("{at}: {} items, expected {}: {actual}", a.len(), e.len()));
            }
            e.iter().zip(a).enumerate().try_for_each(|(i, (x, y))| holds(x, y, &format!("{at}[{i}]")))
        }
        (J::Number(x), J::Number(y)) => {
            let (x, y) = (x.as_f64().unwrap(), y.as_f64().unwrap());
            if (x - y).abs() <= 1e-12 * x.abs().max(1.0) { Ok(()) } else { Err(format!("{at}: {y}, expected {x}")) }
        }
        _ if expected == actual => Ok(()),
        _ => Err(format!("{at}: {actual}, expected {expected}")),
    }
}

/// Expected effects with each cell in the effects' own form.
fn expected_effects(e: &J) -> J {
    J::Array(
        e.as_array()
            .unwrap()
            .iter()
            .map(|row| {
                let t = table(row["table"].as_str().unwrap());
                let cells: serde_json::Map<String, J> = row["cells"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(k, v)| (k.clone(), expected_cell(v, t.col_named(k))))
                    .collect();
                serde_json::json!({"table": t.name, "id": row["id"], "cells": cells})
            })
            .collect(),
    )
}

#[test]
fn vectors() {
    let file: J = serde_json::from_str(include_str!("vectors.json")).unwrap();
    let mut failures = Vec::new();
    for case in file["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let today = case["today"].as_i64().unwrap() as i32;
        let mut k = Kernel::new();
        k.set_today(today);
        k.boot(&boot(&case["rows"]), 1).unwrap();
        for (i, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let at = format!("{name} / step {i}");
            let result = if let Some(f) = step.get("view") {
                let ids = k.view(&abi::filter(&f.to_string()));
                holds(&step["ids"], &serde_json::json!(ids), &at)
            } else if let Some(doc) = step["doc"].as_str() {
                let got = match doc {
                    "atlas" => k.atlas(step["arg"].as_str()),
                    "lanes" => k.lanes(),
                    "overview" => k.overview(10),
                    "application" => k.application(step["arg"].as_u64().unwrap() as u32).unwrap_or(J::Null),
                    other => panic!("doc {other}"),
                };
                holds(&step["expect"], &got, &at)
            } else {
                let raw = op(step);
                let held = [];
                let ctx = Ctx { today, now: today as i64 * 86_400, human: step["human"].as_bool().unwrap_or(false), key_id: Some(KEY_ID), held: &held };
                match (k.judge(&raw, &ctx), step["refusal"].as_str()) {
                    (Ok(rows), None) => {
                        let r = holds(&expected_effects(&step["effects"]), &abi::effects_json(&rows), &at);
                        if step["apply"].as_bool() == Some(true) {
                            k.predict(&raw, &ctx).unwrap();
                        }
                        r
                    }
                    (Err(r), Some(want)) => {
                        let got = abi::refusal_json(&r);
                        holds(&serde_json::json!({"refusal": want, "data": step["data"]}), &got, &at)
                    }
                    (Ok(rows), Some(want)) => Err(format!("{at}: allowed {}, expected {want}", abi::effects_json(&rows))),
                    (Err(r), None) => Err(format!("{at}: refused {}", abi::refusal_json(&r))),
                }
            };
            if let Err(e) = result {
                failures.push(e);
            }
        }
    }
    assert!(failures.is_empty(), "{} vector failures:\n{}", failures.len(), failures.join("\n"));
}
