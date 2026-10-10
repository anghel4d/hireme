//! hireme-mcp: a stdio MCP server for agents such as Claude Code.
//!
//! An agent is a client of hireme exactly as a browser is. hireme-mcp
//! holds one session (WebTransport, or the `/wire` WebSocket where UDP is
//! blocked), receives the account's raw tables and every delta, and keeps
//! them resident in the desk kernel (`native/kernel`), the same code the
//! browser runs as WebAssembly. Every read is answered here from that
//! copy. The agent holds one lease: a contiguous block of applications
//! (entries 1..n, in the order they were added), taken with `lease` and
//! given back with `release` or when the session ends. Writes to those
//! applications go up as the binary ops the browser sends, and Elixir
//! decides them. Every tool called with `{}` prints its call shape, and
//! every refusal reads like a rustc diagnostic (`diag.rs`).
//!
//! Configuration is read from the environment: `HIREME_API_KEY`
//! (required); `HIREME_WT_URL` (e.g. `https://host/wt`); `HIREME_WS_URL`
//! (e.g. `wss://host`, the fallback); `HIREME_TRANSPORT` = `auto` | `wt`
//! | `ws`; and, for a development gate's self-signed certificate,
//! `HIREME_WT_CERT_SHA256` or `HIREME_WT_CERT_SHA256_FILE`.

// A diagnostic is a tool's whole error answer, built once per refusal: its size
// is not on any hot path.
#![allow(clippy::result_large_err)]

mod carrier;
mod diag;

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use carrier::{Config, Link};
use diag::Diag;
use kernel::Desk;
use kernel::schema::{self, col, frame, op, table};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

const EVENTS_KEPT: usize = 256;
const PROTOCOL: &str = "2025-06-18";
/// RPC replies are keyed apart from op ids.
const RPC_KEY: u64 = 1 << 63;
/// A block's size when the agent names none.
const BLOCK: u32 = 16;

enum Answer {
    Ack,
    Nack(u8, String),
    Rpc(Value),
}

/// The agent's lease: entries `from..=to`, the lane its writes ride, and
/// the applications it holds as (entry, job id).
#[derive(Clone)]
struct Block {
    from: u32,
    to: u32,
    lane: u64,
    jobs: Vec<(u32, u32)>,
}

impl Block {
    fn holds(&self, job: u32) -> bool {
        self.jobs.iter().any(|&(_, j)| j == job)
    }
}

/// A tool's answer: a value and any warnings, or one diagnostic.
type Reply = Result<(Value, Vec<Diag>), Diag>;
type Outcome = Result<Value, String>;

struct Hub {
    cfg: Config,
    out: mpsc::UnboundedSender<Value>,
    link: tokio::sync::Mutex<Option<Arc<Link>>>,
    desk: Mutex<Desk>,
    /// Frames received but not yet ingested: the desk takes them in one
    /// batch when a read needs it, so a write's answer never waits on a
    /// re-derive.
    unread: Mutex<Vec<u8>>,
    waits: Mutex<HashMap<u64, oneshot::Sender<Answer>>>,
    block: Mutex<Option<Block>>,
    events: Mutex<HashMap<u32, VecDeque<Value>>>,
    /// Op ids are the account's ledger keys: this run's random high half, then a count.
    next_op: AtomicU64,
    frames: AtomicU64,
    delivered: AtomicU64,
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let cfg = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("hireme-mcp: {e}");
            std::process::exit(2);
        }
    };

    let (out, mut out_rx) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(v) = out_rx.recv().await {
            let mut line = serde_json::to_vec(&v).unwrap_or_default();
            line.push(b'\n');
            if stdout.write_all(&line).await.is_err() || stdout.flush().await.is_err() {
                std::process::exit(0);
            }
        }
    });

    let hub = Arc::new(Hub {
        cfg,
        out,
        link: tokio::sync::Mutex::new(None),
        desk: Mutex::new(Desk::new()),
        unread: Mutex::new(Vec::new()),
        waits: Mutex::new(HashMap::new()),
        block: Mutex::new(None),
        events: Mutex::new(HashMap::new()),
        next_op: AtomicU64::new(run_id() << 32 | 1),
        frames: AtomicU64::new(0),
        delivered: AtomicU64::new(0),
    });

    // Connect while the agent is still initializing, so the desk is
    // resident before the first call. A failure goes to stderr, where an
    // MCP host logs its servers, and is reported again by that call.
    let warm = hub.clone();
    tokio::spawn(async move {
        if let Err(e) = warm.link().await {
            eprintln!("hireme-mcp: {e}");
        }
    });

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let hub = hub.clone();
        tokio::spawn(async move {
            let reply = match serde_json::from_str::<Value>(&line) {
                Ok(msg) => hub.request(msg).await,
                Err(_) => Some(json!({"jsonrpc": "2.0", "id": null,
                    "error": {"code": -32700, "message": "parse error"}})),
            };
            if let Some(reply) = reply {
                let _ = hub.out.send(reply);
            }
        });
    }
}

impl Hub {
    // ---- MCP ----------------------------------------------------------------

