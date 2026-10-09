//! How hireme-mcp reaches hireme: one session, carried by WebTransport
//! or, where QUIC cannot get through, by the `/wire` WebSocket. Both
//! carry the same frames the browser's session does, in one ordered
//! channel (WebTransport's control stream, or the socket's binary
//! messages).
//!
//! The client sends an agent HELLO (flag AGENT, the API key as its
//! credential). The server answers with the account's raw tables, a BOOT
//! flagged END and the rest as PATCHes, then every delta. Leases ride
//! the same channel as lanes: a frame whose header `rev` is a lane
//! number ≥ 1 belongs to that lane's lease, and BYE on a lane ends it.
//! One key authentication per session, however many leases.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};
use wire::schema::frame;
use wtransport::{ClientConfig, Endpoint, tls::Sha256Digest};

/// Every whole frame the server sends, in order.
pub type Sink = Arc<dyn Fn(wire::Frame<'_>) + Send + Sync>;

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

/// A live session. Frames written here go out in order; `alive` drops
/// when the session ends, and every lease ends with it.
pub struct Link {
    pub name: &'static str,
    out: mpsc::UnboundedSender<Vec<u8>>,
    alive: Arc<AtomicBool>,
}

impl Link {
    pub fn alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }

    pub fn send(&self, frame: Vec<u8>) -> Result<(), String> {
        self.out
            .send(frame)
            .map_err(|_| "session closed".to_string())
    }
}

/// Connects the way the config allows. In auto mode WebTransport is
/// tried first and the WebSocket is the fallback when QUIC cannot get
/// through. A server that answered and refused (a bad key, or a wire
/// schema this build does not speak) is not retried another way: the
/// refusal, with what to do about it, is the answer.
pub async fn connect(
    cfg: &Config,
    sink: Sink,
    on_close: impl FnOnce() + Send + 'static,
) -> Result<Link, String> {
    if cfg.mode != Mode::Ws && cfg.wt_url.is_some() {
        let tried = tokio::time::timeout(Duration::from_secs(5), wt(cfg)).await;
        let fallback = cfg.mode == Mode::Auto && cfg.ws_url.is_some();
        match tried {
            Ok(Ok(pipe)) => return session(cfg, pipe, sink, on_close).await,
            Ok(Err(e)) if !fallback => return Err(e),
            Err(_) if !fallback => {
                return Err("webtransport: no answer in 5 s (UDP blocked?)".into());
            }
            Ok(Err(e)) => eprintln!("hireme-mcp: {e}; falling back to the websocket"),
            Err(_) => {
                eprintln!("hireme-mcp: webtransport timed out; falling back to the websocket")
            }
        }
    }
    session(cfg, ws(cfg).await?, sink, on_close).await
}

/// A carrier, opened: bytes out, chunks in, and why it ended.
struct Pipe {
    name: &'static str,
    out: mpsc::UnboundedSender<Vec<u8>>,
    chunks: mpsc::UnboundedReceiver<Vec<u8>>,
    ended: oneshot::Receiver<String>,
}

/// HELLO, then frames until the BOOT flagged END ("ready") or a refusal;
/// after that every frame goes to `sink` until the carrier closes.
async fn session(
    cfg: &Config,
    mut pipe: Pipe,
    sink: Sink,
    on_close: impl FnOnce() + Send + 'static,
) -> Result<Link, String> {
    pipe.out.send(hello(&cfg.key)).map_err(|_| refused(None))?;
    let mut buf = Vec::with_capacity(64 * 1024);
    loop {
        let Some(chunk) = pipe.chunks.recv().await else {
            return Err(refused(pipe.ended.await.ok()));
        };
        buf.extend_from_slice(&chunk);
        let mut ready = false;
        let mut bye = None;
        let used = each_frame(&buf, |f| {
            if f.header.kind == frame::BYE {
                bye = Some(bye_reason(f.body));
                return false;
            }
            sink(f);
            ready |= f.header.kind == frame::BOOT && f.header.flags & wire::END != 0;
            true
        })
        .map_err(|e| format!("frame from the server: {e:?}"))?;
        buf.drain(..used);
        if bye.is_some() {
            return Err(refused(bye));
        }
        if ready {
            break;
        }
    }

    let alive = Arc::new(AtomicBool::new(true));
    let flag = alive.clone();
    tokio::spawn(async move {
        while let Some(chunk) = pipe.chunks.recv().await {
            buf.extend_from_slice(&chunk);
            match each_frame(&buf, |f| {
                sink(f);
                true
            }) {
                Ok(used) => {
                    buf.drain(..used);
                }
                Err(_) => break,
            }
        }
        flag.store(false, Ordering::Relaxed);
        on_close();
    });
    Ok(Link {
        name: pipe.name,
        out: pipe.out,
        alive,
    })
}

// ---- WebTransport ---------------------------------------------------------

