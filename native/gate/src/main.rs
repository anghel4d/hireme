//! hireme-gate: the WebTransport front door.
//!
//! It terminates QUIC and HTTP/3 and holds no business logic. Each
//! WebTransport session becomes one connection to the BEAM's Unix socket,
//! and its control stream's bytes cross that socket as `{packet,4}`
//! messages; authentication, the frames and everything after them are the
//! BEAM's (`HiremeWeb.Gate` holds the bridge protocol, and this file is its
//! gate half).
//!
//! A wire session needs one client bidirectional stream (the control
//! stream, which carries every frame in order) and server unidirectional
//! streams for bulk (the BOOT). The gate admits nothing else: no other
//! client stream and no datagrams.
//!
//! Nothing is allocated for a peer before it passes the cheap checks:
//! - QUIC Retry (stateless address validation) while handshakes pile up,
//!   and always for an address at its cap;
//! - a per-IP cap on live sessions;
//! - a path prefix and an `Origin` allow-list (no Origin is a native agent,
//!   forwarded as "", and the BEAM then insists on an API key);
//! - the BEAM must ACCEPT within 2 s and declare READY (HELLO verified)
//!   within 2 s after that, or the session closes;
//! - until READY, a 64 KiB connection receive window.
//!
//! The BEAM runs the gate as a Port and talks to it on stdin, one command
//! per line: `reload` rereads the certificate (also reread whenever the PEM
//! files change, so an ACME renewal needs no restart) and `stats` prints the
//! counters. When stdin closes the BEAM is gone, and the gate stops.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{Notify, mpsc};
use tokio::time::{sleep, timeout};
use wtransport::endpoint::{IncomingSession, SessionRequest};
use wtransport::quinn::congestion::CubicConfig;
use wtransport::quinn::{TransportConfig, VarInt as QVarInt};
use wtransport::{Connection, Endpoint, Identity, RecvStream, SendStream, ServerConfig, VarInt};

// Bridge opcodes; see HiremeWeb.Gate.
const OPEN: u8 = 0x01;
const ACCEPT: u8 = 0x02;
const REFUSE: u8 = 0x03;
const READY: u8 = 0x04;
const DATA: u8 = 0x11;
const UNI: u8 = 0x15;
const CLOSE: u8 = 0x30;

/// The longest bridge message accepted from the BEAM.
const MAX_MESSAGE: usize = 16 << 20;
/// Bytes queued towards QUIC per session before the gate gives up on a
/// peer that does not read.
const MAX_QUEUED: usize = 32 << 20;
/// Control bytes the BEAM may queue before the client opens its stream.
const HELD_MAX: usize = 4 << 20;
const DEADLINE: Duration = Duration::from_secs(2);
/// QUIC handshake plus the CONNECT. A lossy path spends seconds in probe
/// timeouts (333 ms, doubling), and a browser given no answer waits for
/// good, so this bound is generous.
const HANDSHAKE: Duration = Duration::from_secs(10);
/// HTTP/3 takes one bidi stream (the CONNECT) and three uni streams
/// (control, QPACK encoder and decoder); the session adds its own one.
const BIDI: u32 = 2;
const UNI_IN: u32 = 3;
/// Bulk yields to the control stream.
const BULK_PRIORITY: i32 = -1;
/// Handshakes in flight above which every unvalidated address gets a Retry.
const RETRY_ABOVE: usize = 32;
const WINDOW_BEFORE: u32 = 64 << 10;
const WINDOW_AFTER: u32 = 16 << 20;
const STREAM_WINDOW: u32 = 4 << 20;
/// Congestion window before the first loss or ACK. quinn's default, ten
/// packets, keeps a cold BOOT in slow start for several round trips; the
/// window is paced over the measured RTT, so it never leaves as one burst.
const INITIAL_WINDOW: usize = 1 << 20;

/// Close codes the gate itself uses (the BEAM picks its own).
const CODE_DEADLINE: u32 = 0x4001;
const CODE_OVERFLOW: u32 = 0x4002;
const CODE_BRIDGE: u32 = 0x4003;
const CODE_PROTOCOL: u32 = 0x4004;

