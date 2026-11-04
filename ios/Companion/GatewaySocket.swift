import CryptoKit
import Foundation
import Synchronization

/// How a connection reached the Gateway.
enum GatewayPath: String, Sendable {
    /// Straight to its tailnet address.
    case tailnet
    /// Through the Relay, end-to-end encrypted with Noise (ADR 0006).
    case relay
}

/// What this device needs to reach the Gateway through the Relay: from
/// `relay_enroll` on the tailnet, or from pairing through the Relay.
struct RelayInfo: Codable, Equatable, Sendable {
    /// `https://relay.example.com` (`http://` for a local relay).
    var url: String
    var route: String
    /// The Gateway's Noise static public key, base64url.
    var gatewayKey: String
    /// This device's psk, base64url.
    var psk: String

    /// Where a phone opens a stream: `wss://<relay>/c/<route>`.
    var streamURL: URL? {
        let base = if url.hasPrefix("https://") {
            "wss://" + url.dropFirst("https://".count)
        } else if url.hasPrefix("http://") {
            "ws://" + url.dropFirst("http://".count)
        } else {
            url
        }
        return URL(string: base + "/c/" + route)
    }
}

/// The Relay keys this device keeps, in the Keychain: its own Noise static
/// key, and what the Gateway gave it.
enum RelayKeys {
    private static let staticKeyAccount = "gateway.noise-key"
    private static let infoAccount = "gateway.relay"
    private static let cache = Mutex<RelayInfo??>(nil)

    /// Made on first use; one per device, kept until it unpairs.
    static func staticKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let stored = Keychain.read(staticKeyAccount).flatMap({ Data(base64URL: $0) }),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        Keychain.write(key.rawRepresentation.base64URL, account: staticKeyAccount)
        return key
    }

    static var info: RelayInfo? {
        cache.withLock { cached in
            if let cached { return cached }
            let loaded = Keychain.read(infoAccount).flatMap { try? JSONDecoder().decode(RelayInfo.self, from: Data($0.utf8)) }
            cached = .some(loaded)
            return loaded
        }
    }

    static func save(_ info: RelayInfo?) {
        cache.withLock { cached in
            guard cached != .some(info) else { return }
            cached = .some(info)
            if let info, let data = try? JSONEncoder().encode(info) {
                Keychain.write(String(decoding: data, as: UTF8.self), account: infoAccount)
            } else {
                Keychain.delete(infoAccount)
            }
        }
    }

    static func clear() {
        save(nil)
        Keychain.delete(staticKeyAccount)
    }
}

/// Which path new connections try first: the one that worked last.
enum GatewayRoute {
    private static let last = Mutex(GatewayPath.tailnet)

    static var preferred: GatewayPath {
        get { last.withLock { $0 } }
        set { last.withLock { $0 = newValue } }
    }

    /// How long the tailnet gets before the Relay is tried.
    static let tailnetWait = Duration.seconds(2)
}

/// The Gateway refused the connection: an HTTP status, as on the tailnet
/// (401 not paired, 404 no such session).
struct GatewayRefusal: Error {
    let status: Int
}

/// One WebSocket to a Gateway endpoint, over the tailnet or through the
/// Relay; messages are the same either way. It connects on first use.
final class GatewaySocket: Sendable {
    private let opening: Task<any GatewayLink, any Error>
    private let box = Box()

    private final class Box: Sendable {
        let state = Mutex(State())
    }

    private struct State {
        var link: (any GatewayLink)?
        var refusal: Int?
        var cancelled = false
    }

    /// `url` is the endpoint's tailnet address. Without Relay keys it is the
    /// only path. `tailnetFirst` tries the tailnet first even when the Relay
    /// worked last, so the app's main connection finds its way back.
    init(url: URL, token: String, maximumMessageSize: Int, tailnetFirst: Bool = false) {
        let box = box
        opening = Task {
            do {
                let link = try await Self.open(url: url, token: token, maximumMessageSize: maximumMessageSize,
                                               tailnetFirst: tailnetFirst)
                let cancelled = box.state.withLock { state in
                    state.link = link
                    return state.cancelled
                }
                if cancelled {
                    link.cancel()
                    throw CancellationError()
                }
                return link
            } catch let refusal as GatewayRefusal {
                box.state.withLock { $0.refusal = refusal.status }
                throw refusal
            }
        }
    }

