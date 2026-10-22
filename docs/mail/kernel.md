# Missions, fire keys, mailboxes and the filer: the schema and the kernel

The interface the mail lanes build against (opus-lovelace's lane), under the
brief [passthrough.md](passthrough.md) and its agreed rules. The OutreachItem
type (its variants, matchers and guards, Rust and Elixir) is opus-turing's
alone; this lane consumes it through a published interface and asks for
changes as `type-request:` lines in the team log. Everything here is the
kernel's, so the node (NIF), the daemon and the page (wasm) judge alike.

## Actors

The judge tells three writers apart by the context it is given:

| actor | context | may |
| --- | --- | --- |
| the operator | `human: true` (a browser session, or an internal op under operator grants) | everything but a keyless shot: the operator fires under a live key too, made under step-up (a browser session cannot tell the operator from an AI driving it; the step-up at key creation is the proof of a human) |
| an agent | `human: false, key_id: Some(k)` | stage up to fire ready; fire only under a live key |
| the mail actor | `human: false, key_id: None` (the node's connector and the domain pipe) | record facts: mailbox state, a send's outcome, ingest |

Commands meant for one actor are refused to the others in the judge (`scope`
with `{need: "mail" | "operator"}`), not by a schema flag.

## Schema

### `missions` (desk, resident)

One per route of an application; the unit of fire.

| column | type | notes |
| --- | --- | --- |
| application_id | ref applications ! | |
| kind | enum `outreach_kind` ! | the outreach it produces: any kind but `note` (turing's `Kind::fireable`) |
| target | str ? | the route: a URL or a handle; an email's To, up to 10 addresses, read by `outreach::addrs` and stored bare, comma-separated |
| contact_id | ref contacts ? | |
| draft | text ? | markdown: a form's fields, a DM's text; an email's body |
| cc, subject | str ? | an email's |
| in_reply_to, refs | str ?, text ? | an email follow-up's, as the thread holds them |
| message_id | str ? readonly | the Message-ID the node minted, stamped before SMTP |
| gmail_msgid, gmail_thrid | i64 ? readonly | set by `landed` |
| cv_version_id | ref cv_versions ? readonly | the CV the shot carries, recorded by `fire`: the version the key's hash covered; the node attaches it, and `landed` freezes it on the application |
| state | enum `mission_state`: draft, draft_ready, fire_ready, in_flight, fired, cancelled ! = draft | |
| last_error | text ? readonly | the last failed shot's reason (rule 2) |
| fired_at | time ? readonly | when the shot landed |
| fired_by | enum actor ? readonly | |
| fire_key_id | ref fire_keys ? readonly loose | the key it went under; null for the operator's own fire |
| fired_with | ref api_keys ? readonly loose | the API key that fired |
| in_flight_at | time ? readonly | when the current shot started |
| confirmation | enum `confirmation`: provisional, confirmed ? readonly | self-reported missions (rule 3) |
| note | text ? | |

States by put: draft, draft_ready, fire_ready and cancelled move among
themselves; in_flight and fired only by the commands below. A mission in
flight or fired takes no edit to kind, target, draft, application or its
email draft.

Commands:

- `fire key:u32?`: any actor but mail. Judged below. The mission goes in
  flight. A refusal is `fire` with the commander's answer.
- `stamp message_id`: the mail actor, once, while in flight: the Message-ID
  the node minted (`<hm.{random}@{the address's domain}>`), recorded before
  it sends, so after a crash the node finds it in Gmail's Sent and writes
  `landed` instead of sending twice.
- `landed gmail_msgid:i64? gmail_thrid:i64?`: the shot landed. Email: the
  mail actor only (the node, after SMTP accepted it; also after a crash, when
  Gmail's Sent holds the Message-ID). Other kinds: the API key that fired, or
  the operator (the agent's report: rule 3 makes it provisional). One op: the
  mission fired (fired_at, the Gmail ids), its shot burned, an email's sent
  record written (`outreach::sent_record`: an outbound outreach row filed to
  the mission, or Gmail's copy of it updated; an unstamped email is refused
  `stage`, rule `unstamped`), the application moved to submitted (from fire_ready or open_fire; later
  stages stay) with its CV version frozen, and a `fire` event.
- `failed reason:text`: the shot failed (SMTP error; a form that refused).
  Same authority as `landed`. The mission back to fire_ready with last_error,
  the shot unburned and still covered.

An email mission's sent mail and every reply are outreach rows (turing's
type): records of what happened, filed to the mission by its message_id
(Gmail's copy of the sent mail is ingested like any other).

### `fire_requests` (desk, resident)

An agent's ask, written with a plain put; the predialed link is
`/fire/<request id>`. Requested_at is the row's inserted_at.

| column | type | notes |
| --- | --- | --- |
| missions | str ! | ranges, stored canonical (`1-44,56-213,444`) |
| reason | str ? | at most 280 |
| requested_by | ref api_keys ? readonly loose | set by the kernel from the calling key |
| status | enum `request_status`: open, granted, declined ! = open readonly | |
| fire_key_id | ref fire_keys ? readonly loose | the key it became |

Command `decline` (operator).

### `fire_keys` (desk, resident)

Created only by the operator's command; no secret. Every column is
readonly: the commands write them.

| column | type | notes |
| --- | --- | --- |
| scope | str ! | canonical ranges of the missions it covers |
| usable_by | ref api_keys ? loose | that key only; null: any key of the account |
| request_id | ref fire_requests ? loose | |
| first_used_at | time ? | |
| expires_at | time ! | created + 7 days; from the first use, that use + 24 h |
| revoked_at | time ? | |

Commands, operator only: `create_fire_key missions:str digest:str
usable_by:u32? request:u32?` (target 0; the page takes the step-up), and
`revoke_fire_key`.

### `fire_shots` (desk, resident)

The frozen scope (rule 1): one row per mission a key covers.

| column | type | notes |
| --- | --- | --- |
| fire_key_id | ref fire_keys ! | |
| mission_id | ref missions ! | unique with the key |
| hash | str ! | SHA-256 (hex) of what the mission fires, at the key's creation |
| burned_at | time ? | set by `landed`, cleared by a bounce |

The hash covers the mission's kind, target, draft, cc, subject, in_reply_to
and refs, its application, and the CV version the application's pick sends:
everything that goes out. A mission edited after the key
was made no longer matches its shot: `fire` answers `changed`.

### `mailboxes` (mail, resident, singleton)

| column | type | notes |
| --- | --- | --- |
| provider | enum `mail_provider`: gmail ! | |
| address | str ! | |
| status | enum `mailbox_status`: linking, live, auth_failed, error, unlinked ! = linking | |
| last_sync_at | time ? | |
| last_error | text ? | shown verbatim |
| daily_cap | u32 ! = 25 | operator only (`human_only`) |
| pipe_id | str ? (unique, global) | the domain pipe's public id, 12 base62 |
| secret | bytes ? server_only | the app password, `Hireme.Security.seal(password, "hireme mail app password")` |
| pipe_secret | bytes ? server_only | `Hireme.Security.seal(secret, "hireme mail pipe secret")` |
| folder, uidvalidity, last_uid | str, u32, u32 ? server_only | the connector's cursor |

The node writes server_only cells with its own server write (never a put).
A put by the mail actor creates the row (provider, address). Commands:
`mailbox_state status last_error last_sync_at` (mail actor), `unlink_mail`
(operator: status unlinked; the node clears the secret and the cursor).

### `applications.prior_send` (rule 5)

`prior_send` enum `prior_send`: applied, not_applied ? human_only. An
application whose stage_notes carry `sync.applied_on` and whose prior_send is
null cannot fire (`unsettled`); the operator settles it by setting prior_send.

## The fire judge

`fire` on mission m by actor a, in order; the first that fails is the
answer (`fire`, data below):

1. m exists and is fire_ready (`not_ready`, `in_flight`, `fired`). An
   email: its To (1 to 10 bare addresses), subject and body set
   (`incomplete`), and for a first contact (no in_reply_to) the CV the
   application's pick sends is a file, a PDF or DOCX version (`cv_file`);
   a reply inside a thread goes without one. A put that would make such a
   mission fire_ready is refused the same (`stage`, rule `cv_file`).
2. Its application: linked (`unlinked`), at fire_ready, open_fire or later
   but not closed (`app_stage`), its prior send settled (`unsettled`).
3. Authority, the same for every actor: a shot of m under a key that is
   unrevoked (`revoked`), unexpired (`expired`), usable by the caller
   (`not_yours`: a key with usable_by takes that API key only; the operator's
   session may use any live key), unburned (`burned`), and whose hash matches
   m now (`changed`); none at all is `no_key`; a named key that does not cover
   m is `out_of_scope`. The mail actor never fires.
4. Email: a live mailbox (`mailbox`), and the daily cap: email missions in
   flight or landed today (UTC), against daily_cap (`cap`, with resets_at).
5. The heat governor, when the application has not gone out yet (`heat`, as
   today).

Effects: m in flight (in_flight_at, the key, the API key), the key's
first_used_at and expires_at on its first use, the email row queued.

The commander's answer (`fire` refusal data), for the MCP to render as an
answer, never an error:

```json
{"why": "burned", "mission": 33, "key": 7,
 "burned": "33-34,56-213,4413", "remaining": "1-32,35-44,444", "changed": "",
 "expires_at": "2026-10-23T14:02:11Z", "expires_in": "23:41:07",
 "live_keys": [{"id": 7, "scope": "1-44,56-213,444,4413", "remaining": "1-32,35-44,444"}]}
```

## Queries (`Kernel::query` ops; the node's /mcp, the daemon and the page alike)

- `ranges {ids: [...]}` or `{text: "..."}`: `{text, count, ids}` canonical.
- `missions {application?, state?, kind?}`: rows plus `hash`, `covered_by`
  (the live keys whose unburned shot covers it), `hold` (why it cannot
  fire whoever asks, or null) and `report_due` (a fired shot hireme could
  not watch, anything but an email, that no outreach item names yet). An
  untracked shot is closed by the agent in two writes: `landed` (or
  `failed`) on the mission, then the outreach item its kind's brief
  describes, naming the mission.
- `mission_brief {mission}`: kind, target, application, company, contact,
  state, what the shot produces and must be reported, its live keys.
- `fire_review {request} | {missions}`: every mission's draft and target in
  full (rule 4), its application and company, the CV version, its hash, and
  whether it is eligible (with why not); `scope` (the eligible, canonical) and
  `digest`, which `create_fire_key` must echo.
- `live_keys {}`: `[{id, scope, usable_by, request_id, burned, remaining,
  changed, first_used_at, expires_at, expires_in_s}]`.
- `mail_quota {}`: `{cap, used, left, resets_at}`.
- `mail_match {...the envelope}`: the filing, below; the node asks it
  through the account kernel's read before it stores anything.
- The application document (`Kernel::application`, the desk card) carries
  `missions`: the rows `missions {application}` answers.
- Filing (`unfiled`, threads): over the outreach type, once its interface is
  published.

## The filer

One finite-automaton lexer over every outreach item's text into tokens
(Message-IDs, addresses and their domains, URLs with their host and path,
handles, bare domains, numbers, words), and correlation by lookups against
the replica, scored by one fixed table. The email specialization adds the
header rules (In-Reply-To / References, the Gmail thread, ATS senders and
tenants, bounces).

`Kernel::mail_match(json)` (`Hireme.Kernel.mail_match/1`), on the envelope
alone, before anything is stored:

```json
{"message_id": "...", "in_reply_to": "...", "refs": ["..."], "from": "Name <a@b>",
 "to": ["..."], "cc": ["..."], "subject": "...", "text": "...", "date": 1760000000,
 "gmail_thrid": 123, "headers": {"reply-to": "...", "list-id": "..."},
 "report": {"kind": "bounce", "original_message_id": "...", "status": "5.1.1", "diagnostic": "..."}}
```

answers

```json
{"relevant": true, "filing": "filed", "application_id": 12, "corporation_id": 3,
 "contact_id": null, "mission_id": 9, "thread_key": "...",
 "evidence": [{"token": "greenhouse.io", "kind": "ats_sender", "weight": 50, "table": "corporations", "id": 3}],
 "candidates": [{"table": "applications", "id": 12, "label": "...", "score": 90}]}
```

`relevant: false`: the node neither stores nor labels it. The put of a stored
message is filed by the same code in its judge (the filing cells are
readonly: the writer never sets them). Message-IDs are compared in one
canonical form (no brackets or spaces, lowercased); they are stored as given.

| evidence | weight | certain |
| --- | --- | --- |
| its own Message-ID is one a mission stamped (Gmail's copy of a sent mail) | 100 | yes |
| in_reply_to or refs names a message the account holds | 100 | yes |
| a bounce report naming a message the account sent | 100 | yes |
| the Gmail thread of a filed message | 100 | yes |
| a URL whose canonical form is an application's canonical_url | 90 | yes |
| the sender is a contact | 60 | |
| an ATS sender or link whose tenant is a corporation's ats_tenant | 50 | |
| the sender's domain is a corporation's (not a freemail host) | 50 | |
| a corporation's name in the subject | 20 | |
| an application's role words (that corporation's) | 20 | |
| an ATS sender with no known tenant | 10 | |

Filed on certain evidence that agrees (certain evidence naming two
applications files nothing), or when one corporation's evidence reaches 50
ahead of every other and it has exactly one application in play
(submitted, reply, or a mission in flight or fired), or the application's
role words pick one by a clear margin (2 words or more, ahead of the rest);
a known contact at a corporation with no application files to the contact.
Else unfiled with the candidates ranked. Relevant: any evidence that
reaches the desk (a thread the account holds, a contact, an ATS sender, or a
corporation with an application). A filed bounce marks its message bounced
and fails its mission (rule 2); a filed confirmation mail confirms a
provisional mission (rule 3).

## Answers, by example

Times are ISO 8601 (UTC), as every query answers them; ranges are canonical
text; absent values are `null`, empty sets `""`.

`fire_review {request: 17}` (one eligible email mission, one careers-page
mission held by an unsettled prior send):

```json
{"request": {"id": 17, "missions": "33-34", "reason": "Acme: both routes drafted", "requested_by": 4, "status": "open"},
 "missions": [
  {"id": 33, "kind": "email", "target": "jobs@acme.example", "state": "fire_ready",
   "application": {"id": 120, "no": 120, "company": "Acme", "role": "Staff Engineer", "stage": "fire_ready", "corporation_id": 3},
   "draft": {"to": "jobs@acme.example", "cc": null, "subject": "Staff Engineer application", "body": "Hello ...", "in_reply_to": null, "refs": null},
   "cv_version_id": 88, "hash": "9f2c...", "eligible": true, "why": null},
  {"id": 34, "kind": "careers_page", "target": "https://job-boards.greenhouse.io/acme/jobs/4012", "state": "fire_ready",
   "application": {"id": 121, "no": 121, "company": "Acme", "role": "Platform Engineer", "stage": "fire_ready", "corporation_id": 3},
   "draft": {"markdown": "## Name\nMatei ...\n## Why Acme\n..."},
   "cv_version_id": 88, "hash": "41ab...", "eligible": false, "why": "unsettled"}
 ],
 "scope": "33", "count": 1, "digest": "5be1..."}
```

`why` is one of the fire judge's holds (`not_ready`, `in_flight`, `fired`,
`incomplete`, `cv_file`, `unlinked`, `app_stage`, `unsettled`); `digest` is the SHA-256 of
the eligible missions' ids and hashes, which `create_fire_key` echoes.

`missions {application: 120}`:

```json
{"missions": [
  {"id": 33, "application_id": 120, "kind": "email", "target": "jobs@acme.example", "contact_id": null,
   "state": "fire_ready", "draft": "Hello ...", "cc": null, "subject": "Staff Engineer application",
   "in_reply_to": null, "refs": null, "message_id": null, "last_error": null,
   "fired_at": null, "fired_by": null, "fire_key_id": null, "in_flight_at": null, "confirmation": null, "note": null,
   "gmail_msgid": null, "gmail_thrid": null, "hash": "9f2c...", "covered_by": [7], "hold": null}
]}
```

`live_keys {}`:

```json
{"keys": [
  {"id": 7, "scope": "1-44,56-213,444,4413", "usable_by": 4, "request_id": 17, "created_at": "2026-10-22T14:02:11Z",
   "first_used_at": "2026-10-22T14:20:00Z", "expires_at": "2026-10-23T14:20:00Z", "expires_in_s": 85267, "expires_in": "23:41:07",
   "burned": "33-34,56-213,4413", "remaining": "1-32,35-44,444", "in_flight": "", "changed": ""}
]}
```

`burned` + `remaining` + `in_flight` + `changed` partition the key's shots;
`changed` holds missions edited since the key was made (they will not fire
under it).

A `fire` refusal for a mission no key covers (`no_key`):

```json
{"code": "fire",
 "data": {"why": "no_key", "mission": 33, "key": null,
          "burned": "", "remaining": "", "in_flight": "", "changed": "",
          "expires_at": null, "expires_in": null, "live_keys": [],
          "ask": {"missions": "33"}}}
```

`ask` is what a `fire_requests` put for this mission would carry; under a
key (`burned`, `out_of_scope`, `expired`, ...) `key` names it and the sets
and times are that key's.
