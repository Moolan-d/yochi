// Ported from Heeler (https://github.com/ZingerLittleBee/Heeler), Apache-2.0,
// at b9790d8; trimmed to Claude Code's dialogs.

import Foundation
import Testing

@testable import Yochi

/// Captured Agent screens under `Fixtures/screens/`, addressed by stem:
/// `claude-27-n1-narrow-bash` reads `screens/claude/claude-27-n1-narrow-bash.ansi`.
enum ScreenFixture {
    static let claude = [
        "claude-00-trust", "claude-01-ready", "claude-02-c1-bash-blocked", "claude-03-c1-focus-no",
        "claude-03-bash-touch-permission", "claude-04-c1-tab-on-no", "claude-05-c1-pasted-feedback",
        "claude-06-c2-tab-on-yes", "claude-07-c2-pasted", "claude-08-c4-auq-q1",
        "claude-09-c4-toggled", "claude-10-c4-focus-next", "claude-11-c4-q2",
        "claude-12-c4-q2-digit3", "claude-13-c4-q2-pasted", "claude-14-c4-review",
        "claude-15-c9-enterplanmode", "claude-16-c6-exitplan-1", "claude-17-c6-digit3",
        "claude-18-c6-pasted", "claude-19-c6-exitplan-2", "claude-20-c6-pasted-2",
        "claude-21-c6-after", "claude-22-c7-edit", "claude-23-c7-after-esc",
        "claude-24-c8-webfetch", "claude-25-c8-after-digit3", "claude-26-c10-subagent-ask",
        "claude-27-n1-narrow-bash", "claude-28-n1-narrow-bash-later", "claude-29-c3-after-immediate",
        "claude-30-par-first", "claude-31-par-second", "claude-32-c7-phone-bash-blocked",
        "claude-33-c7-phone-focus-no", "claude-34-c7-phone-tab-on-no", "claude-35-c7-phone-pasted-truncated",
        "claude-36-c7-phone-yes-blocked", "claude-37-c7-phone-yes-pasted-wrapped",
        "claude-38-c8-phone-plan-stale-call", "claude-39-c8-phone-question-titled-rule",
        "claude-40-c8-phone-review-titled-rule", "claude-41-c8-phone-question2-padded-rule",
        "claude-42-c8-phone-question-previews", "claude-43-c12-read-file", "claude-44-model-picker",
        "claude-45-release-notes", "claude-46-accept-edits",
    ]

    static let all = claude

    /// The stems of the captures on disk, for the test that checks the list
    /// above covers them.
    static var captured: [String] {
        guard let root = fixtures else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "screens/claude").path))
        return (names ?? []).filter { $0.hasSuffix(".ansi") }.map { String($0.dropLast(".ansi".count)) }.sorted()
    }

    static func path(_ stem: String) -> String {
        "screens/\(program(stem).rawValue)/\(stem).ansi"
    }

    static func text(_ stem: String) throws -> String {
        let url = try #require(fixtures?.appending(path: path(stem)))
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// The test bundle's copy of `Fixtures/`.
    static var fixtures: URL? {
        Bundle(for: Locator.self).url(forResource: "Fixtures", withExtension: nil)
    }

    private final class Locator {}

    static func screen(_ stem: String) throws -> ANSIScreen {
        ANSIScreenDecoder.decode(try text(stem))
    }

    /// The program that drew a capture.
    static func program(_ stem: String) -> ChatProgram {
        .claude
    }

    /// A screen built from raw ANSI rows, for states no capture shows yet.
    static func synthetic(_ rows: [String]) -> ANSIScreen {
        ANSIScreenDecoder.decode(rows.joined(separator: "\r\n"))
    }
}

/// SGR spellings for synthetic rows, matching what the captures use.
enum SGR {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let italic = "\u{1B}[3m"
    static let reverse = "\u{1B}[7m"

    static func fg(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "\u{1B}[38;2;\(red);\(green);\(blue)m"
    }

    static func bg(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "\u{1B}[48;2;\(red);\(green);\(blue)m"
    }

    /// Claude's dark-theme roles.
    static let claudeInactive = fg(153, 153, 153)
    static let claudeAccent = fg(177, 185, 249)
    static let claudePromptBorder = fg(136, 136, 136)

    /// A Claude input-box rule `width` cells wide.
    static func claudeRule(_ width: Int) -> String {
        reset + claudePromptBorder + String(repeating: "─", count: width) + reset
    }
}
