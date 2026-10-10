//! What an agent reads back when a call goes wrong, shaped like rustc's
//! diagnostics: a stable code, a one-line headline, the call echoed with
//! the offending argument pointed at, `note:`s saying why, and `help:`s
//! giving the corrected call to copy. Every code has a long form,
//! `hireme {"explain":"<code>"}`, as `rustc --explain` has. Diagnostics
//! are values; a caller builds one per refusal by matching on it.

use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Error,
    Warning,
}

#[derive(Clone, Debug)]
pub struct Diag {
    pub level: Level,
    pub code: &'static str,
    headline: String,
    call: Option<String>,
    mark: Option<(usize, usize, String)>,
    notes: Vec<String>,
    helps: Vec<String>,
}

impl Diag {
    pub fn error(code: &'static str, headline: impl Into<String>) -> Diag {
        Diag::new(Level::Error, code, headline)
    }

    pub fn warning(code: &'static str, headline: impl Into<String>) -> Diag {
        Diag::new(Level::Warning, code, headline)
    }

    fn new(level: Level, code: &'static str, headline: impl Into<String>) -> Diag {
        Diag {
            level,
            code,
            headline: headline.into(),
            call: None,
            mark: None,
            notes: vec![],
            helps: vec![],
        }
    }

    /// Echo the call as the agent made it.
    pub fn call(mut self, tool: &str, args: &Value) -> Diag {
        self.call = Some(format!("{tool} {args}"));
        self
    }

    /// Point at one argument's value in the echoed call.
    pub fn at(mut self, field: &str, label: impl Into<String>) -> Diag {
        let key = format!("\"{field}\":");
        self.mark = self.call.as_ref().and_then(|c| {
            let start = c.find(&key)? + key.len();
            let rest = &c[start..];
            let len = rest.find([',', '}']).unwrap_or(rest.len()).max(1);
            Some((start, len, label.into()))
        });
        self
    }

    pub fn note(mut self, note: impl Into<String>) -> Diag {
        self.notes.push(note.into());
        self
    }

    pub fn help(mut self, help: impl Into<String>) -> Diag {
        self.helps.push(help.into());
        self
    }

    pub fn render(&self) -> String {
        let level = match self.level {
            Level::Error => "error",
            Level::Warning => "warning",
        };
        let mut out = format!("{level}[{}]: {}\n", self.code, self.headline);
        if let Some(call) = &self.call {
            out += &format!("  |\n  | {call}\n");
            if let Some((at, len, label)) = &self.mark {
                out += &format!("  | {}{} {label}\n", " ".repeat(*at), "^".repeat(*len));
            }
            out += "  |\n";
        }
        for note in &self.notes {
            out += &format!("  = note: {}\n", indent(note));
        }
        for help in &self.helps {
            out += &format!("  = help: {}\n", indent(help));
        }
        out + &format!("  = explain: hireme {{\"explain\":\"{}\"}}", self.code)
    }
}

/// Continuation lines line up under the first.
fn indent(text: &str) -> String {
    text.replace('\n', "\n          ")
}

