//! Codex rollout lines (`~/.codex/sessions/…/rollout-*.jsonl`) as items. Only
//! what the page shows is read: the user's messages, the Agent's replies,
//! shell commands with their output summary, and `apply_patch` edits.
//! Reasoning, token counts, turn settings and the context Codex injects as
//! user and developer messages never leave the Gateway; record types it
//! doesn't know are skipped, so a newer Codex degrades to fewer items.

use super::*;

impl Conversation {
    pub(super) fn codex_record(&mut self, record: &Value) -> Vec<String> {
        let payload = &record["payload"];
        match record["type"].as_str() {
            Some("turn_context") => {
                if let Some(model) = payload["model"].as_str().filter(|model| !model.is_empty()) {
                    self.model = Some(model.to_owned());
                }
                Vec::new()
            }
            Some("event_msg") if matches!(payload["type"].as_str(), Some("turn_aborted" | "task_aborted")) => {
                let id = codex_id(record, payload);
                let text = self.lang.pick("已中断", "Interrupted").into();
                vec![self.upsert(Item::Notice { id, text, code: Some("interrupted") })]
            }
            Some("response_item") => self.codex_item(record, payload),
            _ => Vec::new(),
        }
    }

    fn codex_item(&mut self, record: &Value, payload: &Value) -> Vec<String> {
        match payload["type"].as_str() {
            Some("message") => {
                let id = codex_id(record, payload);
                let text = codex_text(&payload["content"]);
                match payload["role"].as_str() {
                    // What Codex injects (its environment, instructions) is
                    // filed as tagged user messages.
                    Some("user") if !text.is_empty() && !is_injected(&text) => {
                        vec![self.upsert(Item::User { id, text: clip(&text, MAX_TEXT) })]
                    }
                    Some("assistant") if !text.is_empty() => vec![self.upsert(Item::Agent { id, text: clip(&text, MAX_TEXT) })],
                    _ => Vec::new(),
                }
            }
            Some("function_call") => {
                let args = parse_json(&payload["arguments"]);
                self.codex_call(payload, payload["name"].as_str().unwrap_or("tool"), &args, None)
            }
            Some("local_shell_call") => {
                let command = command_text(&payload["action"]["command"]);
                self.codex_call(payload, "shell", &json!({"command": command}), None)
            }
            Some("custom_tool_call") => {
                let name = payload["name"].as_str().unwrap_or("tool");
                self.codex_call(payload, name, &Value::Null, payload["input"].as_str())
            }
            Some("function_call_output" | "custom_tool_call_output" | "local_shell_call_output") => {
                self.codex_output(payload).into_iter().collect()
            }
            _ => Vec::new(),
        }
    }

    /// A tool call: running until its output arrives.
    fn codex_call(&mut self, payload: &Value, name: &str, args: &Value, input: Option<&str>) -> Vec<String> {
        let Some(call) = payload["call_id"].as_str().filter(|id| !id.is_empty()) else { return Vec::new() };
        if name == "apply_patch" {
            let patch = input.map(str::to_owned).or_else(|| args["input"].as_str().map(str::to_owned)).unwrap_or_default();
            let mut touched = Vec::new();
            for (n, edit) in patch_edits(&patch).into_iter().enumerate() {
                // The first keeps the call's id, so its output finds it.
                let id = if n == 0 { call.to_owned() } else { format!("{call}:{n}") };
                let (state, summary) = (if n == 0 { ToolState::Running } else { ToolState::Done }, edit.path.clone());
                touched.push(self.upsert(Item::Tool {
                    id, name: "Edit".into(), summary, state, output: None, questions: None, answers: None,
                    edit: Some(edit), agent: None,
                }));
            }
            if touched.is_empty() {
                touched.push(self.upsert(tool(call, "Edit", "apply_patch".into(), ToolState::Running)));
            }
            return touched;
        }
        let (shown, summary) = match name {
            "shell" | "exec_command" | "shell_command" | "container.exec" | "local_shell" => {
                let command = args["command"].as_array().map(|_| command_text(&args["command"]))
                    .or_else(|| args["command"].as_str().map(str::to_owned))
                    .or_else(|| args["cmd"].as_str().map(str::to_owned))
                    .unwrap_or_default();
                ("Bash".to_owned(), command)
            }
            other => {
                let first = args.as_object().and_then(|args| args.values().find_map(Value::as_str)).unwrap_or_default();
                (other.to_owned(), first.to_owned())
            }
        };
        vec![self.upsert(tool(call, &shown, clip(summary.trim(), 500), ToolState::Running))]
    }

    fn codex_output(&mut self, payload: &Value) -> Option<String> {
        let call = payload["call_id"].as_str()?;
        let &i = self.index.get(call)?;
        let Item::Tool { id, name, summary, edit, agent, questions, answers, .. } = self.items[i].clone() else { return None };
        let (text, failed) = codex_result(&payload["output"]);
        // An applied patch's output only says it worked; the diff stays.
        let output = (!text.is_empty() && edit.is_none()).then(|| clip_output(&text, self.lang));
        let state = if failed { ToolState::Error } else { ToolState::Done };
        Some(self.upsert(Item::Tool { id, name, summary, state, output, questions, answers, edit, agent }))
    }
}

