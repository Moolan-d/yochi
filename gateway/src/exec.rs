//! One program through core's `machine.exec`, on the session's machine,
//! without a terminal. Only fixed, read-only programs go through here
//! (ADR 0001, 2026-11-03 revision): the phone never names what runs.

use crate::core::{RequestError, request as request_core};
use crate::lang::Lang;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use std::time::Duration;

pub enum Program<'a> {
    /// Run as given, no shell.
    Argv(&'a [&'a str]),
    /// A fixed script for that machine's `sh -c`.
    Line(&'a str),
}

pub struct Output {
    /// None when a signal ended it.
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    /// It wrote more than core kept, or ran out of time: stdout is the start.
    pub cut: bool,
}

#[derive(Debug)]
pub struct Failure {
    pub kind: String,
    pub message: String,
}

impl Failure {
    pub fn new(kind: &str, message: impl Into<String>) -> Self {
        Self { kind: kind.into(), message: message.into() }
    }
}

pub async fn exec(
    hc: &str,
    machine: Option<&str>,
    cwd: &str,
    program: Program<'_>,
    input: Option<&[u8]>,
    timeout_secs: u64,
    lang: Lang,
) -> Result<Output, Failure> {
    let mut params = json!({"cwd": cwd, "timeout": timeout_secs});
    match program {
        Program::Argv(argv) => params["argv"] = json!(argv),
        Program::Line(line) => params["line"] = json!(line),
    }
    if let Some(machine) = machine {
        params["on"] = json!(machine);
    }
    if let Some(input) = input {
        params["input"] = json!(STANDARD.encode(input));
    }
    // A little longer than core's own limit, so its answer wins.
    let wait = Duration::from_secs(timeout_secs + 5);
    match tokio::time::timeout(wait, request_core(hc, "machine.exec", params)).await {
        Ok(Ok(reply)) => from_reply(reply, lang),
        // Only reads; either way it is safe to ask again.
        Ok(Err(RequestError::BeforeSend(error) | RequestError::AfterSend(error))) => {
            Err(Failure::new("unavailable", format!("{error:#}")))
        }
        Err(_) => Err(Failure::new("timeout", lang.pick("超时", "Timed out"))),
    }
}

pub fn from_reply(reply: Value, lang: Lang) -> Result<Output, Failure> {
    if let Some(error) = reply.get("error") {
        return Err(Failure::new(
            error["data"]["kind"].as_str().unwrap_or("unavailable"),
            error["message"].as_str().unwrap_or(lang.pick("执行失败", "Couldn't run it")),
        ));
    }
    let result = &reply["result"];
    let stdout = result["stdout"]
        .as_str()
        .and_then(|data| STANDARD.decode(data).ok())
        .ok_or_else(|| Failure::new("unknown", lang.pick("herdr-core 返回了无效的结果", "herdr-core gave an invalid result")))?;
    Ok(Output {
        code: result["code"].as_i64().map(|code| code as i32),
        stdout,
        cut: result["truncated"] == true || result["timed_out"] == true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_results_and_errors() {
        let reply = json!({"result": {"code": 1, "stdout": STANDARD.encode("hi"), "truncated": false, "timed_out": true}});
        let output = from_reply(reply, Lang::English).unwrap();
        assert_eq!((output.code, output.stdout.as_slice(), output.cut), (Some(1), &b"hi"[..], true));
        let reply = json!({"error": {"message": "no answer", "data": {"kind": "unreachable"}}});
        assert_eq!(from_reply(reply, Lang::English).err().unwrap().kind, "unreachable");
        assert_eq!(from_reply(json!({"result": {}}), Lang::English).err().unwrap().kind, "unknown");
    }
}
