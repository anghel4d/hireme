//! The documents the focus lens and the MCP read, as JSON: one
//! application with everything derived about it, the desk overview, the
//! atlas and the lanes. A document is a pure function of the resident
//! rows and `today`; the browser and `hireme-mcp` render the same one.
//!
//! Raw text the operator or an agent wrote (`listing_raw` is deferred and
//! never here; notes, prose, letters, event bodies are) is returned as
//! written; marking it untrusted is the MCP's job at its edge.

use alloc::string::String;
use alloc::vec::Vec;

use schema::col::applications as A;
use schema::{col, enums, table};
use serde_json::{json, Map, Value as Json};

use crate::atlas::{self, Me, Place, Weights};
use crate::board::{self, Board};
use crate::cv::{self, Item, Overlay, Theme};
use crate::lanes::{self, NetKind, RepOutcome};
use crate::pipeline::{self, Stage, STAGES};
use crate::rows::{Rows, Table, Val};
use crate::{keywords, Day};

fn enum_name(names: &[&'static str], v: Option<u32>) -> Json {
    v.and_then(|v| names.get(v as usize)).map_or(Json::Null, |n| Json::String((*n).into()))
}

fn val(v: Val) -> Json {
    match v {
        Val::None => Json::Null,
        Val::U32(x) => x.into(),
        Val::I64(x) => x.into(),
        Val::F64(x) => x.into(),
        Val::Str(s) => s.into(),
        Val::Deferred(n, h) => json!({"length": n, "sha": h.iter().map(|b| alloc::format!("{b:02x}")).collect::<String>()}),
        Val::List(l) => l.into(),
    }
}

/// Every column of a row, named by the catalog, enums by name.
pub fn row(t: &Table, id: u32) -> Json {
    let Some(def) = schema::table_def(t.id) else { return Json::Null };
    let mut m = Map::new();
    for c in def.cols {
        if c.flags & (schema::flag::SERVER_ONLY | schema::flag::PRIVATE) != 0 {
            continue;
        }
        let v = t.get(id, c.id);
        let j = match (c.type_code, c.target) {
            (code, Some(e)) if code == schema::Type::Enum.code() => enum_name(enum_names(e), t.u32(id, c.id)),
            (code, _) if code == schema::Type::Bool.code() => t.u32(id, c.id).map_or(Json::Null, |b| Json::Bool(b == 1)),
            (code, _) if code == schema::Type::Json.code() => match &v {
                Val::Str(s) => serde_json::from_str(s).unwrap_or(Json::String(s.clone())),
                _ => Json::Null,
            },
            _ => val(v),
        };
        m.insert(c.name.into(), j);
    }
    Json::Object(m)
}

fn enum_names(name: &str) -> &'static [&'static str] {
    schema::enum_names(name).unwrap_or(&[])
}

/// One application: its row, card, rail, heat, suggestion, coverage, CV,
/// events, batch and lineage.
pub fn application(rows: &Rows, board: &Board, id: u32, today: Day) -> Option<Json> {
    let t = rows.table(table::APPLICATIONS)?;
    if !t.has(id) {
        return None;
    }
    let stage = t.u32(id, A::STAGE).and_then(|v| u8::try_from(v).ok().and_then(Stage::from_u8)).unwrap_or(Stage::Discovered);
    let rail = pipeline::rail_of(stage, t.str(id, A::PIPS));
    let rail: Vec<Json> = STAGES
        .iter()
        .map(|s| json!({"stage": s.name(), "label": s.label(), "hint": s.hint(), "pip": rail[s.index()].name(), "fire_locked": s.fire_locked()}))
        .collect();

    let (lines, theme) = cv_of(rows, board.lines_built(), t, id);
    let cv_text = cv::visible(&lines, &theme);
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

    let events: Vec<Json> = rows
        .table(table::EVENTS)
        .map(|e| {
            let mut ids: Vec<u32> = e.ids().iter().copied().filter(|&x| e.u32(x, col::events::APPLICATION_ID) == Some(id)).collect();
            ids.sort_unstable_by(|a, b| b.cmp(a));
            ids.into_iter().map(|x| row(e, x)).collect()
        })
        .unwrap_or_default();

    let batch = t.u32(id, A::BATCH_ID).and_then(|b| rows.table(table::BATCHES).filter(|bt| bt.has(b)).map(|bt| row(bt, b)));
    let lineage = t
        .u32(id, A::CORPORATION_ID)
        .and_then(|c| {
            let lt = rows.table(table::CV_LINEAGES)?;
            lt.ids().iter().copied().find(|&l| lt.u32(l, col::cv_lineages::CORPORATION_ID) == Some(c)).map(|l| (lt, l))
        })
        .map(|(lt, l)| {
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
        "coverage": coverage.to_json(),
        "cv": {"theme": theme.to_json(), "lines": cv_lines},
        "events": events,
        "batch": batch,
        "lineage": lineage,
    }))
}

