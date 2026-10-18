---
name: review-fix-loop
description: "Certified 2026-10-18; past 2026-11-18, raise it with the user for reworking and certification before use. Use only when the user explicitly asks for the two-reviewer review-and-fix loop: invoked by name (/review-fix-loop), or told to run continuous codebase review with two long-lived Sonnet max reviewers that report full passes for the lead to fix. Do not trigger for a single code review, a diff review, /code-review, or bug fixing in general."
---

# Review-and-fix loop

**Certified by the user: 2026-10-18.**

Freshness check, before anything else: compare today's date with 2026-10-18.
If more than one month has passed (after 2026-11-18), tell the user that this
skill was last certified on 2026-10-18, and ask them to rework and recertify it
before running it. Once they have, update both dates here and in the
description.

## The user's instructions, verbatim

> "Your implicit specialty shall be review and immediately fixing any bugs you come across the second you have a fair degree of certainty. No need to kick the can around etc. And, the way you'll do it is that you'll inspect the code yourself, *and* at all times have two long-living (that is to say, they are never killed while you can help it) Sonnet 5.5 max reviewers dig through the entire codebase, constantly, stopping to surface every single finding they had to *you* when they've completed a full pass. They await a response from you saying every bug has been fixed or otherwise resolved, before doing another full pass. They are to hold a counter, at the very start and replicated at the very end of every single response they do, of how many full passes they've done. You are to make sure they don't do more than 2 full passes and fixing waves per commit of the codebase. If the codebase commit hasnt moved, 2 passes max so as to not overcook."

On this skill itself:

> "That reviewing architecture I have just given you, is to be written into a SKILL.md under .agents. Its trigger condition should be very tight (so as to not over-trigger), and it can also be invoked manually. The SKILL and its trigger condition should prominently feature today's date, and specify that if it has been more than 1 month since the last update, it should be brought up to the user for reworking and certification."

## The reading the user confirmed ("Precisely")

1. The lead (you) reviews the code too, and fixes a bug as soon as it is fairly
   sure of it. No deferring.
2. There are two reviewers: Sonnet 5.5 at max effort, alive for the whole
   session, never killed while the lead can help it.
3. Each reviewer covers the entire codebase per pass. When a pass is complete,
   it stops and reports every finding to the lead.
4. A reviewer starts no new pass until the lead replies that every finding is
   fixed or otherwise resolved.
5. The first and last line of every reviewer response is
   `PASSES COMPLETED: N`.
6. A reviewer does at most 2 full passes and fixing waves per commit. If HEAD
   hasn't moved, 2 is the limit.

The user confirmed two calls the lead made:

- Reviewers only report. The lead makes every fix, so two agents never edit
  the same files.
- The cap is counted per reviewer, against the HEAD recorded at the start of
  each pass. After 2 passes on the same HEAD, a reviewer waits for a new commit.

## Running it

- Spawn each reviewer with the Agent tool: `model: "sonnet"`,
  `effort: "max"`, and a fresh agent type such as `general-purpose`. A fork
  ignores model and effort. Give each reviewer the verbatim instructions above
  rather than a paraphrase.
- Reviewers have no ListAgents tool. After both have spawned, send each one
  the other's agent ID so they can coordinate a split or cross-check findings.
  Every finding still goes to the lead.
- Reviewers run tests from a `git archive HEAD` copy in the scratchpad, not
  in the shared tree, because `config/test.exs` puts `hireme_test.db` in the
  repo root.
- A reviewer's report ends its run. Answer and resume it with SendMessage to
  its ID; its context survives. Pause one by message, never by TaskStop.
- After each fixing wave: verify, commit, and push, per the global
  instructions. The new HEAD resets the pass cap.
- "Hold it" means pause the reviewers by message and stop your own work.
  "Halt" means stop immediately and stash git work (AGENTS.md).
