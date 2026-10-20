//! The atlas: every country and city in `places`, ordered for the person
//! behind the account. Nothing personal lives in source: whose passports,
//! permits and languages, which countries they want or never want, and
//! which figures matter to them are the `me` row; which citizenships
//! need no permit where is each place's `work_permit`, and what a place
//! speaks is its `language`. The lens and the MCP read the fit from here.
//!
//! A place gets a route, whether it speaks one of the person's languages,
//! and an order. The person's `weights` name any numeric metric of
//! `places` plus `route` and `language`; each figure is its mid-rank
//! percentile among places of the same kind that have it (countries
//! against countries, cities against cities; a city missing a figure, a
//! language list or a permit list takes its country's), and a negative
//! weight ranks a lower figure higher. The fit is the weighted mean of the
//! parts present, 0..=1, and it only orders: the lens shows the figures
//! themselves. Places in `prefer` come first and places in `avoid` last,
//! never hidden.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::text;

/// One place as the fit reads it; `figures` are the person's weighted metrics, in `Me::metrics` order.
#[derive(Clone, Debug, Default)]
pub struct Place<'a> {
    pub id: u32,
    pub city: bool,
    pub country_id: Option<u32>,
    pub iso2: Option<&'a str>,
    pub name: &'a str,
    pub language: Option<&'a str>,
    pub work_permit: Option<&'a str>,
    pub figures: Vec<Option<f64>>,
}

/// The person's side of the fit; every list is U+001F-joined codes.
#[derive(Clone, Debug, Default)]
pub struct Me<'a> {
    pub citizenships: &'a str,
    pub work_permits: &'a str,
    /// The person's languages, U+001F-joined ISO 639-1 codes (their `languages` rows).
    pub languages: alloc::borrow::Cow<'a, str>,
    pub prefer: &'a str,
    pub avoid: &'a str,
    /// A weight per figure in `Place::figures`; negative ranks a lower figure higher, zero or non-finite leaves it out.
    pub metrics: Vec<f64>,
    pub route: f64,
    pub language: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Route {
    /// The person holds this country's citizenship.
    Citizen = 0,
    /// The person already holds a work permit or a residence right here.
    Permit = 1,
    /// One of the person's citizenships needs no permit here.
    Free = 2,
    /// A work permit would be needed.
    Needs = 3,
    /// No citizenship or permit given, or neither the country nor a permit list is known.
    Unknown = 4,
}

impl Route {
    pub fn name(self) -> &'static str {
        ["citizen", "permit_held", "free", "needs_permit", "unknown"][self as usize]
    }

    /// The route's part of the fit.
    fn part(self) -> Option<f64> {
        match self {
            Route::Citizen | Route::Permit => Some(1.0),
            Route::Free => Some(0.9),
            Route::Needs => Some(0.3),
            Route::Unknown => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Fit {
    pub id: u32,
    pub route: Route,
    /// Whether the place speaks one of the person's languages; `None` when its languages are unknown.
    pub speaks: Option<bool>,
    pub preferred: bool,
    pub avoided: bool,
    /// The weighted mean of the parts present; `None` with nothing to weigh.
    pub fit: Option<f64>,
}

impl Fit {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "id": self.id, "route": self.route.name(), "speaks": self.speaks, "preferred": self.preferred, "avoided": self.avoided,
            "fit": self.fit.map(|f| libm::round(f * 1000.0) / 1000.0),
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
    let [citizen, held, spoken, prefer, avoid] = [me.citizenships, me.work_permits, &me.languages, me.prefer, me.avoid].map(text::codes);
    let by_id: BTreeMap<u32, usize> = places.iter().enumerate().map(|(i, p)| (p.id, i)).collect();
    let country = |p: &Place| -> Option<usize> {
        if p.city { p.country_id.and_then(|c| by_id.get(&c).copied()).filter(|&c| !places[c].city) } else { None }
    };
    let weight = |w: f64| if w.is_finite() && w != 0.0 { Some(w) } else { None };

    // Each figure ranked per kind, a negative weight reversing it.
    let ranked: Vec<BTreeMap<usize, f64>> = me
        .metrics
        .iter()
        .enumerate()
        .map(|(k, w)| {
            let mut out = BTreeMap::new();
            for city in [false, true] {
                let vals: Vec<(usize, f64)> = places
                    .iter()
                    .enumerate()
                    .filter(|(_, p)| p.city == city)
                    .filter_map(|(i, p)| p.figures.get(k).copied().flatten().filter(|v| v.is_finite()).map(|v| (i, if *w < 0.0 { -v } else { v })))
                    .collect();
                out.extend(ranks(&vals));
            }
            out
        })
        .collect();
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
            let is = |list: &[String]| iso2.is_some_and(|code| list.iter().any(|m| m.eq_ignore_ascii_case(code)));
            let route = if citizen.is_empty() && held.is_empty() {
                Route::Unknown
            } else if is(&citizen) {
                Route::Citizen
            } else if is(&held) {
                Route::Permit
            } else if permit.is_some_and(|l| names_any(l, &citizen)) {
                Route::Free
            } else if iso2.is_some() || permit.is_some() {
                Route::Needs
            } else {
                Route::Unknown
            };
            let speaks = langs.map(|l| names_any(l, &spoken));
            let (mut num, mut den) = (0.0, 0.0);
            let mut add = |w: f64, v: Option<f64>| {
                if let (Some(w), Some(v)) = (weight(w), v) {
                    num += libm::fabs(w) * v;
                    den += libm::fabs(w);
                }
            };
            for (k, m) in ranked.iter().enumerate() {
                add(me.metrics[k], part(m, i));
            }
            add(me.route, route.part());
            add(me.language, speaks.map(|s| if s { 1.0 } else { 0.0 }));
            let fit = (den > 0.0).then(|| (num / den).clamp(0.0, 1.0)).filter(|f| f.is_finite());
            Fit { id: p.id, route, speaks, preferred: is(&prefer), avoided: is(&avoid), fit }
        })
        .collect()
}

