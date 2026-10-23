//! The filer through its entry point, over a replica: where a mail belongs
//! (docs/mail/kernel.md's evidence table), filed on certain evidence or one
//! corporation's clear lead, else unfiled with its candidates; a bounce and
//! a confirmation named; mail that reaches no part of the desk irrelevant.

mod fixture;

use kernel::abi::Kernel;
use kernel::filer::{self, Input, NoStore};
use serde_json::json;

/// Acme (acme.example, Greenhouse tenant `acme`) with applications 1
/// (Staff Engineer, submitted) and 2 (Platform Engineer, submitted), whose
/// careers-page mission 20 is provisional and email mission 21 sent as
/// `<hm.Sent1@example.com>` in Gmail thread 900; Initech (initech.example)
/// with application 3 (Data Engineer, discovered); Dana, a contact at
/// Globex (no applications); application 1's posting at
/// https://job-boards.greenhouse.io/acme/jobs/4012.
fn rows() -> Kernel {
    fixture::kernel(json!({
        "corporations": [{"id": 1, "domain": "acme.example", "name": "Acme", "ats": "greenhouse", "ats_tenant": "acme"}, {"id": 2, "domain": "initech.example", "name": "Initech"}, {"id": 3, "domain": "globex.example", "name": "Globex"}],
        "applications": [
            {"id": 1, "no": 1, "stage": "submitted", "company": "Acme", "role": "Staff Engineer, Search Infrastructure", "corporation_id": 1, "canonical_url": "https://job-boards.greenhouse.io/acme/jobs/4012"},
            {"id": 2, "no": 2, "stage": "submitted", "company": "Acme", "role": "Platform Engineer, Data", "corporation_id": 1},
            {"id": 3, "no": 3, "stage": "discovered", "company": "Initech", "role": "Data Engineer", "corporation_id": 2},
        ],
        "missions": [
            {"id": 20, "application_id": 1, "kind": "careers_page", "state": "fired", "confirmation": "provisional"},
            {"id": 21, "application_id": 2, "kind": "email", "state": "fired", "message_id": "hm.Sent1@example.com", "gmail_thrid": 900},
        ],
        "contacts": [{"id": 7, "corporation_id": 3, "name": "Dana", "email": "Dana@Globex.example"}],
    }))
}

fn mail<'a>(from: &'a str, subject: &'a str, body: &'a str) -> Input<'a> {
    Input { email: true, inbound: true, from, subject, body, ..Input::default() }
}

fn kinds(f: &filer::Filing) -> Vec<&'static str> {
    f.evidence.iter().map(|e| e.kind).collect()
}

#[test]
fn a_reply_to_a_sent_mission_files_to_it_by_the_thread() {
    let k = rows();
    let refs = vec!["<HM.sent1@EXAMPLE.com>".to_string()];
    let f = filer::file(k.rows(), &NoStore, &Input { refs: &refs, in_reply_to: "<hm.sent1@example.com>", ..mail("someone@gmail.com", "Re: Platform Engineer", "Thanks!") });
    assert!(f.filed && f.relevant);
    assert_eq!((f.mission_id, f.application_id, f.corporation_id), (Some(21), Some(2), Some(1)));
    assert_eq!(f.thread_key.as_deref(), Some("hm.sent1@example.com"));
    assert_eq!(kinds(&f)[..2], ["in_reply_to", "refs"]);
    // Gmail's copy of the sent mail itself is the mission's by its own id.
    let to = vec!["jobs@acme.example".to_string()];
    let f = filer::file(k.rows(), &NoStore, &Input { inbound: false, message_id: "<hm.sent1@example.com>", to: &to, ..mail("ana@example.com", "Platform Engineer", "Hello") });
    assert_eq!((f.filed, f.mission_id, kinds(&f)[0]), (true, Some(21), "sent"));
    // Gmail's thread files it as surely.
    let f = filer::file(k.rows(), &NoStore, &Input { gmail_thrid: Some(900), ..mail("x@gmail.com", "", "") });
    assert_eq!((f.filed, f.mission_id), (true, Some(21)));
}

#[test]
fn an_ats_confirmation_files_to_the_posting_and_confirms_the_shot() {
    let k = rows();
    let body = "Hi Ana, thank you for applying to Acme! Track it at https://job-boards.greenhouse.io/acme/jobs/4012?gh_src=mail.";
    let f = filer::file(k.rows(), &NoStore, &mail("Acme Hiring <no-reply@us.greenhouse-mail.io>", "Your application", body));
    assert!(f.filed);
    assert_eq!((f.application_id, f.corporation_id), (Some(1), Some(1)));
    assert!(kinds(&f).contains(&"url") && kinds(&f).contains(&"ats_tenant"), "{:?}", kinds(&f));
    assert_eq!(f.confirms, Some(20));
}

