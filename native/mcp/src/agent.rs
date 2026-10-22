//! One local agent: the MCP session ([`mcp::session`], the node's too)
//! hosted over the daemon's shared [`Upstream`] instead of a wire session
//! of its own. Each step of a request runs on a free replica; its effects
//! go out as the upstream's ops, claims and blobs; the upstream's events
//! become the agent's notifications, sent to the streams the front opened.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use mcp::session::{self, Effect, Host, Outcome, Session, SinkId, Step, Wait};
use mcp::tools::Masks;
use serde_json::{Value as Json, json};
use tokio::sync::{broadcast, mpsc};

use crate::upstream::{AgentId, Event, Upstream, lock, now, random};

/// Where an agent's notifications go: a legacy stream (or stdio), or one `subscriptions/listen`.
pub type Sink = mpsc::UnboundedSender<Json>;

pub struct Agent {
    pub id: AgentId,
    pub sid: String,
    pub up: Arc<Upstream>,
    session: Mutex<Session>,
    sinks: Mutex<HashMap<SinkId, Sink>>,
    next_sink: AtomicU64,
    /// Unix seconds of the last request: an agent idle past its limit is closed, its lease with it.
    used: AtomicU64,
    pump: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

static NEXT: AtomicU64 = AtomicU64::new(1);

impl Agent {
    pub fn new(up: Arc<Upstream>, label: String, sid: Option<String>) -> Arc<Agent> {
        Arc::new(Agent {
            id: NEXT.fetch_add(1, Ordering::Relaxed),
            sid: sid.unwrap_or_else(|| format!("{:016x}{:016x}", random(), random())),
            up,
            session: Mutex::new(Session::new(label)),
            sinks: Mutex::new(HashMap::new()),
            next_sink: AtomicU64::new(1),
            used: AtomicU64::new(now() as u64),
            pump: Mutex::new(None),
        })
    }

    pub fn idle_for(&self) -> u64 {
        (now() as u64).saturating_sub(self.used.load(Ordering::Relaxed))
    }

    pub fn streaming(&self) -> bool {
        lock(&self.session).streaming()
    }

    /// The agent's end: its streams close, and its lease goes back to the node.
    pub async fn close(&self) {
        if let Some(p) = lock(&self.pump).take() {
            p.abort();
        }
        let out = lock(&self.session).close();
        self.deliver(out);
        lock(&self.sinks).clear();
        self.up.forget(self.id).await;
    }

    /// A legacy notification stream (the HTTP GET, or stdio's stdout).
    pub fn attach(self: &Arc<Self>, sink: Sink) {
        let id = self.register(sink);
        lock(&self.session).attach(id);
        self.follow();
    }

    /// One JSON-RPC message: the answer to send, or `None` (a notification, a response, a cancelled request).
    pub async fn message(self: &Arc<Self>, msg: Json) -> Option<Json> {
        self.used.store(now() as u64, Ordering::Relaxed);
        let answer = self.drive(move |s, k, h| s.request(k, h, msg)).await;
        self.follow();
        answer
    }

    /// `subscriptions/listen`: the acknowledgment to send first, and the stream stays open on `sink`.
    pub async fn listen(self: &Arc<Self>, msg: &Json, sink: Sink) -> Json {
        let id = self.register(sink);
        let msg = msg.clone();
        let ack = self.drive(move |s, k, h| s.listen(k, h, msg, id)).await;
        self.follow();
        ack.unwrap_or(Json::Null)
    }

    fn register(&self, sink: Sink) -> SinkId {
        let id = self.next_sink.fetch_add(1, Ordering::Relaxed);
        lock(&self.sinks).insert(id, sink);
        id
    }

