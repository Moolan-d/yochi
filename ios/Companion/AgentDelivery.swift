import SwiftUI

/// A Device-local key: Drafts and the latest Delivery belong to one session on
/// one Gateway, so switching either must not leak the other's composer.
enum AgentMessageStore {
    static func key(host: String, session: String) -> String {
        "\(host)|\(session)"
    }

    static func draft(host: String, session: String) -> String {
        UserDefaults.standard.string(forKey: "agent-message.draft.\(key(host: host, session: session))") ?? ""
    }

    static func saveDraft(_ draft: String, host: String, session: String) {
        UserDefaults.standard.set(draft, forKey: "agent-message.draft.\(key(host: host, session: session))")
    }

    static func clearDraft(host: String, session: String) {
        UserDefaults.standard.removeObject(forKey: "agent-message.draft.\(key(host: host, session: session))")
    }

    /// Every queued message kept on this iPhone, by `key(host:session:)`.
    static func allQueued() -> [String: QueuedMessage] {
        let defaults = UserDefaults.standard
        var queued: [String: QueuedMessage] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(queuedPrefix) {
            guard let data = value as? Data, let message = try? JSONDecoder().decode(QueuedMessage.self, from: data) else {
                continue
            }
            queued[String(key.dropFirst(queuedPrefix.count))] = message
        }
        return queued
    }

    static func saveQueued(_ message: QueuedMessage?, key: String) {
        if let message, let data = try? JSONEncoder().encode(message) {
            UserDefaults.standard.set(data, forKey: queuedPrefix + key)
        } else {
            UserDefaults.standard.removeObject(forKey: queuedPrefix + key)
        }
    }

    private static let queuedPrefix = "agent-message.queued."

    #if DEBUG
    /// UI tests start from nothing; several of them share one test session.
    static func clearAllDrafts() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("agent-message.draft.") || key.hasPrefix(queuedPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
    #endif
}

/// An Agent Message held on this iPhone while the Agent works, sent once the
/// turn ends. One per session; kept like the draft, so leaving the page or
/// the app doesn't lose it.
struct QueuedMessage: Codable, Equatable {
    var text: String
    /// The last completed turn when it was queued: the turn it waits for
    /// ends as `turn + 1`.
    let turn: UInt64
    /// Why sending it didn't go through; it then waits for the user.
    var failure: String?

    enum Release: Equatable {
        case wait
        case send
        /// More turns ended than the one it waited for (work went on at the
        /// desktop), or sending failed: the user decides.
        case ask
    }

    /// A slash command such as `/model` or `/effort high`: the Agent's own
    /// command, which must reach it on its own rather than inside a queued
    /// message. A path such as `/Users/me/a.txt` is not one.
    static func isCommand(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.first == "/", !text.contains(where: \.isNewline) else { return false }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let first = name.first, first.isASCII, first.isLowercase else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-_:".contains($0)) }
    }

    /// What to do with it now. A turn that ends waiting on the user (blocked)
    /// keeps it queued until the dialog is handled.
    func release(state: String?, turn now: UInt64) -> Release {
        if failure != nil || now > turn + 1 { return .ask }
        return state == "idle" || state == "done" ? .send : .wait
    }
}

/// The result of one submitted Agent Message, from local draft to a completed turn.
enum AgentDelivery: Equatable {
    case sending(text: String)
    case sent(text: String, turn: UInt64, status: String?, started: Bool?)
    case turnCompleted(text: String, status: String?)
    case failed(text: String, kind: String, message: String)
    case unknown(text: String)

    var text: String {
        switch self {
        case .sending(let text), .sent(let text, _, _, _), .turnCompleted(let text, _),
             .failed(let text, _, _), .unknown(let text):
            text
        }
    }

    var state: String {
        switch self {
        case .sending: String(localized: "Sending…")
        case .sent(_, _, let status, let started): AgentMessagePresentation.accepted(status: status, started: started)
        case .turnCompleted(_, let status): AgentMessagePresentation.afterTurn(status: status)
        case .failed(_, let kind, let message): Self.failure(kind: kind, message: message)
        case .unknown: String(localized: "Result unknown; it may have been sent")
        }
    }

    /// For a shell command: delivered or why not. A shell has no turns, and
    /// core's quiet rule is all `terminal.send` waits for.
    var shellState: String {
        switch self {
        case .sending: String(localized: "Sending…")
        case .sent, .turnCompleted: String(localized: "Delivered")
        case .failed(_, let kind, let message): Self.failure(kind: kind, message: message)
        case .unknown: String(localized: "Result unknown. Check the terminal")
        }
    }

    var symbol: String {
        switch self {
        case .sending: "ellipsis.circle"
        case .sent: "checkmark.circle"
        case .turnCompleted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .turnCompleted: .green
        case .failed: .red
        case .unknown: .orange
        default: .secondary
        }
    }

    /// The kind is the user-facing reason; core and Gateway prose is detail.
    private static func failure(kind: String, message: String) -> String {
        switch kind {
        case "blocked": String(localized: "The Agent is waiting for a confirmation; not sent yet")
        case "not_found", "finished": String(localized: "The session has ended")
        case "machine_unknown", "unavailable": String(localized: "Not connected, or herdr-core is unavailable")
        case "status_mismatch": String(localized: "The Agent's state changed. Try again")
        case "too_long": String(localized: "The message is too long (16 KiB at most)")
        case "invalid_params": String(localized: "The message is empty or invalid")
        case "config": String(localized: "herdr-core's configuration is unavailable")
        default: message.isEmpty ? String(localized: "Couldn't send") : String(localized: "Couldn't send (\(message))")
        }
    }
}