    /// One message from the agent; `None` for notifications.
    async fn request(self: &Arc<Self>, msg: Value) -> Option<Value> {
        let id = msg.get("id").cloned()?;
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let result = match msg["method"].as_str().unwrap_or("") {
            "initialize" => Ok(initialize(&params)),
            "ping" | "logging/setLevel" => Ok(json!({})),
            "tools/list" => match self.link().await {
                Ok(_) => Ok(json!({"tools": self.with_desk(tools)})),
                Err(e) => Err((-32000, e)),
            },
            "tools/call" => Ok(self.call_tool(&params).await),
            _ => Err((-32601, "unknown method".to_string())),
        };
        Some(match result {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, message)) => {
                json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
            }
        })
    }

    async fn call_tool(self: &Arc<Self>, params: &Value) -> Value {
        let name = params["name"].as_str().unwrap_or("");
        let a = match &params["arguments"] {
            Value::Object(m) => Value::Object(m.clone()),
            _ => json!({}),
        };
        let reply = match self.link().await {
            Err(e) => Err(Diag::error("session", "hireme could not be reached").note(e)),
            Ok(_) => self.tool(name, &a).await,
        };
        match reply {
            // Help and usage are text to read; everything else is data.
            Ok((Value::String(text), _)) => json!({"content": [{"type": "text", "text": text}]}),
            Ok((v, warnings)) => {
                let shown: Vec<String> = warnings.iter().map(Diag::render).collect();
                let text =
                    shown.iter().map(|w| format!("{w}\n\n")).collect::<String>() + &v.to_string();
                let mut v = v;
                if !shown.is_empty() {
                    v["warnings"] = json!(shown);
                }
                json!({"content": [{"type": "text", "text": text}], "structuredContent": v})
            }
            Err(d) => json!({"content": [{"type": "text", "text": d.render()}], "isError": true}),
        }
    }

    /// Every tool, matched on its name and whether it was called blank:
    /// a blank call is the base case and prints the tool's call shape.
    async fn tool(self: &Arc<Self>, name: &str, a: &Value) -> Reply {
        let blank = a.as_object().is_none_or(Map::is_empty);
        match (name, blank) {
            ("hireme", true) => Ok((json!(self.overview()), vec![])),
            ("hireme", false) => explained(a),
            ("lease", true) => Ok((json!(self.usage_with_next("lease")), vec![])),
            ("lease", false) => self.lease(a).await,
            ("release", _) => self.release().await,
            ("block", _) => self.block_rows(),
            ("letterbox_events", _) => Ok((self.drain_events(a), vec![])),
            (_, true) if needs_arguments(name) => Ok((json!(usage(name)), vec![])),
            ("application", false) => {
                let (job, _) = self.target(name, a)?;
                self.with_desk(|d| json_text(&d.focus_json(job)))
                    .map(|v| (v, vec![]))
                    .map_err(|e| Diag::error("internal", e))
            }
            ("set_stage", false) => {
                self.stage(a)?;
                self.write_job(name, a, op::STAGE, vec![text(&a["stage"])])
                    .await
            }
            ("set_next_action", false) => {
                let fields = vec![text(&a["next_action"]), text(&a["next_due"])];
                self.write_job(name, a, op::NEXT, fields).await
            }
            ("set_score", false) => {
                self.write_job(name, a, op::SCORE, vec![text(&a["score"])])
                    .await
            }
            ("tailor_line", false) => {
                let fields = ["item_id", "mode", "body", "reason", "title"].map(|k| text(&a[k]));
                self.write_job(name, a, op::OVERLAY, fields.to_vec()).await
            }
            ("open_cv_generation", false) => self.write_job(name, a, op::GENERATION, vec![]).await,
            ("can_apply", false) => {
                let (job, _) = self.target(name, a)?;
                self.read(|d| verdict(d, job))
            }
            ("list_applications", _) => {
                let limit = a["limit"]
                    .as_u64()
                    .map_or(100, |l| l.clamp(1, 1000) as usize);
                self.read(|d| json_text(&d.applications_json(&query(a, "all", -1, limit))))
            }
            ("recommend_applications", _) => {
                let limit = a["limit"].as_u64().map_or(25, |l| l.clamp(1, 100) as usize);
                self.read(|d| json_text(&d.recommend_json(&query(a, "open", 90, limit))))
            }
            ("score_distribution", _) => {
                self.read(|d| json_text(&d.distribution_json(&query(a, "all", -1, usize::MAX))))
            }
            ("heat_status", _) => {
                let s = |k: &str| a[k].as_str().unwrap_or("").to_string();
                self.read(|d| json_text(&d.heat_json(&s("company"), &s("ats"))))
            }
            ("list_batches", _) => {
                self.read(|d| Ok(json!({"batches": all_rows(d, table::BATCHES)})))
            }
            ("gym_status", _) => self.read(|d| lanes(d, "gym")),
            ("net_status", _) => self.read(|d| lanes(d, "net")),
            ("gym_log", false) => self.write_desk(name, a, op::GYM_LOG, pairs(a)).await,
            ("gym_set_target", false) => {
                self.write_desk(name, a, op::GYM_TARGET, vec![text(&a["target"])])
                    .await
            }
            ("net_log", false) => self.write_desk(name, a, op::NET_LOG, pairs(a)).await,
            ("net_set_lane", false) => {
                self.write_desk(name, a, op::NET_LANE, vec![text(&a["url"])])
                    .await
            }
            (name, _) => Err(
                Diag::error("argument", format!("there is no tool `{name}`"))
                    .help("hireme {} lists every tool and how to start"),
            ),
        }
    }

    fn read(&self, f: impl FnOnce(&mut Desk) -> Outcome) -> Reply {
        self.with_desk(f)
            .map(|v| (v, vec![]))
            .map_err(|e| Diag::error("internal", e))
    }

    fn with_desk<T>(&self, f: impl FnOnce(&mut Desk) -> T) -> T {
        let mut desk = self.desk.lock().unwrap();
        let unread = std::mem::take(&mut *self.unread.lock().unwrap());
        if !unread.is_empty() {
            desk.ingest(&unread);
        }
        f(&mut desk)
    }

    // ---- help ---------------------------------------------------------------

    /// The blank call's answer: what hireme is, where this agent stands, and how to work.
    fn overview(&self) -> String {
        let n = self.with_desk(|d| entries(d).last().map_or(0, |e| e.0));
        let carrier = self
            .link
            .try_lock()
            .ok()
            .and_then(|l| l.as_ref().map(|l| l.name))
            .unwrap_or("connecting");
        let mine = match self.block.lock().unwrap().clone() {
            Some(b) => format!(
                "entries {}..{} ({} applications)",
                b.from,
                b.to,
                b.jobs.len()
            ),
            None => "none yet".into(),
        };
        let next = self.next_lease();
        format!(
            "hireme: a job-search desk for agents. FIRE HOLD: nothing here submits an application.

This agent has one session ({carrier}) and holds at most one lease: a block of applications.
Desk: {n} applications, numbered as entries 1..{n} in the order they were added.
Your block: {mine}.

How to work:
  1. {next}
       take the first free block of {BLOCK}; or name one: lease {{\"from\":1,\"to\":16}}
  2. block {{}}
       your block: entry, job_id, company, role, stage, score, next action
  3. application {{\"entry\":E}}
       one application: its fields, rail, events and composed CV (item ids for tailor_line)
  4. set_stage, set_next_action, set_score, tailor_line, open_cv_generation {{\"entry\":E, ...}}
       change applications in your block; answered when the server has written them
  5. release {{}}
       give the block back, then lease the next one

Reading the whole desk needs no lease: list_applications, recommend_applications,
score_distribution, heat_status, can_apply, list_batches, gym_status, net_status,
letterbox_events (changes to your block, also sent as log notifications).
Desk-wide writes need none either: gym_log, gym_set_target, net_log, net_set_lane.

Any tool called with {{}} prints its call shape. A refusal reads like a rustc
diagnostic: error[code], the call with the bad argument marked, note: why, and
help: the corrected call to copy. hireme {{\"explain\":\"<code>\"}} prints a code's long form.

NEXT: {next}"
        )
    }

    fn usage_with_next(&self, tool: &str) -> String {
        format!("{}\n\nNEXT: {}", usage(tool), self.next_lease())
    }

    /// The lease call to make now: the desk picks a free block of the size.
    fn next_lease(&self) -> String {
        format!("lease {{\"count\":{BLOCK}}}")
    }

    // ---- the lease ----------------------------------------------------------

    async fn lease(self: &Arc<Self>, a: &Value) -> Reply {
        let want = match (a.get("count"), a.get("from"), a.get("to")) {
            (Some(c), None, None) => int(c).map(|c| json!({"count": c})).ok_or("count"),
            (None, Some(f), t) => match (int(f), t.map(int)) {
                (Some(f), None) => Ok(json!({"from": f, "to": f + i64::from(BLOCK) - 1})),
                (Some(f), Some(Some(t))) => Ok(json!({"from": f, "to": t})),
                (None, _) => Err("from"),
                (_, Some(None)) => Err("to"),
            },
            (Some(_), _, _) => Err("count"),
            (None, None, _) => Err("from"),
        }
        .map_err(|field| {
            Diag::error(
                "argument",
                "lease takes a count, or a range from..to of entries",
            )
            .call("lease", a)
            .at(field, "expected a whole number here")
            .help(usage("lease"))
        })?;
        let reply = self.acquire(want, 3).await?;
        match (
            reply.get("result"),
            reply["error"]["data"].get("code").and_then(Value::as_str),
        ) {
            (Some(r), _) => {
                let pair = |p: &Value| Some((p[0].as_u64()? as u32, p[1].as_u64()? as u32));
                let block = Block {
                    from: r["from"].as_u64().unwrap_or(0) as u32,
                    to: r["to"].as_u64().unwrap_or(0) as u32,
                    lane: r["lane"].as_u64().unwrap_or(0),
                    jobs: r["jobs"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(pair)
                        .collect(),
                };
                let warnings = r["warnings"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|w| lease_warning(a, w, &block))
                    .chain(size_advice(a, &block))
                    .collect();
                *self.block.lock().unwrap() = Some(block.clone());
                Ok((self.with_desk(|d| block_view(d, &block)), warnings))
            }
            (None, Some(code)) => Err(lease_refused(
                a,
                code,
                &reply["error"]["data"],
                &self.next_lease(),
            )),
            (None, None) => {
                Err(Diag::error("internal", "the lease answer was empty").call("lease", a))
            }
        }
    }

    /// A count names no entries, so losing a race for a free run to another
    /// agent asking at the same moment is not the caller's mistake: ask again
    /// a few times before refusing. A range named outright is refused at once.
    async fn acquire(self: &Arc<Self>, want: Value, tries: u32) -> Result<Value, Diag> {
        let reply = self.rpc("lease/acquire", want.clone()).await?;
        let raced = reply["error"]["data"]["code"] == "busy" && want.get("count").is_some();
        match (raced, tries) {
            (true, 2..) => Box::pin(self.acquire(want, tries - 1)).await,
            _ => Ok(reply),
        }
    }

    async fn release(self: &Arc<Self>) -> Reply {
        let held = self.block.lock().unwrap().take();
        self.rpc("lease/release", json!({})).await?;
        let released = held.map(|b| json!({"from": b.from, "to": b.to}));
        Ok((
            json!({"released": released, "next": self.next_lease()}),
            vec![],
        ))
    }

    fn block_rows(&self) -> Reply {
        let block = self.block.lock().unwrap().clone().ok_or_else(|| {
            Diag::error("leased", "this agent holds no block yet")
                .note("an agent writes only the applications its block holds")
                .help(format!("take one:\n{}", self.next_lease()))
        })?;
        Ok((self.with_desk(|d| block_view(d, &block)), vec![]))
    }

    /// The job a call names, by `job_id` or `entry`, and its entry.
    fn target(&self, tool: &str, a: &Value) -> Result<(u32, u32), Diag> {
        let ids = self.with_desk(entries);
        let job = a.get("job_id").or(a.get("role_id")).and_then(int);
        let entry = a.get("entry").and_then(int);
        let found = ids
            .iter()
            .find(|&&(e, j)| job.map_or(entry == Some(i64::from(e)), |job| i64::from(j) == job))
            .map(|&(e, j)| (j, e));
        let field = if a.get("job_id").is_some() {
            "job_id"
        } else {
            "entry"
        };
        found.ok_or_else(|| {
            Diag::error(
                "not_found",
                format!("no application on this desk matches that {field}"),
            )
            .call(tool, a)
            .at(
                field,
                format!(
                    "expected a job id from block {{}}, or an entry in 1..{}",
                    ids.last().map_or(0, |e| e.0)
                ),
            )
            .help(format!(
                "{}\n{tool} {{\"entry\":E, ...}}",
                usage(tool).lines().next().unwrap_or("")
            ))
        })
    }

    /// One write to an application: it must be in this agent's block.
    async fn write_job(
        self: &Arc<Self>,
        tool: &str,
        a: &Value,
        kind: u8,
        fields: Vec<String>,
    ) -> Reply {
        let (job, entry) = self.target(tool, a)?;
        let block = self.block.lock().unwrap().clone();
        match &block {
            Some(b) if b.holds(job) => {}
            Some(b) => {
                return Err(Diag::error("leased", format!("entry {entry} is not in your block {}..{}", b.from, b.to))
                    .call(tool, a)
                    .at(if a.get("job_id").is_some() { "job_id" } else { "entry" }, format!("job {job}, outside your block"))
                    .note(self.describe(job))
                    .help(format!(
                        "work inside your block (block {{}} lists it), or move to this one:\nrelease {{}}\nlease {{\"from\":{entry},\"to\":{}}}",
                        entry + BLOCK - 1
                    )));
            }
            None => {
                return Err(Diag::error("leased", "this agent holds no block yet")
                    .call(tool, a)
                    .note(self.describe(job))
                    .help(format!("take the block that starts at this entry:\nlease {{\"from\":{entry},\"to\":{}}}", entry + BLOCK - 1)));
            }
        }
        let lane = block.map_or(0, |b| b.lane);
        match self.write(kind, lane, job, fields).await {
            Ok(()) => Ok((json!({"ok": true, "job_id": job, "entry": entry}), vec![])),
            Err((code, msg)) => Err(self.refused(tool, a, job, code, &msg)),
        }
    }

    async fn write_desk(
        self: &Arc<Self>,
        tool: &str,
        a: &Value,
        kind: u8,
        fields: Vec<String>,
    ) -> Reply {
        match self.write(kind, 0, 0, fields).await {
            Ok(()) => Ok((json!({"ok": true}), vec![])),
            Err((code, msg)) => Err(self.refused(tool, a, 0, code, &msg)),
        }
    }

    /// The server refused a write: a diagnostic per refusal code.
    fn refused(&self, tool: &str, a: &Value, job: u32, code: u8, msg: &str) -> Diag {
        let name = schema::REFUSALS
            .iter()
            .find(|r| r.0 == code)
            .map_or("internal", |r| r.1);
        let base = Diag::error(name, format!("{tool} was refused: {msg}")).call(tool, a);
        match name {
            "argument" => {
                let field = msg.trim_start_matches("Need a ").trim_end_matches('.').to_string();
                base.at(&field, "not a value this tool accepts").help(usage(tool))
            }
            "heat" => base
                .note(self.with_desk(|d| verdict(d, job)).map_or(String::new(), |v| {
                    format!(
                        "{}: company load {} of cap {}, cooldown {} days",
                        v["company"], v["company_load"], v["company_cap"], v["cooldown_days"]
                    )
                }))
                .help(format!("check before queueing, or pick a cooler one:\ncan_apply {{\"job_id\":{job}}}\nrecommend_applications {{}}")),
            "cooldown" | "not_additive" => base
                .note("CV generations are rewritable for 90 days, then additive only")
                .help(format!("open an additive generation, then add lines:\nopen_cv_generation {{\"job_id\":{job}}}")),
            "lineage_busy" => base
                .note(format!("{}; another agent's block wrote this employer's CV first", self.describe(job)))
                .help("stages, scores and next actions still work here; tailor another employer's CV in your block (block {})"),
            "leased" => base
                .note(self.describe(job))
                .help("block {} lists what this agent may write"),
            "not_found" if tool == "tailor_line" => {
                Diag::error("not_found", format!("item {} is not a line of this application's CV", a["item_id"]))
                    .call(tool, a)
                    .at("item_id", "no such line")
                    .help(format!(
                        "item ids are the CV's lines: application {{\"job_id\":{job}}} shows cv.sections[].lines[].id"
                    ))
            }
            "fire_hold" => base.note("the batch is on hold; nothing here submits an application"),
            _ => base,
        }
    }

    /// A stage the desk knows, or a diagnostic naming the ones it does.
    fn stage(&self, a: &Value) -> Result<(), Diag> {
        let want = a["stage"].as_str().unwrap_or("");
        let known: Vec<String> = self.with_desk(|d| {
            (0..d.rows(table::STAGES))
                .map(|r| d.str_at(table::STAGES, 2, r).to_string())
                .collect()
        });
        match known.iter().min_by_key(|k| distance(k, want)) {
            Some(k) if k == want => Ok(()),
            closest => {
                let mut fixed = a.clone();
                fixed["stage"] = json!(closest.cloned().unwrap_or_default());
                Err(Diag::error("argument", format!("`{want}` is not a stage"))
                    .call("set_stage", a)
                    .at("stage", "unknown stage")
                    .note(format!("stages, in battleplan order: {}", known.join(", ")))
                    .help(format!(
                        "the closest is `{}`:\nset_stage {fixed}",
                        fixed["stage"].as_str().unwrap_or("")
                    )))
            }
        }
    }

    /// One line naming an application, for notes.
    fn describe(&self, job: u32) -> String {
        self.with_desk(|d| {
            d.row_of(table::CARDS, job)
                .map_or(format!("job {job}"), |r| {
                    format!(
                        "job {job} is {} — {}",
                        d.str_at(table::CARDS, col::cards::COMPANY, r),
                        d.str_at(table::CARDS, col::cards::ROLE, r)
                    )
                })
        })
    }

    // ---- the session --------------------------------------------------------

    async fn link(self: &Arc<Self>) -> Result<Arc<Link>, String> {
        let mut slot = self.link.lock().await;
        if let Some(l) = slot.as_ref().filter(|l| l.alive()) {
            return Ok(l.clone());
        }
        *self.desk.lock().unwrap() = Desk::new();
        self.unread.lock().unwrap().clear();
        let hub = Arc::downgrade(self);
        let closed = Arc::downgrade(self);
        let link = carrier::connect(
            &self.cfg,
            Arc::new(move |f| {
                if let Some(hub) = hub.upgrade() {
                    hub.frame(f)
                }
            }),
            move || {
                if let Some(hub) = closed.upgrade() {
                    hub.session_lost()
                }
            },
        )
        .await?;
        let link = Arc::new(link);
        *slot = Some(link.clone());
        Ok(link)
    }

    /// One frame from the server, in order.
    fn frame(&self, f: wire::Frame<'_>) {
        self.frames.fetch_add(1, Ordering::Relaxed);
        match f.header.kind {
            frame::BOOT | frame::PATCH | frame::TICK => {
                if f.header.kind == frame::PATCH {
                    self.notify_rows(&f);
                }
                // Deflated ones too: the kernel's ingest inflates them.
                let mut unread = self.unread.lock().unwrap();
                unread.extend_from_slice(&f.header.bytes());
                unread.extend_from_slice(f.body);
            }
            frame::ACK => {
                if let Ok(op_id) = wire::ack(f.body) {
                    self.answer(op_id, Answer::Ack);
                }
            }
            frame::NACK => {
                if let Ok((op_id, code, msg)) = wire::nack(f.body) {
                    self.answer(op_id, Answer::Nack(code, msg.to_string()));
                }
            }
            frame::RPC => {
                let reply = f.body.get(0..4).and_then(|n| {
                    let n = u32::from_le_bytes(n.try_into().ok()?) as usize;
                    serde_json::from_slice::<Value>(f.body.get(8..8 + n)?).ok()
                });
                if let Some(id) = reply.as_ref().and_then(|r| r["id"].as_u64()) {
                    self.answer(RPC_KEY | id, Answer::Rpc(reply.unwrap_or_default()));
                }
            }
            _ => {}
        }
    }

    fn answer(&self, key: u64, answer: Answer) {
        if let Some(tx) = self.waits.lock().unwrap().remove(&key) {
            let _ = tx.send(answer);
        }
    }

    /// Send one frame and wait for what answers it.
    async fn ask(self: &Arc<Self>, key: u64, bytes: Vec<u8>) -> Result<Answer, Diag> {
        let (tx, rx) = oneshot::channel();
        self.waits.lock().unwrap().insert(key, tx);
        let lost = |why: String| Diag::error("session", "the session answered nothing").note(why);
        self.link().await.map_err(lost)?.send(bytes).map_err(lost)?;
        match tokio::time::timeout(Duration::from_secs(10), rx).await {
            Ok(Ok(answer)) => Ok(answer),
            Ok(Err(_)) => Err(lost("the session closed; the next call reconnects".into())),
            Err(_) => {
                self.waits.lock().unwrap().remove(&key);
                Err(lost("no answer in 10 s".into()))
            }
        }
    }

    /// One op on the session. Its answer comes after its delta, so the
    /// desk shows what it wrote once that delta is read.
    async fn write(
        self: &Arc<Self>,
        kind: u8,
        lane: u64,
        target: u32,
        fields: Vec<String>,
    ) -> Result<(), (u8, String)> {
        let op_id = self.next_op.fetch_add(1, Ordering::Relaxed);
        let mut w = wire::Writer::new();
        w.begin(frame::OP, 0, lane);
        w.op(
            op_id,
            kind,
            target,
            &fields.iter().map(String::as_str).collect::<Vec<_>>(),
        );
        w.end();
        match self.ask(op_id, w.buf).await {
            Ok(Answer::Ack) => Ok(()),
            Ok(Answer::Nack(code, msg)) => Err((code, msg)),
            Ok(Answer::Rpc(_)) => Err((10, "an unexpected answer".into())),
            Err(d) => Err((10, d.render())),
        }
    }

    /// One lease RPC: `{id, method, params}` up, `{id, result | error}` down.
    async fn rpc(self: &Arc<Self>, method: &str, params: Value) -> Result<Value, Diag> {
        let id = self.next_op.fetch_add(1, Ordering::Relaxed) & !RPC_KEY;
        let json = serde_json::to_vec(&json!({"id": id, "method": method, "params": params}))
            .unwrap_or_default();
        let mut body = (json.len() as u32).to_le_bytes().to_vec();
        body.extend_from_slice(&[0; 4]);
        body.extend_from_slice(&json);
        match self
            .ask(RPC_KEY | id, carrier::frame(frame::RPC, 0, &body))
            .await?
        {
            Answer::Rpc(v) => Ok(v),
            _ => Err(Diag::error(
                "internal",
                format!("{method} answered with an op's reply"),
            )),
        }
    }

    fn session_lost(&self) {
        let lost = self.block.lock().unwrap().take();
        self.waits.lock().unwrap().clear();
        for (_, job) in lost.map(|b| b.jobs).unwrap_or_default() {
            self.notify(job, json!({"type": "lease_lost", "job_id": job}));
        }
    }

    // ---- desk changes to the block --------------------------------------------

    /// A PATCH's application rows and deletions, for the jobs in the block.
    fn notify_rows(&self, f: &wire::Frame<'_>) {
        let held: Vec<u32> = self
            .block
            .lock()
            .unwrap()
            .as_ref()
            .map(|b| b.jobs.iter().map(|&(_, j)| j).collect())
            .unwrap_or_default();
        if held.is_empty() {
            return;
        }
        for t in f.tables().flatten() {
            if t.id == table::JOB_APPS
                && let Some(ids) = t.col(col::job_apps::ID)
            {
                for i in (0..t.nrows as usize).filter(|&i| held.contains(&ids.u32(i))) {
                    let mut row = Map::new();
                    for c in t.cols() {
                        if let Some(def) = schema::col_def(t.id, c.id)
                            && def.name != "listing"
                        {
                            row.insert(def.name.into(), cell(&c, i, def.kind));
                        }
                    }
                    // A row that is only its id moved nothing an agent reads.
                    if row.len() > 1 {
                        self.notify(ids.u32(i), json!({"type": "row", "application": row}));
                    }
                }
            }
            if t.id == table::GONE
                && let (Some(tables), Some(ids)) = (t.col(col::gone::TABLE), t.col(col::gone::ID))
            {
                for i in 0..t.nrows as usize {
                    if tables.u32(i) == u32::from(table::JOB_APPS) && held.contains(&ids.u32(i)) {
                        self.notify(ids.u32(i), json!({"type": "gone", "job_id": ids.u32(i)}));
                    }
                }
            }
        }
    }

    /// A desk event for the block: a log notification, and kept for polling.
    fn notify(&self, job: u32, event: Value) {
        self.delivered.fetch_add(1, Ordering::Relaxed);
        let mut events = self.events.lock().unwrap();
        let q = events.entry(job).or_default();
        if q.len() == EVENTS_KEPT {
            q.pop_front();
        }
        q.push_back(event.clone());
        let _ = self.out.send(json!({
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {"level": "info", "logger": format!("hireme/job/{job}"), "data": event},
        }));
    }

    fn drain_events(&self, a: &Value) -> Value {
        let mut events = self.events.lock().unwrap();
        let jobs: Vec<u32> = match a.get("job_id").or(a.get("role_id")).and_then(int) {
            Some(job) => vec![job as u32],
            None => events.keys().copied().collect(),
        };
        let mut drained = Vec::new();
        for j in jobs {
            drained.extend(events.get_mut(&j).into_iter().flat_map(|q| q.drain(..)));
        }
        json!({"events": drained})
    }
}

/// `hireme {"explain":"<code>"}`: a code's long form.
fn explained(a: &Value) -> Reply {
    let code = a["explain"].as_str().unwrap_or("");
    diag::explain(code)
        .map(|t| (json!(t), vec![]))
        .ok_or_else(|| {
            Diag::error("argument", format!("no diagnostic code `{code}`"))
                .call("hireme", a)
                .at("explain", "not a code hireme-mcp uses")
                .help("codes appear in brackets: error[busy] → hireme {\"explain\":\"busy\"}")
        })
}

fn lease_refused(a: &Value, code: &str, data: &Value, next: &str) -> Diag {
    let n = data["n"].as_u64().unwrap_or(0);
    let field = if a.get("count").is_some() {
        "count"
    } else {
        "from"
    };
    match code {
        "busy" => {
            let held: Vec<u64> = data["held"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_u64)
                .collect();
            let help = match data["free"]
                .as_array()
                .map(|f| (f[0].as_u64(), f[1].as_u64()))
            {
                Some((Some(f), Some(t))) => format!(
                    "entries {f}..{t} are free, the same size:\nlease {{\"from\":{f},\"to\":{t}}}"
                ),
                _ => "ask by size, and the desk finds a free run:\nlease {\"count\":8}".into(),
            };
            let label = match held.as_slice() {
                [] => "no free run of that size".to_string(),
                [one] => format!("entry {one} is held by another agent"),
                many => format!("entries {} are held by other agents", runs(many)),
            };
            Diag::error("busy", "the block overlaps another agent's")
                .call("lease", a)
                .at(field, label)
                .note("a block is all or nothing: nothing was leased")
                .help(help)
        }
        "empty" => Diag::error(
            "empty",
            format!("that range names no application: entries run 1..{n}"),
        )
        .call("lease", a)
        .at(field, format!("outside 1..{n}"))
        .help(format!(
            "lease a range inside 1..{n}, or by size:\n{}",
            next
        )),
        "held" => {
            let (f, t) = (
                data["from"].as_u64().unwrap_or(0),
                data["to"].as_u64().unwrap_or(0),
            );
            Diag::error("held", format!("this agent already holds entries {f}..{t}"))
                .call("lease", a)
                .note("one session holds one block")
                .help("give it back first, then lease again:\nrelease {}")
        }
        other => {
            Diag::error("internal", format!("the lease was refused: {other}")).call("lease", a)
        }
    }
}

/// Held entries as runs: 3, 10..16.
fn runs(entries: &[u64]) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut start = 0;
    for i in 1..=entries.len() {
        if i == entries.len() || entries[i] != entries[i - 1] + 1 {
            out.push(match i - start {
                1 => entries[start].to_string(),
                _ => format!("{}..{}", entries[start], entries[i - 1]),
            });
            start = i;
        }
    }
    out.join(", ")
}

/// A block whose size is not a power of two works, but reads oddly.
fn size_advice(a: &Value, b: &Block) -> Option<Diag> {
    let size = b.to + 1 - b.from;
    match size.is_power_of_two() {
        true => None,
        false => {
            let (down, up) = (1 << (31 - size.leading_zeros()), size.next_power_of_two());
            let field = if a.get("count").is_some() {
                "count"
            } else {
                "to"
            };
            Some(
                Diag::warning(
                    "size",
                    format!("a block of {size} entries; prefer a power of two"),
                )
                .call("lease", a)
                .at(field, format!("{size} entries"))
                .note("the lease is granted as asked; blocks of 8, 16 or 32, aligned to their size, tile the desk and merge back whole")
                .help(format!(
                    "next time, {down} or {up}:\nlease {{\"from\":{},\"to\":{}}}",
                    (b.from - 1) / up * up + 1,
                    (b.from - 1) / up * up + up
                )),
            )
        }
    }
}

/// A server warning about a lease, as a diagnostic.
fn lease_warning(a: &Value, w: &Value, b: &Block) -> Diag {
    let n = w["n"].as_u64().unwrap_or(0);
    match w["code"].as_str().unwrap_or("") {
        "truncated" => Diag::warning(
            "truncated",
            format!(
                "entries {}..{} truncated to {}..{}",
                w["asked"][0], w["asked"][1], b.from, b.to
            ),
        )
        .call("lease", a)
        .at("to", format!("the desk has {n} applications"))
        .note("the lease covers the part of the range that exists"),
        "count_capped" => Diag::warning(
            "count_capped",
            format!("asked for {} entries; the desk has {n}", w["asked"]),
        )
        .call("lease", a)
        .at("count", format!("capped to {n}")),
        "align" => {
            let (f, t) = (&w["aligned"][0], &w["aligned"][1]);
            let size = b.to + 1 - b.from;
            Diag::warning(
                "align",
                format!("entries {}..{} are a block of {size} off its alignment", b.from, b.to),
            )
            .call("lease", a)
            .at("from", "granted as asked")
            .note(format!(
                "blocks of {size} align at 1, {}, {}, ...: aligned blocks tile the desk and merge back whole",
                size + 1,
                2 * size + 1
            ))
            .help(format!("the aligned block holding entry {}:\nlease {{\"from\":{f},\"to\":{t}}}", b.from))
        }
        other => Diag::warning("internal", format!("the lease carried a warning `{other}`")),
    }
}

/// The account's applications as (entry, job id), by entry: the account's
/// own numbering, which counts them in the order they were added.
fn entries(d: &mut Desk) -> Vec<(u32, u32)> {
    let t = table::JOB_APPS;
    let mut all: Vec<(u32, u32)> = (0..d.rows(t))
        .map(|r| {
            (
                d.u32_at(t, col::job_apps::NO, r),
                d.u32_at(t, col::job_apps::ID, r),
            )
        })
        .collect();
    all.sort_unstable();
    all
}

/// A block as the agent works through it: one line per application.
fn block_view(d: &mut Desk, b: &Block) -> Value {
    let keep = [
        "job_id",
        "company",
        "role",
        "stage",
        "score_100",
        "band",
        "next_action",
        "next_due",
        "heat_state",
        "batch",
    ];
    let rows: Vec<Value> = b
        .jobs
        .iter()
        .map(|&(entry, job)| {
            let card = json_text(&d.application_json(job)).unwrap_or_default();
            let mut line: Map<String, Value> = keep
                .iter()
                .map(|k| ((*k).to_string(), card[*k].clone()))
                .collect();
            line.insert("entry".into(), json!(entry));
            Value::Object(line)
        })
        .collect();
    json!({"from": b.from, "to": b.to, "applications": rows})
}

/// Edit distance, for "did you mean" helps.
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut prev = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cur = row[j + 1];
            row[j + 1] = (prev + usize::from(ca != *cb)).min(row[j] + 1).min(cur + 1);
            prev = cur;
        }
    }
    row[b.len()]
}

fn int(v: &Value) -> Option<i64> {
    match v {
        Value::Number(n) => n.as_i64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

// ---- reading the desk ---------------------------------------------------------

/// One row of any table, every column named as the schema names it.
fn row(d: &Desk, t: u16, r: usize) -> Map<String, Value> {
    let mut m = Map::new();
    for def in schema::COLS.iter().filter(|c| c.table == t) {
        let v = match def.kind {
            "str" | "sym" => json!(d.str_at(t, def.col, r)),
            "f64" => json!(d.f64_at(t, def.col, r))
                .as_f64()
                .map_or(Value::Null, |x| json!(x)),
            kind => match d.u32_at(t, def.col, r) {
                wire::NONE => Value::Null,
                v if kind == "day" => json!(iso_day(i64::from(v))),
                v => json!(v),
            },
        };
        m.insert(def.name.into(), v);
    }
    m
}

fn all_rows(d: &Desk, t: u16) -> Vec<Value> {
    (0..d.rows(t))
        .map(|r| Value::Object(row(d, t, r)))
        .collect()
}

/// The board's filters as a call names them, over this tool's defaults.
fn query<'a>(a: &'a Value, status: &'a str, min: i32, limit: usize) -> kernel::Query<'a> {
    let s = |k: &str| a.get(k).and_then(Value::as_str).unwrap_or("");
    kernel::Query {
        band: s("band"),
        stage: s("stage"),
        status: Some(s("status"))
            .filter(|x| !x.is_empty())
            .unwrap_or(status),
        heat: s("heat"),
        batch: s("batch"),
        min_score: a["min_score"].as_i64().map_or(min, |m| m as i32),
        q: s("q"),
        limit,
    }
}

fn verdict(d: &mut Desk, job: u32) -> Outcome {
    match json_text(&d.verdict_json(job))? {
        Value::Null => Err(format!("job {job}: not found")),
        v => Ok(v),
    }
}

fn lanes(d: &mut Desk, which: &str) -> Outcome {
    let all = json_text(&d.lanes_json())?;
    let mut lane = all[which].clone();
    lane["note"] = json!(match which {
        "gym" =>
            "Gym score is weekly conditioning pace (0–100), not Life-EV score_100. FIRE HOLD — does not submit.",
        _ => "Not CRM. Broadside Observer + shipped work. FIRE HOLD — does not submit.",
    });
    Ok(lane)
}

/// One of the kernel's composed views, the browser's own JSON.
fn json_text(s: &str) -> Outcome {
    serde_json::from_str(s).map_err(|e| format!("view: {e}"))
}

// ---- arguments ----------------------------------------------------------------

/// 32 bits that differ between runs, so this run's op ids are its own.
fn run_id() -> u64 {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64);
    (t ^ (u64::from(std::process::id()) << 16)) & 0xFFFF_FFFF
}

/// `job_id`, or as the distillation packs call it, `role_id`.
fn text(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// A gym or net entry's fields as the op carries them: key, value, ...
fn pairs(a: &Value) -> Vec<String> {
    a.as_object()
        .into_iter()
        .flatten()
        .flat_map(|(k, v)| [k.clone(), text(v)])
        .collect()
}

/// A cell of a raw row as a notification carries it.
fn cell(c: &wire::Col<'_>, i: usize, kind: &str) -> Value {
    match c.ty {
        wire::STR | wire::SYM if kind == "str" || kind == "sym" => {
            let s = c.str(i);
            serde_json::from_str::<Value>(s)
                .ok()
                .filter(Value::is_object)
                .unwrap_or_else(|| json!(s))
        }
        wire::U32 => match c.u32(i) {
            wire::NONE => Value::Null,
            v if kind == "day" => json!(iso_day(i64::from(v))),
            v => json!(v),
        },
        wire::U64 => json!(c.u64(i)),
        wire::F64 => json!(c.f64(i)).as_f64().map_or(Value::Null, |x| json!(x)),
        _ => Value::Null,
    }
}

/// Days since 1970-01-01 as `YYYY-MM-DD` (Howard Hinnant's civil_from_days).
fn iso_day(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

// ---- the tools ------------------------------------------------------------------

fn initialize(params: &Value) -> Value {
    json!({
        "protocolVersion": params["protocolVersion"].as_str().unwrap_or(PROTOCOL),
        "capabilities": {"tools": {"listChanged": false}, "logging": {}},
        "serverInfo": {"name": "hireme-mcp", "version": env!("CARGO_PKG_VERSION")},
        "instructions": "hireme is a job-search desk. Start with hireme {}: it says where this agent \
            stands and what to call next. This agent holds one lease, a block of consecutive \
            applications (lease {\"count\":16}), works through it (block {}, application, set_*, \
            tailor_line), and releases it (release {}). Any tool called with {} prints its call \
            shape; refusals read like rustc diagnostics, and hireme {\"explain\":\"<code>\"} gives the \
            long form. FIRE HOLD: nothing here submits an application."
    })
}

/// Each tool's call shape: its description, and what a blank call prints.
fn usage(tool: &str) -> &'static str {
    match tool {
        "hireme" => "Where this agent stands and how to work; the base case of every question.

Call shape: hireme {}  |  hireme {\"explain\":\"<code>\"}
- {}: the desk's size, this agent's block, the workflow, and NEXT: the call to make.
- explain: the long form of a diagnostic code, e.g. hireme {\"explain\":\"busy\"}.",
        "lease" => "Take this agent's one lease: a block of entries (the account's application numbers, 1..n).

Call shape: lease {\"count\":16}  |  lease {\"from\":1,\"to\":16}  |  lease {\"from\":17}
- count: a free block of that size, aligned (16: 1..16, 17..32, ...), picked by the desk.
- from..to: exactly those entries. from alone takes 16.
Response branching (do not guess); hireme {\"explain\":\"<code>\"} explains each code:
- granted: {from, to, applications:[{entry, job_id, company, role, stage, score_100, ...}]},
  after any warning[truncated | count_capped | size | align].
- refused, nothing leased: error[busy] (help: a free block), error[held], error[empty].",
        "release" => "Give this agent's block back.

Call shape: release {}
Response: {released:{from,to} | null, next:\"lease ...\"}: the block is free for any agent at once.",
        "block" => "This agent's block, one line per application.

Call shape: block {}
Response: {from, to, applications:[{entry, job_id, company, role, stage, score_100, next_action, heat_state, ...}]}.
error[leased] if this agent holds no block: help: names the lease call to make.",
        "application" => "One application in full: its fields, rail, events, heat, coverage and composed CV.

Call shape: application {\"entry\":E}  |  application {\"job_id\":J}
The CV's lines are cv.sections[].lines[]: each has id (the item_id tailor_line takes), mode, title, body.",
        "set_stage" => "Move an application in your block along the battleplan.

Call shape: set_stage {\"entry\":E,\"stage\":\"<stage>\"}  (or job_id instead of entry)
Response: {ok, job_id, entry} once written. error[leased] outside your block; error[argument] for an unknown stage; error[fire_hold] for submission stages.",
        "set_next_action" => "Set an application's next action, and optionally its due date.

Call shape: set_next_action {\"entry\":E,\"next_action\":\"<text>\",\"next_due\":\"YYYY-MM-DD\"}
Response: {ok, job_id, entry}.",
        "set_score" => "Set an application's score_100 (0..100).

Call shape: set_score {\"entry\":E,\"score\":90}
Response: {ok, job_id, entry}. error[argument] outside 0..100.",
        "tailor_line" => "Hide, emphasize, alter or restore one line of an application's CV.

Call shape: tailor_line {\"entry\":E,\"item_id\":I,\"mode\":\"hidden|emphasized|altered|inherit\",\"title\":\"...\",\"body\":\"...\",\"reason\":\"...\"}
item_id comes from application {\"entry\":E}: cv.sections[].lines[].id. title/body only for altered.
An employer's applications share one CV: the first agent to tailor it holds it (error[lineage_busy] for others).",
        "open_cv_generation" => "After the 90-day window, open an additive CV generation for an application's employer.

Call shape: open_cv_generation {\"entry\":E}
error[cooldown] inside the window.",
        "can_apply" => "Would queueing this application exceed its company or ATS heat? allow or defer, with the reason and cooldown.

Call shape: can_apply {\"entry\":E}  |  can_apply {\"job_id\":J}",
        "list_applications" => "The board, ranked by score_100 then cooler heat, filtered like the desk's top bar.

Call shape: list_applications {\"q\":\"...\",\"stage\":\"...\",\"status\":\"open\",\"batch\":\"B-1\",\"min_score\":80,\"band\":\"...\",\"heat\":\"cool\",\"limit\":100}  (all optional)",
        "recommend_applications" => "The open applications to draft first: score_100 ≥ 90 by default, heat-blocked ones left out.

Call shape: recommend_applications {}  |  {\"min_score\":80,\"limit\":25}",
        "score_distribution" => "score_100 band counts and ten-point bins over the filtered board.

Call shape: score_distribution {}  (list_applications' filters apply)",
        "heat_status" => "Company and ATS heat against cap, with cooldowns.

Call shape: heat_status {}  |  {\"company\":\"acme\"}  |  {\"ats\":\"greenhouse\"}",
        "list_batches" => "The batches on the desk.

Call shape: list_batches {}",
        "gym_status" => "Gym conditioning: daily target, streak, weekly pace (not score_100), topics.

Call shape: gym_status {}",
        "net_status" => "Networking lane: Broadside Observer URL, shipped work this week, drafts, observer runs. Not a CRM.

Call shape: net_status {}",
        "gym_log" => "Log a LeetCode / Codeforces / systems rep.

Call shape: gym_log {\"title\":\"...\",\"slug\":\"...\",\"platform\":\"leetcode\",\"topic\":\"dp\",\"difficulty\":\"medium\",\"outcome\":\"solved\",\"minutes\":20,\"url\":\"...\",\"note\":\"...\",\"done_on\":\"YYYY-MM-DD\"}",
        "gym_set_target" => "Set the gym's daily solved-rep target (1..30).

Call shape: gym_set_target {\"target\":3}",
        "net_log" => "Log an observer run, shipped artifact, post or draft. Not a CRM.

Call shape: net_log {\"kind\":\"artifact\",\"channel\":\"broadside\",\"title\":\"...\",\"url\":\"...\",\"body\":\"...\",\"shipped_on\":\"YYYY-MM-DD\"}",
        "net_set_lane" => "Set the Broadside Observer research lane URL.

Call shape: net_set_lane {\"url\":\"https://...\"}",
        "letterbox_events" => "Drain the changes to your block's applications (also sent as log notifications).

Call shape: letterbox_events {}  |  {\"job_id\":J}",
        _ => "No such tool: hireme {} lists them.",
    }
}

/// Tools whose blank call has nothing to act on, so it prints their call shape.
fn needs_arguments(tool: &str) -> bool {
    matches!(
        tool,
        "application"
            | "set_stage"
            | "set_next_action"
            | "set_score"
            | "tailor_line"
            | "open_cv_generation"
            | "can_apply"
            | "gym_log"
            | "gym_set_target"
            | "net_log"
            | "net_set_lane"
    )
}

fn tools(d: &mut Desk) -> Vec<Value> {
    let keys = |t: u16| -> Value { (0..d.rows(t)).map(|r| json!(d.str_at(t, 2, r))).collect() };
    let en = |t: u16| json!({"type": "string", "enum": keys(t)});
    let int = json!({"type": "integer"});
    let s = json!({"type": "string"});
    let score = json!({"type": "integer", "minimum": 0, "maximum": 100});
    let target = json!({"entry": {"type": "integer", "description": "An entry in your block (1..n)"},
                        "job_id": {"type": "integer", "description": "Or the application's job id"}});
    let filters = json!({"q": s, "stage": en(table::STAGES), "status": s, "batch": s,
        "min_score": score, "band": en(table::BANDS), "heat": en(table::HEAT_STATES), "limit": int});
    let with = |extra: Value| {
        let mut p = target.clone();
        p.as_object_mut()
            .unwrap()
            .extend(extra.as_object().cloned().unwrap_or_default());
        p
    };
    let schemas: [(&str, Value); 23] = [
        (
            "hireme",
            json!({"explain": {"type": "string", "description": "A diagnostic code, e.g. busy"}}),
        ),
        ("lease", json!({"count": int, "from": int, "to": int})),
        ("release", json!({})),
        ("block", json!({})),
        ("application", target.clone()),
        ("set_stage", with(json!({"stage": en(table::STAGES)}))),
        (
            "set_next_action",
            with(json!({"next_action": s, "next_due": s})),
        ),
        ("set_score", with(json!({"score": score}))),
        (
            "tailor_line",
            with(
                json!({"item_id": int, "mode": {"type": "string", "enum": ["hidden", "emphasized", "altered", "inherit"]}, "title": s, "body": s, "reason": s}),
            ),
        ),
        ("open_cv_generation", target.clone()),
        ("can_apply", target.clone()),
        ("list_applications", filters.clone()),
        ("recommend_applications", filters.clone()),
        ("score_distribution", filters),
        ("heat_status", json!({"company": s, "ats": s})),
        ("list_batches", json!({})),
        ("gym_status", json!({})),
        ("net_status", json!({})),
        (
            "gym_log",
            json!({"title": s, "slug": s, "platform": s, "topic": s, "difficulty": s, "outcome": s, "minutes": int, "url": s, "note": s, "done_on": s}),
        ),
        (
            "gym_set_target",
            json!({"target": {"type": "integer", "minimum": 1, "maximum": 30}}),
        ),
        (
            "net_log",
            json!({"kind": s, "channel": s, "title": s, "url": s, "body": s, "shipped_on": s}),
        ),
        ("net_set_lane", json!({"url": s})),
        ("letterbox_events", json!({"job_id": int})),
    ];
    schemas
        .into_iter()
        .map(|(name, props)| {
            json!({"name": name, "description": usage(name),
                   "inputSchema": {"type": "object", "properties": props}})
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_are_civil_dates() {
        assert_eq!(iso_day(0), "1970-01-01");
        assert_eq!(iso_day(59), "1970-03-01");
        assert_eq!(iso_day(11_016), "2000-02-29");
        assert_eq!(iso_day(20_735), "2026-10-09");
    }

    #[test]
    fn arguments_read_as_the_server_did() {
        assert_eq!(int(&json!(7)), Some(7));
        assert_eq!(int(&json!(" 8")), Some(8));
        assert_eq!(int(&Value::Null), None);
        assert_eq!(
            pairs(&json!({"title": "x", "minutes": 20})),
            ["minutes", "20", "title", "x"]
        );
        assert_eq!(text(&Value::Null), "");
    }

    // Golden outputs: what an agent reads for each lease refusal and warning.
    #[test]
    fn lease_refusals_read_like_rustc() {
        let next = "lease {\"count\":16}   (entries 33..48 are free now)";
        let busy = lease_refused(
            &json!({"from": 10, "to": 25}),
            "busy",
            &json!({"code": "busy", "held": [10, 11, 12, 13, 14, 15, 16], "free": [17, 32], "n": 1000}),
            next,
        );
        assert_eq!(
            busy.render(),
            "error[busy]: the block overlaps another agent's
  |
  | lease {\"from\":10,\"to\":25}
  |               ^^ entries 10..16 are held by other agents
  |
  = note: a block is all or nothing: nothing was leased
  = help: entries 17..32 are free, the same size:
          lease {\"from\":17,\"to\":32}
  = explain: hireme {\"explain\":\"busy\"}"
        );

        let empty = lease_refused(
            &json!({"from": 2000, "to": 2015}),
            "empty",
            &json!({"code": "empty", "asked": [2000, 2015], "n": 1000}),
            next,
        );
        assert_eq!(
            empty.render(),
            "error[empty]: that range names no application: entries run 1..1000
  |
  | lease {\"from\":2000,\"to\":2015}
  |               ^^^^ outside 1..1000
  |
  = help: lease a range inside 1..1000, or by size:
          lease {\"count\":16}   (entries 33..48 are free now)
  = explain: hireme {\"explain\":\"empty\"}"
        );

        let held = lease_refused(
            &json!({"count": 16}),
            "held",
            &json!({"code": "held", "from": 1, "to": 16}),
            next,
        );
        assert!(
            held.render()
                .starts_with("error[held]: this agent already holds entries 1..16")
        );
    }

    #[test]
    fn lease_warnings_ride_with_the_grant() {
        let block = Block {
            from: 990,
            to: 1000,
            lane: 990,
            jobs: vec![],
        };
        let a = json!({"from": 990, "to": 1010});
        let truncated = lease_warning(
            &a,
            &json!({"code": "truncated", "asked": [990, 1010], "n": 1000}),
            &block,
        );
        assert_eq!(
            truncated.render(),
            "warning[truncated]: entries 990..1010 truncated to 990..1000
  |
  | lease {\"from\":990,\"to\":1010}
  |                        ^^^^ the desk has 1000 applications
  |
  = note: the lease covers the part of the range that exists
  = explain: hireme {\"explain\":\"truncated\"}"
        );
        let size = size_advice(&a, &block).expect("11 is not a power of two");
        assert_eq!(
            size.render(),
            "warning[size]: a block of 11 entries; prefer a power of two
  |
  | lease {\"from\":990,\"to\":1010}
  |                        ^^^^ 11 entries
  |
  = note: the lease is granted as asked; blocks of 8, 16 or 32, aligned to their size, tile the desk and merge back whole
  = help: next time, 8 or 16:
          lease {\"from\":977,\"to\":992}
  = explain: hireme {\"explain\":\"size\"}"
        );
        assert!(
            size_advice(
                &json!({"count": 16}),
                &Block {
                    from: 1,
                    to: 16,
                    lane: 1,
                    jobs: vec![]
                }
            )
            .is_none()
        );
    }

    #[test]
    fn an_unaligned_block_is_granted_and_named() {
        let block = Block {
            from: 3,
            to: 18,
            lane: 3,
            jobs: vec![],
        };
        let a = json!({"from": 3, "to": 18});
        let w = lease_warning(
            &a,
            &json!({"code": "align", "asked": [3, 18], "aligned": [1, 16]}),
            &block,
        );
        assert_eq!(
            w.render(),
            "warning[align]: entries 3..18 are a block of 16 off its alignment
  |
  | lease {\"from\":3,\"to\":18}
  |               ^ granted as asked
  |
  = note: blocks of 16 align at 1, 17, 33, ...: aligned blocks tile the desk and merge back whole
  = help: the aligned block holding entry 3:
          lease {\"from\":1,\"to\":16}
  = explain: hireme {\"explain\":\"align\"}"
        );
    }

    #[test]
    fn helpers_behind_the_suggestions() {
        assert_eq!(runs(&[3, 10, 11, 12, 20]), "3, 10..12, 20");
        assert_eq!(distance("gatd", "gated"), 1);
        assert_eq!(distance("", "abc"), 3);
    }
}
