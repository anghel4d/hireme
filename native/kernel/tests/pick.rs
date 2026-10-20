//! Which CV root an application gets, through the kernel's facade: the
//! ordered match over the rules, pins, the default, the reads the lens
//! and the MCP draw from, and the judge's rules on CV writes.

use kernel::abi::Kernel;
use kernel::judge::{Ctx, EVal, Row};
use kernel::query::Grants;
use kernel::rows::Val;
use schema::col::applications as A;
use schema::{col, command, enums, param, refusal, table};
use serde_json::{Value as Json, json};

const TODAY: i32 = 739_528;

fn ctx(human: bool) -> Ctx<'static> {
    Ctx { today: TODAY, now: (TODAY - kernel::UNIX_EPOCH_DAY) as i64 * 86_400, human, key_id: (!human).then_some(3), held: &[] }
}

/// Germany (1) with Berlin (2), France (3); Stripe (10) and Acme (11);
/// roots DACH (20, markdown, version 30), Stripe (21, pdf, version 31),
/// Default (22, composed, no version), France (23, markdown, none yet);
/// the dach mask; rules in order: a disabled catch-all, Stripe, dach,
/// France; the default root 22. Applications: Stripe in Berlin (1), Acme
/// in Berlin (2), Acme in France (3), Acme nowhere (4), Acme in Berlin
/// pinned to Stripe by an agent (5), all in an open batch and open_fire.
fn kernel() -> Kernel {
    let mut w = wire::BodyWriter::new();
    let none = wire::NONE;
    let mut b = w.block(table::PLACES, 3);
    b.u32s(col::places::ID, [1, 2, 3].into_iter())
        .u32s(col::places::KIND, [enums::place_kind::COUNTRY, enums::place_kind::CITY, enums::place_kind::COUNTRY].map(u32::from).into_iter())
        .u32s(col::places::COUNTRY_ID, [none, 1, none].into_iter())
        .strs(col::places::ISO2, ["DE", "", "FR"].into_iter())
        .strs(col::places::NAME, ["Germany", "Berlin", "France"].into_iter());
    b.done();
    let mut b = w.block(table::CORPORATIONS, 2);
    b.u32s(col::corporations::ID, [10, 11].into_iter())
        .strs(col::corporations::DOMAIN, ["stripe.com", "acme.com"].into_iter())
        .strs(col::corporations::NAME, ["Stripe", "Acme"].into_iter());
    b.done();
    let fmt = |f: u8| f as u32;
    let mut b = w.block(table::CV_ROOTS, 4);
    b.u32s(col::cv_roots::ID, [20, 21, 22, 23].into_iter())
        .strs(col::cv_roots::SLUG, ["dach", "stripe", "default", "france"].into_iter())
        .strs(col::cv_roots::NAME, ["DACH", "Stripe", "Default", "France"].into_iter())
        .u32s(col::cv_roots::FORMAT, [enums::cv_format::MARKDOWN, enums::cv_format::PDF, enums::cv_format::COMPOSED, enums::cv_format::MARKDOWN].map(fmt).into_iter())
        .u32s(col::cv_roots::VERSION_ID, [30, 31, none, none].into_iter());
    b.done();
    let mut b = w.block(table::CV_VERSIONS, 2);
    b.u32s(col::cv_versions::ID, [30, 31].into_iter())
        .u32s(col::cv_versions::ROOT_ID, [20, 21].into_iter())
        .u32s(col::cv_versions::N, [1, 1].into_iter())
        .strs(col::cv_versions::TEXT, ["# Ana\nRust, inference kernels.", "Payments infrastructure."].into_iter());
    b.done();
    let mut b = w.block(table::CV_MASKS, 1);
    b.u32s(col::cv_masks::ID, [50].into_iter()).strs(col::cv_masks::NAME, ["dach"].into_iter()).strs(col::cv_masks::PATTERN, ["[country in [DE, AT, CH]]"].into_iter());
    b.done();
    let mut b = w.block(table::CV_RULES, 4);
    b.u32s(col::cv_rules::ID, [43, 40, 41, 42].into_iter())
        .u32s(col::cv_rules::POSITION, [0, 1, 2, 3].into_iter())
        .u32s(col::cv_rules::ROOT_ID, [21, 21, 20, 23].into_iter())
        .u32s(col::cv_rules::ENABLED, [0, 1, 1, 1].into_iter())
        .strs(col::cv_rules::PATTERN, ["[country _]", "[company.domain = \"stripe.com\"]", "dach", "country = FR"].into_iter());
    b.done();
    let mut b = w.block(table::ME, 1);
    b.u32s(col::me::ID, [1].into_iter()).u32s(col::me::CV_DEFAULT_ROOT_ID, [22].into_iter()).strs(col::me::CITIZENSHIPS, ["DE"].into_iter());
    b.done();
    let mut b = w.block(table::BATCHES, 1);
    b.u32s(col::batches::ID, [1].into_iter()).u32s(col::batches::FIRE, [enums::fire::OPEN_FIRE as u32].into_iter());
    b.done();
    let mut b = w.block(table::APPLICATIONS, 5);
    b.u32s(A::ID, 1..=5)
        .u32s(A::NO, 1..=5)
        .u32s(A::STAGE, (1..=5).map(|_| enums::stage::OPEN_FIRE as u32))
        .u32s(A::BATCH_ID, (1..=5).map(|_| 1))
        .strs(A::COMPANY, ["Stripe", "Acme", "Acme", "Acme", "Acme"].into_iter())
        .strs(A::ROLE, (1..=5).map(|_| "Research Engineer"))
        .u32s(A::CORPORATION_ID, [10, 11, 11, 11, 11].into_iter())
        .u32s(A::PLACE_ID, [2, 2, 3, none, 2].into_iter())
        .u32s(A::CV_ROOT_ID, [none, none, none, none, 21].into_iter())
        .u32s(A::CV_PINNED_BY, [none, none, none, none, enums::actor::AGENT as u32].into_iter())
        .u32s(A::HEAT_OVERRIDE, (1..=5).map(|_| 0));
    b.done();
    let mut k = Kernel::new();
    k.set_today(TODAY);
    k.set_grants(Grants { human: true, read_mask: 0b1111, write_mask: 0b1111, may_delete: true });
    k.boot(&w.finish(), 1).unwrap();
    k
}

