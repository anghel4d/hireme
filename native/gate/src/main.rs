//! hireme-gate: the WebTransport front door.
//!
//! It terminates QUIC and HTTP/3 and holds no business logic. Each
//! WebTransport session becomes one connection to the BEAM's Unix
//! socket. Stream bytes, datagrams and stream lifecycle cross that socket
//! as `{packet,4}` messages, and authentication, the ledger and the domain
//! all stay in Elixir. `lib/hireme_web/gate.ex` holds the authoritative
//! description of the bridge protocol, and this file implements the gate
//! half of it.
//!
//! The gate behaves like an order gateway, so nothing is allocated for a
//! peer before it has passed the cheap checks:
//! - QUIC Retry (stateless address validation) while handshakes pile up,
//!   and always for an address at its cap, so a refusal goes only to an
//!   address that proved it is real;
//! - a per-IP cap on live sessions;
//! - a path prefix and an `Origin` allow-list (an absent Origin is a native
//!   agent and is forwarded as "", so the BEAM then insists on an API key);
//! - the BEAM must ACCEPT within 2 s and declare READY (HELLO verified)
//!   within 2 s after that, or the connection closes (a Session that
//!   authenticated at OPEN may write ahead of its ACCEPT);
//! - until READY, one client bidi stream, a 64 KiB connection receive
//!   window, and no datagrams forwarded.
//!
//! Traffic is what the Session uses: client bidi streams (the control
//! stream and letterbox leases), client datagrams, and server uni streams
//! the BEAM opens for bulk (the BOOT, sent as the session is accepted), which
//! always yield to the client's streams. The gate accepts no uni streams.
//!
//! The certificate is reloaded on SIGHUP and whenever the PEM files
//! change on disk, so an ACME renewal needs no restart.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use tokio::io::{AsyncReadExt, AsyncWriteExt, BufWriter};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
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
const STREAM: u8 = 0x10;
const DATA: u8 = 0x11;
const FIN: u8 = 0x12;
const RESET: u8 = 0x13;
const STOP: u8 = 0x14;
const OPEN_UNI: u8 = 0x15;
const DGRAM: u8 = 0x20;
const CLOSE: u8 = 0x30;

/// The longest bridge message accepted from the BEAM.
const MAX_MESSAGE: usize = 16 << 20;
/// Bytes queued towards QUIC per session before the gate gives up on a
/// peer that does not read.
const MAX_QUEUED: usize = 32 << 20;
/// Bytes the BEAM may queue for the control stream before the client opens it.
const HELD_MAX: usize = 4 << 20;
const DEADLINE: Duration = Duration::from_secs(2);
/// QUIC handshake plus the CONNECT. A lossy path spends seconds in probe
/// timeouts here (333 ms, doubling), and a browser that gets no answer waits
/// for good, so this bound is generous; the release's patched wtransport
/// closes a connection given up on (native/gate/wtransport.patch).
const HANDSHAKE: Duration = Duration::from_secs(10);
/// QUIC-level stream counts. HTTP/3 itself takes one bidi (the CONNECT
/// request) and three uni streams (control and the two QPACK streams).
const BIDI_BEFORE: u32 = 2;
const BIDI_AFTER: u32 = 1 + 64;
const UNI: u32 = 3;
/// A server uni stream carries bulk; client streams (control) go first.
const BULK_PRIORITY: i32 = -1;
/// Handshakes in flight above which every unvalidated address gets a Retry.
const RETRY_ABOVE: usize = 32;
const WINDOW_BEFORE: u32 = 64 << 10;
const WINDOW_AFTER: u32 = 16 << 20;
const STREAM_WINDOW: u32 = 4 << 20;
/// Congestion window before the first loss or ACK, in bytes (GATE_INITIAL_WINDOW
/// overrides it). quinn's default is ten packets, 14,720 bytes, which keeps a
/// cold BOOT's rest frame in slow start for round trips. 1 MiB pushed at
/// accept to Chromium, until its last byte:
///   47 ms RTT, unconstrained: 372 ms at the default, 246 at 256 KiB, 174 at 1 MiB;
///   30 ms, 300 Mbit/s: 160 at 256 KiB, 120 at 1 MiB;
///   47 ms, 100 Mbit/s: 249 at 256 KiB, 206 at 1 MiB;
///   47 ms, 20 Mbit/s, 100-packet queue: 550 at 256 KiB, 590 at 1 MiB.
/// quinn paces the window over the measured RTT, so it does not leave as
/// one burst; only a slow link with a shallow queue pays a little for it.
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

