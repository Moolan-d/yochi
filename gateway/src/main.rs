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
mod relay_setup;
mod resume;
mod run;
mod screen;
mod server;
mod service;
mod session;
mod tailnet;
mod transcript;

use anyhow::{Context as _, Result, bail};
use clap::{CommandFactory as _, FromArgMatches as _, Parser, Subcommand};
use devices::{Device, Store};
use std::collections::HashSet;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Parser)]
#[command(
    version,
    about = "Yochi: serves herdr-core sessions to the Yochi iPhone app, on the tailnet or through a Relay"
)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Without a command, the Gateway runs with these.
    #[command(flatten)]
    serve: ServeArgs,

    /// Where paired devices and the relay settings are kept. Defaults to
    /// ~/Library/Application Support/Yochi.
    #[arg(long, global = true, env = "YOCHI_STATE_DIR")]
    state_dir: Option<PathBuf>,
}

#[derive(clap::Args)]
struct ListenArg {
    /// Address to listen on (and to give phones when pairing). Defaults to this
    /// Mac's tailnet IPv4, port 7420.
    #[arg(long, env = "YOCHI_LISTEN")]
    listen: Option<SocketAddr>,
}

#[derive(clap::Args)]
struct ServeArgs {
    #[command(flatten)]
    listen: ListenArg,

    /// The hc binary used to reach the local herdr-core.
    #[arg(long, env = "YOCHI_HC", default_value = "hc")]
    hc: String,
}

