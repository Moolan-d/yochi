import XCTest
@testable import Companion

@MainActor
final class ObservedTerminalTests: XCTestCase {
    private let content = CGSize(width: 2000, height: 1600)
    private let visible = CGSize(width: 400, height: 800)

    func testCaretNearTopIsVisibleWithoutScrollingDown() {
        let offset = ObservedTerminalScrollView.initialOffset(
            caret: CGRect(x: 10, y: 20, width: 8, height: 16),
            content: content,
            visible: visible
        )
        XCTAssertEqual(offset, .zero)
    }

    func testCaretLowInGridKeepsItsRowNearTheBottom() {
        let offset = ObservedTerminalScrollView.initialOffset(
            caret: CGRect(x: 10, y: 1400, width: 8, height: 16),
            content: content,
            visible: visible
        )
        XCTAssertEqual(offset.x, 0)
        XCTAssertEqual(offset.y, content.height - visible.height)
    }

    func testCaretOnTheRightScrollsHorizontallyIntoView() {
        let offset = ObservedTerminalScrollView.initialOffset(
            caret: CGRect(x: 1500, y: 20, width: 8, height: 16),
            content: content,
            visible: visible
        )
        XCTAssertEqual(offset.x, 1504 - visible.width / 2)
    }

    func testOffsetStaysInsideSmallContent() {
        let offset = ObservedTerminalScrollView.initialOffset(
            caret: CGRect(x: 10, y: 300, width: 8, height: 16),
            content: CGSize(width: 300, height: 400),
            visible: visible
        )
        XCTAssertEqual(offset, .zero)
    }

    /// Ghostty's cell at font size 9 measured 7.33 pt wide on an iPhone 18 Pro (402 pt).
    private let cell: CGFloat = 22.0 / 3

    func testNarrowGridOpensFitted() {
        let fit = 402 / (60 * cell)
        XCTAssertEqual(ObservedTerminalScrollView.defaultZoom(fit: fit, cellWidth: cell), fit)
    }

    func testWideGridOpensAtAReadableSize() {
        let fit = 402 / (200 * cell)
        let zoom = ObservedTerminalScrollView.defaultZoom(fit: fit, cellWidth: cell)
        XCTAssertEqual(zoom * cell, ObservedTerminalScrollView.readableCellWidth, accuracy: 0.001)
    }

    func testGridSmallerThanTheScreenIsNeverShrunk() {
        let fit = 402 / (40 * cell)
        XCTAssertEqual(ObservedTerminalScrollView.defaultZoom(fit: fit, cellWidth: cell), fit)
    }
}
