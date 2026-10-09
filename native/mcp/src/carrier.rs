//! The two ways hireme-mcp reaches hireme, behind one shape.
//!
//! **WebTransport** (the default): one QUIC session to the gate. Bidi
//! stream 0 is the control stream. It carries the agent HELLO (flag
//! AGENT, the API key as credential), then the BOOT (flagged END) that
//! means "ready", then the account's columnar PATCH fan-out. Each
//! letterbox lease is one more bidi stream: a LEASE frame first, then
//! RPC frames both ways. Closing the stream releases the lease. One key
//! authentication per session, however many leases.
//!
//! **WebSocket** (the fallback, for networks that drop UDP): today's
//! per-lease sockets, `/mcp/websocket` and
//! `/mcp/letterbox/:id/websocket`. Each one is a key authentication and
//! carries no columnar rows, but it works where QUIC cannot.
//!
//! Either way a lane is a pair of channels of JSON-RPC values. The
//! carrier is responsible only for moving those values.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest, http::HeaderValue};
use wire::schema::frame;
use wtransport::{ClientConfig, Connection, Endpoint, tls::Sha256Digest};

/// Messages to the server, and messages from it, for one lane.
pub type Up = mpsc::UnboundedSender<Value>;
pub type Down = mpsc::UnboundedReceiver<Value>;

