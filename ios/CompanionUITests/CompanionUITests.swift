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
        // The subtitle gains the grid size once the terminal is attached.
        XCTAssert(text(app, containing: "×").waitForExistence(timeout: 15), "terminal never attached")
        snapshot("3 observe")
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
        app.navigationBars.buttons.firstMatch.tap()
        let session = testSession(app)
        XCTAssert(session.waitForExistence(timeout: 10))
        session.tap()
        XCTAssert(composer(app).waitForExistence(timeout: 10))
        XCTAssertEqual(composer(app).value as? String, draft)
        snapshot("1 restored draft")
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
        app.cells.buttons.containing(.staticText, identifier: "companion-uitest").firstMatch
    }

    @MainActor
    private func leaveAndUnpair(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["设置"].tap()
        XCTAssert(app.staticTexts["设备 ID"].waitForExistence(timeout: 5))
        app.buttons["取消配对"].tap()
        confirm(app, "取消配对")
        XCTAssert(app.textFields["配对码"].waitForExistence(timeout: 10))
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
