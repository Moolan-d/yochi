//! The custom slash commands and skills a Claude Code session can use, for
//! the phone's slash completion. One fixed script runs through core's
//! `machine.exec` in the session's directory, on its machine, and prints the
//! head of each command or skill file; the Gateway reads their frontmatter.
//! Built-in commands are the app's own list; plugins are not listed.

use crate::exec::{Program, exec};
use crate::herdr::CoreView;
use serde::Serialize;
use std::collections::HashSet;
use tokio::sync::watch;

const SCRIPT_TIMEOUT_SECS: u64 = 10;
pub const MAX_COMMANDS: usize = 200;
const MAX_DESCRIPTION_CHARS: usize = 120;

/// Each file as a record separator, its source and path, then its first lines.
/// Project files come first, so they win over personal ones of the same name.
const SCRIPT: &str = r#"p() { for f in "$@"; do [ -f "$f" ] || continue; printf '\036%s\t%s\n' "$src" "$f"; head -n 40 "$f" | head -c 4000; echo; done; }
src=project; p .claude/commands/*.md
src=user; p "$HOME"/.claude/commands/*.md
src=skill; p .claude/skills/*/SKILL.md "$HOME"/.claude/skills/*/SKILL.md
"#;

pub struct Request {
    pub id: String,
    pub session: String,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Command {
    /// With its slash, e.g. `/research`.
    pub name: String,
    pub description: String,
    /// project, user or skill.
    pub source: String,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    CommandList { id: String, commands: Vec<Command> },
    CommandsFailed { id: String, kind: String, message: String },
}

pub async fn list(hc: &str, view: &watch::Receiver<CoreView>, request: Request) -> Response {
    let failed = |kind: &str, message: String| Response::CommandsFailed { id: request.id.clone(), kind: kind.into(), message };
    let Some((machine, cwd)) = view
        .borrow()
        .sessions
        .iter()
        .find(|session| session.id == request.session)
        .map(|session| (session.machine.clone(), session.cwd.clone()))
    else {
        return failed("not_found", "会话不存在或已结束".into());
    };
    match exec(hc, machine.as_deref(), &cwd, Program::Line(SCRIPT), None, SCRIPT_TIMEOUT_SECS).await {
        Ok(output) if output.cut => failed("timeout", "列命令超时".into()),
        Ok(output) => Response::CommandList { id: request.id, commands: parse(&String::from_utf8_lossy(&output.stdout)) },
        Err(failure) => failed(&failure.kind, failure.message),
    }
}

/// The script's output as commands, by name, the first of each name kept.
fn parse(output: &str) -> Vec<Command> {
    let mut seen = HashSet::new();
    let mut commands: Vec<Command> = output
        .split('\u{1e}')
        .filter_map(|record| {
            let (header, content) = record.split_once('\n').unwrap_or((record, ""));
            let (source, path) = header.split_once('\t')?;
            let fields = frontmatter(content);
            let stem = if source == "skill" {
                path.rsplit('/').nth(1)?
            } else {
                path.rsplit('/').next()?.strip_suffix(".md")?
            };
            let name = match (source, fields.name) {
                ("skill", Some(name)) if !name.is_empty() => name,
                _ => stem.to_owned(),
            };
            let description = fields.description.unwrap_or_else(|| first_line(fields.body));
            Some(Command {
                name: format!("/{name}"),
                description: description.chars().take(MAX_DESCRIPTION_CHARS).collect(),
                source: source.to_owned(),
            })
        })
        .filter(|command| seen.insert(command.name.clone()))
        .collect();
    commands.sort_by(|a, b| a.name.cmp(&b.name));
    commands.truncate(MAX_COMMANDS);
    commands
}

struct Fields<'a> {
    name: Option<String>,
    description: Option<String>,
    body: &'a str,
}

/// `name` and `description` from a leading `---` block, with folded or
/// literal (`>`, `|`) descriptions joined into one line.
fn frontmatter(content: &str) -> Fields<'_> {
    let mut fields = Fields { name: None, description: None, body: content };
    let Some(rest) = content.strip_prefix("---\n") else { return fields };
    let (block, body) = match rest.find("\n---") {
        Some(end) => (&rest[..end], rest[end + 4..].trim_start_matches(['-', '\n'])),
        None => (rest, ""),
    };
    fields.body = body;
    let lines: Vec<&str> = block.lines().collect();
    for (index, line) in lines.iter().enumerate() {
        let Some((key, value)) = line.split_once(':') else { continue };
        if key.starts_with([' ', '\t']) {
            continue;
        }
        let value = value.trim();
        let value = if value.is_empty() || value.starts_with(['>', '|']) {
            lines[index + 1..]
                .iter()
                .take_while(|line| line.starts_with([' ', '\t']) || line.is_empty())
                .map(|line| line.trim())
                .filter(|line| !line.is_empty())
                .collect::<Vec<_>>()
                .join(" ")
        } else {
            unquote(value).to_owned()
        };
        match key.trim() {
            "name" => fields.name = Some(value),
            "description" => fields.description = Some(value),
            _ => {}
        }
    }
    fields
}

fn unquote(value: &str) -> &str {
    for quote in ['"', '\''] {
        if let Some(inner) = value.strip_prefix(quote).and_then(|v| v.strip_suffix(quote)) {
            return inner;
        }
    }
    value
}

/// A command file without a description: its first line of text, as Claude Code shows it.
fn first_line(body: &str) -> String {
    body.lines()
        .map(|line| line.trim().trim_start_matches('#').trim())
        .find(|line| !line.is_empty())
        .unwrap_or("")
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(name: &str, description: &str, source: &str) -> Command {
        Command { name: name.into(), description: description.into(), source: source.into() }
    }

    #[test]
    fn reads_commands_and_skills_from_the_script_output() {
        let output = "\u{1e}project\t.claude/commands/ship.md\n---\ndescription: \"Ship it\"\n---\nRun the release.\n\n\
            \u{1e}user\t/home/me/.claude/commands/notes.md\n# Write notes\nMore.\n\n\
            \u{1e}user\t/home/me/.claude/commands/ship.md\n---\ndescription: Personal ship\n---\n\n\
            \u{1e}skill\t/home/me/.claude/skills/research/SKILL.md\n---\nname: research\ndescription: >\n  Investigate a question\n  against sources.\nallowed-tools: Read\n---\nBody\n\n\
            \u{1e}skill\t.claude/skills/run-app/SKILL.md\n---\ndescription: 'Launch it'\n---\n\n";
        assert_eq!(
            parse(output),
            [
                command("/notes", "Write notes", "user"),
                command("/research", "Investigate a question against sources.", "skill"),
                command("/run-app", "Launch it", "skill"),
                command("/ship", "Ship it", "project"),
            ]
        );
    }

    #[test]
    fn caps_descriptions_and_count() {
        let long = "x".repeat(300);
        let mut output = String::new();
        for i in 0..250 {
            output.push_str(&format!("\u{1e}user\t/c/{i:03}.md\n---\ndescription: {long}\n---\n"));
        }
        let commands = parse(&output);
        assert_eq!(commands.len(), MAX_COMMANDS);
        assert_eq!(commands[0].description.chars().count(), MAX_DESCRIPTION_CHARS);
    }

    /// The script itself, against a sample home and project.
    #[test]
    fn script_lists_the_sample_tree() {
        let root = std::env::temp_dir().join(format!("companion-commands-{}", std::process::id()));
        let home = root.join("home");
        let project = root.join("project");
        for dir in [home.join(".claude/commands"), home.join(".claude/skills/tdd"), project.join(".claude/commands")] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(home.join(".claude/commands/notes.md"), "Write notes\n").unwrap();
        std::fs::write(home.join(".claude/skills/tdd/SKILL.md"), "---\nname: tdd\ndescription: Test first\n---\n").unwrap();
        std::fs::write(project.join(".claude/commands/ship.md"), "---\ndescription: Ship\n---\n").unwrap();
        let output = std::process::Command::new("sh")
            .args(["-c", SCRIPT])
            .current_dir(&project)
            .env("HOME", &home)
            .output()
            .unwrap();
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(
            parse(&String::from_utf8_lossy(&output.stdout)),
            [
                command("/notes", "Write notes", "user"),
                command("/ship", "Ship", "project"),
                command("/tdd", "Test first", "skill"),
            ]
        );
    }
}
