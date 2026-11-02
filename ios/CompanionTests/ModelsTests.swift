import XCTest
@testable import Companion

final class ModelsTests: XCTestCase {
    func testSessionWithoutTurnDecodesAsZero() throws {
        let data = Data(#"""
        {"id":"t1","machine":null,"title":"agent","program":"cat","cwd":"/","status":null}
        """#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session.turn, 0)
    }

    func testSessionTurnRoundTrips() throws {
        let data = Data(#"""
        {"id":"t1","machine":"vps","title":"agent","program":"claude","cwd":"/app",
         "status":{"state":"working"},"turn":7}
        """#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session.turn, 7)
        XCTAssertEqual(session.status?.state, "working")
    }

    func testRunRepliesDecode() throws {
        let created = Data(#"{"type":"run_created","id":"r1","session":"vps-us/t7"}"#.utf8)
        guard case .runCreated(let id, let session) = try JSONDecoder().decode(ServerMessage.self, from: created) else {
            return XCTFail("not run_created")
        }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(session, "vps-us/t7")

        let failed = Data(#"{"type":"run_failed","id":"r2","kind":"machine_unknown","message":"no such machine"}"#.utf8)
        guard case .runFailed(let id, let kind, let message) = try JSONDecoder().decode(ServerMessage.self, from: failed) else {
            return XCTFail("not run_failed")
        }
        XCTAssertEqual(id, "r2")
        XCTAssertEqual(kind, "machine_unknown")
        XCTAssertEqual(message, "no such machine")
    }
}
