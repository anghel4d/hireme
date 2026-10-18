//! The one judge of a write on a replicated table, as the sequencer judges
//! it: provenance, natural keys, shape, uniques and drops from the replica.

use kernel::abi::Kernel;
use kernel::judge::{Ctx, EVal, Refusal, Row};
use kernel::rows::Val;
use schema::col::{citations as C, corporations as K, sources as S};
use schema::{refusal, table};

const TODAY: i32 = 739_528;
const D0: u32 = 739_000;

fn kernel() -> Kernel {
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::CORPORATIONS, 1);
    b.u32s(K::ID, [1].into_iter())
        .i64s(K::REV, [2].into_iter())
        .strs(K::DOMAIN, ["acme.com"].into_iter())
        .strs(K::NAME, ["Acme"].into_iter())
        .u32s(K::HEADCOUNT, [100].into_iter())
        .u32s(K::HEADCOUNT_ON, [D0].into_iter());
    b.done();
    let mut b = w.block(table::SOURCES, 2);
    b.u32s(S::ID, [1, 2].into_iter())
        .strs(S::URL, ["https://www.levels.fyi/acme", "https://blog.example/a"].into_iter())
        .strs(S::HOST, ["www.levels.fyi", "blog.example"].into_iter());
    b.done();
    let mut b = w.block(table::TRUSTED, 1);
    b.u32s(schema::col::trusted::ID, [1].into_iter()).strs(schema::col::trusted::HOST, ["levels.fyi"].into_iter());
    b.done();
    let mut b = w.block(table::CITATIONS, 1);
    b.u32s(C::ID, [1].into_iter())
        .strs(C::TABLE, ["corporations"].into_iter())
        .u32s(C::ROW_ID, [1].into_iter())
        .strs(C::COLUMN, ["headcount"].into_iter())
        .u32s(C::SOURCE_ID, [1].into_iter())
        .u32s(C::AS_OF, [D0].into_iter());
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn ctx(human: bool) -> Ctx<'static> {
    Ctx { today: TODAY, now: 1_792_000_000, human, key_id: (!human).then_some(3), held: &[] }
}

fn put(flags: u8, target: u32, rev: Option<u32>, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(77, wire::PUT, flags, table::CORPORATIONS, target, rev);
    cells(&mut o);
    o.done();
    w.finish()[8..].to_vec()
}

fn judge(k: &mut Kernel, op: &[u8]) -> Result<Vec<Row>, Refusal> {
    k.judge(op, &ctx(false))
}

fn refused(k: &mut Kernel, op: &[u8]) -> (u16, serde_json::Value) {
    let r = judge(k, op).expect_err("expected a refusal");
    (r.code, r.data)
}

fn cell(rows: &[Row], t: u16, col: u16) -> Option<&EVal> {
    rows.iter().find(|r| r.table == t)?.cells.iter().find(|c| c.0 == col).map(|c| &c.1)
}