fn q(k: &Kernel, req: Json) -> Json {
    k.query(&req).unwrap_or_else(|r| panic!("{req}: {r:?}"))
}

fn picks(k: &Kernel) -> Vec<Json> {
    q(k, json!({"op": "cv_picks"}))["picks"].as_array().unwrap().clone()
}

fn op(verb: u8, table: u16, target: u32, cells: impl FnOnce(&mut wire::OpWriter)) -> Vec<u8> {
    let mut w = wire::OpsWriter::new();
    let mut o = w.op(77, verb, 0, table, target, None);
    cells(&mut o);
    o.done();
    w.finish()[8..].to_vec()
}

fn pick_cv(app: u32, root: u32) -> Vec<u8> {
    op(wire::COMMAND, command::PICK_CV, app, |o| {
        o.u32(param::pick_cv::CV_ROOT_ID, root);
    })
}

fn refusal_of(r: Result<Vec<Row>, kernel::judge::Refusal>) -> kernel::judge::Refusal {
    r.expect_err("expected a refusal")
}

#[test]
fn the_first_enabled_arm_wins_a_pin_wins_over_it_and_the_default_takes_the_rest() {
    let k = kernel();
    let p = picks(&k);
    let row = |i: usize| (&p[i]["state"], &p[i]["root"], &p[i]["arm"], &p[i]["also"], &p[i]["version_id"], &p[i]["by"]);
    // Stripe in Berlin: the Stripe arm comes before dach, which also matches.
    assert_eq!(row(0), (&json!("matched"), &json!(21), &json!(40), &json!([41]), &json!(31), &json!(null)));
    assert_eq!(row(1), (&json!("matched"), &json!(20), &json!(41), &json!([]), &json!(30), &json!(null)));
    // France's root has nothing to send yet.
    assert_eq!(row(2), (&json!("empty"), &json!(23), &json!(42), &json!([]), &json!(null), &json!(null)));
    // No arm: the default, a composition, needs no version.
    assert_eq!(row(3), (&json!("default"), &json!(22), &json!(null), &json!([]), &json!(null), &json!(null)));
    assert_eq!(row(4), (&json!("pinned"), &json!(21), &json!(null), &json!([41]), &json!(31), &json!("agent")));

    assert_eq!(q(&k, json!({"op": "cv_picks", "where": {"state": "matched"}}))["picks"].as_array().unwrap().len(), 2);
    assert_eq!(q(&k, json!({"op": "cv_pick", "application": 2}))["root"], 20);
    assert_eq!(k.query(&json!({"op": "cv_pick", "application": 99})).unwrap_err().code, refusal::NOT_FOUND);
}

