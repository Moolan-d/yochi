// Ported from Heeler (https://github.com/ZingerLittleBee/Heeler), Apache-2.0,
// at b9790d8; trimmed to Claude Code's dialogs.

import Foundation
import Testing

@testable import Companion

@Suite("Dialog action planner")
struct DialogActionPlannerTests {
    private func dialog(_ stem: String) throws -> BlockedDialog {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        return try #require(result.dialog, "\(stem) parsed as \(result)")
    }

    private func plan(_ action: DialogAction, _ stem: String, toolUseID: String? = nil) throws -> DialogActionPlan {
        try DialogActionPlanner.plan(action, for: dialog(stem), toolUseID: toolUseID)
    }

    // MARK: Claude permissions

    @Test("A digit picks a permission option; Esc declines")
    func permissionChoice() throws {
        #expect(
            try plan(.choose(ordinal: 1), "claude-02-c1-bash-blocked")
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .fingerprintChange))
        #expect(
            try plan(.choose(ordinal: 4), "claude-02-c1-bash-blocked", toolUseID: "toolu_01")
                == DialogActionPlan(steps: [.keys(["4"])], confirmation: .toolResult(id: "toolu_01")))
        #expect(
            try plan(.dismiss, "claude-02-c1-bash-blocked")
                == DialogActionPlan(steps: [.keys(["esc"])], confirmation: .fingerprintChange))
        #expect(try plan(.choose(ordinal: 2), "claude-22-c7-edit").steps == [.keys(["2"])])
        #expect(try plan(.choose(ordinal: 3), "claude-24-c8-webfetch").steps == [.keys(["3"])])
        #expect(
            try plan(.choose(ordinal: 1), "claude-43-c12-read-file", toolUseID: "toolu_r")
                == DialogActionPlan(steps: [.keys(["1"])], confirmation: .toolResult(id: "toolu_r")))
        #expect(throws: DialogPlanError.noSuchOption(5)) {
            try plan(.choose(ordinal: 5), "claude-02-c1-bash-blocked")
        }
    }

    @Test("A note on No: arrows to the row, Tab, paste, check, Enter")
    func declineWithNote() throws {
        let note = "Do not create it; reply with the single word skipped"
        let tail: [DialogStep] = [.paste(note), .expect(.inputText(note)), .keys(["enter"])]
        #expect(
            try plan(.amend(ordinal: 4, note: note), "claude-02-c1-bash-blocked").steps
                == [
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .keys(["down"]), .expect(.focus(ordinal: 4)), .keys(["tab"]), .expect(.feedbackMode(ordinal: 4)),
                ] + tail)
        // The probe's own path: focus already on No, then the field open.
        #expect(
            try plan(.amend(ordinal: 4, note: note), "claude-03-c1-focus-no").steps
                == [.keys(["tab"]), .expect(.feedbackMode(ordinal: 4))] + tail)
        #expect(try plan(.amend(ordinal: 4, note: note), "claude-04-c1-tab-on-no").steps == tail)
    }

    @Test("A note on Yes")
    func approveWithNote() throws {
        let note = "after it succeeds, reply with the single word created"
        let tail: [DialogStep] = [.paste(note), .expect(.inputText(note)), .keys(["enter"])]
        #expect(
            try plan(.amend(ordinal: 1, note: note), "claude-02-c1-bash-blocked").steps
                == [.keys(["tab"]), .expect(.feedbackMode(ordinal: 1))] + tail)
        #expect(try plan(.amend(ordinal: 1, note: note), "claude-06-c2-tab-on-yes").steps == tail)
        // File dialogs take notes like Bash; inferred from Claude's code, not yet captured.
        #expect(
            try plan(.amend(ordinal: 3, note: note), "claude-22-c7-edit").steps.prefix(4)
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3))])
        // Read file's footer offers Tab to amend too.
        #expect(
            try plan(.amend(ordinal: 2, note: note), "claude-43-c12-read-file").steps
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["tab"]), .expect(.feedbackMode(ordinal: 2))]
                + tail)
    }

    @Test("Notes go only on the Yes and No rows of Bash and file dialogs")
    func noteLimits() throws {
        #expect(throws: DialogPlanError.unsupported("Only the Yes and No rows take a note.")) {
            try plan(.amend(ordinal: 2, note: "note"), "claude-02-c1-bash-blocked")
        }
        #expect(
            throws: DialogPlanError.unsupported("Only Claude's Bash and file dialogs take a note with the answer.")
        ) {
            try plan(.amend(ordinal: 3, note: "note"), "claude-24-c8-webfetch")
        }
        #expect(throws: DialogPlanError.multilineText) {
            try plan(.amend(ordinal: 4, note: "one\ntwo"), "claude-02-c1-bash-blocked")
        }
    }

    @Test(
        "Text typed in the terminal stops every plan but Esc",
        arguments: [
            "claude-05-c1-pasted-feedback", "claude-07-c2-pasted", "claude-13-c4-q2-pasted", "claude-18-c6-pasted",
            "claude-35-c7-phone-pasted-truncated", "claude-37-c7-phone-yes-pasted-wrapped",
        ])
    func typedText(stem: String) throws {
        let dialog = try dialog(stem)
        #expect(dialog.hasTypedText)
        for option in dialog.options {
            #expect(throws: DialogPlanError.textFieldNotEmpty) {
                try DialogActionPlanner.plan(.choose(ordinal: option.ordinal), for: dialog)
            }
        }
        let field = try #require(dialog.options.first { $0.input != nil })
        let typing: DialogAction =
            dialog.kind == .claudeBash
            ? .amend(ordinal: field.ordinal, note: "more") : .respond(ordinal: field.ordinal, text: "more")
        #expect(throws: DialogPlanError.textFieldNotEmpty) { try DialogActionPlanner.plan(typing, for: dialog) }
        #expect(try DialogActionPlanner.plan(.dismiss, for: dialog).steps == [.keys(["esc"])])
    }

    @Test("Digits step off a focused empty field first")
    func leaveField() throws {
        // No's note field is open: up to option 3, then the digit.
        #expect(
            try plan(.choose(ordinal: 1), "claude-04-c1-tab-on-no").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 3)), .keys(["1"])])
        // Yes's note field is open on the first row: down instead.
        #expect(
            try plan(.choose(ordinal: 4), "claude-06-c2-tab-on-yes").steps
                == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["4"])])
        #expect(
            try plan(.choose(ordinal: 2), "claude-17-c6-digit3").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 2)), .keys(["2"])])
        #expect(
            try plan(.choose(ordinal: 1), "claude-12-c4-q2-digit3").steps
                == [.keys(["up"]), .expect(.focus(ordinal: 2)), .keys(["1"]), .expect(.page("Review your answers"))])
    }

    // MARK: Claude plans and questions

    @Test("Plan: approve by digit, send back or approve with a note")
    func planActions() throws {
        let stem = "claude-16-c6-exitplan-1"
        let note = "Name the file q.txt instead"
        #expect(try plan(.choose(ordinal: 2), stem).steps == [.keys(["2"])])
        #expect(throws: DialogPlanError.needsText) { try plan(.choose(ordinal: 3), stem) }
        #expect(
            try plan(.respond(ordinal: 3, text: note), stem).steps
                == [
                    .keys(["3"]), .expect(.focus(ordinal: 3)), .paste(note), .expect(.inputText(note)),
                    .keys(["enter"]),
                ])
        #expect(
            try plan(.approvePlan(note: note), stem).steps
                == [
                    .keys(["3"]), .expect(.focus(ordinal: 3)), .paste(note), .expect(.inputText(note)),
                    .keys(["shift+tab"]),
                ])
        // With the row focused already, no digit.
        #expect(
            try plan(.respond(ordinal: 3, text: note), "claude-17-c6-digit3").steps
                == [.paste(note), .expect(.inputText(note)), .keys(["enter"])])
        #expect(throws: DialogPlanError.unsupported("Option 1 is not a text field.")) {
            try plan(.respond(ordinal: 1, text: note), stem)
        }
        #expect(throws: DialogPlanError.unsupported("This dialog does not offer approving with feedback.")) {
            try plan(.approvePlan(note: note), "claude-02-c1-bash-blocked")
        }
    }

    @Test("Multi-select: a checked digit each, arrows to Next, Enter, the next page")
    func multiSelect() throws {
        // The probe pressed `1`, `3`, `down` four times and `enter`.
        #expect(
            try plan(.submitSelection([1, 3]), "claude-08-c4-auq-q1").steps
                == [
                    .keys(["1"]), .expect(.checked([1])), .keys(["3"]), .expect(.checked([1, 3])),
                    .keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3)),
                    .keys(["down"]), .expect(.focus(ordinal: 4)), .keys(["down"]), .expect(.focus(ordinal: 5)),
                    .keys(["enter"]), .expect(.page("Size")),
                ])
        #expect(
            try plan(.submitSelection([1, 3]), "claude-09-c4-toggled").keys
                == ["down", "down", "down", "down", "enter"])
        #expect(
            Array(try plan(.submitSelection([2]), "claude-09-c4-toggled").steps.prefix(6))
                == [
                    .keys(["1"]), .expect(.checked([3])), .keys(["2"]), .expect(.checked([2, 3])), .keys(["3"]),
                    .expect(.checked([2])),
                ])
        #expect(
            try plan(.submitSelection([1, 3]), "claude-10-c4-focus-next").steps
                == [.keys(["enter"]), .expect(.page("Size"))])
        #expect(
            try plan(.choose(ordinal: 5), "claude-10-c4-focus-next").steps
                == [.keys(["enter"]), .expect(.page("Size"))])
        // Chat about this keeps its own number.
        #expect(try plan(.choose(ordinal: 6), "claude-08-c4-auq-q1").steps == [.keys(["5"])])
    }

    @Test("Multi-select refusals")
    func multiSelectLimits() throws {
        let stem = "claude-08-c4-auq-q1"
        #expect(throws: DialogPlanError.unsupported("A multi-select question takes its answers as a set.")) {
            try plan(.choose(ordinal: 1), stem)
        }
        #expect(throws: DialogPlanError.emptySelection) { try plan(.submitSelection([]), stem) }
        #expect(throws: DialogPlanError.unsupported("Option 4 is not an answer Heeler can check.")) {
            try plan(.submitSelection([4]), stem)
        }
        #expect(throws: DialogPlanError.noSuchOption(9)) { try plan(.submitSelection([9]), stem) }
        #expect(throws: DialogPlanError.unsupported("Heeler does not type into a multi-select question's Other row.")) {
            try plan(.respond(ordinal: 4, text: "Teal"), stem)
        }
        #expect(throws: DialogPlanError.unsupported("Only a multi-select question takes a set of answers.")) {
            try plan(.submitSelection([1]), "claude-11-c4-q2")
        }
    }

    @Test("Single select: a digit answers and turns the page; Other takes text")
    func singleSelect() throws {
        let stem = "claude-11-c4-q2"
        let review: DialogStep = .expect(.page("Review your answers"))
        #expect(try plan(.choose(ordinal: 2), stem).steps == [.keys(["2"]), review])
        #expect(try plan(.choose(ordinal: 4), stem).steps == [.keys(["4"])])
        #expect(throws: DialogPlanError.needsText) { try plan(.choose(ordinal: 3), stem) }
        #expect(
            try plan(.respond(ordinal: 3, text: "Medium"), stem).steps
                == [
                    .keys(["3"]), .expect(.focus(ordinal: 3)), .paste("Medium"), .expect(.inputText("Medium")),
                    .keys(["enter"]), review,
                ])
        #expect(
            try plan(.respond(ordinal: 3, text: "Medium"), "claude-12-c4-q2-digit3").steps
                == [.paste("Medium"), .expect(.inputText("Medium")), .keys(["enter"]), review])
    }

    @Test("Review page: a digit submits or cancels")
    func reviewPage() throws {
        #expect(try plan(.choose(ordinal: 1), "claude-14-c4-review").steps == [.keys(["1"])])
        #expect(try plan(.choose(ordinal: 2), "claude-14-c4-review").steps == [.keys(["2"])])
    }

    @Test("Trust: arrows and Enter, since the options have no numbers")
    func trust() throws {
        let stem = "claude-00-trust"
        #expect(
            try plan(.choose(ordinal: 2), stem)
                == DialogActionPlan(
                    steps: [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"])],
                    confirmation: .fingerprintChange))
        #expect(try plan(.choose(ordinal: 1), stem).steps == [.keys(["enter"])])
        #expect(try plan(.dismiss, stem).steps == [.keys(["esc"])])
    }

    // MARK: Generic card, text and keys

    @Test("The generic card's buttons press the digits it lists")
    func genericCard() throws {
        let unknown = try #require(
            ClaudeDialogParser.parse(ClaudeDialogRows.screen(title: "Tool use", options: ["Yes", "No"])).excerpt)
        #expect(
            try DialogActionPlanner.plan(number: 2, for: unknown, program: .claude)
                == DialogActionPlan(steps: [.keys(["2"])], confirmation: .fingerprintChange))
        #expect(throws: DialogPlanError.noSuchOption(3)) {
            try DialogActionPlanner.plan(number: 3, for: unknown, program: .claude)
        }

        // A reverse-video cursor means a field has focus.
        let withCursor = try #require(
            ClaudeDialogParser.parse(
                ClaudeDialogRows.screen(
                    title: "Tool use", options: ["Yes", "No, " + SGR.reverse + "a" + SGR.reset + "nd tell Claude"],
                    focused: 2)
            ).excerpt)
        #expect(
            throws: DialogPlanError.unsupported(
                "A text field in the dialog has the cursor, so a digit would be typed into it.")
        ) {
            try DialogActionPlanner.plan(number: 1, for: withCursor, program: .claude)
        }
    }

    @Test("Field text is one trimmed line without control characters")
    func fieldText() throws {
        #expect(try DialogActionPlanner.fieldText("  Use q.txt  ") == "Use q.txt")
        #expect(throws: DialogPlanError.emptyText) { try DialogActionPlanner.fieldText("   ") }
        #expect(throws: DialogPlanError.multilineText) { try DialogActionPlanner.fieldText("one\ntwo") }
        #expect(throws: DialogPlanError.multilineText) { try DialogActionPlanner.fieldText("one\r\ntwo") }
        #expect(throws: DialogPlanError.multilineText) { try DialogActionPlanner.fieldText("one\u{2028}two") }
        #expect(throws: DialogPlanError.unsafeText) { try DialogActionPlanner.fieldText("one\ttwo") }
        #expect(throws: DialogPlanError.unsafeText) { try DialogActionPlanner.fieldText("one\u{1B}[Atwo") }
    }

    @Test("Moves send one checked down or up arrow per row and need a focused row")
    func verticalMovesAreUnchanged() throws {
        let dialog = try dialog("claude-02-c1-bash-blocked")
        var down = StepBuilder(dialog: dialog)
        try down.move(to: 3)
        #expect(
            down.steps == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["down"]), .expect(.focus(ordinal: 3))])
        #expect(down.focus == 3)
        try down.move(to: 3)
        #expect(down.steps.count == 4)

        var up = StepBuilder(dialog: try self.dialog("claude-03-c1-focus-no"))
        try up.move(to: 3)
        #expect(up.steps == [.keys(["up"]), .expect(.focus(ordinal: 3))])

        let unfocused = BlockedDialog(
            kind: dialog.kind, title: dialog.title, sourceSuffix: dialog.sourceSuffix,
            positionLabel: dialog.positionLabel, body: dialog.body, progress: dialog.progress, options: dialog.options,
            rows: dialog.rows, fingerprint: dialog.fingerprint, focus: DialogFocusState(), subject: dialog.subject)
        #expect(throws: DialogPlanError.noFocus) {
            var builder = StepBuilder(dialog: unfocused)
            try builder.move(to: 2)
        }
    }

    /// The key names plans may send, all of which core's `terminal.keys` takes.
    private static let coreKeys: Set<String> = Set(["up", "down", "enter", "esc", "tab", "shift+tab"] + (1...9).map(String.init))

    @Test(
        "Plans for every captured dialog use keys the Gateway takes and check after each arrow and paste",
        arguments: ScreenFixture.all)
    func planShapes(stem: String) throws {
        let result = BlockedDialogParser.parse(try ScreenFixture.screen(stem), program: ScreenFixture.program(stem))
        guard let dialog = result.dialog else { return }
        var actions: [DialogAction] = [
            .dismiss, .approvePlan(note: "note"),
            .submitSelection(Set(dialog.options.filter { $0.role == .answer }.map(\.ordinal))),
        ]
        for option in dialog.options {
            actions += [
                .choose(ordinal: option.ordinal), .amend(ordinal: option.ordinal, note: "note"),
                .respond(ordinal: option.ordinal, text: "note"),
            ]
        }
        var planned = 0
        for action in actions {
            guard let plan = try? DialogActionPlanner.plan(action, for: dialog) else { continue }
            planned += 1
            for key in plan.keys {
                #expect(Self.coreKeys.contains(key), "\(stem) \(action): \(key)")
            }
            for (index, step) in plan.steps.enumerated() {
                let next = plan.steps.indices.contains(index + 1) ? plan.steps[index + 1] : nil
                switch step {
                case .keys(["up"]), .keys(["down"]):
                    let checksFocus = if case .expect(.focus)? = next { true } else { false }
                    #expect(checksFocus, "\(stem) \(action): an arrow without a focus check")
                case .paste:
                    let checksText =
                        switch next {
                        case .expect(.inputText)?, .expect(.notes)?: true
                        default: false
                        }
                    #expect(checksText, "\(stem) \(action): a paste without a check")
                default:
                    break
                }
            }
        }
        #expect(planned > 0 || dialog.hasTypedText, "\(stem): no action planned")
    }
}

