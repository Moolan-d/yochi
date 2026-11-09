//! Finds the Claude Code transcript of the program in a terminal and reads
//! what it appends, all through the core's `file.read`, so remote machines
//! need nothing installed. The terminal's foreground pid names Claude Code's
//! own registry file, `~/.claude/sessions/<pid>.json`, which holds the
//! current session id (renewed by `/clear`) and the launch folder that keys
//! the transcript's directory.

use crate::core::{Client, error_kind};
use anyhow::{Result, bail};
use serde_json::{Value, json};

/// How far back the first read goes; older lines are not shown.
const WINDOW_LINES: usize = 2000;

/// Where a terminal's transcript is, as far as Claude Code's registry says.
#[derive(Clone, Debug, PartialEq)]
pub struct Located {
    pub session_id: String,
    pub path: String,
}

/// Paths on this Mac are absolute from the Gateway's home (the same user as
/// the core); on another machine they are relative, which `file.read`
/// starts from that machine's home.
fn claude_path(machine: Option<&str>, rest: &str) -> String {
    match machine {
        Some(_) => format!(".claude/{rest}"),
        None => format!("{}/.claude/{rest}", std::env::var("HOME").unwrap_or_default()),
    }
}

/// Claude Code's directory name for a launch folder. Very long folders get a
/// hashed name instead, which isn't reproduced here.
pub fn project_key(cwd: &str) -> Option<String> {
    let key: String = cwd.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    (key.len() <= 200).then_some(key)
}

/// None when the terminal's foreground process isn't a Claude Code session.
pub async fn locate(client: &mut Client, machine: Option<&str>, pid: u64) -> Result<Option<Located>> {
    let registry = claude_path(machine, &format!("sessions/{pid}.json"));
    let text = match read(client, machine, &registry, None, None).await? {
        Some(read) => read.text,
        None => return Ok(None),
    };
    let Ok(record) = serde_json::from_str::<Value>(&text) else { return Ok(None) };
    let (Some(session_id), Some(cwd)) = (record["sessionId"].as_str(), record["cwd"].as_str()) else {
        return Ok(None);
    };
    let Some(key) = project_key(cwd) else { return Ok(None) };
    let path = claude_path(machine, &format!("projects/{key}/{session_id}.jsonl"));
    Ok(Some(Located { session_id: session_id.to_owned(), path }))
}

/// Follows one transcript file by line number.
pub struct Tail {
    machine: Option<String>,
    path: String,
    /// Lines already handed on.
    pub seen: usize,
}

impl Tail {
    pub fn new(machine: Option<&str>, located: &Located) -> Self {
        Self { machine: machine.map(str::to_owned), path: located.path.clone(), seen: 0 }
    }

    /// The last [`WINDOW_LINES`] lines, or nothing yet: Claude Code writes the
    /// file only once the first message is sent.
    pub async fn start(&mut self, client: &mut Client) -> Result<Vec<String>> {
        self.start_last(client, WINDOW_LINES).await
    }

    /// Like [`start`](Self::start), from the last `window` lines.
    pub async fn start_last(&mut self, client: &mut Client, window: usize) -> Result<Vec<String>> {
        let Some(probe) = read(client, self.machine.as_deref(), &self.path, Some(1), Some(1)).await? else {
            return Ok(Vec::new());
        };
        self.seen = probe.lines.saturating_sub(window);
        self.more(client).await
    }

    /// Whole lines appended since the last call. A line still being written
    /// waits for the next call.
    pub async fn more(&mut self, client: &mut Client) -> Result<Vec<String>> {
        let mut out = Vec::new();
        loop {
            // Reading from the last line already seen, not the one after it:
            // the core refuses an offset past the end of the file.
            let from = self.seen.max(1);
            let Some(read) = read(client, self.machine.as_deref(), &self.path, Some(from), None).await? else {
                return Ok(out);
            };
            if read.lines < self.seen {
                bail!("{} got shorter", self.path);
            }
            let mut lines: Vec<&str> = read.text.split_inclusive('\n').collect();
            if self.seen > 0 && !lines.is_empty() {
                lines.remove(0);
            }
            let mut taken = 0;
            for line in lines {
                let Some(line) = line.strip_suffix('\n') else { break };
                out.push(line.to_owned());
                taken += 1;
            }
            self.seen += taken;
            // A reply is capped at 8 MB; keep going until caught up.
            if read.last >= read.lines || taken == 0 {
                return Ok(out);
            }
        }
    }
}

struct Read {
    text: String,
    last: usize,
    lines: usize,
}

/// None when the file doesn't exist.
async fn read(
    client: &mut Client,
    machine: Option<&str>,
    path: &str,
    offset: Option<usize>,
    limit: Option<usize>,
) -> Result<Option<Read>> {
    let params = json!({"path": path, "on": machine, "offset": offset, "limit": limit});
    match client.call("file.read", params).await? {
        Ok(result) => Ok(Some(Read {
            text: result["text"].as_str().unwrap_or_default().to_owned(),
            last: result["last"].as_u64().unwrap_or(0) as usize,
            lines: result["lines"].as_u64().unwrap_or(0) as usize,
        })),
        Err(error) if error_kind(&error) == "not_found" => Ok(None),
        Err(error) => bail!("reading {path}: {}", error["message"].as_str().unwrap_or("file.read failed")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_key_replaces_every_non_alphanumeric() {
        assert_eq!(project_key("/private/tmp/companion-conv-exp/work").unwrap(), "-private-tmp-companion-conv-exp-work");
        assert_eq!(project_key("/Users/ryan/my.app_2").unwrap(), "-Users-ryan-my-app-2");
        assert_eq!(project_key("/a/界").unwrap(), "-a--");
        assert_eq!(project_key(&format!("/{}", "x".repeat(250))), None);
    }

    #[test]
    fn remote_paths_start_at_that_machines_home() {
        assert_eq!(claude_path(Some("vps"), "sessions/7.json"), ".claude/sessions/7.json");
        assert!(claude_path(None, "sessions/7.json").ends_with("/.claude/sessions/7.json"));
        assert!(claude_path(None, "x").starts_with('/'));
    }
}
