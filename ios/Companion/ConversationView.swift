import SwiftUI

/// The Agent's conversation, newest at the bottom. It follows new items
/// while the reader is at the bottom and stays put while they read back.
struct ConversationPane: View {
    let feed: ConversationFeed
    let status: Status?
    /// The composer's keyboard shortens the viewport; the newest item must
    /// stay above it, whatever the system does with the scroll view's insets.
    let keyboardShown: Bool
    let retry: () -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// How far the content's end is below the visible area, and how tall that
    /// area is: the keyboard changes both, and the follow must keep the newest
    /// item above it.
    @State private var distanceBelow = CGFloat.zero
    @State private var viewport = CGFloat.zero
    /// Items arrived while the reader was further back.
    @State private var unseen = false

    private var working: Bool { status?.state == "working" }

    var body: some View {
        if feed.items.isEmpty {
            placeholder
        } else {
            list
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch feed.phase {
        case .connecting:
            ProgressView("正在读取对话…")
        case .failed(let reason):
            ContentUnavailableView {
                Label("无法读取对话", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("重试", action: retry).buttonStyle(.borderedProminent)
            }
        case .closed(let reason):
            ContentUnavailableView("会话已结束", systemImage: "stop.circle", description: Text(reason))
        case .following, .unsupported:
            // Unsupported shows only for Claude Code before its transcript exists.
            ContentUnavailableView {
                Label("还没有对话", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(working ? "Agent 正在工作…" : "发出第一条消息后，对话会显示在这里。")
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(feed.items) { item in
                    ConversationRow(item: item)
                }
                if working {
                    Label {
                        Text("Agent 正在工作…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentWorking")
                }
                switch feed.phase {
                case .failed(let reason):
                    HStack {
                        BannerLabel(text: "连接中断：\(reason)", systemImage: "wifi.exclamationmark")
                        Button("重试", action: retry).buttonStyle(.bordered)
                    }
                case .closed(let reason):
                    BannerLabel(text: reason, systemImage: "stop.circle")
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: CGPoint.self) { geometry in
            // visibleRect is what the reader sees, so a keyboard-inset bottom
            // counts as the bottom; the system's frame may extend under it.
            CGPoint(x: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                    y: geometry.visibleRect.height)
        } action: { _, metrics in
            distanceBelow = metrics.x
            viewport = metrics.y
            atBottom = metrics.x < 60
            if atBottom { unseen = false }
        }
        .onChange(of: feed.items) { _, _ in
            if atBottom { follow() } else { unseen = true }
        }
        .onChange(of: working) { _, _ in follow() }
        .onChange(of: keyboardShown) { _, _ in followAfterKeyboard() }
        .accessibilityIdentifier("conversation")
        // After the identifier, which would otherwise name the button too.
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if !atBottom {
                    latestButton.transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .animation(.snappy(duration: 0.2), value: atBottom)
        }
    }

    /// Back to the newest item; the list follows again from there.
    private var latestButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: .circle)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unseen ? "回到最新，有新消息" : "回到最新")
        .accessibilityIdentifier("scrollToLatest")
    }

    private func follow() {
        guard atBottom else { return }
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
    }

    /// The keyboard shortens the viewport without moving the list: the newest
    /// item would sit behind it. Follow the bottom when the reader was within
    /// a screen of it, and leave someone reading further back where they are.
    private func followAfterKeyboard() {
        guard distanceBelow < viewport else { return }
        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }
}

struct ConversationRow: View {
    let item: ConversationItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(item.text ?? "")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: .rect(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("你：\(item.text ?? "")")
        case .agent:
            MarkdownText(text: item.text ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolRow(item: item)
        case .command:
            CommandRow(item: item)
        case .task:
            TaskRow(item: item)
        case .notice:
            Text(item.text ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        case .other:
            EmptyView()
        }
    }
}

/// One tool call, collapsed to a line; tap for its output.
private struct ToolRow: View {
    let item: ConversationItem
    @State private var expanded = false

    private var answer: String? {
        guard let answers = item.answers, !answers.isEmpty else { return nil }
        return answers.values.sorted().joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: ToolRow.symbol(for: item.name ?? ""))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "工具")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let summary = item.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(expanded ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }
                        if let answer {
                            Text("已选：\(answer)")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                    }
                    Spacer(minLength: 0)
                    stateIcon
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.output == nil)

            if expanded, let output = item.output, !output.isEmpty {
                ScrollView(.horizontal) {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("工具 \(item.name ?? "")：\(item.summary ?? "")，\(stateText)\(answer.map { "，已选：\($0)" } ?? "")")
        .accessibilityHint(item.output == nil ? "" : "轻点两下显示或隐藏输出")
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch item.state {
        case .running:
            ProgressView().controlSize(.small)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .done, nil:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    private var stateText: String {
        switch item.state {
        case .running: "运行中"
        case .error: "出错"
        case .done, nil: "已完成"
        }
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "AskUserQuestion": "questionmark.bubble"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

/// A subagent or background task reporting back, collapsed to its summary;
/// tap for the report. Claude Code files it as a user message, but the user
/// never typed it.
struct TaskRow: View {
    let item: ConversationItem
    @State private var expanded = false

    /// `Agent "Find roadmap items" finished` → a subagent named by its task.
    private var subagent: String? {
        guard let summary = item.summary, summary.hasPrefix("Agent \"") else { return nil }
        let name = summary.dropFirst("Agent \"".count).prefix { $0 != "\"" }
        return name.isEmpty ? nil : String(name)
    }

    private var failed: Bool { item.state == .error }

    var heading: String {
        let who = subagent == nil ? "后台任务" : "子代理"
        return "\(who)\(failed ? "失败" : "完成")"
    }

    var detail: String { subagent ?? item.summary ?? "" }

    private var report: String? {
        guard let text = item.text, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: subagent == nil ? "gearshape.2" : "person.2")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(heading)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(failed ? Color.red : Color.primary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if report != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(report == nil)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(heading)：\(detail)")
            .accessibilityHint(report == nil ? "" : "轻点两下显示或隐藏汇报")
            .accessibilityIdentifier("taskRow")

            if expanded, let report {
                MarkdownText(text: report)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
                    .accessibilityIdentifier("taskReport")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// A slash command run in Claude Code, and what it printed.
private struct CommandRow: View {
    let item: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.name ?? "", systemImage: "chevron.forward.2")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
            if let output = item.output, !output.isEmpty {
                Text(output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("命令 \(item.name ?? "")")
    }
}