@Suite("Dialog expectations and confirmations")
struct DialogExpectationTests {
    private func observe(_ stem: String, resolved: Set<String> = []) throws -> DialogObservation {
        DialogObservation(
            screen: try ScreenFixture.screen(stem), program: ScreenFixture.program(stem), resolvedToolUseIDs: resolved)
    }

    private func fingerprint(_ stem: String) throws -> DialogFingerprint {
        try #require(try observe(stem).result.dialog?.fingerprint)
    }

    /// Whether capture `stem` shows `expectation` for the dialog last read
    /// with `fingerprint`.
    private func meets(
        _ expectation: DialogExpectation, _ stem: String, _ fingerprint: DialogFingerprint
    ) throws -> Bool {
        expectation.isMet(by: try observe(stem), fingerprint: fingerprint)
    }

    private func confirms(
        _ rule: ConfirmationRule, _ stem: String, _ fingerprint: DialogFingerprint, resolved: Set<String> = []
    ) throws -> Bool {
        rule.isMet(by: try observe(stem, resolved: resolved), fingerprint: fingerprint)
    }

    @Test("Each step of the probe's note on No meets its check")
    func noteOnNo() throws {
        let bash = try fingerprint("claude-02-c1-bash-blocked")
        let note = "Do not create it; reply with the single word skipped"
        #expect(try meets(.focus(ordinal: 4), "claude-03-c1-focus-no", bash))
        #expect(try !meets(.focus(ordinal: 4), "claude-02-c1-bash-blocked", bash))
        #expect(try meets(.feedbackMode(ordinal: 4), "claude-04-c1-tab-on-no", bash))
        #expect(try !meets(.feedbackMode(ordinal: 4), "claude-03-c1-focus-no", bash))
        #expect(try !meets(.feedbackMode(ordinal: 4), "claude-05-c1-pasted-feedback", bash))
        #expect(try meets(.inputText(note), "claude-05-c1-pasted-feedback", bash))
        #expect(try !meets(.inputText(note), "claude-04-c1-tab-on-no", bash))
        #expect(try !meets(.inputText("Do not create it"), "claude-05-c1-pasted-feedback", bash))
    }

