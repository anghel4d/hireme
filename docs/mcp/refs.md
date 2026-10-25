# Refs, the mission union and the outcome split

The types lane of the MCP campaigns (docs/mcp/campaigns.md, opus-turing).
Three things the MCP's inputs gain so that a wrong call fails to parse at
the door, in the words of the design page: "A ref of the wrong kind fails to
parse", "Missions as a tagged union", "Outcomes split by what went out".

## Refs: one handle per row

A ref is `<kind>:<key>`. Nine kinds, each one table:

| ref | table | key |
| --- | --- | --- |
| `app:412` | applications | the application's `no` (what every page and listing shows) |
| `mission:34` | missions | id |
| `contact:9` | contacts | id |
| `corp:stripe.com` | corporations | `domain` (lowercased; the natural key) |
| `place:3` | places | id |
| `outreach:1291` | outreach | id |
| `batch:96` | batches | id |
| `fire_key:51` | fire_keys | id |
| `fire_request:88` | fire_requests | id |

The table of kinds is the kernel's, `kernel::refs::KINDS` in
`native/kernel/src/refs.rs` (the kind, its prefix, its table): the campaign writes
every ref it renders by it (`refs::app`, `mission`, `contact`, `outreach`,
`request`), and the resolver re-exports `Kind` and reads the table, so the
grammar is defined once.

`<kind>:new` names a row to insert (`"ref":"mission:new"`); it is accepted
by `put` alone. A ref is parsed strictly: the kind must be one of the nine,
the key a whole number from 1 (`app`, ids) or a domain (`corp`); anything
else is refused as `ref` with what a ref looks like.

### Where a ref goes

The resolver (`native/mcp/src/refs.rs`, `refs::resolve`) rewrites a tool's
arguments before dispatch. After it, every ref has become the table and id
(or key) the existing tools already take, so nothing downstream changes.

