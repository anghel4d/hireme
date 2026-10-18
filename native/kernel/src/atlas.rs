//! The atlas: every charted place (`atlas_position` set) scored against
//! the operator's own citizenships, languages and weights. This is the
//! only copy of the fit; the lens and the MCP read it from here.
//!
//! It reads exactly the `atlas` projection's columns and the settings
//! row, and nothing personal lives in source: whose passports and which
//! languages are `settings.citizenships` and `settings.languages`, and
//! which citizenships need no permit where is each place's `work_permit`.
//!
//! A place gets a route and seven parts, each in 0..=1 or absent:
//!
//! | part | from |
//! | --- | --- |
//! | energy | production over consumption per capita, ranked |
//! | economy | `gdp_per_capita_ppp_usd`, ranked |
//! | liveability | `qol_index`, ranked |
//! | mobility | the route: citizen 1, no permit needed 0.9, otherwise half the place's `mobility` rank |
//! | language | 1 when the place speaks one of the operator's languages, else 0 |
//! | tech | `tech`, ranked |
//! | ease | `ease`, ranked |
//!
//! "Ranked" is the mid-rank percentile among charted places of the same
//! kind that have the figure, so countries are compared with countries
//! and cities with cities. A city missing a figure, a language list or a
//! permit list takes its country's when the country is charted. The fit
//! is the weighted mean of the parts present, as 0..=100; weights come
//! from `settings.w_*` (absent is 1, negative is 0) or a preset.

use alloc::collections::BTreeMap;
use alloc::vec::Vec;

use crate::text;

pub const PARTS: [&str; 7] = ["energy", "economy", "liveability", "mobility", "language", "tech", "ease"];

/// One row of the `atlas` projection.
#[derive(Clone, Debug, Default)]
pub struct Place<'a> {
    pub id: u32,
    pub city: bool,
    pub country_id: Option<u32>,
    pub iso2: Option<&'a str>,
    pub name: &'a str,
    pub position: u32,
    pub labeled: bool,
    pub gdp_per_capita_ppp_usd: Option<f64>,
    pub qol_index: Option<f64>,
    pub energy_production_per_capita_kwh: Option<f64>,
    pub energy_consumption_per_capita_kwh: Option<f64>,
    pub mobility: Option<f64>,
    pub language: Option<&'a str>,
    pub tech: Option<f64>,
    pub ease: Option<f64>,
    pub work_permit: Option<&'a str>,
}

/// The operator's side of the fit.
#[derive(Clone, Debug, Default)]
pub struct Me<'a> {
    pub citizenships: &'a str,
    pub languages: &'a str,
    pub weights: Weights,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Weights(pub [f64; 7]);

impl Default for Weights {
    fn default() -> Weights {
        Weights([1.0; 7])
    }
}

impl Weights {
    /// From the settings columns in `PARTS` order: absent is 1, negative
    /// or non-finite is 0.
    pub fn from_settings(w: [Option<f64>; 7]) -> Weights {
        Weights(w.map(|x| match x {
            None => 1.0,
            // Bounded so a sum of weights stays finite.
            Some(x) if x.is_finite() && x > 0.0 => x.min(1e6),
            Some(_) => 0.0,
        }))
    }
}