#[test]
fn a_pin_by_the_operator_or_an_agent_moves_the_pick_and_unpinning_gives_it_back() {
    let mut k = kernel();
    k.predict(&pick_cv(2, 23), &ctx(true)).unwrap();
    let p = q(&k, json!({"op": "cv_pick", "application": 2}));
    assert_eq!((&p["state"], &p["root"], &p["by"]), (&json!("empty"), &json!(23), &json!("operator")));

    k.predict(&op(wire::COMMAND, command::UNPIN_CV, 2, |_| {}), &ctx(false)).unwrap();
    assert_eq!(q(&k, json!({"op": "cv_pick", "application": 2}))["state"], "matched");

    assert_eq!(refusal_of(k.judge(&pick_cv(2, 99), &ctx(false))).code, refusal::NOT_FOUND);
    let fx = k.judge(&pick_cv(2, 21), &ctx(false)).unwrap();
    assert!(fx.iter().any(|r| r.table == table::EVENTS), "a pin is on the application's trail");
}

#[test]
fn a_dropped_root_turns_its_pin_stale() {
    let mut k = kernel();
    let mut w = wire::BodyWriter::new();
    w.gone(table::CV_ROOTS, &[21]);
    k.patch(&w.finish(), 2).unwrap();
    let p = picks(&k);
    assert_eq!((&p[4]["state"], &p[4]["root"]), (&json!("stale"), &json!(21)));
    // Its arm is gone with it: Stripe falls through to dach.
    assert_eq!((&p[0]["arm"], &p[0]["root"]), (&json!(41), &json!(20)));
}

#[test]
fn going_out_freezes_the_version_the_pick_sends() {
    let mut k = kernel();
    let out = |k: &mut Kernel, app: u32| {
        let fx = k.judge(&op(wire::COMMAND, command::STAGE, app, |o| {
            o.u32(param::stage::STAGE, enums::stage::SUBMITTED as u32);
        }), &ctx(true));
        fx.unwrap().into_iter().find(|r| r.table == table::APPLICATIONS).and_then(|r| r.cells.into_iter().find(|c| c.0 == A::CV_VERSION_ID)).map(|c| c.1)
    };
    assert_eq!(out(&mut k, 1), Some(EVal::Val(Val::U32(31))));
    assert_eq!(out(&mut k, 4), Some(EVal::Val(Val::None)));
}

#[test]
fn a_rule_or_mask_that_does_not_compile_is_refused_where_it_breaks() {
    let mut k = kernel();
    let put_rule = |text: &str| {
        let text = text.to_string();
        op(wire::PUT, table::CV_RULES, 40, move |o| {
            o.str(col::cv_rules::PATTERN, &text);
        })
    };
    let r = refusal_of(k.judge(&put_rule("country = :de"), &ctx(true)));
    assert_eq!((r.code, &r.data["at"], &r.data["rule"]), (refusal::RULE, &json!(10), &json!(40)));
    assert!(k.judge(&put_rule("dach & company.size = :mega"), &ctx(true)).is_ok());

    // Renaming dach breaks the rule that names it; dropping it too.
    let rename = op(wire::PUT, table::CV_MASKS, 50, |o| {
        o.str(col::cv_masks::NAME, "dacha");
    });
    let r = refusal_of(k.judge(&rename, &ctx(true)));
    assert_eq!((r.code, &r.data["rule"]), (refusal::RULE, &json!(41)));
    let r = refusal_of(k.judge(&op(wire::DROP, table::CV_MASKS, 50, |_| {}), &ctx(true)));
    assert_eq!((r.code, &r.data["rule"]), (refusal::RULE, &json!(41)));
    for bad in ["country", "Dach", "in"] {
        let named = op(wire::PUT, table::CV_MASKS, 0, |o| {
            o.str(col::cv_masks::NAME, bad).str(col::cv_masks::PATTERN, "country = DE");
        });
        assert_eq!(refusal_of(k.judge(&named, &ctx(true))).code, refusal::RULE, "{bad}");
    }
    // A mask naming itself through another is a cycle.
    let cycle = op(wire::PUT, table::CV_MASKS, 50, |o| {
        o.str(col::cv_masks::PATTERN, "dach | country = FR");
    });
    assert!(refusal_of(k.judge(&cycle, &ctx(true))).data["error"].as_str().unwrap().contains("names itself"));
}

