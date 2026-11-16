import XCTest
@testable import Yochi

final class ConversationTurnsTests: XCTestCase {
    private func items(_ json: String) throws -> [ConversationItem] {
        try JSONDecoder().decode([ConversationItem].self, from: Data(json.utf8))
    }

    private let finishedAndOpen = #"""
    [{"kind":"user","id":"u1","text":"fix it"},
     {"kind":"agent","id":"a1","text":"Looking."},
     {"kind":"tool","id":"t1","name":"Read","summary":"a.swift","state":"done"},
     {"kind":"tool","id":"t2","name":"Edit","summary":"a.swift","state":"done"},
     {"kind":"agent","id":"a2","text":"Fixed."},
     {"kind":"user","id":"u2","text":"now test"},
     {"kind":"tool","id":"t3","name":"Bash","summary":"make","state":"running"}]
    """#

    func testFinishedTurnFoldsItsMiddle() throws {
        let entries = ConversationTurns.entries(try items(finishedAndOpen), inProgress: false)
        XCTAssertEqual(entries.prefix(3).map(\.id), ["u1", "fold-a1", "a2"])
        guard case .folded(_, let steps) = entries[1] else { return XCTFail("not folded") }
        XCTAssertEqual(steps.map(\.id), ["a1", "t1", "t2"])
    }

    func testTurnWithoutAReplyStaysOpen() throws {
        let entries = ConversationTurns.entries(try items(finishedAndOpen), inProgress: false)
        // The second turn has no reply yet: its tool stays in view.
        XCTAssertEqual(entries.map(\.id), ["u1", "fold-a1", "a2", "u2", "t3"])
    }

    func testLastTurnStaysOpenWhileTheAgentWorks() throws {
        let done = #"""
        [{"kind":"user","id":"u1","text":"go"},
         {"kind":"tool","id":"t1","name":"Read","state":"done"},
         {"kind":"agent","id":"a1","text":"Done."}]
        """#
        XCTAssertEqual(ConversationTurns.entries(try items(done), inProgress: true).map(\.id), ["u1", "t1", "a1"])
        XCTAssertEqual(ConversationTurns.entries(try items(done), inProgress: false).map(\.id), ["u1", "fold-t1", "a1"])
    }

    func testNoticesAndUserMessagesStayVisible() throws {
        let json = #"""
        [{"kind":"user","id":"u1","text":"go"},
         {"kind":"tool","id":"t1","name":"Read","state":"done"},
         {"kind":"notice","id":"n1","text":"x","code":"interrupted"},
         {"kind":"tool","id":"t2","name":"Read","state":"done"},
         {"kind":"agent","id":"a1","text":"Done."}]
        """#
        XCTAssertEqual(ConversationTurns.entries(try items(json), inProgress: false).map(\.id),
                       ["u1", "fold-t1", "n1", "fold-t2", "a1"])
    }

    func testAConversationStartingWithoutAUserMessageIsOneTurn() throws {
        let json = #"""
        [{"kind":"tool","id":"t1","name":"Read","state":"done"},
         {"kind":"agent","id":"a1","text":"Hi."}]
        """#
        XCTAssertEqual(ConversationTurns.entries(try items(json), inProgress: false).map(\.id), ["fold-t1", "a1"])
        XCTAssertTrue(ConversationTurns.entries([], inProgress: false).isEmpty)
    }
}
