import CryptoKit
import Foundation
import Testing

@testable import Yochi

/// The app's Noise against what the Gateway's `snow` produced with the same
/// fixed keys (`gateway/src/noise.rs` writes `Fixtures/noise/ikpsk2.json`).
struct NoiseTests {
    private struct Vectors: Decodable {
        struct Direction: Decodable {
            struct Plain: Decodable {
                let binary: Bool
                let text: String?
                let hex: String?
                var data: Data { text.map { Data($0.utf8) } ?? Data(hex: hex ?? "") }
            }

            let messages: [String]
            let plain: [Plain]
        }

        let protocol_: String
        let prologue: String
        let phone_static_private: String
        let phone_static_public: String
        let phone_ephemeral_private: String
        let gateway_static_public: String
        let psk: String
        let message_1: String
        let message_2: String
        let to_gateway: Direction
        let to_phone: Direction

        enum CodingKeys: String, CodingKey {
            case protocol_ = "protocol"
            case prologue, phone_static_private, phone_static_public, phone_ephemeral_private, gateway_static_public
            case psk, message_1, message_2, to_gateway, to_phone
        }
    }

    private final class Locator {}

    private func vectors() throws -> Vectors {
        let url = try #require(Bundle(for: Locator.self).url(forResource: "Fixtures", withExtension: nil)?
            .appending(path: "noise/ikpsk2.json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func handshake(_ v: Vectors) throws -> (Noise.Initiator, Data) {
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.phone_static_private))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.phone_ephemeral_private))
        var initiator = try Noise.Initiator(staticKey: phone, gateway: Data(hex: v.gateway_static_public),
                                            psk: Data(hex: v.psk), ephemeral: ephemeral)
        let first = try initiator.writeFirst()
        return (initiator, first)
    }

    @Test func theHandshakeMatchesTheGateway() throws {
        let v = try vectors()
        #expect(v.protocol_ == Noise.protocolName)
        #expect(Data(hex: v.prologue) == Noise.prologue)
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.phone_static_private))
        #expect(phone.publicKey.rawRepresentation == Data(hex: v.phone_static_public))

        var (initiator, first) = try handshake(v)
        #expect(first == Data(hex: v.message_1))
        var (transport, payload) = try initiator.readSecond(Data(hex: v.message_2))
        #expect(payload.isEmpty)

        var sent: [Data] = []
        for plain in v.to_gateway.plain {
            sent += try transport.seal(binary: plain.binary, plain.data)
        }
        #expect(sent == v.to_gateway.messages.map { Data(hex: $0) })

        for (message, plain) in zip(v.to_phone.messages, v.to_phone.plain) {
            let opened = try #require(try transport.open(Data(hex: message)))
            #expect(opened.binary == plain.binary)
            #expect(opened.payload == plain.data)
        }
    }

    @Test func aWrongPskCannotReadTheReply() throws {
        let v = try vectors()
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.phone_static_private))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v.phone_ephemeral_private))
        var initiator = try Noise.Initiator(staticKey: phone, gateway: Data(hex: v.gateway_static_public),
                                            psk: Data(repeating: 7, count: 32), ephemeral: ephemeral)
        _ = try initiator.writeFirst()
        #expect(throws: Noise.Failure.decrypt) { try initiator.readSecond(Data(hex: v.message_2)) }
    }

    @Test func replayedMessagesAreRefused() throws {
        let v = try vectors()
        var (initiator, _) = try handshake(v)
        var (transport, _) = try initiator.readSecond(Data(hex: v.message_2))
        let first = Data(hex: v.to_phone.messages[0])
        _ = try transport.open(first)
        #expect(throws: Noise.Failure.decrypt) { try transport.open(first) }
    }

    @Test func largeMessagesGoInFragments() throws {
        // Two transports facing each other: the phone's sender keyed as the
        // other's receiver, by running the same handshake twice.
        let v = try vectors()
        var (a, _) = try handshake(v)
        var (b, _) = try handshake(v)
        var (sender, _) = try a.readSecond(Data(hex: v.message_2))
        var (mirror, _) = try b.readSecond(Data(hex: v.message_2))
        mirror.swapDirectionsForTesting()

        let payload = Data((0 ..< Noise.maxChunk * 2 + 10).map { UInt8($0 % 251) })
        let messages = try sender.seal(binary: true, payload)
        #expect(messages.count == 3)
        #expect(messages.allSatisfy { $0.count <= Noise.maxMessage })
        #expect(try mirror.open(messages[0]) == nil)
        #expect(try mirror.open(messages[1]) == nil)
        let whole = try #require(try mirror.open(messages[2]))
        #expect(whole.binary && whole.payload == payload)
        let empty = try #require(try mirror.open(try sender.seal(binary: false, Data())[0]))
        #expect(!empty.binary && empty.payload.isEmpty)
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