    @Test("A note cut off at the phone's width still meets its check")
    func truncatedNoteOnNo() throws {
        let bash = try fingerprint("claude-32-c7-phone-bash-blocked")
        let note = "Do not create it; reply with the single word skipped"
        #expect(try meets(.focus(ordinal: 4), "claude-33-c7-phone-focus-no", bash))
        #expect(try meets(.feedbackMode(ordinal: 4), "claude-34-c7-phone-tab-on-no", bash))
        #expect(try !meets(.feedbackMode(ordinal: 4), "claude-35-c7-phone-pasted-truncated", bash))
        #expect(try meets(.inputText(note), "claude-35-c7-phone-pasted-truncated", bash))
        let other = "Do not create it; reply with one word"
        #expect(try !meets(.inputText(other), "claude-35-c7-phone-pasted-truncated", bash))
        #expect(try !meets(.inputText("Do not"), "claude-35-c7-phone-pasted-truncated", bash))
        let dialog = try #require(try observe("claude-35-c7-phone-pasted-truncated").result.dialog)
        #expect(dialog.option(4)?.label == "No")
        #expect(dialog.focus.feedbackOrdinal == 4)
    }

    @Test("An empty note drawn without its cursor cell still reads as the placeholder")
    func emptyNoteWithoutTheCursor() throws {
        let bash = try fingerprint("claude-32-c7-phone-bash-blocked")
        // claude-34 with the cursor cell drawn dim like the rest.
        let text = try ScreenFixture.text("claude-34-c7-phone-tab-on-no")
        let cursorless = text.replacingOccurrences(of: "\u{1B}[7ma", with: "\u{1B}[2ma")
        try #require(cursorless != text)
        let observation = DialogObservation(
            screen: ANSIScreenDecoder.decode(cursorless), program: .claude)
        #expect(DialogExpectation.feedbackMode(ordinal: 4).isMet(by: observation, fingerprint: bash))
    }

