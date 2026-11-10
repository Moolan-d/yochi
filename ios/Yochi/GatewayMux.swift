import Foundation
import Synchronization

/// One `/v0/mux` connection carrying many streams (ADR 0007), so a page opens
/// without dialling the Relay and redoing the Noise handshake. Every message
/// is a frame, `[stream id: u32][kind: u8][payload]`, little endian.
///
/// The main connection warms one up on its own path once it is connected;
/// pages take a stream on it when it is ready and on the path they would try
/// first, and otherwise connect by themselves as before.
final class GatewayMux: Sendable {
    enum Kind: UInt8 {
        case open = 0, text, binary, close
    }

    static func frame(_ id: UInt32, _ kind: Kind, _ payload: Data = Data()) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        withUnsafeBytes(of: id.littleEndian) { frame.append(contentsOf: $0) }
        frame.append(kind.rawValue)
        frame.append(payload)
        return frame
    }

    static func parse(_ frame: Data) -> (id: UInt32, kind: Kind, payload: Data)? {
        let bytes = [UInt8](frame.prefix(5))
        guard bytes.count == 5, let kind = Kind(rawValue: bytes[4]) else { return nil }
        let id = bytes[..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        return (id, kind, Data(frame.dropFirst(5)))
    }

    /// What the Gateway says on stream 0 first: it speaks mux.
    private struct Hello: Decodable {
        let type: String
        let v: Int
    }

    /// Where the endpoint is and who is asking: a mux serves only streams for
    /// the Gateway and device it was opened for.
    struct Key: Hashable, Sendable {
        let host: String
        let port: Int?
        let token: String

        init?(_ url: URL, token: String) {
            guard let host = url.host() else { return nil }
            self.host = host
            self.port = url.port
            self.token = token
        }
    }

    let key: Key
    let path: GatewayPath
    private let link: any GatewayLink
    private let state = Mutex(State())

    private struct State {
        var streams: [UInt32: Inbox] = [:]
        var next: UInt32 = 1
        var dead = false
        /// Replaced by a newer mux: no new streams, closed once its own end.
        var retired = false
        var reader: Task<Void, Never>?
        var pings: Task<Void, Never>?
    }

    init(link: any GatewayLink, key: Key) {
        self.link = link
        self.key = key
        path = link.path
    }

    /// Waits for the Gateway's hello, then serves streams. False when the
    /// Gateway doesn't speak mux (an older one refuses `/v0/mux`).
    func start(within limit: Duration = .seconds(10)) async -> Bool {
        let link = link
        let hello = try? await withTimeout(limit) { () -> Bool in
            guard case .data(let frame) = try await link.receive(),
                  let (id, kind, payload) = Self.parse(frame), id == 0, kind == .text,
                  let hello = try? JSONDecoder().decode(Hello.self, from: payload) else { return false }
            return hello.type == "mux" && hello.v == 1
        }
        guard hello == true else {
            fail(URLError(.badServerResponse))
            return false
        }
        let reader = Task { [weak self] () -> Void in await self?.read() }
        let pings = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                if !(await self.link.ping()) {
                    self.fail(URLError(.networkConnectionLost))
                    return
                }
            }
        }
        state.withLock { state in
            state.reader = reader
            state.pings = pings
        }
        return true
    }

    /// Takes new streams: started, alive and not replaced.
    var open: Bool { state.withLock { !$0.dead && !$0.retired } }

    /// A stream to `endpoint` (its path and query), opened at once: the
    /// endpoint's first message is a round trip away. Returns once the
    /// request is on its way, so the stream's own messages follow it.
    func stream(to endpoint: URL) async -> Stream? {
        let inbox = Inbox()
        let id = state.withLock { state -> UInt32? in
            guard !state.dead, !state.retired else { return nil }
            let id = state.next
            state.next &+= 1
            state.streams[id] = inbox
            return id
        }
        guard let id else { return nil }
        do {
            try await link.send(.data(Self.frame(id, .open, Self.request(endpoint))))
        } catch {
            fail(error)
            return nil
        }
        return Stream(mux: self, id: id, inbox: inbox)
    }

    /// No new streams; the connection closes once the ones on it end.
    func retire() {
        let idle = state.withLock { state in
            state.retired = true
            return state.streams.isEmpty
        }
        if idle { close() }
    }

    func close() {
        fail(CancellationError())
    }

    fileprivate func send(_ id: UInt32, _ message: URLSessionWebSocketTask.Message) async throws {
        let frame = switch message {
        case .string(let text): Self.frame(id, .text, Data(text.utf8))
        case .data(let data): Self.frame(id, .binary, data)
        @unknown default: Data()
        }
        do {
            try await link.send(.data(frame))
        } catch {
            fail(error)
            throw error
        }
    }

    fileprivate func ping() async -> Bool {
        guard state.withLock({ !$0.dead }) else { return false }
        if await link.ping() { return true }
        fail(URLError(.networkConnectionLost))
        return false
    }

    /// The app is done with a stream: the Gateway closes its endpoint.
    fileprivate func end(_ id: UInt32) {
        let (known, idle) = state.withLock { state in
            let known = state.streams.removeValue(forKey: id) != nil && !state.dead
            return (known, state.retired && state.streams.isEmpty)
        }
        guard known else { return }
        let link = link
        Task {
            try? await link.send(.data(Self.frame(id, .close, Self.closing(1000))))
            if idle { self.close() }
        }
    }

    private func read() async {
        do {
            while !Task.isCancelled {
                guard case .data(let frame) = try await link.receive() else { continue }
                guard let (id, kind, payload) = Self.parse(frame) else { throw URLError(.cannotParseResponse) }
                switch kind {
                case .text:
                    state.withLock { $0.streams[id] }?.push(.string(String(decoding: payload, as: UTF8.self)))
                case .binary:
                    state.withLock { $0.streams[id] }?.push(.data(payload))
                case .close:
                    let bytes = [UInt8](payload.prefix(2))
                    let code = bytes.count == 2 ? Int(bytes[0]) | Int(bytes[1]) << 8 : 1005
                    let (inbox, idle) = state.withLock { state in
                        (state.streams.removeValue(forKey: id), state.retired && state.streams.isEmpty)
                    }
                    inbox?.finish(URLError(.networkConnectionLost), code: code)
                    if idle { close() }
                case .open:
                    break
                }
            }
        } catch {
            fail(error)
        }
    }

    /// The connection is gone, and every stream on it.
    private func fail(_ error: any Error) {
        let (streams, tasks) = state.withLock { state -> ([Inbox], [Task<Void, Never>]) in
            guard !state.dead else { return ([], []) }
            state.dead = true
            defer { state.streams = [:] }
            return (Array(state.streams.values), [state.reader, state.pings].compactMap { $0 })
        }
        tasks.forEach { $0.cancel() }
        link.cancel()
        for inbox in streams { inbox.finish(error, code: nil) }
        Self.forget(self)
    }

    private static func request(_ url: URL) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? url.path
        if let query = components?.percentEncodedQuery { path += "?" + query }
        return Data(path.utf8)
    }

    private static func closing(_ code: UInt16) -> Data {
        withUnsafeBytes(of: code.littleEndian) { Data($0) }
    }

    /// A stream on a mux: to its page, the same as a connection of its own.
    final class Stream: GatewayLink {
        private let mux: GatewayMux
        let id: UInt32
        private let inbox: Inbox

        fileprivate init(mux: GatewayMux, id: UInt32, inbox: Inbox) {
            self.mux = mux
            self.id = id
            self.inbox = inbox
        }

        var path: GatewayPath { mux.path }
        /// The Gateway's refusal, `4000 + status`, as on the Relay.
        var status: Int? {
            guard let code = inbox.code, (4000 ..< 5000).contains(code) else { return nil }
            return code - 4000
        }

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            guard inbox.code == nil else { throw URLError(.networkConnectionLost) }
            try await mux.send(id, message)
        }

        func receive() async throws -> URLSessionWebSocketTask.Message {
            try await inbox.next()
        }

        func ping() async -> Bool {
            guard inbox.code == nil else { return false }
            return await mux.ping()
        }

        func cancel() {
            mux.end(id)
            inbox.finish(CancellationError(), code: nil)
        }
    }

    /// One stream's messages, waiting to be received.
    fileprivate final class Inbox: Sendable {
        private struct State {
            var queue: [URLSessionWebSocketTask.Message] = []
            var ended: (any Error)?
            var code: Int?
            var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, any Error>?
        }

        private let state = Mutex(State())

        /// The close code the Gateway ended the stream with.
        var code: Int? { state.withLock { $0.code } }

        func push(_ message: URLSessionWebSocketTask.Message) {
            let waiter = state.withLock { state -> CheckedContinuation<URLSessionWebSocketTask.Message, any Error>? in
                guard state.ended == nil else { return nil }
                guard let waiter = state.waiter else {
                    state.queue.append(message)
                    return nil
                }
                state.waiter = nil
                return waiter
            }
            waiter?.resume(returning: message)
        }

        /// Messages already here are still received; then `error`.
        func finish(_ error: any Error, code: Int?) {
            let waiter = state.withLock { state -> CheckedContinuation<URLSessionWebSocketTask.Message, any Error>? in
                guard state.ended == nil else { return nil }
                state.ended = error
                state.code = code
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: error)
        }

        func next() async throws -> URLSessionWebSocketTask.Message {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let ready = state.withLock { state -> Result<URLSessionWebSocketTask.Message, any Error>? in
                        if !state.queue.isEmpty { return .success(state.queue.removeFirst()) }
                        if let ended = state.ended { return .failure(ended) }
                        state.waiter = continuation
                        return nil
                    }
                    if let ready { continuation.resume(with: ready) }
                }
            } onCancel: {
                finish(CancellationError(), code: nil)
            }
        }
    }

    // MARK: The one the app keeps

    private static let current = Mutex<GatewayMux?>(nil)
    /// The mux being opened, so a second warm-up for it waits its turn.
    private static let warming = Mutex<Task<Void, Never>?>(nil)

    /// Opens a mux on `path` for the Gateway `endpoint` belongs to, in place
    /// of the one there was; called each time the main connection connects.
    static func warm(endpoint: URL, token: String, path: GatewayPath) {
        guard let key = Key(endpoint, token: token), var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return
        }
        components.path = "/v0/mux"
        components.query = nil
        guard let url = components.url else { return }
        let task = Task {
            guard let link = try? await GatewaySocket.link(on: path, url: url, token: token, maximumMessageSize: (32 << 20) + 5) else {
                return
            }
            let mux = GatewayMux(link: link, key: key)
            guard await mux.start(), !Task.isCancelled else {
                mux.close()
                return
            }
            let replaced = current.withLock { current in
                defer { current = mux }
                return current
            }
            replaced?.retire()
        }
        warming.withLock { warming in
            warming?.cancel()
            warming = task
        }
    }

    /// A stream to `endpoint` on the app's mux, if it is ready for that
    /// Gateway and device on `path`.
    static func stream(to endpoint: URL, token: String, on path: GatewayPath) async -> Stream? {
        guard let key = Key(endpoint, token: token) else { return nil }
        let mux = current.withLock { $0 }
        guard let mux, mux.key == key, mux.path == path else { return nil }
        return await mux.stream(to: endpoint)
    }

    /// The main connection ended: pages connect by themselves until it is
    /// back and warms a new mux. Streams already open go on.
    static func retireAll() {
        warming.withLock { warming in
            warming?.cancel()
            warming = nil
        }
        let mux = current.withLock { current in
            defer { current = nil }
            return current
        }
        mux?.retire()
    }

    private static func forget(_ mux: GatewayMux) {
        current.withLock { current in
            if current === mux { current = nil }
        }
    }

    #if DEBUG
    /// For tests: the mux pages would use.
    static var shared: GatewayMux? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
    #endif
}
