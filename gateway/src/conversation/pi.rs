//! pi session lines (`~/.pi/agent/sessions/--<folder>--/*.jsonl`) as items:
//! the user's messages, the Agent's replies and its tool calls (`bash`,
//! `read`, `write`, `edit`, anything else by name) with their results. The
//! model's thinking, usage and system messages never leave the Gateway;
//! record types it doesn't know are skipped.

use super::*;

impl Conversation {
    pub(super) fn pi_record(&mut self, record: &Value) -> Vec<String> {
        match record["type"].as_str() {
            Some("model_change") => {
                if let Some(model) = record["modelId"].as_str().filter(|model| !model.is_empty()) {
                    self.model = Some(model.to_owned());
                }
                Vec::new()
            }
            Some("message") => self.pi_message(record, &record["message"]),
            _ => Vec::new(),
        }
    }

    fn pi_message(&mut self, record: &Value, message: &Value) -> Vec<String> {
        let id = record["id"].as_str().filter(|id| !id.is_empty()).unwrap_or_default().to_owned();
        match message["role"].as_str() {
            Some("user") => {
                let text = pi_text(&message["content"], self.lang);
                if id.is_empty() || text.is_empty() {
                    return Vec::new();
                }
                vec![self.upsert(Item::User { id, text: clip(&text, MAX_TEXT) })]
            }
            Some("assistant") => {
                if let Some(model) = message["model"].as_str().filter(|model| !model.is_empty()) {
                    self.model = Some(model.to_owned());
                }
                let mut touched = Vec::new();
                let text = pi_text(&message["content"], self.lang);
                if !text.is_empty() && !id.is_empty() {
                    touched.push(self.upsert(Item::Agent { id: id.clone(), text: clip(&text, MAX_TEXT) }));
                }
                for block in message["content"].as_array().into_iter().flatten() {
                    if block["type"] == "toolCall" {
                        touched.extend(self.pi_call(block));
                    }
                }
                if let Some(error) = message["errorMessage"].as_str().filter(|error| !error.trim().is_empty())
                    && !id.is_empty()
                {
                    // Stopped by the user, in the phone's language; anything
                    // else as its first line (some are a page of HTML).
                    let (text, code) = if message["stopReason"] == "aborted" {
                        (self.lang.pick("已中断", "Interrupted").to_owned(), Some("interrupted"))
                    } else {
                        (clip(error.trim().lines().next().unwrap_or_default().trim(), 300), None)
                    };
                    // pi retries a failed request, and each try is a record:
                    // the same failure in a row is said once.
                    let repeated = matches!(self.items.last(), Some(Item::Notice { text: last, .. }) if *last == text);
                    if !repeated {
                        touched.push(self.upsert(Item::Notice { id: format!("{id}:error"), text, code }));
                    }
                }
                touched
            }
            Some("toolResult") => self.pi_result(message).into_iter().collect(),
            _ => Vec::new(),
        }
    }

    fn pi_call(&mut self, block: &Value) -> Option<String> {
        let id = block["id"].as_str().filter(|id| !id.is_empty())?;
        let args = &block["arguments"];
        let field = |key: &str| args[key].as_str().map(str::to_owned);
        let (name, summary) = match block["name"].as_str().unwrap_or("tool") {
            "bash" => ("Bash".to_owned(), field("command")),
            "read" => ("Read".to_owned(), field("path")),
            "write" => ("Write".to_owned(), field("path")),
            "edit" => ("Edit".to_owned(), field("path")),
            other => (other.to_owned(), args.as_object().and_then(|args| args.values().find_map(Value::as_str)).map(str::to_owned)),
        };
        let summary = clip(summary.unwrap_or_default().trim(), 500);
        // A new file's text is known at once; an edit's diff comes with its result.
        let edit = (name == "Write").then(|| written(&summary, args["content"].as_str().unwrap_or_default()));
        Some(self.upsert(Item::Tool {
            id: id.into(), name, summary, state: ToolState::Running, output: None, questions: None, answers: None, edit, agent: None,
        }))
    }

    fn pi_result(&mut self, message: &Value) -> Option<String> {
        let call = message["toolCallId"].as_str()?;
        let &i = self.index.get(call)?;
        let Item::Tool { id, name, summary, edit, agent, questions, answers, .. } = self.items[i].clone() else { return None };
        let failed = message["isError"] == true;
        let text = pi_text(&message["content"], self.lang);
        let edit = if failed {
            None
        } else if name == "Edit" {
            message["details"]["patch"].as_str().and_then(|patch| diff_edit(&summary, patch)).or(edit)
        } else {
            edit
        };
        // A file's text or diff is on the card already; a failure says why.
        let output = (!text.is_empty() && (edit.is_none() || failed)).then(|| clip_output(&text, self.lang));
        let state = if failed { ToolState::Error } else { ToolState::Done };
        Some(self.upsert(Item::Tool { id, name, summary, state, output, questions, answers, edit, agent }))
    }
}

/// The text blocks of a message's content (a string, or blocks).
fn pi_text(content: &Value, lang: Lang) -> String {
    if let Some(text) = content.as_str() {
        return text.trim().to_owned();
    }
    let mut text = String::new();
    for block in content.as_array().into_iter().flatten() {
        match block["type"].as_str() {
            Some("text") => push_paragraph(&mut text, block["text"].as_str().unwrap_or_default()),
            Some("image") => push_paragraph(&mut text, image(lang)),
            _ => {}
        }
    }
    text
}