/// A whole frame from the control stream, handed to the hub as it arrives.
pub type ControlSink = Box<dyn Fn(wire::Frame<'_>) + Send + Sync>;

#[derive(Clone, Debug)]
pub struct Config {
    pub key: String,
    pub wt_url: Option<String>,
    pub wt_cert: Option<String>,
    pub wt_cert_file: Option<String>,
    pub ws_url: Option<String>,
    pub mode: Mode,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Auto,
    Wt,
    Ws,
}

impl Config {
    pub fn from_env() -> Result<Config, String> {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let key = var("HIREME_API_KEY").ok_or("HIREME_API_KEY is not set")?;
        let mode = match var("HIREME_TRANSPORT").as_deref() {
            None | Some("auto") => Mode::Auto,
            Some("wt") => Mode::Wt,
            Some("ws") => Mode::Ws,
            Some(other) => return Err(format!("HIREME_TRANSPORT={other}: use auto, wt or ws")),
        };
        let cfg = Config {
            key,
            wt_url: var("HIREME_WT_URL"),
            wt_cert: var("HIREME_WT_CERT_SHA256"),
            wt_cert_file: var("HIREME_WT_CERT_SHA256_FILE"),
            ws_url: var("HIREME_WS_URL").map(|u| u.trim_end_matches('/').to_string()),
            mode,
        };
        if cfg.wt_url.is_none() && cfg.ws_url.is_none() {
            return Err("set HIREME_WT_URL, HIREME_WS_URL, or both".into());
        }
        Ok(cfg)
    }
}

/// A connected carrier. `alive` drops to false when the session ends;
/// every lease on it is gone with it.
pub enum Carrier {
    Wt {
        conn: Connection,
        alive: Arc<AtomicBool>,
    },
    Ws {
        cfg: Config,
    },
}

impl Carrier {
    pub fn alive(&self) -> bool {
        match self {
            Carrier::Wt { alive, .. } => alive.load(Ordering::Relaxed),
            Carrier::Ws { .. } => true,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Carrier::Wt { .. } => "webtransport",
            Carrier::Ws { .. } => "websocket",
        }
    }

    /// Connects the way the config allows. In auto mode WebTransport is
    /// tried first and WebSocket is the fallback when QUIC cannot get
    /// through. A server that answered and refused (a bad key, or a wire
    /// schema this build does not speak) is not retried another way: the
    /// refusal, with what to do about it, is the answer.
    pub async fn connect(
        cfg: &Config,
        control: ControlSink,
        on_close: impl FnOnce() + Send + 'static,
    ) -> Result<Carrier, String> {
        let wt = cfg.mode != Mode::Ws && cfg.wt_url.is_some();
        if wt {
            let tried =
                tokio::time::timeout(Duration::from_secs(5), wt_connect(cfg, control, on_close))
                    .await;
            match tried {
                Ok(Ok(c)) => return Ok(c),
                Ok(Err(e))
                    if cfg.mode == Mode::Wt
                        || cfg.ws_url.is_none()
                        || e.starts_with("hello refused") =>
                {
                    return Err(e);
                }
                Err(_) if cfg.mode == Mode::Wt || cfg.ws_url.is_none() => {
                    return Err("webtransport: no answer in 5 s (UDP blocked?)".into());
                }
                Ok(Err(e)) => eprintln!("hireme-mcp: {e}; falling back to websocket"),
                Err(_) => {
                    eprintln!("hireme-mcp: webtransport timed out; falling back to websocket")
                }
            }
        }
        Ok(Carrier::Ws { cfg: cfg.clone() })
    }

    /// Opens one lane: `0` is the read-only directory, any other id a
    /// lease. The first value down is always `notifications/lease`,
    /// with the lease's ids or an `error`.
    pub async fn open(&self, letterbox_id: u64) -> Result<(Up, Down), String> {
        match self {
            Carrier::Wt { conn, .. } => wt_lane(conn, letterbox_id).await,
            Carrier::Ws { cfg } => ws_lane(cfg, letterbox_id).await,
        }
    }
}

// ---------------------------------------------------------------------------
// WebTransport

async fn wt_connect(
    cfg: &Config,
    control: ControlSink,
    on_close: impl FnOnce() + Send + 'static,
) -> Result<Carrier, String> {
    let url = cfg.wt_url.clone().ok_or("no HIREME_WT_URL")?;
    let pinned = match (&cfg.wt_cert, &cfg.wt_cert_file) {
        (Some(hex), _) => Some(hex.trim().to_string()),
        (None, Some(path)) => Some(
            std::fs::read_to_string(path)
                .map_err(|e| format!("{path}: {e}"))?
                .trim()
                .to_string(),
        ),
        _ => None,
    };
    let builder = ClientConfig::builder().with_bind_default();
    let config = match pinned {
        Some(hex) => {
            let digest = sha256_hex(&hex).ok_or("certificate hash: want 64 hex digits")?;
            builder.with_server_certificate_hashes([digest]).build()
        }
        None => builder.with_native_certs().build(),
    };
    let endpoint = Endpoint::client(config).map_err(|e| format!("webtransport endpoint: {e}"))?;
    let conn = endpoint
        .connect(&url)
        .await
        .map_err(|e| format!("webtransport connect: {e}"))?;

    let (mut send, mut recv) = conn
        .open_bi()
        .await
        .map_err(|e| format!("control stream: {e}"))?
        .await
        .map_err(|e| format!("control stream: {e}"))?;
    send.write_all(&hello(&cfg.key))
        .await
        .map_err(|e| format!("hello: {e}"))?;

    // The BOOT flagged END is the session's "ready". BYE is a refusal.
    let mut buf = Vec::with_capacity(64 * 1024);
    loop {
        if !matches!(read_some(&mut recv, &mut buf).await, Ok(n) if n > 0) {
            return Err(refused(&conn, None).await);
        }
        let mut ready = false;
        let mut bye = None;
        let used = each_frame(&buf, |f| {
            if f.header.kind == frame::BYE {
                bye = Some(bye_reason(f.body));
                return false;
            }
            control(f);
            if f.header.kind == frame::BOOT && f.header.flags & wire::END != 0 {
                ready = true;
            }
            true
        })
        .map_err(|e| format!("control frame: {e:?}"))?;
        buf.drain(..used.0);
        if used.1 {
            return Err(refused(&conn, bye).await);
        }
        if ready {
            break;
        }
    }

    let alive = Arc::new(AtomicBool::new(true));
    let flag = alive.clone();
    let watched = conn.clone();
    tokio::spawn(async move {
        // The control stream stays open for PATCHes until the session ends.
        let _keep = send;
        loop {
            match read_some(&mut recv, &mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(_) => match each_frame(&buf, |f| {
                    control(f);
                    f.header.kind != frame::BYE
                }) {
                    Ok((used, bye)) => {
                        buf.drain(..used);
                        if bye {
                            break;
                        }
                    }
                    Err(_) => break,
                },
            }
        }
        flag.store(false, Ordering::Relaxed);
        watched.close(0u32.into(), b"");
        on_close();
    });
    Ok(Carrier::Wt { conn, alive })
}

async fn wt_lane(conn: &Connection, letterbox_id: u64) -> Result<(Up, Down), String> {
    let (mut send, mut recv) = conn
        .open_bi()
        .await
        .map_err(|e| format!("open stream: {e}"))?
        .await
        .map_err(|e| format!("open stream: {e}"))?;
    let mut w = wire::Writer::new();
    w.begin(frame::LEASE, 0, 0);
    w.raw(&letterbox_id.to_le_bytes());
    w.end();
    send.write_all(&w.buf)
        .await
        .map_err(|e| format!("lease: {e}"))?;

    let (up_tx, mut up_rx) = mpsc::unbounded_channel::<Value>();
    let (down_tx, down_rx) = mpsc::unbounded_channel::<Value>();

    tokio::spawn(async move {
        while let Some(v) = up_rx.recv().await {
            if send.write_all(&rpc_frame(&v)).await.is_err() {
                return;
            }
        }
        // Every sender is gone: the lease is released by closing the stream.
        let _ = send.finish().await;
    });

    tokio::spawn(async move {
        let mut buf = Vec::with_capacity(16 * 1024);
        while let Ok(n) = read_some(&mut recv, &mut buf).await {
            if n == 0 {
                break;
            }
            let mut msgs = Vec::new();
            match each_frame(&buf, |f| {
                if f.header.kind == frame::RPC
                    && let Some(v) = rpc_value(f.body)
                {
                    msgs.push(v);
                }
                true
            }) {
                Ok((used, _)) => {
                    buf.drain(..used);
                }
                Err(_) => break,
            }
            for v in msgs {
                if down_tx.send(v).is_err() {
                    return;
                }
            }
        }
    });

    Ok((up_tx, down_rx))
}

/// Why the session refused the HELLO: the BYE's reason when it arrived,
/// else the connection's close reason, which races the BYE.
async fn refused(conn: &Connection, bye: Option<String>) -> String {
    let reason = match bye {
        Some(r) => r,
        None => match tokio::time::timeout(Duration::from_millis(500), conn.closed()).await {
            Ok(wtransport::error::ConnectionError::ApplicationClosed(c)) => {
                String::from_utf8_lossy(c.reason()).into_owned()
            }
            Ok(e) => e.to_string(),
            Err(_) => "control stream closed".into(),
        },
    };
    let hint = match reason.as_str() {
        "schema" | "hello" => format!(
            ": this hireme-mcp speaks wire schema {:04x}, and the server runs another. \
             Rebuild it from the server's commit: \
             cargo build --release --manifest-path native/mcp/Cargo.toml",
            wire::schema::HASH
        ),
        "key" => ": the API key was refused (revoked, expired, or rate limited)".into(),
        _ => String::new(),
    };
    format!("hello refused ({reason}){hint}")
}

/// A BYE body: `u16 len | utf8 reason`.
fn bye_reason(body: &[u8]) -> String {
    let n = body
        .get(0..2)
        .map_or(0, |b| u16::from_le_bytes([b[0], b[1]]) as usize);
    String::from_utf8_lossy(body.get(2..2 + n).unwrap_or_default()).into_owned()
}

/// A certificate hash as the gate writes it: 64 hex digits, colons allowed.
fn sha256_hex(s: &str) -> Option<Sha256Digest> {
    let digits: Vec<u8> = s.bytes().filter(|&b| b != b':').collect();
    if digits.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, pair) in digits.chunks(2).enumerate() {
        out[i] = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
    }
    Some(Sha256Digest::new(out))
}