async fn wt(cfg: &Config) -> Result<Pipe, String> {
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
    let builder = match pinned {
        Some(hex) => {
            let digest = sha256_hex(&hex).ok_or("certificate hash: want 64 hex digits")?;
            builder.with_server_certificate_hashes([digest])
        }
        None => builder.with_native_certs(),
    };
    // UDP has no FIN: a client that dies is noticed only when it goes
    // quiet. A short idle timeout (the lower of the two peers' applies),
    // kept alive while healthy, gives a dead agent's block back in
    // seconds instead of the default half minute.
    let config = builder
        .keep_alive_interval(Some(Duration::from_millis(500)))
        .max_idle_timeout(Some(Duration::from_secs(2)))
        .map_err(|_| "idle timeout")?
        .build();
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

    let (out, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let (chunks_tx, chunks) = mpsc::unbounded_channel();
    let (ended_tx, ended) = oneshot::channel();
    tokio::spawn(async move {
        while let Some(bytes) = out_rx.recv().await {
            if send.write_all(&bytes).await.is_err() {
                break;
            }
        }
    });
    tokio::spawn(async move {
        let mut chunk = vec![0u8; 64 * 1024];
        while let Ok(Some(n)) = recv.read(&mut chunk).await {
            if chunks_tx.send(chunk[..n].to_vec()).is_err() {
                break;
            }
        }
        drop(chunks_tx);
        // The close reason races a BYE that went out just before it.
        let reason = match tokio::time::timeout(Duration::from_millis(500), conn.closed()).await {
            Ok(wtransport::error::ConnectionError::ApplicationClosed(c)) => {
                String::from_utf8_lossy(c.reason()).into_owned()
            }
            Ok(e) => e.to_string(),
            Err(_) => "closed".into(),
        };
        let _ = ended_tx.send(reason);
    });
    Ok(Pipe {
        name: "webtransport",
        out,
        chunks,
        ended,
    })
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

// ---- WebSocket ------------------------------------------------------------

async fn ws(cfg: &Config) -> Result<Pipe, String> {
    let base = cfg
        .ws_url
        .as_deref()
        .ok_or("no HIREME_WS_URL for the websocket")?;
    let req = format!("{base}/wire/websocket")
        .into_client_request()
        .map_err(|e| e.to_string())?;
    let (socket, _) = tokio_tungstenite::connect_async(req)
        .await
        .map_err(|e| format!("websocket: {e}"))?;
    let (mut sink, mut stream) = socket.split();
    let (out, mut out_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let (chunks_tx, chunks) = mpsc::unbounded_channel();
    let (ended_tx, ended) = oneshot::channel();
    tokio::spawn(async move {
        while let Some(bytes) = out_rx.recv().await {
            if sink.send(Message::binary(bytes)).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    tokio::spawn(async move {
        let mut reason = String::from("closed");
        while let Some(Ok(msg)) = stream.next().await {
            match msg {
                Message::Binary(b) => {
                    if chunks_tx.send(b.to_vec()).is_err() {
                        break;
                    }
                }
                Message::Close(Some(c)) => reason = c.reason.to_string(),
                _ => {}
            }
        }
        let _ = ended_tx.send(reason);
    });
    Ok(Pipe {
        name: "websocket",
        out,
        chunks,
        ended,
    })
}

// ---- Frames ---------------------------------------------------------------

/// Why the session refused the HELLO, with what to do about it.
fn refused(reason: Option<String>) -> String {
    let reason = reason.unwrap_or_else(|| "closed".into());
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
pub fn bye_reason(body: &[u8]) -> String {
    let n = body
        .get(0..2)
        .map_or(0, |b| u16::from_le_bytes([b[0], b[1]]) as usize);
    String::from_utf8_lossy(body.get(2..2 + n).unwrap_or_default()).into_owned()
}

/// The agent HELLO: `u16 cred_len | cred | pad8 | u64 snapshot_rev | u32 client_id | u32 opts`.
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

/// One frame of `kind` on `lane` around `body`.
pub fn frame(kind: u8, lane: u64, body: &[u8]) -> Vec<u8> {
    let mut w = wire::Writer::new();
    w.begin(kind, 0, lane);
    w.raw(body);
    w.end();
    w.buf
}

/// Calls `f` on every whole frame at the front of `buf` and returns the
/// bytes consumed; `f` answering false stops there.
fn each_frame(
    buf: &[u8],
    mut f: impl FnMut(wire::Frame<'_>) -> bool,
) -> Result<usize, wire::Error> {
    let mut at = 0;
    while buf.len() - at >= wire::HEADER {
        let len = wire::Header::parse(&buf[at..])?.len as usize;
        if buf.len() - at < len {
            break;
        }
        let fr = wire::Frame::parse(&buf[at..at + len])?;
        at += len;
        if !f(fr) {
            break;
        }
    }
    Ok(at)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_survive_any_chunking() {
        let frames: Vec<Vec<u8>> = (0..20u64)
            .map(|i| frame(frame::OP, i % 4, &vec![i as u8; i as usize * 3]))
            .collect();
        let bytes: Vec<u8> = frames.concat();
        for cut in [1usize, 7, 8, 13, 64, 1000] {
            let mut buf = Vec::new();
            let mut got = Vec::new();
            for chunk in bytes.chunks(cut) {
                buf.extend_from_slice(chunk);
                let used = each_frame(&buf, |f| {
                    assert!(f.header.check().is_ok());
                    got.push((f.header.rev, f.body.len()));
                    true
                })
                .unwrap();
                buf.drain(..used);
            }
            assert!(buf.is_empty());
            let want: Vec<_> = (0..20u64)
                .map(|i| (i % 4, wire::pad8(i as usize * 3)))
                .collect();
            assert_eq!(got, want);
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
