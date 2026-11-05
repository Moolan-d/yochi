import Foundation

/// Delivery wording derived only from terminal.send's snapshot and turn rule.
enum AgentMessagePresentation {
    static func accepted(status: String?, started: Bool?) -> String {
        if started == false { return String(localized: "Sent · the Agent hasn't picked it up yet") }
        if status == "working" { return String(localized: "Sent · the Agent is busy") }
        return String(localized: "Sent")
    }

    static func afterTurn(status: String?) -> String {
        // A message sent into an already-working turn may have been queued for
        // the next one, so ending this turn is not evidence it was answered.
        status == "working" ? String(localized: "Agent finished a turn") : String(localized: "Agent responded")
    }

    /// What to say after the stop button, or nil when the conversation shows
    /// it anyway (Claude Code records the interruption in its transcript).
    static func stopped(_ result: GatewayClient.InterruptResult) -> String? {
        switch result {
        case .pressed(outcome: "stopped"): nil
        case .pressed(outcome: "still_working"): String(localized: "The Agent didn't stop. You can press again")
        case .pressed(outcome: "exited"): String(localized: "Agent exited")
        case .pressed: String(localized: "Pressed stop, but can't tell whether the Agent stopped")
        case .failed(_, let message): String(localized: "Couldn't stop: \(message)")
        case .unknown: String(localized: "Not sure whether it stopped")
        }
    }
}
