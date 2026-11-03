import SwiftUI

/// A Claude Code dialog read from the screen, answered with its own options
/// (ADR 0005). Each tap sends the keys the planner chose for the dialog as
/// shown, checking the screen between them; an option that needs typing
/// stays in the terminal.
struct DialogCard: View {
    let dialog: BlockedDialog
    let run: (DialogActionPlan, BlockedDialog) async -> DialogRunner.Outcome
    let openTerminal: () -> Void

    /// The option being answered; 0 for Esc.
    @State private var running: Int?
    @State private var failure: String?
    @State private var confirming: Confirmation?
    @State private var answered = 0

    private struct Confirmation: Identifiable {
        let id: Int
        let title: String
        let message: String
        let action: DialogAction
    }

    private static let escOrdinal = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(heading, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            details
            VStack(spacing: 8) {
                ForEach(dialog.options, id: \.ordinal) { option in
                    optionButton(option)
                }
            }
            footer
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.5))
        }
        .disabled(running != nil)
        .sensoryFeedback(.success, trigger: answered)
        .confirmationDialog(confirming?.title ?? "", isPresented: confirmingShown, titleVisibility: .visible,
                            presenting: confirming) { confirmation in
            Button(confirmation.title, role: .destructive) { perform(confirmation.action, marker: confirmation.id) }
            // iOS 26 can drop `.cancel` here; an explicit plain button remains.
            Button("返回") {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dialogCard")
    }

    private var confirmingShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var heading: String {
        switch dialog.kind {
        case .claudeBash: "Agent 想运行命令"
        case .claudeFileEdit: "Agent 想修改文件"
        case .claudeFileCreate: "Agent 想创建文件"
        case .claudeFileRead: "Agent 想读取文件"
        case .claudeFetch: "Agent 想访问网页"
        case .claudePlan: "Agent 的计划等你确认"
        case .claudeQuestion: "Agent 在问你"
        case .claudeQuestionReview: "确认你的回答"
        case .claudeWorkspaceTrust: "是否信任这个文件夹？"
        }
    }

    private var symbol: String {
        switch dialog.kind {
        case .claudeQuestion, .claudeQuestionReview: "questionmark.bubble.fill"
        case .claudeWorkspaceTrust: "folder.badge.questionmark"
        case .claudePlan: "list.bullet.clipboard.fill"
        default: "hand.raised.fill"
        }
    }

    /// The dialog's own words, as Claude Code draws them.
    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(dialog.title).font(.footnote.weight(.semibold))
                if let suffix = dialog.sourceSuffix {
                    Text(suffix).font(.footnote).foregroundStyle(.secondary)
                }
                if let position = dialog.positionLabel {
                    Spacer(minLength: 0)
                    Text(position).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let progress = dialog.progress {
                Text(progress).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if let command = dialog.subject.command {
                if let description = dialog.subject.commandDescription {
                    Text(description).font(.footnote).foregroundStyle(.secondary)
                }
                Text(command)
                    .font(.callout.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
            } else if !dialog.body.isEmpty {
                Text(dialog.body.joined(separator: "\n"))
                    .font(dialog.kind == .claudePlan ? .footnote : .callout)
                    .lineLimit(dialog.kind == .claudePlan ? 10 : 6)
                    .textSelection(.enabled)
            }
        }
    }

    private func plan(for option: DialogOption) -> DialogActionPlan? {
        guard let plan = try? DialogActionPlanner.plan(.choose(ordinal: option.ordinal), for: dialog),
              !plan.steps.contains(where: { if case .paste = $0 { true } else { false } }) else { return nil }
        return plan
    }

    private func optionButton(_ option: DialogOption) -> some View {
        let available = plan(for: option) != nil
        let destructive = option.role == .decline || option.role == .exitProgram
        // The one-time approval, as on the desk where it comes first.
        let prominent = option.role == .trust || (option.role == .approve && option.ordinal == 1)
        return Button {
            choose(option)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.body.weight(.medium))
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(.footnote).opacity(0.75)
                    }
                    if let note = note(for: option) {
                        Label(note, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(prominent ? Color.white : Color.orange)
                    }
                    if !available {
                        Text("请在终端中完成").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if running == option.ordinal {
                    ProgressView()
                } else if option.isFocused {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .opacity(0.6)
                        .accessibilityLabel("终端里的当前选项")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(ChoiceStyle(role: prominent ? .prominent : destructive ? .destructive : .normal))
        .disabled(!available)
        .accessibilityIdentifier("dialogOption-\(option.ordinal)")
    }

    /// What an option keeps beyond this one request, for its caution line.
    /// Claude Code's `always allow access to <dir> from this project` adds
    /// the folder for the session; `don't ask again` options save a rule.
    private func note(for option: DialogOption) -> String? {
        switch option.role {
        case .approvePersistent:
            DialogRowScanner.comparable(option.label.lowercased())
                .contains(DialogRowScanner.comparable("always allow access to"))
                ? "本次会话内允许 Claude 访问这个文件夹" : "会保存一条规则，以后不再询问"
        case .approveModeSwitch: "会切换 Claude Code 的权限模式"
        case .exitProgram: "Claude Code 会退出"
        default: nil
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("在终端中查看", action: openTerminal)
                .font(.footnote)
                .buttonStyle(.borderless)
            Spacer()
            Button(role: .destructive) {
                confirming = Confirmation(
                    id: Self.escOrdinal,
                    title: dialog.kind == .claudeWorkspaceTrust ? "退出 Claude Code" : "取消（Esc）",
                    message: dialog.kind == .claudeWorkspaceTrust
                        ? "不信任这个文件夹，Claude Code 会退出。" : "Agent 会停下这一轮，等你的下一条消息。",
                    action: .dismiss)
            } label: {
                HStack(spacing: 4) {
                    if running == Self.escOrdinal { ProgressView() }
                    Text(dialog.kind == .claudeWorkspaceTrust ? "退出" : "取消")
                }
            }
            .font(.footnote)
            .accessibilityIdentifier("dialogDismiss")
        }
    }

    private func choose(_ option: DialogOption) {
        switch option.role {
        case .decline:
            confirming = Confirmation(id: option.ordinal, title: "拒绝这次请求？",
                                      message: "Agent 会停下这一轮，等你的下一条消息。",
                                      action: .choose(ordinal: option.ordinal))
        case .exitProgram:
            confirming = Confirmation(id: option.ordinal, title: "退出 Claude Code",
                                      message: "不信任这个文件夹，Claude Code 会退出。",
                                      action: .choose(ordinal: option.ordinal))
        default:
            perform(.choose(ordinal: option.ordinal), marker: option.ordinal)
        }
    }

    private func perform(_ action: DialogAction, marker: Int) {
        let dialog = dialog
        let plan: DialogActionPlan
        do {
            plan = try DialogActionPlanner.plan(action, for: dialog)
        } catch {
            failure = "这个回答请在终端中完成"
            return
        }
        running = marker
        failure = nil
        Task {
            let outcome = await run(plan, dialog)
            running = nil
            switch outcome {
            case .done: answered += 1
            case .unconfirmed: failure = "已按键，但对话框还在，请看终端"
            case .failed(let message): failure = message
            }
        }
    }
}

/// A screen that looks like a dialog the parser can't read for sure: its
/// rows as drawn, and the way to the terminal. Nothing is pressed from here.
struct GenericDialogCard: View {
    let excerpt: GenericDialogExcerpt
    let openTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agent 在等终端里的操作", systemImage: "rectangle.and.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ScrollView(.vertical) {
                Text(lines)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .scrollBounceBehavior(.basedOnSize)
            Button("在终端中作答", action: openTerminal)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("answerInTerminal")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange.opacity(0.5))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genericDialogCard")
    }

    /// The rows without rules and outer blank rows, each trimmed: a desk-wide
    /// row would wrap into noise at the phone's width.
    private var lines: String {
        let rows = excerpt.rows.filter { !Self.isFrame($0) }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        return rows.drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed().joined(separator: "\n")
    }

    /// A rule or the `▔` edge Claude Code draws above a picker.
    private static func isFrame(_ row: ScreenRow) -> Bool {
        !row.isBlank && row.text.allSatisfy { $0 == "─" || $0 == "▔" || $0 == " " }
    }
}