/// The CV lines and theme for one application.
pub fn cv_of<'r>(rows: &'r Rows, lines: Option<&crate::board::Lines>, t: &'r Table, id: u32) -> (Vec<cv::Line<'r>>, Theme) {
    use col::items as I;
    let profile = t.u32(id, A::PROFILE_ID);
    let items: Vec<Item> = rows
        .table(table::ITEMS)
        .map(|it| {
            it.ids()
                .iter()
                .map(|&x| Item {
                    id: x,
                    profile_id: it.u32(x, I::PROFILE_ID),
                    kind: it.u32(x, I::KIND).unwrap_or(0) as u8,
                    key: it.str(x, I::KEY).unwrap_or(""),
                    title: it.str(x, I::TITLE).unwrap_or(""),
                    body: it.str(x, I::BODY),
                    org: it.str(x, I::ORG),
                    span: it.str(x, I::SPAN),
                    position: it.u32(x, I::POSITION).unwrap_or(0),
                })
                .collect()
        })
        .unwrap_or_default();
    // The lineage's overlays, from every application to the corporation:
    // one story per company.
    let lineage = t.u32(id, A::CORPORATION_ID).and_then(|c| {
        let lt = rows.table(table::CV_LINEAGES)?;
        lt.ids().iter().copied().find(|&l| lt.u32(l, col::cv_lineages::CORPORATION_ID) == Some(c))
    });
    let overlays: Vec<Overlay> = rows
        .table(table::CV_OVERLAYS)
        .map(|o| {
            use col::cv_overlays as O;
            // The lineage's overlays from the index when there is one; an
            // application with no lineage reads its own by a scan.
            // The lineage's and the application's own, as the scan below.
            let ids: Vec<u32> = match (lines, lineage) {
                (Some(l), Some(lid)) => {
                    let mut ids: Vec<u32> = l.overlays(lid).chain(l.overlays_of(id)).collect();
                    ids.sort_unstable();
                    ids.dedup();
                    ids
                }
                _ => o
                    .ids()
                    .iter()
                    .copied()
                    .filter(|&x| o.u32(x, O::APPLICATION_ID) == Some(id) || (lineage.is_some() && o.u32(x, O::LINEAGE_ID) == lineage))
                    .collect(),
            };
            ids.iter()
                .filter(|&&x| o.has(x))
                .filter_map(|&x| {
                    Some(Overlay {
                        id: x,
                        own: o.u32(x, O::APPLICATION_ID) == Some(id),
                        item_id: o.u32(x, O::ITEM_ID)?,
                        mode: u8::try_from(o.u32(x, O::MODE)?).ok().and_then(cv::Mode::from_u8)?,
                        title: o.str(x, O::TITLE),
                        body: o.str(x, O::BODY),
                        reason: o.str(x, O::REASON),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let lineage_theme = t
        .u32(id, A::CORPORATION_ID)
        .and_then(|c| {
            let lt = rows.table(table::CV_LINEAGES)?;
            let l = lt.ids().iter().copied().find(|&l| lt.u32(l, col::cv_lineages::CORPORATION_ID) == Some(c))?;
            Some(Theme::parse(lt.str(l, col::cv_lineages::THEME)))
        })
        .unwrap_or_default();
    let theme = Theme::parse(t.str(id, A::CV_THEME)).over(lineage_theme);
    (cv::compose(profile, &items, &overlays), theme)
}

/// The desk at a glance: the scoreboard, the lanes, the top of the board.
pub fn overview(rows: &Rows, board: &Board, today: Day, top: usize) -> Json {
    let apps = rows.table(table::APPLICATIONS);
    let head: Vec<Json> = board
        .order()
        .iter()
        .take(top)
        .filter_map(|&id| {
            let c = board.card(id)?;
            let t = apps?;
            Some(json!({
                "id": id, "no": c.no, "company": t.str(id, A::COMPANY), "role": t.str(id, A::ROLE),
                "stage": c.stage.name(), "score_100": c.score, "band": c.band.name(), "class": c.class.name(),
            }))
        })
        .collect();
    json!({
        "today": today,
        "scoreboard": board.scoreboard(rows, today).to_json(),
        "lanes": lanes_doc(rows, today),
        "top": head,
    })
}

/// The gym and net lanes.
pub fn lanes_doc(rows: &Rows, today: Day) -> Json {
    let target = board::settings(rows).and_then(|(t, id)| t.u32(id, col::settings::GYM_TARGET));
    let reps: Vec<(Day, RepOutcome)> = rows
        .table(table::GYM_REPS)
        .map(|t| {
            t.ids()
                .iter()
                .filter_map(|&id| {
                    let d = t.u32(id, col::gym_reps::DONE_ON)? as Day;
                    let o = u8::try_from(t.u32(id, col::gym_reps::OUTCOME).unwrap_or(0)).ok().and_then(RepOutcome::from_u8)?;
                    Some((d, o))
                })
                .collect()
        })
        .unwrap_or_default();
    let entries: Vec<(NetKind, Option<Day>)> = rows
        .table(table::NET_ENTRIES)
        .map(|t| {
            t.ids()
                .iter()
                .filter_map(|&id| {
                    let k = u8::try_from(t.u32(id, col::net_entries::KIND)?).ok().and_then(NetKind::from_u8)?;
                    Some((k, t.u32(id, col::net_entries::SHIPPED_ON).map(|d| d as Day)))
                })
                .collect()
        })
        .unwrap_or_default();
    json!({"gym": lanes::gym(reps, target, today).to_json(), "net": lanes::net(entries, today).to_json()})
}

/// The atlas places as the fit reads them.
pub fn places(rows: &Rows) -> Vec<Place<'_>> {
    use col::atlas as P;
    let Some(t) = rows.table(table::ATLAS) else { return Vec::new() };
    t.ids()
        .iter()
        .map(|&id| Place {
            id,
            city: t.u32(id, P::KIND) == Some(enums::place_kind::CITY as u32),
            country_id: t.u32(id, P::COUNTRY_ID),
            iso2: t.str(id, P::ISO2),
            name: t.str(id, P::NAME).unwrap_or(""),
            position: t.u32(id, P::ATLAS_POSITION).unwrap_or(u32::MAX),
            labeled: t.u32(id, P::ATLAS_LABELED) == Some(1),
            gdp_per_capita_ppp_usd: t.f64(id, P::GDP_PER_CAPITA_PPP_USD),
            qol_index: t.f64(id, P::QOL_INDEX),
            energy_production_per_capita_kwh: t.f64(id, P::ENERGY_PRODUCTION_PER_CAPITA_KWH),
            energy_consumption_per_capita_kwh: t.f64(id, P::ENERGY_CONSUMPTION_PER_CAPITA_KWH),
            mobility: t.f64(id, P::MOBILITY),
            language: t.str(id, P::LANGUAGE),
            tech: t.f64(id, P::TECH),
            ease: t.f64(id, P::EASE),
            work_permit: t.str(id, P::WORK_PERMIT),
        })
        .collect()
}

/// The operator's side of the fit: settings, or a preset's weights.
pub fn me<'r>(rows: &'r Rows, preset: Option<&str>) -> Me<'r> {
    use col::settings as S;
    let st = board::settings(rows);
    let get = |c: u16| st.and_then(|(t, id)| t.f64(id, c));
    let weights = preset.and_then(atlas::preset).unwrap_or_else(|| {
        Weights::from_settings([S::W_ENERGY, S::W_ECONOMY, S::W_LIVEABILITY, S::W_MOBILITY, S::W_LANGUAGE, S::W_TECH, S::W_EASE].map(get))
    });
    Me {
        citizenships: st.and_then(|(t, id)| t.str(id, S::CITIZENSHIPS)).unwrap_or(""),
        languages: st.and_then(|(t, id)| t.str(id, S::LANGUAGES)).unwrap_or(""),
        weights,
    }
}

/// Every charted place with its fit, best first, and the presets.
pub fn atlas_doc(rows: &Rows, preset: Option<&str>) -> Json {
    let ps = places(rows);
    let me = me(rows, preset);
    let fits = atlas::fit(&ps, &me);
    let order = atlas::order(&fits);
    let by_id: alloc::collections::BTreeMap<u32, usize> = ps.iter().enumerate().map(|(i, p)| (p.id, i)).collect();
    let places: Vec<Json> = order
        .iter()
        .filter_map(|id| by_id.get(id))
        .map(|&i| {
            let mut j = fits[i].to_json();
            j["name"] = ps[i].name.into();
            j["iso2"] = ps[i].iso2.into();
            j["kind"] = if ps[i].city { "city" } else { "country" }.into();
            j["position"] = ps[i].position.into();
            j["labeled"] = ps[i].labeled.into();
            j
        })
        .collect();
    let presets: Map<String, Json> = atlas::PRESETS.iter().map(|(n, w)| ((*n).into(), json!(w))).collect();
    json!({"parts": atlas::PARTS, "weights": me.weights.0, "presets": presets, "places": places})
}
