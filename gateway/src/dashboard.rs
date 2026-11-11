//! `yochi dashboard`: a page in the browser that shows how the Gateway stands
//! and drives it. It is a process of its own, started when wanted, so it
//! costs nothing while closed and still opens when the Gateway is stopped.
//!
//! It listens on 127.0.0.1 only. Every `/api` request must carry the token
//! the page got in its link's fragment and name this server in `Host`, so
//! another page in the browser, or a name rebound to 127.0.0.1, can neither
//! read the status nor pair a phone.

use crate::devices::{self, Store};
use crate::{lang, notify, relay, service, tailnet};
use anyhow::{Context as _, Result};
use axum::extract::{Path as UrlPath, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{Html, IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The LaunchAgent `ios/scripts/renew-device.sh --enable` adds.
const RENEW_LABEL: &str = "dev.yochi.renew";
/// With no request for this long the page is closed, and the dashboard exits.
const IDLE: Duration = Duration::from_secs(10 * 60);

const PAGE: &str = include_str!("dashboard.html");

pub struct Options {
    pub port: u16,
    pub open: bool,
    pub label: String,
    pub listen: Option<SocketAddr>,
}

struct Dashboard {
    store: Store,
    label: String,
    listen: Option<SocketAddr>,
    token: String,
    /// `127.0.0.1:<port>` and `localhost:<port>`: what `Host` may say.
    hosts: [String; 2],
    pairing: Mutex<Option<Pairing>>,
    /// The device the last pairing added, until the next one starts.
    paired: Mutex<Option<String>>,
    last_request: AtomicU64,
}

/// A pairing this dashboard started, shown until it ends.
struct Pairing {
    before: HashSet<String>,
    shown: Value,
}

pub async fn run(store: Store, options: Options) -> Result<()> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", options.port))
        .await
        .with_context(|| format!("listening on 127.0.0.1:{}", options.port))?;
    let port = listener.local_addr()?.port();
    let token = hex(&devices::random_bytes::<24>()?);
    let dashboard = Arc::new(Dashboard {
        store,
        label: options.label,
        listen: options.listen,
        token: token.clone(),
        hosts: [format!("127.0.0.1:{port}"), format!("localhost:{port}")],
        pairing: Mutex::new(None),
        paired: Mutex::new(None),
        last_request: AtomicU64::new(devices::now()),
    });
    // In the fragment, the token reaches neither a server's log nor a Referer.
    let url = format!("http://127.0.0.1:{port}/#{token}");
    println!("Dashboard  {url}");
    println!("Ctrl-C stops it; it also stops by itself ten minutes after its page closes.");
    if options.open {
        let _ = std::process::Command::new("/usr/bin/open").arg(&url).status();
    }
    let idle = {
        let dashboard = dashboard.clone();
        async move {
            loop {
                tokio::time::sleep(Duration::from_secs(30)).await;
                if devices::now().saturating_sub(dashboard.last_request.load(Ordering::Relaxed)) > IDLE.as_secs() {
                    println!("No page has asked for ten minutes; stopping.");
                    return;
                }
            }
        }
    };
    let ending = dashboard.clone();
    let served = axum::serve(listener, router(dashboard)).with_graceful_shutdown(async move {
        tokio::select! {
            _ = idle => {}
            _ = tokio::signal::ctrl_c() => {}
        }
    });
    let result = served.await;
    // A code nobody is shown any more should not stay valid.
    if ending.pairing.lock().unwrap().is_some() {
        let _ = ending.store.cancel_offer();
    }
    Ok(result?)
}

fn router(dashboard: Arc<Dashboard>) -> Router {
    let api = Router::new()
        .route("/status", get(status))
        .route("/pair", post(pair).delete(cancel_pairing))
        .route("/devices/{id}/revoke", post(revoke))
        .route("/service/{action}", post(service_action))
        .route("/push/test", post(push_test))
        .route("/renew", post(renew))
        .layer(middleware::from_fn_with_state(dashboard.clone(), authorize));
    Router::new()
        .route("/", get(page))
        .nest("/api", api)
        .layer(middleware::from_fn_with_state(dashboard.clone(), local_only))
        .with_state(dashboard)
}

/// Whether `Host` names this server, as it does unless a page elsewhere had
/// its own name resolve to 127.0.0.1.
fn names_this_server(dashboard: &Dashboard, headers: &HeaderMap) -> bool {
    headers.get(header::HOST).and_then(|host| host.to_str().ok()).is_some_and(|host| dashboard.hosts.iter().any(|own| own == host))
}

fn holds_token(dashboard: &Dashboard, headers: &HeaderMap) -> bool {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|token| devices::constant_time_eq(token.as_bytes(), dashboard.token.as_bytes()))
}

