//! Companion API v0, all WebSocket (iOS blocks plain HTTP to tailnet IPs, not
//! `ws://`). `/v0/pair` trades a pairing code for a device token; the others
//! need `Authorization: Bearer <device token>`:
//! - `/v0/ws` pushes `hello`, then the whole session list whenever it changes.
//!   The app may send Agent Messages, key presses, or `unpair` to remove itself.
//! - `/v0/observe?session=<id>` streams one terminal: control as text,
//!   terminal bytes as binary messages. With `takeover=1&cols=&rows=` the
//!   terminal takes the phone's size while it is watched.
//! - `/v0/conversation?session=<id>` follows the conversation of the Agent in
//!   one terminal, read from its transcript.
//! - `/v0/screen?session=<id>` sends one terminal's screen as styled text while
//!   its Agent isn't working, for the app to find dialogs in (ADR 0005).
//!
//! Unpairing a device (by itself or with `yochi revoke`) closes its connections.
//!
//! The same endpoints are reachable through the Relay (`relay.rs`): there the
//! Noise handshake names the device, carried as a `RelayDevice` extension.

use crate::about::{self, About};
use crate::agent;
use crate::changes;
use crate::commands;
use crate::conversation::{Item, Pending};
use crate::core::Client;
use crate::devices::{Device, Store};
use crate::following::{Follower, Update};
use crate::herdr::CoreView;
use crate::layout::Space;
use crate::relay::{self, RelayDevice};
use crate::observe::{self, Observer, Output};
use crate::run;
use crate::screen::Screen;
use crate::session::Session;
use anyhow::{Context as _, Result};
use axum::{Extension, Router};
use axum::extract::{Query, State};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};
use tokio::sync::watch;

pub const API_VERSION: u32 = 0;

