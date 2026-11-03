import SwiftUI

/// A Claude Code slash command or skill the draft can start with.
struct SlashCommand: Decodable, Hashable, Identifiable {
    enum Source: String, Decodable {
        case builtin, project, user, skill, other

        var title: String {
            switch self {
            case .builtin: "内置"
            case .project: "项目"
            case .user: "个人"
            case .skill: "skill"
            case .other: "其他"
            }
        }
    }

    /// With its slash, e.g. `/compact`.
    let name: String
    let description: String
    let source: Source

    var id: String { name }

    /// Sending it ends the session.
    var endsSession: Bool { source == .builtin && name == "/exit" }

    init(name: String, description: String, source: Source) {
        self.name = name
        self.description = description
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case name, description, source }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        source = (try? c.decode(Source.self, forKey: .source)) ?? .other
    }
}

enum SlashCompletion {
    /// Claude Code 2.1.317's built-in commands that make sense from a phone,
    /// checked against its `/` menu. Ones that open a picker or panel are
    /// answered through the screen-read dialog cards; `/exit` comes last.
    static let builtins: [SlashCommand] = [
        ("/compact", "压缩对话，腾出上下文"),
        ("/clear", "清空上下文，开始新对话"),
        ("/context", "查看上下文用量"),
        ("/model", "切换模型"),
        ("/effort", "设置思考强度"),
        ("/fast", "开关快速模式"),
        ("/resume", "恢复之前的对话"),
        ("/rewind", "把代码或对话回退到之前某一步"),
        ("/btw", "不打断当前工作，问个小问题"),
        ("/goal", "设定 Agent 停下前要检查的目标"),
        ("/init", "生成 CLAUDE.md"),
        ("/memory", "编辑 CLAUDE.md 和记忆设置"),
        ("/usage", "查看费用和用量"),
        ("/status", "查看版本、模型、账号和连接"),
        ("/add-dir", "添加工作目录"),
        ("/permissions", "管理工具权限规则"),
        ("/mcp", "管理 MCP 服务器"),
        ("/export", "导出对话"),
        ("/doctor", "检查安装和配置"),
        ("/help", "帮助和全部命令"),
        ("/exit", "退出 Claude Code，会话随之结束"),
    ].map { SlashCommand(name: $0.0, description: $0.1, source: .builtin) }

    /// What follows the slash while the draft is still just a command name.
    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst()).lowercased()
    }

    /// Built-ins first, then the custom ones; names that start with the query
    /// before names that only contain it. A custom command can't shadow a built-in.
    static func matches(_ query: String, custom: [SlashCommand]) -> [SlashCommand] {
        let names = Set(builtins.map(\.name))
        let all = builtins + custom.filter { !names.contains($0.name) }
        let starting = all.filter { $0.name.dropFirst().lowercased().hasPrefix(query) }
        let containing = query.isEmpty ? [] : all.filter {
            let name = $0.name.dropFirst().lowercased()
            return !name.hasPrefix(query) && name.contains(query)
        }
        return starting + containing
    }

    static func fill(_ command: SlashCommand) -> String { command.name + " " }
}

/// The list above the composer while the draft is a bare `/name`.
struct SlashSuggestions: View {
    let commands: [SlashCommand]
    let pick: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(commands) { command in
                    Button { pick(command) } label: { row(command) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(command.name)
                        .accessibilityValue(command.description)
                        .accessibilityHint(command.source.title)
                        .accessibilityIdentifier("slash-\(command.name)")
                    if command.id != commands.last?.id { Divider().padding(.leading, 14) }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator))
        }
        .accessibilityIdentifier("slashSuggestions")
    }

    private func row(_ command: SlashCommand) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(.body.monospaced())
                    .foregroundStyle(command.endsSession ? .red : .primary)
                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text(command.source.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
