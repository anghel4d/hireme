//! A WebTransport probe for the gate. It never runs a benchmark sweep on its
//! own; each mode is one targeted measurement.
//!
//! ```text
//! probe handshake URL [--hash HEX] [--n N]
//!     N fresh connections: time to QUIC + CONNECT accepted, and quinn's
//!     smoothed RTT after a second of keep-alives. No credentials: against
//!     production the session is a pending agent that the BEAM drops after 2 s.
//! probe boot URL?boot=B [--hash HEX] [--n N]
//!     N cold sessions whose BOOT (B bytes) the echoing Session
//!     (bench/gate_echo.exs) pushes on a
//!     server uni stream as it accepts: time to `ready`, to the first and to
//!     the last BOOT byte, all from the start of the connect.
//! ```

use std::time::{Duration, Instant};
use std::net::SocketAddr;
use std::pin::Pin;
use wtransport::config::{DnsLookupFuture, DnsResolver};
use wtransport::tls::Sha256Digest;
use wtransport::{ClientConfig, Endpoint};

struct Args {
    mode: String,
    url: String,
    hash: Option<String>,
    n: usize,
}

fn args() -> Args {
    let mut it = std::env::args().skip(1);
    let mode = it.next().expect("mode: handshake | boot");
    let url = it.next().expect("URL");
    let mut a = Args { mode, url, hash: None, n: 20 };
    while let Some(flag) = it.next() {
        let v = it.next().expect("flag value");
        match flag.as_str() {
            "--hash" => a.hash = Some(v).filter(|h| h.len() == 64),
            "--n" => a.n = v.parse().unwrap(),
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

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let a = args();
    match a.mode.as_str() {
        "handshake" => handshake(&a).await,
        "boot" => boot(&a).await,
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

async fn boot(a: &Args) {
    let addr = resolve(&a.url).await;
    let (mut ready, mut first, mut last) = (Vec::new(), Vec::new(), Vec::new());
    for _ in 0..a.n {
        let ep = endpoint(&a.hash, addr);
        let t = Instant::now();
        let conn = ep.connect(&a.url).await.expect("connect");
        ready.push(t.elapsed());
        let mut uni = conn.accept_uni().await.unwrap();
        let mut buf = vec![0u8; 1 << 16];
        let mut got = uni.read(&mut buf).await.unwrap().unwrap_or(0);
        first.push(t.elapsed());
        while let Some(n) = uni.read(&mut buf).await.unwrap() {
            got += n;
        }
        last.push(t.elapsed());
        assert!(got > 0);
        conn.close(0u32.into(), b"");
    }
    println!(
        "{{\"mode\":\"boot\",\"n\":{},\"ready_ms\":{},\"first_byte_ms\":{},\"last_byte_ms\":{}}}",
        a.n,
        ms(pct(&mut ready, 50)),
        ms(pct(&mut first, 50)),
        ms(pct(&mut last, 50))
    );
}
