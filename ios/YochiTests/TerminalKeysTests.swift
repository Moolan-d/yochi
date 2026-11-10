import GhosttyTerminal
import XCTest
@testable import Yochi

final class TerminalKeysTests: XCTestCase {
    func testKeysRepliesDecode() throws {
        let sent = Data(#"{"type":"keys_sent","id":"k1"}"#.utf8)
        guard case .keysSent(let id) = try JSONDecoder().decode(ServerMessage.self, from: sent) else {
            return XCTFail("not keys_sent")
        }
        XCTAssertEqual(id, "k1")
        let failed = Data(#"{"type":"keys_failed","id":"k2","kind":"finished","message":"finished"}"#.utf8)
        guard case .keysFailed(let id, let kind, _) = try JSONDecoder().decode(ServerMessage.self, from: failed) else {
            return XCTFail("not keys_failed")
        }
        XCTAssertEqual(id, "k2")
        XCTAssertEqual(kind, "finished")
    }

    func testQuickCommandFillsTheDraft() {
        XCTAssertEqual(QuickCommand.insert("/compact", into: ""), "/compact")
        XCTAssertEqual(QuickCommand.insert("继续", into: "看完日志"), "看完日志 继续")
        XCTAssertEqual(QuickCommand.insert("继续", into: "第一行\n"), "第一行\n继续")
    }

    func testKeyBarUsesCoreKeyNames() {
        XCTAssertEqual(TerminalKey.bar.map(\.id), ["ctrl+c", "tab", "up", "down", "enter", "esc"])
    }

    /// The typing bar's three pages, what each key sends, and the core key
    /// names it falls back on.
    func testTypingBarPagesAndKeys() {
        XCTAssertEqual(TypingKey.pages.map { $0.map(\.id) }, [
            ["esc", "ctrl", "alt", "tab", "shift+tab", "arrows", "ctrl+c"],
            ["ctrl+d", "ctrl+z", "ctrl+l", "pipe", "tilde", "slash", "minus"],
            ["home", "end", "pageup", "pagedown"],
        ])
        let keys = Dictionary(uniqueKeysWithValues: (TypingKey.pages.flatMap { $0 }
            + [TypingKey.up, TypingKey.left, TypingKey.down, TypingKey.right]).map { ($0.id, $0.action) })
        XCTAssertEqual(keys["ctrl"], .sticky(.ctrl))
        XCTAssertEqual(keys["alt"], .sticky(.alt))
        XCTAssertEqual(keys["arrows"], .arrows)
        XCTAssertEqual(keys["shift+tab"], .press(TerminalKeyPress(.tab, modifiers: .shift)))
        XCTAssertEqual(keys["ctrl+c"], .press(TerminalKeyPress(.c, modifiers: .ctrl)))
        XCTAssertEqual(keys["ctrl+l"], .press(TerminalKeyPress(.l, modifiers: .ctrl)))
        XCTAssertEqual(keys["left"], .press(TerminalKeyPress(.arrowLeft)))
        XCTAssertEqual(keys["pagedown"], .press(TerminalKeyPress(.pageDown)))
        for (id, character) in [("pipe", "|"), ("tilde", "~"), ("slash", "/"), ("minus", "-")] as [(String, Character)] {
            XCTAssertEqual(keys[id], .press(TerminalKeyPress(typing: character)!), id)
        }
        let fallbacks = Set(TypingKey.pages.flatMap { $0 }.compactMap(\.fallbackName)
            + [TypingKey.up, TypingKey.down].compactMap(\.fallbackName))
        XCTAssertEqual(fallbacks, ["esc", "tab", "shift+tab", "ctrl+c", "up", "down"])
    }
}
