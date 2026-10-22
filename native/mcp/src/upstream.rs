//! One wire session per API key, shared by every local agent holding that
//! key: one carrier, one lease on the node, and a small pool of replicas of
//! the account's rows. The kernel memoizes inside its reads, so a replica
//! serves one read at a time; every frame is applied to every replica, in
//! order, before the next frame is taken, and a read takes whichever
//! replica is free, so agents read in parallel up to the pool's size and a
//! verdict never overtakes the PATCH that carries its write. Writes go out
//! as this session's OPS, each verdict routed back to the call that sent it.
//!
//! The node keys a lease and a bulk contract to the wire session, so the
//! daemon keeps them apart per agent here: each agent's claimed
//! applications are its own (a write naming another agent's is refused
//! `leased` before it is sent), and the node's contract is the pool of
//! every agent's own. After a reconnect the claims are taken again, so a
//! node restart does not cost an agent its lease.

use std::collections::{HashMap, HashSet};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use kernel::abi::Kernel;
use serde_json::{Value as Json, json};
use tokio::sync::{Notify, Semaphore, broadcast, oneshot};

use crate::link::{self, Carrier, Dial, Inbound};
use mcp::tools::Masks;
pub use mcp::session::{Event, Submitted, Verdict};

const PING: Duration = Duration::from_secs(15);
const SILENT: Duration = Duration::from_secs(45);
/// An RPC whose REPLY never comes fails instead of hanging its tool call.
const RPC_WAIT: Duration = Duration::from_secs(30);
/// How long a request waits for the first WELCOME, or for the train, before answering without it.
pub const READY_WAIT: Duration = Duration::from_secs(10);
/// An OPS frame stays under the node's 2 MiB WebSocket frame limit.
const FRAME_BYTES: usize = 1_900_000;
/// The most a bulk contract may hold (the node's own bound).
const BULK_MAX: u64 = 1_000_000;
const BULK_LIFE: Duration = Duration::from_secs(600);

pub type AgentId = u64;

#[derive(Clone, Debug, Default)]
pub struct Welcome {
    pub account_id: u64,
    pub session_id: u64,
    pub read_mask: u16,
    pub write_mask: u16,
    pub may_delete: bool,
}

impl Welcome {
    pub fn masks(&self) -> Masks {
        Masks { read: self.read_mask, write: self.write_mask, may_delete: self.may_delete }
    }
}

/// An RPC's answer as the node sent it: `Ok(result)` or `Err(error)`.
pub type Answer = Result<Json, Json>;

/// The carrier dropped (or never came) before the answer did.
#[derive(Clone, Debug)]
pub struct Lost(pub String);

/// What one agent holds: its claimed applications and its share of the bulk contract.
#[derive(Default)]
struct Hold {
    label: String,
    open: bool,
    ids: HashSet<u32>,
    bulk: Option<(u64, Instant)>,
}

#[derive(Default)]
struct Book {
    agents: HashMap<AgentId, Hold>,
    holder: HashMap<u32, AgentId>,
    /// The operator paused this key's writing: since when, as the node said.
    paused: Option<String>,
}

impl Book {
    fn give(&mut self, agent: AgentId, ids: impl IntoIterator<Item = u32>) {
        let hold = self.agents.entry(agent).or_default();
        hold.open = true;
        for id in ids {
            hold.ids.insert(id);
            self.holder.insert(id, agent);
        }
    }

    fn take(&mut self, agent: AgentId, ids: &[u32]) {
        if let Some(hold) = self.agents.get_mut(&agent) {
            for id in ids {
                hold.ids.remove(id);
            }
        }
        for id in ids {
            if self.holder.get(id) == Some(&agent) {
                self.holder.remove(id);
            }
        }
    }

    /// Writes left in every agent's live contract: what the node's pooled contract must hold.
    fn pool(&self, now: Instant) -> u64 {
        self.agents.values().filter_map(|h| h.bulk).filter(|(_, until)| *until > now).map(|(n, _)| n).sum()
    }
}

struct Live {
    out: tokio::sync::mpsc::UnboundedSender<Vec<u8>>,
    carrier: Carrier,
    rpcs: HashMap<u32, oneshot::Sender<Answer>>,
    ops: HashMap<u64, oneshot::Sender<Verdict>>,
}

#[derive(Default)]
struct State {
    welcome: Option<Welcome>,
    /// The masks the replica was booted under: rows a narrower mask no longer covers must not outlive it.
    built: Option<(u16, u16, bool)>,
    dead: Option<String>,
    connected: Option<Carrier>,
    last_end: String,
}


/// Replicas of the rows, each fed every frame; a read borrows a free one.
struct Replicas {
    all: Vec<Mutex<Kernel>>,
    free: Mutex<Vec<usize>>,
    permits: Semaphore,
}

impl Replicas {
    fn new(n: usize) -> Replicas {
        let n = n.max(1);
        Replicas { all: (0..n).map(|_| Mutex::new(fresh_kernel())).collect(), free: Mutex::new((0..n).collect()), permits: Semaphore::new(n) }
    }

