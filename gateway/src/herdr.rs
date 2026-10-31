//! One plain-mode connection to the local herdr-core through `hc connect`:
//! `hello`, then `events.subscribe`, applying events to a snapshot of terminals.

use crate::session::Session;
use anyhow::{Context as _, Result, anyhow, bail};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::process::Command;
use tokio::sync::watch;

/// What the Gateway currently knows about the core, as the app sees it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CoreView {
    /// The core's name for this Mac, once connected.
    pub core: Option<String>,
    pub sessions: Vec<Session>,
}

impl CoreView {
    pub fn connected(&self) -> bool {
        self.core.is_some()
    }
}

/// Keeps a core connection alive in the background, reconnecting after loss.
pub fn spawn(hc: String) -> watch::Receiver<CoreView> {
    let (tx, rx) = watch::channel(CoreView::default());
    tokio::spawn(async move {
        loop {
            if let Err(err) = follow(&hc, &tx).await {
                eprintln!("core: {err:#}");
            }
            tx.send_replace(CoreView::default());
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
    rx
}

async fn follow(hc: &str, tx: &watch::Sender<CoreView>) -> Result<()> {
    let mut child = Command::new(hc)
        .arg("connect")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting `{hc} connect`"))?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
    let mut lines = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?).lines();

    for (id, method) in [(1, "hello"), (2, "events.subscribe")] {
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": {}});
        stdin.write_all(format!("{request}\n").as_bytes()).await?;
    }
    stdin.flush().await?;

    let mut core = None;
    let mut terminals = Terminals::default();
    while let Some(line) = lines.next_line().await? {
        let message: Value = serde_json::from_str(&line).context("core sent invalid JSON")?;
        if let Some(error) = message.get("error") {
            bail!("core refused request {}: {error}", message["id"]);
        }
        match (message["id"].as_u64(), message["method"].as_str()) {
            (Some(1), _) => {
                let hello = &message["result"];
                if hello["generation"] != 1 {
                    bail!("unsupported herdr-core protocol generation {}", hello["generation"]);
                }
                core = Some(hello["core"]["name"].as_str().unwrap_or("herdr-core").to_owned());
                continue;
            }
            (Some(2), _) => terminals.reset(&message["result"]["terminals"]),
            (None, Some("event")) => terminals.apply(&message["params"]),
            (None, Some("missed")) => terminals.reset(&message["params"]["terminals"]),
            _ => continue,
        }
        let view = CoreView { core: core.clone(), sessions: terminals.sessions() };
        tx.send_if_modified(|current| {
            let changed = *current != view;
            *current = view;
            changed
        });
    }
    bail!("core connection closed")
}

/// Core terminal records by address, kept current from events.
#[derive(Default)]
struct Terminals(BTreeMap<String, Value>);

impl Terminals {
    fn reset(&mut self, records: &Value) {
        self.0.clear();
        for record in records.as_array().into_iter().flatten() {
            self.insert(record.clone());
        }
    }

    fn insert(&mut self, record: Value) {
        if let Some(address) = record["address"].as_str() {
            self.0.insert(address.to_owned(), record);
        }
    }

    /// Applies one event as `schema/README.md` in herdr-core describes.
    fn apply(&mut self, event: &Value) {
        let Some(address) = event["terminal"].as_str() else { return };
        let data = &event["data"];
        match event["type"].as_str().unwrap_or_default() {
            "created" | "restarted" => self.insert(data.clone()),
            "removed" => {
                self.0.remove(address);
            }
            "labels" => {
                if data["record"].is_object() {
                    self.insert(data["record"].clone());
                } else if let Some(record) = self.record(address) {
                    record.insert("labels".into(), data["labels"].clone());
                }
            }
            kind => {
                let Some(record) = self.record(address) else { return };
                match kind {
                    "finished" => {
                        merge(record, data);
                        record.insert("state".into(), "finished".into());
                        record.remove("foreground");
                    }
                    "lost" => {
                        merge(record, data);
                        record.remove("pid");
                        record.remove("foreground");
                    }
                    // `turn` data also carries the word the turn ended on, which is not the record's state.
                    "turn" => {
                        record.insert("turn".into(), data["turn"].clone());
                    }
                    "foreground" => {
                        record.insert("foreground".into(), data.clone());
                    }
                    "status" | "keep" | "title" | "size" => merge(record, data),
                    _ => {}
                }
            }
        }
    }

    fn record(&mut self, address: &str) -> Option<&mut Map<String, Value>> {
        self.0.get_mut(address)?.as_object_mut()
    }

    fn sessions(&self) -> Vec<Session> {
        self.0.values().filter_map(Session::from_record).collect()
    }
}

fn merge(record: &mut Map<String, Value>, data: &Value) {
    for (key, value) in data.as_object().into_iter().flatten() {
        record.insert(key.clone(), value.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn live(address: &str) -> Value {
        json!({"address": address, "state": "live", "cwd": "/", "foreground": {"name": "zsh", "cwd": "/"}})
    }

    #[test]
    fn events_update_the_snapshot() {
        let mut terminals = Terminals::default();
        terminals.reset(&json!([live("t1"), live("t2")]));

        terminals.apply(&json!({"type": "status", "terminal": "t1",
            "data": {"status": {"state": "working", "app": "claude"}, "records": {}, "reported": true}}));
        terminals.apply(&json!({"type": "turn", "terminal": "t1", "data": {"turn": 3, "state": "idle"}}));
        terminals.apply(&json!({"type": "finished", "terminal": "t2",
            "data": {"reason": "exited", "exit_code": 0, "signal": null, "finished_ms": 1}}));
        terminals.apply(&json!({"type": "created", "terminal": "vps/t9", "data": live("vps/t9")}));

        let sessions = terminals.sessions();
        let ids: Vec<_> = sessions.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["t1", "vps/t9"]);
        assert_eq!(sessions[0].status.as_ref().unwrap().state, "working");
        assert_eq!(terminals.0["t1"]["state"], "live");
    }

    #[test]
    fn removed_and_unknown_terminals() {
        let mut terminals = Terminals::default();
        terminals.reset(&json!([live("t1")]));
        terminals.apply(&json!({"type": "title", "terminal": "t404", "data": {"title": "x"}}));
        terminals.apply(&json!({"type": "removed", "terminal": "t1", "data": {}}));
        assert!(terminals.sessions().is_empty());
    }
}