/// The agent HELLO: `u16 cred_len | cred | pad8 | u64 snapshot_rev | u32 client_id | u32 0`.
fn hello(key: &str) -> Vec<u8> {
    let mut body = Vec::with_capacity(64);
    body.extend_from_slice(&(key.len() as u16).to_le_bytes());
    body.extend_from_slice(key.as_bytes());
    body.resize(wire::pad8(body.len()), 0);
    body.extend_from_slice(&0u64.to_le_bytes());
    body.extend_from_slice(&std::process::id().to_le_bytes());
    body.extend_from_slice(&0u32.to_le_bytes());
    let mut w = wire::Writer::new();
    w.begin(frame::HELLO, wire::AGENT, 0);
    w.raw(&body);
    w.end();
    w.buf
}

/// An RPC frame: `u32 json_len | u32 0 | json | pad`.
pub fn rpc_frame(v: &Value) -> Vec<u8> {
    let json = serde_json::to_vec(v).unwrap_or_default();
    let mut w = wire::Writer::new();
    w.begin(frame::RPC, 0, 0);
    w.raw(&(json.len() as u32).to_le_bytes());
    w.raw(&0u32.to_le_bytes());
    w.raw(&json);
    w.end();
    w.buf
}

pub fn rpc_value(body: &[u8]) -> Option<Value> {
    let n = u32::from_le_bytes(body.get(0..4)?.try_into().ok()?) as usize;
    serde_json::from_slice(body.get(8..8 + n)?).ok()
}

