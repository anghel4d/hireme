//! A carrier to the node: WebTransport through the gate, or a WebSocket to
//! `/wire`. Either way the session above sees one inbox of whole frames and
//! one outbox; dropping the [`Link`] ends the connection and its tasks.
//!
//! WebTransport is the gate's: a control stream the client opens, carrying
//! every frame both ways in order, plus server uni streams that each carry
//! one whole payload (the BOOT). Those race the control stream, so the
//! inbox says which stream a frame came on and the session orders the train
//! (`upstream.rs`), as the browser's wire does.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

/// The largest frame the node sends (a packed BOOT is far under it).
const MAX_FRAME: usize = 256 << 20;
/// A dial that hangs (UDP dropped on the way, a dead gate) gives up and lets the other carrier try.
const DIAL_WAIT: Duration = Duration::from_secs(8);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Carrier {
    WebTransport,
    WebSocket,
}

impl Carrier {
    pub fn name(self) -> &'static str {
        match self {
            Carrier::WebTransport => "webtransport",
            Carrier::WebSocket => "websocket",
        }
    }
}

/// Which carrier to dial: WebTransport first and the socket if it fails (the browser's order), or one only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Prefer {
    Auto,
    WebTransport,
    WebSocket,
}

/// Where the node is: its `/wire` socket URL, and its gate's URL when it runs one.
#[derive(Clone, Debug)]
pub struct Dial {
    pub wire: String,
    pub gate: Option<String>,
    /// SHA-256 of a self-signed gate's certificate (a dev node); empty trusts the system's roots.
    pub cert_hashes: Vec<[u8; 32]>,
    pub prefer: Prefer,
}

pub enum Inbound {
    /// A frame off the control stream (or the socket): in order with every other one there.
    Control(Vec<u8>),
    /// A frame off one of the gate's uni streams: whole, but racing the control stream.
    Bulk(Vec<u8>),
    Closed(String),
}

pub struct Link {
    pub carrier: Carrier,
    pub out: mpsc::UnboundedSender<Vec<u8>>,
    pub inbox: mpsc::UnboundedReceiver<Inbound>,
    tasks: Vec<JoinHandle<()>>,
}

impl Drop for Link {
    fn drop(&mut self) {
        for t in &self.tasks {
            t.abort();
        }
    }
}

/// Dials the node as `d` prefers. `wt_broken` (WebTransport failed before in this process) goes straight to the socket.
pub async fn connect(d: &Dial, wt_broken: bool) -> Result<Link, String> {
    let try_wt = d.gate.is_some() && d.prefer != Prefer::WebSocket && !(wt_broken && d.prefer == Prefer::Auto);
    if try_wt {
        match tokio::time::timeout(DIAL_WAIT, webtransport(d)).await {
            Ok(Ok(link)) => return Ok(link),
            Ok(Err(e)) if d.prefer == Prefer::WebTransport => return Err(e),
            Err(_) if d.prefer == Prefer::WebTransport => return Err(format!("no WebTransport session within {} s", DIAL_WAIT.as_secs())),
            _ => {}
        }
    }
    match tokio::time::timeout(DIAL_WAIT, websocket(d)).await {
        Ok(r) => r,
        Err(_) => Err(format!("no WebSocket within {} s", DIAL_WAIT.as_secs())),
    }
}

