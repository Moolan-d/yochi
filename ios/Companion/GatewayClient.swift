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

    enum RunResult {
        /// The new terminal's id in the session list.
        case created(session: String)
        case failed(kind: String, message: String)
        /// The terminal may have been created; the session list will show it.
        case unknown
    }

    enum InterruptResult {
        /// core's outcome: stopped, exited, still_working or unknown.
        case pressed(outcome: String)
        case failed(kind: String, message: String)
        /// The stop key may have been pressed.
        case unknown
    }

    enum PutResult {
        /// Where the file landed, beside the terminal on its machine.
        case done(path: String)
        case failed(kind: String, message: String)
        /// The upload may have arrived.
        case unknown
    }

    /// A reply to any request the app makes on this socket, matched by id.
    private enum Reply {
        case sent(turn: UInt64, status: String?, started: Bool?)
        case keysSent
        case runCreated(session: String)
        case interrupted(outcome: String)
        case putDone(path: String)
        case commandList([SlashCommand])
        case changes(ChangeList)
        case changeDiff(patch: String, truncated: Bool)
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
    /// Messages waiting for their session's turn to end, by host + session.
    private(set) var queued: [String: QueuedMessage] = AgentMessageStore.allQueued()
    /// The Gateway this client follows, which queued messages belong to.
    private var host: String?
    /// Session pages' streams, kept a while after a page leaves.
    @ObservationIgnored let feedStore = SessionFeedStore()
    /// How the app reaches the Gateway right now, once connected.
    private(set) var path: GatewayPath?

    private var socket: GatewaySocket?
    private var loop: Task<Void, Never>?
    /// Pending requests stay bound to the socket they were written to, so a
    /// superseded connection's teardown cannot fail a newer connection's request.
    private var pending: [String: Pending] = [:]
    private var responseTimeouts: [String: Task<Void, Never>] = [:]

    private struct Pending {
        let socket: GatewaySocket
        let continuation: CheckedContinuation<Reply, Never>
    }

    func delivery(host: String, session: String) -> AgentDelivery? {
        deliveries[AgentMessageStore.key(host: host, session: session)]
    }

    func remember(_ delivery: AgentDelivery, host: String, session: String) {
        deliveries[AgentMessageStore.key(host: host, session: session)] = delivery
    }

    func queuedMessage(session: String) -> QueuedMessage? {
        host.flatMap { queued[AgentMessageStore.key(host: $0, session: session)] }
    }

    /// Holds `text` until the turn in progress ends; a second message joins
    /// the first after a blank line.
    func enqueue(_ text: String, session: String, turn: UInt64) {
        guard let host else { return }
        let key = AgentMessageStore.key(host: host, session: session)
        var message = queued[key] ?? QueuedMessage(text: "", turn: turn)
        message.text = message.text.isEmpty ? text : message.text + "\n\n" + text
        message.failure = nil
        setQueued(message, key: key)
    }

    /// Takes the queued message back; its text is returned to the draft.
    func withdrawQueued(session: String) -> String? {
        guard let host else { return nil }
        let key = AgentMessageStore.key(host: host, session: session)
        let text = queued[key]?.text
        setQueued(nil, key: key)
        return text
    }

    /// Sends the queued message now, as the user decided.
    func sendQueued(session: String) {
        guard let host, let text = withdrawQueued(session: session) else { return }
        Task { await submitQueued(text, host: host, session: session) }
    }

    /// Sends one Agent Message and records its Delivery.
    @discardableResult
    func submit(_ text: String, host: String, session: String, force: Bool = false) async -> AgentMessageResult {
        remember(.sending(text: text), host: host, session: session)
        let result = await sendMessage(session: session, text: text, force: force)
        switch result {
        case .accepted(let turn, let status, let started):
            remember(.sent(text: text, turn: turn, status: status, started: started), host: host, session: session)
        case .failed(let kind, _) where kind == "timeout" || kind == "unknown":
            remember(.unknown(text: text), host: host, session: session)
        case .failed(let kind, let message):
            remember(.failed(text: text, kind: kind, message: message), host: host, session: session)
        case .unknown:
            remember(.unknown(text: text), host: host, session: session)
        }
        return result
    }

    private func setQueued(_ message: QueuedMessage?, key: String) {
        queued[key] = message
        AgentMessageStore.saveQueued(message, key: key)
    }

    /// Sends what waited for a turn that has now ended; runs on every session list.
    private func releaseQueued() {
        guard let host else { return }
        for session in sessions {
            let key = AgentMessageStore.key(host: host, session: session.id)
            guard let message = queued[key],
                  message.release(state: session.status?.state, turn: session.turn) == .send else { continue }
            setQueued(nil, key: key)
            Task { await submitQueued(message.text, host: host, session: session.id) }
        }
    }

    /// A refused message goes back in the queue, marked, so its text isn't
    /// lost; one that may have arrived is not queued again.
    private func submitQueued(_ text: String, host: String, session: String) async {
        guard case .failed(let kind, let message) = await submit(text, host: host, session: session),
              kind != "timeout", kind != "unknown" else { return }
        let key = AgentMessageStore.key(host: host, session: session)
        var queued = self.queued[key] ?? QueuedMessage(text: "", turn: sessions.first { $0.id == session }?.turn ?? 0)
        queued.text = queued.text.isEmpty ? text : text + "\n\n" + queued.text
        queued.failure = AgentDelivery.failed(text: text, kind: kind, message: message).state
        setQueued(queued, key: key)
    }

    /// The Gateway named a different tailnet address, or none (`""`): its
    /// tailnet moved, came on, or went off. The owner saves it and reconnects.
    @ObservationIgnored var onTailnet: ((String) -> Void)?

    func connect(_ config: GatewayConfig) {
        disconnect()
        host = config.host
        loop = Task { await run(config) }
    }

    func disconnect() {
        GatewayMux.retireAll()
        failPending()
        loop?.cancel()
        loop = nil
        socket?.cancel()
        socket = nil
        path = nil
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
        case .keysSent, .runCreated, .interrupted, .putDone, .commandList, .changes, .changeDiff, .unknown: return .unknown
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
        case .sent, .runCreated, .interrupted, .putDone, .commandList, .changes, .changeDiff, .unknown: return .unknown
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
        case .sent, .runCreated, .interrupted, .putDone, .commandList, .changes, .changeDiff, .unknown: return .unknown
        }
    }

    /// Stops the Agent's current turn: core presses its stop key (Esc for an
    /// Agent that reports status) once and reports what happened.
    func interrupt(session: String) async -> InterruptResult {
        struct Request: Encodable {
            let type = "interrupt"
            let id: String
            let session: String
        }
        let reply = await request { Request(id: $0, session: session) }
        switch reply {
        case .interrupted(let outcome): return .pressed(outcome: outcome)
        case .failed(let kind, _) where kind == "timeout" || kind == "unknown": return .unknown
        case .failed(let kind, let message): return .failed(kind: kind, message: message)
        case .sent, .keysSent, .runCreated, .putDone, .commandList, .changes, .changeDiff, .unknown: return .unknown
        }
    }

    /// Starts a new terminal on the Gateway's core (or a connected machine):
    /// `argv` empty means the machine's shell. Herdr takes it into `space`, in
    /// a tab of its own, or into a new space when it is nil.
    /// Puts a file beside the terminal for its program to read (core's
    /// `terminal.put`); nothing is typed.
    func put(session: String, name: String, data: Data) async -> PutResult {
        struct Request: Encodable {
            let type = "put"
            let id: String
            let session: String
            let name: String
            let data: String
        }
        let base64 = data.base64EncodedString()
        let reply = await request { Request(id: $0, session: session, name: name, data: base64) }
        switch reply {
        case .putDone(let path): return .done(path: path)
        case .failed(let kind, _) where kind == "timeout" || kind == "unknown": return .unknown
        case .failed(let kind, let message): return .failed(kind: kind, message: message)
        case .sent, .keysSent, .runCreated, .interrupted, .commandList, .changes, .changeDiff, .unknown: return .unknown
        }
    }

    /// The session's custom slash commands and skills; nil when they
    /// couldn't be listed (the built-in ones still are).
    func commands(session: String) async -> [SlashCommand]? {
        struct Request: Encodable {
            let type = "commands"
            let id: String
            let session: String
        }
        let reply = await request { Request(id: $0, session: session) }
        if case .commandList(let commands) = reply { return commands }
        return nil
    }

    /// The session's Changes against HEAD.
    func changes(session: String) async -> Result<ChangeList, ChangesError> {
        struct Request: Encodable {
            let type = "changes"
            let id: String
            let session: String
        }
        switch await request({ Request(id: $0, session: session) }) {
        case .changes(let list): return .success(list)
        case .failed(let kind, let message): return .failure(ChangesError(kind: kind, message: message))
        default: return .failure(ChangesError(kind: "unknown", message: String(localized: "No result came back")))
        }
    }

    /// One file's diff; `path` must come from the latest Changes of this session.
    func changeDiff(session: String, path: String) async -> Result<FileDiff, ChangesError> {
        struct Request: Encodable {
            let type = "change_diff"
            let id: String
            let session: String
            let path: String
        }
        switch await request({ Request(id: $0, session: session, path: path) }) {
        case .changeDiff(let patch, let truncated): return .success(FileDiff(patch: patch, truncated: truncated))
        case .failed(let kind, let message): return .failure(ChangesError(kind: kind, message: message))
        default: return .failure(ChangesError(kind: "unknown", message: String(localized: "No result came back")))
        }
    }

    func runSession(machine: String?, cwd: String, argv: [String], space: String?) async -> RunResult {
        struct Request: Encodable {
            let type = "run"
            let id: String
            let machine: String?
            let cwd: String
            let argv: [String]
            let space: String?
        }
        let reply = await request { Request(id: $0, machine: machine, cwd: cwd, argv: argv, space: space) }
        switch reply {
        case .runCreated(let session): return .created(session: session)
        case .failed(let kind, let message): return .failed(kind: kind, message: message)
        case .sent, .keysSent, .interrupted, .putDone, .commandList, .changes, .changeDiff, .unknown: return .unknown
        }
    }

    private func request(_ make: (String) -> some Encodable) async -> Reply {
        guard phase == .connected, let socket else {
            return .failed(kind: "unavailable", message: String(localized: "Not connected"))
        }
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(make(id)) else {
            return .failed(kind: "invalid_params", message: String(localized: "Couldn't encode the request"))
        }
        return await withCheckedContinuation { continuation in
            pending[id] = Pending(socket: socket, continuation: continuation)
            responseTimeouts[id] = Task {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }
                complete(id: id, with: .unknown)
                socket.cancel()
            }
            Task {
                do {
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                } catch {
                    complete(id: id, with: .unknown)
                    socket.cancel()
                }
            }
        }
    }

    /// Asks the Gateway to forget this device, then disconnects. Only possible
    /// while connected; otherwise `yochi revoke` cleans up.
    func unpair() async {
        if phase == .connected, let socket {
            try? await socket.send(.string(#"{"type":"unpair"}"#))
        }
        disconnect()
        // What this device saw is no longer its to show.
        feedStore.cache.dropUnused()
    }

    private func run(_ config: GatewayConfig) async {
        guard let url = config.url else {
            phase = .failed(String(localized: "Invalid address: \(config.host)"))
            return
        }
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
            phase = .connecting
            do {
                try await follow(url: url, token: config.token)
            } catch {
                if Task.isCancelled { return }
                path = nil
                if socket?.status == 401 {
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
        // A file's diff can run to half a megabyte. The tailnet goes first
        // even after the Relay, so the app finds its way back to it.
        let socket = GatewaySocket(url: url, token: token, maximumMessageSize: 4 << 20, tailnetFirst: true, viaMux: false)
        self.socket = socket
        let pings = Task { await Self.keepAlive(socket) }
        defer {
            GatewayMux.retireAll()
            failPending(for: socket)
            pings.cancel()
            socket.cancel()
        }

        while true {
            guard case .string(let text) = try await socket.receive() else { continue }
            switch try await Self.decode(text) {
            case .hello:
                phase = .connected
                path = socket.path
                // Pages open as streams on one connection beside this one (ADR 0007).
                if let path { GatewayMux.warm(endpoint: url, token: token, path: path) }
                // On the tailnet, the Gateway tells this device how to reach
                // it through the Relay, for when the tailnet isn't there.
                if path == .tailnet {
                    let key = RelayKeys.staticKey().publicKey.rawRepresentation.base64URL
                    try? await socket.send(.string(#"{"type":"relay_enroll","static_key":"\#(key)"}"#))
                }
            case .relay(let info, let failed):
                // A failed enrollment keeps what this device had.
                if info != nil || !failed { RelayKeys.save(info) }
            case .tailnet(let host):
                // A phone that paired through the Relay learns the tailnet
                // here; one whose Gateway left the tailnet stops trying it.
                if (host ?? "") != self.host { onTailnet?(host ?? "") }
            case .sessions(let core, let connected, let sessions, let spaces):
                // Every page reads these; an unchanged list redraws nothing.
                if coreName != core { coreName = core }
                if coreConnected != connected { coreConnected = connected }
                if self.sessions != sessions { self.sessions = sessions }
                if self.spaces != spaces { self.spaces = spaces }
                releaseQueued()
            case .sent(let id, let turn, let status, let started):
                complete(id: id, with: .sent(turn: turn, status: status, started: started))
            case .sendFailed(let id, let kind, let message), .keysFailed(let id, let kind, let message):
                complete(id: id, with: .failed(kind: kind, message: message))
            case .keysSent(let id):
                complete(id: id, with: .keysSent)
            case .runCreated(let id, let session):
                complete(id: id, with: .runCreated(session: session))
            case .runFailed(let id, let kind, let message), .interruptFailed(let id, let kind, let message):
                complete(id: id, with: .failed(kind: kind, message: message))
            case .interrupted(let id, let outcome):
                complete(id: id, with: .interrupted(outcome: outcome))
            case .putDone(let id, let path):
                complete(id: id, with: .putDone(path: path))
            case .putFailed(let id, let kind, let message), .commandsFailed(let id, let kind, let message):
                complete(id: id, with: .failed(kind: kind, message: message))
            case .commandList(let id, let commands):
                complete(id: id, with: .commandList(commands))
            case .changes(let id, let list):
                complete(id: id, with: .changes(list))
            case .changeDiff(let id, let patch, let truncated):
                complete(id: id, with: .changeDiff(patch: patch, truncated: truncated))
            case .changesFailed(let id, let kind, let message), .changeDiffFailed(let id, let kind, let message):
                complete(id: id, with: .failed(kind: kind, message: message))
            case .unknown:
                break
            }
        }
    }

    /// Off the main thread: the session list, a change list or a diff.
    nonisolated private static func decode(_ text: String) async throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8))
    }

    private func complete(id: String, with result: Reply) {
        responseTimeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.continuation.resume(returning: result)
    }

    private func failPending(for socket: GatewaySocket? = nil) {
        let failed = pending.filter { socket == nil || $0.value.socket === socket }
        for (id, request) in failed {
            pending.removeValue(forKey: id)
            responseTimeouts.removeValue(forKey: id)?.cancel()
            request.continuation.resume(returning: .unknown)
        }
    }

    /// A dead link (the Mac slept, the phone changed networks) shows as a failed ping.
    private static func keepAlive(_ socket: GatewaySocket) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if !(await socket.ping()) {
                socket.cancel()
                return
            }
        }
    }

    private func describe(_ error: Error) -> String {
        if error is DecodingError { return String(localized: "The Gateway sent data the app doesn't recognize") }
        return error.localizedDescription
    }
}
