import XCTest
@testable import Companion

final class TerminalViewTests: XCTestCase {
    func testTextSizeStaysInRange() {
        XCTAssertEqual(TerminalTextSize.clamped(3), TerminalTextSize.range.lowerBound)
        XCTAssertEqual(TerminalTextSize.clamped(20), TerminalTextSize.range.upperBound)
        XCTAssertEqual(TerminalTextSize.clamped(11), 11)
    }

    func testPhoneGridIsTheWholeCellsInsideThePadding() {
        let padding = CGSize(width: 6, height: 4)
        let cell = CGSize(width: 5.5, height: 11)
        // 402 − 12 = 390 points: 70.9 cells across; 600 − 8 = 592: 53.8 rows.
        XCTAssertEqual(TerminalGrid.fitting(CGSize(width: 402, height: 600), cell: cell, padding: padding),
                       TerminalGrid(cols: 70, rows: 53))
        // Exactly 70 cells must not be floored to 69 by rounding.
        XCTAssertEqual(TerminalGrid.fitting(CGSize(width: 12 + 70 * 5.5, height: 8 + 3 * 11), cell: cell, padding: padding),
                       TerminalGrid(cols: 70, rows: 3))
        XCTAssertNil(TerminalGrid.fitting(CGSize(width: 15, height: 600), cell: cell, padding: padding))
        XCTAssertNil(TerminalGrid.fitting(CGSize(width: 402, height: 600), cell: .zero, padding: padding))
    }

    @MainActor
    func testPhoneGridWaitsForAMeasuredCell() {
        TerminalCell.forget()
        XCTAssertNil(TerminalCell.grid(fitting: CGSize(width: 402, height: 600), fontSize: 9))
        TerminalCell.remember(CGSize(width: 5.5, height: 11), fontSize: 9)
        XCTAssertEqual(TerminalCell.grid(fitting: CGSize(width: 402, height: 600), fontSize: 9),
                       TerminalGrid(cols: 70, rows: 53))
        XCTAssertNil(TerminalCell.grid(fitting: CGSize(width: 402, height: 600), fontSize: 10))
        TerminalCell.forget()
    }

