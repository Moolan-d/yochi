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
        // The echo terminal: an Agent's session would open its conversation instead.
        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 15), "no sessions after pairing")
        snapshot("2 sessions")

        session.tap()
        XCTAssert(text(app, containing: "查看").waitForExistence(timeout: 10))
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
    /// the phone scrambles the screen. Taking over resizes the terminal itself
    /// for as long as the page is open, and leaving gives the desktop its size
    /// back.
    @MainActor
    func testTakeOverFullScreen() throws {
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("COMPANION_ALT_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no full-screen session")
        session.tap()
        XCTAssert(text(app, containing: "查看").waitForExistence(timeout: 10))

        let offer = app.buttons["takeoverButton"]
        XCTAssert(offer.waitForExistence(timeout: 20), "no takeover offer for a full-screen program")
        snapshot("1 full screen")
        offer.tap()
        let confirm = app.buttons["开始适配"]
        XCTAssert(confirm.waitForExistence(timeout: 5), "no takeover confirmation")
        confirm.tap()
        XCTAssert(text(app, containing: "已适配手机宽度").waitForExistence(timeout: 20),
                  "takeover did not start")
        RunLoop.current.run(until: .now.addingTimeInterval(2))
        XCTAssertFalse(text(app, containing: "连接中断").exists, "takeover stream broke")
        snapshot("2 taken over")

        app.buttons["恢复桌面"].tap()
        XCTAssert(offer.waitForExistence(timeout: 25), "did not return to the watcher view")
        leaveAndUnpair(app)
    }

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
        if app.buttons["终端"].waitForExistence(timeout: 3) { app.buttons["终端"].tap() }
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

    /// A full-screen program keeps its history to itself: dragging opens it
    /// as text read through core. The pager shows 400 at the bottom; 1 is
    /// only in its history.
    @MainActor
    func testFullScreenHistory() throws {
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        let session = sessionCell(app, name: env("COMPANION_PAGER_SESSION_NAME"))
        XCTAssert(session.waitForExistence(timeout: 15), "no pager session")
        session.tap()
        if app.buttons["终端"].waitForExistence(timeout: 3) { app.buttons["终端"].tap() }
        XCTAssert(app.buttons["terminalHistoryButton"].waitForExistence(timeout: 15), "not seen as full screen")
        let terminal = app.descendants(matching: .any)["terminalGrid"]
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))

        let history = app.textViews["terminalHistory"]
        XCTAssert(history.waitForExistence(timeout: 20), "dragging did not open the history")
        snapshot("1 history")
        let lines = ((history.value as? String) ?? "").split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(lines.first, "1", "history does not reach the top")
        XCTAssert(lines.contains("400"), "history lost the screen")
        app.buttons["完成"].tap()
        XCTAssert(history.waitForNonExistence(timeout: 5), "history did not close")

        app.buttons["terminalHistoryButton"].tap()
        XCTAssert(history.waitForExistence(timeout: 20), "the button did not open the history")
        app.buttons["完成"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
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

        app.buttons["quickCommands"].tap()
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
        XCTAssert(app.descendants(matching: .any)["sessionMode"].waitForExistence(timeout: 15), "no conversation")
        XCTAssert(text(app, containing: "对话").waitForExistence(timeout: 5))
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

        app.buttons["终端"].tap()
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        snapshot("7 terminal")
        leaveAndUnpair(app)
    }

    @MainActor
    func testNewSessionSheet() throws {
        let app = launchUnpaired()
        pair(app, host: env("COMPANION_HOST"), code: env("COMPANION_CODE"))
        waitUntilPaired(app)

        app.buttons["新建会话"].tap()
        XCTAssert(app.navigationBars["新建会话"].waitForExistence(timeout: 5), "no new session sheet")
        XCTAssert(app.buttons["Claude Code"].exists, "no program choice")
        let directory = app.textFields["newSessionDirectory"]
        XCTAssert(directory.exists, "no directory field")
        directory.tap()
        directory.typeText("/tmp/companion-ui-work")
        snapshot("1 new session")
        app.buttons["取消"].tap()
        XCTAssert(app.buttons["新建会话"].waitForExistence(timeout: 5), "sheet did not close")
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

        app.buttons["新建会话"].tap()
        XCTAssert(app.navigationBars["新建会话"].waitForExistence(timeout: 5), "no new session sheet")
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
        XCTAssert(app.descendants(matching: .any)["sessionMode"].waitForExistence(timeout: 15), "no conversation")

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
    private func launchUnpaired(observing id: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
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

    /// A session is titled with the name it was started under.
    @MainActor
    private func sessionCell(_ app: XCUIApplication, name: String) -> XCUIElement {
        app.cells.buttons.containing(.staticText, identifier: name).firstMatch
    }

    @MainActor
    private func leaveAndUnpair(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        unpair(app)
    }

    @MainActor
    private func unpair(_ app: XCUIApplication) {
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
