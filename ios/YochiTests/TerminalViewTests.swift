import XCTest
@testable import Yochi

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

    /// Typing on a takeover goes back as Ghostty encoded it; Ghostty's own
    /// replies to the program's queries (herdr-core already answered them)
    /// and taps' clicks don't.
    func testOnlyTypingGoesBackToTheProgram() {
        for key in ["ls\t", "\r", "\u{7f}", "\u{03}", "\u{1b}", "\u{1b}x", "\u{1b}[A", "\u{1b}OA", "\u{1b}[Z",
                    "\u{1b}[3~", "\u{1b}[1;5C", "\u{1b}[99;5u", "\u{1b}[13u", "\u{1b}[<64;10;5M", "é", "\u{1b}["] {
            XCTAssertEqual(TerminalInput.typed(in: Data(key.utf8)), Data(key.utf8), key.debugDescription)
        }
        let replies = ["\u{1b}[?62;22c", "\u{1b}[>1;10;0c", "\u{1b}[0n", "\u{1b}[12;40R", "\u{1b}[?2026;2$y",
                       "\u{1b}[?0u", "\u{1b}]11;rgb:2121/2121/2121\u{1b}\\", "\u{1b}]10;rgb:0/0/0\u{07}",
                       "\u{1b}P>|ghostty 1.2\u{1b}\\", "\u{1b}_Gi=1;OK\u{1b}\\", "\u{1b}[8;24;80t", "\u{1b}[I", "\u{1b}[O",
                       "\u{1b}[<0;10;5M", "\u{1b}[<0;10;5m", "\u{1b}[<35;10;5M", "\u{1b}[M !!", "\u{1b}]52;c;"]
        for reply in replies {
            XCTAssertNil(TerminalInput.typed(in: Data(reply.utf8)), reply.debugDescription)
        }
        // A reply written beside a keystroke leaves the keystroke.
        XCTAssertEqual(TerminalInput.typed(in: Data(("\u{1b}[?62c" + "a" + "\u{1b}[<0;1;1M" + "\r").utf8)), Data("a\r".utf8))
    }

    /// The window is open while the terminal has the keyboard, and for a
    /// moment after a key-bar press.
    func testTypingWindowFollowsTheKeyboardAndKeyPresses() async throws {
        let window = TypingWindow()
        XCTAssertFalse(window.isOpen)
        window.setFocused(true)
        XCTAssertTrue(window.isOpen)
        window.setFocused(false)
        XCTAssertFalse(window.isOpen)
        window.keyPressed()
        XCTAssertTrue(window.isOpen)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(window.isOpen)
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
