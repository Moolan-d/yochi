//! Companion API v0, all WebSocket (iOS blocks plain HTTP to tailnet IPs, not
//! `ws://`). `/v0/pair` trades a pairing code for a device token; the others
//! need `Authorization: Bearer <device token>`:
//! - `/v0/ws` pushes `hello`, then the whole session list whenever it changes.
//!   The app may send Agent Messages, key presses, or `unpair` to remove itself.
//! - `/v0/observe?session=<id>` streams one terminal: control as text,
//!   terminal bytes as binary messages. With `takeover=1&cols=&rows=` the
//!   terminal takes the phone's size while it is watched, and the app's
//!   scrolling reaches a full-screen program as the mouse wheel. With
//!   `resumable=1` a dropped stream waits for the phone to come back with
//!   `resume=<token>&offset=<bytes>` (`resume.rs`); `detach` ends it at once.
//! - `/v0/conversation?session=<id>` follows the conversation of the Agent in
//!   one terminal, read from its transcript.
//! - `/v0/screen?session=<id>` sends one terminal's screen as styled text while
//!   its Agent isn't working, for the app to find dialogs in (ADR 0005).
//!
//! - `/v0/mux` carries streams to any of the above but pairing on one
//!   WebSocket, so a page opens without a connection of its own (`mux.rs`).
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
use crate::mux;
use crate::notify;
use crate::relay::{self, RelayDevice};
use crate::resume::{self, Replay};
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
use tokio::sync::{mpsc, oneshot, watch};

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
    /// Terminal streams a phone can come back to, by resume token.
    streams: resume::Registry<Claim>,
    /// Phones with Yochi open, which notifications wait for.
    phones: Arc<notify::Phones>,
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
    /// Observing began; render a grid of this size. A resumable stream also
    /// gives the token to come back with and how long it waits for that.
    Attached {
        cols: u16,
        rows: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        resume: Option<&'a str>,
        #[serde(skip_serializing_if = "Option::is_none")]
        keep_ms: Option<u64>,
    },
    /// The stream goes on from the byte the app asked for; binary messages
    /// that follow continue it. `resume` replaces the token used.
    Resumed { resume: &'a str, keep_ms: u64 },
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
    let phones = Arc::new(notify::Phones::default());
    tokio::spawn(notify::run(hc.clone(), store.dir().to_path_buf(), view.clone(), phones.clone()));
    let state = AppState { hc, view, store, devices, changes: Arc::default(), about, tailnet, streams: Default::default(), phones };
    let app = with_mux(api(state.clone()), state.clone());
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

/// Every endpoint but the mux: what a mux's streams may open.
fn api(state: AppState) -> Router {
    Router::new()
        .route("/v0/pair", get(pair))
        .route("/v0/ws", get(upgrade))
        .route("/v0/observe", get(observe))
        .route("/v0/conversation", get(conversation))
        .route("/v0/screen", get(screen))
        .with_state(state)
}

/// `api` and `/v0/mux` (ADR 0007), whose streams it serves.
fn with_mux(api: Router, state: AppState) -> Router {
    let streams = api.clone();
    api.route(
        "/v0/mux",
        get(move |headers: HeaderMap, via_relay: Option<Extension<RelayDevice>>, ws: WebSocketUpgrade| {
            multiplex(state.clone(), streams.clone(), headers, via_relay, ws)
        }),
    )
}

async fn multiplex(
    state: AppState,
    api: Router,
    headers: HeaderMap,
    via_relay: Option<Extension<RelayDevice>>,
    ws: WebSocketUpgrade,
) -> Response {
    let relayed = via_relay.as_ref().map(|Extension(RelayDevice(device))| device.clone());
    let Some(caller) = authorize(&headers, via_relay, &state.devices.borrow()) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let pass = match (relayed, headers.get(header::AUTHORIZATION)) {
        (Some(device), _) => mux::Pass::Relay(device),
        (None, Some(token)) => mux::Pass::Bearer(token.clone()),
        (None, None) => return StatusCode::UNAUTHORIZED.into_response(),
    };
    let mut access = state.access(&caller);
    ws.on_upgrade(move |socket| async move { mux::serve(socket, api, pass, access.lost()).await })
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
    /// 1: the app can come back to this stream after its connection drops,
    /// so the stream waits for it (`resume::KEEP`) instead of ending.
    resumable: Option<u8>,
    /// Come back to a stream: its latest token, and how many of its bytes
    /// the app has. Answered `410` when the stream can't go on from there.
    resume: Option<String>,
    offset: Option<u64>,
    /// The language the phone shows; see `LangQuery`.
    lang: Option<String>,
}

/// What the app may send on a stream. Only a takeover resizes or scrolls.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ObserveMessage {
    /// The phone's grid changed, e.g. its keyboard came up.
    Resize { cols: u16, rows: u16 },
    /// A drag on a full-screen program, as the wheel reports the phone's
    /// terminal made for it; anything but wheel reports is dropped.
    Wheel { data: String },
    /// The app is leaving the stream: end it now rather than wait for the
    /// app to come back, so a takeover gives the desktop its size at once.
    Detach,
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
    if let Some(token) = &query.resume {
        let offset = query.offset.unwrap_or(0);
        return match come_back(&state, &device, token, &query.session, offset).await {
            Some(handover) => ws.on_upgrade(move |socket| async move {
                let _ = handover.send((socket, device));
            }),
            None => StatusCode::GONE.into_response(),
        };
    }
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
    let resumable = query.resumable.unwrap_or(0) == 1;
    ws.on_upgrade(move |socket| relay(socket, state, device, query.session, size, takeover, resumable))
}

