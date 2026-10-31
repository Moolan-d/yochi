import Foundation
import Observation

/// One WebSocket to the Gateway, kept open with reconnects while the app is active.
@MainActor @Observable
final class GatewayClient {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
        /// The Gateway no longer accepts this device (it was unpaired); retrying is pointless.
        case unauthorized
    }

    private(set) var phase: Phase = .disconnected
    /// The core's name for the Gateway's Mac, and whether the Gateway reaches it.
    private(set) var coreName: String?
    private(set) var coreConnected = false
    private(set) var sessions: [Session] = []

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    func connect(_ config: GatewayConfig) {
        disconnect()
        loop = Task { await run(config) }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        phase = .disconnected
    }

    /// Asks the Gateway to forget this device, then disconnects. Only possible
    /// while connected; otherwise `companion-gateway revoke` cleans up.
    func unpair() async {
        if phase == .connected, let socket {
            try? await socket.send(.string(#"{"type":"unpair"}"#))
        }
        disconnect()
    }

    private func run(_ config: GatewayConfig) async {
        guard let url = config.url else {
            phase = .failed("地址无效：\(config.host)")
            return
        }
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
            phase = .connecting
            do {
                try await follow(url: url, token: config.token)
            } catch {
                if Task.isCancelled { return }
                if (socket?.response as? HTTPURLResponse)?.statusCode == 401 {
                    // Unpaired: what this device saw before is no longer its to show.
                    sessions = []
                    coreName = nil
                    phase = .unauthorized
                    return
                }
                phase = .failed(describe(error))
            }
            if phase == .connected { delay = .seconds(1) }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(15))
        }
    }

    private func follow(url: URL, token: String) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        let pings = Task { await Self.keepAlive(socket) }
        defer {
            pings.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }

        while true {
            guard case .string(let text) = try await socket.receive() else { continue }
            switch try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) {
            case .hello:
                phase = .connected
            case .sessions(let core, let connected, let sessions):
                coreName = core
                coreConnected = connected
                self.sessions = sessions
            case .unknown:
                break
            }
        }
    }

    /// A dead link (the Mac slept, the phone changed networks) shows as a failed ping.
    private static func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            let alive = await withCheckedContinuation { done in
                socket.sendPing { done.resume(returning: $0 == nil) }
            }
            if !alive {
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if error is DecodingError { return "Gateway 返回了无法识别的数据" }
        return error.localizedDescription
    }
}
