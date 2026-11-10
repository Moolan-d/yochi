import Foundation
import Testing

@testable import Yochi

/// The captured screens are the dialog parser's only input besides the app
/// itself. These catch the two ways that corpus goes wrong: a capture added
/// without a test, and a parser that answers differently on a second read of
/// the same screen.
@Suite("Captured Claude screens")
struct DialogFixtureTests {
    @Test("Every capture is declared in ScreenFixture")
    func inventory() {
        #expect(ScreenFixture.captured == ScreenFixture.claude.sorted())
    }

    @Test("A capture parses the same way twice", arguments: ScreenFixture.claude)
    func deterministic(stem: String) throws {
        let first = ClaudeDialogParser.parse(try ScreenFixture.screen(stem))
        let second = ClaudeDialogParser.parse(try ScreenFixture.screen(stem))
        #expect(first == second, "\(stem) parsed differently on a second read")
    }
}
