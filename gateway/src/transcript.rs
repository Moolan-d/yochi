//! Finds the Claude Code transcript of the program in a terminal and reads
//! what it appends, all through the core's `file.read`, so remote machines
//! need nothing installed. The terminal's foreground pid names Claude Code's
//! own registry file, `~/.claude/sessions/<pid>.json`, which holds the
//! current session id (renewed by `/clear`) and the launch folder that keys
//! the transcript's directory.

use crate::conversation::Dialect;
use crate::core::{Client, error_kind};
use crate::session::Session;
use anyhow::{Result, bail};
use serde_json::{Value, json};

/// How far back the first read goes; older lines are not shown.
const WINDOW_LINES: usize = 2000;

/// Where a terminal's transcript is, as far as Claude Code's registry says,
/// or the file Codex or pi has open.
#[derive(Clone, Debug, PartialEq)]
pub struct Located {
    pub dialect: Dialect,
    pub session_id: String,
    pub path: String,
}

/// The Agents whose transcripts the Gateway reads, by the command or program
/// in the terminal.
pub fn dialect_of(session: &Session) -> Option<Dialect> {
    Dialect::of(session.program.as_deref(), session.command.as_deref())
}

/// Codex and pi have no registry by pid: the file they write is open in
/// their process (or a child of it). A fixed read-only script, run through
/// core's `machine.exec` on the session's machine, finds it; failing that, pi's
/// newest file for the folder (its sessions live in a folder named after it).
/// Prints the path, relative to the home folder for another machine.
const FIND_SCRIPT: &str = r#"
pid="$1"; mode="$2"; dir="$3"
pids="$pid $(pgrep -P "$pid" 2>/dev/null)"
for q in $pids; do pids="$pids $(pgrep -P "$q" 2>/dev/null)"; done
found=
for q in $pids; do
  f=$(lsof -nP -p "$q" -Fn 2>/dev/null | sed -n 's/^n//p' | grep -m1 -E '/(\.codex|\.pi/agent)/sessions/.*\.jsonl$')
  [ -n "$f" ] || f=$(ls -l /proc/"$q"/fd 2>/dev/null | grep -o -E '/[^ ]*/(\.codex|\.pi/agent)/sessions/[^ ]*\.jsonl' | head -1)
  if [ -n "$f" ]; then found=$f; break; fi
done
if [ -z "$found" ] && [ -n "$dir" ]; then found=$(ls -t "$HOME"/.pi/agent/sessions/"$dir"/*.jsonl 2>/dev/null | head -1); fi
[ -n "$found" ] || exit 3
if [ "$mode" = rel ]; then found=${found#"$HOME"/}; fi
printf '%s' "$found"
"#;

/// pi's folder name for a working directory: `/Users/me/app` is `--Users-me-app--`.
pub fn pi_folder(cwd: &str) -> Option<String> {
    let inner: String = cwd.trim_matches('/').chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '_' { c } else { '-' }).collect();
    (!inner.is_empty() && inner.len() <= 200).then(|| format!("--{inner}--"))
}

async fn locate_open_file(client: &mut Client, session: &Session, pid: u64, dialect: Dialect) -> Result<Option<Located>> {
    let machine = session.machine.as_deref();
    let dir = if dialect == Dialect::Pi { pi_folder(&session.cwd).unwrap_or_default() } else { String::new() };
    let mut params = json!({
        "argv": ["sh", "-c", FIND_SCRIPT, "sh", pid.to_string(), if machine.is_some() { "rel" } else { "abs" }, dir],
        "cwd": "/",
        "timeout": 5,
    });
    if let Some(machine) = machine {
        params["on"] = json!(machine);
    }
    let Ok(result) = client.call("machine.exec", params).await? else { return Ok(None) };
    if result["code"].as_i64() != Some(0) {
        return Ok(None);
    }
    let path = result["stdout"]
        .as_str()
        .and_then(|data| base64::Engine::decode(&base64::engine::general_purpose::STANDARD, data).ok())
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .map(|path| path.trim().to_owned())
        .filter(|path| path.ends_with(".jsonl") && !path.contains('\n'));
    Ok(path.map(|path| Located { dialect, session_id: path.clone(), path }))
}

/// The transcript of the Agent in this terminal, whichever Agent it is.
pub async fn locate_for(client: &mut Client, session: &Session, pid: u64) -> Result<Option<Located>> {
    match dialect_of(session) {
        Some(Dialect::Claude) | None => locate(client, session.machine.as_deref(), pid).await,
        Some(dialect) => locate_open_file(client, session, pid, dialect).await,
    }
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
    Ok(Some(Located { dialect: Dialect::Claude, session_id: session_id.to_owned(), path }))
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
        assert_eq!(project_key("/Users/me/my.app_2").unwrap(), "-Users-me-my-app-2");
        assert_eq!(project_key("/a/界").unwrap(), "-a--");
        assert_eq!(project_key(&format!("/{}", "x".repeat(250))), None);
    }

    #[test]
    fn pi_names_a_folder_after_the_working_directory() {
        assert_eq!(pi_folder("/Users/me/app").as_deref(), Some("--Users-me-app--"));
        assert_eq!(pi_folder("/srv/work").as_deref(), Some("--srv-work--"));
        assert_eq!(pi_folder("/a b/c;d").as_deref(), Some("--a-b-c-d--"), "nothing a shell would read");
        assert_eq!(pi_folder("/"), None);
    }

    #[test]
    fn the_agent_is_told_by_its_command_or_program() {
        let session = |program: Option<&str>, command: Option<&str>| {
            let mut value = json!({"address": "t1", "state": "live", "argv": [], "foreground": null});
            if let Some(command) = command {
                value["argv"] = json!([command]);
            }
            let mut session = Session::from_record(&value).unwrap();
            session.program = program.map(str::to_owned);
            session.command = command.map(str::to_owned);
            session
        };
        assert_eq!(dialect_of(&session(Some("claude"), None)), Some(Dialect::Claude));
        assert_eq!(dialect_of(&session(Some("zsh"), Some("Codex"))), None);
        assert_eq!(dialect_of(&session(Some("zsh"), Some("Pi"))), Some(Dialect::Pi));
        assert_eq!(dialect_of(&session(Some("pi"), None)), Some(Dialect::Pi));
        assert_eq!(dialect_of(&session(Some("htop"), Some("htop"))), None);
    }

    #[test]
    fn remote_paths_start_at_that_machines_home() {
        assert_eq!(claude_path(Some("vps"), "sessions/7.json"), ".claude/sessions/7.json");
        assert!(claude_path(None, "sessions/7.json").ends_with("/.claude/sessions/7.json"));
        assert!(claude_path(None, "x").starts_with('/'));
    }
}
