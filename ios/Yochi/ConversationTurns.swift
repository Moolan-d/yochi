import SwiftUI

/// What the conversation page lists: an item, or the steps of a finished
/// turn folded into one line.
enum ConversationEntry: Identifiable, Equatable {
    case item(ConversationItem)
    /// The tool calls and interim messages between a user message and the
    /// Agent's final reply. Its id is the first step's.
    case folded(id: String, steps: [ConversationItem])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .folded(let id, _): "fold-" + id
        }
    }
}

enum ConversationTurns {
    /// Folds each finished turn's middle: from the user message that opens a
    /// turn to the Agent's last reply in it, the steps between collapse into
    /// one entry. The user's messages, the final replies and notices stay in
    /// view, and so does the last turn while the Agent is still in it
    /// (`inProgress`) or when it has no reply yet.
    ///
    /// The Gateway sends no time for an item, so a fold knows its step count
    /// only.
    static func entries(_ items: [ConversationItem], inProgress: Bool) -> [ConversationEntry] {
        // Turns start at user messages; items before the first belong to one.
        var starts = items.indices.filter { items[$0].kind == .user }
        if starts.first != 0 { starts.insert(0, at: 0) }
        var entries: [ConversationEntry] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : items.count
            let turn = Array(items[start..<end])
            if inProgress && n == starts.count - 1 {
                entries += turn.map(ConversationEntry.item)
            } else {
                entries += fold(turn)
            }
        }
        return entries
    }

    private static func fold(_ turn: [ConversationItem]) -> [ConversationEntry] {
        guard let final = turn.lastIndex(where: { $0.kind == .agent && !($0.text ?? "").isEmpty }) else {
            return turn.map(ConversationEntry.item)
        }
        var entries: [ConversationEntry] = []
        var steps: [ConversationItem] = []
        func flush() {
            if !steps.isEmpty { entries.append(.folded(id: steps[0].id, steps: steps)) }
            steps = []
        }
        for (index, item) in turn.enumerated() {
            let foldable = index < final && item.kind != .user && item.kind != .notice
            if foldable {
                steps.append(item)
            } else {
                flush()
                entries.append(.item(item))
            }
        }
        flush()
        return entries
    }
}

/// 「Worked · 12 steps」; tap to show them.
struct FoldedSteps: View {
    let steps: [ConversationItem]
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text("Worked · \(steps.count) steps")
                    .font(.footnote.weight(.medium))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Double-tap to hide the steps" : "Double-tap to show the steps")
        .accessibilityIdentifier("foldedSteps")
    }
}
