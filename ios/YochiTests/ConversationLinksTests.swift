import SwiftUI
import XCTest
@testable import Yochi

final class ConversationLinksTests: XCTestCase {
    private let changed = ["ios/Yochi/Foo.swift", "Foo.swift", "docs/a.md"]

    private func linked(_ text: String, changed: [String]? = nil) -> [String: String] {
        let result = ConversationLinks.linkify(AttributedString(text), changed: changed ?? self.changed)
        var out: [String: String] = [:]
        for run in result.runs {
            if let link = run.link { out[String(result[run.range].characters)] = link.absoluteString }
        }
        return out
    }

    func testMentionsMatchByPathSuffix() {
        XCTAssertEqual(ConversationLinks.changedPath(matching: "/Users/me/app/ios/Yochi/Foo.swift", in: changed), "ios/Yochi/Foo.swift")
        XCTAssertEqual(ConversationLinks.changedPath(matching: "ios/Yochi/Foo.swift", in: changed), "ios/Yochi/Foo.swift")
        XCTAssertEqual(ConversationLinks.changedPath(matching: "./Foo.swift", in: changed), "Foo.swift")
        XCTAssertNil(ConversationLinks.changedPath(matching: "/x/BarFoo.swift", in: changed), "not inside a longer name")
        XCTAssertNil(ConversationLinks.changedPath(matching: "/x/other.swift", in: changed))
    }

    func testAChangedPathBecomesALinkWithItsAbsolutePrefix() throws {
        let links = linked("Edited /Users/me/app/docs/a.md just now")
        XCTAssertEqual(links.keys.sorted(), ["/Users/me/app/docs/a.md"])
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(links.values.first)))
        XCTAssertEqual(ConversationLinks.changedPath(from: url), "docs/a.md")
    }

    func testLineNumbersAndSentenceEndsStayOutsideTheLink() {
        XCTAssertEqual(linked("see docs/a.md:42 and docs/a.md.").keys.sorted(), ["docs/a.md"].sorted())
        XCTAssertEqual(ConversationLinks.pathRanges(in: "see docs/a.md:42 and docs/a.md.", changed: changed).count, 2)
    }

    func testNamesContainingAPathAreLeftAlone() {
        XCTAssertTrue(linked("see mydocs/a.md and docs/a.mdx").isEmpty)
        XCTAssertTrue(linked("docs/a.md", changed: []).isEmpty)
    }

    func testTheLongestPathWins() {
        let links = linked("ios/Yochi/Foo.swift")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(ConversationLinks.changedPath(from: URL(string: links.values.first!)!), "ios/Yochi/Foo.swift")
    }

    func testBareWebAddressesBecomeLinksWithoutTrailingPunctuation() {
        XCTAssertEqual(linked("Open https://example.com/a?b=1, then (https://swift.org).", changed: []),
                       ["https://example.com/a?b=1": "https://example.com/a?b=1", "https://swift.org": "https://swift.org"])
        XCTAssertTrue(linked("just https:// alone", changed: []).isEmpty)
    }

    func testOnlyWebAndChangeLinksAreFollowed() {
        XCTAssertTrue(ConversationLinks.isWeb(URL(string: "https://a.b")!))
        XCTAssertTrue(ConversationLinks.isWeb(URL(string: "http://a.b")!))
        XCTAssertFalse(ConversationLinks.isWeb(URL(string: "tel:123")!))
        XCTAssertFalse(ConversationLinks.isWeb(URL(string: "file:///etc/hosts")!))
    }

    func testAMarkdownLinkKeepsItsOwnTarget() throws {
        var text = AttributedString("docs/a.md")
        text.link = URL(string: "https://example.com")
        let result = ConversationLinks.linkify(text, changed: changed)
        XCTAssertEqual(result.runs.first?.link, URL(string: "https://example.com"))
    }
}
