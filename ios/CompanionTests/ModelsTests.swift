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
}
