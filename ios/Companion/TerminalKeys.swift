import Observation
import SwiftUI

/// A key the phone can press in a terminal, by core's key name.
struct TerminalKey: Identifiable {
    let id: String
    let label: String
    let symbol: String?
    let spoken: String

    /// What a shell needs beside the command line: stop, complete, recall
    /// history, confirm, cancel. Agents are driven from the conversation.
    static let bar: [TerminalKey] = [
        TerminalKey(id: "ctrl+c", label: "⌃C", symbol: nil, spoken: String(localized: "Control C，中断")),
        TerminalKey(id: "tab", label: "⇥", symbol: "arrow.right.to.line", spoken: String(localized: "Tab，补全")),
        TerminalKey(id: "up", label: "↑", symbol: "arrow.up", spoken: String(localized: "上")),
        TerminalKey(id: "down", label: "↓", symbol: "arrow.down", spoken: String(localized: "下")),
        TerminalKey(id: "enter", label: "⏎", symbol: "return", spoken: String(localized: "回车")),
        TerminalKey(id: "esc", label: "esc", symbol: nil, spoken: "Esc"),
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
                    failure = String(localized: "按键结果未知，请看终端确认")
                }
            }
            draining = false
        }
    }

    private static func describe(kind: String, message: String) -> String {
        switch kind {
        case "not_found", "finished": String(localized: "按键未送达：会话已结束")
        case "machine_unknown", "unavailable": String(localized: "按键未送达：未连接或 herdr-core 不可用")
        case "timeout": String(localized: "按键结果未知，请看终端确认")
        default: String(localized: "按键未送达：\(message)")
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
/// pads too much for seven keys across a phone.
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
    static let phrases = [String(localized: "继续"), String(localized: "好的，按你的建议做"), String(localized: "先停下，说明你接下来的计划")]

    static func insert(_ command: String, into draft: String) -> String {
        if draft.isEmpty { return command }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + command : draft + " " + command
    }
}
