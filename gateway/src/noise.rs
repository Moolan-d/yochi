//! Noise `IKpsk2` between the app and this Gateway over the Relay (ADR 0006).
//!
//! The phone (initiator) knows the Gateway's static key from pairing; the
//! Gateway (responder) reads the first handshake message, learns the phone's
//! static key, and only then picks the psk: that device's own, or the waiting
//! pairing's link secret for a phone that is pairing. After the handshake each
//! WebSocket message travels as one or more Noise messages, each carrying
//! `[flags][payload]`: bit 0 set for binary, bit 1 set when more fragments of
//! the same message follow.

use anyhow::{Context as _, Result, bail};
use snow::{Builder, HandshakeState, TransportState};

pub const PARAMS: &str = "Noise_IKpsk2_25519_ChaChaPoly_SHA256";
/// Binds both sides to this use of the pattern.
pub const PROLOGUE: &[u8] = b"yochi-relay-v1";
/// The psk goes in at the end of the second handshake message.
pub const PSK_SLOT: usize = 2;
/// Largest Noise message.
pub const MAX_MESSAGE: usize = 65535;
const TAG: usize = 16;
/// Payload bytes one Noise message carries after its flags byte.
pub const MAX_CHUNK: usize = MAX_MESSAGE - TAG - 1;
/// Largest WebSocket message reassembled from fragments.
pub const MAX_REASSEMBLED: usize = 64 * 1024 * 1024;

const BINARY: u8 = 1;
const MORE: u8 = 2;

fn params() -> snow::params::NoiseParams {
    PARAMS.parse().expect("valid Noise parameters")
}

pub struct Keypair {
    pub private: [u8; 32],
    pub public: [u8; 32],
}

impl Keypair {
    pub fn generate() -> Result<Self> {
        let keypair = Builder::new(params()).generate_keypair()?;
        Ok(Self {
            private: keypair.private.try_into().map_err(|_| anyhow::anyhow!("bad private key"))?,
            public: keypair.public.try_into().map_err(|_| anyhow::anyhow!("bad public key"))?,
        })
    }

    /// `private ‖ public`, as kept in `gateway.key`.
    pub fn to_bytes(&self) -> [u8; 64] {
        let mut bytes = [0u8; 64];
        bytes[..32].copy_from_slice(&self.private);
        bytes[32..].copy_from_slice(&self.public);
        bytes
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != 64 {
            bail!("a Gateway key is 64 bytes, not {}", bytes.len());
        }
        Ok(Self { private: bytes[..32].try_into()?, public: bytes[32..].try_into()? })
    }
}

/// The Gateway's side, before the first message. The psk is set after it.
pub fn responder(private: &[u8; 32]) -> Result<HandshakeState> {
    Ok(Builder::new(params()).local_private_key(private)?.prologue(PROLOGUE)?.build_responder()?)
}

/// The phone's side (the app has its own; this one is for tests).
#[cfg(test)]
pub fn initiator(private: &[u8; 32], gateway: &[u8; 32], psk: &[u8; 32]) -> Result<HandshakeState> {
    Ok(Builder::new(params())
        .local_private_key(private)?
        .remote_public_key(gateway)?
        .prologue(PROLOGUE)?
        .psk(PSK_SLOT as u8, psk)?
        .build_initiator()?)
}

/// One WebSocket message as Noise messages.
pub fn seal(transport: &mut TransportState, binary: bool, payload: &[u8]) -> Result<Vec<Vec<u8>>> {
    let mut chunks: Vec<&[u8]> = payload.chunks(MAX_CHUNK).collect();
    if chunks.is_empty() {
        chunks.push(&[]);
    }
    let last = chunks.len() - 1;
    let mut plain = Vec::with_capacity(MAX_CHUNK + 1);
    let mut out = Vec::with_capacity(chunks.len());
    for (index, chunk) in chunks.into_iter().enumerate() {
        plain.clear();
        plain.push(if binary { BINARY } else { 0 } | if index < last { MORE } else { 0 });
        plain.extend_from_slice(chunk);
        let mut message = vec![0u8; plain.len() + TAG];
        let n = transport.write_message(&plain, &mut message)?;
        message.truncate(n);
        out.push(message);
    }
    Ok(out)
}

/// Puts fragments back together into WebSocket messages.
#[derive(Default)]
pub struct Opener {
    buffer: Vec<u8>,
    binary: Option<bool>,
}

