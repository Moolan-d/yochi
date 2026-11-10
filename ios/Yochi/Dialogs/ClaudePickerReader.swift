import Foundation

/// Reads the list a Claude Code slash command opens in place of its input
/// box, such as `/model`: a `▔` edge, a bold title, gray description rows,
/// numbered rows with `❯` on the focused one, and a footer of key hints
/// that ends `Esc to cancel`. A long list shows a window of its rows: `↑`
/// on the first row shown when more lie above, `↓` or `… +N` below.
///
/// Permission, question and plan dialogs draw `─` rules inside, so a screen
/// with one is left to the other readers.
enum ClaudePickerReader {
    /// Nil when the screen is not a picker.
    static func read(_ screen: ANSIScreen) -> DialogParseResult? {
        let rows = screen.rows
        let fullWidth = max(8, screen.columns - 4)
        guard let footerIndex = rows.lastIndex(where: { !$0.isBlank }) else { return nil }
        let hints = hints(in: rows[footerIndex].trimmedText)
        guard hints.contains(where: { $0.key.lowercased() == "esc" && $0.action.lowercased() == "cancel" }),
            let edge = (max(0, footerIndex - 80)..<footerIndex).reversed().first(where: {
                // The edge can carry the effort level: `▔▔ ● high · /effort ▔`.
                DialogRowScanner.isLabeledRule(rows[$0], of: "▔", minimumWidth: fullWidth)
            })
        else { return nil }
        let inside = rows[(edge + 1)..<footerIndex]
        guard
            !inside.contains(where: { row in
                ["─", "╌"].contains { DialogRowScanner.isLabeledRule(row, of: $0, minimumWidth: fullWidth / 2) }
            }),
            let titleIndex = inside.firstIndex(where: { !$0.isBlank }),
            rows[titleIndex].visibleRuns.allSatisfy(\.style.isBold)
        else { return nil }

        func unrecognized(_ reason: String) -> DialogParseResult {
            .unrecognized(
                ClaudeExcerpt.make(
                    rows: Array(rows[edge...footerIndex]), footerRows: [footerIndex], numbered: [:], reason: reason))
        }

        var description: [String] = []
        var after: [String] = []
        var drafts: [Draft] = []
        var inactive: ScreenColor?
        var hiddenBelow: Int?
        var listEnded = false
        for index in (titleIndex + 1)..<footerIndex {
            let row = rows[index]
            if !listEnded, let numbered = numberedRow(row) {
                guard drafts.last.map({ numbered.number == $0.number + 1 }) ?? true,
                    inactive == nil || numbered.color == inactive
                else { return unrecognized("The picker's rows are not numbered in order.") }
                inactive = numbered.color
                drafts.append(read(row, numbered, inactive: numbered.color))
                continue
            }
            if row.isBlank {
                if !drafts.isEmpty { listEnded = true }
                continue
            }
            if drafts.isEmpty {
                description.append(row.trimmedText)
            } else if !listEnded, let count = hiddenCount(row.trimmedText) {
                hiddenBelow = count
                listEnded = true
            } else if !listEnded, var last = drafts.popLast(), let indent = row.indent, indent >= last.labelColumn {
                last.append(DialogRowScanner.runs(of: row, from: last.labelColumn), inactive: inactive)
                drafts.append(last)
            } else {
                listEnded = true
                after.append(row.trimmedText)
            }
        }
        guard !drafts.isEmpty else { return nil }
        guard drafts.filter(\.isFocused).count == 1 else { return unrecognized("No row of the picker shows focus.") }

        let title = rows[titleIndex].trimmedText
        let options = drafts.enumerated().map { index, draft in
            DialogOption(
                ordinal: index + 1, number: draft.number, label: draft.label,
                detail: draft.detail.isEmpty ? nil : draft.detail, role: .answer, isFocused: draft.isFocused,
                isChecked: draft.isCurrent ? true : nil)
        }
        // A letter would go into a search field that has the cursor.
        let typing = inside.contains { $0.runs.contains(where: \.style.isReverse) }
        let picker = DialogPicker(
            hiddenBelow: hiddenBelow, moreBelow: (hiddenBelow ?? 0) > 0 || drafts.last?.marker == "↓",
            enterAction: hints.first { $0.key.lowercased() == "enter" }?.action,
            keys: typing ? [] : hints.compactMap { hint in
                guard hint.key.count == 1, let letter = hint.key.first, letter.isASCII, letter.isLetter else {
                    return nil
                }
                return DialogKeyHint(key: hint.key.lowercased(), action: hint.action)
            },
            firstNumber: drafts.first?.number)
        // Rows under the list can follow the focus (a model's effort), so
        // only the title and description name the picker.
        let fingerprint = DialogFingerprint(
            program: .claude, kind: .claudePicker, title: title, sourceSuffix: nil, body: description, progress: nil,
            options: [])
        return .dialog(
            BlockedDialog(
                kind: .claudePicker, title: title, sourceSuffix: nil, positionLabel: nil, body: description + after,
                progress: nil, options: options, rows: edge..<(footerIndex + 1), fingerprint: fingerprint,
                focus: DialogFocusState(focusedOrdinal: options.first(where: \.isFocused)?.ordinal),
                subject: DialogSubject(), picker: picker))
    }

