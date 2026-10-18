//! A WebTransport probe for the gate: one targeted measurement, never a sweep.
//!
//! ```text
//! probe handshake URL [--hash HEX] [--n N]
//! probe hello URL --frame FILE [--hash HEX]
//! ```
//!
//! `hello` sends FILE's bytes (a HELLO frame) on the control stream and
//! reports, as one JSON line, the kinds of the frames that come back on it
//! and on the first server uni stream, with the time to each: the round
//! trip a page makes, end to end through a live node.
//!
//! N fresh connections: the time to QUIC plus an accepted CONNECT, and
//! quinn's smoothed RTT after a second of keep-alives, as one JSON line. It
//! sends no HELLO, so against a live node each session is a pending peer
//! the gate closes at its READY deadline. `nix/deploy.sh` runs it to prove a
//! deploy from outside; exit status 0 means every connection was accepted.

use std::net::SocketAddr;
use std::pin::Pin;
use std::time::{Duration, Instant};

use wtransport::config::{DnsLookupFuture, DnsResolver};
use wtransport::tls::Sha256Digest;
use wtransport::{ClientConfig, Endpoint};

struct Args {
    mode: String,
    url: String,
    hash: Option<String>,
    n: usize,
    frame: Option<String>,
}

fn args() -> Result<Args, String> {
    let mut it = std::env::args().skip(1);
    let mode = match it.next().as_deref() {
        Some(m @ ("handshake" | "hello")) => m.to_string(),
        other => return Err(format!("mode: handshake | hello (got {other:?})")),
    };
    let url = it.next().ok_or("URL")?;
    let mut a = Args { mode, url, hash: None, n: 20, frame: None };
    while let Some(flag) = it.next() {
        let v = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--hash" if v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()) => a.hash = Some(v),
            "--hash" => return Err("--hash: 64 hex digits".into()),
            "--n" => a.n = v.parse().map_err(|_| "--n: a number")?,
            "--frame" => a.frame = Some(v),
            _ => return Err(format!("unknown flag {flag}")),
        }
    }
    Ok(a)
}

/// Answers every lookup with the address resolved once at start, so a cold
/// connect is timed without the system resolver.
#[derive(Debug)]
struct Fixed(SocketAddr);

impl DnsResolver for Fixed {
    fn resolve(&self, _host: &str) -> Pin<Box<dyn DnsLookupFuture>> {
        let addr = self.0;
        Box::pin(async move { Ok(Some(addr)) })
    }
}

async fn resolve(url: &str) -> Result<SocketAddr, String> {
    let authority = url.split("://").nth(1).and_then(|r| r.split('/').next()).ok_or("URL: want https://host[:port]/path")?;
    let target = if authority.contains(':') { authority.to_string() } else { format!("{authority}:443") };
    tokio::net::lookup_host(&target)
        .await
        .map_err(|e| format!("{target}: {e}"))?
        .next()
        .ok_or_else(|| format!("{target}: no address"))
}

fn endpoint(hash: &Option<String>, addr: SocketAddr) -> Endpoint<wtransport::endpoint::endpoint_side::Client> {
    let builder = ClientConfig::builder().with_bind_default();
    let config = match hash {
        Some(h) => {
            let bytes: Vec<u8> = (0..32).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap_or(0)).collect();
            builder.with_server_certificate_hashes([Sha256Digest::new(bytes.try_into().unwrap())])
        }
        None => builder.with_native_certs(),
    }
    .keep_alive_interval(Some(Duration::from_millis(200)))
    .dns_resolver(Fixed(addr))
    .build();
    Endpoint::client(config).expect("client endpoint")
}

fn pct(samples: &mut [Duration], p: usize) -> Duration {
    samples.sort();
    samples[(samples.len() * p / 100).min(samples.len() - 1)]
}

