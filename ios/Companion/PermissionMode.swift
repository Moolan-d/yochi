import Foundation

/// Claude Code's permission mode, as its transcript names it (ADR 0005).
enum PermissionMode: String, CaseIterable, Sendable {
    case `default`
    case acceptEdits
    case plan
    case auto
    case bypassPermissions

    var title: String {
        switch self {
        case .default: "普通"
        case .acceptEdits: "自动接受编辑"
        case .plan: "计划"
        case .auto: "自动"
        case .bypassPermissions: "跳过所有权限"
        }
    }

    var symbol: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "pencil"
        case .plan: "list.bullet.clipboard"
        case .auto: "wand.and.stars"
        case .bypassPermissions: "exclamationmark.shield"
        }
    }

    /// What the phone offers to switch to: never bypassing every permission,
    /// and auto only where this session has it (it isn't always in the cycle).
    static func targets(including seen: Set<PermissionMode>) -> [PermissionMode] {
        [.default, .acceptEdits, .plan] + (seen.contains(.auto) ? [.auto] : [])
    }

    /// The mode line under Claude Code's prompt, e.g. `⏵⏵ accept edits on
    /// (shift+tab to cycle)` or `⏸ manual mode on · ← 1 agent` (2.1.317). Only
    /// the last few rows count, so a mode named in the conversation doesn't.
    static func read(_ screen: ANSIScreen) -> PermissionMode? {
        let rows = screen.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for row in rows.suffix(3).reversed() {
            guard row.hasPrefix("⏵⏵ ") || row.hasPrefix("⏸ ") else { continue }
            let phrase = row.drop { $0 != " " }.dropFirst()
            for (words, mode) in screenNames where phrase.hasPrefix(words + " on") {
                return mode
            }
        }
        return nil
    }

    private static let screenNames: [(String, PermissionMode)] = [
        ("manual mode", .default), ("accept edits", .acceptEdits), ("plan mode", .plan),
        ("auto mode", .auto), ("bypass permissions", .bypassPermissions),
    ]
}

/// Switches the mode the way a person would: one Shift+Tab at a time, each
/// confirmed by the mode line on a fresh screen before the next. Passing
/// through bypass-permissions on the way is harmless while the Agent idles.
@MainActor
struct PermissionModeSwitcher {
    enum Outcome: Equatable {
        case done
        case failed(String)
    }

    let feed: ScreenFeed
    let press: ([String]) async -> GatewayClient.KeysResult
    let agentWorking: () -> Bool
    /// Core presses once the terminal has been still for about 3 seconds.
    var timeout = Duration.seconds(10)
    /// More than any cycle has modes; reaching it means the target isn't in it.
    var maxPresses = 5

    func run(to target: PermissionMode) async -> Outcome {
        guard let screen = feed.screen, var current = PermissionMode.read(screen) else {
            return .failed("终端里看不到当前模式，请在电脑上切换")
        }
        for _ in 0..<maxPresses {
            if current == target { return .done }
            guard !agentWorking() else { return .failed("Agent 开始工作了，已停止切换") }
            let since = feed.revision
            switch await press(["shift+tab"]) {
            case .pressed: break
            case .failed(let kind, let message):
                return .failed(kind == "not_found" || kind == "finished" ? "会话已结束" : message)
            case .unknown: return .failed("按键结果未知，请在电脑上确认当前模式")
            }
            guard let next = await nextMode(since: since, after: current) else {
                return .failed("终端画面和预期不一致，已停止切换，请在电脑上查看")
            }
            current = next
        }
        return current == target ? .done : .failed("没有切到「\(target.title)」，请在电脑上查看")
    }

    /// The mode on the first fresh screen that shows a different one.
    private func nextMode(since start: Int, after current: PermissionMode) async -> PermissionMode? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if feed.revision != start, let screen = feed.screen,
               let mode = PermissionMode.read(screen), mode != current {
                return mode
            }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return nil }
        }
        return nil
    }
}
