//! The Gateway's side of the Relay (ADR 0006, `relay/PROTOCOL.md`).
//!
//! The Gateway dials out to the relay named in `relay.json` and registers with
//! the SHA-256 of its route token. Each phone socket arrives as a stream; the
//! phone opens it with a Noise `IKpsk2` handshake, then sends which endpoint it
//! wants (`{"path":"/v0/ws"}`). The stream is then served by the same Router as
//! the tailnet, in this process over an in-memory pipe, with the device the
//! handshake proved attached as a [`RelayDevice`] extension instead of a
//! bearer token. A phone that is pairing proves the link secret instead, and
//! may only ask to pair.

use crate::devices::{Device, Store, b64, decode_key};
use crate::noise::{self, Keypair, Opener};
use anyhow::{Context as _, Result, anyhow, bail};
use axum::{Extension, Router};
use futures_util::{SinkExt as _, StreamExt as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::{self, Message, client::IntoClientRequest as _, protocol::CloseFrame};

/// Data frame kind (`relay/PROTOCOL.md`).
const DATA: u8 = 1;
const PROTOCOL: u32 = 1;
const PING_EVERY: Duration = Duration::from_secs(20);
/// Nothing at all from the relay for this long means the connection is dead.
const SILENT_FOR: Duration = Duration::from_secs(60);
const HANDSHAKE_WITHIN: Duration = Duration::from_secs(15);
const CONFIG_CHECK: Duration = Duration::from_secs(10);

/// Close codes a stream ends with, besides the local endpoint's own.
const UNKNOWN_DEVICE: u16 = 4401;
const BAD_REQUEST: u16 = 4400;

/// The device a Relay stream's handshake proved; handlers take it in place of
/// a bearer token. Only streams from the Relay carry it.
#[derive(Clone)]
pub struct RelayDevice(pub String);

/// `relay.json` in the state directory.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct Config {
    /// `https://relay.example.com` (or `wss://`; `http://` for a local relay).
    pub url: String,
    /// The relay's registration key, if it has one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    /// The route token (base64url, 256 bits) phones reach this Gateway by.
    pub route: String,
}

impl Config {
    fn path(dir: &Path) -> PathBuf {
        dir.join("relay.json")
    }

    pub fn load(dir: &Path) -> Result<Option<Self>> {
        let path = Self::path(dir);
        match std::fs::read(&path) {
            Ok(bytes) => Ok(Some(serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))?)),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err).with_context(|| format!("reading {}", path.display())),
        }
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt as _;
        let tmp = dir.join("relay.json.tmp");
        let mut file = std::fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&tmp)?;
        file.write_all(&serde_json::to_vec_pretty(self)?)?;
        file.sync_all()?;
        std::fs::rename(&tmp, Self::path(dir))?;
        Ok(())
    }

    pub fn remove(dir: &Path) -> Result<bool> {
        match std::fs::remove_file(Self::path(dir)) {
            Ok(()) => Ok(true),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(err) => Err(err.into()),
        }
    }

    /// A new configuration with a fresh route token.
    pub fn new(url: &str, key: Option<String>) -> Result<Self> {
        let url = url.trim_end_matches('/').to_owned();
        if !["https://", "wss://", "http://", "ws://"].iter().any(|scheme| url.starts_with(scheme)) {
            bail!("the relay address starts with https:// (or wss://), not {url:?}");
        }
        Ok(Self { url, key, route: b64(&crate::devices::random_bytes::<32>()?) })
    }

    pub fn route_hash(&self) -> String {
        crate::devices::hex(&Sha256::digest(self.route.as_bytes()))
    }

    /// The relay's WebSocket address for a Gateway.
    fn gateway_url(&self) -> String {
        let base = if let Some(rest) = self.url.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = self.url.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            self.url.clone()
        };
        format!("{base}/gateway?route={}", self.route_hash())
    }
}

