//! hireme-mcp: a stdio MCP server for agents such as Claude Code.
//!
//! An agent is a client of hireme exactly as a browser is. hireme-mcp
//! holds one session (WebTransport, or the `/wire` WebSocket where UDP is
//! blocked), receives the account's raw tables and every delta, and keeps
//! them resident in the desk kernel (`native/kernel`), the same code the
//! browser runs as WebAssembly. Every read tool is answered here from
//! that copy: the ranked board, heat, the score chart, gym and net
//! progress, one application's composed CV. Writes go up as the binary
//! ops the browser sends, and Elixir decides them: desk-wide ops on the
//! session itself, an application's ops on the lane of its lease. A lease
//! is held by one process on the server, for one application, until it
//! is released or the session ends; hold as many as there are parallel
//! tasks. Desk changes to leased applications arrive as log
//! notifications and are kept for `letterbox_events`.
//!
//! Configuration is read from the environment: `HIREME_API_KEY`
//! (required); `HIREME_WT_URL` (e.g. `https://host/wt`); `HIREME_WS_URL`
//! (e.g. `wss://host`, the fallback); `HIREME_TRANSPORT` = `auto` | `wt`
//! | `ws`; and, for a development gate's self-signed certificate,
//! `HIREME_WT_CERT_SHA256` or `HIREME_WT_CERT_SHA256_FILE`.

mod carrier;

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use carrier::{Config, Link};
use kernel::Desk;
use kernel::schema::{self, col, frame, op, table};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

const EVENTS_KEPT: usize = 256;
const PROTOCOL: &str = "2025-06-18";
/// A lease answer is keyed by its lane, apart from the op ids.
const LANE_KEY: u64 = 1 << 63;

enum Answer {
    Ack,
    Nack(String),
}

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
    /// Leased job id → its lane.
    leases: Mutex<HashMap<u32, u64>>,
    events: Mutex<HashMap<u32, VecDeque<Value>>>,
    /// Op ids are the account's ledger keys: this run's random high half, then a count.
    next_op: AtomicU64,
    next_lane: AtomicU64,
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
        leases: Mutex::new(HashMap::new()),
        events: Mutex::new(HashMap::new()),
        next_op: AtomicU64::new(run_id() << 32 | 1),
        next_lane: AtomicU64::new(1),
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

