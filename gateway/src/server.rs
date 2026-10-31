//! Companion API v0, authorized by a bearer token:
//! - `/v0/ws` pushes `hello`, then the whole session list whenever it changes.
//! - `/v0/observe?session=<id>` streams one terminal read-only: control as text,
//!   terminal bytes as binary messages.

use crate::herdr::CoreView;
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
use tokio::sync::watch;

pub const API_VERSION: u32 = 0;

#[derive(Clone)]
struct AppState {
    token: Arc<str>,
    hc: Arc<str>,
    view: watch::Receiver<CoreView>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage<'a> {
    Hello { api: u32, gateway: &'static str },
    Sessions { core: Option<&'a str>, connected: bool, sessions: &'a [Session] },
    /// Observing began; render a grid of this size.
    Attached { cols: u16, rows: u16 },
    /// The terminal's grid changed (another client resized it).
    Size { cols: u16, rows: u16 },
    /// The stream ended; `reason` as the core gave it, or why attaching failed.
    Closed { reason: &'a Value },
}

pub async fn serve(listen: SocketAddr, token: String, hc: String, view: watch::Receiver<CoreView>) -> Result<()> {
    let state = AppState { token: token.into(), hc: hc.into(), view };
    let app = Router::new()
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

async fn upgrade(State(state): State<AppState>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    if !authorized(&headers, &state.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    ws.on_upgrade(move |socket| push(socket, state.view))
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
    if !authorized(&headers, &state.token) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(size) = session_size(&state.view.borrow(), &query.session) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    ws.on_upgrade(move |socket| relay(socket, state, query.session, size))
}

fn session_size(view: &CoreView, id: &str) -> Option<(u16, u16)> {
    view.sessions.iter().find(|s| s.id == id).map(|s| (s.cols, s.rows))
}

async fn relay(mut socket: WebSocket, state: AppState, id: String, (cols, rows): (u16, u16)) {
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
        }
    }
    observer.detach().await;
}

fn authorized(headers: &HeaderMap, token: &str) -> bool {
    let given = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();
    constant_time_eq(given.as_bytes(), token.as_bytes())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn push(mut socket: WebSocket, mut view: watch::Receiver<CoreView>) {
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
            })
        };
        let Ok(message) = message else { return };
        if socket.send(Message::Text(message.into())).await.is_err() {
            return;
        }
        tokio::select! {
            changed = view.changed() => if changed.is_err() { return },
            // The app sends nothing yet; a close or error ends the connection.
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => return,
                Some(Ok(_)) => {}
            },
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
    fn bearer_token_must_match() {
        let mut headers = HeaderMap::new();
        assert!(!authorized(&headers, "secret"));
        headers.insert(header::AUTHORIZATION, "Bearer secret".parse().unwrap());
        assert!(authorized(&headers, "secret"));
        headers.insert(header::AUTHORIZATION, "Bearer secreT".parse().unwrap());
        assert!(!authorized(&headers, "secret"));
    }
}
