//! One Agent Message or key press per plain-mode `hc connect`: hello,
//! terminal.send or terminal.keys, then close. This never occupies the
//! connection that pushes the session list.

use crate::herdr::CoreView;
use anyhow::{Context as _, Result, anyhow};
use serde::Serialize;
use serde_json::{Value, json};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::process::Command;
use tokio::sync::watch;

pub const MAX_MESSAGE_BYTES: usize = 16 * 1024;
/// Enough for a chord sequence such as `down down enter`; the app sends one tap at a time.
pub const MAX_KEYS: usize = 8;
const SEND_TIMEOUT: Duration = Duration::from_secs(30);

pub struct Request {
    pub id: String,
    pub session: String,
    pub text: String,
    pub force: bool,
}

/// Named keys for terminal.keys (`up`, `enter`, `esc`, `shift+tab`, `1`, …).
pub struct KeysRequest {
    pub id: String,
    pub session: String,
    pub keys: Vec<String>,
}

/// An answer to what the Agent is waiting for: `allow` or `deny` a
/// permission, or an option's number (from 1) for a question.
pub struct AnswerRequest {
    pub id: String,
    pub session: String,
    pub choice: String,
    /// core's status message the phone showed; the answer only goes in while it still holds.
    pub expect: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Sent {
        id: String,
        turn: u64,
        status: Option<String>,
        started: Option<bool>,
    },
    SendFailed {
        id: String,
        kind: String,
        message: String,
    },
    KeysSent {
        id: String,
    },
    KeysFailed {
        id: String,
        kind: String,
        message: String,
    },
}

impl Response {
    fn failed(id: impl Into<String>, kind: impl Into<String>, message: impl Into<String>) -> Self {
        Self::SendFailed { id: id.into(), kind: kind.into(), message: message.into() }
    }
}

pub async fn send(hc: &str, view: &watch::Receiver<CoreView>, request: Request) -> Response {
    if let Err(response) = validate(&view.borrow(), &request) {
        return response;
    }
    let params = json!({"terminal": request.session, "text": request.text, "force": request.force});
    match tokio::time::timeout(SEND_TIMEOUT, request_core(hc, "terminal.send", params)).await {
        Ok(Ok(reply)) => map_reply(request, reply),
        Ok(Err(err)) => err.into_response(request.id),
        Err(_) => Response::failed(request.id, "timeout", "发送超时，结果未知"),
    }
}

/// Like an Agent Message, pressing keys never attaches to the terminal, so it
/// neither takes over nor resizes it; core applies the same quiet rule.
pub async fn press(hc: &str, view: &watch::Receiver<CoreView>, request: KeysRequest) -> Response {
    let failed = |kind: &str, message: String| Response::KeysFailed { id: request.id.clone(), kind: kind.into(), message };
    if let Err(message) = validate_keys(&view.borrow(), &request) {
        return failed("invalid_params", message.into());
    }
    let params = json!({"terminal": request.session, "keys": request.keys});
    let reply = match tokio::time::timeout(SEND_TIMEOUT, request_core(hc, "terminal.keys", params)).await {
        Ok(Ok(reply)) => reply,
        Ok(Err(RequestError::BeforeSend(error))) => return failed("unavailable", format!("{error:#}")),
        Ok(Err(RequestError::AfterSend(error))) => return failed("unknown", format!("{error:#}")),
        Err(_) => return failed("timeout", "按键超时，结果未知".into()),
    };
    match reply.get("error") {
        Some(error) => failed(
            error["data"]["kind"].as_str().unwrap_or("unavailable"),
            error["message"].as_str().unwrap_or("按键发送失败").into(),
        ),
        None => Response::KeysSent { id: request.id },
    }
}

/// Presses the keys for an answer, after checking the Agent still waits for
/// the same thing the phone showed: someone at the desk may have answered.
/// Claude Code's dialogs put Yes first, cancel on Esc, and number a single
/// question's options from 1 (experiment 0001).
pub async fn answer(hc: &str, view: &watch::Receiver<CoreView>, request: AnswerRequest) -> Response {
    let keys = match answer_keys(&view.borrow(), &request) {
        Ok(keys) => keys,
        Err((kind, message)) => return Response::KeysFailed { id: request.id, kind: kind.into(), message: message.into() },
    };
    press(hc, view, KeysRequest { id: request.id, session: request.session, keys }).await
}

fn answer_keys(view: &CoreView, request: &AnswerRequest) -> Result<Vec<String>, (&'static str, &'static str)> {
    let session = view.sessions.iter().find(|session| session.id == request.session).ok_or(("not_found", "会话不存在或已结束"))?;
    let status = session.status.as_ref().filter(|status| status.state == "blocked").ok_or(("changed", "Agent 已不在等待"))?;
    if status.message != request.expect {
        return Err(("changed", "Agent 等待的内容已变化"));
    }
    let key = match (status.kind.as_deref(), request.choice.as_str()) {
        (Some("permission"), "allow") => "1",
        (Some("permission" | "question"), "deny") => "esc",
        (Some("question"), number) if matches!(number.parse::<u8>(), Ok(1..=9)) => number,
        _ => return Err(("invalid_params", "无法这样作答")),
    };
    Ok(vec![key.to_owned()])
}

