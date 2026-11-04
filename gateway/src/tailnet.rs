//! The tailnet path: phones on the tailnet reach the Gateway directly.
//!
//! It and the Relay stand on their own: either can be on without the other
//! (ADR 0006). The tailnet is on unless `yochi tailnet off` turned it off; while
//! it is on, the Gateway listens at this Mac's tailnet address whenever there is
//! one, and stops listening (closing its tailnet connections) once it is off.

use anyhow::{Context as _, Result};
use axum::Router;
use std::future::Future;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::watch;

/// Where the tailnet path stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// Turned off with `yochi tailnet off`.
    Off,
    /// On, but this Mac has no tailnet address yet (Tailscale is stopped or
    /// not installed).
    Waiting,
    /// Listening here.
    At(SocketAddr),
}

fn off_marker(dir: &Path) -> PathBuf {
    dir.join("tailnet-off")
}

pub fn enabled(dir: &Path) -> bool {
    !off_marker(dir).exists()
}

/// Turns the tailnet path on or off; false when it already was.
pub fn set(dir: &Path, on: bool) -> Result<bool> {
    let marker = off_marker(dir);
    if on == !marker.exists() {
        return Ok(false);
    }
    if on {
        std::fs::remove_file(&marker).with_context(|| format!("removing {}", marker.display()))?;
    } else {
        std::fs::create_dir_all(dir)?;
        std::fs::write(&marker, "").with_context(|| format!("writing {}", marker.display()))?;
    }
    Ok(true)
}

/// How often the switch is read.
const CHECK: Duration = Duration::from_secs(1);
/// How often the address is looked up while listening, in case it moved.
const RECHECK_ADDRESS: Duration = Duration::from_secs(30);

struct Listening {
    /// The address asked for, which may name port 0.
    asked: SocketAddr,
    stop: tokio::sync::oneshot::Sender<()>,
}

