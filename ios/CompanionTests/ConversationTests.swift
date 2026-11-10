import SwiftUI
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

    /// A notice the app knows is worded by the app; others show the Gateway's text.
    func testNoticesWithACodeAreWordedByTheApp() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"""
        {"type":"conversation","supported":true,"items":[
          {"kind":"notice","id":"n1","text":"已中断","code":"interrupted"},
          {"kind":"notice","id":"n2","text":"Context compacted","code":"compacted"},
          {"kind":"notice","id":"n3","text":"Something new","code":"later"},
          {"kind":"notice","id":"n4","text":"Old Gateway"}
        ]}
        """#))
        XCTAssertEqual(feed.items.map(\.noticeText), [
            String(localized: "Interrupted"), String(localized: "Context compacted"), "Something new", "Old Gateway",
        ])
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

    /// An Agent by what runs; its page by whether Claude Code runs in it.
    func testAgentAndPageForm() throws {
        func session(program: String?, command: String?, state: String? = nil) throws -> Session {
            var json: [String: Any] = ["id": "t1", "title": "x", "cwd": "/"]
            json["program"] = program
            json["command"] = command
            json["status"] = state.map { ["state": $0] }
            return try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let started = try session(program: "claude", command: "claude", state: "idle")
        XCTAssertTrue(started.isAgent)
        XCTAssertTrue(started.showsConversation, "a terminal started as Claude Code is its conversation")
        let typed = try session(program: "claude", command: "zsh", state: "working")
        XCTAssertTrue(typed.isAgent)
        XCTAssertTrue(typed.showsConversation, "Claude Code typed into a shell is its conversation too")
        let unreported = try session(program: "codex", command: nil)
        XCTAssertTrue(unreported.isAgent, "a known Agent CLI before (or without) a status")
        XCTAssertFalse(unreported.showsConversation)
        let pi = try session(program: "pi", command: "pi", state: "done")
        XCTAssertTrue(pi.isAgent)
        XCTAssertFalse(pi.showsConversation, "only Claude Code has a conversation page")
        let shell = try session(program: "zsh", command: nil)
        XCTAssertFalse(shell.isAgent)
        XCTAssertFalse(shell.showsConversation)
        let server = try session(program: "node", command: "zsh")
        XCTAssertFalse(server.isAgent, "a dev server is a plain terminal")

        XCTAssertEqual(AgentBrand.color(for: started), AgentBrand.claude, "a conversation Agent wears its brand color")
        XCTAssertEqual(AgentBrand.color(for: typed), AgentBrand.claude)
        for plain in [unreported, pi, shell, server] {
            XCTAssertNil(AgentBrand.color(for: plain), "\(plain.program ?? "-") keeps the plain mark")
        }
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

    /// A reply that comes in while following is revealed from what was
    /// there; the whole conversation, sent again, reveals nothing.
    func testLiveRepliesAreRevealedFromWhatWasThere() throws {
        let feed = ConversationFeed()
        feed.apply(try decode(#"{"type":"conversation","supported":true,"items":[{"kind":"agent","id":"a1","text":"old"}]}"#))
        XCTAssertTrue(feed.arrivals.isEmpty)
        feed.apply(try decode(#"{"type":"items","items":[{"kind":"agent","id":"a2","text":"new"},{"kind":"tool","id":"t1","name":"Bash"}]}"#))
        XCTAssertEqual(feed.arrivals.keys.sorted(), ["a2"])
        XCTAssertNil(feed.arrivals["a2"]?.previous)
        feed.apply(try decode(#"{"type":"items","items":[{"kind":"agent","id":"a1","text":"old and more"}]}"#))
        XCTAssertEqual(feed.arrivals["a1"]?.previous, "old")
        feed.apply(try decode(#"{"type":"conversation","supported":true,"items":[{"kind":"agent","id":"a3","text":"x"}]}"#))
        XCTAssertTrue(feed.arrivals.isEmpty)
    }

    /// Part-way through, whole blocks come first and then the start of the
    /// next, with its styles; a table shows whole.
    func testMarkdownRevealsBlockByBlock() throws {
        let blocks = MarkdownBlock.parse("# Title\n\nSome **bold** words\n\n| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(MarkdownBlock.revealLength(of: blocks), 5 + 15 + 1)
        XCTAssertEqual(MarkdownBlock.revealed(blocks, upTo: 3).map(\.text), ["Tit"])
        let part = MarkdownBlock.revealed(blocks, upTo: 5 + 7)
        XCTAssertEqual(part.map(\.text), ["Title", "Some bo"])
        XCTAssertEqual(part[1].content.runs.last?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(MarkdownBlock.revealed(blocks, upTo: 21), blocks)

        let reveal = Reveal(text: "Some **bold** words", arrival: Arrival(previous: "Some", at: .distantPast))
        XCTAssertEqual(reveal.from, 4)
        XCTAssertEqual(reveal.position(at: .distantPast), 4)
        // It runs on past the end until the last character is clear.
        XCTAssertEqual(reveal.position(at: .now), 15 + Reveal.fade)
    }

    /// The newest characters fade in: the one just showing is faint, those
    /// `fade` back are clear, and once past the end nothing is faded.
    func testRevealFadesInItsNewestCharacters() throws {
        let blocks = MarkdownBlock.parse("Title\n\nSome **bold** words")
        func opacities(_ blocks: [MarkdownBlock]) -> [Double] {
            blocks.flatMap { block in
                block.content.runs.flatMap { run in
                    let count = block.content[run.range].characters.count
                    return Array(repeating: run.swiftUI.foregroundColor == nil ? 1.0 : 0.5, count: count)
                }
            }
        }
        let part = MarkdownBlock.revealed(blocks, at: 8.5, fade: 4)
        XCTAssertEqual(part.map(\.text), ["Title", "Some"])
        // The title is clear; the four characters after it are fading in.
        XCTAssertEqual(opacities(part), [1, 1, 1, 1, 1, 0.5, 0.5, 0.5, 0.5])
        // Styles stay with the characters they fade.
        let bold = MarkdownBlock.revealed(blocks, at: 12, fade: 4)[1]
        XCTAssertEqual(bold.text, "Some bo")
        XCTAssertEqual(bold.content.runs.last?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertNotNil(bold.content.runs.last?.swiftUI.foregroundColor)

        XCTAssertEqual(MarkdownBlock.revealed(blocks, at: 21 + 4, fade: 4), blocks)
        XCTAssertEqual(MarkdownBlock.revealed(blocks, at: 12, fade: 0), MarkdownBlock.revealed(blocks, upTo: 12))
    }
}
