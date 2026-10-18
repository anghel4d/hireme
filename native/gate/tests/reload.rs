//! Certificate reload: after a pair that does not load (an empty certificate, a garbage key, a mismatched pair) the gate keeps the old one and follows the next good pair.
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::time::{sleep, timeout};
use wtransport::tls::{Identity, Sha256Digest};
use wtransport::{ClientConfig, Endpoint};

fn message(op: u8, body: &[u8]) -> Vec<u8> {
    let mut m = ((1 + body.len()) as u32).to_be_bytes().to_vec();
    m.push(op);
    m.extend_from_slice(body);
    m
}

struct Pair {
    cert: String,
    key: String,
    hash: [u8; 32],
}

fn pair() -> Pair {
    let id = Identity::self_signed(["127.0.0.1"]).unwrap();
    let cert = id.certificate_chain().as_slice()[0].clone();
    let h = cert.hash();
    let mut hash = [0u8; 32];
    hash.copy_from_slice(h.as_ref());
    Pair { cert: cert.to_pem(), key: id.private_key().clone_key().to_secret_pem(), hash }
}

async fn reaches(url: &str, hash: [u8; 32]) -> bool {
    let config = ClientConfig::builder().with_bind_default().with_server_certificate_hashes([Sha256Digest::new(hash)]).build();
    let client = Endpoint::client(config).unwrap();
    matches!(timeout(Duration::from_secs(3), client.connect(url)).await, Ok(Ok(_)))
}

async fn scenario(kind: &str) {
    let dir = std::env::temp_dir().join(format!("rvbreload-{}-{}", std::process::id(), kind.len()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("g.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    tokio::spawn(async move {
        let mut held = Vec::new();
        loop {
            let (mut s, _) = listener.accept().await.unwrap();
            let len = s.read_u32().await.unwrap() as usize;
            let mut buf = vec![0; len];
            s.read_exact(&mut buf).await.unwrap();
            s.write_all(&message(2, &[])).await.unwrap();
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
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let log = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let l2 = log.clone();
    tokio::spawn(async move {
        use tokio::io::AsyncBufReadExt;
        let mut lines = tokio::io::BufReader::new(stderr).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            l2.lock().unwrap().push_str(&format!("{line}\n"));
        }
    });
    sleep(Duration::from_millis(800)).await;
    let url = format!("https://127.0.0.1:{port}/wt");
    println!("start: pinned A {} / pinned B {}", reaches(&url, a.hash).await, reaches(&url, b.hash).await);

    async fn reload(stdin: &mut tokio::process::ChildStdin) {
        stdin.write_all(b"reload\n").await.unwrap();
        stdin.flush().await.unwrap();
        sleep(Duration::from_millis(4000)).await;
    }

    // inject one failure, then a whole new pair B; does the gate still follow?
    match kind {
        "empty cert file" => { std::fs::write(&cert, "").unwrap(); }
        "garbage key" => { std::fs::write(&key, "-----BEGIN PRIVATE KEY-----\ngarbage\n-----END PRIVATE KEY-----\n").unwrap(); }
        "mismatched pair (cert B, key A)" => { std::fs::write(&cert, &b.cert).unwrap(); }
        _ => unreachable!(),
    }
    reload(&mut stdin).await;
    println!("[{kind}] after the failure: pinned A {}  gate alive: {}", reaches(&url, a.hash).await, child.try_wait().unwrap().is_none());
    std::fs::write(&cert, &b.cert).unwrap();
    std::fs::write(&key, &b.key).unwrap();
    reload(&mut stdin).await;
    println!("[{kind}] whole pair B written and reload sent: pinned B {} (true = the gate followed)", reaches(&url, b.hash).await);
    println!("[{kind}] gate stderr: {}", log.lock().unwrap().replace('\n', " | "));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn reload_after_an_empty_cert_file() { scenario("empty cert file").await }
#[tokio::test]
async fn reload_after_a_garbage_key() { scenario("garbage key").await }
#[tokio::test]
async fn reload_after_a_mismatched_pair() { scenario("mismatched pair (cert B, key A)").await }
