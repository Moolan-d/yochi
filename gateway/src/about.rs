//! What the home page shows beside each session that the core doesn't keep:
//! the git repository (and worktree) its folder is in, and the to-do a
//! working Claude Code is on. Both are read on the session's machine through
//! the core, so nothing is installed there.

use crate::changes;
use crate::conversation::Conversation;
use crate::core::Client;
use crate::herdr::CoreView;
use crate::session::Session;
use crate::transcript::{self, Located, Tail};
use anyhow::Result;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::watch;

/// How often a working Agent's transcript is read again.
const TICK: Duration = Duration::from_secs(2);
/// When git couldn't be asked (machine away, timeout), ask again after this.
const RETRY: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Repo {
    /// The main checkout's folder name.
    pub name: String,
    /// The linked worktree's folder name, when the folder is in one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct TodoNow {
    /// The item in progress, as the Agent words it while doing it.
    pub text: String,
    pub done: usize,
    pub total: usize,
}

/// By session id.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct About {
    pub repos: HashMap<String, Repo>,
    pub todos: HashMap<String, TodoNow>,
}

impl About {
    /// The sessions as the app gets them.
    pub fn fill(&self, sessions: &[Session]) -> Vec<Session> {
        sessions
            .iter()
            .cloned()
            .map(|mut session| {
                session.repo = self.repos.get(&session.id).cloned();
                session.todo = self.todos.get(&session.id).cloned();
                session
            })
            .collect()
    }
}

/// Keeps `about` current with the core's sessions: each folder's repository
/// once, and while an Agent works, its to-do every [`TICK`].
pub async fn run(hc: Arc<str>, mut view: watch::Receiver<CoreView>, about: watch::Sender<About>) {
    let mut repos: HashMap<(Option<String>, String), Lookup> = HashMap::new();
    let mut trackers: HashMap<String, Tracker> = HashMap::new();
    let mut client: Option<Client> = None;
    loop {
        let sessions = view.borrow_and_update().sessions.clone();
        let mut next = About::default();
        for session in sessions.iter().filter(|s| !s.cwd.is_empty()) {
            let key = (session.machine.clone(), session.cwd.clone());
            if repos.get(&key).is_none_or(Lookup::stale) {
                repos.insert(key.clone(), lookup(&hc, session.machine.as_deref(), &session.cwd).await);
            }
            if let Some(Lookup::Found(Some(repo))) = repos.get(&key) {
                next.repos.insert(session.id.clone(), repo.clone());
            }
        }

        let working: Vec<&Session> = sessions.iter().filter(|s| s.status.as_ref().is_some_and(|s| s.state == "working")).collect();
        trackers.retain(|id, _| working.iter().any(|s| &s.id == id));
        if !working.is_empty() && client.is_none() {
            client = Client::connect(&hc).await.inspect_err(|err| eprintln!("about: {err:#}")).ok();
        }
        if let Some(connected) = client.as_mut() {
            let mut broken = false;
            for session in &working {
                match trackers.entry(session.id.clone()).or_default().tick(connected, session).await {
                    Ok(Some(todo)) => {
                        next.todos.insert(session.id.clone(), todo);
                    }
                    Ok(None) => {}
                    Err(err) => {
                        eprintln!("about: {err:#}");
                        broken = true;
                        break;
                    }
                }
            }
            if broken || working.is_empty() {
                client = None;
            }
        }

        about.send_if_modified(|current| {
            let changed = *current != next;
            if changed {
                *current = next;
            }
            changed
        });
        if trackers.is_empty() {
            if view.changed().await.is_err() {
                return;
            }
        } else {
            // Titles change often while an Agent works; read on a steady beat instead.
            tokio::time::sleep(TICK).await;
        }
    }
}

enum Lookup {
    Found(Option<Repo>),
    Failed(Instant),
}

impl Lookup {
    fn stale(&self) -> bool {
        matches!(self, Self::Failed(at) if at.elapsed() >= RETRY)
    }
}

async fn lookup(hc: &str, machine: Option<&str>, cwd: &str) -> Lookup {
    match changes::git(hc, machine, cwd, &["rev-parse", "--show-toplevel", "--git-common-dir"]).await {
        Ok(output) if output.code == Some(0) => Lookup::Found(parse_repo(cwd, &String::from_utf8_lossy(&output.stdout))),
        // Not in a repository, or a bare one.
        Ok(_) => Lookup::Found(None),
        Err(failure) => {
            eprintln!("about: git in {cwd}: {}", failure.message);
            Lookup::Failed(Instant::now())
        }
    }
}

