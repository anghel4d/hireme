//! The declaration's contract: what each hash covers, and the lines it refuses.

use schema::{SOURCE, parse};

fn with(after: &str, line: &str) -> String {
    let at = SOURCE.find(after).expect("anchor in the declaration") + after.len();
    let mut s = SOURCE.to_owned();
    s.insert_str(at, &format!("\n{line}"));
    s
}

#[test]
fn a_server_table_metric_moves_schema_rev_alone_and_a_resident_column_moves_both() {
    let base = parse(SOURCE).unwrap();

    // Appended, as a new column must be: one inserted earlier renumbers the
    // columns after it. A server table (api_keys) never travels.
    let server = parse(&with("  col paused_at time ? readonly", "  metric probe_metric u32")).unwrap();
    assert_eq!(server.wire_hash, base.wire_hash);
    assert_ne!(server.schema_rev, base.schema_rev);
    assert!(server.table("api_keys").unwrap().col("probe_metric_on").is_some());

    let hidden = parse(&with("  col cv_theme json ?", "  col probe_hidden str ? server_only")).unwrap();
    assert_eq!(hidden.wire_hash, base.wire_hash, "a server_only column never travels");
    let hidden_enum = parse(&with(
        "  col cv_theme json ?",
        "  col probe_hidden enum probe_kind ? server_only",
    ).replacen("enum place_kind", "enum probe_kind a b\nenum place_kind", 1))
    .unwrap();
    assert_eq!(hidden_enum.wire_hash, base.wire_hash, "an enum only server_only columns use never travels");

    let resident = parse(&with("table applications desk resident", "  col probe_col str ?")).unwrap();
    assert_ne!(resident.wire_hash, base.wire_hash);
    assert_ne!(resident.schema_rev, base.schema_rev);
}

#[test]
fn the_layout_line_is_part_of_what_a_client_is_compiled_against() {
    let base = parse(SOURCE).unwrap();
    let bumped = parse(&SOURCE.replacen(&format!("layout {}", base.layout), &format!("layout {}", base.layout + 1), 1)).unwrap();
    assert_ne!(bumped.wire_hash, base.wire_hash);
}

#[test]
fn malformed_lines_are_refused_with_their_line_number() {
    let cases = [
        with("table places world resident", "  col nope widget ?"),
        with("table places world resident", "  pick name"),
        with("pick kind", "  col oops str ?"),
        with("table places world resident", "  col kind str ?"),
        with("table places world resident", "  col x ref nowhere ?"),
        with("table places world resident", "  col y enum stage ! = nonsense"),
        with("table places world resident", "  metric z f64 !"),
        with("table places world resident", "  index account_id name"),
        with("table places world resident", "  natural region where kind = 'contry'"),
        with("table places world resident", "  natural region where kind like 'c%'"),
        with("table places world resident", "  natural region where atlas_labeled = 'true'"),
        with("table places world resident", "  natural region where population = '5'"),
        with("table places world resident", "  col n u32 ? deferred"),
        with("table places world resident", "  col n u32 ? = 4294967295"),
        format!("{SOURCE}\ntable probe_uncapped lanes server\n  col x str ?\n"),
        with("table places world resident", "  index name global global"),
        with("table places world resident", "  cap -1"),
        with("table places world resident", "  col Bad str ?"),
        with("table places world resident", "  col flag bool ? = maybe"),
        with("table places world resident", "  col n u8 ? = 300"),
        with("table places world resident", "  command poke n:text??"),
        with("table places world resident", "  command poke human_only human_only"),
        SOURCE.replacen("frame HELLO 1", "frame HELLO 300", 1),
        SOURCE.replacen("frame WELCOME 2", "frame WELCOME 1", 1),
        SOURCE.replacen("domain world desk", "domain world world desk", 1),
        SOURCE.replacen("enum verb put drop command", "enum verb put drop put", 1),
        SOURCE.replacen("\nlayout ", "\n# layout ", 1),
    ];
    for (i, source) in cases.iter().enumerate() {
        assert!(parse(source).is_err(), "accepted case {i}");
    }

    let err = parse(&with("table places world resident", "  col nope widget ?")).unwrap_err();
    let line = SOURCE[..SOURCE.find("table places world resident").unwrap()].matches('\n').count() + 2;
    assert_eq!(err.line, line);
}

#[test]
fn a_server_enum_inserted_anywhere_leaves_the_wire_alone() {
    let base = parse(SOURCE).unwrap();
    let inserted = parse(&SOURCE.replacen("enum place_kind", "enum probe_kind a b\nenum place_kind", 1)).unwrap();
    assert_eq!(inserted.wire_hash, base.wire_hash);
    assert_ne!(inserted.schema_rev, base.schema_rev);
}

#[test]
fn the_compiled_constants_are_the_parsed_declaration() {
    let s = parse(SOURCE).unwrap();
    assert_eq!(schema::WIRE_HASH, s.wire_hash);
    assert_eq!(schema::SCHEMA_REV, s.schema_rev);
    assert_eq!(schema::LAYOUT, s.layout);
    for t in &s.tables {
        let def = schema::table_def(t.id).unwrap();
        assert_eq!(def.name, t.name);
        let ids: Vec<(u16, &str)> = def.cols.iter().map(|c| (c.id, c.name)).collect();
        let want: Vec<(u16, &str)> = t.cols.iter().map(|c| (c.id, c.name.as_str())).collect();
        assert_eq!(ids, want, "{}", t.name);
    }
}

#[test]
fn a_frozen_database_whose_foreign_keys_disagree_with_the_declaration_needs_a_rebuild() {
    use schema::sql::{Shape, additive};
    let s = parse(SOURCE).unwrap();
    // A table's every column as the database names them, so only the
    // foreign keys differ.
    let cols = |t: &str| -> String {
        s.table(t).unwrap().cols.iter().map(|c| format!("col {t} {} X 0 -\n", c.name)).collect()
    };

    // audit.key_id is loose: a foreign key the database still holds is the hand's to remove.
    let held = Shape::read(&format!("{}fk audit key_id SET NULL\n", cols("audit"))).unwrap();
    let diff = additive(&s, &held).unwrap();
    assert!(diff.extra.iter().any(|x| x.contains("audit.key_id has a foreign key")), "{:?}", diff.extra);

    // applications.corporation_id is a ref: an existing column without its foreign key needs a rebuild.
    let missing = Shape::read(&cols("applications")).unwrap();
    let diff = additive(&s, &missing).unwrap();
    assert!(diff.extra.iter().any(|x| x.contains("applications.corporation_id has no foreign key")), "{:?}", diff.extra);
}

#[test]
fn a_table_def_names_its_keys_and_their_wheres() {
    use schema::{Cond, table_def, table};
    let places = table_def(table::PLACES).unwrap();
    let naturals: Vec<_> = places.keys.iter().filter(|k| k.natural).map(|k| (k.cols, &k.cond)).collect();
    assert_eq!(naturals, [(&["iso2"][..], &Some(Cond::Eq("kind", "country"))), (&["geonames_id"][..], &Some(Cond::Eq("kind", "city")))]);
    let sources = table_def(table::SOURCES).unwrap();
    assert!(sources.soft_delete && !sources.singleton && !sources.unmasked);
    assert!(table_def(table::SETTINGS).unwrap().singleton);
}