fn ms(d: Duration) -> String {
    format!("{:.2}", d.as_secs_f64() * 1000.0)
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let a = match args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("probe: {e}");
            std::process::exit(2);
        }
    };
    let addr = match resolve(&a.url).await {
        Ok(addr) => addr,
        Err(e) => {
            eprintln!("probe: {e}");
            std::process::exit(2);
        }
    };
    if a.mode == "hello" {
        return hello(&a, addr).await;
    }
    let (mut connect, mut rtt) = (Vec::new(), Vec::new());
    for _ in 0..a.n.max(1) {
        // A fresh endpoint each time: no session ticket, no address token;
        // built before the clock starts, since loading roots is not a
        // per-connection cost a browser pays.
        let ep = endpoint(&a.hash, addr);
        let t = Instant::now();
        let conn = match ep.connect(&a.url).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("probe: connect {}: {e}", a.url);
                std::process::exit(1);
            }
        };
        connect.push(t.elapsed());
        tokio::time::sleep(Duration::from_secs(1)).await;
        rtt.push(conn.rtt());
        conn.close(0u32.into(), b"");
    }
    println!(
        "{{\"mode\":\"handshake\",\"n\":{},\"connect_ms\":{{\"p50\":{},\"p90\":{},\"min\":{}}},\"rtt_ms\":{{\"p50\":{},\"min\":{}}}}}",
        connect.len(),
        ms(pct(&mut connect, 50)),
        ms(pct(&mut connect, 90)),
        ms(pct(&mut connect, 0)),
        ms(pct(&mut rtt, 50)),
        ms(pct(&mut rtt, 0))
    );
}

// Frame kinds from a byte stream of whole frames (u32 len | u8 kind | ...).
fn kinds(buf: &[u8]) -> (Vec<u8>, usize) {
    let (mut out, mut at) = (Vec::new(), 0);
    while buf.len() >= at + 16 {
        let len = u32::from_le_bytes(buf[at..at + 4].try_into().unwrap()) as usize;
        if len < 16 || buf.len() < at + len {
            break;
        }
        out.push(buf[at + 4]);
        at += len;
    }
    (out, at)
}

async fn hello(a: &Args, addr: SocketAddr) {
    let Some(path) = &a.frame else {
        eprintln!("probe: hello needs --frame FILE");
        std::process::exit(2);
    };
    let frame = std::fs::read(path).unwrap_or_else(|e| {
        eprintln!("probe: {path}: {e}");
        std::process::exit(2)
    });
    let ep = endpoint(&a.hash, addr);
    let t = Instant::now();
    let conn = ep.connect(&a.url).await.unwrap_or_else(|e| {
        eprintln!("probe: connect {}: {e}", a.url);
        std::process::exit(1)
    });
    let connected = t.elapsed();
    let (mut send, mut recv) = conn.open_bi().await.expect("open bi").await.expect("bi stream");
    send.write_all(&frame).await.expect("write HELLO");

    let control = async {
        let (mut buf, mut chunk) = (Vec::new(), vec![0u8; 1 << 16]);
        loop {
            match recv.read(&mut chunk).await {
                Ok(Some(n)) => {
                    buf.extend_from_slice(&chunk[..n]);
                    let (k, _) = kinds(&buf);
                    if !k.is_empty() {
                        return (k, t.elapsed());
                    }
                }
                _ => return (kinds(&buf).0, t.elapsed()),
            }
        }
    };
    let bulk = async {
        let Ok(mut uni) = conn.accept_uni().await else { return (Vec::new(), 0, t.elapsed()) };
        let (mut buf, mut chunk) = (Vec::new(), vec![0u8; 1 << 16]);
        while let Ok(Some(n)) = uni.read(&mut chunk).await {
            buf.extend_from_slice(&chunk[..n]);
        }
        (kinds(&buf).0, buf.len(), t.elapsed())
    };
    let ((control_kinds, first), (bulk_kinds, bulk_bytes, last)) =
        tokio::time::timeout(Duration::from_secs(10), async { tokio::join!(control, bulk) })
            .await
            .unwrap_or_else(|_| {
                eprintln!("probe: no answer in 10 s");
                std::process::exit(1)
            });
    conn.close(0u32.into(), b"");
    println!(
        "{{\"mode\":\"hello\",\"connect_ms\":{},\"control_kinds\":{:?},\"control_ms\":{},\"bulk_kinds\":{:?},\"bulk_bytes\":{},\"bulk_ms\":{}}}",
        ms(connected),
        control_kinds,
        ms(first),
        bulk_kinds,
        bulk_bytes,
        ms(last)
    );
    if control_kinds.is_empty() {
        std::process::exit(1);
    }
}
