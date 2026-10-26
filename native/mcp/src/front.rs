//! The daemon's two doors. Over HTTP on loopback (MCP's Streamable HTTP
//! transport) any number of local agents each hold an MCP session: an
//! [`Agent`] on the upstream of the key it presents, so a hundred agents on
//! one key are a hundred sessions in this one process sharing one wire
//! session and one replica. Over stdio, one agent, in process.
//!
//! An agent presents either the daemon's local token (the daemon's own key)
//! or an API key of its own (which gets an upstream of its own). The port
//! answers loopback only, and a request with an `Origin` or a Host that is
//! not loopback is refused: a web page must never reach the operator's key
//! through it (DNS rebinding).

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, Limited, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::{Request, Response, StatusCode};
use serde_json::{Value as Json, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::agent::Agent;
use crate::upstream::{Upstream, lock};

/// A burst of puts is one request: room for a big one, never unbounded.
const MAX_BODY: usize = 64 << 20;
/// An agent that has served nothing for this long (and holds no stream) ends, its lease with it.
const IDLE: Duration = Duration::from_secs(30 * 60);
const KEEPALIVE: Duration = Duration::from_secs(15);

type Body = BoxBody<Bytes, Infallible>;

pub struct Config {
    /// The node's `/wire` socket URL.
    pub wire: String,
    pub origin: String,
    pub label: String,
    /// The daemon's own key, for agents that present the local token; none: every agent brings its own.
    pub key: Option<String>,
    pub token: String,
    /// Replicas of the rows per key: how many reads run at once.
    pub replicas: usize,
}

pub struct Daemon {
    cfg: Config,
    upstreams: Mutex<HashMap<String, Arc<Upstream>>>,
    agents: Mutex<HashMap<String, (String, Arc<Agent>)>>,
    /// A key's default agent: requests that name no session (a stateless client keeps its lease).
    defaults: Mutex<HashMap<String, String>>,
}

impl Daemon {
    pub fn new(cfg: Config) -> Arc<Daemon> {
        Arc::new(Daemon { cfg, upstreams: Mutex::new(HashMap::new()), agents: Mutex::new(HashMap::new()), defaults: Mutex::new(HashMap::new()) })
    }

    /// The key's upstream, started on first use.
    pub fn upstream(&self, key: &str) -> Arc<Upstream> {
        lock(&self.upstreams)
            .entry(key.to_owned())
            .or_insert_with(|| Upstream::start(key.to_owned(), self.cfg.label.clone(), self.cfg.wire.clone(), self.cfg.origin.clone(), self.cfg.replicas))
            .clone()
    }

    /// Serves HTTP on `addr` until the process ends.
    pub async fn serve(self: Arc<Self>, addr: SocketAddr) -> std::io::Result<()> {
        let listener = tokio::net::TcpListener::bind(addr).await?;
        eprintln!("hireme-mcp: serving MCP on http://{addr}/mcp");
        if let Some(key) = &self.cfg.key {
            // The daemon's own key connects at once, so the first agent finds the replica warm.
            let _ = self.upstream(key);
        }
        let reaper = self.clone();
        tokio::spawn(async move { reaper.reap().await });
        loop {
            let (stream, _) = listener.accept().await?;
            let _ = stream.set_nodelay(true);
            let daemon = self.clone();
            tokio::spawn(async move {
                let service = hyper::service::service_fn(move |req| {
                    let daemon = daemon.clone();
                    async move { Ok::<_, Infallible>(daemon.handle(req, addr).await) }
                });
                let _ = hyper::server::conn::http1::Builder::new().keep_alive(true).serve_connection(hyper_util::rt::TokioIo::new(stream), service).await;
            });
        }
    }

    async fn reap(&self) {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            let idle: Vec<Arc<Agent>> = {
                let mut agents = lock(&self.agents);
                let gone: Vec<String> = agents.iter().filter(|(_, (_, a))| a.idle_for() >= IDLE.as_secs() && !a.streaming()).map(|(sid, _)| sid.clone()).collect();
                gone.into_iter().filter_map(|sid| agents.remove(&sid).map(|(_, a)| a)).collect()
            };
            lock(&self.defaults).retain(|_, sid| !idle.iter().any(|a| &a.sid == sid));
            for a in idle {
                a.close().await;
            }
        }
    }

    /// Every agent ends (each one's lease goes back to the node).
    pub async fn shutdown(&self) {
        let agents: Vec<Arc<Agent>> = lock(&self.agents).drain().map(|(_, (_, a))| a).collect();
        for a in agents {
            a.close().await;
        }
    }

    async fn handle(self: &Arc<Self>, req: Request<Incoming>, addr: SocketAddr) -> Response<Body> {
        if !loopback_host(req.headers().get("host").and_then(|h| h.to_str().ok()), addr) || req.headers().contains_key("origin") {
            return plain(StatusCode::FORBIDDEN, "a page in a browser may not call this daemon");
        }
        let Some(key) = self.key_of(req.headers().get("authorization").and_then(|h| h.to_str().ok())) else {
            let mut r = plain(StatusCode::UNAUTHORIZED, "present the daemon's token (hireme-mcp token) or an API key as Bearer");
            r.headers_mut().insert("www-authenticate", hyper::header::HeaderValue::from_static("Bearer realm=\"hireme-mcp\""));
            return r;
        };
        match (req.method().as_str(), req.uri().path()) {
            ("GET", "/health") => self.health(),
            ("POST", "/mcp") => self.post(req, &key).await,
            ("GET", "/mcp") => match self.agent(&key, req.headers().get("mcp-session-id").and_then(|h| h.to_str().ok()), None) {
                Ok(agent) => {
                    let (sink, rx) = mpsc::unbounded_channel();
                    agent.attach(sink);
                    events(rx, &agent.sid, Vec::new())
                }
                Err((status, why)) => plain(status, why),
            },
            ("DELETE", "/mcp") => {
                let sid = req.headers().get("mcp-session-id").and_then(|h| h.to_str().ok()).unwrap_or("").to_owned();
                let found = lock(&self.agents).remove(&sid);
                match found {
                    Some((owner, agent)) if owner == key => {
                        lock(&self.defaults).retain(|_, s| s != &sid);
                        agent.close().await;
                        empty(StatusCode::NO_CONTENT)
                    }
                    Some(entry) => {
                        lock(&self.agents).insert(sid, entry);
                        plain(StatusCode::NOT_FOUND, "no such session")
                    }
                    None => plain(StatusCode::NOT_FOUND, "no such session"),
                }
            }
            (_, "/mcp") => plain(StatusCode::METHOD_NOT_ALLOWED, "MCP takes GET, POST and DELETE"),
            _ => plain(StatusCode::NOT_FOUND, "the daemon serves /mcp and /health"),
        }
    }

    /// The key a request stands for: the daemon's own behind its token, or the one it presents.
    fn key_of(&self, auth: Option<&str>) -> Option<String> {
        let secret = auth?.strip_prefix("Bearer ")?.trim();
        if same(secret.as_bytes(), self.cfg.token.as_bytes()) {
            return self.cfg.key.clone();
        }
        // An API key's shape: the node checks the key itself on HELLO.
        (secret.starts_with("hm_") && secret.len() <= 256).then(|| secret.to_owned())
    }

    /// The session a request names (a new one under that id when the daemon no longer holds it), the one an
    /// `initialize` starts, or the key's default.
    fn agent(&self, key: &str, sid: Option<&str>, method: Option<&str>) -> Result<Arc<Agent>, (StatusCode, &'static str)> {
        let mut agents = lock(&self.agents);
        if let Some(sid) = sid {
            return match agents.get(sid) {
                Some((owner, a)) if owner == key => Ok(a.clone()),
                Some(_) => Err((StatusCode::NOT_FOUND, "that session id is another key's")),
                None if sid.len() >= 16 && sid.len() <= 128 && sid.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') => {
                    let a = Agent::new(self.upstream(key), String::new(), Some(sid.to_owned()));
                    agents.insert(sid.to_owned(), (key.to_owned(), a.clone()));
                    Ok(a)
                }
                None => Err((StatusCode::NOT_FOUND, "no such session")),
            };
        }
        if method != Some("initialize")
            && let Some(sid) = lock(&self.defaults).get(key)
            && let Some((_, a)) = agents.get(sid)
        {
            return Ok(a.clone());
        }
        let a = Agent::new(self.upstream(key), String::new(), None);
        agents.insert(a.sid.clone(), (key.to_owned(), a.clone()));
        if method != Some("initialize") {
            lock(&self.defaults).insert(key.to_owned(), a.sid.clone());
        }
        Ok(a)
    }

    async fn post(self: &Arc<Self>, req: Request<Incoming>, key: &str) -> Response<Body> {
        let sid = req.headers().get("mcp-session-id").and_then(|h| h.to_str().ok()).map(str::to_owned);
        let body = match Limited::new(req.into_body(), MAX_BODY).collect().await {
            Ok(b) => b.to_bytes(),
            Err(_) => return rpc_error(StatusCode::PAYLOAD_TOO_LARGE, Json::Null, -32000, &format!("the body is over {} MiB", MAX_BODY >> 20)),
        };
        let msg: Json = match serde_json::from_slice(&body) {
            Ok(Json::Object(o)) if o.get("jsonrpc") == Some(&json!("2.0")) => Json::Object(o),
            Ok(Json::Array(_)) => return rpc_error(StatusCode::BAD_REQUEST, Json::Null, -32600, "one JSON-RPC 2.0 message per request; batches are not answered"),
            _ => return rpc_error(StatusCode::BAD_REQUEST, Json::Null, -32700, "the body is not one JSON-RPC 2.0 message"),
        };
        let method = msg.get("method").and_then(Json::as_str).map(str::to_owned);
        let agent = match self.agent(key, sid.as_deref(), method.as_deref()) {
            Ok(a) => a,
            Err((status, why)) => return plain(status, why),
        };
        if method.as_deref() == Some("subscriptions/listen") && msg.get("id").is_some() {
            let (sink, rx) = mpsc::unbounded_channel();
            let ack = agent.listen(&msg, sink).await;
            return events(rx, &agent.sid, vec![ack]);
        }
        // A notification, a response, or a request cancelled meanwhile: taken, nothing to answer.
        let mut r = match agent.message(msg).await {
            Some(answer) => json_response(StatusCode::OK, &answer),
            None => empty(StatusCode::ACCEPTED),
        };
        set_sid(&mut r, &agent.sid);
        r
    }

    fn health(&self) -> Response<Body> {
        let agents = lock(&self.agents);
        let upstreams = lock(&self.upstreams);
        json_response(
            StatusCode::OK,
            &json!({
                "agents": agents.len(),
                "streaming": agents.values().filter(|(_, a)| a.streaming()).count(),
                "upstreams": upstreams.values().map(|u| u.status()).collect::<Vec<_>>(),
            }),
        )
    }
}

