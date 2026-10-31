//! The narrow session model the app sees. Core records stay inside the Gateway.

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
    /// The last completed Agent turn, or zero when none has been reported.
    pub turn: u64,
    /// The terminal's grid; the size an observer must render to.
    pub cols: u16,
    pub rows: u16,
    /// The terminal that started this one (a sub-agent's Agent), if any.
    #[serde(skip)]
    pub parent: Option<String>,
    /// Herdr's `where` label, `<space> / <tab>`, used to name spaces.
    #[serde(skip)]
    pub place: Option<String>,
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
        let program = text(&foreground["name"]);
        let title = text(&record["name"])
            .or_else(|| text(&record["title"]))
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
            turn: record["turn"].as_u64().unwrap_or(0),
            cols: size("cols", 80),
            rows: size("rows", 24),
            parent: text(&record["parent"]),
            place: text(&record["labels"]["where"]),
        })
    }
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
            "cwd": "/root", "cols": 200, "rows": 50, "turn": 4,
            "foreground": {"name": "claude", "cwd": "/root/app"},
            "status": {"state": "blocked", "app": "claude", "kind": "permission", "msg": "Run ls?"},
        });
        let session = Session::from_record(&record).unwrap();
        assert_eq!(session.machine.as_deref(), Some("vps-us"));
        assert_eq!(session.title, "claude");
        assert_eq!(session.cwd, "/root/app");
        assert_eq!((session.cols, session.rows), (200, 50));
        assert_eq!(session.turn, 4);
        let status = session.status.unwrap();
        assert_eq!(status.state, "blocked");
        assert_eq!(status.kind.as_deref(), Some("permission"));
    }

    #[test]
    fn finished_terminal_is_hidden() {
        let record = json!({"address": "t1", "state": "finished", "cwd": "/"});
        assert_eq!(Session::from_record(&record), None);
    }
}
