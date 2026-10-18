//! `hireme-schema`: the emitters behind `mix hireme.schema`.
//!
//!   hireme-schema sql                 priv/db/baseline.sql on stdout
//!   hireme-schema ts                  assets/js/gen/schema.ts on stdout
//!   hireme-schema diff <shape-file>   additive SQL for a database's shape;
//!                                     extras (destructive) on stderr, exit 3
//!   hireme-schema canonical wire|full the bytes the hashes cover
//!   hireme-schema hash                wire_hash and schema_rev
//!
//! Every command reads the declaration from `--schema <path>` (default: the
//! one compiled in), so the mix task can run it against the tree's file.

use schema::{Scope, sql, ts};
use std::io::Write;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let (path, source) = match args.iter().position(|a| a == "--schema") {
        Some(i) if i + 1 < args.len() => {
            let path = args.remove(i + 1);
            args.remove(i);
            match std::fs::read_to_string(&path) {
                Ok(s) => (path, s),
                Err(e) => return fail(&format!("{path}: {e}")),
            }
        }
        Some(_) => return fail("--schema needs a path"),
        None => ("schema/hireme.schema (compiled in)".to_owned(), schema::SOURCE.to_owned()),
    };
    let model = match schema::parse(&source) {
        Ok(m) => m,
        Err(e) => return fail(&format!("{path}:{e}")),
    };

    let out = match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["sql"] => sql::baseline(&model),
        ["ts"] => ts::emit(&model),
        ["canonical", "wire"] => schema::canonical(&model, Scope::Wire),
        ["canonical", "full"] => schema::canonical(&model, Scope::Full),
        ["hash"] => format!("wire_hash {:#06x}\nschema_rev {:#010x}\n", model.wire_hash, model.schema_rev),
        ["diff", path] => {
            let text = match std::fs::read_to_string(path) {
                Ok(t) => t,
                Err(e) => return fail(&format!("{path}: {e}")),
            };
            let shape = match sql::Shape::read(&text) {
                Ok(s) => s,
                Err(e) => return fail(&e),
            };
            match sql::additive(&model, &shape) {
                Ok(diff) if diff.extra.is_empty() => diff.sql,
                Ok(diff) => {
                    print(&diff.sql);
                    for x in &diff.extra {
                        eprintln!("destructive: {x}");
                    }
                    return ExitCode::from(3);
                }
                Err(e) => return fail(&e),
            }
        }
        _ => return fail("usage: hireme-schema [--schema <path>] sql | ts | diff <shape> | canonical wire|full | hash"),
    };
    print(&out);
    ExitCode::SUCCESS
}

fn print(s: &str) {
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(s.as_bytes());
}

fn fail(msg: &str) -> ExitCode {
    eprintln!("hireme-schema: {msg}");
    ExitCode::from(2)
}
