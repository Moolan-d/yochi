import XCTest
@testable import Companion

final class TerminalViewTests: XCTestCase {
    func testTextSizeStaysInRange() {
        XCTAssertEqual(TerminalTextSize.clamped(3), TerminalTextSize.range.lowerBound)
        XCTAssertEqual(TerminalTextSize.clamped(20), TerminalTextSize.range.upperBound)
        XCTAssertEqual(TerminalTextSize.clamped(11), 11)
    }

    func testZoomLabelNamesFittedReadableAndCustom() {
        // Fitted to the screen's width, nothing is cut off.
        XCTAssertEqual(ObservedTerminalScrollView.zoomLabel(scale: 0.5, fit: 0.5, defaultScale: 0.5), "全貌")
        // The default for a wide grid: readable, not fitted.
        XCTAssertEqual(ObservedTerminalScrollView.zoomLabel(scale: 0.9, fit: 0.5, defaultScale: 0.9), "可读")
        // A pinch: report how far past the fitted width it went.
        XCTAssertEqual(ObservedTerminalScrollView.zoomLabel(scale: 1.0, fit: 0.5, defaultScale: 0.9), "200%")
        // Before the surface has a size there is nothing to report.
        XCTAssertEqual(ObservedTerminalScrollView.zoomLabel(scale: 1, fit: 0, defaultScale: 0), "")
    }
}
