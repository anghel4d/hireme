//! The battleplan: ten stages, the rail of pips one application carries
//! through them, the moves the desk allows, and FIRE HOLD.
//!
//! The `stage` command never submits. `open_fire` is named by a human
//! through its own command (the schema declares it `human_only`), and a
//! move to `submitted` records a submission the operator made by hand, so
//! it is reachable only from `open_fire`: an application a human has opened
//! fire on. The other way out is a mission's shot landing under a fire key
//! the operator made (`fire`), which moves its application to `submitted`
//! from fire_ready or open_fire.
//!
//! A rail is one pip per stage in stage order, stored as ten characters
//! (`D` done, `A` active, `P` pending, `S` skipped, `B` blocked) in
//! `applications.pips`. `encode` and `decode` are inverse on every
//! well-formed rail.

/// Stages in declaration order; the discriminant is the schema's enum
/// value, checked against `schema/hireme.schema` by a test.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Stage {
    Discovered = 0,
    Freshness = 1,
    Gated = 2,
    InBatch = 3,
    DraftReady = 4,
    FireReady = 5,
    OpenFire = 6,
    Submitted = 7,
    Reply = 8,
    Closed = 9,
}

pub const STAGES: [Stage; 10] = [
    Stage::Discovered,
    Stage::Freshness,
    Stage::Gated,
    Stage::InBatch,
    Stage::DraftReady,
    Stage::FireReady,
    Stage::OpenFire,
    Stage::Submitted,
    Stage::Reply,
    Stage::Closed,
];

/// Each stage's name (the schema's), label and hint, in stage order.
const STAGE_TEXT: [(&str, &str, &str); 10] = [
    ("discovered", "Discovered", "Listing captured"),
    ("freshness", "Freshness", "Open, thin, closed, or blocked"),
    ("gated", "Gated", "Pursue, maybe, or skip"),
    ("in_batch", "In batch", "Named batch"),
    ("draft_ready", "Draft ready", "Tailored CV drafted"),
    ("fire_ready", "Fire ready", "Packed. Submit stays locked."),
    ("open_fire", "Open fire", "Batch named. Submit is allowed."),
    ("submitted", "Submitted", "Sent by hand. This desk does not submit."),
    ("reply", "Reply", "Reply or interview"),
    ("closed", "Closed", "Done"),
];

impl Stage {
    /// From a row's `stage` cell or a param.
    pub fn from_u32(v: u32) -> Option<Stage> {
        STAGES.get(v as usize).copied()
    }

    pub fn parse(name: &str) -> Option<Stage> {
        STAGES.iter().copied().find(|s| s.name() == name)
    }

    pub fn name(self) -> &'static str {
        STAGE_TEXT[self as usize].0
    }

    pub fn label(self) -> &'static str {
        STAGE_TEXT[self as usize].1
    }

    pub fn hint(self) -> &'static str {
        STAGE_TEXT[self as usize].2
    }

    pub fn index(self) -> usize {
        self as usize
    }

    /// The submit queue: entering it from a cold stage is what the heat
    /// governor judges.
    pub fn queued(self) -> bool {
        matches!(self, Stage::FireReady | Stage::OpenFire | Stage::Submitted)
    }

    /// Stages that need the application to be in a batch.
    pub fn batched(self) -> bool {
        matches!(self, Stage::InBatch | Stage::DraftReady | Stage::FireReady | Stage::OpenFire | Stage::Submitted)
    }

    /// FIRE HOLD: stages a human must open.
    pub fn fire_locked(self) -> bool {
        matches!(self, Stage::OpenFire | Stage::Submitted)
    }

    /// The stages an application stands on once sent.
    pub fn after_send(self) -> bool {
        self >= Stage::Submitted
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pip {
    Done,
    Active,
    Pending,
    Skipped,
    Blocked,
}

/// Each pip's stored character and name, in `Pip` order.
const PIPS: [(Pip, u8, &str); 5] =
    [(Pip::Done, b'D', "done"), (Pip::Active, b'A', "active"), (Pip::Pending, b'P', "pending"), (Pip::Skipped, b'S', "skipped"), (Pip::Blocked, b'B', "blocked")];

impl Pip {
    pub fn from_char(c: u8) -> Option<Pip> {
        PIPS.iter().find(|p| p.1 == c).map(|p| p.0)
    }

    pub fn name(self) -> &'static str {
        PIPS[self as usize].2
    }
}

/// One pip per stage, in stage order.
pub type Rail = [Pip; 10];

