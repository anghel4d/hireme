//! The carrier to the node: a WebSocket to `/wire`. The session above sees
//! one inbox of whole frames and one outbox; dropping the [`Link`] ends the
//! connection and its tasks.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

/// The largest frame the node sends (a packed BOOT is far under it).
const MAX_FRAME: usize = 256 << 20;
/// A dial that hangs gives up; the next attempt follows the session's backoff.
const DIAL_WAIT: Duration = Duration::from_secs(8);

pub enum Inbound {
    /// One frame, in order with every other.
    Frame(Vec<u8>),
    Closed(String),
}

pub struct Link {
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

/// Dials the node's `/wire` socket at `wire`.
pub async fn connect(wire: &str) -> Result<Link, String> {
    match tokio::time::timeout(DIAL_WAIT, websocket(wire)).await {
        Ok(r) => r,
        Err(_) => Err(format!("no WebSocket within {} s", DIAL_WAIT.as_secs())),
    }
}

async fn websocket(wire: &str) -> Result<Link, String> {
    let request = wire.into_client_request().map_err(|e| format!("{wire}: {e}"))?;
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(MAX_FRAME);
    config.max_frame_size = Some(MAX_FRAME);
    let (ws, _) = tokio_tungstenite::connect_async_with_config(request, Some(config), true).await.map_err(|e| format!("{wire}: {e}"))?;
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
                    if tx.send(Inbound::Frame(b.into())).is_err() {
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
    Ok(Link { out, inbox, tasks: vec![writer, reader] })
}
