//! hireme-mcp: a stdio MCP server for agents such as Claude Code.
//!
//! It holds one session to hireme (WebTransport, falling back to
//! WebSocket) and gives each letterbox lease its own stream, so an agent
//! can hold any number of leases at once. Tool calls on different leases
//! run in parallel; calls on one lease keep their order. The account's
//! columnar desk deltas arrive once per session and are decoded here
//! into `notifications/message` for the leased applications. They are
//! also kept for `letterbox_events`, for clients that do not surface
//! notifications.
//!
//! Configuration is read from the environment:
//! `HIREME_API_KEY` (required); `HIREME_WT_URL` (e.g. `https://host/wt`);
//! `HIREME_WS_URL` (e.g. `wss://host`, used as the fallback);
//! `HIREME_TRANSPORT` = `auto` | `wt` | `ws`; and, for a dev gate's
//! self-signed certificate, `HIREME_WT_CERT_SHA256` or
//! `HIREME_WT_CERT_SHA256_FILE`.

mod carrier;

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use carrier::{Carrier, Config, Down, Up};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};
use wire::schema::{self, col, table};

/// Desk events kept per lease for `letterbox_events`.
const EVENTS_KEPT: usize = 256;
const PROTOCOL: &str = "2025-06-18";

type Reply = oneshot::Sender<Value>;

/// One open lane: the directory (id 0) or one lease.
struct Lane {
    info: Value,
    calls: mpsc::UnboundedSender<(Value, Reply)>,
}

impl Lane {
    /// One JSON-RPC request on this lane, answered in order.
    async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let (tx, rx) = oneshot::channel();
        let msg = json!({"jsonrpc": "2.0", "method": method, "params": params});
        self.calls
            .send((msg, tx))
            .map_err(|_| "lease closed".to_string())?;
        rx.await.map_err(|_| "lease closed".to_string())
    }
}

/// Batch codes by id, from the batches table.
#[derive(Default)]
struct Dict {
    names: HashMap<(u16, u32), String>,
}

#[derive(Default)]
struct Counters {
    frames: AtomicU64,
    rows: AtomicU64,
    delivered: AtomicU64,
}

struct Hub {
    cfg: Config,
    out: mpsc::UnboundedSender<Value>,
    carrier: tokio::sync::Mutex<Option<Arc<Carrier>>>,
    directory: tokio::sync::Mutex<Option<Arc<Lane>>>,
    leases: Mutex<HashMap<u64, Arc<Lane>>>,
    events: Mutex<HashMap<u64, VecDeque<Value>>>,
    dict: Mutex<Dict>,
    leased_tools: tokio::sync::OnceCell<Vec<Value>>,
    counters: Counters,
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
        carrier: tokio::sync::Mutex::new(None),
        directory: tokio::sync::Mutex::new(None),
        leases: Mutex::new(HashMap::new()),
        events: Mutex::new(HashMap::new()),
        dict: Mutex::new(Dict::default()),
        leased_tools: tokio::sync::OnceCell::new(),
        counters: Counters::default(),
    });

    // Connect while the agent is still initializing: the session, the
    // directory and the lease tool list are ready before the first call.
    // A failure here is reported by that call instead.
    let warm = hub.clone();
    tokio::spawn(async move {
        let _ = warm.leased_tools().await;
    });

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let hub = hub.clone();
        // Every request runs on its own task: leases answer in parallel.
        tokio::spawn(async move {
            match serde_json::from_str::<Value>(&line) {
                Ok(msg) => {
                    if let Some(reply) = hub.request(msg).await {
                        let _ = hub.out.send(reply);
                    }
                }
                Err(_) => {
                    let _ = hub.out.send(json!({"jsonrpc": "2.0", "id": null,
                        "error": {"code": -32700, "message": "parse error"}}));
                }
            }
        });
    }
}

impl Hub {
    /// One message from the agent; `None` for notifications.
    async fn request(self: &Arc<Self>, msg: Value) -> Option<Value> {
        let id = msg.get("id").cloned()?;
        let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let answer = match method {
            "initialize" => Ok(self.initialize(&params)),
            "ping" | "logging/setLevel" => Ok(json!({})),
            "tools/list" => self.tools().await.map(|tools| json!({"tools": tools})),
            "tools/call" => Ok(self.call_tool(&params).await),
            _ => Err((-32601, "unknown method".to_string())),
        };
        Some(match answer {
            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
            Err((code, message)) => {
                json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
            }
        })
    }

