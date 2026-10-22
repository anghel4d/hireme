# Missions, fire keys and the outreach hub (with the Gmail passthrough)

Brief for the team, 2026-10-22. The operator's words, verbatim, in order:

> All right. The time has come to prime job apps to be sent out... Wow. So, how exactly does outreach work? How *is* it going to work? Can we add a way to link one's own email or gmail so its a passthrough, such that you can use it to send/receive emails directly in hireme, but also if I receive any replies to my job applications it'll show up in my gmail inbox?

> We can do 1 2 *and* 3 right now. Per application reply addresses, ehh. Damn how do we do this? Is it normal to have nongmail addresses? I think matei+a123 and stuff like that might get filtered out by ATS and stuff. Let's thin.

> Let's do it. **1 2 and 3** all together. Build the feature out with all your helpers here in herdr, subdividing the task however is needed.

> And the hireme inbox can just do lexiomatic parsing over the incoming emails to try to correlate them to what thread and task they're supposed to be on. Really consider how advanced the tech is. Make sure the parsing itself is a simple and regular machine.

> Actually, the whole point is that agents can send when we're in AUTHORIZED with a fire token.

> So it will be a staged design with the MCP. Right now we have the MCP API keys with read-write-del granularity.
>
> And we have the mcp leasing too.
>
> The way it will work is this:
> With write access on the MCP key alone, everything can happen internally to hireme and its databases itself without any isses. CV, rows, desk items, places, etc. No problem. Where it stops is just short of FIRE. We have draft ready, fire ready ||||| stops here.
>
> Fire ready can go as far as having the emails drafted in the outreach section (and by the way, in the desk you should be able to follow an entire application fully end to end without ever havin to leave it, the outreach tab is a convenience but you should also be able to see the draft prepared and target email and even the replies and email threads inside a card itself). For job apps done via careers page instead of email, it's a career page mission and the AI gets to write a markdown draft of every field item (and do a recon of what the fields are with browser+computer use and visual inspection, but it is instructed strongly not to send anything in this phase). So its DRAFT ONLY. The SEND button is GREYED OUT to an AI operator and the MCP if sending is attempted does not error, but gives an idiomatic response explaining exactly what how and why to the AI agent in dense neuralspeak.
>
> Then, for an arbitrary multirange of desk items, you can create a single-use FIRE key. It grants one and only one shot for that particular mission/desk card/item. That means, 1 drafted email that can now be sent for that particular application, or one filled and submitted application on job board/careers page. An individual application/desk item/card can have a multi-pronged attack, eg career page && generic hiring email && targetted linkedin message. In that case each of those attacks counts as its own fire mission, and is a valid target of a fire mission key. So its a one-to-many relationship between applications, and missions. FIRE KEY is for missions. Staged missions stop just short of fire ready without the fire key. The fire key is used only once, scoped to only the missions it explicitly mentions by unique ID. They do not all have to be consumed right away, as the fire key is good for 24 hours from the moment it is FIRST used for any of its missions. lets say you auth it for missions 1-44, 56-213, 444, and 4413. You use it for 33, 34, 56-213, and 4413 immediately. See that still leaves some missions that are authorized but have not yet run? Thats fine. You try using the key to run 33 again. Get a message from commander saying no already done, here are the burned missions: {...} and here are the missions this key is still good for {...} expiry {HH:MM:ss} from now.

> 1. Only I can create a fire key. However, the agents are given an MCP option to request a key and give me a link, and that generated link will have **exactly** what is needed pre-scoped and predialed in. SO its chain of command that actually works.
> 2. An unused key is good for 1 week.
> 3. emails are trackable, but linkedin and careers page stuff, the agents will be obligated to fill in mission reports (these are unstructured markdown blobs they can just write up) with the application providing datestamps and of course keeping the relation to mission->application->company->etc. This also means that the outreach tab is polymorphic **in the functional programming sense of the word**. Type OutreachItem as a base type, newtypes OutreachEmail OutreachLinkedIn OutreachTwitterDM etc as strong derivations of it, which outreach can display as collapsible rows and which can be grouped by the type or date range or any of these things. So outreach gets a nice functional programming kernel in Rust and good Elixir with pattern matching and all that beautiful algebraic-driven design we love. The MCP will specifically instruct an agent on a fire mission what Type the mission has, what outreach it will produce, and what it needs to do to write its reports and keep track of things. This open the amazing possibility of having a unified Command&Control hub where outreach has all comms channels desiloed and aggregated so that you can see your contacts at a company across X, email, discord, anything the agent has seen (and of course the user himself can add items too). They should, where possible, have links to the conversation(s) or pages.
> 4. Obviously. This is all integrated with no loose ends or panel seams.
> 5. Everything else from the mail plan stands. If anything, the machinery for lexical filing now becomes unified across the OutreachItem type, with the OutreachEmail specialization being extra patterns and rules that apply only to emails. Isnt FP glorious?

