import SwiftUI

/// The session's Changes, read-only: what its repository has against HEAD.
/// Refreshes on open, on pull, and whenever the Agent ends a turn.
struct ChangesView: View {
    let session: String
    let client: GatewayClient
    /// Claude Code sessions can ask the Agent to commit; nil hides the button.
    let askToCommit: (() -> Void)?

    private enum Load: Equatable {
        case loading
        case loaded(ChangeList)
        case failed(ChangesError)
    }

    @State private var load = Load.loading

    private var turn: UInt64? { client.sessions.first { $0.id == session }?.turn }

        var body: some View {
List {
                Group {
                if case .loaded(let list) = load, !list.files.isEmpty {
                    Section {
                        ForEach(list.files) { file in
                            NavigationLink {
                                ChangeDiffView(session: session, file: file, client: client)
                            } label: {
                                FileChangeRow(file: file)
                            }
                            .accessibilityIdentifier("change-\(file.path)")
                        }
                    } header: {
                        summary(list)
                    } footer: {
                        Text(list.truncated ? "Showing the first \(list.files.count) files. Read-only on the phone: nothing can be staged or committed." : "Read-only on the phone: nothing can be staged or committed.")
                    }
                    if let askToCommit {
                        Section {
                            Button("Ask Agent to Commit", systemImage: "checkmark.seal") { askToCommit() }
                                .accessibilityIdentifier("askToCommit")
                        } footer: {
                            Text("Puts “\(Self.commitRequest)” in the message field. You send it from the conversation.")
                        }
                    }
                }
            }
            .homeRow()
        }
        .homeListStyle()
        .overlay { placeholder }
        .navigationTitle("Changes")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: turn) { _, _ in Task { await refresh() } }
    }

    static let commitRequest = String(localized: "Please commit these changes")

    private func summary(_ list: ChangeList) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(list.repo) · against HEAD")
                .font(.headline)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text("\(list.files.count) files")
                Text("+\(list.added)").foregroundStyle(.green)
                Text("−\(list.deleted)").foregroundStyle(.red)
            }
            .font(.subheadline.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Files: \(list.files.count), lines added: \(list.added), lines deleted: \(list.deleted)")
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var placeholder: some View {
        switch load {
        case .loading:
            ProgressView("Loading changes…")
        case .loaded(let list) where list.files.isEmpty:
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                   description: Text("\(list.repo) matches HEAD, with no untracked files."))
        case .failed(let error) where error.kind == "not_git":
            ContentUnavailableView("Not a Git Repository", systemImage: "folder.badge.questionmark",
                                   description: Text("This session's directory isn't in a Git repository."))
        case .failed(let error):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Retry") { Task { await refresh() } }
                    .buttonStyle(.bordered)
            }
        case .loaded:
            EmptyView()
        }
    }

    private func refresh() async {
        switch await client.changes(session: session) {
        case .success(let list): load = .loaded(list)
        case .failure(let error): load = .failed(error)
        }
    }
}

private struct FileChangeRow: View {
    let file: FileChange

    var body: some View {
        HStack(spacing: 12) {
            StatusMark(status: file.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            ChangeCounts(added: file.added, deleted: file.deleted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.accessibilityLabel)
        .accessibilityHint("Shows this file's changes")
    }
}

/// +a −d, or 「二进制」.
struct ChangeCounts: View {
    let added: Int?
    let deleted: Int?

    var body: some View {
        Group {
            if added == nil && deleted == nil {
                Text("Binary").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("+\(added ?? 0)").foregroundStyle(.green)
                    Text("−\(deleted ?? 0)").foregroundStyle(.red)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }
}

/// The status as a letter on a tint, so it never rests on colour alone.
private struct StatusMark: View {
    let status: FileChange.Status
    @ScaledMetric(relativeTo: .caption) private var size = 22

    var body: some View {
        Text(status.rawValue)
            .font(.caption.weight(.bold).monospaced())
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch status {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .typeChanged: .purple
        case .unmerged: .pink
        case .untracked: .gray
        }
    }
}

/// One file's change, as hunks.
struct ChangeDiffView: View {
    let session: String
    let file: FileChange
    let client: GatewayClient

    private enum Load: Equatable {
        case loading
        case loaded(ParsedDiff, truncated: Bool)
        case failed(ChangesError)
    }

    @State private var load = Load.loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView("Loading…")
            case .failed(let error):
                ContentUnavailableView {
                    Label(error.kind == "changed" ? "The File List Changed" : "Couldn't Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.kind == "changed" ? String(localized: "Go back to Changes to refresh it, then open this again.") : error.message)
                } actions: {
                    if error.kind != "changed" {
                        Button("Retry") { Task { await refresh() } }
                            .buttonStyle(.bordered)
                    }
                }
            case .loaded(let diff, _) where diff.binary:
                ContentUnavailableView("binary file", systemImage: "doc",
                                       description: Text("Changes to binary files can't be shown."))
            case .loaded(let diff, _) where diff.hunks.isEmpty:
                ContentUnavailableView("No Text Changes", systemImage: "doc.text",
                                       description: Text(file.status == .renamed ? "Only renamed." : "The content didn't change. Maybe only its permissions did."))
            case .loaded(let diff, let truncated):
                ScrollView {
                    DiffView(diff: diff)
                    if truncated {
                        Text("The change is too long; only the beginning is shown.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(file.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(file.directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        ChangeCounts(added: file.added, deleted: file.deleted)
                    }
                    .font(.caption)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(file.accessibilityLabel), in \(file.directory)")
                .accessibilityAddTraits(.isHeader)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        switch await client.changeDiff(session: session, path: file.path) {
        case .success(let diff): load = .loaded(ParsedDiff(diff.patch), truncated: diff.truncated)
        case .failure(let error): load = .failed(error)
        }
    }
}

/// Hunks with line numbers, added and deleted lines on tints with a sign.
/// Also used for an edit's diff in the conversation.
struct DiffView: View {
    let diff: ParsedDiff
    @ScaledMetric(relativeTo: .footnote) private var digitWidth = 8

    private var numberWidth: CGFloat {
        let largest = diff.hunks.flatMap(\.lines).map(\.number).max() ?? 1
        return CGFloat(max(String(largest).count, 2)) * digitWidth + 4
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(diff.hunks) { hunk in
                HStack(spacing: 6) {
                    Text("@@ line \(hunk.line)").fontWeight(.semibold).fixedSize()
                    Text(hunk.context).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Changes from line \(hunk.line)")
                .accessibilityAddTraits(.isHeader)
                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line, numberWidth: numberWidth)
                }
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: ParsedDiff.Line
    let numberWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Never wrapped; wider than the estimate at the largest text sizes.
            Text(String(line.number))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: numberWidth, alignment: .trailing)
            Text(sign)
                .foregroundStyle(signColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(line.text.replacingOccurrences(of: "\t", with: "    "))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if line.noNewline {
                    Text("No newline at end of file").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
    }

    private var sign: String {
        switch line.kind {
        case .context: " "
        case .added: "+"
        case .deleted: "−"
        }
    }

    private var signColor: Color {
        switch line.kind {
        case .context: .secondary
        case .added: .green
        case .deleted: .red
        }
    }

    private var background: Color {
        switch line.kind {
        case .context: .clear
        case .added: .green.opacity(0.14)
        case .deleted: .red.opacity(0.14)
        }
    }
}