    /// Steps a request to its answer: each step on a free replica, each effect on the upstream between them.
    async fn drive(&self, first: impl FnOnce(&mut Session, &mut kernel::abi::Kernel, &dyn Host) -> Step) -> Option<Json> {
        let host = Facts { up: &self.up, agent: self.id };
        let mut step = match self.up.read(|k| first(&mut lock(&self.session), k, &host)).await {
            Ok(step) => step,
            Err(why) => return Some(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":why}})),
        };
        loop {
            let (ticket, effect) = match step {
                Step::Answer(answer) => return answer,
                Step::Pending(ticket, effect) => (ticket, effect),
            };
            let outcome = self.perform(effect).await;
            step = match self.up.read(|k| lock(&self.session).resume(k, &host, ticket, outcome)).await {
                Ok(step) => step,
                Err(why) => return Some(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":why}})),
            };
        }
    }

    async fn perform(&self, effect: Effect) -> Outcome {
        match effect {
            Effect::Wait(Wait::Masks) => {
                self.up.masks().await;
                Outcome::Waited
            }
            Effect::Wait(Wait::Trained) => {
                let _ = self.up.trained().await;
                Outcome::Waited
            }
            Effect::Submit { ops, atomic } => Outcome::Submitted(self.up.submit(&ops, atomic, tokio::time::Instant::now() + session::DEADLINE).await),
            Effect::Claim { label, args } => Outcome::Claimed(self.up.claim(self.id, &label, &args).await.map_err(|lost| lost.0)),
            Effect::Release(ids) => Outcome::Released(self.up.release(self.id, ids).await.map_err(|lost| lost.0)),
            Effect::Blob { ty, bytes } => Outcome::Blob(self.up.put_blob(ty, bytes).await),
        }
    }

    /// Notifications to their streams; a legacy stream that is gone is forgotten.
    fn deliver(&self, out: Vec<(SinkId, Json)>) {
        let mut gone = Vec::new();
        {
            let sinks = lock(&self.sinks);
            for (id, v) in out {
                if sinks.get(&id).is_none_or(|s| s.send(v).is_err()) {
                    gone.push(id);
                }
            }
        }
        if !gone.is_empty() {
            let mut s = lock(&self.session);
            let mut sinks = lock(&self.sinks);
            for id in gone {
                s.detach(id);
                sinks.remove(&id);
            }
        }
    }

    /// A task that turns the upstream's events into this agent's notifications, while it has somewhere to send them.
    fn follow(self: &Arc<Self>) {
        if !lock(&self.session).following() {
            return;
        }
        let mut pump = lock(&self.pump);
        if pump.as_ref().is_some_and(|p| !p.is_finished()) {
            return;
        }
        let me = Arc::downgrade(self);
        let mut events = self.up.subscribe();
        *pump = Some(tokio::spawn(async move {
            loop {
                let e = match events.recv().await {
                    Ok(e) => e,
                    // Fell behind: every watched row may have moved.
                    Err(broadcast::error::RecvError::Lagged(_)) => Event::Booted,
                    Err(broadcast::error::RecvError::Closed) => return,
                };
                let Some(agent) = me.upgrade() else { return };
                let out = lock(&agent.session).event(&e);
                agent.deliver(out);
            }
        }));
    }
}

/// What the session asks the daemon: the upstream's book, for this agent.
struct Facts<'a> {
    up: &'a Upstream,
    agent: AgentId,
}

impl Host for Facts<'_> {
    fn agent(&self) -> u64 {
        self.agent
    }
    fn masks(&self) -> Option<Masks> {
        self.up.welcome().map(|w| w.masks())
    }
    fn welcome(&self) -> Option<(u64, u64)> {
        self.up.welcome().map(|w| (w.account_id, w.session_id))
    }
    fn dead(&self) -> Option<String> {
        self.up.dead()
    }
    fn untrained(&self) -> Option<String> {
        self.up.untrained()
    }
    fn held(&self) -> (bool, Vec<u32>) {
        self.up.held(self.agent)
    }
    fn paused(&self) -> Option<String> {
        self.up.paused()
    }
    fn bulk(&self) -> Option<(u64, u64)> {
        self.up.bulk(self.agent).map(|(n, left)| (n, left.as_secs()))
    }
    fn rev(&self) -> u64 {
        self.up.rev()
    }
    fn carrier(&self) -> Option<&'static str> {
        self.up.connected().map(crate::link::Carrier::name)
    }
    fn origin(&self) -> String {
        self.up.origin.clone()
    }
    fn server(&self) -> (String, String) {
        ("hireme-mcp".into(), env!("CARGO_PKG_VERSION").into())
    }
    fn holder(&self, application: u32) -> Option<(u64, String)> {
        self.up.holder(application)
    }
    fn draw(&self, n: u64) -> bool {
        self.up.draw(self.agent, n)
    }
    fn op_ids(&self, n: usize) -> u64 {
        self.up.op_ids(n)
    }
    fn adopt(&self, application: u32) {
        self.up.adopt(self.agent, application);
    }
    fn lost_lease(&self, paused: Option<String>) {
        self.up.lost_lease(paused);
    }
}
