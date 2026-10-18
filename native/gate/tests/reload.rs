//! Certificate reload: after a pair that does not load (an empty certificate, a garbage key, a
//! mismatched pair) the gate stays up on the old one and follows the next good pair.
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::process::ChildStdin;
use tokio::time::{sleep, timeout};
use wtransport::tls::{Identity, Sha256Digest};
use wtransport::{ClientConfig, Endpoint};

struct Pair {
    cert: String,
    key: String,
    hash: [u8; 32],
}

fn pair() -> Pair {
    let id = Identity::self_signed(["127.0.0.1"]).unwrap();
    let cert = id.certificate_chain().as_slice()[0].clone();
    let mut hash = [0u8; 32];
    hash.copy_from_slice(cert.hash().as_ref());
    Pair { cert: cert.to_pem(), key: id.private_key().clone_key().to_secret_pem(), hash }
}

async fn reaches(url: &str, hash: [u8; 32]) -> bool {
    let config = ClientConfig::builder().with_bind_default().with_server_certificate_hashes([Sha256Digest::new(hash)]).build();
    let client = Endpoint::client(config).unwrap();
    matches!(timeout(Duration::from_secs(3), client.connect(url)).await, Ok(Ok(_)))
}

/// `reload` rereads the pair a second later.
async fn reload(stdin: &mut ChildStdin) {
    stdin.write_all(b"reload\n").await.unwrap();
    stdin.flush().await.unwrap();
    sleep(Duration::from_millis(4000)).await;
}

/// A gate up on pair A: `spoil` breaks the pair on disk and the gate is told to reload, then pair B
/// is written whole and the gate told again.
async fn scenario(name: &str, spoil: impl FnOnce(&Path, &Path, &Pair)) {
    let dir = std::env::temp_dir().join(format!("hg-reload-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("g.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    // A stand-in BEAM that ACCEPTs every session and holds it.
    tokio::spawn(async move {
        let mut held = Vec::new();
        loop {
            let (mut s, _) = listener.accept().await.unwrap();
            let len = s.read_u32().await.unwrap() as usize;
            let mut buf = vec![0; len];
            s.read_exact(&mut buf).await.unwrap();
            s.write_all(&[0, 0, 0, 1, 0x02]).await.unwrap();
            held.push(s);
        }
    });
    let (a, b) = (pair(), pair());
    let (cert, key) = (dir.join("fullchain.pem"), dir.join("key.pem"));
    std::fs::write(&cert, &a.cert).unwrap();
    std::fs::write(&key, &a.key).unwrap();
    let port = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_hireme-gate"))
        .env("GATE_SOCKET", &socket)
        .env("GATE_LISTEN", format!("127.0.0.1:{port}"))
        .env("GATE_CERT", &cert)
        .env("GATE_KEY", &key)
        .env("GATE_PER_IP", "64")
        .stdin(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let url = format!("https://127.0.0.1:{port}/wt");
    sleep(Duration::from_millis(800)).await;
    assert!(reaches(&url, a.hash).await && !reaches(&url, b.hash).await, "{name}: up on pair A alone");
    spoil(&cert, &key, &b);
    reload(&mut stdin).await;
    assert!(child.try_wait().unwrap().is_none(), "{name}: the gate survives a pair that does not load");
    assert!(reaches(&url, a.hash).await, "{name}: it keeps the old certificate");
    std::fs::write(&cert, &b.cert).unwrap();
    std::fs::write(&key, &b.key).unwrap();
    reload(&mut stdin).await;
    assert!(reaches(&url, b.hash).await, "{name}: it follows the next good pair");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_pair_that_does_not_load_keeps_the_old_certificate_until_a_good_pair_comes() {
    tokio::join!(
        scenario("empty-cert", |cert, _, _| std::fs::write(cert, "").unwrap()),
        scenario("garbage-key", |_, key, _| std::fs::write(key, "-----BEGIN PRIVATE KEY-----\ngarbage\n-----END PRIVATE KEY-----\n").unwrap()),
        scenario("mismatched-pair", |cert, _, b| std::fs::write(cert, &b.cert).unwrap()),
    );
}
