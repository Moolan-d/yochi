import Foundation
import Observation

/// A stream of one terminal from the Gateway (`/v0/observe`): watched as
/// it is, or taken over at the phone's grid. Text messages carry control,
/// binary messages the terminal's bytes. Nothing is ever typed through it.
@MainActor @Observable
final class TerminalObserver {
    enum Phase: Equatable {
        case connecting
        /// Render a grid of this size; it changes when the terminal is resized.
        case observing(cols: Int, rows: Int)
        /// The core ended the stream (`exited`, `killed`, …) or attaching failed.
        case closed(reason: String)
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    /// The terminal's bytes, in order. Set before connecting.
    var onBytes: ((Data) -> Void)?

    private var socket: GatewaySocket?
    private var loop: Task<Void, Never>?

    /// With `takeover`, the terminal takes that grid while this stream is
    /// open; core gives the desktop its size back once it closes.
    func start(_ config: GatewayConfig, session: String, takeover: TerminalGrid? = nil) {
        stop()
        guard let url = config.observeURL(session: session, takeover: takeover) else {
            phase = .failed("地址无效：\(config.host)")
            return
        }
        let socket = GatewaySocket(url: url, token: config.token, maximumMessageSize: 32 << 20)
        self.socket = socket
        phase = .connecting
        loop = Task { await follow(socket) }
    }

    /// A taken-over terminal follows the phone's grid, e.g. as the keyboard
    /// comes up. Ignored by the Gateway on a stream that only watches.
    func resize(_ grid: TerminalGrid) {
        #if DEBUG
        resizes.append(grid)
        #endif
        guard let socket else { return }
        let message = #"{"type":"resize","cols":\#(grid.cols),"rows":\#(grid.rows)}"#
        Task { try? await socket.send(.string(message)) }
    }

    /// A drag on a full-screen program, as the wheel reports Ghostty made
    /// for it. Ignored by the Gateway on a stream that only watches.
    func wheel(_ reports: Data) {
        #if DEBUG
        wheels.append(reports)
        #endif
        guard let socket,
              let message = try? JSONEncoder().encode(["type": "wheel", "data": String(decoding: reports, as: UTF8.self)])
        else { return }
        Task { try? await socket.send(.string(String(decoding: message, as: UTF8.self))) }
    }

    #if DEBUG
    /// Every grid asked for, for tests.
    private(set) var resizes: [TerminalGrid] = []
    /// Every scroll passed on, for tests.
    private(set) var wheels: [Data] = []

    /// Core answered the attach with this grid, for tests.
    func attached(cols: Int, rows: Int) {
        phase = .observing(cols: cols, rows: rows)
    }
    #endif

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel()
        socket = nil
    }

    private func follow(_ socket: GatewaySocket) async {
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
            let status = socket.status
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
            items += [URLQueryItem(name: "takeover", value: "1"),
                      URLQueryItem(name: "cols", value: String(takeover.cols)),
                      URLQueryItem(name: "rows", value: String(takeover.rows))]
        }
        components.queryItems = items
        return components.url
    }
}
