// Ported from Heeler (https://github.com/ZingerLittleBee/Heeler), Apache-2.0,
// at b9790d8; trimmed to Claude Code's dialogs.

import Foundation

/// Turns a card action into the keys, pastes and checks that perform it on
/// the dialog as last read.
///
/// Plans stay as short as the dialog allows: a digit where the program binds
/// one, otherwise one arrow key per row with a re-read after each, so a key
/// that lands somewhere unexpected stops the plan before Enter. Text typed
/// in the terminal stops every plan that would send keys past it, since
/// Heeler never clears it.
enum DialogActionPlanner {
    /// - Parameter toolUseID: The matched request's `tool_use` id; the card
    ///   then confirms by the request's result.
    static func plan(
        _ action: DialogAction, for dialog: BlockedDialog, toolUseID: String? = nil
    ) throws(DialogPlanError) -> DialogActionPlan {
        if dialog.kind == .claudePicker { return try ClaudePickerPlanner(dialog: dialog).plan(action) }
        switch dialog.program {
        case .claude: return try ClaudeDialogPlanner(dialog: dialog, toolUseID: toolUseID).plan(action)
        }
    }

    /// The generic card's option button: the digit of an option the excerpt
    /// lists.
    static func plan(
        number: Int, for excerpt: GenericDialogExcerpt, program: ChatProgram
    ) throws(DialogPlanError) -> DialogActionPlan {
        guard excerpt.numbered[number] != nil else { throw .noSuchOption(number) }
        guard let digit = digitKey(number) else { throw .unsupported("Option \(number) has no digit key.") }
        // Claude draws its text cursor in reverse video. With a field
        // focused, the digit would be typed rather than pressed.
        if excerpt.rows.contains(where: { $0.runs.contains(where: \.style.isReverse) }) {
            throw .unsupported("A text field in the dialog has the cursor, so a digit would be typed into it.")
        }
        return DialogActionPlan(steps: [.keys([digit])], confirmation: .fingerprintChange)
    }

    /// The key for an option number; programs bind digits 1 to 9 only.
    static func digitKey(_ number: Int?) -> String? {
        guard let number, (1...9).contains(number) else { return nil }
        return String(number)
    }

    /// `text` as a dialog field takes it: one line, trimmed, with no
    /// character the program would read as a key. Without bracketed paste a
    /// Tab or line break would act on the dialog.
    static func fieldText(_ text: String) throws(DialogPlanError) -> String {
        let normalized = TerminalTextSafety.normalizingNewlines(text)
        let hasLineSeparator = normalized.unicodeScalars.contains { $0 == "\u{2028}" || $0 == "\u{2029}" }
        if TerminalTextSafety.isMultiline(normalized) || hasLineSeparator { throw .multilineText }
        guard TerminalTextSafety.containsOnlySafeScalars(normalized), !normalized.unicodeScalars.contains("\t")
        else { throw .unsafeText }
        let trimmed = normalized.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .emptyText }
        return trimmed
    }
}

extension BlockedDialog {
    /// Whether one of the dialog's fields holds typed text.
    var hasTypedText: Bool {
        if let notes = focus.notesText, !notes.isEmpty { return true }
        return focus.inputText != nil
            || options.contains { option in
                if case .text = option.input { return true }
                return false
            }
    }
}

/// Collects steps while tracking where focus will be once they have run.
struct StepBuilder {
    let dialog: BlockedDialog
    private(set) var steps: [DialogStep] = []
    private(set) var focus: Int?

    init(dialog: BlockedDialog) {
        self.dialog = dialog
        focus = dialog.focus.focusedOrdinal
    }

    mutating func keys(_ key: String) {
        steps.append(.keys([key]))
    }

    mutating func paste(_ text: String) {
        steps.append(.paste(text))
    }

    mutating func expect(_ expectation: DialogExpectation) {
        steps.append(.expect(expectation))
    }

    mutating func append(_ more: [DialogStep]) {
        steps.append(contentsOf: more)
    }

    /// One arrow key per option from the focus to `target`, each checked.
    mutating func move(to target: Int) throws(DialogPlanError) {
        guard var current = focus else { throw .noFocus }
        while current != target {
            let isForward = target > current
            current += isForward ? 1 : -1
            keys(isForward ? "down" : "up")
            expect(.focus(ordinal: current))
        }
        focus = target
    }

    /// Steps off a focused text field, where digits would be typed rather
    /// than pressed. Arrow keys still move focus from a field.
    mutating func leaveField() throws(DialogPlanError) {
        guard let current = focus, dialog.option(current)?.input != nil else { return }
        let neighbor = current > 1 ? current - 1 : current + 1
        guard dialog.option(neighbor) != nil else {
            throw .unsupported("The focused text field has no option next to it to step to.")
        }
        try move(to: neighbor)
    }