fn tool(id: &str, name: &str, summary: String, state: ToolState) -> Item {
    Item::Tool { id: id.into(), name: name.into(), summary, state, output: None, questions: None, answers: None, edit: None, agent: None }
}

fn codex_id(record: &Value, payload: &Value) -> String {
    payload["id"]
        .as_str()
        .or_else(|| payload["call_id"].as_str())
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("c{}", record["ordinal"].as_u64().unwrap_or_default()))
}

/// The text of a message's `input_text` and `output_text` blocks.
fn codex_text(content: &Value) -> String {
    let mut text = String::new();
    for block in content.as_array().into_iter().flatten() {
        if matches!(block["type"].as_str(), Some("input_text" | "output_text" | "text")) {
            push_paragraph(&mut text, block["text"].as_str().unwrap_or_default());
        }
    }
    text
}

/// A user message that is one tagged block (`<environment_context>…</…>`):
/// context Codex adds, not what the user typed.
fn is_injected(text: &str) -> bool {
    let text = text.trim();
    text.starts_with('<') && text.ends_with('>')
}

/// A call's `arguments`: a JSON string, or already an object.
fn parse_json(value: &Value) -> Value {
    match value.as_str() {
        Some(text) => serde_json::from_str(text).unwrap_or(Value::Null),
        None => value.clone(),
    }
}

/// A command given as an array, as the line to show: a shell's `-c` script
/// stands for the whole.
fn command_text(command: &Value) -> String {
    let words: Vec<&str> = command.as_array().into_iter().flatten().filter_map(Value::as_str).collect();
    match words.as_slice() {
        [shell, flag, script] if shell.ends_with("sh") && flag.ends_with('c') => (*script).to_owned(),
        _ => words.join(" "),
    }
}

/// A tool output as text, and whether it failed: a plain string, or a JSON
/// object with `output` and a `metadata.exit_code`.
fn codex_result(output: &Value) -> (String, bool) {
    let structured = match output {
        Value::String(text) if text.trim_start().starts_with('{') => serde_json::from_str::<Value>(text).ok(),
        Value::Object(_) => Some(output.clone()),
        _ => None,
    };
    let Some(structured) = structured else { return (output.as_str().unwrap_or_default().to_owned(), false) };
    let text = structured["output"].as_str().or_else(|| structured["content"].as_str()).unwrap_or_default().to_owned();
    let failed = structured["metadata"]["exit_code"].as_i64().is_some_and(|code| code != 0) || structured["success"] == false;
    (text, failed)
}

