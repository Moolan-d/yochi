//! One Agent Message per plain-mode `hc connect`: hello, terminal.send, then
//! close. This never occupies the connection that pushes the session list.

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
const SEND_TIMEOUT: Duration = Duration::from_secs(30);

pub struct Request {
    pub id: String,
    pub session: String,
    pub text: String,
    pub force: bool,
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
    match tokio::time::timeout(SEND_TIMEOUT, request_core(hc, &request)).await {
        Ok(Ok(reply)) => map_reply(request, reply),
        Ok(Err(err)) => err.into_response(request.id),
        Err(_) => Response::failed(request.id, "timeout", "发送超时，结果未知"),
    }
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

async fn request_core(hc: &str, request: &Request) -> std::result::Result<Value, RequestError> {
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

    let send = json!({"jsonrpc": "2.0", "id": 1, "method": "terminal.send", "params": {
        "terminal": request.session, "text": request.text, "force": request.force,
    }});
    stdin.write_all(format!("{send}\n").as_bytes()).await.map_err(RequestError::after)?;
    stdin.flush().await.map_err(RequestError::after)?;
    while let Some(line) = lines.next_line().await.map_err(RequestError::after)? {
        let reply: Value = serde_json::from_str(&line).context("bad terminal.send reply from core").map_err(RequestError::after)?;
        if reply["id"] == 1 {
            return Ok(reply);
        }
    }
    Err(RequestError::after(anyhow!("core closed before terminal.send replied")))
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