fn validate_keys(view: &CoreView, request: &KeysRequest) -> Result<(), &'static str> {
    if request.keys.is_empty() || request.keys.len() > MAX_KEYS {
        return Err("按键数量无效");
    }
    if request.keys.iter().any(|key| key.is_empty() || key.len() > 16) {
        return Err("按键名称无效");
    }
    if !view.sessions.iter().any(|session| session.id == request.session) {
        return Err("会话不存在或已结束");
    }
    Ok(())
}

fn validate(view: &CoreView, request: &Request) -> Result<(), Response> {
    if request.text.trim().is_empty() {
        return Err(Response::failed(&request.id, "invalid_params", "消息不能为空"));
    }
    if request.text.len() > MAX_MESSAGE_BYTES {
        return Err(Response::failed(&request.id, "too_long", "消息超过 16 KiB 上限"));
    }
    if !view.sessions.iter().any(|session| session.id == request.session) {
        return Err(Response::failed(&request.id, "not_found", "会话不存在或已结束"));
    }
    Ok(())
}

/// Once any part of terminal.send may have been written, a transport failure
/// cannot prove that core did not accept it.
enum RequestError {
    BeforeSend(anyhow::Error),
    AfterSend(anyhow::Error),
}

impl RequestError {
    fn before(error: impl Into<anyhow::Error>) -> Self {
        Self::BeforeSend(error.into())
    }

    fn after(error: impl Into<anyhow::Error>) -> Self {
        Self::AfterSend(error.into())
    }

    fn into_response(self, id: String) -> Response {
        let (kind, error) = match self {
            Self::BeforeSend(error) => ("unavailable", error),
            Self::AfterSend(error) => ("unknown", error),
        };
        Response::failed(id, kind, format!("{error:#}"))
    }
}

async fn request_core(hc: &str, method: &str, params: Value) -> std::result::Result<Value, RequestError> {
    let mut child = Command::new(hc)
        .arg("connect")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting `{hc} connect`"))
        .map_err(RequestError::before)?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin")).map_err(RequestError::before)?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout")).map_err(RequestError::before)?;
    let mut lines = BufReader::new(stdout).lines();

    let hello = json!({"jsonrpc": "2.0", "id": 0, "method": "hello", "params": {}});
    stdin.write_all(format!("{hello}\n").as_bytes()).await.map_err(RequestError::before)?;
    stdin.flush().await.map_err(RequestError::before)?;
    let line = lines
        .next_line()
        .await
        .map_err(RequestError::before)?
        .ok_or_else(|| anyhow!("core closed before hello"))
        .map_err(RequestError::before)?;
    let reply: Value = serde_json::from_str(&line).context("bad hello reply from core").map_err(RequestError::before)?;
    if let Some(error) = reply.get("error") {
        return Err(RequestError::before(anyhow!("core refused hello: {error}")));
    }
    if reply["result"]["generation"] != 1 {
        return Err(RequestError::before(anyhow!(
            "unsupported herdr-core protocol generation {}",
            reply["result"]["generation"]
        )));
    }

    let call = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    stdin.write_all(format!("{call}\n").as_bytes()).await.map_err(RequestError::after)?;
    stdin.flush().await.map_err(RequestError::after)?;
    while let Some(line) = lines.next_line().await.map_err(RequestError::after)? {
        let reply: Value = serde_json::from_str(&line).with_context(|| format!("bad {method} reply from core")).map_err(RequestError::after)?;
        if reply["id"] == 1 {
            return Ok(reply);
        }
    }
    Err(RequestError::after(anyhow!("core closed before {method} replied")))
}