#[test]
fn a_metric_needs_its_date_and_cites_what_changes() {
    let mut k = kernel();
    let headcount = |n: u32, on: Option<u32>, src: Option<u32>| {
        put(0, 1, None, move |o| {
            o.u32(K::HEADCOUNT, n);
            if let Some(d) = on {
                o.u32(schema::AS_OF, d);
            }
            if let Some(s) = src {
                o.u32(schema::SOURCE_CELL, s);
            }
        })
    };
    assert_eq!(refused(&mut k, &headcount(120, None, Some(1))).0, refusal::FRESHNESS);
    let (code, data) = refused(&mut k, &headcount(120, Some(D0 - 1), Some(1)));
    assert_eq!((code, data["on"].as_str()), (refusal::STALE, Some("2023-04-25")));
    assert_eq!(refused(&mut k, &headcount(120, Some(TODAY as u32 + 2), Some(1))).0, refusal::FRESHNESS);
    // The same value, date and source again writes nothing.
    assert_eq!(judge(&mut k, &headcount(100, Some(D0), Some(1))).unwrap(), Vec::new());
    // The same value from another source corroborates: cited.
    let fx = judge(&mut k, &headcount(100, Some(D0), Some(2))).unwrap();
    assert_eq!(cell(&fx, table::CITATIONS, C::SOURCE_ID), Some(&EVal::Val(Val::U32(2))));
    // A new figure from a new URL: the source first, its host derived, then
    // the row with its date moved, then the citation naming both.
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(78, wire::PUT, 0, table::CORPORATIONS, 1, None);
    o.u32(K::HEADCOUNT, 140).u32(schema::AS_OF, D0 + 30).str(schema::SOURCE_CELL, "https://Careers.Acme.com./jobs");
    o.done();
    let fx = judge(&mut k, &w.finish()[8..]).unwrap();
    assert_eq!((fx[0].table, fx[0].id), (table::SOURCES, 0));
    assert_eq!(cell(&fx, table::SOURCES, S::HOST), Some(&EVal::Val(Val::Str("careers.acme.com".into()))));
    assert_eq!(cell(&fx, table::CORPORATIONS, K::HEADCOUNT_ON), Some(&EVal::Val(Val::U32(D0 + 30))));
    assert_eq!(cell(&fx, table::CITATIONS, C::SOURCE_ID), Some(&EVal::New(0)));
    assert_eq!(cell(&fx, table::CITATIONS, C::ROW_ID), Some(&EVal::Val(Val::U32(1))));
}

#[test]
fn ratings_need_a_trusted_host_and_prose_its_rev_and_source() {
    let mut k = kernel();
    let rating = |src: u32| put(0, 1, None, move |o| { o.f64(K::RATING, 4.2).u32(schema::AS_OF, D0).u32(schema::SOURCE_CELL, src); });
    assert_eq!(refused(&mut k, &rating(2)).0, refusal::SOURCE_TRUST);
    // A subdomain of a trusted host is trusted.
    assert!(judge(&mut k, &rating(1)).is_ok());
    let culture = |rev: Option<u32>, src: Option<u32>| {
        put(0, 1, rev, move |o| {
            o.str(K::CULTURE, "Writes everything down.");
            if let Some(s) = src {
                o.u32(schema::SOURCE_CELL, s);
            }
        })
    };
    assert_eq!(refused(&mut k, &culture(None, Some(1))).0, refusal::REV);
    assert_eq!(refused(&mut k, &culture(Some(1), Some(1))).0, refusal::REV);
    assert_eq!(refused(&mut k, &culture(Some(2), None)).0, refusal::SOURCE_MISSING);
    assert!(judge(&mut k, &culture(Some(2), Some(1))).is_ok());
}

