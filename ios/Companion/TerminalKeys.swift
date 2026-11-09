import GhosttyTerminal
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
        TerminalKey(id: "ctrl+c", label: "⌃C", symbol: nil, spoken: String(localized: "Control C, interrupt")),
        TerminalKey(id: "tab", label: "⇥", symbol: "arrow.right.to.line", spoken: String(localized: "Tab, complete")),
        TerminalKey(id: "up", label: "↑", symbol: "arrow.up", spoken: String(localized: "Up")),
        TerminalKey(id: "down", label: "↓", symbol: "arrow.down", spoken: String(localized: "Down")),
        TerminalKey(id: "enter", label: "⏎", symbol: "return", spoken: String(localized: "Return")),
        TerminalKey(id: "esc", label: "esc", symbol: nil, spoken: "Esc"),
    ]
}

extension TerminalKey {
    /// The key for the phone's own terminal to encode, as the program's modes
    /// want it, when the takeover can type.
    var press: TerminalKeyPress? {
        switch id {
        case "ctrl+c": TerminalKeyPress(.c, modifiers: .ctrl)
        case "tab": TerminalKeyPress(.tab)
        case "up": TerminalKeyPress(.arrowUp)
        case "down": TerminalKeyPress(.arrowDown)
        case "enter": TerminalKeyPress(.enter)
        case "esc": TerminalKeyPress(.escape)
        default: nil
        }
    }
}

/// A key of the typing key bar, shown when a takeover types straight into
/// the terminal. Pressed through Ghostty, so the program's key modes apply.
struct TypingKey: Identifiable, Equatable {
    enum Action: Equatable {
        case press(TerminalKeyPress)
        /// Ctrl or Alt held for the next key only.
        case sticky(TerminalPublicStickyModifier)
        /// Opens the arrow keys.
        case arrows
    }

    let id: String
    let label: String
    let spoken: String
    let action: Action

    /// The key name `terminal.keys` knows for it, for the rare press the
    /// terminal can't encode; nil for the keys only Ghostty can send.
    var fallbackName: String? {
        switch id {
        case "esc", "tab", "shift+tab", "up", "down", "ctrl+c": id
        default: nil
        }
    }

    private static func key(_ id: String, _ label: String, _ spoken: String, _ press: TerminalKeyPress) -> TypingKey {
        TypingKey(id: id, label: label, spoken: spoken, action: .press(press))
    }

    /// A character any US keyboard types.
    private static func character(_ id: String, _ character: Character, _ spoken: String) -> TypingKey {
        // `TerminalKeyPress(typing:)` is nil only for a character no US key types.
        key(id, String(character), spoken, TerminalKeyPress(typing: character) ?? TerminalKeyPress(.escape))
    }

    /// The three pages, as a terminal user reaches for them: control keys,
    /// then the shell's chords and the characters a phone keyboard buries,
    /// then moving through output.
    static let pages: [[TypingKey]] = [
        [
            key("esc", "esc", String(localized: "Escape"), TerminalKeyPress(.escape)),
            TypingKey(id: "ctrl", label: "ctrl", spoken: String(localized: "Control, for the next key"), action: .sticky(.ctrl)),
            TypingKey(id: "alt", label: "alt", spoken: String(localized: "Option, for the next key"), action: .sticky(.alt)),
            key("tab", "tab", String(localized: "Tab, complete"), TerminalKeyPress(.tab)),
            key("shift+tab", "⇧tab", String(localized: "Shift Tab, previous"), TerminalKeyPress(.tab, modifiers: .shift)),
            TypingKey(id: "arrows", label: "✥", spoken: String(localized: "Arrow Keys"), action: .arrows),
            key("ctrl+c", "^C", String(localized: "Control C, interrupt"), TerminalKeyPress(.c, modifiers: .ctrl)),
        ],
        [
            key("ctrl+d", "^D", String(localized: "Control D, end of input"), TerminalKeyPress(.d, modifiers: .ctrl)),
            key("ctrl+z", "^Z", String(localized: "Control Z, suspend"), TerminalKeyPress(.z, modifiers: .ctrl)),
            key("ctrl+l", "^L", String(localized: "Control L, clear screen"), TerminalKeyPress(.l, modifiers: .ctrl)),
            character("pipe", "|", String(localized: "Vertical bar")),
            character("tilde", "~", String(localized: "Tilde")),
            character("slash", "/", String(localized: "Slash")),
            character("minus", "-", String(localized: "Hyphen")),
        ],
        [
            key("home", "home", String(localized: "Home"), TerminalKeyPress(.home)),
            key("end", "end", String(localized: "End"), TerminalKeyPress(.end)),
            key("pageup", "pgup", String(localized: "Page Up"), TerminalKeyPress(.pageUp)),
            key("pagedown", "pgdn", String(localized: "Page Down"), TerminalKeyPress(.pageDown)),
        ],
    ]

    /// The arrow keys in the popover, laid out as an inverted T.
    static let up = key("up", "↑", String(localized: "Up"), TerminalKeyPress(.arrowUp))
    static let left = key("left", "←", String(localized: "Left"), TerminalKeyPress(.arrowLeft))
    static let down = key("down", "↓", String(localized: "Down"), TerminalKeyPress(.arrowDown))
    static let right = key("right", "→", String(localized: "Right"), TerminalKeyPress(.arrowRight))
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
                    failure = String(localized: "Not sure the key went through. Check the terminal")
                }
            }
            draining = false
        }
    }

    private static func describe(kind: String, message: String) -> String {
        switch kind {
        case "not_found", "finished": String(localized: "Key not delivered: the session has ended")
        case "machine_unknown", "unavailable": String(localized: "Key not delivered: not connected, or herdr-core is unavailable")
        case "timeout": String(localized: "Not sure the key went through. Check the terminal")
        default: String(localized: "Key not delivered: \(message)")
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
        .accessibilityLabel("Terminal Keys")
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
            .accessibilityLabel(keyboardShown ? "Hide Keyboard" : "Show Keyboard")
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
    static let phrases = [String(localized: "Continue"), String(localized: "OK, go with your suggestion"), String(localized: "Stop first, and explain what you plan to do next")]

    static func insert(_ command: String, into draft: String) -> String {
        if draft.isEmpty { return command }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + command : draft + " " + command
    }
}
