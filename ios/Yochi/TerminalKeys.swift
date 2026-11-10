import GhosttyTerminal
import Observation
import SwiftUI

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

/// Text the composer can fill in; the user still taps send.
enum QuickCommand {
    static let phrases = [String(localized: "Continue"), String(localized: "OK, go with your suggestion"), String(localized: "Stop first, and explain what you plan to do next")]

    static func insert(_ command: String, into draft: String) -> String {
        if draft.isEmpty { return command }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + command : draft + " " + command
    }
}
