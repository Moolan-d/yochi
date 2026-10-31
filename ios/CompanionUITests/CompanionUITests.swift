import XCTest

/// Drives the app against a throwaway Gateway. Run through scripts/ui-test.sh,
/// which gives each test the Gateway's address and a fresh pairing code
/// (COMPANION_HOST, COMPANION_CODE).
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
        // Section headers are cells too; session rows are the buttons in them.
        let session = app.cells.buttons.firstMatch
        XCTAssert(session.waitForExistence(timeout: 15), "no sessions after pairing")
        snapshot("2 sessions")

        session.tap()
        XCTAssert(text(app, containing: "仅查看").waitForExistence(timeout: 10))
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

    // MARK: - Helpers

    @MainActor
    private func launchUnpaired() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["COMPANION_RESET"] = "1"
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
    private func waitUntilPaired(_ app: XCUIApplication) {
        XCTAssert(app.buttons["设置"].waitForExistence(timeout: 15), "pairing did not finish")
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