    /// The path this socket took, once connected.
    var path: GatewayPath? { box.state.withLock { $0.link?.path } }

    /// The status the Gateway refused with, if it did.
    var status: Int? {
        box.state.withLock { $0.refusal ?? $0.link?.status }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await opening.value.send(message)
    }

    /// A failed receive ends the link, as a closed socket would.
    func receive() async throws -> URLSessionWebSocketTask.Message {
        let link = try await opening.value
        do {
            return try await link.receive()
        } catch {
            link.cancel()
            throw error
        }
    }

    /// False once the link is dead.
    func ping() async -> Bool {
        guard let link = try? await opening.value else { return false }
        return await link.ping()
    }

    func cancel() {
        opening.cancel()
        let link = box.state.withLock { state in
            state.cancelled = true
            return state.link
        }
        link?.cancel()
    }

    private static func open(url: URL, token: String, maximumMessageSize: Int, tailnetFirst: Bool) async throws -> any GatewayLink {
        guard let relay = RelayKeys.info else {
            return TailnetLink(url: url, token: token, maximumMessageSize: maximumMessageSize)
        }
        let order: [GatewayPath] = tailnetFirst || GatewayRoute.preferred == .tailnet ? [.tailnet, .relay] : [.relay, .tailnet]
        var failure: any Error = URLError(.cannotConnectToHost)
        for (index, path) in order.enumerated() {
            try Task.checkCancellation()
            do {
                let link: any GatewayLink = switch path {
                case .tailnet:
                    try await TailnetLink.connect(url: url, token: token, maximumMessageSize: maximumMessageSize,
                                                  within: index == 0 ? GatewayRoute.tailnetWait : .seconds(10))
                case .relay:
                    try await RelayLink.connect(relay, request: relayRequest(url))
                }
                GatewayRoute.preferred = path
                return link
            } catch let refusal as GatewayRefusal {
                throw refusal
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// The endpoint, as the first message on a Relay stream names it.
    private static func relayRequest(_ url: URL) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? url.path
        if let query = components?.percentEncodedQuery { path += "?" + query }
        return (try? JSONEncoder().encode(["path": path])) ?? Data()
    }
}

protocol GatewayLink: Sendable {
    var path: GatewayPath { get }
    var status: Int? { get }
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping() async -> Bool
    func cancel()
}

/// Straight to the Gateway's tailnet address, with the device token.
private struct TailnetLink: GatewayLink {
    let task: URLSessionWebSocketTask

    init(url: URL, token: String, maximumMessageSize: Int, delegate: (any URLSessionTaskDelegate)? = nil) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        task.delegate = delegate
        task.resume()
    }

    /// Waits until the WebSocket is open. A refusal (401, 404) is final; a
    /// tailnet that doesn't answer `within` gives way to the Relay.
    static func connect(url: URL, token: String, maximumMessageSize: Int, within: Duration) async throws -> TailnetLink {
        let watch = OpenWatch()
        let link = TailnetLink(url: url, token: token, maximumMessageSize: maximumMessageSize, delegate: watch)
        do {
            try await watch.wait(within: within)
            return link
        } catch {
            link.cancel()
            if let status = link.status, (400 ..< 500).contains(status) { throw GatewayRefusal(status: status) }
            throw error
        }
    }

    var path: GatewayPath { .tailnet }
    var status: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func ping() async -> Bool {
        await withCheckedContinuation { done in
            task.sendPing { done.resume(returning: $0 == nil) }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Resolves once a WebSocket task opens, fails if it ends first or the time runs out.
private final class OpenWatch: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let state = Mutex<(result: Result<Void, any Error>?, waiter: CheckedContinuation<Void, any Error>?)>((nil, nil))

    func wait(within limit: Duration) async throws {
        let timeout = Task { [weak self] in
            try await Task.sleep(for: limit)
            self?.finish(.failure(URLError(.timedOut)))
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let done = state.withLock { state -> Result<Void, any Error>? in
                    if let result = state.result { return result }
                    state.waiter = continuation
                    return nil
                }
                if let done { continuation.resume(with: done) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(.failure(error ?? URLError(.networkConnectionLost)))
    }
}

/// A stream through the Relay: Noise `IKpsk2` with this device's static key
/// and psk, then the endpoint's messages, sealed.
private actor RelayLink: GatewayLink {
    nonisolated let task: URLSessionWebSocketTask
    private var transport: Noise.Transport

    private init(task: URLSessionWebSocketTask, transport: Noise.Transport) {
        self.task = task
        self.transport = transport
    }

    static func connect(_ relay: RelayInfo, request: Data) async throws -> RelayLink {
        guard let gateway = Data(base64URL: relay.gatewayKey), let psk = Data(base64URL: relay.psk) else {
            throw URLError(.badURL)
        }
        let (task, transport) = try await handshake(relay, gateway: gateway, psk: psk, request: request)
        return RelayLink(task: task, transport: transport)
    }

    /// Opens a stream and proves this device with `psk` (its own, or a pairing
    /// link's secret); `request` is the first message. The Gateway turning the
    /// device away (close code 4401) is a refusal; anything else is the
    /// Relay path failing.
    static func handshake(_ relay: RelayInfo, gateway: Data, psk: Data, request: Data) async throws
        -> (URLSessionWebSocketTask, Noise.Transport) {
        guard let url = relay.streamURL else { throw URLError(.badURL) }
        let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 10))
        task.resume()
        do {
            var initiator = try Noise.Initiator(staticKey: RelayKeys.staticKey(), gateway: gateway, psk: psk)
            try await task.send(.data(initiator.writeFirst()))
            let reply = try await withTimeout(.seconds(10)) { try await task.receive() }
            guard case .data(let second) = reply else { throw Noise.Failure.badMessage }
            var (transport, _) = try initiator.readSecond(second)
            for message in try transport.seal(binary: false, request) {
                try await task.send(.data(message))
            }
            return (task, transport)
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            if let status = refusal(task) { throw GatewayRefusal(status: status) }
            throw error
        }
    }

    /// The Gateway's close code `4000 + status`, as the HTTP status it stands for.
    nonisolated static func refusal(_ task: URLSessionWebSocketTask) -> Int? {
        let code = task.closeCode.rawValue
        return (4000 ..< 5000).contains(code) ? code - 4000 : nil
    }

    nonisolated var path: GatewayPath { .relay }
    nonisolated var status: Int? { Self.refusal(task) }

    /// Fragments go out back to back, so another send can't come between them.
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let sealed = switch message {
        case .string(let text): try transport.seal(binary: false, Data(text.utf8))
        case .data(let data): try transport.seal(binary: true, data)
        @unknown default: [Data]()
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            let remaining = Mutex(sealed.count)
            let failed = Mutex(false)
            for fragment in sealed {
                task.send(.data(fragment)) { error in
                    if let error, !failed.withLock({ let was = $0; $0 = true; return was }) {
                        done.resume(throwing: error)
                        return
                    }
                    let last = remaining.withLock { $0 -= 1; return $0 == 0 }
                    if last, !failed.withLock({ $0 }) { done.resume() }
                }
            }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        while true {
            guard case .data(let message) = try await task.receive() else { continue }
            guard let (binary, payload) = try transport.open(message) else { continue }
            return binary ? .data(payload) : .string(String(decoding: payload, as: UTF8.self))
        }
    }

    nonisolated func ping() async -> Bool {
        await withCheckedContinuation { done in
            task.sendPing { done.resume(returning: $0 == nil) }
        }
    }

    nonisolated func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Pairs through the Relay with a link v2 secret (ADR 0006).
enum RelayPairing {
    struct Paired {
        let device: String
        let token: String
        let psk: String
    }

    static func pair(_ relay: RelayInfo, secret: Data, gateway: Data, name: String) async throws -> Paired? {
        let request = try JSONEncoder().encode(["path": "/v0/pair", "name": name])
        let (task, transport) = try await RelayLink.handshake(relay, gateway: gateway, psk: secret, request: request)
        var opener = transport
        defer { task.cancel(with: .normalClosure, reason: nil) }
        while true {
            guard case .data(let message) = try await withTimeout(.seconds(10), { try await task.receive() }) else { continue }
            guard let (_, payload) = try opener.open(message) else { continue }
            struct Reply: Decodable {
                let type: String
                let device: String?
                let token: String?
                let psk: String?
            }
            let reply = try JSONDecoder().decode(Reply.self, from: payload)
            guard reply.type == "paired", let device = reply.device, let token = reply.token, let psk = reply.psk else {
                return nil
            }
            return Paired(device: device, token: token, psk: psk)
        }
    }
}

/// `operation`, or `URLError(.timedOut)` after `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

extension Data {
    /// Base64url without padding, as keys travel in links and messages.
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
