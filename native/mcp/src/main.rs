//! hireme-mcp: hireme's MCP for local agents, as one daemon or one stdio process.
//!
//!     hireme-mcp serve [--listen 127.0.0.1:7341]   one process for every local agent (MCP over HTTP)
//!     hireme-mcp stdio                             one agent, MCP on stdin and stdout
//!     hireme-mcp token                             the daemon's local token, for an agent's config
//!
//! Every agent of a key shares one wire session to the node (WebTransport
//! through the gate, or a WebSocket to `/wire`), one replica of the
//! account's rows and one lease, kept apart per agent (`upstream.rs`).
//! A key is read from `HIREME_KEY`, `HIREME_KEY_FILE` or `--key-file`,
//! never from argv, where every process on the host could read it; an
//! agent may also present its own key as its Bearer.

mod agent;
mod front;
mod link;
mod upstream;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use link::{Dial, Prefer};

const HELP: &str = "hireme-mcp: hireme's MCP for local agents.

  hireme-mcp serve   one daemon for every local agent: MCP over HTTP on loopback
  hireme-mcp stdio   one agent: MCP on stdin and stdout
  hireme-mcp token   print the daemon's local token (an agent sends it as Bearer)

  --node URL         the node, https://... (HIREME_URL); plain http only for localhost
  --gate URL         its WebTransport gate (HIREME_GATE); default https://wt.<node host>/wt, `none` for the socket only
  --carrier C        auto (WebTransport, then the socket), webtransport or websocket (HIREME_CARRIER)
  --cert-hash HEX    a self-signed gate's certificate SHA-256 (a dev node); may repeat
  --key-file PATH    the API key (or HIREME_KEY / HIREME_KEY_FILE); serve runs without one, each agent bringing its own
  --label NAME       how the node names this session's lease (HIREME_LABEL)
  --listen ADDR      serve: the loopback address (HIREME_MCP_LISTEN, default 127.0.0.1:7341)
  --replicas N       serve: replicas of the rows per key, so N reads run at once (default: the cores, at most 8)
  --token-file PATH  serve/token: where the local token is kept (default $XDG_STATE_HOME/hireme-mcp/token)

An agent connects to http://127.0.0.1:7341/mcp with `Authorization: Bearer <token>`
(the daemon's key) or `Bearer <its own API key>`, e.g.
  claude mcp add --transport http hireme http://127.0.0.1:7341/mcp --header \"Authorization: Bearer $(hireme-mcp token)\"";

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("--help");
    if matches!(command, "--help" | "-h" | "help") {
        return println!("{HELP}");
    }
    let opts = match Opts::parse(&args[1..]) {
        Ok(o) => o,
        Err(e) => return fail(&e),
    };
    // rustls picks a crypto provider only when exactly one is compiled in; name it, so a dial never panics.
    let _ = rustls::crypto::ring::default_provider().install_default();
    match command {
        "token" => match token(&opts.token_file()) {
            Ok(t) => println!("{t}"),
            Err(e) => fail(&e),
        },
        "serve" | "stdio" => {
            let (dial, origin) = match opts.dial() {
                Ok(d) => d,
                Err(e) => return fail(&e),
            };
            let key = match opts.key() {
                Ok(k) => k,
                Err(e) => return fail(&e),
            };
            let label = opts.label.clone().unwrap_or_else(|| concat!("hireme-mcp/", env!("CARGO_PKG_VERSION")).into());
            if command == "stdio" {
                let Some(key) = key else { return fail("stdio needs a key: HIREME_KEY, HIREME_KEY_FILE or --key-file") };
                return front::stdio(upstream::Upstream::start(key, label, dial, origin, 1)).await;
            }
            let token = match token(&opts.token_file()) {
                Ok(t) => t,
                Err(e) => return fail(&e),
            };
            let listen = opts.listen.clone().unwrap_or_else(|| "127.0.0.1:7341".into());
            let addr: SocketAddr = match listen.parse() {
                Ok(a) => a,
                Err(e) => return fail(&format!("--listen {listen}: {e}")),
            };
            if !addr.ip().is_loopback() {
                return fail("--listen must be a loopback address: the daemon holds keys and answers anyone who reaches it");
            }
            let replicas = match opts.replicas.as_deref().map(str::parse::<usize>) {
                None => std::thread::available_parallelism().map_or(2, |n| n.get().min(8)),
                Some(Ok(n)) if (1..=64).contains(&n) => n,
                Some(_) => return fail("--replicas is 1 to 64"),
            };
            let daemon = front::Daemon::new(front::Config { dial, origin, label, key, token, replicas });
            let serving = Arc::clone(&daemon);
            tokio::select! {
                r = serving.serve(addr) => if let Err(e) = r { fail(&format!("{addr}: {e}")) },
                _ = shutdown() => {
                    // Each agent's lease goes back to the node before the process ends.
                    daemon.shutdown().await;
                }
            }
        }
        other => fail(&format!("no command {other}; hireme-mcp --help")),
    }
}

