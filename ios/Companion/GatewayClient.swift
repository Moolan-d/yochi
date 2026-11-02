import Foundation
import Observation

/// One WebSocket to the Gateway, kept open with reconnects while the app is active.
@MainActor @Observable
final class GatewayClient {
    enum AgentMessageResult {
        case accepted(turn: UInt64, status: String?, started: Bool?)
        case failed(kind: String, message: String)
        /// The request may have reached the backend; retrying could duplicate it.
        case unknown
    }

    enum KeysResult {
        case pressed
        case failed(kind: String, message: String)
        /// The keys may have been pressed; pressing again could repeat them.
        case unknown
    }

    /// A reply to any request the app makes on this socket, matched by id.
    private enum Reply {
        case sent(turn: UInt64, status: String?, started: Bool?)
        case keysSent
        case failed(kind: String, message: String)
        case unknown
    }

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
    private(set) var spaces: [Space] = []
    /// Latest Delivery per host + session; memory only, so leaving and returning
    /// to a terminal keeps its status without restoring stale drafts.
    private(set) var deliveries: [String: AgentDelivery] = [:]

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    /// Pending requests stay bound to the socket they were written to, so a
    /// superseded connection's teardown cannot fail a newer connection's request.
    private var pending: [String: Pending] = [:]
    private var responseTimeouts: [String: Task<Void, Never>] = [:]

    private struct Pending {
        let socket: URLSessionWebSocketTask
        let continuation: CheckedContinuation<Reply, Never>
    }

    func delivery(host: String, session: String) -> AgentDelivery? {
        deliveries[AgentMessageStore.key(host: host, session: session)]
    }

    func remember(_ delivery: AgentDelivery, host: String, session: String) {
        deliveries[AgentMessageStore.key(host: host, session: session)] = delivery
    }

    func connect(_ config: GatewayConfig) {
        disconnect()
        loop = Task { await run(config) }
    }

    func disconnect() {
        failPending()
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        phase = .disconnected
    }

    /// Sends one complete Agent Message without taking over the terminal. The
    /// continuation resolves only from its matching reply or a broken connection.
    func sendMessage(session: String, text: String, force: Bool = false) async -> AgentMessageResult {
        struct Request: Encodable {
            let type = "send"
            let id: String
            let session: String
            let text: String
            let force: Bool
        }
        let reply = await request { Request(id: $0, session: session, text: text, force: force) }
        switch reply {
        case .sent(let turn, let status, let started): return .accepted(turn: turn, status: status, started: started)
        case .failed(let kind, let message): return .failed(kind: kind, message: message)
        case .keysSent, .unknown: return .unknown
        }
    }

    /// Presses named keys (`up`, `enter`, `esc`, …) without taking over the
    /// terminal: no attach, so the desktop's size is untouched.
    func pressKeys(session: String, keys: [String]) async -> KeysResult {
        struct Request: Encodable {
            let type = "keys"
            let id: String
            let session: String
            let keys: [String]
        }
        let reply = await request { Request(id: $0, session: session, keys: keys) }
        switch reply {
        case .keysSent: return .pressed
        case .failed(let kind, let message): return .failed(kind: kind, message: message)
        case .sent, .unknown: return .unknown
        }
    }

    /// Answers what the Agent waits for: `allow`, `deny`, or an option's
    /// number. The Gateway refuses (`changed`) unless core still shows `expect`.
    func answer(session: String, choice: String, expect: String?) async -> KeysResult {
        struct Request: Encodable {
            let type = "answer"
            let id: String
            let session: String
            let choice: String
            let expect: String?
        }
        let reply = await request { Request(id: $0, session: session, choice: choice, expect: expect) }
        switch reply {
        case .keysSent: return .pressed
        case .failed(let kind, let message): return .failed(kind: kind, message: message)
        case .sent, .unknown: return .unknown
        }
    }

    private func request(_ make: (String) -> some Encodable) async -> Reply {
        guard phase == .connected, let socket else {
            return .failed(kind: "unavailable", message: "未连接")
        }
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(make(id)) else {
            return .failed(kind: "invalid_params", message: "请求编码失败")
        }
        return await withCheckedContinuation { continuation in
            pending[id] = Pending(socket: socket, continuation: continuation)
            responseTimeouts[id] = Task {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                complete(id: id, with: .unknown)
                socket.cancel(with: .goingAway, reason: nil)
            }
            Task {
                do {
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                } catch {
                    complete(id: id, with: .unknown)
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
        }
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
                    spaces = []
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
            failPending(for: socket)
            pings.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }

        while true {
            guard case .string(let text) = try await socket.receive() else { continue }
            switch try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) {
            case .hello:
                phase = .connected
            case .sessions(let core, let connected, let sessions, let spaces):
                coreName = core
                coreConnected = connected
                self.sessions = sessions
                self.spaces = spaces
            case .sent(let id, let turn, let status, let started):
                complete(id: id, with: .sent(turn: turn, status: status, started: started))
            case .sendFailed(let id, let kind, let message), .keysFailed(let id, let kind, let message):
                complete(id: id, with: .failed(kind: kind, message: message))
            case .keysSent(let id):
                complete(id: id, with: .keysSent)
            case .unknown:
                break
            }
        }
    }

    private func complete(id: String, with result: Reply) {
        responseTimeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.continuation.resume(returning: result)
    }

    private func failPending(for socket: URLSessionWebSocketTask? = nil) {
        let failed = pending.filter { socket == nil || $0.value.socket === socket }
        for (id, request) in failed {
            pending.removeValue(forKey: id)
            responseTimeouts.removeValue(forKey: id)?.cancel()
            request.continuation.resume(returning: .unknown)
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
