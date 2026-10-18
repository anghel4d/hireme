//! The wire session hireme-mcp holds: one WebSocket to `/wire`, HELLO with
//! the API key, and every frame after it.
//!
//! The carrier owns the socket, liveness (a PING every 15 s; 45 s of
//! silence ends the session) and reconnects. Callers see three things:
//! [`Carrier::rpc`] and [`Carrier::ops`], which resolve with their REPLY or
//! their ACK/NACK, and the [`Event`] stream, which carries WELCOME, the row
//! frames (BOOT, PATCH, TICK) for the kernel, and the end of a session.
//! A call in flight when the socket drops fails with [`Lost`]: whether an
//! op in it was written is unknown, and a new call is a new op (the ledger
//! dedupes only a resent `op_id`), so the caller reads before it retries.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures_util::{SinkExt, StreamExt};
use serde_json::Value as Json;
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

pub const PING: Duration = Duration::from_secs(15);
pub const SILENT: Duration = Duration::from_secs(45);
/// An RPC whose REPLY never comes fails instead of hanging its tool call.
pub const RPC_WAIT: Duration = Duration::from_secs(30);

/// What WELCOME said about this session.
#[derive(Clone, Debug, Default)]
pub struct Welcome {
    pub account_id: u64,
    pub session_id: u64,
    pub schema_rev: u64,
    pub read_mask: u16,
    pub write_mask: u16,
    pub may_delete: bool,
    pub leased: bool,
    pub label: String,
    pub rev: u64,
}

pub enum Event {
    Welcome(Welcome),
    /// A BOOT, PATCH or TICK frame, whole, for the kernel.
    Rows(Vec<u8>),
    /// The session ended. `again` is false when reconnecting cannot help.
    Ended { reason: String, message: String, again: bool },
}

/// The socket dropped before the answer came.
#[derive(Debug, Clone)]
pub struct Lost(pub String);

/// One op's verdict.
#[derive(Debug, Clone)]
pub enum Verdict {
    Ack { rev: u64, id: u32 },
    Nack { code: u16, data: Json },
}

/// An RPC's answer: `Ok(result)` or `Err(error)` as the server sent them.
pub type Answer = Result<Json, Json>;

type Out = mpsc::UnboundedSender<Vec<u8>>;

struct Live {
    out: Out,
    rpcs: HashMap<u32, oneshot::Sender<Answer>>,
    ops: HashMap<u64, oneshot::Sender<Verdict>>,
}

pub struct Carrier {
    hash: u16,
    /// Ends the current session at once (a frame the caller could not apply); the usual reconnect follows.
    kick: tokio::sync::Notify,
    live: Mutex<Option<Live>>,
    next_rpc: AtomicU32,
    next_op: AtomicU64,
}

/// What HELLO names on each (re)connect: (snapshot_rev, schema_rev).
pub type Snapshot = Arc<dyn Fn() -> (u64, u64) + Send + Sync>;

impl Carrier {
    /// Connects and keeps reconnecting until a session ends for good.
    pub fn start(url: String, key: String, label: String, hash: u16, snapshot: Snapshot) -> (Arc<Carrier>, mpsc::UnboundedReceiver<Event>) {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
        // An op id is unique per key for the ledger's 24 h: the start time in
        // the high bits, a counter in the low 20 (a million ops per process start).
        let base = (now.as_millis() as u64) << 20;
        let carrier = Arc::new(Carrier { hash, kick: tokio::sync::Notify::new(), live: Mutex::new(None), next_rpc: AtomicU32::new(1), next_op: AtomicU64::new(base) });
        let (events, rx) = mpsc::unbounded_channel();
        let c = carrier.clone();
        let watch = events.clone();
        let task = tokio::spawn(async move { c.run(url, key, label, snapshot, events).await });
        // A panic in the carrier is the end of the session, said out loud, not a silent hang.
        tokio::spawn(async move {
            if let Err(e) = task.await {
                let _ = watch.send(Event::Ended { reason: "internal".into(), message: format!("the wire carrier failed: {e}"), again: false });
            }
        });
        (carrier, rx)
    }

    /// Whether a session is up right now (between connect and close).
    pub async fn connected(&self) -> bool {
        self.live.lock().await.is_some()
    }

    /// Drops the session; the next one boots whole.
    pub fn restart(&self) {
        self.kick.notify_one();
    }

    pub fn op_id(&self) -> u64 {
        self.next_op.fetch_add(1, Ordering::Relaxed)
    }

