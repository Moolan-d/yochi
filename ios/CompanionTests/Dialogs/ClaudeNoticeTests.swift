import Testing

@testable import Companion

/// Claude Code's notices and panels with no numbered options: the card
/// shows their words and offers only the keys their footer names.
struct ClaudeNoticeTests {
    private static let accent = SGR.fg(177, 185, 249)
    private static let gray = SGR.fg(153, 153, 153)

    /// The auto mode notice from a phone report, rebuilt row by row.
    private static func notice(footer: String) -> ANSIScreen {
        ScreenFixture.synthetic([
            "  ⎿  $ ps -axo pid,rss,comm | head -30",
            "",
            accent + String(repeating: "─", count: 80) + SGR.reset,
            "  " + SGR.bold + accent + "We're changing auto mode to no longer charge for classifier requests." + SGR.reset,
            "",
            "  However, this session isn't eligible.",
            "",
            "  Nothing breaks: auto mode keeps working.",
            "",
            "  " + SGR.italic + gray + footer + SGR.reset,
        ])
    }

    @Test("A notice offers the Enter and Esc its footer names (synthetic)")
    func notice() throws {
        let excerpt = try #require(ClaudeDialogParser.parse(Self.notice(footer: "Enter to continue · Esc to cancel")).excerpt)
        #expect(excerpt.keys == [DialogKeyHint(key: "Enter", action: "continue"), DialogKeyHint(key: "Esc", action: "cancel")])
        #expect(excerpt.rows.first?.trimmedText.hasPrefix("───") == true)
        #expect(excerpt.rows.contains { $0.trimmedText.hasPrefix("We're changing auto mode") })
        #expect(!excerpt.rows.contains { $0.trimmedText.hasPrefix("⎿") })
    }

    @Test("A notice whose footer names no Esc is not read (synthetic)")
    func noticeWithoutEscape() {
        #expect(ClaudeDialogParser.parse(Self.notice(footer: "Enter to continue")) == DialogParseResult.none)
    }

    @Test("A list offers only Esc: Enter would act on a row the reader never chose")
    func releaseNotes() throws {
        let excerpt = try #require(ClaudeDialogParser.parse(try ScreenFixture.screen("claude-45-release-notes")).excerpt)
        #expect(excerpt.keys == [DialogKeyHint(key: "Esc", action: "cancel")])
        #expect(excerpt.rows.contains { $0.trimmedText == "Release notes" })
        #expect(excerpt.rows.last?.trimmedText == "Enter to confirm · Esc to cancel")
    }

    @Test("A screen's fingerprint ignores the footer, so the key check survives a redraw (synthetic)")
    func fingerprint() throws {
        let one = try #require(ClaudeDialogParser.parse(Self.notice(footer: "Enter to continue · Esc to cancel")).excerpt)
        let other = try #require(ClaudeDialogParser.parse(Self.notice(footer: "Enter to continue · Esc to close")).excerpt)
        #expect(one.fingerprint.matches(other.fingerprint))
    }
}
