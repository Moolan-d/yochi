import Foundation
import Testing

@testable import Yochi

private final class DialogFixtureBundleLocator {}

/// Turns a parse result into stable JSON without depending on Swift's
/// reflection order for dictionaries and sets. This is test-only code: the
/// snapshots are a reviewable description of what the app would put on a card.
private enum DialogSnapshot {
    static func text(for result: DialogParseResult) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: normalize(result), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func normalize(_ value: Any) -> Any {
        if let range = value as? Range<Int> {
            return ["lowerBound": range.lowerBound, "upperBound": range.upperBound]
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return normalize(child.value)
        }
        switch mirror.displayStyle {
        case .collection:
            return mirror.children.map { normalize($0.value) }
        case .set:
            return mirror.children.map { normalize($0.value) }.sorted { canonical($0) < canonical($1) }
        case .dictionary:
            return mirror.children.map { child in
                let pair = Array(Mirror(reflecting: child.value).children)
                return ["key": normalize(pair[0].value), "value": normalize(pair[1].value)]
            }.sorted { canonical($0) < canonical($1) }
        case .enum:
            let description = String(describing: value)
            let name = description.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? description
            guard !mirror.children.isEmpty else { return name }
            return ["case": name, "associated": mirror.children.map { normalize($0.value) }]
        case .struct:
            var object: [String: Any] = [:]
            for child in mirror.children {
                object[child.label ?? "_"] = normalize(child.value)
            }
            return object
        default:
            switch value {
            case let value as String: return value
            case let value as Bool: return value
            case let value as Int: return value
            case let value as Int8: return Int(value)
            case let value as Int16: return Int(value)
            case let value as Int32: return Int(value)
            case let value as Int64: return Int(value)
            case let value as UInt: return Int(value)
            case let value as UInt8: return Int(value)
            case let value as UInt16: return Int(value)
            case let value as UInt32: return Int(value)
            case let value as UInt64: return Int(value)
            case let value as Double: return value
            case let value as Float: return Double(value)
            default: return String(reflecting: value)
            }
        }
    }

    private static func canonical(_ value: Any) -> String {
        // Wrapping also makes this valid for a scalar set element.
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .fragmentsAllowed]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
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
            let url = sourceSnapshotURL(stem)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let fixtures = try #require(Bundle(for: DialogFixtureBundleLocator.self).url(forResource: "Fixtures", withExtension: nil))
        let expected = try String(contentsOf: fixtures.appending(path: path), encoding: .utf8)
        #expect(actual == expected, "\(stem) changed; review the parser diff and record new snapshots intentionally")
    }

    private var sourceSnapshotDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/snapshots")
    }

    private func sourceSnapshotURL(_ stem: String) -> URL {
        sourceSnapshotDirectory.appending(path: "claude/\(stem).json")
    }
}