    pub async fn rpc(&self, method: &str, params: &Json) -> Result<Answer, Lost> {
        let id = self.next_rpc.fetch_add(1, Ordering::Relaxed);
        let body = serde_json::to_vec(params).unwrap_or_else(|_| b"{}".to_vec());
        let frame = wire::Rpc { id, method, params: &body }.encode(self.hash);
        let rx = {
            let mut live = self.live.lock().await;
            let Some(l) = live.as_mut() else { return Err(Lost("not connected".into())) };
            let (tx, rx) = oneshot::channel();
            l.rpcs.insert(id, tx);
            l.out.send(frame).map_err(|_| Lost("socket closed".into()))?;
            rx
        };
        match tokio::time::timeout(RPC_WAIT, rx).await {
            Ok(r) => r.map_err(|_| Lost("the session ended before the reply".into())),
            Err(_) => {
                if let Some(l) = self.live.lock().await.as_mut() {
                    l.rpcs.remove(&id);
                }
                Err(Lost(format!("no reply in {} s", RPC_WAIT.as_secs())))
            }
        }
    }

    /// Sends one OPS frame of already-encoded ops (`wire::OpsWriter`) and waits for every verdict.
    pub async fn ops(&self, frame: Vec<u8>, op_ids: &[u64]) -> Result<Vec<Verdict>, Lost> {
        let rxs = {
            let mut live = self.live.lock().await;
            let Some(l) = live.as_mut() else { return Err(Lost("not connected".into())) };
            let rxs: Vec<_> = op_ids
                .iter()
                .map(|id| {
                    let (tx, rx) = oneshot::channel();
                    l.ops.insert(*id, tx);
                    rx
                })
                .collect();
            l.out.send(frame).map_err(|_| Lost("socket closed".into()))?;
            rxs
        };
        // The ledger may hold a verdict that never comes back down: like an RPC, an OPS waits a bounded time.
        let deadline = tokio::time::Instant::now() + RPC_WAIT;
        let mut out = Vec::with_capacity(rxs.len());
        for rx in rxs {
            match tokio::time::timeout_at(deadline, rx).await {
                Ok(v) => out.push(v.map_err(|_| Lost("the session ended before the verdict".into()))?),
                Err(_) => return Err(Lost(format!("no verdict in {} s", RPC_WAIT.as_secs()))),
            }
        }
        Ok(out)
    }

    async fn run(self: Arc<Self>, url: String, key: String, label: String, snapshot: Snapshot, events: mpsc::UnboundedSender<Event>) {
        let mut attempt = 0u32;
        loop {
            let started = Instant::now();
            let end = self.session(&url, &key, &label, &snapshot, &events).await;
            let failed = self.live.lock().await.take();
            drop(failed);
            let (reason, message, again) = end;
            let _ = events.send(Event::Ended { reason: reason.clone(), message, again });
            if !again {
                return;
            }
            if started.elapsed() > Duration::from_secs(60) {
                attempt = 0;
            }
            let wait = Duration::from_millis((500u64 << attempt.min(6)).min(30_000));
            attempt += 1;
            tokio::time::sleep(wait).await;
        }
    }

    /// One session, from connect to close: (reason, message, worth reconnecting).
    async fn session(&self, url: &str, key: &str, label: &str, snapshot: &Snapshot, events: &mpsc::UnboundedSender<Event>) -> (String, String, bool) {
        let request = match url.into_client_request() {
            Ok(r) => r,
            Err(e) => return ("url".into(), format!("{url}: {e}"), false),
        };
        let ws = match tokio_tungstenite::connect_async(request).await {
            Ok((ws, _)) => ws,
            Err(e) => return ("connect".into(), e.to_string(), true),
        };
        let (mut sink, mut stream) = ws.split();
        let (snapshot_rev, schema_rev) = snapshot();
        let hello = wire::Hello {
            cred: wire::CRED_KEY,
            snapshot_rev,
            schema_rev,
            credential: key.as_bytes(),
            label,
        }
        .encode(self.hash);
        if let Err(e) = sink.send(Message::binary(hello)).await {
            return ("connect".into(), e.to_string(), true);
        }
        let (out, mut outq) = mpsc::unbounded_channel::<Vec<u8>>();
        *self.live.lock().await = Some(Live { out: out.clone(), rpcs: HashMap::new(), ops: HashMap::new() });
        let writer = tokio::spawn(async move {
            while let Some(f) = outq.recv().await {
                if sink.send(Message::binary(f)).await.is_err() {
                    break;
                }
            }
            let _ = sink.close().await;
        });
        let mut heard = Instant::now();
        let mut tick = tokio::time::interval(PING);
        tick.tick().await;
        let mut nonce = 0u64;
        let end = loop {
            tokio::select! {
                msg = stream.next() => {
                    let bytes = match msg {
                        Some(Ok(Message::Binary(b))) => b,
                        Some(Ok(Message::Close(c))) => break ("closed".into(), c.map(|c| c.reason.to_string()).unwrap_or_default(), true),
                        Some(Ok(_)) => continue,
                        Some(Err(e)) => break ("socket".into(), e.to_string(), true),
                        None => break ("closed".into(), String::new(), true),
                    };
                    heard = Instant::now();
                    match self.frame(&bytes, events).await {
                        Ok(None) => {}
                        Ok(Some(end)) => break end,
                        Err(e) => break ("frame".into(), format!("{e:?}"), true),
                    }
                }
                _ = self.kick.notified() => break ("restart".into(), "a row frame did not apply".into(), true),
                _ = tick.tick() => {
                    if heard.elapsed() > SILENT {
                        break ("silent".into(), format!("no frame for {} s", SILENT.as_secs()), true);
                    }
                    nonce += 1;
                    let _ = out.send(wire::encode_ping(wire::PING, self.hash, nonce));
                }
            }
        };
        drop(out);
        *self.live.lock().await = None;
        writer.abort();
        end
    }

