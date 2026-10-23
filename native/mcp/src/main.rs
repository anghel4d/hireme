//! hireme-mcp: hireme's MCP for local agents, as one daemon or one stdio process.
//!
//!     hireme-mcp serve [--listen 127.0.0.1:7341]   one process for every local agent (MCP over HTTP)
//!     hireme-mcp stdio                             one agent, MCP on stdin and stdout
//!     hireme-mcp token                             the daemon's local token, for an agent's config
//!
//! Every agent of a key shares one wire session to the node (a WebSocket
//! to `/wire`), one replica of the
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

const HELP: &str = "hireme-mcp: hireme's MCP for local agents.

  hireme-mcp serve   one daemon for every local agent: MCP over HTTP on loopback
  hireme-mcp stdio   one agent: MCP on stdin and stdout
  hireme-mcp token   print the daemon's local token (an agent sends it as Bearer)

  --node URL         the node, https://... (HIREME_URL); plain http only for localhost
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
            let (wire, origin) = match opts.dial() {
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
                return front::stdio(upstream::Upstream::start(key, label, wire, origin, 1)).await;
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
            let daemon = front::Daemon::new(front::Config { wire, origin, label, key, token, replicas });
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

    /// The node's `/wire` socket URL and its https origin (the blob store).
    fn dial(&self) -> Result<(String, String), String> {
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
        let origin = format!("{}://{host}", if plain { "http" } else { "https" });
        let wire = format!("{}://{host}/wire", if plain { "ws" } else { "wss" });
        Ok((wire, origin))
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

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(node: &str) -> Opts {
        Opts { node: Some(node.into()), ..Opts::default() }
    }

    #[test]
    fn the_key_never_crosses_the_network_in_plain_text() {
        assert_eq!(opts("http://localhost:4000").dial().unwrap(), ("ws://localhost:4000/wire".to_owned(), "http://localhost:4000".to_owned()));
        assert_eq!(opts("https://node.example").dial().unwrap(), ("wss://node.example/wire".to_owned(), "https://node.example".to_owned()));
        for bad in ["http://node.example", "ws://10.0.0.1:4000", "http://localhost:4000@evil.example", "https://u:p@node.example"] {
            assert!(opts(bad).dial().is_err(), "{bad}");
        }
    }

    #[test]
    fn a_key_in_argv_is_refused() {
        assert!(Opts::parse(&["--key".into(), "hm_x".into()]).is_err());
        assert!(Opts::parse(&["--bogus".into(), "x".into()]).is_err());
    }
}
