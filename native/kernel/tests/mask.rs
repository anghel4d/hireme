// The CV mask language through its public face: compile a text, match
// an application's facts, explain a miss, refuse a bad text where it is bad.

use std::borrow::Cow;
use std::collections::HashMap;

use kernel::mask::{self, Facts, Val};

struct App(HashMap<usize, Val<'static>>);

impl Facts for App {
    fn read(&self, field: usize) -> Option<Val<'_>> {
        self.0.get(&field).cloned()
    }
}

fn app(cells: &[(&str, Val<'static>)]) -> App {
    App(cells.iter().map(|(p, v)| (mask::field(p).unwrap_or_else(|| panic!("no field {p}")), v.clone())).collect())
}

fn code(c: &'static str) -> Val<'static> {
    Val::Code(Cow::Borrowed(c))
}

fn text(t: &'static str) -> Val<'static> {
    Val::Text(Cow::Borrowed(t))
}

fn enum_of(e: &str, v: &str) -> Val<'static> {
    Val::Enum(mask::values(e).iter().position(|x| *x == v).unwrap_or_else(|| panic!("{e} has no {v}")) as u32)
}

fn no_masks(_: &str) -> Option<&'static str> {
    None
}

fn holds(src: &str, facts: &App) -> bool {
    mask::compile(src, &no_masks).unwrap_or_else(|e| panic!("{src}: {e:?}")).matches(facts)
}

fn refused(src: &str) -> mask::Error {
    mask::compile(src, &no_masks).expect_err(src)
}

#[test]
fn a_desk_rule_reads_the_place_the_company_the_role_and_me() {
    let a = app(&[
        ("country", code("AT")),
        ("company.domain", text("Stripe.com")),
        ("company.size", enum_of("size", "large")),
        ("field", enum_of("department", "research")),
        ("work_mode", enum_of("work_mode", "remote")),
        ("stage", enum_of("stage", "gated")),
        ("role", text("Senior Research Engineer, Inference")),
        ("keywords", Val::List(vec![text("rust"), text("gpu kernels")])),
        ("me.citizenships", Val::List(vec![code("DE"), code("AT")])),
        ("me.work_modes", Val::List(vec![enum_of("work_mode", "remote")])),
        ("score", Val::Num(71.0)),
    ]);
    for yes in [
        "[country in [DE, AT, CH]] & field = :research & !(company.size = :mega)",
        "[company.domain = \"stripe.com\"]",
        "[country _] & country in me.citizenships & work_mode in me.work_modes",
        "stage < :submitted & score >= 70",
        "role ~ \"research engineer\" & keywords ~ \"gpu kernels\" & role ^= \"senior\"",
        "me.citizenships ~ AT | country = FR",
        "[!city] & !(city = \"Wien\")",
    ] {
        assert!(holds(yes, &a), "{yes}");
    }
    for no in ["country = DE", "role ~ \"search\"", "city != \"Wien\"", "[country _, !country]", "keywords ~ \"gpu\" & field = :data"] {
        assert!(!holds(no, &a), "{no}");
    }
}

#[test]
fn and_or_not_keep_their_laws_over_any_facts() {
    // Seeded: every subset of three facts, every pair of atoms.
    let atoms = ["country = DE", "field = :infra", "me.relocate", "[city _]", "score > 50"];
    let cells: Vec<(&str, Val<'static>)> = vec![
        ("country", code("DE")),
        ("field", enum_of("department", "infra")),
        ("me.relocate", Val::Bool(true)),
        ("city", text("Berlin")),
        ("score", Val::Num(60.0)),
    ];
    for mask_bits in 0u32..32 {
        let a = app(&cells.iter().enumerate().filter(|(i, _)| mask_bits & (1 << i) != 0).map(|(_, c)| c.clone()).collect::<Vec<_>>());
        for x in atoms {
            for y in atoms {
                let (p, q) = (holds(x, &a), holds(y, &a));
                assert_eq!(holds(&format!("({x}) & ({y})"), &a), p && q, "{x} & {y} on {mask_bits:05b}");
                assert_eq!(holds(&format!("({x}) | ({y})"), &a), p || q, "{x} | {y} on {mask_bits:05b}");
                assert_eq!(holds(&format!("!({x})"), &a), !p, "!{x} on {mask_bits:05b}");
                assert_eq!(holds(&format!("[{x}, {y}]"), &a), p && q, "[{x}, {y}] on {mask_bits:05b}");
            }
        }
    }
}

#[test]
fn a_miss_names_the_test_that_failed_and_the_value_it_read() {
    let a = app(&[("country", code("FR")), ("company.size", enum_of("size", "mega"))]);
    let src = "[country _] & country in [DE, AT] & !(company.size = :mega)";
    let fail = mask::compile(src, &no_masks).unwrap().explain(&a).expect("misses");
    assert_eq!(&src[fail.span.at as usize..][..fail.span.len as usize], "country in [DE, AT]");
    assert_eq!(fail.read, "FR");

    let fail = mask::compile("city = \"Paris\"", &no_masks).unwrap().explain(&a).unwrap();
    assert_eq!(fail.read, "absent");
    assert!(mask::compile("country = FR", &no_masks).unwrap().explain(&a).is_none());
}

#[test]
fn a_named_mask_is_inlined_and_a_miss_inside_it_points_at_its_name() {
    let masks = |n: &str| match n {
        "dach" => Some("[country in [DE, AT, CH]]"),
        "eu_research" => Some("dach & field = :research"),
        "loop_a" => Some("loop_b"),
        "loop_b" => Some("loop_a"),
        "broken" => Some("country = :de"),
        _ => None,
    };
    let a = app(&[("country", code("CH")), ("field", enum_of("department", "infra"))]);
    let e = mask::compile("eu_research | company.size = :small", &masks).unwrap();
    let fail = e.explain(&a).unwrap();
    assert_eq!((fail.span.at, fail.span.len), (0, 11));
    assert!(mask::compile("dach", &masks).unwrap().matches(&a));

    let cycle = mask::compile("loop_a", &masks).unwrap_err();
    assert!(cycle.msg.contains("names itself"), "{}", cycle.msg);
    let inner = mask::compile("country = CH & broken", &masks).unwrap_err();
    assert_eq!((inner.span.at, inner.span.len), (15, 6));
    assert!(inner.msg.starts_with("mask broken:"), "{}", inner.msg);
}

#[test]
fn a_bad_text_is_refused_where_it_is_bad() {
    for (src, at, says) in [
        ("", 0, "empty"),
        ("country = :de", 10, "not an enum"),
        ("work_mode = :sometimes", 12, "not a work_mode"),
        ("countrey = DE", 0, "neither a field nor a mask"),
        ("score > \"high\"", 6, "holds num"),
        ("me.citizenships = DE", 16, "list field"),
        ("country in DE", 11, "in takes a list"),
        ("country = DEU-X-1", 10, "ISO code"),
        ("[country _, field", 17, "expected , or ]"),
        ("(country = DE", 13, "expected )"),
        ("country = DE country", 13, "& or |"),
        ("city = \"Wien", 7, "not closed"),
        ("country = DE & $", 15, "no meaning"),
        ("company ^= 12", 8, "holds text"),
        ("company.size < company", 13, "cannot be compared"),
    ] {
        let e = refused(src);
        assert_eq!(e.span.at, at, "{src}: {e:?}");
        assert!(e.msg.contains(says), "{src}: {}", e.msg);
    }
}

#[test]
fn the_catalog_lists_every_field_with_its_type_and_values() {
    let fields: Vec<serde_json::Value> = serde_json::from_str(mask::catalog()).unwrap();
    assert_eq!(fields.len(), mask::FIELDS.len());
    let wm = fields.iter().find(|f| f["path"] == "me.work_modes").unwrap();
    assert_eq!(wm["type"], "list");
    assert_eq!(wm["list_of"], "enum");
    assert_eq!(wm["values"], serde_json::json!(["onsite", "hybrid", "remote"]));
    // Every field compiles as a presence test: no catalog entry the parser refuses.
    for f in mask::FIELDS {
        mask::compile(&format!("[{} _]", f.path), &no_masks).unwrap_or_else(|e| panic!("{}: {e:?}", f.path));
    }
}
