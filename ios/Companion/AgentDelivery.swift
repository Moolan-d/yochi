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
        case .sending: String(localized: "发送中…")
        case .sent(_, _, let status, let started): AgentMessagePresentation.accepted(status: status, started: started)
        case .turnCompleted(_, let status): AgentMessagePresentation.afterTurn(status: status)
        case .failed(_, let kind, let message): Self.failure(kind: kind, message: message)
        case .unknown: String(localized: "结果未知，可能已发送")
        }
    }

    /// For a shell command: delivered or why not. A shell has no turns, and
    /// core's quiet rule is all `terminal.send` waits for.
    var shellState: String {
        switch self {
        case .sending: String(localized: "发送中…")
        case .sent, .turnCompleted: String(localized: "已送达")
        case .failed(_, let kind, let message): Self.failure(kind: kind, message: message)
        case .unknown: String(localized: "结果未知，请看终端确认")
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
        case "blocked": String(localized: "Agent 正在等待确认，尚未发送")
        case "not_found", "finished": String(localized: "会话已结束")
        case "machine_unknown", "unavailable": String(localized: "未连接或 herdr-core 不可用")
        case "status_mismatch": String(localized: "Agent 状态已变化，请重试")
        case "too_long": String(localized: "消息过长（最多 16 KiB）")
        case "invalid_params": String(localized: "消息为空或参数无效")
        case "config": String(localized: "herdr-core 配置不可用")
        default: message.isEmpty ? String(localized: "发送失败") : String(localized: "发送失败（\(message)）")
        }
    }
}
