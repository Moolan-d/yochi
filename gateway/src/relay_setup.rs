//! `yochi relay setup` and `yochi relay rotate` (ADR 0006): deploys the
//! Cloudflare Worker edition of the relay with the user's own wrangler login,
//! then points this Gateway at it.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail};
use serde_json::{Value, json};

use crate::devices::{b64, now, random_bytes};
use crate::relay;

/// The Worker, built into the binary so an installed `yochi` deploys the
/// relay it speaks to.
const WORKER: &str = include_str!("../../relay/cloudflare/worker.mjs");
const SHARED: &str = include_str!("../../relay/shared.mjs");
/// Kept in step with `relay/wrangler.jsonc` (a test checks).
const COMPATIBILITY_DATE: &str = "2026-06-01";
/// An exact wrangler, so a deploy today and one next year build the same.
const WRANGLER: &str = "wrangler@4.157.0";

/// How to run wrangler: `npx --yes wrangler@…`, or another program (tests).
pub struct Wrangler {
    program: Vec<String>,
}

impl Wrangler {
    /// `YOCHI_WRANGLER` runs another program in its place, for tests.
    pub fn from_env() -> Self {
        match std::env::var("YOCHI_WRANGLER") {
            Ok(program) if !program.is_empty() => Self { program: vec![program] },
            _ => Self { program: vec!["npx".into(), "--yes".into(), WRANGLER.into()] },
        }
    }

    fn command(&self, dir: &Path, args: &[&str]) -> Command {
        let mut command = Command::new(&self.program[0]);
        command.args(&self.program[1..]).args(args).current_dir(dir);
        command
    }

    /// With the user's terminal, so wrangler can ask and show its progress.
    fn run(&self, dir: &Path, args: &[&str]) -> Result<()> {
        let status = self.command(dir, args).status().with_context(|| self.missing())?;
        if !status.success() {
            bail!("`wrangler {}` failed", args.join(" "));
        }
        Ok(())
    }