fn session_size(view: &CoreView, id: &str) -> Option<(u16, u16)> {
    view.sessions.iter().find(|s| s.id == id).map(|s| (s.cols, s.rows))
}

/// A phone coming back to a stream with `offset` of its bytes. The stream
/// answers with where to hand the new connection over, or None to refuse.
struct Claim {
    offset: u64,
    reply: oneshot::Sender<Option<Handover>>,
}

type Handover = oneshot::Sender<(WebSocket, Caller)>;

/// Asks the stream `token` names whether it can go on from `offset`.
async fn come_back(state: &AppState, caller: &Caller, token: &str, session: &str, offset: u64) -> Option<Handover> {
    let claims = state.streams.find(token, &caller.device, session)?;
    let (reply, answer) = oneshot::channel();
    claims.send(Claim { offset, reply }).await.ok()?;
    answer.await.ok()?
}

/// How often a stream pings its phone, and how long it goes without hearing
/// from it before it counts the phone as gone: no reset reaches us when a
/// phone walks out of the network, and the takeover would hold till TCP gave up.
const PING_EVERY: Duration = Duration::from_secs(15);
const SILENT_FOR: Duration = Duration::from_secs(45);
/// How long a phone coming back has to finish opening its connection.
const HANDOVER_WITHIN: Duration = Duration::from_secs(10);

/// Why a connection stopped carrying its stream.
enum Ended {
    /// The stream is over: core ended it, the app left, or access was lost.
    Done,
    /// The phone dropped off; a resumable stream waits for it.
    Dropped,
    /// The phone came back on another connection, wanting bytes from `u64` on.
    Replaced(Box<WebSocket>, Caller, u64),
}

/// How a stream answered a phone coming back.
enum Accepted {
    Yes(Box<WebSocket>, Caller, u64),
    /// It lacks bytes the phone needs, or gave up waiting; the phone attaches afresh.
    Refused,
    /// The phone's new connection never arrived.
    Lost,
}

/// One terminal stream, which can outlive the connection that opened it.
struct Stream {
    observer: Observer,
    replay: Replay,
    /// Bytes taken from core but not credited back, because they haven't
    /// reached a phone; credited once they do.
    owed: usize,
    /// The grid the app was last told.
    size: (u16, u16),
    takeover: bool,
}

