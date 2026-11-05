import Foundation

/// The session's Changes: what its git repository has against HEAD, untracked files included.
struct ChangeList: Decodable, Equatable {
    /// The repository root's name.
    let repo: String
    let files: [FileChange]
    /// More than the Gateway lists.
    let truncated: Bool

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var deleted: Int { files.reduce(0) { $0 + ($1.deleted ?? 0) } }

    private enum CodingKeys: String, CodingKey { case repo, files, truncated }

    init(repo: String, files: [FileChange], truncated: Bool = false) {
        self.repo = repo
        self.files = files
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        files = try c.decode([FileChange].self, forKey: .files)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

struct FileChange: Decodable, Hashable, Identifiable {
    enum Status: String {
        case modified = "M", added = "A", deleted = "D", renamed = "R"
        case typeChanged = "T", unmerged = "U", untracked = "?"

        var title: String {
            switch self {
            case .modified: String(localized: "Modified")
            case .added: String(localized: "Added")
            case .deleted: String(localized: "Deleted")
            case .renamed: String(localized: "Renamed")
            case .typeChanged: String(localized: "Type changed")
            case .unmerged: String(localized: "Conflict")
            case .untracked: String(localized: "Untracked")
            }
        }
    }

    /// From the repository root.
    let path: String
    /// Where a renamed file came from.
    let oldPath: String?
    let status: Status
    /// Nil for binary files.
    let added: Int?
    let deleted: Int?

    var id: String { path }
    var isBinary: Bool { added == nil && deleted == nil }

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// The directory, or 「根目录」.
    var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return String(localized: "root") }
        return String(path[..<slash])
    }

    /// What the row says under the name.
    var detail: String {
        switch status {
        case .added: String(localized: "\(directory) · new file")
        case .untracked: String(localized: "\(directory) · untracked")
        case .renamed: String(localized: "\(directory) · renamed from \(oldPath.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "")")
        default: directory
        }
    }

    var accessibilityLabel: String {
        var parts = [name, status.title]
        if isBinary {
            parts.append(String(localized: "binary file"))
        } else {
            if let added, added > 0 { parts.append(String(localized: "\(added) lines added")) }
            if let deleted, deleted > 0 { parts.append(String(localized: "\(deleted) lines deleted")) }
        }
        return parts.joined(separator: String(localized: "detail.separator", defaultValue: ", "))
    }

    init(path: String, oldPath: String? = nil, status: Status, added: Int?, deleted: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey { case path, oldPath = "old_path", status, added, deleted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        oldPath = try c.decodeIfPresent(String.self, forKey: .oldPath)
        status = Status(rawValue: try c.decode(String.self, forKey: .status)) ?? .modified
        added = try c.decodeIfPresent(Int.self, forKey: .added)
        deleted = try c.decodeIfPresent(Int.self, forKey: .deleted)
    }
}

struct ChangesError: Error, Equatable {
    let kind: String
    let message: String
}

/// One file's unified diff, as the Gateway sent it.
struct FileDiff: Equatable {
    let patch: String
    /// Cut at the Gateway's limit.
    let truncated: Bool
}

/// A unified diff read into hunks with line numbers.
struct ParsedDiff: Equatable {
    struct Hunk: Equatable, Identifiable {
        let id: Int
        /// Where it starts in the new file, or the old one when the file was deleted.
        let line: Int
        /// The text git puts after the second `@@`, usually the enclosing function.
        let context: String
        var lines: [Line]
    }

    struct Line: Equatable, Identifiable {
        enum Kind: Equatable { case context, added, deleted }

        let id: Int
        let kind: Kind
        /// The old number for deleted lines, the new one otherwise.
        let number: Int
        let text: String
        /// Followed by `\ No newline at end of file`.
        var noNewline = false

        var accessibilityLabel: String {
            let text = text.isEmpty ? String(localized: "blank line") : text
            switch kind {
            case .context: return String(localized: "Line \(number): \(text)")
            case .added: return String(localized: "Line \(number), added: \(text)")
            case .deleted: return String(localized: "Line \(number), deleted: \(text)")
            }
        }
    }

    var hunks: [Hunk] = []
    /// Git said the files differ but showed no text.
    var binary = false

    init(hunks: [Hunk] = [], binary: Bool = false) {
        self.hunks = hunks
        self.binary = binary
    }

    init(_ patch: String) {
        var old = 0, new = 0
        var oldLeft = 0, newLeft = 0
        var lineID = 0
        // The newline that ends the last line doesn't start another, even in a hunk the limit cut short.
        let body = patch.hasSuffix("\n") ? patch.dropLast() : Substring(patch)
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if oldLeft > 0 || newLeft > 0 {
                let first = raw.first
                let text = String(raw.dropFirst())
                let kind: Line.Kind
                let number: Int
                switch first {
                case "+":
                    kind = .added; number = new; new += 1; newLeft -= 1
                case "-":
                    kind = .deleted; number = old; old += 1; oldLeft -= 1
                case "\\":
                    markNoNewline()
                    continue
                default:
                    // A context line; some tools strip the space off empty ones.
                    kind = .context; number = new; old += 1; new += 1; oldLeft -= 1; newLeft -= 1
                }
                hunks[hunks.count - 1].lines.append(Line(id: lineID, kind: kind, number: number, text: text))
                lineID += 1
                continue
            }
            if raw.hasPrefix("\\") {
                markNoNewline()
            } else if raw.hasPrefix("@@ "), let header = Self.header(raw) {
                old = header.oldStart; new = header.newStart
                oldLeft = header.oldCount; newLeft = header.newCount
                hunks.append(Hunk(id: hunks.count, line: header.newCount > 0 || header.oldStart == 0 ? header.newStart : header.oldStart,
                                  context: header.context, lines: []))
            } else if raw.hasPrefix("Binary files ") || raw.hasPrefix("GIT binary patch") {
                binary = true
            }
        }
    }

    private mutating func markNoNewline() {
        guard !hunks.isEmpty, !hunks[hunks.count - 1].lines.isEmpty else { return }
        hunks[hunks.count - 1].lines[hunks[hunks.count - 1].lines.count - 1].noNewline = true
    }

    /// `@@ -a,b +c,d @@ context`; a missing count is 1.
    private static func header(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, context: String)? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"), parts[3].hasPrefix("@@") else { return nil }
        func range(_ part: Substring) -> (Int, Int)? {
            let numbers = part.dropFirst().split(separator: ",", maxSplits: 1)
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) : 1
            return count.map { (start, $0) }
        }
        guard let (oldStart, oldCount) = range(parts[1]), let (newStart, newCount) = range(parts[2]) else { return nil }
        let context = parts[3].dropFirst(2).trimmingCharacters(in: .whitespaces)
        return (oldStart, oldCount, newStart, newCount, context)
    }
}