    @Test("A note wrapped at the phone's width, with the cursor on its last row, meets its check")
    func wrappedNoteOnYes() throws {
        let bash = try fingerprint("claude-36-c7-phone-yes-blocked")
        let note = "after it succeeds, reply with the single word created"
        #expect(try meets(.focus(ordinal: 1), "claude-36-c7-phone-yes-blocked", bash))
        #expect(try meets(.inputText(note), "claude-37-c7-phone-yes-pasted-wrapped", bash))
        #expect(try !meets(.inputText("after it succeeds"), "claude-37-c7-phone-yes-pasted-wrapped", bash))
        let dialog = try #require(try observe("claude-37-c7-phone-yes-pasted-wrapped").result.dialog)
        #expect(dialog.option(1)?.label == "Yes")
        #expect(dialog.focus.feedbackOrdinal == 1)
        #expect(dialog.options.count == 4)
    }

    @Test("A check about the same dialog fails once the dialog changed")
    func changedDialog() throws {
        let first = try fingerprint("claude-30-par-first")
        #expect(try meets(.focus(ordinal: 1), "claude-30-par-first", first))
        // The next request also has focus on 1, but asks about another command.
        #expect(try !meets(.focus(ordinal: 1), "claude-31-par-second", first))
    }

    @Test("Checks and pages")
    func otherChecks() throws {
        let colors = try fingerprint("claude-08-c4-auq-q1")
        #expect(try meets(.checked([1, 3]), "claude-09-c4-toggled", colors))
        #expect(try !meets(.checked([1]), "claude-09-c4-toggled", colors))
        #expect(try meets(.focus(ordinal: 5), "claude-10-c4-focus-next", colors))
        #expect(try meets(.page("Size"), "claude-11-c4-q2", colors))
        #expect(try !meets(.page("Size"), "claude-10-c4-focus-next", colors))
        #expect(try meets(.page("Review your answers"), "claude-14-c4-review", colors))
    }

    @Test("Claude confirms by the tool result or by the dialog leaving")
    func claudeConfirmation() throws {
        let bash = try fingerprint("claude-02-c1-bash-blocked")
        let rule = ConfirmationRule.toolResult(id: "toolu_01")
        #expect(try !confirms(rule, "claude-03-c1-focus-no", bash))
        #expect(try confirms(rule, "claude-03-c1-focus-no", bash, resolved: ["toolu_01"]))
        #expect(try confirms(rule, "claude-29-c3-after-immediate", bash))
        #expect(try !confirms(.fingerprintChange, "claude-03-c1-focus-no", bash))
        #expect(try confirms(.fingerprintChange, "claude-31-par-second", fingerprint("claude-30-par-first")))
    }
}
