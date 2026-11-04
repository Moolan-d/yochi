mod about;
mod agent;
mod changes;
mod commands;
mod conversation;
mod core;
mod devices;
mod exec;
mod following;
mod herdr;
mod layout;
mod noise;
mod observe;
mod relay;
mod run;
mod screen;
mod server;
mod service;
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
#[command(version, about = "Yochi: serves herdr-core sessions to the Yochi iPhone app over the tailnet")]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Address to listen on (and to give phones when pairing). Defaults to this
    /// Mac's tailnet IPv4, port 7420.
    #[arg(long, global = true, env = "YOCHI_LISTEN")]
    listen: Option<SocketAddr>,

    /// Where paired devices are kept. Defaults to ~/Library/Application Support/Yochi.
    #[arg(long, global = true, env = "YOCHI_STATE_DIR")]
    state_dir: Option<PathBuf>,

    /// The hc binary used to reach the local herdr-core.
    #[arg(long, global = true, env = "YOCHI_HC", default_value = "hc")]
    hc: String,
}

#[derive(Subcommand)]
enum Command {
    /// Run the Gateway (the default).
    Serve,
    /// Pair a phone: show a single-use code, valid for five minutes.
    Pair {
        /// Also print the pairing link, for the UI tests.
        #[arg(long, hide = true)]
        link: bool,
    },
    /// List paired devices.
    Devices,
    /// Unpair a device; its open connections close within seconds.
    Revoke { id: String },
    /// Reach this Gateway through a Relay when the phone is off the tailnet.
    Relay {
        #[command(subcommand)]
        action: RelayAction,
    },
    /// Run the Gateway at login, as a LaunchAgent.
    Service {
        #[command(subcommand)]
        action: ServiceAction,
        /// The LaunchAgent's label; another one can try a second Gateway alongside.
        #[arg(long, default_value = service::LABEL, global = true, hide = true)]
        label: String,
    },
}

#[derive(Subcommand)]
enum RelayAction {
    /// Use the relay at this address (https://…); the running Gateway connects
    /// within seconds. Phones learn it the next time they connect on the tailnet.
    Use {
        url: String,
        /// The relay's registration key.
        #[arg(long, env = "YOCHI_RELAY_KEY", hide_env_values = true)]
        key: Option<String>,
    },
    /// Stop using a relay. Phones then reach this Gateway only on the tailnet.
    Off,
    /// Show the relay in use and whether the Gateway is connected to it.
    Status,
}

#[derive(Subcommand)]
enum ServiceAction {
    /// Install (or update) the LaunchAgent and start it.
    Install,
    /// Stop the LaunchAgent and remove it.
    Uninstall,
    /// Show whether the LaunchAgent is installed and running.
    Status,
}

const DEFAULT_PORT: u16 = 7420;

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let store = Store::open(match &args.state_dir {
        Some(dir) => dir.clone(),
        None => Store::default_dir()?,
    })?;
    match args.command.unwrap_or(Command::Serve) {
        Command::Serve => {
            let listen = listen_addr(args.listen).await?;
            let view = herdr::spawn(args.hc.clone());
            server::serve(listen, store, args.hc, view).await
        }
        Command::Pair { link } => pair(&store, listen_addr(args.listen).await?, link).await,
        Command::Devices => {
            list(&store.devices()?);
            Ok(())
        }
        Command::Revoke { id } => match store.revoke(&id)? {
            Some(device) => {
                println!("Unpaired {} ({}). Its open connections close within seconds.", device.name, device.id);
                Ok(())
            }
            None => bail!("no paired device {id:?}; see `yochi devices`"),
        },
        Command::Relay { action } => relay_command(&store, action),
        Command::Service { action, label } => match action {
            ServiceAction::Install => install(&label, args.listen, args.state_dir, &args.hc).await,
            ServiceAction::Uninstall => {
                if label == service::LABEL && service::uninstall(service::LEGACY_LABEL)? {
                    println!("Stopped and removed the old LaunchAgent {}.", service::LEGACY_LABEL);
                }
                if service::uninstall(&label)? {
                    println!("Stopped and removed the LaunchAgent {label}.");
                } else {
                    println!("The LaunchAgent {label} was not installed.");
                }
                Ok(())
            }
            ServiceAction::Status => status(&label, args.listen).await,
        },
    }
}

