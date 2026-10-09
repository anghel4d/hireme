// Reads priv/wire/schema.txt and writes the ids, the name tables and the
// schema hash as Rust constants. The Elixir encoder reads the same file,
// so the two sides cannot disagree on an id without the hash changing.

use std::fmt::Write as _;
use std::path::PathBuf;

fn main() {
    let dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let path = dir.join("../../priv/wire/schema.txt");
    println!("cargo:rerun-if-changed={}", path.display());
    let bytes = std::fs::read(&path).expect("priv/wire/schema.txt");
    let text = std::str::from_utf8(&bytes).expect("schema is utf-8");

    let mut h: u32 = 0x811c9dc5;
    for b in &bytes {
        h ^= *b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    let hash = ((h >> 16) ^ (h & 0xffff)) as u16;

    let mut frames = Vec::new();
    let mut tables: Vec<(String, u16)> = Vec::new();
    let mut cols: Vec<(String, String, u16, u8, String)> = Vec::new();
    let mut ops: Vec<(String, u8, String, Vec<String>)> = Vec::new();
    let mut refusals = Vec::new();

    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let w: Vec<&str> = line.split_whitespace().collect();
        match w[0] {
            "frame" if w.len() == 3 => frames.push((w[1].to_string(), w[2].parse::<u8>().unwrap())),
            "table" if w.len() == 3 => tables.push((w[1].to_string(), w[2].parse().unwrap())),
            "col" if w.len() == 5 => {
                let ty = match w[4] {
                    "u32" | "day" | "time" => 1,
                    // A sym column is stored like a str one; only its wire
                    // layout differs.
                    "str" | "sym" => 2,
                    "u64" => 3,
                    "f64" => 4,
                    _ => panic!("schema.txt:{}: cannot read {line:?}", n + 1),
                };
                if !tables.iter().any(|(t, _)| t == w[1]) {
                    panic!("schema.txt:{}: cannot read {line:?}", n + 1)
                }
                cols.push((
                    w[1].to_string(),
                    w[2].to_string(),
                    w[3].parse().unwrap(),
                    ty,
                    w[4].to_string(),
                ));
            }
            "op" if w.len() >= 4 => ops.push((
                w[1].to_string(),
                w[2].parse().unwrap(),
                w[3].to_string(),
                w[4..].iter().map(|s| s.to_string()).collect(),
            )),
            "refusal" if w.len() == 3 => {
                refusals.push((w[1].to_string(), w[2].parse::<u8>().unwrap()))
            }
            _ => panic!("schema.txt:{}: cannot read {line:?}", n + 1),
        }
    }

    let mut o = String::new();
    writeln!(
        o,
        "/// FNV-1a-32 of priv/wire/schema.txt, xor-folded to 16 bits."
    )
    .unwrap();
    writeln!(o, "pub const HASH: u16 = {hash:#06x};").unwrap();

    writeln!(o, "/// Frame kinds.\npub mod frame {{").unwrap();
    for (name, k) in &frames {
        writeln!(o, "    pub const {name}: u8 = {k};").unwrap();
    }
    writeln!(o, "}}\n/// Table ids.\npub mod table {{").unwrap();
    for (name, id) in &tables {
        writeln!(o, "    pub const {}: u16 = {id};", name.to_uppercase()).unwrap();
    }
    writeln!(
        o,
        "}}\n/// Column ids, one module per table.\npub mod col {{"
    )
    .unwrap();
    for (t, _) in &tables {
        writeln!(o, "    pub mod {t} {{").unwrap();
        for (ct, name, id, _, _) in &cols {
            if ct == t {
                writeln!(o, "        pub const {}: u16 = {id};", name.to_uppercase()).unwrap();
            }
        }
        writeln!(o, "    }}").unwrap();
    }
    writeln!(o, "}}\n/// Op kinds.\npub mod op {{").unwrap();
    for (name, k, _, _) in &ops {
        writeln!(o, "    pub const {}: u8 = {k};", name.to_uppercase()).unwrap();
    }
    writeln!(
        o,
        "}}\n/// Refusal codes; 0 means accepted.\npub mod refusal {{"
    )
    .unwrap();
    for (name, k) in &refusals {
        writeln!(o, "    pub const {}: u8 = {k};", name.to_uppercase()).unwrap();
    }
    writeln!(o, "}}").unwrap();

    writeln!(o, "pub const FRAMES: &[(u8, &str)] = &[").unwrap();
    for (name, k) in &frames {
        writeln!(o, "    ({k}, {name:?}),").unwrap();
    }
    writeln!(o, "];\npub const TABLES: &[(u16, &str)] = &[").unwrap();
    for (name, id) in &tables {
        writeln!(o, "    ({id}, {name:?}),").unwrap();
    }
    writeln!(o, "];\npub const COLS: &[ColDef] = &[").unwrap();
    for (t, name, id, ty, kind) in &cols {
        let tid = tables.iter().find(|(n, _)| n == t).unwrap().1;
        writeln!(
            o,
            "    ColDef {{ table: {tid}, col: {id}, ty: {ty}, name: {name:?}, kind: {kind:?} }},"
        )
        .unwrap();
    }
    writeln!(o, "];\npub const OPS: &[OpDef] = &[").unwrap();
    for (name, k, target, fields) in &ops {
        writeln!(
            o,
            "    OpDef {{ kind: {k}, name: {name:?}, target: {target:?}, fields: &{fields:?} }},"
        )
        .unwrap();
    }
    writeln!(o, "];\npub const REFUSALS: &[(u8, &str)] = &[").unwrap();
    for (name, k) in &refusals {
        writeln!(o, "    ({k}, {name:?}),").unwrap();
    }
    writeln!(o, "];").unwrap();

    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("schema.rs");
    std::fs::write(out, o).unwrap();
}