#[test]
fn keys_shape_uniques_and_drops_are_the_sequencers() {
    let mut k = kernel();
    // A keyed put lands on the row its natural key names, or inserts.
    let keyed = |flags: u8, domain: &'static str| put(wire::KEYED | flags, 0, None, move |o| { o.str(K::DOMAIN, domain).str(K::NAME, "Acme Inc"); });
    assert_eq!(judge(&mut k, &keyed(0, "acme.com")).unwrap().last().map(|r| r.id), Some(1));
    assert_eq!(judge(&mut k, &keyed(0, "new.example")).unwrap().last().map(|r| r.id), Some(0));
    assert_eq!(refused(&mut k, &keyed(wire::CREATE_ONLY, "acme.com")).0, refusal::NATURAL_KEY);
    // The same domain unkeyed is a unique clash.
    assert_eq!(refused(&mut k, &put(0, 0, None, |o| { o.str(K::DOMAIN, "acme.com").str(K::NAME, "Dup"); })).0, refusal::NATURAL_KEY);
    // Shape: required columns, types, refs, readonly twins.
    let (code, data) = refused(&mut k, &put(0, 0, None, |o| { o.str(K::DOMAIN, "x.example"); }));
    assert_eq!((code, data["missing"][0].as_str()), (refusal::COLUMN, Some("name")));
    assert_eq!(refused(&mut k, &put(0, 1, None, |o| { o.str(K::HEADCOUNT, "many"); })).0, refusal::TYPE);
    assert_eq!(refused(&mut k, &put(0, 1, None, |o| { o.u32(K::HQ_PLACE_ID, 999); })).0, refusal::NOT_FOUND);
    assert_eq!(refused(&mut k, &put(0, 1, None, |o| { o.u32(K::HEADCOUNT_ON, D0); })).0, refusal::COLUMN);
    assert_eq!(refused(&mut k, &put(0, 9, None, |o| { o.str(K::NAME, "Ghost"); })).0, refusal::NOT_FOUND);
    // A cited source outlives a key's drop, not the operator's; a stale rev
    // and an append-only table refuse a drop.
    let drop = |t: u16, id: u32, rev: Option<u32>| {
        let mut w = wire::OpsWriter::new();
        w.op(79, wire::DROP, 0, t, id, rev).done();
        w.finish()[8..].to_vec()
    };
    assert_eq!(refused(&mut k, &drop(table::SOURCES, 1, None)).0, refusal::SCOPE);
    assert!(k.judge(&drop(table::SOURCES, 1, None), &ctx(true)).is_ok());
    assert_eq!(refused(&mut k, &drop(table::CORPORATIONS, 1, Some(1))).0, refusal::REV);
    assert_eq!(refused(&mut k, &drop(table::CITATIONS, 1, None)).0, refusal::COLUMN);
    // Citations are the server's to write.
    let mut w = wire::OpsWriter::new();
    w.op(80, wire::PUT, 0, table::CITATIONS, 0, None).done();
    let (code, data) = refused(&mut k, &w.finish()[8..]);
    assert_eq!((code, data["reason"].as_str()), (refusal::COLUMN, Some("the server writes this table")));
}

/// A table at its cap refuses an insert, never a restatement (which
/// writes nothing): the citations a write adds count the same way.
#[test]
fn a_cap_refuses_inserts_not_restatements() {
    let cap = schema::table_def(table::CORPORATIONS).and_then(|t| t.cap).unwrap();
    let mut w = wire::BodyWriter::new();
    let mut b = w.block(table::CORPORATIONS, cap as usize);
    let domains: Vec<String> = (1..=cap).map(|i| format!("c{i}.example")).collect();
    b.u32s(K::ID, 1..=cap).strs(K::DOMAIN, domains.iter().map(String::as_str)).strs(K::NAME, (1..=cap).map(|_| "C"));
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.boot(&w.finish(), 1).unwrap();
    let (code, data) = refused(&mut k, &put(0, 0, None, |o| { o.str(K::DOMAIN, "one-more.example").str(K::NAME, "C"); }));
    assert_eq!((code, data["cap"].as_u64()), (refusal::CAP, Some(cap as u64)));
    assert_eq!(judge(&mut k, &put(0, 7, None, |o| { o.str(K::NAME, "C"); })).unwrap(), Vec::new());
}

#[test]
fn a_source_host_is_what_a_browser_opens() {
    use kernel::write::host;
    assert_eq!(host("https://WWW.Levels.FYI./x?y#z").as_deref(), Some("www.levels.fyi"));
    assert_eq!(host("http://a.example:080/").as_deref(), Some("a.example"));
    assert_eq!(host("HTTPS://ABC.com.:443/p").as_deref(), Some("abc.com"));
    for bad in ["https://evil.example\\@levels.fyi/", "https://u@levels.fyi/", "ftp://a.example/", "https://127.0.0.1/", "https://0x7f.1/", "https://a.example:99999/", "https://a b.example/", "https://localhost/", "https://-a.example/"] {
        assert_eq!(host(bad), None, "{bad}");
    }
}