/// A written file as an edit that is all additions.
fn written(path: &str, content: &str) -> Edit {
    let mut patch = Patch::default();
    let lines: Vec<&str> = content.lines().collect();
    if !lines.is_empty() {
        patch.line(&format!("@@ -0,0 +1,{} @@", lines.len()));
    }
    for line in lines {
        patch.added += 1;
        patch.line(&format!("+{line}"));
    }
    Edit { path: path.to_owned(), added: patch.added, deleted: 0, patch: patch.text, created: true, truncated: patch.truncated }
}

/// A unified diff with its file headers, as the hunks only; None when it has no hunk.
fn diff_edit(path: &str, diff: &str) -> Option<Edit> {
    let mut patch = Patch::default();
    let mut in_hunk = false;
    for line in diff.lines() {
        if line.starts_with("@@") {
            in_hunk = true;
        }
        if !in_hunk {
            continue;
        }
        match line.chars().next() {
            Some('+') => patch.added += 1,
            Some('-') => patch.deleted += 1,
            _ => {}
        }
        patch.line(line);
    }
    in_hunk.then(|| Edit { path: path.to_owned(), added: patch.added, deleted: patch.deleted, patch: patch.text, created: false, truncated: patch.truncated })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_calls_and_results_become_items() {
        let mut conversation = Conversation::pi(Lang::English);
        conversation.apply([
            r#"{"type":"session","id":"s","cwd":"/w/app","version":3}"#,
            r#"{"type":"model_change","id":"mc","provider":"p","modelId":"model-a"}"#,
            r#"{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"list files"}]}}"#,
            r#"{"type":"message","id":"a1","message":{"role":"assistant","model":"model-b","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."},{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"ls","timeout":5}}]}}"#,
            r#"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"t1","toolName":"bash","isError":false,"content":[{"type":"text","text":"a\nb"}]}}"#,
            r#"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"text","text":"Two files."}]}}"#,
            r#"{"type":"message","id":"s1","message":{"role":"system","content":"x"}}"#,
        ]);
        assert_eq!(conversation.model(), Some("model-b"));
        let items = conversation.items();
        assert_eq!(items.len(), 4);
        assert_eq!(items[0], Item::User { id: "u1".into(), text: "list files".into() });
        assert_eq!(items[1], Item::Agent { id: "a1".into(), text: "Looking.".into() });
        assert!(matches!(&items[2], Item::Tool { id, name, summary, state: ToolState::Done, output: Some(output), .. }
            if id == "t1" && name == "Bash" && summary == "ls" && output == "a\nb"));
        assert_eq!(items[3], Item::Agent { id: "a2".into(), text: "Two files.".into() });
    }

    #[test]
    fn an_edit_takes_its_diff_from_the_result_and_a_write_shows_its_text() {
        let mut conversation = Conversation::pi(Lang::English);
        let changed = conversation.apply([
            r#"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"e1","name":"edit","arguments":{"path":"/w/a.md","edits":[]}},{"type":"toolCall","id":"w1","name":"write","arguments":{"path":"/w/b.md","content":"x\ny"}}]}}"#,
            &serde_json::to_string(&json!({"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"e1","toolName":"edit","isError":false,
                "content":[{"type":"text","text":"Edited"}],
                "details":{"patch":"--- /w/a.md\n+++ /w/a.md\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"}}})).unwrap(),
        ]);
        let Item::Tool { edit: Some(edit), state, output, .. } = &changed[0] else { panic!("no edit") };
        assert_eq!((edit.path.as_str(), edit.added, edit.deleted, *state, output.is_none()), ("/w/a.md", 1, 1, ToolState::Done, true));
        assert_eq!(edit.patch, "@@ -1,2 +1,2 @@\n keep\n-old\n+new\n");
        let Item::Tool { edit: Some(written), state, .. } = &changed[1] else { panic!("no write") };
        assert_eq!((written.created, written.added, *state), (true, 2, ToolState::Running));
    }

    #[test]
    fn failures_errors_and_unknown_records_are_handled() {
        let mut conversation = Conversation::pi(Lang::English);
        conversation.apply([
            r#"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"toolCall","id":"t1","name":"bash","arguments":{"command":"false"}}]}}"#,
            r#"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"t1","isError":true,"content":[{"type":"text","text":"exit 1"}]}}"#,
            r#"{"type":"message","id":"a2","message":{"role":"assistant","content":[],"errorMessage":"rate limited"}}"#,
            r#"{"type":"context_edit","id":"x"}"#,
            "not json",
        ]);
        let items = conversation.items();
        assert!(matches!(&items[0], Item::Tool { state: ToolState::Error, output: Some(_), .. }));
        assert!(matches!(&items[1], Item::Notice { text, code: None, .. } if text == "rate limited"));
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn retried_failures_are_said_once_and_a_stop_is_an_interruption() {
        let mut conversation = Conversation::pi(Lang::English);
        conversation.apply([
            r#"{"type":"message","id":"a1","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"API error (401): 401 <html>\r\n<head>"}}"#,
            r#"{"type":"message","id":"a2","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"API error (401): 401 <html>\r\n<head>"}}"#,
            r#"{"type":"message","id":"a3","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"}],"stopReason":"aborted","errorMessage":"Operation aborted"}}"#,
            r#"{"type":"message","id":"a4","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"API error (401): 401 <html>\r\n<head>"}}"#,
        ]);
        let items = conversation.items();
        assert_eq!(items.len(), 3, "{items:?}");
        assert!(matches!(&items[0], Item::Notice { id, text, code: None } if id == "a1:error" && text == "API error (401): 401 <html>"));
        assert!(matches!(&items[1], Item::Notice { text, code: Some("interrupted"), .. } if text == "Interrupted"));
        assert!(matches!(&items[2], Item::Notice { id, .. } if id == "a4:error"));
    }
}
