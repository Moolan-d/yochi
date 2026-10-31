//! Companion API v0, all WebSocket (iOS blocks plain HTTP to tailnet IPs, not
//! `ws://`). `/v0/pair` trades a pairing code for a device token; the others
//! need `Authorization: Bearer <device token>`:
//! - `/v0/ws` pushes `hello`, then the whole session list whenever it changes.
//!   The app may send Agent Messages or `unpair` to remove itself.
//! - `/v0/observe?session=<id>` streams one terminal read-only: control as text,
//!   terminal bytes as binary messages.
//!
//! Unpairing a device (by itself or with `companion-gateway revoke`) closes its connections.

use crate::agent;
use crate::devices::{Device, Store};
use crate::herdr::CoreView;
use crate::layout::Space;
use crate::observe::{Observer, Output};
use crate::session::Session;
use anyhow::{Context as _, Result};
use axum::Router;
use axum::extract::{Query, State};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, SystemTime};
use tokio::sync::watch;

pub const API_VERSION: u32 = 0;

#[derive(Clone)]
struct AppState {
    hc: Arc<str>,
    view: watch::Receiver<CoreView>,
    store: Arc<Store>,
    /// Paired devices, reloaded when the CLI changes the state file.
    devices: Arc<watch::Sender<Vec<Device>>>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage<'a> {
    Hello { api: u32, gateway: &'static str },
    Sessions { core: Option<&'a str>, connected: bool, sessions: &'a [Session], spaces: &'a [Space] },
    /// Observing began; render a grid of this size.
    Attached { cols: u16, rows: u16 },
    /// The terminal's grid changed (another client resized it).
    Size { cols: u16, rows: u16 },
    /// The stream ended; `reason` as the core gave it, or why attaching failed.
    Closed { reason: &'a Value },
    /// Pairing succeeded; the token is this device's from now on.
    Paired { device: &'a str, token: &'a str },
    /// Wrong or expired pairing code.
    Rejected,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum AppMessage {
    Pair {
        code: String,
        #[serde(default)]
        name: String,
    },
    Send {
        id: String,
        session: String,
        text: String,
        #[serde(default)]
        force: bool,
    },
    /// Forget this device (the app's own "unpair").
    Unpair,
}

pub async fn serve(listen: SocketAddr, store: Store, hc: String, view: watch::Receiver<CoreView>) -> Result<()> {
    let devices = store.devices()?;
    if devices.is_empty() {
        eprintln!("No paired devices yet; pair a phone with `companion-gateway pair`.");
    }
    let store = Arc::new(store);
    let devices = Arc::new(watch::Sender::new(devices));
    tokio::spawn(reload_devices(store.clone(), devices.clone()));
    let state = AppState { hc: hc.into(), view, store, devices };
    let app = Router::new()
        .route("/v0/pair", get(pair))
        .route("/v0/ws", get(upgrade))
        .route("/v0/observe", get(observe))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind(listen)
        .await
        .with_context(|| format!("listening on {listen}"))?;
    eprintln!("Gateway listening on ws://{listen}/v0/ws");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

/// Picks up `companion-gateway revoke` (and anything else that rewrites the state file).
async fn reload_devices(store: Arc<Store>, devices: Arc<watch::Sender<Vec<Device>>>) {
    let modified = || std::fs::metadata(store.path()).and_then(|meta| meta.modified()).ok();
    let mut seen: Option<SystemTime> = modified();
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let now = modified();
        if now == seen {
            continue;
        }
        seen = now;
        match store.devices() {
            Ok(current) => {
                devices.send_if_modified(|devices| {
                    let changed = *devices != current;
                    *devices = current;
                    changed
                });
            }
            Err(err) => eprintln!("reloading paired devices: {err:#}"),
        }
    }
}

async fn pair(State(state): State<AppState>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| pairing(socket, state))
}

/// One attempt: the app sends `pair`, gets `paired` or `rejected`, and the socket closes.
async fn pairing(mut socket: WebSocket, state: AppState) {
    let Ok(Some(Ok(Message::Text(text)))) = tokio::time::timeout(Duration::from_secs(10), socket.recv()).await else {
        return;
    };
    let Ok(AppMessage::Pair { code, name }) = serde_json::from_str(&text) else { return };
    let name: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
    let name = match name.trim() {
        "" => "iPhone".to_owned(),
        name => name.to_owned(),
    };
    let store = state.store.clone();
    let paired = tokio::task::spawn_blocking(move || store.pair(&code, &name)).await;
    match paired.map_err(anyhow::Error::from).and_then(|paired| paired) {
        Ok(Some((device, token))) => {
            eprintln!("Paired {} ({})", device.name, device.id);
            let id = device.id.clone();
            state.devices.send_modify(|devices| devices.push(device));
            let _ = send(&mut socket, &ServerMessage::Paired { device: &id, token: &token }).await;
        }
        Ok(None) => {
            let _ = send(&mut socket, &ServerMessage::Rejected).await;
        }
        Err(err) => eprintln!("pairing: {err:#}"),
    }
    let _ = socket.send(Message::Close(None)).await;
}

async fn unpair(state: &AppState, id: &str) {
    let store = state.store.clone();
    let revoke = id.to_owned();
    match tokio::task::spawn_blocking(move || store.revoke(&revoke)).await.map_err(anyhow::Error::from) {
        Ok(Ok(Some(device))) => eprintln!("{} ({}) unpaired itself", device.name, device.id),
        Ok(Ok(None)) => {}
        Ok(Err(err)) | Err(err) => eprintln!("unpairing: {err:#}"),
    }
    state.devices.send_modify(|devices| devices.retain(|device| device.id != id));
}

async fn upgrade(State(state): State<AppState>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    let Some(device) = authorize(&headers, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    ws.on_upgrade(move |socket| push(socket, state, device))
}

#[derive(Deserialize)]
struct ObserveQuery {
    session: String,
}

async fn observe(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ObserveQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(device) = authorize(&headers, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Some(size) = session_size(&state.view.borrow(), &query.session) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    ws.on_upgrade(move |socket| relay(socket, state, device, query.session, size))
}

fn session_size(view: &CoreView, id: &str) -> Option<(u16, u16)> {
    view.sessions.iter().find(|s| s.id == id).map(|s| (s.cols, s.rows))
}

async fn relay(mut socket: WebSocket, state: AppState, device: String, id: String, (cols, rows): (u16, u16)) {
    let mut observer = match Observer::attach(&state.hc, &id, cols, rows).await {
        Ok(observer) => observer,
        Err(err) => {
            let reason = Value::String(format!("{err:#}"));
            let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
            return;
        }
    };
    let grid = |record: &Value, key: &str, default: u16| {
        record[key].as_u64().and_then(|n| u16::try_from(n).ok()).unwrap_or(default)
    };
    let mut size = (grid(&observer.terminal, "cols", cols), grid(&observer.terminal, "rows", rows));
    if send(&mut socket, &ServerMessage::Attached { cols: size.0, rows: size.1 }).await.is_err() {
        return;
    }

    let mut view = state.view.clone();
    view.mark_unchanged();
    let mut devices = state.devices.subscribe();
    loop {
        tokio::select! {
            output = observer.next() => match output {
                Some(Output::Data(bytes)) => {
                    let len = bytes.len();
                    if socket.send(Message::Binary(bytes.into())).await.is_err() { break }
                    // Credit only what reached the app, so a slow phone gets a fresh repaint
                    // from the core instead of an ever-growing backlog here.
                    if observer.consumed(len).await.is_err() { break }
                }
                Some(Output::Closed(reason)) => {
                    let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
                    return;
                }
                None => return,
            },
            changed = view.changed() => {
                if changed.is_err() { break }
                let current = session_size(&view.borrow_and_update(), &id);
                if let Some(current) = current && current != size {
                    size = current;
                    if send(&mut socket, &ServerMessage::Size { cols: size.0, rows: size.1 }).await.is_err() { break }
                }
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
            () = unpaired(&mut devices, &device) => break,
        }
    }
    observer.detach().await;
}

/// The paired device whose token the request carries.
fn authorize(headers: &HeaderMap, devices: &[Device]) -> Option<String> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))?;
    devices.iter().find(|device| device.holds(token)).map(|device| device.id.clone())
}

/// Resolves once `device` is no longer paired.
async fn unpaired(devices: &mut watch::Receiver<Vec<Device>>, device: &str) {
    if devices.wait_for(|devices| !devices.iter().any(|d| d.id == device)).await.is_err() {
        std::future::pending::<()>().await;
    }
}

async fn push(mut socket: WebSocket, state: AppState, device: String) {
    let mut view = state.view.clone();
    let mut devices = state.devices.subscribe();
    let (outgoing, mut responses) = tokio::sync::mpsc::unbounded_channel::<String>();
    let hello = ServerMessage::Hello { api: API_VERSION, gateway: env!("CARGO_PKG_VERSION") };
    if send(&mut socket, &hello).await.is_err() {
        return;
    }
    loop {
        let message = {
            let current = view.borrow_and_update();
            serde_json::to_string(&ServerMessage::Sessions {
                core: current.core.as_deref(),
                connected: current.connected(),
                sessions: &current.sessions,
                spaces: &current.spaces,
            })
        };
        let Ok(message) = message else { return };
        if socket.send(Message::Text(message.into())).await.is_err() {
            return;
        }
        tokio::select! {
            changed = view.changed() => if changed.is_err() { return },
            response = responses.recv() => {
                let Some(response) = response else { return };
                if socket.send(Message::Text(response.into())).await.is_err() { return }
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return,
                Some(Ok(Message::Text(text))) => match serde_json::from_str(&text) {
                    Ok(AppMessage::Unpair) => {
                        unpair(&state, &device).await;
                        return;
                    }
                    Ok(AppMessage::Send { id, session, text, force }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = agent::Request { id, session, text, force };
                            let response = agent::send(&state.hc, &state.view, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    _ => {}
                },
                Some(Ok(_)) => {}
            },
            () = unpaired(&mut devices, &device) => return,
        }
    }
}

async fn send(socket: &mut WebSocket, message: &ServerMessage<'_>) -> Result<()> {
    let text = serde_json::to_string(message)?;
    socket.send(Message::Text(text.into())).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_agent_message_and_unpair() {
        let message: AppMessage = serde_json::from_str(
            r#"{"type":"send","id":"r1","session":"t1","text":"hello"}"#,
        )
        .unwrap();
        assert!(matches!(
            message,
            AppMessage::Send { id, session, text, force: false }
                if id == "r1" && session == "t1" && text == "hello"
        ));
        let message: AppMessage = serde_json::from_str(
            r#"{"type":"send","id":"r2","session":"t1","text":"yes","force":true}"#,
        )
        .unwrap();
        assert!(matches!(message, AppMessage::Send { force: true, .. }));
        assert!(matches!(serde_json::from_str(r#"{"type":"unpair"}"#), Ok(AppMessage::Unpair)));
    }

    #[test]
    fn bearer_token_names_the_device() {
        let dir = std::env::temp_dir().join(format!("companion-server-{}", std::process::id()));
        let store = Store::open(dir.clone()).unwrap();
        let code = store.offer().unwrap();
        let (device, token) = store.pair(&code, "iPhone").unwrap().unwrap();
        let devices = store.devices().unwrap();
        std::fs::remove_dir_all(dir).unwrap();

        let mut headers = HeaderMap::new();
        assert_eq!(authorize(&headers, &devices), None);
        headers.insert(header::AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        assert_eq!(authorize(&headers, &devices), Some(device.id));
        headers.insert(header::AUTHORIZATION, "Bearer wrong".parse().unwrap());
        assert_eq!(authorize(&headers, &devices), None);
    }
}