/// A fresh rail with `active` active: everything before it done.
pub fn initial(active: Stage) -> Rail {
    let a = active.index();
    core::array::from_fn(|i| match i.cmp(&a) {
        core::cmp::Ordering::Less => Pip::Done,
        core::cmp::Ordering::Equal => Pip::Active,
        core::cmp::Ordering::Greater => Pip::Pending,
    })
}

/// The rail after a move to `to`. Skipped and blocked rungs keep their
/// mark (they record a decision, not progress). A forward jump marks the
/// rungs it passes over without visiting them as skipped, so closing a
/// gated application does not claim it was ever submitted; rungs up to
/// where it stood are done, rungs after `to` pending.
pub fn move_to(rail: &Rail, to: Stage) -> Rail {
    let t = to.index();
    let from = current(rail).index();
    core::array::from_fn(|i| {
        if i == t {
            Pip::Active
        } else if matches!(rail[i], Pip::Skipped | Pip::Blocked) {
            rail[i]
        } else if i < t && i > from && rail[i] == Pip::Pending {
            Pip::Skipped
        } else if i < t {
            Pip::Done
        } else {
            Pip::Pending
        }
    })
}

/// The stage a rail stands on: its active rung, else its first pending,
/// else the last.
pub fn current(rail: &Rail) -> Stage {
    let at = rail
        .iter()
        .position(|p| *p == Pip::Active)
        .or_else(|| rail.iter().position(|p| *p == Pip::Pending))
        .unwrap_or(9);
    STAGES[at]
}

pub fn encode(rail: &Rail) -> [u8; 10] {
    rail.map(|p| PIPS[p as usize].1)
}

/// A rail from its ten characters; anything else is `None`.
pub fn decode(pips: &str) -> Option<Rail> {
    let b: [u8; 10] = pips.as_bytes().try_into().ok()?;
    let mut rail = [Pip::Pending; 10];
    for (slot, c) in rail.iter_mut().zip(b) {
        *slot = Pip::from_char(c)?;
    }
    Some(rail)
}

/// The rail of a row whose stored pips do not agree with its stage: the
/// stage's fresh rail, where a reply or a close keeps the `submitted` and
/// `reply` rungs only if the row's dates say they happened (an outreach is
/// answered unsubmitted; a listing may close unsent).
pub fn rail_by_dates(stage: Stage, applied: bool, replied: bool) -> Rail {
    let mut rail = initial(stage);
    if stage >= Stage::Reply && !applied {
        rail[Stage::Submitted.index()] = Pip::Skipped;
    }
    if stage == Stage::Closed && !replied {
        rail[Stage::Reply.index()] = Pip::Skipped;
    }
    rail
}

/// Whether the rail records that something went out: its `submitted` or
/// `reply` rung was reached, not jumped over (an outreach application is
/// answered without a submission). Closing a listing that died before
/// anything went out leaves both skipped.
pub fn sent(rail: &Rail) -> bool {
    [Stage::Submitted, Stage::Reply].iter().any(|s| matches!(rail[s.index()], Pip::Done | Pip::Active))
}

/// Whether the rail records a submission: its `submitted` rung was reached.
/// The scoreboard counts these; an outreach answered without one is `sent`
/// (heat counts it) but not submitted.
pub fn submitted(rail: &Rail) -> bool {
    matches!(rail[Stage::Submitted.index()], Pip::Done | Pip::Active)
}

/// What a move is judged against, besides the two stages.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    pub has_batch: bool,
    /// Whether it ever went out ([`sent`]).
    pub sent: bool,
    /// Whether it goes through a person rather than a listing: a channel
    /// other than `listing` (referral, recruiter, cold, inbound, other),
    /// where a reply needs no submission.
    pub outreach: bool,
}

/// Why a stage move is refused, before heat (which `heat` judges).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The target stage needs a batch and the application has none.
    NeedsBatch,
    /// `open_fire` is named only by its human command.
    OpenFireByCommand,
    /// `submitted` needs the batch opened by a human first.
    FireHold,
    /// Once sent, an application cannot go back to a pre-send stage.
    Sent,
    /// A reply to a listing application needs it sent first.
    NotSent,
}

impl Refusal {
    pub fn name(self) -> &'static str {
        ["needs_batch", "open_fire_by_command", "fire_hold", "sent", "not_sent"][self as usize]
    }
}

