import Foundation
import Testing

@testable import Yochi

@MainActor
@Suite("Dialog runner")
struct DialogRunnerTests {
    /// The trust capture with the pointer on `Yes`, as after one ↓.
    private func trustOnYes() throws -> String {
        let text = try ScreenFixture.text("claude-00-trust")
        let moved = text
            .replacingOccurrences(of: "\u{1B}[38;2;177;185;249m❯ No, exit", with: "  No, exit")
            .replacingOccurrences(of: "   Yes, I trust this folder", with: " \u{1B}[38;2;177;185;249m❯ Yes, I trust this folder\u{1B}[0m")
        try #require(moved != text)
        return moved
    }

    /// Runs `action` on the dialog `stem` shows; each key press shows the
    /// next of `screens`.
    private func run(
        _ action: DialogAction, on stem: String, screens: [String]
    ) async throws -> (DialogRunner.Outcome, [[String]]) {
        let feed = ScreenFeed()
        feed.apply(screenText: try ScreenFixture.text(stem))
        let dialog = try #require(feed.result.dialog)
        let plan = try DialogActionPlanner.plan(action, for: dialog)
        var pressed: [[String]] = []
        var next = screens[...]
        let runner = DialogRunner(
            session: "t1", feed: feed,
            press: { keys in
                pressed.append(keys)
                if let screen = next.popFirst() { feed.apply(screenText: screen) }
                return .pressed
            },
            agentWorking: { false }, timeout: .milliseconds(300))
        return (await runner.run(plan, on: dialog), pressed)
    }

    @Test("Trust: ↓, the focus checked on a fresh screen, then Enter")
    func trust() async throws {
        let (outcome, pressed) = try await run(
            .choose(ordinal: 2), on: "claude-00-trust",
            screens: [try trustOnYes(), try ScreenFixture.text("claude-01-ready")])
        #expect(outcome == .done)
        #expect(pressed == [["down"], ["enter"]])
    }

    @Test("A key that brings another dialog stops the plan before Enter")
    func changedDialogStops() async throws {
        let (outcome, pressed) = try await run(
            .choose(ordinal: 2), on: "claude-00-trust",
            screens: [try ScreenFixture.text("claude-02-c1-bash-blocked")])
        #expect(outcome == .failed("终端画面和预期不一致，已停止按键，请在电脑上查看"))
        #expect(pressed == [["down"]])
    }

    @Test("A digit answers; a dialog still there is unconfirmed")
    func digit() async throws {
        let (done, pressed) = try await run(
            .choose(ordinal: 1), on: "claude-02-c1-bash-blocked",
            screens: [try ScreenFixture.text("claude-29-c3-after-immediate")])
        #expect(done == .done)
        #expect(pressed == [["1"]])
        let (unconfirmed, _) = try await run(
            .choose(ordinal: 1), on: "claude-02-c1-bash-blocked",
            screens: [try ScreenFixture.text("claude-03-c1-focus-no")])
        #expect(unconfirmed == .unconfirmed)
    }

    @Test("A plan that types text stays in the terminal")
    func pasteRefused() async throws {
        let (outcome, pressed) = try await run(
            .amend(ordinal: 4, note: "no"), on: "claude-02-c1-bash-blocked", screens: [])
        #expect(outcome == .failed("这个回答要输入文字，请在电脑上完成"))
        #expect(pressed.isEmpty)
    }
}