    /// Presses an option: its digit, or arrow keys and Enter.
    mutating func press(_ option: DialogOption) throws(DialogPlanError) {
        if let digit = DialogActionPlanner.digitKey(option.number) {
            try leaveField()
            keys(digit)
        } else {
            try move(to: option.ordinal)
            keys("enter")
        }
    }

    /// Focuses an empty text field. Its digit only focuses it, since the
    /// program submits a field by digit only once it holds text.
    mutating func focusField(_ option: DialogOption) throws(DialogPlanError) {
        guard focus != option.ordinal else { return }
        if let digit = DialogActionPlanner.digitKey(option.number) {
            keys(digit)
            expect(.focus(ordinal: option.ordinal))
            focus = option.ordinal
        } else {
            try move(to: option.ordinal)
        }
    }
}

private struct ClaudeDialogPlanner {
    let dialog: BlockedDialog
    let toolUseID: String?

    private var confirmation: ConfirmationRule {
        toolUseID.map { .toolResult(id: $0) } ?? .fingerprintChange
    }

    private var isMultiSelect: Bool {
        dialog.kind == .claudeQuestion && dialog.options.contains { $0.role == .next }
    }

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        switch action {
        case .dismiss:
            // Esc cancels rather than submits, so it goes through even when
            // a field holds text.
            DialogActionPlan(steps: [.keys(["esc"])], confirmation: confirmation)
        case .choose(let ordinal):
            try choose(ordinal)
        case .amend(let ordinal, let note):
            try amend(ordinal, note: note)
        case .respond(let ordinal, let text):
            try respond(ordinal, text: text, submitKey: "enter")
        case .approvePlan(let note):
            try approvePlan(note: note)
        case .submitSelection(let ordinals):
            try submitSelection(ordinals)
        case .pick, .scroll:
            throw .unsupported("Only a picker scrolls or takes a key from its footer.")
        }
    }

    private func choose(_ ordinal: Int) throws(DialogPlanError) -> DialogActionPlan {
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        switch option.role {
        case .otherText:
            throw .needsText
        case .answer where isMultiSelect:
            throw .unsupported("A multi-select question takes its answers as a set.")
        case .next:
            try builder.move(to: ordinal)
            builder.keys("enter")
            builder.append(pageTurn())
        case .answer:
            try builder.press(option)
            builder.append(pageTurn())
        default:
            try builder.press(option)
        }
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    /// Tab on a `Yes` or `No` row opens its note field: `Yes, and tell
    /// Claude what to do next`, `No, and tell Claude what to do
    /// differently`.
    private func amend(_ ordinal: Int, note: String) throws(DialogPlanError) -> DialogActionPlan {
        guard [.claudeBash, .claudeFileEdit, .claudeFileCreate, .claudeFileRead].contains(dialog.kind) else {
            throw .unsupported("Only Claude's Bash and file dialogs take a note with the answer.")
        }
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard option.role == .approve || option.role == .decline else {
            throw .unsupported("Only the Yes and No rows take a note.")
        }
        let text = try DialogActionPlanner.fieldText(note)
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        // A row already turned into an empty note field skips the Tab.
        if dialog.focus.feedbackOrdinal != ordinal {
            try builder.move(to: ordinal)
            builder.keys("tab")
            builder.expect(.feedbackMode(ordinal: ordinal))
        }
        builder.paste(text)
        builder.expect(.inputText(text))
        builder.keys("enter")
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    private func respond(_ ordinal: Int, text: String, submitKey: String) throws(DialogPlanError) -> DialogActionPlan {
        guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
        guard option.role == .otherText, option.input != nil else {
            throw .unsupported("Option \(ordinal) is not a text field.")
        }
        guard !isMultiSelect else {
            throw .unsupported("Heeler does not type into a multi-select question's Other row.")
        }
        let text = try DialogActionPlanner.fieldText(text)
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        var builder = StepBuilder(dialog: dialog)
        try builder.focusField(option)
        builder.paste(text)
        builder.expect(.inputText(text))
        builder.keys(submitKey)
        if submitKey == "enter" { builder.append(pageTurn()) }
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    /// shift+tab in the plan's feedback row approves with the note, taking
    /// the first approval option; the card names that option's mode.
    private func approvePlan(note: String) throws(DialogPlanError) -> DialogActionPlan {
        guard dialog.kind == .claudePlan, let field = dialog.options.last(where: { $0.role == .otherText }),
            field.detail?.hasPrefix("shift+tab to approve") == true
        else { throw .unsupported("This dialog does not offer approving with feedback.") }
        return try respond(field.ordinal, text: note, submitKey: "shift+tab")
    }

    /// Toggles answers by digit (focus stays put), then moves to the page's
    /// button and presses Enter.
    private func submitSelection(_ ordinals: Set<Int>) throws(DialogPlanError) -> DialogActionPlan {
        guard isMultiSelect, let button = dialog.options.first(where: { $0.role == .next }) else {
            throw .unsupported("Only a multi-select question takes a set of answers.")
        }
        guard !ordinals.isEmpty else { throw .emptySelection }
        for ordinal in ordinals.sorted() {
            guard let option = dialog.option(ordinal) else { throw .noSuchOption(ordinal) }
            guard option.role == .answer else {
                throw .unsupported("Option \(ordinal) is not an answer Heeler can check.")
            }
        }
        guard !dialog.hasTypedText else { throw .textFieldNotEmpty }
        if dialog.options.contains(where: { $0.role == .otherText && $0.isChecked == true }) {
            throw .unsupported("The typed answer is checked; finish it in the terminal.")
        }
        var builder = StepBuilder(dialog: dialog)
        try builder.leaveField()
        var checked = dialog.focus.checked
        for option in dialog.options
        where option.role == .answer && ordinals.contains(option.ordinal) != checked.contains(option.ordinal) {
            guard let digit = DialogActionPlanner.digitKey(option.number) else {
                throw .unsupported("Option \(option.ordinal) has no digit key.")
            }
            checked.formSymmetricDifference([option.ordinal])
            builder.keys(digit)
            builder.expect(.checked(checked))
        }
        try builder.move(to: button.ordinal)
        builder.keys("enter")
        builder.append(pageTurn())
        return DialogActionPlan(steps: builder.steps, confirmation: confirmation)
    }

    /// Answering a page of several questions shows the next question, and
    /// after the last one the review page.
    private func pageTurn() -> [DialogStep] {
        let headers = dialog.subject.questionHeaders
        guard dialog.kind == .claudeQuestion, headers.count > 1, let current = dialog.progress,
            let index = headers.firstIndex(of: current)
        else { return [] }
        let next = headers.indices.contains(index + 1) ? headers[index + 1] : "Review your answers"
        return [.expect(.page(next))]
    }
}

/// A picker moves by arrow keys only: its digits are not bound, and its
/// numbers run past 9. Arrows go out a batch at a time, each checked by the
/// focused row's number, which stays put as the list scrolls; Enter or the
/// footer's letter goes out only once focus is on the row the user tapped.
private struct ClaudePickerPlanner {
    let dialog: BlockedDialog

    /// The most keys the Gateway takes in one request.
    static let batch = 8

    func plan(_ action: DialogAction) throws(DialogPlanError) -> DialogActionPlan {
        guard let picker = dialog.picker else { throw .unsupported("The picker's list could not be read.") }
        switch action {
        case .dismiss:
            return DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChange)
        case .choose(let ordinal):
            return try pick(ordinal, key: "enter", picker: picker)
        case .pick(let ordinal, let key):
            return try pick(ordinal, key: key, picker: picker)
        case .scroll(let forward):
            guard let first = dialog.options.first?.number, let last = dialog.options.last?.number else {
                throw .noFocus
            }
            let page = dialog.options.count
            let target: Int
            if forward {
                guard picker.moreBelow else { throw .unsupported("No more options below.") }
                target = last + min(page, picker.hiddenBelow ?? 1)
            } else {
                guard picker.hiddenAbove > 0 else { throw .unsupported("No more options above.") }
                target = first - min(page, picker.hiddenAbove)
            }
            return DialogActionPlan(steps: try move(to: target), confirmation: .steps)
        case .amend, .respond, .approvePlan, .submitSelection:
            throw .unsupported("A picker only takes a choice.")
        }
    }

    private func pick(_ ordinal: Int, key: String, picker: DialogPicker) throws(DialogPlanError) -> DialogActionPlan {
        guard let option = dialog.option(ordinal), let number = option.number else { throw .noSuchOption(ordinal) }
        guard key == "enter" || picker.keys.contains(where: { $0.key == key }) else {
            throw .unsupported("The picker's footer does not bind \(key).")
        }
        return DialogActionPlan(steps: try move(to: number) + [.keys([key])], confirmation: .fingerprintChange)
    }

    private func move(to target: Int) throws(DialogPlanError) -> [DialogStep] {
        guard var current = dialog.focus.focusedOrdinal.flatMap(dialog.option)?.number else { throw .noFocus }
        var steps: [DialogStep] = []
        while current != target {
            let count = min(Self.batch, abs(target - current))
            let forward = target > current
            current += forward ? count : -count
            steps.append(.keys(Array(repeating: forward ? "down" : "up", count: count)))
            steps.append(.expect(.focusNumber(current)))
        }
        return steps
    }
}
