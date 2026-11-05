//! Starts a new terminal on the core, for the phone's "new session": a chosen
//! program (an Agent or the machine's shell) in a chosen directory, on this Mac
//! or a connected machine. Only the Gateway's side of herdr-core is touched, so
//! it is not a Takeover and does not resize anything. Its `herdr.space` label
//! has the Herdr desktop app take it into a space, in a tab of its own.

use crate::core::{RequestError, error_kind, request as request_core};
use crate::lang::Lang;
use serde::Serialize;
use serde_json::{Value, json};
use std::time::Duration;

const RUN_TIMEOUT: Duration = Duration::from_secs(30);
pub const MAX_ARGV: usize = 8;
pub const MAX_ARG_BYTES: usize = 512;
pub const MAX_CWD_BYTES: usize = 4096;
pub const MAX_MACHINE_BYTES: usize = 64;
pub const MAX_SPACE_BYTES: usize = 128;

pub struct RunRequest {
    pub id: String,
    /// Core's name for a connected machine; None for this Mac.
    pub machine: Option<String>,
    /// Empty means the core's default: its own directory here, the machine's
    /// home there.
    pub cwd: String,
    /// Program and arguments; empty for the machine's shell.
    pub argv: Vec<String>,
    /// A space from the session list, on the same machine; None for a new one.
    pub space: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    RunCreated { id: String, session: String },
    RunFailed { id: String, kind: String, message: String },
}

impl Response {
    fn failed(id: String, kind: impl Into<String>, message: impl Into<String>) -> Self {
        Self::RunFailed { id, kind: kind.into(), message: message.into() }
    }
}

pub async fn run(hc: &str, request: RunRequest, lang: Lang) -> Response {
    if let Err(message) = validate(&request, lang) {
        return Response::failed(request.id, "invalid_params", message);
    }
    let id = request.id.clone();
    let machine = machine(&request).map(str::to_owned);
    let space = match space(&request) {
        Some(space) => local(space, machine.as_deref()).to_owned(),
        None => match new_space_id() {
            Ok(id) => id,
            Err(error) => return Response::failed(id, "unavailable", format!("{error:#}")),
        },
    };
    match tokio::time::timeout(RUN_TIMEOUT, request_core(hc, "terminal.run", params(&request, &space))).await {
        Ok(Ok(reply)) => map_reply(id, machine.as_deref(), reply, lang),
        Ok(Err(RequestError::BeforeSend(error))) => Response::failed(id, "unavailable", format!("{error:#}")),
        // The call may have started a terminal; say so rather than offer a retry.
        Ok(Err(RequestError::AfterSend(error))) => Response::failed(id, "unknown", format!("{error:#}")),
        Err(_) => Response::failed(id, "unknown", lang.pick("创建超时，结果未知", "Timed out creating it; the result is unknown")),
    }
}

fn machine(request: &RunRequest) -> Option<&str> {
    request.machine.as_deref().map(str::trim).filter(|machine| !machine.is_empty())
}

fn space(request: &RunRequest) -> Option<&str> {
    request.space.as_deref().map(str::trim).filter(|space| !space.is_empty())
}

/// The space's id on its own machine, as its labels and layout name it.
fn local<'a>(space: &'a str, machine: Option<&str>) -> &'a str {
    machine.and_then(|m| space.strip_prefix(m)?.strip_prefix('/')).unwrap_or(space)
}

/// Herdr's shape of id; the app makes the space, unnamed, when it adopts the
/// terminal, and names it after the terminal's folder.
fn new_space_id() -> anyhow::Result<String> {
    Ok(format!("sp{}", crate::devices::hex(&crate::devices::random_bytes::<16>()?)))
}

fn validate(request: &RunRequest, lang: Lang) -> Result<(), String> {
    if request.argv.len() > MAX_ARGV {
        return Err(lang.pick(format!("程序参数最多 {MAX_ARGV} 个"), format!("At most {MAX_ARGV} program arguments")));
    }
    if request.argv.iter().any(|arg| arg.is_empty() || arg.len() > MAX_ARG_BYTES) {
        return Err(lang.pick("程序参数无效", "Invalid program arguments").into());
    }
    if request.cwd.len() > MAX_CWD_BYTES {
        return Err(lang.pick("目录过长", "The folder is too long").into());
    }
    if machine(request).is_some_and(|machine| machine.len() > MAX_MACHINE_BYTES) {
        return Err(lang.pick("机器名无效", "Invalid machine name").into());
    }
    if let Some(space) = space(request) {
        // A space lives on one machine; one from another would be made anew there.
        let here = local(space, machine(request));
        if space.len() > MAX_SPACE_BYTES || here.contains('/') || (machine(request).is_some() && here == space) {
            return Err(lang.pick("Space 不在所选机器上", "The Space isn't on the chosen machine").into());
        }
    }
    Ok(())
}

fn params(request: &RunRequest, space: &str) -> Value {
    let mut params = json!({
        "argv": request.argv,
        // The Gateway is no terminal: never make it the new terminal's parent,
        // and never type news about it anywhere.
        "no_parent": true,
        "no_notify": true,
        // No tab: Herdr opens one for it, rather than split someone's panes.
        "labels": {"herdr.space": space},
    });
    let cwd = request.cwd.trim();
    if !cwd.is_empty() {
        params["cwd"] = json!(cwd);
    }
    if let Some(machine) = machine(request) {
        params["on"] = json!(machine);
    }
    params
}