struct Settings {
    listen: SocketAddr,
    socket: PathBuf,
    cert: Option<(PathBuf, PathBuf)>,
    hash_file: Option<PathBuf>,
    origins: Vec<String>,
    path: String,
    per_ip: usize,
    initial_window: u64,
}

impl Settings {
    fn from_env() -> Result<Self, String> {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let num = |k: &str, d: usize| -> Result<usize, String> {
            var(k).map_or(Ok(d), |v| v.parse().map_err(|_| format!("{k}: not a number")))
        };
        let listen = var("GATE_LISTEN")
            .unwrap_or_else(|| "127.0.0.1:4433".into())
            .parse()
            .map_err(|_| "GATE_LISTEN: want ip:port".to_string())?;
        let cert = match (var("GATE_CERT"), var("GATE_KEY")) {
            (Some(c), Some(k)) => Some((c.into(), k.into())),
            (None, None) => None,
            _ => return Err("GATE_CERT and GATE_KEY go together".into()),
        };
        Ok(Settings {
            listen,
            socket: var("GATE_SOCKET").ok_or("GATE_SOCKET: the BEAM's Unix socket")?.into(),
            cert,
            hash_file: var("GATE_CERT_HASH_FILE").map(Into::into),
            origins: var("GATE_ORIGINS")
                .unwrap_or_default()
                .split(',')
                .map(|o| o.trim().trim_end_matches('/').to_string())
                .filter(|o| !o.is_empty())
                .collect(),
            path: var("GATE_PATH").unwrap_or_else(|| "/wt".into()),
            per_ip: num("GATE_PER_IP", 16)?,
            initial_window: num("GATE_INITIAL_WINDOW", INITIAL_WINDOW)? as u64,
        })
    }
}

/// In-memory counters, printed on `stats` and never written anywhere.
#[derive(Default)]
struct Counters {
    incoming: AtomicU64,
    retried: AtomicU64,
    refused_ip: AtomicU64,
    refused_origin: AtomicU64,
    refused_beam: AtomicU64,
    accepted: AtomicU64,
    ready: AtomicU64,
    deadline: AtomicU64,
    overflow: AtomicU64,
    bytes_in: AtomicU64,
    bytes_out: AtomicU64,
}

struct Gate {
    settings: Settings,
    handshakes: AtomicUsize,
    per_ip: Mutex<HashMap<IpAddr, usize>>,
    counters: Counters,
}

/// One live session's claim on its address's slot, released on drop.
struct IpSlot(Arc<Gate>, IpAddr);

impl Drop for IpSlot {
    fn drop(&mut self) {
        let mut map = self.0.per_ip.lock().unwrap();
        if let Some(n) = map.get_mut(&self.1) {
            *n -= 1;
            if *n == 0 {
                map.remove(&self.1);
            }
        }
    }
}

impl Gate {
    fn claim(self: &Arc<Self>, ip: IpAddr) -> Option<IpSlot> {
        let mut map = self.per_ip.lock().unwrap();
        let n = map.entry(ip).or_insert(0);
        if *n >= self.settings.per_ip {
            return None;
        }
        *n += 1;
        Some(IpSlot(self.clone(), ip))
    }

    fn at_cap(&self, ip: IpAddr) -> bool {
        self.per_ip.lock().unwrap().get(&ip).is_some_and(|n| *n >= self.settings.per_ip)
    }

    fn origin_ok(&self, origin: Option<&str>) -> bool {
        match origin {
            None => true,
            Some(o) => self.settings.origins.iter().any(|a| a == o.trim_end_matches('/')),
        }
    }
}

fn transport(s: &Settings) -> TransportConfig {
    let mut t = TransportConfig::default();
    let mut cubic = CubicConfig::default();
    cubic.initial_window(s.initial_window);
    t.congestion_controller_factory(Arc::new(cubic));
    // The connection window is the pre-auth cap and rises at READY; a
    // stream window cannot change later, so it is sized for the session.
    t.max_concurrent_bidi_streams(QVarInt::from_u32(BIDI))
        .max_concurrent_uni_streams(QVarInt::from_u32(UNI_IN))
        .receive_window(QVarInt::from_u32(WINDOW_BEFORE))
        .stream_receive_window(QVarInt::from_u32(STREAM_WINDOW))
        .max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()))
        .keep_alive_interval(Some(Duration::from_secs(10)));
    t
}

