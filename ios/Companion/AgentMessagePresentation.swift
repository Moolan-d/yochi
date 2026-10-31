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
}