/// Whether the `stage` command may move an application `from` → `to`. A
/// move to the stage it is on is allowed and changes nothing.
pub fn check(from: Stage, to: Stage, f: Facts) -> Result<(), Refusal> {
    let Facts { has_batch, sent, outreach } = f;
    if from == to {
        return Ok(());
    }
    if sent && !to.after_send() {
        return Err(Refusal::Sent);
    }
    if to == Stage::Reply && !sent && !outreach {
        return Err(Refusal::NotSent);
    }
    if to == Stage::OpenFire {
        return Err(Refusal::OpenFireByCommand);
    }
    if to.batched() && !has_batch {
        return Err(Refusal::NeedsBatch);
    }
    // Only the human's open_fire reaches open_fire, and only from there is
    // anything recorded as submitted: no flag on a batch an agent can
    // join opens the way.
    if to == Stage::Submitted && from != Stage::OpenFire {
        return Err(Refusal::FireHold);
    }
    Ok(())
}

/// Whether `open_fire` (the human's command on one application) moves it
/// from `from`: only a `fire_ready` application goes to `open_fire`.
pub fn opens(from: Stage) -> bool {
    from == Stage::FireReady
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rails_round_trip_and_stand_on_their_stage() {
        for s in STAGES {
            let r = initial(s);
            let e = encode(&r);
            let back = decode(core::str::from_utf8(&e).unwrap()).unwrap();
            assert_eq!(back, r);
            assert_eq!(current(&r), s);
        }
        assert_eq!(&encode(&initial(Stage::Gated)), b"DDAPPPPPPP");
        assert!(decode("DDAPPPPPP").is_none());
        assert!(decode("DDAPPPPPPX").is_none());
    }

    #[test]
    fn move_keeps_decisions() {
        let mut r = initial(Stage::Discovered);
        r[1] = Pip::Skipped;
        // Landing on a skipped rung makes it active.
        let r = move_to(&r, Stage::Freshness);
        assert_eq!(&encode(&r), b"DAPPPPPPPP");
        let r = move_to(&initial(Stage::Gated), Stage::DraftReady);
        assert_eq!(&encode(&r), b"DDDSAPPPPP");
        let r = move_to(&r, Stage::Gated);
        assert_eq!(&encode(&r), b"DDASPPPPPP");
        // Step by step, nothing is skipped.
        let r = move_to(&move_to(&initial(Stage::Gated), Stage::InBatch), Stage::DraftReady);
        assert_eq!(&encode(&r), b"DDDDAPPPPP");
    }

    #[test]
    fn fire_hold_and_batches() {
        use Refusal::*;
        assert_eq!(check(Stage::Gated, Stage::InBatch, Facts { has_batch: false, sent: false, outreach: false }), Err(NeedsBatch));
        assert_eq!(check(Stage::Gated, Stage::InBatch, Facts { has_batch: true, sent: false, outreach: false }), Ok(()));
        assert_eq!(check(Stage::FireReady, Stage::OpenFire, Facts { has_batch: true, sent: false, outreach: false }), Err(OpenFireByCommand));
        assert_eq!(check(Stage::FireReady, Stage::Submitted, Facts { has_batch: true, sent: false, outreach: false }), Err(FireHold));
        assert_eq!(check(Stage::OpenFire, Stage::Submitted, Facts { has_batch: true, sent: false, outreach: false }), Ok(()));
        // A batch already fired opens nothing for an application that
        // joins it: submitted is reached through open_fire only.
        for from in [Stage::Discovered, Stage::Gated, Stage::InBatch, Stage::DraftReady, Stage::FireReady, Stage::Reply, Stage::Closed] {
            assert_eq!(check(from, Stage::Submitted, Facts { has_batch: true, sent: false, outreach: false }), Err(FireHold), "{from:?}");
        }
        assert_eq!(check(Stage::Submitted, Stage::Gated, Facts { has_batch: true, sent: true, outreach: false }), Err(Sent));
        assert_eq!(check(Stage::Submitted, Stage::Closed, Facts { has_batch: true, sent: true, outreach: false }), Ok(()));
        assert_eq!(check(Stage::Discovered, Stage::Closed, Facts { has_batch: false, sent: false, outreach: false }), Ok(()));
        assert_eq!(check(Stage::Reply, Stage::Reply, Facts { has_batch: false, sent: true, outreach: false }), Ok(()));
        assert_eq!(check(Stage::FireReady, Stage::Reply, Facts { has_batch: true, sent: false, outreach: false }), Err(NotSent));
        // Cold outreach and referrals get replies without a submission.
        assert_eq!(check(Stage::Discovered, Stage::Reply, Facts { has_batch: false, sent: false, outreach: true }), Ok(()));
        // A listing closed before anything went out can be reopened.
        let closed = move_to(&initial(Stage::Gated), Stage::Closed);
        assert!(!sent(&closed));
        assert_eq!(check(Stage::Closed, Stage::Gated, Facts { has_batch: false, sent: sent(&closed), outreach: false }), Ok(()));
        assert!(sent(&move_to(&initial(Stage::Submitted), Stage::Closed)));
    }
}
