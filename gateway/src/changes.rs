//! Changes: what the session's git repository holds that HEAD doesn't,
//! untracked files included, and one file's diff at a time. Only fixed,
//! read-only git commands run, through core's `machine.exec` on the
//! session's machine; none writes the index or wakes fsmonitor. The phone
//! picks a file only from the latest list this Gateway gave it.

use crate::exec::{Failure, Output, Program, exec};
use crate::herdr::CoreView;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::watch;

pub const MAX_FILES: usize = 1000;
const MAX_PATCH_LINES: usize = 5000;
const MAX_PATCH_BYTES: usize = 512 * 1024;
const GIT_TIMEOUT_SECS: u64 = 20;
/// What a repository without commits is compared to.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// Read-only git: no optional locks, no index refresh, no fsmonitor, paths as they are.
const GIT: [&str; 10] = [
    "git",
    "--no-optional-locks",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "diff.autoRefreshIndex=false",
    "-c",
    "core.quotepath=off",
    "-c",
    "color.ui=false",
];
/// No external diff programs or text conversion the user configured.
const DIFF: [&str; 4] = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"];

/// Line counts of the untracked files named on stdin (NUL-separated);
/// `-` for a binary one.
const COUNT_LINES: &str = r#"xargs -0 sh -c 'for f do if [ -s "$f" ] && ! LC_ALL=C grep -Iq "" -- "$f"; then n=-; else n=$(grep -c "" -- "$f"); fi; printf "%s\t%s\0" "$n" "$f"; done' sh"#;

pub struct Request {
    pub id: String,
    pub session: String,
}