async fn install(label: &str, listen: Option<SocketAddr>, state_dir: Option<PathBuf>, hc: &str) -> Result<()> {
    let agent = service::Agent {
        label: label.into(),
        exe: std::env::current_exe()?.canonicalize()?,
        hc: service::which(hc)?,
        tailscale: service::which("tailscale")?,
        listen,
        state_dir,
        log: service::default_log()?,
    };
    let addr = listen_addr(listen).await?;
    if label == service::LABEL && service::uninstall(service::LEGACY_LABEL)? {
        println!("Stopped and removed the old LaunchAgent {}.", service::LEGACY_LABEL);
        // bootout returns before the old Gateway lets go of the port.
        for _ in 0..20 {
            if !answering(addr).await {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }
    // The LaunchAgent would only crash-loop on a port another Gateway holds.
    if service::status(label)?.running.is_none() && answering(addr).await {
        bail!("a Gateway is already listening at {addr}; stop it first, then install");
    }
    if agent.exe.components().any(|part| part.as_os_str() == "target") {
        eprintln!("Note: running from a cargo build directory; the LaunchAgent picks up rebuilds only when it restarts.");
        eprintln!("`cargo install --path gateway` gives it a stable copy.\n");
    }
    let plist = service::install(&agent)?;
    println!("Installed {}", plist.display());
    for _ in 0..20 {
        if answering(addr).await {
            println!("The Gateway is running at {addr} and will start again at login.");
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    bail!("the Gateway did not start listening at {addr}; see {}", agent.log.display())
}

async fn status(label: &str, listen: Option<SocketAddr>) -> Result<()> {
    let status = service::status(label)?;
    let Some(plist) = status.plist else {
        println!("The LaunchAgent {label} is not installed; `yochi service install` installs it.");
        return Ok(());
    };
    println!("Installed  {}", plist.display());
    match (status.running, status.last_exit) {
        (Some(pid), _) => println!("Running    pid {pid}"),
        (None, Some(code)) => println!("Stopped    last exit code {code}"),
        (None, None) => println!("Stopped"),
    }
    match listen_addr(listen).await {
        Ok(addr) if answering(addr).await => println!("Listening  {addr}"),
        Ok(addr) => println!("Listening  nothing at {addr}"),
        Err(err) => println!("Listening  unknown ({err:#})"),
    }
    println!("Log        {}", service::default_log()?.display());
    Ok(())
}

async fn answering(addr: SocketAddr) -> bool {
    tokio::time::timeout(Duration::from_secs(1), tokio::net::TcpStream::connect(addr))
        .await
        .is_ok_and(|connected| connected.is_ok())
}

fn relay_command(store: &Store, action: RelayAction) -> Result<()> {
    let dir = store.dir();
    match action {
        RelayAction::Use { url, key } => {
            let mut config = relay::Config::new(&url, key)?;
            // The same route keeps phones that already know it working.
            if let Some(old) = relay::Config::load(dir)? {
                config.route = old.route;
            }
            config.save(dir)?;
            println!("Using the relay at {}.", config.url);
            println!("The running Gateway connects within seconds; check with `yochi relay status`.");
            println!("Paired phones pick it up the next time they connect on the tailnet.");
        }
        RelayAction::Off => {
            if relay::Config::remove(dir)? {
                println!("No longer using a relay; the running Gateway disconnects within seconds.");
            } else {
                println!("No relay was in use.");
            }
        }
        RelayAction::Status => {
            let Some(config) = relay::Config::load(dir)? else {
                println!("No relay in use; `yochi relay use <url>` sets one.");
                return Ok(());
            };
            println!("Relay      {}", config.url);
            println!("Key        {}", if config.key.is_some() { "set" } else { "none" });
            let fresh = |status: &relay::Status| devices::now().saturating_sub(status.at) <= 3 * relay::Status::EVERY.as_secs();
            match relay::Status::load(dir) {
                Some(status) if status.url == config.url && status.connected && fresh(&status) => println!("Connected  yes"),
                Some(status) if status.url == config.url && !status.connected => {
                    println!("Connected  no, {} ago{}", ago(devices::now().saturating_sub(status.at)), status.error.map(|e| format!(": {e}")).unwrap_or_default())
                }
                _ => println!("Connected  unknown; is the Gateway running?"),
            }
            let enrolled = store.devices()?.iter().filter(|device| device.uses_relay()).count();
            println!("Phones     {enrolled} can use it");
        }
    }
    Ok(())
}

/// A query value with everything but unreserved characters escaped.
fn query_value(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The pairing link. With a relay in use it is link v2 (ADR 0006): the phone
/// can also pair through the relay, with the link secret as its psk.
fn invite(store: &Store, listen: SocketAddr, code: &str) -> Result<String> {
    Ok(match (relay::Config::load(store.dir())?, store.offer_secret()?) {
        (Some(config), Some(secret)) => format!(
            "yochi://pair?v=2&host={listen}&code={code}&key={}&relay={}&route={}&secret={}",
            devices::b64(&store.gateway_key()?.public),
            query_value(&config.url),
            config.route,
            devices::b64(&secret),
        ),
        _ => format!("yochi://pair?host={listen}&code={code}"),
    })
}

async fn pair(store: &Store, listen: SocketAddr, link: bool) -> Result<()> {
    if !answering(listen).await {
        eprintln!("Note: no Gateway is answering at {listen}; start it (`yochi`) before the phone pairs.\n");
    }
    let before: HashSet<String> = store.devices()?.into_iter().map(|device| device.id).collect();
    let code = store.offer()?;
    let invite = invite(store, listen, &code)?;

    println!("{}", qr(&invite)?);
    println!("Scan with the iPhone camera, or enter these in Yochi:");
    println!("  Address  {listen}");
    println!("  Code     {}\n", devices::display_code(&code));
    if link {
        println!("  Link     {invite}\n");
    }
    println!("A paired phone can watch and type into every session this Gateway serves,");
    println!("which means running anything your account can on this Mac and its machines.");
    println!("Unpair later with `yochi revoke <id>`.\n");
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
            bail!("the code expired or took too many wrong attempts; run `yochi pair` again");
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
        println!("No paired devices. Pair one with `yochi pair`.");
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pairing_link_carries_the_relay_once_one_is_in_use() {
        let dir = std::env::temp_dir().join(format!("yochi-invite-{}", std::process::id()));
        let store = Store::open(dir.clone()).unwrap();
        let listen: SocketAddr = "100.64.0.1:7420".parse().unwrap();
        let code = store.offer().unwrap();
        assert_eq!(invite(&store, listen, &code).unwrap(), format!("yochi://pair?host=100.64.0.1:7420&code={code}"));

        let config = relay::Config::new("https://relay.example.com", None).unwrap();
        config.save(&dir).unwrap();
        let link = invite(&store, listen, &code).unwrap();
        let secret = devices::b64(&store.offer_secret().unwrap().unwrap());
        let key = devices::b64(&store.gateway_key().unwrap().public);
        std::fs::remove_dir_all(dir).unwrap();
        assert_eq!(
            link,
            format!(
                "yochi://pair?v=2&host=100.64.0.1:7420&code={code}&key={key}&relay=https%3A%2F%2Frelay.example.com&route={}&secret={secret}",
                config.route
            )
        );
    }
}
