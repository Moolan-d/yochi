// Ported from Heeler (https://github.com/ZingerLittleBee/Heeler), Apache-2.0,
// at b9790d8; trimmed to Claude Code's dialogs.

import Foundation

/// What the user asked a card to do. The planner turns it into keys for the
/// dialog as last read, or refuses with the reason.
enum DialogAction: Sendable, Hashable {
    /// Picks an option: its digit when it has one, otherwise arrow keys and
    /// Enter.
    case choose(ordinal: Int)
    /// Claude's Bash and file dialogs: Tab turns a `Yes` or `No` row into a
    /// note field, then `note` goes in and Enter answers with it.
    case amend(ordinal: Int, note: String)
    /// Types `text` into a text option and submits it: a question's Other
    /// row, the plan's feedback row, Codex's `None of the above` notes.
    case respond(ordinal: Int, text: String)
    /// Claude plan: types `note` into the feedback row and approves with
    /// shift+tab, which takes the first approval option.
    case approvePlan(note: String)
    /// Claude multi-select question: leaves exactly these answers checked,
    /// then presses the page's `Next` or `Submit` button.
    case submitSelection(Set<Int>)
    /// A picker: moves to this option, then presses `key`, Enter or a
    /// letter the footer names.
    case pick(ordinal: Int, key: String)
    /// A picker: moves focus past the rows shown, so the list scrolls to
    /// the next or previous page.
    case scroll(forward: Bool)
    /// Esc. Claude declines and stops the turn, and quits on the trust
    /// dialog; Codex declines an approval or interrupts the turn.
    case dismiss
}

/// One thing a card does to the pane, in order.
enum DialogStep: Sendable, Hashable {
    /// `agent.send_keys` with these herdr key names.
    case keys([String])
    /// `pane.send_input` with text only. Selection keys never go this way:
    /// a bracketed paste does not press them.
    case paste(String)
    /// Re-read the screen until it shows this, polling briefly; when it
    /// never does, stop and send nothing more.
    case expect(DialogExpectation)
}

/// What a fresh read must show before the next step.
enum DialogExpectation: Sendable, Hashable {
    /// The same dialog with focus on this option.
    case focus(ordinal: Int)
    /// The same picker with focus on the option numbered this, wherever
    /// the list has scrolled.
    case focusNumber(Int)
    /// Claude: the same dialog, Tab having turned this option's row into an
    /// empty note field.
    case feedbackMode(ordinal: Int)
    /// The same dialog, its focused field holding this text.
    case inputText(String)
    /// Codex: the same question, its notes holding this text.
    case notes(String)
    /// The same dialog with exactly these options checked.
    case checked(Set<Int>)
    /// A dialog on this page: Claude's active question tab or `Review your
    /// answers`, Codex's `Question i/n`.
    case page(String)
}

/// How a card knows its keys took effect. Leaving Blocked proves little on
/// its own: Claude can hold the next queued dialog without leaving it.
enum ConfirmationRule: Sendable, Hashable {
    /// Claude with a matched request: the transcript shows its
    /// `tool_result`, or the dialog left the screen.
    case toolResult(id: String)
    /// The screen no longer shows the dialog: another one, a page turn, or
    /// none. Two identical dialogs in a row look unchanged, so a card
    /// without a matched request can end up unconfirmed until the
    /// transcript shows a waiting call resolve.
    case fingerprintChange
    /// The plan's own checks confirm it: moving a picker's focus leaves
    /// the picker open.
    case steps
}

struct DialogActionPlan: Sendable, Hashable {
    let steps: [DialogStep]
    let confirmation: ConfirmationRule

    /// Every key name the plan sends, in order.
    var keys: [String] {
        steps.flatMap { step -> [String] in
            if case .keys(let keys) = step { return keys }
            return []
        }
    }
}

/// Why the planner sent nothing.
enum DialogPlanError: Error, Sendable, Hashable {
    /// The action does not apply to this dialog; why, for the card.
    case unsupported(String)
    /// The dialog has no option at this ordinal.
    case noSuchOption(Int)
    /// The action needs arrow keys, but no option shows focus.
    case noFocus
    /// One of the dialog's fields holds text typed in the terminal. Heeler
    /// never clears it, and keys sent now would mix with it.
    case textFieldNotEmpty
    /// The option is a text field: answer it with `respond`.
    case needsText
    /// The text is empty once trimmed.
    case emptyText
    /// The text has a line break; dialog fields take one line, and a
    /// newline would submit early.
    case multilineText
    /// The text has a control character, such as Esc or Tab, that the
    /// program would read as a key.
    case unsafeText
    /// A multi-select page needs at least one answer.
    case emptySelection
}

/// A fresh read of the Agent while a card acts, which expectations and
/// confirmation rules are checked against.
struct DialogObservation: Sendable {
    let screen: ANSIScreen
    let result: DialogParseResult
    /// Tool uses whose results the transcript shows.
    let resolvedToolUseIDs: Set<String>

    init(screen: ANSIScreen, program: ChatProgram, resolvedToolUseIDs: Set<String> = []) {
        self.screen = screen
        result = BlockedDialogParser.parse(screen, program: program)
        self.resolvedToolUseIDs = resolvedToolUseIDs
    }
}

extension DialogExpectation {
    /// Whether `observation` shows this. Expectations about the same dialog
    /// fail once its fingerprint no longer matches, so later keys never
    /// land on a dialog the user did not see.
    func isMet(by observation: DialogObservation, fingerprint: DialogFingerprint) -> Bool {
        switch self {
        case .page(let page):
            return observation.result.dialog?.progress.map(DialogRowScanner.comparable)
                == DialogRowScanner.comparable(page)
        case .focus, .focusNumber, .feedbackMode, .inputText, .notes, .checked:
            break
        }
        guard let dialog = observation.result.dialog, dialog.fingerprint.matches(fingerprint) else { return false }
        let focus = dialog.focus
        switch self {
        case .focus(let ordinal):
            return focus.focusedOrdinal == ordinal
        case .focusNumber(let number):
            return focus.focusedOrdinal.flatMap(dialog.option)?.number == number
        case .feedbackMode(let ordinal):
            return focus.focusedOrdinal == ordinal && focus.feedbackOrdinal == ordinal && focus.inputText == nil
        case .inputText(let text):
            guard let shown = focus.inputText else { return false }
            // Wrapping moves spaces around, so compare without them. A note
            // too long for its row shows only its start, cut off with `…`.
            let expected = DialogRowScanner.comparable(text)
            if shown.hasSuffix("…"), !expected.hasSuffix("…") {
                let start = DialogRowScanner.comparable(String(shown.dropLast()))
                return !start.isEmpty && expected.hasPrefix(start)
            }
            return DialogRowScanner.comparable(shown) == expected
        case .notes(let text):
            return focus.notesText.map(DialogRowScanner.comparable) == DialogRowScanner.comparable(text)
        case .checked(let ordinals):
            return focus.checked == ordinals
        case .page:
            return false
        }
    }
}

extension ConfirmationRule {
    /// Whether `observation` confirms the keys sent for the dialog with
    /// `fingerprint`.
    func isMet(by observation: DialogObservation, fingerprint: DialogFingerprint) -> Bool {
        let dialogLeft = observation.result.fingerprint?.matches(fingerprint) != true
        switch self {
        case .toolResult(let id):
            return observation.resolvedToolUseIDs.contains(id) || dialogLeft
        case .fingerprintChange:
            return dialogLeft
        case .steps:
            return true
        }
    }
}