/// One agent over stdin and stdout, in this process: newline-delimited JSON-RPC.
pub async fn stdio(up: Arc<Upstream>) {
    let (out, mut outq) = mpsc::unbounded_channel::<Json>();
    tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(v) = outq.recv().await {
            let mut line = v.to_string();
            line.push('\n');
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    let agent = Agent::new(up, String::new(), None);
    agent.attach(out.clone());
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let msg: Json = match serde_json::from_str(&line) {
            Ok(Json::Object(o)) => Json::Object(o),
            Ok(Json::Array(_)) => {
                let _ = out.send(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"JSON-RPC batches are not supported; send one message per line"}}));
                continue;
            }
            Ok(_) | Err(_) => {
                // A blob that spans lines is the mistake callers actually make: the door reads one
                // message per line, so name that rather than only saying "not JSON".
                let message = if line.trim_start().starts_with('{') && !line.trim_end().ends_with('}') {
                    "this line is not a whole JSON-RPC message: the stdio door reads one message per line, so arguments must stay on one line (a multi-line blob arrives as fragments)"
                } else {
                    "not a JSON-RPC message"
                };
                let _ = out.send(json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":message}}));
                continue;
            }
        };
        let (agent, out) = (agent.clone(), out.clone());
        // Each request on its own task: a slow write never holds up the reads behind it.
        tokio::spawn(async move {
            if msg.get("method").and_then(Json::as_str) == Some("subscriptions/listen") && msg.get("id").is_some() {
                let ack = agent.listen(&msg, out.clone()).await;
                let _ = out.send(ack);
            } else if let Some(answer) = agent.message(msg).await {
                let _ = out.send(answer);
            }
        });
    }
    agent.close().await;
}