    fn initialize(&self, params: &Value) -> Value {
        let version = params["protocolVersion"].as_str().unwrap_or(PROTOCOL);
        json!({
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": false}, "logging": {}},
            "serverInfo": {"name": "hireme-mcp", "version": env!("CARGO_PKG_VERSION")},
            "instructions": "hireme desk. Directory tools read and rank the whole desk. \
                To work on one application, lease_letterbox(letterbox_id) and pass that \
                letterbox_id to the per-application tools. Hold as many leases as you have \
                parallel tasks; release_letterbox when done. Desk changes to leased \
                applications arrive as log notifications and through letterbox_events. \
                FIRE HOLD: nothing here submits an application."
        })
    }

    // -- tools ---------------------------------------------------------------

    async fn tools(self: &Arc<Self>) -> Result<Vec<Value>, (i64, String)> {
        let dir = self.directory().await.map_err(|e| (-32000, e))?;
        let listed = dir
            .call("tools/list", json!({}))
            .await
            .map_err(|e| (-32000, e))?;
        let mut tools: Vec<Value> = listed["result"]["tools"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        tools.extend(local_tools());
        tools.extend(
            self.leased_tools()
                .await
                .map_err(|e| (-32000, e))?
                .iter()
                .cloned(),
        );
        Ok(tools)
    }

    /// The per-lease tools, each with a required `letterbox_id`.
    async fn leased_tools(self: &Arc<Self>) -> Result<&Vec<Value>, String> {
        self.leased_tools
            .get_or_try_init(|| async {
                let dir = self.directory().await?;
                let r = dir.call("letterbox/tools", json!({})).await?;
                let tools = r["result"]["tools"].as_array().cloned().unwrap_or_default();
                Ok(tools
                    .into_iter()
                    .map(|mut t| {
                        let schema = &mut t["inputSchema"];
                        schema["properties"]["letterbox_id"] = json!({"type": "integer",
                            "description": "A letterbox this agent leased with lease_letterbox"});
                        let mut req = schema["required"].as_array().cloned().unwrap_or_default();
                        req.push(json!("letterbox_id"));
                        schema["required"] = Value::Array(req);
                        t
                    })
                    .collect())
            })
            .await
    }

    async fn call_tool(self: &Arc<Self>, params: &Value) -> Value {
        let name = params["name"].as_str().unwrap_or("");
        let args = match &params["arguments"] {
            Value::Object(m) => Value::Object(m.clone()),
            _ => json!({}),
        };
        let result = match name {
            "lease_letterbox" => self.lease(&args).await,
            "release_letterbox" => self.release(&args),
            "list_leases" => Ok(self.list_leases().await),
            "letterbox_events" => Ok(self.drain_events(&args)),
            _ => self.forward(name, args).await,
        };
        match result {
            Ok(v) => json!({
                "content": [{"type": "text", "text": v.to_string()}],
                "structuredContent": v,
            }),
            Err(e) => json!({"content": [{"type": "text", "text": e}], "isError": true}),
        }
    }

    async fn forward(self: &Arc<Self>, name: &str, args: Value) -> Result<Value, String> {
        let leased = self.leased_tools().await?.iter().any(|t| t["name"] == name);
        let lane = if leased {
            let id = args["letterbox_id"]
                .as_u64()
                .ok_or("letterbox_id is required")?;
            self.leases
                .lock()
                .unwrap()
                .get(&id)
                .cloned()
                .ok_or(format!(
                    "letterbox {id} is not leased here: call lease_letterbox first"
                ))?
        } else {
            self.directory().await?
        };
        let reply = lane
            .call("tools/call", json!({"name": name, "arguments": args}))
            .await?;
        match (reply.get("result"), reply.get("error")) {
            (Some(r), _) => Ok(r.clone()),
            (_, Some(e)) => Err(e["message"].as_str().unwrap_or("error").to_string()),
            _ => Err("empty reply".into()),
        }
    }

    async fn lease(self: &Arc<Self>, args: &Value) -> Result<Value, String> {
        let id = args["letterbox_id"]
            .as_u64()
            .filter(|&i| i > 0)
            .ok_or("letterbox_id is required")?;
        if let Some(lane) = self.leases.lock().unwrap().get(&id) {
            return Ok(lane.info.clone());
        }
        let lane = self.open(id).await?;
        let mut leases = self.leases.lock().unwrap();
        // Two racing leases of one id: the server granted only one stream.
        let lane = leases.entry(id).or_insert(lane).clone();
        Ok(lane.info.clone())
    }

    fn release(&self, args: &Value) -> Result<Value, String> {
        let id = args["letterbox_id"]
            .as_u64()
            .ok_or("letterbox_id is required")?;
        // Dropping the lane closes its stream, which is the release.
        match self.leases.lock().unwrap().remove(&id) {
            Some(_) => Ok(json!({"letterbox_id": id, "released": true})),
            None => Err(format!("letterbox {id} is not leased here")),
        }
    }

    async fn list_leases(&self) -> Value {
        let carrier = self
            .carrier
            .lock()
            .await
            .as_ref()
            .map(|c| c.name())
            .unwrap_or("none");
        let leases: Vec<Value> = self
            .leases
            .lock()
            .unwrap()
            .values()
            .map(|l| l.info.clone())
            .collect();
        json!({
            "carrier": carrier,
            "leases": leases,
            "frames": self.counters.frames.load(Ordering::Relaxed),
            "rows_decoded": self.counters.rows.load(Ordering::Relaxed),
            "rows_delivered": self.counters.delivered.load(Ordering::Relaxed),
        })
    }

    fn drain_events(&self, args: &Value) -> Value {
        let mut events = self.events.lock().unwrap();
        let ids: Vec<u64> = match args["letterbox_id"].as_u64() {
            Some(id) => vec![id],
            None => events.keys().copied().collect(),
        };
        let drained: Vec<Value> = ids
            .iter()
            .flat_map(|id| {
                events
                    .get_mut(id)
                    .map(|q| q.drain(..).collect::<Vec<_>>())
                    .unwrap_or_default()
            })
            .collect();
        json!({"events": drained})
    }

    // -- lanes ---------------------------------------------------------------

    async fn directory(self: &Arc<Self>) -> Result<Arc<Lane>, String> {
        let mut dir = self.directory.lock().await;
        if let Some(lane) = dir.as_ref().filter(|l| !l.calls.is_closed()) {
            return Ok(lane.clone());
        }
        let lane = self.open(0).await?;
        *dir = Some(lane.clone());
        Ok(lane)
    }

    async fn carrier(self: &Arc<Self>) -> Result<Arc<Carrier>, String> {
        let mut slot = self.carrier.lock().await;
        if let Some(c) = slot.as_ref().filter(|c| c.alive()) {
            return Ok(c.clone());
        }
        let hub = Arc::downgrade(self);
        let closed = Arc::downgrade(self);
        let c = Carrier::connect(
            &self.cfg,
            Box::new(move |f| {
                if let Some(hub) = hub.upgrade() {
                    hub.control(f)
                }
            }),
            move || {
                if let Some(hub) = closed.upgrade() {
                    hub.session_lost()
                }
            },
        )
        .await?;
        let c = Arc::new(c);
        *slot = Some(c.clone());
        Ok(c)
    }

    /// Opens a lane and waits for the server's answer to the lease.
    async fn open(self: &Arc<Self>, letterbox_id: u64) -> Result<Arc<Lane>, String> {
        let carrier = self.carrier().await?;
        let (up, mut down) = carrier.open(letterbox_id).await?;
        let first = down
            .recv()
            .await
            .ok_or("stream closed before the lease answer")?;
        let info = first["params"].clone();
        if let Some(e) = info.get("error") {
            return Err(format!(
                "letterbox {letterbox_id}: {}",
                e.as_str().unwrap_or("refused")
            ));
        }
        let (calls, calls_rx) = mpsc::unbounded_channel();
        tokio::spawn(run_lane(
            Arc::downgrade(self),
            letterbox_id,
            up,
            down,
            calls_rx,
        ));
        Ok(Arc::new(Lane { info, calls }))
    }

    fn session_lost(&self) {
        let lost: Vec<u64> = self
            .leases
            .lock()
            .unwrap()
            .drain()
            .map(|(id, _)| id)
            .collect();
        for id in lost {
            self.notify(id, json!({"type": "lease_lost", "letterbox_id": id}));
        }
    }

    // -- desk deltas ---------------------------------------------------------

    /// One control-stream frame: batch codes, then raw application rows.
    fn control(&self, f: wire::Frame<'_>) {
        self.counters.frames.fetch_add(1, Ordering::Relaxed);
        if f.header.kind != schema::frame::BOOT && f.header.kind != schema::frame::PATCH {
            return;
        }
        let jobs: HashMap<u64, u64> = self
            .leases
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(id, l)| Some((l.info["job_id"].as_u64()?, *id)))
            .collect();
        for t in f.tables().flatten() {
            match t.id {
                table::JOB_APPS => self.rows(&t, &jobs),
                table::GONE => self.gone(&t, &jobs),
                table::BATCHES => self.learn(&t),
                _ => {}
            }
        }
    }