#[test]
fn a_company_with_two_live_applications_needs_the_role_to_file() {
    let k = rows();
    // The sender's domain is Acme's; the subject's role words pick one.
    let f = filer::file(k.rows(), &NoStore, &mail("Riley <riley@talent.acme.example>", "Staff Engineer, Search: next steps", "Can we talk Tuesday?"));
    assert_eq!((f.filed, f.application_id, f.corporation_id), (true, Some(1), Some(1)));
    assert!(kinds(&f).contains(&"role"));
    // No role named: both are candidates, nothing is filed on a guess.
    let f = filer::file(k.rows(), &NoStore, &mail("riley@acme.example", "Quick question", "Are you still interested?"));
    assert!(!f.filed && f.relevant);
    let mut apps: Vec<u32> = f.candidates.iter().filter(|c| c.table == "applications").map(|c| c.id).collect();
    apps.sort_unstable();
    assert_eq!(apps, [1, 2]);
}

#[test]
fn mail_that_reaches_no_part_of_the_desk_is_not_read() {
    let k = rows();
    let f = filer::file(k.rows(), &NoStore, &mail("newsletter@shop.example", "Big sale on keyboards", "50% off"));
    assert!(!f.relevant && !f.filed && f.candidates.is_empty());
    // A freemail stranger naming no company is not either.
    let f = filer::file(k.rows(), &NoStore, &mail("friend@gmail.com", "Dinner?", "Tonight at 8"));
    assert!(!f.relevant);
    // A tracking system's mail is job search, filed or not.
    let f = filer::file(k.rows(), &NoStore, &mail("no-reply@ashbyhq.com", "Your application to Hooli", "We got it."));
    assert!(f.relevant && !f.filed);
    assert_eq!(kinds(&f), ["ats_sender"]);
}

#[test]
fn a_bounce_names_the_mission_it_returns() {
    let k = rows();
    let body = "Delivery to the following recipient failed permanently: jobs@acme.example\n\nMessage-ID: <hm.Sent1@example.com>";
    let f = filer::file(k.rows(), &NoStore, &mail("Mail Delivery Subsystem <mailer-daemon@googlemail.com>", "Delivery Status Notification (Failure)", body));
    assert_eq!(f.bounce.map(|b| b.0), Some(21));
    assert!(f.filed && f.confirms.is_none());
    // The node's parsed report names it without the wording.
    let report = json!({"report": {"kind": "bounce", "original_message_id": "<hm.sent1@example.com>", "status": "5.1.1"}});
    let f = filer::file(k.rows(), &NoStore, &Input { headers: Some(&report), ..mail("postmaster@acme.example", "Undelivered", "") });
    assert_eq!(f.bounce.map(|b| b.0), Some(21));
    // A mailer-daemon quoting a mail hireme never sent returns nothing.
    let f = filer::file(k.rows(), &NoStore, &mail("mailer-daemon@googlemail.com", "Delivery Status Notification (Failure)", "Message-ID: <other@x.example>"));
    assert!(f.bounce.is_none());
}

#[test]
fn a_forged_sender_files_nothing() {
    let k = rows();
    let auth = json!({"authentication-results": "mx.google.com; spf=fail smtp.mailfrom=acme.example; dmarc=fail (p=REJECT) header.from=acme.example"});
    let input = Input { headers: Some(&auth), in_reply_to: "<hm.sent1@example.com>", ..mail("riley@acme.example", "Staff Engineer, Search: offer", "Sign here: https://evil.example") };
    let f = filer::file(k.rows(), &NoStore, &input);
    assert!(f.relevant && !f.filed && f.bounce.is_none() && f.confirms.is_none());
    assert_eq!(kinds(&f)[0], "dmarc_fail");
    assert!(!kinds(&f).contains(&"sender_domain"));
    // Nor does a forged bounce fail the mission it names.
    let bounce = Input { headers: Some(&auth), ..mail("mailer-daemon@acme.example", "Delivery Status Notification (Failure)", "Message-ID: <hm.Sent1@example.com>") };
    assert!(filer::file(k.rows(), &NoStore, &bounce).bounce.is_none());
}

#[test]
fn a_known_person_files_to_them() {
    let k = rows();
    let f = filer::file(k.rows(), &NoStore, &mail("dana@globex.example", "Coffee next week?", "Hi!"));
    assert_eq!((f.filed, f.contact_id, f.corporation_id, f.application_id), (true, Some(7), Some(3), None));
}

#[test]
fn certain_evidence_that_disagrees_files_nothing() {
    let k = rows();
    // A reply in mission 21's thread (application 2) linking application 1's posting.
    let f = filer::file(
        k.rows(),
        &NoStore,
        &Input { in_reply_to: "<hm.sent1@example.com>", ..mail("x@gmail.com", "Re:", "See https://job-boards.greenhouse.io/acme/jobs/4012") },
    );
    assert!(!f.filed);
    let mut apps: Vec<u32> = f.candidates.iter().map(|c| c.id).collect();
    apps.sort_unstable();
    assert_eq!(apps, [1, 2]);
}

#[test]
fn the_node_asks_with_the_envelope_as_json() {
    let k = rows();
    let req = json!({"op": "mail_match", "from": "Acme Hiring <no-reply@us.greenhouse-mail.io>", "to": ["ana@example.com"],
        "subject": "Your application", "text": "thanks for applying: https://job-boards.greenhouse.io/acme/jobs/4012"});
    let a = filer::match_json(k.rows(), &NoStore, &req);
    assert_eq!((a["relevant"].as_bool(), a["filing"].as_str(), a["application_id"].as_u64(), a["confirms"].as_u64()), (Some(true), Some("filed"), Some(1), Some(20)));
}