async fn webtransport(d: &Dial) -> Result<Link, String> {
    let gate = d.gate.as_deref().ok_or("no gate")?;
    let config = wtransport::ClientConfig::builder().with_bind_default();
    let config = if d.cert_hashes.is_empty() {
        config.with_native_certs()
    } else {
        config.with_server_certificate_hashes(d.cert_hashes.iter().map(|h| wtransport::tls::Sha256Digest::new(*h)))
    };
    // QUIC keeps the path warm under the wire's own 15 s PING.
    let config = config.keep_alive_interval(Some(Duration::from_secs(10))).build();
    let endpoint = wtransport::Endpoint::client(config).map_err(|e| format!("gate: {e}"))?;
    let connection = endpoint.connect(gate).await.map_err(|e| format!("gate {gate}: {e}"))?;
    let (mut send, mut recv) = connection.open_bi().await.map_err(|e| format!("gate: {e}"))?.await.map_err(|e| format!("gate: {e}"))?;
    let (out, mut outq) = mpsc::unbounded_channel::<Vec<u8>>();
    let (tx, inbox) = mpsc::unbounded_channel();
    let writer = tokio::spawn(async move {
        while let Some(f) = outq.recv().await {
            if send.write_all(&f).await.is_err() {
                break;
            }
        }
    });
    let control = {
        let tx = tx.clone();
        tokio::spawn(async move {
            let mut buf = Vec::with_capacity(64 << 10);
            let mut chunk = vec![0u8; 64 << 10];
            loop {
                match recv.read(&mut chunk).await {
                    Ok(Some(n)) => {
                        buf.extend_from_slice(&chunk[..n]);
                        if let Err(why) = drain(&mut buf, |f| tx.send(Inbound::Control(f)).is_ok()) {
                            let _ = tx.send(Inbound::Closed(why));
                            return;
                        }
                    }
                    Ok(None) => return drop(tx.send(Inbound::Closed("the gate closed the control stream".into()))),
                    Err(e) => return drop(tx.send(Inbound::Closed(format!("control stream: {e}")))),
                }
            }
        })
    };
    let bulk = {
        let tx = tx.clone();
        let connection = connection.clone();
        tokio::spawn(async move {
            while let Ok(mut uni) = connection.accept_uni().await {
                let tx = tx.clone();
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let mut chunk = vec![0u8; 256 << 10];
                    while let Ok(Some(n)) = uni.read(&mut chunk).await {
                        if buf.len() + n > MAX_FRAME {
                            let _ = tx.send(Inbound::Closed("a bulk stream over the frame limit".into()));
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                    }
                    if let Err(why) = drain(&mut buf, |f| tx.send(Inbound::Bulk(f)).is_ok()) {
                        let _ = tx.send(Inbound::Closed(why));
                    } else if !buf.is_empty() {
                        let _ = tx.send(Inbound::Closed("a bulk stream ended mid-frame".into()));
                    }
                });
            }
        })
    };
    let closed = tokio::spawn(async move {
        let e = connection.closed().await;
        let _ = tx.send(Inbound::Closed(format!("the gate closed the session: {e}")));
        drop(endpoint);
    });
    Ok(Link { carrier: Carrier::WebTransport, out, inbox, tasks: vec![writer, control, bulk, closed] })
}

async fn websocket(d: &Dial) -> Result<Link, String> {
    let request = d.wire.as_str().into_client_request().map_err(|e| format!("{}: {e}", d.wire))?;
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_FRAME);
    config.max_frame_size = Some(MAX_FRAME);
    let (ws, _) = tokio_tungstenite::connect_async_with_config(request, Some(config), true).await.map_err(|e| format!("{}: {e}", d.wire))?;
    let (mut sink, mut stream) = ws.split();
    let (out, mut outq) = mpsc::unbounded_channel::<Vec<u8>>();
    let (tx, inbox) = mpsc::unbounded_channel();
    let writer = tokio::spawn(async move {
        while let Some(f) = outq.recv().await {
            if sink.send(Message::binary(f)).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let reader = tokio::spawn(async move {
        // One WebSocket message is one frame.
        let why = loop {
            match stream.next().await {
                Some(Ok(Message::Binary(b))) => {
                    if tx.send(Inbound::Control(b.into())).is_err() {
                        return;
                    }
                }
                Some(Ok(Message::Close(c))) => break c.map(|c| c.reason.to_string()).unwrap_or_else(|| "the node closed the socket".into()),
                Some(Ok(_)) => {}
                Some(Err(e)) => break format!("socket: {e}"),
                None => break "the socket closed".into(),
            }
        };
        let _ = tx.send(Inbound::Closed(why));
    });
    Ok(Link { carrier: Carrier::WebSocket, out, inbox, tasks: vec![writer, reader] })
}

/// Hands every whole frame at the front of `buf` to `each` and keeps the rest; a byte stream that is not frames is an error.
fn drain(buf: &mut Vec<u8>, mut each: impl FnMut(Vec<u8>) -> bool) -> Result<(), String> {
    let mut at = 0;
    while let Some((_, frame, _)) = wire::split(&buf[at..], MAX_FRAME).map_err(|e| format!("the stream is not frames: {e}"))? {
        let n = frame.len();
        if !each(frame.to_vec()) {
            break;
        }
        at += n;
    }
    buf.drain(..at);
    Ok(())
}
