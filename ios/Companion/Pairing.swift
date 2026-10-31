import Foundation
import UIKit

/// What `companion-gateway pair` shows: the Gateway's address and a single-use
/// code, typed in or opened from its QR code (`companion://pair?host=…&code=…`).
struct PairingInvite: Equatable {
    var host: String
    var code: String

    init(host: String, code: String) {
        self.host = host
        self.code = code
    }

    init?(url: URL) {
        guard url.scheme == "companion", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        self.init(host: host, code: code)
    }

    /// Trades the code for this device's own token, over a WebSocket like the
    /// rest of the API (iOS refuses plain HTTP to tailnet IPs).
    func pair() async throws -> GatewayConfig {
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
        case .badAddress: "地址无效"
        case .rejected: "配对码不正确或已过期。请在主 Mac 上重新运行 companion-gateway pair。"
        case .unexpected: "Gateway 返回了无法识别的响应"
        }
    }
}