    fn output(&self, dir: &Path, args: &[&str]) -> Result<String> {
        let out = self.command(dir, args).stdin(Stdio::null()).output().with_context(|| self.missing())?;
        Ok(format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
    }

    fn missing(&self) -> String {
        if self.program[0] == "npx" {
            "running npx; the relay deploys with Node.js 20 or later (`brew install node`)".into()
        } else {
            format!("running {}", self.program[0])
        }
    }
}

pub struct Options {
    /// The Worker's name in the Cloudflare account.
    pub name: String,
    /// A hostname in a zone of the same account (`relay.example.com`); without
    /// one the relay is at `<name>.<account>.workers.dev`.
    pub domain: Option<String>,
    /// How long to wait for the running Gateway to connect.
    pub wait: Duration,
}

/// Deploys the relay to the user's Cloudflare account and uses it.
pub fn setup(dir: &Path, options: &Options, wrangler: &Wrangler) -> Result<relay::Config> {
    if let Some(domain) = &options.domain
        && (domain.contains("://") || domain.contains('/') || !domain.contains('.'))
    {
        bail!("--domain takes a hostname like relay.example.com, not {domain:?}");
    }
    let work = write_worker(dir, options)?;

    println!("Checking the Cloudflare login…");
    if !wrangler.output(&work, &["whoami"])?.contains("You are logged in") {
        println!("Log in to Cloudflare in the browser that opens; the relay deploys to your account.");
        wrangler.run(&work, &["login"])?;
    }

    println!("Deploying the relay…");
    let output = work.join("wrangler-output.ndjson");
    let _ = std::fs::remove_file(&output);
    let status = wrangler
        .command(&work, &["deploy"])
        .env("WRANGLER_OUTPUT_FILE_PATH", &output)
        .status()
        .with_context(|| wrangler.missing())?;
    if !status.success() {
        bail!("`wrangler deploy` failed");
    }
    let url = match &options.domain {
        Some(domain) => format!("https://{domain}"),
        None => deployed_url(&std::fs::read_to_string(&output).unwrap_or_default()).context(
            "wrangler did not say where the relay is; find its address in the Cloudflare dashboard and run `yochi relay use <url> --key …`",
        )?,
    };

    // The Worker turns every Gateway away until this secret exists.
    println!("Setting the registration key…");
    let key = b64(&random_bytes::<32>()?);
    let mut secret = wrangler
        .command(&work, &["secret", "put", "RELAY_REGISTRATION_KEY"])
        .stdin(Stdio::piped())
        .spawn()
        .with_context(|| wrangler.missing())?;
    {
        use std::io::Write as _;
        let mut stdin = secret.stdin.take().context("wrangler's input")?;
        stdin.write_all(format!("{key}\n").as_bytes())?;
    }
    if !secret.wait()?.success() {
        bail!("`wrangler secret put` failed");
    }

    let config = use_relay(dir, &url, Some(key))?;
    println!("Using the relay at {}.", config.url);
    if wait_until_connected(dir, &config.url, options.wait) {
        println!("The Gateway is connected to it.");
    } else if !options.wait.is_zero() {
        println!("The Gateway has not connected yet; check with `yochi relay status` (is it running?).");
    }
    println!("Paired phones pick it up the next time they connect on the tailnet.");
    Ok(config)
}

/// Points the Gateway at `url`, keeping the route phones already know.
pub fn use_relay(dir: &Path, url: &str, key: Option<String>) -> Result<relay::Config> {
    let mut config = relay::Config::new(url, key)?;
    if let Some(old) = relay::Config::load(dir)? {
        config.route = old.route;
    }
    config.save(dir)?;
    Ok(config)
}

/// A new route token: the old one, and pairing links that carry it, stop
/// working. Phones learn the new one on the tailnet.
pub fn rotate(dir: &Path) -> Result<relay::Config> {
    let Some(old) = relay::Config::load(dir)? else {
        bail!("no relay in use; `yochi relay setup` deploys one");
    };
    let mut config = relay::Config::new(&old.url, old.key)?;
    while config.route == old.route {
        config = relay::Config::new(&old.url, config.key)?;
    }
    config.save(dir)?;
    Ok(config)
}

/// The Worker's files, where wrangler deploys from: `relay-worker/` in the state directory.
fn write_worker(dir: &Path, options: &Options) -> Result<PathBuf> {
    let work = dir.join("relay-worker");
    std::fs::create_dir_all(work.join("cloudflare"))?;
    std::fs::write(work.join("cloudflare/worker.mjs"), WORKER)?;
    std::fs::write(work.join("shared.mjs"), SHARED)?;
    let config = serde_json::to_vec_pretty(&wrangler_config(options))?;
    std::fs::write(work.join("wrangler.json"), config)?;
    Ok(work)
}

fn wrangler_config(options: &Options) -> Value {
    let mut config = json!({
        "name": options.name,
        "main": "cloudflare/worker.mjs",
        "compatibility_date": COMPATIBILITY_DATE,
        "durable_objects": { "bindings": [{ "name": "TUNNEL", "class_name": "TunnelDO" }] },
        // SQLite-backed Durable Objects run on the Workers Free plan.
        "migrations": [{ "tag": "v1", "new_sqlite_classes": ["TunnelDO"] }],
        // Closed until `secret put` sets the key, a moment after the deploy.
        "vars": { "REQUIRE_REGISTRATION_KEY": "1" },
        "workers_dev": options.domain.is_none(),
    });
    if let Some(domain) = &options.domain {
        config["routes"] = json!([{ "pattern": domain, "custom_domain": true }]);
    }
    config
}

/// The `workers.dev` address in wrangler's output file (one JSON object per line).
fn deployed_url(output: &str) -> Option<String> {
    output
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|entry| entry["type"] == "deploy")
        .flat_map(|entry| entry["targets"].as_array().cloned().unwrap_or_default())
        .filter_map(|target| target.as_str().map(str::to_owned))
        .find(|target| target.starts_with("https://") && target.ends_with(".workers.dev"))
}

