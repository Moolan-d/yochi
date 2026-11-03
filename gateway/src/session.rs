//! The narrow session model the app sees. Core records stay inside the Gateway.

use crate::about::{Repo, TodoNow};
use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Session {
    /// The core's address, opaque to the app (`t3`, `vps-us/t1`).
    pub id: String,
    /// The machine the session runs on, as this core names it; null for this Mac.
    pub machine: Option<String>,
    pub title: String,
    /// What runs in the terminal now (`claude`, `zsh`).
    pub program: Option<String>,
    pub cwd: String,
    pub status: Option<Status>,
    /// When the status word last changed, in ms since the epoch by the Mac's clock.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status_ms: Option<u64>,
    /// The last completed Agent turn, or zero when none has been reported.
    pub turn: u64,
    /// The terminal's grid; the size an observer must render to.
    pub cols: u16,
    pub rows: u16,
    /// The terminal that started this one (a sub-agent's Agent), if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    /// Pinned to the top of the agent lists in Herdr (`herdr.pinned`).
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub pinned: bool,
    /// The turn Herdr's desktop last showed (`herdr.seen`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seen: Option<u64>,
    /// The git repository its folder is in; filled in on the way to the app.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<Repo>,
    /// The to-do a working Claude Code is on; filled in on the way to the app.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub todo: Option<TodoNow>,
    /// Herdr's `where` label, `<space> / <tab>`, used to name spaces.
    #[serde(skip)]
    pub place: Option<String>,
    /// The foreground process, which names an Agent's own session records.
    #[serde(skip)]
    pub pid: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Status {
    /// idle, working, done, blocked or error: the program's own word.
    pub state: String,
    pub app: Option<String>,
    pub message: Option<String>,
    /// permission, question or auth, when blocked.
    pub kind: Option<String>,
}

impl Session {
    /// The app's view of a live core terminal; None for finished ones.
    pub fn from_record(record: &Value) -> Option<Self> {
        if record["state"] != "live" {
            return None;
        }
        let id = record["address"].as_str()?.to_owned();
        let machine = id.rsplit_once('/').map(|(machine, _)| machine.to_owned());
        let foreground = &record["foreground"];
        // The command as started: Claude Code's process is named after its version (`2.1.316`).
        // A terminal just started has no foreground yet; the core's argv names it.
        let program = foreground["argv"][0]
            .as_str()
            .or_else(|| foreground.is_null().then(|| record["argv"][0].as_str()).flatten())
            .and_then(|argv0| argv0.rsplit('/').next())
            .map(|name| name.trim_start_matches('-'))
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
            .or_else(|| text(&foreground["name"]));
        let title = text(&record["name"])
            .or_else(|| text(&record["title"]).map(|title| without_spinner(&title)))
            .or_else(|| program.clone())
            .unwrap_or_else(|| id.clone());
        let cwd = text(&foreground["cwd"])
            .or_else(|| text(&record["cwd"]))
            .unwrap_or_default();
        let status = record["status"].as_object().map(|status| Status {
            state: status.get("state").and_then(Value::as_str).unwrap_or("unknown").to_owned(),
            app: status.get("app").and_then(text),
            message: status.get("msg").and_then(text),
            kind: status.get("kind").and_then(text),
        });
        let size = |key: &str, default| record[key].as_u64().and_then(|n| u16::try_from(n).ok()).unwrap_or(default);
        Some(Session {
            id,
            machine,
            title,
            program,
            cwd,
            status,
            status_ms: record["status_ms"].as_u64(),
            turn: record["turn"].as_u64().unwrap_or(0),
            cols: size("cols", 80),
            rows: size("rows", 24),
            parent: text(&record["parent"]),
            pinned: text(&record["labels"]["herdr.pinned"]).is_some_and(|value| value != "0" && value != "false"),
            seen: text(&record["labels"]["herdr.seen"]).and_then(|turn| turn.parse().ok()),
            repo: None,
            todo: None,
            place: text(&record["labels"]["where"]),
            pid: foreground["pid"].as_u64(),
        })
    }
}

/// Claude Code puts a spinner or a star before its title (`✳ Fix login`).
fn without_spinner(title: &str) -> String {
    let rest = title.trim_start_matches(|c: char| {
        matches!(c, '\u{2800}'..='\u{28FF}' | '✳' | '✶' | '✻' | '✽' | '✢' | '·' | '*') || c.is_whitespace()
    });
    if rest.is_empty() { title.to_owned() } else { rest.to_owned() }
}

/// A non-empty string, or None.
fn text(value: &Value) -> Option<String> {
    value.as_str().filter(|s| !s.is_empty()).map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn remote_live_terminal() {
        let record = json!({
            "address": "vps-us/t1", "state": "live", "name": null, "title": "",
            "cwd": "/root", "cols": 200, "rows": 50, "turn": 4, "status_ms": 1762156800000_u64, "parent": "vps-us/t0",
            "foreground": {"name": "2.1.316", "argv": ["claude", "--resume"], "pid": 42, "cwd": "/root/app"},
            "status": {"state": "blocked", "app": "claude", "kind": "permission", "msg": "Run ls?"},
        });
        let session = Session::from_record(&record).unwrap();
        assert_eq!(session.machine.as_deref(), Some("vps-us"));
        assert_eq!(session.title, "claude");
        assert_eq!(session.program.as_deref(), Some("claude"));
        assert_eq!(session.pid, Some(42));
        assert_eq!(session.cwd, "/root/app");
        assert_eq!((session.cols, session.rows), (200, 50));
        assert_eq!(session.turn, 4);
        assert_eq!(session.status_ms, Some(1_762_156_800_000));
        let json = serde_json::to_value(&session).unwrap();
        assert_eq!((json["status_ms"].as_u64(), json["parent"].as_str()), (Some(1_762_156_800_000), Some("vps-us/t0")));
        let status = session.status.unwrap();
        assert_eq!(status.state, "blocked");
        assert_eq!(status.kind.as_deref(), Some("permission"));
    }

    #[test]
    fn herdr_labels_and_the_title_without_its_spinner() {
        let session = |labels: Value, title: &str| {
            Session::from_record(&json!({"address": "t1", "state": "live", "cwd": "/", "title": title, "labels": labels})).unwrap()
        };
        let pinned = session(json!({"herdr.pinned": "1", "herdr.seen": "31"}), "✳ Fix login");
        assert_eq!((pinned.pinned, pinned.seen, pinned.title.as_str()), (true, Some(31), "Fix login"));
        let json = serde_json::to_value(&pinned).unwrap();
        assert_eq!((json["pinned"].as_bool(), json["seen"].as_u64()), (Some(true), Some(31)));

        let plain = session(json!({"herdr.seen": "0"}), "⠂ 修复 · 登录页");
        assert_eq!((plain.pinned, plain.title.as_str()), (false, "修复 · 登录页"));
        assert!(serde_json::to_value(&plain).unwrap().get("pinned").is_none());
        assert_eq!(session(json!({}), "✳").title, "✳", "nothing but the star stays");
    }

    #[test]
    fn program_is_the_command_as_started() {
        let program = |foreground: Value| {
            Session::from_record(&json!({"address": "t1", "state": "live", "cwd": "/", "foreground": foreground}))
                .unwrap()
                .program
        };
        assert_eq!(program(json!({"name": "zsh", "argv": ["-zsh"]})).as_deref(), Some("zsh"));
        assert_eq!(program(json!({"name": "zsh", "argv": ["/bin/zsh", "-l"]})).as_deref(), Some("zsh"));
        assert_eq!(program(json!({"name": "pi"})).as_deref(), Some("pi"));
        // Just started, before core reports the foreground.
        let started = json!({"address": "t1", "state": "live", "cwd": "/", "argv": ["/Users/me/.local/bin/claude"]});
        assert_eq!(Session::from_record(&started).unwrap().program.as_deref(), Some("claude"));
        let shell = json!({"address": "t1", "state": "live", "cwd": "/", "argv": []});
        assert_eq!(Session::from_record(&shell).unwrap().program, None);
    }

    #[test]
    fn finished_terminal_is_hidden() {
        let record = json!({"address": "t1", "state": "finished", "cwd": "/"});
        assert_eq!(Session::from_record(&record), None);
    }
}
