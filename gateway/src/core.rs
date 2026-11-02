//! A plain-mode `hc connect` kept open for a series of requests, for work
//! that asks the core again and again (following a transcript).

use anyhow::{Context as _, Result, anyhow, bail};
use serde_json::{Value, json};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

pub struct Client {
    _child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    next: u64,
}

impl Client {
    pub async fn connect(hc: &str) -> Result<Self> {
        let mut child = Command::new(hc)
            .arg("connect")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("starting `{hc} connect`"))?;
        let stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
        let lines = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?).lines();
        let mut client = Self { _child: child, stdin, lines, next: 0 };
        let hello = client.call("hello", json!({})).await?.map_err(|error| anyhow!("core refused hello: {error}"))?;
        if hello["generation"] != 1 {
            bail!("unsupported herdr-core protocol generation {}", hello["generation"]);
        }
        Ok(client)
    }

    /// The result, or the core's error object (`kind` under `data`).
    pub async fn call(&mut self, method: &str, params: Value) -> Result<std::result::Result<Value, Value>> {
        let id = self.next;
        self.next += 1;
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.stdin.write_all(format!("{request}\n").as_bytes()).await?;
        self.stdin.flush().await?;
        while let Some(line) = self.lines.next_line().await? {
            let mut reply: Value = serde_json::from_str(&line).with_context(|| format!("bad {method} reply from core"))?;
            if reply["id"] != id {
                continue;
            }
            return Ok(match reply.get_mut("error") {
                Some(error) => Err(error.take()),
                None => Ok(reply["result"].take()),
            });
        }
        bail!("core closed before {method} replied")
    }
}

/// The `kind` of a core error object.
pub fn error_kind(error: &Value) -> &str {
    error["data"]["kind"].as_str().unwrap_or("")
}

/// A one-shot plain-mode connection: `hello`, one call, then close. Work that
/// happens once (a message, keys, a new terminal) uses this instead of keeping
/// a connection open.
pub enum RequestError {
    /// The call was never written: it certainly did not happen.
    BeforeSend(anyhow::Error),
    /// The call was written and something broke: it may have happened.
    AfterSend(anyhow::Error),
}

impl RequestError {
    pub fn before(error: impl Into<anyhow::Error>) -> Self {
        Self::BeforeSend(error.into())
    }

    pub fn after(error: impl Into<anyhow::Error>) -> Self {
        Self::AfterSend(error.into())
    }
}

/// The whole reply (`result` or `error`), after checking the protocol generation.
pub async fn request(hc: &str, method: &str, params: Value) -> std::result::Result<Value, RequestError> {
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
