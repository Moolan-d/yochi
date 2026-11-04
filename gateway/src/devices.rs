//! Device Pairing: the phones allowed to use this Gateway, and the one pairing
//! code that may be waiting. They live in one state file shared by the running
//! server and the CLI (`pair`, `devices`, `revoke`); every change is a locked
//! read-modify-write that replaces the file atomically.

use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::fs;
use std::io::{Read as _, Write as _};
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// How long a pairing code stays valid.
pub const OFFER_TTL: Duration = Duration::from_secs(300);
/// Wrong codes allowed before the pairing is cancelled.
const OFFER_ATTEMPTS: u32 = 5;
/// Crockford base32: no I, L, O or U, so a code read aloud or retyped survives.
const CODE_ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    /// Unix seconds.
    pub paired_at: u64,
    /// The device's token stays on the device; only its hash is kept here.
    token_sha256: String,
}

impl Device {
    pub fn holds(&self, token: &str) -> bool {
        constant_time_eq(sha256(token).as_bytes(), self.token_sha256.as_bytes())
    }
}

#[derive(Serialize, Deserialize)]
struct Offer {
    code_sha256: String,
    expires_at: u64,
    attempts: u32,
}

#[derive(Default, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    devices: Vec<Device>,
    offer: Option<Offer>,
}

fn resolve_dir(home: &std::path::Path, legacy_agent: bool) -> Result<PathBuf> {
    let dir = home.join("Library/Application Support/Yochi");
    let legacy = home.join("Library/Application Support/Companion Gateway");
    if !dir.exists() && legacy.is_dir() {
        if legacy_agent {
            return Ok(legacy);
        }
        fs::rename(&legacy, &dir).with_context(|| format!("moving {} to {}", legacy.display(), dir.display()))?;
    }
    Ok(dir)
}

pub struct Store {
    dir: PathBuf,
}

impl Store {
    /// `~/Library/Application Support/Yochi`. Pairings kept under the
    /// codename's old directory move here, unless the old LaunchAgent is still
    /// installed: that Gateway keeps writing there until `service install`
    /// replaces it.
    pub fn default_dir() -> Result<PathBuf> {
        let home = PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?);
        let legacy_agent = crate::service::plist_path(crate::service::LEGACY_LABEL)?.exists();
        resolve_dir(&home, legacy_agent)
    }

    pub fn open(dir: PathBuf) -> Result<Self> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .with_context(|| format!("creating {}", dir.display()))?;
        Ok(Self { dir })
    }

    pub fn path(&self) -> PathBuf {
        self.dir.join("state.json")
    }

    pub fn devices(&self) -> Result<Vec<Device>> {
        Ok(self.read()?.devices)
    }

    /// Starts a pairing, cancelling any earlier one, and returns its code.
    pub fn offer(&self) -> Result<String> {
        let code: String = random_bytes::<8>()?.iter().map(|b| CODE_ALPHABET[usize::from(b % 32)] as char).collect();
        let offer = Offer { code_sha256: sha256(&code), expires_at: now() + OFFER_TTL.as_secs(), attempts: 0 };
        self.update(|state| state.offer = Some(offer))?;
        Ok(code)
    }

    /// Whether a pairing code is still waiting to be used.
    pub fn offer_pending(&self) -> Result<bool> {
        Ok(self.read()?.offer.is_some_and(|offer| offer.expires_at > now()))
    }

    pub fn cancel_offer(&self) -> Result<()> {
        self.update(|state| state.offer = None)
    }

    /// Trades the waiting pairing code for a new device and its token. A wrong
    /// or expired code gets `None`; too many wrong codes cancel the pairing.
    pub fn pair(&self, code: &str, name: &str) -> Result<Option<(Device, String)>> {
        let token = hex(&random_bytes::<32>()?);
        let id = hex(&random_bytes::<4>()?);
        self.update(|state| {
            let offer = state.offer.as_mut()?;
            if offer.expires_at <= now() {
                state.offer = None;
                return None;
            }
            if !constant_time_eq(sha256(&normalize_code(code)).as_bytes(), offer.code_sha256.as_bytes()) {
                offer.attempts += 1;
                if offer.attempts >= OFFER_ATTEMPTS {
                    state.offer = None;
                }
                return None;
            }
            state.offer = None;
            let device = Device { id, name: name.to_owned(), paired_at: now(), token_sha256: sha256(&token) };
            state.devices.push(device.clone());
            Some((device, token))
        })
    }

    pub fn revoke(&self, id: &str) -> Result<Option<Device>> {
        self.update(|state| {
            let index = state.devices.iter().position(|device| device.id == id)?;
            Some(state.devices.remove(index))
        })
    }

    fn read(&self) -> Result<State> {
        let path = self.path();
        let mut text = String::new();
        match fs::File::open(&path) {
            Ok(mut file) => file.read_to_string(&mut text)?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(State::default()),
            Err(err) => return Err(err).with_context(|| format!("reading {}", path.display())),
        };
        serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    fn update<T>(&self, change: impl FnOnce(&mut State) -> T) -> Result<T> {
        let lock = fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(self.dir.join("state.lock"))?;
        lock.lock()?;
        let mut state = self.read()?;
        let result = change(&mut state);
        let tmp = self.dir.join("state.json.tmp");
        let mut file = fs::OpenOptions::new().create(true).truncate(true).write(true).mode(0o600).open(&tmp)?;
        file.write_all(&serde_json::to_vec_pretty(&state)?)?;
        file.sync_all()?;
        fs::rename(&tmp, self.path())?;
        Ok(result)
    }
}

