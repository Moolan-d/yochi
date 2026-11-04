import Foundation
import Testing

@testable import Companion

struct PairingTests {
    @Test func aFirstVersionLinkPairsOverTheTailnetOnly() throws {
        let invite = try #require(PairingInvite(url: URL(string: "yochi://pair?host=100.64.0.1:7420&code=ABCD-1234")!))
        #expect(invite == PairingInvite(host: "100.64.0.1:7420", code: "ABCD-1234"))
    }

    @Test func aSecondVersionLinkCarriesTheRelay() throws {
        let url = URL(string: "yochi://pair?v=2&host=mac.tail:7420&code=ABCD-1234&key=a-b_c"
            + "&relay=https%3A%2F%2Frelay.example.com&route=r0ute&secret=s3cr_t")!
        let invite = try #require(PairingInvite(url: url))
        #expect(invite.host == "mac.tail:7420")
        #expect(invite.relay == .init(url: "https://relay.example.com", route: "r0ute", gatewayKey: "a-b_c", secret: "s3cr_t"))
    }

    @Test func aLinkMissingARelayPartStillPairsOverTheTailnet() throws {
        let url = URL(string: "yochi://pair?v=2&host=mac.tail&code=C&key=k&relay=https%3A%2F%2Fr.example&secret=s")!
        let invite = try #require(PairingInvite(url: url))
        #expect(invite.relay == nil)
        #expect(PairingInvite(url: URL(string: "yochi://pair?v=2&code=C")!) == nil)
    }

    @Test func aRelayOnlySpeaksWebSocketsOverItsOwnScheme() {
        let secure = RelayInfo(url: "https://relay.example.com", route: "abc", gatewayKey: "", psk: "")
        #expect(secure.streamURL?.absoluteString == "wss://relay.example.com/c/abc")
        let local = RelayInfo(url: "http://127.0.0.1:8787", route: "abc", gatewayKey: "", psk: "")
        #expect(local.streamURL?.absoluteString == "ws://127.0.0.1:8787/c/abc")
    }

    @Test func enrollmentRepliesDecode() throws {
        func decode(_ json: String) throws -> ServerMessage {
            try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
        }
        let available = try decode(#"{"type":"relay","available":true,"url":"https://r.example","route":"rt","gateway_key":"gk","psk":"p"}"#)
        guard case .relay(let info, let failed) = available else { Issue.record("not relay"); return }
        #expect(info == RelayInfo(url: "https://r.example", route: "rt", gatewayKey: "gk", psk: "p"))
        #expect(!failed)
        guard case .relay(nil, false) = try decode(#"{"type":"relay","available":false}"#) else { Issue.record("off"); return }
        guard case .relay(nil, true) = try decode(#"{"type":"relay","available":false,"error":"x"}"#) else {
            Issue.record("failed")
            return
        }
    }

    @Test func keysRoundTripAsBase64URL() {
        let bytes = Data((0 ..< 32).map { UInt8($0 * 7 % 256) })
        let text = bytes.base64URL
        #expect(!text.contains("=") && !text.contains("+") && !text.contains("/"))
        #expect(Data(base64URL: text) == bytes)
    }
}
