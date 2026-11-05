//! `/v0/mux`: many streams on one WebSocket (ADR 0007).
//!
//! Every message is one frame, `[stream id: u32][kind: u8][payload]`, little
//! endian. The phone opens a stream with OPEN and the endpoint's path; the
//! stream is then served by the Gateway's own Router in this process, as if
//! the phone had connected to that endpoint by itself, and its messages go
//! back and forth as TEXT and BINARY frames until either side sends CLOSE.
//! Stream 0 is the mux's own: the Gateway says `{"type":"mux","v":1}` on it as
//! soon as it accepts the connection.

use crate::relay::{self, RelayDevice};
use axum::extract::ws::{self, WebSocket};
use axum::http::HeaderValue;
use axum::{Extension, Router};
use futures_util::{SinkExt as _, StreamExt as _};
use std::collections::HashMap;
use std::future::Future;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest as _};

pub const OPEN: u8 = 0;
pub const TEXT: u8 = 1;
pub const BINARY: u8 = 2;
pub const CLOSE: u8 = 3;

pub const HELLO: &[u8] = br#"{"type":"mux","v":1}"#;
/// Streams one mux carries at once.
pub const MAX_STREAMS: usize = 32;
/// Messages from the phone a stream holds before it counts as fallen behind.
const QUEUE: usize = 64;
const PING_EVERY: Duration = Duration::from_secs(15);
const SILENT_FOR: Duration = Duration::from_secs(45);

/// Close codes of the mux's own.
const BAD_REQUEST: u16 = 4400;
const TRY_AGAIN: u16 = 1013;

pub fn encode(id: u32, kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.extend_from_slice(&id.to_le_bytes());
    frame.push(kind);
    frame.extend_from_slice(payload);
    frame
}

pub fn decode(frame: &[u8]) -> Option<(u32, u8, &[u8])> {
    let id = u32::from_le_bytes(frame.get(..4)?.try_into().ok()?);
    Some((id, *frame.get(4)?, &frame[5..]))
}

pub fn close(id: u32, code: u16, reason: &str) -> Vec<u8> {
    let mut payload = code.to_le_bytes().to_vec();
    payload.extend_from_slice(reason.as_bytes());
    encode(id, CLOSE, &payload)
}

/// How the mux's streams prove the phone to their endpoints: as the mux
/// itself was proved.
pub enum Pass {
    /// Through the Relay: the device the Noise handshake named.
    Relay(String),
    /// On the tailnet: the device token the mux was opened with.
    Bearer(HeaderValue),
}

/// An endpoint a stream may open: any but pairing and the mux itself.
fn allowed(path: &str) -> bool {
    path.starts_with("/v0/") && !path.starts_with("/v0/pair") && !path.starts_with("/v0/mux")
}

/// Serves one mux to its end, or until `lost` (the device was unpaired, its
/// path went away). Its streams end with it.
pub async fn serve(socket: WebSocket, api: Router, pass: Pass, lost: impl Future<Output = ()>) {
    let (router, bearer) = match pass {
        Pass::Relay(device) => (api.layer(Extension(RelayDevice(device))), None),
        Pass::Bearer(token) => (api, Some(token)),
    };
    let (mut sink, mut incoming) = socket.split();
    if sink.send(ws::Message::Binary(encode(0, TEXT, HELLO).into())).await.is_err() {
        return;
    }
    let (to_phone, mut outgoing) = mpsc::channel::<Vec<u8>>(QUEUE);
    let (ended, mut ended_streams) = mpsc::unbounded_channel::<u32>();
    let mut streams: HashMap<u32, mpsc::Sender<Message>> = HashMap::new();
    let mut last_heard = Instant::now();
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut lost = std::pin::pin!(lost);
    loop {
        tokio::select! {
            message = incoming.next() => {
                last_heard = Instant::now();
                let frame = match message {
                    Some(Ok(ws::Message::Binary(frame))) => frame,
                    Some(Ok(ws::Message::Ping(_) | ws::Message::Pong(_))) => continue,
                    _ => break,
                };
                let Some((id, kind, payload)) = decode(&frame) else { break };
                match kind {
                    OPEN if id != 0 && !streams.contains_key(&id) => {
                        let path = std::str::from_utf8(payload).unwrap_or_default();
                        let request = allowed(path).then(|| format!("ws://gateway{path}").into_client_request().ok()).flatten();
                        let Some(mut request) = request else {
                            let _ = sink.send(ws::Message::Binary(close(id, BAD_REQUEST, "Unknown endpoint").into())).await;
                            continue;
                        };
                        if streams.len() >= MAX_STREAMS {
                            let _ = sink.send(ws::Message::Binary(close(id, TRY_AGAIN, "Too many streams").into())).await;
                            continue;
                        }
                        if let Some(token) = &bearer {
                            request.headers_mut().insert(axum::http::header::AUTHORIZATION, token.clone());
                        }
                        let (sender, receiver) = mpsc::channel(QUEUE);
                        streams.insert(id, sender);
                        tokio::spawn(stream(router.clone(), request, id, receiver, to_phone.clone(), ended.clone()));
                    }
                    TEXT | BINARY => {
                        let Some(sender) = streams.get(&id) else { continue };
                        let message = if kind == TEXT {
                            match String::from_utf8(payload.to_vec()) {
                                Ok(text) => Message::Text(text.into()),
                                Err(_) => break,
                            }
                        } else {
                            Message::Binary(payload.to_vec().into())
                        };
                        // Waiting on one stream would hold up the others.
                        if sender.try_send(message).is_err() {
                            streams.remove(&id);
                            let _ = sink.send(ws::Message::Binary(close(id, TRY_AGAIN, "Fell behind").into())).await;
                        }
                    }
                    // The phone is done with it: its endpoint sees the connection close.
                    CLOSE => {
                        streams.remove(&id);
                    }
                    _ => {}
                }
            }
            Some(frame) = outgoing.recv() => {
                if sink.send(ws::Message::Binary(frame.into())).await.is_err() {
                    break;
                }
            }
            Some(id) = ended_streams.recv() => {
                streams.remove(&id);
            }
            _ = ping.tick() => {
                if last_heard.elapsed() > SILENT_FOR {
                    break;
                }
                let _ = sink.send(ws::Message::Ping(Vec::new().into())).await;
            }
            () = &mut lost => break,
        }
    }
    drop(streams);
    let _ = sink.close().await;
}