    /// Runs `f` on a free replica (waiting for one when all are reading). A kernel panic is an error.
    async fn with<R>(&self, f: impl FnOnce(&mut Kernel) -> R) -> Result<R, String> {
        let _permit = self.permits.acquire().await.map_err(|_| "the replicas are closed".to_owned())?;
        let i = lock(&self.free).pop().ok_or("no free replica")?;
        let r = {
            let mut k = lock(&self.all[i]);
            // A big read is CPU for a while: the runtime moves other tasks off this thread meanwhile.
            tokio::task::block_in_place(|| catch_unwind(AssertUnwindSafe(|| f(&mut k))))
        };
        lock(&self.free).push(i);
        r.map_err(|_| "the replica failed to answer".to_owned())
    }

    /// Applies `f` to every replica, each in turn (a read in progress on one is waited for).
    fn each(&self, mut f: impl FnMut(&mut Kernel) -> bool) -> bool {
        self.all.iter().all(|k| matches!(catch_unwind(AssertUnwindSafe(|| f(&mut lock(k)))), Ok(true)))
    }

    fn reset(&self) {
        for k in &self.all {
            *lock(k) = fresh_kernel();
        }
    }
}

pub struct Upstream {
    key: String,
    label: String,
    dial: Dial,
    /// The node's https origin, for the blob store.
    pub origin: String,
    replicas: Replicas,
    trained: AtomicBool,
    rev: AtomicU64,
    features: AtomicU16,
    state: Mutex<State>,
    live: Mutex<Option<Live>>,
    book: Mutex<Book>,
    ready: Notify,
    kick: Notify,
    kick_why: Mutex<(&'static str, String)>,
    events: broadcast::Sender<Event>,
    next_rpc: AtomicU32,
    next_op: AtomicU64,
    wt_broken: AtomicBool,
    pub started: Instant,
}

impl Upstream {
    /// Starts the session; it keeps reconnecting until it ends for good.
    pub fn start(key: String, label: String, dial: Dial, origin: String, replicas: usize) -> Arc<Upstream> {
        let up = Arc::new(Upstream {
            key,
            label,
            dial,
            origin,
            replicas: Replicas::new(replicas),
            trained: AtomicBool::new(false),
            rev: AtomicU64::new(0),
            features: AtomicU16::new(0),
            state: Mutex::new(State::default()),
            live: Mutex::new(None),
            book: Mutex::new(Book::default()),
            ready: Notify::new(),
            kick: Notify::new(),
            kick_why: Mutex::new(("requested", String::new())),
            events: broadcast::channel(1024).0,
            next_rpc: AtomicU32::new(1),
            // Op ids are unique per key for the ledger's 24 h: a random base, then counted.
            next_op: AtomicU64::new(random() & 0x3FFF_FFFF_FFFF_FFFF),
            wt_broken: AtomicBool::new(false),
            started: Instant::now(),
        });
        let run = up.clone();
        tokio::spawn(async move { run.run().await });
        up
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub fn welcome(&self) -> Option<Welcome> {
        lock(&self.state).welcome.clone()
    }

    pub fn dead(&self) -> Option<String> {
        lock(&self.state).dead.clone()
    }

    pub fn connected(&self) -> Option<Carrier> {
        lock(&self.state).connected
    }

    pub fn rev(&self) -> u64 {
        self.rev.load(Ordering::Relaxed)
    }

    pub fn is_trained(&self) -> bool {
        self.trained.load(Ordering::Acquire)
    }

    /// The masks once a WELCOME has said them, waiting up to READY_WAIT; none once the session ended for good.
    pub async fn masks(&self) -> Option<Masks> {
        self.wait(|up| lock(&up.state).welcome.as_ref().map(Welcome::masks)).await
    }

    /// Waits until the replica holds its train (READY_WAIT at most).
    pub async fn trained(&self) -> Result<(), String> {
        self.wait(|up| up.is_trained().then_some(())).await;
        self.untrained().map_or(Ok(()), Err)
    }

    /// Why the replica cannot be read yet, or `None` once it holds its train.
    pub fn untrained(&self) -> Option<String> {
        if self.is_trained() {
            return None;
        }
        Some(match self.dead() {
            Some(why) => why,
            None => format!("not connected yet: the replica has not booted ({})", lock(&self.state).last_end),
        })
    }

    async fn wait<T>(&self, mut f: impl FnMut(&Self) -> Option<T>) -> Option<T> {
        let deadline = tokio::time::Instant::now() + READY_WAIT;
        loop {
            let notified = self.ready.notified();
            if let Some(v) = f(self) {
                return Some(v);
            }
            if self.dead().is_some() || tokio::time::Instant::now() >= deadline {
                return None;
            }
            let _ = tokio::time::timeout_at(deadline, notified).await;
        }
    }

    // ------------------------------------------------------------ the replica

    /// Reads a replica (any free one). A kernel panic is an error, never the daemon's end.
    pub async fn read<R>(&self, f: impl FnOnce(&mut Kernel) -> R) -> Result<R, String> {
        self.replicas.with(f).await
    }

    /// The replica no longer matches the node: emptied, and a fresh session boots it whole.
    fn unapplied(&self, why: &str) {
        self.trained.store(false, Ordering::Release);
        self.replicas.reset();
        lock(&self.state).built = None;
        self.restart("unapplied", why);
    }

    // ------------------------------------------------------------ calls

    pub async fn rpc(&self, method: &str, params: &Json) -> Result<Answer, Lost> {
        let id = self.next_rpc.fetch_add(1, Ordering::Relaxed);
        let body = serde_json::to_vec(params).unwrap_or_else(|_| b"{}".to_vec());
        let frame = wire::Rpc { id, method, params: &body }.encode(schema::WIRE_HASH);
        let rx = {
            let mut live = lock(&self.live);
            let Some(l) = live.as_mut() else { return Err(Lost("not connected".into())) };
            let (tx, rx) = oneshot::channel();
            l.rpcs.insert(id, tx);
            l.out.send(frame).map_err(|_| Lost("the carrier closed".into()))?;
            rx
        };
        match tokio::time::timeout(RPC_WAIT, rx).await {
            Ok(r) => r.map_err(|_| Lost("the session ended before the reply".into())),
            Err(_) => {
                if let Some(l) = lock(&self.live).as_mut() {
                    l.rpcs.remove(&id);
                }
                Err(Lost(format!("no reply in {} s", RPC_WAIT.as_secs())))
            }
        }
    }

    /// The first of `n` op ids, unique to this key.
    pub fn op_ids(&self, n: usize) -> u64 {
        self.next_op.fetch_add(n as u64, Ordering::Relaxed)
    }

    /// Sends ops (already encoded, numbered from [`Upstream::op_ids`]) and waits for their verdicts until
    /// `deadline`. `atomic` sends them as one burst when the node takes bursts; otherwise each is judged alone.
    pub async fn submit(&self, ops: &[mcp::Encoded], atomic: bool, deadline: tokio::time::Instant) -> Submitted {
        let atomic = atomic && self.features.load(Ordering::Relaxed) & wire::FEATURE_ATOMIC != 0;
        let mut waits = Vec::with_capacity(ops.len());
        {
            let mut live = lock(&self.live);
            let Some(l) = live.as_mut() else {
                return Submitted { verdicts: vec![None; ops.len()], lost: Some("not connected".into()), atomic };
            };
            for (op_id, _, _) in ops {
                let (tx, rx) = oneshot::channel();
                l.ops.insert(*op_id, tx);
                waits.push(rx);
            }
            let groups = frames(ops);
            let last = groups.len().saturating_sub(1);
            for (i, group) in groups.iter().enumerate() {
                let mut w = wire::Writer::new(wire::OPS, schema::WIRE_HASH, 0);
                w.u32(group.len() as u32).u32(0);
                for (_, _, bytes) in group.iter() {
                    w.bytes(bytes);
                }
                let mut frame = w.finish();
                if atomic {
                    frame[5] |= wire::ATOMIC | if i == last { wire::END } else { 0 };
                }
                if l.out.send(frame).is_err() {
                    let n = ops.len();
                    return Submitted { verdicts: vec![None; n], lost: Some("the carrier closed".into()), atomic };
                }
            }
        }
        let mut verdicts = Vec::with_capacity(waits.len());
        let mut lost = None;
        for rx in waits {
            if lost.is_some() {
                verdicts.push(None);
                continue;
            }
            match tokio::time::timeout_at(deadline, rx).await {
                Ok(Ok(v)) => verdicts.push(Some(v)),
                Ok(Err(_)) => {
                    lost = Some("the session ended before every verdict came".to_owned());
                    verdicts.push(None);
                }
                Err(_) => verdicts.push(None),
            }
        }
        if let Some(l) = lock(&self.live).as_mut() {
            for (op_id, _, _) in ops {
                l.ops.remove(op_id);
            }
        }
        Submitted { verdicts, lost, atomic }
    }

    /// Stores a CV file in the node's blob store under this key (`PUT /blobs`): its SHA-256.
    pub async fn put_blob(&self, ty: &str, bytes: Vec<u8>) -> Result<String, String> {
        use http_body_util::{BodyExt, Full};
        static CLIENT: std::sync::OnceLock<hyper_util::client::legacy::Client<hyper_rustls::HttpsConnector<hyper_util::client::legacy::connect::HttpConnector>, Full<bytes::Bytes>>> = std::sync::OnceLock::new();
        let client = CLIENT.get_or_init(|| {
            let https = hyper_rustls::HttpsConnectorBuilder::new().with_webpki_roots().https_or_http().enable_http1().build();
            hyper_util::client::legacy::Client::builder(hyper_util::rt::TokioExecutor::new()).build(https)
        });
        let request = hyper::Request::put(format!("{}/blobs", self.origin))
            .header("authorization", format!("Bearer {}", self.key))
            .header("content-type", ty)
            .header("user-agent", concat!("hireme-mcp/", env!("CARGO_PKG_VERSION")))
            .body(Full::new(bytes::Bytes::from(bytes)))
            .map_err(|e| format!("the upload could not be made: {e}"))?;
        let response = tokio::time::timeout(RPC_WAIT, client.request(request)).await.map_err(|_| "the upload took over 30 s".to_owned())?.map_err(|e| format!("the upload failed: {e}"))?;
        let status = response.status().as_u16();
        let body = response.into_body().collect().await.map_err(|e| format!("the upload failed: {e}"))?.to_bytes();
        match status {
            200 | 201 => json_of(&body)["sha"].as_str().map(str::to_owned).ok_or_else(|| "the node answered without a sha".to_owned()),
            413 => Err("a CV file is at most 10 MiB".into()),
            415 => Err("name the file .pdf, .docx, .doc or .md (markdown in UTF-8)".into()),
            403 => Err("this key may not write CV files (it needs the corpus domain)".into()),
            s => Err(format!("the node refused the upload ({s})")),
        }
    }

    // ------------------------------------------------------------ the lease, per agent

    /// Who among this daemon's agents holds application `id`.
    pub fn holder(&self, id: u32) -> Option<(AgentId, String)> {
        let book = lock(&self.book);
        book.holder.get(&id).map(|a| (*a, book.agents.get(a).map(|h| h.label.clone()).unwrap_or_default()))
    }

    pub fn held(&self, agent: AgentId) -> (bool, Vec<u32>) {
        let book = lock(&self.book);
        book.agents.get(&agent).map_or((false, Vec::new()), |h| {
            let mut ids: Vec<u32> = h.ids.iter().copied().collect();
            ids.sort_unstable();
            (h.open, ids)
        })
    }

    pub fn paused(&self) -> Option<String> {
        lock(&self.book).paused.clone()
    }

    /// This agent's share of the bulk contract: writes left, if it is live.
    pub fn bulk(&self, agent: AgentId) -> Option<(u64, Duration)> {
        let now = Instant::now();
        lock(&self.book).agents.get(&agent).and_then(|h| h.bulk).filter(|(_, until)| *until > now).map(|(n, until)| (n, until - now))
    }

    /// Spends `n` of this agent's contract for an atomic burst: false when it does not cover them.
    pub fn draw(&self, agent: AgentId, n: u64) -> bool {
        let now = Instant::now();
        let mut book = lock(&self.book);
        match book.agents.get_mut(&agent).and_then(|h| h.bulk.as_mut()) {
            Some((left, until)) if *until > now && *left >= n => {
                *left -= n;
                true
            }
            _ => false,
        }
    }

    /// An application an agent created is its own, as the node holds it for the session that created it.
    pub fn adopt(&self, agent: AgentId, id: u32) {
        lock(&self.book).give(agent, [id]);
    }

    /// `lease` for one agent: ids another agent here holds are refused `leased` without asking the node;
    /// the rest go to the node, and what it grants is this agent's. A bulk ask asks the node for the pool.
    pub async fn claim(&self, agent: AgentId, label: &str, args: &Json) -> Result<Answer, Lost> {
        if let Some(ids) = args.get("ids").and_then(Json::as_array) {
            let book = lock(&self.book);
            let theirs: Vec<(u32, &str)> = ids
                .iter()
                .filter_map(|i| i.as_u64().and_then(|i| u32::try_from(i).ok()))
                .filter_map(|i| book.holder.get(&i).filter(|a| **a != agent).map(|a| (i, book.agents.get(a).map_or("", |h| h.label.as_str()))))
                .collect();
            if let Some((id, who)) = theirs.first() {
                return Ok(Err(json!({"code":"leased","data":{"id": id, "holder": who, "reason": "another agent on this daemon holds it", "ids": theirs.iter().map(|(i, _)| i).collect::<Vec<_>>()}})));
            }
        }
        let mut ask = args.clone();
        let wanted = args.get("bulk").and_then(Json::as_u64);
        if let Some(n) = wanted {
            let pool = lock(&self.book).pool(Instant::now());
            let mine = self.bulk(agent).map_or(0, |(n, _)| n);
            ask["bulk"] = json!((pool - mine + n).min(BULK_MAX));
        }
        let answer = self.rpc("lease.claim", &ask).await?;
        if let Ok(reply) = &answer {
            let mut book = lock(&self.book);
            book.paused = None;
            book.give(agent, ids_of(reply, "ids"));
            let hold = book.agents.entry(agent).or_default();
            hold.label = label.to_owned();
            if let Some(n) = wanted {
                hold.bulk = Some((n, Instant::now() + BULK_LIFE));
            }
        }
        // The node said this agent's own share, not the pool it was asked for.
        Ok(answer.map(|mut reply| {
            if let (Some(n), Some(b)) = (wanted, reply.get_mut("bulk")) {
                b["writes"] = json!(n);
            }
            reply
        }))
    }

    /// `release` for one agent: its own ids (all of them for `None`). The node's channel closes only once
    /// no agent here keeps it open.
    pub async fn release(&self, agent: AgentId, ids: Option<Vec<u32>>) -> Result<Answer, Lost> {
        let (mine, others, last) = {
            let book = lock(&self.book);
            let held = book.agents.get(&agent).map(|h| h.ids.clone()).unwrap_or_default();
            let (mine, others): (Vec<u32>, Vec<u32>) = match &ids {
                Some(ids) => ids.iter().partition(|i| held.contains(i)),
                None => (held.into_iter().collect(), Vec::new()),
            };
            let last = ids.is_none() && !book.agents.iter().any(|(a, h)| *a != agent && h.open);
            (mine, others, last)
        };
        let answer = if last {
            self.rpc("lease.release", &json!({})).await?
        } else if mine.is_empty() {
            Ok(json!({"released": []}))
        } else {
            self.rpc("lease.release", &json!({"ids": mine})).await?
        };
        if answer.is_ok() {
            let mut book = lock(&self.book);
            book.take(agent, &mine);
            if ids.is_none()
                && let Some(h) = book.agents.get_mut(&agent)
            {
                h.open = false;
                h.bulk = None;
            }
        }
        Ok(answer.map(|mut r| {
            if !others.is_empty() {
                r["not_yours"] = json!(others);
            }
            r
        }))
    }

    /// An agent left (closed, or idle past its limit): its claims go back to the node.
    pub async fn forget(&self, agent: AgentId) {
        let open = lock(&self.book).agents.get(&agent).is_some_and(|h| h.open || !h.ids.is_empty());
        if open {
            let _ = self.release(agent, None).await;
        }
        lock(&self.book).agents.remove(&agent);
    }

    /// A refusal that says the node no longer holds the lease (an operator revoke, a pause).
    pub fn lost_lease(&self, paused: Option<String>) {
        let mut book = lock(&self.book);
        book.holder.clear();
        for h in book.agents.values_mut() {
            h.ids.clear();
            h.open = false;
            h.bulk = None;
        }
        if paused.is_some() {
            book.paused = paused;
        }
    }

    /// A new session holds no lease: every agent's claims are asked for again, in one claim.
    async fn reclaim(&self) {
        let (open, ids) = {
            let book = lock(&self.book);
            (book.agents.values().any(|h| h.open), book.holder.keys().copied().collect::<Vec<_>>())
        };
        if !open && ids.is_empty() {
            return;
        }
        let ask = if ids.is_empty() { json!({}) } else { json!({"ids": ids}) };
        match self.rpc("lease.claim", &ask).await {
            Ok(Ok(_)) => {}
            // Taken by another session meanwhile (or paused): what the agents held is gone; their next write says so.
            _ => self.lost_lease(None),
        }
    }

    // ------------------------------------------------------------ the session

    /// Drops the current session; the usual reconnect follows.
    pub fn restart(&self, reason: &'static str, why: &str) {
        *lock(&self.kick_why) = (reason, why.to_owned());
        self.kick.notify_one();
    }

    async fn run(self: Arc<Self>) {
        let mut attempt = 0u32;
        let mut previous = String::new();
        loop {
            let started = Instant::now();
            let (reason, message, again) = match link::connect(&self.dial, self.wt_broken.load(Ordering::Relaxed)).await {
                Ok(link) => self.clone().session(link).await,
                Err(e) => {
                    if self.dial.gate.is_some() {
                        self.wt_broken.store(true, Ordering::Relaxed);
                    }
                    ("connect".to_owned(), e, true)
                }
            };
            {
                let mut s = lock(&self.state);
                s.connected = None;
                s.last_end = format!("{reason}{}{message}", if message.is_empty() { "" } else { ": " });
            }
            // Calls in flight fail now (dropping their senders), not at their timeouts.
            lock(&self.live).take();
            if matches!(reason.as_str(), "grants" | "schema") {
                // Other masks or another schema can change which rows this key sees: the next BOOT is whole.
                self.trained.store(false, Ordering::Release);
                self.replicas.reset();
                lock(&self.state).built = None;
            }
            if !again {
                let why = format!("the session ended for good ({reason}{}{message})", if message.is_empty() { "" } else { ": " });
                lock(&self.state).dead = Some(why.clone());
                let _ = self.events.send(Event::Ended(why));
                self.ready.notify_waiters();
                return;
            }
            self.ready.notify_waiters();
            let lived = started.elapsed();
            let skip = reason == "requested" && lived >= Duration::from_secs(10) && previous != "requested";
            previous.clone_from(&reason);
            if lived > Duration::from_secs(60) || skip {
                attempt = 0;
            }
            if !skip {
                tokio::time::sleep(backoff(attempt, &reason, &message)).await;
                attempt += 1;
            }
        }
    }

    /// One session, from HELLO to its end: (reason, message, worth reconnecting).
    async fn session(self: Arc<Self>, mut link: link::Link) -> (String, String, bool) {
        let _ = futures_util::FutureExt::now_or_never(self.kick.notified());
        // A replica booted under these masks resumes from its rev (a PATCH train); otherwise the node sends a BOOT.
        let resume = self.is_trained() && lock(&self.state).built.is_some();
        let (snapshot_rev, schema_rev) = if resume { (self.rev(), u64::from(schema::SCHEMA_REV)) } else { (0, 0) };
        if !resume {
            self.trained.store(false, Ordering::Release);
        }
        let hello = wire::Hello { cred: wire::CRED_KEY, snapshot_rev, schema_rev, credential: self.key.as_bytes(), label: &self.label }.encode(schema::WIRE_HASH);
        if link.out.send(hello).is_err() {
            return ("connect".into(), "the carrier closed before HELLO".into(), true);
        }
        *lock(&self.live) = Some(Live { out: link.out.clone(), carrier: link.carrier, rpcs: HashMap::new(), ops: HashMap::new() });
        let mut train = Train::new(link.carrier);
        let mut heard = Instant::now();
        let mut tick = tokio::time::interval(PING);
        tick.tick().await;
        let mut nonce = 0u64;
        loop {
            tokio::select! {
                msg = link.inbox.recv() => {
                    heard = Instant::now();
                    let frame = match msg {
                        Some(Inbound::Control(f)) => (f, false),
                        Some(Inbound::Bulk(f)) => (f, true),
                        Some(Inbound::Closed(why)) => return ("closed".into(), why, true),
                        None => return ("closed".into(), String::new(), true),
                    };
                    match self.deliver(frame.0, &mut train, &link.out) {
                        Ok(None) => {}
                        Ok(Some(end)) => return end,
                        Err(e) => return ("frame".into(), e, true),
                    }
                }
                _ = self.kick.notified() => {
                    let (reason, why) = lock(&self.kick_why).clone();
                    return (reason.into(), why, true);
                }
                _ = tick.tick() => {
                    if heard.elapsed() > SILENT {
                        return ("silent".into(), format!("no frame for {} s", SILENT.as_secs()), true);
                    }
                    nonce += 1;
                    let _ = link.out.send(wire::encode_ping(wire::PING, schema::WIRE_HASH, nonce));
                }
            }
        }
    }

    /// One frame from the node. Train frames (a BOOT, or the resume's PATCHes up to WELCOME's rev) pass
    /// at once; on WebTransport every other frame waits for the train's END, since the BOOT rides a stream
    /// of its own (the browser's wire, `assets/js/wire.ts`).
    fn deliver(self: &Arc<Self>, f: Vec<u8>, train: &mut Train, out: &tokio::sync::mpsc::UnboundedSender<Vec<u8>>) -> Result<Option<(String, String, bool)>, String> {
        let h = wire::Header::peek(&f).map_err(|e| format!("{e:?}"))?;
        if h.kind == wire::BYE && h.hash != schema::WIRE_HASH {
            let b = wire::Bye::decode(f.get(wire::HEADER..h.len as usize).unwrap_or(&[])).map(|b| b.message.to_owned()).unwrap_or_default();
            return Ok(Some(("schema".into(), format!("the node speaks another wire ({b}); update hireme-mcp"), false)));
        }
        match h.kind {
            wire::REPLY => {
                let frame = wire::Frame::parse(&f, schema::WIRE_HASH).map_err(|e| format!("{e:?}"))?;
                let body = frame.body().map_err(|e| format!("{e:?}"))?;
                let r = wire::Reply::decode(&body).map_err(|e| format!("{e:?}"))?;
                if let Some(tx) = lock(&self.live).as_mut().and_then(|l| l.rpcs.remove(&r.id)) {
                    let _ = tx.send(if r.ok { Ok(json_of(r.json)) } else { Err(json_of(r.json)) });
                }
                Ok(None)
            }
            wire::PING => {
                let frame = wire::Frame::parse(&f, schema::WIRE_HASH).map_err(|e| format!("{e:?}"))?;
                let n = wire::decode_ping(&frame.body().map_err(|e| format!("{e:?}"))?).map_err(|e| format!("{e:?}"))?;
                let _ = out.send(wire::encode_ping(wire::PONG, schema::WIRE_HASH, n));
                Ok(None)
            }
            wire::WELCOME => {
                train.welcome_rev = Some(h.rev);
                self.welcomed(&f, h.rev)?;
                // A resume PATCH that beat WELCOME was held as live; it is the train after all.
                if let Some(held) = train.held.as_mut().map(std::mem::take) {
                    for g in held {
                        if let Some(end) = self.pass(g, train)? {
                            return Ok(Some(end));
                        }
                    }
                }
                if train.end_early && !train.trained {
                    return self.train_done(train);
                }
                Ok(None)
            }
            _ => self.pass(f, train),
        }
    }

    fn pass(self: &Arc<Self>, f: Vec<u8>, train: &mut Train) -> Result<Option<(String, String, bool)>, String> {
        let h = wire::Header::peek(&f).map_err(|e| format!("{e:?}"))?;
        let is_train = h.kind == wire::BOOT || (h.kind == wire::PATCH && train.welcome_rev.is_some_and(|w| h.rev <= w));
        if let Some(held) = train.held.as_mut()
            && !is_train
            && h.kind != wire::BYE
            && h.kind != wire::PONG
        {
            held.push(f);
            return Ok(None);
        }
        if let Some(end) = self.apply(&f, h)? {
            return Ok(Some(end));
        }
        if train.trained || h.flags & wire::END == 0 || !(is_train || train.held.is_none()) {
            return Ok(None);
        }
        if train.welcome_rev.is_some() {
            self.train_done(train)
        } else {
            if h.kind == wire::BOOT {
                train.end_early = true;
            }
            Ok(None)
        }
    }

    fn train_done(self: &Arc<Self>, train: &mut Train) -> Result<Option<(String, String, bool)>, String> {
        train.trained = true;
        self.trained.store(true, Ordering::Release);
        self.ready.notify_waiters();
        for g in train.held.take().unwrap_or_default() {
            let h = wire::Header::peek(&g).map_err(|e| format!("{e:?}"))?;
            if let Some(end) = self.apply(&g, h)? {
                return Ok(Some(end));
            }
        }
        // A session past its train holds no lease yet: the agents' claims are asked for again.
        let up = self.clone();
        tokio::spawn(async move { up.reclaim().await });
        Ok(None)
    }

    fn apply(&self, f: &[u8], h: wire::Header) -> Result<Option<(String, String, bool)>, String> {
        match h.kind {
            wire::BOOT | wire::PATCH | wire::TICK => {
                let moved = if h.kind == wire::PATCH {
                    wire::Frame::parse(f, schema::WIRE_HASH).ok().and_then(|fr| fr.body().ok().map(|b| mcp::moved(&b)))
                } else {
                    None
                };
                let applied = self.replicas.each(|k| k.ingest(f).is_ok());
                if !applied {
                    self.unapplied("a row frame did not apply");
                    return Ok(None);
                }
                if h.kind == wire::BOOT {
                    let w = lock(&self.state).welcome.as_ref().map(|w| (w.read_mask, w.write_mask, w.may_delete));
                    lock(&self.state).built = w;
                }
                self.rev.fetch_max(h.rev, Ordering::Relaxed);
                let _ = match (h.kind, moved) {
                    (wire::BOOT, _) => self.events.send(Event::Booted),
                    (_, Some(m)) if !m.is_empty() => self.events.send(Event::Moved(Arc::new(m.into_iter().collect()))),
                    _ => Ok(0),
                };
                Ok(None)
            }
            wire::ACK | wire::NACK => {
                let frame = wire::Frame::parse(f, schema::WIRE_HASH).map_err(|e| format!("{e:?}"))?;
                let body = frame.body().map_err(|e| format!("{e:?}"))?;
                let verdicts: Vec<(u64, Verdict)> = if h.kind == wire::ACK {
                    wire::decode_acks(&body).map_err(|e| format!("{e:?}"))?.into_iter().map(|a| (a.op_id, Verdict::Ack { rev: a.rev, id: a.id })).collect()
                } else {
                    wire::decode_nacks(&body).map_err(|e| format!("{e:?}"))?.into_iter().map(|n| (n.op_id, Verdict::Nack { code: n.code, data: json_of(n.data) })).collect()
                };
                let mut live = lock(&self.live);
                if let Some(l) = live.as_mut() {
                    for (op_id, v) in verdicts {
                        if let Some(tx) = l.ops.remove(&op_id) {
                            let _ = tx.send(v);
                        }
                    }
                }
                Ok(None)
            }
            wire::BYE => {
                let frame = wire::Frame::parse(f, schema::WIRE_HASH).map_err(|e| format!("{e:?}"))?;
                let body = frame.body().map_err(|e| format!("{e:?}"))?;
                let b = wire::Bye::decode(&body).map_err(|e| format!("{e:?}"))?;
                let (reason, again) = match b.reason {
                    wire::BYE_REVOKED => ("revoked", false),
                    wire::BYE_SUSPENDED => ("suspended", false),
                    wire::BYE_GRANTS => ("grants", true),
                    wire::BYE_RESTART => ("restart", true),
                    wire::BYE_SCHEMA => ("schema", true),
                    _ => ("bye", true),
                };
                Ok(Some((reason.into(), b.message.to_owned(), again)))
            }
            _ => Ok(None),
        }
    }

    fn welcomed(&self, f: &[u8], rev: u64) -> Result<(), String> {
        let frame = wire::Frame::parse(f, schema::WIRE_HASH).map_err(|e| format!("{e:?}"))?;
        let body = frame.body().map_err(|e| format!("{e:?}"))?;
        let w = wire::Welcome::decode(&body).map_err(|e| format!("{e:?}"))?;
        let welcome = Welcome {
            account_id: w.account_id,
            session_id: w.session_id,
            read_mask: w.read_mask,
            write_mask: w.write_mask,
            may_delete: w.may_delete,
        };
        self.features.store(w.features, Ordering::Relaxed);
        let masks = (w.read_mask, w.write_mask, w.may_delete);
        let carrier = lock(&self.live).as_ref().map(|l| l.carrier);
        let (changed, stale) = {
            let mut s = lock(&self.state);
            let before = s.welcome.as_ref().map(|w| (w.read_mask, w.write_mask, w.may_delete));
            s.welcome = Some(welcome);
            s.connected = carrier;
            (before.map_or(Some(true), |b| (b != masks).then_some(false)), s.built.is_some_and(|b| b != masks))
        };
        let grants = kernel::query::Grants { human: false, read_mask: w.read_mask as u8, write_mask: w.write_mask as u8, may_delete: w.may_delete };
        self.replicas.each(|k| {
            k.set_grants(grants);
            true
        });
        self.rev.fetch_max(rev, Ordering::Relaxed);
        if stale {
            // Booted under other masks: rows the new ones do not cover could linger. A whole BOOT replaces them.
            self.unapplied("the key's masks changed");
        }
        if let Some(first) = changed {
            let _ = self.events.send(Event::Masks(first));
        }
        self.ready.notify_waiters();
        Ok(())
    }

    /// For `/health`: what this session is doing.
    pub fn status(&self) -> Json {
        let s = lock(&self.state);
        let book = lock(&self.book);
        json!({
            "label": self.label,
            "up_s": self.started.elapsed().as_secs(),
            "account": s.welcome.as_ref().map(|w| w.account_id),
            "carrier": s.connected.map(Carrier::name),
            "trained": self.is_trained(),
            "replicas": self.replicas.all.len(),
            "rev": self.rev(),
            "atomic": self.features.load(Ordering::Relaxed) & wire::FEATURE_ATOMIC != 0,
            "agents_holding": book.agents.values().filter(|h| h.open).count(),
            "claimed": book.holder.len(),
            "paused": book.paused,
            "dead": s.dead,
            "last_end": s.last_end,
        })
    }
}

/// The ordering state of one session's train.
struct Train {
    /// Frames that wait for the train's END (WebTransport only; a socket is one ordered stream).
    held: Option<Vec<Vec<u8>>>,
    welcome_rev: Option<u64>,
    trained: bool,
    /// A BOOT flagged END came before WELCOME (it rides its own stream).
    end_early: bool,
}

impl Train {
    fn new(carrier: Carrier) -> Train {
        Train { held: (carrier == Carrier::WebTransport).then(Vec::new), welcome_rev: None, trained: false, end_early: false }
    }
}

/// Ops grouped into OPS frames under the node's frame limit and the 256-op cap.
fn frames(ops: &[mcp::Encoded]) -> Vec<&[mcp::Encoded]> {
    let mut out = Vec::new();
    let (mut start, mut bytes) = (0, 0);
    for (i, (_, _, b)) in ops.iter().enumerate() {
        if i > start && (i - start >= wire::MAX_OPS || bytes + b.len() > FRAME_BYTES) {
            out.push(&ops[start..i]);
            start = i;
            bytes = 0;
        }
        bytes += b.len();
    }
    if start < ops.len() {
        out.push(&ops[start..]);
    }
    out
}

/// Doubling from 0.5 s to 30 s, and at least a minute when the node said its limit lifts in one.
fn backoff(attempt: u32, reason: &str, message: &str) -> Duration {
    let doubling = Duration::from_millis((500u64 << attempt.min(6)).min(30_000));
    if reason == "restart" && message.contains("retry in a minute") { doubling.max(Duration::from_secs(60)) } else { doubling }
}

fn ids_of(v: &Json, k: &str) -> Vec<u32> {
    v.get(k).and_then(Json::as_array).map(|a| a.iter().filter_map(Json::as_u64).filter_map(|i| u32::try_from(i).ok()).collect()).unwrap_or_default()
}

/// A frame's JSON field; an empty one, or one that does not parse, is null.
fn json_of(b: &[u8]) -> Json {
    if b.is_empty() { Json::Null } else { serde_json::from_slice(b).unwrap_or(Json::Null) }
}

/// A poisoned lock is still the data: a panic elsewhere must not take every agent down with it.
pub fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| {
        m.clear_poison();
        p.into_inner()
    })
}

