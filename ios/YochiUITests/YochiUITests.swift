import XCTest

/// Drives the app against a throwaway Gateway. Run through scripts/ui-test.sh,
/// which gives each test the Gateway's address, a fresh pairing code and the
/// dedicated echo terminal (YOCHI_HOST, YOCHI_CODE, YOCHI_SESSION).
final class YochiUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPairObserveAndUnpair() throws {
        let app = launchUnpaired()

        // A wrong code is refused without using up the real one.
        pair(app, host: env("YOCHI_HOST"), code: "AAAA-AAAA")
        XCTAssert(text(app, containing: "配对码不正确").waitForExistence(timeout: 10))
        snapshot("1 wrong code")

        pair(app, host: nil, code: env("YOCHI_CODE"))
        waitUntilPaired(app)
        XCTAssert(app.searchFields.firstMatch.waitForExistence(timeout: 15), "no home page")
        snapshot("2 home")
        // The echo terminal: an Agent's session would open its conversation instead.
        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 15), "no sessions after pairing")
        snapshot("2 sessions")

        session.tap()
        XCTAssert(text(app, containing: "终端 ·").waitForExistence(timeout: 10))
        // The subtitle gains the phone-sized grid once the terminal is attached.
        let gridTitle = text(app, containing: "×")
        XCTAssert(gridTitle.waitForExistence(timeout: 15), "terminal never attached")
        if let range = gridTitle.label.range(of: #"\d+×\d+"#, options: .regularExpression) {
            let columns = gridTitle.label[range].split(separator: "×").first.flatMap { Int($0) }
            // The echo terminal is 200 columns; a phone at this font fits
            // about 55, so this is what shows the screen was reflowed.
            XCTAssertNotNil(columns)
            XCTAssertLessThan(columns ?? 999, 100, "terminal did not reflow: \(gridTitle.label)")
        } else {
            XCTFail("no grid in the title: \(gridTitle.label)")
        }
        snapshot("3 observe")

        // The terminal's text size is a phone-side preference; changing it
        // rebuilds the surface and attaches again for core's exact screen.
        // The menu stays open while the size steps; its header follows.
        app.buttons["moreMenu"].tap()
        XCTAssert(text(app, containing: "字号 · 9 pt").waitForExistence(timeout: 5), "no text size header")
        XCTAssertFalse(app.buttons["恢复默认字号"].isEnabled, "the default size can be restored at the default")
        snapshot("3 more menu")
        app.buttons["增大字号"].tap()
        XCTAssert(text(app, containing: "字号 · 10 pt").waitForExistence(timeout: 5),
                  "the menu closed or kept the old size after a step")
        snapshot("3 larger text")
        app.buttons["恢复默认字号"].tap()
        XCTAssert(text(app, containing: "字号 · 9 pt").waitForExistence(timeout: 5), "the default size was not restored")
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15),
                  "terminal did not re-attach after the font size change")

        // A long press opens the visible rows in a selectable sheet; Copy is
        // one tap and confirms on the terminal page.
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        XCTAssert(terminal.waitForExistence(timeout: 10), "terminal grid is not accessible")
        terminal.press(forDuration: 1.0)
        XCTAssert(text(app, containing: "选取文字").waitForExistence(timeout: 5), "no selection sheet")
        XCTAssert(app.buttons["copyTerminalSelection"].waitForExistence(timeout: 5))
        app.buttons["copyTerminalSelection"].tap()
        XCTAssert(text(app, containing: "已复制").waitForExistence(timeout: 5), "no copy confirmation")
        snapshot("3 copied")

        app.navigationBars.buttons.firstMatch.tap()

        endSearch(app)
        app.buttons["home.settings"].tap()
        XCTAssert(app.buttons["settings.gateway"].waitForExistence(timeout: 5), "no Gateway row in settings")
        snapshot("4 settings")
        app.buttons["settings.gateway"].tap()
        XCTAssert(app.staticTexts["设备 ID"].waitForExistence(timeout: 5))
        snapshot("4 gateway settings")
        app.buttons["取消配对"].tap()
        XCTAssert(app.sheets["取消与此 Gateway 的配对？"].waitForExistence(timeout: 5))
        snapshot("5 unpair prompt")
        app.buttons["保留配对"].tap()
        XCTAssert(app.staticTexts["设备 ID"].exists, "keeping the pairing dropped it")
        app.buttons["取消配对"].tap()
        confirm(app, "取消配对")
        XCTAssert(app.textFields["配对码"].waitForExistence(timeout: 10), "pairing form did not return")
        snapshot("6 unpaired")

        // Settings opens before pairing too, with nothing to show for the Gateway.
        app.buttons["设置"].tap()
        let notPaired = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "未配对")).firstMatch
        XCTAssert(notPaired.waitForExistence(timeout: 5), "unpaired settings did not open")
        XCTAssertFalse(app.buttons["settings.gateway"].exists, "unpaired settings offered a Gateway page")
        snapshot("7 unpaired settings")
        app.buttons["完成"].tap()
        XCTAssert(app.textFields["配对码"].waitForExistence(timeout: 5), "unpaired settings did not close")
    }

    /// Opening the terminal takes it over at the phone's grid, so a
    /// full-screen program draws for the phone itself instead of being shown
    /// as the desktop drew it; coming back takes it over again.
    @MainActor
    func testFullScreenDrawsForThePhone() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("YOCHI_ALT_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no full-screen session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        snapshot("1 drawn for the phone")
        // The program prints its own size whenever it changes: the phone's
        // grid, which is also the one on screen.
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        let grid = try XCTUnwrap(titleGrid(app), "no grid in the title")
        XCTAssertLessThan(grid.cols, 100, "the terminal kept the desktop's grid")
        XCTAssertEqual(try viewportNumbers(app, terminal), [grid.rows, grid.cols],
                       "the full-screen program did not draw at the phone's grid")
        XCTAssertFalse(app.buttons["terminalTakeOver"].exists, "the desktop seemed to take the terminal back")

        // Leaving lets go; coming back takes it over at the same grid again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached again")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        XCTAssertEqual(try viewportNumbers(app, terminal), [grid.rows, grid.cols],
                       "coming back did not take the terminal over again")
        leaveAndUnpair(app)
    }

    /// The grid on screen as the title shows it (`…·46×30`).
    @MainActor
    private func titleGrid(_ app: XCUIApplication) -> TerminalGridValue? {
        let label = text(app, containing: "×").label
        guard let match = label.firstMatch(of: /(\d+)×(\d+)/),
              let cols = Int(match.1), let rows = Int(match.2) else { return nil }
        return TerminalGridValue(cols: cols, rows: rows)
    }

    private struct TerminalGridValue { let cols: Int; let rows: Int }

    /// Dragging down reveals earlier output. The history terminal printed
    /// 1…400, so the viewport starts near 400; the long-press sheet reads it.
    @MainActor
    func testTerminalScrollsHistory() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("YOCHI_HISTORY_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no history session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        let before = try viewportNumbers(app, terminal)
        snapshot("1 bottom")

        for _ in 0..<3 {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        RunLoop.current.run(until: .now.addingTimeInterval(1))
        snapshot("2 dragged")
        let after = try viewportNumbers(app, terminal)
        XCTAssertLessThan(after.max() ?? .max, before.min() ?? 0,
                          "dragging did not scroll into history: \(before.min() ?? -1)… → \(after.max() ?? -1)")
        // Off the bottom, one tap goes back to the newest output.
        let latest = app.buttons["terminalScrollToLatest"]
        XCTAssert(latest.waitForExistence(timeout: 5), "no way back to the newest output")
        snapshot("3 back to latest offered")
        latest.tap()
        XCTAssert(latest.waitForNonExistence(timeout: 5), "still away from the newest output")
        XCTAssertGreaterThanOrEqual(try viewportNumbers(app, terminal).max() ?? 0, before.min() ?? .max,
                                    "did not return to the newest output")
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// A full-screen program keeps its history itself, as Claude Code does:
    /// on the alternate screen with mouse reporting on, it scrolls only on
    /// wheel reports. Taken over, dragging must reach it as the wheel. The
    /// wheel terminal shows 1…400 and starts at 400.
    @MainActor
    func testFullScreenScrollsHistory() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("YOCHI_WHEEL_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no wheel session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        snapshot("1 bottom")

        // Drag before anything else touches the terminal: a tap or long press
        // places Ghostty's pointer, and a finger's scroll must not need one.
        for _ in 0..<3 {
            terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        RunLoop.current.run(until: .now.addingTimeInterval(1))
        snapshot("2 dragged")
        // The program starts at its newest line, 400.
        let after = try viewportNumbers(app, terminal)
        XCTAssertLessThan(after.max() ?? .max, 400, "dragging did not scroll the program's history: \(after)")
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// The numbers on screen, read through the long-press selection sheet.
    @MainActor
    private func viewportNumbers(_ app: XCUIApplication, _ terminal: XCUIElement) throws -> [Int] {
        let numbers = try viewportText(app, terminal).split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertFalse(numbers.isEmpty, "no numbers in the viewport")
        return numbers
    }

    /// The visible rows, as the long-press selection sheet shows them.
    @MainActor
    private func viewportText(_ app: XCUIApplication, _ terminal: XCUIElement) throws -> String {
        terminal.press(forDuration: 1.0)
        let view = app.textViews.firstMatch
        XCTAssert(view.waitForExistence(timeout: 5), "no selection sheet")
        let text = (view.value as? String) ?? ""
        app.buttons["取消"].tap()
        XCTAssert(view.waitForNonExistence(timeout: 5), "selection sheet did not close")
        return text
    }

    @MainActor
    func testInviteLinkReplacesPairing() throws {
        let app = launchUnpaired()
        let host = env("YOCHI_HOST")
        pair(app, host: host, code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        // Through the system, as a scanned QR code would (`app.open` relaunches the app).
        XCUIDevice.shared.system.open(URL(string: "yochi://pair?host=\(host)&code=ZZZZ-ZZZZ")!)
        // iOS may first ask whether to open the link in Yochi.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons.matching(NSPredicate(format: "label IN {'打开', 'Open'}")).firstMatch
        waitForReplacePrompt(app, open: open)
        app.buttons["保留当前配对"].tap()
        XCTAssert(app.buttons["home.settings"].waitForExistence(timeout: 5), "keeping the pairing dropped it")
        XCTAssert(app.searchFields.firstMatch.exists, "the Inbox is gone after keeping the pairing")
        XCUIDevice.shared.system.open(URL(string: "yochi://pair?host=\(host)&code=ZZZZ-ZZZZ")!)
        waitForReplacePrompt(app, open: open)
        snapshot("1 replace prompt")
        confirm(app, "配对新的 Gateway")

        let code = app.textFields["配对码"]
        XCTAssert(code.waitForExistence(timeout: 10), "pairing form did not open")
        XCTAssertEqual(code.value as? String, "ZZZZ-ZZZZ")
        XCTAssertEqual(app.textFields["地址"].value as? String, host)
        snapshot("2 prefilled form")
    }

    /// Off the tailnet (the link's address goes nowhere), the phone pairs and
    /// watches a terminal through the Relay, end-to-end encrypted.
    @MainActor
    func testPairAndObserveOverRelay() throws {
        // ui-test.sh turns the Gateway's tailnet off, so the link has only the
        // Relay; 15 s after pairing it turns the tailnet back on.
        let app = launchUnpaired()
        let link = try XCTUnwrap(URL(string: env("YOCHI_LINK")))
        XCTAssertFalse(link.absoluteString.contains("host="), "the link still names a tailnet address")
        XCUIDevice.shared.system.open(link)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons.matching(NSPredicate(format: "label IN {'打开', 'Open'}")).firstMatch
        let pair = app.buttons["配对"]
        let deadline = Date.now.addingTimeInterval(10)
        while !(pair.exists && pair.isEnabled), Date.now < deadline {
            if open.exists { open.tap() }
            RunLoop.current.run(until: .now.addingTimeInterval(0.3))
        }
        XCTAssert(pair.isEnabled, "the link did not fill the form")
        pair.tap()
        XCTAssert(app.buttons["home.settings"].waitForExistence(timeout: 30), "pairing through the Relay did not finish")

        app.buttons["home.settings"].tap()
        app.buttons["settings.gateway"].tap()
        let path = app.descendants(matching: .any)["gateway.path"]
        XCTAssert(path.waitForExistence(timeout: 10), "no connection path in settings")
        XCTAssert(describes(path, "Relay"), "not connected through the Relay: \(path.label)")
        XCTAssert(describes(app.descendants(matching: .any)["gateway.host"], "仅经 Relay"), "a tailnet address before the Gateway gave one")
        snapshot("1 settings over relay")
        app.buttons["完成"].tap()

        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 15), "no sessions through the Relay")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 20), "terminal never attached through the Relay")
        snapshot("2 observe over relay")
        app.navigationBars.buttons.firstMatch.tap()
        endSearch(app)

        // The Gateway names its tailnet address once the tailnet is back on.
        app.buttons["home.settings"].tap()
        app.buttons["settings.gateway"].tap()
        let onTailnet = NSPredicate { _, _ in self.describes(path, "Tailnet") }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: onTailnet, evaluatedWith: nil)], timeout: 40), .completed,
                       "never moved to the tailnet: \(path.label)")
        XCTAssertFalse(describes(app.descendants(matching: .any)["gateway.host"], "仅经 Relay"), "no tailnet address learned")
        snapshot("3 settings back on tailnet")
        app.buttons["完成"].tap()
        unpair(app)
    }

    /// Whether a settings row shows `text`, as its label or its value.
    private func describes(_ element: XCUIElement, _ text: String) -> Bool {
        element.exists && (element.label.contains(text) || (element.value as? String)?.contains(text) == true)
    }

    @MainActor
    func testAgentMessageIsAccepted() throws {
        let app = launchUnpaired(observing: env("YOCHI_SESSION"))
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)

        // /bin/cat is a terminal, not an Agent: what is sent is a command.
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        run(app, "Yochi UI test")
        snapshot("1 accepted")

        // The result and the cleared draft survive leaving the terminal.
        app.navigationBars.buttons.firstMatch.tap()
        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssert(text(app, containing: "已送达").waitForExistence(timeout: 10))
        let composerAfterReturn = composer(app)
        XCTAssertTrue(waitUntilCleared(composerAfterReturn), "sent message returned as a draft")
        snapshot("2 sent message did not return as a draft")
        leaveAndUnpair(app)
    }

    /// A shell runs what the composer sends; the key bar recalls the last
    /// command and stops a running one. ui-test.sh checks the shell's output.
    @MainActor
    func testShellCommandsRun() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("YOCHI_SHELL_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no shell session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        XCTAssertFalse(app.buttons["composerMenu"].exists, "the terminal offers the Agent's images and phrases")
        snapshot("1 key bar and command field")

        run(app, "echo yochi-$((6*7))")
        snapshot("2 command delivered")
        // Sent from the pencil's field, the keyboard is back on the
        // terminal: ↑ from the arrow keys, then Return.
        pressArrow(app, "up")
        app.keyboards.firstMatch.buttons["Return"].tap()
        XCTAssertFalse(text(app, containing: "按键未送达").waitForExistence(timeout: 3))

        run(app, "sleep 30")
        app.buttons["key-ctrl+c"].tap()
        XCTAssertFalse(text(app, containing: "按键未送达").waitForExistence(timeout: 3))
        run(app, "echo stopped-$((1+1))")
        snapshot("3 interrupted, then ran again")
        // Taken over at the phone's grid while the page shows; the script
        // reads the size the shell saw, and that leaving gave it back.
        run(app, "stty size")
        XCTAssertFalse(app.buttons["terminalTakeOver"].exists, "the desktop seemed to take the terminal back")
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// A takeover types straight into the terminal: the keyboard button
    /// gives the terminal itself the keyboard, what is typed goes to the
    /// shell as typed, and the key bar's keys too. The script reads what
    /// the shell ran.
    @MainActor
    func testTypesIntoTheTerminal() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("YOCHI_SHELL_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no shell session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        let toggle = app.buttons["toggleKeyboard"]
        toggle.tap()
        let shown = NSPredicate(format: "label == %@", "收起键盘")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: shown, evaluatedWith: toggle)], timeout: 5), .completed,
                       "the terminal never took the keyboard")
        snapshot("1 typing into the terminal")

        // The terminal isn't a text field to XCUITest, so `typeText` finds no
        // focus: tap the keys of the keyboard it brought up instead.
        let keyboard = app.keyboards.firstMatch
        func type(_ word: String) {
            for (index, letter) in word.split(separator: " ").enumerated() {
                if index > 0 { keyboard.keys["space"].tap() }
                for key in letter { keyboard.keys[String(key)].tap() }
            }
        }
        type("echo typed")
        keyboard.buttons["Return"].tap()
        // ← from the arrow keys moves the cursor: the shell runs `echo baxr`.
        type("echo br")
        pressArrow(app, "left")
        type("ax")
        keyboard.buttons["Return"].tap()
        snapshot("2 typed and pressed")

        // The pencil writes in the command field, and sending gives the
        // keyboard back to the terminal.
        run(app, "echo composed")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: shown, evaluatedWith: toggle)], timeout: 5), .completed,
                       "the terminal did not get the keyboard back")
        XCTAssertFalse(app.descendants(matching: .any)["terminalCommandField"].exists, "the command field stayed")

        toggle.tap()
        let hidden = NSPredicate(format: "label == %@", "显示键盘")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: hidden, evaluatedWith: toggle)], timeout: 5), .completed,
                       "the keyboard did not go away")
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// Claude Code started by hand in a terminal page turns the page into its
    /// conversation. The More menu switches back to the terminal, where
    /// Claude Code draws at the phone's grid, and leaving gives the desktop
    /// its size back (the script samples both). Its first dialog, if any, is
    /// only looked at, never answered.
    @MainActor
    func testClaudeStartedInTerminal() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("YOCHI_SHELL_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no shell session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        snapshot("1 shell")
        let field = composer(app)
        field.tap()
        field.typeText("~/.local/bin/claude")
        app.buttons["发送命令"].tap()
        // Claude Code starts and the core reports it; the conversation takes the page.
        let message = app.descendants(matching: .any)["agentMessageField"]
        XCTAssert(message.waitForExistence(timeout: 30), "the page did not turn into the conversation")
        XCTAssert(text(app, containing: "对话 ·").exists, "the title does not say conversation")
        snapshot("2 claude as a conversation")

        app.buttons["moreMenu"].tap()
        let terminalPage = app.buttons["终端"]
        XCTAssert(terminalPage.waitForExistence(timeout: 5), "no switch to the terminal")
        terminalPage.tap()
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        XCTAssert(terminal.waitForExistence(timeout: 15), "the terminal page did not come back")
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never re-attached")
        XCTAssertFalse(message.exists, "the conversation stayed")
        snapshot("3 claude in the terminal")
        terminal.press(forDuration: 1.0)
        let view = app.textViews.firstMatch
        XCTAssert(view.waitForExistence(timeout: 5), "no selection sheet")
        XCTAssert(((view.value as? String) ?? "").contains("Claude Code"), "Claude Code is not on the terminal")
        app.buttons["取消"].tap()
        XCTAssert(view.waitForNonExistence(timeout: 5), "selection sheet did not close")
        XCTAssertFalse(app.buttons["terminalTakeOver"].exists, "the desktop seemed to take the terminal back")
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// Sends one command and waits until it is delivered: the field clears
    /// only then, and core waits ~3 s of quiet before it pastes.
    @MainActor
    private func run(_ app: XCUIApplication, _ command: String) {
        // A takeover that types shows its command field from the pencil.
        let typing = app.buttons["toggleComposer"].exists
        let field = composer(app)
        field.tap()
        field.typeText(command)
        app.buttons["发送命令"].tap()
        // A terminal that types puts its command field away once sent.
        XCTAssertTrue(typing ? field.waitForNonExistence(timeout: 25) : waitUntilCleared(field, timeout: 25),
                      "\(command) was not delivered")
        XCTAssert(text(app, containing: "已送达").exists, "\(command): no delivery shown")
    }

    /// An arrow key from the key bar's arrow popover, which is then put away.
    @MainActor
    private func pressArrow(_ app: XCUIApplication, _ name: String) {
        app.buttons["key-arrows"].tap()
        let arrow = app.buttons["key-\(name)"]
        XCTAssert(arrow.waitForExistence(timeout: 5), "no arrow keys")
        arrow.tap()
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if outside.exists { outside.tap() }
        XCTAssert(arrow.waitForNonExistence(timeout: 5), "the arrow keys stayed up")
    }

    @MainActor
    func testAgentMessageDraftSurvivesNavigation() throws {
        let app = launchUnpaired(observing: env("YOCHI_SESSION"))
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)

        let draft = "尚未发送的草稿"
        let field = composer(app)
        field.tap()
        field.typeText(draft)
        let keyboard = app.keyboards.firstMatch
        XCTAssert(keyboard.waitForExistence(timeout: 10), "keyboard never appeared")
        snapshot("1 keyboard up")
        let keyboardKey = app.buttons["toggleKeyboard"]
        XCTAssert(keyboardKey.waitForExistence(timeout: 5), "no keyboard toggle")
        keyboardKey.tap()
        XCTAssert(keyboard.waitForNonExistence(timeout: 10), "keyboard would not go away")
        snapshot("2 keyboard away, keys still there")
        keyboardKey.tap()
        XCTAssert(keyboard.waitForExistence(timeout: 10), "keyboard would not come back")
        keyboardKey.tap()
        XCTAssert(keyboard.waitForNonExistence(timeout: 10), "keyboard would not go away")
        snapshot("3 keyboard dismissed")
        app.navigationBars.buttons.firstMatch.tap()
        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssert(composer(app).waitForExistence(timeout: 10))
        XCTAssertEqual(composer(app).value as? String, draft)
        snapshot("4 restored draft")
        leaveAndUnpair(app)
    }

    /// Needs a real Claude Code in manual permission mode, named
    /// yochi-uitest (YOCHI_AGENT_SESSION); skipped otherwise.
    @MainActor
    func testConversationAnswersAgent() throws {
        guard let agent = ProcessInfo.processInfo.environment["YOCHI_AGENT_SESSION"], !agent.isEmpty else {
            throw XCTSkip("YOCHI_AGENT_SESSION is not set")
        }
        let app = launchUnpaired(observing: agent)
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")
        XCTAssertFalse(app.buttons["终端"].exists, "a Claude Code session still offers the terminal")
        snapshot("1 conversation")

        send(app, "Use the AskUserQuestion tool to ask me: Tea or Coffee? Then reply with my choice in one short sentence.")
        let coffee = app.buttons["option-2"]
        XCTAssert(coffee.waitForExistence(timeout: 90), "no question card")
        snapshot("2 question")
        coffee.tap()
        XCTAssert(text(app, containing: "已选：Coffee").waitForExistence(timeout: 30), "answer not in the conversation")
        XCTAssert(app.buttons["option-2"].waitForNonExistence(timeout: 10), "question card stayed")
        snapshot("3 answered")

        send(app, "Run the shell command: date > stamp.txt")
        let allow = app.buttons["allowPending"]
        XCTAssert(allow.waitForExistence(timeout: 90), "no permission card")
        snapshot("4 permission")
        allow.tap()
        XCTAssert(allow.waitForNonExistence(timeout: 20), "permission card stayed")
        snapshot("5 approved")

        send(app, "Run the shell command: rm stamp.txt")
        let deny = app.buttons["denyPending"]
        XCTAssert(deny.waitForExistence(timeout: 90), "no second permission card")
        deny.tap()
        confirm(app, "拒绝")
        XCTAssert(deny.waitForNonExistence(timeout: 20), "permission card stayed after denying")
        XCTAssert(text(app, containing: "已中断").waitForExistence(timeout: 20))
        snapshot("6 denied")
        leaveAndUnpair(app)
    }

    /// A Claude Code folder trust dialog, read from the screen, answered from
    /// the conversation page. "No, exit" so no setting is saved; Claude Code
    /// exits and its test terminal goes with it.
    @MainActor
    func testDialogFromScreen() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_DIALOG_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_DIALOG_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        XCTAssert(session.waitForExistence(timeout: 15), "no Claude Code session")
        session.tap()
        let card = app.descendants(matching: .any)["dialogCard"]
        XCTAssert(card.waitForExistence(timeout: 20), "no dialog card")
        XCTAssert(text(app, containing: "是否信任这个文件夹").exists)
        snapshot("1 trust dialog")

        let exit = app.buttons["dialogOption-1"]
        XCTAssert(exit.label.contains("No"), "option 1 is \(exit.label)")
        exit.tap()
        confirm(app, "退出 Claude Code")
        XCTAssert(card.waitForNonExistence(timeout: 20), "dialog card stayed")
        snapshot("2 answered")
        leaveAndUnpair(app)
    }

    /// `/model` sent from the phone opens Claude Code's picker as a card on
    /// the conversation page. Paging only moves the focus, and 关闭 presses
    /// Esc, so no model is chosen and nothing is saved.
    @MainActor
    func testPickerFromScreen() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        // The largest text short of the accessibility sizes makes the card
        // taller than the page, as on a phone with bigger text.
        let app = launchUnpaired(textSize: "UICTContentSizeCategoryXXXL")
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        // Big text pushes the session further down the list.
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")
        XCTAssertFalse(app.buttons["终端"].exists, "a Claude Code session still offers the terminal")
        // Claude Code takes a moment to draw its prompt.
        RunLoop.current.run(until: .now.addingTimeInterval(5))
        send(app, "/model")

        let card = app.descendants(matching: .any)["dialogCard"]
        XCTAssert(card.waitForExistence(timeout: 30), "no picker card")
        XCTAssert(text(app, containing: "Claude Code 在等你选择").exists)
        XCTAssert(text(app, containing: "Select model").exists)
        let first = app.buttons["dialogOption-1"]
        XCTAssert(first.exists, "no options")
        let heading = text(app, containing: "Claude Code 在等你选择")
        XCTAssertGreaterThanOrEqual(heading.frame.minY, app.navigationBars.firstMatch.frame.maxY,
                                    "the card runs under the navigation bar")
        XCTAssert(app.buttons["dialogDismiss"].isHittable, "the card's footer is off screen")
        XCTAssert(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard covers the card")
        snapshot("1 picker")

        let down = app.buttons["pickerScrollDown"]
        if down.exists {
            let before = first.label
            down.tap()
            let deadline = Date.now.addingTimeInterval(30)
            while first.label == before, Date.now < deadline {
                RunLoop.current.run(until: .now.addingTimeInterval(0.3))
            }
            XCTAssertNotEqual(first.label, before, "the list did not scroll")
            XCTAssert(app.buttons["pickerScrollUp"].waitForExistence(timeout: 5), "no way back up")
            snapshot("2 scrolled")
        }

        app.buttons["dialogDismiss"].tap()
        XCTAssert(card.waitForNonExistence(timeout: 30), "picker card stayed")
        snapshot("3 closed")
        leaveAndUnpair(app)
    }

    /// A panel with no numbered options shows as the screen's words with
    /// the keys its footer names; a list offers only Esc, never Enter.
    @MainActor
    func testNoticeFromScreen() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")
        // Claude Code takes a moment to draw its prompt.
        RunLoop.current.run(until: .now.addingTimeInterval(5))
        send(app, "/release-notes")

        let card = app.descendants(matching: .any)["genericDialogCard"]
        XCTAssert(card.waitForExistence(timeout: 30), "no card for the release notes")
        XCTAssert(text(app, containing: "Release notes").exists)
        XCTAssertFalse(app.buttons["genericDialogKey-enter"].exists, "a list offers Enter")
        snapshot("1 notes")

        app.buttons["genericDialogCancel"].tap()
        app.buttons["取消（Esc）"].firstMatch.tap()
        XCTAssert(card.waitForNonExistence(timeout: 30), "the card stayed")
        snapshot("2 closed")
        leaveAndUnpair(app)
    }

    /// The mode chip reads Claude Code's mode line and switches with
    /// Shift+Tab. Nothing is sent, and the mode isn't saved anywhere.
    @MainActor
    func testPermissionModeFromScreen() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        let chip = app.buttons["permissionMode"]
        XCTAssert(chip.waitForExistence(timeout: 30), "no mode chip")
        let deadline = Date.now.addingTimeInterval(15)
        while !chip.isEnabled, Date.now < deadline { RunLoop.current.run(until: .now.addingTimeInterval(0.3)) }
        XCTAssert(chip.isEnabled, "the mode chip stays disabled")
        let before = chip.value as? String ?? ""
        snapshot("1 mode")

        let target = before == "计划" ? "普通" : "计划"
        chip.tap()
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", target)).firstMatch
        XCTAssert(option.waitForExistence(timeout: 5), "no \(target) in the menu")
        snapshot("2 menu")
        option.tap()
        let switched = NSPredicate(format: "value == %@", target)
        expectation(for: switched, evaluatedWith: chip)
        waitForExpectations(timeout: 40)
        XCTAssertFalse(app.descendants(matching: .any)["modeFailure"].exists, "the switch reported a failure")
        snapshot("3 switched")
        leaveAndUnpair(app)
    }

    /// A message sent while Claude Code works waits on the phone, can be
    /// taken back into the draft, and goes out once the turn ends. The turn
    /// only sleeps, in a folder under build/.
    @MainActor
    func testMessageQueuedWhileWorking() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")
        // Claude Code takes a moment to draw its prompt.
        RunLoop.current.run(until: .now.addingTimeInterval(5))
        send(app, "In the foreground, not in the background, run the shell command `python3 -c 'import time; time.sleep(40)'`, then reply with just: done")
        XCTAssert(app.buttons["stopAgent"].waitForExistence(timeout: 30), "the Agent never started working")
        XCTAssert(text(app, containing: "工作中 · ").waitForExistence(timeout: 10), "no working timer in the title")

        let field = composer(app)
        field.tap()
        field.typeText("Queued from the phone")
        let queue = app.buttons["排队发送"]
        XCTAssert(queue.exists, "sending while working doesn't queue")
        queue.tap()
        let banner = app.descendants(matching: .any)["queuedMessage"]
        XCTAssert(banner.waitForExistence(timeout: 5), "no queued message")
        XCTAssert(banner.label.contains("排队中"), "the queued message reads \(banner.label)")
        snapshot("1 queued")

        app.buttons["withdrawQueued"].tap()
        XCTAssert(banner.waitForNonExistence(timeout: 5), "withdrawing left it queued")
        XCTAssertEqual(field.value as? String, "Queued from the phone", "the text did not return to the draft")
        if app.buttons["排队发送"].exists {
            app.buttons["排队发送"].tap()
            XCTAssert(banner.waitForExistence(timeout: 5), "no queued message after queuing again")
            XCTAssert(banner.waitForNonExistence(timeout: 120), "the queued message was never sent")
        } else {
            // The turn ended while withdrawing; the plain send still works.
            app.buttons["发送消息"].tap()
        }
        XCTAssert(text(app, containing: "Queued from the phone").waitForExistence(timeout: 30),
                  "the queued message is not in the conversation")
        snapshot("2 sent")
        leaveAndUnpair(app)
    }

    /// A photo from the library is put beside the terminal and named in the
    /// draft by its path; Claude Code reads it from there.
    @MainActor
    func testImageSentToAgent() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")
        RunLoop.current.run(until: .now.addingTimeInterval(5))

        // Text first: tapping a filled field puts the cursor where it lands,
        // and typing into the middle of the path would break it.
        let field = composer(app)
        field.tap()
        field.typeText("Describe this image in at most five words.")
        app.buttons["composerMenu"].tap()
        app.buttons["照片图库"].tap()
        // The system picker's grid; the simulator ships a few photos.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssert(photo.waitForExistence(timeout: 30), "no photo in the library")
        snapshot("1 library")
        photo.tap()
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "添加", "Done", "Add"])).firstMatch
        XCTAssert(done.waitForExistence(timeout: 5), "no way to confirm the picker")
        done.tap()

        let thumbnail = app.descendants(matching: .any)["attachment-1"]
        XCTAssert(thumbnail.waitForExistence(timeout: 20), "no thumbnail")
        let uploaded = NSPredicate(format: "value == %@", "已上传")
        expectation(for: uploaded, evaluatedWith: thumbnail)
        waitForExpectations(timeout: 30)
        let draft = field.value as? String ?? ""
        XCTAssert(draft.hasPrefix("Describe this image in at most five words. /") && draft.hasSuffix(".jpg"),
                  "the draft is \(draft)")
        snapshot("2 attached")

        app.buttons["发送消息"].tap()
        XCTAssert(thumbnail.waitForNonExistence(timeout: 20), "the thumbnail stayed after sending")
        // The Agent took it as a message (not, say, a slash command it refused).
        XCTAssert(text(app, containing: "Describe this image").waitForExistence(timeout: 30),
                  "the message is not in the conversation")
        XCTAssert(app.descendants(matching: .any)["stopAgent"].waitForNonExistence(timeout: 90), "the Agent kept working")
        snapshot("3 described")
        leaveAndUnpair(app)
    }

    /// The DEBUG sample home, at the default text size and an accessibility
    /// one: the Inbox's sections and badge, a pinned Agent with its child,
    /// search by Space and for a shell, a search with no match offering 新建;
    /// then the Spaces tab, a space's page and the terminals in no space.
    @MainActor
    func testHomeSample() throws {
        for size in [nil, "UICTContentSizeCategoryAccessibilityL"] {
            let app = Self.chineseApp()
            if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launchEnvironment["YOCHI_SAMPLE_HOME"] = "1"
            app.launch()
            let suffix = size == nil ? "" : "-large"

            let blocked = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "服务助手页面自动断联后重连卡住")).firstMatch
            XCTAssert(blocked.waitForExistence(timeout: 10), "no blocked Agent")
            XCTAssertEqual(blocked.label, "服务助手页面自动断联后重连卡住，等你处理，要运行 npm test，允许吗？，小程序 · wx-mini · fix-reconnect")
            XCTAssertEqual(blocked.identifier, "session-t1")
            XCTAssert(app.staticTexts["需要你"].exists, "no Needs You section")
            // One Agent waits: the Inbox tab carries 1.
            let inboxTab = app.tabBars.buttons["收件箱"]
            XCTAssert(inboxTab.exists, "no Inbox tab")
            XCTAssert((inboxTab.value as? String)?.hasPrefix("1") == true, "the Inbox badge counts the Agents that need you: \(String(describing: inboxTab.value))")
            XCTAssert(app.tabBars.buttons["Space"].exists, "no Spaces tab")
            if size == nil {
                // Larger text pushes these below the fold, where the list hasn't made them yet.
                let rows = app.cells.buttons.allElementsBoundByIndex.map(\.label)
                let unseen = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("整理日志轮转，完成，未看过，vps · 运维") }, "\(rows)")
                XCTAssertGreaterThan(unseen, try XCTUnwrap(rows.firstIndex { $0.hasPrefix("补单元测试，完成，未看过") }), "\(rows)")
                XCTAssertFalse(rows.contains { $0.hasPrefix("zsh") }, "a shell is in the Inbox: \(rows)")
            }
            snapshot("inbox-top\(suffix)")

            let pinned = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "已置顶，主页改版，工作中，正在写主页列表")).firstMatch
            scrollUntilHittable(pinned, in: app, up: true)
            let child = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查路线图剩余项，子 Agent，工作中")).firstMatch
            XCTAssert(child.exists, "no child Agent")
            XCTAssertLessThan(pinned.frame.minY, child.frame.minY, "the child is not under its parent")
            snapshot("inbox-working\(suffix)")

            for _ in 0..<4 where !app.searchFields.firstMatch.isHittable { app.swipeDown() }
            let search = app.searchFields.firstMatch
            XCTAssert(search.isHittable, "no search field")
            search.tap()
            search.typeText("运维")
            XCTAssert(app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "升级 Caddy 配置")).firstMatch
                .waitForExistence(timeout: 5), "search by space found nothing")
            XCTAssert(app.staticTexts["Agent"].exists, "no Agents section in the results")
            snapshot("inbox-search\(suffix)")
            search.typeText("没有的东西")
            XCTAssert(app.staticTexts["没有匹配「运维没有的东西」的 Agent"].waitForExistence(timeout: 5), "no empty search result")
            XCTAssert(app.buttons["新建"].exists, "no 新建 for an empty search")
            snapshot("inbox-search-empty\(suffix)")
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9))
            search.typeText("zsh")
            let shell = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "zsh，")).firstMatch
            XCTAssert(shell.waitForExistence(timeout: 5), "search did not find the shell")
            XCTAssertEqual(shell.identifier, "session-t5")
            XCTAssert(app.staticTexts["终端"].exists, "no Terminals section in the results")
            snapshot("inbox-search-shell\(suffix)")

            // Spaces.
            if Self.closeSearch(app).exists { Self.closeSearch(app).tap() }
            app.tabBars.buttons["Space"].tap()
            let companion = app.buttons["space-sp1"]
            XCTAssert(companion.waitForExistence(timeout: 5), "no space row")
            XCTAssert(companion.label.hasPrefix("companion，2 个标签页"), companion.label)
            let mini = app.buttons["space-sp2"]
            XCTAssertEqual(mini.label, "小程序，1 个标签页，1 个 Agent 需要你")
            XCTAssert(app.buttons["others-"].exists, "no Other Terminals row")
            snapshot("spaces\(suffix)")
            companion.tap()
            let parent = app.buttons["session-t2"]
            XCTAssert(parent.waitForExistence(timeout: 5), "the space page lists no Agent")
            XCTAssert(app.buttons["session-t5"].exists, "the space page lists no shell")
            XCTAssertLessThan(parent.frame.minY, app.buttons["session-t3"].frame.minY, "the child is not under its parent")
            XCTAssertFalse(app.tabBars.buttons["收件箱"].isHittable && app.tabBars.buttons["收件箱"].frame.height == 0, "tab bar")
            snapshot("space-detail\(suffix)")
            app.navigationBars.buttons.firstMatch.tap()
            let others = app.buttons["others-"]
            XCTAssert(others.waitForExistence(timeout: 5))
            others.tap()
            XCTAssert(app.buttons["session-t9"].waitForExistence(timeout: 5), "Other Terminals lists nothing")
            snapshot("other-terminals\(suffix)")
            app.terminate()
        }
    }

    /// Edit, to-do, subtask and peer cards in the DEBUG sample conversation,
    /// at the default text size and an accessibility one.
    @MainActor
    func testConversationCards() throws {
        for size in [nil, "UICTContentSizeCategoryAccessibilityL"] {
            let app = Self.chineseApp()
            if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launchEnvironment["YOCHI_SAMPLE_CONVERSATION"] = "1"
            app.launch()
            let suffix = size == nil ? "" : "-large"

            let progress = app.descendants(matching: .any)["todoProgress"]
            XCTAssertTrue(progress.waitForExistence(timeout: 10))
            XCTAssertEqual(progress.label, "正在查路线图，已完成 2 项，共 3 项")
            let lists = app.buttons.matching(identifier: "todosRow")
            XCTAssertEqual(lists.count, 2)
            XCTAssertEqual(lists.element(boundBy: 1).value as? String, "已展开")
            XCTAssertEqual(lists.element(boundBy: 0).value as? String, "已收起")
            XCTAssertTrue(app.staticTexts["查路线图"].exists || app.otherElements["查路线图，进行中"].exists
                          || app.descendants(matching: .any)["查路线图，进行中"].exists)
            snapshot("cards-bottom\(suffix)")

            let subtask = app.descendants(matching: .any).matching(identifier: "subtaskRow").firstMatch
            scrollUntilHittable(subtask, in: app)
            XCTAssertEqual(subtask.label, "子任务 查路线图剩余项，运行中")
            let peer = app.buttons.matching(identifier: "peerRow").element(boundBy: 1)
            XCTAssertEqual(peer.label, "来自 web-session：要，网页版下周一起改。先把 iOS 的提交了。")

            let edit = app.buttons.matching(identifier: "editRow").firstMatch
            scrollUntilHittable(edit, in: app)
            XCTAssertTrue(edit.label.hasPrefix("编辑 SessionListView.swift，增加 3 行，删除 1 行，在 /Users/me/app/ios/Yochi"))
            edit.tap()
            let added = app.descendants(matching: .any)["第 43 行，增加：            } description: {"]
            XCTAssertTrue(added.waitForExistence(timeout: 5), "the edit's diff did not open")
            snapshot("cards-edit\(suffix)")
            app.terminate()
        }
    }

    /// The search bar floats over the bottom of the home list, and a row
    /// under it counts as hittable while the bar takes its taps: drag the
    /// list up a little until the row is clear of it.
    @MainActor
    private func clearOfSearchBar(_ element: XCUIElement, in app: XCUIApplication) {
        let bar = app.searchFields.firstMatch
        for _ in 0..<3 where bar.exists && element.frame.maxY > bar.frame.minY - 12 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false) {
        let list = app.scrollViews["conversation"]
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            if up { app.swipeUp() } else { list.swipeDown() }
        }
        XCTAssertTrue(element.isHittable, "\(element) is not on screen")
    }

    /// The Changes page of a session whose directory has a modified and a new
    /// file, one file's diff, and 「让 Agent 提交」 filling the draft.
    @MainActor
    func testChangesPage() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")

        app.buttons["moreMenu"].tap()
        app.buttons["改动"].tap()
        XCTAssert(text(app, containing: "uitest-agent · 相对 HEAD").waitForExistence(timeout: 20), "no changes header")
        let changed = app.buttons["change-app.txt"]
        XCTAssert(changed.exists, "no modified file")
        XCTAssertEqual(changed.label, "app.txt，修改，增加 1 行，删除 1 行")
        XCTAssertEqual(app.buttons["change-notes.md"].label, "notes.md，未跟踪，增加 1 行")
        snapshot("1 changes")

        changed.tap()
        let added = app.descendants(matching: .any)["第 5 行，增加：line five changed"]
        XCTAssert(added.waitForExistence(timeout: 20), "no added line")
        XCTAssert(app.descendants(matching: .any)["第 5 行，删除：line 5"].exists, "no deleted line")
        snapshot("2 diff")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let ask = app.buttons["askToCommit"]
        XCTAssert(ask.waitForExistence(timeout: 5), "no 让 Agent 提交")
        ask.tap()
        let field = composer(app)
        XCTAssert(field.waitForExistence(timeout: 5), "did not return to the conversation")
        XCTAssertEqual(field.value as? String, "请提交这些改动")
        snapshot("3 draft")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        leaveAndUnpair(app)
    }

    @MainActor
    func testSlashCompletion() throws {
        guard let name = ProcessInfo.processInfo.environment["YOCHI_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("YOCHI_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")

        let field = composer(app)
        field.tap()
        field.typeText("/")
        let list = app.descendants(matching: .any)["slashSuggestions"]
        XCTAssert(list.waitForExistence(timeout: 5), "no completion list")
        XCTAssert(app.buttons["slash-/compact"].exists, "no built-in commands")
        snapshot("1 all commands")

        // The project's own command, listed by the Gateway.
        field.typeText("uitest")
        let hello = app.buttons["slash-/uitest-hello"]
        XCTAssert(hello.waitForExistence(timeout: 20), "no project command")
        XCTAssertEqual(hello.value as? String, "Say hello from the UI test")
        snapshot("2 filtered")
        hello.tap()
        XCTAssertEqual(field.value as? String, "/uitest-hello ")
        XCTAssert(list.waitForNonExistence(timeout: 5), "the list stayed after the space")

        // /exit asks first; cancelling leaves the draft alone.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        field.typeText("/exi")
        let exit = app.buttons["slash-/exit"]
        XCTAssert(exit.waitForExistence(timeout: 5), "no /exit")
        exit.tap()
        let fill = app.buttons["填入 /exit"]
        XCTAssert(fill.waitForExistence(timeout: 5), "/exit did not ask first")
        snapshot("3 exit asks")
        // The sheet's own: a dialog card on the Agent's screen can have one too.
        app.sheets.firstMatch.buttons["取消"].tap()
        XCTAssertEqual(field.value as? String, "/exi")
        leaveAndUnpair(app)
    }

    @MainActor
    func testNewSessionSheet() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        app.buttons["新建"].tap()
        XCTAssert(app.navigationBars["新建"].waitForExistence(timeout: 5), "no new session sheet")
        XCTAssert(app.buttons["Claude Code"].exists, "no program choice")
        let directory = app.textFields["newSessionDirectory"]
        XCTAssert(directory.exists, "no directory field")
        directory.tap()
        directory.typeText("/tmp/companion-ui-work")
        XCTAssert(app.descendants(matching: .any)["newSessionSpace"].exists, "no space choice")
        snapshot("1 new session")
        app.buttons["取消"].tap()
        XCTAssert(app.buttons["新建"].waitForExistence(timeout: 5), "sheet did not close")
        unpair(app)
    }

    /// Creates a shell terminal on the core and opens it. Off by default: it
    /// leaves a terminal on the developer's machine until it is killed there.
    @MainActor
    func testCreatesTerminal() throws {
        guard ProcessInfo.processInfo.environment["YOCHI_CREATE_SESSION"] == "1" else {
            throw XCTSkip("YOCHI_CREATE_SESSION is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)

        app.buttons["新建"].tap()
        XCTAssert(app.navigationBars["新建"].waitForExistence(timeout: 5), "no new session sheet")
        app.buttons["终端"].tap()
        app.buttons["createSession"].tap()
        // The app opens the new terminal once the session list carries it.
        XCTAssert(composer(app).waitForExistence(timeout: 20), "did not open the new session")
        snapshot("1 created")
        leaveAndUnpair(app)
    }

    /// The keyboard must not cover the conversation or the composer; the
    /// newest message stays visible above it.
    @MainActor
    func testConversationKeepsContentAboveKeyboard() throws {
        guard let agent = ProcessInfo.processInfo.environment["YOCHI_AGENT_SESSION"], !agent.isEmpty else {
            throw XCTSkip("YOCHI_AGENT_SESSION is not set")
        }
        let app = launchUnpaired(observing: agent)
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")

        // A tall reply fills the list; the keyboard then keeps the viewport
        // short while it arrives, and the newest line must stay above it.
        send(app, "Reply with the numbers 1 through 60, one per line, then a final line ZEND with no punctuation after it.")
        let last = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "ZEND")).firstMatch
        XCTAssert(last.waitForExistence(timeout: 90), "no reply")
        let field = composer(app)
        field.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssert(keyboard.waitForExistence(timeout: 10), "keyboard never appeared")
        // Let the keyboard's layout and the follow settle.
        RunLoop.current.run(until: .now.addingTimeInterval(1))

        let info = "composer=\(field.frame) keyboard=\(keyboard.frame) last=\(last.frame)"
        XCTAssertTrue(field.frame.maxY <= keyboard.frame.minY + 1, "composer runs under the keyboard: \(info)")
        XCTAssertTrue(last.frame.maxY <= keyboard.frame.minY + 1, "newest reply runs under the keyboard: \(info)")
        snapshot("1 keyboard up, reply visible")
        leaveAndUnpair(app)
    }

    /// A Claude Code session opens on its conversation alone, rows shown
    /// with no tap or drag, and reading back offers a way to the newest
    /// item. Reads an existing session with a transcript; nothing is sent
    /// or pressed.
    /// The menu of the other terminals in an existing session's Herdr tab,
    /// and opening one read-only: YOCHI_TAB_SESSION=<id> of a session
    /// whose tab holds more than it.
    @MainActor
    func testTabMenu() throws {
        guard let id = ProcessInfo.processInfo.environment["YOCHI_TAB_SESSION"], !id.isEmpty else {
            throw XCTSkip("YOCHI_TAB_SESSION is not set")
        }
        let app = launchUnpaired(observing: id)
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)
        let menu = app.buttons["moreMenu"]
        XCTAssert(menu.waitForExistence(timeout: 15), "no More menu")
        XCTAssertEqual(menu.label, "更多")
        menu.tap()
        let switcher = app.buttons["切换 Pane"]
        XCTAssert(switcher.waitForExistence(timeout: 5), "no Switch Pane in the menu")
        snapshot("1 more menu")
        switcher.tap()
        // The open terminal is the selected one; take the first other.
        let other = app.collectionViews.buttons.allElementsBoundByIndex.first { !$0.isSelected && $0.label != "切换 Pane" }
        XCTAssert(other?.exists == true, "the tab lists no other terminal")
        guard let first = other else { return }
        let title = (first.label.components(separatedBy: ",").first ?? first.label)
            .replacingOccurrences(of: "…", with: "")
        first.tap()
        XCTAssert(app.navigationBars.staticTexts[title].waitForExistence(timeout: 10)
                  || text(app, containing: title).waitForExistence(timeout: 5), "\(title) did not open")
        snapshot("2 opened")
        // The switch took the first session's place: Back leads home.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssert(app.buttons["home.settings"].waitForExistence(timeout: 10), "Back did not lead home")
        unpair(app)
    }

    /// A sideways swipe swaps the page for the next terminal in the tab, and
    /// the page must show that terminal, not keep the last one's screen under
    /// the new title. Two throwaway terminals stand in as one Herdr tab
    /// (YOCHI_TEST_TAB); each printed its own word.
    @MainActor
    func testSwipeSwitchesPanes() throws {
        let first = env("YOCHI_PANE_A"), second = env("YOCHI_PANE_B")
        let app = Self.chineseApp()
        app.launchEnvironment["YOCHI_RESET"] = "1"
        app.launchEnvironment["YOCHI_OBSERVE"] = first
        app.launchEnvironment["YOCHI_TEST_TAB"] = "\(first),\(second)"
        app.launch()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)

        let terminal = app.descendants(matching: .any)["terminalGrid"]
        XCTAssert(terminal.waitForExistence(timeout: 15), "the first pane never showed its terminal")
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "the first pane never attached")
        XCTAssert(try viewportText(app, terminal).contains("alpha-pane"), "the first pane shows another terminal")
        snapshot("1 first pane")

        terminal.swipeLeft()
        XCTAssert(text(app, containing: "yochi-uitest-pane-b").waitForExistence(timeout: 10),
                  "the swipe did not switch to the second pane")
        XCTAssert(terminal.waitForExistence(timeout: 15), "the second pane never showed its terminal")
        let shown = waitForViewport(app, terminal, containing: "beta-pane")
        snapshot("2 second pane")
        XCTAssert(shown.contains("beta-pane"), "the second pane kept showing the first one's terminal: \(shown)")
        XCTAssertFalse(shown.contains("alpha-pane"), "the second pane shows the first one's terminal: \(shown)")

        terminal.swipeRight()
        XCTAssert(text(app, containing: "yochi-uitest-pane-a").waitForExistence(timeout: 10),
                  "the swipe back did not switch to the first pane")
        let back = waitForViewport(app, terminal, containing: "alpha-pane")
        snapshot("3 first pane again")
        XCTAssert(back.contains("alpha-pane") && !back.contains("beta-pane"),
                  "coming back shows another terminal: \(back)")

        // The More menu lists the tab's panes, the open one selected.
        app.buttons["moreMenu"].tap()
        app.buttons["切换 Pane"].tap()
        // Both names are cut to one line at the same point; the panes come in tab order.
        let panes = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "yochi-uitest"))
        let paneB = panes.element(boundBy: 1)
        XCTAssert(paneB.waitForExistence(timeout: 5), "Switch Pane does not list the second pane")
        XCTAssert(panes.element(boundBy: 0).isSelected, "the open pane is not the selected one")
        snapshot("4 switch pane menu")
        paneB.tap()
        XCTAssert(text(app, containing: "yochi-uitest-pane-b").waitForExistence(timeout: 10),
                  "the menu did not switch to the second pane")
        XCTAssert(waitForViewport(app, terminal, containing: "beta-pane").contains("beta-pane"),
                  "the menu switch kept showing the first pane's terminal")

        // Each switch took the last one's place: Back leads home.
        leaveAndUnpair(app)
    }

    /// The visible rows, read again until they hold `word` or time runs out.
    @MainActor
    private func waitForViewport(_ app: XCUIApplication, _ terminal: XCUIElement, containing word: String,
                                 timeout: TimeInterval = 15) -> String {
        let deadline = Date.now.addingTimeInterval(timeout)
        var shown = ""
        repeat {
            XCTAssert(terminal.waitForExistence(timeout: 5))
            shown = (try? viewportText(app, terminal)) ?? ""
            if shown.contains(word) { break }
            RunLoop.current.run(until: .now.addingTimeInterval(1))
        } while Date.now < deadline
        return shown
    }

    @MainActor
    func testConversationScrollsToLatest() throws {
        guard let id = ProcessInfo.processInfo.environment["YOCHI_CONVERSATION_SESSION"], !id.isEmpty else {
            throw XCTSkip("YOCHI_CONVERSATION_SESSION is not set")
        }
        let app = launchUnpaired(observing: id)
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)
        let conversation = app.scrollViews["conversation"]
        XCTAssert(conversation.waitForExistence(timeout: 15), "no conversation")
        RunLoop.current.run(until: .now.addingTimeInterval(1))
        snapshot("1 conversation")
        XCTAssertFalse(app.buttons["终端"].exists, "a Claude Code session still offers the terminal")
        let shown = conversation.staticTexts.allElementsBoundByIndex.filter {
            $0.isHittable && conversation.frame.intersects($0.frame)
        }
        XCTAssertFalse(shown.isEmpty, "conversation blank on opening")

        // At the newest item there is no way back to it; further up there is.
        let latest = app.buttons["scrollToLatest"]
        XCTAssertFalse(latest.exists, "back-to-latest shown at the bottom")
        conversation.swipeDown(velocity: .fast)
        conversation.swipeDown(velocity: .fast)
        XCTAssert(latest.waitForExistence(timeout: 3), "no back-to-latest after reading back")
        snapshot("2 read back")
        latest.tap()
        XCTAssert(latest.waitForNonExistence(timeout: 3), "back-to-latest stayed at the bottom")

        // A subagent's report, if this conversation has one, is its own row.
        let task = app.buttons["taskRow"].firstMatch
        if task.exists {
            task.tap()
            snapshot("3 task report")
        }
        app.navigationBars.buttons.firstMatch.tap()
        snapshot("4 session list")
        // A working session's symbol turns: a later frame differs.
        RunLoop.current.run(until: .now.addingTimeInterval(0.35))
        snapshot("5 session list later")
        unpair(app)
    }

    /// The DEBUG long sample: forty long turns, then a reply every four
    /// seconds. Back to latest from far up lands on the real end, never past
    /// it on a blank page, and a new long reply stops with its start at the top.
    @MainActor
    func testConversationSampleBackToLatest() throws {
        let app = Self.chineseApp()
        app.launchEnvironment["YOCHI_SAMPLE_CONVERSATION"] = "long"
        app.launch()
        let conversation = app.scrollViews["conversation"]
        XCTAssert(conversation.waitForExistence(timeout: 10), "no conversation")
        let latest = app.buttons["scrollToLatest"]

        // The frame first: a reply part-way through its reveal may have none
        // to test hits on.
        func showsText() -> Bool {
            conversation.staticTexts.allElementsBoundByIndex.contains {
                !$0.frame.isEmpty && conversation.frame.intersects($0.frame) && $0.isHittable
            }
        }

        for (round, flicks) in [2, 6, 12].enumerated() {
            for _ in 0..<flicks { conversation.swipeDown(velocity: .fast) }
            XCTAssert(latest.waitForExistence(timeout: 3), "no back-to-latest after reading back")
            // The flicks may still be gliding: a tap then only stops them.
            RunLoop.current.run(until: .now.addingTimeInterval(1.5))
            latest.tap()
            XCTAssert(latest.waitForNonExistence(timeout: 3), "round \(round): back-to-latest did not reach the end")
            RunLoop.current.run(until: .now.addingTimeInterval(0.5))
            XCTAssert(showsText(), "round \(round): blank after back to latest")
            snapshot("latest \(round)")
        }

        // A long reply that arrives is read from its start: the list stops
        // with its heading under the bar instead of following it to its end.
        if latest.exists {
            latest.tap()
            XCTAssert(latest.waitForNonExistence(timeout: 3), "back-to-latest did not reach the end")
        }
        XCTAssert(latest.waitForExistence(timeout: 12), "followed an arriving reply to its end")
        RunLoop.current.run(until: .now.addingTimeInterval(0.5))
        let bar = app.navigationBars.firstMatch.frame.maxY
        let headings = conversation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "段回复"))
            .allElementsBoundByIndex.filter { !$0.frame.isEmpty && $0.frame.minY >= bar - 20 && $0.isHittable }
        let top = headings.map(\.frame.minY).min() ?? .infinity
        XCTAssert(top - bar < 60, "the arriving reply's start is not at the top (\(top) below a bar ending at \(bar))")
        snapshot("reply from its start")
        latest.tap()
        XCTAssert(latest.waitForNonExistence(timeout: 3), "back-to-latest did not reach the end")
        XCTAssert(showsText(), "blank after replies arrived")
        snapshot("latest after replies")
    }

    /// Not a check: scrolls a terminal with live output for the app's frame
    /// meter, which logs `frames scroll …` (scripts/perf-test.sh reads it).
    @MainActor
    func testPerfTerminalScroll() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)
        let session = sessionCell(app, name: env("YOCHI_PERF_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no perf session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        for round in 0..<5 {
            // Flicks back into history, then towards the bottom; each window
            // ends two seconds after its last touch.
            for _ in 0..<3 {
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                    .press(forDuration: 0.02, thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            for _ in 0..<2 {
                terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                    .press(forDuration: 0.02, thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            RunLoop.current.run(until: .now.addingTimeInterval(2.5))
            snapshot("scroll \(round)")
        }
        leaveAndUnpair(app)
    }

    /// Not a check: opens a session, leaves it and opens it again soon after,
    /// for the app's `shown …` log lines (scripts/perf-test.sh reads them).
    @MainActor
    func testPerfReenter() throws {
        let app = launchUnpaired()
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app)
        let session = sessionCell(app, name: env("YOCHI_PERF_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no perf session")
        for round in 0..<3 {
            session.tap()
            XCTAssert(app.descendants(matching: .any)["terminalGrid"].waitForExistence(timeout: 15))
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
            snapshot("terminal \(round)")
            RunLoop.current.run(until: .now.addingTimeInterval(2.5))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssert(session.waitForExistence(timeout: 10))
            RunLoop.current.run(until: .now.addingTimeInterval(3))
        }
        unpair(app)
    }

    /// The same for an Agent's conversation: an existing session, read only.
    @MainActor
    func testPerfReenterConversation() throws {
        guard let id = ProcessInfo.processInfo.environment["YOCHI_CONVERSATION_SESSION"], !id.isEmpty else {
            throw XCTSkip("YOCHI_CONVERSATION_SESSION is not set")
        }
        let app = launchUnpaired(observing: id)
        pair(app, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(app, observing: true)
        let agent = app.buttons.matching(identifier: "session-\(id)").firstMatch
        for round in 0..<4 {
            XCTAssert(app.scrollViews["conversation"].waitForExistence(timeout: 15), "no conversation")
            RunLoop.current.run(until: .now.addingTimeInterval(0.25))
            snapshot("conversation \(round)")
            RunLoop.current.run(until: .now.addingTimeInterval(2.5))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssert(agent.waitForExistence(timeout: 10), "no row for the session")
            RunLoop.current.run(until: .now.addingTimeInterval(3))
            if round < 3 { agent.tap() }
        }
        unpair(app)
    }

    /// Not a check: the first search and the first terminal after a cold
    /// launch, already paired. Prints how long the keyboard and each
    /// terminal took; the app logs `hang ms=…` for each main-thread stall.
    @MainActor
    func testPerfFirstUse() throws {
        let paired = launchUnpaired()
        pair(paired, host: env("YOCHI_HOST"), code: env("YOCHI_CODE"))
        waitUntilPaired(paired)
        paired.terminate()
        let app = Self.chineseApp()
        app.launch()
        waitUntilPaired(app)
        XCTAssert(app.searchFields.firstMatch.waitForExistence(timeout: 15), "no Inbox")
        RunLoop.current.run(until: .now.addingTimeInterval(3))

        let search = app.searchFields.firstMatch
        var start = Date.now
        search.tap()
        let keyboard = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        print("perf-first search keyboard=\(keyboard) ms=\(Int(Date.now.timeIntervalSince(start) * 1000))")
        RunLoop.current.run(until: .now.addingTimeInterval(1))
        start = .now
        search.typeText("c")
        print("perf-first search typed ms=\(Int(Date.now.timeIntervalSince(start) * 1000))")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        search.typeText(XCUIKeyboardKey.delete.rawValue)
        RunLoop.current.run(until: .now.addingTimeInterval(1))

        for name in [env("YOCHI_PERF_SESSION_NAME"), "yochi-uitest"] {
            // A search left from the last round starts again from empty.
            endSearch(app)
            let cell = sessionCell(app, name: name)
            XCTAssert(cell.waitForExistence(timeout: 15), "no \(name)")
            RunLoop.current.run(until: .now.addingTimeInterval(1))
            start = .now
            cell.tap()
            let grid = app.descendants(matching: .any)["terminalGrid"].waitForExistence(timeout: 15)
            print("perf-first terminal \(name) grid=\(grid) ms=\(Int(Date.now.timeIntervalSince(start) * 1000))")
            RunLoop.current.run(until: .now.addingTimeInterval(3))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssert(Self.closeSearch(app).waitForExistence(timeout: 10) || app.buttons["home.settings"].exists)
            RunLoop.current.run(until: .now.addingTimeInterval(1))
        }
        unpair(app)
    }

    // MARK: - Helpers

    @MainActor
    private func send(_ app: XCUIApplication, _ message: String) {
        let field = composer(app)
        field.tap()
        field.typeText(message)
        app.buttons["发送消息"].tap()
        XCTAssertTrue(waitUntilCleared(field, timeout: 20), "message was not sent")
    }

    @MainActor
    private func launchUnpaired(observing id: String? = nil, textSize: String? = nil) -> XCUIApplication {
        let app = Self.chineseApp()
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchEnvironment["YOCHI_RESET"] = "1"
        if let id { app.launchEnvironment["YOCHI_OBSERVE"] = id }
        app.launch()
        return app
    }

    @MainActor
    private func pair(_ app: XCUIApplication, host: String?, code: String) {
        if let host { replace(app.textFields["地址"], with: host) }
        replace(app.textFields["配对码"], with: code)
        app.buttons["配对"].tap()
    }

    @MainActor
    private func waitForReplacePrompt(_ app: XCUIApplication, open: XCUIElement) {
        let prompt = app.staticTexts["与新的 Gateway 配对？"]
        let deadline = Date.now.addingTimeInterval(10)
        while !prompt.exists, Date.now < deadline {
            if open.exists { open.tap() }
            RunLoop.current.run(until: .now.addingTimeInterval(0.3))
        }
        XCTAssert(prompt.exists, "no prompt to replace the pairing")
    }

    /// The pairing form has cells too; only the session list has the settings button.
    @MainActor
    private func waitUntilPaired(_ app: XCUIApplication, observing: Bool = false) {
        if observing {
            // A conversation shows its message field; a terminal shows its
            // grid and keeps the command field hidden until asked for.
            let page = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier IN %@", ["agentMessageField", "terminalCommandField", "terminalGrid"])).firstMatch
            XCTAssert(page.waitForExistence(timeout: 15), "pairing did not finish")
        } else {
            XCTAssert(app.buttons["home.settings"].waitForExistence(timeout: 15), "pairing did not finish")
        }
    }

    @MainActor
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        // The Agent's message field, or a terminal's command field.
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["agentMessageField", "terminalCommandField"])).firstMatch
        // A terminal that types keeps its command field behind the pencil.
        let pencil = app.buttons["toggleComposer"]
        let deadline = Date.now.addingTimeInterval(15)
        while !field.exists, !pencil.exists, Date.now < deadline {
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        if !field.exists, pencil.exists { pencil.tap() }
        XCTAssert(field.waitForExistence(timeout: 15))
        return field
    }

    @MainActor
    private func waitUntilCleared(_ field: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            guard let value = field.value as? String else { return true }
            if value.isEmpty || value == field.placeholderValue { return true }
            RunLoop.current.run(until: .now.addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func testSession(_ app: XCUIApplication) -> XCUIElement {
        sessionCell(app, name: "yochi-uitest")
    }

    /// A session is titled with the name it was started under. An Agent's
    /// row reads as one label (pinned first, then the title); a terminal's
    /// keeps its texts. The Inbox lists Agents only and the Mac's own sessions
    /// can push a row far down, so this searches for it: matches list flat.
    @MainActor
    private func sessionCell(_ app: XCUIApplication, name: String) -> XCUIElement {
        let cell = app.cells.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label CONTAINS %@",
            name, "\(name)，", "\(name)、", "\(name), ", "置顶，\(name)，")).firstMatch
        guard app.searchFields.firstMatch.waitForExistence(timeout: 15) else { return cell }
        let search = app.searchFields.firstMatch
        for _ in 0..<4 where !search.isHittable { app.swipeDown() }
        guard search.isHittable, (search.value as? String) != name else { return cell }
        search.tap()
        if let current = search.value as? String, !current.isEmpty, current != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        search.typeText(name)
        return cell
    }

    @MainActor
    private func leaveAndUnpair(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// A search left from finding a row hides the toolbar.
    @MainActor
    private func endSearch(_ app: XCUIApplication) {
        let close = Self.closeSearch(app)
        guard !app.buttons["home.settings"].exists, close.exists else { return }
        // Coming back to the list gives the search field its focus again,
        // and the keyboard slides up under where close was: let it settle.
        if app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            RunLoop.current.run(until: .now.addingTimeInterval(0.6))
        }
        close.tap()
    }

    @MainActor
    private func unpair(_ app: XCUIApplication) {
        endSearch(app)
        app.buttons["home.settings"].tap()
        XCTAssert(app.buttons["settings.gateway"].waitForExistence(timeout: 5), "no settings sheet")
        app.buttons["settings.gateway"].tap()
        XCTAssert(app.staticTexts["设备 ID"].waitForExistence(timeout: 5), "no Gateway settings")
        app.buttons["取消配对"].tap()
        confirm(app, "取消配对")
        XCTAssert(app.textFields["配对码"].waitForExistence(timeout: 10), "did not unpair")
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssert(field.waitForExistence(timeout: 10))
        // The text is trailing-aligned: tap its end so deletes clear all of it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    /// Taps the destructive button of a confirmation dialog whose trigger may
    /// carry the same title.
    @MainActor
    private func confirm(_ app: XCUIApplication, _ title: String) {
        let buttons = app.buttons.matching(identifier: title)
        let deadline = Date.now.addingTimeInterval(5)
        while buttons.allElementsBoundByIndex.filter(\.isHittable).count < 1, Date.now < deadline {
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        }
        let hittable = buttons.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(hittable.isEmpty, "no \(title) button in the dialog")
        hittable.last?.tap()
    }

    @MainActor
    private func text(_ app: XCUIApplication, containing part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func env(_ key: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            XCTFail("\(key) is not set; run scripts/ui-test.sh")
            return ""
        }
        return value
    }

    /// The search's own close button, which the system names in the app's language.
    @MainActor
    private static func closeSearch(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'close' OR label IN {'close', '关闭'}")).firstMatch
    }

    /// The tests read the Chinese interface, whatever the simulator's language.
    @MainActor
    private static func chineseApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        return app
    }
}