async fn local_only(State(dashboard): State<Arc<Dashboard>>, request: Request, next: Next) -> Response {
    if !names_this_server(&dashboard, request.headers()) {
        return StatusCode::FORBIDDEN.into_response();
    }
    next.run(request).await
}

async fn authorize(State(dashboard): State<Arc<Dashboard>>, request: Request, next: Next) -> Response {
    if !holds_token(&dashboard, request.headers()) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    dashboard.last_request.store(devices::now(), Ordering::Relaxed);
    next.run(request).await
}

async fn page() -> impl IntoResponse {
    // The page holds no secret; what it shows comes from /api with the token.
    ([(header::CACHE_CONTROL, "no-store"), (header::REFERRER_POLICY, "no-referrer")], Html(PAGE))
}

/// A failed action, said in the page as it would be in the terminal.
struct Failed(anyhow::Error);

impl<E: Into<anyhow::Error>> From<E> for Failed {
    fn from(error: E) -> Self {
        Self(error.into())
    }
}

impl IntoResponse for Failed {
    fn into_response(self) -> Response {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": format!("{:#}", self.0) }))).into_response()
    }
}

type Reply = Result<Json<Value>, Failed>;

async fn status(State(dashboard): State<Arc<Dashboard>>) -> Reply {
    Ok(Json(snapshot(&dashboard).await?))
}

async fn snapshot(dashboard: &Dashboard) -> Result<Value> {
    let dir = dashboard.store.dir();
    let agent = service::status(&dashboard.label)?;
    let tailnet = if tailnet::enabled(dir) {
        match crate::listen_addr(dashboard.listen).await {
            Ok(addr) => json!({ "enabled": true, "address": addr.to_string(), "listening": crate::answering(addr).await }),
            Err(error) => json!({ "enabled": true, "address": null, "listening": false, "error": format!("{error:#}") }),
        }
    } else {
        json!({ "enabled": false, "address": null, "listening": false })
    };
    let devices = dashboard.store.devices()?;
    let relay = relay::Config::load(dir)?.map(|config| {
        let status = relay::Status::load(dir).filter(|status| status.url == config.url);
        let connected = crate::relay_connected(dir, &config);
        json!({
            "url": config.url,
            // Unknown while no running Gateway has reported lately.
            "connected": if connected { Some(true) } else { status.as_ref().filter(|status| !status.connected).map(|_| false) },
            "since": status.as_ref().filter(|_| connected).and_then(|status| status.since),
            "error": status.as_ref().filter(|status| !status.connected).and_then(|status| status.error.clone()),
            "phones": devices.iter().filter(|device| device.uses_relay()).count(),
        })
    });
    let push = notify::Config::load(dir)?.map(|config| json!({ "server": config.server, "encrypted": config.key.is_some() }));
    Ok(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "now": devices::now(),
        "service": {
            "label": dashboard.label,
            "installed": agent.plist.is_some(),
            "pid": agent.running,
            "last_exit": agent.last_exit,
            "log": service::default_log()?.display().to_string(),
        },
        "tailnet": tailnet,
        "relay": relay,
        "push": push,
        "devices": devices.iter().map(|device| json!({
            "id": device.id,
            "name": device.name,
            "paired_at": device.paired_at,
            "relay": device.uses_relay(),
        })).collect::<Vec<_>>(),
        "signing": signing(),
        "pairing": pairing(dashboard, &devices)?,
        "paired": dashboard.paired.lock().unwrap().clone(),
    }))
}

/// The pairing in progress, ended here once a phone took it or it ran out.
fn pairing(dashboard: &Dashboard, devices: &[devices::Device]) -> Result<Option<Value>> {
    let mut pairing = dashboard.pairing.lock().unwrap();
    let Some(current) = pairing.as_ref() else { return Ok(None) };
    if let Some(device) = devices.iter().find(|device| !current.before.contains(&device.id)) {
        *dashboard.paired.lock().unwrap() = Some(device.name.clone());
        *pairing = None;
    } else if !dashboard.store.offer_pending()? {
        *pairing = None;
    }
    Ok(pairing.as_ref().map(|current| current.shown.clone()))
}