    /// Batch codes, so a row can name its batch rather than its id.
    fn learn(&self, t: &wire::Table<'_>) {
        let (Some(k), Some(n)) = (t.col(col::batches::ID), t.col(col::batches::CODE)) else {
            return;
        };
        let mut dict = self.dict.lock().unwrap();
        for i in 0..t.nrows as usize {
            dict.names.insert((t.id, k.u32(i)), n.str(i).to_string());
        }
    }

    /// Upserted `job_apps` rows for leased jobs, as named JSON: only the
    /// columns the delta carries, so a row is what changed.
    fn rows(&self, t: &wire::Table<'_>, jobs: &HashMap<u64, u64>) {
        let Some(ids) = t.col(col::job_apps::ID) else {
            return;
        };
        self.counters
            .rows
            .fetch_add(t.nrows as u64, Ordering::Relaxed);
        if jobs.is_empty() {
            return;
        }
        let cols: Vec<_> = t.cols().collect();
        let dict = self.dict.lock().unwrap();
        let mut rows = Vec::new();
        for i in 0..t.nrows as usize {
            let Some(&lb) = jobs.get(&(ids.u32(i) as u64)) else {
                continue;
            };
            let mut row = Map::new();
            for c in &cols {
                let Some(def) = schema::col_def(t.id, c.id) else {
                    continue;
                };
                if let Some((name, value)) = cell(c, i, def, &dict) {
                    row.insert(name, value);
                }
            }
            rows.push((lb, row));
        }
        drop(dict);
        for (lb, row) in rows {
            self.notify(
                lb,
                json!({"type": "row", "letterbox_id": lb, "application": row}),
            );
        }
    }

