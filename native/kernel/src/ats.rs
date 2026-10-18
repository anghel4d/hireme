//! The applicant tracking system behind an apply URL: the vendor from
//! its host, the tenant (one company's board on that vendor) from its
//! host or path. The vendor set is closed; an unknown host is `Unknown`
//! with no tenant and never trips vendor heat.

use alloc::string::String;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Vendor {
    Greenhouse,
    Lever,
    Ashby,
    Workday,
    Icims,
    SmartRecruiters,
    Workable,
    Jobvite,
    Taleo,
    SuccessFactors,
    BambooHr,
    Rippling,
    Eightfold,
    Gem,
    Unknown,
}

impl Vendor {
    pub fn name(self) -> &'static str {
        match self {
            Vendor::Greenhouse => "greenhouse",
            Vendor::Lever => "lever",
            Vendor::Ashby => "ashby",
            Vendor::Workday => "workday",
            Vendor::Icims => "icims",
            Vendor::SmartRecruiters => "smartrecruiters",
            Vendor::Workable => "workable",
            Vendor::Jobvite => "jobvite",
            Vendor::Taleo => "taleo",
            Vendor::SuccessFactors => "successfactors",
            Vendor::BambooHr => "bamboohr",
            Vendor::Rippling => "rippling",
            Vendor::Eightfold => "eightfold",
            Vendor::Gem => "gem",
            Vendor::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ats {
    pub vendor: Vendor,
    pub tenant: Option<String>,
}

impl Ats {
    pub const UNKNOWN: Ats = Ats { vendor: Vendor::Unknown, tenant: None };
}

/// A host root: `Exact` matches the root or any subdomain of it,
/// `Sub` only subdomains.
enum Root {
    Exact(&'static str),
    Sub(&'static str),
}

use Root::{Exact, Sub};

const HOSTS: &[(Vendor, &[Root])] = &[
    (Vendor::Greenhouse, &[Exact("greenhouse.io"), Sub("greenhouse.net")]),
    (Vendor::Lever, &[Exact("lever.co")]),
    (Vendor::Ashby, &[Exact("ashbyhq.com")]),
    (Vendor::Workday, &[Sub("myworkdayjobs.com"), Sub("myworkday.com"), Sub("myworkdaysite.com")]),
    (Vendor::Icims, &[Exact("icims.com")]),
    (Vendor::SmartRecruiters, &[Exact("smartrecruiters.com")]),
    (Vendor::Workable, &[Exact("workable.com")]),
    (Vendor::Jobvite, &[Exact("jobvite.com")]),
    (Vendor::Taleo, &[Exact("taleo.net")]),
    (Vendor::SuccessFactors, &[Sub("successfactors.com"), Sub("successfactors.eu"), Sub("sapsf.com"), Sub("sapsf.eu")]),
    (Vendor::BambooHr, &[Exact("bamboohr.com")]),
    (Vendor::Rippling, &[Sub("rippling.com")]),
    (Vendor::Eightfold, &[Sub("eightfold.ai")]),
    (Vendor::Gem, &[Exact("gem.com")]),
];

fn under(host: &str, root: &str) -> bool {
    host.len() > root.len() && host.ends_with(root) && host.as_bytes()[host.len() - root.len() - 1] == b'.'
}

fn matches(host: &str, root: &Root) -> bool {
    match root {
        Exact(r) => host == *r || under(host, r),
        Sub(r) => under(host, r),
    }
}

/// Host (lowercased, no port, userinfo or trailing dot), path and query
/// of a URL, the fragment cut first.
fn split(url: &str) -> Option<(String, &str, &str)> {
    let url = url.trim();
    let url = &url[..url.find('#').unwrap_or(url.len())];
    // A scheme is only a "://" before any path or query.
    let rest = match url.find("://") {
        Some(i) if !url[..i].contains(['/', '?']) => &url[i + 3..],
        _ => url,
    };
    let end = rest.find(['/', '?']).unwrap_or(rest.len());
    let authority = &rest[..end];
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let host = host.split(':').next().unwrap_or("").trim_end_matches('.');
    if host.is_empty() || !host.contains('.') {
        return None;
    }
    let (path, query) = rest[end..].split_once('?').unwrap_or((&rest[end..], ""));
    Some((host.to_ascii_lowercase(), path, query))
}

pub fn parse(url: &str) -> Ats {
    let Some((host, path, query)) = split(url) else { return Ats::UNKNOWN };
    let param = |key: &str| param(query, key);
    let Some(&(vendor, roots)) = HOSTS.iter().find(|(_, roots)| roots.iter().any(|r| matches(&host, r))) else {
        return Ats::UNKNOWN;
    };
    let tenant = match vendor {
        // The embed form names the board in its query: /embed/job_app?for=acme.
        Vendor::Greenhouse => {
            if path.starts_with("/embed") { param("for") } else { first_segment(path) }
        }
            .or_else(|| subdomain(&host, "greenhouse.io"))
            .or_else(|| subdomain(&host, "greenhouse.net")),
        Vendor::Lever | Vendor::Ashby => {
            let Exact(r) = roots[0] else { unreachable!() };
            first_segment(path).or_else(|| subdomain(&host, r))
        }
        // acme.workable.com/jobs/123, or apply.workable.com/acme/j/123.
        Vendor::Workable => subdomain(&host, "workable.com").or_else(|| first_segment(path)),
        Vendor::SmartRecruiters | Vendor::Jobvite | Vendor::Rippling | Vendor::Gem => first_segment(path),
        Vendor::Taleo | Vendor::BambooHr | Vendor::Eightfold => {
            let r = match roots[0] {
                Exact(r) | Sub(r) => r,
            };
            subdomain(&host, r)
        }
        // acme.wd5.myworkdayjobs.com and acme.myworkdayjobs.com name it in
        // the host; wd3.myworkdaysite.com/en-US/recruiting/acme/x and
        // wd5.myworkday.com/acme/x put a data center there and the tenant
        // in the path.
        Vendor::Workday => {
            let first = host.split('.').next().unwrap_or("");
            let data_center = first.len() > 2 && first.starts_with("wd") && first[2..].bytes().all(|b| b.is_ascii_digit());
            (!data_center && first != "www" && !first.is_empty()).then(|| String::from(first)).or_else(|| workday_segment(path))
        }
        // careers-acme.icims.com
        Vendor::Icims => {
            let left = host.strip_suffix(".icims.com").unwrap_or("");
            let left = left.strip_prefix("careers-").unwrap_or(left);
            let left = left.rsplit('.').next().unwrap_or("");
            (!left.is_empty() && left != "www").then(|| String::from(left))
        }
        // career4.successfactors.com is a shared server; the company is
        // the `company` parameter.
        Vendor::SuccessFactors => param("company"),
        Vendor::Unknown => None,
    };
    Ats { vendor, tenant }
}

/// One query parameter's value, lowercased.
fn param(query: &str, key: &str) -> Option<String> {
    query
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .find(|(k, v)| *k == key && !v.trim().is_empty())
        .map(|(_, v)| v.trim().to_ascii_lowercase())
}

/// The first path segment that is not a generic jobs word or an id (all
/// digits).
fn first_segment(path: &str) -> Option<String> {
    segments(path).find(|s| !matches!(s.as_str(), "job" | "jobs" | "career" | "careers" | "apply" | "embed" | "job_app" | "j"))
}

/// Workday's path tenant, after an optional locale ("en-US") and
/// `recruiting`.
fn workday_segment(path: &str) -> Option<String> {
    let locale = |s: &str| s.len() == 5 && s.as_bytes()[2] == b'-';
    segments(path).find(|s| !locale(s) && s != "recruiting")
}

fn segments(path: &str) -> impl Iterator<Item = String> + '_ {
    path.split('/').filter(|s| !s.is_empty() && !s.bytes().all(|b| b.is_ascii_digit())).map(str::to_ascii_lowercase)
}

/// The label just left of `root` in `host`, unless it is a generic one.
fn subdomain(host: &str, root: &str) -> Option<String> {
    let left = host.strip_suffix(root)?.strip_suffix('.')?;
    let name = left.rsplit('.').next()?;
    (!matches!(name, "" | "www" | "jobs" | "boards" | "job-boards" | "apply" | "ats")).then(|| String::from(name))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(url: &str) -> (Vendor, Option<&'static str>) {
        let a = parse(url);
        (a.vendor, a.tenant.map(|s| &*alloc::boxed::Box::leak(s.into_boxed_str())))
    }

    #[test]
    fn vendors_and_tenants() {
        assert_eq!(t("https://boards.greenhouse.io/acme/jobs/123"), (Vendor::Greenhouse, Some("acme")));
        assert_eq!(t("https://job-boards.greenhouse.io/embed/job_app?for=x"), (Vendor::Greenhouse, Some("x")));
        assert_eq!(t("https://jobs.lever.co/acme/abc-123"), (Vendor::Lever, Some("acme")));
        assert_eq!(t("https://jobs.ashbyhq.com/Acme"), (Vendor::Ashby, Some("acme")));
        assert_eq!(t("https://acme.wd5.myworkdayjobs.com/en-US/External"), (Vendor::Workday, Some("acme")));
        assert_eq!(t("https://careers-acme.icims.com/jobs/1/x/job"), (Vendor::Icims, Some("acme")));
        assert_eq!(t("https://career4.successfactors.com/career?company=Acme"), (Vendor::SuccessFactors, Some("acme")));
        assert_eq!(t("https://wd3.myworkdaysite.com/en-US/recruiting/acme/External"), (Vendor::Workday, Some("acme")));
        assert_eq!(t("https://wd5.myworkday.com/acme/d/x"), (Vendor::Workday, Some("acme")));
        assert_eq!(t("https://acme.workable.com/jobs/123456"), (Vendor::Workable, Some("acme")));
        assert_eq!(t("https://apply.workable.com/acme/j/ABC"), (Vendor::Workable, Some("acme")));
        assert_eq!(t("https://boards.greenhouse.io/embed/job_app?token=1"), (Vendor::Greenhouse, None));
        assert_eq!(t("https://boards.greenhouse.io/embed/job_app?for=acme%0A#x?for=evil"), (Vendor::Greenhouse, Some("acme%0a")));
        assert_eq!(t("https://jobs.lever.co./acme"), (Vendor::Lever, Some("acme")));
        assert_eq!(t("https://jobs.lever.co/ai/3f2a"), (Vendor::Lever, Some("ai")));
        assert_eq!(t("https://boards.greenhouse.io/ey/jobs/1"), (Vendor::Greenhouse, Some("ey")));
        assert_eq!(t("https://boards.greenhouse.io/acme/jobs/1?for=other"), (Vendor::Greenhouse, Some("acme")));
        assert_eq!(t("jobs.lever.co/acme?next=https://x.y"), (Vendor::Lever, Some("acme")));
        assert_eq!(t("https://x.successfactors.com/career"), (Vendor::SuccessFactors, None));
        assert_eq!(t("https://acme.bamboohr.com/careers/12"), (Vendor::BambooHr, Some("acme")));
        assert_eq!(t("https://ats.rippling.com/acme/jobs/1"), (Vendor::Rippling, Some("acme")));
        assert_eq!(t("https://acme.eightfold.ai/careers"), (Vendor::Eightfold, Some("acme")));
        assert_eq!(t("https://www.gem.com/acme"), (Vendor::Gem, Some("acme")));
        assert_eq!(t("https://user@JOBS.LEVER.CO:443/Acme?x=1#y"), (Vendor::Lever, Some("acme")));
    }

    #[test]
    fn unknown_hosts_and_lookalikes() {
        assert_eq!(parse("https://acme.com/careers"), Ats::UNKNOWN);
        assert_eq!(parse("https://notlever.co/acme"), Ats::UNKNOWN);
        assert_eq!(parse("https://rippling.com/careers").vendor, Vendor::Unknown);
        assert_eq!(parse(""), Ats::UNKNOWN);
        assert_eq!(parse("not a url"), Ats::UNKNOWN);
    }
}