/// An empty kernel that knows today; the node's `clock` takes over once a TICK lands.
fn fresh_kernel() -> Kernel {
    let mut k = Kernel::new();
    k.set_today((now() / 86_400) as i32 + kernel::UNIX_EPOCH_DAY);
    k
}

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64)
}

/// 64 random bits from the OS's hash seeding, mixed with the clock: enough for op-id bases and nonces.
pub fn random() -> u64 {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos()));
    h.write_u32(std::process::id());
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ops_split_into_frames_under_the_node_limit_and_the_op_cap() {
        let big = (1u64, String::new(), vec![0u8; 1 << 20]);
        let small = (2u64, String::new(), vec![0u8; 32]);
        let three = vec![big.clone(), big.clone(), big];
        assert_eq!(frames(&three).iter().map(|f| f.len()).collect::<Vec<_>>(), vec![1, 1, 1]);
        let many = vec![small; 300];
        assert_eq!(frames(&many).iter().map(|f| f.len()).collect::<Vec<_>>(), vec![256, 44]);
        assert!(frames(&[]).is_empty());
    }

    #[test]
    fn reconnects_back_off_and_wait_out_a_throttle() {
        assert_eq!(backoff(0, "restart", "too many sessions"), Duration::from_millis(500));
        assert_eq!(backoff(10, "socket", ""), Duration::from_secs(30));
        assert_eq!(backoff(0, "restart", "rate limited; retry in a minute"), Duration::from_secs(60));
    }

    #[test]
    fn the_pooled_contract_is_every_live_share() {
        let mut book = Book::default();
        let now = Instant::now();
        book.agents.insert(1, Hold { bulk: Some((300, now + BULK_LIFE)), ..Hold::default() });
        book.agents.insert(2, Hold { bulk: Some((200, now + BULK_LIFE)), ..Hold::default() });
        book.agents.insert(3, Hold { bulk: Some((900, now)), ..Hold::default() });
        assert_eq!(book.pool(now), 500);
        book.give(1, [7, 8]);
        book.take(2, &[7]);
        assert_eq!(book.holder.get(&7), Some(&1), "only the holder releases");
        book.take(1, &[7]);
        assert_eq!(book.holder.get(&7), None);
    }
}
