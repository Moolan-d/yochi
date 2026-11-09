//! Notifications when an Agent needs you or finishes, sent through Bark
//! (https://bark.day.app) while no phone has Yochi open. Bark is a free iOS
//! app that relays pushes through its own APNs certificate, so Yochi needs no
//! paid developer account. With an AES key the Bark server and Apple see only
//! ciphertext; the Bark app on the phone decrypts it.
//!
//! The app holds `/v0/ws` open only while it is in the foreground, so an open
//! one means someone is looking at Yochi already and nothing is sent.

use crate::conversation::Conversation;
use crate::core::Client;
use crate::devices::{hex, random_bytes};
use crate::transcript::{self, Tail};
use crate::herdr::CoreView;
use crate::lang::Lang;
use crate::session::Session;
use aes::cipher::{BlockEncryptMut as _, KeyIvInit as _, block_padding::Pkcs7};
use anyhow::{Context as _, Result, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncWriteExt as _;
use tokio::sync::watch;
use tokio::time::Instant;

/// How long a change has to last before it is sent: someone at the Mac has
/// usually answered or looked by then, and a blip doesn't buzz the phone.
const DELAY: Duration = Duration::from_secs(10);
const SEND_WITHIN: Duration = Duration::from_secs(20);
/// How long reading the Agent's reply may hold a notification up.
const READ_WITHIN: Duration = Duration::from_secs(5);
/// A finished turn's reply is at the end; this many lines reach it.
const REPLY_LINES: usize = 200;
/// Longer first sentences are cut, in characters.
const SENTENCE: usize = 120;
pub const DEFAULT_SERVER: &str = "https://api.day.app";

/// `push.json` in the state directory.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Config {
    /// The Bark server, `https://api.day.app` or your own.
    pub server: String,
    /// The phone's Bark device key.
    pub device: String,
    /// AES key (16, 24 or 32 characters) set in Bark's Push Encryption, CBC mode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}

impl Config {
    fn path(dir: &Path) -> PathBuf {
        dir.join("push.json")
    }

    pub fn load(dir: &Path) -> Result<Option<Self>> {
        let path = Self::path(dir);
        match std::fs::read(&path) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))?)),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err).with_context(|| format!("reading {}", path.display())),
        }
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let tmp = dir.join("push.json.tmp");
        let mut file = std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&tmp)?;
        file.write_all(&serde_json::to_vec_pretty(self)?)?;
        file.sync_all()?;
        std::fs::rename(&tmp, Self::path(dir))?;
        Ok(())
    }

    pub fn remove(dir: &Path) -> Result<bool> {
        match std::fs::remove_file(Self::path(dir)) {
            Ok(()) => Ok(true),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(err) => Err(err.into()),
        }
    }

    /// From what Bark shows: the device key, or its whole push address
    /// (`https://api.day.app/<key>/…`), which also names the server.
    pub fn new(target: &str, server: Option<&str>, key: Option<String>) -> Result<Self> {
        let target = target.trim();
        let (found_server, device) = match target.split_once("://") {
            Some((scheme, rest)) => {
                let mut parts = rest.split('/').filter(|part| !part.is_empty());
                let host = parts.next().ok_or_else(|| anyhow!("no server in {target:?}"))?;
                let device = parts.next().ok_or_else(|| anyhow!("no device key in {target:?}"))?;
                (Some(format!("{scheme}://{host}")), device.to_owned())
            }
            None => (None, target.to_owned()),
        };
        if device.is_empty() || !device.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
            bail!("{device:?} doesn't look like a Bark device key");
        }
        let server = server.map(str::to_owned).or(found_server).unwrap_or_else(|| DEFAULT_SERVER.to_owned());
        let server = server.trim_end_matches('/').to_owned();
        if !server.starts_with("https://") && !server.starts_with("http://") {
            bail!("the Bark server starts with https://, not {server:?}");
        }
        if let Some(key) = &key
            && ![16, 24, 32].contains(&key.len())
        {
            bail!("the AES key is 16, 24 or 32 characters, not {}", key.len());
        }
        Ok(Self { server, device, key })
    }
}

