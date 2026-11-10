import XCTest
@testable import Yochi

final class PaneMapTests: XCTestCase {
    private func node(_ json: String) throws -> PaneNode {
        try JSONDecoder().decode(PaneNode.self, from: Data(json.utf8))
    }

    func testFramesFollowTheSplitsAndWeights() throws {
        let layout = try node("""
        {"split": "row", "children": [
          {"weight": 0.6, "session": "t3"},
          {"weight": 0.4, "split": "column", "children": [{"session": "t4"}, {}]}
        ]}
        """)
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames, [
            PaneFrame(session: "t3", rect: CGRect(x: 0, y: 0, width: 60, height: 50)),
            PaneFrame(session: "t4", rect: CGRect(x: 60, y: 0, width: 40, height: 25)),
            PaneFrame(session: nil, rect: CGRect(x: 60, y: 25, width: 40, height: 25)),
        ])
        XCTAssertEqual(layout.sessions, ["t3", "t4"])
    }

    func testGapsComeOutOfTheRoom() {
        let frames = PaneNode.row(of: ["a", "b"]).frames(in: CGRect(x: 0, y: 0, width: 103, height: 10), gap: 3)
        XCTAssertEqual(frames.map(\.rect), [CGRect(x: 0, y: 0, width: 50, height: 10), CGRect(x: 53, y: 0, width: 50, height: 10)])
    }

    func testAnUnknownSplitIsDrawnSideBySide() throws {
        XCTAssertEqual(try node(#"{"split": "grid", "children": [{}]}"#).split, .row)
        XCTAssertNil(try node(#"{"session": "t1"}"#).split)
    }

    func testTheTabLightsTheSessionOrTheTerminalThatStartedIt() {
        let tab = SpaceTab(id: "tb", name: "1", sessions: ["t3", "t7", "t4"],
                           layout: PaneNode.row(of: ["t3", "t4"]))
        let spaces = [Space(id: "sp", machine: nil, name: "app", folder: nil, tabs: [tab])]
        let sessions = [session("t3", parent: nil), session("t7", parent: "t3"), session("t4", parent: nil)]

        let child = PaneTab(of: "t7", sessions: sessions, spaces: spaces)
        XCTAssertEqual(child?.lit, "t3")
        XCTAssertEqual(child?.neighbor(1), "t4")
        XCTAssertEqual(child?.neighbor(-1), "t3")
        XCTAssertNil(PaneTab(of: "t4", sessions: sessions, spaces: spaces)?.neighbor(1))
        XCTAssertNil(PaneTab(of: "t9", sessions: sessions, spaces: spaces))
    }

    func testASwipeGoesFarOrFastEnough() {
        XCTAssertEqual(PaneSwipeGesture.step(moved: -80, speed: -50), 1)
        XCTAssertEqual(PaneSwipeGesture.step(moved: 80, speed: 0), -1)
        XCTAssertEqual(PaneSwipeGesture.step(moved: -20, speed: -900), 1)
        XCTAssertNil(PaneSwipeGesture.step(moved: -20, speed: -100))
        // Flicked back the other way: no switch.
        XCTAssertNil(PaneSwipeGesture.step(moved: -90, speed: 600))
    }

    private func session(_ id: String, parent: String?) -> Session {
        var json: [String: Any] = ["id": id, "title": id, "cwd": "/", "turn": 0]
        if let parent { json["parent"] = parent }
        return try! JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