async fn identity(s: &Settings) -> Result<Identity, String> {
    let id = match &s.cert {
        Some((c, k)) => Identity::load_pemfiles(c, k).await.map_err(|e| format!("certificate: {e}"))?,
        // ECDSA P-256, valid 14 days: what `serverCertificateHashes` allows.
        None => Identity::self_signed(["localhost", "127.0.0.1", "::1"]).map_err(|e| e.to_string())?,
    };
    if let Some(path) = &s.hash_file {
        // The hash a page passes as `serverCertificateHashes`, written
        // whole (rename) for the BEAM to read.
        let hex: String = id.certificate_chain().as_slice()[0]
            .hash()
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, hex + "\n")
            .and_then(|_| std::fs::rename(&tmp, path))
            .map_err(|e| format!("hash file: {e}"))?;
    }
    Ok(id)
}

async fn server_config(s: &Settings) -> Result<ServerConfig, String> {
    let mut config = ServerConfig::builder()
        .with_bind_address(s.listen)
        .with_custom_transport(identity(s).await?, transport(s))
        .build();
    config.quic_config_mut().retry_token_lifetime(Duration::from_secs(15));
    Ok(config)
}

fn cert_stamp(s: &Settings) -> Option<(SystemTime, SystemTime)> {
    let (c, k) = s.cert.as_ref()?;
    let m = |p: &PathBuf| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    Some((m(c)?, m(k)?))
}

// One thread: a frame crosses several tasks between the Unix socket and the
// UDP socket, and on a work-stealing pool most of those wakes cost a futex
// on another core. The gate's work is I/O, which one core carries.
#[tokio::main(flavor = "current_thread")]
async fn main() {
    let settings = match Settings::from_env() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("hireme-gate: {e}");
            std::process::exit(2);
        }
    };
    let config = match server_config(&settings).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("hireme-gate: {e}");
            std::process::exit(1);
        }
    };
    let endpoint = match Endpoint::server(config) {
        Ok(e) => Arc::new(e),
        Err(e) => {
            eprintln!("hireme-gate: bind {}: {e}", settings.listen);
            std::process::exit(1);
        }
    };
    let gate = Arc::new(Gate {
        settings,
        handshakes: AtomicUsize::new(0),
        per_ip: Mutex::new(HashMap::new()),
        counters: Counters::default(),
    });
    let reload_now = Arc::new(Notify::new());
    tokio::spawn(reload(gate.clone(), endpoint.clone(), reload_now.clone()));

    let mut commands = BufReader::new(tokio::io::stdin()).lines();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => admit(&gate, incoming),
            line = commands.next_line() => match line.ok().flatten().as_deref() {
                None => break,
                Some("reload") => reload_now.notify_one(),
                Some("stats") => stats(&gate),
                Some(other) => eprintln!("hireme-gate: unknown command {other:?}"),
            },
        }
    }
    endpoint.close(VarInt::from_u32(0), b"shutdown");
    let _ = timeout(Duration::from_secs(2), endpoint.wait_idle()).await;
}

/// Decides, from the first packet alone, whether a handshake may begin.
fn admit(gate: &Arc<Gate>, incoming: IncomingSession) {
    let c = &gate.counters;
    c.incoming.fetch_add(1, Relaxed);
    let ip = incoming.remote_address().ip();
    if !incoming.remote_address_validated() && (gate.handshakes.load(Relaxed) >= RETRY_ABOVE || gate.at_cap(ip)) {
        c.retried.fetch_add(1, Relaxed);
        incoming.retry();
        return;
    }
    let Some(slot) = gate.claim(ip) else {
        c.refused_ip.fetch_add(1, Relaxed);
        incoming.refuse();
        return;
    };
    gate.handshakes.fetch_add(1, Relaxed);
    let gate = gate.clone();
    tokio::spawn(async move {
        let request = timeout(HANDSHAKE, incoming).await;
        gate.handshakes.fetch_sub(1, Relaxed);
        if let Ok(Ok(request)) = request {
            session(gate, request, slot).await;
        }
    });
}

