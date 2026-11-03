//! Turns Claude Code transcript lines into what the app shows: messages,
//! tool calls and notices. Only the fields shown are kept; thinking, token
//! usage, request records and attachments never leave the Gateway. Unknown
//! record types are skipped, so a newer Claude Code degrades to fewer items.

use serde::Serialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;

const MAX_TEXT: usize = 32 * 1024;
const MAX_OUTPUT: usize = 2000;
const MAX_OUTPUT_LINES: usize = 40;
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
    },
    /// A slash command run in Claude Code, with what it printed.
    Command { id: String, name: String, output: Option<String> },
    /// Something that happened to the conversation (compacted, interrupted, API error).
    Notice { id: String, text: String },
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
            | Self::Task { id, .. } => id,
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
    items: Vec<Item>,
    index: HashMap<String, usize>,
    /// Claude Code's permission mode as of its latest message.
    mode: Option<String>,
}

impl Conversation {
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
        if record["isSidechain"] == true || record["isMeta"] == true || record["isVisibleInTranscriptOnly"] == true {
            return Vec::new();
        }
        let uuid = record["uuid"].as_str().unwrap_or_default();
        match record["type"].as_str() {
            Some("user") => self.user(uuid, record),
            Some("assistant") => self.assistant(uuid, record),
            Some("system") => self.system(uuid, record),
            _ => Vec::new(),
        }
    }

    fn user(&mut self, uuid: &str, record: &Value) -> Vec<String> {
        let content = &record["message"]["content"];
        let notification =
            record["origin"]["kind"] == "task-notification" || record["turnOrigin"] == "task_notification";
        if let Some(text) = content.as_str() {
            if notification || text.trim_start().starts_with("<task-notification>") {
                return self.task(uuid, text).into_iter().collect();
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
                Some("image") => push_paragraph(&mut text, "［图片］"),
                Some("tool_result") => touched.extend(self.tool_result(block, &record["toolUseResult"])),
                _ => {}
            }
        }
        if notification || text.trim_start().starts_with("<task-notification>") {
            touched.extend(self.task(uuid, &text));
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
            return Some(self.upsert(Item::Notice { id: uuid.into(), text: "已中断".into() }));
        }
        Some(self.upsert(Item::User { id: uuid.into(), text: clip(text, MAX_TEXT) }))
    }

    /// A `<task-notification>`: its summary on the collapsed line, the report
    /// behind it. One without the tags still never shows as the user's.
    fn task(&mut self, uuid: &str, text: &str) -> Option<String> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }
        let state = match tag(text, "status") {
            Some("failed" | "killed" | "error") => ToolState::Error,
            _ => ToolState::Done,
        };
        let (summary, report) = match tag(text, "summary") {
            Some(summary) => (summary.to_owned(), tag(text, "result")),
            None => ("任务通知".to_owned(), Some(text)),
        };
        let report = report.filter(|report| !report.is_empty()).map(|report| clip(report, MAX_TEXT));
        Some(self.upsert(Item::Task { id: uuid.into(), summary: clip(&summary, MAX_OUTPUT), state, text: report }))
    }

    /// A local command's output belongs to the command just before it.
    fn command_output(&mut self, output: &str) -> Option<String> {
        let output = output.trim();
        let Some(Item::Command { id, name, output: None }) = self.items.last().cloned() else { return None };
        if output.is_empty() {
            return None;
        }
        Some(self.upsert(Item::Command { id, name, output: Some(clip_output(output)) }))
    }

    fn tool_result(&mut self, block: &Value, structured: &Value) -> Option<String> {
        let id = block["tool_use_id"].as_str()?;
        let &i = self.index.get(id)?;
        let Item::Tool { name, summary, questions, .. } = self.items[i].clone() else { return None };
        let state = if block["is_error"] == true { ToolState::Error } else { ToolState::Done };
        let output = result_text(&block["content"]).map(|text| clip_output(&text));
        let answers = structured.get("answers").filter(|answers| answers.is_object()).cloned();
        Some(self.upsert(Item::Tool { id: id.into(), name, summary, state, output, questions, answers }))
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
                        Item::Notice { id, text: clip(text, MAX_TEXT) }
                    } else {
                        Item::Agent { id, text: clip(text, MAX_TEXT) }
                    };
                    touched.push(self.upsert(item));
                }
                Some("tool_use") => {
                    let Some(id) = block["id"].as_str() else { continue };
                    let name = block["name"].as_str().unwrap_or("tool").to_owned();
                    let input = &block["input"];
                    let questions = (name == "AskUserQuestion").then(|| questions(input));
                    touched.push(self.upsert(Item::Tool {
                        id: id.into(),
                        summary: summary(&name, input),
                        name,
                        state: ToolState::Running,
                        output: None,
                        questions,
                        answers: None,
                    }));
                }
                _ => {}
            }
        }
        touched
    }

    fn system(&mut self, uuid: &str, record: &Value) -> Vec<String> {
        match record["subtype"].as_str() {
            Some("compact_boundary") => vec![self.upsert(Item::Notice { id: uuid.into(), text: "上下文已压缩".into() })],
            Some("local_command") => {
                let content = record["content"].as_str().unwrap_or_default();
                tag(content, "local-command-stdout").and_then(|output| self.command_output(output)).into_iter().collect()
            }
            _ => Vec::new(),
        }
    }
}

/// The one line a collapsed tool call shows.
fn summary(name: &str, input: &Value) -> String {
    let field = |key: &str| input[key].as_str().map(str::to_owned);
    let text = match name {
        "Bash" => field("command"),
        "Read" | "Edit" | "Write" | "MultiEdit" => field("file_path"),
        "NotebookEdit" => field("notebook_path"),
        "Grep" | "Glob" => field("pattern"),
        "WebFetch" => field("url"),
        "WebSearch" => field("query"),
        "AskUserQuestion" => input["questions"][0]["question"].as_str().map(str::to_owned),
        "TodoWrite" => Some("更新待办".into()),
        _ => None,
    }
    .or_else(|| field("description"))
    .or_else(|| input.as_object().and_then(|input| input.values().find_map(Value::as_str)).map(str::to_owned))
    .unwrap_or_default();
    clip(text.trim(), 500)
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

fn result_text(content: &Value) -> Option<String> {
    if let Some(text) = content.as_str() {
        return Some(text.to_owned());
    }
    let mut text = String::new();
    for block in content.as_array()? {
        match block["type"].as_str() {
            Some("text") => push_paragraph(&mut text, block["text"].as_str().unwrap_or_default()),
            Some("image") => push_paragraph(&mut text, "［图片］"),
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

fn clip_output(text: &str) -> String {
    let mut lines = text.lines();
    let head: Vec<&str> = lines.by_ref().take(MAX_OUTPUT_LINES).collect();
    let more = lines.count();
    let mut out = clip(&head.join("\n"), MAX_OUTPUT);
    if more > 0 {
        out.push_str(&format!("\n…（另有 {more} 行）"));
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
        let output = clip_output(&(1..=100).map(|n| n.to_string()).collect::<Vec<_>>().join("\n"));
        assert!(output.starts_with("1\n2\n"));
        assert!(output.ends_with("（另有 60 行）"));
        assert_eq!(clip("界界", 4), "界…");
    }
}
