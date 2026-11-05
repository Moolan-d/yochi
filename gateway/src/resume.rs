//! Terminal streams that outlive their connection. A phone that drops off
//! (network change, app suspended) comes back with the stream's latest token
//! and the number of bytes it has, and the stream goes on from the next byte
//! instead of attaching afresh; a takeover keeps its size meanwhile.

use anyhow::Result;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

/// How long a stream waits for its phone to come back.
pub const KEEP: Duration = Duration::from_secs(30);
/// The most recent output kept for a resume. Past this the phone attaches afresh.
const REPLAY_MAX: usize = 4 << 20;

/// The stream's bytes so far, numbered from 0 at attaching; the latest
/// `REPLAY_MAX` are kept so a phone can pick up from where it left off.
#[derive(Default)]
pub struct Replay {
    /// The number of the first byte kept.
    start: u64,
    bytes: VecDeque<u8>,
}

impl Replay {
    pub fn push(&mut self, data: &[u8]) {
        self.bytes.extend(data);
        let over = self.bytes.len().saturating_sub(REPLAY_MAX);
        if over > 0 {
            self.bytes.drain(..over);
            self.start += over as u64;
        }
    }

    /// The number of bytes the stream has carried.
    pub fn end(&self) -> u64 {
        self.start + self.bytes.len() as u64
    }

    /// The bytes from `offset` on, if they are all still kept. None when the
    /// phone counts more than was sent, or the bytes it lacks are gone.
    pub fn since(&self, offset: u64) -> Option<Vec<u8>> {
        if offset < self.start || offset > self.end() {
            return None;
        }
        Some(self.bytes.range((offset - self.start) as usize..).copied().collect())
    }
}

/// Live and waiting streams by their current token, so a phone's resume
/// reaches the stream it left. Each token works for one device and session.
pub struct Registry<C> {
    slots: Arc<Mutex<HashMap<String, Slot<C>>>>,
}

impl<C> Clone for Registry<C> {
    fn clone(&self) -> Self {
        Self { slots: self.slots.clone() }
    }
}

impl<C> Default for Registry<C> {
    fn default() -> Self {
        Self { slots: Arc::default() }
    }
}

struct Slot<C> {
    device: String,
    session: String,
    claims: mpsc::Sender<C>,
}

impl<C> Registry<C> {
    /// A new token for a stream, retiring its `old` one: each connection gets
    /// its own, so a token that resumed once can't resume again.
    pub fn register(&self, old: Option<&str>, device: &str, session: &str, claims: mpsc::Sender<C>) -> Result<String> {
        let token = crate::devices::hex(&crate::devices::random_bytes::<16>()?);
        let mut slots = self.slots.lock().unwrap();
        if let Some(old) = old {
            slots.remove(old);
        }
        slots.insert(token.clone(), Slot { device: device.to_owned(), session: session.to_owned(), claims });
        Ok(token)
    }

    pub fn remove(&self, token: &str) {
        self.slots.lock().unwrap().remove(token);
    }

    /// Where to send a resume for `token`, if `device` holds it for `session`.
    pub fn find(&self, token: &str, device: &str, session: &str) -> Option<mpsc::Sender<C>> {
        let slots = self.slots.lock().unwrap();
        let slot = slots.get(token)?;
        (slot.device == device && slot.session == session).then(|| slot.claims.clone())
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.slots.lock().unwrap().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_gives_what_the_phone_lacks() {
        let mut replay = Replay::default();
        replay.push(b"hello ");
        replay.push(b"world");
        assert_eq!(replay.end(), 11);
        assert_eq!(replay.since(6).unwrap(), b"world");
        assert_eq!(replay.since(11).unwrap(), b"");
        assert_eq!(replay.since(0).unwrap(), b"hello world");
        assert!(replay.since(12).is_none(), "counted more than was sent");
    }

    #[test]
    fn replay_forgets_the_oldest() {
        let mut replay = Replay::default();
        replay.push(&vec![b'a'; REPLAY_MAX]);
        replay.push(b"bc");
        assert_eq!(replay.end(), REPLAY_MAX as u64 + 2);
        assert!(replay.since(1).is_none(), "the first bytes are gone");
        assert_eq!(replay.since(REPLAY_MAX as u64).unwrap(), b"bc");
        assert_eq!(replay.since(2).unwrap().len(), REPLAY_MAX);
    }

    #[test]
    fn tokens_name_one_device_and_session_and_turn_over() {
        let registry = Registry::<()>::default();
        let (claims, _rx) = mpsc::channel(1);
        let first = registry.register(None, "d1", "t1", claims.clone()).unwrap();
        assert_eq!(first.len(), 32);
        assert!(registry.find(&first, "d1", "t1").is_some());
        assert!(registry.find(&first, "d2", "t1").is_none(), "another device");
        assert!(registry.find(&first, "d1", "t2").is_none(), "another session");

        let second = registry.register(Some(&first), "d1", "t1", claims).unwrap();
        assert_ne!(first, second);
        assert!(registry.find(&first, "d1", "t1").is_none(), "the old token is retired");
        assert!(registry.find(&second, "d1", "t1").is_some());
        assert_eq!(registry.len(), 1);

        registry.remove(&second);
        assert_eq!(registry.len(), 0);
    }
}
