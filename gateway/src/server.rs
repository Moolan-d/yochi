//! Companion API v0, all WebSocket (iOS blocks plain HTTP to tailnet IPs, not
//! `ws://`). `/v0/pair` trades a pairing code for a device token; the others
//! need `Authorization: Bearer <device token>`:
//! - `/v0/ws` pushes `hello`, then the whole session list whenever it changes.
//!   The app may send Agent Messages, key presses, or `unpair` to remove itself.
//! - `/v0/observe?session=<id>` streams one terminal: control as text,
//!   terminal bytes as binary messages. With `takeover=1&cols=&rows=` the
//!   terminal takes the phone's size while it is watched, and the app's
//!   scrolling reaches a full-screen program as the mouse wheel.
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
use crate::lang::Lang;
use crate::layout::Space;
use crate::relay::{self, RelayDevice};
use crate::tailnet;
use crate::observe::{self, Observer, Output};
use crate::run;
use crate::screen::Screen;
use crate::session::Session;
use anyhow::Result;
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
    /// Whether phones can reach the Gateway on the tailnet, and where.
    tailnet: watch::Receiver<tailnet::State>,
}

/// Who opened a connection, and which way.
#[derive(Clone, Debug, PartialEq)]
struct Caller {
    device: String,
    /// On the tailnet rather than through the Relay.
    tailnet: bool,
}

impl AppState {
    /// What has to hold for `caller`'s connection to go on.
    fn access(&self, caller: &Caller) -> Access {
        Access {
            devices: self.devices.subscribe(),
            tailnet: caller.tailnet.then(|| self.tailnet.clone()),
            device: caller.device.clone(),
        }
    }
}

/// A connection goes on while its device is paired and, on the tailnet,
/// while the tailnet stays on.
struct Access {
    devices: watch::Receiver<Vec<Device>>,
    tailnet: Option<watch::Receiver<tailnet::State>>,
    device: String,
}

