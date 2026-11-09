//! Turns Claude Code transcript lines into what the app shows: messages,
//! tool calls and notices. Only the fields shown are kept; thinking, token
//! usage, request records and attachments never leave the Gateway. Unknown
//! record types are skipped, so a newer Claude Code degrades to fewer items.

use crate::lang::Lang;
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;

const MAX_TEXT: usize = 32 * 1024;
const MAX_OUTPUT: usize = 2000;
const MAX_OUTPUT_LINES: usize = 40;
/// An edit's diff on the phone; the Changes page has the whole file.
const MAX_PATCH_LINES: usize = 200;
const MAX_PATCH_BYTES: usize = 16 * 1024;
/// Items a phone gets when it starts following.
pub const FIRST_ITEMS: usize = 300;

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Item {
    /// What the user typed (or sent from the phone).
    User { id: String, text: String },
    /// The Agent's reply, as Markdown.
    Agent { id: String, text: String },
    /// One tool call; updated in place when its result arrives.
    Tool {
        id: String,
        name: String,
        summary: String,
        state: ToolState,
        #[serde(skip_serializing_if = "Option::is_none")]
        output: Option<String>,
        /// AskUserQuestion's questions and, once answered, the answers.
        #[serde(skip_serializing_if = "Option::is_none")]
        questions: Option<Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        answers: Option<Value>,
        /// Edit, MultiEdit and Write: what changed, once done.
        #[serde(skip_serializing_if = "Option::is_none")]
        edit: Option<Edit>,
        /// Agent (formerly Task): the subtask it runs.
        #[serde(skip_serializing_if = "Option::is_none")]
        agent: Option<Subagent>,
    },
    /// A slash command run in Claude Code, with what it printed.
    Command { id: String, name: String, output: Option<String> },
    /// Something that happened to the conversation (compacted, interrupted, API error).
    Notice {
        id: String,
        text: String,
        /// `interrupted` or `compacted` when the Gateway wrote `text`, for the
        /// app to say in its own words; none for an API error's own text.
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<&'static str>,
    },
    /// A subagent or background task reporting back to the Agent. Claude Code
    /// files it as a user message; it is not what the user typed.
    Task {
        id: String,
        summary: String,
        state: ToolState,
        /// The subagent's report, as Markdown; background commands have none.
        #[serde(skip_serializing_if = "Option::is_none")]
        text: Option<String>,
    },
    /// The Agent's to-do list as of these TaskCreate, TaskUpdate or TodoWrite
    /// calls; back-to-back updates share one item.
    Todos { id: String, items: Vec<Todo> },
    /// A message between Agents: one this Agent sent with SendMessage, or one
    /// another Agent sent it. Never what the user typed.
    Peer {
        id: String,
        direction: Direction,
        /// The other Agent: a subtask's or session's name; None when unknown.
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        text: String,
        state: ToolState,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Edit {
    pub path: String,
    pub added: u64,
    pub deleted: u64,
    /// Unified diff hunks (`@@ -a,b +c,d @@` and their lines), no file headers.
    pub patch: String,
    /// Write made a new file; the patch is its text.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub created: bool,
    pub truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Subagent {
    pub name: String,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// When the Agent called it, by the transcript's clock.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// Runs on after the call returns; a task notification ends it.
    pub background: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Todo {
    /// TaskCreate's task id, which TaskUpdate names.
    #[serde(skip)]
    key: String,
    pub text: String,
    /// The `activeForm`: what the Agent is doing while it is in progress.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active: Option<String>,
    /// pending, in_progress or completed.
    pub status: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Sent,
    Received,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolState {
    Running,
    Done,
    Error,
}

impl Item {
    pub fn id(&self) -> &str {
        match self {
            Self::User { id, .. }
            | Self::Agent { id, .. }
            | Self::Tool { id, .. }
            | Self::Command { id, .. }
            | Self::Notice { id, .. }
            | Self::Task { id, .. }
            | Self::Todos { id, .. }
            | Self::Peer { id, .. } => id,
        }
    }
}

/// What the Agent is waiting for, from core's status and the transcript.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Pending {
    /// permission, question or auth, as the core reports it.
    pub kind: String,
    /// core's one-line summary; an answer must quote it back.
    pub message: Option<String>,
    /// The tool call being asked about, when the transcript shows one.
    pub tool: Option<String>,
}

#[derive(Default)]
pub struct Conversation {
    /// The phone's language, for the few words the Gateway adds.
    lang: Lang,
    items: Vec<Item>,
    index: HashMap<String, usize>,
    /// Claude Code's permission mode as of its latest message.
    mode: Option<String>,
    todos: Vec<Todo>,
    /// TaskCreate and TaskUpdate calls awaiting their results, by tool call.
    todo_calls: HashMap<String, (String, Value)>,
    /// Subtask names by agentId, so a SendMessage to one names it.
    subagents: HashMap<String, String>,
    /// Agents that sent messages here, by their `uds:` address.
    peers: HashMap<String, String>,
}

impl Conversation {
    pub fn new(lang: Lang) -> Self {
        Self { lang, ..Self::default() }
    }

    #[cfg(test)]
    pub fn items(&self) -> &[Item] {
        &self.items
    }

    /// The newest items, for a phone that starts following.
    pub fn recent(&self) -> &[Item] {
        &self.items[self.items.len().saturating_sub(FIRST_ITEMS)..]
    }

    /// Applies transcript lines; returns the items added or changed, in order.
    pub fn apply<'a>(&mut self, lines: impl IntoIterator<Item = &'a str>) -> Vec<Item> {
        let mut touched: Vec<String> = Vec::new();
        for line in lines {
            let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
            for id in self.record(&record) {
                if !touched.contains(&id) {
                    touched.push(id);
                }
            }
        }
        touched.iter().filter_map(|id| self.index.get(id).map(|&i| self.items[i].clone())).collect()
    }

    /// The Agent's newest reply in the latest turn: what it said last,
    /// unless the user has spoken since.
    pub fn last_reply(&self) -> Option<&str> {
        self.items.iter().rev().find_map(|item| match item {
            Item::Agent { text, .. } => Some(Some(text.as_str())),
            Item::User { .. } => Some(None),
            _ => None,
        })?
    }

    /// The to-do in progress on the newest list, with how far the list is.
    pub fn todo_now(&self) -> Option<crate::about::TodoNow> {
        let current = self.todos.iter().find(|todo| todo.status == "in_progress")?;
        Some(crate::about::TodoNow {
            text: current.active.clone().unwrap_or_else(|| current.text.clone()),
            done: self.todos.iter().filter(|todo| todo.status == "completed").count(),
            total: self.todos.len(),
        })
    }

    /// `default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`, …: Claude
    /// Code writes it with each message, so a switch shows after the next one.
    pub fn mode(&self) -> Option<&str> {
        self.mode.as_deref()
    }

    /// The tool call the Agent is blocked on: the last one still running.
    pub fn pending(&self, status: Option<&crate::session::Status>) -> Option<Pending> {
        let status = status.filter(|status| status.state == "blocked")?;
        let tool = self.items.iter().rev().find_map(|item| match item {
            Item::Tool { id, state: ToolState::Running, .. } => Some(id.clone()),
            _ => None,
        });
        Some(Pending {
            kind: status.kind.clone().unwrap_or_else(|| "other".into()),
            message: status.message.clone(),
            tool,
        })
    }

    fn upsert(&mut self, item: Item) -> String {
        let id = item.id().to_owned();
        match self.index.get(&id) {
            Some(&i) => self.items[i] = item,
            None => {
                self.index.insert(id.clone(), self.items.len());
                self.items.push(item);
            }
        }
        id
    }

    fn record(&mut self, record: &Value) -> Vec<String> {
        if matches!(record["type"].as_str(), Some("permission-mode" | "user")) && record["isSidechain"] != true {
            if let Some(mode) = record["permissionMode"].as_str().filter(|mode| !mode.is_empty()) {
                self.mode = Some(mode.to_owned());
            }
        }
        let uuid = record["uuid"].as_str().unwrap_or_default();
        // Filed as a meta user message, but the Agent acts on it.
        if record["type"] == "user" && record["isSidechain"] != true && record["origin"]["kind"] == "peer" {
            return self.peer_message(uuid, record).into_iter().collect();
        }
        if record["isSidechain"] == true || record["isMeta"] == true || record["isVisibleInTranscriptOnly"] == true {
            return Vec::new();
        }
        match record["type"].as_str() {
            Some("user") => self.user(uuid, record),
            Some("assistant") => self.assistant(uuid, record),
            Some("system") => self.system(uuid, record),
            _ => Vec::new(),
        }
    }

    fn user(&mut self, uuid: &str, record: &Value) -> Vec<String> {
        let content = &record["message"]["content"];
        let at = record["timestamp"].as_str().and_then(epoch_ms);
        let notification =
            record["origin"]["kind"] == "task-notification" || record["turnOrigin"] == "task_notification";
        if let Some(text) = content.as_str() {
            if notification || text.trim_start().starts_with("<task-notification>") {
                return self.task(uuid, text, at);
            }
            return self.user_text(uuid, text).into_iter().collect();
        }
        let mut touched = Vec::new();
        let mut text = String::new();
        for block in content.as_array().into_iter().flatten() {
            match block["type"].as_str() {
                Some("text") => {
                    push_paragraph(&mut text, block["text"].as_str().unwrap_or_default());
                }
                Some("image") => push_paragraph(&mut text, image(self.lang)),
                Some("tool_result") => touched.extend(self.tool_result(block, &record["toolUseResult"])),
                _ => {}
            }
        }
        if notification || text.trim_start().starts_with("<task-notification>") {
            touched.extend(self.task(uuid, &text, at));
        } else {
            touched.extend(self.user_text(uuid, &text));
        }
        touched
    }

    fn user_text(&mut self, uuid: &str, text: &str) -> Option<String> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }
        if let Some(name) = tag(text, "command-name") {
            let name = match tag(text, "command-args").filter(|args| !args.is_empty()) {
                Some(args) => format!("{name} {args}"),
                None => name.to_owned(),
            };
            return Some(self.upsert(Item::Command { id: uuid.into(), name, output: None }));
        }
        if let Some(output) = tag(text, "local-command-stdout") {
            return self.command_output(output);
        }
        if text.starts_with("[Request interrupted by user") {
            let text = self.lang.pick("已中断", "Interrupted").into();
            return Some(self.upsert(Item::Notice { id: uuid.into(), text, code: Some("interrupted") }));
        }
        Some(self.upsert(Item::User { id: uuid.into(), text: clip(text, MAX_TEXT) }))
    }

    /// A `<task-notification>`: its summary on the collapsed line, the report
    /// behind it. One without the tags still never shows as the user's. A
    /// background subtask's call it names ends here.
    fn task(&mut self, uuid: &str, text: &str, at: Option<u64>) -> Vec<String> {
        let text = text.trim();
        if text.is_empty() {
            return Vec::new();
        }
        let mut touched = Vec::new();
        let state = match tag(text, "status") {
            Some("failed" | "killed" | "error") => ToolState::Error,
            _ => ToolState::Done,
        };
        let (summary, report) = match tag(text, "summary") {
            Some(summary) => (summary.to_owned(), tag(text, "result")),
            None => (self.lang.pick("任务通知", "Task notification").to_owned(), Some(text)),
        };
        let report = report.filter(|report| !report.is_empty()).map(|report| clip(report, MAX_TEXT));
        if let Some(call) = tag(text, "tool-use-id").and_then(|id| self.index.get(id)).map(|&i| self.items[i].clone()) {
            if let Item::Tool { state: ToolState::Running, agent: Some(mut agent), .. } = call.clone() {
                agent.duration_ms = agent.started_ms.zip(at).map(|(start, end)| end.saturating_sub(start));
                if let Item::Tool { id, name, summary, output, questions, answers, edit, .. } = call {
                    touched.push(self.upsert(Item::Tool {
                        id, name, summary, state, output, questions, answers, edit, agent: Some(agent),
                    }));
                }
            }
        }
        touched.push(self.upsert(Item::Task { id: uuid.into(), summary: clip(&summary, MAX_OUTPUT), state, text: report }));
        touched
    }

    /// A message another Agent sent this one.
    fn peer_message(&mut self, uuid: &str, record: &Value) -> Option<String> {
        let origin = &record["origin"];
        let name = origin["name"].as_str().filter(|name| !name.is_empty()).map(str::to_owned);
        if let (Some(from), Some(name)) = (origin["from"].as_str(), &name) {
            self.peers.insert(from.to_owned(), name.clone());
        }
        let text = origin["body"].as_str().or_else(|| record["message"]["content"].as_str())?.trim();
        if text.is_empty() {
            return None;
        }
        Some(self.upsert(Item::Peer {
            id: uuid.into(),
            direction: Direction::Received,
            name,
            text: clip(text, MAX_TEXT),
            state: ToolState::Done,
        }))
    }

    /// Who a SendMessage goes to: a subtask by its name, an Agent that wrote
    /// here by the name it gave, a session by its own name.
    fn recipient(&self, to: &str) -> Option<String> {
        if let Some(name) = self.subagents.get(to) {
            return Some(name.clone());
        }
        if to.starts_with("uds:") {
            return self.peers.get(to).cloned();
        }
        Some(to.to_owned()).filter(|to| !to.is_empty())
    }

    /// TaskCreate and TaskUpdate change the list once they succeed; TodoWrite
    /// carries the whole list in its call.
    fn todo_result(&mut self, id: &str, name: &str, input: &Value, block: &Value, structured: &Value) -> Option<String> {
        if block["is_error"] == true {
            return None;
        }
        let field = |key: &str| input[key].as_str().filter(|text| !text.is_empty()).map(str::to_owned);
        let key = |value: &Value| value.as_str().map(str::to_owned).or_else(|| value.as_u64().map(|n| n.to_string()));
        if name == "TaskCreate" {
            self.todos.push(Todo {
                key: key(&structured["task"]["id"]).unwrap_or_else(|| id.to_owned()),
                text: field("subject").unwrap_or_default(),
                active: field("activeForm"),
                status: "pending".into(),
            });
        } else {
            let target = key(&input["taskId"])?;
            let i = self.todos.iter().position(|todo| todo.key == target)?;
            match field("status").as_deref() {
                Some("deleted") => {
                    self.todos.remove(i);
                }
                status => {
                    let todo = &mut self.todos[i];
                    if let Some(status) = status {
                        todo.status = status.to_owned();
                    }
                    if let Some(text) = field("subject") {
                        todo.text = text;
                    }
                    if let Some(active) = field("activeForm") {
                        todo.active = Some(active);
                    }
                }
            }
        }
        Some(self.show_todos(id))
    }

    /// The list as it is now, in the last item when that is already the list.
    fn show_todos(&mut self, id: &str) -> String {
        let id = match self.items.last() {
            Some(Item::Todos { id, .. }) => id.clone(),
            _ => id.to_owned(),
        };
        self.upsert(Item::Todos { id, items: self.todos.clone() })
    }

    /// A local command's output belongs to the command just before it.
    fn command_output(&mut self, output: &str) -> Option<String> {
        let output = output.trim();
        let Some(Item::Command { id, name, output: None }) = self.items.last().cloned() else { return None };
        if output.is_empty() {
            return None;
        }
        Some(self.upsert(Item::Command { id, name, output: Some(clip_output(output, self.lang)) }))
    }

    fn tool_result(&mut self, block: &Value, structured: &Value) -> Option<String> {
        let id = block["tool_use_id"].as_str()?;
        if let Some((name, input)) = self.todo_calls.remove(id) {
            return self.todo_result(id, &name, &input, block, structured);
        }
        let &i = self.index.get(id)?;
        let failed = block["is_error"] == true;
        let (name, summary, questions, mut agent) = match self.items[i].clone() {
            Item::Tool { name, summary, questions, agent, .. } => (name, summary, questions, agent),
            Item::Peer { id, direction, name, text, .. } => {
                let state = if failed || structured["success"] == false { ToolState::Error } else { ToolState::Done };
                return Some(self.upsert(Item::Peer { id, direction, name, text, state }));
            }
            _ => return None,
        };
        let mut state = if failed { ToolState::Error } else { ToolState::Done };
        let output = result_text(&block["content"], self.lang).map(|text| clip_output(&text, self.lang));
        let answers = structured.get("answers").filter(|answers| answers.is_object()).cloned();
        let edit = (!failed && matches!(name.as_str(), "Edit" | "MultiEdit" | "Write")).then(|| edit(structured)).flatten();
        if let Some(agent) = agent.as_mut().filter(|_| !failed) {
            if let Some(agent_id) = structured["agentId"].as_str() {
                self.subagents.insert(agent_id.to_owned(), agent.name.clone());
            }
            if structured["status"] == "async_launched" {
                agent.background = true;
                state = ToolState::Running;
            } else {
                agent.duration_ms = structured["totalDurationMs"].as_u64();
            }
        }
        Some(self.upsert(Item::Tool { id: id.into(), name, summary, state, output, questions, answers, edit, agent }))
    }

    fn assistant(&mut self, uuid: &str, record: &Value) -> Vec<String> {
        let content = &record["message"]["content"];
        let mut touched = Vec::new();
        for (n, block) in content.as_array().into_iter().flatten().enumerate() {
            match block["type"].as_str() {
                Some("text") => {
                    let text = block["text"].as_str().unwrap_or_default().trim();
                    if text.is_empty() {
                        continue;
                    }
                    let id = format!("{uuid}.{n}");
                    let item = if record["isApiErrorMessage"] == true {
                        Item::Notice { id, text: clip(text, MAX_TEXT), code: None }
                    } else {
                        Item::Agent { id, text: clip(text, MAX_TEXT) }
                    };
                    touched.push(self.upsert(item));
                }
                Some("tool_use") => {
                    let Some(id) = block["id"].as_str() else { continue };
                    let name = block["name"].as_str().unwrap_or("tool").to_owned();
                    let input = &block["input"];
                    match name.as_str() {
                        "TaskCreate" | "TaskUpdate" => {
                            self.todo_calls.insert(id.into(), (name, input.clone()));
                            continue;
                        }
                        "TodoWrite" => {
                            self.todos = todo_list(input);
                            touched.push(self.show_todos(id));
                            continue;
                        }
                        "SendMessage" => {
                            let to = input["to"].as_str().unwrap_or_default();
                            let text = input["message"].as_str().map(str::to_owned).unwrap_or_else(|| input["message"].to_string());
                            touched.push(self.upsert(Item::Peer {
                                id: id.into(),
                                direction: Direction::Sent,
                                name: self.recipient(to),
                                text: clip(text.trim(), MAX_TEXT),
                                state: ToolState::Running,
                            }));
                            continue;
                        }
                        _ => {}
                    }
                    let questions = (name == "AskUserQuestion").then(|| questions(input));
                    let agent = matches!(name.as_str(), "Agent" | "Task").then(|| Subagent {
                        name: summary(&name, input, self.lang),
                        kind: input["subagent_type"].as_str().map(str::to_owned),
                        started_ms: record["timestamp"].as_str().and_then(epoch_ms),
                        duration_ms: None,
                        background: input["run_in_background"] == true,
                    });
                    touched.push(self.upsert(Item::Tool {
                        id: id.into(),
                        summary: summary(&name, input, self.lang),
                        name,
                        state: ToolState::Running,
                        output: None,
                        questions,
                        answers: None,
                        edit: None,
                        agent,
                    }));
                }
                _ => {}
            }
        }
        touched
    }

    fn system(&mut self, uuid: &str, record: &Value) -> Vec<String> {
        match record["subtype"].as_str() {
            Some("compact_boundary") => {
                let text = self.lang.pick("上下文已压缩", "Context compacted").into();
                vec![self.upsert(Item::Notice { id: uuid.into(), text, code: Some("compacted") })]
            }
            Some("local_command") => {
                let content = record["content"].as_str().unwrap_or_default();
                tag(content, "local-command-stdout").and_then(|output| self.command_output(output)).into_iter().collect()
            }
            _ => Vec::new(),
        }
    }
}

/// The one line a collapsed tool call shows.
fn summary(name: &str, input: &Value, lang: Lang) -> String {
    let field = |key: &str| input[key].as_str().map(str::to_owned);
    let text = match name {
        "Bash" => field("command"),
        "Read" | "Edit" | "Write" | "MultiEdit" => field("file_path"),
        "NotebookEdit" => field("notebook_path"),
        "Grep" | "Glob" => field("pattern"),
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        "AskUserQuestion" => input["questions"][0]["question"].as_str().map(str::to_owned),
        "TodoWrite" => Some(lang.pick("更新待办", "Update to-dos").into()),
        _ => None,
    }
    .or_else(|| field("description"))
    .or_else(|| input.as_object().and_then(|input| input.values().find_map(Value::as_str)).map(str::to_owned))
    .unwrap_or_default();
    clip(text.trim(), 500)
}

/// TodoWrite's whole list.
fn todo_list(input: &Value) -> Vec<Todo> {
    input["todos"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(n, todo)| Todo {
            key: n.to_string(),
            text: todo["content"].as_str().unwrap_or_default().to_owned(),
            active: todo["activeForm"].as_str().filter(|text| !text.is_empty()).map(str::to_owned),
            status: todo["status"].as_str().unwrap_or("pending").to_owned(),
        })
        .collect()
}

/// What an Edit or Write changed, from its structured result: the hunks
/// Claude Code computed, or a new file's text.
fn edit(structured: &Value) -> Option<Edit> {
    let path = structured["filePath"].as_str()?.to_owned();
    let mut patch = Patch::default();
    let created = structured["type"] == "create";
    if created {
        let content = structured["content"].as_str().unwrap_or_default();
        let lines: Vec<&str> = content.lines().collect();
        if !lines.is_empty() {
            patch.line(&format!("@@ -0,0 +1,{} @@", lines.len()));
        }
        for line in lines {
            patch.added += 1;
            patch.line(&format!("+{line}"));
        }
    } else {
        for hunk in structured["structuredPatch"].as_array()? {
            let number = |key: &str| hunk[key].as_u64().unwrap_or(0);
            patch.line(&format!(
                "@@ -{},{} +{},{} @@",
                number("oldStart"), number("oldLines"), number("newStart"), number("newLines")
            ));
            for line in hunk["lines"].as_array().into_iter().flatten().filter_map(Value::as_str) {
                match line.chars().next() {
                    Some('+') => patch.added += 1,
                    Some('-') => patch.deleted += 1,
                    _ => {}
                }
                patch.line(line);
            }
        }
    }
    Some(Edit { path, added: patch.added, deleted: patch.deleted, patch: patch.text, created, truncated: patch.truncated })
}

/// A diff built up to the phone's limit; counts keep going past it.
#[derive(Default)]
struct Patch {
    text: String,
    lines: usize,
    added: u64,
    deleted: u64,
    truncated: bool,
}

impl Patch {
    fn line(&mut self, line: &str) {
        if self.truncated || self.lines >= MAX_PATCH_LINES || self.text.len() + line.len() + 1 > MAX_PATCH_BYTES {
            self.truncated = true;
            return;
        }
        self.text.push_str(line);
        self.text.push('\n');
        self.lines += 1;
    }
}

/// `2026-11-03T08:26:52.583Z` as milliseconds since the epoch.
fn epoch_ms(timestamp: &str) -> Option<u64> {
    let (date, time) = timestamp.split_once('T')?;
    let mut date = date.splitn(3, '-').map(str::parse::<i64>);
    let (year, month, day) = (date.next()?.ok()?, date.next()?.ok()?, date.next()?.ok()?);
    let time = time.strip_suffix('Z')?;
    let (clock, fraction) = time.split_once('.').unwrap_or((time, ""));
    let mut clock = clock.splitn(3, ':').map(str::parse::<i64>);
    let (hour, minute, second) = (clock.next()?.ok()?, clock.next()?.ok()?, clock.next()?.ok()?);
    let millis = format!("{:0<3}", fraction.get(..3).unwrap_or(fraction)).parse::<i64>().ok()?;
    // Days from the civil date (Howard Hinnant's algorithm).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    u64::try_from(((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + millis).ok()
}

/// AskUserQuestion's questions with only what the app shows.
fn questions(input: &Value) -> Value {
    let questions: Vec<Value> = input["questions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|question| {
            let options: Vec<Value> = question["options"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|option| json!({"label": option["label"], "description": option["description"]}))
                .collect();
            let mut out = Map::new();
            out.insert("question".into(), question["question"].clone());
            out.insert("header".into(), question["header"].clone());
            out.insert("multi_select".into(), Value::Bool(question["multiSelect"] == true));
            out.insert("options".into(), Value::Array(options));
            Value::Object(out)
        })
        .collect();
    Value::Array(questions)
}

