//! What the heat governor reads off a company name and a role title:
//! the size tier (org breadth, not Life-EV), the department, and the
//! role family with seniority stripped. Every reader takes the text
//! normalized (`text::normalize`).
//!
//! Size is breadth: a mega employer can take a few roles across
//! departments, a small shop takes one, maybe two after decay. The named
//! tiers are public company names; anything unnamed with a systems or
//! labs word in its name is `Mid`, everything else `Small`.

use crate::lexicon::{self, Hits};

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

/// The size tier of a company by its normalized name. Any word of the
/// name, or the name with its spaces removed ("Deep Mind" → "deepmind"),
/// can name a tier.
pub fn size(n: &str) -> Size {
    Size::of_hits(Hits::of(n))
}

/// The department a normalized role title points at, first match wins.
pub fn department(n: &str) -> Department {
    Department::of_hits(Hits::of(n))
}

/// The role family of a normalized title once seniority words are
/// stripped, so "Senior Software Engineer" and "Staff Software Engineer"
/// are clones.
pub fn family(n: &str) -> Family {
    Family::of_hits(Hits::family(n))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::normalize as n;

    #[test]
    fn sizes() {
        assert_eq!(size(&n("Google DeepMind")), Size::Mega);
        assert_eq!(size(&n("Deep Mind")), Size::Large);
        assert_eq!(size(&n("Anthropic")), Size::Large);
        assert_eq!(size(&n("Acme Systems")), Size::Mid);
        assert_eq!(size(&n("Acme")), Size::Small);
        assert_eq!(size(""), Size::Small);
    }

    #[test]
    fn departments_and_families() {
        assert_eq!(department(&n("Research Engineer, Interpretability")), Department::Research);
        assert_eq!(department(&n("Infrastructure Engineer")), Department::Infra);
        assert_eq!(department(&n("iOS Engineer")), Department::Product);
        assert_eq!(department(&n("Software Engineer")), Department::Eng);
        assert_eq!(department(&n("Recruiter")), Department::Other);
        assert_eq!(family(&n("Senior Software Engineer")), family(&n("Staff Software Engineer, L6")));
        assert_eq!(family(&n("Sr. Research Scientist")), Family::ResearchScientist);
        assert_eq!(family(&n("SRE II")), Family::Sre);
        assert_eq!(family(&n("Account Executive")), Family::Other);
        assert_eq!(family(&n("Engineering Manager")), Family::SoftwareEngineer);
        assert_eq!(family(&n("Senior Engineers")), Family::SoftwareEngineer);
        assert_eq!(department(&n("Swedish Teacher")), Department::Other);
    }
}