- **The row a call is about.** `{"ref": "app:412", ...}` on `get`, `text`,
  `history`, `put`, `drop`, `mission`, `report`, `fire`, `stage`, `note`,
  `heat_override`, `pick_cv`, `unpin_cv`, `landed`, `failed`, `file`,
  `ignore` and every other command. It stands for `table` + `id` (or `no`).
  A ref of a kind the tool cannot take is refused: `expected app:…, got
  mission:34` (a command's table is fixed; `mission` takes a mission). A
  call that names its row twice and differently (`ref` beside `id`, `no` or
  `key`) is refused; the same row twice is fine.
- **Ref columns.** In `set`, `key`, `where` and command params, a column of
  type ref takes a ref of its target's kind as a string:
  `"application_id": "app:412"`, `"corporation_id": "corp:acme.com"`,
  `"contact_id": "contact:9"`, `"mission_id": "mission:34"`,
  `"place_id": "place:3"`, `"batch_id": "batch:96"`. A plain id is still
  accepted. The wrong kind is refused the same way.
- **Tool arguments that name rows.** `missions {"application": "app:412"}`,
  `campaign {"application": "app:412"}` or `{"app": "app:412"}`,
  `cv {"application": "app:412"}` (or the plain `no`),
  `report {"mission": "mission:34"}`, `fire {"key": "fire_key:51"}`,
  `lease {"refs": ["app:412", ...]}` and `release {"refs": [...]}` (beside
  `ids`), `request_fire_key {"missions": "mission:34-35,mission:40"}` (or an
  array of refs and ranges; the prefixes are stripped and the text goes to
  `fire::Ranges`, so `"34-35"` still works).
- **An item as a thread.** An email mission's `in_reply_to` takes
  `"outreach:1291"`: the resolver reads that item's Message-ID and writes
  it, so the kernel's reply rules see a mail the account holds. A
  Message-ID string is accepted as before.

Resolution reads the daemon's replica: `app:<no>` → the application's id
(`get` by `no`), `corp:<domain>` → the corporation's id (by `domain`),
`outreach:<id>` → its Message-ID. An unknown `no` or domain is refused
`not_found` with the ref. Every other kind passes its id through; the kernel
judges existence, as it does today.

### Refs out

Answers name rows the same way (shannon's rendering): `refs::app(no)`,
`refs::corp(domain)` and `refs::of(table, id)` give the text; a row carries
its ref where the id alone was shown.

## The mission union

A mission is put with its kind, and the keys the kind takes; the resolver
lowers them to the `missions` row the kernel judges. `put` with
`"ref": "mission:new"` (or `"mission:34"` to edit) and `"kind"`, the fields
beside them (or inside `set`, both forms are one):

| kind | keys | lowers to |
| --- | --- | --- |
| every kind | `app` (an `app:<no>` ref; aliases `application`, `application_id`), `draft`, `note`, `state` (`draft` \| `draft_ready` \| `fire_ready`), `contact` (`contact:<id>`; alias `contact_id`) | application_id, draft, note, state, contact_id |
| `email` | `to` (one address, or 1 to 10 as an array or a comma list), `cc`, `subject`, `in_reply_to` (a Message-ID or `outreach:<id>`), `refs` | target, cc, subject, in_reply_to, refs |
| `careers_page` | `form` (the form's https URL) | target |
| `linkedin` | `profile` (a linkedin.com/in/ URL), or `contact` whose row has one and no `profile` | target (or empty, with contact_id) |
| `x_dm` | `handle` (the @ is stripped) | target |
| `discord` | `handle` (a user, or server/#channel) | target |
| `other` | `target` (the route in words) | target |

`target` itself is accepted for every kind, as the raw column. A new
mission needs `kind` and `app`. Any other key is refused `shape` with a
did-you-mean over the kind's keys (`"form" is not a key of an email mission;
did you mean "to"?`). The per-kind form of the target (an https URL, a
profile, a handle) is judged by one kernel function, `fire::target(kind,
text)`, which the resolver calls at the door and the missions judge on the
put, so both say the same words.

The JSON Schema of the union (`refs::mission_schema()`) is a `oneOf` keyed
by `kind`, each branch with its `required` and `additionalProperties:
false`, for the tool list.

## Unknown keys

Every tool's arguments are checked against its input schema's properties
(and the resolver's own: `ref`, `refs`): a key the tool does not take is
refused `shape` with a did-you-mean (the nearest known key by edit distance
or prefix) and the known keys. Today an unknown key on a command is dropped
silently (`stage {"outcome": …}` wrote nothing of it); after this it is a
refusal, so a strict client and a loose one are told the same.

## The outcome split (decision 6)

`enum outcome offer rejected ghosted withdrawn declined expired skipped` (the
two new values appended, so stored codes keep). The `stage` command takes
`outcome?`, so a close is one call:

```
stage {"ref":"app:412","stage":"closed","outcome":"expired"}
```

The judge sets `outcome` with the move and refuses the pair that cannot be:

| the application | may close as |
| --- | --- |
| nothing went out (`board::sent` false: no submission or reply on its rail) | `expired`, `skipped`, `withdrawn` |
| something went out | `offer`, `rejected`, `ghosted`, `withdrawn`, `declined` |

`outcome` with any stage but `closed` is refused; `put` of `outcome` on an
application is judged by the same table. A close without an outcome stays
allowed (the operator may close first and say why later). The refusal is
`type` on column `outcome` with the reason and the allowed list.

## The hook

```rust
// native/mcp/src/refs.rs
pub trait Lookup {                                  // the daemon's replica, under the key's grants
    fn app_id(&self, no: u32) -> Option<u32>;
    fn corp_id(&self, domain: &str) -> Option<u32>;
    fn message_id(&self, outreach: u32) -> Option<String>;
    fn mission_kind(&self, mission: u32) -> Option<String>;   // an edit of mission:34 takes its kind's keys
}
pub struct Replica<'a>(pub &'a mut kernel::abi::Kernel, pub kernel::query::Grants);   // Lookup over the kernel
pub fn resolve(tool: &str, args: &Json, look: &mut dyn Lookup) -> Result<Json, (String, Json)>;
pub fn mission_schema() -> Json;                    // the oneOf for the tool list
pub fn app(no: u32) -> String; pub fn corp(domain: &str) -> String; pub fn of(table: &str, id: u32) -> Option<String>;
```

`resolve` answers the rewritten arguments, or `(code, data)` for
`diag::render` (`ref`, `shape`, `not_found`; data names `field`, `expected`,
`got`, `did_you_mean`, `known`). session.rs calls it once in `answer`, after
the help check and before the match on the tool's name:

```rust
let args = match read(|k| refs::resolve(name, &args, &mut refs::Replica(k, grants(m)))) { Ok(Ok(a)) => a, Ok(Err((code, data))) => return Ok(text(diag::render(&code, &format!("{name} {}", compact(&args)), &data), None, true)), Err(lost) => ... };
```

## Lanes

- **opus-lovelace (kernel campaign.rs):** `next.args` use the tools' own
  grammar with refs, as above. `fire::target(kind, text)` is yours; I call
  it from the resolver.
- **opus-shannon (MCP surface):** the one call in `answer`; the `oneOf` in
  `put`'s schema (or wherever the tool list wants it); `ref`/`shape` in
  diag's tables for their headline; refs in answers through
  `refs::app/corp/of`.
