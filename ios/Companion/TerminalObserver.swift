import Foundation
import Observation

/// A read-only stream of one terminal from the Gateway (`/v0/observe`).
/// Text messages carry control, binary messages the terminal's bytes.
@MainActor @Observable
final class TerminalObserver {
    enum Phase: Equatable {
        case connecting
        /// Render a grid of this size; it changes when another client resizes the terminal.
        case observing(cols: Int, rows: Int)
        /// The core ended the stream (`exited`, `killed`, …) or attaching failed.
        case closed(reason: String)
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    /// The terminal's bytes, in order. Set before connecting.
    var onBytes: ((Data) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?

    /// `takeover` asks the core to resize the terminal to the phone's grid for
    /// as long as this stream stays open; nil only watches.
    func start(_ config: GatewayConfig, session: String, takeover: TerminalGrid? = nil) {
        stop()
        guard let url = config.observeURL(session: session, takeover: takeover) else {
            phase = .failed("地址无效：\(config.host)")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 32 << 20
        self.socket = socket
        phase = .connecting
        socket.resume()
        loop = Task { await follow(socket) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func follow(_ socket: URLSessionWebSocketTask) async {
        do {
            while true {
                switch try await socket.receive() {
                case .data(let bytes):
                    onBytes?(bytes)
                case .string(let text):
                    apply(try JSONDecoder().decode(ObserveMessage.self, from: Data(text.utf8)))
                @unknown default:
                    break
                }
            }
        } catch {
            if Task.isCancelled { return }
            if case .closed = phase { return }
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            let reason = switch status {
            case 401: "配对已失效"
            case 404: "会话已不存在"
            default: error.localizedDescription
            }
            phase = .failed(reason)
        }
    }

    private func apply(_ message: ObserveMessage) {
        switch message.type {
        case "attached", "size":
            if let cols = message.cols, let rows = message.rows {
                phase = .observing(cols: cols, rows: rows)
            }
        case "closed":
            phase = .closed(reason: message.reasonText)
        default:
            break
        }
    }
}

private struct ObserveMessage: Decodable {
    let type: String
    let cols: Int?
    let rows: Int?
    let reason: Reason?

    /// The core sends `{reason, exit_code, …}`; a failed attach sends a plain string.
    enum Reason: Decodable {
        case text(String)
        case record(reason: String?, exitCode: Int?)

        private enum Keys: String, CodingKey { case reason, exit_code }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self = .text(text)
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            self = .record(reason: try c.decodeIfPresent(String.self, forKey: .reason),
                           exitCode: try c.decodeIfPresent(Int.self, forKey: .exit_code))
        }
    }

    var reasonText: String {
        switch reason {
        case .text(let text): text
        case .record(let reason, let exitCode):
            switch reason {
            case "exited": exitCode.map { "程序已退出（退出码 \($0)）" } ?? "程序已退出"
            case "killed": "会话已被结束"
            case "core_lost": "与 herdr-core 的连接已断开"
            case "server_stop", "host_shutdown": "herdr-core 已停止"
            case let other?: other
            case nil: "会话已结束"
            }
        case nil: "会话已结束"
        }
    }
}

extension GatewayConfig {
    func observeURL(session: String, takeover: TerminalGrid? = nil) -> URL? {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.path = "/v0/observe"
        var items = [URLQueryItem(name: "session", value: session)]
        if let takeover {
            items += [
                URLQueryItem(name: "takeover", value: "1"),
                URLQueryItem(name: "cols", value: String(takeover.cols)),
                URLQueryItem(name: "rows", value: String(takeover.rows)),
            ]
        }
        components.queryItems = items
        return components.url
    }
}