#[derive(Clone)]
struct AppState {
    hc: Arc<str>,
    view: watch::Receiver<CoreView>,
    store: Arc<Store>,
    /// Paired devices, reloaded when the CLI changes the state file.
    devices: Arc<watch::Sender<Vec<Device>>>,
    /// The latest Changes each session was shown, so only those files open.
    changes: Arc<changes::Listed>,
    /// Repositories and to-dos the home page shows beside the sessions.
    about: watch::Receiver<About>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage<'a> {
    Hello { api: u32, gateway: &'static str },
    Sessions { core: Option<&'a str>, connected: bool, sessions: Vec<Session>, spaces: &'a [Space] },
    /// Observing began; render a grid of this size.
    Attached { cols: u16, rows: u16 },
    /// The terminal's grid changed (another client resized it).
    Size { cols: u16, rows: u16 },
    /// The stream ended; `reason` as the core gave it, or why attaching failed.
    Closed { reason: &'a Value },
    /// The screen as styled rows (CRLF between rows, SGR only); the cursor
    /// is `[row, column]`, null while hidden.
    Screen { cols: u16, rows: u16, text: &'a str, cursor: Option<(u16, u16)> },
    /// Pairing succeeded; the token is this device's from now on.
    Paired { device: &'a str, token: &'a str },
    /// Wrong or expired pairing code.
    Rejected,
    /// The whole conversation again; `supported: false` means terminal view only.
    Conversation { supported: bool, items: &'a [Item] },
    /// Conversation items added or changed, replacing any with the same id.
    Items { items: &'a [Item] },
    /// What the Agent is waiting for, or null once it isn't.
    Pending { pending: Option<&'a Pending> },
    /// Claude Code's permission mode as of its latest message.
    Mode { mode: &'a str },
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
    /// Press named keys in a session without taking it over.
    Keys {
        id: String,
        session: String,
        keys: Vec<String>,
    },
    /// Stop the Agent's current turn.
    Interrupt {
        id: String,
        session: String,
    },
    /// A file for the terminal's program, such as a photo; base64 data.
    Put {
        id: String,
        session: String,
        name: String,
        data: String,
    },
    /// The session's Changes: its repository against HEAD.
    Changes {
        id: String,
        session: String,
    },
    /// One file's diff, from the latest Changes this session was shown.
    ChangeDiff {
        id: String,
        session: String,
        path: String,
    },
    /// The session's custom slash commands and skills, for completion.
    Commands {
        id: String,
        session: String,
    },
    /// Answer what the Agent is waiting for, if it still is.
    Answer {
        id: String,
        session: String,
        choice: String,
        expect: Option<String>,
    },
    /// Start a new terminal: a program in a directory, here or on a machine.
    Run {
        id: String,
        #[serde(default)]
        machine: Option<String>,
        #[serde(default)]
        cwd: String,
        #[serde(default)]
        argv: Vec<String>,
        /// A space from the list; absent for a new one.
        #[serde(default)]
        space: Option<String>,
    },
    /// Forget this device (the app's own "unpair").
    Unpair,
    /// Let this device use the Relay with this Noise static key (base64url);
    /// answered with `relay` (ADR 0006).
    RelayEnroll { static_key: String },
}

/// Where the Gateway listens.
pub enum Listen {
    At(SocketAddr),
    /// This Mac's tailnet address, once Tailscale is up. Until then phones
    /// reach the Gateway only through the relay.
    Tailnet,
}

/// How often the Gateway looks for the tailnet while it isn't up.
const TAILNET_RETRY: Duration = Duration::from_secs(5);

pub async fn serve(listen: Listen, store: Store, hc: String, view: watch::Receiver<CoreView>) -> Result<()> {
    let devices = store.devices()?;
    if devices.is_empty() {
        eprintln!("No paired devices yet; pair a phone with `yochi pair`.");
    }
    let store = Arc::new(store);
    let devices = Arc::new(watch::Sender::new(devices));
    tokio::spawn(reload_devices(store.clone(), devices.clone()));
    let hc: Arc<str> = hc.into();
    let (about_sender, about) = watch::channel(About::default());
    tokio::spawn(about::run(hc.clone(), view.clone(), about_sender));
    let state = AppState { hc, view, store, devices, changes: Arc::default(), about };
    let app = Router::new()
        .route("/v0/pair", get(pair))
        .route("/v0/ws", get(upgrade))
        .route("/v0/observe", get(observe))
        .route("/v0/conversation", get(conversation))
        .route("/v0/screen", get(screen))
        .with_state(state.clone());
    let keys = state.store.gateway_key()?;
    let relay = relay::Relay { router: app.clone(), store: state.store.clone(), devices: state.devices.clone(), keys };
    tokio::spawn(relay::run(Arc::new(relay)));
    let listener = match listen {
        Listen::At(addr) => tokio::net::TcpListener::bind(addr).await.with_context(|| format!("listening on {addr}"))?,
        Listen::Tailnet => tokio::select! {
            listener = bind_when_ready(|| crate::listen_addr(None), TAILNET_RETRY) => listener?,
            _ = tokio::signal::ctrl_c() => return Ok(()),
        },
    };
    eprintln!("Gateway listening on ws://{}/v0/ws", listener.local_addr()?);
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

/// Picks up `yochi revoke` (and anything else that rewrites the state file).
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

async fn upgrade(
    State(state): State<AppState>,
    headers: HeaderMap,
    via_relay: Option<Extension<RelayDevice>>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(device) = authorize(&headers, via_relay, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    ws.on_upgrade(move |socket| push(socket, state, device))
}

#[derive(Deserialize)]
struct ObserveQuery {
    session: String,
    /// 1 takes the terminal over: it is resized to `cols` × `rows` while this
    /// viewer stays attached, so its program draws for the phone.
    takeover: Option<u8>,
    cols: Option<u16>,
    rows: Option<u16>,
}

/// What the app may send on a takeover stream.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ObserveMessage {
    /// The phone's grid changed, e.g. its keyboard came up.
    Resize { cols: u16, rows: u16 },
}

/// A grid core can draw: neither empty nor absurd.
fn valid_grid(cols: u16, rows: u16) -> bool {
    (1..=1000).contains(&cols) && (1..=1000).contains(&rows)
}

async fn observe(
    State(state): State<AppState>,
    headers: HeaderMap,
    via_relay: Option<Extension<RelayDevice>>,
    Query(query): Query<ObserveQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(device) = authorize(&headers, via_relay, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Some(observed) = session_size(&state.view.borrow(), &query.session) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let (size, takeover) = match query.takeover.unwrap_or(0) == 1 {
        true => match (query.cols, query.rows) {
            (Some(cols), Some(rows)) if valid_grid(cols, rows) => ((cols, rows), true),
            _ => return (StatusCode::BAD_REQUEST, "takeover needs cols and rows").into_response(),
        },
        false => (observed, false),
    };
    ws.on_upgrade(move |socket| relay(socket, state, device, query.session, size, takeover))
}

fn session_size(view: &CoreView, id: &str) -> Option<(u16, u16)> {
    view.sessions.iter().find(|s| s.id == id).map(|s| (s.cols, s.rows))
}

/// Streams one terminal. An observer only watches; a takeover viewer also
/// sets the terminal's size, and resizes it when the phone's grid changes.
async fn relay(
    mut socket: WebSocket,
    state: AppState,
    device: String,
    id: String,
    (cols, rows): (u16, u16),
    takeover: bool,
) {
    let mut observer = match Observer::attach(&state.hc, &id, cols, rows, observe::HISTORY, !takeover).await {
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
                Some(Ok(Message::Text(text))) if takeover => {
                    if let Ok(ObserveMessage::Resize { cols, rows }) = serde_json::from_str(&text)
                        && valid_grid(cols, rows)
                        && observer.resize(cols, rows).await.is_err()
                    {
                        break;
                    }
                }
                Some(Ok(_)) => {}
            },
            () = unpaired(&mut devices, &device) => break,
        }
    }
    observer.detach().await;
}

async fn screen(
    State(state): State<AppState>,
    headers: HeaderMap,
    via_relay: Option<Extension<RelayDevice>>,
    Query(query): Query<ObserveQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(device) = authorize(&headers, via_relay, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Some(size) = session_size(&state.view.borrow(), &query.session) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    ws.on_upgrade(move |socket| watch_screen(socket, state, device, query.session, size))
}

/// Whether the Agent in the terminal is working; its screen then only shows
/// progress, so it isn't sent.
fn working(view: &CoreView, id: &str) -> bool {
    view.sessions.iter().find(|s| s.id == id).and_then(|s| s.status.as_ref()).is_some_and(|s| s.state == "working")
}

/// Keeps the terminal's screen from a read-only attach and sends it once it
/// has been still for a moment, unless it is what was sent last.
async fn watch_screen(mut socket: WebSocket, state: AppState, device: String, id: String, (cols, rows): (u16, u16)) {
    const SETTLE: Duration = Duration::from_millis(150);
    let mut observer = match Observer::attach(&state.hc, &id, cols, rows, 0, true).await {
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
    let mut screen = Screen::new(size.0, size.1);
    let mut view = state.view.clone();
    view.mark_unchanged();
    let mut busy = working(&view.borrow(), &id);
    let mut devices = state.devices.subscribe();
    let mut sent = String::new();
    // When the screen last changed; None once it has been sent or found unchanged.
    let mut changed_at: Option<Instant> = Some(Instant::now());
    loop {
        let settle = async {
            match changed_at {
                Some(at) if !busy => tokio::time::sleep_until((at + SETTLE).into()).await,
                _ => std::future::pending().await,
            }
        };
        tokio::select! {
            output = observer.next() => match output {
                Some(Output::Data(bytes)) => {
                    screen.process(&bytes);
                    changed_at = Some(Instant::now());
                    if observer.consumed(bytes.len()).await.is_err() { break }
                }
                Some(Output::Closed(reason)) => {
                    let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
                    return;
                }
                None => return,
            },
            () = settle => {
                changed_at = None;
                let text = screen.render();
                if text != sent {
                    let message = ServerMessage::Screen { cols: size.0, rows: size.1, text: &text, cursor: screen.cursor() };
                    if send(&mut socket, &message).await.is_err() { break }
                    sent = text;
                }
            },
            changed = view.changed() => {
                if changed.is_err() { break }
                let view = view.borrow_and_update();
                if let Some(current) = session_size(&view, &id) && current != size {
                    size = current;
                    screen.resize(size.0, size.1);
                    changed_at = Some(Instant::now());
                }
                let now = working(&view, &id);
                if busy && !now {
                    changed_at = Some(Instant::now());
                }
                busy = now;
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

async fn conversation(
    State(state): State<AppState>,
    headers: HeaderMap,
    via_relay: Option<Extension<RelayDevice>>,
    Query(query): Query<ObserveQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(device) = authorize(&headers, via_relay, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    if session_size(&state.view.borrow(), &query.session).is_none() {
        return StatusCode::NOT_FOUND.into_response();
    }
    ws.on_upgrade(move |socket| follow(socket, state, device, query.session))
}

/// What a tick depends on; a change in it means look again now.
fn watched(view: &CoreView, id: &str) -> Option<(Option<u64>, u64, Option<crate::session::Status>)> {
    view.sessions.iter().find(|s| s.id == id).map(|s| (s.pid, s.turn, s.status.clone()))
}

/// Polls the transcript while a phone follows the conversation: every second
/// while the Agent works or waits and for a few seconds after any change
/// (Claude Code may finish before its last line is written), else every few.
async fn follow(mut socket: WebSocket, state: AppState, device: String, id: String) {
    let mut client = match Client::connect(&state.hc).await {
        Ok(client) => client,
        Err(err) => {
            let reason = Value::String(format!("{err:#}"));
            let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
            return;
        }
    };
    let mut follower = Follower::default();
    let mut view = state.view.clone();
    let mut devices = state.devices.subscribe();
    let mut seen = None;
    let mut busy_until = Instant::now();
    loop {
        let Some(session) = view.borrow_and_update().sessions.iter().find(|s| s.id == id).cloned() else {
            let reason = Value::String("finished".into());
            let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
            return;
        };
        let updates = match follower.tick(&mut client, &session).await {
            Ok(updates) => updates,
            Err(err) => {
                let reason = Value::String(format!("{err:#}"));
                let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
                return;
            }
        };
        for update in &updates {
            let message = match update {
                Update::Conversation { supported, items } => ServerMessage::Conversation { supported: *supported, items },
                Update::Items(items) => ServerMessage::Items { items },
                Update::Pending(pending) => ServerMessage::Pending { pending: pending.as_ref() },
                Update::Mode(mode) => ServerMessage::Mode { mode },
            };
            if send(&mut socket, &message).await.is_err() {
                return;
            }
        }
        let current = watched(&view.borrow(), &id);
        if current != seen {
            seen = current;
            busy_until = Instant::now() + Duration::from_secs(5);
        }
        let active = session.status.as_ref().is_some_and(|status| matches!(status.state.as_str(), "working" | "blocked"));
        let wait = if active || Instant::now() < busy_until { Duration::from_secs(1) } else { Duration::from_secs(4) };
        let sleep = tokio::time::sleep(wait);
        tokio::pin!(sleep);
        loop {
            tokio::select! {
                () = &mut sleep => break,
                changed = view.changed() => {
                    if changed.is_err() { return }
                    if watched(&view.borrow(), &id) != seen { break }
                },
                incoming = socket.recv() => match incoming {
                    Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return,
                    Some(Ok(_)) => {}
                },
                () = unpaired(&mut devices, &device) => return,
            }
        }
    }
}

/// The paired device whose token the request carries, or that a Relay
/// stream's handshake proved (only Relay streams carry that extension).
fn authorize(headers: &HeaderMap, via_relay: Option<Extension<RelayDevice>>, devices: &[Device]) -> Option<String> {
    if let Some(Extension(RelayDevice(id))) = via_relay {
        return devices.iter().any(|device| device.id == id).then_some(id);
    }
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
    let mut about = state.about.clone();
    let mut devices = state.devices.subscribe();
    let (outgoing, mut responses) = tokio::sync::mpsc::unbounded_channel::<String>();
    let hello = ServerMessage::Hello { api: API_VERSION, gateway: env!("CARGO_PKG_VERSION") };
    if send(&mut socket, &hello).await.is_err() {
        return;
    }
    // The list goes out at the start and after each change, not again after
    // every reply, ping or request: the App redraws its pages on each list.
    let mut changed_since_sent = true;
    loop {
        if std::mem::take(&mut changed_since_sent) {
            let message = {
                let current = view.borrow_and_update();
                serde_json::to_string(&ServerMessage::Sessions {
                    core: current.core.as_deref(),
                    connected: current.connected(),
                    sessions: about.borrow_and_update().fill(&current.sessions),
                    spaces: &current.spaces,
                })
            };
            let Ok(message) = message else { return };
            if socket.send(Message::Text(message.into())).await.is_err() {
                return;
            }
        }
        tokio::select! {
            changed = view.changed() => {
                if changed.is_err() { return }
                changed_since_sent = true;
            },
            changed = about.changed() => {
                if changed.is_err() { return }
                changed_since_sent = true;
            },
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
                    Ok(AppMessage::Answer { id, session, choice, expect }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = agent::AnswerRequest { id, session, choice, expect };
                            let response = agent::answer(&state.hc, &state.view, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::Interrupt { id, session }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = agent::InterruptRequest { id, session };
                            let response = agent::interrupt(&state.hc, &state.view, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::Put { id, session, name, data }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = agent::PutRequest { id, session, name, data };
                            let response = agent::put(&state.hc, &state.view, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::Changes { id, session }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = changes::Request { id, session };
                            let response = changes::list(&state.hc, &state.view, &state.changes, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::ChangeDiff { id, session, path }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = changes::DiffRequest { id, session, path };
                            let response = changes::diff(&state.hc, &state.changes, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::Commands { id, session }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = commands::Request { id, session };
                            let response = commands::list(&state.hc, &state.view, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::Run { id, machine, cwd, argv, space }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = run::RunRequest { id, machine, cwd, argv, space };
                            let response = run::run(&state.hc, request).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    Ok(AppMessage::RelayEnroll { static_key }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        let device = device.clone();
                        tokio::spawn(async move {
                            let store = state.store.clone();
                            let reply = tokio::task::spawn_blocking(move || {
                                let reply = relay::enrollment(&store, &device, &static_key);
                                (reply, store.devices())
                            })
                            .await;
                            let Ok((reply, devices)) = reply else { return };
                            if let Ok(devices) = devices {
                                state.devices.send_if_modified(|current| std::mem::replace(current, devices) != *current);
                            }
                            let reply = reply.unwrap_or_else(|err| serde_json::json!({ "type": "relay", "available": false, "error": format!("{err:#}") }));
                            let _ = outgoing.send(reply.to_string());
                        });
                    }
                    Ok(AppMessage::Keys { id, session, keys }) => {
                        let state = state.clone();
                        let outgoing = outgoing.clone();
                        tokio::spawn(async move {
                            let request = agent::KeysRequest { id, session, keys };
                            let response = agent::press(&state.hc, &state.view, request).await;
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

/// Binds where `resolve` says once that address exists on this Mac, trying
/// again every `every` until then. Any other failure, such as the port being
/// taken, is an error.
async fn bind_when_ready<F, Fut>(mut resolve: F, every: Duration) -> Result<tokio::net::TcpListener>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<SocketAddr>>,
{
    let mut waiting = false;
    loop {
        let unavailable = match resolve().await {
            Ok(addr) => match tokio::net::TcpListener::bind(addr).await {
                Ok(listener) => {
                    if waiting {
                        eprintln!("On the tailnet now.");
                    }
                    return Ok(listener);
                }
                Err(err) if err.kind() == std::io::ErrorKind::AddrNotAvailable => {
                    anyhow::Error::new(err).context(format!("listening on {addr}"))
                }
                Err(err) => return Err(err).with_context(|| format!("listening on {addr}")),
            },
            Err(err) => err,
        };
        if !waiting {
            eprintln!(
                "Not on the tailnet ({unavailable:#}); until it is, phones reach this Gateway only through a relay. \
                 Trying again every {} s.",
                every.as_secs()
            );
            waiting = true;
        }
        tokio::time::sleep(every).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_gateway_listens_once_the_tailnet_address_exists() {
        // 192.0.2.1 (TEST-NET-1) isn't on this machine, like the tailnet
        // address while Tailscale is down.
        let mut tries = 0;
        let listener = bind_when_ready(
            || {
                tries += 1;
                let ip = if tries < 3 { "192.0.2.1" } else { "127.0.0.1" };
                std::future::ready(Ok(SocketAddr::new(ip.parse().unwrap(), 0)))
            },
            Duration::from_millis(10),
        )
        .await
        .unwrap();
        assert_eq!(tries, 3);
        assert!(listener.local_addr().unwrap().ip().is_loopback());

        let mut tries = 0;
        bind_when_ready(
            || {
                tries += 1;
                std::future::ready(if tries < 2 { Err(anyhow::anyhow!("Tailscale is stopped")) } else { Ok("127.0.0.1:0".parse().unwrap()) })
            },
            Duration::from_millis(10),
        )
        .await
        .unwrap();
        assert_eq!(tries, 2);
    }

    #[tokio::test]
    async fn a_taken_port_is_an_error_not_a_wait() {
        let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = taken.local_addr().unwrap();
        let bound = tokio::time::timeout(
            Duration::from_secs(1),
            bind_when_ready(|| std::future::ready(Ok(addr)), Duration::from_millis(10)),
        )
        .await
        .expect("gave up waiting");
        assert!(bound.is_err());
    }

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
        let message: AppMessage =
            serde_json::from_str(r#"{"type":"keys","id":"k1","session":"t1","keys":["down","enter"]}"#).unwrap();
        assert!(matches!(message, AppMessage::Keys { keys, .. } if keys == ["down", "enter"]));
        let message: AppMessage = serde_json::from_str(
            r#"{"type":"answer","id":"a1","session":"t1","choice":"allow","expect":"approve Bash: ls"}"#,
        )
        .unwrap();
        assert!(matches!(message, AppMessage::Answer { choice, expect: Some(expect), .. }
            if choice == "allow" && expect == "approve Bash: ls"));
        let message: AppMessage = serde_json::from_str(r#"{"type":"interrupt","id":"i1","session":"t1"}"#).unwrap();
        assert!(matches!(message, AppMessage::Interrupt { id, session } if id == "i1" && session == "t1"));
        let message: AppMessage =
            serde_json::from_str(r#"{"type":"put","id":"p1","session":"t1","name":"a.jpg","data":"AAAA"}"#).unwrap();
        assert!(matches!(message, AppMessage::Put { name, data, .. } if name == "a.jpg" && data == "AAAA"));
        let message: AppMessage = serde_json::from_str(r#"{"type":"commands","id":"c1","session":"t1"}"#).unwrap();
        assert!(matches!(message, AppMessage::Commands { id, session } if id == "c1" && session == "t1"));
        let message: AppMessage = serde_json::from_str(r#"{"type":"change_diff","id":"g2","session":"t1","path":"a b.txt"}"#).unwrap();
        assert!(matches!(message, AppMessage::ChangeDiff { path, .. } if path == "a b.txt"));
    }

    #[test]
    fn parses_resize_and_checks_the_grid() {
        let message: ObserveMessage = serde_json::from_str(r#"{"type":"resize","cols":49,"rows":45}"#).unwrap();
        assert!(matches!(message, ObserveMessage::Resize { cols: 49, rows: 45 }));
        assert!(serde_json::from_str::<ObserveMessage>(r#"{"type":"resize","cols":-1,"rows":45}"#).is_err());
        assert!(valid_grid(1, 1) && valid_grid(1000, 1000));
        assert!(!valid_grid(0, 45) && !valid_grid(49, 0) && !valid_grid(1001, 45));
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
        assert_eq!(authorize(&headers, None, &devices), None);
        headers.insert(header::AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        assert_eq!(authorize(&headers, None, &devices), Some(device.id));
        headers.insert(header::AUTHORIZATION, "Bearer wrong".parse().unwrap());
        assert_eq!(authorize(&headers, None, &devices), None);
    }
}
