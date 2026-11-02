import XCTest
@testable import Companion

final class TerminalViewTests: XCTestCase {
    func testTextSizeStaysInRange() {
        XCTAssertEqual(TerminalTextSize.clamped(3), TerminalTextSize.range.lowerBound)
        XCTAssertEqual(TerminalTextSize.clamped(20), TerminalTextSize.range.upperBound)
        XCTAssertEqual(TerminalTextSize.clamped(11), 11)
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
