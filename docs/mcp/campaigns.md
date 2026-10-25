# Campaigns: the MCP's golden routes

Design page (the operator approved it): https://claude.ai/artifact/9wtJjpe6oYkUzhgYs7HdGA

## The operator's words

The brief (2026-10-25), verbatim:

> Next task, improve the MCP so that it is totally retard proof. Let's design a pipeline that accounts for every possible "story route" in an application, hints the next steps to take to the agents utilizing it (in 1-2 lines at a time, made to look like hyperdense instructions or Rust compiler errors/warnings, including embedding ansi color codes, with success being green, next-hints being cyan, warnings or inaccuracies being yellow, and errors being red), and have a standard framework for what it really takes to take an application through past the finish line completely end to end from initial acquisition and entry into the data system, to preparing and drafting application documents, to outreach, submission, and follow-up. This touches every single MCP command and output to make it as idiot-proof as possible. ALso an opportunity to tighten MCP behaviour with stronger types, ADTs, pattern matching, guards, and other measures to render invalid state completely unrepresentable and impossible to input altogether. Finally, this also adds the first of many "golden routes" or "task-campaigns" to the MCP, whereby the first usage of the MCP or -h will show these campaigns first, erroring will also direct ai agents to looking into campaigns -h or man campaigns or whatever it is (btw, we must standardize and allow for both man and -h with ALL of the completely standard, widely expected commands. Manpages as have existed for the last 50 years are probably a good idea). In pursuit of this, show me as a unicode diagram or a claude web artifact, precisely the pipeline for this first campaign. Essentially every MCP command as a surgical thing you can do still exists, for instance editing an individual entry. But a campaign is like, almost like a text adventure game mode for the LLM, telling it exactly what to do next based on the hireme state, with branching paths where available and railroading where necessary, eg if an application is email only, the next phase will be emails. If an application has a connected linkedin contact, a follow-up to the HR responsible like "Hey! I'm Matei, [short intro], [prior work]. Just applied to [job] {etc}."
>
> Show me what that might look like before we implement.

On the design page:

> Yeah looks good. Make the design decisions yourself. Campaign should have the llm query the user for a fire-key when it gets to that stage, duh. For the colour codes, 6-10 tokens if they are widely recognized is probably fine yeah. As long as the rest of the message is short. Itll make it more readable for me and signal to the llm something clearly

On the line budget, asked whether to suspend the per-commit net <= 0 bound for this feature: "Suspend for this feature (Recommended)". **Line budget:** suspended for this feature, as for mail (passthrough.md rule 7); each commit still states its net.

Then: "When ready, begin and implement in full, end to end, with the help of opus-turing and opus-lovelace."

## Decisions (opus-shannon, on "make the design decisions yourself")

1. **Follow-up cadence:** a LinkedIn note on day 0–1 after submission (when a recruiter or hiring-manager contact has a profile), email nudges on days 7 and 14 in the submission's thread (when an address is on file), close as ghosted on day 30. Any filed reply stops every timer.
2. **The fire key is the operator's one gate for a campaign's shots.** The kernel already moves an application to submitted when a mission lands, so `open_fire` is not on the route. The batch stays: the stage rail needs one before in_batch, so the campaign joins today's day_pack mechanically. At the fire-key phase the campaign tells the agent to **ask the user** for the key, giving the review link (`/fire/<request id>`), and to stop there.
3. **Colour is on by default.** Green success, cyan next and help, yellow warning, red error. `NO_COLOR` (no-color.org) in the daemon's environment, or `{"color":false}` on `hireme`, turns it off. The words are the same either way, and every answer stays short.
4. **Which application `campaign {"run":"apply"}` picks:** the open one closest to done that the agent can move now (no wait, no operator ask). Ties go to the higher score.
5. **The LinkedIn intro** is written per application, from the `me` row and the corpus items that best match the listing's keywords. A note over 300 characters is a warning (LinkedIn's connection-note limit), not a refusal: a message to an existing connection may be longer.
6. **Closed outcomes split by whether anything went out.** Add `expired` and `skipped` to `enum outcome`. A close of an unsent application takes expired, skipped or withdrawn. A sent one takes offer, rejected, ghosted, withdrawn or declined. The kernel refuses the rest.

## The route (campaign `apply`)

Thirteen phases, derived from stored state every time (nothing campaign-specific is stored):

1 acquire · 2 link · 3 qualify · 4 route · 5 batch · 6 documents · 7 stage · 8 fire key · 9 fire · 10 confirm · 11 follow-up · 12 reply · 13 close.

The design page has the diagram and the table of branches; it is the reference for what each phase reads and says.

## The lanes

- **opus-lovelace (kernel):** `native/kernel/src/campaign.rs`. It derives one application's step, picks the next application, and serves query op `campaign`. The route graph is tested whole: every reachable combination yields exactly one next, with no dead ends. The per-kind mission target rules go in the missions put judge: careers_page an https URL, linkedin a linkedin.com profile URL or a contact with one, x_dm a handle, discord a handle; email is already judged by `outreach::addrs`.
- **opus-turing (types):**
  - Typed refs at the MCP boundary: `app:412` (the application's no), `mission:34`, `contact:9`, `corp:<domain>`, `place:<id>`, `outreach:<id>`, `batch:<id>`, `fire_key:<id>`, `fire_request:<id>`. `{"ref":…}` names a row for get, put, drop and commands. A ref field of the wrong kind is refused (`expected app:…, got mission:34`).
  - Missions' kind-tagged input shape: a `oneOf` keyed by kind.
  - Unknown keys refused with a did-you-mean.
  - The outcome split (decision 6), in the schema and its judge.
- **opus-shannon (MCP surface):**
  - the hint grammar and ANSI painting of every answer;
  - `-h`/`--help`/`help` on every tool (in every tool's input schema, so strict clients pass it);
  - the `man` tool (sections 1, 5, 7, 8 and `man -k`, also as `man://` resources), which absorbs `hireme {"explain":…}`;
  - CAMPAIGNS first in `initialize`'s instructions and `hireme`;
  - the refusal footer `help: man <code> · campaign apply -h`;
  - the `campaign` tool, and the campaign's next line after every write on an application in play;
  - integration and the final pass.

## The interface between the kernel and the MCP

Query op `campaign`:
- `{"application": <id>}` answers that application's step.
- `{}` answers the step of the application it picks.

The answer:

```json
{"application": {"id": 120, "no": 412, "company": "…", "role": "…", "stage": "gated"},
 "phase": {"n": 4, "name": "route"},
 "said": [{"level": "ok" | "warn", "code": "routed", "text": "…"}],
 "next": {"kind": "do" | "ask" | "wait" | "done",
          "tool": "put", "args": {…},
          "ask": "what to ask the user",
          "until": "2026-11-01",
          "why": "one line"}}
```

- `said` holds at most one ok line and one warn line.
- `next` is exactly one of its four kinds.
- `args` name rows by ref (`"app:412"`), which turing's resolver turns into ids.

The MCP renders it as at most two coloured lines after the payload.

## Gates

Every commit:
- `cargo test -p kernel -p wire -p mcp -p schema --features mcp/client`;
- `cargo clippy --workspace --all-targets --features mcp/client -- -D warnings`;
- the NIF builds;
- `mix format`, `compile --warnings-as-errors`, `credo --strict` ("found no issues"), `mix test`.

Shared-tree rules stand:
- stage and commit atomically with explicit pathspecs;
- no amend, revert, checkout or stash;
- a change to another lane's file goes to its owner as a patch.
