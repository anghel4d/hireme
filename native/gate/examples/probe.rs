//! A WebTransport probe for the gate. It never runs a benchmark sweep on its
//! own; each mode is one targeted measurement.
//!
//! ```text
//! probe handshake URL [--hash HEX] [--n N]
//!     N fresh connections: time to QUIC + CONNECT accepted, and quinn's
//!     smoothed RTT after a second of keep-alives. No credentials: against
//!     production the session is a pending agent that the BEAM drops after 2 s.
//! probe echo URL [--hash HEX] [--n N]
//!     N round trips on the control stream (needs an echoing Session, as in
//!     the localhost loop).
//! probe bulk URL [--hash HEX] [--bytes B] [--rounds R]
//!     Ask the echoing Session for B bytes on a low-priority uni stream and
//!     time the last byte, while pinging the control stream every 5 ms to see
//!     whether bulk delays control.
//! ```
//!
//! The echoing Session's control protocol: `E` + 8 bytes is echoed back;
//! `B` + u32 LE asks for that many bytes on a new server uni stream.

use std::time::{Duration, Instant};
use std::net::SocketAddr;
use std::pin::Pin;
use wtransport::config::{DnsLookupFuture, DnsResolver};
use wtransport::tls::Sha256Digest;
use wtransport::{ClientConfig, Connection, Endpoint};

struct Args {
    mode: String,
    url: String,
    hash: Option<String>,
    n: usize,
    bytes: usize,
    rounds: usize,
}

fn args() -> Args {
    let mut it = std::env::args().skip(1);
    let mode = it.next().expect("mode: handshake | echo | bulk");
    let url = it.next().expect("URL");
    let mut a = Args { mode, url, hash: None, n: 20, bytes: 2 << 20, rounds: 5 };
    while let Some(flag) = it.next() {
        let v = it.next().expect("flag value");
        match flag.as_str() {
            "--hash" => a.hash = Some(v).filter(|h| h.len() == 64),
            "--n" => a.n = v.parse().unwrap(),
            "--bytes" => a.bytes = v.parse().unwrap(),
            "--rounds" => a.rounds = v.parse().unwrap(),
            _ => panic!("unknown flag {flag}"),
        }
    }
    a
}

/// Answers every lookup with the address resolved once at start, so a cold
/// connect is timed without the system resolver (tens of ms under WSL).
#[derive(Debug)]
struct Fixed(SocketAddr);

impl DnsResolver for Fixed {
    fn resolve(&self, _host: &str) -> Pin<Box<dyn DnsLookupFuture>> {
        let addr = self.0;
        Box::pin(async move { Ok(Some(addr)) })
    }
}

async fn resolve(url: &str) -> SocketAddr {
    let authority = url.split("://").nth(1).unwrap().split('/').next().unwrap();
    let target = if authority.contains(':') { authority.to_string() } else { format!("{authority}:443") };
    tokio::net::lookup_host(target).await.unwrap().next().expect("no address")
}

fn endpoint(hash: &Option<String>, addr: SocketAddr) -> Endpoint<wtransport::endpoint::endpoint_side::Client> {
    let builder = ClientConfig::builder().with_bind_default();
    let config = match hash {
        Some(h) => {
            let bytes: Vec<u8> = (0..32).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect();
            builder.with_server_certificate_hashes([Sha256Digest::new(bytes.try_into().unwrap())])
        }
        None => builder.with_native_certs(),
    }
    .keep_alive_interval(Some(Duration::from_millis(200)))
    .dns_resolver(Fixed(addr))
    .build();
    Endpoint::client(config).unwrap()
}

fn pct(samples: &mut [Duration], p: usize) -> Duration {
    samples.sort();
    samples[(samples.len() * p / 100).min(samples.len() - 1)]
}

fn ms(d: Duration) -> String {
    format!("{:.2}", d.as_secs_f64() * 1000.0)
}

#[tokio::main]
async fn main() {
    let a = args();
    match a.mode.as_str() {
        "handshake" => handshake(&a).await,
        "echo" => echo(&a).await,
        "bulk" => bulk(&a).await,
        m => panic!("unknown mode {m}"),
    }
}