/// An event stream: the first events, then whatever reaches the sink, with a keepalive comment.
fn events(rx: mpsc::UnboundedReceiver<Json>, sid: &str, first: Vec<Json>) -> Response<Body> {
    let stream = futures_util::stream::unfold((rx, first.into_iter(), tokio::time::interval(KEEPALIVE)), |(mut rx, mut first, mut tick)| async move {
        if let Some(v) = first.next() {
            return Some((Ok::<_, Infallible>(Frame::data(sse(&v))), (rx, first, tick)));
        }
        tokio::select! {
            v = rx.recv() => v.map(|v| (Ok(Frame::data(sse(&v))), (rx, first, tick))),
            _ = tick.tick() => Some((Ok(Frame::data(Bytes::from_static(b": keepalive\n\n"))), (rx, first, tick))),
        }
    });
    let mut r = Response::new(StreamBody::new(stream).boxed());
    let h = r.headers_mut();
    h.insert("content-type", hyper::header::HeaderValue::from_static("text/event-stream"));
    h.insert("cache-control", hyper::header::HeaderValue::from_static("no-store"));
    set_sid(&mut r, sid);
    r
}

fn sse(v: &Json) -> Bytes {
    Bytes::from(format!("event: message\ndata: {v}\n\n"))
}

fn set_sid(r: &mut Response<Body>, sid: &str) {
    if let Ok(v) = hyper::header::HeaderValue::from_str(sid) {
        r.headers_mut().insert("mcp-session-id", v);
    }
}