/// `git rev-parse --show-toplevel --git-common-dir` run in `cwd`: the
/// checkout's root, then the repository's shared git directory (relative to
/// `cwd` unless git says otherwise).
fn parse_repo(cwd: &str, output: &str) -> Option<Repo> {
    let mut lines = output.lines();
    let top = normalize(lines.next()?);
    let common = normalize(&absolute(cwd, lines.next()?));
    let base = |path: &str| path.rsplit('/').find(|part| !part.is_empty()).map(str::to_owned);
    match common.strip_suffix("/.git") {
        Some(main) => Some(Repo { name: base(main)?, worktree: (top != main).then(|| base(&top)).flatten() }),
        // A bare repository's worktree, or a submodule's (`.git/modules/x`).
        None => {
            let name = base(&common)?.trim_end_matches(".git").to_owned();
            let worktree = base(&top).filter(|folder| *folder != name);
            Some(Repo { name, worktree })
        }
    }
}

fn absolute(cwd: &str, path: &str) -> String {
    if path.starts_with('/') { path.to_owned() } else { format!("{cwd}/{path}") }
}

/// Without `.`, `..` or doubled slashes.
fn normalize(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    format!("/{}", parts.join("/"))
}

/// Follows one working Agent's transcript for its to-do list, as the
/// conversation page would.
#[derive(Default)]
struct Tracker {
    following: Option<(Located, Tail)>,
    conversation: Conversation,
}

impl Tracker {
    async fn tick(&mut self, client: &mut Client, session: &Session) -> Result<Option<TodoNow>> {
        let machine = session.machine.as_deref();
        let located = match session.pid {
            Some(pid) => transcript::locate(client, machine, pid).await?,
            None => None,
        };
        let Some(located) = located else {
            self.following = None;
            return Ok(None);
        };
        match &mut self.following {
            Some((current, tail)) if *current == located => match tail.more(client).await {
                Ok(lines) => {
                    self.conversation.apply(lines.iter().map(String::as_str));
                }
                // Rewritten under us: start over on the next tick.
                Err(_) => self.following = None,
            },
            _ => {
                let mut tail = Tail::new(machine, &located);
                let lines = tail.start(client).await?;
                self.conversation = Conversation::default();
                self.conversation.apply(lines.iter().map(String::as_str));
                self.following = Some((located, tail));
            }
        }
        Ok(self.conversation.todo_now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo(name: &str, worktree: Option<&str>) -> Option<Repo> {
        Some(Repo { name: name.into(), worktree: worktree.map(Into::into) })
    }

    #[test]
    fn repositories_and_their_worktrees() {
        assert_eq!(parse_repo("/w/app", "/w/app\n.git\n"), repo("app", None));
        assert_eq!(parse_repo("/w/app/src/ui", "/w/app\n../../.git\n"), repo("app", None), "a folder inside it");
        assert_eq!(
            parse_repo("/w/app/.claude/worktrees/fix-a", "/w/app/.claude/worktrees/fix-a\n/w/app/.git\n"),
            repo("app", Some("fix-a")),
            "Claude Code's worktree"
        );
        assert_eq!(parse_repo("/w/app.worktrees/b", "/w/app.worktrees/b\n/w/app/.git\n"), repo("app", Some("b")));
        assert_eq!(parse_repo("/w/x/main", "/w/x/main\n/w/x.git\n"), repo("x", Some("main")), "a bare repository's worktree");
        assert_eq!(parse_repo("/w/app/lib", "/w/app/lib\n/w/app/.git/modules/lib\n"), repo("lib", None), "a submodule");
        assert_eq!(parse_repo("/w", ""), None);
    }

    #[test]
    fn sessions_carry_what_was_found() {
        let session = Session::from_record(&serde_json::json!({"address": "t1", "state": "live", "cwd": "/w/app"})).unwrap();
        let mut about = About::default();
        about.repos.insert("t1".into(), Repo { name: "app".into(), worktree: None });
        about.todos.insert("t1".into(), TodoNow { text: "写测试中".into(), done: 1, total: 3 });
        let json = serde_json::to_value(&about.fill(&[session])[0]).unwrap();
        assert_eq!(json["repo"], serde_json::json!({"name": "app"}));
        assert_eq!(json["todo"], serde_json::json!({"text": "写测试中", "done": 1, "total": 3}));
    }
}
