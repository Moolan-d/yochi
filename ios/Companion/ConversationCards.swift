import SwiftUI

/// The rounded card every collapsed conversation row sits on.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(Color.homeCard, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// The chevron of a row that opens.
private struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .accessibilityHidden(true)
    }
}

/// An Edit or Write, collapsed to the file and its counts; tap for the diff.
struct EditRow: View {
    let item: ConversationItem
    let edit: EditInfo
    @State private var expanded = false

    private var diff: ParsedDiff { ParsedDiff(edit.patch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: edit.created ? "doc.badge.plus" : "pencil")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(edit.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 1)
                            .truncationMode(.middle)
                        Text(edit.directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if !edit.created {
                        ChangeCounts(added: edit.added, deleted: edit.deleted)
                    }
                    Chevron(expanded: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(edit.accessibilityLabel)
            .accessibilityValue(expanded ? "Expanded" : "")
            .accessibilityHint("Double-tap to show or hide the changes")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("editRow")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    DiffView(diff: diff)
                    if edit.truncated {
                        Text("The change is too long; only the beginning is shown. The Changes page has the whole file.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityIdentifier("editDiff")
            }
        }
        .modifier(CardBackground())
    }
}

/// A subtask the Agent started: its name and how long it has run.
struct SubtaskRow: View {
    let item: ConversationItem
    let subtask: Subtask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "person.2")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Subtask · \(subtask.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.state == .error ? Color.red : Color.primary)
                    .lineLimit(2)
                if let type = subtask.type, !type.isEmpty {
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if item.state == .running {
                // Only a running one ticks.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    timing(at: context.date)
                }
            } else {
                timing(at: .now)
            }
        }
        .modifier(CardBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("subtaskRow")
    }

    @ViewBuilder
    private func timing(at now: Date) -> some View {
        if let text = subtask.timing(state: item.state, now: now) {
            HStack(spacing: 6) {
                if item.state == .running { ProgressView().controlSize(.mini) }
                Text(text)
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(item.state == .error ? Color.red : Color.secondary)
        }
    }

    /// Read once, not every second: 「子任务 Find items，运行中」.
    private var accessibilityLabel: String {
        let state = switch item.state {
        case .running, nil: subtask.background ? String(localized: "Running in background") : String(localized: "Running")
        case .done: subtask.durationMs.map { String(localized: "Took \(Elapsed.spoken(milliseconds: $0))") } ?? String(localized: "Completed")
        case .error: String(localized: "Failed")
        }
        return String(localized: "Subtask \(subtask.name), \(state)")
    }
}

/// The Agent's to-do list. The newest one is open; earlier ones fold to
/// 「待办 3/7」.
struct TodosRow: View {
    let item: ConversationItem
    let latest: Bool
    /// The reader's own choice; until then the newest list is open.
    @State private var toggled: Bool?

    private var entries: [TodoEntry] { item.todos ?? [] }
    private var done: Int { entries.count { $0.status == .completed } }
    private var expanded: Bool { toggled ?? latest }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { toggled = !expanded }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("To-Dos \(done)/\(entries.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Chevron(expanded: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("To-dos, \(done) of \(entries.count) done")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double-tap to show or hide the list")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("todosRow")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        TodoLine(entry: entry)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .modifier(CardBackground())
    }
}

private struct TodoLine: View {
    let entry: TodoEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(entry.status == .pending ? Color.secondary : Color.accentColor)
            Text(entry.text)
                .strikethrough(entry.status == .completed)
                .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                .fontWeight(entry.status == .inProgress ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.text), \(stateText)")
    }

    private var symbol: String {
        switch entry.status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }

    private var stateText: String {
        switch entry.status {
        case .pending: String(localized: "not started")
        case .inProgress: String(localized: "in progress")
        case .completed: String(localized: "Completed")
        }
    }
}

/// A message to or from another Agent, collapsed to its start; tap for all
/// of it. Never the user's own words.
struct PeerRow: View {
    let item: ConversationItem
    @State private var expanded = false

    private var sent: Bool { item.direction == .sent }
    private var who: String { item.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "another Agent") }
    var heading: String { sent ? String(localized: "To \(who)") : String(localized: "From \(who)") }
    private var text: String { item.text ?? "" }
    /// The Markdown without its marks, for the collapsed line and VoiceOver.
    var plainText: String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: sent ? "paperplane" : "tray.and.arrow.down")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(heading)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !expanded {
                            Text(plainText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if item.state == .error {
                            Text("Not delivered")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 0)
                    if item.state == .running {
                        ProgressView().controlSize(.small)
                    }
                    Chevron(expanded: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(heading)\(item.state == .error ? String(localized: ", not delivered") : ""): \(plainText)")
            .accessibilityHint("Double-tap to show or hide the full text")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("peerRow")

            if expanded {
                MarkdownText(text: text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
            }
        }
        .modifier(CardBackground())
    }
}

/// 「正在：修复水印（3/7）」 above the composer.
struct TodoProgressLine: View {
    let progress: TodoProgress

    var body: some View {
        Label {
            Text(progress.text)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(Color.accentColor)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.accessibilityLabel)
        .accessibilityIdentifier("todoProgress")
    }
}
