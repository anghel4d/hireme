//! A WebTransport probe for the gate: connects, writes `hello` on the
//! control stream, then times N echo round trips through the gate and the
//! BEAM. It is meant for localhost and for a post-deploy check, never for a
//! benchmark sweep.
//!
//! `cargo run --release --example probe -- URL [CERT_SHA256_HEX] [N]`
//! The BEAM side must echo stream 0, which is what a Session in its probe
//! mode (or the gate test's echo Session) does.

use std::time::{Duration, Instant};
use wtransport::tls::Sha256Digest;
use wtransport::{ClientConfig, Endpoint};

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let url = args.next().expect("URL");
    let hash = args.next().filter(|h| h.len() == 64);
    let n: usize = args.next().and_then(|n| n.parse().ok()).unwrap_or(200);

    let builder = ClientConfig::builder().with_bind_default();
    let config = match hash {
        Some(h) => {
            let bytes: Vec<u8> = (0..32).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect();
            builder.with_server_certificate_hashes([Sha256Digest::new(bytes.try_into().unwrap())])
        }
        None => builder.with_native_certs(),
    }
    .keep_alive_interval(Some(Duration::from_secs(5)))
    .build();

    let t0 = Instant::now();
    let conn = Endpoint::client(config).unwrap().connect(&url).await.expect("connect");
    let connected = t0.elapsed();
    let (mut send, mut recv) = conn.open_bi().await.unwrap().await.unwrap();
    send.write_all(b"hello").await.unwrap();
    let mut buf = [0u8; 64];
    let k = recv.read(&mut buf).await.unwrap().unwrap();
    let hello = t0.elapsed();
    assert_eq!(&buf[..k], b"hello", "echo");

    let mut samples = Vec::with_capacity(n);
    for i in 0..n {
        let msg = (i as u64).to_le_bytes();
        let t = Instant::now();
        send.write_all(&msg).await.unwrap();
        let mut got = [0u8; 8];
        recv.read_exact(&mut got).await.unwrap();
        samples.push(t.elapsed());
        assert_eq!(got, msg);
    }
    samples.sort();
    let pct = |p: usize| samples[(samples.len() * p / 100).min(samples.len() - 1)];
    println!(
        "connect {:?}  hello echo {:?}  stream rtt over {n}: p50 {:?} p90 {:?} p99 {:?}  quic rtt {:?}",
        connected,
        hello,
        pct(50),
        pct(90),
        pct(99),
        conn.rtt()
    );
}
