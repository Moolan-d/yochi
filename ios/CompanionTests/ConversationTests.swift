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
        > quoted
        ```swift
        let x = 1

        print(x)
        ```
        Tail
        """)
        XCTAssertEqual(blocks, [
            .heading("Plan"),
            .paragraph("First **line**\ncontinues here."),
            .paragraph("• one\n  • nested"),
            .quote("quoted"),
            .code("let x = 1\n\nprint(x)"),
            .paragraph("Tail"),
        ])
    }

    func testUnclosedCodeFenceKeepsItsText() {
        XCTAssertEqual(MarkdownBlock.parse("```\nstill typing"), [.code("still typing")])
    }
}