async fn reload(gate: Arc<Gate>, endpoint: Arc<Endpoint<wtransport::endpoint::endpoint_side::Server>>, now: Arc<Notify>) {
    let mut stamp = cert_stamp(&gate.settings);
    loop {
        tokio::select! {
            _ = now.notified() => {}
            _ = sleep(Duration::from_secs(300)) => {
                if cert_stamp(&gate.settings) == stamp { continue; }
            }
        }
        // A renewal may still be writing the pair.
        sleep(Duration::from_secs(1)).await;
        stamp = cert_stamp(&gate.settings);
        match server_config(&gate.settings).await {
            Ok(config) => {
                if let Err(e) = endpoint.reload_config(config, false) {
                    eprintln!("hireme-gate: reload: {e}");
                }
            }
            Err(e) => eprintln!("hireme-gate: reload kept the old certificate: {e}"),
        }
    }
}

fn stats(gate: &Gate) {
    let c = &gate.counters;
    eprintln!(
        "hireme-gate: incoming={} retried={} refused_ip={} refused_origin={} refused_beam={} accepted={} ready={} deadline={} overflow={} bytes_in={} bytes_out={} handshakes={} ips={}",
        c.incoming.load(Relaxed),
        c.retried.load(Relaxed),
        c.refused_ip.load(Relaxed),
        c.refused_origin.load(Relaxed),
        c.refused_beam.load(Relaxed),
        c.accepted.load(Relaxed),
        c.ready.load(Relaxed),
        c.deadline.load(Relaxed),
        c.overflow.load(Relaxed),
        c.bytes_in.load(Relaxed),
        c.bytes_out.load(Relaxed),
        gate.handshakes.load(Relaxed),
        gate.per_ip.lock().unwrap().len(),
    );
}

// ---------------------------------------------------------------- bridge

fn message(op: u8, body: &[u8]) -> Vec<u8> {
    let len = 1 + body.len();
    let mut m = Vec::with_capacity(4 + len);
    m.extend_from_slice(&(len as u32).to_be_bytes());
    m.push(op);
    m.extend_from_slice(body);
    m
}

async fn read_message(r: &mut OwnedReadHalf) -> Option<Vec<u8>> {
    let len = r.read_u32().await.ok()? as usize;
    if len == 0 || len > MAX_MESSAGE {
        return None;
    }
    let mut buf = vec![0; len];
    r.read_exact(&mut buf).await.ok()?;
    Some(buf)
}

/// Writes queued messages to the BEAM, flushing once the queue is empty,
/// so a burst of small DATA messages costs one syscall.
async fn bridge_writer(w: OwnedWriteHalf, mut rx: mpsc::UnboundedReceiver<Vec<u8>>) {
    let mut w = BufWriter::with_capacity(64 << 10, w);
    while let Some(m) = rx.recv().await {
        if w.write_all(&m).await.is_err() {
            return;
        }
        while let Ok(m) = rx.try_recv() {
            if w.write_all(&m).await.is_err() {
                return;
            }
        }
        if w.flush().await.is_err() {
            return;
        }
    }
}

fn open_body(ip: &str, origin: &str, path: &str) -> Vec<u8> {
    let mut b = Vec::with_capacity(5 + ip.len() + origin.len() + path.len());
    b.push(ip.len() as u8);
    b.extend_from_slice(ip.as_bytes());
    for field in [origin, path] {
        let f = &field.as_bytes()[..field.len().min(u16::MAX as usize)];
        b.extend_from_slice(&(f.len() as u16).to_be_bytes());
        b.extend_from_slice(f);
    }
    b
}

// --------------------------------------------------------------- session

struct Shared {
    up: mpsc::UnboundedSender<Vec<u8>>,
    queued: AtomicUsize,
    ready: AtomicBool,
    gate: Arc<Gate>,
}

