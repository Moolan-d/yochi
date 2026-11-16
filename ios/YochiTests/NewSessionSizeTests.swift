import XCTest
@testable import Yochi

final class NewSessionSizeTests: XCTestCase {
    private func json(_ message: GatewayClient.RunMessage) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    }

    func testTheRunRequestCarriesThePhoneGridOnlyWhenKnown() throws {
        let sized = try json(.init(id: "r1", machine: nil, cwd: "/a", argv: ["claude"], space: nil, size: TerminalGrid(cols: 49, rows: 45)))
        XCTAssertEqual(sized["cols"] as? Int, 49)
        XCTAssertEqual(sized["rows"] as? Int, 45)
        XCTAssertEqual(sized["type"] as? String, "run")
        let plain = try json(.init(id: "r1", machine: nil, cwd: "/a", argv: [], space: nil, size: nil))
        XCTAssertNil(plain["cols"], "an older flow sends no size")
        XCTAssertNil(plain["rows"])
    }

    func testTheRememberedGridSurvivesAndRefusesNonsense() {
        let key = "terminal.phoneGrid"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertNil(TerminalGrid.remembered)
        TerminalGrid.remember(TerminalGrid(cols: 49, rows: 45))
        XCTAssertEqual(TerminalGrid.remembered, TerminalGrid(cols: 49, rows: 45))
        TerminalGrid.remember(TerminalGrid(cols: 0, rows: 45))
        TerminalGrid.remember(TerminalGrid(cols: 49, rows: 5000))
        XCTAssertEqual(TerminalGrid.remembered, TerminalGrid(cols: 49, rows: 45), "out of range is not kept")
        UserDefaults.standard.set([0, 10], forKey: key)
        XCTAssertNil(TerminalGrid.remembered)
    }
}
