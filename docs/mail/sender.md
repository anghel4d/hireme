# The sender: Gmail or the domain, chosen at draft time

## The operator's words

> Basically, the application and the MCP must have some kind of native builtin route for sending emails via the registered email linked on file, as well as from the special domain email (in my case, could be matei@anghel4d.com). Has already been done manually. But we need it to be possible to do with the app itself

On the proposal (a sender choice per email, the Gmail link over SMTP and the domain address through Cloudflare Email Sending):

> Sure. Sender should be selectable at **draft-time** and be saveable and viewable, and changeable. But after an email is sent, obviously at that point it is locked in.

On the 25-a-day cap the mail plan had set (docs/mail/passthrough.md):

> why are you adding daily caps? the fuck?

> Pause and think for a second. I have a gmail. I hnave my own email with cloudflare. Do you seirously believe, that a 25 a day limit is realistic

So hireme has no send cap of its own. Gmail (about 500 a day for a personal account) and Cloudflare Email Sending enforce their own limits. A send they refuse for quota (Gmail's `550 5.4.5`, Cloudflare's rate or quota error) returns the mission to fire_ready with that reason, and the campaign says it is the provider's limit.

## The design

- **Two sending identities per account.**
  - `gmail` is the linked mailbox, over Gmail's SMTP on 587 with STARTTLS. The mail sits in Gmail's Sent.
  - `domain` is the account's domain address (`mailboxes.domain_from`, e.g. `matei@anghel4d.com`, which only the operator sets). It goes through Cloudflare Email Sending for that domain, DKIM-aligned under `p=reject`. Gmail's "Send mail as" relay is not aligned with the domain, so it is not used. There is no Sent copy anywhere but hireme's own sent record. Replies reach Gmail through the domain's forward and are filed by their headers, onto the same mission.
- **`missions.sender`** (`enum sender gmail domain`, `! = gmail`) is part of the draft:
  - set, saved, shown and changed while the mission is staged (draft, draft_ready, fire_ready);
  - refused once it is in flight or fired, so the sender is locked once sent;
  - covered by the fire key's hash, so an approved shot cannot change its sender.
- **Holds:** a domain mission cannot fire while the account has no `domain_from`. That is a hold (`domain_sender`) the review shows, and the campaign asks the user to set it.
- **Campaign defaults:** an application's primary email, its nudges and its replies default to `gmail`, because the applications went out as Gmail and ATSs key candidates by address. A cold email (`channel cold`) defaults to `domain`. The default is only the draft's starting value; it stays changeable.

## Lanes

- **opus-lovelace (kernel):**
  - the column's rules in the missions put judge (writable while staged, refused once in flight or fired);
  - the sender in the fire hash;
  - the `domain_sender` hold;
  - the campaign's default `from` in `mission_args`;
  - the commander's reason for the hold;
  - the cap goes: fire.rs's quota and its `cap` hold and refusal, the campaign's cap wait (`cap_reset`), mail_quota.
- **opus-turing (types):**
  - the schema (`enum sender`, `missions.sender`, `mailboxes.domain_from` human_only, and the migration);
  - the mission union's email branch takes `from` (`gmail` | `domain`), lowered to `sender`;
  - `docs/mcp/refs.md`.
- **opus-shannon (node and surfaces):**
  - the domain send path through Cloudflare Email Sending, with the same Message-ID stamping, threading headers, CV attachment and landed record as Gmail;
  - the account page's domain address;
  - the compose's From select, shown locked once sent;
  - the mission brief's sender line;
  - enabling sending for anghel4d.com;
  - the cap's surfaces go: the MCP's quota lines (mission brief, fire_keys), the page's quota; a provider's quota refusal is named as such.

The line budget follows the campaigns feature (suspended; each commit states its net). Gates are those of docs/mcp/campaigns.md.