impl Access {
    /// Resolves once the connection has to close.
    async fn lost(&mut self) {
        let off = async {
            let closed = match &mut self.tailnet {
                Some(tailnet) => tailnet.wait_for(|state| *state == tailnet::State::Off).await.is_err(),
                None => true,
            };
            if closed {
                std::future::pending::<()>().await;
            }
        };
        tokio::select! {
            () = unpaired(&mut self.devices, &self.device) => {}
            () = off => {}
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage<'a> {
    Hello { api: u32, gateway: &'static str },
    /// Where the phone reaches this Gateway on the tailnet; null once the
    /// tailnet is off. Sent after `hello` and on each change, so a phone that
    /// paired through the Relay learns the tailnet too.
    Tailnet { host: Option<SocketAddr> },
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
    /// This Mac's tailnet address, whenever there is one.
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
    let (tailnet_state, tailnet) = watch::channel(tailnet::State::Waiting);
    let state = AppState { hc, view, store, devices, changes: Arc::default(), about, tailnet };
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
    let fixed = match listen {
        Listen::At(addr) => Some(addr),
        Listen::Tailnet => None,
    };
    let resolve = move || async move {
        match fixed {
            Some(addr) => Ok(addr),
            None => crate::listen_addr(None).await,
        }
    };
    let dir = state.store.dir().to_path_buf();
    tokio::select! {
        ran = tailnet::run(dir, resolve, app, tailnet_state, TAILNET_RETRY) => ran,
        _ = tokio::signal::ctrl_c() => Ok(()),
    }
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
    Query(query): Query<LangQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let Some(device) = authorize(&headers, via_relay, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let lang = Lang::from_tag(query.lang.as_deref());
    ws.on_upgrade(move |socket| push(socket, state, device, lang))
}

/// The language the phone shows, on any endpoint: `lang=en`, `lang=zh-Hans`.
#[derive(Deserialize)]
struct LangQuery {
    lang: Option<String>,
}

#[derive(Deserialize)]
struct ObserveQuery {
    session: String,
    /// 1 takes the terminal over: it is resized to `cols` × `rows` while this
    /// viewer stays attached, so its program draws for the phone.
    takeover: Option<u8>,
    cols: Option<u16>,
    rows: Option<u16>,
    /// The language the phone shows; see `LangQuery`.
    lang: Option<String>,
}

/// What the app may send on a takeover stream.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ObserveMessage {
    /// The phone's grid changed, e.g. its keyboard came up.
    Resize { cols: u16, rows: u16 },
    /// A drag on a full-screen program, as the wheel reports the phone's
    /// terminal made for it; anything but wheel reports is dropped.
    Wheel { data: String },
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
    caller: Caller,
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
    let mut access = state.access(&caller);
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
                    let sent = match serde_json::from_str(&text) {
                        Ok(ObserveMessage::Resize { cols, rows }) if valid_grid(cols, rows) => {
                            observer.resize(cols, rows).await
                        }
                        Ok(ObserveMessage::Wheel { data }) if observe::wheel_only(data.as_bytes()) => {
                            observer.wheel(data.as_bytes()).await
                        }
                        _ => Ok(()),
                    };
                    if sent.is_err() { break }
                }
                Some(Ok(_)) => {}
            },
            () = access.lost() => break,
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
async fn watch_screen(mut socket: WebSocket, state: AppState, caller: Caller, id: String, (cols, rows): (u16, u16)) {
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
    let mut access = state.access(&caller);
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
            () = access.lost() => break,
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
    let lang = Lang::from_tag(query.lang.as_deref());
    ws.on_upgrade(move |socket| follow(socket, state, device, query.session, lang))
}

/// What a tick depends on; a change in it means look again now.
fn watched(view: &CoreView, id: &str) -> Option<(Option<u64>, u64, Option<crate::session::Status>)> {
    view.sessions.iter().find(|s| s.id == id).map(|s| (s.pid, s.turn, s.status.clone()))
}

/// Polls the transcript while a phone follows the conversation: every second
/// while the Agent works or waits and for a few seconds after any change
/// (Claude Code may finish before its last line is written), else every few.
async fn follow(mut socket: WebSocket, state: AppState, caller: Caller, id: String, lang: Lang) {
    let mut client = match Client::connect(&state.hc).await {
        Ok(client) => client,
        Err(err) => {
            let reason = Value::String(format!("{err:#}"));
            let _ = send(&mut socket, &ServerMessage::Closed { reason: &reason }).await;
            return;
        }
    };
    let mut follower = Follower::new(lang);
    let mut view = state.view.clone();
    let mut access = state.access(&caller);
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
                () = access.lost() => return,
            }
        }
    }
}

/// The paired device whose token the request carries, or that a Relay
/// stream's handshake proved (only Relay streams carry that extension).
fn authorize(headers: &HeaderMap, via_relay: Option<Extension<RelayDevice>>, devices: &[Device]) -> Option<Caller> {
    if let Some(Extension(RelayDevice(id))) = via_relay {
        return devices.iter().any(|device| device.id == id).then_some(Caller { device: id, tailnet: false });
    }
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))?;
    devices.iter().find(|device| device.holds(token)).map(|device| Caller { device: device.id.clone(), tailnet: true })
}

/// Resolves once `device` is no longer paired.
async fn unpaired(devices: &mut watch::Receiver<Vec<Device>>, device: &str) {
    if devices.wait_for(|devices| !devices.iter().any(|d| d.id == device)).await.is_err() {
        std::future::pending::<()>().await;
    }
}

