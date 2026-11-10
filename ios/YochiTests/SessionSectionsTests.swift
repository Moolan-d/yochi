import XCTest
@testable import Yochi

final class SessionSectionsTests: XCTestCase {
    private func session(
        _ id: String, title: String? = nil, machine: String? = nil, state: String? = nil, parent: String? = nil,
        cwd: String = "/w/app", turn: Int = 0, extra: [String: Any] = [:]
    ) throws -> Session {
        var json: [String: Any] = ["id": id, "title": title ?? id, "cwd": cwd, "turn": turn]
        if let parent { json["parent"] = parent }
        if let machine { json["machine"] = machine }
        if let state { json["status"] = ["state": state] }
        json.merge(extra) { _, new in new }
        return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func agent(_ id: String, _ state: String = "idle", parent: String? = nil, turn: Int = 0,
                       extra: [String: Any] = [:]) throws -> Session {
        try session(id, state: state, parent: parent, turn: turn, extra: extra)
    }

    private func space(_ id: String, _ name: String, machine: String? = nil, tabs: [(String, [String])]) -> Space {
        Space(id: id, machine: machine, name: name, folder: nil,
              tabs: tabs.map { SpaceTab(id: "\(id)/\($0.0)", name: $0.0, sessions: $0.1, layout: nil) })
    }

    private func row(_ session: Session, space: String? = nil, tab: String? = nil, unseen: Bool = false) -> HomeRow {
        HomeRow(session: session, space: space, tab: tab, unseen: unseen)
    }

    func testSessionsMessageWithoutSpacesDecodes() throws {
        let data = Data(#"{"type":"sessions","core":"mac","connected":true,"sessions":[]}"#.utf8)
        guard case .sessions(_, _, _, let spaces) = try JSONDecoder().decode(ServerMessage.self, from: data) else {
            return XCTFail("not a sessions message")
        }
        XCTAssertEqual(spaces, [])
    }

    func testNewFieldsDecodeAndBadOnesAreDropped() throws {
        let full = try agent("t1", extra: [
            "pinned": true, "seen": 3, "repo": ["name": "app", "worktree": "fix"],
            "todo": ["text": "写测试", "done": 1, "total": 4],
        ])
        XCTAssertEqual(full.pinned, true)
        XCTAssertEqual(full.seen, 3)
        XCTAssertEqual(full.repo, Repo(name: "app", worktree: "fix"))
        XCTAssertEqual(full.todo, TodoNow(text: "写测试", done: 1, total: 4))
        let odd = try agent("t2", extra: ["repo": "app", "todo": ["text": 1]])
        XCTAssertNil(odd.repo)
        XCTAssertNil(odd.todo)
        XCTAssertFalse(odd.pinned)
    }

    func testOnlyAgentsAreListedAndTerminalsFold() throws {
        let sessions = [try agent("t1"), try session("t2"), try agent("t3", "working"), try session("t9")]
        let home = makeHome(sessions: sessions, spaces: [space("sp1", "app", tabs: [("1", ["t1", "t2"]), ("logs", ["t3"])])])
        XCTAssertEqual(home.groups.map(\.title), ["app", "其他终端"])
        XCTAssertEqual(home.groups[0].agents.map(\.id), ["t1", "t3"])
        XCTAssertEqual(home.groups[0].terminals.map(\.id), ["t2"])
        XCTAssertEqual(home.groups[0].agents.map(\.tab), [nil, "logs"], "numbered tabs say nothing")
        XCTAssertEqual(home.groups[1].agents, [])
        XCTAssertEqual(home.groups[1].terminals.map(\.id), ["t9"])
    }

    func testWithoutSpacesGroupsByMachine() throws {
        let home = makeHome(sessions: [try agent("vps/t1").with(machine: "vps"), try agent("t1")], spaces: [])
        XCTAssertEqual(home.groups.map(\.title), ["本机", "vps"])
        XCTAssertEqual(home.groups.map(\.machine), [nil, nil], "the title already names it")
    }

    func testRemoteSpacesAndOthersCarryTheirMachine() throws {
        let sessions = [try agent("t1"), try agent("vps/t1").with(machine: "vps"), try agent("vps/t2").with(machine: "vps")]
        let home = makeHome(sessions: sessions, spaces: [
            space("sp1", "app", tabs: [("1", ["t1"])]),
            space("vps/sp1", "infra", machine: "vps", tabs: [("1", ["vps/t1"])]),
        ])
        XCTAssertEqual(home.groups.map(\.title), ["app", "infra", "其他终端"])
        XCTAssertEqual(home.groups.map(\.machine), [nil, "vps", "vps"])
    }

    func testChildAgentsFollowTheirParentOutsideSpaces() throws {
        let sessions = [
            try agent("t1"), try agent("t5", parent: "t9"), try agent("t3", parent: "t2"),
            try agent("t2"), try agent("t4", parent: "t1"), try agent("t6", parent: "t4"),
        ]
        // t5's parent is gone, so it stands on its own.
        XCTAssertEqual(makeHome(sessions: sessions, spaces: []).groups[0].agents.map(\.id), ["t1", "t4", "t6", "t5", "t2", "t3"])
    }

    func testPinnedAgentsLeadWithTheirChildren() throws {
        let sessions = [try agent("t1"), try agent("t2", extra: ["pinned": true]), try agent("t3", parent: "t2"), try agent("t4")]
        let home = makeHome(sessions: sessions, spaces: [space("sp1", "app", tabs: [("1", ["t1", "t2", "t3", "t4"])])])
        XCTAssertEqual(home.groups[0].agents.map(\.id), ["t2", "t3", "t1", "t4"])
    }

    func testInboxGroupsAgentsByStateInListOrder() throws {
        let sessions = [
            try agent("t1", "done", turn: 5, extra: ["seen": 5]),
            try agent("t2", "done", turn: 5, extra: ["seen": 4]),
            try agent("t3", "blocked"),
            try agent("t4", "done", turn: 2),
            try agent("t5", "working", turn: 9),
            try agent("t6", "done", turn: 3),
            try agent("t7", "error"),
            try agent("t8", "idle"),
            try agent("t9", "working"),
            try session("t10"),
        ]
        let inbox = makeInbox(sessions: sessions, spaces: [space("sp1", "app", tabs: [("1", sessions.map(\.id))])],
                              seen: ["t4": 2, "t6": 2])
        XCTAssertEqual(inbox.sections.map(\.kind), [.needsYou, .done, .working, .idle])
        XCTAssertEqual(inbox.sections[0].rows.map(\.id), ["t3", "t7"], "blocked and failed, in list order")
        XCTAssertEqual(inbox.sections[1].rows.map(\.id), ["t2", "t6"], "t4 was seen on this iPhone, t1 on the desktop")
        XCTAssertEqual(inbox.sections[2].rows.map(\.id), ["t5", "t9"])
        XCTAssertEqual(inbox.sections[3].rows.map(\.id), ["t1", "t4", "t8"], "finished and seen rests")
        XCTAssertEqual(inbox.badge, 2)
        XCTAssertEqual(inbox.terminals.map(\.id), ["t10"], "terminals stay out of the sections")
    }

    func testInboxOmitsEmptySectionsAndHasNoBadgeWithoutNeeds() throws {
        let inbox = makeInbox(sessions: [try agent("t1", "working"), try session("t2")], spaces: [])
        XCTAssertEqual(inbox.sections.map(\.kind), [.working])
        XCTAssertEqual(inbox.badge, 0)
        XCTAssertFalse(inbox.isEmpty)
        XCTAssertTrue(makeInbox(sessions: [try session("t2")], spaces: []).isEmpty)
    }

    func testInboxKeepsSpaceOrderAndPinnedFirstInsideASection() throws {
        let sessions = [
            try agent("t1", "working"), try agent("t2", "working", extra: ["pinned": true]),
            try agent("v1", "working").with(machine: "vps"), try agent("t3", "working"),
        ]
        let inbox = makeInbox(sessions: sessions, spaces: [
            space("sp1", "app", tabs: [("1", ["t1", "t2"])]),
            space("vps/sp1", "infra", machine: "vps", tabs: [("1", ["v1"])]),
        ])
        XCTAssertEqual(inbox.sections[0].rows.map(\.id), ["t2", "t1", "v1", "t3"])
    }

    func testSearchSplitsAgentsFromTerminalsAndFindsBySpaceFolderAndMachine() throws {
        let sessions = [
            try agent("t1", extra: ["repo": ["name": "companion", "worktree": "home"]]),
            try session("t2", title: "pnpm dev", cwd: "/w/companion"),
            try agent("v1", "blocked").with(machine: "vps"),
            try session("t4", title: "htop", cwd: "/root"),
        ]
        let inbox = makeInbox(sessions: sessions, spaces: [space("sp1", "运维", tabs: [("1", ["t1", "t2"])])])
        var found = inbox.search("companion")
        XCTAssertEqual(found.agents.map(\.id), ["t1"])
        XCTAssertEqual(found.terminals.map(\.id), ["t2"], "by folder")
        found = inbox.search("运维")
        XCTAssertEqual(found.agents.map(\.id), ["t1"])
        XCTAssertEqual(found.terminals.map(\.id), ["t2"], "by space")
        XCTAssertEqual(inbox.search("vps").agents.map(\.id), ["v1"], "by machine")
        XCTAssertEqual(inbox.search("home").agents.map(\.id), ["t1"], "by worktree")
        XCTAssertEqual(inbox.search("htop").terminals.map(\.id), ["t4"])
        XCTAssertTrue(inbox.search("nothing").agents.isEmpty && inbox.search("nothing").terminals.isEmpty)
    }

    func testRowDetailIsTheQuestionOrTheTodoAndNothingElse() throws {
        let blocked = try agent("t1", "blocked", extra: ["status": ["state": "blocked", "message": "要运行 npm test，允许吗？"]])
        XCTAssertEqual(row(blocked).detail, .question("要运行 npm test，允许吗？"))
        let asking = try agent("t1", "blocked", extra: ["status": ["state": "blocked", "kind": "question", "message": "answer: 先处理哪件事？"]])
        XCTAssertEqual(row(asking).detail, .question("先处理哪件事？"), "herdr-core's reply hint stays off the row")
        XCTAssertNil(row(try agent("t1", "blocked")).detail, "the pill says it already")
        let working = try agent("t1", "working", extra: ["todo": ["text": "补单元测试", "done": 3, "total": 7]])
        XCTAssertEqual(row(working).detail, .progress("正在：补单元测试（3/7）"))
        XCTAssertNil(row(try agent("t1", "working")).detail)
        XCTAssertEqual(row(try agent("t1", "error", extra: ["status": ["state": "error", "message": "boom"]])).detail, .failure("boom"))
        XCTAssertNil(row(try agent("t1", "idle")).detail)
        XCTAssertNil(row(try agent("t1", "done")).detail)
    }

    func testRowSignalNamesTheTrailingState() throws {
        XCTAssertEqual(row(try agent("t1", "blocked")).signal, .needsYou)
        XCTAssertEqual(row(try agent("t1", "error")).signal, .error)
        XCTAssertEqual(row(try agent("t1", "working")).signal, .working)
        XCTAssertEqual(row(try agent("t1", "done"), unseen: true).signal, .unseen)
        XCTAssertNil(row(try agent("t1", "done")).signal)
        XCTAssertNil(row(try agent("t1", "idle")).signal)
    }

    func testShortAgoAndSince() throws {
        XCTAssertEqual(ShortAgo.text(milliseconds: 30_000), "刚刚")
        XCTAssertEqual(ShortAgo.text(milliseconds: 240_000), "4分")
        XCTAssertEqual(ShortAgo.text(milliseconds: 3_600_000), "1时")
        XCTAssertEqual(ShortAgo.text(milliseconds: 172_800_000), "2天")
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(row(try agent("t1", "working", extra: ["status_ms": Int64(1_000 - 240) * 1000])).since(at: now), "4分")
        XCTAssertNil(row(try agent("t1", "working")).since(at: now), "the Gateway doesn't say since when")
    }

    func testPlaceLineSaysChildAgents() throws {
        XCTAssertEqual(row(try agent("t2", "idle", parent: "t1"), space: "app").placeLine(awayFromSpace: true), "子 Agent · app")
        XCTAssertEqual(row(try agent("t2")).placeLine(awayFromSpace: true), "app")
    }

    func testSpaceColorsAreStableAndAccessible() {
        XCTAssertEqual(SpacePalette.light.count, SpacePalette.dark.count)
        // Pinned: a space keeps its color across launches and updates.
        XCTAssertEqual(SpacePalette.index(for: "sp1"), 5)
        XCTAssertEqual(SpacePalette.index(for: "sp2"), 4)
        XCTAssertEqual(SpacePalette.index(for: "vps/sp1"), 5)
        for id in ["", "a", "sp1", "有中文", "vps/sp9"] {
            XCTAssert((0..<SpacePalette.count).contains(SpacePalette.index(for: id)))
        }
        for hex in SpacePalette.light + SpacePalette.dark {
            XCTAssertGreaterThanOrEqual(contrast(hex, 0xFFFFFF), 3, String(hex, radix: 16))
        }
    }

    func testHomeColorsKeepTextReadable() {
        for (text, fill) in HomeColorValues.pairs {
            XCTAssertGreaterThanOrEqual(contrast(text, fill), 4.5, "\(String(text, radix: 16)) on \(String(fill, radix: 16))")
        }
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((hex >> UInt32(shift)) & 0xFF) / 255
                return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    func testSpacesBoardListsSpacesTabsAndWhatIsInNoSpace() throws {
        let sessions = [
            try agent("t1", "blocked"), try session("t2"), try agent("t3", "working"), try agent("t4", "done", turn: 2),
            try agent("t5", "idle", parent: "t1"),
            try agent("v1", "working").with(machine: "vps"), try session("v2").with(machine: "vps"),
            try session("t9"), try agent("t8", "idle", parent: "t9"),
        ]
        let board = makeSpacesBoard(sessions: sessions, spaces: [
            space("sp1", "app", tabs: [("1", ["t1", "t5", "t2"]), ("logs", ["t3"]), ("empty", ["gone"])]),
            space("sp2", "docs", tabs: [("1", ["t4"])]),
            space("vps/sp1", "infra", machine: "vps", tabs: [("1", ["v1"])]),
            space("sp3", "gone", tabs: [("1", ["gone"])]),
        ])
        XCTAssertEqual(board.map(\.machine), [nil, "vps"], "this Mac first")
        XCTAssertEqual(board.map(\.title), ["本机", "vps"])
        let mac = board[0]
        XCTAssertEqual(mac.spaces.map(\.name), ["app", "docs"], "a space with no live terminal is left out")
        XCTAssertEqual(mac.spaces[0].tabs.map(\.title), ["标签页 1", "logs"])
        XCTAssertEqual(mac.spaces[0].tabs.map { $0.rows.map(\.id) }, [["t1", "t5", "t2"], ["t3"]], "pane order, children after parents")
        XCTAssertEqual(mac.spaces[0].tabs[0].rows[0].spaceID, "sp1")
        XCTAssertEqual(mac.spaces.map(\.status), [.needsYou(1), .unseen])
        XCTAssertEqual(mac.others.map(\.id), ["t9", "t8"], "Agents too, children after their parent")
        XCTAssertEqual(board[1].spaces.map(\.status), [.working])
        XCTAssertEqual(board[1].others.map(\.id), ["v2"])
    }

    func testSpaceStatusPrefersWaitingThenWorkingThenUnseen() throws {
        let board = makeSpacesBoard(sessions: [
            try agent("a", "blocked"), try agent("b", "error"), try agent("c", "working"),
            try agent("d", "done", turn: 1), try agent("e", "idle"), try session("f"),
        ], spaces: [
            space("s1", "one", tabs: [("1", ["a", "b", "c"])]),
            space("s2", "two", tabs: [("1", ["c2", "d", "f"])]),
            space("s3", "three", tabs: [("1", ["e", "f2"])]),
        ])
        XCTAssertEqual(board[0].spaces.map(\.status), [.needsYou(2), .unseen, nil])
    }

    func testBoardWithoutSpacesHasOnlyTheMachinesTerminals() throws {
        let board = makeSpacesBoard(sessions: [try agent("t1"), try agent("v1").with(machine: "vps")], spaces: [])
        XCTAssertEqual(board.map(\.title), ["本机", "vps"])
        XCTAssertEqual(board.map { $0.spaces.count }, [0, 0])
        XCTAssertEqual(board.map { $0.others.count }, [1, 1])
    }

    func testPaneMarksTintWorkingAndBlockedPanesAndFoldInChildren() throws {
        let rows = [
            row(try agent("a", "working")), row(try agent("b", "blocked")), row(try session("c")),
            row(try agent("d", "blocked", parent: "c")), row(try agent("e", "idle")),
        ]
        let layout = PaneNode.row(of: ["a", "b", "c", "e"])
        let marks = paneMarks(layout: layout, rows: rows)
        XCTAssertEqual(marks["a"], .working)
        XCTAssertEqual(marks["b"], .blocked)
        XCTAssertEqual(marks["c"], .blocked, "a child Agent's state lands on the pane that started it")
        XCTAssertEqual(marks["e"], .idle)
        XCTAssertNil(marks["d"], "children have no pane of their own")
    }

    func testTabTitleNumbersTheUnnamed() {
        func title(_ name: String, _ position: Int) -> String {
            SpaceTabEntry(id: "x", name: name, position: position, layout: PaneNode(), rows: [], marks: [:]).title
        }
        XCTAssertEqual(title("review", 2), "review")
        XCTAssertEqual(title("3", 1), "标签页 3")
        XCTAssertEqual(title("", 2), "标签页 2")
    }

    func testTitleFallsBackFromGenericWords() throws {
        XCTAssertEqual(row(try session("t1", title: "修复登录", state: "idle")).title, "修复登录")
        for generic in ["Claude Code", "claude", "2.1.317", "t1", ""] {
            let agent = try session("t1", title: generic, state: "idle", cwd: "/w/app")
            XCTAssertEqual(row(agent, tab: "review").title, "review", generic)
            XCTAssertEqual(row(agent).title, "app", generic)
        }
        XCTAssertEqual(row(try session("t2", title: "pnpm dev")).title, "pnpm dev", "a terminal keeps its title")
    }

    func testSecondLine() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let at = { (seconds: Int) in Int64(1_000 - seconds) * 1000 }
        let blocked = try agent("t1", "blocked", extra: ["status": ["state": "blocked", "message": "要运行 npm test，允许吗？"]])
        XCTAssertEqual(row(blocked).activity(at: now), "要运行 npm test，允许吗？")
        XCTAssertEqual(row(try agent("t1", "blocked")).activity(at: now), "等你处理")
        let working = try agent("t1", "working", extra: ["status_ms": at(125), "todo": ["text": "补单元测试", "done": 3, "total": 7]])
        XCTAssertEqual(row(working).activity(at: now), "正在：补单元测试（3/7） · 2m 5s")
        XCTAssertEqual(row(try agent("t1", "working", extra: ["status_ms": at(5)])).activity(at: now), "工作中 · 5s")
        XCTAssertEqual(row(try agent("t1", "done", extra: ["status_ms": at(180)])).activity(at: now), "完成 · 3 分钟前")
        XCTAssertNil(row(try agent("t1", "idle")).activity(at: now))
        XCTAssertEqual(row(try agent("t2", "idle", parent: "t1")).activity(at: now), "子 Agent")
        XCTAssertEqual(row(try agent("t2", "blocked", parent: "t1")).activity(at: now), "子 Agent · 等你处理")
    }

    func testThirdLine() throws {
        let inWorktree = try agent("t1", extra: ["repo": ["name": "app", "worktree": "fix-a"]]).with(machine: "vps")
        XCTAssertEqual(row(inWorktree, space: "infra", tab: "review").place(awayFromSpace: false), "app · fix-a · review")
        XCTAssertEqual(row(inWorktree, space: "infra", tab: "review").place(awayFromSpace: true), "vps · infra · app · fix-a · review")
        XCTAssertEqual(row(try agent("t2")).place(awayFromSpace: false), "app", "no repository: the folder")
        XCTAssertEqual(row(try agent("t3"), space: "app").place(awayFromSpace: true), "app", "said once")
    }

    func testAccessibilityLabelReadsTheWholeRow() throws {
        let pinned = try session("t1", title: "修复登录", state: "done", parent: "t0",
                                 extra: ["pinned": true, "repo": ["name": "app"]])
        XCTAssertEqual(row(pinned, space: "web", unseen: true).accessibilityLabel(), "已置顶，修复登录，子 Agent，完成，未看过，app")
        XCTAssertEqual(row(pinned, space: "web").accessibilityLabel(awayFromSpace: true), "已置顶，修复登录，子 Agent，已完成，web · app")
    }

    func testSearchMatchesWhatTheRowShowsAndWhereItLives() throws {
        let found = row(try agent("t1", extra: ["repo": ["name": "companion", "worktree": "home"]]).with(machine: "vps"),
                        space: "运维", tab: "review")
        for query in ["COMPANION", "home", "运维", "review", "vps", "t1", " "] {
            XCTAssert(found.matches(query), query)
        }
        XCTAssertFalse(found.matches("nothing"))
    }

    func testTabMatesAreTheOtherTerminalsInItsTab() throws {
        let sessions = [try agent("t1"), try session("t2"), try session("t3"), try session("t4")]
        let spaces = [space("sp1", "app", tabs: [("1", ["t2", "t1", "t9", "t3"]), ("2", ["t4"])])]
        XCTAssertEqual(tabMates(of: "t1", sessions: sessions, spaces: spaces).map(\.id), ["t2", "t3"], "gone ones drop out")
        XCTAssertEqual(tabMates(of: "t4", sessions: sessions, spaces: spaces), [])
        XCTAssertEqual(tabMates(of: "t5", sessions: sessions, spaces: spaces), [], "in no tab")
    }

    func testAgo() {
        XCTAssertEqual(Ago.text(milliseconds: 30_000), "刚刚")
        XCTAssertEqual(Ago.text(milliseconds: 600_000), "10 分钟前")
        XCTAssertEqual(Ago.text(milliseconds: 7_200_000), "2 小时前")
        XCTAssertEqual(Ago.text(milliseconds: 172_800_000), "2 天前")
    }

    func testNewSessionGoesToTheSpaceHoldingItsDirectory() {
        let spaces = ["/Users/me", "/Users/me/app/", "/Users/me/app-docs", ""].enumerated().map { index, folder in
            Space(id: "sp\(index)", machine: nil, name: "s\(index)", folder: folder.isEmpty ? nil : folder, tabs: [])
        }
        XCTAssertEqual(spaceHolding("/Users/me/app", in: spaces)?.id, "sp1")
        XCTAssertEqual(spaceHolding(" /Users/me/app/src/ ", in: spaces)?.id, "sp1")
        XCTAssertEqual(spaceHolding("/Users/me/app-docs/a", in: spaces)?.id, "sp2")
        XCTAssertEqual(spaceHolding("/Users/me/notes", in: spaces)?.id, "sp0")
        XCTAssertNil(spaceHolding("/opt/x", in: spaces))
        XCTAssertNil(spaceHolding("", in: spaces))
        XCTAssertNil(spaceHolding("app", in: spaces))
    }
}

private extension Session {
    /// The same session on another machine.
    func with(machine: String) throws -> Session {
        var json: [String: Any] = ["id": id, "title": title, "cwd": cwd, "turn": turn, "machine": machine, "pinned": pinned]
        if let program { json["program"] = program }
        if let parent { json["parent"] = parent }
        if let status { json["status"] = ["state": status.state] }
        if let repo { json["repo"] = ["name": repo.name, "worktree": repo.worktree as Any? ?? NSNull()] }
        return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
