//! The battleplan: ten stages, the rail of pips one application carries
//! through them, the moves the desk allows, and FIRE HOLD.
//!
//! The desk never submits. `open_fire` is named by a human through its
//! own command (the schema declares it `human_only`), and `submitted`
//! records a submission the operator made by hand, so it is reachable
//! only from a batch that a human has opened fire on.
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

impl Stage {
    pub fn from_u8(v: u8) -> Option<Stage> {
        STAGES.get(v as usize).copied()
    }

    pub fn parse(name: &str) -> Option<Stage> {
        STAGES.iter().copied().find(|s| s.name() == name)
    }

    pub fn name(self) -> &'static str {
        match self {
            Stage::Discovered => "discovered",
            Stage::Freshness => "freshness",
            Stage::Gated => "gated",
            Stage::InBatch => "in_batch",
            Stage::DraftReady => "draft_ready",
            Stage::FireReady => "fire_ready",
            Stage::OpenFire => "open_fire",
            Stage::Submitted => "submitted",
            Stage::Reply => "reply",
            Stage::Closed => "closed",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Stage::Discovered => "Discovered",
            Stage::Freshness => "Freshness",
            Stage::Gated => "Gated",
            Stage::InBatch => "In batch",
            Stage::DraftReady => "Draft ready",
            Stage::FireReady => "Fire ready",
            Stage::OpenFire => "Open fire",
            Stage::Submitted => "Submitted",
            Stage::Reply => "Reply",
            Stage::Closed => "Closed",
        }
    }

    pub fn hint(self) -> &'static str {
        match self {
            Stage::Discovered => "Listing captured",
            Stage::Freshness => "Open, thin, closed, or blocked",
            Stage::Gated => "Pursue, maybe, or skip",
            Stage::InBatch => "Named batch",
            Stage::DraftReady => "Tailored CV drafted",
            Stage::FireReady => "Packed. Submit stays locked.",
            Stage::OpenFire => "Batch named. Submit is allowed.",
            Stage::Submitted => "Sent by hand. This desk does not submit.",
            Stage::Reply => "Reply or interview",
            Stage::Closed => "Done",
        }
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

impl Pip {
    pub fn char(self) -> char {
        match self {
            Pip::Done => 'D',
            Pip::Active => 'A',
            Pip::Pending => 'P',
            Pip::Skipped => 'S',
            Pip::Blocked => 'B',
        }
    }

    pub fn from_char(c: char) -> Option<Pip> {
        Some(match c {
            'D' => Pip::Done,
            'A' => Pip::Active,
            'P' => Pip::Pending,
            'S' => Pip::Skipped,
            'B' => Pip::Blocked,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Pip::Done => "done",
            Pip::Active => "active",
            Pip::Pending => "pending",
            Pip::Skipped => "skipped",
            Pip::Blocked => "blocked",
        }
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
    rail.map(|p| p.char() as u8)
}

/// A rail from its ten characters; anything else is `None`.
pub fn decode(pips: &str) -> Option<Rail> {
    let b = pips.as_bytes();
    if b.len() != 10 {
        return None;
    }
    let mut rail = [Pip::Pending; 10];
    for (slot, &c) in rail.iter_mut().zip(b) {
        *slot = Pip::from_char(c as char)?;
    }
    Some(rail)
}

/// The rail an application shows: its stored pips when they parse and
/// agree with its stage, otherwise the fresh rail for its stage.
pub fn rail_of(stage: Stage, pips: Option<&str>) -> Rail {
    match pips.and_then(decode) {
        Some(rail) if current(&rail) == stage => rail,
        _ => initial(stage),
    }
}

/// Whether the rail records that something went out: its `submitted` or
/// `reply` rung was reached, not jumped over (an outreach application is
/// answered without a submission). Closing a listing that died before
/// anything went out leaves both skipped.
pub fn sent(rail: &Rail) -> bool {
    [Stage::Submitted, Stage::Reply].iter().any(|s| matches!(rail[s.index()], Pip::Done | Pip::Active))
}

/// What a move is judged against, besides the two stages.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    pub has_batch: bool,
    /// The batch's `fire` flag (false with no batch).
    pub batch_fire: bool,
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
        match self {
            Refusal::NeedsBatch => "needs_batch",
            Refusal::OpenFireByCommand => "open_fire_by_command",
            Refusal::FireHold => "fire_hold",
            Refusal::Sent => "sent",
            Refusal::NotSent => "not_sent",
        }
    }
}

/// Whether the `stage` command may move an application `from` → `to`. A
/// move to the stage it is on is allowed and changes nothing.
pub fn check(from: Stage, to: Stage, f: Facts) -> Result<(), Refusal> {
    let Facts { has_batch, batch_fire, sent, outreach } = f;
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
    if to == Stage::Submitted && !(batch_fire || from == Stage::OpenFire) {
        return Err(Refusal::FireHold);
    }
    Ok(())
}

/// Whether `open_fire` (the human's command on a batch) moves a member
/// at `from`: members packed and ready go to `open_fire`; the rest stay.
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
        assert_eq!(check(Stage::Gated, Stage::InBatch, Facts { has_batch: false, batch_fire: false, sent: false, outreach: false }), Err(NeedsBatch));
        assert_eq!(check(Stage::Gated, Stage::InBatch, Facts { has_batch: true, batch_fire: false, sent: false, outreach: false }), Ok(()));
        assert_eq!(check(Stage::FireReady, Stage::OpenFire, Facts { has_batch: true, batch_fire: true, sent: false, outreach: false }), Err(OpenFireByCommand));
        assert_eq!(check(Stage::FireReady, Stage::Submitted, Facts { has_batch: true, batch_fire: false, sent: false, outreach: false }), Err(FireHold));
        assert_eq!(check(Stage::OpenFire, Stage::Submitted, Facts { has_batch: true, batch_fire: false, sent: false, outreach: false }), Ok(()));
        assert_eq!(check(Stage::Submitted, Stage::Gated, Facts { has_batch: true, batch_fire: true, sent: true, outreach: false }), Err(Sent));
        assert_eq!(check(Stage::Submitted, Stage::Closed, Facts { has_batch: true, batch_fire: true, sent: true, outreach: false }), Ok(()));
        assert_eq!(check(Stage::Discovered, Stage::Closed, Facts { has_batch: false, batch_fire: false, sent: false, outreach: false }), Ok(()));
        assert_eq!(check(Stage::Reply, Stage::Reply, Facts { has_batch: false, batch_fire: false, sent: true, outreach: false }), Ok(()));
        assert_eq!(check(Stage::FireReady, Stage::Reply, Facts { has_batch: true, batch_fire: false, sent: false, outreach: false }), Err(NotSent));
        // Cold outreach and referrals get replies without a submission.
        assert_eq!(check(Stage::Discovered, Stage::Reply, Facts { has_batch: false, batch_fire: false, sent: false, outreach: true }), Ok(()));
        // A listing closed before anything went out can be reopened.
        let closed = move_to(&initial(Stage::Gated), Stage::Closed);
        assert!(!sent(&closed));
        assert_eq!(check(Stage::Closed, Stage::Gated, Facts { has_batch: false, batch_fire: false, sent: sent(&closed), outreach: false }), Ok(()));
        assert!(sent(&move_to(&initial(Stage::Submitted), Stage::Closed)));
    }
}
