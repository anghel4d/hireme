//! What the heat governor reads off a company name and a role title:
//! the size tier (org breadth, not Life-EV), the department, and the
//! role family with seniority stripped.
//!
//! Size is breadth: a mega employer can take a few roles across
//! departments, a small shop takes one, maybe two after decay. The named
//! tiers are public company names; anything unnamed with a systems or
//! labs word in its name is `Mid`, everything else `Small`.

use crate::text;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Size {
    Mega,
    Large,
    Mid,
    Small,
}

impl Size {
    pub fn name(self) -> &'static str {
        match self {
            Size::Mega => "mega",
            Size::Large => "large",
            Size::Mid => "mid",
            Size::Small => "small",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Department {
    Infra,
    Research,
    Security,
    Data,
    Product,
    Eng,
    Other,
}

impl Department {
    pub fn name(self) -> &'static str {
        match self {
            Department::Infra => "infra",
            Department::Research => "research",
            Department::Security => "security",
            Department::Data => "data",
            Department::Product => "product",
            Department::Eng => "eng",
            Department::Other => "other",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Family {
    SoftwareEngineer,
    ResearchEngineer,
    ResearchScientist,
    Sre,
    DataEngineer,
    SecurityEngineer,
    Other,
}

impl Family {
    pub fn name(self) -> &'static str {
        match self {
            Family::SoftwareEngineer => "software_engineer",
            Family::ResearchEngineer => "research_engineer",
            Family::ResearchScientist => "research_scientist",
            Family::Sre => "sre",
            Family::DataEngineer => "data_engineer",
            Family::SecurityEngineer => "security_engineer",
            Family::Other => "other",
        }
    }
}

const MEGA: &[&str] = &["google", "alphabet", "amazon", "aws", "meta", "facebook", "nvidia", "microsoft"];
const LARGE: &[&str] = &[
    "apple", "netflix", "uber", "stripe", "databricks", "snowflake", "tesla", "adobe", "salesforce", "oracle",
    "linkedin", "snap", "pinterest", "shopify", "openai", "anthropic", "spacex", "neuralink", "xai", "starfish",
    "valve", "gdm", "deepmind", "ssi", "mira",
];
const MID: &[&str] = &["systems", "runtime", "infra", "lab", "labs"];

/// The size tier of a company by name. Any word of the name, or the name
/// with its spaces removed ("Deep Mind" → "deepmind"), can name a tier.
pub fn size(company: &str) -> Size {
    let n = text::normalize(company);
    let compact: alloc::string::String = n.chars().filter(|c| *c != ' ').collect();
    let named = |set: &[&str]| set.contains(&compact.as_str()) || text::words(&n).any(|w| set.contains(&w));
    if named(MEGA) {
        Size::Mega
    } else if named(LARGE) {
        Size::Large
    } else if text::any_word(&n, MID) {
        Size::Mid
    } else {
        Size::Small
    }
}

/// The key two company names are the same company under: normalized.
pub fn company_key(company: &str) -> alloc::string::String {
    text::normalize(company)
}

/// The department a role title points at, first match wins.
pub fn department(role: &str) -> Department {
    let n = text::normalize(role);
    if text::any_start(&n, &["research", "scientist", "machine learning", "applied sci"]) || text::word(&n, "ml") {
        Department::Research
    } else if text::any_start(&n, &["sre", "site reliability", "infra", "platform", "runtime", "kernel", "systems"]) {
        Department::Infra
    } else if text::any_start(&n, &["security", "privacy"]) {
        Department::Security
    } else if text::any_start(&n, &["data engineer", "analytics", "data platform"]) {
        Department::Data
    } else if text::any_start(&n, &["frontend", "front end", "ios", "android", "mobile", "product engineer"]) {
        Department::Product
    } else if text::any_start(&n, &["engineer", "developer", "swe"]) {
        Department::Eng
    } else {
        Department::Other
    }
}

const SENIORITY: &[&str] = &[
    "staff", "senior", "sr", "principal", "distinguished", "fellow", "junior", "jr", "intern", "iii", "ii", "i",
    "l3", "l4", "l5", "l6", "l7", "l8", "lead",
];

/// The role family of a title once seniority words are stripped, so
/// "Senior Software Engineer" and "Staff Software Engineer" are clones.
pub fn family(role: &str) -> Family {
    let n = text::normalize(role);
    let mut core = alloc::string::String::with_capacity(n.len());
    for w in text::words(&n).filter(|w| !SENIORITY.contains(w)) {
        if !core.is_empty() {
            core.push(' ');
        }
        core.push_str(w);
    }
    let n = core;
    if text::any_start(&n, &["research scientist", "applied scientist"]) {
        Family::ResearchScientist
    } else if text::starts(&n, "research engineer") {
        Family::ResearchEngineer
    } else if text::any_word(&n, &["site reliability", "sre"]) {
        Family::Sre
    } else if text::starts(&n, "data engineer") {
        Family::DataEngineer
    } else if text::starts(&n, "security engineer") {
        Family::SecurityEngineer
    } else if text::any_word(&n, &["software engineer", "swe", "engineer", "developer"]) {
        Family::SoftwareEngineer
    } else {
        Family::Other
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes() {
        assert_eq!(size("Google DeepMind"), Size::Mega);
        assert_eq!(size("Deep Mind"), Size::Large);
        assert_eq!(size("Anthropic"), Size::Large);
        assert_eq!(size("Acme Systems"), Size::Mid);
        assert_eq!(size("Acme"), Size::Small);
        assert_eq!(size(""), Size::Small);
    }

    #[test]
    fn departments_and_families() {
        assert_eq!(department("Research Engineer, Interpretability"), Department::Research);
        assert_eq!(department("Infrastructure Engineer"), Department::Infra);
        assert_eq!(department("iOS Engineer"), Department::Product);
        assert_eq!(department("Software Engineer"), Department::Eng);
        assert_eq!(department("Recruiter"), Department::Other);
        assert_eq!(family("Senior Software Engineer"), family("Staff Software Engineer, L6"));
        assert_eq!(family("Sr. Research Scientist"), Family::ResearchScientist);
        assert_eq!(family("SRE II"), Family::Sre);
        assert_eq!(family("Account Executive"), Family::Other);
    }
}