type Outcome = Result<Value, String>;

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
        let outcome = match self.link().await {
            Err(e) => Err(e),
            Ok(_) => self.tool(name, &a).await,
        };
        match outcome {
            Ok(v) => {
                json!({"content": [{"type": "text", "text": v.to_string()}], "structuredContent": v})
            }
            Err(e) => json!({"content": [{"type": "text", "text": e}], "isError": true}),
        }
    }

    async fn tool(self: &Arc<Self>, name: &str, a: &Value) -> Outcome {
        let job = || job_arg(a);
        match name {
            // Reads, from the resident desk.
            "list_letterboxes" => self.with_desk(|d| letterboxes(d, a)),
            "list_batches" => {
                self.with_desk(|d| Ok(json!({"batches": all_rows(d, table::BATCHES)})))
            }
            "list_applications" => self.with_desk(|d| applications(d, a, "all", None)),
            "recommend_applications" => self.with_desk(|d| recommend(d, a)),
            "score_distribution" => self.with_desk(|d| distribution(d, a)),
            "heat_status" => self.with_desk(|d| heat(d, a)),
            "can_apply" => self.with_desk(|d| verdict(d, job()?)),
            "gym_status" => self.with_desk(|d| lanes(d, "gym")),
            "net_status" => self.with_desk(|d| lanes(d, "net")),
            "get_application" => {
                let job = job()?;
                self.held(job)?;
                self.with_desk(|d| json_text(&d.focus_json(job)))
            }
            // Leases.
            "lease_letterbox" => self.lease(job()?).await,
            "release_letterbox" => self.release(job()?),
            "list_leases" => Ok(self.list_leases()),
            "letterbox_events" => Ok(self.drain_events(a)),
            // Desk-wide writes, on the session.
            "gym_log" => self.write(0, op::GYM_LOG, 0, pairs(a)).await,
            "gym_set_target" => {
                self.write(0, op::GYM_TARGET, 0, vec![text(&a["target"])])
                    .await
            }
            "net_log" => self.write(0, op::NET_LOG, 0, pairs(a)).await,
            "net_set_lane" => self.write(0, op::NET_LANE, 0, vec![text(&a["url"])]).await,
            // An application's writes, on its lease.
            "set_stage" => {
                self.lease_write(job()?, op::STAGE, vec![text(&a["stage"])])
                    .await
            }
            "set_next_action" => {
                let fields = vec![text(&a["next_action"]), text(&a["next_due"])];
                self.lease_write(job()?, op::NEXT, fields).await
            }
            "set_score" => {
                self.lease_write(job()?, op::SCORE, vec![text(&a["score"])])
                    .await
            }
            "tailor_line" => {
                let fields = ["item_id", "mode", "body", "reason", "title"].map(|k| text(&a[k]));
                self.lease_write(job()?, op::OVERLAY, fields.to_vec()).await
            }
            "open_cv_generation" => self.lease_write(job()?, op::GENERATION, vec![]).await,
            _ => Err(format!("unknown tool {name}")),
        }
    }

    fn with_desk<T>(&self, f: impl FnOnce(&mut Desk) -> T) -> T {
        let mut desk = self.desk.lock().unwrap();
        let unread = std::mem::take(&mut *self.unread.lock().unwrap());
        if !unread.is_empty() {
            desk.ingest(&unread);
        }
        f(&mut desk)
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
        let lane = f.header.rev;
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
                    self.answer(
                        if op_id == 0 { LANE_KEY | lane } else { op_id },
                        Answer::Ack,
                    );
                }
            }
            frame::NACK => {
                if let Ok((op_id, _code, msg)) = wire::nack(f.body) {
                    let key = if op_id == 0 { LANE_KEY | lane } else { op_id };
                    self.answer(key, Answer::Nack(msg.to_string()));
                }
            }
            // A lane's BYE: the server ended that lease (revoked, released).
            frame::BYE => {
                let mut leases = self.leases.lock().unwrap();
                if let Some((&job, _)) = leases.iter().find(|(_, l)| **l == lane) {
                    leases.remove(&job);
                    drop(leases);
                    self.answer(LANE_KEY | lane, Answer::Nack(carrier::bye_reason(f.body)));
                    self.notify(job, json!({"type": "lease_lost", "job_id": job}));
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

    /// Send one frame and wait for its ACK or NACK.
    async fn ask(self: &Arc<Self>, key: u64, bytes: Vec<u8>) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.waits.lock().unwrap().insert(key, tx);
        self.link().await?.send(bytes)?;
        match tokio::time::timeout(Duration::from_secs(10), rx).await {
            Ok(Ok(Answer::Ack)) => Ok(()),
            Ok(Ok(Answer::Nack(why))) => Err(why),
            Ok(Err(_)) => Err("session closed".into()),
            Err(_) => {
                self.waits.lock().unwrap().remove(&key);
                Err("no answer in 10 s".into())
            }
        }
    }

    /// One op, on `lane` (0: the session). The answer comes after its
    /// delta, so the desk already shows what it wrote.
    async fn write(
        self: &Arc<Self>,
        lane: u64,
        kind: u8,
        target: u32,
        fields: Vec<String>,
    ) -> Outcome {
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
        self.ask(op_id, w.buf).await?;
        Ok(json!({"ok": true, "job_id": target}))
    }

    async fn lease_write(self: &Arc<Self>, job: u32, kind: u8, fields: Vec<String>) -> Outcome {
        let lane = self.held(job)?;
        self.write(lane, kind, job, fields).await
    }

    fn held(&self, job: u32) -> Result<u64, String> {
        self.leases
            .lock()
            .unwrap()
            .get(&job)
            .copied()
            .ok_or(format!(
                "job {job} is not leased here: call lease_letterbox first"
            ))
    }

    async fn lease(self: &Arc<Self>, job: u32) -> Outcome {
        if self.held(job).is_err() {
            let lane = self.next_lane.fetch_add(1, Ordering::Relaxed);
            let lease = carrier::frame(frame::LEASE, lane, &u64::from(job).to_le_bytes());
            self.ask(LANE_KEY | lane, lease)
                .await
                .map_err(|why| format!("job {job}: {why}"))?;
            self.leases.lock().unwrap().insert(job, lane);
        }
        Ok(self.with_desk(|d| application(d, job)))
    }

    fn release(&self, job: u32) -> Outcome {
        let lane = self.held(job)?;
        self.leases.lock().unwrap().remove(&job);
        if let Some(link) = self.link.try_lock().ok().and_then(|l| l.clone()) {
            let mut body = 7u16.to_le_bytes().to_vec();
            body.extend_from_slice(b"release");
            let _ = link.send(carrier::frame(frame::BYE, lane, &body));
        }
        Ok(json!({"job_id": job, "released": true}))
    }

    fn session_lost(&self) {
        let lost: Vec<u32> = self
            .leases
            .lock()
            .unwrap()
            .drain()
            .map(|(job, _)| job)
            .collect();
        self.waits.lock().unwrap().clear();
        for job in lost {
            self.notify(job, json!({"type": "lease_lost", "job_id": job}));
        }
    }

    fn list_leases(&self) -> Value {
        let carrier = self
            .link
            .try_lock()
            .ok()
            .and_then(|l| l.as_ref().map(|l| l.name));
        let jobs: Vec<u32> = self.leases.lock().unwrap().keys().copied().collect();
        json!({
            "carrier": carrier,
            "schema": format!("{:04x}", schema::HASH),
            "leases": self.with_desk(|d| jobs.iter().map(|&j| application(d, j)).collect::<Vec<_>>()),
            "frames": self.frames.load(Ordering::Relaxed),
            "notifications": self.delivered.load(Ordering::Relaxed),
        })
    }

    // ---- desk changes to leased applications --------------------------------

    /// A PATCH's application rows and deletions, for the jobs leased here.
    fn notify_rows(&self, f: &wire::Frame<'_>) {
        let held: Vec<u32> = self.leases.lock().unwrap().keys().copied().collect();
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

    /// A desk event for one lease: a log notification, and kept for polling.
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
        let jobs: Vec<u32> = match job_arg(a) {
            Ok(job) => vec![job],
            Err(_) => events.keys().copied().collect(),
        };
        let mut drained = Vec::new();
        for j in jobs {
            drained.extend(events.get_mut(&j).into_iter().flat_map(|q| q.drain(..)));
        }
        json!({"events": drained})
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

/// The key a lookup table gives index `ix` (stages, statuses, heat_states...).
fn key_of(d: &Desk, t: u16, ix: u32) -> Value {
    d.row_of(t, ix)
        .map_or(Value::Null, |r| json!(d.str_at(t, 2, r)))
}

/// The index of a key in a lookup table, or -1 for none or "all".
fn ix_of(d: &Desk, t: u16, key: &Value) -> i32 {
    let Some(key) = key.as_str().filter(|k| !k.is_empty() && *k != "all") else {
        return -1;
    };
    (0..d.rows(t))
        .find(|&r| d.str_at(t, 2, r) == key)
        .map_or(-2, |r| d.u32_at(t, 1, r) as i32)
}

fn band(d: &Desk, score: u32) -> Value {
    let t = table::BANDS;
    (0..d.rows(t))
        .find(|&r| (d.u32_at(t, 4, r)..=d.u32_at(t, 5, r)).contains(&score))
        .map_or(Value::Null, |r| json!(d.str_at(t, 2, r)))
}

/// One card as an agent reads it: names for the enum columns.
fn card(d: &Desk, r: usize) -> Value {
    let mut m = row(d, table::CARDS, r);
    let c = table::CARDS;
    for (name, lookup) in [
        ("stage", table::STAGES),
        ("status", table::STATUSES),
        ("freshness", table::FRESHNESS),
        ("gate", table::GATES),
        ("heat_state", table::HEAT_STATES),
    ] {
        let ix = m[name].as_u64().unwrap_or(u64::from(wire::NONE)) as u32;
        m.insert(name.into(), key_of(d, lookup, ix));
    }
    let batch = d.u32_at(c, col::cards::BATCH, r);
    m.insert(
        "batch".into(),
        d.row_of(table::BATCHES, batch).map_or(Value::Null, |b| {
            json!(d.str_at(table::BATCHES, col::batches::CODE, b))
        }),
    );
    m.insert("band".into(), band(d, d.u32_at(c, col::cards::SCORE, r)));
    let score = m.remove("score").unwrap_or(Value::Null);
    m.insert("score_100".into(), score);
    let job = m.remove("id").unwrap_or(Value::Null);
    m.insert("job_id".into(), job);
    for skip in [
        "pips",
        "fit",
        "hits",
        "total",
        "hidden",
        "altered",
        "emphasized",
        "profile",
    ] {
        m.remove(skip);
    }
    Value::Object(m)
}

fn application(d: &mut Desk, job: u32) -> Value {
    d.derive();
    d.row_of(table::CARDS, job)
        .map_or(json!({"job_id": job}), |r| card(d, r))
}

/// The board in order, filtered as the desk's top bar filters it.
fn select(d: &mut Desk, a: &Value, status: &str) -> Vec<usize> {
    let (lo, hi) = match ix_of(d, table::BANDS, &a["band"]) {
        -1 => (0, i32::MAX),
        ix => d.row_of(table::BANDS, ix as u32).map_or((1, 0), |r| {
            (
                d.u32_at(table::BANDS, 4, r) as i32,
                d.u32_at(table::BANDS, 5, r) as i32,
            )
        }),
    };
    let status = match &a["status"] {
        Value::String(s) if !s.is_empty() => json!(s),
        _ => json!(status),
    };
    let batch = match a["batch"].as_str().filter(|b| !b.is_empty()) {
        None => -1,
        Some(code) => (0..d.rows(table::BATCHES))
            .find(|&r| d.str_at(table::BATCHES, col::batches::CODE, r) == code)
            .map_or(i32::MAX, |r| {
                d.u32_at(table::BATCHES, col::batches::ID, r) as i32
            }),
    };
    let min = a["min_score"].as_i64().map_or(-1, |m| m as i32);
    let (stage, status, heat) = (
        ix_of(d, table::STAGES, &a["stage"]),
        ix_of(d, table::STATUSES, &status),
        ix_of(d, table::HEAT_STATES, &a["heat"]),
    );
    let q = a["q"].as_str().unwrap_or("").as_bytes().to_vec();
    d.select(min, lo, hi, stage, status, batch, -1, heat, &q);
    d.selection().iter().map(|&r| r as usize).collect()
}

fn applications(d: &mut Desk, a: &Value, status: &str, limit: Option<usize>) -> Outcome {
    let limit = a["limit"]
        .as_u64()
        .map_or(limit.unwrap_or(100), |l| l.clamp(1, 1000) as usize);
    let rows: Vec<Value> = select(d, a, status)
        .into_iter()
        .take(limit)
        .map(|r| card(d, r))
        .collect();
    Ok(json!({"applications": rows}))
}

fn recommend(d: &mut Desk, a: &Value) -> Outcome {
    let mut a = a.clone();
    if a["min_score"].is_null() {
        a["min_score"] = json!(90);
    }
    let limit = a["limit"].as_u64().map_or(25, |l| l.clamp(1, 100) as usize);
    let apps: Vec<Value> = select(d, &a, "open")
        .into_iter()
        .map(|r| card(d, r))
        .filter(|c| c["heat_state"] != "blocked")
        .take(limit)
        .collect();
    let open_fire =
        (0..d.rows(table::BATCHES)).any(|r| d.u32_at(table::BATCHES, col::batches::FIRE, r) == 1);
    Ok(json!({
        "applications": apps,
        "min_score": a["min_score"],
        "fire": if open_fire { "open_fire" } else { "hold" },
        "note": "FIRE HOLD. Ranked by score_100 then cooler heat. Blocked (over cap) omitted. Does not submit."
    }))
}

/// Band counts and ten-point bins over the filtered board.
fn distribution(d: &mut Desk, a: &Value) -> Outcome {
    let scores: Vec<u32> = select(d, a, "all")
        .into_iter()
        .map(|r| d.u32_at(table::CARDS, col::cards::SCORE, r))
        .collect();
    let bands: Vec<Value> = (0..d.rows(table::BANDS))
        .map(|r| {
            let (lo, hi) = (d.u32_at(table::BANDS, 4, r), d.u32_at(table::BANDS, 5, r));
            let n = scores.iter().filter(|s| (lo..=hi).contains(s)).count();
            json!({"key": d.str_at(table::BANDS, 2, r), "label": d.str_at(table::BANDS, 3, r),
                   "min": lo, "max": hi, "count": n})
        })
        .collect();
    let bins: Vec<Value> = (0..10)
        .map(|b| {
            let (lo, hi) = (b * 10, if b == 9 { 100 } else { b * 10 + 9 });
            json!({"lo": lo, "hi": hi, "count": scores.iter().filter(|s| (lo..=hi).contains(*s)).count()})
        })
        .collect();
    let n = scores.len();
    let mean = if n == 0 {
        0.0
    } else {
        f64::from(scores.iter().sum::<u32>()) / n as f64
    };
    Ok(json!({"n": n, "mean": mean, "bands": bands, "bins": bins}))
}

fn heat(d: &mut Desk, a: &Value) -> Outcome {
    d.derive();
    let t = table::HEAT_ROWS;
    let pick = |group: u32, needle: &Value| -> Vec<Value> {
        let needle = needle.as_str().unwrap_or("").to_lowercase();
        (0..d.rows(t))
            .filter(|&r| d.u32_at(t, col::heat_rows::GROUP, r) == group)
            .filter(|&r| {
                needle.is_empty()
                    || d.str_at(t, col::heat_rows::KEY, r)
                        .to_lowercase()
                        .contains(&needle)
                    || d.str_at(t, col::heat_rows::LABEL, r)
                        .to_lowercase()
                        .contains(&needle)
            })
            .map(|r| Value::Object(row(d, t, r)))
            .collect()
    };
    Ok(json!({
        "companies": pick(0, &a["company"]),
        "vendors": pick(1, &a["ats"]),
        "note": "FIRE HOLD. Heat gates the queue. It does not submit."
    }))
}

fn verdict(d: &mut Desk, job: u32) -> Outcome {
    d.derive();
    let r = d
        .row_of(table::VERDICTS, job)
        .ok_or(format!("job {job}: not found"))?;
    let mut v = row(d, table::VERDICTS, r);
    v.insert("job_id".into(), json!(job));
    v.insert("fire".into(), json!("hold"));
    Ok(Value::Object(v))
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

fn letterboxes(d: &mut Desk, a: &Value) -> Outcome {
    let rows = applications(
        d,
        &json!({"min_score": a["min_score"], "limit": a["limit"]}),
        "all",
        Some(1000),
    )?;
    Ok(json!({"letterboxes": rows["applications"]}))
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
fn job_arg(a: &Value) -> Result<u32, String> {
    ["job_id", "role_id"]
        .iter()
        .find_map(|k| match &a[*k] {
            Value::Number(n) => n.as_u64(),
            Value::String(s) => s.parse().ok(),
            _ => None,
        })
        .map(|n| n as u32)
        .ok_or("job_id is required".into())
}

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
        "instructions": "hireme desk. The read tools rank and report on the whole desk. To change \
            one application, lease_letterbox(job_id) and pass that job_id to its write tools. Hold \
            as many leases as you have parallel tasks; release_letterbox when done. Changes to \
            leased applications arrive as log notifications and through letterbox_events. \
            FIRE HOLD: nothing here submits an application."
    })
}

fn tools(d: &mut Desk) -> Vec<Value> {
    let keys = |t: u16| -> Value { (0..d.rows(t)).map(|r| json!(d.str_at(t, 2, r))).collect() };
    let en = |t: u16| json!({"type": "string", "enum": keys(t)});
    let score = json!({"type": "integer", "minimum": 0, "maximum": 100});
    let s = json!({"type": "string"});
    let job = json!({"type": "integer", "description": "The application's job id"});
    let filters = json!({"q": s, "stage": en(table::STAGES), "status": s, "batch": s,
        "min_score": score, "band": en(table::BANDS), "heat": en(table::HEAT_STATES),
        "limit": {"type": "integer", "minimum": 1}});
    let tool = |name: &str, description: &str, props: Value, required: &[&str]| {
        json!({"name": name, "description": description,
               "inputSchema": {"type": "object", "properties": props, "required": required}})
    };
    let with_job = |extra: Value| {
        let mut p = extra;
        p["job_id"] = job.clone();
        p
    };
    vec![
        tool(
            "list_letterboxes",
            "Applications an agent can lease, highest score_100 first, with whether each is leased",
            json!({"min_score": score, "limit": {"type": "integer"}}),
            &[],
        ),
        tool("list_batches", "The batches on the desk", json!({}), &[]),
        tool(
            "list_applications",
            "Applications ranked by score_100, then cooler company heat, filtered like the desk's top bar. FIRE HOLD — does not submit",
            filters.clone(),
            &[],
        ),
        tool(
            "recommend_applications",
            "The open applications to draft first (score_100 floor 90 by default), heat-blocked ones left out. Ranks only; does not submit",
            filters.clone(),
            &[],
        ),
        tool(
            "score_distribution",
            "score_100 band counts and ten-point bins over the filtered desk",
            filters,
            &[],
        ),
        tool(
            "heat_status",
            "Company and ATS heat against cap, with cooldowns, optionally filtered by company or ats. FIRE HOLD",
            json!({"company": s, "ats": s}),
            &[],
        ),
        tool(
            "can_apply",
            "Would queueing this application exceed company or ATS heat? allow or defer, with reason and cooldown. FIRE HOLD",
            json!({"job_id": job}),
            &["job_id"],
        ),
        tool(
            "gym_status",
            "Gym conditioning: daily target, streak, weekly pace (not Life-EV score_100), topic counts",
            json!({}),
            &[],
        ),
        tool(
            "gym_log",
            "Log a LeetCode / Codeforces / systems rep (platform, title, slug, topic, difficulty, url, outcome, minutes, note, done_on)",
            json!({"title": s, "slug": s, "platform": s, "topic": s, "difficulty": s, "url": s, "outcome": s, "minutes": {"type": "integer"}, "note": s, "done_on": s}),
            &[],
        ),
        tool(
            "gym_set_target",
            "Set the gym daily solved-rep target (1–30)",
            json!({"target": {"type": "integer", "minimum": 1, "maximum": 30}}),
            &["target"],
        ),
        tool(
            "net_status",
            "Networking lane: Broadside Observer URL, shipped work this week, open drafts, observer runs. Not CRM",
            json!({}),
            &[],
        ),
        tool(
            "net_log",
            "Log an observer run, shipped artifact, post, or draft (kind, channel, title, url, body, shipped_on). Not CRM",
            json!({"kind": s, "channel": s, "title": s, "url": s, "body": s, "shipped_on": s}),
            &[],
        ),
        tool(
            "net_set_lane",
            "Set the Broadside Observer research lane URL",
            json!({"url": s}),
            &["url"],
        ),
        tool(
            "lease_letterbox",
            "Lease one application so this agent can change it. Hold several to work in parallel",
            json!({"job_id": job}),
            &["job_id"],
        ),
        tool(
            "release_letterbox",
            "Release a lease",
            json!({"job_id": job}),
            &["job_id"],
        ),
        tool(
            "list_leases",
            "The leases this agent holds, the carrier, and the wire schema",
            json!({}),
            &[],
        ),
        tool(
            "letterbox_events",
            "Drain desk changes to leased applications (all, or one job_id)",
            json!({"job_id": job}),
            &[],
        ),
        tool(
            "get_application",
            "A leased application with its composed CV: lines, modes, theme and rail",
            json!({"job_id": job}),
            &["job_id"],
        ),
        tool(
            "set_stage",
            "Move a leased application along the battleplan",
            with_job(json!({"stage": en(table::STAGES)})),
            &["job_id", "stage"],
        ),
        tool(
            "set_next_action",
            "Set a leased application's next action and optional due date (ISO)",
            with_job(json!({"next_action": s, "next_due": s})),
            &["job_id", "next_action"],
        ),
        tool(
            "set_score",
            "Set a leased application's score_100",
            with_job(json!({"score": score})),
            &["job_id", "score"],
        ),
        tool(
            "tailor_line",
            "Hide, emphasize, alter (title/body) or inherit a line on a leased application's CV",
            with_job(
                json!({"item_id": {"type": "integer"}, "mode": {"type": "string", "enum": ["hidden", "emphasized", "altered", "inherit"]}, "title": s, "body": s, "reason": s}),
            ),
            &["job_id", "item_id", "mode"],
        ),
        tool(
            "open_cv_generation",
            "After the cooldown, open an additive CV generation for a leased application's employer",
            with_job(json!({})),
            &["job_id"],
        ),
    ]
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
        assert_eq!(job_arg(&json!({"job_id": 7})), Ok(7));
        assert_eq!(job_arg(&json!({"role_id": "8"})), Ok(8));
        assert!(job_arg(&json!({})).is_err());
        assert_eq!(
            pairs(&json!({"title": "x", "minutes": 20})),
            ["minutes", "20", "title", "x"]
        );
        assert_eq!(text(&Value::Null), "");
    }
}
