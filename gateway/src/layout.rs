//! Herdr's spaces and tabs, from the `herdr-app` document each machine's core
//! keeps for the Herdr desktop app. Read-only: the Gateway never writes it.

use crate::session::Session;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;

pub const DOCUMENT: &str = "herdr-app";

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Space {
    /// Opaque, unique across machines (`vps-us/sp…` for a remote one).
    pub id: String,
    /// The machine it lives on, null for this Mac.
    pub machine: Option<String>,
    pub name: String,
    /// The folder Herdr starts the space's terminals in; empty if unknown.
    pub folder: String,
    pub tabs: Vec<Tab>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Tab {
    pub id: String,
    pub name: String,
    /// Live session ids in pane order, then sub-agents started from them.
    pub sessions: Vec<String>,
}

/// One machine's spaces as its document lists them: names as given (empty
/// when nobody named them), terminals qualified with the machine.
pub fn read(document: &Value, machine: Option<&str>) -> Vec<Space> {
    let qualify = |id: &str| match machine {
        Some(machine) => format!("{machine}/{id}"),
        None => id.to_owned(),
    };
    let text = |value: &Value| value.as_str().unwrap_or_default().to_owned();
    document["spaces"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|space| Space {
            id: qualify(space["id"].as_str().unwrap_or_default()),
            machine: machine.map(str::to_owned),
            name: text(&space["name"]),
            folder: text(&space["folder"]),
            tabs: space["tabs"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|tab| {
                    let mut terminals = Vec::new();
                    collect_terminals(&tab["root"], &mut terminals);
                    Tab {
                        id: qualify(tab["id"].as_str().unwrap_or_default()),
                        name: text(&tab["name"]),
                        sessions: terminals.iter().map(|t| qualify(t)).collect(),
                    }
                })
                .collect(),
        })
        .collect()
}

/// Terminal addresses in a pane tree, in layout order.
fn collect_terminals(node: &Value, out: &mut Vec<String>) {
    if let Some(terminal) = node["content"]["terminal"].as_str() {
        out.push(terminal.to_owned());
    }
    for child in node["children"].as_array().into_iter().flatten() {
        collect_terminals(child, out);
    }
}

/// The spaces the app shows: only live sessions, sub-agents beside the
/// terminal that started them, Herdr's automatic names filled in, and spaces
/// or tabs left empty dropped.
pub fn arrange(spaces: Vec<Space>, sessions: &[Session]) -> Vec<Space> {
    let live: HashMap<&str, &Session> = sessions.iter().map(|s| (s.id.as_str(), s)).collect();
    let mut tab_of: HashMap<String, (usize, usize)> = HashMap::new();
    let mut spaces = spaces;
    for (s, space) in spaces.iter_mut().enumerate() {
        for (t, tab) in space.tabs.iter_mut().enumerate() {
            tab.sessions.retain(|id| live.contains_key(id.as_str()));
            for id in &tab.sessions {
                tab_of.insert(id.clone(), (s, t));
            }
        }
    }
    // Sub-agents aren't in the layout; they belong where their parent is.
    for session in sessions {
        if tab_of.contains_key(&session.id) {
            continue;
        }
        let mut parent = session.parent.as_deref();
        for _ in 0..32 {
            let Some(id) = parent else { break };
            if let Some(&(s, t)) = tab_of.get(id) {
                spaces[s].tabs[t].sessions.push(session.id.clone());
                break;
            }
            parent = live.get(id).and_then(|p| p.parent.as_deref());
        }
    }

    for space in &mut spaces {
        for (index, tab) in space.tabs.iter_mut().enumerate() {
            if tab.name.is_empty() {
                tab.name = (index + 1).to_string();
            }
        }
        space.tabs.retain(|tab| !tab.sessions.is_empty());
        if space.name.is_empty() {
            space.name = automatic_name(space, &live);
        }
    }
    spaces.retain(|space| !space.tabs.is_empty());
    spaces
}

/// Herdr names an unnamed space after its first terminal's checkout and
/// writes `<space> / <tab>` into each terminal's `where` label; use that,
/// else the first terminal's folder.
fn automatic_name(space: &Space, live: &HashMap<&str, &Session>) -> String {
    for tab in &space.tabs {
        for id in &tab.sessions {
            let place = live.get(id.as_str()).and_then(|s| s.place.as_deref());
            if let Some(name) = place.and_then(|p| p.strip_suffix(&format!(" / {}", tab.name))) {
                return name.to_owned();
            }
        }
    }
    let cwd = space.tabs[0].sessions.first().and_then(|id| live.get(id.as_str())).map_or("", |s| s.cwd.as_str());
    cwd.trim_end_matches('/').rsplit('/').next().filter(|name| !name.is_empty()).unwrap_or("~").to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn session(id: &str, parent: Option<&str>, place: Option<&str>) -> Session {
        Session::from_record(&json!({
            "address": id, "state": "live", "cwd": "/opt/demo/app", "parent": parent,
            "labels": {"where": place},
        }))
        .unwrap()
    }

    fn document() -> Value {
        json!({"spaces": [
            {"id": "sp1", "name": "", "folder": "/opt/demo", "tabs": [
                {"id": "tb1", "name": "", "root": {"type": "row", "children": [
                    {"type": "block", "content": {"terminal": "t3"}},
                    {"type": "column", "children": [
                        {"type": "block", "content": {"terminal": "t4"}},
                        {"type": "block", "content": {"mod": "files"}},
                    ]},
                ]}},
                {"id": "tb2", "name": "logs", "root": {"type": "row", "children": [
                    {"type": "block", "content": {"terminal": "t9"}},
                ]}},
            ]},
            {"id": "sp2", "name": "infra", "tabs": [
                {"id": "tb3", "name": "", "root": {"type": "block", "content": {"terminal": "t5"}}},
            ]},
        ]})
    }

    #[test]
    fn reads_terminals_in_layout_order() {
        let spaces = read(&document(), Some("vps"));
        assert_eq!(spaces[0].id, "vps/sp1");
        assert_eq!(spaces[0].machine.as_deref(), Some("vps"));
        assert_eq!(spaces[0].folder, "/opt/demo");
        assert_eq!(spaces[1].folder, "");
        assert_eq!(spaces[0].tabs[0].sessions, ["vps/t3", "vps/t4"]);
        assert_eq!(spaces[1].tabs[0].sessions, ["vps/t5"]);
        assert!(read(&Value::Null, None).is_empty());
    }

    #[test]
    fn arranges_live_sessions_with_names() {
        let sessions = [
            session("t3", None, Some("app / 1")),
            session("t4", None, None),
            session("t7", Some("t4"), None),
            session("t8", Some("t7"), None),
            session("t5", None, None),
            session("t6", None, None),
        ];
        let spaces = arrange(read(&document(), None), &sessions);
        assert_eq!(spaces.len(), 2);
        assert_eq!(spaces[0].name, "app");
        // The logs tab has no live terminal (t9 is gone), so it is dropped.
        assert_eq!(spaces[0].tabs.len(), 1);
        assert_eq!(spaces[0].tabs[0].name, "1");
        assert_eq!(spaces[0].tabs[0].sessions, ["t3", "t4", "t7", "t8"]);
        assert_eq!(spaces[1].name, "infra");
        // t6 is in no space; the app lists it apart.
        assert!(spaces.iter().flat_map(|s| &s.tabs).all(|t| !t.sessions.contains(&"t6".to_owned())));
    }

    #[test]
    fn unnamed_space_without_a_where_label_uses_the_folder() {
        let spaces = arrange(read(&document(), None), &[session("t5", None, None), session("t3", None, None)]);
        assert_eq!(spaces[0].name, "app");
    }
}
