import SwiftUI

/// A Claude Code dialog read from the screen, answered with its own options
/// (ADR 0005). Each tap sends the keys the planner chose for the dialog as
/// shown, checking the screen between them; an option that needs typing
/// is left to the desk.
struct DialogCard: View {
    let dialog: BlockedDialog
    /// The most the dialog's words and options may take; beyond it they
    /// scroll inside the card, so its heading and footer stay on screen.
    let maxBodyHeight: CGFloat
    let run: (DialogActionPlan, BlockedDialog) async -> DialogRunner.Outcome

    /// The option being answered; 0 for Esc, and the scroll markers below.
    @State private var running: Int?
    @State private var failure: String?
    @State private var confirming: Confirmation?
    /// A picker option waiting for the reader to pick Enter or a letter.
    @State private var picking: DialogOption?
    @State private var answered = 0
    @State private var bodyHeight: CGFloat = 0

    private struct Confirmation: Identifiable {
        let id: Int
        let title: String
        let message: String
        let action: DialogAction
    }

    private static let escOrdinal = 0
    private static let scrollUpMarker = -1
    private static let scrollDownMarker = -2

    private var isPicker: Bool { dialog.kind == .claudePicker }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(heading, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            scrollingBody
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
        .confirmationDialog(picking?.label ?? "", isPresented: pickingShown, titleVisibility: .visible,
                            presenting: picking) { option in
            if let picker = dialog.picker {
                Button(Self.pickerAction(picker.enterAction ?? "select")) {
                    perform(.choose(ordinal: option.ordinal), marker: option.ordinal)
                }
                ForEach(picker.keys, id: \.key) { key in
                    Button(Self.pickerAction(key.action)) {
                        perform(.pick(ordinal: option.ordinal, key: key.key), marker: option.ordinal)
                    }
                }
            }
            Button("返回") {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dialogCard")
    }

    private var confirmingShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var pickingShown: Binding<Bool> {
        Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })
    }

    /// A picker footer's action in the reader's words, where Claude Code's
    /// usual ones are known; others as the footer has them.
    static func pickerAction(_ action: String) -> String {
        switch action.lowercased() {
        case "set as default": String(localized: "设为默认")
        case "use this session only": String(localized: "仅用于本会话")
        case "select", "confirm", "choose": String(localized: "选择")
        default: action.prefix(1).uppercased() + action.dropFirst()
        }
    }

    private var heading: String {
        switch dialog.kind {
        case .claudeBash: String(localized: "Agent 想运行命令")
        case .claudeFileEdit: String(localized: "Agent 想修改文件")
        case .claudeFileCreate: String(localized: "Agent 想创建文件")
        case .claudeFileRead: String(localized: "Agent 想读取文件")
        case .claudeFetch: String(localized: "Agent 想访问网页")
        case .claudePlan: String(localized: "Agent 的计划等你确认")
        case .claudeQuestion: String(localized: "Agent 在问你")
        case .claudeQuestionReview: String(localized: "确认你的回答")
        case .claudeWorkspaceTrust: String(localized: "是否信任这个文件夹？")
        case .claudePicker: String(localized: "Claude Code 在等你选择")
        }
    }

