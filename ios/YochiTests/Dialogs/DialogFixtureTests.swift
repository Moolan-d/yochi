import Foundation
import Testing

@testable import Yochi

/// What a parse result puts on the phone, as stable JSON: the dialog's kind,
/// text, options, focus and keys, or the generic card's lines. Screen rows'
/// styling, row ranges and fingerprints are left out, so a decoder or
/// fingerprint change that leaves the cards alone does not touch a snapshot.
/// Nil and empty values are dropped to keep the files short.
private enum DialogSnapshot {
    static func text(for result: DialogParseResult) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object(result), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func object(_ result: DialogParseResult) -> [String: Any] {
        switch result {
        case .dialog(let dialog): ["dialog": object(dialog)]
        case .unrecognized(let excerpt): ["unrecognized": object(excerpt)]
        case .none: ["none": true]
        }
    }

    private static func object(_ dialog: BlockedDialog) -> [String: Any] {
        compact([
            "kind": dialog.kind.rawValue,
            "title": dialog.title,
            "sourceSuffix": dialog.sourceSuffix,
            "positionLabel": dialog.positionLabel,
            "body": dialog.body,
            "progress": dialog.progress,
            "options": dialog.options.map(object),
            "focus": compact([
                "focusedOrdinal": dialog.focus.focusedOrdinal,
                "checked": dialog.focus.checked.sorted(),
                "inputText": dialog.focus.inputText,
                "feedbackOrdinal": dialog.focus.feedbackOrdinal,
            ]),
            "subject": object(dialog.subject),
            "note": dialog.note,
            "picker": dialog.picker.map { picker in
                compact([
                    "firstNumber": picker.firstNumber,
                    "hiddenBelow": picker.hiddenBelow,
                    "moreBelow": picker.moreBelow ? true : nil,
                    "enterAction": picker.enterAction,
                    "keys": picker.keys.map(object),
                ])
            },
        ])
    }

    private static func object(_ option: DialogOption) -> [String: Any] {
        var input: [String: Any]?
        switch option.input {
        case .placeholder(let hint): input = ["placeholder": hint]
        case .text(let text): input = ["text": text]
        case nil: input = nil
        }
        return compact([
            "ordinal": option.ordinal,
            "number": option.number,
            "label": option.label,
            "detail": option.detail,
            "shortcut": option.shortcut,
            "role": option.role.rawValue,
            "focused": option.isFocused ? true : nil,
            "checked": option.isChecked,
            "input": input,
        ])
    }

    private static func object(_ subject: DialogSubject) -> [String: Any] {
        compact([
            "command": subject.command,
            "commandDescription": subject.commandDescription,
            "filePath": subject.filePath,
            "url": subject.url,
            "host": subject.host,
            "prompt": subject.prompt,
            "question": subject.question,
            "questionHeaders": subject.questionHeaders,
            "reviewAnswers": subject.reviewAnswers.map { ["question": $0.question, "answer": $0.answer] },
            "planFilePath": subject.planFilePath,
            "workspacePath": subject.workspacePath,
        ])
    }

    private static func object(_ excerpt: GenericDialogExcerpt) -> [String: Any] {
        compact([
            "reason": excerpt.reason,
            "lines": excerpt.displayLines ?? excerpt.rows.map { $0.text.replacing(/\s+$/, with: "") },
            "numbered": excerpt.numbered.sorted { $0.key < $1.key }.map { ["number": $0.key, "label": $0.value] },
            "keys": excerpt.keys.map(object),
        ])
    }

    private static func object(_ hint: DialogKeyHint) -> [String: Any] {
        ["key": hint.key, "action": hint.action]
    }

    /// Drops nil values and empty strings, lists and objects.
    private static func compact(_ fields: [String: Any?]) -> [String: Any] {
        fields.compactMapValues { value -> Any? in
            switch value {
            case nil: nil
            case let string as String where string.isEmpty: nil
            case let list as [Any] where list.isEmpty: nil
            case let object as [String: Any] where object.isEmpty: nil
            case let value?: value
            }
        }
    }
}

@Suite("Captured Claude screens")
struct DialogFixtureTests {
    @Test("Every capture is declared in ScreenFixture")
    func inventory() {
        #expect(ScreenFixture.captured == ScreenFixture.claude.sorted())
    }

    /// Regenerate after an intentional parser change with
    /// `scripts/record-dialog-snapshots.sh` from `ios/`.
    /// Review the resulting JSON diff before committing it.
    @Test("Every capture matches its recorded parse result", arguments: ScreenFixture.claude)
    func snapshot(stem: String) throws {
        let actual = try DialogSnapshot.text(for: ClaudeDialogParser.parse(try ScreenFixture.screen(stem)))
        let path = "snapshots/claude/\(stem).json"
        if FileManager.default.fileExists(atPath: sourceSnapshotDirectory.appending(path: ".record").path) {
            let url = sourceSnapshotDirectory.appending(path: "claude/\(stem).json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let fixtures = try #require(ScreenFixture.fixtures)
        let expected = try String(contentsOf: fixtures.appending(path: path), encoding: .utf8)
        #expect(actual == expected, "\(stem) changed; review the parser diff and record new snapshots intentionally")
    }

    private var sourceSnapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/snapshots")
    }
}