impl Opener {
    /// The whole message once its last fragment is in: `(binary, payload)`.
    /// A message that fails to decrypt, or fragments that disagree, end the stream.
    pub fn open(&mut self, transport: &mut TransportState, message: &[u8]) -> Result<Option<(bool, Vec<u8>)>> {
        let mut plain = vec![0u8; message.len()];
        let n = transport.read_message(message, &mut plain).context("decrypting a Noise message")?;
        let (&flags, payload) = plain[..n].split_first().context("empty Noise message")?;
        let binary = flags & BINARY != 0;
        if *self.binary.get_or_insert(binary) != binary {
            bail!("fragments of one message disagree on its type");
        }
        if self.buffer.len() + payload.len() > MAX_REASSEMBLED {
            bail!("message over {MAX_REASSEMBLED} bytes");
        }
        self.buffer.extend_from_slice(payload);
        if flags & MORE != 0 {
            return Ok(None);
        }
        self.binary = None;
        Ok(Some((binary, std::mem::take(&mut self.buffer))))
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A finished handshake: (phone, gateway) transports.
    pub fn pair_up(psk_phone: &[u8; 32], psk_gateway: &[u8; 32]) -> Result<(TransportState, TransportState, [u8; 32])> {
        let gateway = Keypair::generate()?;
        let phone = Keypair::generate()?;
        let mut initiator = initiator(&phone.private, &gateway.public, psk_phone)?;
        let mut responder = responder(&gateway.private)?;
        let mut first = [0u8; MAX_MESSAGE];
        let n = initiator.write_message(&[], &mut first)?;
        let mut scratch = [0u8; MAX_MESSAGE];
        responder.read_message(&first[..n], &mut scratch)?;
        let remote: [u8; 32] = responder.get_remote_static().unwrap().try_into()?;
        responder.set_psk(PSK_SLOT, psk_gateway)?;
        let mut second = [0u8; MAX_MESSAGE];
        let n = responder.write_message(&[], &mut second)?;
        initiator.read_message(&second[..n], &mut scratch)?;
        Ok((initiator.into_transport_mode()?, responder.into_transport_mode()?, remote))
    }

    #[test]
    fn the_gateway_learns_the_phone_key_before_choosing_the_psk() {
        let psk = [3u8; 32];
        let (mut phone, mut gateway, remote) = pair_up(&psk, &psk).unwrap();
        assert_eq!(remote.len(), 32);
        let sealed = seal(&mut phone, false, b"{\"path\":\"/v0/ws\"}").unwrap();
        assert_eq!(sealed.len(), 1);
        let mut opener = Opener::default();
        assert_eq!(opener.open(&mut gateway, &sealed[0]).unwrap(), Some((false, b"{\"path\":\"/v0/ws\"}".to_vec())));
        let back = seal(&mut gateway, true, &[1, 2]).unwrap();
        assert_eq!(Opener::default().open(&mut phone, &back[0]).unwrap(), Some((true, vec![1, 2])));
    }

    #[test]
    fn a_wrong_psk_fails_the_handshake() {
        // The phone can't read the Gateway's reply, so it never sends a request.
        assert!(pair_up(&[1u8; 32], &[2u8; 32]).is_err());
    }

    #[test]
    fn large_messages_come_back_whole() {
        let psk = [9u8; 32];
        let (mut phone, mut gateway, _) = pair_up(&psk, &psk).unwrap();
        let payload: Vec<u8> = (0..MAX_CHUNK * 2 + 10).map(|i| i as u8).collect();
        let sealed = seal(&mut gateway, true, &payload).unwrap();
        assert_eq!(sealed.len(), 3);
        assert!(sealed.iter().all(|m| m.len() <= MAX_MESSAGE));
        let mut opener = Opener::default();
        assert_eq!(opener.open(&mut phone, &sealed[0]).unwrap(), None);
        assert_eq!(opener.open(&mut phone, &sealed[1]).unwrap(), None);
        assert_eq!(opener.open(&mut phone, &sealed[2]).unwrap(), Some((true, payload)));
        let empty = seal(&mut gateway, false, &[]).unwrap();
        assert_eq!(opener.open(&mut phone, &empty[0]).unwrap(), Some((false, vec![])));
    }

    #[test]
    fn replayed_or_reordered_messages_are_refused() {
        let psk = [4u8; 32];
        let (mut phone, mut gateway, _) = pair_up(&psk, &psk).unwrap();
        let one = seal(&mut phone, false, b"one").unwrap().remove(0);
        let two = seal(&mut phone, false, b"two").unwrap().remove(0);
        let mut opener = Opener::default();
        assert!(opener.open(&mut gateway, &two).is_err());
        let (mut phone, mut gateway, _) = pair_up(&psk, &psk).unwrap();
        let one_again = seal(&mut phone, false, b"one").unwrap().remove(0);
        assert!(opener.open(&mut gateway, &one_again).is_ok());
        assert!(opener.open(&mut gateway, &one_again).is_err());
        let _ = one;
    }

    /// Fixed-key handshake and messages the iOS Noise is checked against
    /// (`ios/YochiTests/Fixtures/noise/ikpsk2.json`). The test fails if the
    /// file is out of date; `WRITE_NOISE_VECTORS=1 cargo test` rewrites it.
    #[test]
    fn interop_vectors_for_the_app_are_current() {
        let key = |byte: u8| -> [u8; 32] { std::array::from_fn(|i| byte.wrapping_add(i as u8)) };
        let (phone_static, phone_ephemeral, gateway_static, gateway_ephemeral, psk) = (key(0x10), key(0x30), key(0x50), key(0x70), key(0x90));
        let hex = |bytes: &[u8]| -> String { bytes.iter().map(|b| format!("{b:02x}")).collect() };
        let public = |private: &[u8; 32]| curve25519_dalek::MontgomeryPoint::mul_base_clamped(*private).to_bytes();
        let gateway_public = public(&gateway_static);

        let mut initiator = Builder::new(params())
            .local_private_key(&phone_static)
            .unwrap()
            .remote_public_key(&gateway_public)
            .unwrap()
            .prologue(PROLOGUE)
            .unwrap()
            .psk(PSK_SLOT as u8, &psk)
            .unwrap()
            .fixed_ephemeral_key_for_testing_only(&phone_ephemeral)
            .build_initiator()
            .unwrap();
        let mut responder = Builder::new(params())
            .local_private_key(&gateway_static)
            .unwrap()
            .prologue(PROLOGUE)
            .unwrap()
            .fixed_ephemeral_key_for_testing_only(&gateway_ephemeral)
            .build_responder()
            .unwrap();
        let mut buffer = [0u8; MAX_MESSAGE];
        let n = initiator.write_message(&[], &mut buffer).unwrap();
        let first = buffer[..n].to_vec();
        responder.read_message(&first, &mut [0u8; MAX_MESSAGE]).unwrap();
        responder.set_psk(PSK_SLOT, &psk).unwrap();
        let n = responder.write_message(&[], &mut buffer).unwrap();
        let second = buffer[..n].to_vec();
        initiator.read_message(&second, &mut [0u8; MAX_MESSAGE]).unwrap();
        let (mut phone, mut gateway) = (initiator.into_transport_mode().unwrap(), responder.into_transport_mode().unwrap());

        let request = br#"{"path":"/v0/ws"}"#;
        let to_gateway: Vec<String> = [seal(&mut phone, false, request).unwrap(), seal(&mut phone, true, &[]).unwrap()].concat().iter().map(|m| hex(m)).collect();
        let to_phone: Vec<String> = [seal(&mut gateway, false, br#"{"type":"hello"}"#).unwrap(), seal(&mut gateway, true, &[0, 1, 2, 255]).unwrap()]
            .concat()
            .iter()
            .map(|m| hex(m))
            .collect();
        let vectors = serde_json::json!({
            "protocol": PARAMS,
            "prologue": hex(PROLOGUE),
            "psk_slot": PSK_SLOT,
            "phone_static_private": hex(&phone_static),
            "phone_static_public": hex(&public(&phone_static)),
            "phone_ephemeral_private": hex(&phone_ephemeral),
            "gateway_static_private": hex(&gateway_static),
            "gateway_static_public": hex(&gateway_public),
            "gateway_ephemeral_private": hex(&gateway_ephemeral),
            "psk": hex(&psk),
            "message_1": hex(&first),
            "message_2": hex(&second),
            "to_gateway": { "messages": to_gateway, "plain": [{ "binary": false, "text": std::str::from_utf8(request).unwrap() }, { "binary": true, "hex": "" }] },
            "to_phone": { "messages": to_phone, "plain": [{ "binary": false, "text": "{\"type\":\"hello\"}" }, { "binary": true, "hex": "000102ff" }] },
        });
        let text = serde_json::to_string_pretty(&vectors).unwrap() + "\n";
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../ios/YochiTests/Fixtures/noise/ikpsk2.json");
        if std::env::var_os("WRITE_NOISE_VECTORS").is_some() {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, &text).unwrap();
        }
        assert_eq!(std::fs::read_to_string(&path).ok().as_deref(), Some(text.as_str()), "rerun with WRITE_NOISE_VECTORS=1");
    }
}