#[derive(Subcommand)]
enum Command {
    /// Run the Gateway (the default).
    Serve(ServeArgs),
    /// Pair a phone: show a single-use code, valid for five minutes.
    Pair {
        #[command(flatten)]
        listen: ListenArg,
        /// Also print the pairing link, for the UI tests.
        #[arg(long, hide = true)]
        link: bool,
    },
    /// List paired devices.
    Devices,
    /// Unpair a device; its open connections close within seconds.
    Revoke {
        /// The device's ID, as `yochi devices` lists it.
        id: String,
    },
    /// Reach this Gateway on the tailnet: on by default, whenever this Mac is on it.
    Tailnet {
        #[command(subcommand)]
        action: TailnetAction,
    },
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
enum TailnetAction {
    /// Listen on the tailnet again whenever this Mac is on it.
    On,
    /// Stop listening on the tailnet and close its connections; phones then
    /// reach this Gateway only through a relay.
    Off,
    /// Show whether the tailnet is on, this Mac's address on it, and whether
    /// the Gateway is listening there.
    Status {
        #[command(flatten)]
        listen: ListenArg,
    },
}

#[derive(Subcommand)]
enum RelayAction {
    /// Deploy a relay to your Cloudflare account (Workers, free plan) and use
    /// it. Needs Node.js; wrangler asks you to log in the first time.
    Setup {
        /// Serve it on a hostname in one of your Cloudflare zones
        /// (relay.example.com) instead of *.workers.dev, which some networks block.
        #[arg(long)]
        domain: Option<String>,
        /// The Worker's name in your account.
        #[arg(long, default_value = "yochi-relay")]
        name: String,
    },
    /// Show the relay in use, whether the Gateway is connected to it, and how
    /// many phones can use it.
    Status,
    /// Use a relay you already run; the running Gateway connects within
    /// seconds. Phones learn it the next time they connect on the tailnet.
    Use {
        /// The relay's address, https://…
        url: String,
        /// The relay's registration key.
        #[arg(long, env = "YOCHI_RELAY_KEY", hide_env_values = true)]
        key: Option<String>,
    },
    /// Give this Gateway a new address on the relay. The old one, and pairing
    /// links that carry it, stop working; phones learn the new one on the tailnet.
    Rotate,
    /// Stop using a relay. Phones then reach this Gateway only on the tailnet.
    Off,
}

#[derive(Subcommand)]
enum ServiceAction {
    /// Install (or update) the LaunchAgent and start it. It runs the Gateway
    /// with these settings.
    Install(ServeArgs),
    /// Stop the LaunchAgent and remove it.
    Uninstall,
    /// Show whether the LaunchAgent is installed and running.
    Status {
        #[command(flatten)]
        listen: ListenArg,
    },
}

const DEFAULT_PORT: u16 = 7420;

#[tokio::main]
async fn main() -> Result<()> {
    let args = parse_args();
    let store = Store::open(match &args.state_dir {
        Some(dir) => dir.clone(),
        None => Store::default_dir()?,
    })?;
    match args.command.unwrap_or(Command::Serve(args.serve)) {
        Command::Serve(serve) => {
            let listen = match serve.listen.listen {
                Some(addr) => server::Listen::At(addr),
                None => server::Listen::Tailnet,
            };
            let view = herdr::spawn(serve.hc.clone());
            server::serve(listen, store, serve.hc, view).await
        }
        Command::Pair { listen, link } => pair(&store, listen.listen, link).await,
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
        Command::Tailnet { action } => tailnet_command(&store, action).await,
        Command::Relay { action } => relay_command(&store, action),
        Command::Service { action, label } => match action {
            ServiceAction::Install(serve) => install(&label, serve.listen.listen, args.state_dir, &serve.hc).await,
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
            ServiceAction::Status { listen } => status(&label, listen.listen).await,
        },
    }
}

/// `--listen` and `--hc` before a command would be ignored, so they are refused.
fn parse_args() -> Args {
    let matches = Args::command().get_matches();
    let args = Args::from_arg_matches(&matches).unwrap_or_else(|err| err.exit());
    if let Some((name, _)) = matches.subcommand() {
        for id in ["listen", "hc"] {
            if matches.value_source(id) == Some(clap::parser::ValueSource::CommandLine) {
                Args::command()
                    .error(clap::error::ErrorKind::ArgumentConflict, format!("--{id} before a command has no effect; put it after the command if it takes one (see `yochi {name} --help`)"))
                    .exit();
            }
        }
    }
    args
}

async fn install(label: &str, listen: Option<SocketAddr>, state_dir: Option<PathBuf>, hc: &str) -> Result<()> {
    // Off the tailnet there is no address to check; the Gateway waits for one.
    let dir = state_dir.clone().map_or_else(Store::default_dir, Ok)?;
    let addr = if tailnet::enabled(&dir) { listen_addr(listen).await.ok() } else { None };
    let agent = service::Agent {
        label: label.into(),
        exe: std::env::current_exe()?.canonicalize()?,
        hc: service::which(hc)?,
        tailscale: service::which("tailscale").ok(),
        listen,
        state_dir,
        log: service::default_log()?,
    };
    if label == service::LABEL && service::uninstall(service::LEGACY_LABEL)? {
        println!("Stopped and removed the old LaunchAgent {}.", service::LEGACY_LABEL);
        // bootout returns before the old Gateway lets go of the port.
        if let Some(addr) = addr {
            for _ in 0..20 {
                if !answering(addr).await {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
    }
    // The LaunchAgent would only crash-loop on a port another Gateway holds.
    if let Some(addr) = addr
        && service::status(label)?.running.is_none()
        && answering(addr).await
    {
        bail!("a Gateway is already listening at {addr}; stop it first, then install");
    }
    if agent.exe.components().any(|part| part.as_os_str() == "target") {
        eprintln!("Note: running from a cargo build directory; the LaunchAgent picks up rebuilds only when it restarts.");
        eprintln!("`cargo install --path gateway` gives it a stable copy.\n");
    }
    let plist = service::install(&agent)?;
    println!("Installed {}", plist.display());
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_millis(250)).await;
        match addr {
            Some(addr) if answering(addr).await => {
                println!("The Gateway is running at {addr} and will start again at login.");
                return Ok(());
            }
            None if service::status(label)?.running.is_some() => {
                println!("The Gateway is running and will start again at login.");
                println!("It isn't on the tailnet, so phones reach it only through a relay (`yochi relay status`).");
                return Ok(());
            }
            _ => {}
        }
    }
    match addr {
        Some(addr) => bail!("the Gateway did not start listening at {addr}; see {}", agent.log.display()),
        None => bail!("the Gateway did not start; see {}", agent.log.display()),
    }
}

async fn tailnet_command(store: &Store, action: TailnetAction) -> Result<()> {
    let dir = store.dir();
    match action {
        TailnetAction::On => {
            if tailnet::set(dir, true)? {
                println!("Tailnet on; the running Gateway listens there within seconds, once this Mac is on the tailnet.");
                println!("Phones learn the address the next time they connect, even through a relay.");
            } else {
                println!("The tailnet was already on.");
            }
        }
        TailnetAction::Off => {
            if tailnet::set(dir, false)? {
                println!("Tailnet off; the running Gateway stops listening there and closes its tailnet connections within seconds.");
                if relay::Config::load(dir)?.is_none() {
                    println!("No relay is in use either, so no phone can reach this Gateway now; `yochi relay setup` sets one up.");
                }
            } else {
                println!("The tailnet was already off.");
            }
        }
        TailnetAction::Status { listen } => {
            if !tailnet::enabled(dir) {
                println!("Tailnet    off; `yochi tailnet on` turns it on");
                return Ok(());
            }
            println!("Tailnet    on");
            match listen_addr(listen.listen).await {
                Ok(addr) => {
                    println!("Address    {addr}");
                    println!("Listening  {}", if answering(addr).await { "yes" } else { "no; is the Gateway running?" });
                }
                Err(err) => println!("Address    none, not on the tailnet ({err:#})"),
            }
        }
    }
    Ok(())
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
            // The same route keeps phones that already know it working.
            let config = relay_setup::use_relay(dir, &url, key)?;
            println!("Using the relay at {}.", config.url);
            println!("The running Gateway connects within seconds; check with `yochi relay status`.");
            println!("Paired phones pick it up the next time they connect on the tailnet.");
        }
        RelayAction::Setup { domain, name } => {
            let options = relay_setup::Options { name, domain, wait: Duration::from_secs(30) };
            relay_setup::setup(dir, &options, &relay_setup::Wrangler::from_env())?;
        }
        RelayAction::Rotate => {
            relay_setup::rotate(dir)?;
            println!("This Gateway has a new address on the relay; the running Gateway moves to it within seconds.");
            println!("Phones off the tailnet can't reach it until they next connect on the tailnet.");
            println!("Pairing links shown before now no longer work through the relay.");
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
            match relay::Status::load(dir) {
                _ if relay_connected(dir, &config) => println!("Connected  yes"),
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
/// Off the tailnet (`host` is None) the link has only the way through the relay.
fn invite(store: &Store, host: Option<SocketAddr>, code: &str) -> Result<String> {
    Ok(match (relay::Config::load(store.dir())?, store.offer_secret()?, host) {
        (Some(config), Some(secret), _) => format!(
            "yochi://pair?v=2{}&code={code}&key={}&relay={}&route={}&secret={}",
            host.map(|host| format!("&host={host}")).unwrap_or_default(),
            devices::b64(&store.gateway_key()?.public),
            query_value(&config.url),
            config.route,
            devices::b64(&secret),
        ),
        (_, _, Some(host)) => format!("yochi://pair?host={host}&code={code}"),
        _ => bail!("the link has no way to this Gateway: neither the tailnet nor a relay"),
    })
}

/// The running Gateway reported being connected to this relay a moment ago.
fn relay_connected(dir: &std::path::Path, config: &relay::Config) -> bool {
    relay::Status::load(dir).is_some_and(|status| {
        status.url == config.url && status.connected && devices::now().saturating_sub(status.at) <= 3 * relay::Status::EVERY.as_secs()
    })
}

async fn pair(store: &Store, listen: Option<SocketAddr>, link: bool) -> Result<()> {
    let relay = relay::Config::load(store.dir())?;
    let host = if tailnet::enabled(store.dir()) {
        match listen_addr(listen).await {
            Ok(host) => Some(host),
            Err(err) if relay.is_some() => {
                eprintln!("Note: not on the tailnet ({err:#}); the phone pairs through the relay.\n");
                None
            }
            Err(err) => return Err(err.context("not on the tailnet, and no relay is in use; `yochi relay setup` sets one up")),
        }
    } else {
        None
    };
    match (host, &relay) {
        (None, None) => bail!("the tailnet is off and no relay is in use; `yochi tailnet on` or `yochi relay setup`"),
        (Some(host), _) if !answering(host).await => {
            eprintln!("Note: no Gateway is answering at {host}; start it (`yochi`) before the phone pairs.\n");
        }
        (None, Some(config)) if !relay_connected(store.dir(), config) => {
            eprintln!("Note: the Gateway isn't connected to the relay; start it (`yochi`) before the phone pairs.\n");
        }
        _ => {}
    }
    let before: HashSet<String> = store.devices()?.into_iter().map(|device| device.id).collect();
    let code = store.offer()?;
    let invite = invite(store, host, &code)?;

    println!("{}", qr(&invite)?);
    match host {
        Some(host) => {
            println!("Scan with the iPhone camera, or enter these in Yochi:");
            println!("  Address  {host}");
            println!("  Code     {}\n", devices::display_code(&code));
        }
        None => println!("Scan with the iPhone camera; the phone pairs through the relay.\n"),
    }
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
        assert_eq!(invite(&store, Some(listen), &code).unwrap(), format!("yochi://pair?host=100.64.0.1:7420&code={code}"));
        assert!(invite(&store, None, &code).is_err(), "a link with no way to the Gateway");

        let config = relay::Config::new("https://relay.example.com", None).unwrap();
        config.save(&dir).unwrap();
        let link = invite(&store, Some(listen), &code).unwrap();
        let relay_only = invite(&store, None, &code).unwrap();
        let secret = devices::b64(&store.offer_secret().unwrap().unwrap());
        let key = devices::b64(&store.gateway_key().unwrap().public);
        std::fs::remove_dir_all(dir).unwrap();
        assert_eq!(
            relay_only,
            format!(
                "yochi://pair?v=2&code={code}&key={key}&relay=https%3A%2F%2Frelay.example.com&route={}&secret={secret}",
                config.route
            )
        );
        assert_eq!(
            link,
            format!(
                "yochi://pair?v=2&host=100.64.0.1:7420&code={code}&key={key}&relay=https%3A%2F%2Frelay.example.com&route={}&secret={secret}",
                config.route
            )
        );
    }
}