/// Whether the running Gateway reports a connection to `url` within `limit`.
fn wait_until_connected(dir: &Path, url: &str, limit: Duration) -> bool {
    let since = now();
    let start = Instant::now();
    loop {
        if let Some(status) = relay::Status::load(dir)
            && status.url == url
            && status.connected
            && status.at >= since
        {
            return true;
        }
        if start.elapsed() >= limit {
            return false;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh state directory, removed when dropped.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("yochi-relay-setup-{}", crate::devices::hex(&random_bytes::<6>().unwrap())));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn options(domain: Option<&str>) -> Options {
        Options { name: "yochi-relay".into(), domain: domain.map(str::to_owned), wait: Duration::ZERO }
    }

    #[test]
    fn the_built_in_worker_matches_the_relay_folder() {
        let jsonc = include_str!("../../relay/wrangler.jsonc");
        assert!(jsonc.contains(&format!("\"compatibility_date\": \"{COMPATIBILITY_DATE}\"")));
        assert!(WORKER.contains("from '../shared.mjs'"), "the worker sits one folder below shared.mjs");
        assert!(SHARED.contains("REQUIRE_REGISTRATION_KEY"));
    }

    #[test]
    fn a_domain_replaces_workers_dev() {
        let config = wrangler_config(&options(None));
        assert_eq!(config["workers_dev"], true);
        assert!(config.get("routes").is_none());
        assert_eq!(config["vars"]["REQUIRE_REGISTRATION_KEY"], "1");

        let config = wrangler_config(&options(Some("relay.example.com")));
        assert_eq!(config["workers_dev"], false);
        assert_eq!(config["routes"], json!([{ "pattern": "relay.example.com", "custom_domain": true }]));
    }

    #[test]
    fn the_address_comes_from_wranglers_output_file() {
        let output = concat!(
            r#"{"type":"wrangler-session","version":1}"#,
            "\n",
            r#"{"type":"deploy","version":1,"worker_name":"yochi-relay","targets":["https://yochi-relay.someone.workers.dev"]}"#,
            "\n"
        );
        assert_eq!(deployed_url(output).as_deref(), Some("https://yochi-relay.someone.workers.dev"));
        assert_eq!(deployed_url(r#"{"type":"deploy","targets":[]}"#), None);
        assert_eq!(deployed_url("not json"), None);
    }

    /// A stand-in for wrangler that logs what it was asked, in order.
    fn fake_wrangler(dir: &Path, logged_in: bool) -> Wrangler {
        let script = dir.join("wrangler.sh");
        let log = dir.join("wrangler.log");
        let whoami = if logged_in { "You are logged in with an OAuth Token" } else { "You are not authenticated" };
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
echo "$*" >> "{log}"
case "$1" in
whoami) echo "{whoami}" ;;
deploy) echo '{{"type":"deploy","targets":["https://yochi-relay.someone.workers.dev"]}}' > "$WRANGLER_OUTPUT_FILE_PATH" ;;
secret) read key; echo "key $key" >> "{log}" ;;
esac
"#,
                log = log.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        Wrangler { program: vec![script.display().to_string()] }
    }

    #[test]
    fn setup_logs_in_deploys_then_sets_the_key() {
        let dir = TempDir::new();
        let config = setup(dir.path(), &options(None), &fake_wrangler(dir.path(), false)).unwrap();
        assert_eq!(config.url, "https://yochi-relay.someone.workers.dev");
        let key = config.key.clone().unwrap();
        let log = std::fs::read_to_string(dir.path().join("wrangler.log")).unwrap();
        assert_eq!(log, format!("whoami\nlogin\ndeploy\nsecret put RELAY_REGISTRATION_KEY\nkey {key}\n"));
        assert!(relay::Config::load(dir.path()).unwrap() == Some(config.clone()));
        let written: Value = serde_json::from_slice(&std::fs::read(dir.path().join("relay-worker/wrangler.json")).unwrap()).unwrap();
        assert_eq!(written["name"], "yochi-relay");
        assert!(dir.path().join("relay-worker/cloudflare/worker.mjs").exists());

        // Again, logged in and on a domain: the same route, a new key.
        let again = setup(dir.path(), &options(Some("relay.example.com")), &fake_wrangler(dir.path(), true)).unwrap();
        assert_eq!(again.url, "https://relay.example.com");
        assert_eq!(again.route, config.route);
        assert_ne!(again.key, config.key);
    }

    #[test]
    fn a_domain_is_a_bare_hostname() {
        let dir = TempDir::new();
        for bad in ["https://relay.example.com", "relay.example.com/x", "localhost"] {
            assert!(setup(dir.path(), &options(Some(bad)), &fake_wrangler(dir.path(), true)).is_err(), "{bad}");
        }
        assert!(!dir.path().join("wrangler.log").exists(), "nothing ran");
    }

    #[test]
    fn rotating_changes_only_the_route() {
        let dir = TempDir::new();
        assert!(rotate(dir.path()).is_err(), "no relay to rotate");
        let before = use_relay(dir.path(), "https://relay.example.com", Some("k".into())).unwrap();
        let after = rotate(dir.path()).unwrap();
        assert_ne!(after.route, before.route);
        assert_eq!((after.url.as_str(), after.key.as_deref()), ("https://relay.example.com", Some("k")));
        assert!(relay::Config::load(dir.path()).unwrap() == Some(after));
    }
}