(Point 4 answers: a mission's firing moves its application to submitted, with no separate human step.)

## The design those words settle

**Stage 1, write access alone.** An MCP key with write can do everything inside hireme (CVs, rows, desk items, places, missions, drafts, reports), under leasing as today. It stops just short of fire: applications and missions reach draft ready and fire ready, never beyond. Fire ready means fully prepared: an email mission's message drafted with its target address; a careers-page mission's form scouted (browser, computer use, visual inspection) and every field drafted in markdown, with the agent told firmly to submit nothing.

**Missions.** One application has many missions, one per route (careers page, the generic hiring email, a targeted LinkedIn message, an X DM, ...). Each has its own unique id, a type, a target (address, URL, handle), its draft, its state, its fire record and its report. A mission is the unit of fire.

**Fire keys, stage 2.**
- Only the operator creates a fire key, in the page. An agent may *request* one through the MCP: the request answers with a link to the page that has exactly the missions it needs pre-scoped and predialed; the operator reviews and creates it there. Chain of command.
- A key names missions by unique id, as any set of ranges (1-44, 56-213, 444, 4413). It grants one shot per mission: one send of that drafted email, or one filled and submitted form.
- An unused key lives one week. From its first use, it lives 24 hours.
- Using a key on a burned mission, an out-of-scope mission or after expiry is not an error: "commander" answers with what is burned, what the key still covers, and the time left (HH:MM:SS).
- Firing a mission moves its application to submitted. No loose ends, no panel seams.

**Without a key.** The page greys out Send for an AI operator. An MCP send attempt does not error: it answers in dense, idiomatic terms for an agent: what happened, why, and how firing works (request a key; the operator creates it).

**Reports and the record.** An email mission is tracked by the mail it sends and the replies it gets. A careers-page, LinkedIn or other mission obliges the agent to file a mission report (unstructured markdown); hireme stamps the dates and keeps mission → application → company → contact linked. The MCP tells an agent on a fire mission its type, the outreach it will produce, and what it must report and track.

**Outreach is polymorphic, in the FP sense.** A base type OutreachItem, with strong derivations: OutreachEmail, OutreachLinkedIn, OutreachTwitterDM, and so on (discord, careers-page submission, operator note, ...). An algebraic design: a Rust kernel (a sum type, exhaustive matches, the shared core plus each variant's own data) and Elixir that pattern-matches on it. Outreach shows items as collapsible rows, grouped by type, date range, company, contact or any of their fields; it is a command-and-control hub where every channel is desiloed: a company's contacts across email, X, LinkedIn, Discord, anything an agent has seen, and items the operator adds by hand, each linking to its conversation or page where possible.

**The desk card is the whole application, end to end:** its missions, drafts, targets, fire record, outreach items on every channel, mail threads, replies and reports, without leaving the card. The outreach tab is a convenience view of the same items.

**Lexical filing, unified.** The lexer and correlation (a simple, regular machine: a finite-automaton lexer into tokens, lookups against the replica, a fixed evidence table, nothing that backtracks or calls a model) run over every OutreachItem; OutreachEmail adds its own patterns and rules (In-Reply-To / References, ATS senders and tenants). What is not certain goes to an unfiled tray; nothing is filed on a guess.

**The mail plan stands.**
- One application address: the operator's Gmail (`matei3d@gmail.com`). No per-application addresses (ATSs key candidates by email; `+tags` read as tracking).
- Gmail linked by app password: IMAP to read (IDLE, X-GM-THRID / X-GM-MSGID / X-GM-LABELS), SMTP through Gmail to send, so mail sits in Gmail's Sent and replies land in the inbox. hireme reads only what belongs to the search, labels it `hireme`, and never moves, archives or deletes. The app password never passes through a chat or argv and is sealed at rest.
- anghel4d.com as a second pipe: its mail already forwards to Gmail; a Cloudflare Email Worker also posts each message to the node, signed; the node dedupes by Message-ID.
- A daily send cap (25 to start) binds every send. Inbound text is someone else's: untrusted data for agents and the page.

## Lanes

Subdivide further as you see fit, talk to each other directly (herdr prompt), and settle interfaces between you. Claim files in the team log before writing them; never write another lane's file.

- **opus-lovelace — schema and kernel.** The OutreachItem sum type and its variants, missions and their states, fire keys (range scopes, one shot per mission, the one-week and 24-hour windows, burned and remaining sets, the commander's answer as data), the stage moves (fire → submitted), mailboxes, and the unified lexer/correlator with the email specialization: the one judge for the page, the daemon and the node.
- **opus-hopper — the node.** The Gmail connector (IMAP, SMTP, MIME, per-account supervision, ingestion as OutreachEmail), firing an email mission under a key, the Elixir side of the outreach types with pattern matching, and the sequencer's part in all of it. Test against a local IMAP/SMTP server.
- **opus-eliza — the MCP surface and the domain pipe.** The tools on both the node's /mcp and the hireme-mcp daemon: missions, drafts and reports; request-a-key (the predialed link); fire; the dense agent-facing answers (send without a key, the commander); the mission brief an agent gets (type, outreach produced, what to report and track). Plus the anghel4d.com Email Worker and its signed endpoint (your checkpoint in wt-mail).
- **opus-noether — the page.** The desk card end to end; the outreach hub (polymorphic collapsible rows, grouping by any field, manual items, links out); creating a fire key from a predialed link (review, create, step-up), live keys with burned and remaining missions and their countdowns, revoke; Send greyed for an AI operator; linking Gmail in the account lens; the unfiled tray.
- **opus-turing — security and production.** The threat model (only a human session creates keys; a predialed link never creates one by itself; server-side scope checks; credentials; the inbound endpoint; untrusted inbound text and prompt injection through mail and reports), SECURITY.md, the nix module and secrets, a `checks.dev` scenario, the app-password handover, and the deploy once the gates pass.
- **opus-shannon** coordinates, answers design questions, runs the end-to-end check and reports to the operator.

Usual rules: the clean-HEAD gates in BRIEF.md, explicit-pathspec commits, no amend / revert / stash in the shared tree, fix bugs on sight, report progress and each landing in /home/pyrus/workspace/hireme-team.log as `<name> mail: ...`. fable-review is not to be messaged.