/// Serves `app` on the tailnet for as long as the Gateway runs, following the
/// switch in `dir` and the address `resolve` finds. Only a failure to listen
/// at the start that waiting won't fix (the port is taken) is an error.
pub async fn run<F, Fut>(dir: PathBuf, mut resolve: F, app: Router, state: watch::Sender<State>, every: Duration) -> Result<()>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<SocketAddr>>,
{
    let mut listening: Option<Listening> = None;
    let mut looked_up: Option<Instant> = None;
    let mut first = true;
    let mut said = String::new();
    let mut say = |text: String| {
        if text != said {
            eprintln!("{text}");
            said = text;
        }
    };
    loop {
        if !enabled(&dir) {
            if let Some(current) = listening.take() {
                let _ = current.stop.send(());
            }
            state.send_if_modified(|state| std::mem::replace(state, State::Off) != State::Off);
            say("Tailnet off (`yochi tailnet on` turns it back on); phones reach this Gateway only through a relay.".into());
            looked_up = None;
        } else if listening.is_none() || looked_up.is_none_or(|at| at.elapsed() >= RECHECK_ADDRESS) {
            looked_up = Some(Instant::now());
            match resolve().await {
                // Tailscale stopping for a moment doesn't close the listener.
                Err(err) if listening.is_none() => {
                    state.send_if_modified(|state| std::mem::replace(state, State::Waiting) != State::Waiting);
                    say(format!(
                        "Not on the tailnet ({err:#}); until it is, phones reach this Gateway only through a relay. Looking again every {} s.",
                        every.as_secs()
                    ));
                }
                Err(_) => {}
                Ok(asked) if listening.as_ref().is_some_and(|current| current.asked == asked) => {}
                Ok(asked) => {
                    if let Some(current) = listening.take() {
                        let _ = current.stop.send(());
                    }
                    match tokio::net::TcpListener::bind(asked).await {
                        Ok(listener) => {
                            let at = listener.local_addr()?;
                            let (stop, stopped) = tokio::sync::oneshot::channel();
                            let app = app.clone();
                            tokio::spawn(async move {
                                let serving = axum::serve(listener, app).with_graceful_shutdown(async {
                                    let _ = stopped.await;
                                });
                                if let Err(err) = serving.await {
                                    eprintln!("tailnet: {err:#}");
                                }
                            });
                            listening = Some(Listening { asked, stop });
                            state.send_replace(State::At(at));
                            say(format!("Gateway listening on ws://{at}/v0/ws"));
                        }
                        Err(err) if err.kind() == std::io::ErrorKind::AddrNotAvailable => {
                            state.send_if_modified(|state| std::mem::replace(state, State::Waiting) != State::Waiting);
                            say(format!(
                                "Not on the tailnet ({asked} isn't this Mac's yet); until it is, phones reach this Gateway only through a relay. Looking again every {} s.",
                                every.as_secs()
                            ));
                            looked_up = None;
                        }
                        Err(err) if first => return Err(err).with_context(|| format!("listening on {asked}")),
                        Err(err) => {
                            state.send_if_modified(|state| std::mem::replace(state, State::Waiting) != State::Waiting);
                            say(format!("listening on {asked}: {err}; trying again every {} s.", every.as_secs()));
                            looked_up = None;
                        }
                    }
                }
            }
        }
        first = false;
        // Waiting for an address is slower than reading the switch.
        let pause = if listening.is_none() && enabled(&dir) { every } else { CHECK.min(every) };
        tokio::time::sleep(pause).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::routing::get;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("yochi-tailnet-{}", crate::devices::hex(&crate::devices::random_bytes::<6>().unwrap())));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    async fn until(state: &mut watch::Receiver<State>, want: impl Fn(&State) -> bool) -> State {
        *tokio::time::timeout(Duration::from_secs(5), state.wait_for(want)).await.expect("state never came").unwrap()
    }

    async fn answers(at: SocketAddr) -> bool {
        tokio::net::TcpStream::connect(at).await.is_ok()
    }

    #[test]
    fn the_switch_is_on_until_turned_off() {
        let dir = TempDir::new();
        assert!(enabled(&dir.0));
        assert!(set(&dir.0, false).unwrap());
        assert!(!set(&dir.0, false).unwrap());
        assert!(!enabled(&dir.0));
        assert!(set(&dir.0, true).unwrap());
        assert!(enabled(&dir.0));
    }

    #[tokio::test]
    async fn the_listener_follows_the_switch_and_the_address() {
        let dir = TempDir::new();
        let app = Router::new().route("/", get(|| async { "ok" }));
        let (sender, mut state) = watch::channel(State::Waiting);
        // 192.0.2.1 (TEST-NET-1) isn't on this machine, like the tailnet
        // address while Tailscale is down; then the address appears.
        let mut tries = 0;
        let resolve = move || {
            tries += 1;
            let ip = if tries < 3 { "192.0.2.1" } else { "127.0.0.1" };
            std::future::ready(Ok(SocketAddr::new(ip.parse().unwrap(), 0)))
        };
        let running = tokio::spawn(run(dir.0.clone(), resolve, app, sender, Duration::from_millis(20)));

        let State::At(at) = until(&mut state, |s| matches!(s, State::At(_))).await else { unreachable!() };
        assert!(at.ip().is_loopback());
        assert!(answers(at).await);

        set(&dir.0, false).unwrap();
        until(&mut state, |s| *s == State::Off).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!answers(at).await, "still listening with the tailnet off");

        set(&dir.0, true).unwrap();
        let State::At(again) = until(&mut state, |s| matches!(s, State::At(_))).await else { unreachable!() };
        assert!(answers(again).await);
        running.abort();
    }

    #[tokio::test]
    async fn a_taken_port_at_the_start_is_an_error_not_a_wait() {
        let dir = TempDir::new();
        let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = taken.local_addr().unwrap();
        let (sender, _state) = watch::channel(State::Waiting);
        let ran = tokio::time::timeout(
            Duration::from_secs(1),
            run(dir.0.clone(), move || std::future::ready(Ok(addr)), Router::new(), sender, Duration::from_millis(20)),
        )
        .await
        .expect("kept waiting");
        assert!(ran.is_err());
    }
}