async fn session(gate: Arc<Gate>, request: SessionRequest, _slot: IpSlot) {
    let c = &gate.counters;
    if !request.path().starts_with(gate.settings.path.as_str()) {
        request.not_found().await;
        return;
    }
    if !gate.origin_ok(request.origin()) {
        c.refused_origin.fetch_add(1, Relaxed);
        request.forbidden().await;
        return;
    }
    let Ok(Ok(unix)) = timeout(DEADLINE, UnixStream::connect(&gate.settings.socket)).await else {
        eprintln!("hireme-gate: the BEAM socket {} is not answering", gate.settings.socket.display());
        let _ = request.too_many_requests().await;
        return;
    };
    let (mut down, w) = unix.into_split();
    let (up, rx) = mpsc::unbounded_channel();
    tokio::spawn(bridge_writer(w, rx));

    let ip = request.remote_address().ip().to_string();
    let _ = up.send(message(OPEN, &open_body(&ip, request.origin().unwrap_or(""), request.path())));

    // The BEAM may write ahead of its ACCEPT; those messages wait here and
    // are applied the moment the session exists.
    let answer = timeout(DEADLINE, async {
        let mut early = Vec::new();
        loop {
            match read_message(&mut down).await {
                Some(m) if m[0] != ACCEPT && m[0] != REFUSE => early.push(m),
                other => return (other, early),
            }
        }
    })
    .await;
    let early = match answer {
        Ok((Some(m), early)) if m[0] == ACCEPT => early,
        Ok((Some(m), _)) if m[0] == REFUSE => {
            c.refused_beam.fetch_add(1, Relaxed);
            match m.get(1..3).map(|s| u16::from_be_bytes([s[0], s[1]])) {
                Some(404) => request.not_found().await,
                Some(429) => request.too_many_requests().await,
                _ => request.forbidden().await,
            }
            return;
        }
        Ok(_) => return request.forbidden().await,
        Err(_) => {
            c.deadline.fetch_add(1, Relaxed);
            return request.too_many_requests().await;
        }
    };
    let Ok(conn) = request.accept().await else { return };
    c.accepted.fetch_add(1, Relaxed);
    let shared = Arc::new(Shared { up, queued: AtomicUsize::new(0), ready: false.into(), gate: gate.clone() });
    // A select! over a partial read would lose bytes, so the BEAM's half is
    // read by its own task and arrives here as whole messages.
    let (beam_tx, beam_rx) = mpsc::channel(64);
    let pump = tokio::spawn(async move {
        while let Some(m) = read_message(&mut down).await {
            if beam_tx.send(m).await.is_err() {
                break;
            }
        }
    });
    let code = run(&conn, &shared, early, beam_rx).await;
    pump.abort();
    if let Some((code, reason)) = code {
        conn.close(VarInt::from_u32(code), &reason);
    }
    let reason = conn.closed().await.to_string();
    let mut body = 0u32.to_be_bytes().to_vec();
    body.extend_from_slice(reason.as_bytes());
    let _ = shared.up.send(message(CLOSE, &body));
}