fn result_text(content: &Value, lang: Lang) -> Option<String> {
    if let Some(text) = content.as_str() {
        return Some(text.to_owned());
    }
    let mut text = String::new();
    for block in content.as_array()? {
        match block["type"].as_str() {
            Some("text") => push_paragraph(&mut text, block["text"].as_str().unwrap_or_default()),
            Some("image") => push_paragraph(&mut text, image(lang)),
            _ => {}
        }
    }
    Some(text)
}

/// The text between `<name>` and `</name>`, if the tag is there.
fn tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let start = text.find(&format!("<{name}>"))? + name.len() + 2;
    let end = text[start..].find(&format!("</{name}>"))? + start;
    Some(text[start..end].trim())
}

fn push_paragraph(text: &mut String, more: &str) {
    if more.trim().is_empty() {
        return;
    }
    if !text.is_empty() {
        text.push_str("\n\n");
    }
    text.push_str(more.trim());
}

fn clip(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &text[..end])
}

/// Where an image was, in text that is otherwise kept.
fn image(lang: Lang) -> &'static str {
    lang.pick("［图片］", "[Image]")
}

fn clip_output(text: &str, lang: Lang) -> String {
    let mut lines = text.lines();
    let head: Vec<&str> = lines.by_ref().take(MAX_OUTPUT_LINES).collect();
    let more = lines.count();
    let mut out = clip(&head.join("\n"), MAX_OUTPUT);
    if more > 0 {
        out.push_str(&lang.pick(format!("\n…（另有 {more} 行）"), format!("\n… ({more} more lines)")));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Status;

    /// Records shaped like Claude Code 2.1.316's, trimmed to the fields read.
    const SAMPLE: &str = r#"{"type":"mode","mode":"normal","sessionId":"s1"}
{"type":"user","uuid":"u0","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>The command below was run directly</local-command-caveat>"}}
{"type":"user","uuid":"u1","message":{"role":"user","content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"}}
{"type":"system","subtype":"local_command","uuid":"s1","content":"<local-command-stdout></local-command-stdout>"}
{"type":"user","uuid":"u2","message":{"role":"user","content":"Run echo, then ask me Red or Blue."}}
{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"thinking","thinking":"secret plan"}]}}
{"type":"assistant","uuid":"a2","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi > note.txt && cat note.txt","description":"Write and print"}}]}}
{"type":"user","uuid":"u3","toolUseResult":{"stdout":"hi"},"message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"hi","is_error":false}]}}
{"type":"assistant","uuid":"a3","message":{"id":"m2","content":[{"type":"tool_use","id":"toolu_2","name":"AskUserQuestion","input":{"questions":[{"question":"Do you prefer Red or Blue?","header":"Color","multiSelect":false,"options":[{"label":"Red","description":"Choose Red"},{"label":"Blue","description":"Choose Blue"}]}]}}]}}
{"type":"attachment","uuid":"x1","attachment":{"type":"skill_listing"}}
{"type":"api-request","uuid":"x2","request":{"huge":true}}
"#;

    const ANSWER: &str = r#"{"type":"user","uuid":"u4","toolUseResult":{"answers":{"Do you prefer Red or Blue?":"Blue"}},"message":{"role":"user","content":[{"type":"tool_result","content":"Your questions have been answered","tool_use_id":"toolu_2"}]}}
{"type":"assistant","uuid":"a4","message":{"id":"m3","content":[{"type":"text","text":"You picked **Blue**."}]}}
{"type":"system","subtype":"turn_duration","uuid":"s2","durationMs":4000}
"#;

    fn kinds(items: &[Item]) -> Vec<&'static str> {
        items
            .iter()
            .map(|item| match item {
                Item::User { .. } => "user",
                Item::Agent { .. } => "agent",
                Item::Tool { .. } => "tool",
                Item::Command { .. } => "command",
                Item::Notice { .. } => "notice",
                Item::Task { .. } => "task",
                Item::Todos { .. } => "todos",
                Item::Peer { .. } => "peer",
            })
            .collect()
    }

    fn blocked(kind: &str) -> Status {
        Status { state: "blocked".into(), app: Some("claude-code".into()), message: Some("answer: Red?".into()), kind: Some(kind.into()) }
    }

    #[test]
    fn keeps_messages_tools_and_commands_and_drops_the_rest() {
        let mut conversation = Conversation::default();
        let added = conversation.apply(SAMPLE.lines());
        assert_eq!(kinds(&added), ["command", "user", "tool", "tool"]);
        assert!(matches!(&added[0], Item::Command { name, output: None, .. } if name == "/clear"));
        assert!(matches!(&added[1], Item::User { text, .. } if text == "Run echo, then ask me Red or Blue."));
        assert!(matches!(&added[2], Item::Tool { name, summary, state: ToolState::Done, output: Some(output), .. }
            if name == "Bash" && summary == "echo hi > note.txt && cat note.txt" && output == "hi"));
        let json = serde_json::to_string(conversation.items()).unwrap();
        assert!(!json.contains("secret plan"), "thinking stays in the Gateway");
        assert!(!json.contains("huge"));
    }

    #[test]
    fn mode_is_the_latest_permission_mode_record() {
        let mut conversation = Conversation::default();
        assert_eq!(conversation.mode(), None);
        conversation.apply([r#"{"type":"permission-mode","permissionMode":"auto","sessionId":"s"}"#]);
        assert_eq!(conversation.mode(), Some("auto"));
        let added = conversation.apply([
            r#"{"type":"user","uuid":"u1","permissionMode":"plan","message":{"role":"user","content":"plan it"}}"#,
            r#"{"type":"user","uuid":"u2","isSidechain":true,"permissionMode":"default","message":{"content":"sub"}}"#,
        ]);
        assert_eq!(kinds(&added), ["user"], "the mode record is not an item");
        assert_eq!(conversation.mode(), Some("plan"), "a subagent's mode is not the Agent's");
    }

    #[test]
    fn a_running_tool_is_pending_while_blocked_and_its_answer_updates_it() {
        let mut conversation = Conversation::default();
        conversation.apply(SAMPLE.lines());
        assert_eq!(conversation.pending(None), None);
        let pending = conversation.pending(Some(&blocked("question"))).unwrap();
        assert_eq!(pending.kind, "question");
        assert_eq!(pending.tool.as_deref(), Some("toolu_2"));
        let Item::Tool { questions: Some(questions), .. } = &conversation.items()[3] else { panic!() };
        assert_eq!(questions[0]["options"][1]["label"], "Blue");
        assert_eq!(questions[0]["multi_select"], false);

        let changed = conversation.apply(ANSWER.lines());
        assert_eq!(kinds(&changed), ["tool", "agent"]);
        assert!(matches!(&changed[0], Item::Tool { id, state: ToolState::Done, answers: Some(answers), .. }
            if id == "toolu_2" && answers["Do you prefer Red or Blue?"] == "Blue"));
        assert!(matches!(&changed[1], Item::Agent { text, .. } if text == "You picked **Blue**."));
        assert_eq!(conversation.items().len(), 5, "the answer replaced the tool call in place");
        assert_eq!(conversation.pending(Some(&blocked("permission"))).unwrap().tool, None);
    }

    #[test]
    fn the_last_reply_is_the_latest_turns() {
        let mut conversation = Conversation::default();
        conversation.apply(SAMPLE.lines());
        assert_eq!(conversation.last_reply(), None, "waiting on a question after the user spoke");
        conversation.apply(ANSWER.lines());
        assert_eq!(conversation.last_reply(), Some("You picked **Blue**."));
        conversation.apply([r#"{"type":"user","uuid":"u9","message":{"role":"user","content":"thanks"}}"#]);
        assert_eq!(conversation.last_reply(), None);
    }

    #[test]
    fn errors_interruptions_compaction_and_command_output() {
        let lines = [
            r#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x"}}]}}"#,
            r#"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"no such file"}]}]}}"#,
            r#"{"type":"user","uuid":"u2","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            r#"{"type":"system","subtype":"compact_boundary","uuid":"s1"}"#,
            r#"{"type":"user","uuid":"u3","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued"}}"#,
            r#"{"type":"user","uuid":"u4","message":{"content":"<command-name>/model</command-name><command-args>haiku</command-args>"}}"#,
            r#"{"type":"user","uuid":"u5","message":{"content":"<local-command-stdout>Set model to haiku</local-command-stdout>"}}"#,
            r#"{"type":"assistant","uuid":"a2","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: overloaded"}]}}"#,
            r#"{"type":"user","uuid":"u6","isSidechain":true,"message":{"content":"sub-agent prompt"}}"#,
            "not json",
        ];
        let mut conversation = Conversation::default();
        conversation.apply(lines);
        let items = conversation.items();
        assert_eq!(kinds(items), ["tool", "notice", "notice", "command", "notice"]);
        assert!(matches!(&items[1], Item::Notice { text, code: Some("interrupted"), .. } if text == "已中断"));
        assert!(matches!(&items[2], Item::Notice { code: Some("compacted"), .. }));
        assert!(matches!(&items[4], Item::Notice { code: None, .. }));
        let mut english = Conversation::new(Lang::English);
        english.apply(lines);
        assert!(matches!(&english.items()[1], Item::Notice { text, .. } if text == "Interrupted"));
        assert!(matches!(&english.items()[2], Item::Notice { text, .. } if text == "Context compacted"));
        let json = serde_json::to_value(&english.items()[1]).unwrap();
        assert_eq!(json, serde_json::json!({"kind": "notice", "id": "u2", "text": "Interrupted", "code": "interrupted"}));
        assert!(serde_json::to_value(&items[4]).unwrap().get("code").is_none());
        assert!(matches!(&items[0], Item::Tool { state: ToolState::Error, output: Some(output), .. } if output == "no such file"));
        assert!(matches!(&items[3], Item::Command { name, output: Some(output), .. }
            if name == "/model haiku" && output == "Set model to haiku"));
    }

    #[test]
    fn task_notifications_are_not_the_users_messages() {
        let lines = [
            // A subagent's report, as Claude Code 2.1.316 files it.
            r#"{"type":"user","uuid":"u1","isSidechain":false,"origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","turnOrigin":"task_notification","message":{"role":"user","content":"<task-notification>\n<task-id>a1</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>completed</status>\n<summary>Agent \"Find roadmap items\" finished</summary>\n<note>May notify again.</note>\n<result>Found **3** items.</result>\n<usage><tool_uses>2</tool_uses></usage>\n</task-notification>"}}"#,
            // A background command, without a report.
            r#"{"type":"user","uuid":"u2","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>\n<status>failed</status>\n<summary>Background command \"make\" failed with exit code 1</summary>\n</task-notification>"}}"#,
            // An older transcript without the metadata.
            r#"{"type":"user","uuid":"u3","message":{"content":"<task-notification><status>completed</status><summary>Done</summary></task-notification>"}}"#,
            // Flagged but without the tags: still not the user's.
            r#"{"type":"user","uuid":"u4","turnOrigin":"task_notification","message":{"content":"something new"}}"#,
            r#"{"type":"user","uuid":"u5","message":{"content":"What is a <task-notification>?"}}"#,
        ];
        let mut conversation = Conversation::default();
        conversation.apply(lines);
        let items = conversation.items();
        assert_eq!(kinds(items), ["task", "task", "task", "task", "user"]);
        assert!(matches!(&items[0], Item::Task { summary, state: ToolState::Done, text: Some(text), .. }
            if summary == "Agent \"Find roadmap items\" finished" && text == "Found **3** items."));
        assert!(matches!(&items[1], Item::Task { state: ToolState::Error, text: None, .. }));
        assert!(matches!(&items[3], Item::Task { summary, text: Some(text), .. } if summary == "任务通知" && text == "something new"));
        let json = serde_json::to_value(&items[0]).unwrap();
        assert_eq!(json["kind"], "task");
        assert_eq!(json["state"], "done");
    }

    #[test]
    fn long_output_is_clipped_by_lines_and_bytes() {
        let long = (1..=100).map(|n| n.to_string()).collect::<Vec<_>>().join("\n");
        let output = clip_output(&long, Lang::Chinese);
        assert!(output.starts_with("1\n2\n"));
        assert!(output.ends_with("（另有 60 行）"));
        assert!(clip_output(&long, Lang::English).ends_with("… (60 more lines)"));
        assert_eq!(clip("界界", 4), "界…");
    }

    #[test]
    fn edits_carry_their_diff() {
        let lines = [
            r#"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"/x/A.swift","old_string":"a","new_string":"b"}},{"type":"tool_use","id":"toolu_2","name":"Write","input":{"file_path":"/x/new.md","content":"one\ntwo\n"}},{"type":"tool_use","id":"toolu_3","name":"Edit","input":{"file_path":"/x/B.swift"}}]}}"#,
            r#"{"type":"user","uuid":"u1","toolUseResult":{"filePath":"/x/A.swift","structuredPatch":[{"oldStart":3,"oldLines":3,"newStart":3,"newLines":4,"lines":[" keep","-old","+new","+more"," keep"]}]},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#,
            r#"{"type":"user","uuid":"u2","toolUseResult":{"type":"create","filePath":"/x/new.md","content":"one\ntwo\n"},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"ok"}]}}"#,
            r#"{"type":"user","uuid":"u3","toolUseResult":"Error: string not found","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"not found","is_error":true}]}}"#,
        ];
        let mut conversation = Conversation::default();
        conversation.apply(lines);
        let items = conversation.items();
        let Item::Tool { edit: Some(edit), state: ToolState::Done, .. } = &items[0] else { panic!("{:?}", items[0]) };
        assert_eq!((edit.path.as_str(), edit.added, edit.deleted, edit.created), ("/x/A.swift", 2, 1, false));
        assert_eq!(edit.patch, "@@ -3,3 +3,4 @@\n keep\n-old\n+new\n+more\n keep\n");
        let Item::Tool { edit: Some(created), .. } = &items[1] else { panic!() };
        assert_eq!((created.added, created.created), (2, true));
        assert_eq!(created.patch, "@@ -0,0 +1,2 @@\n+one\n+two\n");
        assert!(matches!(&items[2], Item::Tool { edit: None, state: ToolState::Error, .. }));
        let json = serde_json::to_value(&items[1]).unwrap();
        assert_eq!(json["edit"]["created"], true);
        assert!(serde_json::to_value(&items[0]).unwrap()["edit"].get("created").is_none());

        let long: Vec<String> = (0..300).map(|n| format!("\"+{n}\"")).collect();
        let record = format!(r#"{{"filePath":"/x/C","structuredPatch":[{{"oldStart":0,"oldLines":0,"newStart":1,"newLines":300,"lines":[{}]}}]}}"#, long.join(","));
        let cut = super::edit(&serde_json::from_str(&record).unwrap()).unwrap();
        assert!(cut.truncated);
        assert_eq!(cut.added, 300, "counts go past the limit");
        assert_eq!(cut.patch.lines().count(), MAX_PATCH_LINES);
    }

    fn todo_texts(item: &Item) -> Vec<String> {
        let Item::Todos { items, .. } = item else { panic!("{item:?}") };
        items.iter().map(|todo| format!("{} {}", todo.status, todo.text)).collect()
    }

    #[test]
    fn task_tools_become_one_checklist() {
        let call = |n: u32, name: &str, input: &str| {
            format!(r#"{{"type":"assistant","uuid":"a{n}","message":{{"id":"m{n}","content":[{{"type":"tool_use","id":"toolu_{n}","name":"{name}","input":{input}}}]}}}}"#)
        };
        let result = |n: u32, structured: &str| {
            format!(r#"{{"type":"user","uuid":"u{n}","toolUseResult":{structured},"message":{{"content":[{{"type":"tool_result","tool_use_id":"toolu_{n}","content":"ok"}}]}}}}"#)
        };
        let lines = [
            call(1, "TaskCreate", r#"{"subject":"读代码","activeForm":"读代码中"}"#),
            result(1, r#"{"task":{"id":"1","subject":"读代码"}}"#),
            call(2, "TaskCreate", r#"{"subject":"写测试","description":"x"}"#),
            result(2, r#"{"task":{"id":"2","subject":"写测试"}}"#),
            call(3, "TaskUpdate", r#"{"taskId":"1","status":"in_progress"}"#),
            result(3, r#"{"success":true,"taskId":"1"}"#),
            r#"{"type":"assistant","uuid":"a4","message":{"id":"m4","content":[{"type":"text","text":"开始"}]}}"#.to_owned(),
            call(5, "TaskUpdate", r#"{"taskId":"1","status":"completed"}"#),
            result(5, r#"{"success":true}"#),
            call(6, "TaskUpdate", r#"{"taskId":"2","status":"deleted"}"#),
            result(6, r#"{"success":true}"#),
            call(7, "TaskUpdate", r#"{"taskId":"9","status":"completed"}"#),
            result(7, r#"{"success":false}"#),
        ];
        let mut conversation = Conversation::default();
        conversation.apply(lines[..6].iter().map(String::as_str));
        assert_eq!(conversation.todo_now(), Some(crate::about::TodoNow { text: "读代码中".into(), done: 0, total: 2 }));
        conversation.apply(lines[6..].iter().map(String::as_str));
        assert_eq!(conversation.todo_now(), None, "nothing is in progress at the end");
        let items = conversation.items();
        assert_eq!(kinds(items), ["todos", "agent", "todos"]);
        assert_eq!(items[0].id(), "toolu_1", "back-to-back updates share the first one's item");
        assert_eq!(todo_texts(&items[0]), ["in_progress 读代码", "pending 写测试"]);
        assert_eq!(todo_texts(&items[2]), ["completed 读代码"]);
        let json = serde_json::to_value(&items[0]).unwrap();
        assert_eq!(json["items"][0], serde_json::json!({"text": "读代码", "active": "读代码中", "status": "in_progress"}));

        let mut old = Conversation::default();
        old.apply([call(1, "TodoWrite", r#"{"todos":[{"content":"A","status":"completed","activeForm":"Aing"},{"content":"B","status":"in_progress","activeForm":"Bing"}]}"#)].iter().map(String::as_str));
        assert_eq!(todo_texts(&old.items()[0]), ["completed A", "in_progress B"]);
    }

    #[test]
    fn subtasks_are_timed_and_background_ones_end_with_their_notification() {
        let lines = [
            r#"{"type":"assistant","uuid":"a1","timestamp":"2026-11-03T08:26:52.583Z","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"Find items","subagent_type":"Explore","prompt":"p"}},{"type":"tool_use","id":"toolu_2","name":"Agent","input":{"description":"Watch CI","prompt":"p","run_in_background":true}}]}}"#,
            r#"{"type":"user","uuid":"u1","toolUseResult":{"status":"completed","agentId":"ag1","totalDurationMs":12000,"content":[]},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}"#,
            r#"{"type":"user","uuid":"u2","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"ag2"},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"launched"}]}}"#,
        ];
        let mut conversation = Conversation::default();
        conversation.apply(lines);
        let agent = |item: &Item| match item {
            Item::Tool { agent: Some(agent), state, .. } => (agent.clone(), *state),
            other => panic!("{other:?}"),
        };
        let (sync, state) = agent(&conversation.items()[0]);
        assert_eq!((sync.name.as_str(), sync.kind.as_deref(), sync.duration_ms, state), ("Find items", Some("Explore"), Some(12000), ToolState::Done));
        assert_eq!(sync.started_ms, Some(1_793_694_412_583));
        let (background, state) = agent(&conversation.items()[1]);
        assert!(background.background && background.duration_ms.is_none());
        assert_eq!(state, ToolState::Running);

        let touched = conversation.apply([
            r#"{"type":"user","uuid":"u3","timestamp":"2026-11-03T08:28:52.583Z","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>\n<task-id>ag2</task-id>\n<tool-use-id>toolu_2</tool-use-id>\n<status>completed</status>\n<summary>Agent \"Watch CI\" finished</summary>\n</task-notification>"}}"#,
        ]);
        assert_eq!(kinds(&touched), ["tool", "task"]);
        let (background, state) = agent(&conversation.items()[1]);
        assert_eq!((background.duration_ms, state), (Some(120_000), ToolState::Done));
    }

    #[test]
    fn messages_between_agents_name_the_other_one() {
        let send = |n: u32, to: &str| {
            format!(r#"{{"type":"assistant","uuid":"a{n}","message":{{"id":"m{n}","content":[{{"type":"tool_use","id":"toolu_{n}","name":"SendMessage","input":{{"to":"{to}","message":"hi {n}","summary":"s"}}}}]}}}}"#)
        };
        let lines = [
            send(1, "uds:/tmp/cc-socks/1.sock"),
            r#"{"type":"user","uuid":"u1","isMeta":true,"origin":{"kind":"peer","from":"uds:/tmp/cc-socks/1.sock","name":"static-workorder","body":"已改好"},"message":{"content":"<cross-session-message>已改好</cross-session-message> Reply with SendMessage"}}"#.to_owned(),
            send(2, "uds:/tmp/cc-socks/1.sock"),
            r#"{"type":"assistant","uuid":"a3","message":{"id":"m3","content":[{"type":"tool_use","id":"toolu_3","name":"Agent","input":{"description":"Find items","prompt":"p","run_in_background":true}}]}}"#.to_owned(),
            r#"{"type":"user","uuid":"u3","toolUseResult":{"status":"async_launched","agentId":"ag1"},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_3","content":"ok"}]}}"#.to_owned(),
            send(4, "ag1"),
            send(5, "web-session"),
            r#"{"type":"user","uuid":"u5","toolUseResult":{"success":false},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_5","content":"no such agent","is_error":true}]}}"#.to_owned(),
        ];
        let mut conversation = Conversation::default();
        conversation.apply(lines.iter().map(String::as_str));
        let peers: Vec<_> = conversation
            .items()
            .iter()
            .filter_map(|item| match item {
                Item::Peer { direction, name, text, state, .. } => Some((*direction, name.clone(), text.clone(), *state)),
                _ => None,
            })
            .collect();
        let name = |name: &str| Some(name.to_owned());
        assert_eq!(peers, [
            (Direction::Sent, None, "hi 1".into(), ToolState::Running),
            (Direction::Received, name("static-workorder"), "已改好".into(), ToolState::Done),
            (Direction::Sent, name("static-workorder"), "hi 2".into(), ToolState::Running),
            (Direction::Sent, name("Find items"), "hi 4".into(), ToolState::Running),
            (Direction::Sent, name("web-session"), "hi 5".into(), ToolState::Error),
        ]);
        let json = serde_json::to_value(&conversation.items()[1]).unwrap();
        assert_eq!((json["kind"].as_str(), json["direction"].as_str()), (Some("peer"), Some("received")));
        assert!(!serde_json::to_string(conversation.items()).unwrap().contains("Reply with SendMessage"));
    }

    #[test]
    fn transcript_timestamps_read_as_epoch_ms() {
        assert_eq!(epoch_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(epoch_ms("2000-03-01T00:00:01.5Z"), Some(951_868_801_500));
        assert_eq!(epoch_ms("2026-11-03T08:26:52.583Z"), Some(1_793_694_412_583));
        assert_eq!(epoch_ms("yesterday"), None);
    }
}
