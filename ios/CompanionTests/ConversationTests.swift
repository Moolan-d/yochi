import XCTest
@testable import Companion

@MainActor
final class ConversationTests: XCTestCase {
    private func decode(_ json: String) throws -> ConversationMessage {
        try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
    }

    func testItemsReplaceByIdAndUnknownKindsAreSkipped() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"user","id":"u1","text":"run it"},
          {"kind":"tool","id":"toolu_1","name":"Bash","summary":"ls","state":"running"},
          {"kind":"hologram","id":"x1"}
        ]}
        """#))
        XCTAssertEqual(feed.phase, .following)
        XCTAssertEqual(feed.items.map(\.id), ["u1", "toolu_1"])

        feed.apply(try decode(#"""
        {"type":"items","items":[
          {"kind":"tool","id":"toolu_1","name":"Bash","summary":"ls","state":"done","output":"a\nb"},
          {"kind":"agent","id":"a1.0","text":"Done **here**."}
        ]}
        """#))
        XCTAssertEqual(feed.items.map(\.id), ["u1", "toolu_1", "a1.0"])
        XCTAssertEqual(feed.items[1].state, .done)
        XCTAssertEqual(feed.items[1].output, "a\nb")
    }

    func testTaskReportsAreTheirOwnItems() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"task","id":"u1","summary":"Agent \"Find roadmap items\" finished","state":"done","text":"Found **3**."},
          {"kind":"task","id":"u2","summary":"Background command \"make\" failed with exit code 1","state":"error"}
        ]}
        """#))
        XCTAssertEqual(feed.items.map(\.kind), [.task, .task])
        let subagent = TaskRow(item: feed.items[0])
        XCTAssertEqual(subagent.heading, "子代理完成")
        XCTAssertEqual(subagent.detail, "Find roadmap items")
        XCTAssertEqual(feed.items[0].text, "Found **3**.")
        let command = TaskRow(item: feed.items[1])
        XCTAssertEqual(command.heading, "后台任务失败")
        XCTAssertEqual(command.detail, "Background command \"make\" failed with exit code 1")
    }

    func testPendingPointsAtItsToolAndQuestionDecodes() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"tool","id":"toolu_2","name":"AskUserQuestion","summary":"Cats or Dogs?","state":"running",
           "questions":[{"question":"Cats or Dogs?","header":"Pet","multi_select":false,
                         "options":[{"label":"Cats","description":"Meow"},{"label":"Dogs","description":null}]}]}
        ]}
        """#))
        feed.apply(try decode(#"""
        {"type":"pending","pending":{"kind":"question","message":"answer: Cats or Dogs? (Cats · Dogs)","tool":"toolu_2"}}
        """#))
        XCTAssertEqual(feed.pending?.kind, "question")
        let question = try XCTUnwrap(feed.pendingTool?.questions?.first)
        XCTAssertFalse(question.multiSelect)
        XCTAssertEqual(question.options.map(\.label), ["Cats", "Dogs"])

        feed.apply(try decode(#"{"type":"pending","pending":null}"#))
        XCTAssertNil(feed.pending)
    }

    func testUnsupportedAndClosed() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"{"type":"conversation","supported":false,"items":[]}"#))
        XCTAssertEqual(feed.phase, .unsupported)
        feed.apply(try decode(#"{"type":"closed","reason":"finished"}"#))
        XCTAssertEqual(feed.phase, .closed(reason: "会话已结束"))
    }

    func testModeIsTheLatestAndForgottenWithAFreshConversation() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"{"type":"conversation","supported":true,"items":[]}"#))
        XCTAssertNil(feed.mode)
        feed.apply(try decode(#"{"type":"mode","mode":"acceptEdits"}"#))
        XCTAssertEqual(feed.mode, .acceptEdits)
        feed.apply(try decode(#"{"type":"mode","mode":"someNewMode"}"#))
        XCTAssertNil(feed.mode)
        feed.apply(try decode(#"{"type":"mode","mode":"plan"}"#))
        feed.apply(try decode(#"{"type":"conversation","supported":true,"items":[]}"#))
        XCTAssertNil(feed.mode)
    }

    func testClaudeCodeIsRecognisedByStatusOrCommand() throws {
        func session(_ program: String, app: String?) throws -> Session {
            let status = app.map { #"{"state":"idle","app":"\#($0)"}"# } ?? "null"
            return try JSONDecoder().decode(Session.self, from: Data(#"""
            {"id":"t1","machine":null,"title":"x","program":"\#(program)","cwd":"/","status":\#(status)}
            """#.utf8))
        }
        XCTAssertTrue(QuickCommand.isClaudeCode(try session("2.1.316", app: "claude-code")))
        XCTAssertTrue(QuickCommand.isClaudeCode(try session("claude", app: nil)))
        XCTAssertFalse(QuickCommand.isClaudeCode(try session("pi", app: "pi")))
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownBlock.parse("""
        # Plan
        First **line**
        continues here.

        - one
          - nested
        - two

          more of two
        3. third
        > quoted
        ```swift
        let x = 1

        print(x)
        ```
        ---
        Tail
        """)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(1), .paragraph, .listItem(marker: "•"), .listItem(marker: "◦"), .listItem(marker: "•"),
            .paragraph, .listItem(marker: "3."), .paragraph, .code(language: "swift"), .rule, .paragraph,
        ])
        XCTAssertEqual(blocks.map(\.text), [
            "Plan", "First line\ncontinues here.", "one", "nested", "two",
            "more of two", "third", "quoted", "let x = 1\n\nprint(x)", "", "Tail",
        ])
        XCTAssertEqual(blocks.map(\.listDepth), [0, 0, 1, 2, 1, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(blocks[7].quoteDepth, 1)
    }

    func testMarkdownTable() throws {
        let blocks = MarkdownBlock.parse("""
        | 目录 | 内容 |
        |:---|---:|
        | `ios/` | SwiftUI **App** |
        | a |  |
        """)
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = try XCTUnwrap(blocks.first).kind else { return XCTFail("not a table") }
        XCTAssertEqual(table.columns, [.leading, .trailing])
        XCTAssertEqual(table.rows.map { $0.map { String($0.characters) } },
                       [["目录", "内容"], ["ios/", "SwiftUI App"], ["a", ""]])
    }

    func testTableColumnsShareTheWidthByContent() {
        // Room to spare: each column grows with its content.
        XCTAssertEqual(MarkdownTableLayout.share(300, ideal: [50, 100], minimum: 96), [100, 200])
        // Too wide: the short columns keep their width, the long one takes the rest.
        XCTAssertEqual(MarkdownTableLayout.share(370, ideal: [120, 400, 90], minimum: 96), [120, 160, 90])
        // Two long ones split what is left.
        XCTAssertEqual(MarkdownTableLayout.share(300, ideal: [60, 400, 500], minimum: 96), [60, 120, 120])
        // Below the floors the table overruns and scrolls.
        XCTAssertEqual(MarkdownTableLayout.share(0, ideal: [60, 400, 500], minimum: 96), [60, 96, 96])
    }

    func testUnclosedCodeFenceKeepsItsText() {
        let blocks = MarkdownBlock.parse("```\nstill typing")
        XCTAssertEqual(blocks.map(\.kind), [.code(language: nil)])
        XCTAssertEqual(blocks.map(\.text), ["still typing"])
    }

    func testCachedParseMatchesParseForEachText() {
        let first = "# Title\n\n- one\n- two"
        XCTAssertEqual(MarkdownBlock.cachedParse(first), MarkdownBlock.parse(first))
        XCTAssertEqual(MarkdownBlock.cachedParse(first), MarkdownBlock.parse(first))
        // A message still streaming changes its text: each text parses on its own.
        let longer = first + "\n- three"
        XCTAssertEqual(MarkdownBlock.cachedParse(longer).count, 4)
    }
}
