mod herdr;
mod server;
mod session;

use anyhow::{Context as _, Result, bail};
use clap::Parser;
use std::net::SocketAddr;

#[derive(Parser)]
#[command(version, about = "Companion Gateway: serves herdr-core sessions to the Companion App over the tailnet")]
struct Args {
    /// Address to listen on. Defaults to this Mac's tailnet IPv4, port 7420.
    #[arg(long, env = "COMPANION_LISTEN")]
    listen: Option<SocketAddr>,

    /// Bearer token the app must present. Generated and printed when unset.
    #[arg(long, env = "COMPANION_TOKEN", hide_env_values = true)]
    token: Option<String>,

    /// The hc binary used to reach the local herdr-core.
    #[arg(long, env = "COMPANION_HC", default_value = "hc")]
    hc: String,
}

const DEFAULT_PORT: u16 = 7420;

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let listen = match args.listen {
        Some(addr) => addr,
        None => SocketAddr::new(tailnet_ip().await?, DEFAULT_PORT),
    };
    let token = match args.token {
        Some(token) if !token.is_empty() => token,
        _ => {
            let token = random_token()?;
            eprintln!("No token given; generated one for this run:\n  COMPANION_TOKEN={token}");
            token
        }
    };

    let view = herdr::spawn(args.hc);
    server::serve(listen, token, view).await
}

/// This Mac's tailnet IPv4, so the Gateway is not reachable from the plain LAN.
async fn tailnet_ip() -> Result<std::net::IpAddr> {
    let out = tokio::process::Command::new("tailscale")
        .args(["ip", "-4"])
        .output()
        .await
        .context("running `tailscale ip -4` (pass --listen to skip)")?;
    if !out.status.success() {
        bail!("`tailscale ip -4` failed: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    let text = String::from_utf8(out.stdout)?;
    let first = text.lines().next().unwrap_or_default().trim();
    first.parse().with_context(|| format!("unexpected `tailscale ip -4` output: {first:?}"))
}

fn random_token() -> Result<String> {
    use std::io::Read as _;
    let mut bytes = [0u8; 24];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
