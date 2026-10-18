//! The two side lanes: the gym (practice reps against a daily target)
//! and the net (observer runs, artifacts, posts, drafts).
//!
//! A gym day counts when it has at least one rep that was solved or
//! attempted; a `skip` is recorded but does not keep a streak. The streak
//! runs back from today, or from yesterday while today is still empty,
//! so it does not read as broken in the morning.

use alloc::collections::BTreeMap;

use crate::Day;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RepOutcome {
    Solved = 0,
    Attempt = 1,
    Skip = 2,
}

impl RepOutcome {
    pub fn from_u8(v: u8) -> Option<RepOutcome> {
        [RepOutcome::Solved, RepOutcome::Attempt, RepOutcome::Skip].get(v as usize).copied()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Gym {
    pub today: u32,
    pub streak: u32,
    /// Counted reps over the last seven days, today included.
    pub week: u32,
    pub target: Option<u32>,
    /// `week` over seven days of `target`; `None` without a target.
    pub pace: Option<f64>,
    /// Reps still owed today to meet the target.
    pub owed: Option<u32>,
}

/// The gym lane from `(done_on, outcome)` per rep.
pub fn gym(reps: impl IntoIterator<Item = (Day, RepOutcome)>, target: Option<u32>, today: Day) -> Gym {
    let mut by_day: BTreeMap<Day, u32> = BTreeMap::new();
    for (day, outcome) in reps {
        if outcome != RepOutcome::Skip && day <= today {
            *by_day.entry(day).or_insert(0) += 1;
        }
    }
    let on = |d: Day| by_day.get(&d).copied().unwrap_or(0);
    let mut day = if on(today) > 0 { today } else { today.saturating_sub(1) };
    let mut streak = 0;
    while on(day) > 0 {
        streak += 1;
        day = match day.checked_sub(1) {
            Some(d) => d,
            None => break,
        };
    }
    let week: u32 = by_day.range(today.saturating_sub(6)..=today).map(|(_, n)| n).sum();
    let target = target.filter(|t| *t > 0);
    Gym {
        today: on(today),
        streak,
        week,
        target,
        pace: target.map(|t| week as f64 / (7.0 * t as f64)),
        owed: target.map(|t| t.saturating_sub(on(today))),
    }
}

impl Gym {
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "today": self.today, "streak": self.streak, "week": self.week,
            "target": self.target, "pace": self.pace, "owed": self.owed,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum NetKind {
    Observer = 0,
    Artifact = 1,
    Post = 2,
    Draft = 3,
}

impl NetKind {
    pub const ALL: [NetKind; 4] = [NetKind::Observer, NetKind::Artifact, NetKind::Post, NetKind::Draft];

    pub fn from_u8(v: u8) -> Option<NetKind> {
        NetKind::ALL.get(v as usize).copied()
    }

    pub fn name(self) -> &'static str {
        match self {
            NetKind::Observer => "observer",
            NetKind::Artifact => "artifact",
            NetKind::Post => "post",
            NetKind::Draft => "draft",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Net {
    /// Entries per kind, in `NetKind::ALL` order.
    pub total: [u32; 4],
    /// Shipped in the last seven days, per kind.
    pub week: [u32; 4],
    /// Entries with no `shipped_on` yet.
    pub unshipped: u32,
}

/// The net lane from `(kind, shipped_on)` per entry.
pub fn net(entries: impl IntoIterator<Item = (NetKind, Option<Day>)>, today: Day) -> Net {
    let mut n = Net::default();
    for (kind, shipped) in entries {
        let k = kind as usize;
        n.total[k] += 1;
        match shipped {
            Some(d) if d <= today && d > today.saturating_sub(7) => n.week[k] += 1,
            Some(_) => {}
            None => n.unshipped += 1,
        }
    }
    n
}

impl Net {
    pub fn to_json(&self) -> serde_json::Value {
        let mut m = serde_json::Map::new();
        for k in NetKind::ALL {
            m.insert(k.name().into(), serde_json::json!({"total": self.total[k as usize], "week": self.week[k as usize]}));
        }
        m.insert("unshipped".into(), self.unshipped.into());
        serde_json::Value::Object(m)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use RepOutcome::*;

    #[test]
    fn streak_survives_the_morning_and_skips_do_not_count() {
        let t = 100;
        let reps = [(t - 1, Solved), (t - 2, Attempt), (t - 2, Solved), (t - 3, Skip), (t - 4, Solved)];
        let g = gym(reps, Some(2), t);
        assert_eq!((g.today, g.streak, g.week, g.owed), (0, 2, 4, Some(2)));
        assert!((g.pace.unwrap() - 4.0 / 14.0).abs() < 1e-12);
        let g = gym(reps.into_iter().chain([(t, Solved)]), None, t);
        assert_eq!((g.today, g.streak, g.pace, g.owed), (1, 3, None, None));
        assert_eq!(gym([(t - 2, Solved)], Some(0), t).streak, 0);
    }

    /// The week is the seven days ending today, never a calendar week:
    /// on Sunday 2026-10-18 it starts Monday the 12th, whatever weekday
    /// the day count's epoch fell on.
    #[test]
    fn the_week_is_the_last_seven_days() {
        let sunday = 740_272;
        let g = gym([(sunday, Solved), (sunday - 6, Solved), (sunday - 7, Solved)], None, sunday);
        assert_eq!((g.week, g.streak), (2, 1));
        let n = net([(NetKind::Post, Some(sunday - 6)), (NetKind::Post, Some(sunday - 7)), (NetKind::Draft, None)], sunday);
        assert_eq!((n.total, n.week, n.unshipped), ([0, 0, 2, 1], [0, 0, 1, 0], 1));
    }
}