    func testTakeoverAsksForThePhonesGrid() throws {
        let config = GatewayConfig(host: "127.0.0.1:9", token: "t")
        let watch = try XCTUnwrap(config.observeURL(session: "t1"))
        XCTAssertEqual(URLComponents(url: watch, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "session", value: "t1"), URLQueryItem(name: "lang", value: GatewayConfig.language)])
        let take = try XCTUnwrap(config.observeURL(session: "t1", takeover: TerminalGrid(cols: 49, rows: 45)))
        XCTAssertEqual(URLComponents(url: take, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "session", value: "t1"), URLQueryItem(name: "takeover", value: "1"),
            URLQueryItem(name: "cols", value: "49"), URLQueryItem(name: "rows", value: "45"),
            URLQueryItem(name: "lang", value: GatewayConfig.language),
        ])
        let resumable = try XCTUnwrap(config.observeURL(session: "t1", resumable: true))
        XCTAssertEqual(URLComponents(url: resumable, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "session", value: "t1"), URLQueryItem(name: "resumable", value: "1"),
                        URLQueryItem(name: "lang", value: GatewayConfig.language)])
        // Coming back names only the stream and how far the phone got.
        let back = try XCTUnwrap(config.observeURL(session: "t1", takeover: TerminalGrid(cols: 49, rows: 45),
                                                   resume: "tok", offset: 1234))
        XCTAssertEqual(URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "session", value: "t1"), URLQueryItem(name: "resume", value: "tok"),
            URLQueryItem(name: "offset", value: "1234"), URLQueryItem(name: "lang", value: GatewayConfig.language),
        ])
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

    @MainActor
    func testMouseReportingFollowsTheModeSwitches() {
        let feed = TerminalFeed()
        XCTAssertFalse(feed.reportsMouse)
        feed.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertTrue(feed.reportsMouse)
        XCTAssertFalse(feed.isFullScreen)
        // Several modes in one switch, and one split across chunks.
        feed.receive(Data("\u{1b}[?1000;1002l\u{1b}[?10".utf8))
        XCTAssertFalse(feed.reportsMouse)
        feed.receive(Data("03;1049h".utf8))
        XCTAssertTrue(feed.reportsMouse)
        XCTAssertTrue(feed.isFullScreen)
        feed.receive(Data("\u{1b}[?1003l\u{1b}[?25h".utf8))
        XCTAssertFalse(feed.reportsMouse)
        XCTAssertTrue(feed.isFullScreen)
    }

    /// The text follows the finger between rows: Ghostty a row ahead on the
    /// edge lines come in from, the surface shifted by the rest.
    func testHistoryScrollSplitsIntoRowAndShift() {
        var scroll = HistoryScroll(cell: 10, row: 50, lastRow: 50)
        XCTAssertEqual(scroll.frame.row, 50)
        XCTAssertEqual(scroll.frame.shift, 0)
        scroll.move(by: -4)
        // Older lines come in at the top: row 49, cut 6 points off its top.
        XCTAssertEqual(scroll.frame.row, 49)
        XCTAssertEqual(scroll.frame.shift, -6, accuracy: 0.001)
        scroll.move(by: 1)
        // Newer lines come in at the bottom: row 50, shifted 3 points down.
        XCTAssertEqual(scroll.frame.row, 50)
        XCTAssertEqual(scroll.frame.shift, 3, accuracy: 0.001)
        scroll.move(by: 100)
        XCTAssertEqual(scroll.frame.row, 50)
        XCTAssertTrue(scroll.atRest)
        scroll.move(by: -1000)
        XCTAssertEqual(scroll.position, 0)
        XCTAssertEqual(scroll.frame.row, 0)
    }

    func testAGlideComesToRestOnARow() {
        var scroll = HistoryScroll(cell: 10, row: 50, lastRow: 100)
        scroll.move(by: -3)
        let flick = HistoryGlide(from: scroll, velocity: -1000)
        XCTAssertEqual(flick.target.truncatingRemainder(dividingBy: 10), 0)
        XCTAssertLessThan(flick.target, 497 - 400)
        // Starts at the finger's speed.
        let slope = (flick.position(at: 0.001) - flick.start) / 0.001
        XCTAssertEqual(slope, -1000, accuracy: 30)
        XCTAssertTrue(flick.isDone(at: 10))
        let release = HistoryGlide(from: scroll, velocity: 0)
        XCTAssertEqual(release.target, 500)
        XCTAssertTrue(release.isDone(at: 0.5))
        // A flick past the start of the history stops there.
        XCTAssertEqual(HistoryGlide(from: scroll, velocity: -100_000).target, 0)
    }

    /// Ghostty writes a drag on a full-screen program as wheel reports (or,
    /// without mouse reporting, cursor up and down); only those go back.
    func testOnlyWheelReportsGoBackToTheProgram() {
        let up = "\u{1b}[<64;10;5M", down = "\u{1b}[<65;1;1M", shifted = "\u{1b}[<68;300;40M"
        XCTAssertEqual(TerminalWheel.reports(in: Data((up + down + shifted).utf8)), Data((up + down + shifted).utf8))
        XCTAssertEqual(TerminalWheel.reports(in: Data("\u{1b}[A\u{1b}OB".utf8)), Data("\u{1b}[A\u{1b}OB".utf8))
        // A tap is a click and release: dropped, even beside a wheel report.
        let click = "\u{1b}[<0;10;5M\u{1b}[<0;10;5m"
        XCTAssertEqual(TerminalWheel.reports(in: Data((click + up).utf8)), Data(up.utf8))
        for other in [click, "\u{1b}[<35;10;5M", "\u{1b}[<64;10;5m", "\u{1b}[<64;10;5", "\u{1b}[<64;;5M",
                      "ls\r", "\u{1b}[C", "\u{1b}[M`!!", "\u{1b}[<64;12345;5M"] {
            XCTAssertNil(TerminalWheel.reports(in: Data(other.utf8)), other.debugDescription)
        }
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
