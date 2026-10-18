//! What the heat governor reads off a company name and a role title:
//! the size tier (org breadth, not Life-EV), the department, and the
//! role family with seniority stripped.
//!
//! Size is breadth: a mega employer can take a few roles across
//! departments, a small shop takes one, maybe two after decay. The named
//! tiers are public company names; anything unnamed with a systems or
//! labs word in its name is `Mid`, everything else `Small`.

use crate::lexicon::{self, Hits};
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

/// `Other` stays the last variant: the governor sizes its counts by it.
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

/// `Other` stays the last variant: the governor sizes its counts by it.
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

/// The size tier of a company by name. Any word of the name, or the name
/// with its spaces removed ("Deep Mind" → "deepmind"), can name a tier.
pub fn size(company: &str) -> Size {
    size_normalized(&text::normalize(company))
}

/// [`size`] of an already normalized name.
pub fn size_normalized(n: &str) -> Size {
    Size::of_hits(Hits::of(n))
}

impl Size {
    /// The size tier from a name's [`Hits`].
    pub fn of_hits(h: Hits) -> Size {
        if h.has(lexicon::MEGA) {
            Size::Mega
        } else if h.has(lexicon::LARGE) {
            Size::Large
        } else if h.has(lexicon::MID) {
            Size::Mid
        } else {
            Size::Small
        }
    }
}

pub fn company_key(company: &str) -> alloc::string::String {
    text::normalize(company)
}

/// The department a role title points at, first match wins.
pub fn department(role: &str) -> Department {
    department_normalized(&text::normalize(role))
}

/// [`department`] of an already normalized title.
pub fn department_normalized(n: &str) -> Department {
    Department::of_hits(Hits::of(n))
}

impl Department {
    /// The department from a title's [`Hits`], first match wins.
    pub fn of_hits(h: Hits) -> Department {
        [
            (lexicon::DEPT_RESEARCH, Department::Research),
            (lexicon::DEPT_INFRA, Department::Infra),
            (lexicon::DEPT_SECURITY, Department::Security),
            (lexicon::DEPT_DATA, Department::Data),
            (lexicon::DEPT_PRODUCT, Department::Product),
            (lexicon::DEPT_ENG, Department::Eng),
        ]
        .into_iter()
        .find(|(g, _)| h.has(*g))
        .map_or(Department::Other, |(_, d)| d)
    }
}

/// The role family of a title once seniority words are stripped, so
/// "Senior Software Engineer" and "Staff Software Engineer" are clones.
pub fn family(role: &str) -> Family {
    family_normalized(&text::normalize(role))
}

/// [`family`] of an already normalized title.
pub fn family_normalized(n: &str) -> Family {
    Family::of_hits(Hits::family(n))
}

impl Family {
    /// The family from a title's family [`Hits`], first match wins.
    pub fn of_hits(h: Hits) -> Family {
        [
            (lexicon::FAM_RESEARCH_SCIENTIST, Family::ResearchScientist),
            (lexicon::FAM_RESEARCH_ENGINEER, Family::ResearchEngineer),
            (lexicon::FAM_SRE, Family::Sre),
            (lexicon::FAM_DATA_ENGINEER, Family::DataEngineer),
            (lexicon::FAM_SECURITY_ENGINEER, Family::SecurityEngineer),
            (lexicon::FAM_SOFTWARE_ENGINEER, Family::SoftwareEngineer),
        ]
        .into_iter()
        .find(|(g, _)| h.has(*g))
        .map_or(Family::Other, |(_, f)| f)
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
        assert_eq!(family("Engineering Manager"), Family::SoftwareEngineer);
        assert_eq!(family("Senior Engineers"), Family::SoftwareEngineer);
        assert_eq!(department("Swedish Teacher"), Department::Other);
    }
}
