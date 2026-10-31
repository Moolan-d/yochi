//! One plain-mode connection to the local herdr-core through `hc connect`:
//! `hello`, then `events.subscribe`, applying events to a snapshot of terminals.
//! A subscribed plain connection carries only notifications, so each machine's
//! Herdr layout document is read over a short connection of its own, again
//! whenever the stream says it changed.

use crate::layout::{self, Space};
use crate::session::Session;
use anyhow::{Context as _, Result, anyhow, bail};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, watch};

/// What the Gateway currently knows about the core, as the app sees it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CoreView {
    /// The core's name for this Mac, once connected.
    pub core: Option<String>,
    pub sessions: Vec<Session>,
    /// Herdr's spaces holding those sessions; machines whose layout can't be
    /// read have none, and the app groups their sessions by machine.
    pub spaces: Vec<Space>,
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
    let mut layouts = Layouts::default();
    let (read_tx, mut reads) = mpsc::unbounded_channel();
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { break };
                let message: Value = serde_json::from_str(&line).context("core sent invalid JSON")?;
                if let Some(error) = message.get("error") {
                    bail!("core refused request {}: {error}", message["id"]);
                }
                let params = &message["params"];
                match (message["id"].as_u64(), message["method"].as_str()) {
                    (Some(1), _) => {
                        let hello = &message["result"];
                        if hello["generation"] != 1 {
                            bail!("unsupported herdr-core protocol generation {}", hello["generation"]);
                        }
                        core = Some(hello["core"]["name"].as_str().unwrap_or("herdr-core").to_owned());
                        layouts.supported = hello["methods"].as_array().is_some_and(|m| m.iter().any(|m| m == "doc.get"));
                        continue;
                    }
                    (Some(2), _) => {
                        terminals.reset(&message["result"]["terminals"]);
                        layouts.stale = true;
                    }
                    (None, Some("event")) if params["type"] == "doc" => {
                        layouts.stale |= params["data"]["name"] == layout::DOCUMENT;
                    }
                    (None, Some("event")) => terminals.apply(params),
                    (None, Some("missed")) => {
                        terminals.reset(&params["terminals"]);
                        layouts.stale = true;
                    }
                    _ => continue,
                }
            }
            Some((machine, document)) = reads.recv() => layouts.update(machine, document),
        }
        let machines = layouts.due(&terminals);
        if !machines.is_empty() {
            let (hc, read_tx) = (hc.to_owned(), read_tx.clone());
            tokio::spawn(async move {
                for (machine, document) in read_documents(&hc, &machines).await {
                    let _ = read_tx.send((machine, document));
                }
            });
        }
        let sessions = terminals.sessions();
        let spaces = layout::arrange(layouts.spaces(), &sessions);
        let view = CoreView { core: core.clone(), sessions, spaces };
        tx.send_if_modified(|current| {
            let changed = *current != view;
            *current = view;
            changed
        });
    }
    bail!("core connection closed")
}

type Machine = Option<String>;

/// A document's version and value, or None when it couldn't be read.
type Document = Option<(u64, Value)>;

/// Each machine's layout as last read, and the reads in flight.
#[derive(Default)]
struct Layouts {
    supported: bool,
    /// Read every machine's document again: it changed, or changes were missed.
    stale: bool,
    read: BTreeMap<Machine, (u64, Vec<Space>)>,
    reading: BTreeSet<Machine>,
}

impl Layouts {
    /// Machines to read now: this Mac and each machine with live terminals,
    /// all of them when stale, else only those never read.
    fn due(&mut self, terminals: &Terminals) -> Vec<Machine> {
        if !self.supported {
            return Vec::new();
        }
        let mut machines = terminals.machines();
        machines.insert(None);
        self.read.retain(|machine, _| machines.contains(machine));
        let stale = std::mem::take(&mut self.stale);
        let wanted: Vec<Machine> = machines
            .into_iter()
            .filter(|machine| stale || !(self.read.contains_key(machine) || self.reading.contains(machine)))
            .collect();
        self.reading.extend(wanted.iter().cloned());
        wanted
    }

