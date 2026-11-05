import Foundation
import UIKit

/// What `yochi pair` shows: the Gateway's address and a single-use
/// code, typed in or opened from its QR code (`yochi://pair?host=…&code=…`).
/// A Gateway with a Relay adds a way through it (link v2): the Relay, the
/// route, the Gateway's Noise key and a single-use secret. Off the tailnet
/// the link has only that, and `host` is empty.
struct PairingInvite: Equatable {
    var host: String
    var code: String
    var relay: Relay?

    struct Relay: Equatable {
        var url: String
        var route: String
        var gatewayKey: String
        var secret: String
    }

    init(host: String, code: String, relay: Relay? = nil) {
        self.host = host
        self.code = code
        self.relay = relay
    }

    init?(url: URL) {
        guard url.scheme == "yochi", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        var relay: Relay?
        // A link without every Relay part still pairs over the tailnet.
        if value("v") == "2", let address = value("relay"), let route = value("route"), let key = value("key"),
           let secret = value("secret"), address.hasPrefix("https://") || address.hasPrefix("http://") {
            relay = Relay(url: address, route: route, gatewayKey: key, secret: secret)
        }
        let host = value("host")
        guard host != nil || relay != nil else { return nil }
        self.init(host: host ?? "", code: value("code") ?? "", relay: relay)
    }

    /// Pairs over the tailnet; with a Relay in the link, through the Relay
    /// when the tailnet doesn't answer.
    func pair() async throws -> GatewayConfig {
        guard let relay else { return try await pairOnTailnet() }
        if host.isEmpty { return try await pairThrough(relay) }
        do {
            return try await withTimeout(.seconds(4)) { try await pairOnTailnet() }
        } catch PairingError.rejected {
            throw PairingError.rejected
        } catch {
            return try await pairThrough(relay)
        }
    }

    /// Proves this device with the link's secret; the Gateway answers with
    /// a token and this device's own psk.
    private func pairThrough(_ relay: Relay) async throws -> GatewayConfig {
        guard let gateway = Data(base64URL: relay.gatewayKey), let secret = Data(base64URL: relay.secret) else {
            throw PairingError.badAddress
        }
        let link = RelayInfo(url: relay.url, route: relay.route, gatewayKey: relay.gatewayKey, psk: relay.secret)
        let name = await UIDevice.current.name
        let paired: RelayPairing.Paired?
        do {
            paired = try await RelayPairing.pair(link, secret: secret, gateway: gateway, name: name)
        } catch is GatewayRefusal {
            throw PairingError.rejected
        } catch Noise.Failure.decrypt {
            // The secret was used or has expired.
            throw PairingError.rejected
        }
        guard let paired else { throw PairingError.unexpected }
        RelayKeys.save(RelayInfo(url: relay.url, route: relay.route, gatewayKey: relay.gatewayKey, psk: paired.psk))
        return GatewayConfig(host: host, token: paired.token, device: paired.device)
    }

    /// Trades the code for this device's own token, over a WebSocket like the
    /// rest of the API (iOS refuses plain HTTP to tailnet IPs).
    private func pairOnTailnet() async throws -> GatewayConfig {
        guard let url = GatewayConfig.endpoint(host: host, path: "/v0/pair") else {
            throw PairingError.badAddress
        }
        let socket = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 10))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let name = await UIDevice.current.name
        let request = try JSONEncoder().encode(["type": "pair", "code": code, "name": name])
        try await socket.send(.string(String(decoding: request, as: UTF8.self)))
        guard case .string(let text) = try await socket.receive() else { throw PairingError.unexpected }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(text.utf8))
        switch reply.type {
        case "paired":
            guard let device = reply.device, let token = reply.token else { throw PairingError.unexpected }
            return GatewayConfig(host: host, token: token, device: device)
        case "rejected":
            throw PairingError.rejected
        default:
            throw PairingError.unexpected
        }
    }

    private struct Reply: Decodable {
        let type: String
        let device: String?
        let token: String?
    }
}

enum PairingError: LocalizedError {
    case badAddress
    case rejected
    case unexpected

    var errorDescription: String? {
        switch self {
        case .badAddress: String(localized: "Invalid address")
        case .rejected: String(localized: "The pairing code is wrong or has expired. Run yochi pair on the main Mac again.")
        case .unexpected: String(localized: "The Gateway sent a response the app doesn't recognize")
        }
    }
}