    private var symbol: String {
        switch dialog.kind {
        case .claudeQuestion, .claudeQuestionReview: "questionmark.bubble.fill"
        case .claudeWorkspaceTrust: "folder.badge.questionmark"
        case .claudePlan: "list.bullet.clipboard.fill"
        case .claudePicker: "list.bullet"
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

    /// A long dialog scrolls within the card rather than growing past the
    /// top of the page; it opens on the focused row.
    private var scrollingBody: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    details
                    VStack(spacing: 8) {
                        if let picker = dialog.picker, picker.hiddenAbove > 0 {
                            scrollButton(forward: false, title: String(localized: "上面还有 \(picker.hiddenAbove) 项"))
                        }
                        optionRows
                        if let picker = dialog.picker, picker.moreBelow {
                            scrollButton(forward: true, title: picker.hiddenBelow.map { String(localized: "下面还有 \($0) 项") } ?? String(localized: "下面还有更多"))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // A bottom inset is offered no height, so the scroll view takes
            // the height its content measures, up to the limit.
            .frame(height: min(bodyHeight, maxBodyHeight))
            .onChange(of: bodyHeight > maxBodyHeight) { _, overflows in
                if overflows { proxy.scrollTo(dialog.focus.focusedOrdinal, anchor: .center) }
            }
            .onChange(of: dialog.focus.focusedOrdinal) { _, ordinal in
                proxy.scrollTo(ordinal, anchor: .center)
            }
        }
    }

    private var optionRows: some View {
        VStack(spacing: 8) {
            ForEach(dialog.options, id: \.ordinal) { option in
                optionButton(option).id(option.ordinal)
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
                        Text("请在电脑上完成").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if running == option.ordinal {
                    ProgressView()
                } else if isPicker, option.isChecked == true {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .accessibilityLabel("正在使用")
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

    /// Moves the picker's focus past the rows shown, so the list scrolls.
    /// Nothing is chosen.
    private func scrollButton(forward: Bool, title: String) -> some View {
        let marker = forward ? Self.scrollDownMarker : Self.scrollUpMarker
        return Button {
            perform(.scroll(forward: forward), marker: marker)
        } label: {
            HStack(spacing: 6) {
                if running == marker {
                    ProgressView()
                } else {
                    Image(systemName: forward ? "chevron.down" : "chevron.up")
                }
                Text(title)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(forward ? "pickerScrollDown" : "pickerScrollUp")
    }

    /// What an option keeps beyond this one request, for its caution line.
    /// Claude Code's `always allow access to <dir> from this project` adds
    /// the folder for the session; `don't ask again` options save a rule.
    private func note(for option: DialogOption) -> String? {
        switch option.role {
        case .approvePersistent:
            DialogRowScanner.comparable(option.label.lowercased())
                .contains(DialogRowScanner.comparable("always allow access to"))
                ? String(localized: "本次会话内允许 Claude 访问这个文件夹") : String(localized: "会保存一条规则，以后不再询问")
        case .approveModeSwitch: String(localized: "会切换 Claude Code 的权限模式")
        case .exitProgram: String(localized: "Claude Code 会退出")
        default: nil
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            Button(role: isPicker ? nil : .destructive) {
                // Esc only closes a picker; nothing changes.
                if isPicker { return perform(.dismiss, marker: Self.escOrdinal) }
                confirming = Confirmation(
                    id: Self.escOrdinal,
                    title: dialog.kind == .claudeWorkspaceTrust ? String(localized: "退出 Claude Code") : String(localized: "取消（Esc）"),
                    message: dialog.kind == .claudeWorkspaceTrust
                        ? String(localized: "不信任这个文件夹，Claude Code 会退出。") : String(localized: "Agent 会停下这一轮，等你的下一条消息。"),
                    action: .dismiss)
            } label: {
                HStack(spacing: 4) {
                    if running == Self.escOrdinal { ProgressView() }
                    Text(dialog.kind == .claudeWorkspaceTrust ? "退出" : isPicker ? "关闭" : "取消")
                }
            }
            .font(.footnote)
            .accessibilityIdentifier("dialogDismiss")
        }
    }

    private func choose(_ option: DialogOption) {
        switch option.role {
        case .decline:
            confirming = Confirmation(id: option.ordinal, title: String(localized: "拒绝这次请求？"),
                                      message: String(localized: "Agent 会停下这一轮，等你的下一条消息。"),
                                      action: .choose(ordinal: option.ordinal))
        case .exitProgram:
            confirming = Confirmation(id: option.ordinal, title: String(localized: "退出 Claude Code"),
                                      message: String(localized: "不信任这个文件夹，Claude Code 会退出。"),
                                      action: .choose(ordinal: option.ordinal))
        case .answer where dialog.picker?.keys.isEmpty == false:
            picking = option
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
            failure = String(localized: "这个回答请在电脑上完成")
            return
        }
        running = marker
        failure = nil
        Task {
            let outcome = await run(plan, dialog)
            running = nil
            switch outcome {
            case .done: if plan.confirmation != .steps { answered += 1 }
            case .unconfirmed: failure = String(localized: "已按键，但对话框还在，请在电脑上查看")
            case .failed(let message): failure = message
            }
        }
    }
}

/// A screen that looks like a dialog the parser can't read for sure: its
/// rows as drawn, and Esc to close it. Nothing else is pressed from here.
struct GenericDialogCard: View {
    let excerpt: GenericDialogExcerpt
    /// Presses the key if the screen still shows this; the failure, if any.
    let press: (String) async -> String?

    /// The key being pressed.
    @State private var pressing: String?
    @State private var confirming: DialogKeyHint?
    @State private var failure: String?

    /// The footer's keys; Esc with its usual meaning when the footer names none.
    private var keys: [DialogKeyHint] {
        excerpt.keys.contains { Self.isEscape($0) } ? excerpt.keys
            : excerpt.keys + [DialogKeyHint(key: "Esc", action: "cancel")]
    }

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
            HStack(spacing: 12) {
                Text(excerpt.keys.contains { !Self.isEscape($0) } ? "按底部提示作答" : "手机还认不出这个对话框，请在电脑上作答")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(keys, id: \.key) { key in
                    Button(role: Self.isEscape(key) ? .destructive : nil) { confirming = key } label: {
                        HStack(spacing: 4) {
                            if pressing == key.key { ProgressView() }
                            Text(Self.title(key))
                        }
                    }
                    .font(Self.isEscape(key) ? .footnote : .footnote.weight(.semibold))
                    .accessibilityIdentifier(Self.isEscape(key) ? "genericDialogCancel" : "genericDialogKey-\(key.key.lowercased())")
                }
                .disabled(pressing != nil)
            }
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
        .confirmationDialog(confirming.map(Self.confirmTitle) ?? "", isPresented: confirmingShown,
                            titleVisibility: .visible, presenting: confirming) { key in
            Button(Self.confirmTitle(key), role: Self.isEscape(key) ? .destructive : nil) {
                pressing = key.key
                failure = nil
                Task {
                    failure = await press(key.key.lowercased())
                    pressing = nil
                }
            }
            // iOS 26 can drop `.cancel` here; an explicit plain button remains.
            Button("返回") {}
        } message: { key in
            Text(Self.isEscape(key) && excerpt.keys.isEmpty
                ? "在终端里按 Esc：通常会关闭对话框；Agent 在问你时会停下这一轮。"
                : "在终端里按 \(key.key)：\(key.action)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genericDialogCard")
    }

    private var confirmingShown: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private static func isEscape(_ key: DialogKeyHint) -> Bool { key.key.lowercased() == "esc" }

    /// The footer's action in the reader's words, where Claude Code's usual
    /// ones are known.
    static func title(_ key: DialogKeyHint) -> String {
        switch key.action.lowercased() {
        case "continue": String(localized: "继续")
        case "confirm": String(localized: "确认")
        case "cancel": String(localized: "取消")
        case "close": String(localized: "关闭")
        case "exit": String(localized: "退出")
        case "go back", "back": String(localized: "返回")
        case "dismiss": String(localized: "关闭")
        default: DialogCard.pickerAction(key.action)
        }
    }

    private static func confirmTitle(_ key: DialogKeyHint) -> String { String(localized: "\(title(key))（\(key.key)）") }

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