    /// Keeps the newest version: reads may finish out of order. A machine
    /// that is offline or has no Herdr layout just goes ungrouped.
    fn update(&mut self, machine: Machine, document: Document) {
        self.reading.remove(&machine);
        let (version, spaces) = match document {
            Some((version, value)) => (version, layout::read(&value, machine.as_deref())),
            None if self.read.contains_key(&machine) => return,
            None => (0, Vec::new()),
        };
        if self.read.get(&machine).is_none_or(|(current, _)| version >= *current) {
            self.read.insert(machine, (version, spaces));
        }
    }

    fn spaces(&self) -> Vec<Space> {
        self.read.values().flat_map(|(_, spaces)| spaces.iter().cloned()).collect()
    }
}

/// Reads each machine's layout document over one short connection.
async fn read_documents(hc: &str, machines: &[Machine]) -> Vec<(Machine, Document)> {
    let read = async {
        let mut child = Command::new(hc)
            .arg("connect")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
        let mut lines = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?).lines();
        let mut requests = vec![json!({"jsonrpc": "2.0", "id": 0, "method": "hello", "params": {}})];
        for (id, machine) in (1..).zip(machines) {
            requests.push(json!({"jsonrpc": "2.0", "id": id, "method": "doc.get",
                "params": {"name": layout::DOCUMENT, "on": machine}}));
        }
        for request in requests {
            stdin.write_all(format!("{request}\n").as_bytes()).await?;
        }
        stdin.flush().await?;
        let mut documents = vec![None; machines.len()];
        let mut answered = 0;
        while answered < machines.len() {
            let Some(line) = lines.next_line().await? else { break };
            let reply: Value = serde_json::from_str(&line)?;
            let Some(slot) = reply["id"].as_u64().and_then(|id| documents.get_mut(id.checked_sub(1)? as usize)) else {
                continue;
            };
            answered += 1;
            *slot = reply["result"]["version"].as_u64().map(|version| (version, reply["result"]["value"].clone()));
        }
        anyhow::Ok(documents)
    };
    let documents = match tokio::time::timeout(Duration::from_secs(10), read).await {
        Ok(Ok(documents)) => documents,
        Ok(Err(err)) => {
            eprintln!("core: reading layouts: {err:#}");
            vec![None; machines.len()]
        }
        Err(_) => vec![None; machines.len()],
    };
    machines.iter().cloned().zip(documents).collect()
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

    /// Remote machines with live terminals.
    fn machines(&self) -> BTreeSet<Option<String>> {
        self.0.keys().filter_map(|address| address.rsplit_once('/')).map(|(machine, _)| Some(machine.to_owned())).collect()
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

    #[test]
    fn layouts_are_read_once_per_machine_until_stale() {
        let mut terminals = Terminals::default();
        terminals.reset(&json!([live("t1"), live("vps/t1")]));
        let mut layouts = Layouts::default();
        assert!(layouts.due(&terminals).is_empty(), "core without doc.get");

        layouts.supported = true;
        assert_eq!(layouts.due(&terminals), [None, Some("vps".into())]);
        assert!(layouts.due(&terminals).is_empty(), "already reading");

        layouts.update(None, Some((6, json!({"spaces": [{"id": "sp1", "tabs": []}]}))));
        layouts.update(Some("vps".into()), None);
        assert!(layouts.due(&terminals).is_empty(), "already read, even when unreadable");
        assert_eq!(layouts.spaces().len(), 1);

        layouts.stale = true;
        assert_eq!(layouts.due(&terminals).len(), 2);
        // An older read finishing late, or a failed one, keeps the newer layout.
        layouts.update(None, Some((5, json!({"spaces": []}))));
        layouts.update(None, None);
        assert_eq!(layouts.spaces().len(), 1);

        terminals.apply(&json!({"type": "removed", "terminal": "vps/t1", "data": {}}));
        layouts.due(&terminals);
        assert!(!layouts.read.contains_key(&Some("vps".into())), "machine without terminals forgotten");
    }
}
