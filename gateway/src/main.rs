mod agent;
mod conversation;
mod core;
mod devices;
mod following;
mod herdr;
mod layout;
mod observe;
mod run;
mod server;
mod session;
mod transcript;

use anyhow::{Context as _, Result, bail};
use clap::{Parser, Subcommand};
use devices::{Device, Store};
use std::collections::HashSet;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser)]
#[command(version, about = "Companion Gateway: serves herdr-core sessions to the Companion App over the tailnet")]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Address to listen on (and to give phones when pairing). Defaults to this
    /// Mac's tailnet IPv4, port 7420.
    #[arg(long, global = true, env = "COMPANION_LISTEN")]
    listen: Option<SocketAddr>,

    /// Where paired devices are kept. Defaults to ~/Library/Application Support/Companion Gateway.
    #[arg(long, global = true, env = "COMPANION_STATE_DIR")]
    state_dir: Option<PathBuf>,

    /// The hc binary used to reach the local herdr-core.
    #[arg(long, global = true, env = "COMPANION_HC", default_value = "hc")]
    hc: String,
}

#[derive(Subcommand)]
enum Command {
    /// Run the Gateway (the default).
    Serve,
    /// Pair a phone: show a single-use code, valid for five minutes.
    Pair,
    /// List paired devices.
    Devices,
    /// Unpair a device; its open connections close within seconds.
    Revoke { id: String },
}

const DEFAULT_PORT: u16 = 7420;

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let store = Store::open(match args.state_dir {
        Some(dir) => dir,
        None => Store::default_dir()?,
    })?;
    match args.command.unwrap_or(Command::Serve) {
        Command::Serve => {
            let listen = listen_addr(args.listen).await?;
            let view = herdr::spawn(args.hc.clone());
            server::serve(listen, store, args.hc, view).await
        }
        Command::Pair => pair(&store, listen_addr(args.listen).await?).await,
        Command::Devices => {
            list(&store.devices()?);
            Ok(())
        }
        Command::Revoke { id } => match store.revoke(&id)? {
            Some(device) => {
                println!("Unpaired {} ({}). Its open connections close within seconds.", device.name, device.id);
                Ok(())
            }
            None => bail!("no paired device {id:?}; see `companion-gateway devices`"),
        },
    }
}

async fn pair(store: &Store, listen: SocketAddr) -> Result<()> {
    if tokio::time::timeout(Duration::from_secs(1), tokio::net::TcpStream::connect(listen)).await.map_or(true, |r| r.is_err()) {
        eprintln!("Note: no Gateway is answering at {listen}; start it (`companion-gateway`) before the phone pairs.\n");
    }
    let before: HashSet<String> = store.devices()?.into_iter().map(|device| device.id).collect();
    let code = store.offer()?;
    let invite = format!("companion://pair?host={listen}&code={code}");

    println!("{}", qr(&invite)?);
    println!("Scan with the iPhone camera, or enter these in Companion:");
    println!("  Address  {listen}");
    println!("  Code     {}\n", devices::display_code(&code));
    println!("A paired phone can watch and type into every session this Gateway serves,");
    println!("which means running anything your account can on this Mac and its machines.");
    println!("Unpair later with `companion-gateway revoke <id>`.\n");
    println!("Waiting up to {} minutes…", devices::OFFER_TTL.as_secs() / 60);

    loop {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(1)) => {}
            _ = tokio::signal::ctrl_c() => {
                store.cancel_offer()?;
                bail!("pairing cancelled");
            }
        }
        if let Some(device) = store.devices()?.into_iter().find(|device| !before.contains(&device.id)) {
            println!("Paired {} ({}).", device.name, device.id);
            return Ok(());
        }
        if !store.offer_pending()? {
            bail!("the code expired or took too many wrong attempts; run `companion-gateway pair` again");
        }
    }
}

/// A QR code in half-block characters, black on white whatever the terminal's colors.
fn qr(text: &str) -> Result<String> {
    let code = qrcode::QrCode::new(text.as_bytes())?;
    let width = code.width() as isize;
    let colors = code.to_colors();
    let dark = |x: isize, y: isize| {
        (0..width).contains(&x) && (0..width).contains(&y) && colors[(y * width + x) as usize] == qrcode::Color::Dark
    };
    let quiet = 2;
    let mut out = String::new();
    for y in (-quiet..width + quiet).step_by(2) {
        for x in -quiet..width + quiet {
            // Upper module in the foreground, lower one in the background.
            let fg = if dark(x, y) { 30 } else { 97 };
            let bg = if dark(x, y + 1) { 40 } else { 107 };
            out.push_str(&format!("\x1b[{fg};{bg}m▀"));
        }
        out.push_str("\x1b[0m\n");
    }
    Ok(out)
}

fn list(devices: &[Device]) {
    if devices.is_empty() {
        println!("No paired devices. Pair one with `companion-gateway pair`.");
        return;
    }
    let width = devices.iter().map(|device| device.name.chars().count()).max().unwrap_or(0).max(4);
    println!("{:<8}  {:<width$}  PAIRED", "ID", "NAME");
    for device in devices {
        println!("{:<8}  {:<width$}  {}", device.id, device.name, ago(devices::now().saturating_sub(device.paired_at)));
    }
}

fn ago(seconds: u64) -> String {
    match seconds {
        0..60 => "just now".into(),
        60..3600 => format!("{} min ago", seconds / 60),
        3600..86400 => format!("{} h ago", seconds / 3600),
        _ => format!("{} days ago", seconds / 86400),
    }
}

async fn listen_addr(listen: Option<SocketAddr>) -> Result<SocketAddr> {
    match listen {
        Some(addr) => Ok(addr),
        None => Ok(SocketAddr::new(tailnet_ip().await?, DEFAULT_PORT)),
    }
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