/// Streams one terminal. An observer only watches; a takeover viewer also
/// sets the terminal's size, and resizes it when the phone's grid changes.
/// A resumable stream that loses its phone stays attached to core (so a
/// takeover keeps its size) for `resume::KEEP`, holding the output for when
/// the phone comes back.
async fn relay(
    mut socket: WebSocket,
    state: AppState,
    mut caller: Caller,
    id: String,
    (cols, rows): (u16, u16),
    takeover: bool,
    resumable: bool,
) {
    let observer = match Observer::attach(&state.hc, &id, cols, rows, observe::HISTORY, !takeover).await {
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
    let size = (grid(&observer.terminal, "cols", cols), grid(&observer.terminal, "rows", rows));
    let mut stream = Stream { observer, replay: Replay::default(), owed: 0, size, takeover };
    let (claims_tx, mut claims) = mpsc::channel(4);
    let keep_ms = resume::KEEP.as_millis() as u64;
    let mut token = None;
    if resumable {
        match state.streams.register(None, &caller.device, &id, claims_tx.clone()) {
            Ok(issued) => token = Some(issued),
            Err(err) => eprintln!("observe: no resume token: {err:#}"),
        }
    }

    let attached = ServerMessage::Attached {
        cols: size.0,
        rows: size.1,
        resume: token.as_deref(),
        keep_ms: token.as_ref().map(|_| keep_ms),
    };
    let mut ended = match send(&mut socket, &attached).await {
        Ok(()) => stream.live(&mut socket, &state, &caller, &id, &mut claims).await,
        Err(_) => Ended::Dropped,
    };
    drop(socket);
    loop {
        let (mut socket, offset) = match ended {
            Ended::Done => break,
            Ended::Dropped if token.is_none() => break,
            Ended::Dropped => match stream.wait(&mut claims, &mut state.access(&caller)).await {
                Accepted::Yes(socket, by, offset) => {
                    caller = by;
                    (*socket, offset)
                }
                Accepted::Refused | Accepted::Lost => break,
            },
            Ended::Replaced(socket, by, offset) => {
                caller = by;
                (*socket, offset)
            }
        };
        // A new token for each connection, so a token that resumed once can't again.
        match state.streams.register(token.as_deref(), &caller.device, &id, claims_tx.clone()) {
            Ok(issued) => token = Some(issued),
            Err(_) => break,
        }
        let resumed = ServerMessage::Resumed { resume: token.as_deref().unwrap_or_default(), keep_ms };
        ended = match stream.go_on(&mut socket, &state, &id, &resumed, offset).await {
            Ok(true) => stream.live(&mut socket, &state, &caller, &id, &mut claims).await,
            Ok(false) => Ended::Done,
            Err(_) => Ended::Dropped,
        };
    }
    if let Some(token) = token {
        state.streams.remove(&token);
    }
    stream.observer.detach().await;
}

impl Stream {
    /// Carries the stream over `socket` until that connection ends.
    async fn live(
        &mut self,
        socket: &mut WebSocket,
        state: &AppState,
        caller: &Caller,
        id: &str,
        claims: &mut mpsc::Receiver<Claim>,
    ) -> Ended {
        let mut view = state.view.clone();
        view.mark_unchanged();
        let mut access = state.access(caller);
        let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_EVERY, PING_EVERY);
        let mut heard = Instant::now();
        loop {
            tokio::select! {
                output = self.observer.next() => match output {
                    Some(Output::Data(bytes)) => {
                        let len = bytes.len();
                        self.replay.push(&bytes);
                        if socket.send(Message::Binary(bytes.into())).await.is_err() {
                            self.owed += len;
                            return Ended::Dropped;
                        }
                        // Credit only what reached the app, so a slow phone gets a fresh repaint
                        // from the core instead of an ever-growing backlog here.
                        if self.observer.consumed(len).await.is_err() { return Ended::Done }
                    }
                    Some(Output::Closed(reason)) => {
                        let _ = send(socket, &ServerMessage::Closed { reason: &reason }).await;
                        return Ended::Done;
                    }
                    None => return Ended::Done,
                },
                changed = view.changed() => {
                    if changed.is_err() { return Ended::Done }
                    let current = session_size(&view.borrow_and_update(), id);
                    if let Some(current) = current && current != self.size {
                        self.size = current;
                        if send(socket, &ServerMessage::Size { cols: current.0, rows: current.1 }).await.is_err() {
                            return Ended::Dropped;
                        }
                    }
                },
                incoming = socket.recv() => {
                    heard = Instant::now();
                    match incoming {
                        Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return Ended::Dropped,
                        Some(Ok(Message::Text(text))) => {
                            let sent = match serde_json::from_str(&text) {
                                Ok(ObserveMessage::Detach) => return Ended::Done,
                                Ok(ObserveMessage::Resize { cols, rows }) if self.takeover && valid_grid(cols, rows) => {
                                    self.observer.resize(cols, rows).await
                                }
                                Ok(ObserveMessage::Wheel { data }) if self.takeover && observe::wheel_only(data.as_bytes()) => {
                                    self.observer.wheel(data.as_bytes()).await
                                }
                                _ => Ok(()),
                            };
                            if sent.is_err() { return Ended::Done }
                        }
                        Some(Ok(_)) => {}
                    }
                },
                Some(claim) = claims.recv() => match self.accept(claim).await {
                    // The phone came back another way (say, the Relay after the
                    // tailnet went), before this connection was found dead.
                    Accepted::Yes(socket, by, offset) => return Ended::Replaced(socket, by, offset),
                    Accepted::Refused | Accepted::Lost => {}
                },
                _ = ping.tick() => {
                    if heard.elapsed() > SILENT_FOR { return Ended::Dropped }
                    let _ = socket.send(Message::Ping(Vec::new().into())).await;
                },
                () = access.lost() => return Ended::Done,
            }
        }
    }

    /// Waits for the phone to come back, keeping core's output meanwhile.
    /// Core sends no more than its credit allows, so what is kept stays bounded.
    async fn wait(&mut self, claims: &mut mpsc::Receiver<Claim>, access: &mut Access) -> Accepted {
        let deadline = tokio::time::sleep(resume::KEEP);
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                output = self.observer.next() => match output {
                    Some(Output::Data(bytes)) => {
                        self.owed += bytes.len();
                        self.replay.push(&bytes);
                    }
                    // The stream ended while the phone was away; it learns so
                    // when it attaches afresh.
                    Some(Output::Closed(_)) | None => return Accepted::Refused,
                },
                Some(claim) = claims.recv() => match self.accept(claim).await {
                    Accepted::Lost => {}
                    answer => return answer,
                },
                () = &mut deadline => return Accepted::Refused,
                () = access.lost() => return Accepted::Refused,
            }
        }
    }

    /// A phone coming back: hand over if every byte it lacks is still here.
    async fn accept(&self, claim: Claim) -> Accepted {
        if self.replay.since(claim.offset).is_none() {
            let _ = claim.reply.send(None);
            return Accepted::Refused;
        }
        let (handover, arrival) = oneshot::channel();
        if claim.reply.send(Some(handover)).is_err() {
            return Accepted::Lost;
        }
        match tokio::time::timeout(HANDOVER_WITHIN, arrival).await {
            Ok(Ok((socket, caller))) => Accepted::Yes(Box::new(socket), caller, claim.offset),
            _ => Accepted::Lost,
        }
    }

    /// Picks the stream up on a phone's new connection: `resumed`, the bytes
    /// it lacks, then the grid if it changed meanwhile. False if those bytes
    /// are gone after all.
    async fn go_on(
        &mut self,
        socket: &mut WebSocket,
        state: &AppState,
        id: &str,
        resumed: &ServerMessage<'_>,
        offset: u64,
    ) -> Result<bool> {
        let Some(missed) = self.replay.since(offset) else { return Ok(false) };
        send(socket, resumed).await?;
        for chunk in missed.chunks(64 << 10) {
            socket.send(Message::Binary(chunk.to_vec().into())).await?;
        }
        if self.owed > 0 {
            self.observer.consumed(std::mem::take(&mut self.owed)).await?;
        }
        let current = session_size(&state.view.borrow(), id);
        if let Some(current) = current && current != self.size {
            self.size = current;
            send(socket, &ServerMessage::Size { cols: current.0, rows: current.1 }).await?;
        }
        Ok(true)
    }
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
    // The app holds this socket only while it is in the foreground.
    let _here = state.phones.arrive(lang);
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
        let message: ObserveMessage = serde_json::from_str(r#"{"type":"detach"}"#).unwrap();
        assert!(matches!(message, ObserveMessage::Detach));
    }

    #[test]
    fn resume_is_opt_in_and_says_where_to_go_on() {
        let query = |q: &str| {
            let uri = format!("/v0/observe?{q}").parse().unwrap();
            Query::<ObserveQuery>::try_from_uri(&uri).unwrap().0
        };
        let old = query("session=t1&takeover=1&cols=49&rows=45");
        assert!(old.resumable.is_none() && old.resume.is_none());
        let back = query("session=t1&resume=ab12&offset=1048576");
        assert_eq!(back.resume.as_deref(), Some("ab12"));
        assert_eq!(back.offset, Some(1 << 20));

        let attached = |resume, keep_ms| {
            serde_json::to_value(ServerMessage::Attached { cols: 80, rows: 24, resume, keep_ms }).unwrap()
        };
        assert_eq!(attached(None, None), serde_json::json!({"type": "attached", "cols": 80, "rows": 24}));
        assert_eq!(attached(Some("ab12"), Some(30000))["resume"], "ab12");
        let resumed = serde_json::to_value(ServerMessage::Resumed { resume: "cd34", keep_ms: 30000 }).unwrap();
        assert_eq!(resumed, serde_json::json!({"type": "resumed", "resume": "cd34", "keep_ms": 30000}));
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

    /// A stand-in for `hc connect` that attaches, sends `first`, `second` a
    /// little after `first` is credited, and `third` once both are; it logs
    /// what the Gateway sends it.
    const FAKE_CORE: &str = r#"#!/usr/bin/env python3
import json, struct, sys, threading, time
LOG = sys.argv[0] + ".log"
inp, out = sys.stdin.buffer, sys.stdout.buffer
lock = threading.Lock()
def log(line):
    with open(LOG, "a") as f: f.write(line + "\n")
def frame(channel, kind, payload):
    with lock:
        out.write(struct.pack("<IBI", channel, kind, len(payload)) + payload); out.flush()
def read():
    header = inp.read(9)
    if len(header) < 9: return None
    channel, kind, n = struct.unpack("<IBI", header)
    return channel, kind, inp.read(n)
inp.readline()
out.write(b'{"jsonrpc":"2.0","id":0,"result":{}}\n'); out.flush()
params = json.loads(read()[2])["params"]
log("attach %d %d" % (params["cols"], params["rows"]))
frame(0, 0, json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"channel": 7, "terminal": {"cols": params["cols"], "rows": params["rows"]}}}).encode())
frame(7, 0, b"first")
def later():
    time.sleep(0.3); frame(7, 0, b"second")