    async fn frame(&self, bytes: &[u8], events: &mpsc::UnboundedSender<Event>) -> Result<Option<(String, String, bool)>, wire::Error> {
        // A BYE is read whatever wire it was stamped for: a node on a newer schema says so in one.
        let h = wire::Header::peek(bytes)?;
        if h.kind == wire::BYE && h.hash != self.hash {
            let b = wire::Bye::decode(bytes.get(wire::HEADER..h.len as usize).ok_or(wire::Error::Short)?)?;
            return Ok(Some(("schema".into(), format!("the node speaks another wire ({}); update hireme-mcp", b.message), false)));
        }
        let f = wire::Frame::parse(bytes, self.hash)?;
        match f.kind() {
            wire::WELCOME => {
                let body = f.body()?;
                let w = wire::Welcome::decode(&body)?;
                let _ = events.send(Event::Welcome(Welcome {
                    account_id: w.account_id,
                    session_id: w.session_id,
                    schema_rev: w.schema_rev,
                    read_mask: w.read_mask,
                    write_mask: w.write_mask,
                    may_delete: w.may_delete,
                    leased: w.lease,
                    label: w.label.to_owned(),
                    rev: f.header.rev,
                }));
            }
            wire::BOOT | wire::PATCH | wire::TICK => {
                let _ = events.send(Event::Rows(bytes.to_vec()));
            }
            wire::ACK => {
                let body = f.body()?;
                let acks = wire::decode_acks(&body)?;
                let mut live = self.live.lock().await;
                if let Some(l) = live.as_mut() {
                    for a in acks {
                        if let Some(tx) = l.ops.remove(&a.op_id) {
                            let _ = tx.send(Verdict::Ack { rev: a.rev, id: a.id });
                        }
                    }
                }
            }
            wire::NACK => {
                let body = f.body()?;
                let nacks = wire::decode_nacks(&body)?;
                let mut live = self.live.lock().await;
                if let Some(l) = live.as_mut() {
                    for n in nacks {
                        let data = if n.data.is_empty() { Json::Null } else { serde_json::from_slice(n.data).unwrap_or(Json::Null) };
                        if let Some(tx) = l.ops.remove(&n.op_id) {
                            let _ = tx.send(Verdict::Nack { code: n.code, data });
                        }
                    }
                }
            }
            wire::REPLY => {
                let body = f.body()?;
                let r = wire::Reply::decode(&body)?;
                let json: Json = if r.json.is_empty() { Json::Null } else { serde_json::from_slice(r.json).unwrap_or(Json::Null) };
                let mut live = self.live.lock().await;
                if let Some(tx) = live.as_mut().and_then(|l| l.rpcs.remove(&r.id)) {
                    let _ = tx.send(if r.ok { Ok(json) } else { Err(json) });
                }
            }
            wire::PING => {
                let body = f.body()?;
                let nonce = wire::decode_ping(&body)?;
                if let Some(l) = self.live.lock().await.as_ref() {
                    let _ = l.out.send(wire::encode_ping(wire::PONG, self.hash, nonce));
                }
            }
            wire::PONG => {}
            wire::BYE => {
                let body = f.body()?;
                let b = wire::Bye::decode(&body)?;
                let (reason, again) = match b.reason {
                    wire::BYE_REVOKED => ("revoked", false),
                    wire::BYE_SUSPENDED => ("suspended", false),
                    wire::BYE_GRANTS => ("grants", true),
                    wire::BYE_RESTART => ("restart", true),
                    // Same wire, new schema_rev (a server-side column): reconnect and refetch the catalog.
                    wire::BYE_SCHEMA => ("schema", true),
                    _ => ("bye", true),
                };
                return Ok(Some((reason.into(), b.message.to_owned(), again)));
            }
            _ => {}
        }
        Ok(None)
    }
}