/// Place indexes in atlas order: preferred first, avoided last, by fit
/// (unscored last), then name, then id.
pub fn order(places: &[Place<'_>], fits: &[Fit]) -> Vec<usize> {
    let names: Vec<String> = places.iter().map(|p| text::fold(p.name)).collect();
    let tier = |f: &Fit| if f.avoided { 2 } else if f.preferred { 0 } else { 1 };
    let mut v: Vec<usize> = (0..fits.len()).collect();
    v.sort_by(|&a, &b| {
        tier(&fits[a])
            .cmp(&tier(&fits[b]))
            .then(fits[b].fit.unwrap_or(-1.0).total_cmp(&fits[a].fit.unwrap_or(-1.0)))
            .then_with(|| names[a].cmp(&names[b]))
            .then(fits[a].id.cmp(&fits[b].id))
    });
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn country(id: u32, iso2: &'static str, figure: f64, permit: &'static str, lang: &'static str) -> Place<'static> {
        Place { id, iso2: Some(iso2), name: iso2, figures: alloc::vec![Some(figure)], work_permit: Some(permit), language: Some(lang), ..Place::default() }
    }

    fn me(citizenships: &'static str, languages: &'static str) -> Me<'static> {
        Me { citizenships, languages: languages.into(), metrics: alloc::vec![1.0], route: 1.0, language: 1.0, ..Me::default() }
    }

    #[test]
    fn routes_languages_and_inheritance() {
        let places = [
            country(1, "AA", 10.0, "", "xx"),
            country(2, "BB", 30.0, "AA\u{1f}CC", "yy"),
            country(3, "DD", 20.0, "", "zz\u{1f}xx"),
            Place { id: 4, city: true, country_id: Some(2), name: "b-city", ..Place::default() },
            Place { id: 5, city: true, country_id: Some(99), name: "lost", ..Place::default() },
        ];
        let f = fit(&places, &me("aa", "XX"));
        assert_eq!(f.iter().map(|x| x.route).collect::<Vec<_>>(), [Route::Citizen, Route::Free, Route::Needs, Route::Free, Route::Unknown]);
        assert_eq!(f.iter().map(|x| x.speaks).collect::<Vec<_>>(), [Some(true), Some(false), Some(true), Some(false), None]);
        // AA: figure ranked 0 of the three countries, route 1, language 1 → 2/3; the city takes its country's rank.
        assert_eq!(f[0].fit, Some(2.0 / 3.0));
        assert_eq!(f[3].fit, Some((1.0 + 0.9) / 3.0));
        assert_eq!(f[4].fit, None);
        // A permit held is a route of its own; with nothing given about the person, every route is unknown.
        let held = Me { work_permits: "bb", ..me("", "") };
        assert_eq!(fit(&places, &held).iter().map(|x| x.route).collect::<Vec<_>>(), [Route::Needs, Route::Permit, Route::Needs, Route::Permit, Route::Unknown]);
        assert!(fit(&places, &Me::default()).iter().all(|x| x.route == Route::Unknown && x.fit.is_none()));
    }

    #[test]
    fn a_negative_weight_prefers_the_lower_figure_and_the_lists_bracket_the_order() {
        let places = [country(1, "AA", 10.0, "", ""), country(2, "BB", 30.0, "", ""), country(3, "CC", 30.0, "", "")];
        let lower = Me { metrics: alloc::vec![-1.0], ..Me::default() };
        let f = fit(&places, &lower);
        assert_eq!((f[0].fit, f[1].fit, f[2].fit), (Some(1.0), Some(0.25), Some(0.25)));
        assert_eq!(order(&places, &f), [0, 1, 2]);
        let bracketed = Me { prefer: "cc", avoid: "aa", ..lower };
        let f = fit(&places, &bracketed);
        assert_eq!(order(&places, &f), [2, 1, 0]);
        // A zero, non-finite or absurd weight never breaks the mean.
        let odd = Me { metrics: alloc::vec![0.0], route: f64::NAN, language: 1e308, languages: "xx".into(), ..Me::default() };
        assert!(fit(&[country(1, "AA", 1.0, "", "xx")], &odd).iter().all(|x| x.fit == Some(1.0)));
    }
}