/// The address as the session list gives it: `t7` here, `vps-us/t7` there.
fn map_reply(id: String, machine: Option<&str>, reply: Value, lang: Lang) -> Response {
    if let Some(error) = reply.get("error") {
        return Response::failed(
            id,
            error_kind(error),
            error["message"].as_str().unwrap_or(lang.pick("创建会话失败", "Couldn't create the session")),
        );
    }
    let Some(address) = reply["result"]["address"].as_str().filter(|address| !address.is_empty()) else {
        return Response::failed(id, "unknown", lang.pick("herdr-core 返回了无效的会话信息", "herdr-core gave invalid session details"));
    };
    let session = match machine {
        Some(machine) if !address.contains('/') => format!("{machine}/{address}"),
        _ => address.to_owned(),
    };
    Response::RunCreated { id, session }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> RunRequest {
        RunRequest { id: "r1".into(), machine: None, cwd: "/Users/ryan/app".into(), argv: vec!["claude".into()], space: None }
    }

    #[test]
    fn params_leave_the_default_directory_alone() {
        let mut request = request();
        request.cwd = "  ".into();
        let params = params(&request, "sp1");
        assert_eq!(params["argv"], json!(["claude"]));
        assert!(params.get("cwd").is_none());
        assert!(params.get("on").is_none());
        assert_eq!(params["no_parent"], json!(true));
        assert_eq!(params["no_notify"], json!(true));
        assert_eq!(params["labels"], json!({"herdr.space": "sp1"}));
    }

    #[test]
    fn params_carry_directory_and_machine() {
        let mut request = request();
        request.machine = Some(" vps-us ".into());
        request.cwd = " /root/app ".into();
        request.argv = Vec::new();
        let params = params(&request, "sp2");
        assert_eq!(params["cwd"], json!("/root/app"));
        assert_eq!(params["on"], json!("vps-us"));
        assert_eq!(params["argv"], json!([]));
    }

    #[test]
    fn validates_arguments() {
        let mut request = request();
        assert!(validate(&request, Lang::English).is_ok());
        request.argv = vec!["x".into(); MAX_ARGV + 1];
        assert!(validate(&request, Lang::English).is_err());
        request.argv = vec!["".into()];
        assert!(validate(&request, Lang::English).is_err());
        request.argv = vec!["x".into()];
        request.cwd = "x".repeat(MAX_CWD_BYTES + 1);
        assert!(validate(&request, Lang::English).is_err());
        request.cwd = "/".into();
        request.machine = Some("m".repeat(MAX_MACHINE_BYTES + 1));
        assert!(validate(&request, Lang::English).is_err());
    }

    #[test]
    fn says_why_in_the_phones_language() {
        let mut request = request();
        request.cwd = "x".repeat(MAX_CWD_BYTES + 1);
        assert_eq!(validate(&request, Lang::English).unwrap_err(), "The folder is too long");
        assert_eq!(validate(&request, Lang::Chinese).unwrap_err(), "目录过长");
    }

    #[test]
    fn space_must_be_on_the_chosen_machine() {
        let mut request = request();
        request.space = Some("sp1".into());
        assert!(validate(&request, Lang::English).is_ok());
        request.space = Some("vps-us/sp1".into());
        assert!(validate(&request, Lang::English).is_err());
        request.machine = Some("vps-us".into());
        assert!(validate(&request, Lang::English).is_ok());
        assert_eq!(local("vps-us/sp1", Some("vps-us")), "sp1");
        request.space = Some("sp1".into());
        assert!(validate(&request, Lang::English).is_err());
        request.space = Some("vps-eu/sp1".into());
        assert!(validate(&request, Lang::English).is_err());
        request.space = Some(" ".into());
        assert!(validate(&request, Lang::English).is_ok());
    }

    #[test]
    fn new_space_ids_look_like_herdrs() {
        let id = new_space_id().unwrap();
        assert!(id.starts_with("sp") && id.len() == 34);
        assert_ne!(id, new_space_id().unwrap());
    }

    #[test]
    fn maps_created_with_its_machine() {
        let local = map_reply("r1".into(), None, json!({"result": {"address": "t24"}}), Lang::English);
        assert!(matches!(local, Response::RunCreated { session, .. } if session == "t24"));
        let remote = map_reply("r2".into(), Some("vps-us"), json!({"result": {"address": "t7"}}), Lang::English);
        assert!(matches!(remote, Response::RunCreated { session, .. } if session == "vps-us/t7"));
        // Core may already give the qualified address.
        let qualified = map_reply("r3".into(), Some("vps-us"), json!({"result": {"address": "vps-us/t7"}}), Lang::English);
        assert!(matches!(qualified, Response::RunCreated { session, .. } if session == "vps-us/t7"));
    }

    #[test]
    fn maps_core_errors_and_missing_address() {
        let failed = map_reply("r1".into(), None, json!({
            "error": {"code": -32000, "message": "no such machine", "data": {"kind": "machine_unknown"}},
        }), Lang::English);
        assert!(matches!(failed, Response::RunFailed { kind, .. } if kind == "machine_unknown"));
        let invalid = map_reply("r1".into(), None, json!({"result": {}}), Lang::English);
        assert!(matches!(invalid, Response::RunFailed { kind, .. } if kind == "unknown"));
    }
}