pub struct DiffRequest {
    pub id: String,
    pub session: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct FileChange {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    /// M, A, D, R, T, U, or ? for untracked.
    pub status: String,
    /// None for a binary file.
    pub added: Option<u64>,
    pub deleted: Option<u64>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Changes { id: String, repo: String, files: Vec<FileChange>, truncated: bool },
    ChangesFailed { id: String, kind: String, message: String },
    ChangeDiff { id: String, patch: String, truncated: bool },
    ChangeDiffFailed { id: String, kind: String, message: String },
}

/// The latest list each session's phone was given: only these files can be opened.
#[derive(Default)]
pub struct Listed(Mutex<HashMap<String, Listing>>);

#[derive(Clone)]
struct Listing {
    machine: Option<String>,
    root: String,
    base: String,
    files: HashMap<String, FileChange>,
}

fn session_place(view: &watch::Receiver<CoreView>, session: &str) -> Option<(Option<String>, String)> {
    view.borrow()
        .sessions
        .iter()
        .find(|s| s.id == session)
        .map(|s| (s.machine.clone(), s.cwd.clone()))
}

async fn git(hc: &str, machine: Option<&str>, cwd: &str, args: &[&str]) -> Result<Output, Failure> {
    let argv: Vec<&str> = GIT.iter().copied().chain(args.iter().copied()).collect();
    exec(hc, machine, cwd, Program::Argv(&argv), None, GIT_TIMEOUT_SECS).await
}

fn text(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_owned()
}

pub async fn list(hc: &str, view: &watch::Receiver<CoreView>, listed: &Listed, request: Request) -> Response {
    let failed = |failure: Failure| Response::ChangesFailed { id: request.id.clone(), kind: failure.kind, message: failure.message };
    let Some((machine, cwd)) = session_place(view, &request.session) else {
        return failed(Failure::new("not_found", "会话不存在或已结束"));
    };
    match collect(hc, machine.as_deref(), &cwd).await {
        Ok((listing, files, truncated)) => {
            let repo = listing.root.rsplit('/').find(|part| !part.is_empty()).unwrap_or("/").to_owned();
            let listing = Listing { machine, ..listing };
            listed.0.lock().unwrap().insert(request.session, listing);
            Response::Changes { id: request.id, repo, files, truncated }
        }
        Err(failure) => failed(failure),
    }
}

async fn collect(hc: &str, machine: Option<&str>, cwd: &str) -> Result<(Listing, Vec<FileChange>, bool), Failure> {
    let top = git(hc, machine, cwd, &["rev-parse", "--show-toplevel"]).await?;
    if top.code != Some(0) {
        return Err(Failure::new("not_git", "不是 git 仓库"));
    }
    let root = text(&top);
    let head = git(hc, machine, &root, &["rev-parse", "-q", "--verify", "HEAD"]).await?;
    let base = if head.code == Some(0) { text(&head) } else { EMPTY_TREE.to_owned() };

    let status_args: Vec<&str> = DIFF.iter().copied().chain([base.as_str(), "-z", "-M", "--name-status"]).collect();
    let numstat_args: Vec<&str> = DIFF.iter().copied().chain([base.as_str(), "-z", "-M", "--numstat"]).collect();
    let (status, numstat, untracked) = tokio::join!(
        git(hc, machine, &root, &status_args),
        git(hc, machine, &root, &numstat_args),
        git(hc, machine, &root, &["ls-files", "-o", "--exclude-standard", "-z"]),
    );
    let (status, numstat, untracked) = (status?, numstat?, untracked?);
    for output in [&status, &numstat, &untracked] {
        if output.code != Some(0) {
            return Err(Failure::new("unavailable", "git 没能列出改动"));
        }
    }
    let mut files = tracked(&status.stdout, &numstat.stdout);
    let mut cut = status.cut || numstat.cut || untracked.cut;

    let mut names: Vec<&[u8]> = untracked.stdout.split(|&b| b == 0).filter(|name| !name.is_empty()).collect();
    if files.len() + names.len() > MAX_FILES {
        names.truncate(MAX_FILES.saturating_sub(files.len()));
        cut = true;
    }
    if !names.is_empty() {
        let input = names.join(&0u8);
        let counted = exec(hc, machine, &root, Program::Line(COUNT_LINES), Some(&input), GIT_TIMEOUT_SECS).await?;
        cut |= counted.cut;
        files.extend(untracked_files(&counted.stdout));
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    if files.len() > MAX_FILES {
        files.truncate(MAX_FILES);
        cut = true;
    }
    let listing = Listing {
        machine: None,
        root,
        base,
        files: files.iter().map(|file| (file.path.clone(), file.clone())).collect(),
    };
    Ok((listing, files, cut))
}

/// `--name-status -z` and `--numstat -z` together, in the same order. A
/// modification of nothing (a file whose timestamp changed, as the index
/// isn't refreshed) is left out.
fn tracked(status: &[u8], numstat: &[u8]) -> Vec<FileChange> {
    let mut fields = status.split(|&b| b == 0).map(|f| String::from_utf8_lossy(f).into_owned());
    let mut files = Vec::new();
    while let Some(code) = fields.next() {
        if code.is_empty() {
            continue;
        }
        let letter = &code[..1];
        let (path, old_path) = if matches!(letter, "R" | "C") {
            let old = fields.next().unwrap_or_default();
            (fields.next().unwrap_or_default(), Some(old))
        } else {
            (fields.next().unwrap_or_default(), None)
        };
        let status = if letter == "C" { "A" } else { letter };
        let old_path = if letter == "R" { old_path } else { None };
        files.push(FileChange { path, old_path, status: status.into(), added: None, deleted: None });
    }

    let mut counts = HashMap::new();
    let mut fields = numstat.split(|&b| b == 0).map(|f| String::from_utf8_lossy(f).into_owned());
    while let Some(field) = fields.next() {
        let mut parts = field.splitn(3, '\t');
        let (Some(added), Some(deleted), Some(path)) = (parts.next(), parts.next(), parts.next()) else { continue };
        // A rename: the two paths follow as fields of their own.
        let path = if path.is_empty() {
            fields.next();
            fields.next().unwrap_or_default()
        } else {
            path.to_owned()
        };
        counts.insert(path, (added.parse().ok(), deleted.parse().ok()));
    }
    for file in &mut files {
        if let Some(&(added, deleted)) = counts.get(&file.path) {
            (file.added, file.deleted) = (added, deleted);
        }
    }
    files.retain(|file| !(file.status == "M" && file.added == Some(0) && file.deleted == Some(0)));
    files
}

/// The line-count script's output: `count\tpath\0`, `-` for binary.
fn untracked_files(output: &[u8]) -> Vec<FileChange> {
    output
        .split(|&b| b == 0)
        .filter_map(|record| {
            let record = String::from_utf8_lossy(record);
            let (count, path) = record.split_once('\t')?;
            let added = count.parse().ok();
            Some(FileChange {
                path: path.to_owned(),
                old_path: None,
                status: "?".into(),
                added,
                deleted: added.map(|_| 0),
            })
        })
        .collect()
}

pub async fn diff(hc: &str, listed: &Listed, request: DiffRequest) -> Response {
    let failed = |failure: Failure| Response::ChangeDiffFailed { id: request.id.clone(), kind: failure.kind, message: failure.message };
    let Some(listing) = listed.0.lock().unwrap().get(&request.session).cloned() else {
        return failed(Failure::new("changed", "改动已变化，请刷新"));
    };
    let Some(file) = listing.files.get(&request.path) else {
        return failed(Failure::new("changed", "改动已变化，请刷新"));
    };
    let output = if file.status == "?" {
        let args: Vec<&str> = DIFF.iter().copied().chain(["--no-index", "--", "/dev/null", file.path.as_str()]).collect();
        git(hc, listing.machine.as_deref(), &listing.root, &args).await
    } else {
        let mut specs = vec![format!(":(top,literal){}", file.path)];
        if let Some(old) = &file.old_path {
            specs.push(format!(":(top,literal){old}"));
        }
        let args: Vec<&str> = DIFF
            .iter()
            .copied()
            .chain([listing.base.as_str(), "-M", "--"])
            .chain(specs.iter().map(String::as_str))
            .collect();
        git(hc, listing.machine.as_deref(), &listing.root, &args).await
    };
    match output {
        // --no-index exits 1 when the files differ, which they do.
        Ok(output) if matches!(output.code, Some(0 | 1)) => {
            let (patch, cut) = clip(&String::from_utf8_lossy(&output.stdout));
            Response::ChangeDiff { id: request.id, patch, truncated: cut || output.cut }
        }
        Ok(_) => failed(Failure::new("unavailable", "git 没能读出这个文件的改动")),
        Err(failure) => failed(failure),
    }
}

/// At most MAX_PATCH_LINES lines and MAX_PATCH_BYTES bytes, cut at a line.
fn clip(patch: &str) -> (String, bool) {
    let mut end = 0;
    for (count, line) in patch.split_inclusive('\n').enumerate() {
        if count == MAX_PATCH_LINES || end + line.len() > MAX_PATCH_BYTES {
            return (patch[..end].to_owned(), true);
        }
        end += line.len();
    }
    (patch.to_owned(), false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn change(path: &str, old: Option<&str>, status: &str, added: Option<u64>, deleted: Option<u64>) -> FileChange {
        FileChange { path: path.into(), old_path: old.map(Into::into), status: status.into(), added, deleted }
    }

    #[test]
    fn reads_tracked_changes() {
        let status = b"M\0a.txt\0R087\0old.txt\0new.txt\0D\0gone.txt\0A\0img.png\0M\0touched.txt\0";
        let numstat = b"3\t1\ta.txt\0" as &[u8];
        let numstat = [numstat, b"1\t1\t\0old.txt\0new.txt\0", b"0\t4\tgone.txt\0-\t-\timg.png\0", b"0\t0\ttouched.txt\0"].concat();
        assert_eq!(
            tracked(status, &numstat),
            [
                change("a.txt", None, "M", Some(3), Some(1)),
                change("new.txt", Some("old.txt"), "R", Some(1), Some(1)),
                change("gone.txt", None, "D", Some(0), Some(4)),
                change("img.png", None, "A", None, None),
            ]
        );
    }

    #[test]
    fn reads_untracked_counts() {
        assert_eq!(
            untracked_files(b"4\tnotes.md\0-\tlogo.png\0"),
            [change("notes.md", None, "?", Some(4), Some(0)), change("logo.png", None, "?", None, None)]
        );
    }

    #[test]
    fn clips_long_patches_at_a_line() {
        let patch = "+x\n".repeat(MAX_PATCH_LINES + 10);
        let (clipped, cut) = clip(&patch);
        assert!(cut);
        assert_eq!(clipped.lines().count(), MAX_PATCH_LINES);
        assert_eq!(clip("a\nb"), ("a\nb".to_owned(), false));
    }

    #[test]
    fn serializes_without_absent_old_paths() {
        let response = Response::Changes {
            id: "g1".into(),
            repo: "app".into(),
            files: vec![change("a", None, "?", Some(2), Some(0))],
            truncated: false,
        };
        assert_eq!(
            serde_json::to_value(response).unwrap(),
            serde_json::json!({"type": "changes", "id": "g1", "repo": "app", "truncated": false,
                "files": [{"path": "a", "status": "?", "added": 2, "deleted": 0}]})
        );
    }

    /// The real commands against a scratch repository, the way core runs them.
    #[test]
    fn git_commands_on_a_sample_repository() {
        let root = std::env::temp_dir().join(format!("companion-changes-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let run = |argv: &[&str], input: Option<&[u8]>| {
            use std::io::Write;
            let mut child = std::process::Command::new(argv[0])
                .args(&argv[1..])
                .current_dir(&root)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            child.stdin.take().unwrap().write_all(input.unwrap_or_default()).unwrap();
            child.wait_with_output().unwrap().stdout
        };
        let git = |args: &[&str]| run(&GIT.iter().copied().chain(args.iter().copied()).collect::<Vec<_>>(), None);
        git(&["init", "-q"]);
        std::fs::write(root.join("a.txt"), "one\ntwo\n").unwrap();
        std::fs::write(root.join("old name.txt"), "keep\nkeep\nkeep\nkeep\n").unwrap();
        git(&["add", "."]);
        git(&["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]);
        std::fs::write(root.join("a.txt"), "one\n2\nthree\n").unwrap();
        std::fs::rename(root.join("old name.txt"), root.join("new name.txt")).unwrap();
        git(&["add", "-A", "new name.txt", "old name.txt"]);
        std::fs::write(root.join("notes.md"), "n\n").unwrap();
        std::fs::write(root.join("blob.bin"), [0u8, 1, 2]).unwrap();

        let base = String::from_utf8(git(&["rev-parse", "-q", "--verify", "HEAD"])).unwrap();
        let base = base.trim();
        let args = |last: &'static str| DIFF.iter().copied().chain([base, "-z", "-M", last]).collect::<Vec<_>>();
        let files = tracked(&git(&args("--name-status")), &git(&args("--numstat")));
        let names = git(&["ls-files", "-o", "--exclude-standard", "-z"]);
        let counted = run(&["sh", "-c", COUNT_LINES], Some(&names));
        let untracked = untracked_files(&counted);
        std::fs::remove_dir_all(&root).unwrap();

        assert_eq!(
            files,
            [
                change("a.txt", None, "M", Some(2), Some(1)),
                change("new name.txt", Some("old name.txt"), "R", Some(0), Some(0)),
            ]
        );
        let mut untracked = untracked;
        untracked.sort_by(|a, b| a.path.cmp(&b.path));
        assert_eq!(untracked, [change("blob.bin", None, "?", None, None), change("notes.md", None, "?", Some(1), Some(0))]);
    }
}
