import CryptoKit
import Foundation

/// Noise `IKpsk2` with CryptoKit, the phone's side only (ADR 0006): the app
/// knows the Gateway's static key and proves itself with its own static key
/// and a psk. Checked against vectors the Gateway's `snow` writes
/// (`Fixtures/noise/ikpsk2.json`). Framing matches `gateway/src/noise.rs`:
/// each WebSocket message is one or more Noise messages carrying
/// `[flags][payload]`, bit 0 for binary, bit 1 when more fragments follow.
enum Noise {
    static let protocolName = "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
    static let prologue = Data("yochi-relay-v1".utf8)
    static let maxMessage = 65535
    static let tagLength = 16
    static let maxChunk = maxMessage - tagLength - 1
    static let maxReassembled = 64 << 20

    enum Failure: Error {
        case badKey
        case badMessage
        case decrypt
        case tooBig
    }

    /// A transport's two directions, after the handshake.
    struct Transport {
        fileprivate var sender: CipherState
        fileprivate var receiver: CipherState
        private var buffer = Data()
        private var binary: Bool?

        fileprivate init(sender: CipherState, receiver: CipherState) {
            self.sender = sender
            self.receiver = receiver
        }

        #if DEBUG
        /// Reads what this side would send, for tests.
        mutating func swapDirectionsForTesting() {
            swap(&sender, &receiver)
        }
        #endif

        /// One WebSocket message as Noise messages.
        mutating func seal(binary: Bool, _ payload: Data) throws -> [Data] {
            var chunks = stride(from: 0, to: payload.count, by: Noise.maxChunk).map {
                payload[payload.startIndex + $0 ..< payload.startIndex + min($0 + Noise.maxChunk, payload.count)]
            }
            if chunks.isEmpty { chunks = [Data()] }
            var out: [Data] = []
            for (index, chunk) in chunks.enumerated() {
                let flags: UInt8 = (binary ? 1 : 0) | (index < chunks.count - 1 ? 2 : 0)
                out.append(try sender.encrypt(ad: Data(), Data([flags]) + chunk))
            }
            return out
        }

        /// The whole message once its last fragment is in.
        mutating func open(_ message: Data) throws -> (binary: Bool, payload: Data)? {
            let plain = try receiver.decrypt(ad: Data(), message)
            guard let flags = plain.first else { throw Failure.badMessage }
            let isBinary = flags & 1 != 0
            if let binary, binary != isBinary { throw Failure.badMessage }
            binary = isBinary
            guard buffer.count + plain.count - 1 <= Noise.maxReassembled else { throw Failure.tooBig }
            buffer.append(plain.dropFirst())
            if flags & 2 != 0 { return nil }
            defer {
                buffer = Data()
                binary = nil
            }
            return (isBinary, buffer)
        }
    }

    /// The phone's handshake: `-> e, es, s, ss` then `<- e, ee, se, psk`.
    struct Initiator {
        private var symmetric = SymmetricState()
        private let staticKey: Curve25519.KeyAgreement.PrivateKey
        private let ephemeral: Curve25519.KeyAgreement.PrivateKey
        private let remoteStatic: Curve25519.KeyAgreement.PublicKey
        private let psk: Data

        init(staticKey: Curve25519.KeyAgreement.PrivateKey, gateway: Data, psk: Data,
             ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws {
            guard psk.count == 32, let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: gateway) else {
                throw Failure.badKey
            }
            self.staticKey = staticKey
            self.ephemeral = ephemeral
            self.remoteStatic = remote
            self.psk = psk
            symmetric.mixHash(Noise.prologue)
            symmetric.mixHash(gateway)
        }

        mutating func writeFirst(payload: Data = Data()) throws -> Data {
            let e = ephemeral.publicKey.rawRepresentation
            symmetric.mixHash(e)
            symmetric.mixKey(e) // psk handshakes mix `e` into the key as well
            symmetric.mixKey(try dh(ephemeral, remoteStatic))
            let s = try symmetric.encryptAndHash(staticKey.publicKey.rawRepresentation)
            symmetric.mixKey(try dh(staticKey, remoteStatic))
            return e + s + (try symmetric.encryptAndHash(payload))
        }

        /// Reads the Gateway's reply; a wrong psk fails here.
        mutating func readSecond(_ message: Data) throws -> (transport: Transport, payload: Data) {
            guard message.count >= 32 + Noise.tagLength,
                  let re = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.prefix(32)) else {
                throw Failure.badMessage
            }
            symmetric.mixHash(re.rawRepresentation)
            symmetric.mixKey(re.rawRepresentation)
            symmetric.mixKey(try dh(ephemeral, re))
            symmetric.mixKey(try dh(staticKey, re))
            symmetric.mixKeyAndHash(psk)
            let payload = try symmetric.decryptAndHash(message.dropFirst(32))
            let (send, receive) = symmetric.split()
            return (Transport(sender: send, receiver: receive), payload)
        }

        private func dh(_ key: Curve25519.KeyAgreement.PrivateKey, _ remote: Curve25519.KeyAgreement.PublicKey) throws -> Data {
            try key.sharedSecretFromKeyAgreement(with: remote).withUnsafeBytes { Data($0) }
        }
    }
}

fileprivate struct CipherState {
    var key: SymmetricKey?
    var nonce: UInt64 = 0

    private var chachaNonce: ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: nonce.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    mutating func encrypt(ad: Data, _ plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: chachaNonce, authenticating: ad)
        nonce += 1
        return box.ciphertext + box.tag
    }

    mutating func decrypt(ad: Data, _ ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard ciphertext.count >= Noise.tagLength else { throw Noise.Failure.decrypt }
        let box = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ciphertext.dropLast(Noise.tagLength),
                                           tag: ciphertext.suffix(Noise.tagLength))
        guard let plain = try? ChaChaPoly.open(box, using: key, authenticating: ad) else { throw Noise.Failure.decrypt }
        nonce += 1
        return plain
    }
}

fileprivate struct SymmetricState {
    var ck: Data
    var h: Data
    var cipher = CipherState()

    init() {
        // A name longer than the hash is hashed; this one is 36 bytes.
        h = Data(SHA256.hash(data: Data(Noise.protocolName.utf8)))
        ck = h
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    mutating func mixKey(_ ikm: Data) {
        let out = Self.hkdf(ck, ikm, count: 2)
        ck = out[0]
        cipher = CipherState(key: SymmetricKey(data: out[1]))
    }

    mutating func mixKeyAndHash(_ ikm: Data) {
        let out = Self.hkdf(ck, ikm, count: 3)
        ck = out[0]
        mixHash(out[1])
        cipher = CipherState(key: SymmetricKey(data: out[2]))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: h, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: h, Data(ciphertext))
        mixHash(Data(ciphertext))
        return plaintext
    }

    /// (initiator → responder, responder → initiator)
    func split() -> (CipherState, CipherState) {
        let out = Self.hkdf(ck, Data(), count: 2)
        return (CipherState(key: SymmetricKey(data: out[0])), CipherState(key: SymmetricKey(data: out[1])))
    }

    /// Noise's HKDF: HMAC-SHA256 with the chaining key, 2 or 3 outputs.
    static func hkdf(_ chainingKey: Data, _ ikm: Data, count: Int) -> [Data] {
        let temp = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: chainingKey))))
        var outputs: [Data] = []
        var previous = Data()
        for index in 1 ... count {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous + [UInt8(index)], using: temp))
            outputs.append(previous)
        }
        return outputs
    }
}
