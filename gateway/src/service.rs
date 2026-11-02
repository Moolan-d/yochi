//! Runs the Gateway as a per-user LaunchAgent, so it starts at login and comes
//! back after a crash or before Tailscale is up (it exits, launchd retries).

use anyhow::{Context as _, Result, bail};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

pub const LABEL: &str = "dev.companion.gateway";
/// Seconds launchd waits before starting the Gateway again after it exits.
const RETRY_INTERVAL: u32 = 10;

/// Everything the LaunchAgent needs, resolved while the user's shell PATH is
/// still around: launchd starts agents with only /usr/bin:/bin:/usr/sbin:/sbin.
pub struct Agent {
    pub label: String,
    pub exe: PathBuf,
    pub hc: PathBuf,
    pub tailscale: PathBuf,
    pub listen: Option<SocketAddr>,
    pub state_dir: Option<PathBuf>,
    pub log: PathBuf,
}

impl Agent {
    pub fn plist(&self) -> String {
        let mut env = vec![(
            "PATH",
            format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", self.tailscale.parent().unwrap_or(Path::new("/")).display()),
        )];
        env.push(("COMPANION_HC", self.hc.display().to_string()));
        if let Some(listen) = self.listen {
            env.push(("COMPANION_LISTEN", listen.to_string()));
        }
        if let Some(dir) = &self.state_dir {
            env.push(("COMPANION_STATE_DIR", dir.display().to_string()));
        }
        let env: String = env
            .iter()
            .map(|(key, value)| format!("\t\t<key>{key}</key>\n\t\t<string>{}</string>\n", escape(value)))
            .collect();
        let log = escape(&self.log.display().to_string());
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{exe}</string>
		<string>serve</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
{env}	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>{RETRY_INTERVAL}</integer>
	<key>StandardOutPath</key>
	<string>{log}</string>
	<key>StandardErrorPath</key>
	<string>{log}</string>
</dict>
</plist>
"#,
            label = escape(&self.label),
            exe = escape(&self.exe.display().to_string()),
        )
    }
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

pub fn plist_path(label: &str) -> Result<PathBuf> {
    Ok(home()?.join("Library/LaunchAgents").join(format!("{label}.plist")))
}

pub fn default_log() -> Result<PathBuf> {
    Ok(home()?.join("Library/Logs/Companion Gateway/gateway.log"))
}

fn home() -> Result<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from).context("HOME is not set")
}

/// The absolute path of a program on the current PATH.
pub fn which(program: &str) -> Result<PathBuf> {
    if program.contains('/') {
        return std::fs::canonicalize(program).with_context(|| format!("no program at {program}"));
    }
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
        .with_context(|| format!("`{program}` is not on PATH"))
}

/// Writes the plist and (re)loads it, replacing a running instance.
pub fn install(agent: &Agent) -> Result<PathBuf> {
    let plist = plist_path(&agent.label)?;
    std::fs::create_dir_all(plist.parent().unwrap())?;
    if let Some(dir) = agent.log.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let partial = plist.with_extension("plist.partial");
    std::fs::write(&partial, agent.plist())?;
    std::fs::rename(&partial, &plist)?;

    let _ = launchctl(&["bootout", &target(&agent.label)?]);
    // bootout returns before the old instance is gone; bootstrap fails until it is.
    let domain = domain()?;
    let plist_arg = plist.display().to_string();
    let mut tries = 0;
    loop {
        match launchctl(&["bootstrap", &domain, &plist_arg]) {
            Ok(_) => return Ok(plist),
            Err(_) if tries < 10 => {
                tries += 1;
                std::thread::sleep(Duration::from_millis(300));
            }
            Err(err) => return Err(err),
        }
    }
}

/// Stops the agent and removes its plist. False if it was not installed.
pub fn uninstall(label: &str) -> Result<bool> {
    let plist = plist_path(label)?;
    let loaded = launchctl(&["bootout", &target(label)?]).is_ok();
    let existed = plist.exists();
    if existed {
        std::fs::remove_file(&plist)?;
    }
    Ok(loaded || existed)
}

pub struct Status {
    pub plist: Option<PathBuf>,
    pub running: Option<u32>,
    pub last_exit: Option<String>,
}

pub fn status(label: &str) -> Result<Status> {
    let plist = plist_path(label)?;
    let mut status = Status { plist: plist.exists().then_some(plist), running: None, last_exit: None };
    if let Ok(out) = launchctl(&["print", &target(label)?]) {
        for line in out.lines().map(str::trim) {
            if let Some(pid) = line.strip_prefix("pid = ") {
                status.running = pid.parse().ok();
            } else if let Some(code) = line.strip_prefix("last exit code = ") {
                status.last_exit = Some(code.to_string());
            }
        }
    }
    Ok(status)
}

fn launchctl(args: &[&str]) -> Result<String> {
    let out = Command::new("/bin/launchctl").args(args).output().context("running launchctl")?;
    if !out.status.success() {
        bail!(
            "launchctl {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn domain() -> Result<String> {
    let out = Command::new("/usr/bin/id").arg("-u").output().context("running id -u")?;
    Ok(format!("gui/{}", String::from_utf8(out.stdout)?.trim()))
}

fn target(label: &str) -> Result<String> {
    Ok(format!("{}/{label}", domain()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent() -> Agent {
        Agent {
            label: LABEL.into(),
            exe: "/opt/demo/.cargo/bin/companion-gateway".into(),
            hc: "/opt/demo/.local/bin/hc".into(),
            tailscale: "/usr/local/bin/tailscale".into(),
            listen: None,
            state_dir: None,
            log: "/opt/demo/Library/Logs/Companion Gateway/gateway.log".into(),
        }
    }

    #[test]
    fn the_plist_carries_what_launchd_does_not() {
        let plist = agent().plist();
        assert!(plist.contains("<string>/opt/demo/.cargo/bin/companion-gateway</string>\n\t\t<string>serve</string>"));
        assert!(plist.contains("<key>PATH</key>\n\t\t<string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"));
        assert!(plist.contains("<key>COMPANION_HC</key>\n\t\t<string>/opt/demo/.local/bin/hc</string>"));
        assert!(!plist.contains("COMPANION_LISTEN"));
        assert!(!plist.contains("COMPANION_STATE_DIR"));
        assert!(plist.contains("<key>KeepAlive</key>\n\t<true/>"));
    }

    #[test]
    fn explicit_settings_are_kept_and_escaped() {
        let plist = Agent {
            listen: Some("100.64.0.1:7422".parse().unwrap()),
            state_dir: Some("/tmp/a&b<c>".into()),
            ..agent()
        }
        .plist();
        assert!(plist.contains("<key>COMPANION_LISTEN</key>\n\t\t<string>100.64.0.1:7422</string>"));
        assert!(plist.contains("<string>/tmp/a&amp;b&lt;c&gt;</string>"));
    }
}