#[test]
fn a_version_carries_what_its_root_format_takes_and_becomes_the_root_head() {
    let mut k = kernel();
    let version = |root: u32, body: Option<&'static str>, blob: Option<&'static str>| {
        op(wire::PUT, table::CV_VERSIONS, 0, move |o| {
            o.u32(col::cv_versions::ROOT_ID, root);
            if let Some(b) = body {
                o.str(col::cv_versions::BODY, b);
            }
            if let Some(s) = blob {
                o.str(col::cv_versions::BLOB_SHA, s);
            }
        })
    };
    assert_eq!(refusal_of(k.judge(&version(23, None, Some("ab12")), &ctx(true))).code, refusal::TYPE);
    assert_eq!(refusal_of(k.judge(&version(21, Some("# CV"), None), &ctx(true))).code, refusal::TYPE);
    assert_eq!(refusal_of(k.judge(&version(99, Some("# CV"), None), &ctx(true))).code, refusal::NOT_FOUND);
    let fx = k.judge(&version(23, Some("# Ana\nRust, kernels"), None), &ctx(true)).unwrap();
    let head = fx.iter().find(|r| r.table == table::CV_ROOTS).expect("the root moves");
    assert_eq!((head.id, &head.cells), (23, &vec![(col::cv_roots::VERSION_ID, EVal::New(0))]));

    k.predict(&version(23, Some("# Ana"), None), &ctx(true)).unwrap();
    assert_eq!(q(&k, json!({"op": "cv_pick", "application": 3}))["state"], "matched");
}

#[test]
fn a_rule_text_is_checked_explained_and_its_fields_listed() {
    let k = kernel();
    let check = |text: &str, at: Option<usize>| q(&k, json!({"op": "mask_check", "text": text, "position": at}));
    // Every application in Germany is already taken by Stripe's arm or dach's.
    let c = check("country = DE", None);
    assert_eq!((&c["ok"], &c["shadowed"], &c["never_matches"]), (&json!(true), &json!([40, 41]), &json!(false)));
    assert_eq!(check("country = DE", Some(0))["shadowed"], json!([]));
    assert_eq!(check("country = JP", None)["never_matches"], true);
    // "Research Engineer" names no level: mid.
    assert_eq!(check("seniority = :mid", Some(0))["never_matches"], false);
    assert_eq!(check("seniority >= :senior", None)["never_matches"], true);
    let bad = check("country = ", None);
    assert_eq!((&bad["ok"], &bad["error"]["pos"]), (&json!(false), &json!(10)));

    let why = q(&k, json!({"op": "cv_explain", "application": 3}));
    let arm40 = why.as_array().unwrap().iter().find(|a| a["arm"] == 40).unwrap();
    assert_eq!((&arm40["matched"], &arm40["failed"]["read"]), (&json!(false), &json!("\"acme.com\"")));
    assert_eq!(why.as_array().unwrap().iter().find(|a| a["arm"] == 42).unwrap()["matched"], true);

    let fields = q(&k, json!({"op": "mask_fields"}))["fields"].as_array().unwrap().len();
    assert_eq!(fields, kernel::mask::FIELDS.len());
}

#[test]
fn a_key_without_the_cv_tables_in_its_mask_reads_no_picks() {
    let mut k = kernel();
    k.set_grants(Grants { human: false, read_mask: 0, write_mask: 0, may_delete: false });
    assert_eq!(k.query(&json!({"op": "cv_picks"})).unwrap_err().code, refusal::SCOPE);
}

#[test]
fn the_application_shows_the_picked_file_version_and_reads_its_words() {
    let mut k = kernel();
    let doc = k.application(2).unwrap();
    let file = &doc["cv"]["file"];
    assert_eq!((&file["format"], &file["version_id"], &file["n"]), (&json!("markdown"), &json!(30), &json!(1)));
    assert_eq!(file["text"], "# Ana\nRust, inference kernels.");
    assert_eq!(doc["cv_pick"]["root"], 20);
    // Pinned elsewhere, it shows that root's version instead.
    k.predict(&pick_cv(2, 21), &ctx(true)).unwrap();
    assert_eq!(k.application(2).unwrap()["cv"]["file"]["text"], "Payments infrastructure.");
    // The default, a composition, has no file.
    assert_eq!(k.application(4).unwrap()["cv"]["file"], Json::Null);
}
