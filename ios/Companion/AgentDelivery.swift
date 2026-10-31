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
        case .sending: "发送中…"
        case .sent(_, _, let status, let started): AgentMessagePresentation.accepted(status: status, started: started)
        case .turnCompleted(_, let status): AgentMessagePresentation.afterTurn(status: status)
        case .failed(_, let kind, let message): Self.failure(kind: kind, message: message)
        case .unknown: "结果未知，可能已发送"
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
        case "blocked": "Agent 正在等待确认，尚未发送"
        case "not_found", "finished": "会话已结束"
        case "machine_unknown", "unavailable": "未连接或 herdr-core 不可用"
        case "status_mismatch": "Agent 状态已变化，请重试"
        case "too_long": "消息过长（最多 16 KiB）"
        case "invalid_params": "消息为空或参数无效"
        case "config": "herdr-core 配置不可用"
        default: message.isEmpty ? "发送失败" : "发送失败（\(message)）"
        }
    }
}