/// How the app that `ios/scripts/install-device.sh` put on the iPhone is
/// signed, on a Mac where that script has run; `null` elsewhere.
fn signing() -> Option<Value> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let until = std::fs::read_to_string(home.join("Library/Caches/dev.yochi/installed-until")).ok();
    let renewal = service::status(RENEW_LABEL).ok().is_some_and(|agent| agent.plist.is_some());
    if until.is_none() && !renewal {
        return None;
    }
    let last = std::fs::read_to_string(home.join("Library/Logs/yochi-renew.log"))
        .ok()
        .and_then(|log| log.lines().rev().find(|line| line.starts_with("20")).map(str::to_owned));
    Some(json!({ "until": until.map(|until| until.trim().to_owned()), "renewal": renewal, "last": last }))
}

async fn pair(State(dashboard): State<Arc<Dashboard>>) -> Reply {
    let store = &dashboard.store;
    let host = if tailnet::enabled(store.dir()) { crate::listen_addr(dashboard.listen).await.ok() } else { None };
    let before = store.devices()?.into_iter().map(|device| device.id).collect();
    let code = store.offer()?;
    let link = match crate::invite(store, host, &code) {
        Ok(link) => link,
        Err(error) => {
            store.cancel_offer()?;
            return Err(error.into());
        }
    };
    let shown = json!({
        "qr": qr_svg(&link)?,
        "address": host.map(|host| host.to_string()),
        "code": devices::display_code(&code),
        "expires_at": devices::now() + devices::OFFER_TTL.as_secs(),
    });
    *dashboard.paired.lock().unwrap() = None;
    *dashboard.pairing.lock().unwrap() = Some(Pairing { before, shown: shown.clone() });
    Ok(Json(shown))
}

async fn cancel_pairing(State(dashboard): State<Arc<Dashboard>>) -> Reply {
    if dashboard.pairing.lock().unwrap().take().is_some() {
        dashboard.store.cancel_offer()?;
    }
    Ok(Json(json!({})))
}

async fn revoke(State(dashboard): State<Arc<Dashboard>>, UrlPath(id): UrlPath<String>) -> Reply {
    match dashboard.store.revoke(&id)? {
        Some(device) => Ok(Json(json!({ "id": device.id, "name": device.name }))),
        None => Err(anyhow::anyhow!("no paired device {id:?}").into()),
    }
}

async fn service_action(State(dashboard): State<Arc<Dashboard>>, UrlPath(action): UrlPath<String>) -> Reply {
    let label = dashboard.label.clone();
    // launchctl waits for the old process; keep that off the async threads.
    tokio::task::spawn_blocking(move || match action.as_str() {
        "start" => service::start(&label),
        "stop" => service::stop(&label),
        "restart" => service::restart(&label),
        _ => Err(anyhow::anyhow!("unknown action {action:?}")),
    })
    .await??;
    Ok(Json(json!({})))
}

async fn push_test(State(dashboard): State<Arc<Dashboard>>) -> Reply {
    let config = notify::Config::load(dashboard.store.dir())?.context("notifications are off; `yochi push bark <key>` turns them on")?;
    let lang = lang::Lang::from_tag(std::env::var("LANG").ok().as_deref());
    notify::send(&config, notify::test_message(lang), None).await?;
    Ok(Json(json!({})))
}

/// Runs the daily renewal's check now. It reinstalls the app, which quits it
/// on the iPhone, only when the signing has under three days left.
async fn renew() -> Reply {
    tokio::task::spawn_blocking(|| service::restart(RENEW_LABEL)).await?.context("the daily renewal is off; `ios/scripts/renew-device.sh --enable` turns it on")?;
    Ok(Json(json!({})))
}

