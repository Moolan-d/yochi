import Foundation
import Testing

@testable import Yochi

/// The `/model` capture: rows 6 to 15 of 23 shown, focus on 15, the model
/// in use.
@Suite("Claude picker")
struct ClaudePickerTests {
    private static let stem = "claude-44-model-picker"

    private func picker(_ text: String? = nil) throws -> BlockedDialog {
        let screen = try text.map(ANSIScreenDecoder.decode) ?? ScreenFixture.screen(Self.stem)
        let result = ClaudeDialogParser.parse(screen)
        return try #require(result.dialog, "parsed as \(result)")
    }

    /// The capture with focus on `number` instead of 15, as the arrows
    /// leave it without scrolling.
    private func focused(on number: Int) throws -> String {
        let text = try ScreenFixture.text(Self.stem)
        let pointer = "\u{1B}[0;38;2;177;185;249m❯ "
        let moved = text.replacingOccurrences(of: pointer, with: "  ")
            .replacingOccurrences(of: "     \u{1B}[0;38;2;153;153;153m\(number). ", with: "   \(pointer)\u{1B}[0;38;2;153;153;153m\(number). ")
        try #require(moved != text)
        return moved
    }

    @Test("The list as shown: numbers, labels, details, focus and the model in use")
    func modelPicker() throws {
        let dialog = try picker()
        #expect(dialog.kind == .claudePicker)
        #expect(dialog.title == "Select model")
        #expect(dialog.body.first?.hasPrefix("Switch between Claude models.") == true)
        #expect(dialog.body.last == "● High effort (default) ←/→ to adjust")
        #expect(dialog.options.map(\.number) == Array(6...15).map(Optional.some))
        #expect(dialog.options.first?.label == "Semantic Routing")
        #expect(dialog.options.first?.detail == "routing group · via router")
        #expect(dialog.options[1].label == "Claude Opus 5.5 · routing group")
        #expect(dialog.options[1].detail == "via router")
        let current = try #require(dialog.options.last)
        #expect(current.label == "DeepSeek V4.1 Flash")
        #expect(current.isFocused && current.isChecked == true)
        #expect(dialog.options.dropLast().allSatisfy { !$0.isFocused && $0.isChecked == nil })

        let picker = try #require(dialog.picker)
        #expect(picker.hiddenAbove == 5)
        #expect(picker.hiddenBelow == 8)
        #expect(picker.moreBelow)
        #expect(picker.enterAction == "set as default")
        #expect(picker.keys == [DialogKeyHint(key: "s", action: "use this session only")])
    }

    @Test("Moving focus keeps the fingerprint")
    func fingerprintIgnoresFocus() throws {
        let moved = try picker(try focused(on: 9))
        #expect(moved.fingerprint == (try picker()).fingerprint)
        #expect(moved.options.first(where: \.isFocused)?.number == 9)
    }

    @Test("A row: arrows up a batch at a time, each checked by number, then Enter or s")
    func pick() throws {
        let dialog = try picker()
        let toNine = try DialogActionPlanner.plan(.choose(ordinal: 4), for: dialog)
        #expect(toNine.steps == [
            .keys(Array(repeating: "up", count: 6)), .expect(.focusNumber(9)), .keys(["enter"]),
        ])
        #expect(toNine.confirmation == .fingerprintChange)
        let toSix = try DialogActionPlanner.plan(.pick(ordinal: 1, key: "s"), for: dialog)
        #expect(toSix.steps == [
            .keys(Array(repeating: "up", count: 8)), .expect(.focusNumber(7)),
            .keys(["up"]), .expect(.focusNumber(6)), .keys(["s"]),
        ])
        let here = try DialogActionPlanner.plan(.choose(ordinal: 10), for: dialog)
        #expect(here.steps == [.keys(["enter"])])
        #expect(throws: DialogPlanError.self) { try DialogActionPlanner.plan(.pick(ordinal: 1, key: "x"), for: dialog) }
        #expect(throws: DialogPlanError.self) {
            try DialogActionPlanner.plan(.respond(ordinal: 1, text: "x"), for: dialog)
        }
        #expect(try DialogActionPlanner.plan(.dismiss, for: dialog).keys == ["esc"])
    }

    @Test("Scrolling moves focus a page past the rows shown, or as far as the list goes")
    func scroll() throws {
        let dialog = try picker()
        let down = try DialogActionPlanner.plan(.scroll(forward: true), for: dialog)
        #expect(down.steps == [.keys(Array(repeating: "down", count: 8)), .expect(.focusNumber(23))])
        #expect(down.confirmation == .steps)
        let up = try DialogActionPlanner.plan(.scroll(forward: false), for: dialog)
        #expect(up.steps == [
            .keys(Array(repeating: "up", count: 8)), .expect(.focusNumber(7)),
            .keys(Array(repeating: "up", count: 6)), .expect(.focusNumber(1)),
        ])
    }

    @Test("Focus on another number meets the check wherever the list scrolled")
    func focusNumberCheck() throws {
        let dialog = try picker()
        let observation = DialogObservation(screen: ANSIScreenDecoder.decode(try focused(on: 9)), program: .claude)
        #expect(DialogExpectation.focusNumber(9).isMet(by: observation, fingerprint: dialog.fingerprint))
        #expect(!DialogExpectation.focusNumber(10).isMet(by: observation, fingerprint: dialog.fingerprint))
    }

    @Test("The permission dialogs never read as pickers", arguments: ScreenFixture.all.filter { $0 != "claude-44-model-picker" })
    func notAPicker(stem: String) throws {
        let result = ClaudeDialogParser.parse(try ScreenFixture.screen(stem))
        #expect(result.dialog?.kind != .claudePicker)
    }
}