/// The long form of a code, for `hireme {"explain":"<code>"}`.
pub fn explain(code: &str) -> Option<&'static str> {
    Some(match code {
        "busy" => {
            "busy: the block you asked for overlaps another agent's.

A block is all or nothing. Entries 1..n are the account's applications in the order
they were added, and each agent holds at most one contiguous run of them. When any
entry of the range you named is already in another agent's block, nothing is
leased: the refusal names the held entries and, when one exists, the nearest free
block of the same size.

Fix: lease the free block the help line names, or ask by size and let the desk
pick: lease {\"count\":16}. Blocks come back when their agent releases them or its
session ends."
        }
        "empty" => {
            "empty: the range names no application.

Entries run 1..n, where n is the number of applications on the desk (hireme {}
shows n). A range wholly outside that has nothing to lease.

Fix: lease {\"count\":16}, or a range inside 1..n."
        }
        "held" => {
            "held: this agent already holds a block.

One session holds one block. To work elsewhere, give it back first: release {},
then lease the next one."
        }
        "truncated" => {
            "truncated (warning): the range ran past the desk and was clamped.

Entries run 1..n. The lease covers the part of your range that exists; the warning
says what you asked for and what you got. Nothing failed."
        }
        "size" => {
            "size (warning): the block's size is not a power of two.

Any size works, and the lease was granted as asked. Powers of two (8, 16, 32) tile
the desk evenly, so agents' blocks line up and the next free block is easy to name;
the help line shows the nearest one."
        }
        "align" => {
            "align (warning): a power-of-two block that does not start at 1 plus a multiple of its size.

Blocks are a buddy allocator's: a block of 16 starts at 1, 17, 33, ..., so two
neighbours make an aligned 32 and blocks merge back whole when released. A range
off its alignment is granted as asked; the help line names the aligned block that
holds its first entry. lease {\"count\":16} always gets an aligned block."
        }
        "count_capped" => {
            "count_capped (warning): you asked for more entries than the desk has.

The lease covers every free entry it could, up to n. Nothing failed."
        }
        "leased" => {
            "leased: the application is not in your block.

An agent writes only the applications its own block holds, and nobody else may
write them while it does. If the application is in another agent's block, wait for
that block to come back; if nobody holds it, lease a block that contains it.

Fix: block {} lists what you hold; lease {\"from\":e,\"to\":e+15} takes a block starting
at entry e."
        }
        "lineage_busy" => {
            "lineage_busy: another agent is editing this employer's CV.

Applications to one employer share one CV lineage. The first agent to write a CV
line for an employer claims that lineage until its block goes back; other agents can
still move those applications' stages, scores and next actions, just not their CV.

Fix: work on another application in your block, and come back later."
        }
        "cooldown" => {
            "cooldown: this CV generation is locked.

A CV generation can be rewritten for 90 days after it opens; after that only an
additive generation may be opened (open_cv_generation), which accepts new lines only.
The note carries the date the lock ends."
        }
        "heat" => {
            "heat: queueing this application would push its company or ATS past its cap.

Heat is the governor that keeps you from spraying one employer or one applicant
tracking system. can_apply {\"job_id\":J} shows the load, the cap and the cooldown.

Fix: pick a cooler application (recommend_applications {}), or wait out the cooldown."
        }
        "fire_hold" => {
            "fire_hold: the batch is on hold.

Nothing here submits an application. Moving into submission stages needs the batch
opened to fire on the desk itself; an agent cannot do that."
        }
        "not_additive" => {
            "not_additive: the open generation accepts new lines only.

After the 90-day window an additive generation is open: it can add lines but not
hide, alter or emphasize existing ones."
        }
        "argument" => {
            "argument: an argument is missing or not one the tool accepts.

The marked argument says which. The help line shows the call with a valid value; the
tool's blank call (for example set_stage {}) prints its full call shape."
        }
        "not_found" => {
            "not_found: the job, item or entry does not exist on this desk.

Ids are the desk's own: job ids from block {} or list_applications {}, item ids from
application {\"job_id\":J} (its cv.sections[].lines[].id)."
        }
        "batch" => "batch: the batch named does not exist or cannot take that change.",
        "invalid" => "invalid: the value did not pass validation, and nothing was saved.",
        "internal" => {
            "internal: the server failed while handling the call. Nothing was saved;
retrying the same call is safe."
        }
        "session" => {
            "session: hireme-mcp could not reach hireme.

The note says why: a refused HELLO (a wrong key, or a wire schema from another
commit: rebuild hireme-mcp), or the network. hireme {} shows the carrier."
        }
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // The exact shape agents read; changing it is a deliberate act.
    #[test]
    fn a_refusal_renders_like_rustc() {
        let d = Diag::error("busy", "entries 2..4 overlap another agent's block")
            .call("lease", &json!({"from": 2, "to": 4}))
            .at("from", "entry 3 is held by another agent")
            .note("a block is all or nothing: nothing was leased")
            .help("entries 4..6 are free:\nlease {\"from\":4,\"to\":6}");
        assert_eq!(
            d.render(),
            "error[busy]: entries 2..4 overlap another agent's block
  |
  | lease {\"from\":2,\"to\":4}
  |               ^ entry 3 is held by another agent
  |
  = note: a block is all or nothing: nothing was leased
  = help: entries 4..6 are free:
          lease {\"from\":4,\"to\":6}
  = explain: hireme {\"explain\":\"busy\"}"
        );
    }

    #[test]
    fn a_warning_without_a_call_is_a_headline_and_notes() {
        let d = Diag::warning("truncated", "entries 990..1010 truncated to 990..1000")
            .note("the desk has 1000 applications");
        assert_eq!(
            d.render(),
            "warning[truncated]: entries 990..1010 truncated to 990..1000
  = note: the desk has 1000 applications
  = explain: hireme {\"explain\":\"truncated\"}"
        );
    }

    #[test]
    fn every_code_a_diagnostic_names_has_a_long_form() {
        for code in [
            "busy",
            "empty",
            "held",
            "truncated",
            "count_capped",
            "size",
            "align",
            "leased",
            "lineage_busy",
            "cooldown",
            "heat",
            "fire_hold",
            "not_additive",
            "argument",
            "not_found",
            "batch",
            "invalid",
            "internal",
            "session",
        ] {
            assert!(explain(code).is_some_and(|t| t.starts_with(code)), "{code}");
        }
        assert!(explain("E0382").is_none());
    }
}