async fn shutdown() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = async { if let Some(t) = term.as_mut() { t.recv().await; } else { std::future::pending::<()>().await } } => {}
    }
}

fn fail(e: &str) {
    eprintln!("hireme-mcp: {e}");
    std::process::exit(2);
}

#[derive(Default)]
struct Opts {
    node: Option<String>,
    gate: Option<String>,
    carrier: Option<String>,
    cert_hashes: Vec<String>,
    key_file: Option<String>,
    label: Option<String>,
    listen: Option<String>,
    token_file: Option<String>,
    replicas: Option<String>,
}

impl Opts {
    fn parse(args: &[String]) -> Result<Opts, String> {
        let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        let mut o = Opts {
            node: env("HIREME_URL"),
            gate: env("HIREME_GATE"),
            carrier: env("HIREME_CARRIER"),
            label: env("HIREME_LABEL"),
            listen: env("HIREME_MCP_LISTEN"),
            ..Opts::default()
        };
        let mut it = args.iter();
        while let Some(flag) = it.next() {
            if flag == "--key" {
                return Err("--key would put the key in argv, where every process can read it: use HIREME_KEY or --key-file".into());
            }
            let value = it.next().cloned().ok_or_else(|| format!("{flag} needs a value"))?;
            match flag.as_str() {
                "--node" => o.node = Some(value),
                "--gate" => o.gate = Some(value),
                "--carrier" => o.carrier = Some(value),
                "--cert-hash" => o.cert_hashes.push(value),
                "--key-file" => o.key_file = Some(value),
                "--label" => o.label = Some(value),
                "--listen" => o.listen = Some(value),
                "--token-file" => o.token_file = Some(value),
                "--replicas" => o.replicas = Some(value),
                _ => return Err(format!("unknown option {flag}; hireme-mcp --help")),
            }
        }
        Ok(o)
    }

    fn key(&self) -> Result<Option<String>, String> {
        let file = self.key_file.clone().or_else(|| std::env::var("HIREME_KEY_FILE").ok());
        let key = match (std::env::var("HIREME_KEY").ok().filter(|k| !k.trim().is_empty()), file) {
            (Some(k), _) => k,
            (None, Some(path)) => std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?,
            (None, None) => return Ok(None),
        };
        let key = key.trim().to_owned();
        if key.is_empty() { Err("the key is empty".into()) } else { Ok(Some(key)) }
    }