    /// Deleted rows: `gone` names (table, id); only applications matter here.
    fn gone(&self, t: &wire::Table<'_>, jobs: &HashMap<u64, u64>) {
        let (Some(tables), Some(ids)) = (t.col(col::gone::TABLE), t.col(col::gone::ID)) else {
            return;
        };
        for i in 0..t.nrows as usize {
            if tables.u32(i) == table::JOB_APPS as u32
                && let Some(&lb) = jobs.get(&(ids.u32(i) as u64))
            {
                self.notify(
                    lb,
                    json!({"type": "gone", "letterbox_id": lb, "job_id": ids.u32(i)}),
                );
            }
        }
    }

    /// A desk event for one lease: a log notification, and kept for polling.
    fn notify(&self, letterbox_id: u64, event: Value) {
        self.counters.delivered.fetch_add(1, Ordering::Relaxed);
        {
            let mut events = self.events.lock().unwrap();
            let q = events.entry(letterbox_id).or_default();
            if q.len() == EVENTS_KEPT {
                q.pop_front();
            }
            q.push_back(event.clone());
        }
        let _ = self.out.send(json!({
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {"level": "info", "logger": format!("hireme/letterbox/{letterbox_id}"), "data": event},
        }));
    }
}

/// One cell as the agent reads it: the batch by its code, days as dates,
/// JSON text as JSON, none as null. The listing's full text is left out:
/// it is long, and `get_application` serves it.
fn cell(c: &wire::Col<'_>, i: usize, def: &schema::ColDef, dict: &Dict) -> Option<(String, Value)> {
    let value = match (def.name, c.ty) {
        ("listing", _) => return None,
        ("batch_id", wire::U32) => match dict.names.get(&(table::BATCHES, c.u32(i))) {
            Some(code) => return Some(("batch".into(), json!(code))),
            None => json!(c.u32(i)),
        },
        ("stage_notes", wire::STR) => {
            serde_json::from_str(c.str(i)).unwrap_or_else(|_| json!(c.str(i)))
        }
        (_, wire::STR) => json!(c.str(i)),
        (_, wire::U32) => match c.u32(i) {
            wire::NONE => Value::Null,
            v if def.kind == "day" => json!(iso_day(v as i64)),
            v => json!(v),
        },
        (_, wire::U64) => json!(c.u64(i)),
        (_, wire::F64) => match c.f64(i) {
            v if v.is_nan() => Value::Null,
            v => json!(v),
        },
        _ => return None,
    };
    Some((def.name.to_string(), value))
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

/// Pumps one lane: numbers requests, matches replies, routes notifications.
async fn run_lane(
    hub: std::sync::Weak<Hub>,
    letterbox_id: u64,
    up: Up,
    mut down: Down,
    mut calls: mpsc::UnboundedReceiver<(Value, Reply)>,
) {
    let mut pending: HashMap<u64, Reply> = HashMap::new();
    let mut next = 1u64;
    loop {
        tokio::select! {
            call = calls.recv() => match call {
                Some((mut msg, reply)) => {
                    msg["id"] = json!(next);
                    pending.insert(next, reply);
                    next += 1;
                    if up.send(msg).is_err() { break; }
                }
                // The lane was released: dropping `up` closes the stream.
                None => break,
            },
            msg = down.recv() => match msg {
                Some(v) => match v.get("id").and_then(Value::as_u64) {
                    Some(id) => {
                        if let Some(reply) = pending.remove(&id) { let _ = reply.send(v); }
                    }
                    None => if let (Some(hub), Some("notifications/desk")) =
                        (hub.upgrade(), v["method"].as_str()) {
                        let mut event = v["params"].clone();
                        event["letterbox_id"] = json!(letterbox_id);
                        hub.notify(letterbox_id, event);
                    },
                },
                None => break,
            },
        }
    }
    // The server ended the stream (revoked, session gone): forget the lease.
    if let Some(hub) = hub.upgrade()
        && letterbox_id != 0
        && hub.leases.lock().unwrap().remove(&letterbox_id).is_some()
    {
        hub.notify(
            letterbox_id,
            json!({"type": "lease_lost", "letterbox_id": letterbox_id}),
        );
    }
}

fn local_tools() -> Vec<Value> {
    let id = json!({"type": "integer"});
    vec![
        json!({"name": "lease_letterbox",
               "description": "Lease one letterbox (one application) on its own stream. Hold several to work on applications in parallel.",
               "inputSchema": {"type": "object", "properties": {"letterbox_id": id}, "required": ["letterbox_id"]}}),
        json!({"name": "release_letterbox",
               "description": "Release a lease by closing its stream.",
               "inputSchema": {"type": "object", "properties": {"letterbox_id": id}, "required": ["letterbox_id"]}}),
        json!({"name": "list_leases",
               "description": "The leases this agent holds, the carrier in use, and delta counters.",
               "inputSchema": {"type": "object", "properties": {}}}),
        json!({"name": "letterbox_events",
               "description": "Drain desk changes for leased applications (all leases, or one letterbox_id).",
               "inputSchema": {"type": "object", "properties": {"letterbox_id": id}}}),
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
    fn application_cells_are_named() {
        let mut w = wire::Writer::new();
        w.begin(schema::frame::PATCH, 0, 7);
        w.table(table::JOB_APPS, 2);
        w.col_u32(col::job_apps::ID, [5u32, 6].into_iter());
        w.col_u32(col::job_apps::BATCH_ID, [9u32, 4].into_iter());
        w.col_u32(col::job_apps::NEXT_DUE, [20_735u32, wire::NONE].into_iter());
        let stages: [&[u8]; 2] = [b"gated", b"discovered"];
        w.col_str(col::job_apps::CURRENT_STAGE, stages.into_iter());
        let notes: [&[u8]; 2] = [br#"{"gated":"ok"}"#, b"not json"];
        w.col_str(col::job_apps::STAGE_NOTES, notes.into_iter());
        let listing: [&[u8]; 2] = [b"long text", b"more"];
        w.col_str(col::job_apps::LISTING, listing.into_iter());
        w.end();
        let f = wire::Frame::parse(&w.buf).unwrap();
        let t = f.tables().next().unwrap().unwrap();
        let mut dict = Dict::default();
        dict.names.insert((table::BATCHES, 9), "B-9".into());
        let row = |i| {
            t.cols()
                .filter_map(|c| cell(&c, i, schema::col_def(t.id, c.id).unwrap(), &dict))
                .collect::<HashMap<_, _>>()
        };
        let r0 = row(0);
        assert_eq!(r0["id"], json!(5));
        assert_eq!(r0["batch"], json!("B-9"));
        assert_eq!(r0["current_stage"], json!("gated"));
        assert_eq!(r0["next_due"], json!("2026-10-09"));
        assert_eq!(r0["stage_notes"], json!({"gated": "ok"}));
        assert!(!r0.contains_key("listing"));
        let r1 = row(1);
        assert_eq!(r1["batch_id"], json!(4));
        assert_eq!(r1["next_due"], Value::Null);
        assert_eq!(r1["stage_notes"], json!("not json"));
    }
}