    /// `Enter to set as default · s to use this session only · Esc to cancel`.
    static func hints(in text: String) -> [DialogKeyHint] {
        text.components(separatedBy: " · ").compactMap { part in
            let part = part.trimmingCharacters(in: .whitespaces)
            guard let range = part.range(of: " to ") else { return nil }
            return DialogKeyHint(key: String(part[..<range.lowerBound]), action: String(part[range.upperBound...]))
        }
    }

    /// `… +8 models` under a list cut short.
    private static func hiddenCount(_ text: String) -> Int? {
        guard text.hasPrefix("…") else { return nil }
        let rest = text.dropFirst().drop(while: ScreenRow.isBlank)
        guard rest.first == "+" else { return nil }
        return Int(rest.dropFirst().prefix(while: \.isNumber))
    }

    private struct NumberedRow {
        let number: Int
        /// `❯` on the focused row, `↑` or `↓` where more rows lie.
        let marker: Character?
        let labelColumn: Int
        let color: ScreenColor?
    }

    /// `❯ 15. Label`, `↑ 6.  Label` or `7.  Label`, the number in a color.
    private static func numberedRow(_ row: ScreenRow) -> NumberedRow? {
        let characters = Array(row.text)
        var index = 0
        var column = 0
        func advance() {
            column += TerminalCellWidth.width(of: characters[index])
            index += 1
        }
        while index < characters.count, ScreenRow.isBlank(characters[index]) { advance() }
        var marker: Character?
        if index + 1 < characters.count, ["❯", "↑", "↓"].contains(characters[index]),
            ScreenRow.isBlank(characters[index + 1])
        {
            marker = characters[index]
            advance()
            while index < characters.count, ScreenRow.isBlank(characters[index]) { advance() }
        }
        let numberColumn = column
        var digits = ""
        while index < characters.count, digits.count < 3, characters[index].isASCII, characters[index].isNumber {
            digits.append(characters[index])
            advance()
        }
        guard let number = Int(digits), number > 0, index + 1 < characters.count, characters[index] == ".",
            ScreenRow.isBlank(characters[index + 1])
        else { return nil }
        advance()
        while index < characters.count, ScreenRow.isBlank(characters[index]) { advance() }
        guard let color = row.run(at: numberColumn)?.style.foreground else { return nil }
        return NumberedRow(number: number, marker: marker, labelColumn: column, color: color)
    }

    private struct Draft {
        let number: Int
        let marker: Character?
        let labelColumn: Int
        var label = ""
        var detail = ""
        var isCurrent = false

        var isFocused: Bool { marker == "❯" }

        /// The label is the text up to the first gray run; the gray rest,
        /// such as `via magpie`, is the detail.
        mutating func append(_ runs: [ScreenRun], inactive: ScreenColor?) {
            var label = ""
            var detail = ""
            for run in runs {
                if detail.isEmpty, DialogRowScanner.isBlank(run) || run.style.foreground != inactive
                    || label.allSatisfy(ScreenRow.isBlank)
                {
                    label += run.text
                } else {
                    detail += run.text
                }
            }
            var text = ScreenRow.normalizedSpaces(label).trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("✔") {
                text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
                isCurrent = true
            }
            self.label = [self.label, text].filter { !$0.isEmpty }.joined(separator: " ")
            let more = ScreenRow.normalizedSpaces(detail).trimmingCharacters(in: .whitespaces)
            self.detail = [self.detail, more].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private static func read(_ row: ScreenRow, _ numbered: NumberedRow, inactive: ScreenColor?) -> Draft {
        var draft = Draft(number: numbered.number, marker: numbered.marker, labelColumn: numbered.labelColumn)
        draft.append(DialogRowScanner.runs(of: row, from: numbered.labelColumn), inactive: inactive)
        return draft
    }
}