/// The pairing link as an SVG QR code, dark on white with a quiet zone.
fn qr_svg(text: &str) -> Result<String> {
    let code = qrcode::QrCode::new(text.as_bytes())?;
    let width = code.width();
    let quiet = 4;
    let size = width + 2 * quiet;
    let mut path = String::new();
    for (i, color) in code.to_colors().into_iter().enumerate() {
        if color == qrcode::Color::Dark {
            path.push_str(&format!("M{} {}h1v1h-1z", i % width + quiet, i / width + quiet));
        }
    }
    Ok(format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" shape-rendering="crispEdges"><rect width="{size}" height="{size}" fill="#fff"/><path d="{path}" fill="#000"/></svg>"##
    ))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn dashboard(name: &str) -> (Arc<Dashboard>, PathBuf) {
        let dir = std::env::temp_dir().join(format!("yochi-dashboard-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dashboard = Dashboard {
            store: Store::open(dir.clone()).unwrap(),
            label: "dev.yochi.dashboard-test".into(),
            listen: Some("100.64.0.1:7420".parse().unwrap()),
            token: "secret".into(),
            hosts: ["127.0.0.1:4000".into(), "localhost:4000".into()],
            pairing: Mutex::new(None),
            paired: Mutex::new(None),
            last_request: AtomicU64::new(0),
        };
        (Arc::new(dashboard), dir)
    }

    fn headers(pairs: &[(header::HeaderName, &str)]) -> HeaderMap {
        pairs.iter().map(|(name, value)| (name.clone(), HeaderValue::from_str(value).unwrap())).collect()
    }

    #[test]
    fn only_this_server_s_own_page_gets_in() {
        let (dashboard, dir) = dashboard("auth");
        std::fs::remove_dir_all(dir).unwrap();
        assert!(names_this_server(&dashboard, &headers(&[(header::HOST, "127.0.0.1:4000")])));
        assert!(names_this_server(&dashboard, &headers(&[(header::HOST, "localhost:4000")])));
        assert!(!names_this_server(&dashboard, &headers(&[(header::HOST, "evil.example:4000")])), "a rebound name");
        assert!(!names_this_server(&dashboard, &headers(&[(header::HOST, "127.0.0.1:4001")])));
        assert!(!names_this_server(&dashboard, &headers(&[])));

        assert!(holds_token(&dashboard, &headers(&[(header::AUTHORIZATION, "Bearer secret")])));
        assert!(!holds_token(&dashboard, &headers(&[(header::AUTHORIZATION, "Bearer other")])));
        assert!(!holds_token(&dashboard, &headers(&[(header::AUTHORIZATION, "secret")])));
        assert!(!holds_token(&dashboard, &headers(&[])));
    }

    #[tokio::test]
    async fn a_pairing_shows_until_a_phone_takes_it() {
        let (dashboard, dir) = dashboard("pair");
        let Json(shown) = pair(State(dashboard.clone())).await.ok().unwrap();
        assert!(shown["qr"].as_str().unwrap().starts_with("<svg"));
        assert_eq!(shown["address"], "100.64.0.1:7420");
        let code = shown["code"].as_str().unwrap().replace(['-', ' '], "");

        let status = snapshot(&dashboard).await.unwrap();
        assert_eq!(status["pairing"]["code"], shown["code"]);
        assert_eq!(status["paired"], Value::Null);
        assert_eq!(status["devices"], json!([]));
        assert_eq!(status["service"]["installed"], false);

        let (device, _) = dashboard.store.pair(&code, "iPhone").unwrap().expect("the code pairs");
        let status = snapshot(&dashboard).await.unwrap();
        assert_eq!(status["pairing"], Value::Null);
        assert_eq!(status["paired"], "iPhone");
        assert_eq!(status["devices"][0]["id"], device.id.as_str());

        let Json(revoked) = revoke(State(dashboard.clone()), UrlPath(device.id.clone())).await.ok().unwrap();
        assert_eq!(revoked["name"], "iPhone");
        assert!(revoke(State(dashboard.clone()), UrlPath(device.id)).await.is_err(), "already unpaired");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn cancelling_takes_the_code_back() {
        let (dashboard, dir) = dashboard("cancel");
        let _ = pair(State(dashboard.clone())).await.ok().unwrap();
        assert!(dashboard.store.offer_pending().unwrap());
        let _ = cancel_pairing(State(dashboard.clone())).await.ok().unwrap();
        assert!(!dashboard.store.offer_pending().unwrap());
        assert_eq!(snapshot(&dashboard).await.unwrap()["pairing"], Value::Null);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_qr_code_is_a_square_with_a_quiet_zone() {
        let svg = qr_svg("yochi://pair?host=100.64.0.1:7420&code=ABCDEFGH").unwrap();
        let size: usize = svg.split("viewBox=\"0 0 ").nth(1).unwrap().split(' ').next().unwrap().parse().unwrap();
        assert!(size >= 21 + 8);
        assert!(svg.contains(&format!("width=\"{size}\" height=\"{size}\" fill=\"#fff\"")));
        assert!(!svg.contains("M0 "), "nothing dark in the quiet zone");
    }
}
