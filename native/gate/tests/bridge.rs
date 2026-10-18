//! The real hireme-gate between a WebTransport client and a stand-in BEAM
//! on its Unix socket (the bridge protocol of HiremeWeb.Gate).

use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::time::timeout;
use wtransport::tls::Sha256Digest;
use wtransport::{ClientConfig, Endpoint};

const OPEN: u8 = 0x01;
const ACCEPT: u8 = 0x02;
const DATA: u8 = 0x11;
const CLOSE: u8 = 0x30;

fn message(op: u8, body: &[u8]) -> Vec<u8> {
    let mut m = ((1 + body.len()) as u32).to_be_bytes().to_vec();
    m.push(op);
    m.extend_from_slice(body);
    m
}

async fn read_message(s: &mut tokio::net::UnixStream) -> Vec<u8> {
    let len = s.read_u32().await.expect("bridge length") as usize;
    let mut buf = vec![0; len];
    s.read_exact(&mut buf).await.expect("bridge message");
    buf
}

struct Gate {
    _child: tokio::process::Child,
    dir: std::path::PathBuf,
    url: String,
    hash: [u8; 32],
    listener: UnixListener,
}

async fn gate() -> Gate {
    let dir = std::env::temp_dir().join(format!("hg-{}-{}", std::process::id(), rand_id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("g.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let port = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let hash_file = dir.join("hash");
    // stdin stays open: the gate stops when it closes.
    let child = tokio::process::Command::new(env!("CARGO_BIN_EXE_hireme-gate"))
        .env("GATE_SOCKET", &socket)
        .env("GATE_LISTEN", format!("127.0.0.1:{port}"))
        .env("GATE_CERT_HASH_FILE", &hash_file)
        .stdin(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .expect("hireme-gate");
    let hex = timeout(Duration::from_secs(10), async {
        loop {
            if let Ok(h) = std::fs::read_to_string(&hash_file) {
                if h.trim().len() == 64 {
                    return h.trim().to_owned();
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the gate wrote its certificate hash");
    let mut hash = [0u8; 32];
    for (i, b) in hash.iter_mut().enumerate() {
        *b = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).unwrap();
    }
    Gate { _child: child, dir, url: format!("https://127.0.0.1:{port}/wt"), hash, listener }
}

fn rand_id() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos() as u64
}

impl Drop for Gate {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn the_last_frames_the_beam_writes_before_close_reach_the_client() {
    let g = gate().await;
    let config = ClientConfig::builder()
        .with_bind_default()
        .with_server_certificate_hashes([Sha256Digest::new(g.hash)])
        .build();
    let client = Endpoint::client(config).unwrap();

    let beam = async {
        let (mut s, _) = g.listener.accept().await.unwrap();
        assert_eq!(read_message(&mut s).await[0], OPEN);
        s.write_all(&message(ACCEPT, &[])).await.unwrap();
        let hello = read_message(&mut s).await;
        assert_eq!(hello[0], DATA);
        // A Session's stop: its BYE and the close, back to back.
        let mut out = message(DATA, b"the last frame");
        out.extend(message(CLOSE, &[0, 0, 0x41, 0x00]));
        s.write_all(&out).await.unwrap();
        s
    };

    let peer = async {
        let conn = client.connect(&g.url).await.expect("connect");
        let (mut send, mut recv) = conn.open_bi().await.unwrap().await.unwrap();
        send.write_all(b"hello").await.unwrap();
        let mut got = Vec::new();
        let mut buf = [0u8; 256];
        while let Ok(Some(n)) = recv.read(&mut buf).await {
            got.extend_from_slice(&buf[..n]);
        }
        got
    };

    let (got, _beam) = timeout(Duration::from_secs(15), async { tokio::join!(peer, beam) }).await.expect("in time");
    assert_eq!(got, b"the last frame");
}