fn map_reply(request: Request, reply: Value) -> Response {
    if let Some(error) = reply.get("error") {
        let kind = error["data"]["kind"].as_str().unwrap_or("unavailable");
        let message = error["message"].as_str().unwrap_or("Agent Message 发送失败");
        return Response::failed(request.id, kind, message);
    }
    let Some(turn) = reply["result"]["turn"].as_u64() else {
        return Response::failed(request.id, "unknown", "herdr-core 返回了无效的发送结果");
    };
    let status = reply["result"]["status"].as_str().map(str::to_owned);
    let started = reply["result"]["started"].as_bool();
    Response::Sent { id: request.id, turn, status, started }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::Session;

    fn request(text: String) -> Request {
        Request { id: "request-1".into(), session: "t1".into(), text, force: false }
    }

    fn view() -> CoreView {
        CoreView {
            core: Some("mac".into()),
            sessions: vec![Session {
                id: "t1".into(),
                machine: None,
                title: "agent".into(),
                program: Some("claude".into()),
                cwd: "/".into(),
                status: None,
                cols: 80,
                rows: 24,
                turn: 0,
                parent: None,
                place: None,
                pid: None,
            }],
            spaces: Vec::new(),
        }
    }

    #[test]
    fn validates_text_and_live_session() {
        let view = view();
        assert!(validate(&view, &request("hello".into())).is_ok());
        assert!(matches!(
            validate(&view, &request("  \n".into())),
            Err(Response::SendFailed { kind, .. }) if kind == "invalid_params"
        ));
        assert!(matches!(
            validate(&view, &request("x".repeat(MAX_MESSAGE_BYTES + 1))),
            Err(Response::SendFailed { kind, .. }) if kind == "too_long"
        ));
        let mut missing = request("hello".into());
        missing.session = "t404".into();
        assert!(matches!(
            validate(&view, &missing),
            Err(Response::SendFailed { kind, .. }) if kind == "not_found"
        ));
    }

    #[test]
    fn validates_keys_and_live_session() {
        let view = view();
        let keys = |keys: &[&str]| KeysRequest {
            id: "k1".into(),
            session: "t1".into(),
            keys: keys.iter().map(|key| (*key).into()).collect(),
        };
        assert!(validate_keys(&view, &keys(&["down", "enter"])).is_ok());
        assert!(validate_keys(&view, &keys(&[])).is_err());
        assert!(validate_keys(&view, &keys(&["up"; MAX_KEYS + 1])).is_err());
        assert!(validate_keys(&view, &keys(&[""])).is_err());
        let mut missing = keys(&["esc"]);
        missing.session = "t404".into();
        assert!(validate_keys(&view, &missing).is_err());
    }

    #[test]
    fn answers_only_what_is_still_asked() {
        let mut view = view();
        let answer = |choice: &str, expect: &str| AnswerRequest {
            id: "a1".into(),
            session: "t1".into(),
            choice: choice.into(),
            expect: Some(expect.into()),
        };
        assert_eq!(answer_keys(&view, &answer("allow", "x")).unwrap_err().0, "changed", "not blocked");
        view.sessions[0].status = Some(crate::session::Status {
            state: "blocked".into(),
            app: Some("claude-code".into()),
            message: Some("approve Bash: ls".into()),
            kind: Some("permission".into()),
        });
        assert_eq!(answer_keys(&view, &answer("allow", "approve Bash: ls")).unwrap(), ["1"]);
        assert_eq!(answer_keys(&view, &answer("deny", "approve Bash: ls")).unwrap(), ["esc"]);
        assert_eq!(answer_keys(&view, &answer("allow", "approve Bash: rm")).unwrap_err().0, "changed");
        assert_eq!(answer_keys(&view, &answer("2", "approve Bash: ls")).unwrap_err().0, "invalid_params");

        let status = view.sessions[0].status.as_mut().unwrap();
        status.kind = Some("question".into());
        status.message = Some("answer: Red or Blue?".into());
        assert_eq!(answer_keys(&view, &answer("2", "answer: Red or Blue?")).unwrap(), ["2"]);
        assert_eq!(answer_keys(&view, &answer("allow", "answer: Red or Blue?")).unwrap_err().0, "invalid_params");
        assert_eq!(answer_keys(&view, &answer("12", "answer: Red or Blue?")).unwrap_err().0, "invalid_params");
    }

    #[test]
    fn length_limit_is_utf8_bytes() {
        let view = view();
        assert!(validate(&view, &request("界".repeat(MAX_MESSAGE_BYTES / 3))).is_ok());
        assert!(matches!(
            validate(&view, &request("界".repeat(MAX_MESSAGE_BYTES / 3 + 1))),
            Err(Response::SendFailed { kind, .. }) if kind == "too_long"
        ));
    }

    #[test]
    fn maps_send_result() {
        let response = map_reply(request("hello".into()), json!({
            "jsonrpc": "2.0", "id": 1,
            "result": {"turn": 7, "status": "working", "started": true, "wait": null},
        }));
        assert!(matches!(
            response,
            Response::Sent { id, turn: 7, status: Some(status), started: Some(true) }
                if id == "request-1" && status == "working"
        ));
    }

    #[test]
    fn transport_failure_knows_whether_send_may_have_started() {
        let before = RequestError::before(anyhow!("no hc")).into_response("request-1".into());
        assert!(matches!(
            before,
            Response::SendFailed { kind, .. } if kind == "unavailable"
        ));
        let after = RequestError::after(anyhow!("connection closed")).into_response("request-1".into());
        assert!(matches!(
            after,
            Response::SendFailed { kind, .. } if kind == "unknown"
        ));
    }

    #[test]
    fn maps_core_error_kind_and_message() {
        let response = map_reply(request("hello".into()), json!({
            "jsonrpc": "2.0", "id": 1,
            "error": {"code": -32000, "message": "waiting for permission", "data": {"kind": "blocked"}},
        }));
        assert!(matches!(
            response,
            Response::SendFailed { id, kind, message }
                if id == "request-1" && kind == "blocked" && message == "waiting for permission"
        ));
    }
}
