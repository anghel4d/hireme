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
    // columns after it, and the resident atlas projection picks those ids.
    let server = parse(&with("  prose liveability\n  prose notes", "  metric probe_metric u32")).unwrap();
    assert_eq!(server.wire_hash, base.wire_hash);
    assert_ne!(server.schema_rev, base.schema_rev);
    assert!(server.table("places").unwrap().col("probe_metric_on").is_some());

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
        with("table places world server", "  col nope widget ?"),
        with("table places world server", "  pick name"),
        with("pick kind", "  col oops str ?"),
        with("table places world server", "  col kind str ?"),
        with("table places world server", "  col x ref nowhere ?"),
        with("table places world server", "  col y enum stage ! = nonsense"),
        with("table places world server", "  metric z f64 !"),
        SOURCE.replacen("\nlayout ", "\n# layout ", 1),
    ];
    for (i, source) in cases.iter().enumerate() {
        assert!(parse(source).is_err(), "accepted case {i}");
    }

    let err = parse(&with("table places world server", "  col nope widget ?")).unwrap_err();
    let line = SOURCE[..SOURCE.find("table places world server").unwrap()].matches('\n').count() + 2;
    assert_eq!(err.line, line);
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
