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
                    Text(list.truncated ? "只列出前 \(list.files.count) 个文件。手机上只读，不能暂存或提交。" : "手机上只读，不能暂存或提交。")
                }
                if let askToCommit {
                    Section {
                        Button("让 Agent 提交", systemImage: "checkmark.seal") { askToCommit() }
                            .accessibilityIdentifier("askToCommit")
                    } footer: {
                        Text("把「\(Self.commitRequest)」填进输入框，回到对话后由你发出。")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { placeholder }
        .navigationTitle("改动")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: turn) { _, _ in Task { await refresh() } }
    }

    static let commitRequest = "请提交这些改动"

    private func summary(_ list: ChangeList) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(list.repo) · 相对 HEAD")
                .font(.headline)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text("\(list.files.count) 个文件")
                Text("+\(list.added)").foregroundStyle(.green)
                Text("−\(list.deleted)").foregroundStyle(.red)
            }
            .font(.subheadline.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(list.files.count) 个文件，增加 \(list.added) 行，删除 \(list.deleted) 行")
        }
        .textCase(nil)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var placeholder: some View {
        switch load {
        case .loading:
            ProgressView("正在读取改动…")
        case .loaded(let list) where list.files.isEmpty:
            ContentUnavailableView("没有改动", systemImage: "checkmark.circle",
                                   description: Text("\(list.repo) 和 HEAD 一致，也没有未跟踪的文件。"))
        case .failed(let error) where error.kind == "not_git":
            ContentUnavailableView("不是 git 仓库", systemImage: "folder.badge.questionmark",
                                   description: Text("这个会话的目录不在 git 仓库里。"))
        case .failed(let error):
            ContentUnavailableView {
                Label("读取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("重试") { Task { await refresh() } }
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
        .accessibilityHint("查看这个文件的改动")
    }
}

/// +a −d, or 「二进制」.
struct ChangeCounts: View {
    let added: Int?
    let deleted: Int?

    var body: some View {
        Group {
            if added == nil && deleted == nil {
                Text("二进制").foregroundStyle(.secondary)
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
                ProgressView("正在读取…")
            case .failed(let error):
                ContentUnavailableView {
                    Label(error.kind == "changed" ? "文件列表已变化" : "读取失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.kind == "changed" ? "返回改动页刷新后再打开。" : error.message)
                } actions: {
                    if error.kind != "changed" {
                        Button("重试") { Task { await refresh() } }
                            .buttonStyle(.bordered)
                    }
                }
            case .loaded(let diff, _) where diff.binary:
                ContentUnavailableView("二进制文件", systemImage: "doc",
                                       description: Text("二进制文件的改动无法显示。"))
            case .loaded(let diff, _) where diff.hunks.isEmpty:
                ContentUnavailableView("没有文字改动", systemImage: "doc.text",
                                       description: Text(file.status == .renamed ? "只是改了名。" : "内容没变，可能只改了权限。"))
            case .loaded(let diff, let truncated):
                ScrollView {
                    DiffView(diff: diff)
                    if truncated {
                        Text("改动太长，只显示了开头的部分。")
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
                .accessibilityLabel("\(file.accessibilityLabel)，在 \(file.directory)")
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
                    Text("@@ 第 \(hunk.line) 行").fontWeight(.semibold).fixedSize()
                    Text(hunk.context).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("从第 \(hunk.line) 行开始的改动")
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
                    Text("文件末尾没有换行").font(.caption2).foregroundStyle(.secondary)
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
