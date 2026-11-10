import Foundation
import Testing
@testable import Yochi

@MainActor
struct ConversationCardsTests {
    private func items(_ json: String) throws -> [ConversationItem] {
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        guard case .conversation(_, let items) = message else {
            Issue.record("not a conversation")
            return []
        }
        return items
    }

    @Test("Edits, subtasks, to-do lists and peer messages decode")
    func decodes() throws {
        let items = try items(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"tool","id":"t1","name":"Edit","summary":"/x/ios/A.swift","state":"done",
           "edit":{"path":"/x/ios/A.swift","added":2,"deleted":1,"patch":"@@ -3,2 +3,3 @@\n keep\n-old\n+new\n+more\n","truncated":false}},
          {"kind":"tool","id":"t2","name":"Write","summary":"/x/N.md","state":"done",
           "edit":{"path":"/x/N.md","added":2,"deleted":0,"patch":"@@ -0,0 +1,2 @@\n+a\n+b\n","created":true,"truncated":false}},
          {"kind":"tool","id":"t3","name":"Agent","summary":"Find items","state":"running",
           "agent":{"name":"Find items","type":"Explore","started_ms":1762156800000,"background":true}},
          {"kind":"todos","id":"t4","items":[{"text":"读代码","active":"读代码中","status":"in_progress"},{"text":"写测试","status":"pending"}]},
          {"kind":"peer","id":"u1","direction":"received","name":"static-workorder","text":"已改好","state":"done"}
        ]}
        """#)
        #expect(items.map(\.kind) == [.tool, .tool, .tool, .todos, .peer])
        let edit = try #require(items[0].edit)
        #expect((edit.name, edit.directory, edit.title) == ("A.swift", "/x/ios", "编辑 A.swift"))
        #expect(edit.accessibilityLabel == "编辑 A.swift，增加 2 行，删除 1 行，在 /x/ios")
        #expect(ParsedDiff(edit.patch).hunks[0].lines.map(\.kind) == [.context, .deleted, .added, .added])
        #expect(items[1].edit?.title == "新建 N.md，2 行")
        let subtask = try #require(items[2].agent)
        #expect(subtask.background && subtask.type == "Explore" && subtask.startedMs == 1_762_156_800_000)
        #expect(items[3].todos == [TodoEntry(text: "读代码", active: "读代码中", status: .inProgress),
                                   TodoEntry(text: "写测试", status: .pending)])
        #expect(items[4].direction == .received && items[4].name == "static-workorder")
    }

    @Test("The line above the composer follows the newest list's item in progress")
    func progress() throws {
        let list = try items(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"todos","id":"t1","items":[{"text":"旧的","status":"in_progress"}]},
          {"kind":"agent","id":"a1","text":"…"},
          {"kind":"todos","id":"t2","items":[
            {"text":"读代码","status":"completed"},{"text":"写测试","active":"写测试中","status":"in_progress"},{"text":"提交","status":"pending"}]}
        ]}
        """#)
        let progress = try #require(TodoProgress(items: list))
        #expect(progress.text == "正在：写测试中（1/3）")
        #expect(progress.accessibilityLabel == "正在：写测试中，已完成 1 项，共 3 项")
        let saysIt = try items(#"{"type":"conversation","supported":true,"items":[{"kind":"todos","id":"t1","items":[{"text":"查","active":"正在查路线图","status":"in_progress"}]}]}"#)
        #expect(TodoProgress(items: saysIt)?.text == "正在查路线图（0/1）")

        let done = try items(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"todos","id":"t1","items":[{"text":"读代码","status":"in_progress"}]},
          {"kind":"todos","id":"t2","items":[{"text":"读代码","status":"completed"}]}
        ]}
        """#)
        #expect(TodoProgress(items: done) == nil)
        #expect(TodoProgress(items: []) == nil)
    }

    @Test("Subtask timing ticks while it runs and says how long it took")
    func timing() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        func subtask(_ json: String) throws -> Subtask {
            try JSONDecoder().decode(Subtask.self, from: Data(json.utf8))
        }
        let running = try subtask(#"{"name":"n","started_ms":1000000,"background":false}"#)
        #expect(running.timing(state: .running, now: start.addingTimeInterval(12)) == "运行中 12s")
        #expect(running.timing(state: .running, now: start.addingTimeInterval(-5)) == "运行中 0s", "a phone clock behind the Mac's")
        let background = try subtask(#"{"name":"n","started_ms":1000000,"background":true}"#)
        #expect(background.timing(state: .running, now: start.addingTimeInterval(150)) == "后台 · 2m 30s")
        let finished = try subtask(#"{"name":"n","duration_ms":3725000}"#)
        #expect(finished.timing(state: .done, now: start) == "用时 1h 2m")
        #expect(finished.timing(state: .error, now: start) == "失败")
        #expect(try subtask(#"{"name":"n"}"#).timing(state: .done, now: start) == nil)
        #expect(Elapsed.spoken(milliseconds: 150_000) == "2 分 30 秒")
    }

    @Test("A peer row names the other Agent, or says it is unknown")
    func peerHeading() throws {
        let list = try items(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"peer","id":"p1","direction":"sent","name":"Find items","text":"hi","state":"running"},
          {"kind":"peer","id":"p2","direction":"received","text":"hi","state":"done"}
        ]}
        """#)
        #expect(PeerRow(item: list[0]).heading == "发给 Find items")
        #expect(PeerRow(item: list[1]).heading == "来自 另一个 Agent")
        let marked = try items(#"{"type":"conversation","supported":true,"items":[{"kind":"peer","id":"p","direction":"received","text":"要，**网页版**下周改","state":"done"}]}"#)
        #expect(PeerRow(item: marked[0]).plainText == "要，网页版下周改")
    }
}