/// One stream: its endpoint, in this process, until either side ends it.
async fn stream(
    router: Router,
    request: tokio_tungstenite::tungstenite::handshake::client::Request,
    id: u32,
    mut from_phone: mpsc::Receiver<Message>,
    to_phone: mpsc::Sender<Vec<u8>>,
    ended: mpsc::UnboundedSender<u32>,
) {
    let end = match relay::in_process(router, request).await {
        Err(code) => Some((code, "Refused".to_owned())),
        Ok(mut local) => loop {
            tokio::select! {
                message = from_phone.recv() => match message {
                    Some(message) => {
                        if local.send(message).await.is_err() {
                            break Some((1000, String::new()));
                        }
                    }
                    // The phone closed it, or the mux is gone.
                    None => {
                        let _ = local.close(None).await;
                        break None;
                    }
                },
                message = local.next() => {
                    let frame = match message {
                        Some(Ok(Message::Text(text))) => encode(id, TEXT, text.as_bytes()),
                        Some(Ok(Message::Binary(bytes))) => encode(id, BINARY, &bytes),
                        Some(Ok(Message::Close(frame))) => break Some(relay::passed_on(frame)),
                        Some(Ok(_)) => continue,
                        Some(Err(_)) | None => break Some((1000, String::new())),
                    };
                    if to_phone.send(frame).await.is_err() {
                        break None;
                    }
                }
            }
        },
    };
    if let Some((code, reason)) = end {
        let _ = to_phone.send(close(id, code, &reason)).await;
    }
    let _ = ended.send(id);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip() {
        let frame = encode(7, BINARY, &[1, 2, 3]);
        assert_eq!(frame[..5], [7, 0, 0, 0, BINARY]);
        assert_eq!(decode(&frame), Some((7, BINARY, &[1u8, 2, 3][..])));
        assert_eq!(decode(&[1, 0, 0, 0]), None);
        assert_eq!(decode(&close(3, 4404, "Refused")), Some((3, CLOSE, &b"\x34\x11Refused"[..])));
    }

    type Phone = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

    /// Says which token it was opened with, echoes, and ends with 4100 on "bye".
    async fn echo(headers: axum::http::HeaderMap, upgrade: ws::WebSocketUpgrade) -> axum::response::Response {
        let token = headers.get(axum::http::header::AUTHORIZATION).and_then(|v| v.to_str().ok()).unwrap_or("").to_owned();
        upgrade.on_upgrade(move |mut socket| async move {
            let _ = socket.send(ws::Message::Text(token.into())).await;
            while let Some(Ok(message)) = socket.recv().await {
                match message {
                    ws::Message::Text(text) if text.as_str() == "bye" => {
                        let frame = ws::CloseFrame { code: 4100, reason: "done".into() };
                        let _ = socket.send(ws::Message::Close(Some(frame))).await;
                        return;
                    }
                    ws::Message::Text(_) | ws::Message::Binary(_) => {
                        #[allow(clippy::collapsible_match)]
                        if socket.send(message).await.is_err() {
                            return;
                        }
                    }
                    _ => {}
                }
            }
        })
    }

    async fn next(phone: &mut Phone) -> (u32, u8, Vec<u8>) {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(5), phone.next()).await.expect("the mux answers");
            if let Message::Binary(frame) = message.expect("open").expect("no error") {
                let (id, kind, payload) = decode(&frame).expect("a frame");
                return (id, kind, payload.to_vec());
            }
        }
    }

    #[tokio::test]
    async fn streams_share_one_socket_and_keep_to_themselves() {
        let api = Router::new().route("/v0/echo", axum::routing::get(echo));
        let streams = api.clone();
        let app = api.route(
            "/v0/mux",
            axum::routing::get(move |headers: axum::http::HeaderMap, upgrade: ws::WebSocketUpgrade| {
                let streams = streams.clone();
                let token = headers.get(axum::http::header::AUTHORIZATION).cloned().unwrap();
                async move { upgrade.on_upgrade(move |socket| serve(socket, streams, Pass::Bearer(token), std::future::pending())) }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await });
        let mut request = format!("ws://{addr}/v0/mux").into_client_request().unwrap();
        request.headers_mut().insert(axum::http::header::AUTHORIZATION, "Bearer t0k".parse().unwrap());
        let (mut phone, _) = tokio_tungstenite::connect_async(request).await.unwrap();
        assert_eq!(next(&mut phone).await, (0, TEXT, HELLO.to_vec()));

        // Two streams at once, each its own endpoint connection, with the mux's token.
        for id in [1u32, 2] {
            phone.send(Message::Binary(encode(id, OPEN, b"/v0/echo").into())).await.unwrap();
        }
        let mut greeted = vec![next(&mut phone).await, next(&mut phone).await];
        greeted.sort();
        assert_eq!(greeted, vec![(1, TEXT, b"Bearer t0k".to_vec()), (2, TEXT, b"Bearer t0k".to_vec())]);
        phone.send(Message::Binary(encode(2, BINARY, &[9, 9]).into())).await.unwrap();
        phone.send(Message::Binary(encode(1, TEXT, b"one").into())).await.unwrap();
        let mut echoed = vec![next(&mut phone).await, next(&mut phone).await];
        echoed.sort();
        assert_eq!(echoed, vec![(1, TEXT, b"one".to_vec()), (2, BINARY, vec![9, 9])]);

        // The endpoint's own close code comes through; the other stream goes on.
        phone.send(Message::Binary(encode(1, TEXT, b"bye").into())).await.unwrap();
        assert_eq!(next(&mut phone).await, (1, CLOSE, b"\x04\x10done".to_vec()));
        phone.send(Message::Binary(encode(2, TEXT, b"still").into())).await.unwrap();
        assert_eq!(next(&mut phone).await, (2, TEXT, b"still".to_vec()));

        // Refusals: no such endpoint, and endpoints a stream may not open.
        phone.send(Message::Binary(encode(3, OPEN, b"/v0/nothing").into())).await.unwrap();
        assert_eq!(next(&mut phone).await, (3, CLOSE, b"\x34\x11Refused".to_vec()));
        phone.send(Message::Binary(encode(4, OPEN, b"/v0/mux").into())).await.unwrap();
        assert_eq!(next(&mut phone).await.1, CLOSE);
        phone.send(Message::Binary(encode(5, OPEN, b"/v0/pair").into())).await.unwrap();
        assert_eq!(next(&mut phone).await, (5, CLOSE, close(5, BAD_REQUEST, "Unknown endpoint")[5..].to_vec()));

        // Closed by the phone: nothing more on it, and the mux carries on.
        phone.send(Message::Binary(close(2, 1000, "").into())).await.unwrap();
        phone.send(Message::Binary(encode(2, TEXT, b"gone").into())).await.unwrap();
        phone.send(Message::Binary(encode(6, OPEN, b"/v0/echo").into())).await.unwrap();
        assert_eq!(next(&mut phone).await.0, 6);
    }

    #[test]
    fn a_stream_opens_any_endpoint_but_pairing_and_the_mux() {
        assert!(allowed("/v0/observe?session=a"));
        assert!(allowed("/v0/ws"));
        assert!(!allowed("/v0/pair"));
        assert!(!allowed("/v0/mux"));
        assert!(!allowed("/elsewhere"));
    }
}
