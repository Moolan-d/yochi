import XCTest
@testable import Companion

final class TerminalKeysTests: XCTestCase {
    func testKeysRepliesDecode() throws {
        let sent = Data(#"{"type":"keys_sent","id":"k1"}"#.utf8)
        guard case .keysSent(let id) = try JSONDecoder().decode(ServerMessage.self, from: sent) else {
            return XCTFail("not keys_sent")
        }
        XCTAssertEqual(id, "k1")
        let failed = Data(#"{"type":"keys_failed","id":"k2","kind":"finished","message":"finished"}"#.utf8)
        guard case .keysFailed(let id, let kind, _) = try JSONDecoder().decode(ServerMessage.self, from: failed) else {
            return XCTFail("not keys_failed")
        }
        XCTAssertEqual(id, "k2")
        XCTAssertEqual(kind, "finished")
    }

    func testQuickCommandFillsTheDraft() {
        XCTAssertEqual(QuickCommand.insert("/compact", into: ""), "/compact")
        XCTAssertEqual(QuickCommand.insert("继续", into: "看完日志"), "看完日志 继续")
        XCTAssertEqual(QuickCommand.insert("继续", into: "第一行\n"), "第一行\n继续")
    }

    func testKeyBarUsesCoreKeyNames() {
        XCTAssertEqual(TerminalKey.bar.map(\.id), ["ctrl+c", "tab", "up", "down", "enter", "esc"])
    }
}
