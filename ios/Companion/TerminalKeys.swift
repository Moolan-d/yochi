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
    let press: (TerminalKey) -> Void
    @State private var taps = 0

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
        HStack(spacing: 5) {
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
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                }
                .buttonStyle(KeyCapStyle())
                .accessibilityLabel(key.spoken)
                .accessibilityIdentifier("key-\(key.id)")
            }
        }
    }
}

/// A key cap that shares the row's width evenly; the system bordered style
/// pads too much for eight keys across a phone.
private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .frame(minWidth: 32, maxWidth: .infinity, minHeight: 38)
            .background(Color(.secondarySystemFill), in: .capsule)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(.capsule)
    }
}

/// Text the composer can fill in; the user still taps send.
enum QuickCommand {
    static let phrases = ["继续", "好的，按你的建议做", "先停下，说明你接下来的计划"]
    static let claudeCode = ["/compact", "/clear", "/model", "/context", "/resume"]

    static func commands(for program: String?) -> [String] {
        program?.localizedCaseInsensitiveContains("claude") == true ? claudeCode : []
    }

    static func insert(_ command: String, into draft: String) -> String {
        if draft.isEmpty { return command }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + command : draft + " " + command
    }
}