fn json_response(status: StatusCode, v: &Json) -> Response<Body> {
    let mut r = Response::new(Full::new(Bytes::from(v.to_string())).boxed());
    *r.status_mut() = status;
    r.headers_mut().insert("content-type", hyper::header::HeaderValue::from_static("application/json"));
    r
}

fn rpc_error(status: StatusCode, id: Json, code: i64, message: &str) -> Response<Body> {
    json_response(status, &json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}))
}

fn plain(status: StatusCode, message: &str) -> Response<Body> {
    rpc_error(status, Json::Null, -32000, message)
}

fn empty(status: StatusCode) -> Response<Body> {
    let mut r = Response::new(Full::new(Bytes::new()).boxed());
    *r.status_mut() = status;
    r
}

/// Whether a Host header names this loopback listener (by address or as localhost).
fn loopback_host(host: Option<&str>, addr: SocketAddr) -> bool {
    let Some(host) = host else { return false };
    let (name, port) = match host.strip_prefix('[') {
        Some(rest) => match rest.split_once(']') {
            Some((h, p)) => (h, p.strip_prefix(':').unwrap_or(p)),
            None => return false,
        },
        None => host.rsplit_once(':').unwrap_or((host, "")),
    };
    (port.is_empty() || port == addr.port().to_string()) && matches!(name, "127.0.0.1" | "localhost" | "::1")
}

/// Compares secrets in time that does not depend on where they differ.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_loopback_host_reaches_the_daemon() {
        let addr: SocketAddr = "127.0.0.1:7341".parse().unwrap();
        for ok in ["127.0.0.1:7341", "localhost:7341", "[::1]:7341", "localhost", "[::1]"] {
            assert!(loopback_host(Some(ok), addr), "{ok}");
        }
        for bad in ["evil.example:7341", "127.0.0.1:80", "localhost.evil.example:7341", "[::1]:9", ""] {
            assert!(!loopback_host(Some(bad), addr), "{bad}");
        }
        assert!(!loopback_host(None, addr));
    }

    #[test]
    fn the_token_comparison_needs_every_byte() {
        assert!(same(b"abc", b"abc"));
        assert!(!same(b"abc", b"abd"));
        assert!(!same(b"abc", b"ab"));
    }
}
