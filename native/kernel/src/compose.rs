//! The documents the focus lens and the MCP read, as JSON: one
//! application with everything derived about it, the desk overview and
//! the atlas. A document is a pure function of the resident
//! rows and `today`; the browser and `hireme-mcp` render the same one.
//!
//! Text the operator or an agent wrote is returned as written, whole;
//! marking it untrusted is the MCP's job at its edge.

use alloc::string::String;
use alloc::vec::Vec;

use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::{json, Value as Json};

use crate::atlas::{self, Me, Place};
use crate::board::{self, Board};
use crate::cv::{self, Item, Overlay, Theme};
use crate::pipeline::{self, Stage, STAGES};
use crate::rows::{Rows, Table};
use crate::{keywords, Day};

fn enum_name(names: &[&'static str], v: Option<u32>) -> Json {
    v.and_then(|v| names.get(v as usize)).map_or(Json::Null, |n| Json::String((*n).into()))
}

/// Every column of a row but the private and server-only ones, as a
/// read of the replica shows it (`query`).
pub fn row(t: &Table, id: u32) -> Json {
    let Some(tm) = schema::table_def(t.id) else { return Json::Null };
    let cols: Vec<_> = tm.cols.iter().filter(|c| c.flags & (schema::flag::SERVER_ONLY | schema::flag::PRIVATE) == 0).collect();
    crate::query::row_out(t, id, &cols, false)
}

/// The lineage telling a corporation's story: the `cv_lineages` row naming it.
fn lineage_of(rows: &Rows, corporation: Option<u32>) -> Option<(&Table, u32)> {
    let c = corporation?;
    let lt = rows.table(table::CV_LINEAGES)?;
    lt.ids().iter().copied().find(|&l| lt.u32(l, col::cv_lineages::CORPORATION_ID) == Some(c)).map(|l| (lt, l))
}

/// One application: its row, card, rail, heat, suggestion, coverage, CV,
/// events, batch and lineage. `cv` is its `cv_part`, which the caller may
/// keep across writes that leave what it reads alone.
pub fn application(rows: &Rows, board: &Board, id: u32, today: Day, cv: (Json, Json)) -> Option<Json> {
    let t = rows.table(table::APPLICATIONS)?;
    if !t.has(id) {
        return None;
    }
    let stage = t.u32(id, A::STAGE).and_then(Stage::from_u32).unwrap_or(Stage::Discovered);
    let rail = board::rail(t, id).unwrap_or_else(|| pipeline::initial(stage));
    let rail: Vec<Json> = STAGES
        .iter()
        .map(|s| json!({"stage": s.name(), "label": s.label(), "hint": s.hint(), "pip": rail[s.index()].name(), "fire_locked": s.fire_locked()}))
        .collect();

    let mut event_ids: Vec<u32> = rows.each(table::EVENTS).filter(|(e, x)| e.u32(*x, col::events::APPLICATION_ID) == Some(id)).map(|(_, x)| x).collect();
    event_ids.sort_unstable_by(|a, b| b.cmp(a));
    let events: Vec<Json> = rows.table(table::EVENTS).map(|e| event_ids.iter().map(|&x| row(e, x)).collect()).unwrap_or_default();

    let batch = t.u32(id, A::BATCH_ID).and_then(|b| rows.table(table::BATCHES).filter(|bt| bt.has(b)).map(|bt| row(bt, b)));
    let lineage = lineage_of(rows, t.u32(id, A::CORPORATION_ID)).map(|(lt, l)| {
        let opened = lt.u32(l, col::cv_lineages::OPENED_ON).unwrap_or(0) as Day;
        let rewrites = lt.u32(l, col::cv_lineages::REWRITES_ALLOWED) == Some(1);
        let phase = match cv::phase(opened, rewrites, today) {
            cv::Phase::Tailor => "tailor",
            cv::Phase::Additive => "additive",
            cv::Phase::Ready => "ready",
        };
        let mut j = row(lt, l);
        j["phase"] = phase.into();
        j["days_to_open"] = cv::days_to_open(opened, today).into();
        j
    });

    let card = board.card(id).zip(board.seat(id)).map(|(c, seat)| {
        let mut heat = c.verdict.to_json(seat);
        heat["cooldown_days"] = json!(board.cooldown(id));
        json!({
            "score_100": c.score, "stored": c.stored, "band": c.band.name(), "class": c.class.name(),
            "suggestion": c.suggestion.to_json(), "heat": heat,
        })
    });

    Some(json!({
        "application": row(t, id),
        "card": card,
        "rail": rail,
        "coverage": cv.0,
        "cv": cv.1,
        "events": events,
        "batch": batch,
        "lineage": lineage,
        "outreach": crate::outreach::summary(rows, id),
    }))
}

/// What `cv_part` reads for one application: the picked root, the
/// corporation, theme and listing keywords; the rest is the items,
/// overlays, lineages, roots and versions tables.
pub type CvKey = (Option<u32>, Option<u32>, String);
pub fn cv_key(t: &Table, id: u32, root: Option<u32>) -> CvKey {
    let text = |c| t.str(id, c).unwrap_or("");
    (root, t.u32(id, A::CORPORATION_ID), alloc::format!("{}\u{1f}{}", text(A::CV_THEME), text(A::KEYWORDS)))
}

/// One application's keyword coverage and composed CV (theme and lines).
pub fn cv_part(rows: &Rows, index: &board::Lines, t: &Table, id: u32, root: Option<u32>) -> (Json, Json) {
    let (lines, theme) = cv_of(rows, index, t, id, root);
    // A file root (markdown, pdf, docx) goes out as its newest version: its
    // text is what the listing's words are found in.
    let file = root.and_then(|r| {
        let rt = rows.table(table::CV_ROOTS)?;
        let format = rt.u32(r, col::cv_roots::FORMAT).filter(|f| *f != schema::enums::cv_format::COMPOSED as u32)?;
        let v = rt.u32(r, col::cv_roots::VERSION_ID)?;
        let vt = rows.table(table::CV_VERSIONS)?;
        let text = vt.text(v, col::cv_versions::TEXT).or_else(|| vt.text(v, col::cv_versions::BODY)).unwrap_or_default().into_owned();
        Some((format, v, vt.u32(v, col::cv_versions::N), text))
    });
    let cv_text = file.as_ref().map_or_else(|| cv::visible(&lines, &theme), |f| f.3.clone());
    let listing_words: Vec<&str> = t.str(id, A::KEYWORDS).map(|k| crate::text::list(k).collect()).unwrap_or_default();
    let coverage = keywords::coverage(
        listing_words.iter().copied().chain(theme.targets.iter().map(String::as_str)),
        &keywords::Text::new(&cv_text),
    );
    let cv_lines: Vec<Json> = lines
        .iter()
        .map(|l| {
            json!({
                "item_id": l.item_id, "kind": enum_name(schema::enums::item_kind::NAMES, Some(l.kind as u32)),
                "key": l.key, "title": l.title, "body": l.body, "org": l.org, "span": l.span,
                "mode": l.mode.map(cv::Mode::name), "reason": l.reason,
            })
        })
        .collect();

    let file = file.map(|(format, v, n, text)| {
        json!({"format": enum_name(schema::enums::cv_format::NAMES, Some(format)), "version_id": v, "n": n, "text": text})
    });
    (coverage.to_json(), json!({"theme": theme.to_json(), "lines": cv_lines, "file": file}))
}

/// The CV lines and theme for one application.
pub fn cv_of<'r>(rows: &'r Rows, index: &board::Lines, t: &'r Table, id: u32, root: Option<u32>) -> (Vec<cv::Line<'r>>, Theme) {
    use col::items as I;
    // The profile a picked root composes, when it is a live composition.
    let profile = root.and_then(|r| rows.table(table::CV_ROOTS)?.u32(r, col::cv_roots::PROFILE_ID));
    let items: Vec<Item> = rows
        .each(table::ITEMS)
        .map(|(it, x)| Item {
            id: x,
            profile_id: it.u32(x, I::PROFILE_ID),
            kind: it.u32(x, I::KIND).unwrap_or(0) as u8,
            key: it.str(x, I::KEY).unwrap_or(""),
            title: it.str(x, I::TITLE).unwrap_or(""),
            body: it.text(x, I::BODY),
            org: it.str(x, I::ORG),
            span: it.str(x, I::SPAN),
            position: it.u32(x, I::POSITION).unwrap_or(0),
        })
        .collect();
    // The lineage's overlays, from every application to the corporation:
    // one story per company.
    let lin = lineage_of(rows, t.u32(id, A::CORPORATION_ID));
    let lineage = lin.map(|(_, l)| l);
    let overlays: Vec<Overlay> = rows
        .table(table::CV_OVERLAYS)
        .map(|o| {
            use col::cv_overlays as O;
            // The lineage's overlays and the application's own, from the index.
            let mut ids: Vec<u32> = lineage.into_iter().flat_map(|l| index.overlays(l)).chain(index.overlays_of(id)).collect();
            ids.sort_unstable();
            ids.dedup();
            ids.iter()
                .filter(|&&x| o.has(x))
                .filter_map(|&x| {
                    Some(Overlay {
                        id: x,
                        own: o.u32(x, O::APPLICATION_ID) == Some(id),
                        item_id: o.u32(x, O::ITEM_ID)?,
                        mode: cv::Mode::from_u32(o.u32(x, O::MODE)?)?,
                        title: o.str(x, O::TITLE),
                        body: o.text(x, O::BODY),
                        reason: o.text(x, O::REASON),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let lineage_theme = lin.map(|(lt, l)| Theme::parse(lt.str(l, col::cv_lineages::THEME))).unwrap_or_default();
    let theme = Theme::parse(t.str(id, A::CV_THEME)).over(lineage_theme);
    (cv::compose(profile, &items, &overlays), theme)
}

/// The person's side of the fit: their lists (the languages from their
/// rows), and their weights (`{"<places metric>": w, "route": w,
/// "language": w}`) resolved against the declaration. Also the metric
/// column ids in `Me::metrics` order, and the names that are no numeric
/// figure of places.
pub fn recipe(rows: &Rows) -> (Me<'_>, Vec<u16>, Vec<String>) {
    use col::me as M;
    let p = rows.first(table::ME);
    let get = |c: u16| p.and_then(|(t, id)| t.str(id, c)).unwrap_or("");
    let mut me = Me { citizenships: get(M::CITIZENSHIPS), work_permits: get(M::WORK_PERMITS), languages: board::languages(rows).into(), prefer: get(M::PREFER), avoid: get(M::AVOID), ..Me::default() };
    let (mut cols, mut unknown) = (Vec::new(), Vec::new());
    let places = schema::table_def(table::PLACES);
    // The weights as stored, or as an agent may put them: a JSON string holding the JSON (one unwrap).
    let weights = serde_json::from_str::<Json>(get(M::WEIGHTS)).ok().and_then(|v| match v {
        Json::String(s) => serde_json::from_str::<Json>(&s).ok(),
        v => Some(v),
    });
    for (name, v) in weights.and_then(|v| v.as_object().cloned()).unwrap_or_default() {
        // A weight that is no number, not finite or zero leaves its figure out; the rest are bounded so a sum stays finite.
        let Some(w) = v.as_f64().filter(|w| w.is_finite() && *w != 0.0).map(|w| w.clamp(-1e6, 1e6)) else { continue };
        match name.as_str() {
            "route" => me.route = w,
            "language" => me.language = w,
            _ => match places.and_then(|t| t.col_named(&name)).filter(|c| c.flags & schema::flag::METRIC != 0) {
                Some(c) => {
                    cols.push(c.id);
                    me.metrics.push(w);
                }
                None => unknown.push(name),
            },
        }
    }
    (me, cols, unknown)
}

/// Every country and city as the fit reads them, each with the recipe's figures (`cols`) in order.
pub fn places<'r>(rows: &'r Rows, cols: &[u16]) -> Vec<Place<'r>> {
    use col::places as P;
    // A metric is f64, u32 (population) or i64 by declaration; the fit reads any as a number.
    let num = |t: &Table, id: u32, c: u16| t.f64(id, c).or_else(|| t.u32(id, c).map(f64::from)).or_else(|| t.i64(id, c).map(|v| v as f64));
    rows.each(table::PLACES)
        .filter(|(t, id)| matches!(t.u32(*id, P::KIND), Some(k) if k == enums::place_kind::COUNTRY as u32 || k == enums::place_kind::CITY as u32))
        .map(|(t, id)| Place {
            id,
            city: t.u32(id, P::KIND) == Some(enums::place_kind::CITY as u32),
            country_id: t.u32(id, P::COUNTRY_ID),
            iso2: t.str(id, P::ISO2),
            name: t.str(id, P::NAME).unwrap_or(""),
            language: t.str(id, P::LANGUAGE),
            work_permit: t.str(id, P::WORK_PERMIT),
            figures: cols.iter().map(|&c| num(t, id, c)).collect(),
        })
        .collect()
}

/// Every country and city in atlas order, each with its route, language
/// match, flags and fit; the recipe as resolved; the names in it that are
/// no figure of places; whether anything is known about the person.
pub fn atlas_doc(rows: &Rows) -> Json {
    let (me, cols, unknown) = recipe(rows);
    let ps = places(rows, &cols);
    let fits = atlas::fit(&ps, &me);
    let by_id: alloc::collections::BTreeMap<u32, usize> = ps.iter().enumerate().map(|(i, p)| (p.id, i)).collect();
    fn langs<'a>(p: &Place<'a>) -> Option<&'a str> {
        p.language.filter(|s| !s.trim().is_empty())
    }
    let places: Vec<Json> = atlas::order(&ps, &fits)
        .into_iter()
        .map(|i| {
            let p = &ps[i];
            let country = p.country_id.and_then(|c| by_id.get(&c)).map(|&c| &ps[c]);
            let mut j = fits[i].to_json();
            j["kind"] = if p.city { "city" } else { "country" }.into();
            j["name"] = p.name.into();
            j["iso2"] = p.iso2.into();
            j["country"] = country.map(|c| c.name).into();
            // What the place speaks, a city through its country, as the fit read it.
            j["languages"] = langs(p).or_else(|| country.and_then(langs)).into();
            j
        })
        .collect();
    let def = schema::table_def(table::PLACES);
    let recipe: Vec<Json> = cols
        .iter()
        .zip(&me.metrics)
        .filter_map(|(c, w)| Some(json!({"key": def?.col(*c)?.name, "weight": w})))
        .chain([("route", me.route), ("language", me.language)].into_iter().filter(|(_, w)| *w != 0.0).map(|(k, w)| json!({"key": k, "weight": w})))
        .collect();
    json!({"known": !me.citizenships.is_empty() || !me.work_permits.is_empty(), "recipe": recipe, "unknown": unknown, "places": places})
}