credited = 0
while True:
    got = read()
    if got is None: log("eof"); break
    _, kind, payload = got
    if kind == 1:
        credited += struct.unpack("<I", payload)[0]
        log("credited %d" % credited)
        if credited == 5: threading.Thread(target=later).start()
        if credited == 11: frame(7, 0, b"third")
    elif kind == 2:
        log("close credited %d" % credited); break
"#;

    #[tokio::test]
    async fn a_dropped_phone_picks_up_where_it_left_off() {
        use futures_util::{SinkExt as _, StreamExt as _};
        use tokio_tungstenite::tungstenite::{self, client::IntoClientRequest as _};
        if std::process::Command::new("python3").arg("-V").output().is_err() {
            eprintln!("skipped: no python3 for the fake core");
            return;
        }
        let dir = std::env::temp_dir().join(format!("companion-resume-{}", std::process::id()));
        let store = Store::open(dir.clone()).unwrap();
        let code = store.offer().unwrap();
        let (_, bearer) = store.pair(&code, "iPhone").unwrap().unwrap();
        let hc = dir.join("hc");
        std::fs::write(&hc, FAKE_CORE).unwrap();
        std::fs::set_permissions(&hc, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        let log = dir.join("hc.log");

        let session = Session::from_record(&serde_json::json!({"address": "t1", "state": "live", "cwd": "/", "cols": 120, "rows": 40})).unwrap();
        let (_view_sender, view) = watch::channel(CoreView { core: Some("mac".into()), sessions: vec![session], spaces: vec![] });
        let (_about_sender, about) = watch::channel(About::default());
        let (_tailnet_sender, tailnet) = watch::channel(tailnet::State::At("127.0.0.1:7420".parse().unwrap()));
        let devices = Arc::new(watch::Sender::new(store.devices().unwrap()));
        let state = AppState {
            hc: hc.to_str().unwrap().into(), view, store: Arc::new(store), devices,
            changes: Arc::default(), about, tailnet, streams: Default::default(), phones: Arc::default(),
        };
        let app = Router::new().route("/v0/observe", get(observe)).with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await });

        let open = |query: String| {
            let mut request = format!("ws://{addr}/v0/observe?{query}").into_client_request().unwrap();
            request.headers_mut().insert(header::AUTHORIZATION, format!("Bearer {bearer}").parse().unwrap());
            tokio_tungstenite::connect_async(request)
        };
        let patience = Duration::from_secs(5);
        async fn text<S: futures_util::Stream<Item = tungstenite::Result<tungstenite::Message>> + Unpin>(phone: &mut S) -> Value {
            loop {
                match phone.next().await.unwrap().unwrap() {
                    tungstenite::Message::Text(text) => return serde_json::from_str(&text).unwrap(),
                    tungstenite::Message::Binary(bytes) => panic!("bytes before control: {bytes:?}"),
                    _ => {}
                }
            }
        }

        // Take the terminal over, read the first bytes, then drop off without a word.
        let (mut phone, _) = open("session=t1&takeover=1&cols=40&rows=10&resumable=1".into()).await.unwrap();
        let attached = text(&mut phone).await;
        assert_eq!((attached["type"].as_str(), attached["keep_ms"].as_u64()), (Some("attached"), Some(30000)));
        let first_token = attached["resume"].as_str().unwrap().to_owned();
        let first = tokio::time::timeout(patience, phone.next()).await.unwrap().unwrap().unwrap();
        assert_eq!(first.into_data().as_ref(), b"first");
        drop(phone);
        tokio::time::sleep(Duration::from_millis(600)).await;

        // Come back with the five bytes it has: the rest follows, from the same attach.
        let (mut phone, _) = open(format!("session=t1&resume={first_token}&offset=5")).await.unwrap();
        let resumed = text(&mut phone).await;
        assert_eq!(resumed["type"], "resumed");
        assert_ne!(resumed["resume"], first_token.as_str());
        let mut missed = Vec::new();
        while missed.len() < b"secondthird".len() {
            let message = tokio::time::timeout(patience, phone.next()).await.unwrap().unwrap().unwrap();
            if let tungstenite::Message::Binary(bytes) = message {
                missed.extend_from_slice(&bytes);
            }
        }
        assert_eq!(missed, b"secondthird");

        // A token works once; another device's or session's never does.
        let reused = open(format!("session=t1&resume={first_token}&offset=5")).await;
        assert!(matches!(reused, Err(tungstenite::Error::Http(response)) if response.status() == 410));

        // Leaving says so, and the stream ends at once.
        phone.send(tungstenite::Message::text(r#"{"type":"detach"}"#)).await.unwrap();
        let closed = tokio::time::timeout(patience, async {
            while let Some(Ok(message)) = phone.next().await {
                if let tungstenite::Message::Close(_) = message {
                    break;
                }
            }
        });
        assert!(closed.await.is_ok(), "the Gateway let the stream go");
        assert_eq!(state.streams.len(), 0);
        // Core is let go right after its CLOSE, so it may not get to log that.
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(logged.starts_with("attach 40 10\n") && logged.matches("attach").count() == 1, "{logged}");
        assert!(logged.contains("credited 16\n"), "every byte credited once it reached the phone: {logged}");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
