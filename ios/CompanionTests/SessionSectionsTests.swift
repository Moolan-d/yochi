import XCTest
@testable import Companion

final class SessionSectionsTests: XCTestCase {
    private func session(_ id: String, machine: String? = nil, state: String? = nil) throws -> Session {
        var json: [String: Any] = ["id": id, "title": id, "cwd": "/"]
        if let machine { json["machine"] = machine }
        if let state { json["status"] = ["state": state] }
        return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func space(_ id: String, _ name: String, machine: String? = nil, tabs: [(String, [String])]) -> Space {
        Space(id: id, machine: machine, name: name,
              tabs: tabs.map { SpaceTab(id: "\(id)/\($0.0)", name: $0.0, sessions: $0.1) })
    }

    func testSessionsMessageWithoutSpacesDecodes() throws {
        let data = Data(#"{"type":"sessions","core":"mac","connected":true,"sessions":[]}"#.utf8)
        guard case .sessions(_, _, _, let spaces) = try JSONDecoder().decode(ServerMessage.self, from: data) else {
            return XCTFail("not a sessions message")
        }
        XCTAssertEqual(spaces, [])
    }

    func testWithoutSpacesGroupsByMachine() throws {
        let sections = sessionSections(
            sessions: [try session("vps/t1", machine: "vps"), try session("t1")], spaces: [])
        XCTAssertEqual(sections.map(\.title), ["本机", "vps"])
        XCTAssertEqual(sections.map(\.kind), [.others, .others])
        XCTAssertNil(sections[0].tabs[0].title)
    }

    func testSpacesTabsAndOthers() throws {
        let sessions = [
            try session("t1", state: "idle"), try session("t2", state: "working"),
            try session("t3"), try session("t9"), try session("vps/t1", machine: "vps"),
        ]
        let spaces = [
            space("sp1", "app", tabs: [("1", ["t1", "t2"]), ("logs", ["t3"])]),
            space("vps/sp1", "infra", machine: "vps", tabs: [("1", ["vps/t1"])]),
        ]
        let sections = sessionSections(sessions: sessions, spaces: spaces)
        XCTAssertEqual(sections.map(\.title), ["app", "infra", "其他终端"])
        XCTAssertEqual(sections[0].tabs.map(\.title), ["1", "logs"])
        XCTAssertEqual(sections[0].tabs[0].entries.map(\.id), ["t1", "t2"])
        XCTAssertEqual(sections[0].status, "working")
        XCTAssertNil(sections[1].tabs[0].title, "a single tab needs no header")
        XCTAssertEqual(sections[1].machine, "vps")
        XCTAssertEqual(sections[2].tabs[0].entries.map(\.id), ["t9"])
    }

    func testBlockedAgentsComeFirstWithTheirPlace() throws {
        let sessions = [
            try session("t1", state: "working"), try session("t2", state: "blocked"),
            try session("vps/t1", machine: "vps", state: "blocked"), try session("t9", state: "blocked"),
        ]
        let spaces = [
            space("sp1", "app", tabs: [("1", ["t1"]), ("review", ["t2"])]),
            space("vps/sp1", "infra", machine: "vps", tabs: [("1", ["vps/t1"])]),
        ]
        let sections = sessionSections(sessions: sessions, spaces: spaces)
        XCTAssertEqual(sections.first?.kind, .needsMe)
        XCTAssertEqual(sections[0].tabs[0].entries.map(\.id), ["t2", "vps/t1", "t9"])
        XCTAssertEqual(sections[0].tabs[0].entries.map(\.place), ["app · review", "vps · infra", nil])
        // Still listed in their own space too.
        XCTAssertEqual(sections[1].title, "app")
        XCTAssertEqual(sections[1].status, "blocked")
    }

    func testMostUrgentStatus() throws {
        XCTAssertEqual(AgentStatus.mostUrgent([try session("a", state: "idle"), try session("b", state: "blocked")]), "blocked")
        XCTAssertEqual(AgentStatus.mostUrgent([try session("a"), try session("b", state: "done")]), "done")
        XCTAssertNil(AgentStatus.mostUrgent([try session("a")]))
    }
}
