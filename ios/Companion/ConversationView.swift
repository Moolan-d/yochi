import SwiftUI

/// The Agent's conversation, newest at the bottom. It follows new items
/// while the reader is at the bottom and stays put while they read back.
struct ConversationPane: View {
    let feed: ConversationFeed
    let status: Status?
    let retry: () -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

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
        case .connecting, .unsupported:
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
        case .following:
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
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
        } action: { _, atBottom in
            self.atBottom = atBottom
        }
        .onChange(of: feed.items) { _, _ in follow() }
        .onChange(of: working) { _, _ in follow() }
        .accessibilityIdentifier("conversation")
    }

    private func follow() {
        guard atBottom else { return }
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
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

/// Markdown as Agents write it: paragraphs and lists with inline styling,
/// headings, quotes and fenced code (scrolling sideways, never wrapped).
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(MarkdownBlock.inline(text))
                case .heading(let text):
                    Text(MarkdownBlock.inline(text)).font(.headline)
                case .quote(let text):
                    Text(MarkdownBlock.inline(text))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color(.separator)).frame(width: 3)
                        }
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code)
                            .font(.callout.monospaced())
                            .padding(10)
                    }
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
                }
            }
        }
        .textSelection(.enabled)
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case quote(String)
    case code(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
            } else if trimmed.hasPrefix("#") {
                flush()
                blocks.append(.heading(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flush()
            } else if let bullet = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                let indent = String(repeating: "  ", count: (line.count - line.drop { $0 == " " }.count) / 2)
                paragraph.append(indent + "• " + trimmed.dropFirst(bullet.count))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Bold, italics, inline code and links; anything else stays as written.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