/// Named weight sets the lens offers; choosing one writes its numbers to
/// the settings row.
pub const PRESETS: [(&str, [f64; 7]); 4] = [
    ("balanced", [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
    ("career", [0.0, 2.0, 1.0, 3.0, 1.0, 3.0, 1.0]),
    ("life", [1.0, 1.0, 3.0, 2.0, 2.0, 0.5, 2.0]),
    ("energy", [3.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
];

pub fn preset(name: &str) -> Option<Weights> {
    PRESETS.iter().find(|(n, _)| *n == name).map(|(_, w)| Weights(*w))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Route {
    /// The operator holds this country's citizenship.
    Citizen = 0,
    /// One of the operator's citizenships needs no permit here.
    Free = 1,
    /// A work permit is needed.
    Permit = 2,
    /// Neither the country nor a permit list is known.
    Unknown = 3,
}

impl Route {
    pub fn name(self) -> &'static str {
        ["citizen", "free", "permit", "unknown"][self as usize]
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Fit {
    pub id: u32,
    pub route: Route,
    pub parts: [Option<f64>; 7],
    /// Whether the place speaks one of the operator's languages; `None`
    /// when its languages are unknown.
    pub speaks: Option<bool>,
    pub fit: Option<u8>,
    pub position: u32,
}

impl Fit {
    pub fn to_json(&self) -> serde_json::Value {
        let mut parts = serde_json::Map::new();
        for (i, p) in PARTS.iter().enumerate() {
            parts.insert((*p).into(), self.parts[i].into());
        }
        serde_json::json!({
            "id": self.id, "route": self.route.name(), "speaks": self.speaks,
            "fit": self.fit, "parts": parts,
        })
    }
}

/// The mid-rank percentile of each present value among `values`.
fn ranks(values: &[(usize, f64)]) -> BTreeMap<usize, f64> {
    let mut sorted: Vec<f64> = values.iter().map(|v| v.1).collect();
    sorted.sort_by(f64::total_cmp);
    let n = sorted.len();
    values
        .iter()
        .map(|&(i, v)| {
            if n == 1 {
                return (i, 0.5);
            }
            let less = sorted.partition_point(|x| *x < v);
            let le = sorted.partition_point(|x| *x <= v);
            let mid = less as f64 + (le - less - 1) as f64 / 2.0;
            (i, mid / (n - 1) as f64)
        })
        .collect()
}

/// Whether a place's list names any of `mine` (already lowercased).
fn names_any(list: &str, mine: &[String]) -> bool {
    !mine.is_empty() && text::list(list).any(|c| mine.iter().any(|m| m.eq_ignore_ascii_case(c)))
}

/// Every place's fit, in input order.
pub fn fit<'a>(places: &[Place<'a>], me: &Me) -> Vec<Fit> {
    let (citizen, spoken) = (text::codes(me.citizenships), text::codes(me.languages));
    let by_id: BTreeMap<u32, usize> = places.iter().enumerate().map(|(i, p)| (p.id, i)).collect();
    let country = |p: &Place| -> Option<usize> {
        if p.city { p.country_id.and_then(|c| by_id.get(&c).copied()).filter(|&c| !places[c].city) } else { None }
    };

    // Ranked figures, per kind.
    type Get = fn(&Place) -> Option<f64>;
    let figures: [Get; 5] = [
        |p| match (p.energy_production_per_capita_kwh, p.energy_consumption_per_capita_kwh) {
            (Some(a), Some(b)) if b > 0.0 && a >= 0.0 => Some(a / b),
            _ => None,
        },
        |p| p.gdp_per_capita_ppp_usd,
        |p| p.qol_index,
        |p| p.tech,
        |p| p.ease,
    ];
    let mobility_fig: Get = |p| p.mobility;
    let ranked = |get: Get| -> BTreeMap<usize, f64> {
        let mut out = BTreeMap::new();
        for city in [false, true] {
            let vals: Vec<(usize, f64)> = places
                .iter()
                .enumerate()
                .filter(|(_, p)| p.city == city)
                .filter_map(|(i, p)| get(p).filter(|v| v.is_finite()).map(|v| (i, v)))
                .collect();
            out.extend(ranks(&vals));
        }
        out
    };
    let ranked_figs: Vec<BTreeMap<usize, f64>> = figures.iter().map(|g| ranked(*g)).collect();
    let mobility_rank = ranked(mobility_fig);
    // A figure for place `i`, else its country's.
    let part = |m: &BTreeMap<usize, f64>, i: usize| m.get(&i).copied().or_else(|| country(&places[i]).and_then(|c| m.get(&c).copied()));

    places
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let c = country(p).map(|c| &places[c]);
            // The wire's null string is empty; empty inherits like absent.
            let some = |s: Option<&'a str>| s.filter(|s| !s.trim().is_empty());
            let iso2 = if p.city { some(c.and_then(|c| c.iso2)).or(some(p.iso2)) } else { some(p.iso2) };
            let permit = some(p.work_permit).or_else(|| some(c.and_then(|c| c.work_permit)));
            let langs = some(p.language).or_else(|| some(c.and_then(|c| c.language)));
            let route = if iso2.is_some_and(|code| citizen.iter().any(|m| m.eq_ignore_ascii_case(code))) {
                Route::Citizen
            } else if permit.is_some_and(|l| names_any(l, &citizen)) {
                Route::Free
            } else if iso2.is_some() || permit.is_some() {
                Route::Permit
            } else {
                Route::Unknown
            };
            let speaks = langs.map(|l| names_any(l, &spoken));
            let mobility = match route {
                Route::Citizen => Some(1.0),
                Route::Free => Some(0.9),
                Route::Permit => Some(part(&mobility_rank, i).unwrap_or(0.0) / 2.0),
                Route::Unknown => None,
            };
            let parts = [
                part(&ranked_figs[0], i),
                part(&ranked_figs[1], i),
                part(&ranked_figs[2], i),
                mobility,
                speaks.map(|s| if s { 1.0 } else { 0.0 }),
                part(&ranked_figs[3], i),
                part(&ranked_figs[4], i),
            ];
            let (mut num, mut den) = (0.0, 0.0);
            for (k, v) in parts.iter().enumerate() {
                if let Some(v) = v {
                    num += me.weights.0[k] * v;
                    den += me.weights.0[k];
                }
            }
            let fit = (den > 0.0).then(|| libm::round(100.0 * num / den).clamp(0.0, 100.0) as u8);
            Fit { id: p.id, route, parts, speaks, fit, position: p.position }
        })
        .collect()
}

/// Place ids by fit, best first; unscored last; ties by atlas position,
/// then id.
pub fn order(fits: &[Fit]) -> Vec<u32> {
    let mut v: Vec<&Fit> = fits.iter().collect();
    v.sort_by(|a, b| {
        let fit = |f: &Fit| f.fit.map_or(-1, |x| x as i32);
        fit(b).cmp(&fit(a)).then(a.position.cmp(&b.position)).then(a.id.cmp(&b.id))
    });
    v.into_iter().map(|f| f.id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn country(id: u32, iso2: &'static str, gdp: f64, permit: &'static str, lang: &'static str) -> Place<'static> {
        Place {
            id,
            iso2: Some(iso2),
            name: iso2,
            position: id,
            gdp_per_capita_ppp_usd: Some(gdp),
            work_permit: Some(permit),
            language: Some(lang),
            ..Place::default()
        }
    }

    #[test]
    fn routes_languages_and_inheritance() {
        let places = [
            country(1, "AA", 10.0, "", "xx"),
            country(2, "BB", 30.0, "AA\u{1f}CC", "yy"),
            country(3, "DD", 20.0, "", "zz\u{1f}xx"),
            Place { id: 4, city: true, country_id: Some(2), name: "b-city", position: 9, ..Place::default() },
            Place { id: 5, city: true, country_id: Some(99), name: "lost", position: 10, ..Place::default() },
        ];
        let me = Me { citizenships: "aa", languages: "XX", weights: Weights::default() };
        let f = fit(&places, &me);
        assert_eq!(f.iter().map(|x| x.route).collect::<Vec<_>>(), [Route::Citizen, Route::Free, Route::Permit, Route::Free, Route::Unknown]);
        assert_eq!(f.iter().map(|x| x.speaks).collect::<Vec<_>>(), [Some(true), Some(false), Some(true), Some(false), None]);
        // Economy ranks among countries: 10 → 0, 20 → 0.5, 30 → 1.
        assert_eq!([f[0].parts[1], f[2].parts[1], f[1].parts[1]], [Some(0.0), Some(0.5), Some(1.0)]);
        // The city takes its country's economy rank.
        assert_eq!(f[3].parts[1], Some(1.0));
        assert_eq!(f[4].fit, None);
        // AA: economy 0, mobility 1, language 1 → 67.
        assert_eq!(f[0].fit, Some(67));
    }

    #[test]
    fn weights_and_presets() {
        assert_eq!(Weights::from_settings([None, Some(2.0), Some(-1.0), Some(f64::NAN), None, None, None]).0, [1.0, 2.0, 0.0, 0.0, 1.0, 1.0, 1.0]);
        assert!(preset("career").is_some() && preset("nope").is_none());
        // Economy alone, mid-ranked: 10 → 0, and the two 30s share 0.75.
        let places = [country(1, "AA", 10.0, "", "xx"), country(2, "BB", 30.0, "", "yy"), country(3, "CC", 30.0, "", "zz")];
        let econ_only = Me { citizenships: "", languages: "", weights: Weights([0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0]) };
        let f = fit(&places, &econ_only);
        assert_eq!((f[0].fit, f[1].fit, f[2].fit), (Some(0), Some(75), Some(75)));
        assert_eq!(order(&f), [2, 3, 1]);
    }

    #[test]
    fn empty_lists_inherit_and_ties_order_by_id() {
        let mut ps = [
            country(1, "AA", 10.0, "", "xx"),
            Place { id: 3, city: true, country_id: Some(1), name: "c", position: 5, work_permit: Some(""), language: Some(" "), ..Place::default() },
            Place { id: 2, city: true, country_id: Some(1), name: "b", position: 5, ..Place::default() },
        ];
        ps[0].work_permit = Some("BB");
        let me = Me { citizenships: "bb", languages: "xx", weights: Weights::default() };
        let f = fit(&ps, &me);
        assert_eq!((f[1].route, f[1].speaks), (Route::Free, Some(true)));
        assert_eq!(order(&f[1..]), [2, 3]);
        let huge = Weights::from_settings([Some(1.7e308), Some(1.7e308), None, None, None, None, None]);
        assert!(fit(&ps, &Me { weights: huge, ..me }).iter().all(|x| x.fit.is_some_and(|v| v <= 100)));
    }
}
