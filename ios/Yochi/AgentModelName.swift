import Foundation

/// The short name of the model an Agent runs, as a person says it: Claude
/// Code records `claude-opus-4-5-20251101`, the page shows "Opus 4.5". An id
/// that isn't Claude's (a proxy can answer with any model) shows as it is.
enum AgentModelName {
    static func short(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bedrock and Vertex wrap the id: `us.anthropic.claude-…-v1:0`, `claude-…@20250514`.
        guard let start = trimmed.range(of: "claude-", options: .caseInsensitive) else { return trimmed }
        let core = trimmed[start.upperBound...].prefix { !":@[".contains($0) }
        var family: String?
        var version: [String] = []
        for token in core.lowercased().split(separator: "-") {
            if token.allSatisfy(\.isNumber) {
                // A date stamp isn't part of the version.
                if token.count <= 2 { version.append(String(token)) }
            } else if family == nil, token.allSatisfy(\.isLetter), !isSuffix(token) {
                family = token.prefix(1).uppercased() + token.dropFirst()
            }
        }
        guard let family else { return trimmed }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }

    private static func isSuffix(_ token: Substring) -> Bool {
        token == "latest" || (token.first == "v" && token.dropFirst().allSatisfy(\.isNumber))
    }
}