/// A key for Bark's Push Encryption (AES-256), typed or pasted into the app.
pub fn new_key() -> Result<String> {
    random_text::<32>()
}

/// Letters and digits, as Bark's settings take them.
fn random_text<const N: usize>() -> Result<String> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    // 248 is the largest multiple of 62 under 256, so every character is as likely.
    let mut text = String::with_capacity(N);
    while text.len() < N {
        for byte in random_bytes::<64>()? {
            if byte < 248 && text.len() < N {
                text.push(ALPHABET[usize::from(byte) % ALPHABET.len()] as char);
            }
        }
    }
    Ok(text)
}

/// Phones with Yochi open now, and the language the latest one shows.
#[derive(Default)]
pub struct Phones(Mutex<(usize, Lang)>);

impl Phones {
    /// A phone opened Yochi; it counts until the returned guard drops.
    pub fn arrive(self: &Arc<Self>, lang: Lang) -> Here {
        let mut state = self.0.lock().unwrap();
        *state = (state.0 + 1, lang);
        Here(self.clone())
    }

    fn open(&self) -> bool {
        self.0.lock().unwrap().0 > 0
    }

    fn lang(&self) -> Lang {
        self.0.lock().unwrap().1
    }
}

pub struct Here(Arc<Phones>);

impl Drop for Here {
    fn drop(&mut self) {
        self.0.0.lock().unwrap().0 -= 1;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Blocked on a permission, a question or a login.
    NeedsYou,
    /// Stopped on an error.
    Failed,
    /// Finished a turn.
    Done,
}

/// What a session was last seen doing.
struct Last {
    stuck: Option<Kind>,
    turn: u64,
}

fn stuck(session: &Session) -> Option<Kind> {
    match session.status.as_ref()?.state.as_str() {
        "blocked" => Some(Kind::NeedsYou),
        "error" => Some(Kind::Failed),
        _ => None,
    }
}

/// What changed since `last`, which it then remembers. A session seen for
/// the first time is only remembered: the Gateway starting, or the core
/// coming back, isn't news. Sub-agents report to their Agent, not the phone.
fn changes(last: &mut HashMap<String, Last>, sessions: &[Session]) -> Vec<(String, Kind)> {
    last.retain(|id, _| sessions.iter().any(|session| session.id == *id));
    let mut found = Vec::new();
    for session in sessions.iter().filter(|session| session.parent.is_none()) {
        let now = Last { stuck: stuck(session), turn: session.turn };
        if let Some(before) = last.get(&session.id) {
            if let Some(kind) = now.stuck.filter(|kind| before.stuck != Some(*kind)) {
                found.push((session.id.clone(), kind));
            } else if now.stuck.is_none() && now.turn > before.turn {
                found.push((session.id.clone(), Kind::Done));
            }
        }
        last.insert(session.id.clone(), now);
    }
    found
}

/// Whether `kind` is still news once [`DELAY`] has passed.
fn still(kind: Kind, session: &Session) -> bool {
    match kind {
        Kind::NeedsYou | Kind::Failed => stuck(session) == Some(kind),
        // Herdr's desktop showed the reply, or the Agent went on working.
        Kind::Done => {
            let state = session.status.as_ref().map(|status| status.state.as_str());
            stuck(session).is_none() && state != Some("working") && session.seen.is_none_or(|seen| seen < session.turn)
        }
    }
}

/// The notification's fields, in Bark's names. `reply` is what the Agent
/// said last, for a finished turn.
fn message(kind: Kind, session: &Session, lang: Lang, reply: Option<String>) -> Value {
    let label = match kind {
        Kind::NeedsYou => lang.pick("需要你处理", "Needs you"),
        Kind::Failed => lang.pick("出错了", "Ran into an error"),
        Kind::Done => lang.pick("完成了", "Done"),
    };
    let fallback = match kind {
        Kind::NeedsYou => lang.pick("在等你回复", "Waiting for you"),
        Kind::Failed => lang.pick("停在了一个错误上", "Stopped on an error"),
        Kind::Done => lang.pick("这一轮做完了", "Finished its turn"),
    };
    // herdr-core puts "answer: " before a question: how to reply, not what is asked.
    let said = || {
        let message = session.status.as_ref()?.message.as_deref()?;
        Some(message.strip_prefix("answer: ").unwrap_or(message).to_owned())
    };
    let body = match kind {
        Kind::Done => reply.or_else(said),
        _ => said(),
    }
    .unwrap_or_else(|| fallback.to_owned());
    let title = match &session.machine {
        Some(machine) => format!("{} · {machine}", session.title),
        None => session.title.clone(),
    };
    json!({
        "title": title,
        "subtitle": label,
        "body": body,
        "group": session.title,
        "url": format!("yochi://session?id={}", query_value(&session.id)),
        "level": if kind == Kind::Done { "active" } else { "timeSensitive" },
    })
}

/// The first sentence of a Claude Code session's newest reply, read through
/// the core like the conversation page reads it. None for other programs,
/// or when the transcript can't be read in time.
async fn last_reply(hc: &str, session: &Session) -> Option<String> {
    let read = async {
        let mut client = Client::connect(hc).await.ok()?;
        let machine = session.machine.as_deref();
        let located = transcript::locate(&mut client, machine, session.pid?).await.ok()??;
        let lines = Tail::new(machine, &located).start_last(&mut client, REPLY_LINES).await.ok()?;
        let mut conversation = Conversation::default();
        conversation.apply(lines.iter().map(String::as_str));
        first_sentence(conversation.last_reply()?)
    };
    tokio::time::timeout(READ_WITHIN, read).await.ok().flatten()
}

/// The first sentence of Markdown, as plain text: the first line with words
/// outside a code block, without its list, heading or emphasis marks, up to
/// the end of its first sentence.
fn first_sentence(markdown: &str) -> Option<String> {
    let mut fenced = false;
    let line = markdown.lines().find_map(|line| {
        let line = line.trim();
        if line.starts_with("```") || line.starts_with("~~~") {
            fenced = !fenced;
            return None;
        }
        if fenced || line.starts_with('|') {
            return None;
        }
        let line = line.trim_start_matches(|c: char| matches!(c, '#' | '>' | '-' | '*' | '+') || c.is_whitespace());
        let line = match line.split_once(". ") {
            Some((number, rest)) if !number.is_empty() && number.chars().all(|c| c.is_ascii_digit()) => rest,
            _ => line,
        };
        let line = line.replace("**", "").replace("__", "").replace('`', "");
        let line = line.trim();
        (line.chars().any(char::is_alphanumeric)).then(|| line.to_owned())
    })?;
    let mut chars = line.char_indices().peekable();
    let mut end = line.len();
    while let Some((at, c)) = chars.next() {
        let after = at + c.len_utf8();
        let ends = match c {
            '。' | '！' | '？' => true,
            '.' | '!' | '?' => chars.peek().is_none_or(|(_, next)| next.is_whitespace()),
            _ => false,
        };
        if ends {
            end = after;
            break;
        }
    }
    let sentence = &line[..end];
    Some(match sentence.char_indices().nth(SENTENCE) {
        Some((cut, _)) => format!("{}…", sentence[..cut].trim_end()),
        None => sentence.to_owned(),
    })
}

/// A query value with everything but unreserved characters escaped.
fn query_value(text: &str) -> String {
    text.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => (byte as char).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// One notification per session in Notification Center: a newer one replaces it.
fn notification_id(session: &str) -> String {
    format!("yochi-{}", &hex(&Sha256::digest(session.as_bytes()))[..16])
}

/// The JSON body Bark's server takes. With a key, only the notification's
/// identifier and interruption level stay readable to the server.
fn request(config: &Config, fields: Value, id: Option<&str>, iv: &str) -> Result<Value> {
    let mut body = match &config.key {
        Some(key) => {
            let level = fields["level"].clone();
            let ciphertext = encrypt(key.as_bytes(), iv.as_bytes(), serde_json::to_string(&fields)?.as_bytes())?;
            json!({"ciphertext": ciphertext, "iv": iv, "level": level})
        }
        None => fields,
    };
    if let Some(id) = id {
        body["id"] = json!(id);
    }
    Ok(body)
}

/// AES-CBC with PKCS#7 padding, base64: what Bark's Push Encryption decrypts.
fn encrypt(key: &[u8], iv: &[u8], plain: &[u8]) -> Result<String> {
    let mut buffer = vec![0u8; (plain.len() / 16 + 1) * 16];
    buffer[..plain.len()].copy_from_slice(plain);
    let size = |_| anyhow!("the AES key is 16, 24 or 32 characters and the IV 16");
    let sealed = match key.len() {
        16 => cbc::Encryptor::<aes::Aes128>::new_from_slices(key, iv).map_err(size)?.encrypt_padded_mut::<Pkcs7>(&mut buffer, plain.len()),
        24 => cbc::Encryptor::<aes::Aes192>::new_from_slices(key, iv).map_err(size)?.encrypt_padded_mut::<Pkcs7>(&mut buffer, plain.len()),
        32 => cbc::Encryptor::<aes::Aes256>::new_from_slices(key, iv).map_err(size)?.encrypt_padded_mut::<Pkcs7>(&mut buffer, plain.len()),
        n => bail!("the AES key is 16, 24 or 32 characters, not {n}"),
    };
    Ok(STANDARD.encode(sealed.map_err(|_| anyhow!("padding"))?))
}

/// Sends one notification. curl does the HTTPS; the device key and the body
/// go to it on stdin, so they never show in `ps`.
pub async fn send(config: &Config, fields: Value, id: Option<&str>) -> Result<()> {
    let body = request(config, fields, id, &random_text::<16>()?)?;
    let url = format!("{}/{}", config.server, config.device);
    let mut child = tokio::process::Command::new("curl")
        .args(["--config", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("running curl")?;
    let mut stdin = child.stdin.take().expect("piped");
    stdin.write_all(curl_config(&url, &serde_json::to_string(&body)?).as_bytes()).await?;
    drop(stdin);
    let output = tokio::time::timeout(SEND_WITHIN, child.wait_with_output()).await.map_err(|_| anyhow!("Bark didn't answer"))??;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let (reply, status) = stdout.rsplit_once('\n').unwrap_or(("", &stdout));
    if !output.status.success() {
        bail!("{}", String::from_utf8_lossy(&output.stderr).trim());
    }
    if status.trim() != "200" {
        let said = serde_json::from_str::<Value>(reply).ok().and_then(|reply| reply["message"].as_str().map(str::to_owned));
        bail!("Bark answered {}: {}", status.trim(), said.unwrap_or_else(|| reply.trim().to_owned()));
    }
    Ok(())
}

/// A curl config file (`curl --config`): quoted values, `\` and `"` escaped.
fn curl_config(url: &str, body: &str) -> String {
    let quote = |text: &str| format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
    [
        format!("url = {}", quote(url)),
        "header = \"Content-Type: application/json; charset=utf-8\"".to_owned(),
        format!("data-binary = {}", quote(body)),
        "silent".to_owned(),
        "show-error".to_owned(),
        format!("max-time = {}", SEND_WITHIN.as_secs() - 2),
        "write-out = \"\\n%{http_code}\"".to_owned(),
    ]
    .join("\n")
        + "\n"
}

/// A notification to check that Bark is set up.
pub fn test_message(lang: Lang) -> Value {
    json!({
        "title": "Yochi",
        "body": lang.pick("推送已接通：Agent 需要你或做完一轮时会通知你。", "Notifications work: you'll hear when an Agent needs you or finishes a turn."),
        "group": "Yochi",
    })
}

/// Watches the core's sessions and sends a notification when one needs you
/// or finishes, if it still does after [`DELAY`] and no phone has Yochi open.
/// `push.json` is read each time, so `yochi push` takes effect at once.
pub async fn run(hc: Arc<str>, dir: PathBuf, mut view: watch::Receiver<CoreView>, phones: Arc<Phones>) {
    let mut last = HashMap::new();
    let mut pending: HashMap<String, (Kind, Instant)> = HashMap::new();
    loop {
        let sessions = view.borrow_and_update().sessions.clone();
        let now = Instant::now();
        for (id, kind) in changes(&mut last, &sessions) {
            pending.insert(id, (kind, now + DELAY));
        }
        let due: Vec<(String, Kind)> = pending.iter().filter(|(_, (_, at))| *at <= now).map(|(id, (kind, _))| (id.clone(), *kind)).collect();
        for (id, kind) in due {
            pending.remove(&id);
            let Some(session) = sessions.iter().find(|session| session.id == id) else { continue };
            if phones.open() || !still(kind, session) {
                continue;
            }
            let config = match Config::load(&dir) {
                Ok(Some(config)) => config,
                Ok(None) => continue,
                Err(error) => {
                    eprintln!("Notifications: {error:#}");
                    continue;
                }
            };
            let (session, lang, hc) = (session.clone(), phones.lang(), hc.clone());
            tokio::spawn(async move {
                let reply = match kind {
                    Kind::Done => last_reply(&hc, &session).await,
                    _ => None,
                };
                let fields = message(kind, &session, lang, reply);
                if let Err(error) = send(&config, fields, Some(&notification_id(&session.id))).await {
                    eprintln!("Notification not sent: {error:#}");
                }
            });
        }
        let next = pending.values().map(|(_, at)| *at).min();
        tokio::select! {
            changed = view.changed() => if changed.is_err() { return },
            () = tokio::time::sleep_until(next.unwrap_or(now)), if next.is_some() => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Status;

    fn session(id: &str, state: &str, turn: u64) -> Session {
        let mut session = Session::from_record(&json!({"address": id, "state": "live", "name": "fix tests", "cwd": "/"})).unwrap();
        session.status = Some(Status { state: state.into(), app: Some("claude".into()), message: None, kind: None });
        session.turn = turn;
        session
    }

    #[test]
    fn first_sight_is_only_remembered() {
        let mut last = HashMap::new();
        assert!(changes(&mut last, &[session("t1", "blocked", 3)]).is_empty());
        assert!(changes(&mut last, &[session("t1", "blocked", 3)]).is_empty());
    }

    #[test]
    fn blocking_errors_and_new_turns_are_news() {
        let mut last = HashMap::new();
        changes(&mut last, &[session("t1", "working", 3), session("t2", "working", 0)]);
        assert_eq!(changes(&mut last, &[session("t1", "blocked", 3), session("t2", "working", 0)]), [("t1".into(), Kind::NeedsYou)]);
        assert!(changes(&mut last, &[session("t1", "blocked", 3), session("t2", "working", 0)]).is_empty());
        assert!(changes(&mut last, &[session("t1", "working", 3), session("t2", "working", 0)]).is_empty());
        assert_eq!(changes(&mut last, &[session("t1", "done", 4), session("t2", "error", 0)]), [
            ("t1".into(), Kind::Done),
            ("t2".into(), Kind::Failed)
        ]);
    }

    #[test]
    fn sub_agents_and_gone_sessions_are_left_out() {
        let mut last = HashMap::new();
        let mut sub = session("t2", "working", 0);
        sub.parent = Some("t1".into());
        changes(&mut last, &[session("t1", "working", 0), sub.clone()]);
        sub.status.as_mut().unwrap().state = "blocked".into();
        assert!(changes(&mut last, &[session("t1", "working", 0), sub]).is_empty());
        // A session that comes back (the core reconnected) is new again.
        changes(&mut last, &[]);
        assert!(changes(&mut last, &[session("t1", "blocked", 0)]).is_empty());
    }

    #[test]
    fn news_that_is_stale_by_send_time_is_dropped() {
        assert!(still(Kind::NeedsYou, &session("t1", "blocked", 1)));
        assert!(!still(Kind::NeedsYou, &session("t1", "working", 1)));
        assert!(still(Kind::Done, &session("t1", "done", 2)));
        assert!(!still(Kind::Done, &session("t1", "working", 2)), "went on working");
        let mut seen = session("t1", "done", 2);
        seen.seen = Some(2);
        assert!(!still(Kind::Done, &seen), "read on the Mac");
    }

    #[test]
    fn says_what_happened_in_the_phones_language() {
        let mut blocked = session("vps/t1", "blocked", 1);
        blocked.machine = Some("vps".into());
        blocked.status.as_mut().unwrap().message = Some("Allow Bash: cargo test?".into());
        let fields = message(Kind::NeedsYou, &blocked, Lang::English, Some("not for a question".into()));
        assert_eq!(fields["title"], "fix tests · vps");
        assert_eq!(fields["subtitle"], "Needs you");
        assert_eq!(fields["body"], "Allow Bash: cargo test?");
        assert_eq!(fields["url"], "yochi://session?id=vps/t1");
        assert_eq!(fields["level"], "timeSensitive");
        let done = message(Kind::Done, &session("t 2&x", "done", 2), Lang::Chinese, None);
        assert_eq!(done["subtitle"], "完成了");
        assert_eq!(done["body"], "这一轮做完了");
        assert_eq!(done["url"], "yochi://session?id=t%202%26x");
        assert_eq!(done["level"], "active");
        blocked.status.as_mut().unwrap().message = Some("answer: Red or Blue?".into());
        assert_eq!(message(Kind::NeedsYou, &blocked, Lang::English, None)["body"], "Red or Blue?");
        let replied = message(Kind::Done, &session("t2", "done", 2), Lang::English, Some("Tests pass.".into()));
        assert_eq!(replied["body"], "Tests pass.");
    }

    #[test]
    fn a_reply_reads_as_its_first_sentence() {
        let first = |text| first_sentence(text);
        assert_eq!(first("Done. All 117 tests pass."), Some("Done.".into()));
        assert_eq!(first("Fixed it in v1.2 of the parser! Then more."), Some("Fixed it in v1.2 of the parser!".into()));
        assert_eq!(first("改好了。测试都通过了。"), Some("改好了。".into()));
        assert_eq!(first("## Summary\n\nMore here."), Some("Summary".into()));
        assert_eq!(first("**Bold** start: `cargo test` passes\nsecond line"), Some("Bold start: cargo test passes".into()));
        assert_eq!(first("```sh\ncargo test\n```\n- 1. First point. Second."), Some("First point.".into()));
        assert_eq!(first("| a | b |\n---\nok"), Some("ok".into()));
        assert_eq!(first("hi"), Some("hi".into()));
        assert_eq!(first("```\nonly code\n```"), None);
        assert_eq!(first("---"), None);
        let long = first(&"word ".repeat(60)).unwrap();
        assert!(long.ends_with('…') && long.chars().count() <= SENTENCE + 1, "{long}");
    }

    #[test]
    fn encrypts_as_barks_example_does() {
        // docs/encryption.md in Finb/Bark.
        let sealed = encrypt(b"1234567890123456", b"1111111111111111", br#"{"body": "test", "sound": "birdsong"}"#).unwrap();
        assert_eq!(sealed, "d3QhjQjP5majvNt5CjsvFWwqqj2gKl96RFj5OO+u6ynTt7lkyigDYNA3abnnCLpr");
        assert_eq!(encrypt(&[7; 32], &[1; 16], b"").unwrap().len(), 24, "a whole block of padding");
    }

    #[test]
    fn hides_the_notification_with_a_key() {
        let plain = Config::new("abc", None, None).unwrap();
        let fields = json!({"title": "t", "body": "b", "level": "active"});
        let body = request(&plain, fields.clone(), Some("yochi-1"), "1111111111111111").unwrap();
        assert_eq!(body["title"], "t");
        assert_eq!(body["id"], "yochi-1");
        let sealed = Config::new("abc", None, Some("1234567890123456".into())).unwrap();
        let body = request(&sealed, fields, Some("yochi-1"), "1111111111111111").unwrap();
        assert!(body.get("title").is_none() && body.get("body").is_none());
        assert_eq!(body["iv"], "1111111111111111");
        assert_eq!(body["level"], "active");
        assert_eq!(body["id"], "yochi-1");
        assert!(body["ciphertext"].as_str().is_some_and(|text| !text.is_empty()));
    }

    #[test]
    fn reads_what_bark_shows() {
        let config = Config::new("https://api.day.app/F5u42Bd3HyW8KxkUqo2gRA/", None, None).unwrap();
        assert_eq!((config.server.as_str(), config.device.as_str()), ("https://api.day.app", "F5u42Bd3HyW8KxkUqo2gRA"));
        let config = Config::new("https://bark.example.com/abc/This is a test", None, None).unwrap();
        assert_eq!((config.server.as_str(), config.device.as_str()), ("https://bark.example.com", "abc"));
        let config = Config::new("abc", Some("http://127.0.0.1:8080/"), None).unwrap();
        assert_eq!(config.server, "http://127.0.0.1:8080");
        assert!(Config::new("not a key", None, None).is_err());
        assert!(Config::new("abc", Some("ftp://x"), None).is_err());
        assert!(Config::new("abc", None, Some("short".into())).is_err());
        assert_eq!(new_key().unwrap().len(), 32);
        assert!(random_text::<16>().unwrap().chars().all(|c| c.is_ascii_alphanumeric()));
    }

    #[test]
    fn counts_open_phones() {
        let phones = Arc::new(Phones::default());
        assert!(!phones.open());
        let here = phones.arrive(Lang::English);
        assert!(phones.open());
        assert_eq!(phones.lang(), Lang::English);
        drop(here);
        assert!(!phones.open());
        assert_eq!(phones.lang(), Lang::English, "the last phone's language stays");
    }

    #[test]
    fn quotes_curl_config_values() {
        let config = curl_config("https://x/k", r#"{"body":"a \"b\"\\n"}"#);
        assert!(config.contains(r#"data-binary = "{\"body\":\"a \\\"b\\\"\\\\n\"}""#), "{config}");
    }

    /// Answers one request like Bark, with `code`; returns the request.
    async fn answer(listener: &tokio::net::TcpListener, code: u16) -> String {
        use tokio::io::AsyncReadExt as _;
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        let mut buffer = [0u8; 4096];
        loop {
            let n = socket.read(&mut buffer).await.unwrap();
            request.extend_from_slice(&buffer[..n]);
            let text = String::from_utf8_lossy(&request);
            if let Some((head, body)) = text.split_once("\r\n\r\n") {
                let length = head
                    .lines()
                    .find_map(|line| line.to_ascii_lowercase().strip_prefix("content-length: ").map(|n| n.trim().parse::<usize>().unwrap()));
                if body.len() >= length.unwrap_or(0) {
                    break;
                }
            }
        }
        let message = if code == 200 { "success" } else { "failed to get device token" };
        let reply = format!(r#"{{"code":{code},"message":"{message}"}}"#);
        let response = format!("HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}", reply.len());
        socket.write_all(response.as_bytes()).await.unwrap();
        String::from_utf8(request).unwrap()
    }

    /// curl posts the body to a local server; its answer comes back.
    #[tokio::test]
    async fn posts_through_curl() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        let config = Config::new("devicekey", Some(&server), None).unwrap();
        let fields = json!({"title": "a \"quoted\" title", "body": "line\nbreak"});
        let (request, sent) = tokio::join!(answer(&listener, 200), send(&config, fields, Some("yochi-1")));
        sent.unwrap();
        assert!(request.starts_with("POST /devicekey HTTP/1.1\r\n"), "{request}");
        let body: Value = serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap();
        assert_eq!(body, json!({"title": "a \"quoted\" title", "body": "line\nbreak", "id": "yochi-1"}));

        let (_, sent) = tokio::join!(answer(&listener, 400), send(&config, test_message(Lang::English), None));
        assert_eq!(sent.unwrap_err().to_string(), "Bark answered 400: failed to get device token");
    }
}