/// Calls `f` on every whole frame at the front of `buf` and returns the
/// bytes consumed, plus whether `f` asked to stop.
fn each_frame(
    buf: &[u8],
    mut f: impl FnMut(wire::Frame<'_>) -> bool,
) -> Result<(usize, bool), wire::Error> {
    let mut at = 0;
    while buf.len() - at >= wire::HEADER {
        let header = wire::Header::parse(&buf[at..])?;
        let len = header.len as usize;
        if buf.len() - at < len {
            break;
        }
        let fr = wire::Frame::parse(&buf[at..at + len])?;
        at += len;
        if !f(fr) {
            return Ok((at, true));
        }
    }
    Ok((at, false))
}

async fn read_some(recv: &mut wtransport::RecvStream, buf: &mut Vec<u8>) -> Result<usize, String> {
    let mut chunk = [0u8; 16 * 1024];
    match recv.read(&mut chunk).await {
        Ok(Some(n)) => {
            buf.extend_from_slice(&chunk[..n]);
            Ok(n)
        }
        Ok(None) => Ok(0),
        Err(e) => Err(e.to_string()),
    }
}

// ---------------------------------------------------------------------------
// WebSocket fallback

async fn ws_lane(cfg: &Config, letterbox_id: u64) -> Result<(Up, Down), String> {
    let base = cfg
        .ws_url
        .as_deref()
        .ok_or("no HIREME_WS_URL for the websocket fallback")?;
    let path = match letterbox_id {
        0 => "/mcp/websocket".to_string(),
        id => format!("/mcp/letterbox/{id}/websocket"),
    };
    let mut req = format!("{base}{path}")
        .into_client_request()
        .map_err(|e| e.to_string())?;
    req.headers_mut().insert(
        "x-api-key",
        HeaderValue::from_str(&cfg.key).map_err(|e| e.to_string())?,
    );

    let (down_tx, down_rx) = mpsc::unbounded_channel::<Value>();
    let ws = match tokio_tungstenite::connect_async(req).await {
        Ok((ws, _)) => ws,
        Err(e) => {
            // The socket refuses before upgrade; it does not say why.
            let reason = if letterbox_id == 0 {
                "refused"
            } else {
                "busy or not found"
            };
            eprintln!("hireme-mcp: websocket {path}: {e}");
            let _ = down_tx.send(lease_note(
                json!({"letterbox_id": letterbox_id, "error": reason}),
            ));
            let (up_tx, _) = mpsc::unbounded_channel();
            return Ok((up_tx, down_rx));
        }
    };
    let (mut sink, mut stream) = ws.split();
    let (up_tx, mut up_rx) = mpsc::unbounded_channel::<Value>();

    // A websocket lease does not announce its ids; read them off the application.
    if letterbox_id == 0 {
        let _ = down_tx.send(lease_note(json!({"letterbox_id": 0, "directory": true})));
    } else {
        let ask = json!({"jsonrpc": "2.0", "id": 0, "method": "tools/call",
                         "params": {"name": "get_application", "arguments": {}}});
        sink.send(Message::text(ask.to_string()))
            .await
            .map_err(|e| e.to_string())?;
        let mut params = json!({"letterbox_id": letterbox_id});
        while let Some(Ok(msg)) = stream.next().await {
            if let Message::Text(t) = msg {
                let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                if v.get("id") == Some(&json!(0)) {
                    if let Some(r) = v.get("result") {
                        for k in ["job_id", "variant_id", "employer_id", "lineage_id"] {
                            params[k] = r[k].clone();
                        }
                    }
                    break;
                }
            }
        }
        let _ = down_tx.send(lease_note(params));
    }

    tokio::spawn(async move {
        while let Some(v) = up_rx.recv().await {
            if sink.send(Message::text(v.to_string())).await.is_err() {
                return;
            }
        }
        let _ = sink.close().await;
    });
    tokio::spawn(async move {
        while let Some(Ok(msg)) = stream.next().await {
            if let Message::Text(t) = msg
                && let Ok(v) = serde_json::from_str::<Value>(&t)
                && down_tx.send(v).is_err()
            {
                return;
            }
        }
    });
    Ok((up_tx, down_rx))
}

fn lease_note(params: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "notifications/lease", "params": params})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rpc_frames_survive_any_chunking() {
        let msgs: Vec<Value> = (0..20)
            .map(|i| json!({"jsonrpc": "2.0", "id": i, "result": {"s": "é".repeat(i)}}))
            .collect();
        let bytes: Vec<u8> = msgs.iter().flat_map(rpc_frame).collect();
        assert_eq!(bytes.len() % 8, 0);
        for cut in [1usize, 7, 8, 13, 64, 1000] {
            let mut buf = Vec::new();
            let mut got = Vec::new();
            for chunk in bytes.chunks(cut) {
                buf.extend_from_slice(chunk);
                let (used, stop) = each_frame(&buf, |f| {
                    assert_eq!(f.header.kind, frame::RPC);
                    assert!(f.header.check().is_ok());
                    got.push(rpc_value(f.body).unwrap());
                    true
                })
                .unwrap();
                assert!(!stop);
                buf.drain(..used);
            }
            assert!(buf.is_empty());
            assert_eq!(got, msgs);
        }
    }

    #[test]
    fn hello_carries_the_key_as_an_agent_credential() {
        let key = "hm_abc.secret";
        let h = hello(key);
        let f = wire::Frame::parse(&h).unwrap();
        assert_eq!((f.header.kind, f.header.flags), (frame::HELLO, wire::AGENT));
        let n = u16::from_le_bytes([f.body[0], f.body[1]]) as usize;
        assert_eq!(&f.body[2..2 + n], key.as_bytes());
        let rev_at = wire::pad8(2 + n);
        assert_eq!(&f.body[rev_at..rev_at + 8], &0u64.to_le_bytes());
    }
}