/// How the running Gateway's connection to the relay stands, for
/// `yochi relay status`: `relay-status.json`, rewritten while connected.
#[derive(Serialize, Deserialize)]
pub struct Status {
    pub url: String,
    pub connected: bool,
    /// Unix seconds of the last write; a stale one means no Gateway is running.
    pub at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Status {
    /// How often a connected Gateway rewrites it.
    pub const EVERY: Duration = PING_EVERY;

    fn path(dir: &Path) -> PathBuf {
        dir.join("relay-status.json")
    }

    pub fn load(dir: &Path) -> Option<Self> {
        serde_json::from_slice(&std::fs::read(Self::path(dir)).ok()?).ok()
    }

    fn write(dir: &Path, url: &str, connected: bool, error: Option<String>) {
        let status = Self { url: url.to_owned(), connected, at: crate::devices::now(), error };
        let tmp = dir.join("relay-status.json.tmp");
        if let Ok(bytes) = serde_json::to_vec(&status)
            && std::fs::write(&tmp, bytes).is_ok()
        {
            let _ = std::fs::rename(&tmp, Self::path(dir));
        }
    }
}

/// What a stream needs from the rest of the Gateway.
pub struct Relay {
    pub router: Router,
    pub store: Arc<Store>,
    pub devices: Arc<watch::Sender<Vec<Device>>>,
    pub keys: Keypair,
}

/// Keeps a connection to the configured relay, redialling when it drops and
/// picking up `relay.json` changes. Without a configuration it waits for one.
/// rustls panics on the first `wss://` connection unless a crypto backend is
/// chosen; tokio-tungstenite leaves that to the program.
pub fn install_tls() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

pub async fn run(relay: Arc<Relay>) {
    install_tls();
    let dir = relay.store.dir().to_owned();
    let mut backoff = Duration::from_secs(1);
    loop {
        let config = match Config::load(&dir) {
            Ok(Some(config)) => config,
            Ok(None) => {
                tokio::time::sleep(CONFIG_CHECK).await;
                continue;
            }
            Err(err) => {
                eprintln!("relay: {err:#}");
                tokio::time::sleep(CONFIG_CHECK).await;
                continue;
            }
        };
        let started = Instant::now();
        match connect(&relay, &config, &dir).await {
            Ok(()) => {
                eprintln!("relay: disconnected from {}", config.url);
                Status::write(&dir, &config.url, false, None);
            }
            Err(err) => {
                eprintln!("relay: {}: {err:#}", config.url);
                Status::write(&dir, &config.url, false, Some(format!("{err:#}")));
            }
        }
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_secs(1);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

/// `[kind][idLen][id][payload]`
fn encode_frame(id: &str, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(2 + id.len() + payload.len());
    frame.push(DATA);
    frame.push(id.len() as u8);
    frame.extend_from_slice(id.as_bytes());
    frame.extend_from_slice(payload);
    frame
}

fn decode_frame(frame: &[u8]) -> Option<(u8, &str, &[u8])> {
    let (&kind, rest) = frame.split_first()?;
    let (&len, rest) = rest.split_first()?;
    let len = usize::from(len);
    if rest.len() < len {
        return None;
    }
    Some((kind, std::str::from_utf8(&rest[..len]).ok()?, &rest[len..]))
}

#[derive(Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
enum Control {
    Registered,
    Error {
        #[serde(default)]
        message: String,
    },
    Open {
        id: String,
    },
    Close {
        id: String,
    },
    #[serde(other)]
    Other,
}

async fn connect(relay: &Arc<Relay>, config: &Config, dir: &Path) -> Result<()> {
    let (socket, _) = tokio::time::timeout(Duration::from_secs(15), tokio_tungstenite::connect_async(config.gateway_url()))
        .await
        .context("timed out connecting")??;
    let (mut sink, mut incoming) = socket.split();
    let register = serde_json::json!({ "t": "register", "v": PROTOCOL, "key": config.key });
    sink.send(Message::Text(register.to_string().into())).await?;
    match tokio::time::timeout(Duration::from_secs(10), incoming.next()).await {
        Ok(Some(Ok(Message::Text(text)))) => match serde_json::from_str(&text) {
            Ok(Control::Registered) => {}
            Ok(Control::Error { message }) => bail!("the relay refused this Gateway: {message}"),
            _ => bail!("unexpected reply from the relay: {text}"),
        },
        Ok(Some(Ok(Message::Close(frame)))) => bail!("the relay closed the connection: {frame:?}"),
        Ok(Some(Err(err))) => return Err(err.into()),
        _ => bail!("the relay did not answer the registration"),
    }
    eprintln!("relay: connected to {}", config.url);
    Status::write(dir, &config.url, true, None);

    let (outgoing, mut to_relay) = mpsc::channel::<Message>(256);
    let writer = tokio::spawn(async move {
        while let Some(message) = to_relay.recv().await {
            if sink.send(message).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let (ended, mut ended_streams) = mpsc::unbounded_channel::<String>();
    let mut streams: HashMap<String, mpsc::Sender<Vec<u8>>> = HashMap::new();
    let mut last_heard = Instant::now();
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut check = tokio::time::interval(CONFIG_CHECK);
    let result = loop {
        tokio::select! {
            message = incoming.next() => {
                last_heard = Instant::now();
                match message {
                    Some(Ok(Message::Text(text))) => match serde_json::from_str(&text) {
                        Ok(Control::Open { id }) => {
                            let (sender, receiver) = mpsc::channel(64);
                            streams.insert(id.clone(), sender);
                            let relay = relay.clone();
                            let outgoing = outgoing.clone();
                            let ended = ended.clone();
                            tokio::spawn(async move {
                                stream(&relay, &id, receiver, &outgoing).await;
                                let _ = ended.send(id);
                            });
                        }
                        Ok(Control::Close { id }) => {
                            streams.remove(&id);
                        }
                        _ => {}
                    },
                    Some(Ok(Message::Binary(frame))) => {
                        let Some((DATA, id, payload)) = decode_frame(&frame) else { continue };
                        // Waiting on one stream would hold up every phone on this
                        // connection; one that falls this far behind is dropped instead.
                        if let Some(sender) = streams.get(id)
                            && sender.try_send(payload.to_vec()).is_err()
                        {
                            eprintln!("relay: stream {id} fell behind; closing it");
                            streams.remove(id);
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break Ok(()),
                    Some(Err(err)) => break Err(err.into()),
                    Some(Ok(_)) => {}
                }
            }
            Some(id) = ended_streams.recv() => {
                streams.remove(&id);
            }
            _ = ping.tick() => {
                if last_heard.elapsed() > SILENT_FOR {
                    break Err(anyhow!("the relay stopped answering"));
                }
                let _ = outgoing.send(Message::Ping(Vec::new().into())).await;
                Status::write(dir, &config.url, true, None);
            }
            _ = check.tick() => {
                if Config::load(dir).ok().flatten().as_ref() != Some(config) {
                    eprintln!("relay: configuration changed");
                    break Ok(());
                }
            }
        }
    };
    drop(streams);
    drop(outgoing);
    writer.abort();
    result
}

/// Who a stream's handshake proved the phone to be.
enum Phone {
    Paired(String),
    /// Pairing with the link secret, holding this static key.
    Pairing([u8; 32], [u8; 32]),
}

#[derive(Deserialize)]
struct Request {
    path: String,
    /// The device's name, when pairing.
    #[serde(default)]
    name: String,
}

/// Serves one phone stream to its end, then tells the relay it is closed.
async fn stream(relay: &Relay, id: &str, mut incoming: mpsc::Receiver<Vec<u8>>, outgoing: &mpsc::Sender<Message>) {
    let (code, reason) = match serve(relay, id, &mut incoming, outgoing).await {
        Ok(close) => close,
        Err(err) => {
            eprintln!("relay: stream {id}: {err:#}");
            (BAD_REQUEST, "Bad stream".to_owned())
        }
    };
    let close = serde_json::json!({ "t": "close", "id": id, "code": code, "reason": reason });
    let _ = outgoing.send(Message::Text(close.to_string().into())).await;
}

async fn send_data(outgoing: &mpsc::Sender<Message>, id: &str, payload: &[u8]) -> Result<()> {
    outgoing.send(Message::Binary(encode_frame(id, payload).into())).await.map_err(|_| anyhow!("relay connection closed"))
}

async fn serve(relay: &Relay, id: &str, incoming: &mut mpsc::Receiver<Vec<u8>>, outgoing: &mpsc::Sender<Message>) -> Result<(u16, String)> {
    // Handshake: the phone's first message names its static key.
    let first = tokio::time::timeout(HANDSHAKE_WITHIN, incoming.recv()).await.context("no handshake")?;
    let Some(first) = first else { return Ok((1000, String::new())) };
    let mut handshake = noise::responder(&relay.keys.private)?;
    let mut scratch = vec![0u8; noise::MAX_MESSAGE];
    if handshake.read_message(&first, &mut scratch).is_err() {
        return Ok((UNKNOWN_DEVICE, "Handshake failed".into()));
    }
    let remote: [u8; 32] = handshake.get_remote_static().context("no static key")?.try_into()?;
    let known = relay.devices.borrow().iter().find_map(|device| Some((device.id.clone(), device.psk_for(&remote)?)));
    let (phone, psk) = match known {
        Some((device, psk)) => (Phone::Paired(device), psk),
        None => {
            let store = relay.store.clone();
            match tokio::task::spawn_blocking(move || store.offer_secret()).await?? {
                Some(secret) => (Phone::Pairing(remote, secret), secret),
                None => return Ok((UNKNOWN_DEVICE, "Unknown device".into())),
            }
        }
    };
    handshake.set_psk(noise::PSK_SLOT, &psk)?;
    let n = handshake.write_message(&[], &mut scratch)?;
    send_data(outgoing, id, &scratch[..n]).await?;
    let mut transport = handshake.into_transport_mode()?;
    let mut opener = Opener::default();

    // The first message proves the psk and says what the phone wants.
    let request = loop {
        let Some(message) = tokio::time::timeout(HANDSHAKE_WITHIN, incoming.recv()).await.context("no request")? else {
            return Ok((1000, String::new()));
        };
        match opener.open(&mut transport, &message) {
            Ok(Some((false, text))) => break serde_json::from_slice::<Request>(&text).context("bad request")?,
            Ok(Some((true, _))) => bail!("binary request"),
            Ok(None) => continue,
            // Wrong psk: not that device, or not the pairing's secret.
            Err(_) => return Ok((UNKNOWN_DEVICE, "Unknown device".into())),
        }
    };

    match phone {
        Phone::Pairing(remote, secret) => {
            if request.path != "/v0/pair" {
                return Ok((UNKNOWN_DEVICE, "Not paired".into()));
            }
            let reply = pair(relay, &secret, &remote, &request.name).await?;
            for message in noise::seal(&mut transport, false, reply.to_string().as_bytes())? {
                send_data(outgoing, id, &message).await?;
            }
            Ok((1000, String::new()))
        }
        Phone::Paired(device) => {
            if !request.path.starts_with("/v0/") || request.path.starts_with("/v0/pair") {
                return Ok((BAD_REQUEST, "Unknown endpoint".into()));
            }
            let local = match local(&relay.router, device, &request.path).await {
                Ok(local) => local,
                Err(code) => return Ok((code, "Refused".into())),
            };
            pump(id, local, incoming, outgoing, &mut transport, &mut opener).await
        }
    }
}

async fn pair(relay: &Relay, secret: &[u8; 32], remote: &[u8; 32], name: &str) -> Result<serde_json::Value> {
    let name: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
    let name = match name.trim() {
        "" => "iPhone".to_owned(),
        name => name.to_owned(),
    };
    let store = relay.store.clone();
    let (secret, remote) = (*secret, *remote);
    let paired = tokio::task::spawn_blocking(move || store.pair_relay(&secret, &remote, &name)).await??;
    Ok(match paired {
        Some((device, token, psk)) => {
            eprintln!("Paired {} ({}) over the Relay", device.name, device.id);
            let reply = serde_json::json!({ "type": "paired", "device": device.id, "token": token, "psk": b64(&psk) });
            relay.devices.send_modify(|devices| devices.push(device));
            reply
        }
        None => serde_json::json!({ "type": "rejected" }),
    })
}

type Local = tokio_tungstenite::WebSocketStream<tokio::io::DuplexStream>;

/// Opens `path` on the Gateway's own Router, in this process, as `device`.
/// Refusals come back as close codes: 4000 + the HTTP status.
async fn local(router: &Router, device: String, path: &str) -> Result<Local, u16> {
    let (client, server) = tokio::io::duplex(256 * 1024);
    let service = hyper_util::service::TowerToHyperService::new(router.clone().layer(Extension(RelayDevice(device))));
    tokio::spawn(async move {
        let io = hyper_util::rt::TokioIo::new(server);
        let _ = hyper::server::conn::http1::Builder::new().serve_connection(io, service).with_upgrades().await;
    });
    let request = format!("ws://gateway{path}").into_client_request().map_err(|_| BAD_REQUEST)?;
    match tokio_tungstenite::client_async(request, client).await {
        Ok((socket, _)) => Ok(socket),
        Err(tungstenite::Error::Http(response)) => Err(4000 + response.status().as_u16().min(999)),
        Err(_) => Err(4500),
    }
}

/// Carries messages both ways until either side ends.
async fn pump(
    id: &str,
    mut local: Local,
    incoming: &mut mpsc::Receiver<Vec<u8>>,
    outgoing: &mpsc::Sender<Message>,
    transport: &mut snow::TransportState,
    opener: &mut Opener,
) -> Result<(u16, String)> {
    loop {
        tokio::select! {
            message = incoming.recv() => {
                let Some(message) = message else {
                    let _ = local.close(None).await;
                    return Ok((1000, String::new()));
                };
                match opener.open(transport, &message)? {
                    Some((true, bytes)) => local.send(Message::Binary(bytes.into())).await?,
                    Some((false, text)) => local.send(Message::Text(String::from_utf8(text)?.into())).await?,
                    None => {}
                }
            }
            message = local.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    for sealed in noise::seal(transport, false, text.as_bytes())? {
                        send_data(outgoing, id, &sealed).await?;
                    }
                }
                Some(Ok(Message::Binary(bytes))) => {
                    for sealed in noise::seal(transport, true, &bytes)? {
                        send_data(outgoing, id, &sealed).await?;
                    }
                }
                Some(Ok(Message::Close(frame))) => {
                    return Ok(frame.map_or((1000, String::new()), |CloseFrame { code, reason }| {
                        let code = u16::from(code);
                        let code = if code == 1000 || (3000..5000).contains(&code) { code } else { 1000 };
                        (code, reason.to_string())
                    }));
                }
                Some(Ok(_)) => {}
                Some(Err(_)) | None => return Ok((1000, String::new())),
            }
        }
    }
}

/// What `relay_enroll` answers a paired device on the tailnet.
pub fn enrollment(store: &Store, device: &str, static_key: &str) -> Result<serde_json::Value> {
    let Some(config) = Config::load(store.dir())? else {
        return Ok(serde_json::json!({ "type": "relay", "available": false }));
    };
    let static_key = decode_key(static_key).context("a static key is 32 bytes, base64url")?;
    let Some(psk) = store.enroll(device, &static_key)? else { bail!("device {device} is not paired") };
    let gateway = store.gateway_key()?;
    Ok(serde_json::json!({
        "type": "relay",
        "available": true,
        "url": config.url,
        "route": config.route,
        "gateway_key": b64(&gateway.public),
        "psk": b64(&psk),
    }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_secure_relay_can_be_reached() {
        super::install_tls();
        // The builder is what panics without a backend.
        let roots = rustls::RootCertStore::empty();
        let _ = rustls::ClientConfig::builder().with_root_certificates(roots).with_no_client_auth();
    }

    use super::*;

    #[test]
    fn frames_round_trip() {
        let frame = encode_frame("s12", &[1, 2, 3]);
        assert_eq!(decode_frame(&frame), Some((DATA, "s12", &[1u8, 2, 3][..])));
        assert_eq!(decode_frame(&[1, 5, b'a']), None);
    }

    #[test]
    fn the_gateway_address_follows_the_relay_scheme() {
        let config = Config { url: "https://relay.example.com".into(), key: None, route: "abc".into() };
        assert!(config.gateway_url().starts_with("wss://relay.example.com/gateway?route="));
        assert_eq!(config.route_hash().len(), 64);
        let local = Config { url: "http://127.0.0.1:8787".into(), ..config };
        assert!(local.gateway_url().starts_with("ws://127.0.0.1:8787/gateway?route="));
        assert!(Config::new("relay.example.com", None).is_err());
        let fresh = Config::new("https://relay.example.com/", None).unwrap();
        assert_eq!(fresh.url, "https://relay.example.com");
        assert_eq!(decode_key(&fresh.route).map(|k| k.len()), Some(32));
    }

    /// The other end of the tunnel: what the app does, with the snow initiator.
    type PhoneSocket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

    struct Phone {
        socket: PhoneSocket,
        transport: snow::TransportState,
        opener: Opener,
    }

    /// How a phone stream ended: its close code.
    type Closed = u16;

    impl Phone {
        async fn connect(port: u16, route: &str, gateway: &[u8; 32], keys: &Keypair, psk: &[u8; 32]) -> Result<Self, Closed> {
            let (mut socket, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/c/{route}")).await.map_err(|_| 0u16)?;
            let mut handshake = noise::initiator(&keys.private, gateway, psk).unwrap();
            let mut buffer = vec![0u8; noise::MAX_MESSAGE];
            let n = handshake.write_message(&[], &mut buffer).unwrap();
            socket.send(Message::Binary(buffer[..n].to_vec().into())).await.unwrap();
            let reply = match next(&mut socket).await {
                Ok(reply) => reply,
                Err(code) => return Err(code),
            };
            handshake.read_message(&reply, &mut buffer).map_err(|_| 1u16)?;
            Ok(Self { socket, transport: handshake.into_transport_mode().unwrap(), opener: Opener::default() })
        }

        async fn send(&mut self, binary: bool, payload: &[u8]) {
            for message in noise::seal(&mut self.transport, binary, payload).unwrap() {
                self.socket.send(Message::Binary(message.into())).await.unwrap();
            }
        }

        async fn recv(&mut self) -> Result<(bool, Vec<u8>), Closed> {
            loop {
                let message = next(&mut self.socket).await?;
                if let Some(whole) = self.opener.open(&mut self.transport, &message).unwrap() {
                    return Ok(whole);
                }
            }
        }

        async fn text(&mut self) -> Result<serde_json::Value, Closed> {
            let (binary, text) = self.recv().await?;
            assert!(!binary);
            Ok(serde_json::from_slice(&text).unwrap())
        }
    }

    async fn next(socket: &mut PhoneSocket) -> Result<Vec<u8>, Closed> {
        loop {
            match tokio::time::timeout(Duration::from_secs(10), socket.next()).await.expect("the relay answers") {
                Some(Ok(Message::Binary(bytes))) => return Ok(bytes.to_vec()),
                Some(Ok(Message::Close(frame))) => return Err(frame.map_or(1005, |frame| u16::from(frame.code))),
                Some(Ok(_)) => continue,
                Some(Err(_)) | None => return Err(1006),
            }
        }
    }

    /// Echoes every message back, after saying which device it serves.
    async fn echo(Extension(RelayDevice(device)): Extension<RelayDevice>, ws: axum::extract::ws::WebSocketUpgrade) -> axum::response::Response {
        use axum::extract::ws::Message as Ws;
        ws.on_upgrade(move |mut socket| async move {
            let _ = socket.send(Ws::Text(format!("{{\"device\":\"{device}\"}}").into())).await;
            while let Some(Ok(message)) = socket.recv().await {
                match message {
                    Ws::Text(_) | Ws::Binary(_) => {
                        if socket.send(message).await.is_err() {
                            break;
                        }
                    }
                    Ws::Close(_) => break,
                    _ => {}
                }
            }
            let _ = socket.send(Ws::Close(Some(axum::extract::ws::CloseFrame { code: 4100, reason: "done".into() }))).await;
        })
    }

    /// The Node relay, if node and the relay's packages are here.
    fn node_relay(port: u16) -> Option<tokio::process::Child> {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../relay");
        if !dir.join("node_modules/ws").exists() {
            eprintln!("skipping: no relay/node_modules (npm install in relay/)");
            return None;
        }
        let child = tokio::process::Command::new("node")
            .arg("index.mjs")
            .current_dir(&dir)
            .env("PORT", port.to_string())
            .env("HOST", "127.0.0.1")
            .env("RELAY_REGISTRATION_KEY", "e2e-key")
            .env("PING_INTERVAL_S", "0")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn();
        match child {
            Ok(child) => Some(child),
            Err(_) => {
                eprintln!("skipping: no node");
                None
            }
        }
    }

    #[tokio::test]
    async fn phones_pair_and_talk_through_a_node_relay() {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let Some(_relay) = node_relay(port) else { return };
        for _ in 0..100 {
            if tokio::net::TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }

        let dir = std::env::temp_dir().join(format!("yochi-relay-e2e-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let store = Arc::new(Store::open(dir.clone()).unwrap());
        let config = Config::new(&format!("http://127.0.0.1:{port}"), Some("e2e-key".into())).unwrap();
        config.save(&dir).unwrap();
        let gateway = store.gateway_key().unwrap();
        let devices = Arc::new(watch::Sender::new(store.devices().unwrap()));
        let router = Router::new().route("/v0/echo", axum::routing::get(echo));
        let relay = Arc::new(Relay { router, store: store.clone(), devices: devices.clone(), keys: store.gateway_key().unwrap() });
        let client = tokio::spawn(run(relay));
        for _ in 0..100 {
            if Status::load(&dir).is_some_and(|status| status.connected) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(Status::load(&dir).is_some_and(|status| status.connected), "the Gateway registers with the relay");

        // Nobody is pairing: an unknown phone is turned away.
        let stranger = Keypair::generate().unwrap();
        let refused = Phone::connect(port, &config.route, &gateway.public, &stranger, &[0u8; 32]).await;
        assert_eq!(refused.err(), Some(UNKNOWN_DEVICE));

        // Pairing with the link secret.
        store.offer().unwrap();
        let secret = store.offer_secret().unwrap().unwrap();
        let keys = Keypair::generate().unwrap();
        let mut phone = Phone::connect(port, &config.route, &gateway.public, &keys, &secret).await.unwrap();
        phone.send(false, br#"{"path":"/v0/pair","name":"Test phone"}"#).await;
        let paired = phone.text().await.unwrap();
        assert_eq!(paired["type"], "paired");
        let device = paired["device"].as_str().unwrap().to_owned();
        let psk = decode_key(paired["psk"].as_str().unwrap()).unwrap();
        assert!(paired["token"].as_str().is_some_and(|token| token.len() == 64));
        assert_eq!(phone.recv().await.err(), Some(1000));
        assert!(store.devices().unwrap().iter().any(|d| d.id == device && d.psk_for(&keys.public) == Some(psk)));
        assert_eq!(store.offer_secret().unwrap(), None, "the link secret pairs once");

        // The same secret again: the pairing is used up.
        let again = Phone::connect(port, &config.route, &gateway.public, &Keypair::generate().unwrap(), &secret).await;
        assert_eq!(again.err(), Some(UNKNOWN_DEVICE));

        // As the paired device: an endpoint, served in process.
        let mut phone = Phone::connect(port, &config.route, &gateway.public, &keys, &psk).await.unwrap();
        phone.send(false, br#"{"path":"/v0/echo"}"#).await;
        assert_eq!(phone.text().await.unwrap()["device"], device.as_str());
        phone.send(false, b"{\"hello\":1}").await;
        assert_eq!(phone.text().await.unwrap()["hello"], 1);
        let big: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        phone.send(true, &big).await;
        assert_eq!(phone.recv().await.unwrap(), (true, big));
        phone.socket.send(Message::Close(None)).await.unwrap();

        // Its psk with someone else's key gets nowhere; nor does a wrong endpoint.
        let wrong = Phone::connect(port, &config.route, &gateway.public, &Keypair::generate().unwrap(), &psk).await;
        assert_eq!(wrong.err(), Some(UNKNOWN_DEVICE));
        let mut phone = Phone::connect(port, &config.route, &gateway.public, &keys, &psk).await.unwrap();
        phone.send(false, br#"{"path":"/v0/nothing"}"#).await;
        assert_eq!(phone.recv().await.err(), Some(4404));
        let mut phone = Phone::connect(port, &config.route, &gateway.public, &keys, &psk).await.unwrap();
        phone.send(false, br#"{"path":"/v0/pair","name":"x"}"#).await;
        assert_eq!(phone.recv().await.err(), Some(BAD_REQUEST));

        // Revoked: its key and psk no longer get through.
        store.revoke(&device).unwrap();
        devices.send_replace(store.devices().unwrap());
        let revoked = Phone::connect(port, &config.route, &gateway.public, &keys, &psk).await;
        assert_eq!(revoked.err(), Some(UNKNOWN_DEVICE));

        client.abort();
        let _ = std::fs::remove_dir_all(dir);
    }
}