/// `abcd-efgh`, `ABCDEFGH` and `ABCD EFGH` are the same code; so are O/0 and I/L/1.
fn normalize_code(code: &str) -> String {
    code.chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            c => c,
        })
        .collect()
}

/// `ABCD-EFGH`, for people to read.
pub fn display_code(code: &str) -> String {
    let (head, tail) = code.split_at(code.len() / 2);
    format!("{head}-{tail}")
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

pub(crate) fn random_bytes<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0u8; N];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn sha256(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Store {
        let dir = std::env::temp_dir().join(format!("companion-devices-{}", hex(&random_bytes::<6>().unwrap())));
        Store::open(dir).unwrap()
    }

    #[test]
    fn pairings_move_from_the_old_directory_once_its_agent_is_gone() {
        let home = std::env::temp_dir().join(format!("companion-home-{}", hex(&random_bytes::<6>().unwrap())));
        let legacy = home.join("Library/Application Support/Companion Gateway");
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join("state.json"), "{}").unwrap();

        assert_eq!(resolve_dir(&home, true).unwrap(), legacy);
        let dir = resolve_dir(&home, false).unwrap();
        assert_eq!(dir, home.join("Library/Application Support/Yochi"));
        assert!(dir.join("state.json").exists());
        assert!(!legacy.exists());
        // Once moved, a reinstalled old agent no longer pulls it back.
        assert_eq!(resolve_dir(&home, true).unwrap(), dir);
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_code_pairs_one_device_once() {
        let store = store();
        let code = store.offer().unwrap();
        let typed = display_code(&code).to_lowercase().replace('0', "o");
        let (device, token) = store.pair(&typed, "iPhone").unwrap().expect("paired");
        assert!(device.holds(&token));
        assert!(!device.holds("other"));
        assert!(store.pair(&code, "again").unwrap().is_none());
        assert_eq!(store.devices().unwrap().len(), 1);
        assert!(!store.offer_pending().unwrap());
    }

    #[test]
    fn wrong_codes_cancel_the_pairing() {
        let store = store();
        let code = store.offer().unwrap();
        for _ in 0..OFFER_ATTEMPTS {
            assert!(store.pair("WRONG000", "x").unwrap().is_none());
        }
        assert!(store.pair(&code, "x").unwrap().is_none());
        assert!(store.devices().unwrap().is_empty());
    }

    #[test]
    fn revoked_devices_are_gone() {
        let store = store();
        let code = store.offer().unwrap();
        let (device, _) = store.pair(&code, "iPhone").unwrap().unwrap();
        assert!(store.revoke(&device.id).unwrap().is_some());
        assert!(store.revoke(&device.id).unwrap().is_none());
        assert!(store.devices().unwrap().is_empty());
    }
}