async fn handshake(a: &Args) {
    let (mut connect, mut rtt) = (Vec::new(), Vec::new());
    let addr = resolve(&a.url).await;
    for _ in 0..a.n {
        // A fresh endpoint each time: no session ticket, no address token.
        // Built before the clock starts: loading the system roots costs
        // tens of milliseconds that no browser pays per connection.
        let ep = endpoint(&a.hash, addr);
        let t = Instant::now();
        let conn = ep.connect(&a.url).await.expect("connect");
        connect.push(t.elapsed());
        tokio::time::sleep(Duration::from_secs(1)).await;
        rtt.push(conn.rtt());
        conn.close(0u32.into(), b"");
    }
    println!(
        "{{\"mode\":\"handshake\",\"n\":{},\"connect_ms\":{{\"p50\":{},\"p90\":{},\"min\":{}}},\"rtt_ms\":{{\"p50\":{},\"min\":{}}}}}",
        a.n,
        ms(pct(&mut connect, 50)),
        ms(pct(&mut connect, 90)),
        ms(pct(&mut connect, 0)),
        ms(pct(&mut rtt, 50)),
        ms(pct(&mut rtt, 0))
    );
}

async fn open(a: &Args) -> (Connection, wtransport::SendStream, wtransport::RecvStream, Duration) {
    let ep = endpoint(&a.hash, resolve(&a.url).await);
    let t = Instant::now();
    let conn = ep.connect(&a.url).await.expect("connect");
    let (mut send, mut recv) = conn.open_bi().await.unwrap().await.unwrap();
    let mut m = [0u8; 9];
    m[0] = b'E';
    send.write_all(&m).await.unwrap();
    recv.read_exact(&mut m).await.unwrap();
    (conn, send, recv, t.elapsed())
}

async fn echo(a: &Args) {
    let (conn, mut send, mut recv, first) = open(a).await;
    let mut samples = Vec::with_capacity(a.n);
    for i in 0..a.n {
        let mut m = [0u8; 9];
        m[0] = b'E';
        m[1..].copy_from_slice(&(i as u64).to_le_bytes());
        let t = Instant::now();
        send.write_all(&m).await.unwrap();
        let mut got = [0u8; 9];
        recv.read_exact(&mut got).await.unwrap();
        samples.push(t.elapsed());
        assert_eq!(got, m);
    }
    println!(
        "{{\"mode\":\"echo\",\"n\":{},\"first_ms\":{},\"rtt_ms\":{{\"p50\":{},\"p90\":{},\"p99\":{}}},\"quic_rtt_ms\":{}}}",
        a.n,
        ms(first),
        ms(pct(&mut samples, 50)),
        ms(pct(&mut samples, 90)),
        ms(pct(&mut samples, 99)),
        ms(conn.rtt())
    );
}

async fn bulk(a: &Args) {
    let (conn, mut send, mut recv, _) = open(a).await;
    let mut times = Vec::new();
    let mut pings: Vec<Duration> = Vec::new();
    for _ in 0..a.rounds {
        let mut req = vec![b'B'];
        req.extend_from_slice(&(a.bytes as u32).to_le_bytes());
        let t = Instant::now();
        send.write_all(&req).await.unwrap();
        let reader = {
            let conn = conn.clone();
            let want = a.bytes;
            tokio::spawn(async move {
                let mut uni = conn.accept_uni().await.unwrap();
                let mut buf = vec![0u8; 1 << 16];
                let mut got = 0;
                while let Some(n) = uni.read(&mut buf).await.unwrap() {
                    got += n;
                }
                assert_eq!(got, want);
            })
        };
        // Control pings while the bulk stream is in flight.
        let mut i = 0u64;
        while !reader.is_finished() {
            let mut m = [0u8; 9];
            m[0] = b'E';
            m[1..].copy_from_slice(&i.to_le_bytes());
            let p = Instant::now();
            send.write_all(&m).await.unwrap();
            let mut got = [0u8; 9];
            recv.read_exact(&mut got).await.unwrap();
            pings.push(p.elapsed());
            i += 1;
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        reader.await.unwrap();
        times.push(t.elapsed());
    }
    let mbit = a.bytes as f64 * 8.0 / pct(&mut times.clone(), 50).as_secs_f64() / 1e6;
    println!(
        "{{\"mode\":\"bulk\",\"bytes\":{},\"rounds\":{},\"bulk_ms\":{{\"p50\":{},\"min\":{},\"max\":{}}},\"mbit_s\":{:.1},\"ping_during_ms\":{{\"n\":{},\"p50\":{},\"p90\":{},\"max\":{}}},\"quic_rtt_ms\":{}}}",
        a.bytes,
        a.rounds,
        ms(pct(&mut times, 50)),
        ms(pct(&mut times, 0)),
        ms(pct(&mut times, 100)),
        mbit,
        pings.len(),
        ms(pct(&mut pings, 50)),
        ms(pct(&mut pings, 90)),
        ms(pct(&mut pings, 100)),
        ms(conn.rtt())
    );
}