    /// The carrier's addresses: the node's `/wire` socket, its gate, and its https origin (the blob store).
    fn dial(&self) -> Result<(Dial, String), String> {
        let node = self.node.as_deref().ok_or("set the node: --node https://... or HIREME_URL")?;
        let (scheme, rest) = node.split_once("://").unwrap_or(("https", node));
        let host = rest.split('/').next().unwrap_or(rest);
        // `user@host` would make the host something other than what the loopback check reads.
        if host.contains('@') || host.is_empty() {
            return Err(format!("{node}: name the node by its host, with no user@"));
        }
        let name = match host.strip_prefix('[') {
            Some(v6) => v6.split_once(']').map_or(v6, |(h, _)| h),
            None => host.rsplit_once(':').map_or(host, |(h, _)| h),
        };
        let plain = matches!(scheme, "http" | "ws");
        if plain && !matches!(name, "localhost" | "127.0.0.1" | "::1") {
            return Err(format!("{node}: the key would cross the network unencrypted; use https:// (plain http only for localhost)"));
        }
        let gate = match self.gate.as_deref() {
            Some("none") => None,
            Some(g) => Some(g.to_owned()),
            None if !plain => Some(format!("https://wt.{name}/wt")),
            None => None,
        };
        let prefer = match self.carrier.as_deref() {
            None | Some("auto") => Prefer::Auto,
            Some("webtransport" | "wt") => Prefer::WebTransport,
            Some("websocket" | "ws") => Prefer::WebSocket,
            Some(other) => return Err(format!("--carrier {other}: auto, webtransport or websocket")),
        };
        let cert_hashes = self.cert_hashes.iter().map(|h| hex32(h).ok_or_else(|| format!("--cert-hash {h}: 64 hex digits"))).collect::<Result<_, _>>()?;
        let origin = format!("{}://{host}", if plain { "http" } else { "https" });
        let wire = format!("{}://{host}/wire", if plain { "ws" } else { "wss" });
        Ok((Dial { wire, gate, cert_hashes, prefer }, origin))
    }

    fn token_file(&self) -> PathBuf {
        self.token_file.clone().map(PathBuf::from).unwrap_or_else(|| {
            let state = std::env::var_os("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"));
            state.join("hireme-mcp/token")
        })
    }
}

/// The daemon's local token: read, or made once (mode 0600, in a 0700 directory).
fn token(path: &PathBuf) -> Result<String, String> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    if let Ok(t) = std::fs::read_to_string(path)
        && !t.trim().is_empty()
    {
        return Ok(t.trim().to_owned());
    }
    if let Some(dir) = path.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let mut raw = [0u8; 32];
    std::fs::File::open("/dev/urandom").and_then(|mut f| std::io::Read::read_exact(&mut f, &mut raw)).map_err(|e| format!("/dev/urandom: {e}"))?;
    let t: String = raw.iter().map(|b| format!("{b:02x}")).collect();
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    std::io::Write::write_all(&mut f, t.as_bytes()).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(t)
}

fn hex32(s: &str) -> Option<[u8; 32]> {
    let s: String = s.chars().filter(|c| *c != ':').collect();
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(node: &str) -> Opts {
        Opts { node: Some(node.into()), ..Opts::default() }
    }

    #[test]
    fn the_key_never_crosses_the_network_in_plain_text() {
        let (d, origin) = opts("http://localhost:4000").dial().unwrap();
        assert_eq!((d.wire.as_str(), d.gate, origin.as_str()), ("ws://localhost:4000/wire", None, "http://localhost:4000"));
        let (d, origin) = opts("https://node.example").dial().unwrap();
        assert_eq!((d.wire.as_str(), d.gate.as_deref(), origin.as_str()), ("wss://node.example/wire", Some("https://wt.node.example/wt"), "https://node.example"));
        for bad in ["http://node.example", "ws://10.0.0.1:4000", "http://localhost:4000@evil.example", "https://u:p@node.example"] {
            assert!(opts(bad).dial().is_err(), "{bad}");
        }
    }

    #[test]
    fn a_key_in_argv_is_refused() {
        assert!(Opts::parse(&["--key".into(), "hm_x".into()]).is_err());
        assert!(Opts::parse(&["--bogus".into(), "x".into()]).is_err());
    }

    #[test]
    fn a_cert_hash_is_64_hex_digits_colons_allowed() {
        assert!(hex32(&"ab".repeat(32)).is_some());
        assert!(hex32(&["ab"; 32].join(":")).is_some());
        assert!(hex32("abc").is_none());
    }
}
