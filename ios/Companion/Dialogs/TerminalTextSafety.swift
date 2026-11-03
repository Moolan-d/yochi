// Ported from Heeler (https://github.com/ZingerLittleBee/Heeler), Apache-2.0,
// at b9790d8; trimmed to Claude Code's dialogs.

import Foundation

/// What arbitrary text may look like before it is typed into a dialog field.
enum TerminalTextSafety {
    /// Tab, line feed, and carriage return are the only control characters
    /// text may carry. Everything else — escapes above all — would be read as
    /// a command by the remote terminal rather than as content.
    static func containsOnlySafeScalars(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                true
            default:
                scalar.properties.generalCategory != .control
            }
        }
    }

    /// Collapses CRLF and lone CR to LF.
    ///
    /// This is the difference that matters for Snippets: the Enter key sends
    /// CR (0x0D), so a carriage return that came in with text pasted from
    /// elsewhere is a submit byte in disguise. LF is not.
    static func normalizingNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// True when `text` contains a CR or LF scalar. Compared on unicode
    /// scalars because Swift treats `"\r\n"` as one `Character`, so a
    /// grapheme `contains("\n")` misses CRLF.
    static func isMultiline(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }
    }
}