/// The files an `apply_patch` input changes, each as hunks. Codex's hunks
/// carry no line numbers, so they count from 1.
pub(super) fn patch_edits(input: &str) -> Vec<Edit> {
    struct File {
        path: String,
        created: bool,
        hunks: Vec<(String, Vec<String>)>,
    }
    let mut files: Vec<File> = Vec::new();
    for line in input.lines() {
        if let Some(path) = line.strip_prefix("*** Add File: ") {
            files.push(File { path: path.trim().to_owned(), created: true, hunks: vec![(String::new(), Vec::new())] });
        } else if let Some(path) = line.strip_prefix("*** Update File: ") {
            files.push(File { path: path.trim().to_owned(), created: false, hunks: Vec::new() });
        } else if line.starts_with("*** ") {
            // Begin, End, Delete File, Move to, End of File: no lines of their own.
        } else if let Some(file) = files.last_mut() {
            if let Some(context) = line.strip_prefix("@@") {
                file.hunks.push((context.trim().to_owned(), Vec::new()));
            } else if matches!(line.chars().next(), Some('+' | '-' | ' ')) {
                if file.hunks.is_empty() {
                    file.hunks.push((String::new(), Vec::new()));
                }
                file.hunks.last_mut().expect("a hunk").1.push(line.to_owned());
            }
        }
    }
    files
        .into_iter()
        .map(|file| {
            let mut patch = Patch::default();
            for (context, lines) in &file.hunks {
                let count = |mark: char| lines.iter().filter(|line| line.starts_with(mark)).count() as u64;
                let (added, deleted) = (count('+'), count('-'));
                let kept = lines.len() as u64 - added - deleted;
                patch.added += added;
                patch.deleted += deleted;
                let (old, new) = if file.created { (0, added) } else { (kept + deleted, kept + added) };
                let start = if file.created { 0 } else { 1 };
                let header = format!("@@ -{start},{old} +1,{new} @@ {context}");
                patch.line(header.trim_end());
                for line in lines {
                    patch.line(line);
                }
            }
            Edit { path: file.path, added: patch.added, deleted: patch.deleted, patch: patch.text, created: file.created, truncated: patch.truncated }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conversation(lines: &[&str]) -> Conversation {
        let mut conversation = Conversation::codex(Lang::English);
        conversation.apply(lines.iter().copied());
        conversation
    }

    #[test]
    fn messages_become_user_and_agent_items_and_context_is_left_out() {
        let conversation = conversation(&[
            r#"{"type":"session_meta","payload":{"id":"s1","cwd":"/w/app"}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions>x</permissions>"}]}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"user","id":"m0","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/w/app</cwd>\n</environment_context>"}]}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"user","id":"m1","content":[{"type":"input_text","text":"fix the login"}]}}"#,
            r#"{"type":"response_item","payload":{"type":"reasoning","id":"r1","summary":[],"encrypted_content":null}}"#,
            r#"{"type":"response_item","payload":{"type":"message","role":"assistant","id":"m2","content":[{"type":"output_text","text":"Done **here**."}]}}"#,
            r#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            r#"{"type":"hologram","payload":{}}"#,
        ]);
        assert_eq!(
            conversation.items(),
            &[Item::User { id: "m1".into(), text: "fix the login".into() }, Item::Agent { id: "m2".into(), text: "Done **here**.".into() }]
        );
    }

    #[test]
    fn a_shell_call_runs_until_its_output_arrives() {
        let mut conversation = Conversation::codex(Lang::English);
        let first = conversation.apply([
            r#"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{\"command\":[\"bash\",\"-lc\",\"ls -la\"]}"}}"#,
        ]);
        assert!(matches!(&first[0], Item::Tool { name, summary, state: ToolState::Running, .. } if name == "Bash" && summary == "ls -la"));
        let done = conversation.apply([
            r#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"{\"output\":\"a\\nb\\n\",\"metadata\":{\"exit_code\":0}}"}}"#,
        ]);
        assert!(matches!(&done[0], Item::Tool { state: ToolState::Done, output: Some(output), .. } if output == "a\nb"));
        let failed = conversation.apply([
            r#"{"type":"response_item","payload":{"type":"local_shell_call","call_id":"c2","action":{"type":"exec","command":["false"]}}}"#,
            r#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c2","output":{"output":"","metadata":{"exit_code":1}}}}"#,
        ]);
        assert!(matches!(&failed[0], Item::Tool { summary, state: ToolState::Error, .. } if summary == "false"));
    }

    #[test]
    fn an_apply_patch_call_becomes_edits_with_counts() {
        let input = "*** Begin Patch\n*** Update File: src/a.rs\n@@ fn main\n keep\n-old\n+new\n+more\n*** Add File: docs/b.md\n+# Title\n+text\n*** End Patch";
        let mut conversation = Conversation::codex(Lang::English);
        let changed = conversation.apply([serde_json::to_string(&json!({
            "type": "response_item",
            "payload": {"type": "custom_tool_call", "name": "apply_patch", "call_id": "p1", "input": input}
        })).unwrap().as_str()]);
        assert_eq!(changed.len(), 2);
        let Item::Tool { id, name, edit: Some(first), state, .. } = &changed[0] else { panic!("not an edit") };
        assert_eq!((id.as_str(), name.as_str(), *state), ("p1", "Edit", ToolState::Running));
        assert_eq!((first.path.as_str(), first.added, first.deleted, first.created), ("src/a.rs", 2, 1, false));
        assert!(first.patch.starts_with("@@ -1,2 +1,3 @@ fn main\n keep\n-old\n+new\n+more\n"));
        let Item::Tool { id, edit: Some(second), .. } = &changed[1] else { panic!("not an edit") };
        assert_eq!(id, "p1:1");
        assert_eq!((second.path.as_str(), second.added, second.created), ("docs/b.md", 2, true));
        assert!(second.patch.starts_with("@@ -0,0 +1,2 @@\n+# Title\n"));
        // Its output ends the call and keeps the diff.
        let done = conversation.apply([r#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"p1","output":"Success. Updated the following files:\nM src/a.rs"}}"#]);
        assert!(matches!(&done[0], Item::Tool { state: ToolState::Done, output: None, edit: Some(_), .. }));
    }

    #[test]
    fn the_model_and_an_aborted_turn_are_noted() {
        let conversation = conversation(&[
            r#"{"type":"turn_context","payload":{"model":"gpt-x","cwd":"/w"}}"#,
            r#"{"type":"event_msg","ordinal":7,"payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
        ]);
        assert_eq!(conversation.model(), Some("gpt-x"));
        assert!(matches!(&conversation.items()[0], Item::Notice { code: Some("interrupted"), .. }));
    }

    #[test]
    fn broken_and_unknown_lines_are_skipped() {
        let conversation = conversation(&["not json", "{}", r#"{"type":"response_item","payload":{"type":"web_search_call"}}"#, r#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"nope","output":"x"}}"#]);
        assert!(conversation.items().is_empty());
    }
}
