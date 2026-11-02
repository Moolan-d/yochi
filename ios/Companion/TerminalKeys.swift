import Observation
import SwiftUI

/// A key the phone can press in a terminal, by core's key name.
struct TerminalKey: Identifiable {
    let id: String
    let label: String
    let symbol: String?
    let spoken: String

    /// What Agent dialogs need: move, choose, confirm, cancel, cycle modes.
    static let bar: [TerminalKey] = [
        TerminalKey(id: "up", label: "↑", symbol: "arrow.up", spoken: "上"),
        TerminalKey(id: "down", label: "↓", symbol: "arrow.down", spoken: "下"),
        TerminalKey(id: "enter", label: "⏎", symbol: "return", spoken: "回车"),
        TerminalKey(id: "esc", label: "esc", symbol: nil, spoken: "Esc"),
        TerminalKey(id: "1", label: "1", symbol: nil, spoken: "1"),
        TerminalKey(id: "2", label: "2", symbol: nil, spoken: "2"),
        TerminalKey(id: "3", label: "3", symbol: nil, spoken: "3"),
        TerminalKey(id: "shift+tab", label: "⇧⇥", symbol: nil, spoken: "Shift Tab，切换模式"),
    ]
}

/// Presses keys in tap order. Taps that arrive while a request is out go in
/// the next request together, so a quick ↓ ↓ ⏎ can never arrive reordered.
@MainActor @Observable
final class KeyPresser {
    private(set) var failure: String?
    private var queued: [String] = []
    private var draining = false

    func press(_ key: String, session: String, client: GatewayClient) {
        queued.append(key)
        guard !draining else { return }
        draining = true
        Task {
            while !queued.isEmpty {
                let batch = Array(queued.prefix(8))
                queued.removeFirst(batch.count)
                switch await client.pressKeys(session: session, keys: batch) {
                case .pressed:
                    failure = nil
                case .failed(let kind, let message):
                    // Later taps assumed this one landed; drop them rather than guess.
                    queued.removeAll()
                    failure = Self.describe(kind: kind, message: message)
                case .unknown:
                    queued.removeAll()
                    failure = "按键结果未知，请看终端确认"
                }
            }
            draining = false
        }
    }

    private static func describe(kind: String, message: String) -> String {
        switch kind {
        case "not_found", "finished": "按键未送达：会话已结束"
        case "machine_unknown", "unavailable": "按键未送达：未连接或 herdr-core 不可用"
        case "timeout": "按键结果未知，请看终端确认"
        default: "按键未送达：\(message)"
        }
    }
}

struct TerminalKeyBar: View {
    /// The composer is the only text input; the last key toggles its keyboard
    /// so the bar stays usable with the keyboard away (as Moshi's toolbar does).
    let keyboardShown: Bool
    let toggleKeyboard: () -> Void
    let press: (TerminalKey) -> Void
    @State private var taps = 0

    init(keyboardShown: Bool, toggleKeyboard: @escaping () -> Void, press: @escaping (TerminalKey) -> Void) {
        self.keyboardShown = keyboardShown
        self.toggleKeyboard = toggleKeyboard
        self.press = press
    }

    var body: some View {
        // Every key fits one row on a phone; at large text sizes the row scrolls instead.
        ViewThatFits(in: .horizontal) {
            row.fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) { row.fixedSize() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("终端按键")
    }

    private var row: some View {
        HStack(spacing: 4) {
            ForEach(TerminalKey.bar) { key in
                Button {
                    taps += 1
                    press(key)
                } label: {
                    Group {
                        if let symbol = key.symbol {
                            Image(systemName: symbol)
                        } else {
                            Text(key.label)
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .buttonStyle(KeyCapStyle())
                .accessibilityLabel(key.spoken)
                .accessibilityIdentifier("key-\(key.id)")
            }
            Button(action: toggleKeyboard) {
                Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .buttonStyle(KeyCapStyle())
            .accessibilityLabel(keyboardShown ? "收起键盘" : "显示键盘")
            .accessibilityIdentifier("toggleKeyboard")
        }
    }
}

/// A key cap that shares the row's width evenly; the system bordered style
/// pads too much for eight keys across a phone.
private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 2)
            .frame(minWidth: 30, maxWidth: .infinity, minHeight: 38)
            .background(Color(.secondarySystemFill), in: .capsule)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(.capsule)
    }
}

/// Text the composer can fill in; the user still taps send.
enum QuickCommand {
    static let phrases = ["继续", "好的，按你的建议做", "先停下，说明你接下来的计划"]
    static let claudeCode = ["/compact", "/clear", "/model", "/context", "/resume"]

    /// Commands that open a selector in the Agent's terminal. Core reports the
    /// Agent as done while it waits there (no structured "blocked"), and the
    /// transcript doesn't record the selector, so only the terminal can finish
    /// them; the app switches to it after sending one of these.
    static let selectors = ["/model", "/resume", "/config", "/permissions", "/mcp", "/agents"]

    /// A bare selector command; with an argument (`/model sonnet`) Claude Code
    /// answers directly and there is nothing to choose.
    static func opensSelector(_ text: String) -> Bool {
        selectors.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func commands(for program: String?) -> [String] {
        program?.localizedCaseInsensitiveContains("claude") == true ? claudeCode : []
    }

    static func commands(for session: Session) -> [String] {
        isClaudeCode(session) ? claudeCode : []
    }

    /// By its own status report, or by the command it was started with.
    static func isClaudeCode(_ session: Session) -> Bool {
        session.status?.app == "claude-code" || !commands(for: session.program).isEmpty
    }

    static func insert(_ command: String, into draft: String) -> String {
        if draft.isEmpty { return command }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + command : draft + " " + command
    }
}