/// The session loop: answers the close code and reason when the gate or the
/// BEAM ends the session, or `None` when the peer did.
async fn run(
    conn: &Connection,
    sh: &Arc<Shared>,
    early: Vec<Vec<u8>>,
    mut down: mpsc::Receiver<Vec<u8>>,
) -> Option<(u32, Vec<u8>)> {
    // The control stream's queue exists from the start: the BEAM may write
    // to it before the client has opened it, and those bytes wait here, in
    // order, up to HELD_MAX.
    let (control_tx, control_rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let mut control_rx = Some(control_rx);
    let mut held = 0;
    for m in &early {
        if m[0] == DATA {
            held += m.len() - 1;
        }
        match beam(conn, sh, &control_tx, m) {
            Ok(None) => {}
            Ok(Some(close)) => return Some(close),
            Err(()) => return Some((CODE_PROTOCOL, b"bridge protocol".to_vec())),
        }
    }
    let deadline = sleep(DEADLINE);
    tokio::pin!(deadline);
    let c = &sh.gate.counters;
    loop {
        let ready = sh.ready.load(Relaxed);
        tokio::select! {
            biased;
            m = down.recv() => {
                let Some(m) = m else { return Some((CODE_BRIDGE, b"bridge closed".to_vec())) };
                if m[0] == DATA && control_rx.is_some() {
                    held += m.len() - 1;
                }
                match beam(conn, sh, &control_tx, &m) {
                    Ok(None) => {}
                    Ok(Some(close)) => return Some(close),
                    Err(()) => return Some((CODE_PROTOCOL, b"bridge protocol".to_vec())),
                }
            }
            _ = &mut deadline, if !ready => {
                c.deadline.fetch_add(1, Relaxed);
                return Some((CODE_DEADLINE, b"hello deadline".to_vec()));
            }
            s = conn.accept_bi() => {
                let Ok((send, recv)) = s else { return None };
                // The first client stream is the control stream; a session
                // has no use for another.
                let Some(rx) = control_rx.take() else {
                    drop((send, recv));
                    continue;
                };
                tokio::spawn(drain(sh.clone(), send, rx));
                tokio::spawn(read_loop(sh.clone(), recv));
            }
        }
        if sh.queued.load(Relaxed) > MAX_QUEUED || (control_rx.is_some() && held > HELD_MAX) {
            c.overflow.fetch_add(1, Relaxed);
            return Some((CODE_OVERFLOW, b"peer is not reading".to_vec()));
        }
    }
}

/// Applies one message from the BEAM.
fn beam(
    conn: &Connection,
    sh: &Arc<Shared>,
    control: &mpsc::UnboundedSender<Vec<u8>>,
    m: &[u8],
) -> Result<Option<(u32, Vec<u8>)>, ()> {
    match m[0] {
        READY => {
            if !sh.ready.swap(true, Relaxed) {
                conn.quic_connection().set_receive_window(QVarInt::from_u32(WINDOW_AFTER));
                sh.gate.counters.ready.fetch_add(1, Relaxed);
            }
        }
        DATA => {
            let body = m[1..].to_vec();
            sh.queued.fetch_add(body.len(), Relaxed);
            let _ = control.send(body);
        }
        UNI => {
            let body = m[1..].to_vec();
            sh.queued.fetch_add(body.len(), Relaxed);
            let (conn, sh) = (conn.clone(), sh.clone());
            tokio::spawn(async move {
                let n = body.len();
                if let Ok(Ok(mut send)) = async { Ok::<_, ()>(conn.open_uni().await.map_err(|_| ())?.await) }.await {
                    send.set_priority(BULK_PRIORITY);
                    if send.write_all(&body).await.is_ok() {
                        let _ = send.finish().await;
                        sh.gate.counters.bytes_out.fetch_add(n as u64, Relaxed);
                    }
                }
                sh.queued.fetch_sub(n, Relaxed);
            });
        }
        CLOSE => {
            let code = u32::from_be_bytes(m.get(1..5).ok_or(())?.try_into().map_err(|_| ())?);
            return Ok(Some((code, m[5..].to_vec())));
        }
        _ => return Err(()),
    }
    Ok(None)
}

/// Moves the control stream's queue onto QUIC.
async fn drain(sh: Arc<Shared>, mut send: SendStream, mut rx: mpsc::UnboundedReceiver<Vec<u8>>) {
    while let Some(bytes) = rx.recv().await {
        let n = bytes.len();
        let ok = send.write_all(&bytes).await.is_ok();
        sh.queued.fetch_sub(n, Relaxed);
        sh.gate.counters.bytes_out.fetch_add(n as u64, Relaxed);
        if !ok {
            return;
        }
    }
}

/// Forwards the control stream's bytes to the BEAM until it ends.
async fn read_loop(sh: Arc<Shared>, mut recv: RecvStream) {
    let mut buf = vec![0u8; 64 << 10];
    while let Ok(Some(n)) = recv.read(&mut buf).await {
        sh.gate.counters.bytes_in.fetch_add(n as u64, Relaxed);
        let _ = sh.up.send(message(DATA, &buf[..n]));
    }
}
