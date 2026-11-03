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

    func testWorkingTimerAndParent() throws {
        let data = Data(#"""
        {"id":"t2","machine":null,"title":"sub","program":"claude","cwd":"/app",
         "status":{"state":"working"},"turn":0,"status_ms":1000000,"parent":"t1"}
        """#.utf8)
        let session = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session.parent, "t1")
        XCTAssertEqual(session.working(at: Date(timeIntervalSince1970: 1_012)), "工作中 · 12s")
        XCTAssertEqual(session.working(at: Date(timeIntervalSince1970: 990)), "工作中 · 0s", "a phone clock behind the Mac's")
        let idle = try JSONDecoder().decode(Session.self, from: Data(#"{"id":"t1","title":"a","cwd":"/","status":{"state":"idle"},"status_ms":1}"#.utf8))
        XCTAssertNil(idle.working(at: .now))
        XCTAssertNil(idle.parent)
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

    func testInterruptRepliesDecode() throws {
        let done = Data(#"{"type":"interrupted","id":"i1","outcome":"still_working"}"#.utf8)
        guard case .interrupted(let id, let outcome) = try JSONDecoder().decode(ServerMessage.self, from: done) else {
            return XCTFail("not interrupted")
        }
        XCTAssertEqual(id, "i1")
        XCTAssertEqual(outcome, "still_working")

        let failed = Data(#"{"type":"interrupt_failed","id":"i2","kind":"finished","message":"finished"}"#.utf8)
        guard case .interruptFailed(let id, let kind, _) = try JSONDecoder().decode(ServerMessage.self, from: failed) else {
            return XCTFail("not interrupt_failed")
        }
        XCTAssertEqual(id, "i2")
        XCTAssertEqual(kind, "finished")
    }

    func testPutRepliesDecode() throws {
        let done = Data(#"{"type":"put_done","id":"p1","path":"/tmp/t7/image.jpg"}"#.utf8)
        guard case .putDone(let id, let path) = try JSONDecoder().decode(ServerMessage.self, from: done) else {
            return XCTFail("not put_done")
        }
        XCTAssertEqual(id, "p1")
        XCTAssertEqual(path, "/tmp/t7/image.jpg")

        let failed = Data(#"{"type":"put_failed","id":"p2","kind":"too_large","message":"文件为空或超过 8 MB"}"#.utf8)
        guard case .putFailed(_, let kind, _) = try JSONDecoder().decode(ServerMessage.self, from: failed) else {
            return XCTFail("not put_failed")
        }
        XCTAssertEqual(kind, "too_large")
    }

    func testCommandListDecodes() throws {
        let list = Data(#"{"type":"command_list","id":"c1","commands":[{"name":"/tdd","description":"Test first","source":"skill"},{"name":"/x","description":"","source":"plugin"}]}"#.utf8)
        guard case .commandList(let id, let commands) = try JSONDecoder().decode(ServerMessage.self, from: list) else {
            return XCTFail("not command_list")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(commands, [SlashCommand(name: "/tdd", description: "Test first", source: .skill),
                                  SlashCommand(name: "/x", description: "", source: .other)])

        let failed = Data(#"{"type":"commands_failed","id":"c2","kind":"unreachable","message":"no answer"}"#.utf8)
        guard case .commandsFailed(_, let kind, _) = try JSONDecoder().decode(ServerMessage.self, from: failed) else {
            return XCTFail("not commands_failed")
        }
        XCTAssertEqual(kind, "unreachable")
    }
}
