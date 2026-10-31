//! Companion API v0: one WebSocket at `/v0/ws`, authorized by a bearer token.
//! The Gateway pushes `hello`, then the whole session list whenever it changes.

use crate::herdr::CoreView;
use crate::session::Session;
use anyhow::{Context as _, Result};
use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use serde::Serialize;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::watch;

pub const API_VERSION: u32 = 0;

#[derive(Clone)]
struct AppState {
    token: Arc<str>,
    view: watch::Receiver<CoreView>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerMessage<'a> {
    Hello { api: u32, gateway: &'static str },
    Sessions { core: Option<&'a str>, connected: bool, sessions: &'a [Session] },
}

pub async fn serve(listen: SocketAddr, token: String, view: watch::Receiver<CoreView>) -> Result<()> {
    let state = AppState { token: token.into(), view };
    let app = Router::new().route("/v0/ws", get(upgrade)).with_state(state);
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
