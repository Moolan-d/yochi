import XCTest
@testable import Companion

final class TerminalViewTests: XCTestCase {
    func testTextSizeStaysInRange() {
        XCTAssertEqual(TerminalTextSize.clamped(3), TerminalTextSize.range.lowerBound)
        XCTAssertEqual(TerminalTextSize.clamped(20), TerminalTextSize.range.upperBound)
        XCTAssertEqual(TerminalTextSize.clamped(11), 11)
    }

    @MainActor
    func testFullScreenFollowsTheAlternateScreenSwitches() {
        let feed = TerminalFeed()
        XCTAssertFalse(feed.isFullScreen)
        feed.receive(Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(feed.isFullScreen)
        // The core's first paint turns the modes off before replaying the screen:
        // the last switch is what the program currently uses.
        feed.receive(Data("\u{1b}[?1049l\u{1b}[?1049h".utf8))
        XCTAssertTrue(feed.isFullScreen)
        feed.receive(Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(feed.isFullScreen)
    }

    @MainActor
    func testFullScreenSwitchSplitAcrossChunksIsStillRead() {
        let feed = TerminalFeed()
        feed.receive(Data("\u{1b}[?10".utf8))
        feed.receive(Data("49h".utf8))
        XCTAssertTrue(feed.isFullScreen)
    }

    func testSelectionPrefersThePressedWord() {
        let text = "cd ~/app\nswift build\n"
        let word = (text as NSString).range(of: "swift build")
        XCTAssertEqual(TerminalTextSelection.initialText(text, anchor: word), "swift build")
        // Nothing under the finger, or a range core no longer matches: select all.
        XCTAssertEqual(TerminalTextSelection.initialText(text, anchor: nil), text)
        XCTAssertEqual(TerminalTextSelection.initialText(text, anchor: NSRange(location: 900, length: 1)), text)
    }
}
