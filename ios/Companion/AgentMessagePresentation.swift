import Foundation

/// Delivery wording derived only from terminal.send's snapshot and turn rule.
enum AgentMessagePresentation {
    static func accepted(status: String?, started: Bool?) -> String {
        if started == false { return "已发送 · Agent 尚未开始处理" }
        if status == "working" { return "已发送 · Agent 正忙" }
        return "已发送"
    }

    static func afterTurn(status: String?) -> String {
        // A message sent into an already-working turn may have been queued for
        // the next one, so ending this turn is not evidence it was answered.
        status == "working" ? "Agent 已结束一轮" : "Agent 已回应"
    }

    /// What to say after the stop button, or nil when the conversation shows
    /// it anyway (Claude Code records the interruption in its transcript).
    static func stopped(_ result: GatewayClient.InterruptResult) -> String? {
        switch result {
        case .pressed(outcome: "stopped"): nil
        case .pressed(outcome: "still_working"): "Agent 没有停下，可以再按一次"
        case .pressed(outcome: "exited"): "Agent 已退出"
        case .pressed: "已按停止键，无法确认 Agent 是否停下"
        case .failed(_, let message): "停止失败：\(message)"
        case .unknown: "停止结果未知"
        }
    }
}