async fn push(mut socket: WebSocket, state: AppState, caller: Caller, lang: Lang) {
    let device = caller.device.clone();
    let mut tailnet = state.tailnet.clone();
    let mut view = state.view.clone();
    let mut about = state.about.clone();
    let mut access = state.access(&caller);
    let (outgoing, mut responses) = tokio::sync::mpsc::unbounded_channel::<String>();
    let hello = ServerMessage::Hello { api: API_VERSION, gateway: env!("CARGO_PKG_VERSION") };
    if send(&mut socket, &hello).await.is_err() {
        return;
    }
    // While the Gateway waits for its tailnet address the phone keeps the one it knows.
    let tailnet_message = |state: tailnet::State| match state {
        tailnet::State::Off => Some(ServerMessage::Tailnet { host: None }),
        tailnet::State::At(addr) => Some(ServerMessage::Tailnet { host: Some(addr) }),
        tailnet::State::Waiting => None,
    };
    let current = *tailnet.borrow_and_update();
    if let Some(message) = tailnet_message(current)
        && send(&mut socket, &message).await.is_err()
    {
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
            changed = tailnet.changed() => {
                if changed.is_err() { return }
                let current = *tailnet.borrow_and_update();
                if let Some(message) = tailnet_message(current)
                    && send(&mut socket, &message).await.is_err()
                {
                    return;
                }
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
                            let response = agent::send(&state.hc, &state.view, request, lang).await;
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
                            let response = agent::answer(&state.hc, &state.view, request, lang).await;
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
                            let response = agent::interrupt(&state.hc, &state.view, request, lang).await;
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
                            let response = agent::put(&state.hc, &state.view, request, lang).await;
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
                            let response = changes::list(&state.hc, &state.view, &state.changes, request, lang).await;
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
                            let response = changes::diff(&state.hc, &state.changes, request, lang).await;
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
                            let response = commands::list(&state.hc, &state.view, request, lang).await;
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
                            let response = run::run(&state.hc, request, lang).await;
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
                            let response = agent::press(&state.hc, &state.view, request, lang).await;
                            if let Ok(response) = serde_json::to_string(&response) {
                                let _ = outgoing.send(response);
                            }
                        });
                    }
                    _ => {}
                },
                Some(Ok(_)) => {}
            },
            () = access.lost() => return,
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

    #[tokio::test]
    async fn turning_the_tailnet_off_closes_only_tailnet_connections() {
        let device: Device = serde_json::from_value(serde_json::json!({ "id": "d", "name": "iPhone", "paired_at": 0, "token_sha256": "" })).unwrap();
        let (_devices_sender, devices) = watch::channel(vec![device]);
        let (tailnet_sender, tailnet) = watch::channel(tailnet::State::At("127.0.0.1:7420".parse().unwrap()));
        let paired = |tailnet: Option<watch::Receiver<tailnet::State>>| Access { devices: devices.clone(), tailnet, device: "d".into() };
        let mut on_tailnet = paired(Some(tailnet.clone()));
        let mut through_relay = paired(None);
        let quick = Duration::from_millis(100);
        assert!(tokio::time::timeout(quick, on_tailnet.lost()).await.is_err(), "closed while the tailnet is on");
        tailnet_sender.send_replace(tailnet::State::Waiting);
        assert!(tokio::time::timeout(quick, on_tailnet.lost()).await.is_err(), "closed while waiting for the address");
        tailnet_sender.send_replace(tailnet::State::Off);
        assert!(tokio::time::timeout(quick, on_tailnet.lost()).await.is_ok(), "still open with the tailnet off");
        assert!(tokio::time::timeout(quick, through_relay.lost()).await.is_err(), "a Relay connection closed too");
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
        let message: ObserveMessage = serde_json::from_str(r#"{"type":"wheel","data":"\u001b[<64;3;4M"}"#).unwrap();
        assert!(matches!(message, ObserveMessage::Wheel { data } if data == "\x1b[<64;3;4M"));
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
        assert_eq!(authorize(&headers, None, &devices).map(|caller| caller.device), Some(device.id));
        headers.insert(header::AUTHORIZATION, "Bearer wrong".parse().unwrap());
        assert_eq!(authorize(&headers, None, &devices), None);
    }
}
