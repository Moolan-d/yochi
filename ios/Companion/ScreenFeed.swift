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

    private var socket: URLSessionWebSocketTask?
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
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Feeds one screen, as the socket does; for tests and previews.
    func apply(screenText text: String) {
        let screen = ANSIScreenDecoder.decode(text)
        self.screen = screen
        result = BlockedDialogParser.parse(screen, program: .claude)
        revision += 1
    }

    /// Reconnects quietly: the conversation works without the screen, and a
    /// card never shows a screen older than the connection.
    private func follow(_ url: URL, token: String) async {
        var delay = Duration.seconds(1)
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.maximumMessageSize = 4 << 20
            self.socket = socket
            socket.resume()
            do {
                while true {
                    guard case .string(let text) = try await socket.receive() else { continue }
                    let message = try JSONDecoder().decode(ScreenMessage.self, from: Data(text.utf8))
                    switch message.type {
                    case "screen":
                        apply(screenText: message.text ?? "")
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
                let status = (socket.response as? HTTPURLResponse)?.statusCode
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

private struct ScreenMessage: Decodable {
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
            return .failed("这个回答要输入文字，请在电脑上完成")
        }
        guard feed.result.fingerprint?.matches(dialog.fingerprint) == true else {
            return .failed("终端里的对话框已变化，请看最新内容")
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
                    case "not_found", "finished": "会话已结束"
                    case "unavailable", "machine_unknown": "未连接或 herdr-core 不可用"
                    default: message
                    }
                    return .failed(reason)
                case .unknown: return .failed("按键结果未知，请在电脑上确认")
                }
            case .expect(let expectation):
                let met = await waitForScreen(since: since) { observation in
                    expectation.isMet(by: observation, fingerprint: dialog.fingerprint)
                }
                if !met { return .failed("终端画面和预期不一致，已停止按键，请在电脑上查看") }
            case .paste:
                return .failed("这个回答要输入文字，请在电脑上完成")
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
