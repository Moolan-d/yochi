import Foundation
import Observation

/// A stream of one terminal from the Gateway (`/v0/observe`): watched as
/// it is, or taken over at the phone's grid. Text messages carry control,
/// binary messages the terminal's bytes. A takeover on a Gateway that says
/// so (`canType`) also carries what the phone types.
///
/// The stream outlives its connection: when the connection drops (network
/// change, the app going to the background) the Gateway keeps the stream
/// for a while, a takeover keeping the phone's size, and the observer comes
/// back to it with the number of bytes it has, so nothing is drawn twice.
/// Leaving for good says so (`stop`), and the Gateway lets go at once.
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
    /// The connection dropped and the observer is coming back to the stream.
    private(set) var reconnecting = false
    /// The Gateway takes typing on this stream (`attached.input`): a takeover
    /// on a Gateway new enough. Otherwise keys go through `terminal.keys`.
    private(set) var canType = false
    /// The terminal's bytes, in order. Set before connecting.
    var onBytes: ((Data) -> Void)?
    /// The stream can't be picked up where it was (the Gateway waited too
    /// long, or lost it); the phase is `failed`, and a fresh attach is in order.
    var onExpired: (() -> Void)?

    private var socket: GatewaySocket?
    private var loop: Task<Void, Never>?
    /// What the stream is of, for coming back to it.
    private var target: (config: GatewayConfig, session: String)?
    /// The stream's latest resume token; nil on a Gateway that can't resume.
    private var token: String?
    /// How long the Gateway keeps the stream once the connection drops.
    private var keep = Duration.zero
    /// Bytes received on this stream so far, across connections.
    private var received: UInt64 = 0
    /// When the connection dropped, while coming back.
    private var droppedAt: ContinuousClock.Instant?
    /// Tries since the connection dropped, for backing off.
    private var tries = 0
    /// The grid last asked for, sent again after coming back in case it was
    /// asked for while the connection was down.
    private var wanted: TerminalGrid?
    /// The last message queued, so wheel and typing go out in the order made.
    private var sending: Task<Void, Never>?

    /// With `takeover`, the terminal takes that grid while this stream is
    /// open; core gives the desktop its size back once it closes.
    func start(_ config: GatewayConfig, session: String, takeover: TerminalGrid? = nil) {
        stop()
        guard let url = config.observeURL(session: session, takeover: takeover, resumable: true) else {
            phase = .failed(String(localized: "Invalid address: \(config.host)"))
            return
        }
        target = (config, session)
        received = 0
        wanted = nil
        canType = false
        phase = .connecting
        connect(url, config: config)
    }

    /// A taken-over terminal follows the phone's grid, e.g. as the keyboard
    /// comes up. Ignored by the Gateway on a stream that only watches.
    func resize(_ grid: TerminalGrid) {
        #if DEBUG
        resizes.append(grid)
        #endif
        wanted = grid
        guard let socket else { return }
        Task { try? await socket.send(.string(Self.resizeMessage(grid))) }
    }

    /// A drag on a full-screen program, as the wheel reports Ghostty made
    /// for it. Ignored by the Gateway on a stream that only watches.
    func wheel(_ reports: Data) {
        #if DEBUG
        wheels.append(reports)
        #endif
        send(["type": "wheel", "data": String(decoding: reports, as: UTF8.self)])
    }

    /// What the user typed, as the phone's terminal encoded it. Dropped on a
    /// stream that can't type, and while the connection is down: a keystroke
    /// replayed seconds later would do more harm than one lost.
    func input(_ bytes: Data) {
        guard canType else { return }
        #if DEBUG
        inputs.append(bytes)
        #endif
        send(["type": "input", "data": String(decoding: bytes, as: UTF8.self)])
    }

    private func send(_ message: [String: String]) {
        guard let socket, let json = try? JSONEncoder().encode(message) else { return }
        let text = String(decoding: json, as: UTF8.self)
        let previous = sending
        sending = Task {
            await previous?.value
            try? await socket.send(.string(text))
        }
    }

    #if DEBUG
    /// Every grid asked for, for tests.
    private(set) var resizes: [TerminalGrid] = []
    /// Every scroll passed on, for tests.
    private(set) var wheels: [Data] = []
    /// Everything typed on a stream that can type, for tests.
    private(set) var inputs: [Data] = []

    /// Core answered the attach with this grid, for tests.
    func attached(cols: Int, rows: Int) {
        phase = .observing(cols: cols, rows: rows)
    }

    /// A control message as the Gateway sends it, for tests.
    func receive(control text: String) throws {
        apply(try JSONDecoder().decode(ObserveMessage.self, from: Data(text.utf8)))
    }
    #endif

    /// Whether the stream can still be picked up where it was.
    var canComeBack: Bool {
        guard token != nil, target != nil else { return false }
        guard let droppedAt else { return true }
        // A little short of the Gateway's wait, which began when it noticed.
        return ContinuousClock.now - droppedAt < keep - .seconds(2)
    }

    /// Whether the connection was let go of (`suspend`) with the stream kept.
    var isSuspended: Bool { socket == nil && droppedAt != nil && token != nil }

    /// Lets go of the connection but not the stream, e.g. as the app goes to
    /// the background: the Gateway keeps it for a while, and `comeBack`
    /// picks it up. A Gateway that can't resume is simply left.
    func suspend() {
        guard token != nil else {
            stop()
            return
        }
        loop?.cancel()
        loop = nil
        socket?.cancel()
        socket = nil
        reconnecting = false
        droppedAt = droppedAt ?? .now
    }

    /// Picks up a suspended stream where it was; false when it can't be, and
    /// the caller attaches afresh.
    @discardableResult
    func comeBack() -> Bool {
        guard isSuspended, canComeBack, let target, let token,
              let url = target.config.observeURL(session: target.session, resume: token, offset: received)
        else { return false }
        reconnecting = true
        connect(url, config: target.config)
        return true
    }

    /// Leaves the stream for good: the Gateway lets go at once, so a takeover
    /// gives the desktop its size back.
    func stop() {
        loop?.cancel()
        loop = nil
        if let socket {
            // An older Gateway ignores this, and lets go once the socket closes.
            Task {
                try? await socket.send(.string(#"{"type":"detach"}"#))
                socket.cancel()
            }
        }
        socket = nil
        token = nil
        droppedAt = nil
        tries = 0
        reconnecting = false
    }

    private func connect(_ url: URL, config: GatewayConfig) {
        let socket = GatewaySocket(url: url, token: config.token, maximumMessageSize: 32 << 20)
        self.socket = socket
        sending = nil
        loop = Task { await follow(socket) }
    }

    private func follow(_ socket: GatewaySocket) async {
        do {
            while true {
                switch try await socket.receive() {
                case .data(let bytes):
                    received += UInt64(bytes.count)
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
            await dropped(socket, error: error)
        }
    }

    /// The connection ended without the stream ending: come back to the
    /// stream while the Gateway keeps it, or fail.
    private func dropped(_ socket: GatewaySocket, error: any Error) async {
        let status = socket.status
        if status == 410 {
            expire()
            return
        }
        if status == nil, token != nil {
            droppedAt = droppedAt ?? .now
            self.socket = nil
            reconnecting = true
            // Straight away the first time (a path switch), then backing off.
            let wait: Duration = tries == 0 ? .zero : .milliseconds(min(500 * (1 << min(tries - 1, 3)), 4000))
            tries += 1
            try? await Task.sleep(for: wait)
            if Task.isCancelled { return }
            if comeBack() { return }
        }
        reconnecting = false
        let reason = switch status {
        case 401: String(localized: "Pairing no longer valid")
        case 404: String(localized: "The session no longer exists")
        default: error.localizedDescription
        }
        phase = .failed(reason)
    }

    /// The stream is gone on the Gateway's side.
    private func expire() {
        socket = nil
        token = nil
        droppedAt = nil
        tries = 0
        reconnecting = false
        phase = .failed(String(localized: "The connection expired"))
        onExpired?()
    }

    private func apply(_ message: ObserveMessage) {
        switch message.type {
        case "attached":
            token = message.resume
            keep = .milliseconds(message.keep_ms ?? 0)
            canType = message.input ?? false
            if let cols = message.cols, let rows = message.rows {
                phase = .observing(cols: cols, rows: rows)
            }
        case "resumed":
            token = message.resume
            keep = .milliseconds(message.keep_ms ?? 0)
            droppedAt = nil
            tries = 0
            reconnecting = false
            if let wanted, let socket {
                Task { try? await socket.send(.string(Self.resizeMessage(wanted))) }
            }
        case "size":
            if let cols = message.cols, let rows = message.rows {
                phase = .observing(cols: cols, rows: rows)
            }
        case "closed":
            token = nil
            reconnecting = false
            canType = false
            phase = .closed(reason: message.reasonText)
        default:
            break
        }
    }

    private static func resizeMessage(_ grid: TerminalGrid) -> String {
        #"{"type":"resize","cols":\#(grid.cols),"rows":\#(grid.rows)}"#
    }
}

private struct ObserveMessage: Decodable {
    let type: String
    let cols: Int?
    let rows: Int?
    let reason: Reason?
    /// `attached` (from a Gateway that can resume) and `resumed`.
    let resume: String?
    let keep_ms: Int?
    /// `attached` on a takeover the Gateway takes typing on.
    let input: Bool?

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
            case "exited": exitCode.map { String(localized: "The program exited (code \($0))") } ?? String(localized: "The program exited")
            case "killed": String(localized: "The session was ended")
            case "core_lost": String(localized: "Lost the connection to herdr-core")
            case "server_stop", "host_shutdown": String(localized: "herdr-core stopped")
            case let other?: other
            case nil: String(localized: "The session has ended")
            }
        case nil: String(localized: "The session has ended")
        }
    }
}

extension GatewayConfig {
    /// A fresh stream, or with `resume` the stream that token names, from
    /// the `offset`-th byte on.
    func observeURL(session: String, takeover: TerminalGrid? = nil, resumable: Bool = false,
                    resume: String? = nil, offset: UInt64 = 0) -> URL? {
        var items = [URLQueryItem(name: "session", value: session)]
        if let resume {
            items += [URLQueryItem(name: "resume", value: resume),
                      URLQueryItem(name: "offset", value: String(offset))]
        } else {
            if let takeover {
                items += [URLQueryItem(name: "takeover", value: "1"),
                          URLQueryItem(name: "cols", value: String(takeover.cols)),
                          URLQueryItem(name: "rows", value: String(takeover.rows))]
            }
            if resumable { items.append(URLQueryItem(name: "resumable", value: "1")) }
        }
        return endpoint("/v0/observe", query: items)
    }
}
