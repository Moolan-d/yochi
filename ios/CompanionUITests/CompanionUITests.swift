import XCTest

/// Drives the app against a throwaway Gateway. Run through scripts/ui-test.sh,
/// which gives each test the Gateway's address, a fresh pairing code and the
/// dedicated echo terminal (COMPANION_HOST, COMPANION_CODE, COMPANION_SESSION).
final class CompanionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPairObserveAndUnpair() throws {
        let app = launchUnpaired()

        // A wrong code is refused without using up the real one.
        pair(app, host: env("COMPANION_HOST"), code: "AAAA-AAAA")
        XCTAssert(text(app, containing: "配对码不正确").waitForExistence(timeout: 10))
        snapshot("1 wrong code")

        pair(app, host: nil, code: env("COMPANION_CODE"))
        waitUntilPaired(app)
        XCTAssert(app.cells.firstMatch.waitForExistence(timeout: 15), "no home page")
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
        app.buttons["终端字号"].tap()
        app.buttons["增大字号"].tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15),
                  "terminal did not re-attach after the font size change")
        app.buttons["终端字号"].tap()
        app.buttons["恢复默认字号"].tap()

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
        app.buttons["设置"].tap()
        XCTAssert(app.staticTexts["设备 ID"].waitForExistence(timeout: 5))
        snapshot("4 settings")
        app.buttons["取消配对"].tap()
        XCTAssert(app.sheets["取消与此 Gateway 的配对？"].waitForExistence(timeout: 5))
        snapshot("5 unpair prompt")
        app.buttons["保留配对"].tap()
        XCTAssert(app.staticTexts["设备 ID"].exists, "keeping the pairing dropped it")
        app.buttons["取消配对"].tap()
        confirm(app, "取消配对")
        XCTAssert(app.textFields["配对码"].waitForExistence(timeout: 10), "pairing form did not return")
        snapshot("6 unpaired")
    }

    /// A full-screen program draws with absolute positions, so reflowing it to
    /// the phone scrambles the screen: it is shown as the desktop drew it, and
    /// watching never resizes the terminal.
    @MainActor
    func testFullScreenShownAsDrawn() throws {
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("COMPANION_ALT_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no full-screen session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        snapshot("1 as drawn")
        // The program prints its own size whenever it changes: still the
        // grid it had, which is also the one on screen.
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        let grid = try XCTUnwrap(titleGrid(app), "no grid in the title")
        XCTAssertEqual(try viewportNumbers(app, terminal), [grid.rows, grid.cols],
                       "the full-screen program was not shown at its own grid")

        // A pinch zooms in; coming back shows the same, unresized terminal.
        terminal.pinch(withScale: 3, velocity: 2)
        snapshot("2 zoomed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssert(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached again")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        XCTAssertEqual(try viewportNumbers(app, terminal), [grid.rows, grid.cols],
                       "viewing resized the terminal")
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
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("COMPANION_HISTORY_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no history session")
        session.tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        RunLoop.current.run(until: .now.addingTimeInterval(1))
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
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    /// The numbers on screen, read through the long-press selection sheet.
    @MainActor
    private func viewportNumbers(_ app: XCUIApplication, _ terminal: XCUIElement) throws -> [Int] {
        terminal.press(forDuration: 1.0)
        let view = app.textViews.firstMatch
        XCTAssert(view.waitForExistence(timeout: 5), "no selection sheet")
        let numbers = ((view.value as? String) ?? "").split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        app.buttons["取消"].tap()
        XCTAssert(view.waitForNonExistence(timeout: 5), "selection sheet did not close")
        XCTAssertFalse(numbers.isEmpty, "no numbers in the viewport")
        return numbers
    }

    @MainActor
    func testInviteLinkReplacesPairing() throws {
        let app = launchUnpaired()
        let host = env("COMPANION_HOST")
        pair(app, host: host, code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        // Through the system, as a scanned QR code would (`app.open` relaunches the app).
        XCUIDevice.shared.system.open(URL(string: "companion://pair?host=\(host)&code=ZZZZ-ZZZZ")!)
        // iOS may first ask whether to open the link in Companion.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons.matching(NSPredicate(format: "label IN {'打开', 'Open'}")).firstMatch
        waitForReplacePrompt(app, open: open)
        app.buttons["保留当前配对"].tap()
        XCTAssert(app.buttons["设置"].waitForExistence(timeout: 5), "keeping the pairing dropped it")
        XCTAssert(app.cells.buttons.firstMatch.exists, "sessions gone after keeping the pairing")
        XCUIDevice.shared.system.open(URL(string: "companion://pair?host=\(host)&code=ZZZZ-ZZZZ")!)
        waitForReplacePrompt(app, open: open)
        snapshot("1 replace prompt")
        confirm(app, "配对新的 Gateway")

        let code = app.textFields["配对码"]
        XCTAssert(code.waitForExistence(timeout: 10), "pairing form did not open")
        XCTAssertEqual(code.value as? String, "ZZZZ-ZZZZ")
        XCTAssertEqual(app.textFields["地址"].value as? String, host)
        snapshot("2 prefilled form")
    }

    @MainActor
    func testAgentMessageIsAccepted() throws {
        let app = launchUnpaired(observing: env("COMPANION_SESSION"))
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app, observing: true)

        let field = composer(app)
        field.tap()
        field.typeText("Companion UI test")
        app.buttons["发送消息"].tap()
        XCTAssert(text(app, containing: "已发送").waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntilCleared(field), "composer kept the sent message")
        snapshot("1 accepted")

        // The result and the cleared draft survive leaving the terminal.
        app.navigationBars.buttons.firstMatch.tap()
        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssert(text(app, containing: "已发送").waitForExistence(timeout: 10))
        let composerAfterReturn = composer(app)
        XCTAssertTrue(waitUntilCleared(composerAfterReturn), "sent message returned as a draft")
        snapshot("2 sent message did not return as a draft")
        // /bin/cat echoes input but reports no Agent turns. The following
        // transition to "Agent 已回应" needs a real Claude Code session.
        leaveAndUnpair(app)
    }

    @MainActor
    func testTerminalKeysArePressed() throws {
        let app = launchUnpaired(observing: env("COMPANION_SESSION"))
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app, observing: true)

        _ = composer(app)
        snapshot("1 key bar and composer")
        // /bin/cat echoes "2" and prints it back after Enter; ui-test.sh checks the screen.
        let two = app.buttons["key-2"]
        XCTAssert(two.waitForExistence(timeout: 10))
        two.tap()
        app.buttons["key-enter"].tap()
        XCTAssertFalse(text(app, containing: "按键未送达").waitForExistence(timeout: 3))

        app.buttons["composerMenu"].tap()
        XCTAssert(app.buttons["继续"].waitForExistence(timeout: 5))
        snapshot("2 quick commands")
        app.buttons["继续"].tap()
        XCTAssertEqual(composer(app).value as? String, "继续")
        snapshot("3 filled draft")
        leaveAndUnpair(app)
    }

    @MainActor
    func testAgentMessageDraftSurvivesNavigation() throws {
        let app = launchUnpaired(observing: env("COMPANION_SESSION"))
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
    /// companion-uitest (COMPANION_AGENT_SESSION); skipped otherwise.
    @MainActor
    func testConversationAnswersAgent() throws {
        guard let agent = ProcessInfo.processInfo.environment["COMPANION_AGENT_SESSION"], !agent.isEmpty else {
            throw XCTSkip("COMPANION_AGENT_SESSION is not set")
        }
        let app = launchUnpaired(observing: agent)
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_DIALOG_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_DIALOG_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        // The largest text short of the accessibility sizes makes the card
        // taller than the page, as on a phone with bigger text.
        let app = launchUnpaired(textSize: "UICTContentSizeCategoryXXXL")
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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

    /// The DEBUG sample home: 需要你 first, a pinned Agent with its child, a
    /// remote space that folds, terminals that unfold, and a search with no
    /// match offering 新建, at the default text size and an accessibility one.
    @MainActor
    func testHomeSample() throws {
        for size in [nil, "UICTContentSizeCategoryAccessibilityL"] {
            let app = XCUIApplication()
            if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launchEnvironment["COMPANION_SAMPLE_HOME"] = "1"
            app.launch()
            let suffix = size == nil ? "" : "-large"

            let blocked = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "服务助手页面自动断联后重连卡住")).firstMatch
            XCTAssert(blocked.waitForExistence(timeout: 10), "no blocked Agent")
            XCTAssertEqual(blocked.label, "服务助手页面自动断联后重连卡住，等你处理，要运行 npm test，允许吗？，小程序 · wx-mini · fix-reconnect")
            if size == nil {
                // Larger text pushes these below the fold, where the list hasn't made them yet.
                let rows = app.cells.buttons.allElementsBoundByIndex.map(\.label)
                let unseen = try XCTUnwrap(rows.firstIndex { $0.hasPrefix("整理日志轮转，完成，未看过，vps · 运维") }, "\(rows)")
                XCTAssertGreaterThan(unseen, try XCTUnwrap(rows.firstIndex { $0.hasPrefix("补单元测试，完成，未看过") }), "\(rows)")
            }
            snapshot("home-top\(suffix)")

            let pinned = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "已置顶，主页改版，工作中，正在写主页列表")).firstMatch
            scrollUntilHittable(pinned, in: app, up: true)
            let child = app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "查路线图剩余项，子 Agent，工作中")).firstMatch
            XCTAssert(child.exists, "no child Agent")
            // The indent is checked on the screenshot: the row is one element.
            XCTAssertLessThan(pinned.frame.minY, child.frame.minY, "the child is not under its parent")

            let terminals = app.buttons.matching(NSPredicate(format: "label == %@", "另有 1 个终端")).firstMatch
            scrollUntilHittable(terminals, in: app, up: true)
            XCTAssertEqual(terminals.value as? String, "已收起")
            terminals.tap()
            XCTAssertEqual(terminals.value as? String, "已展开")
            XCTAssert(app.cells.buttons.containing(.staticText, identifier: "zsh").firstMatch.waitForExistence(timeout: 5), "terminals did not unfold")
            snapshot("home-terminals\(suffix)")
            terminals.tap()

            let remote = app.buttons.matching(identifier: "groupHeader").matching(NSPredicate(format: "label == %@", "运维，vps")).firstMatch
            scrollUntilHittable(remote, in: app, up: true)
            XCTAssertEqual(remote.value as? String, "已展开")
            remote.tap()
            XCTAssertEqual(remote.value as? String, "已收起，2 个 Agent，有未看过的完成")
            XCTAssertFalse(app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "升级 Caddy 配置")).firstMatch.exists)
            snapshot("home-collapsed\(suffix)")
            remote.tap()
            XCTAssertEqual(remote.value as? String, "已展开")

            for _ in 0..<4 where !app.searchFields.firstMatch.isHittable { app.swipeDown() }
            let search = app.searchFields.firstMatch
            XCTAssert(search.isHittable, "no search field")
            search.tap()
            search.typeText("运维")
            XCTAssert(app.cells.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "升级 Caddy 配置")).firstMatch
                .waitForExistence(timeout: 5), "search by space found nothing")
            search.typeText("没有的东西")
            XCTAssert(app.staticTexts["没有匹配「运维没有的东西」的 Agent"].waitForExistence(timeout: 5), "no empty search result")
            XCTAssert(app.buttons["新建"].exists, "no 新建 for an empty search")
            snapshot("home-search-empty\(suffix)")
            app.terminate()
        }
    }

    /// Edit, to-do, subtask and peer cards in the DEBUG sample conversation,
    /// at the default text size and an accessibility one.
    @MainActor
    func testConversationCards() throws {
        for size in [nil, "UICTContentSizeCategoryAccessibilityL"] {
            let app = XCUIApplication()
            if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launchEnvironment["COMPANION_SAMPLE_CONVERSATION"] = "1"
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
            XCTAssertTrue(edit.label.hasPrefix("编辑 SessionListView.swift，增加 3 行，删除 1 行，在 /Users/me/app/ios/Companion"))
            edit.tap()
            let added = app.descendants(matching: .any)["第 43 行，增加：            } description: {"]
            XCTAssertTrue(added.waitForExistence(timeout: 5), "the edit's diff did not open")
            snapshot("cards-edit\(suffix)")
            app.terminate()
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: name)
        _ = session.waitForExistence(timeout: 15)
        for _ in 0..<6 where !session.isHittable { app.swipeUp() }
        XCTAssert(session.isHittable, "no Claude Code session")
        session.tap()
        XCTAssert(text(app, containing: "对话 ·").waitForExistence(timeout: 15), "no conversation")

        app.buttons["changesButton"].tap()
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
        guard let name = ProcessInfo.processInfo.environment["COMPANION_PICKER_SESSION_NAME"], !name.isEmpty else {
            throw XCTSkip("COMPANION_PICKER_SESSION_NAME is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        app.buttons["取消"].tap()
        XCTAssertEqual(field.value as? String, "/exi")
        leaveAndUnpair(app)
    }

    @MainActor
    func testNewSessionSheet() throws {
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard ProcessInfo.processInfo.environment["COMPANION_CREATE_SESSION"] == "1" else {
            throw XCTSkip("COMPANION_CREATE_SESSION is not set")
        }
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        guard let agent = ProcessInfo.processInfo.environment["COMPANION_AGENT_SESSION"], !agent.isEmpty else {
            throw XCTSkip("COMPANION_AGENT_SESSION is not set")
        }
        let app = launchUnpaired(observing: agent)
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
    /// and opening one read-only: COMPANION_TAB_SESSION=<id> of a session
    /// whose tab holds more than it.
    @MainActor
    func testTabMenu() throws {
        guard let id = ProcessInfo.processInfo.environment["COMPANION_TAB_SESSION"], !id.isEmpty else {
            throw XCTSkip("COMPANION_TAB_SESSION is not set")
        }
        let app = launchUnpaired(observing: id)
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app, observing: true)
        let menu = app.buttons["tabMenu"]
        XCTAssert(menu.waitForExistence(timeout: 15), "no menu of the tab's terminals")
        XCTAssertEqual(menu.label, "同一个 Tab 的终端")
        menu.tap()
        let first = app.collectionViews.buttons.firstMatch
        XCTAssert(first.waitForExistence(timeout: 5), "the menu is empty")
        snapshot("1 tab menu")
        let title = first.label.components(separatedBy: ",").first ?? first.label
        first.tap()
        XCTAssert(app.navigationBars.staticTexts[title].waitForExistence(timeout: 10)
                  || text(app, containing: title).waitForExistence(timeout: 5), "\(title) did not open")
        snapshot("2 opened")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssert(menu.waitForExistence(timeout: 10), "did not come back to the first session")
        leaveAndUnpair(app)
    }

    @MainActor
    func testConversationScrollsToLatest() throws {
        guard let id = ProcessInfo.processInfo.environment["COMPANION_CONVERSATION_SESSION"], !id.isEmpty else {
            throw XCTSkip("COMPANION_CONVERSATION_SESSION is not set")
        }
        let app = launchUnpaired(observing: id)
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
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
        let app = XCUIApplication()
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launchEnvironment["COMPANION_RESET"] = "1"
        if let id { app.launchEnvironment["COMPANION_OBSERVE"] = id }
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
            XCTAssert(composer(app).waitForExistence(timeout: 15), "pairing did not finish")
        } else {
            XCTAssert(app.buttons["设置"].waitForExistence(timeout: 15), "pairing did not finish")
        }
    }

    @MainActor
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.descendants(matching: .any).matching(identifier: "agentMessageField").firstMatch
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
        sessionCell(app, name: "companion-uitest")
    }

    /// A session is titled with the name it was started under. An Agent's
    /// row reads as one label (pinned first, then the title); a terminal's
    /// keeps its texts. Terminals are folded and the Mac's own sessions can
    /// push the row far down, so this searches for it: matches list flat.
    @MainActor
    private func sessionCell(_ app: XCUIApplication, name: String) -> XCUIElement {
        let cell = app.cells.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label CONTAINS %@",
            name, "\(name)，", "\(name), ", "置顶，\(name)，")).firstMatch
        guard app.cells.firstMatch.waitForExistence(timeout: 15) else { return cell }
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
        if !app.buttons["设置"].exists, app.buttons["close"].exists { app.buttons["close"].tap() }
    }

    @MainActor
    private func unpair(_ app: XCUIApplication) {
        endSearch(app)
        app.buttons["设置"].tap()
        XCTAssert(app.staticTexts["设备 ID"].waitForExistence(timeout: 5), "no settings sheet")
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
}