/// In-memory counters, printed on SIGUSR1 and never written anywhere.
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
    // Cubic, quinn's default: BBR measured slower in Chromium on every path tried.
    let mut cubic = CubicConfig::default();
    cubic.initial_window(s.initial_window);
    t.congestion_controller_factory(Arc::new(cubic));
    // The connection window is the pre-auth cap and rises at READY; a stream
    // window cannot change later, so it is sized for the session's life.
    t.max_concurrent_bidi_streams(QVarInt::from_u32(BIDI_BEFORE))
        .max_concurrent_uni_streams(QVarInt::from_u32(UNI))
        .receive_window(QVarInt::from_u32(WINDOW_BEFORE))
        .stream_receive_window(QVarInt::from_u32(STREAM_WINDOW))
        .max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()))
        .keep_alive_interval(Some(Duration::from_secs(10)));
    t
}

async fn identity(s: &Settings) -> Result<Identity, String> {
    let id = match &s.cert {
        Some((c, k)) => Identity::load_pemfiles(c, k).await.map_err(|e| format!("certificate: {e}"))?,
        None => Identity::self_signed(["localhost", "127.0.0.1", "::1"]).map_err(|e| e.to_string())?,
    };
    if let Some(path) = &s.hash_file {
        // The hash a browser passes as `serverCertificateHashes` for a
        // self-signed certificate; written atomically for the BEAM to read.
        let hex: String = id.certificate_chain().as_slice()[0]
            .hash()
            .as_ref()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, hex + "\n").and_then(|_| std::fs::rename(&tmp, path)).map_err(|e| format!("hash file: {e}"))?;
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

// One thread. A frame crosses about eight tasks between the Unix socket and
// the UDP socket (bridge reader, session loop, stream writer, quinn's
// connection and endpoint drivers); on a work-stealing pool most of those
// wakes land on another thread and cost a futex each. On one thread a reply
// of two frames went from 0.64 ms p50 / 2.7 ms p99 to 0.37 / 0.61 on loopback,
// and the gate's work is I/O, which one core carries for this site.
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
    tokio::spawn(reload(gate.clone(), endpoint.clone()));
    tokio::spawn(stats(gate.clone()));

    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
    loop {
        tokio::select! {
            incoming = endpoint.accept() => admit(&gate, incoming),
            _ = term.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
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
    let validated = incoming.remote_address_validated();
    if !validated && (gate.handshakes.load(Relaxed) >= RETRY_ABOVE || gate.at_cap(ip)) {
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

async fn reload(gate: Arc<Gate>, endpoint: Arc<Endpoint<wtransport::endpoint::endpoint_side::Server>>) {
    let mut hup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup()).unwrap();
    let mut stamp = cert_stamp(&gate.settings);
    loop {
        tokio::select! {
            _ = hup.recv() => {}
            _ = sleep(Duration::from_secs(300)) => {
                let now = cert_stamp(&gate.settings);
                if now == stamp { continue; }
            }
        }
        // A renewal may still be writing the pair; give it a moment.
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

async fn stats(gate: Arc<Gate>) {
    let mut usr1 = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::user_defined1()).unwrap();
    while usr1.recv().await.is_some() {
        let c = &gate.counters;
        eprintln!(
            "hireme-gate: incoming={} retried={} refused_ip={} refused_origin={} refused_beam={} accepted={} ready={} deadline={} overflow={} bytes_in={} bytes_out={} handshakes={} ips={}",
            c.incoming.load(Relaxed), c.retried.load(Relaxed), c.refused_ip.load(Relaxed),
            c.refused_origin.load(Relaxed), c.refused_beam.load(Relaxed), c.accepted.load(Relaxed),
            c.ready.load(Relaxed), c.deadline.load(Relaxed), c.overflow.load(Relaxed),
            c.bytes_in.load(Relaxed), c.bytes_out.load(Relaxed), gate.handshakes.load(Relaxed),
            gate.per_ip.lock().unwrap().len(),
        );
    }
}

// ---------------------------------------------------------------- bridge

fn message(op: u8, head: &[u8], body: &[u8]) -> Vec<u8> {
    let len = 1 + head.len() + body.len();
    let mut m = Vec::with_capacity(4 + len);
    m.extend_from_slice(&(len as u32).to_be_bytes());
    m.push(op);
    m.extend_from_slice(head);
    m.extend_from_slice(body);
    m
}

fn id_message(op: u8, id: u32, body: &[u8]) -> Vec<u8> {
    message(op, &id.to_be_bytes(), body)
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

/// Writes queued messages to the BEAM, flushing once the queue is empty
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

fn u32_at(b: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(at..at + 4)?.try_into().ok()?))
}

// --------------------------------------------------------------- session

enum Cmd {
    Data(Vec<u8>),
    Fin,
    Reset(u32),
}

struct Shared {
    up: mpsc::UnboundedSender<Vec<u8>>,
    queued: AtomicUsize,
    ready: std::sync::atomic::AtomicBool,
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
    let origin = request.origin().unwrap_or("");
    let path = request.path();
    let mut head = Vec::with_capacity(5 + ip.len() + origin.len() + path.len());
    head.push(ip.len() as u8);
    head.extend_from_slice(ip.as_bytes());
    for field in [origin, path] {
        let f = &field.as_bytes()[..field.len().min(u16::MAX as usize)];
        head.extend_from_slice(&(f.len() as u16).to_be_bytes());
        head.extend_from_slice(f);
    }
    let _ = up.send(message(OPEN, &head, &[]));

    // A Session that authenticated at OPEN (a browser's ticket) may write
    // ahead of its ACCEPT: READY, a bulk stream and the BOOT on it. Those
    // messages wait here and are applied the moment the session exists, so
    // the BOOT leaves in the same flight as the 200.
    let answer = timeout(DEADLINE, async {
        let mut early = Vec::new();
        loop {
            match read_message(&mut down).await {
                Some(m) if m[0] != ACCEPT && m[0] != REFUSE => early.push(m),
                other => return (other, early),
            }
        }
    });
    let (answer, early) = match answer.await {
        Ok((m, early)) => (Ok(m), early),
        Err(e) => (Err(e), Vec::new()),
    };
    match answer {
        Ok(Some(m)) if m[0] == ACCEPT => {}
        Ok(Some(m)) if m[0] == REFUSE => {
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
    }
    let Ok(conn) = request.accept().await else { return };
    c.accepted.fetch_add(1, Relaxed);
    let shared = Arc::new(Shared { up, queued: AtomicUsize::new(0), ready: false.into(), gate: gate.clone() });
    // A select! over a partial read would lose bytes, so the BEAM's half
    // is read by its own task and arrives here as whole messages.
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
    let _ = shared.up.send(message(CLOSE, &0u32.to_be_bytes(), reason.as_bytes()));
}

/// The session loop. It returns the close code and reason when the gate
/// or the BEAM ends the session, or `None` when the peer did.
async fn run(conn: &Connection, sh: &Arc<Shared>, early: Vec<Vec<u8>>, mut down: mpsc::Receiver<Vec<u8>>) -> Option<(u32, Vec<u8>)> {
    // Each stream's queue to its writer, by session-relative id. The
    // control stream's queue exists from the start: the Session may write
    // to it (after an early BOOT) before the client has opened it, and
    // those writes wait here, in order, up to HELD_MAX.
    let mut streams: HashMap<u32, mpsc::UnboundedSender<Cmd>> = HashMap::new();
    let (control_tx, rx) = mpsc::unbounded_channel();
    streams.insert(0, control_tx);
    let mut control_rx = Some(rx);
    let mut held = 0;
    let control_bytes = |m: &[u8]| if m[0] == DATA && u32_at(m, 1) == Some(0) { m.len() } else { 0 };
    for m in &early {
        held += control_bytes(m);
        match beam(conn, sh, &mut streams, m) {
            Ok(None) => {}
            Ok(Some(close)) => return Some(close),
            Err(()) => return Some((CODE_PROTOCOL, b"bridge protocol".to_vec())),
        }
    }
    let mut next_bi = 0u32;
    let deadline = sleep(DEADLINE);
    tokio::pin!(deadline);
    let c = &sh.gate.counters;
    loop {
        let ready = sh.ready.load(Relaxed);
        tokio::select! {
            biased;
            m = down.recv() => {
                let Some(m) = m else { return Some((CODE_BRIDGE, b"bridge closed".to_vec())) };
                held += control_bytes(&m);
                match beam(conn, sh, &mut streams, &m) {
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
                let id = next_bi;
                next_bi += 4;
                if !ready && id != 0 {
                    drop((send, recv));
                    continue;
                }
                match (id, control_rx.take()) {
                    (0, Some(rx)) => drop(tokio::spawn(drain(sh.clone(), 0, send, rx))),
                    _ => drop(streams.insert(id, writer(sh.clone(), id, send))),
                }
                tokio::spawn(read_loop(sh.clone(), id, recv));
                let _ = sh.up.send(id_message(STREAM, id, &[]));
            }
            d = conn.receive_datagram(), if ready => {
                let Ok(d) = d else { return None };
                c.bytes_in.fetch_add(d.payload().len() as u64, Relaxed);
                let _ = sh.up.send(message(DGRAM, &[], &d.payload()));
            }
        }
        if sh.queued.load(Relaxed) > MAX_QUEUED || (control_rx.is_some() && held > HELD_MAX) {
            c.overflow.fetch_add(1, Relaxed);
            return Some((CODE_OVERFLOW, b"peer is not reading".to_vec()));
        }
    }
}

/// The peer is authenticated: lift the pre-auth stream and window caps.
fn lift(conn: &Connection, sh: &Shared) {
    if !sh.ready.swap(true, Relaxed) {
        let q = conn.quic_connection();
        q.set_max_concurrent_bi_streams(QVarInt::from_u32(BIDI_AFTER));
        q.set_receive_window(QVarInt::from_u32(WINDOW_AFTER));
        sh.gate.counters.ready.fetch_add(1, Relaxed);
    }
}

/// Applies one message from the BEAM.
fn beam(conn: &Connection, sh: &Arc<Shared>, streams: &mut HashMap<u32, mpsc::UnboundedSender<Cmd>>, m: &[u8]) -> Result<Option<(u32, Vec<u8>)>, ()> {
    let to = |streams: &mut HashMap<u32, mpsc::UnboundedSender<Cmd>>, id: u32, cmd: Cmd| {
        if let Some(tx) = streams.get(&id) {
            let _ = tx.send(cmd);
        }
    };
    match m[0] {
        READY => lift(conn, sh),
        DATA => {
            let id = u32_at(m, 1).ok_or(())?;
            let body = m[5..].to_vec();
            sh.queued.fetch_add(body.len(), Relaxed);
            to(streams, id, Cmd::Data(body));
        }
        FIN => to(streams, u32_at(m, 1).ok_or(())?, Cmd::Fin),
        RESET => {
            let id = u32_at(m, 1).ok_or(())?;
            to(streams, id, Cmd::Reset(u32_at(m, 5).ok_or(())?));
        }
        OPEN_UNI => {
            let id = u32_at(m, 1).ok_or(())?;
            if id % 4 != 3 || streams.contains_key(&id) {
                return Err(());
            }
            let (tx, rx) = mpsc::unbounded_channel();
            streams.insert(id, tx);
            let (conn, sh) = (conn.clone(), sh.clone());
            tokio::spawn(async move {
                if let Ok(Ok(send)) = async { Ok::<_, ()>(conn.open_uni().await.map_err(|_| ())?.await) }.await {
                    send.set_priority(BULK_PRIORITY);
                    drain(sh, id, send, rx).await;
                }
            });
        }
        CLOSE => {
            let code = u32_at(m, 1).ok_or(())?;
            return Ok(Some((code, m[5..].to_vec())));
        }
        _ => return Err(()),
    }
    Ok(None)
}

fn writer(sh: Arc<Shared>, id: u32, send: SendStream) -> mpsc::UnboundedSender<Cmd> {
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(drain(sh, id, send, rx));
    tx
}

/// Moves one stream's queue onto QUIC, and reports a peer STOP_SENDING.
async fn drain(sh: Arc<Shared>, id: u32, mut send: SendStream, mut rx: mpsc::UnboundedReceiver<Cmd>) {
    loop {
        let cmd = tokio::select! {
            cmd = rx.recv() => cmd,
            e = send.stopped() => {
                let code = match e { wtransport::error::StreamWriteError::Stopped(c) => c.into_inner() as u32, _ => 0 };
                let _ = sh.up.send(id_message(STOP, id, &code.to_be_bytes()));
                return;
            }
        };
        match cmd {
            None => return,
            Some(Cmd::Data(bytes)) => {
                let n = bytes.len();
                let ok = send.write_all(&bytes).await.is_ok();
                sh.queued.fetch_sub(n, Relaxed);
                sh.gate.counters.bytes_out.fetch_add(n as u64, Relaxed);
                if !ok {
                    return;
                }
            }
            Some(Cmd::Fin) => {
                let _ = send.finish().await;
                return;
            }
            Some(Cmd::Reset(code)) => {
                let _ = send.reset(VarInt::from_u32(code));
                return;
            }
        }
    }
}

/// Forwards one stream's bytes to the BEAM until FIN or reset.
async fn read_loop(sh: Arc<Shared>, id: u32, mut recv: RecvStream) {
    let mut buf = vec![0u8; 64 << 10];
    loop {
        match recv.read(&mut buf).await {
            Ok(Some(n)) => {
                sh.gate.counters.bytes_in.fetch_add(n as u64, Relaxed);
                let _ = sh.up.send(id_message(DATA, id, &buf[..n]));
            }
            Ok(None) => {
                let _ = sh.up.send(id_message(FIN, id, &[]));
                return;
            }
            Err(wtransport::error::StreamReadError::Reset(code)) => {
                let _ = sh.up.send(id_message(RESET, id, &(code.into_inner() as u32).to_be_bytes()));
                return;
            }
            Err(_) => return,
        }
    }
}
