import Foundation
import Observation

/// The screen of a Claude Code session from the Gateway (`/v0/screen`), read
/// for the dialogs the transcript doesn't show: folder trust, permissions,
/// questions (ADR 0005). The Gateway sends the screen once it settles and
/// not while the Agent works; the dialog parser runs here.
@MainActor @Observable
final class ScreenFeed {
    /// What the last screen shows.
    private(set) var result: DialogParseResult = .none
    private(set) var screen: ANSIScreen?
    /// Counts screens received, so a waiting step can tell a fresh one.
    private(set) var revision = 0

    private var socket: GatewaySocket?
    private var loop: Task<Void, Never>?
    /// The session ended or refused the phone; nothing reconnects.
    @ObservationIgnored private var ended = false

    /// Nothing streams now; a page coming back starts it again.
    var needsStart: Bool { loop == nil || ended }

    func start(_ config: GatewayConfig, session: String) {
        stop()
        ended = false
        guard let url = config.screenURL(session: session) else { return }
        loop = Task { await follow(url, token: config.token) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel()
        socket = nil
    }

    /// Feeds one screen, as the socket does; for tests and previews.
    func apply(screenText text: String) {
        apply(Self.read(text))
    }

    private func apply(_ read: (ANSIScreen, DialogParseResult)) {
        screen = read.0
        if result != read.1 { result = read.1 }
        revision += 1
    }

    nonisolated private static func read(_ text: String) -> (ANSIScreen, DialogParseResult) {
        let screen = ANSIScreenDecoder.decode(text)
        return (screen, BlockedDialogParser.parse(screen, program: .claude))
    }

    /// Off the main thread: a screen is decoded and searched for dialogs.
    nonisolated private static func receive(_ text: String) async throws -> (type: String, read: (ANSIScreen, DialogParseResult)?) {
        let message = try JSONDecoder().decode(ScreenMessage.self, from: Data(text.utf8))
        return (message.type, message.type == "screen" ? read(message.text ?? "") : nil)
    }

    /// Reconnects quietly: the conversation works without the screen, and a
    /// card never shows a screen older than the connection.
    private func follow(_ url: URL, token: String) async {
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
            let socket = GatewaySocket(url: url, token: token, maximumMessageSize: 4 << 20)
            self.socket = socket
            do {
                while true {
                    guard case .string(let text) = try await socket.receive() else { continue }
                    let message = try await Self.receive(text)
                    switch message.type {
                    case "screen":
                        if let read = message.read { apply(read) }
                        delay = .seconds(1)
                    case "closed":
                        clear()
                        ended = true
                        return
                    default:
                        break
                    }
                }
            } catch {
                if Task.isCancelled { return }
                clear()
                let status = socket.status
                if status == 401 || status == 404 {
                    ended = true
                    return
                }
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func clear() {
        screen = nil
        result = .none
    }
}

private struct ScreenMessage: Decodable, Sendable {
    let type: String
    let text: String?
}

extension GatewayConfig {
    func screenURL(session: String) -> URL? {
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.path = "/v0/screen"
        components.queryItems = [URLQueryItem(name: "session", value: session)]
        return components.url
    }
}

/// Carries out a dialog plan against the live screen: keys go out one step
/// at a time, and each check waits for a fresh screen that shows it, so a
/// key that lands somewhere unexpected stops the plan before the next.
@MainActor
struct DialogRunner {
    enum Outcome: Equatable {
        /// The dialog left the screen.
        case done
        /// The keys went out but the dialog is still there.
        case unconfirmed
        case failed(String)
    }

    let session: String
    let feed: ScreenFeed
    let press: ([String]) async -> GatewayClient.KeysResult
    /// Whether the Agent works now, which means the dialog was answered:
    /// the Gateway sends no screen while it works.
    let agentWorking: () -> Bool

    /// How long a check waits for its screen. Core presses a key once the
    /// terminal has been still for about 3 seconds (ADR 0004).
    var timeout = Duration.seconds(8)

    func run(_ plan: DialogActionPlan, on dialog: BlockedDialog) async -> Outcome {
        guard !plan.steps.contains(where: { if case .paste = $0 { true } else { false } }) else {
            return .failed(String(localized: "This answer needs typing. Finish it on the computer"))
        }
        guard feed.result.fingerprint?.matches(dialog.fingerprint) == true else {
            return .failed(String(localized: "The dialog in the terminal changed. Check what it shows now"))
        }
        // Screens after this one count; the screen a key brings can arrive
        // before the reply to the key does.
        var since = feed.revision
        for step in plan.steps {
            switch step {
            case .keys(let keys):
                since = feed.revision
                switch await press(keys) {
                case .pressed: break
                case .failed(let kind, let message):
                    let reason = switch kind {
                    case "not_found", "finished": String(localized: "The session has ended")
                    case "unavailable", "machine_unknown": String(localized: "Not connected, or herdr-core is unavailable")
                    default: message
                    }
                    return .failed(reason)
                case .unknown: return .failed(String(localized: "Not sure the key went through. Check on the computer"))
                }
            case .expect(let expectation):
                let met = await waitForScreen(since: since) { observation in
                    expectation.isMet(by: observation, fingerprint: dialog.fingerprint)
                }
                if !met { return .failed(String(localized: "The terminal doesn't look as expected, so key presses stopped. Check on the computer")) }
            case .paste:
                return .failed(String(localized: "This answer needs typing. Finish it on the computer"))
            }
        }
        let confirmed = await waitForScreen(since: since, orWorking: true) { observation in
            plan.confirmation.isMet(by: observation, fingerprint: dialog.fingerprint)
        }
        return confirmed ? .done : .unconfirmed
    }

    /// Waits for a screen after revision `since` that meets `condition`,
    /// checking the latest one at each poll.
    private func waitForScreen(
        since start: Int, orWorking: Bool = false, _ condition: (DialogObservation) -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if orWorking, agentWorking() { return true }
            if feed.revision != start, let screen = feed.screen,
               condition(DialogObservation(screen: screen, program: .claude)) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        return false
    }
}
