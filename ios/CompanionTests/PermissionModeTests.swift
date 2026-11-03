import Testing

@testable import Companion

/// The mode line under Claude Code's prompt, and switching by pressing
/// Shift+Tab one step at a time.
@MainActor
struct PermissionModeTests {
    @Test("The mode line of each capture reads as its mode", arguments: [
        ("claude-01-ready", PermissionMode.default), ("claude-15-c9-enterplanmode", .plan),
        ("claude-21-c6-after", .auto), ("claude-46-accept-edits", .acceptEdits),
    ])
    func readsCaptures(stem: String, mode: PermissionMode) throws {
        #expect(PermissionMode.read(try ScreenFixture.screen(stem)) == mode)
    }

    @Test("A dialog hides the mode line")
    func dialogHidesIt() throws {
        #expect(PermissionMode.read(try ScreenFixture.screen("claude-43-c12-read-file")) == nil)
    }

    @Test("A mode named higher up in the conversation doesn't count (synthetic)")
    func onlyTheFooterCounts() {
        let screen = ScreenFixture.synthetic(["  ⏸ plan mode on", "⏺ Done.", "", "❯ ", "  status", "  tokens"])
        #expect(PermissionMode.read(screen) == nil)
    }

    @Test("Auto is offered only where the session has shown it, bypassing never")
    func targets() {
        #expect(PermissionMode.targets(including: []) == [.default, .acceptEdits, .plan])
        #expect(PermissionMode.targets(including: [.auto, .bypassPermissions]) == [.default, .acceptEdits, .plan, .auto])
    }

    private static func footer(_ mode: PermissionMode) -> String {
        switch mode {
        case .default: "  ⏸ manual mode on"
        case .acceptEdits: "  ⏵⏵ accept edits on (shift+tab to cycle)"
        case .plan: "  ⏸ plan mode on (shift+tab to cycle)"
        case .auto: "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        case .bypassPermissions: "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
        }
    }

    /// A terminal whose Shift+Tab steps through `cycle`; `stuck` leaves the
    /// screen as it was, as when a dialog took the key.
    @MainActor private final class FakeTerminal {
        let feed = ScreenFeed()
        let cycle: [PermissionMode]
        var index = 0
        var presses = 0
        var stuck = false

        init(_ cycle: [PermissionMode]) {
            self.cycle = cycle
            show()
        }

        func show() {
            feed.apply(screenText: ["⏺ Done.", "", "❯ ", PermissionModeTests.footer(cycle[index])].joined(separator: "\r\n"))
        }

        func press(_ keys: [String]) -> GatewayClient.KeysResult {
            #expect(keys == ["shift+tab"])
            presses += 1
            if !stuck { index = (index + 1) % cycle.count }
            show()
            return .pressed
        }
    }

    private func switcher(_ terminal: FakeTerminal, working: @escaping () -> Bool = { false }) -> PermissionModeSwitcher {
        var switcher = PermissionModeSwitcher(feed: terminal.feed, press: { terminal.press($0) }, agentWorking: working)
        switcher.timeout = .milliseconds(200)
        return switcher
    }

    @Test("Switching presses Shift+Tab until the screen shows the target")
    func switches() async {
        let terminal = FakeTerminal([.auto, .default, .acceptEdits, .plan])
        #expect(await switcher(terminal).run(to: .plan) == .done)
        #expect(terminal.presses == 3)
        #expect(await switcher(terminal).run(to: .plan) == .done)
        #expect(terminal.presses == 3)
    }

    @Test("A press the screen doesn't answer stops the switch")
    func stopsWhenTheScreenStays() async {
        let terminal = FakeTerminal([.default, .acceptEdits, .plan])
        terminal.stuck = true
        #expect(await switcher(terminal).run(to: .plan) == .failed("终端画面和预期不一致，已停止切换，请在电脑上查看"))
        #expect(terminal.presses == 1)
    }

    @Test("A mode outside the cycle fails after a bounded number of presses")
    func missingTarget() async {
        let terminal = FakeTerminal([.default, .acceptEdits, .plan])
        #expect(await switcher(terminal).run(to: .auto) == .failed("没有切到「自动」，请在电脑上查看"))
        #expect(terminal.presses == 5)
    }

    @Test("Switching stops once the Agent starts working")
    func stopsWhenWorking() async {
        let terminal = FakeTerminal([.default, .acceptEdits, .plan])
        var working = false
        let result = await switcher(terminal, working: {
            defer { working = true }
            return working
        }).run(to: .plan)
        #expect(result == .failed("Agent 开始工作了，已停止切换"))
        #expect(terminal.presses == 1)
    }
}
